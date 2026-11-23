---@module "jetpack.ops"
---@author sravioli
---@license GNU-GPLv2

---sync, check, update, restore, clean and status. Each returns a report:
---one `Jetpack.Result` per plugin it looked at. A plugin with uncommitted
---changes is never checked out.

local wezterm = require "wezterm"

local config = require "jetpack.config"
local deps = require "jetpack.deps"
local git = require "jetpack.git"
local lock = require "jetpack.lock"
local state = require "jetpack.state"

---@class Jetpack.Result
---@field id      string
---@field name    string
---@field action  string  what happened: installed, updated, restored, locked, current, ...
---@field ok      boolean
---@field detail? string  version reached, or the error

---@class Jetpack.Status
---@field id        string
---@field name      string
---@field url       string
---@field path      string
---@field state     "ok"|"update"|"missing"|"dirty"|"drift"|"unlocked"|"local"
---@field locked?   Jetpack.LockEntry
---@field head?     string
---@field available? Jetpack.Available

local M = {}

---Called before each plugin an operation works on, as
---`on_progress(i, n, name, verb)`. The picker sets it while an operation runs.
---@type fun(i: integer, n: integer, name: string, verb: string)|nil
M.on_progress = nil

local function progress(i, n, name, verb)
  if M.on_progress then
    pcall(M.on_progress, i, n, name, verb)
  end
end

M.exists = require("jetpack.hook").exists

local function result(s, action, ok, detail)
  return { id = s.id, name = s.name, action = action, ok = ok, detail = detail }
end

local function short(commit)
  return commit and commit:sub(1, 7) or "?"
end

---@param entry Jetpack.LockEntry|Jetpack.Available
---@return string
local function label(entry)
  return entry.ref or short(entry.commit)
end

