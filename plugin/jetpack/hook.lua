---@module "jetpack.hook"
---@author sravioli
---@license GNU-GPLv2

---Load managed plugins from their pinned clones, and make
---`wezterm.plugin.require`/`list` see them. Plugins that load each other
---through `plugin.require`, or find their own directory through
---`plugin.list()`, then get the pinned copy without changes.

local wezterm = require "wezterm"

local spec = require "jetpack.spec"
local state = require "jetpack.state"

local M = {}

---Whether `path` holds a plugin (`plugin/init.lua`). Pure Lua, no warp.
---@param path string
---@return boolean
function M.exists(path)
  local f = io.open(path .. "/plugin/init.lua", "r")
  if f then
    f:close()
    return true
  end
  return false
end

---Put `<path>/plugin` in front of `package.path`, so `require "<x>.api"`
---resolves to the pinned clone before any other copy.
---@param path string
function M.add_path(path)
  local base = path .. "/plugin/"
  for _, entry in ipairs { base .. "?/init.lua", base .. "?.lua" } do
    if not package.path:find(entry, 1, true) then
      package.path = entry .. ";" .. package.path
    end
  end
end

---Load a managed plugin's `plugin/init.lua` once, the way
---`wezterm.plugin.require` would: called with its component name.
---@param s Jetpack.Spec
---@return any
function M.load(s)
  local loaded = package.loaded[s.component]
  if loaded ~= nil then
    return loaded
  end
  local file = s.path .. "/plugin/init.lua"
  local chunk, err = loadfile(file)
  if not chunk then
    error(("[jetpack] cannot load %s: %s"):format(s.id, tostring(err)), 0)
  end
  local mod = chunk(s.component, file)
  if mod == nil then
    mod = true
  end
  package.loaded[s.component] = mod
  return mod
end

---A managed plugin is about to load without its pinned clone: with
---`strict`, refuse; else say so (once per Lua state) and let WezTerm load its
---own copy, so the config keeps working.
---@param s Jetpack.Spec
function M.unpinned(s)
  if require("jetpack.config").get().strict then
    error(
      ("[jetpack] %s is not installed and `strict` is on; run Sync or fix the spec"):format(s.id),
      0
    )
  end
  if not state.fallbacks[s.id] then
    state.fallbacks[s.id] = true
    wezterm.log_warn(
      ("[jetpack] %s is not installed; loading WezTerm's unpinned copy"):format(s.id)
    )
  end
end

---Remember a plugin loaded through `plugin.require` that no spec lists: it
---runs at whatever version WezTerm cloned. Logged once per WezTerm process.
---@param url string
function M.note_unmanaged(url)
  local key = spec.url_key(url)
  if state.unmanaged[key] then
    return
  end
  state.unmanaged[key] = spec.normalize_url(url)
  state.unmanaged_order[#state.unmanaged_order + 1] = key
  -- Once per WezTerm process, not on every reload.
  local seen = "jetpack.unpinned_logged:" .. key
  if wezterm.GLOBAL and wezterm.GLOBAL[seen] then
    return
  end
  if wezterm.GLOBAL then
    wezterm.GLOBAL[seen] = true
  end
  wezterm.log_warn(
    ("[jetpack] %s is not in the spec, so it is not pinned"):format(spec.normalize_url(url))
  )
end

---Wrap `wezterm.plugin.require` and `wezterm.plugin.list`. Idempotent.
---A managed plugin whose clone is missing falls back to the original
---`require`, so a failed install never breaks the config.
function M.install()
  local plugin = wezterm.plugin
  if not plugin or plugin.__jetpack then
    return
  end
  local original_require, original_list = plugin.require, plugin.list
  plugin.__jetpack = { require = original_require, list = original_list }

  plugin.require = function(url)
    local key = spec.url_key(url)
    local s = state.by_url[key]
    if s then
      if M.exists(s.path) then
        return M.load(s)
      end
      M.unpinned(s)
      return original_require(url)
    end
    M.note_unmanaged(url)
    return original_require(url)
  end

  -- Managed entries come first and replace WezTerm's own clone of the same
  -- URL, so a plugin that finds itself by URL gets the pinned checkout. Only
  -- once that checkout exists: before the first install, a plugin falls back
  -- to WezTerm's copy and must still find that copy here.
  plugin.list = function()
    local list, pinned = {}, {}
    for _, s in ipairs(state.list) do
      if M.exists(s.path) then
        list[#list + 1] = { url = s.url, component = s.component, plugin_dir = s.path }
        pinned[spec.url_key(s.url)] = true
      end
    end
    for _, p in ipairs(original_list()) do
      if not pinned[spec.url_key(tostring(p.url))] then
        list[#list + 1] = p
      end
    end
    return list
  end
end

return M
