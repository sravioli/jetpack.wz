---@module "jetpack.lock"
---@author sravioli
---@license GNU-GPLv2

---`jetpack-lock.json`: the commit each plugin is pinned to. Written with
---sorted keys, one plugin per line, so diffs stay small.
---
---Format: `{ "version": 1, "plugins": { "<id>": { "commit": ... } } }`. A file
---with no `version` is the 0.x format (the `plugins` table on its own); it is
---read as is and rewritten in the current format on the next write.

local wezterm = require "wezterm"

---@class Jetpack.LockEntry
---@field commit    string
---@field ref?      string tag or branch the commit was resolved from
---@field prev?     string commit before the last update (for undo)
---@field prev_ref? string

local M = {}

---The format `write` produces, and the newest one `read` accepts.
M.VERSION = 1

---@param s string
---@return any
local function decode(s)
  local serde = wezterm.serde
  if serde and serde.json_decode then
    return serde.json_decode(s)
  end
  return wezterm.json_parse(s)
end

---Read the lockfile. A missing file is an empty lock; a corrupt one raises,
---so a later write never replaces it with less.
---@param path string
---@return table<string, Jetpack.LockEntry>
function M.read(path)
  local f = io.open(path, "r")
  if not f then
    return {}
  end
  local text = f:read "*a"
  f:close()
  if text:match "^%s*$" then
    return {}
  end
  local ok, data = pcall(decode, text)
  if not ok or type(data) ~= "table" then
    error(("%s is not valid JSON: %s"):format(path, tostring(data)), 0)
  end
  local plugins = data
  if data.version ~= nil then
    if type(data.version) ~= "number" or data.version > M.VERSION then
      error(
        ("%s has lockfile version %s; this jetpack reads up to %d. Update jetpack."):format(
          path,
          tostring(data.version),
          M.VERSION
        ),
        0
      )
    end
    plugins = type(data.plugins) == "table" and data.plugins or {}
  end
  local lock = {}
  for id, entry in pairs(plugins) do
    if type(entry) == "table" and type(entry.commit) == "string" then
      local function str(v)
        return type(v) == "string" and v or nil
      end
      lock[id] = {
        commit = entry.commit,
        ref = str(entry.ref),
        prev = str(entry.prev),
        prev_ref = str(entry.prev_ref),
      }
    end
  end
  return lock
end

local cache = {}

---`read`, once per Lua state and path (for the status bar, which renders
---every second). `write` refreshes it.
---@param path string
---@return table<string, Jetpack.LockEntry>
function M.cached(path)
  if not cache[path] then
    cache[path] = M.read(path)
  end
  return cache[path]
end

---@param s string
---@return string
local function quote(s)
  return '"'
    .. s:gsub('[%c"\\]', function(c)
      local map = { ['"'] = '\\"', ["\\"] = "\\\\", ["\n"] = "\\n", ["\t"] = "\\t" }
      return map[c] or ("\\u%04x"):format(c:byte())
    end)
    .. '"'
end

---@param lock table<string, Jetpack.LockEntry>
---@return string
function M.encode(lock)
  local ids = {}
  for id in pairs(lock) do
    ids[#ids + 1] = id
  end
  table.sort(ids)
  local lines = {}
  for i, id in ipairs(ids) do
    local e = lock[id]
    local fields = { '"commit": ' .. quote(e.commit) }
    for _, k in ipairs { "ref", "prev", "prev_ref" } do
      if e[k] then
        fields[#fields + 1] = ('"%s": %s'):format(k, quote(e[k]))
      end
    end
    lines[i] = ("    %s: { %s }"):format(quote(id), table.concat(fields, ", "))
  end
  local head = ('{\n  "version": %d,\n  "plugins": {'):format(M.VERSION)
  if #lines == 0 then
    return head .. "}\n}\n"
  end
  return head .. "\n" .. table.concat(lines, ",\n") .. "\n  }\n}\n"
end

---@param path string
---@param lock table<string, Jetpack.LockEntry>
---@return boolean ok
---@return string|nil err
function M.write(path, lock)
  cache[path] = nil
  return require("jetpack.deps").warp.filesystem.write_file(path, M.encode(lock))
end

return M