---Specs to act on: `ids` (ids or names), or every git-managed one.
---@param ids? string[]
---@return Jetpack.Spec[]
local function select_specs(ids)
  local out = {}
  if not ids then
    for _, s in ipairs(state.list) do
      if not s.local_dir then
        out[#out + 1] = s
      end
    end
    return out
  end
  for _, want in ipairs(ids) do
    for _, s in ipairs(state.list) do
      if (s.id == want or s.name == want) and not s.local_dir then
        out[#out + 1] = s
      end
    end
  end
  return out
end

---Check out `commit`, fetching once when the clone does not have it yet.
local function checkout(s, commit)
  if not git.commit(s.path, commit) then
    local ok, err = git.fetch(s.path)
    if not ok then
      return false, err
    end
  end
  return git.checkout(s.path, commit)
end

-- Characters cmd.exe interprets even inside an argv element.
local CMD_META = '[%%&|<>^"!%c]'

---Delete one clone. Refuses anything that is not a direct child of the root
---holding a `.git` directory, and (with `keep_work`) any clone with local
---work in it.
---@param p string
---@param keep_work? boolean
---@return boolean ok
---@return string|nil err
local function remove(p, keep_work)
  local root = config.get().root
  local name = p:sub(#root + 2)
  if
    p:sub(1, #root + 1) ~= root .. "/"
    or name == ""
    or name:find "[/\\]"
    or name:find "^%.%.?$"
  then
    return false, "refusing to delete outside the root: " .. p
  end
  if not deps.warp.filesystem.is_dir(p .. "/.git") then
    return false, "not a git clone: " .. p
  end
  if keep_work then
    local work = git.local_work(p)
    if work then
      return false, work
    end
  end
  local argv
  if deps.warp.filesystem.is_win then
    if p:find(CMD_META) then
      return false, "refusing path with cmd.exe metacharacters: " .. p
    end
    argv = { "cmd.exe", "/d", "/c", "rmdir", "/s", "/q", (p:gsub("/", "\\")) }
  else
    argv = { "rm", "-rf", "--", p }
  end
  local ok, _, err = deps.warp.process.run(argv)
  return ok, not ok and err or nil
end

---Clone a missing plugin and check out its locked commit, or lock the newest
---commit its spec accepts.
---@param s Jetpack.Spec
---@param locks table<string, Jetpack.LockEntry>
---@param cloned? string|false what `preclone` found for this plugin: false when
---it is already cloned, an error message when that failed, nil to clone here.
---@return Jetpack.Result
---@return boolean changed lockfile changed
local function install(s, locks, cloned)
  local ok, err
  if cloned == nil then
    ok, err = deps.warp.filesystem.mkdir(config.get().root)
    if ok then
      ok, err = git.clone(s.url, s.path)
    end
  else
    ok, err = not cloned, cloned or nil
  end
  if not ok then
    return result(s, "install", false, err), false
  end
  -- From here on a failure deletes the fresh clone: a clone only exists when
  -- it is checked out at a resolved commit, so setup never loads it unpinned
  -- and retries (and logs) the install on every reload.
  local entry = locks[s.id]
  local fail
  if not entry then
    local commit, ref = git.resolve(s)
    if commit then
      entry = { commit = commit, ref = ref }
    else
      fail = ref
    end
  end
  if not fail then
    ok, err = checkout(s, entry.commit)
    fail = not ok and err or nil
  end
  if fail then
    local removed, rerr = remove(s.path)
    if not removed then
      fail = ("%s; could not remove the clone: %s"):format(tostring(fail), tostring(rerr))
    end
    return result(s, "install", false, fail), false
  end
  local changed = locks[s.id] == nil
  locks[s.id] = entry
  return result(s, "installed", true, label(entry)), changed
end
M.install = install

---Clone the missing ones among `targets` at once, so installing many plugins
---costs about as much as the slowest clone. One missing plugin is left to
---`install`.
---@param targets Jetpack.Spec[]
---@return table<string, string|false> err per path; empty when nothing was cloned
function M.preclone(targets)
  local jobs = {}
  for _, s in ipairs(targets) do
    if not s.local_dir and not M.exists(s.path) then
      jobs[#jobs + 1] = { url = s.url, dir = s.path }
    end
  end
  if #jobs < 2 or not deps.warp.filesystem.mkdir(config.get().root) then
    return {}
  end
  progress(1, 1, ("%d plugins"):format(#jobs), "cloning")
  return git.clone_all(jobs)
end

---Write `locks` when `changed`, turning a write failure into a result.
local function save(locks, changed, report)
  if changed then
    local ok, err = lock.write(config.get().lockfile, locks)
    if not ok then
      report[#report + 1] =
        { id = "lockfile", name = "lockfile", action = "write", ok = false, detail = err }
    end
  end
  return report
end

---Clone missing plugins; check out locked commits; lock unlocked plugins.
---@param ids? string[]
---@return Jetpack.Result[]
function M.sync(ids)
  local locks = lock.read(config.get().lockfile)
  local report, changed = {}, false
  local targets = select_specs(ids)
  local cloned = M.preclone(targets)
  for i, s in ipairs(targets) do
    progress(i, #targets, s.name, "syncing")
    if not M.exists(s.path) then
      local r, c = install(s, locks, cloned[s.path])
      report[#report + 1], changed = r, changed or c
    else
      local entry = locks[s.id]
      if not entry then
        local commit, ref = git.resolve(s)
        if commit then
          entry, changed = { commit = commit, ref = ref }, true
          locks[s.id] = entry
        else
          report[#report + 1] = result(s, "lock", false, ref)
        end
      end
      if entry then
        local head = git.head(s.path)
        if head == entry.commit then
          report[#report + 1] = result(s, "current", true, label(entry))
        elseif git.dirty(s.path) then
          report[#report + 1] = result(s, "sync", false, "uncommitted changes")
        else
          local ok, err = checkout(s, entry.commit)
          report[#report + 1] = result(s, ok and "synced" or "sync", ok, ok and label(entry) or err)
        end
      end
    end
  end
  return save(locks, changed, report)
end

---Fetch every installed target at once, reporting it as one progress step.
---@param targets Jetpack.Spec[]
---@return table<string, string|false> err per path (false: fetched)
local function prefetch(targets)
  local dirs = {}
  for _, s in ipairs(targets) do
    if M.exists(s.path) then
      dirs[#dirs + 1] = s.path
    end
  end
  if #dirs > 0 then
    progress(1, 1, ("%d plugin%s"):format(#dirs, #dirs == 1 and "" or "s"), "fetching")
  end
  return git.fetch_all(dirs)
end

---Fetch and record the newest acceptable commit, without checking it out.
---@param ids? string[]
---@return Jetpack.Result[]
function M.check(ids)
  local locks = lock.read(config.get().lockfile)
  local report = {}
  local targets = select_specs(ids)
  local fetched = prefetch(targets)
  for i, s in ipairs(targets) do
    progress(i, #targets, s.name, "checking")
    if not M.exists(s.path) then
      report[#report + 1] = result(s, "check", false, "not installed")
    else
      local err = fetched[s.path]
      local ok = err == false
      local commit, ref
      if ok then
        commit, ref = git.resolve(s)
      end
      if not commit then
        report[#report + 1] = result(s, "check", false, err or ref)
      else
        state.set_available(s.id, { commit = commit, ref = ref, at = os.time() })
        local entry = locks[s.id]
        local newer = not entry or entry.commit ~= commit
        report[#report + 1] = result(s, newer and "available" or "current", true, ref)
      end
    end
  end
  return report
end

---Fetch, check out the newest acceptable commit and lock it.
---@param ids? string[]
---@return Jetpack.Result[]
function M.update(ids)
  local locks = lock.read(config.get().lockfile)
  local report, changed = {}, false
  local targets = select_specs(ids)
  local fetched = prefetch(targets)
  for i, s in ipairs(targets) do
    progress(i, #targets, s.name, "updating")
    if not M.exists(s.path) then
      local r, c = install(s, locks)
      report[#report + 1], changed = r, changed or c
    elseif git.dirty(s.path) then
      report[#report + 1] = result(s, "update", false, "uncommitted changes")
    else
      local err = fetched[s.path]
      local ok = err == false
      local commit, ref
      if ok then
        commit, ref = git.resolve(s)
      end
      if not commit then
        report[#report + 1] = result(s, "update", false, err or ref)
      else
        state.set_available(s.id, { commit = commit, ref = ref, at = os.time() })
        local entry = locks[s.id]
        local head = git.head(s.path)
        if head == commit and entry and entry.commit == commit then
          report[#report + 1] = result(s, "current", true, ref)
        else
          ok, err = git.checkout(s.path, commit)
          if ok then
            -- Keep where it was, so the update can be undone.
            local prev = entry and entry.commit ~= commit and entry or nil
            locks[s.id], changed =
              {
                commit = commit,
                ref = ref,
                prev = prev and prev.commit or (entry and entry.prev),
                prev_ref = prev and prev.ref or (entry and entry.prev_ref),
              }, true
            -- What was checked out: the lock, unless the clone was moved by hand.
            local from = (entry and entry.commit == head) and label(entry) or short(head)
            report[#report + 1] = result(s, "updated", true, from .. " → " .. ref)
          else
            report[#report + 1] = result(s, "update", false, err)
          end
        end
      end
    end
  end
  return save(locks, changed, report)
end

---Go back to the commit each plugin had before its last update, and lock it.
---@param ids? string[]
---@return Jetpack.Result[]
function M.undo(ids)
  local locks = lock.read(config.get().lockfile)
  local report, changed = {}, false
  local targets = select_specs(ids)
  for i, s in ipairs(targets) do
    progress(i, #targets, s.name, "undoing")
    local entry = locks[s.id]
    if not entry or not entry.prev then
      if ids then
        report[#report + 1] = result(s, "undo", false, "no earlier version recorded")
      end
    elseif not M.exists(s.path) then
      report[#report + 1] = result(s, "undo", false, "not installed")
    elseif git.dirty(s.path) then
      report[#report + 1] = result(s, "undo", false, "uncommitted changes")
    else
      local ok, err = checkout(s, entry.prev)
      if ok then
        local from = label(entry)
        locks[s.id] = { commit = entry.prev, ref = entry.prev_ref }
        changed = true
        report[#report + 1] = result(s, "undone", true, from .. " → " .. label(locks[s.id]))
      else
        report[#report + 1] = result(s, "undo", false, err)
      end
    end
  end
  return save(locks, changed, report)
end

---Check out the locked commits again (undoes an update whose lockfile
---change was reverted, or a manual checkout).
---@param ids? string[]
---@return Jetpack.Result[]
function M.restore(ids)
  local locks = lock.read(config.get().lockfile)
  local report = {}
  local targets = select_specs(ids)
  for i, s in ipairs(targets) do
    progress(i, #targets, s.name, "restoring")
    local entry = locks[s.id]
    if not entry then
      report[#report + 1] = result(s, "restore", false, "not in the lockfile")
    elseif not M.exists(s.path) then
      local r = install(s, locks)
      report[#report + 1] = r
    elseif git.head(s.path) == entry.commit then
      report[#report + 1] = result(s, "current", true, label(entry))
    elseif git.dirty(s.path) then
      report[#report + 1] = result(s, "restore", false, "uncommitted changes")
    else
      local ok, err = checkout(s, entry.commit)
      report[#report + 1] =
        result(s, ok and "restored" or "restore", ok, ok and label(entry) or err)
    end
  end
  return report
end

---@class Jetpack.Commit
---@field hash    string short hash
---@field subject string

---Commits between the locked version and the newest one `check` found,
---newest first. Local git only (the commits are already fetched).
---@param id string spec id
---@param max? integer default 100
---@return Jetpack.Commit[]|nil commits
---@return string|nil err
function M.changes(id, max)
  local s = state.by_id[id]
  if not s or s.local_dir or not M.exists(s.path) then
    return nil, "not installed"
  end
  local entry = lock.read(config.get().lockfile)[id]
  local available = state.get_available(id)
  if not entry or not available then
    return nil, "check for updates first"
  end
  local ok, out, err = git.run(
    s.path,
    "log",
    "--no-decorate",
    "--format=%h%x09%s",
    "--max-count=" .. tostring(max or 100),
    entry.commit .. ".." .. available.commit
  )
  if not ok then
    return nil, err
  end
  local commits = {}
  for line in out:gmatch "[^\n]+" do
    local hash, subject = line:match "^(%x+)\t(.*)$"
    if hash then
      commits[#commits + 1] = { hash = hash, subject = subject }
    end
  end
  return commits
end

---Clones under the root that no spec lists. jetpack's own checkout is kept.
---@return string[] paths
function M.orphans()
  local root = config.get().root
  local ok, entries = pcall(wezterm.read_dir, root)
  if not ok or type(entries) ~= "table" then
    return {}
  end
  local keep = {}
  for _, s in ipairs(state.list) do
    keep[s.path] = true
  end
  if state.own_dir then
    keep[state.own_dir] = true
  end
  local out = {}
  for _, p in ipairs(entries) do
    p = p:gsub("\\", "/")
    if not keep[p] and deps.warp.filesystem.is_dir(p .. "/.git") then
      out[#out + 1] = p
    end
  end
  table.sort(out)
  return out
end

---Delete `paths` (from `orphans()`).
---@param paths? string[]
---@return Jetpack.Result[]
function M.clean(paths)
  local report = {}
  local targets = paths or M.orphans()
  for i, p in ipairs(targets) do
    progress(i, #targets, p:match "[^/]+$", "removing")
    local name = p:match "[^/]+$"
    local ok, err = remove(p, true)
    report[#report + 1] =
      { id = p, name = name, action = ok and "removed" or "remove", ok = ok, detail = err }
  end
  return report
end

---Locked, checked-out and available versions per plugin. Runs git twice per
---clone (HEAD and dirty), so call it on demand, not on every reload.
---@return Jetpack.Status[]
function M.status()
  local locks = lock.read(config.get().lockfile)
  local rows = {}
  for _, s in ipairs(state.list) do
    local row = {
      id = s.id,
      name = s.name,
      url = s.url,
      path = s.path,
      locked = locks[s.id],
      available = state.get_available(s.id),
    }
    if s.local_dir then
      row.state = "local"
    elseif not M.exists(s.path) then
      row.state = "missing"
    else
      row.head = git.head(s.path)
      if git.dirty(s.path) then
        row.state = "dirty"
      elseif not row.locked then
        row.state = "unlocked"
      elseif row.head ~= row.locked.commit then
        row.state = "drift"
      elseif row.available and row.available.commit ~= row.locked.commit then
        row.state = "update"
      else
        row.state = "ok"
      end
    end
    rows[#rows + 1] = row
  end
  return rows
end

-- ── Health report ──────────────────────────────────────────────────────────

---@param seconds number
---@return string
local function ms(seconds)
  return seconds < 0.001 and "<1 ms" or ("%.0f ms"):format(seconds * 1000)
end

---@class Jetpack.Check
---@field level "ok"|"warn"|"info"
---@field text  string

---Everything worth knowing when something seems off. Runs git a few times
---(version, and HEAD/dirty per clone through `status`).
---@return Jetpack.Check[]
function M.doctor()
  local out = {}
  local function add(level, text, ...)
    out[#out + 1] = { level = level, text = text:format(...) }
  end
  local cfg = config.get()
  local fs = deps.warp.filesystem

  add("info", "jetpack %s from %s", require("jetpack.api").VERSION, state.own_dir or "?")

  local git_path = deps.warp.process.which(cfg.git)
  if git_path then
    local _, version = deps.warp.process.run { git_path, "--version" }
    add("ok", "git: %s (%s)", git_path, (version or ""):gsub("%s+$", ""))
  else
    add("warn", "git: `%s` not found; set `git` to its path", cfg.git)
  end

  if fs.is_dir(cfg.root) then
    local probe = cfg.root .. "/.jetpack-write-test"
    local f = io.open(probe, "w")
    if f then
      f:close()
      os.remove(probe)
      add("ok", "root: %s", cfg.root)
    else
      add("warn", "root: %s is not writable", cfg.root)
    end
  else
    add("warn", "root: %s does not exist yet (created on the first install)", cfg.root)
  end

  local lok, locks = pcall(lock.read, cfg.lockfile)
  if not lok then
    add("warn", "lockfile: %s", tostring(locks))
  else
    local n = 0
    for _ in pairs(locks) do
      n = n + 1
    end
    add(
      n > 0 and "ok" or "info",
      "lockfile: %s (%d plugin%s)",
      cfg.lockfile,
      n,
      n == 1 and "" or "s"
    )
  end

  local plugin = wezterm.plugin
  add(
    plugin and plugin.__jetpack and "ok" or "warn",
    "plugin.require/list hooks: %s",
    plugin and plugin.__jetpack and "installed" or "not installed"
  )
  add(
    "info",
    "strict: %s · validation: %s",
    cfg.strict and "on" or "off",
    cfg.validate and "on" or "off"
  )
  if cfg.timings and state.timings.setup then
    add("info", "setup: %s (clones, validation and git included)", ms(state.timings.setup))
  end
  if cfg.auto_check.enabled then
    local due = require("jetpack.auto").next_check() - os.time()
    add(
      "info",
      "automatic check: every %gh, next %s",
      cfg.auto_check.interval_hours,
      due > 0 and ("in %dh %dm"):format(math.floor(due / 3600), math.floor(due % 3600 / 60))
        or "on the next window event"
    )
  else
    add("info", "automatic check: off")
  end

  local held = io.open(cfg.root .. "/.jetpack.lock/since", "r")
  if held then
    held:close()
    add("warn", "lock: another WezTerm process is working on plugins (%s/.jetpack.lock)", cfg.root)
  end

  for _, row in ipairs(M.status()) do
    local s = state.by_id[row.id]
    local module = s and (s.name:gsub("%.wz$", "") .. ".api")
    -- selene: allow(incorrect_standard_library_use)
    local found = module and package.searchpath(module, package.path)
    local where = found and found:gsub("\\", "/") or nil
    local pinned = where and s and where:sub(1, #s.path + 1) == s.path .. "/"
    local level = (row.state == "ok" or row.state == "local") and "ok"
      or row.state == "update" and "info"
      or "warn"
    if where and not pinned then
      level = "warn"
    end
    add(
      level,
      "%s: %s%s · %s%s%s",
      row.name,
      row.state,
      row.locked and (" " .. (row.locked.ref or row.locked.commit:sub(1, 7))) or "",
      row.path,
      state.timings[row.id] and (" · loaded in " .. ms(state.timings[row.id])) or "",
      where and (pinned and "" or (" · but `" .. module .. "` resolves to " .. where)) or ""
    )
  end

  for _, url in ipairs(state.unmanaged_urls()) do
    add("warn", "not pinned: %s (loaded through plugin.require, not in the spec)", url)
  end
  for id in pairs(state.fallbacks) do
    add("warn", "fell back to WezTerm's unpinned copy: %s (its clone is missing)", id)
  end
  return out
end

-- ── Lock between WezTerm processes ────────────────────────────────────────

-- A directory, because creating one is atomic: of two processes racing, one
-- gets it. Older than this, it is taken to be left over from a crash.
M.LOCK_STALE = 15 * 60

local held = 0 -- nesting depth in this Lua state

local function lock_dir()
  return config.get().root .. "/.jetpack.lock"
end

local function rmdir(dir)
  os.remove(dir .. "/since")
  if deps.warp.filesystem.is_win then
    deps.warp.process.run { "cmd.exe", "/d", "/c", "rmdir", "/q", (dir:gsub("/", "\\")) }
  else
    os.remove(dir)
  end
end

local function since(dir)
  local f = io.open(dir .. "/since", "r")
  if not f then
    return nil
  end
  local t = tonumber(f:read "*a")
  f:close()
  return t
end

---@return boolean ok
---@return string|nil why when not acquired
local function acquire()
  if held > 0 then
    held = held + 1
    return true
  end
  local fs = deps.warp.filesystem
  fs.mkdir(config.get().root)
  local dir = lock_dir()
  local argv = fs.is_win and { "cmd.exe", "/d", "/c", "mkdir", (dir:gsub("/", "\\")) }
    or { "mkdir", "--", dir }
  local ok, _, err = deps.warp.process.run(argv)
  if not ok and fs.is_dir(dir) then
    local at = since(dir)
    if at and os.time() - at > M.LOCK_STALE then
      rmdir(dir)
      ok, _, err = deps.warp.process.run(argv)
    else
      local ago = at and math.max(0, os.time() - at) or nil
      return false,
        ("another WezTerm is already working on plugins%s"):format(
          ago and (" (for %ds)"):format(ago) or ""
        )
    end
  end
  if not ok then
    return false, "cannot create " .. dir .. ": " .. tostring(err)
  end
  local f = io.open(dir .. "/since", "w")
  if f then
    f:write(tostring(os.time()))
    f:close()
  end
  held = 1
  return true
end

local function release()
  held = math.max(0, held - 1)
  if held == 0 then
    rmdir(lock_dir())
  end
end

---Run `fn` holding the lock. When another process holds it, returns a
---one-line failure report instead of running.
---@param fn fun(...): Jetpack.Result[]
---@return fun(...): Jetpack.Result[]
function M.locked(fn)
  return function(...)
    local ok, why = acquire()
    if not ok then
      return { { id = "lock", name = "jetpack", action = "lock", ok = false, detail = why } }
    end
    local results = table.pack(pcall(fn, ...))
    release()
    if not results[1] then
      error(results[2], 0)
    end
    return table.unpack(results, 2, results.n)
  end
end

---One-line summary of a report, e.g. "updated 2 · current 9 · failed 1: beacon".
---@param report Jetpack.Result[]
---@return string
function M.summary(report)
  local counts, order, failed = {}, {}, {}
  for _, r in ipairs(report) do
    if r.ok then
      if not counts[r.action] then
        order[#order + 1] = r.action
      end
      counts[r.action] = (counts[r.action] or 0) + 1
    else
      failed[#failed + 1] = r.name
    end
  end
  local parts = {}
  for _, action in ipairs(order) do
    parts[#parts + 1] = ("%s %d"):format(action, counts[action])
  end
  if #failed > 0 then
    parts[#parts + 1] = ("failed %d: %s"):format(#failed, table.concat(failed, ", "))
  end
  return #parts > 0 and table.concat(parts, " · ") or "nothing to do"
end

---Whether a report changed what is checked out (so the config should reload).
---@param report Jetpack.Result[]
---@return boolean
function M.changed(report)
  for _, r in ipairs(report) do
    if
      r.ok
      and (
        r.action == "installed"
        or r.action == "updated"
        or r.action == "synced"
        or r.action == "restored"
        or r.action == "undone"
      )
    then
      return true
    end
  end
  return false
end

-- Everything that runs git or changes clones holds the lock.
for _, name in ipairs { "sync", "check", "update", "undo", "restore", "clean" } do
  M[name] = M.locked(M[name])
end

return M
