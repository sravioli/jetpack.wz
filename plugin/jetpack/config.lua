---@module "jetpack.config"
---@author sravioli
---@license GNU-GPLv2

local wezterm = require "wezterm"

---@class Jetpack.Keybind
---@field key  string
---@field mods string

---@class Jetpack.PickerOptions
---@field title?         string
---@field fuzzy?         boolean
---@field icons?         boolean
---@field hints?         boolean
---@field hint_position? "top"|"status"|"none"
---@field confirm?       boolean  Ask before `clean` deletes clones.
---@field progress?      "auto"|"mosaic"|"notice"|"status"|"none"  Where operation progress shows.
---@field log_pane?      boolean  Also stream progress into a split pane.
---@field key_table?     string
---@field keys?          table<string, Jetpack.Keybind|false>

---@class Jetpack.AutoCheck
---@field enabled?        boolean  Check for updates in the background. Default true.
---@field interval_hours? number   Hours between checks. Minimum 1, default 24.
---@field delay_seconds?  number   Wait after the first window event. Default 10.

---@class Jetpack.Options
---@field spec?     (string|Jetpack.SpecInput)[]
---@field strict?   boolean  Raise instead of loading WezTerm's unpinned copy of a plugin whose clone is missing.
---@field validate? boolean  Validate options with warden.wz. Default true.
---@field auto_check? Jetpack.AutoCheck|false
---@field root?     string  Where clones live. Default: `<data dir>/wezterm/jetpack`.
---@field lockfile? string  Default: `<config dir>/jetpack-lock.json`.
---@field git?      string  git executable (name or path). Default `git`.
---@field picker?   Jetpack.PickerOptions

local M = {}

---Default clone root. Same rule as `warp.filesystem.data_dir`, repeated here
---because it is needed before warp loads.
---@return string
function M.default_root()
  local base
  if (package.config):sub(1, 1) == "\\" then
    base = os.getenv "LOCALAPPDATA" or os.getenv "APPDATA"
  else
    base = os.getenv "XDG_DATA_HOME"
  end
  if not base then
    local home = wezterm.home_dir or os.getenv "HOME" or os.getenv "USERPROFILE" or "."
    base = home .. ((package.config):sub(1, 1) == "\\" and "/AppData/Local" or "/.local/share")
  end
  return (base:gsub("\\", "/"):gsub("/+$", "")) .. "/wezterm/jetpack"
end

---@return table
function M.defaults()
  return {
    spec = {},
    root = M.default_root(),
    lockfile = (wezterm.config_dir or "."):gsub("\\", "/") .. "/jetpack-lock.json",
    git = "git",
    strict = false,
    validate = true,
    auto_check = { enabled = true, interval_hours = 24, delay_seconds = 10 },
    picker = {
      title = "Jetpack",
      fuzzy = true,
      icons = true,
      hints = true,
      hint_position = "top",
      confirm = true,
      -- "auto": the jetpack.progress mosaic module when a layout uses it, else
      -- mosaic's notice slot when mosaic is loaded, else the right status.
      progress = "auto",
      log_pane = false,
      key_table = "jetpack_picker",
      -- Ctrl+N/P/J/K navigate and Ctrl+G/C quit inside InputSelector.
      keys = {
        update = { key = "u", mods = "CTRL" },
        restore = { key = "r", mods = "CTRL" },
        check = { key = "f", mods = "CTRL" },
        browse = { key = "o", mods = "CTRL" },
        copy = { key = "y", mods = "CTRL" },
      },
    },
  }
end

local current

---@param t any
---@param where string
local function check_table(t, where)
  if t ~= nil and type(t) ~= "table" then
    error(("`%s` must be a table"):format(where), 0)
  end
end

