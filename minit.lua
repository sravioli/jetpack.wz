---Minimal config for bug reports. Run it in isolation from your own config:
---
---    wezterm --config-file minit.lua
---
---Put your reproduction below the marker. Keep it as small as possible and
---paste the edited file into the bug report.
local wezterm = require "wezterm"
local jetpack = wezterm.plugin.require "https://github.com/sravioli/jetpack.wz"
local config = wezterm.config_builder()

-- Edit below this line --------------------------------------------------------

jetpack.setup {
  spec = { { "sravioli/warp.wz", version = "*" } },
}
jetpack.apply_to_config(config)
config.keys = {
  { key = "P", mods = "CTRL|SHIFT", action = jetpack.action.open() },
}

return config
