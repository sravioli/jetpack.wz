---@module "jetpack.api"
---@author sravioli
---@license GNU-GPLv2

---Pinning plugin manager for WezTerm.
---
---```lua
---local jetpack = require "jetpack.api" -- after the bootstrap snippet
---jetpack.setup {
---  spec = {
---    { "sravioli/jetpack.wz", version = "^0.1" },
---    { "sravioli/beacon.wz", version = "*" },
---  },
---}
---local beacon = jetpack.require "beacon.wz"
---jetpack.apply_to_config(config)
---table.insert(config.keys, { key = "p", mods = "LEADER", action = jetpack.action.open() })
---```
---
---A config reload runs no git: clones are checked out at their locked
---commits and only put on `package.path`. git runs on first install and when
---an operation is called.

local wezterm = require "wezterm"

local config = require "jetpack.config"
local hook = require "jetpack.hook"
local spec = require "jetpack.spec"
local state = require "jetpack.state"

---@class Jetpack
local M = {}

M.VERSION = "0.1.0"

-- jetpack's own dependencies, pinned like any plugin unless the spec lists them.
local OWN = { "sravioli/warp.wz", "sravioli/warden.wz" }

---Clones that are missing get installed now: the only time git runs while the
---config loads.
local function install_missing()
  local missing = {}
  for _, s in ipairs(state.list) do
    if not s.local_dir and not hook.exists(s.path) then
      missing[#missing + 1] = s
    end
  end
  if #missing == 0 then
    return
  end
  local ops, lock = require "jetpack.ops", require "jetpack.lock"
  local cfg = config.get()
  -- Read, install and write under one lock: another WezTerm starting at the
  -- same time must not read the lockfile before this one has written it.
  local run = ops.locked(function()
    local ok, locks = pcall(lock.read, cfg.lockfile)
    if not ok then
      wezterm.log_error("[jetpack] " .. tostring(locks) .. "; not installing anything")
      return {}
    end
    local changed = false
    for _, s in ipairs(missing) do
      local r, c = ops.install(s, locks)
      changed = changed or c
      if r.ok then
        hook.add_path(s.path)
        wezterm.log_info(("[jetpack] installed %s %s"):format(s.id, r.detail or ""))
      else
        wezterm.log_error(("[jetpack] cannot install %s: %s"):format(s.id, tostring(r.detail)))
      end
    end
    if changed then
      local wrote, err = lock.write(cfg.lockfile, locks)
      if not wrote then
        wezterm.log_error("[jetpack] cannot write the lockfile: " .. tostring(err))
      end
    end
    return {}
  end)
  -- Another process holds the lock: a one-line failure report, nothing done.
  for _, r in ipairs(run()) do
    wezterm.log_error(
      ("[jetpack] cannot install %d plugin(s): %s"):format(#missing, tostring(r.detail))
    )
  end
end

---Configure jetpack, put the pinned clones on `package.path`, install missing
---ones, and hook `wezterm.plugin.require`/`list`. Safe on every reload.
---@param opts? Jetpack.Options
---@return Jetpack
function M.setup(opts)
  local cfg = config.parse(opts)
  local list, by_id, by_url = spec.list(cfg.spec, cfg.root)
  for _, id in ipairs(OWN) do
    if not by_id[id] then
      -- warp 1.0 added `filesystem.write_file`, which the lockfile needs.
      local s =
        spec.normalize(id == "sravioli/warp.wz" and { id, version = ">=1.0.0" } or id, cfg.root)
      list[#list + 1], by_id[s.id], by_url[spec.url_key(s.url)] = s, s, s
    end
  end
  state.list, state.by_id, state.by_url = list, by_id, by_url

  -- selene: allow(incorrect_standard_library_use)
  local own = package.searchpath("jetpack.api", package.path)
  state.own_dir = own and own:gsub("\\", "/"):match "^(.*)/plugin/jetpack/api%.lua$" or nil

  -- Before anything loads warp, so warp comes from its pinned clone too.
  for _, s in ipairs(list) do
    if hook.exists(s.path) then
      hook.add_path(s.path)
    end
  end
  hook.install()
  install_missing()
  -- After the pinned paths are set, so warden loads pinned too.
  if cfg.validate then
    config.validate(opts)
  end
  return M
end

---Load a managed plugin by id (`owner/repo`), name or URL.
---@param name string
---@return any
function M.require(name)
  local s = state.by_id[name] or state.by_url[spec.url_key(name)]
  if not s then
    for _, candidate in ipairs(state.list) do
      if candidate.name == name then
        s = candidate
        break
      end
    end
  end
  if not s then
    error(("[jetpack] %s is not in the spec"):format(tostring(name)), 2)
  end
  if hook.exists(s.path) then
    return hook.load(s)
  end
  hook.unpinned(s)
  return wezterm.plugin.__jetpack and wezterm.plugin.__jetpack.require(s.url)
    or wezterm.plugin.require(s.url)
end

-- ── Operations ─────────────────────────────────────────────────────────────

---@param ids? string[]
---@return Jetpack.Result[]
function M.sync(ids)
  return require("jetpack.ops").sync(ids)
end

---@param ids? string[]
---@return Jetpack.Result[]
function M.check(ids)
  return require("jetpack.ops").check(ids)
end

---@param ids? string[]
---@return Jetpack.Result[]
function M.update(ids)
  return require("jetpack.ops").update(ids)
end

---@param ids? string[]
---@return Jetpack.Result[]
function M.restore(ids)
  return require("jetpack.ops").restore(ids)
end

---Go back to the version each plugin had before its last update.
---@param ids? string[]
---@return Jetpack.Result[]
function M.undo(ids)
  return require("jetpack.ops").undo(ids)
end

---Delete clones under the root that no spec lists. No confirmation: the
---picker asks first; call `orphans()` to see what would go.
---@return Jetpack.Result[]
function M.clean()
  return require("jetpack.ops").clean()
end

---@return string[]
function M.orphans()
  return require("jetpack.ops").orphans()
end

---Health report: git, root, lockfile, hooks, and where each plugin loads
---from. Logged line by line (so the debug overlay shows it readably) and
---returned.
---@return Jetpack.Check[]
function M.doctor()
  local checks = require("jetpack.ops").doctor()
  for _, c in ipairs(checks) do
    local line = ("[jetpack] %s %s"):format(c.level == "warn" and "!" or "·", c.text)
    if c.level == "warn" then
      wezterm.log_warn(line)
    else
      wezterm.log_info(line)
    end
  end
  return checks
end

---@return Jetpack.Status[]
function M.status()
  return require("jetpack.ops").status()
end

-- ── UI ─────────────────────────────────────────────────────────────────────

local function run_action(what, name)
  return wezterm.action_callback(function(window, pane)
    require("jetpack.picker").run(window, pane, what, require("jetpack.ops")[name])
  end)
end

M.action = {
  ---Key assignment that opens the plugin picker.
  ---@param opts? { title?: string }
  open = function(opts)
    return wezterm.action_callback(function(window, pane)
      require("jetpack.picker").open(window, pane, opts)
    end)
  end,
  update = function()
    return run_action("updating all", "update")
  end,
  sync = function()
    return run_action("syncing", "sync")
  end,
  check = function()
    return run_action("checking", "check")
  end,
}

---Show the picker's hints elsewhere (e.g. chord's status bar). Call before
---`apply_to_config`, with `picker.hint_position = "status"`.
---@param adapter? { keys?: table[], open: function }
function M.set_picker_adapter(adapter)
  require("jetpack.picker").set_adapter(adapter)
end

---Register the picker's key table.
---@param c table WezTerm config
---@return table
function M.apply_to_config(c)
  local picker = require "jetpack.picker"
  local name = config.get().picker.key_table
  c.key_tables = c.key_tables or {}
  c.key_tables[name] = picker.key_table()
  if not picker.key_table_ready then
    picker.register_reloaded()
  end
  require("jetpack.auto").register()
  picker.key_table_ready = true
  return c
end

return M
