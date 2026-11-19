---@module "jetpack.state"
---@author sravioli
---@license GNU-GPLv2

---The specs from the last `setup`, and the results of the last `check`.
---Check results live in `wezterm.GLOBAL` (one key per plugin, plain fields),
---so they survive config reloads.

local wezterm = require "wezterm"

---@class Jetpack.Available
---@field commit string
---@field ref?   string
---@field at     integer unix time of the check

---@class Jetpack.State
---@field list    Jetpack.Spec[]
---@field by_id   table<string, Jetpack.Spec>
---@field by_url  table<string, Jetpack.Spec>
---@field own_dir string|nil checkout jetpack itself runs from; `clean` keeps it
local M = {
  list = {},
  by_id = {},
  by_url = {},
  _local = {},
  -- Plugins loaded through plugin.require that no spec lists, by URL key.
  unmanaged = {},
  unmanaged_order = {},
  -- Managed plugins that fell back to WezTerm's own copy this Lua state.
  fallbacks = {},
}

---Plugins loaded through `plugin.require` that no spec lists, in load order.
---@return string[] urls
function M.unmanaged_urls()
  local out = {}
  for _, key in ipairs(M.unmanaged_order) do
    if not M.by_url[key] then
      out[#out + 1] = M.unmanaged[key]
    end
  end
  return out
end

local function key(id)
  return "jetpack.available:" .. id
end

---@param id string
---@return Jetpack.Available|nil
function M.get_available(id)
  local v
  if wezterm.GLOBAL then
    v = wezterm.GLOBAL[key(id)]
  else
    v = M._local[id]
  end
  if v and v.commit then
    return { commit = v.commit, ref = v.ref, at = v.at }
  end
  return nil
end

---@param id string
---@param value Jetpack.Available|nil
function M.set_available(id, value)
  if wezterm.GLOBAL then
    wezterm.GLOBAL[key(id)] = value
  else
    M._local[id] = value
  end
end

-- ── Progress (read by the `jetpack.progress` mosaic module) ─────────────────

local PROGRESS = "jetpack.progress"

---Older progress is ignored: an operation whose Lua state was replaced by a
---reload never clears its line.
M.PROGRESS_TTL = 120

---True once a layout uses the `jetpack.progress` mosaic module; the picker
---then leaves mosaic's `notice` slot alone.
M.progress_module = false

---@param text string|nil nil clears it
function M.set_progress(text)
  local value = text and { text = text, at = os.time() } or nil
  if wezterm.GLOBAL then
    wezterm.GLOBAL[PROGRESS] = value
  else
    M._local_progress = value
  end
end

---@return string|nil
function M.get_progress()
  local v
  if wezterm.GLOBAL then
    v = wezterm.GLOBAL[PROGRESS]
  else
    v = M._local_progress
  end
  if v and v.text and os.time() - (v.at or 0) <= M.PROGRESS_TTL then
    return v.text
  end
  return nil
end

---Names of the plugins whose last `check` found a commit other than the
---locked one. No git: the lockfile (read once per Lua state) and GLOBAL.
---@return string[]
function M.pending_updates()
  local lock = require "jetpack.lock"
  local ok, locks = pcall(lock.cached, require("jetpack.config").get().lockfile)
  if not ok then
    return {}
  end
  local out = {}
  for _, s in ipairs(M.list) do
    if not s.local_dir then
      local available = M.get_available(s.id)
      local locked = locks[s.id]
      if available and (not locked or locked.commit ~= available.commit) then
        out[#out + 1] = s.name
      end
    end
  end
  return out
end

-- ── Views (read by the `jetpack.status` mosaic module) ─────────────────────

-- Per window: the jetpack view open in it. Plain Lua state: a reload clears it,
-- and every view sets it again when it opens.
local views = {}

---@param window_id integer
---@param text string|nil nil when no jetpack view is open
function M.set_view(window_id, text)
  views[window_id] = text
end

---@param window_id integer|nil
---@return string|nil
function M.get_view(window_id)
  return window_id and views[window_id] or nil
end

---@class Jetpack.Summary
---@field total    integer managed plugins
---@field missing  integer git plugins without a clone
---@field unlocked integer git plugins not in the lockfile
---@field local_count integer `dir` specs

---Counts for the `jetpack.status` module. No git: a file check per plugin and
---the lockfile (read once per Lua state).
---@return Jetpack.Summary
function M.summary()
  local ok, locks = pcall(require("jetpack.lock").cached, require("jetpack.config").get().lockfile)
  locks = ok and locks or {}
  local exists = require("jetpack.hook").exists
  local out = { total = #M.list, missing = 0, unlocked = 0, local_count = 0 }
  for _, s in ipairs(M.list) do
    if s.local_dir then
      out.local_count = out.local_count + 1
    elseif not exists(s.path) then
      out.missing = out.missing + 1
    elseif not locks[s.id] then
      out.unlocked = out.unlocked + 1
    end
  end
  return out
end

return M
