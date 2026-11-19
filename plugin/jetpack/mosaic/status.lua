---@module "jetpack.mosaic.status"
---@author sravioli
---@license GNU-GPLv2

---mosaic integration `jetpack.status`: the jetpack view open in this window
---("plugin list", "beacon.wz", "choose updates", "checking for updates…",
---"results", "confirm"), like a mode badge. With no view open it is hidden,
---unless plugins need attention: then it shows "1 missing", "2 unlocked",
---"3 not pinned", tinted. No git runs here. mosaic reads this file only when a layout names
---it.
---
---Options (`options["jetpack.status"]`):
---  icon?        string|false  glyph before the text (default: md_link_variant); false hides it
---  warn_color?  any           tint for the attention text (default: 4)

return {
  api = 1,
  events = { "jetpack.progress" },
  new = function(opts)
    local state = require "jetpack.state"

    local icon = opts.icon
    if icon == nil then
      icon = (require("wezterm").nerdfonts or {}).md_link_variant or ""
    end
    local warn = opts.warn_color or 4

    local function module(text, tint)
      return {
        enabled = true,
        cond = true,
        can_hide = false,
        padding = { left = 1 },
        accent = 5, -- colour hint; the preset styles the module
        tint = tint,
        icon = {
          enabled = icon ~= false and icon ~= "",
          value = icon or "",
          padding = { right = 1 },
        },
        text = { enabled = true, value = text },
      }
    end

    return function(window)
      local ok, wid = pcall(function()
        return window:window_id()
      end)
      local current = state.get_view(ok and wid or nil)
      if current then
        return module(current)
      end
      local s = state.summary()
      local parts = {}
      if s.missing > 0 then
        parts[#parts + 1] = ("%d missing"):format(s.missing)
      end
      if s.unlocked > 0 then
        parts[#parts + 1] = ("%d unlocked"):format(s.unlocked)
      end
      local unpinned = #state.unmanaged_urls()
      if unpinned > 0 then
        parts[#parts + 1] = ("%d not pinned"):format(unpinned)
      end
      if #parts == 0 then
        return { enabled = false }
      end
      return module(table.concat(parts, " · "), warn)
    end
  end,
}
