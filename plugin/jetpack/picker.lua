---@module "jetpack.picker"
---@author sravioli
---@license GNU-GPLv2

---Plugin picker, harbor's design: an InputSelector with one row per plugin
---plus rows for the bulk operations. In-picker actions use a key table that
---stays active while the selector is open: each action key records the
---pending action and sends Enter, so the selector callback receives the
---highlighted row.

local wezterm = require "wezterm"

local config = require "jetpack.config"
local ops = require "jetpack.ops"
local state = require "jetpack.state"

local act = wezterm.action

local M = {}

M.ACTIONS = { "update", "restore", "check", "browse", "copy" }

local sessions = {}
local adapter
local running = false
M.key_table_ready = false

---Install or replace a host adapter (e.g. chord's status-bar hints). Its
---`open(window, pane, session)` may return a cleanup function; `keys` are
---added to the picker's key table.
---@param value? { keys?: table[], open: function }
function M.set_adapter(value)
  adapter = value
end

local function try(label, f, ...)
  local ok, res = pcall(f, ...)
  if not ok then
    wezterm.log_error(("[jetpack] %s failed: %s"):format(label, tostring(res)))
  end
  return ok, res
end

local function close(window, pane, session)
  local wid = window:window_id()
  if sessions[wid] ~= session then
    return
  end
  sessions[wid] = nil
  if session.owns_table then
    try("pop key table", function()
      if window:active_key_table() == session.key_table then
        window:perform_action(act.PopKeyTable, pane)
      end
    end)
  end
  if session.cleanup then
    try("adapter cleanup", session.cleanup)
  end
end

---Start a picker session in `window`: closes any previous one and, when the
---key table is registered, activates it so the shortcut keys work while the
---selector is open.
---@param window any
---@param pane any
---@param cfg table picker config
---@return table session
---@return boolean use_actions
local function start_session(window, pane, cfg)
  local wid = window:window_id()
  if sessions[wid] then
    close(window, pane, sessions[wid])
  end
  local session = { key_table = cfg.key_table }
  sessions[wid] = session
  local use_actions = M.key_table_ready
  if use_actions and window.effective_config then
    local ok, eff = pcall(window.effective_config, window)
    local tables = ok and eff and eff.key_tables
    use_actions = tables ~= nil and tables[cfg.key_table] ~= nil
  end
  if use_actions then
    window:perform_action(act.ActivateKeyTable { name = cfg.key_table, one_shot = false }, pane)
    session.owns_table = true
  end
  return session, use_actions
end

---Record which jetpack view is open in `window` (for `jetpack.status`) and let
---mosaic redraw.
---@param window any
---@param text string|nil
local function view(window, text)
  local ok, wid = pcall(window.window_id, window)
  if ok then
    state.set_view(wid, text)
  end
  pcall(wezterm.emit, "jetpack.progress", window, nil)
end

local function later(fn)
  if wezterm.time and wezterm.time.call_after then
    wezterm.time.call_after(0.1, function()
      try("reopen", fn)
    end)
  end
end

local function active(window, pane)
  local ok, p = pcall(window.active_pane, window)
  return ok and p or pane
end

local function notify(window, msg)
  if window and window.toast_notification then
    pcall(window.toast_notification, window, "jetpack", msg, nil, 4000)
  end
end

-- ── Labels ─────────────────────────────────────────────────────────────────

---Per state: icon, fallback glyph, words shown in the row, colour.
M.STATES = {
  update = { "md_arrow_up_circle", "^", "update available", "Aqua" },
  missing = { "md_download", "+", "not installed", "Yellow" },
  drift = { "md_alert", "!", "not at its locked version", "Yellow" },
  unlocked = { "md_lock_open_variant", "?", "not in the lockfile", "Yellow" },
  dirty = { "md_pencil", "*", "has local changes", "Fuchsia" },
  ok = { "md_check_circle", "=", "up to date", "Lime" },
  ["local"] = { "md_folder", "~", "local checkout", "Blue" },
}

---Colour of each icon, one meaning per colour, so the same glyph always has the
---same colour: aqua update, lime good, yellow needs a fix, blue information or
---navigation, fuchsia unmanaged or edited, red failure or removal. `AnsiColor`
---names follow the colour scheme.
local ICON_COLORS = {
  md_arrow_up_circle = "Aqua",
  md_checkbox_multiple_marked_outline = "Aqua",
  md_text_box_search_outline = "Blue",
  md_cloud_search = "Blue",
  md_open_in_new = "Blue",
  md_content_copy = "Blue",
  md_folder = "Blue",
  md_download = "Yellow",
  md_stethoscope = "Lime",
  md_check = "Lime",
  md_checkbox_marked = "Lime",
  md_information_outline = "Blue",
  md_check_circle = "Lime",
  md_wrench = "Yellow",
  md_lock = "Yellow",
  md_undo = "Yellow",
  md_undo_variant = "Yellow",
  md_alert = "Yellow",
  md_pin_off = "Fuchsia",
  md_pencil = "Fuchsia",
  md_delete_sweep = "Red",
  md_close = "Red",
}

-- Plugins that need attention come first.
local ORDER = { update = 1, missing = 2, drift = 3, unlocked = 4, dirty = 5, ok = 6, ["local"] = 7 }
local NEEDS_FIX = { missing = true, drift = true, unlocked = true }

local DIM = { Attribute = { Intensity = "Half" } }

local function glyph(name, fallback, cfg)
  if not cfg.icons then
    return fallback
  end
  local g = (wezterm.nerdfonts or {})[name]
  return (g and g ~= "") and g or fallback
end

local function extend(list, more)
  for _, item in ipairs(more) do
    list[#list + 1] = item
  end
end

---Items for an icon followed by two spaces. The glyph and one space take `color`
---(a scheme colour name): the selector reverses the selected row, so the colour
---becomes a two-cell block behind the icon there.
local function icon_items(text, color)
  if not color then
    return { { Text = text .. "  " } }
  end
  return {
    { Foreground = { AnsiColor = color } },
    { Text = text .. " " },
    "ResetAttributes",
    { Text = " " },
  }
end

local function format(items, fallback)
  local ok, s = pcall(wezterm.format, items)
  return ok and s or fallback
end

local function width(text)
  local ok, w = pcall(wezterm.column_width, text)
  return ok and w or #text
end

local function pad(text, cells)
  return text .. string.rep(" ", math.max(0, cells - width(text)))
end

local function version(entry)
  return entry and (entry.ref or entry.commit:sub(1, 7)) or nil
end

---"just now", "5m ago", "3h ago", "2d ago".
---@param at integer|nil
---@return string|nil
function M.ago(at)
  if type(at) ~= "number" or at <= 0 then
    return nil
  end
  local d = math.max(0, os.time() - at)
  if d < 60 then
    return "just now"
  elseif d < 3600 then
    return ("%dm ago"):format(math.floor(d / 60))
  elseif d < 86400 then
    return ("%dh ago"):format(math.floor(d / 3600))
  end
  return ("%dd ago"):format(math.floor(d / 86400))
end

---The version column of a plugin row.
---@param row Jetpack.Status
---@return string
function M.version_text(row)
  local locked = version(row.locked)
  if row.state == "update" then
    return ("%s → %s"):format(locked or "?", version(row.available) or "?")
  elseif row.state == "drift" then
    return ("at %s, locked %s"):format(row.head and row.head:sub(1, 7) or "?", locked or "?")
  elseif row.state == "unlocked" then
    return row.head and row.head:sub(1, 7) or ""
  elseif row.state == "local" then
    return ""
  end
  return locked or ""
end

---Label for a plugin row (wezterm.format string). `widths` aligns columns.
---@param row Jetpack.Status
---@param cfg table picker config
---@param widths? { name: integer, version: integer }
---@return string
function M.label(row, cfg, widths)
  local st = M.STATES[row.state] or M.STATES.ok
  local name, ver = row.name, M.version_text(row)
  if widths then
    name, ver = pad(name, widths.name), pad(ver, widths.version)
  end
  local items = icon_items(glyph(st[1], st[2], cfg), st[4])
  extend(items, {
    { Attribute = { Intensity = "Bold" } },
    { Text = name },
    "ResetAttributes",
    { Text = "  " .. ver },
  })
  -- Plugins that need nothing keep a quiet state word.
  if row.state == "ok" or row.state == "local" then
    items[#items + 1] = DIM
  else
    items[#items + 1] = { Foreground = { AnsiColor = st[4] } }
  end
  items[#items + 1] = { Text = "  " .. st[3] }
  items[#items + 1] = "ResetAttributes"
  return format(items, row.name)
end

---Label for an action row: icon, text, dim hint.
---@param cfg table
---@param icon string nerdfonts name
---@param text string
---@param hint? string
---@return string
local function action_label(cfg, icon, text, hint)
  local items = icon_items(glyph(icon, ">", cfg), ICON_COLORS[icon])
  items[#items + 1] = { Text = text }
  if hint and hint ~= "" then
    items[#items + 1] = DIM
    items[#items + 1] = { Text = "  " .. hint }
    items[#items + 1] = "ResetAttributes"
  end
  return format(items, text)
end

---Action rows from `{ id, icon, text, hint? }` specs, with the hints in one column.
---@param cfg table
---@param specs { id: string, icon: string, text: string, hint?: string }[]
---@return { id: string, label: string }[]
local function aligned(cfg, specs)
  local cells = 0
  for _, spec in ipairs(specs) do
    if spec.hint and spec.hint ~= "" then
      cells = math.max(cells, width(spec.text))
    end
  end
  local rows = {}
  for i, spec in ipairs(specs) do
    local text = spec.hint and pad(spec.text, cells) or spec.text
    rows[i] = { id = spec.id, label = action_label(cfg, spec.icon, text, spec.hint) }
  end
  return rows
end

---"a, b, c" or "a, b +3" past `max`.
local function names(rows, max)
  local out = {}
  for i, row in ipairs(rows) do
    if i > max then
      out[#out] = out[#out] .. (" +%d"):format(#rows - max)
      break
    end
    out[#out + 1] = row.name
  end
  return table.concat(out, ", ")
end

---@class Jetpack.Groups
---@field updates Jetpack.Status[] plugins with an update
---@field fix     Jetpack.Status[] missing, drifted or unlocked plugins
---@field dirty   integer         plugins with local changes
---@field checked integer|nil     time of the newest check
---@field sorted  Jetpack.Status[] all rows, those needing attention first
---@field unmanaged string[]     URLs loaded through plugin.require that no spec lists

---Group status rows for the picker.
---@param status Jetpack.Status[]
---@return Jetpack.Groups
function M.groups(status)
  local g = { updates = {}, fix = {}, dirty = 0, sorted = {}, unmanaged = state.unmanaged_urls() }
  for i, row in ipairs(status) do
    if row.state == "update" then
      g.updates[#g.updates + 1] = row
    elseif NEEDS_FIX[row.state] then
      g.fix[#g.fix + 1] = row
    elseif row.state == "dirty" then
      g.dirty = g.dirty + 1
    end
    if row.available and (not g.checked or row.available.at > g.checked) then
      g.checked = row.available.at
    end
    g.sorted[i] = row
  end
  local index = {}
  for i, row in ipairs(status) do
    index[row] = i
  end
  table.sort(g.sorted, function(x, y)
    local ox, oy = ORDER[x.state] or 9, ORDER[y.state] or 9
    if ox ~= oy then
      return ox < oy
    end
    return index[x] < index[y]
  end)
  return g
end

---One line: what needs attention, and when updates were last checked.
---@param status Jetpack.Status[]
---@return string
function M.summary_line(status)
  local g = M.groups(status)
  local parts = { ("%d plugin%s"):format(#status, #status == 1 and "" or "s") }
  local n = #g.updates
  if n > 0 then
    parts[#parts + 1] = ("%d update%s available"):format(n, n == 1 and "" or "s")
  end
  if #g.fix > 0 then
    parts[#parts + 1] = ("%d need%s fixing"):format(#g.fix, #g.fix == 1 and "s" or "")
  end
  if g.dirty > 0 then
    parts[#parts + 1] = ("%d with local changes"):format(g.dirty)
  end
  if #g.unmanaged > 0 then
    parts[#parts + 1] = ("%d not pinned"):format(#g.unmanaged)
  end
  if n == 0 and #g.fix == 0 and g.dirty == 0 and #g.unmanaged == 0 then
    parts[#parts + 1] = g.checked and "all up to date" or "all at their locked versions"
  end
  local ago = M.ago(g.checked)
  parts[#parts + 1] = ago and ("checked " .. ago) or "not checked for updates yet"
  return table.concat(parts, " · ")
end

---What "Fix" will do, e.g. "install 1, restore 1, lock 1".
local function fix_hint(rows)
  local n = { missing = 0, drift = 0, unlocked = 0 }
  for _, row in ipairs(rows) do
    n[row.state] = n[row.state] + 1
  end
  local parts = {}
  for _, k in ipairs { { "missing", "install" }, { "drift", "restore" }, { "unlocked", "lock" } } do
    if n[k[1]] > 0 then
      parts[#parts + 1] = ("%s %d"):format(k[2], n[k[1]])
    end
  end
  return table.concat(parts, ", ")
end

---Shortcut shown next to a menu action, e.g. "Ctrl+U".
local function shortcut(cfg, action)
  local k = cfg.keys[action]
  if not k or not M.key_table_ready then
    return nil
  end
  local mods = ""
  if k.mods and k.mods ~= "" then
    mods = k.mods:gsub("CTRL", "Ctrl"):gsub("SHIFT", "Shift"):gsub("ALT", "Alt"):gsub("|", "+")
      .. "+"
  end
  return mods .. k.key:upper()
end

---Hint line built from the bindings shown in the picker.
---@param bindings table[]
---@return string
function M.hints(bindings)
  local parts = {}
  for _, k in ipairs(bindings) do
    local mods = k.mods and k.mods ~= "" and (k.mods:gsub("|", "+") .. "+") or ""
    parts[#parts + 1] = ("%s%s %s"):format(mods, k.key, k.desc)
  end
  return table.concat(parts, "  ")
end

-- ── Key table ──────────────────────────────────────────────────────────────

---Key table entries for the in-picker actions (registered by apply_to_config).
---@param cfg? table picker config
---@return table[]
function M.key_table(cfg)
  cfg = cfg or config.get().picker
  local entries = {}
  for _, name in ipairs(M.ACTIONS) do
    local k = cfg.keys[name]
    if k then
      entries[#entries + 1] = {
        key = k.key,
        mods = k.mods,
        desc = name,
        action = wezterm.action_callback(function(window, pane)
          local session = sessions[window:window_id()]
          if not session or not session.owns_table or session.swallow then
            -- Views without shortcuts (results, checklist) keep the table only
            -- so a stray or repeated key cannot reach the selector, which
            -- would take it as a choice.
            return
          end
          session.pending = name
          local ok =
            try("action key", window.perform_action, window, act.SendKey { key = "Enter" }, pane)
          if not ok then
            close(window, pane, session)
          end
        end),
      }
    end
  end
  if adapter and cfg.hints and cfg.hint_position == "status" then
    for _, entry in ipairs(adapter.keys or {}) do
      entries[#entries + 1] = entry
    end
  end
  return entries
end

-- ── Running operations ─────────────────────────────────────────────────────

---Reopen the picker shortly, in whatever pane is active by then (the pane an
---overlay reported may be the log pane, closed in the meantime).
local function reopen(window, pane, notice)
  if wezterm.time and wezterm.time.call_after then
    wezterm.time.call_after(0.1, function()
      try("reopen", M.open, window, active(window, pane), { notice = notice })
    end)
  end
end

-- ── Progress ───────────────────────────────────────────────────────────────

---Where progress goes: "mosaic" (the `jetpack.progress` module), "notice"
---(mosaic's notice slot), "status" (the right status) or "none". "auto" picks
---the module when a layout uses it, else the notice slot when mosaic is
---loaded (its bar would overwrite a right status), else the right status.
---@return string
local function progress_mode()
  local mode = config.get().picker.progress
  if mode == "auto" then
    if state.progress_module then
      return "mosaic"
    end
    return package.loaded["mosaic.api"] and "notice" or "status"
  end
  return mode
end

---Show `text` while an operation runs. It is always recorded for the
---`jetpack.progress` module, and `jetpack.progress` is emitted so mosaic redraws.
---@param window any
---@param pane any
---@param text string|nil nil clears it
---@param seconds? number how long a notice lasts
local function show_progress(window, pane, text, seconds)
  state.set_progress(text)
  try("progress event", wezterm.emit, "jetpack.progress", window, pane)
  local mode = progress_mode()
  if mode == "notice" then
    if text then
      try("progress notice", wezterm.emit, "mosaic-notify", window, pane, text, {
        seconds = seconds or 60,
        icon = (wezterm.nerdfonts or {}).md_sync,
      })
    end
  elseif mode == "status" and window.set_right_status then
    try("progress status", window.set_right_status, window, text and wezterm.format {
      { Attribute = { Intensity = "Bold" } },
      { Text = " " .. text .. " " },
    } or "")
  end
end

---File the optional log pane follows.
---@return string
function M.log_file()
  return config.get().root .. "/jetpack.log"
end

-- In GLOBAL: a reload replaces this Lua state, and the pane must still be
-- found (and reused or closed) afterwards.
local LOG_PANE = "jetpack.log_pane"

---The log pane, when it is still open.
---@return any|nil
local function log_pane()
  local id = wezterm.GLOBAL and wezterm.GLOBAL[LOG_PANE]
  if not id then
    return nil
  end
  local ok, p = pcall(wezterm.mux.get_pane, id)
  return ok and p or nil
end

---Marker file whose appearance makes the log pane's command exit.
---@return string
local function done_file()
  return M.log_file() .. ".done"
end

---Close the log pane, if one is open: the pane's own command sees the marker
---and exits cleanly, so WezTerm closes the pane. No pane is focused or closed
---through an action, so no other pane can be affected.
---@param _window any
function M.close_log_pane(_window)
  if wezterm.GLOBAL then
    wezterm.GLOBAL[LOG_PANE] = nil
  end
  local f = io.open(done_file(), "w")
  if f then
    f:close()
  end
end

local function append_log(line)
  local f = io.open(M.log_file(), "a")
  if f then
    f:write(os.date "%H:%M:%S", "  ", line, "\n")
    f:close()
  end
end

---Start a fresh log and make sure a split pane follows it.
local function open_log_pane(pane, what)
  local fs = require("jetpack.deps").warp.filesystem
  fs.mkdir(config.get().root)
  local f = io.open(M.log_file(), "w")
  if f then
    f:close()
  end
  append_log("jetpack: " .. what)
  if log_pane() then
    return
  end
  os.remove(done_file())
  local file, done = M.log_file(), done_file()
  -- Follow the log until the done marker appears, then exit 0: a clean exit
  -- closes the pane under WezTerm's default exit_behavior.
  local args
  if fs.is_win then
    local function q(x)
      return "'" .. x:gsub("'", "''") .. "'"
    end
    args = {
      "powershell.exe",
      "-NoProfile",
      "-Command",
      (
        "$f=%s; $d=%s; $n=0; while (-not (Test-Path -LiteralPath $d)) { "
        .. "$c=[IO.File]::ReadAllText($f); if ($c.Length -gt $n) { "
        .. "[Console]::Write($c.Substring($n)); $n=$c.Length }; "
        .. "Start-Sleep -Milliseconds 200 }; exit 0"
      ):format(q(file), q(done)),
    }
  else
    args = {
      "sh",
      "-c",
      'tail -n +1 -f "$1" & t=$!; while [ ! -e "$2" ]; do sleep 0.2; done; '
        .. 'kill "$t" 2>/dev/null; rm -f "$2"; exit 0',
      "sh",
      file,
      done,
    }
  end
  local ok, split =
    try("log pane", pane.split, pane, { direction = "Bottom", size = 0.3, args = args })
  if ok and split and wezterm.GLOBAL then
    wezterm.GLOBAL[LOG_PANE] = split:pane_id()
  end
  -- The split takes focus; give it back so the results view gets the keys.
  if pane.activate then
    try("refocus pane", pane.activate, pane)
  end
end

-- ── Results ────────────────────────────────────────────────────────────────

-- Results of an operation that changed checked-out code. WezTerm reloads the
-- config when files it loaded change, which replaces this Lua state and kills
-- its callbacks and timers; so such results are kept in GLOBAL and shown by
-- the new state, after the reloads settle.
local PENDING = "jetpack.results"
local SETTLE = 1.5

local function json_encode(v)
  local serde = wezterm.serde
  return (serde and serde.json_encode or wezterm.json_encode)(v)
end

local function json_decode(s)
  local serde = wezterm.serde
  return (serde and serde.json_decode or wezterm.json_parse)(s)
end

---Show pending results in the window they belong to, once no further reload
---has replaced this state for `SETTLE` seconds (a replaced state's timer
---never fires, and the new state schedules its own).
function M.register_reloaded()
  wezterm.on("window-config-reloaded", function(window)
    local global = wezterm.GLOBAL
    if not global or not global[PENDING] then
      return
    end
    local id = window:window_id()
    wezterm.time.call_after(SETTLE, function()
      local ok, pending = pcall(json_decode, wezterm.GLOBAL[PENDING] or "")
      if not ok or type(pending) ~= "table" or pending.window ~= id then
        return
      end
      wezterm.GLOBAL[PENDING] = nil
      local aok, current = pcall(window.active_pane, window)
      if aok and current then
        try("results after reload", M.results, window, current, pending.what, pending.report)
      end
    end)
  end)
end

---Label for one result row.
---@param r Jetpack.Result
---@param cfg table picker config
---@param widths? { name: integer, what: integer } aligns the columns
---@return string
function M.result_label(r, cfg, widths)
  local name = r.name
  local what = r.ok and r.action or ("failed: " .. r.action)
  if widths then
    name, what = pad(name, widths.name), pad(what, widths.what)
  end
  local items = r.ok and icon_items(glyph("md_check", "+", cfg), ICON_COLORS.md_check)
    or icon_items(glyph("md_close", "x", cfg), ICON_COLORS.md_close)
  extend(items, {
    { Attribute = { Intensity = "Bold" } },
    { Text = name },
    "ResetAttributes",
  })
  if not r.ok then
    items[#items + 1] = { Foreground = { AnsiColor = "Red" } }
  elseif r.action == "updated" then
    items[#items + 1] = { Foreground = { AnsiColor = "Aqua" } }
  end
  items[#items + 1] = { Text = "  " .. what }
  items[#items + 1] = "ResetAttributes"
  if r.detail then
    items[#items + 1] = DIM
    items[#items + 1] = { Text = "  " .. r.detail }
    items[#items + 1] = "ResetAttributes"
  end
  local ok, text = pcall(wezterm.format, items)
  return ok and text or r.name
end

---Show what an operation did, one row per plugin. Any row goes back to the
---picker; Escape closes. Leaving it closes the log pane.
---@param window any
---@param pane any
---@param what string
---@param report Jetpack.Result[]
function M.results(window, pane, what, report)
  local cfg = config.get().picker
  local choices = { { id = "back", label = action_label(cfg, "md_arrow_left", "Back to plugins") } }
  local updated = {}
  for _, r in ipairs(report) do
    if r.ok and r.action == "updated" then
      updated[#updated + 1] = r.id
    end
  end
  if #updated > 0 then
    choices[#choices + 1] = {
      id = "undo",
      label = action_label(
        cfg,
        "md_undo_variant",
        #updated == 1 and "Undo this update" or ("Undo these %d updates"):format(#updated)
      ),
    }
  end
  local widths = { name = 0, what = 0 }
  for _, r in ipairs(report) do
    widths.name = math.max(widths.name, width(r.name))
    widths.what = math.max(widths.what, width(r.ok and r.action or ("failed: " .. r.action)))
  end
  for i, r in ipairs(report) do
    choices[#choices + 1] = { id = "result:" .. i, label = M.result_label(r, cfg, widths) }
  end
  local wid = window:window_id()
  local session = start_session(window, pane, cfg)
  session.swallow = true
  view(window, "results")
  window:perform_action(
    act.InputSelector {
      title = ("%s: %s"):format(cfg.title, what),
      description = ops.summary(report) .. "   |   Enter: back   Esc: close",
      fuzzy = false,
      choices = choices,
      action = wezterm.action_callback(function(w, p, id)
        view(w, nil)
        if sessions[wid] == session then
          close(w, p, session)
        end
        M.close_log_pane(w)
        if id == "undo" then
          later(function()
            M.run(w, active(w, p), "undoing " .. #updated .. " update(s)", function()
              return ops.undo(updated)
            end)
          end)
        elseif id then
          reopen(w, p)
        end
      end),
    },
    pane
  )
end

---Run `fn` (an ops function returning a report) with progress in the status
---bar (and the log pane when enabled), then show the results.
---@param window any
---@param pane any
---@param what string shown while it runs
---@param fn fun(): Jetpack.Result[]
function M.run(window, pane, what, fn)
  if running then
    notify(window, "busy: another operation is running")
    return
  end
  running = true
  view(window, what .. "…")
  local cfg = config.get().picker
  if cfg.log_pane then
    try("log pane", open_log_pane, pane, what)
  end
  show_progress(window, pane, "jetpack: " .. what .. "…")
  ops.on_progress = function(i, n, name, verb)
    local line = ("jetpack: %s %s %d/%d"):format(verb, name, i, n)
    show_progress(window, pane, line)
    if cfg.log_pane then
      append_log(line)
    end
  end
  local ok, report = try(what, fn)
  ops.on_progress = nil
  running = false
  view(window, nil)
  if not ok then
    M.close_log_pane(window)
    show_progress(window, pane, nil)
    notify(window, what .. " failed: " .. tostring(report))
    return
  end
  for _, r in ipairs(report) do
    local line = ("%s %s%s"):format(r.action, r.name, r.detail and (": " .. r.detail) or "")
    if r.ok then
      wezterm.log_info("[jetpack] " .. line)
    else
      wezterm.log_warn("[jetpack] " .. line)
    end
    if cfg.log_pane then
      append_log((r.ok and "  ok  " or "  !!  ") .. line)
    end
  end
  local summary = "jetpack: " .. ops.summary(report)
  if cfg.log_pane then
    append_log(summary)
  end
  show_progress(window, pane, summary, 5)
  -- A notice expires on its own; the module and the right status are cleared
  -- now (the results view shows the summary).
  if progress_mode() == "notice" then
    state.set_progress(nil)
    try("progress event", wezterm.emit, "jetpack.progress", window, pane)
  else
    show_progress(window, pane, nil)
  end
  if ops.changed(report) and wezterm.GLOBAL then
    -- The reload replaces this state; the new one shows the results.
    wezterm.GLOBAL[PENDING] =
      json_encode { window = window:window_id(), what = what, report = report }
    wezterm.reload_configuration()
    return
  end
  M.results(window, pane, what, report)
end

---Whether an operation is running in this Lua state.
---@return boolean
function M.busy()
  return running
end

---Run `fn` with progress in the status bar but no view and no log pane:
---for the automatic check. Results go to the WezTerm log; a summary shows in
---mosaic's notice slot when that is where progress goes.
---@param window any
---@param pane any
---@param what string
---@param fn fun(): Jetpack.Result[]
function M.background(window, pane, what, fn)
  if running then
    return
  end
  running = true
  show_progress(window, pane, "jetpack: " .. what .. "…")
  ops.on_progress = function(i, n, name, verb)
    show_progress(window, pane, ("jetpack: %s %s %d/%d"):format(verb, name, i, n))
  end
  local ok, report = try(what, fn)
  ops.on_progress = nil
  running = false
  if not ok then
    show_progress(window, pane, nil)
    return
  end
  for _, r in ipairs(report) do
    local line = ("[jetpack] %s %s%s"):format(
      r.action,
      r.name,
      r.detail and (": " .. r.detail) or ""
    )
    if r.ok then
      wezterm.log_info(line)
    else
      wezterm.log_warn(line)
    end
  end
  local found = #state.pending_updates()
  local summary = found > 0
      and ("jetpack: %d update%s available"):format(found, found == 1 and "" or "s")
    or nil
  if summary and progress_mode() == "notice" then
    show_progress(window, pane, summary, 8)
    state.set_progress(nil)
    try("progress event", wezterm.emit, "jetpack.progress", window, pane)
  else
    show_progress(window, pane, nil)
  end
end

local function confirm(window, pane, question, yes, on_yes, on_no)
  view(window, "confirm")
  window:perform_action(
    act.InputSelector {
      title = "jetpack: " .. question,
      description = question .. "   Enter: choose   Esc: cancel",
      fuzzy = false,
      choices = { { id = "no", label = "Cancel" }, { id = "yes", label = yes } },
      action = wezterm.action_callback(function(w, p, id)
        view(w, nil)
        if id == "yes" then
          try("confirmed action", on_yes, w, p)
        else
          try("declined action", on_no, w, p)
        end
      end),
    },
    pane
  )
end

---Run one action on one plugin.
---@param action string update, restore, check, install, browse, copy, copy_path
---@param window any
---@param pane any
---@param row Jetpack.Status
function M.perform(action, window, pane, row)
  if action == "browse" then
    try("open url", wezterm.open_with, row.url)
  elseif action == "changes" then
    M.changes(window, pane, row)
  elseif action == "copy" or action == "copy_path" then
    local text = action == "copy_path" and row.path
      or (row.locked and row.locked.commit)
      or row.head
      or row.url
    try("copy", window.copy_to_clipboard, window, text, "Clipboard")
    reopen(window, pane, "Copied " .. text)
  elseif row.state == "local" then
    reopen(window, pane, row.name .. " is a local checkout; jetpack does not run git on it.")
  elseif row.state == "dirty" and action ~= "check" then
    reopen(window, pane, row.name .. " has local changes; commit or stash them first.")
  elseif action == "install" then
    M.run(window, pane, "installing " .. row.name, function()
      return ops.sync { row.id }
    end)
  elseif action == "update" or action == "restore" or action == "check" or action == "undo" then
    local verb =
      { update = "updating", restore = "restoring", check = "checking", undo = "undoing" }
    M.run(window, pane, verb[action] .. " " .. row.name, function()
      return ops[action] { row.id }
    end)
  end
end

-- ── Plugin menu ────────────────────────────────────────────────────────────

---One sentence about where a plugin stands.
---@param row Jetpack.Status
---@return string
function M.describe(row)
  local locked = version(row.locked)
  local available = version(row.available)
  if row.state == "update" then
    return ("locked at %s; %s is available"):format(locked, available)
  elseif row.state == "missing" then
    return locked and ("not installed yet; locked at %s"):format(locked) or "not installed yet"
  elseif row.state == "drift" then
    return ("checked out at %s, but locked at %s"):format(
      row.head and row.head:sub(1, 7) or "?",
      locked or "?"
    )
  elseif row.state == "unlocked" then
    return "installed, but not in the lockfile yet"
  elseif row.state == "dirty" then
    return "has uncommitted changes; commit or stash them before jetpack can move it"
  elseif row.state == "local" then
    return "loaded from " .. row.path .. "; jetpack does not run git on it"
  end
  if row.available then
    return ("locked at %s; nothing newer found (checked %s)"):format(
      locked or "?",
      M.ago(row.available.at) or "earlier"
    )
  end
  return ("locked at %s; not checked for updates yet"):format(locked or "?")
end

---The actions that make sense for a plugin, most useful first.
---@param row Jetpack.Status
---@return { id: string, icon: string, text: string, hint?: string }[]
function M.menu_items(row)
  local items = {}
  local function add(id, icon, text, hint)
    items[#items + 1] = { id = id, icon = icon, text = text, hint = hint }
  end
  local st = row.state
  if st == "update" then
    add("update", "md_arrow_up_circle", "Update to " .. version(row.available))
    add("changes", "md_text_box_search_outline", "See what changed")
    add("check", "md_cloud_search", "Check again")
  elseif st == "missing" then
    add("install", "md_download", "Install", version(row.locked) and ("at " .. version(row.locked)))
  elseif st == "drift" then
    add("restore", "md_undo", "Go back to the locked version " .. (version(row.locked) or ""))
    add("update", "md_arrow_up_circle", "Update to the newest version instead")
  elseif st == "unlocked" then
    add("update", "md_lock", "Lock the newest matching version")
  elseif st == "ok" then
    add("check", "md_cloud_search", "Check for a newer version")
    add(
      "update",
      "md_arrow_up_circle",
      "Update now",
      "fetch and move to the newest matching version"
    )
  end
  if row.locked and row.locked.prev and st ~= "local" then
    add(
      "undo",
      "md_undo_variant",
      "Undo the last update",
      "back to " .. (row.locked.prev_ref or row.locked.prev:sub(1, 7))
    )
  end
  if st ~= "local" then
    add("browse", "md_open_in_new", "Open the repository")
  end
  if row.locked then
    add("copy", "md_content_copy", "Copy the locked commit")
  end
  if st == "dirty" or st == "local" then
    add("copy_path", "md_folder", "Copy the folder path")
  end
  return items
end

---Open the action menu for one plugin.
---@param window any
---@param pane any
---@param row Jetpack.Status
function M.menu(window, pane, row)
  local cfg = config.get().picker
  local specs = {}
  for _, item in ipairs(M.menu_items(row)) do
    local hint = item.hint
    if item.id == "changes" then
      local commits = ops.changes(row.id)
      if commits then
        hint = ("%d commit%s"):format(#commits, #commits == 1 and "" or "s")
      end
    end
    local key = shortcut(cfg, item.id)
    if key then
      hint = hint and (hint .. "   " .. key) or key
    end
    specs[#specs + 1] = { id = item.id, icon = item.icon, text = item.text, hint = hint }
  end
  specs[#specs + 1] = { id = "back", icon = "md_arrow_left", text = "Back to plugins" }
  local choices = aligned(cfg, specs)
  local wid = window:window_id()
  local session = start_session(window, pane, cfg)
  view(window, row.name)
  window:perform_action(
    act.InputSelector {
      title = ("%s: %s"):format(cfg.title, row.name),
      description = row.name .. " " .. M.describe(row) .. "   |   Enter: choose   Esc: close",
      fuzzy = false,
      choices = choices,
      action = wezterm.action_callback(function(w, p, id)
        if sessions[wid] ~= session then
          return
        end
        view(w, nil)
        -- A shortcut key acts on this plugin, whatever row is highlighted.
        local pending = session.pending
        close(w, p, session)
        if pending and id then
          M.perform(pending, w, p, row)
        elseif id == "back" then
          reopen(w, p)
        elseif id then
          M.perform(id, w, p, row)
        end
      end),
    },
    pane
  )
end

-- ── What changed ───────────────────────────────────────────────────────────

---Commits an update would bring in, newest first. Enter on one opens it on
---GitHub (or copies its hash elsewhere); the top row updates.
---@param window any
---@param pane any
---@param row Jetpack.Status
function M.changes(window, pane, row)
  local cfg = config.get().picker
  local commits, err = ops.changes(row.id)
  if not commits then
    return reopen(
      window,
      pane,
      ("Cannot list the changes of %s: %s"):format(row.name, tostring(err))
    )
  end
  local github = row.url:match "^https?://github%.com/"
  local choices = {
    {
      id = "update",
      label = action_label(
        cfg,
        "md_arrow_up_circle",
        "Update to " .. (version(row.available) or "?")
      ),
    },
  }
  for i, c in ipairs(commits) do
    choices[#choices + 1] = {
      id = "commit:" .. i,
      label = format({
        { Foreground = { AnsiColor = "Yellow" } },
        { Text = c.hash .. "  " },
        "ResetAttributes",
        { Text = c.subject },
      }, c.subject),
    }
  end
  choices[#choices + 1] =
    { id = "back", label = action_label(cfg, "md_arrow_left", "Back to " .. row.name) }
  local wid = window:window_id()
  local session = start_session(window, pane, cfg)
  session.swallow = true
  view(window, row.name .. ": changes")
  window:perform_action(
    act.InputSelector {
      title = ("%s: %s changes"):format(cfg.title, row.name),
      description = ("%d commit%s from %s to %s   |   Enter on a commit: %s   Esc: close"):format(
        #commits,
        #commits == 1 and "" or "s",
        version(row.locked) or "?",
        version(row.available) or "?",
        github and "open it" or "copy its hash"
      ),
      fuzzy = false,
      choices = choices,
      action = wezterm.action_callback(function(w, p, id)
        view(w, nil)
        if sessions[wid] == session then
          close(w, p, session)
        end
        if not id then
          return
        elseif id == "update" then
          return M.perform("update", w, p, row)
        elseif id == "back" then
          return later(function()
            M.menu(w, active(w, p), row)
          end)
        end
        local c = commits[tonumber(id:match "^commit:(%d+)$")]
        if c and github then
          try("open commit", wezterm.open_with, row.url .. "/commit/" .. c.hash)
        elseif c then
          try("copy", w.copy_to_clipboard, w, c.hash, "Clipboard")
        end
        later(function()
          M.changes(w, active(w, p), row)
        end)
      end),
    },
    pane
  )
end

-- ── Choosing updates ───────────────────────────────────────────────────────

---Checklist of the plugins with updates. Enter toggles one and reopens the
---list (InputSelector has no multi-select); the top row updates the ticked
---ones.
---@param window any
---@param pane any
---@param rows Jetpack.Status[] plugins with updates
---@param ticked table<string, boolean> by plugin id
function M.choose(window, pane, rows, ticked)
  local cfg = config.get().picker
  local selected = {}
  for _, row in ipairs(rows) do
    if ticked[row.id] then
      selected[#selected + 1] = row
    end
  end
  local choices = {}
  if #selected > 0 then
    choices[1] = {
      id = "go",
      label = action_label(cfg, "md_arrow_up_circle", ("Update selected (%d)"):format(#selected)),
    }
  end
  local wname, wver = 0, 0
  for _, row in ipairs(rows) do
    wname, wver = math.max(wname, width(row.name)), math.max(wver, width(M.version_text(row)))
  end
  for _, row in ipairs(rows) do
    local box = ticked[row.id] and glyph("md_checkbox_marked", "[x]", cfg)
      or glyph("md_checkbox_blank_outline", "[ ]", cfg)
    local items = icon_items(box, ticked[row.id] and ICON_COLORS.md_checkbox_marked or nil)
    extend(items, {
      { Attribute = { Intensity = "Bold" } },
      { Text = pad(row.name, wname) },
      "ResetAttributes",
      { Text = "  " .. pad(M.version_text(row), wver) },
    })
    choices[#choices + 1] = { id = "toggle:" .. row.id, label = format(items, row.name) }
  end
  choices[#choices + 1] =
    { id = "back", label = action_label(cfg, "md_arrow_left", "Back to plugins") }
  local wid = window:window_id()
  local session = start_session(window, pane, cfg)
  session.swallow = true
  view(window, "choose updates")
  window:perform_action(
    act.InputSelector {
      title = cfg.title .. ": choose updates",
      description = "Enter: tick or untick a plugin, then choose Update selected   Esc: close",
      fuzzy = false,
      choices = choices,
      action = wezterm.action_callback(function(w, p, id)
        view(w, nil)
        if sessions[wid] == session then
          close(w, p, session)
        end
        if not id then
          return
        elseif id == "back" then
          reopen(w, p)
        elseif id == "go" then
          local ids = {}
          for _, row in ipairs(selected) do
            ids[#ids + 1] = row.id
          end
          M.run(w, p, ("updating %d plugin%s"):format(#ids, #ids == 1 and "" or "s"), function()
            return ops.update(ids)
          end)
        else
          local pid = id:match "^toggle:(.+)$"
          if pid then
            ticked[pid] = not ticked[pid]
            later(function()
              M.choose(w, active(w, p), rows, ticked)
            end)
          end
        end
      end),
    },
    pane
  )
end

-- ── Health report ──────────────────────────────────────────────────────────

---Show `ops.doctor()`, one check per row, warnings first. Enter on a row
---copies the whole report.
---@param window any
---@param pane any
function M.doctor(window, pane)
  local cfg = config.get().picker
  local checks = ops.doctor()
  table.sort(checks, function(a, b)
    return (a.level == "warn" and 0 or 1) < (b.level == "warn" and 0 or 1)
  end)
  local warnings = 0
  local choices = {}
  local lines = {}
  for i, c in ipairs(checks) do
    if c.level == "warn" then
      warnings = warnings + 1
    end
    local name = c.level == "warn" and "md_alert"
      or c.level == "ok" and "md_check"
      or "md_information_outline"
    local fallback = c.level == "warn" and "!" or c.level == "ok" and "+" or "i"
    local items = icon_items(glyph(name, fallback, cfg), ICON_COLORS[name])
    items[#items + 1] = { Text = c.text }
    choices[#choices + 1] = { id = "check:" .. i, label = format(items, c.text) }
    lines[i] = (c.level == "warn" and "! " or "  ") .. c.text
  end
  choices[#choices + 1] =
    { id = "back", label = action_label(cfg, "md_arrow_left", "Back to plugins") }
  local wid = window:window_id()
  local session = start_session(window, pane, cfg)
  session.swallow = true
  view(window, "health report")
  window:perform_action(
    act.InputSelector {
      title = cfg.title .. ": health report",
      description = (warnings == 0 and "Nothing looks wrong" or ("%d warning%s"):format(
        warnings,
        warnings == 1 and "" or "s"
      )) .. "   |   Enter: copy the report   Esc: close",
      fuzzy = false,
      choices = choices,
      action = wezterm.action_callback(function(w, p, id)
        view(w, nil)
        if sessions[wid] == session then
          close(w, p, session)
        end
        if id == "back" then
          reopen(w, p)
        elseif id then
          try("copy", w.copy_to_clipboard, w, table.concat(lines, "\n"), "Clipboard")
          reopen(w, p, "Copied the health report")
        end
      end),
    },
    pane
  )
end

-- ── Unpinned plugins ───────────────────────────────────────────────────────

---The spec line that would pin `url`.
---@param url string
---@return string
function M.spec_line(url)
  local id = url:match "^https?://github%.com/([^/]+/[^/]+)$"
  if id then
    return ('{ "%s", version = "*" },'):format(id)
  end
  return ('{ url = "%s" },'):format(url)
end

---List the plugins that load without a spec entry, with the spec lines
---that would pin them (Enter copies; the top row copies all of them).
---@param window any
---@param pane any
---@param urls string[]
function M.unmanaged(window, pane, urls)
  local cfg = config.get().picker
  local specs = {
    {
      id = "copy_all",
      icon = "md_content_copy",
      text = "Copy spec lines for all",
      hint = "paste them into jetpack.setup's spec",
    },
  }
  for i, url in ipairs(urls) do
    specs[#specs + 1] = {
      id = "copy:" .. i,
      icon = "md_pin_off",
      text = url:match "[^/]+$" or url,
      hint = M.spec_line(url),
    }
  end
  specs[#specs + 1] = { id = "back", icon = "md_arrow_left", text = "Back to plugins" }
  local choices = aligned(cfg, specs)
  local wid = window:window_id()
  local session = start_session(window, pane, cfg)
  session.swallow = true
  view(window, "not pinned")
  window:perform_action(
    act.InputSelector {
      title = cfg.title .. ": not pinned",
      description = "These load at whatever version WezTerm cloned. Add them to the spec to pin them."
        .. "   |   Enter: copy   Esc: close",
      fuzzy = false,
      choices = choices,
      action = wezterm.action_callback(function(w, p, id)
        view(w, nil)
        if sessions[wid] == session then
          close(w, p, session)
        end
        if not id then
          return
        elseif id == "back" then
          return reopen(w, p)
        end
        local lines = {}
        if id == "copy_all" then
          for i, url in ipairs(urls) do
            lines[i] = M.spec_line(url)
          end
        else
          lines[1] = M.spec_line(urls[tonumber(id:match "^copy:(%d+)$")])
        end
        local text = table.concat(lines, "\n")
        try("copy", w.copy_to_clipboard, w, text, "Clipboard")
        reopen(w, p, ("Copied %d spec line%s"):format(#lines, #lines == 1 and "" or "s"))
      end),
    },
    pane
  )
end

-- ── Main list ──────────────────────────────────────────────────────────────

local function ids_of(rows)
  local out = {}
  for i, row in ipairs(rows) do
    out[i] = row.id
  end
  return out
end

---Run a row of the main list.
---@param action string|nil pending shortcut action, if a shortcut key chose the row
---@param window any
---@param pane any
---@param id string row id
---@param rows table<string, Jetpack.Status>
---@param g? table groups (from M.groups) for the bulk rows
function M.dispatch(action, window, pane, id, rows, g)
  g = g or { updates = {}, fix = {} }
  if action and not rows[id] then
    -- A shortcut acts on the highlighted plugin; on any other row only
    -- "check" means something (check them all).
    if action == "check" then
      id = "op:check"
    else
      return reopen(window, pane, "Highlight a plugin first, then press the shortcut.")
    end
  end
  if id == "op:update" then
    local n = #g.updates
    return M.run(window, pane, ("updating %d plugin%s"):format(n, n == 1 and "" or "s"), function()
      return ops.update(ids_of(g.updates))
    end)
  elseif id == "op:choose" then
    local ticked = {}
    for _, row in ipairs(g.updates) do
      ticked[row.id] = true
    end
    return M.choose(window, pane, g.updates, ticked)
  elseif id == "op:fix" then
    return M.run(window, pane, "fixing " .. names(g.fix, 3), function()
      return ops.sync(ids_of(g.fix))
    end)
  elseif id == "op:check" then
    return M.run(window, pane, "checking for updates", ops.check)
  elseif id == "op:doctor" then
    return M.doctor(window, pane)
  elseif id == "op:unmanaged" then
    return M.unmanaged(window, pane, g.unmanaged or state.unmanaged_urls())
  elseif id == "op:clean" then
    local paths = ops.orphans()
    local run = function(w, p)
      M.run(w, p, "removing unused clones", function()
        return ops.clean(paths)
      end)
    end
    if config.get().picker.confirm then
      local list = {}
      for i, path in ipairs(paths) do
        list[i] = path:match "[^/]+$"
      end
      local question = ("Delete %d unused clone(s): %s?"):format(#paths, table.concat(list, ", "))
      return confirm(window, pane, question, "Delete " .. #paths, run, function(w, p)
        reopen(w, p)
      end)
    end
    return run(window, pane)
  elseif id == "sep" then
    return reopen(window, pane)
  end

  local row = rows[id]
  if not row then
    return
  end
  if action then
    return M.perform(action, window, pane, row)
  end
  M.menu(window, pane, row)
end

---Choices for the main list: bulk rows that apply, then the plugins.
---@param status Jetpack.Status[]
---@param cfg table picker config
---@param orphans integer
---@return table[] choices
---@return table<string, Jetpack.Status> rows
---@return table groups
function M.choices(status, cfg, orphans)
  local g = M.groups(status)
  local specs, rows = {}, {}
  local function add(id, icon, text, hint)
    specs[#specs + 1] = { id = id, icon = icon, text = text, hint = hint }
  end
  local n = #g.updates
  if n == 1 then
    local row = g.updates[1]
    add("op:update", "md_arrow_up_circle", "Update " .. row.name, M.version_text(row))
  elseif n > 1 then
    add("op:update", "md_arrow_up_circle", ("Update all %d"):format(n), names(g.updates, 3))
    add("op:choose", "md_checkbox_multiple_marked_outline", "Choose which to update…")
  end
  if #g.fix > 0 then
    local f = #g.fix
    add("op:fix", "md_wrench", ("Fix %d plugin%s"):format(f, f == 1 and "" or "s"), fix_hint(g.fix))
  end
  if #g.unmanaged > 0 then
    local u = #g.unmanaged
    local short = {}
    for i, url in ipairs(g.unmanaged) do
      short[i] = { name = url:match "[^/]+$" or url }
    end
    add(
      "op:unmanaged",
      "md_pin_off",
      ("%d plugin%s %s not pinned"):format(u, u == 1 and "" or "s", u == 1 and "is" or "are"),
      names(short, 3)
    )
  end
  local ago = M.ago(g.checked)
  add(
    "op:check",
    "md_cloud_search",
    "Check for updates",
    ago and ("last checked " .. ago) or "never checked"
  )
  if orphans > 0 then
    add(
      "op:clean",
      "md_delete_sweep",
      ("Remove %d unused clone%s"):format(orphans, orphans == 1 and "" or "s")
    )
  end
  add(
    "op:doctor",
    "md_stethoscope",
    "Health report",
    "git, files, and where each plugin loads from"
  )
  local choices = aligned(cfg, specs)
  choices[#choices + 1] =
    { id = "sep", label = format({ DIM, { Text = "── plugins ──" } }, "-- plugins --") }

  local widths = { name = 0, version = 0 }
  for _, row in ipairs(g.sorted) do
    widths.name = math.max(widths.name, width(row.name))
    widths.version = math.max(widths.version, width(M.version_text(row)))
  end
  for _, row in ipairs(g.sorted) do
    local id = "plugin:" .. row.id
    rows[id] = row
    choices[#choices + 1] = { id = id, label = M.label(row, cfg, widths) }
  end
  return choices, rows, g
end

---Open the picker.
---@param window any
---@param pane any
---@param opts? { title?: string, notice?: string }
function M.open(window, pane, opts)
  opts = opts or {}
  local cfg = config.get().picker
  local wid = window:window_id()
  local session

  local ok = try("open picker", function()
    local status = ops.status()
    local choices, rows, groups = M.choices(status, cfg, #ops.orphans())

    local use_actions
    session, use_actions = start_session(window, pane, cfg)
    local bindings = { { key = "Enter", mods = "", desc = "choose" } }
    if use_actions then
      for _, b in ipairs(M.key_table(cfg)) do
        bindings[#bindings + 1] = b
      end
    end
    bindings[#bindings + 1] = { key = "Escape", mods = "", desc = "close" }

    local description = M.summary_line(status)
    if cfg.hints and cfg.hint_position ~= "none" then
      description = description .. "   |   Enter: choose   Esc: close"
    end
    if opts.notice then
      description = opts.notice .. "   |   " .. description
    end

    if adapter and use_actions and cfg.hints and cfg.hint_position == "status" then
      session.bindings = bindings
      local _, cleanup = try("adapter open", adapter.open, window, pane, session)
      session.cleanup = type(cleanup) == "function" and cleanup or nil
    end

    view(window, "plugin list")
    window:perform_action(
      act.InputSelector {
        title = opts.title or cfg.title,
        fuzzy = cfg.fuzzy,
        description = description,
        fuzzy_description = "Search: ",
        choices = choices,
        action = wezterm.action_callback(function(w, p, id)
          if sessions[wid] ~= session then
            return
          end
          view(w, nil)
          local action = session.pending
          close(w, p, session)
          if id then
            try("dispatch", M.dispatch, action, w, p, id, rows, groups)
          end
        end),
      },
      pane
    )
  end)
  if not ok and session then
    close(window, pane, session)
  end
end

return M