---Merge `opts` over the defaults. Two levels (`picker`, `picker.keys`) are
---all there is, so this stays dependency-free.
---@param opts? Jetpack.Options
---@return table
function M.parse(opts)
  opts = opts or {}
  check_table(opts, "options")
  check_table(opts.picker, "picker")
  check_table(opts.picker and opts.picker.keys, "picker.keys")
  local cfg = M.defaults()
  for _, k in ipairs { "root", "lockfile", "git" } do
    if opts[k] ~= nil then
      if type(opts[k]) ~= "string" or opts[k] == "" then
        error(("`%s` must be a non-empty string"):format(k), 0)
      end
      cfg[k] = require("jetpack.spec").expand(opts[k])
    end
  end
  if opts.spec ~= nil then
    cfg.spec = opts.spec
  end
  for k, v in pairs(opts.picker or {}) do
    if k ~= "keys" then
      cfg.picker[k] = v
    end
  end
  for k, v in pairs((opts.picker or {}).keys or {}) do
    cfg.picker.keys[k] = v or nil
  end
  for _, k in ipairs { "strict", "validate" } do
    if opts[k] ~= nil then
      cfg[k] = opts[k] == true
    end
  end
  if opts.auto_check == false then
    cfg.auto_check.enabled = false
  elseif type(opts.auto_check) == "table" then
    for k, v in pairs(opts.auto_check) do
      cfg.auto_check[k] = v
    end
  end
  current = cfg
  return cfg
end

-- ── Validation (warden) ────────────────────────────────────────────────────

local schemas

---Schemas, built once per Lua state. warden loads only when validating.
local function build()
  if schemas then
    return schemas
  end
  local w = require("jetpack.deps").warden
  local text = function()
    return w.string():not_empty():optional()
  end
  local keybind = w.union({
    w.literal(false),
    w.object({ key = w.string():not_empty(), mods = w.string():optional() }):unknown "warn",
  }):optional()
  schemas = {
    options = w.object({
      spec = w.table():optional(),
      root = text(),
      lockfile = text(),
      git = text(),
      strict = w.boolean():optional(),
      validate = w.boolean():optional(),
      auto_check = w.union({
        w.literal(false),
        w.object({
          enabled = w.boolean():optional(),
          interval_hours = w.number():min(1):optional(),
          delay_seconds = w.number():min(0):optional(),
        }):unknown "warn",
      }):optional(),
      picker = w.object({
        title = text(),
        fuzzy = w.boolean():optional(),
        icons = w.boolean():optional(),
        hints = w.boolean():optional(),
        hint_position = w.enum({ "top", "status", "none" }):optional(),
        confirm = w.boolean():optional(),
        progress = w.enum({ "auto", "mosaic", "notice", "status", "none" }):optional(),
        log_pane = w.boolean():optional(),
        key_table = text(),
        keys = w.object({
          update = keybind,
          restore = keybind,
          check = keybind,
          browse = keybind,
          copy = keybind,
        })
          :unknown("warn")
          :optional(),
      })
        :unknown("warn")
        :optional(),
    }):unknown "warn",
    -- A spec entry's named fields (its `[1]` is checked by jetpack.spec).
    entry = w.object({
      url = text(),
      name = text(),
      version = text(),
      tag = text(),
      commit = text(),
      branch = text(),
      dir = text(),
    }):unknown "warn",
  }
  return schemas
end

---@param prefix string
---@param result table warden result
local function report(prefix, result)
  for _, issue in ipairs(result.warnings or {}) do
    wezterm.log_warn(("[jetpack] %s%s: %s"):format(prefix, issue.path_text or "?", issue.message))
  end
  if not result.ok then
    local issue = result.issues[1] or {}
    error(("%s%s: %s"):format(prefix, issue.path_text or "?", issue.message or "invalid"), 0)
  end
end

---Validate options and spec entries with warden. Raises on the first error,
---logs a warning for each unknown field (a typo like `verison` would
---otherwise be ignored silently).
---@param opts? Jetpack.Options
function M.validate(opts)
  -- A missing warden (say, offline before the first install) must not break
  -- the config: skip validation and say so. Schema errors still raise.
  local ok, built = pcall(build)
  if not ok then
    wezterm.log_warn("[jetpack] validation skipped: warden.wz is unavailable: " .. tostring(built))
    return
  end
  local s = built
  report("", s.options:safe_parse(opts or {}))
  for i, entry in ipairs((opts or {}).spec or {}) do
    if type(entry) == "table" then
      local named = {}
      for k, v in pairs(entry) do
        if k ~= 1 then
          named[k] = v
        end
      end
      local label = type(entry[1]) == "string" and entry[1] or entry.url or "?"
      report(("spec[%d] (%s): "):format(i, tostring(label)), s.entry:safe_parse(named))
    end
  end
end

---@return table
function M.get()
  return current or M.parse()
end

return M
