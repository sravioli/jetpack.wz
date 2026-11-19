---@module "jetpack.mosaic.progress"
---@author sravioli
---@license GNU-GPLv2

---mosaic integration `jetpack.progress`: the running operation, e.g.
---"checking beacon.wz 3/5"; hidden otherwise. While a layout uses it, the
---picker's `progress = "auto"` puts progress here instead of mosaic's
---`notice` slot. mosaic reads this file only when a layout names it.
---
---Options (`options["jetpack.progress"]`):
---  icon?   string|false  glyph before the text (default: md_sync); false hides it
---  prefix? boolean       keep the leading "jetpack: " (default: false)

return {
  api = 1,
  events = { "jetpack.progress" },
  new = function(opts)
    local state = require "jetpack.state"
    state.progress_module = true

    local icon = opts.icon
    if icon == nil then
      icon = (require("wezterm").nerdfonts or {}).md_sync or ""
    end
    local prefix = opts.prefix == true

    return function()
      local text = state.get_progress()
      if not text then
        return { enabled = false }
      end
      if not prefix then
        text = text:gsub("^jetpack: ", "")
      end
      return {
        enabled = true,
        cond = true,
        can_hide = false,
        padding = { left = 1 },
        accent = 5, -- colour hint; the preset styles the module
        icon = {
          enabled = icon ~= false and icon ~= "",
          value = icon or "",
          padding = { right = 1 },
        },
        text = { enabled = true, value = text },
      }
    end
  end,
}
