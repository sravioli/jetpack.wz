---@module "jetpack.git"
---@author sravioli
---@license GNU-GPLv2

---git through `warp.process.run`: no shell, and git is found even when a
---GUI-launched WezTerm has a short PATH. Every call spawns a process, so
---none of this runs on a normal config reload.

local config = require "jetpack.config"
local deps = require "jetpack.deps"
local semver = require "jetpack.semver"

local M = {}

---@param argv string[]
---@return boolean ok
---@return string stdout trimmed
---@return string stderr trimmed
local function run(argv)
  local git = config.get().git
  table.insert(argv, 1, git)
  local ok, out, err = deps.warp.process.run(argv, { which = { path = git } })
  return ok, (out:gsub("%s+$", "")), (err:gsub("%s+$", ""))
end

---@param dir string
---@return boolean ok
---@return string stdout
---@return string stderr
function M.run(dir, ...)
  return run { "-C", dir, ... }
end

---@param url string
---@param dir string
---@return boolean ok
---@return string|nil err
function M.clone(url, dir)
  -- Full history (tags, changelogs and undo work offline) but file contents
  -- only for what gets checked out.
  local ok, _, err = run { "clone", "--quiet", "--filter=blob:none", "--", url, dir }
  return ok, not ok and err or nil
end

---@param dir string
---@return boolean ok
---@return string|nil err
function M.fetch(dir)
  local ok, _, err = M.run(dir, "fetch", "--quiet", "--tags", "--force", "origin")
  return ok, not ok and err or nil
end

---Fetch several clones at once. POSIX: one `sh` that runs every fetch in the
---background and records each exit status. Windows: one after another.
---@param dirs string[]
---@return table<string, string|false> err per dir: false when it worked
function M.fetch_all(dirs)
  local out = {}
  if #dirs == 0 then
    return out
  end
  local fs = deps.warp.filesystem
  if fs.is_win or #dirs == 1 then
    for _, dir in ipairs(dirs) do
      local ok, err = M.fetch(dir)
      out[dir] = not ok and (err or "fetch failed") or false
    end
    return out
  end
  local git = deps.warp.process.which(config.get().git) or config.get().git
  local script = 'g=$1; shift; for d do ( "$g" -C "$d" fetch --quiet --tags --force origin '
    .. '2>"$d/.git/jetpack-fetch.err"; echo $? >"$d/.git/jetpack-fetch.rc" ) & done; wait'
  local argv = { "sh", "-c", script, "sh", git }
  for _, dir in ipairs(dirs) do
    argv[#argv + 1] = dir
  end
  deps.warp.process.run(argv)
  for _, dir in ipairs(dirs) do
    local function slurp(name)
      local f = io.open(dir .. "/.git/" .. name, "r")
      if not f then
        return nil
      end
      local text = f:read "*a"
      f:close()
      os.remove(dir .. "/.git/" .. name)
      return text
    end
    local rc, err = slurp "jetpack-fetch.rc", slurp "jetpack-fetch.err"
    if tonumber(rc) == 0 then
      out[dir] = false
    else
      out[dir] = (err and err:gsub("%s+$", "") ~= "" and err:gsub("%s+$", "")) or "fetch failed"
    end
  end
  return out
end

---@param dir string
---@param commit string
---@return boolean ok
---@return string|nil err
function M.checkout(dir, commit)
  local ok, _, err = M.run(dir, "-c", "advice.detachedHead=false", "checkout", "--quiet", commit)
  return ok, not ok and err or nil
end

---Commit `ref` points at, or nil.
---@param dir string
---@param ref string
---@return string|nil
function M.commit(dir, ref)
  local ok, out = M.run(dir, "rev-parse", "--verify", "--quiet", ref .. "^{commit}")
  return ok and out ~= "" and out or nil
end

---@param dir string
---@return string|nil
function M.head(dir)
  return M.commit(dir, "HEAD")
end

---@param dir string
---@return string[]
function M.tags(dir)
  local ok, out = M.run(dir, "tag", "--list")
  local tags = {}
  if ok then
    for line in out:gmatch "[^\n]+" do
      tags[#tags + 1] = line
    end
  end
  return tags
end

---Tracked files with uncommitted changes (untracked files are ignored).
---@param dir string
---@return boolean
function M.dirty(dir)
  local ok, out = M.run(dir, "status", "--porcelain", "--untracked-files=no")
  return ok and out ~= ""
end

---Work that deleting the clone would lose: changed or untracked files, or
---commits on no remote. Errs on the side of "yes" when git fails.
---@param dir string
---@return string|nil reason nil when the clone holds nothing local
function M.local_work(dir)
  local ok, out = M.run(dir, "status", "--porcelain")
  if not ok then
    return "cannot read git status"
  elseif out ~= "" then
    return "has uncommitted or untracked files"
  end
  ok, out = M.run(dir, "log", "--oneline", "--branches", "--not", "--remotes")
  if not ok then
    return "cannot list local commits"
  elseif out ~= "" then
    return "has commits not pushed to any remote"
  end
  return nil
end

---@param dir string
---@return string|nil branch e.g. `main`
function M.default_branch(dir)
  local ok, out = M.run(dir, "symbolic-ref", "--short", "refs/remotes/origin/HEAD")
  return ok and out:match "^origin/(.+)$" or nil
end

---Newest commit the spec accepts, from the clone's fetched refs.
---@param s Jetpack.Spec
---@return string|nil commit
---@return string|nil ref tag or branch name, or an error message when commit is nil
function M.resolve(s)
  local dir = s.path
  local kind = require("jetpack.spec").kind(s)
  if kind == "commit" then
    local c = M.commit(dir, s.commit)
    return c, c and s.commit:sub(1, 12) or ("commit not found: " .. s.commit)
  elseif kind == "tag" then
    local c = M.commit(dir, "refs/tags/" .. s.tag)
    return c, c and s.tag or ("tag not found: " .. s.tag)
  elseif kind == "version" then
    local tag = semver.best(s.range, M.tags(dir))
    if not tag then
      return nil, ("no tag matches %s"):format(s.version)
    end
    return M.commit(dir, "refs/tags/" .. tag), tag
  end
  local branch = s.branch or M.default_branch(dir)
  if not branch then
    return nil, "cannot find the default branch"
  end
  local c = M.commit(dir, "refs/remotes/origin/" .. branch)
  return c, c and branch or ("branch not found: " .. branch)
end

return M
