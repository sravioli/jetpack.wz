---@module "jetpack.lock"
---@author sravioli
---@license GNU-GPLv2

---`jetpack-lock.json`: the commit each plugin is pinned to. Written with
---sorted keys, one plugin per line, so diffs stay small.

local wezterm = require "wezterm"

---@class Jetpack.LockEntry
---@field commit    string
---@field ref?      string tag or branch the commit was resolved from
---@field prev?     string commit before the last update (for undo)
---@field prev_ref? string

local M = {}

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
  local lock = {}
  for id, entry in pairs(data) do
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
    lines[i] = ("  %s: { %s }"):format(quote(id), table.concat(fields, ", "))
  end
  if #lines == 0 then
    return "{}\n"
  end
  return "{\n" .. table.concat(lines, ",\n") .. "\n}\n"
end

---Temporary sibling, then rename over `path`, so readers never see half a
---file. Windows cannot rename over an existing file, so it is removed first.
---@param path string
---@param contents string
---@return boolean ok
---@return string|nil err
local function atomic_write(path, contents)
  local tmp = ("%s.%d.tmp"):format(path, os.time())
  local f, err = io.open(tmp, "wb")
  if not f then
    return false, err
  end
  local wrote, werr = f:write(contents)
  f:close()
  if not wrote then
    os.remove(tmp)
    return false, werr
  end
  if not os.rename(tmp, path) then
    os.remove(path)
    local ok, rerr = os.rename(tmp, path)
    if not ok then
      return false, ("%s; the new lock is kept at %s"):format(tostring(rerr), tmp)
    end
  end
  return true
end

---@param path string
---@param lock table<string, Jetpack.LockEntry>
---@return boolean ok
---@return string|nil err
function M.write(path, lock)
  -- shortcut: no file lock; two WezTerm processes updating at once race
  -- (last write wins). Add one if that shows up in practice.
  cache[path] = nil
  local fs = require("jetpack.deps").warp.filesystem
  -- shortcut: warp 0.2.1 (latest release) has no write_file; drop the
  -- fallback once a warp release ships it and the warp spec requires it.
  if fs.write_file then
    return fs.write_file(path, M.encode(lock))
  end
  return atomic_write(path, M.encode(lock))
end

return M
