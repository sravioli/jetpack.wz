---@module "jetpack.semver"
---@author sravioli
---@license GNU-GPLv2

---Semantic versions and the ranges a spec's `version` accepts.
---
---Ranges: `*` (any release), `^1.2.3`/`^1`, `~1.2.3`/`~1.2`, `>=1.2.3`, an
---exact `1.2.3`, or a partial `1.2` (any 1.2.x). A leading `v` is ignored.
---Prereleases match only an exact range. Build metadata is ignored.

---@class Jetpack.Version
---@field major integer
---@field minor integer
---@field patch integer
---@field pre?  string

---@class Jetpack.Range
---@field min?   Jetpack.Version  Inclusive lower bound.
---@field max?   Jetpack.Version  Exclusive upper bound.
---@field exact? Jetpack.Version

local M = {}

---@param s any
---@return Jetpack.Version|nil
function M.parse(s)
  if type(s) ~= "string" then
    return nil
  end
  local major, minor, patch, rest = s:match "^v?(%d+)%.(%d+)%.(%d+)(.*)$"
  if not major then
    return nil
  end
  rest = rest:gsub("%+.*$", "")
  local pre
  if rest ~= "" then
    pre = rest:match "^%-([%w%.%-]+)$"
    if not pre then
      return nil
    end
  end
  return { major = tonumber(major), minor = tonumber(minor), patch = tonumber(patch), pre = pre }
end

---Compare prerelease identifiers per semver §11.
local function compare_pre(a, b)
  if a == b then
    return 0
  elseif not a then
    return 1
  elseif not b then
    return -1
  end
  local ia, ib = {}, {}
  for p in a:gmatch "[^%.]+" do
    ia[#ia + 1] = p
  end
  for p in b:gmatch "[^%.]+" do
    ib[#ib + 1] = p
  end
  for i = 1, math.max(#ia, #ib) do
    local x, y = ia[i], ib[i]
    if not x then
      return -1
    elseif not y then
      return 1
    end
    local nx, ny = tonumber(x), tonumber(y)
    if nx and ny then
      if nx ~= ny then
        return nx < ny and -1 or 1
      end
    elseif nx then
      return -1
    elseif ny then
      return 1
    elseif x ~= y then
      return x < y and -1 or 1
    end
  end
  return 0
end

---@param a Jetpack.Version
---@param b Jetpack.Version
---@return integer -1, 0 or 1
function M.compare(a, b)
  for _, k in ipairs { "major", "minor", "patch" } do
    if a[k] ~= b[k] then
      return a[k] < b[k] and -1 or 1
    end
  end
  return compare_pre(a.pre, b.pre)
end

local function v(major, minor, patch)
  return { major = major, minor = minor, patch = patch }
end

---Parse a range. Returns nil for anything it does not understand.
---@param s any
---@return Jetpack.Range|nil
function M.range(s)
  if type(s) ~= "string" then
    return nil
  end
  s = s:gsub("^%s+", ""):gsub("%s+$", "")
  if s == "*" then
    return {}
  end
  local exact = M.parse(s)
  if exact then
    return { exact = exact }
  end

  local op, body = s:match "^([%^~]?>?=?)v?(.*)$"
  local a, b, c = body:match "^(%d+)%.?(%d*)%.?(%d*)$"
  if not a then
    return nil
  end
  local major, minor, patch = tonumber(a), tonumber(b), tonumber(c)
  local min = v(major, minor or 0, patch or 0)

  if op == ">=" then
    return { min = min }
  elseif op == "^" then
    if major > 0 or not minor then
      return { min = min, max = v(major + 1, 0, 0) }
    elseif minor > 0 or not patch then
      return { min = min, max = v(0, minor + 1, 0) }
    end
    return { min = min, max = v(0, 0, patch + 1) }
  elseif op == "~" or op == "" then
    if minor then
      return { min = min, max = v(major, minor + 1, 0) }
    end
    return { min = min, max = v(major + 1, 0, 0) }
  end
  return nil
end

---@param range Jetpack.Range
---@param version Jetpack.Version
---@return boolean
function M.matches(range, version)
  if range.exact then
    return M.compare(range.exact, version) == 0
  end
  if version.pre then
    return false
  end
  if range.min and M.compare(version, range.min) < 0 then
    return false
  end
  if range.max and M.compare(version, range.max) >= 0 then
    return false
  end
  return true
end

---Highest tag in `tags` that `range` accepts.
---@param range Jetpack.Range
---@param tags string[]
---@return string|nil tag
function M.best(range, tags)
  local best, best_v
  for _, tag in ipairs(tags) do
    local version = M.parse(tag)
    if version and M.matches(range, version) then
      if not best_v or M.compare(version, best_v) > 0 then
        best, best_v = tag, version
      end
    end
  end
  return best
end

return M
