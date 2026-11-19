---@module "jetpack.mosaic.updates"
---@author sravioli
---@license GNU-GPLv2

---mosaic integration `jetpack.updates`: shown while the last check found newer
---versions, as the number of plugins that can be updated. No git runs here:
---it reads the lockfile (once per config load) and the check results.
---mosaic reads this file only when a layout names it.
---
---Options (`options["jetpack.updates"]`):
---  icon?  string|false  glyph before the count (default: md_arrow_up_circle); false hides it
---  names? boolean       show the plugin names instead of the count (default: false)

return {
  api = 1,
  events = { "jetpack.progress" },
  new = function(opts)
    local state = require "jetpack.state"

    local icon = opts.icon
    if icon == nil then
      icon = (require("wezterm").nerdfonts or {}).md_arrow_up_circle or ""
    end
    local names = opts.names == true

    return function()
      local updates = state.pending_updates()
      if #updates == 0 then
        return { enabled = false }
      end
      return {
        enabled = true,
        cond = true,
        can_hide = true,
        padding = { left = 1 },
        accent = 7, -- colour hint; the preset styles the module
        icon = {
          enabled = icon ~= false and icon ~= "",
          value = icon or "",
          padding = { right = 1 },
        },
        text = {
          enabled = true,
          value = names and table.concat(updates, " ") or tostring(#updates),
        },
      }
    end
  end,
}
