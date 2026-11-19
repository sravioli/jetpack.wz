---@module "jetpack.auto"
---@author sravioli
---@license GNU-GPLv2

---Background update checks: on the first window event after the interval is
---due, wait `delay_seconds`, then run `check` without opening any view. The
---next due time lives in `<root>/.next-check`, so other WezTerm processes and
---restarts keep to the interval. It is set before the check runs, so a failing
---check is not retried every second.

local wezterm = require "wezterm"

local config = require "jetpack.config"

local M = {}

local scheduled = false
local cached_next -- read once per Lua state, then kept in step

local function stamp()
  return config.get().root .. "/.next-check"
end

---@return integer
function M.next_check()
  if cached_next == nil then
    local f = io.open(stamp(), "r")
    cached_next = f and tonumber(f:read "*a") or 0
    if f then
      f:close()
    end
  end
  return cached_next
end

---@param at integer
local function set_next(at)
  cached_next = at
  local f = io.open(stamp(), "w")
  if f then
    f:write(tostring(at))
    f:close()
  end
end

---`update-status` handler.
---@param window any
---@param pane any
function M.on_status(window, pane)
  local cfg = config.get().auto_check
  if not cfg.enabled or scheduled or os.time() < M.next_check() then
    return
  end
  scheduled = true
  wezterm.time.call_after(cfg.delay_seconds, function()
    scheduled = false
    cached_next = nil -- another process may have checked meanwhile
    local picker = require "jetpack.picker"
    if os.time() < M.next_check() or picker.busy() then
      return
    end
    set_next(os.time() + math.floor(math.max(cfg.interval_hours, 1) * 3600))
    picker.background(window, pane, "checking for updates", require("jetpack.ops").check)
  end)
end

local registered = false

---Register the handler once per Lua state.
function M.register()
  if not registered then
    registered = true
    wezterm.on("update-status", M.on_status)
  end
end

return M
