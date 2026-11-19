---@module "jetpack.deps"
---@author sravioli
---@license GNU-GPLv2

---Dependency loader, harbor's pattern: prefer modules already on
---`package.path` (pinned clones, local dev checkouts, specs), then fall back
---to `wezterm.plugin.require`. Required lazily: `setup` puts the pinned clones
---on `package.path` first, so warp itself loads pinned.

local wezterm = require "wezterm"

---@class Jetpack.Deps
---@field warp   Warp.Api
---@field warden Warden
local M = {}

local URL = "https://github.com/sravioli/%s.wz"

---@param module string
---@param name string
---@return table
local function require_plugin(module, name)
  local ok, plugin = pcall(require, module)
  if ok and plugin then
    return plugin
  end
  -- WezTerm's own loader, past jetpack's hook: this is bootstrap code. Before
  -- the first install it must load WezTerm's copy even with `strict`, or
  -- nothing could ever be installed.
  local original = wezterm.plugin.__jetpack and wezterm.plugin.__jetpack.require
    or wezterm.plugin.require
  ok, plugin = pcall(original, URL:format(name))
  if ok and plugin then
    return plugin
  end
  error(("[jetpack] unable to load dependency %s: %s"):format(name, tostring(plugin)))
end

M.warp = require_plugin("warp.api", "warp") --[[@as Warp.Api]]
-- warden loads on first use: only validation needs it, and `validate = false`
-- never touches it.
setmetatable(M, {
  __index = function(t, key)
    if key == "warden" then
      local warden = require_plugin("warden.api", "warden")
      rawset(t, key, warden)
      return warden
    end
  end,
})

return M
