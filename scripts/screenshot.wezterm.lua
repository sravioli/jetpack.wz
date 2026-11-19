-- Minimal WezTerm config for `scripts/screenshots.sh`: a window with a small
-- bar from mosaic.wz (https://github.com/sravioli/mosaic.wz) in the kanagawa
-- scheme ($JETPACK_KANAGAWA: "wave" dark, "lotus" light) of the kanagawa plugin
-- (https://github.com/kanagawa-community/wezterm) and the scene named by
-- $JETPACK_SCENE open. jetpack installs demo plugins from the git repositories
-- in $JETPACK_DEMO/repos. Settings come from the environment so the script stays
-- the only place that knows the defaults.
local wezterm = require "wezterm"

local repo = assert(os.getenv "JETPACK_REPO", "JETPACK_REPO is not set")
local demo = assert(os.getenv "JETPACK_DEMO", "JETPACK_DEMO is not set")
local scene = assert(os.getenv "JETPACK_SCENE", "JETPACK_SCENE is not set")
-- Bar-only scenes: an undecorated one-row window the script crops to the bar.
local bar_only = scene == "bar"
for _, name in ipairs { "mosaic", "warp", "warden", "log", "sigil", "ribbon", "memo" } do
  local base = repo .. "/../" .. name .. ".wz/plugin/"
  package.path = base .. "?.lua;" .. base .. "?/init.lua;" .. package.path
end
package.path = repo .. "/plugin/?.lua;" .. repo .. "/plugin/?/init.lua;" .. package.path

local kanagawa = wezterm.plugin.require "https://github.com/kanagawa-community/wezterm"

local jetpack = require "jetpack.api"
local function git(name, extra)
  local spec = { "file://" .. demo .. "/repos/" .. name .. ".wz" }
  for k, v in pairs(extra) do
    spec[k] = v
  end
  return spec
end
jetpack.setup {
  root = demo .. "/root",
  lockfile = demo .. "/jetpack-lock.json",
  auto_check = false,
  spec = {
    -- jetpack's own dependencies come from the sibling checkouts, not GitHub.
    { "sravioli/warp.wz", dir = repo .. "/../warp.wz" },
    { "sravioli/warden.wz", dir = repo .. "/../warden.wz" },
    git("beacon", { version = "^1" }),
    git("chord", { version = "^2" }),
    git("lantern", { branch = "main" }),
    git("mosaic", { tag = "3.0.0" }),
    git("ribbon", { version = "~1.4" }),
  },
}

local mosaic = require "mosaic.api"
mosaic.setup {
  preset = bar_only and "powerline" or "bubbles",
  position = "top",
  layout = {
    left = { "jetpack.status", "workspace" },
    -- One nested group: the powerline preset draws a group as one gradient,
    -- and a module listed on its own as a separate chip.
    right = { { "jetpack.progress", "jetpack.updates", "clock" } },
  },
  -- Only for the screenshots: room between the count and the next segment.
  options = { ["jetpack.updates"] = { text = { padding = { right = 1 } } } },
}

local config = wezterm.config_builder()
config.font = wezterm.font_with_fallback {
  os.getenv "JETPACK_FONT" or "FiraCode Nerd Font",
  "Symbols Nerd Font",
}
config.font_size = tonumber(os.getenv "JETPACK_FONT_SIZE" or 14)
config.initial_cols = tonumber(os.getenv "JETPACK_COLS" or 100)
config.initial_rows = tonumber(os.getenv "JETPACK_ROWS" or 30)
config.enable_wayland = false -- XWayland: KDE draws the frame and title bar
config.window_decorations = "TITLE | RESIZE"
config.window_padding = { left = 8, right = 8, top = 8, bottom = 8 }
config.enable_scroll_bar = false
config.use_fancy_tab_bar = false
config.hide_tab_bar_if_only_one_tab = false
config.tab_max_width = 24
config.check_for_updates = false
config.status_update_interval = 500
-- The scheme first: mosaic draws the new-tab button in the scheme set when it is applied.
kanagawa.apply_to_config(config, { scheme = os.getenv "JETPACK_KANAGAWA" or "wave" })
mosaic.apply_to_config(config)
jetpack.apply_to_config(config)

if bar_only then
  config.window_decorations = "NONE"
  config.initial_cols = tonumber(os.getenv "JETPACK_BAR_COLS" or 140)
  config.initial_rows = 1 -- the bar plus one row; the script keeps only the bar
  config.window_padding = { left = 0, right = 0, top = 0, bottom = 0 }
end

-- The title bar names the feature on show.
wezterm.on("format-window-title", function()
  return "jetpack: " .. scene
end)

-- Pane content that stays open: fastfetch with a config that prints a logo and
-- colour blocks only, so nothing about the machine the shots are taken on shows.
local pane_cmd =
  { "sh", "-c", ("fastfetch -c %q; exec sleep 100000"):format(repo .. "/scripts/fastfetch.jsonc") }

local function plugin(name)
  for _, row in ipairs(jetpack.status()) do
    if row.name == name then
      return row
    end
  end
  error("no plugin named " .. name)
end

-- scene name -> function(window, pane) that opens it.
local scenes = {
  picker = function(w, p)
    w:perform_action(jetpack.action.open(), p)
  end,
  plugin = function(w, p)
    require("jetpack.picker").menu(w, p, plugin "beacon.wz")
  end,
  changes = function(w, p)
    require("jetpack.picker").changes(w, p, plugin "chord.wz")
  end,
  results = function(w, p)
    require("jetpack.picker").results(w, p, "updating all", jetpack.update())
  end,
  bar = function() end, -- the bar shows the check's result without help
}

wezterm.on("gui-startup", function()
  -- Newer releases appear after the install, so the check has something to find.
  local ok, _, err = wezterm.run_child_process {
    repo .. "/scripts/demo-repos.sh",
    "bump",
    demo .. "/repos",
  }
  assert(ok, err)
  jetpack.check()

  local tab, pane, window = wezterm.mux.spawn_window { args = pane_cmd, cwd = wezterm.home_dir }
  tab:set_title "dotfiles"
  if not bar_only then
    pane:split { direction = "Right", args = pane_cmd }
  end
  pane:activate()
  for _, title in ipairs { "notes", "build" } do
    window:spawn_tab({ cwd = wezterm.home_dir }):set_title(title)
  end
  tab:activate()
  -- The GUI window exists only after startup returns.
  wezterm.time.call_after(1, function()
    scenes[scene](window:gui_window(), pane)
  end)
end)

return config
