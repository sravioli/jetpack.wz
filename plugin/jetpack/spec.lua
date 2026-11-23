---@module "jetpack.spec"
---@author sravioli
---@license GNU-GPLv2

---Normalize plugin specs. Pure Lua with no warp: setup runs this before warp
---is loaded, so warp itself can come from its pinned clone.

local wezterm = require "wezterm"

local semver = require "jetpack.semver"

---@class Jetpack.SpecInput
---@field [1]      string?  `owner/repo` (GitHub) or a full git URL.
---@field url?     string   Same as `[1]`.
---@field name?    string   Display name. Defaults to the repository name.
---@field version? string   Semver range over tags (see jetpack.semver).
---@field tag?     string
---@field commit?  string
---@field branch?  string
---@field dir?     string   Local checkout: loaded as-is, never touched by git.
---@field enabled? boolean|fun():boolean  False, or a function that says no, drops the entry.
---@field opts?    table    Passed to the plugin's `apply_to_config(config, opts)`.
---@field config?  fun(plugin: any, config: table, opts: table|nil)  Runs instead of `apply_to_config`.

---@class Jetpack.Spec
---@field id        string  Lockfile key: `owner/repo` on GitHub, else the URL without scheme.
---@field url       string  Normalized URL (no trailing `/` or `.git`).
---@field name      string
---@field path      string  Directory the plugin is loaded from.
---@field component string  Module name it is loaded under.
---@field local_dir boolean True for `dir` specs.
---@field version?  string
---@field range?    Jetpack.Range
---@field tag?      string
---@field commit?   string
---@field branch?   string
---@field opts?     table
---@field config?   function

local M = {}

local GITHUB = "^[%w%-%._]+/[%w%-%._]+$"

---Strip a trailing slash and `.git`; compare URLs case-insensitively.
---@param url string
---@return string
function M.normalize_url(url)
  url = tostring(url):gsub("/+$", ""):gsub("%.git$", "")
  return url
end

---@param url string
---@return string
function M.url_key(url)
  return M.normalize_url(url):lower()
end

---@param p string
---@return string
local function expand(p)
  if p:sub(1, 1) == "~" then
    local home = wezterm.home_dir or os.getenv "HOME" or os.getenv "USERPROFILE" or ""
    p = home .. p:sub(2)
  end
  return (p:gsub("\\", "/"):gsub("/+$", ""))
end
M.expand = expand

---@param id string
---@return string
local function dir_name(id)
  return (id:gsub("/", "__"):gsub("[^%w%._%-]", "_"))
end

---@param entry string|Jetpack.SpecInput
---@param root string clone root
---@return Jetpack.Spec
function M.normalize(entry, root)
  if type(entry) == "string" then
    entry = { entry }
  end
  if type(entry) ~= "table" then
    error(("spec must be a string or a table, got %s"):format(type(entry)), 0)
  end
  local source = entry[1] or entry.url
  if type(source) ~= "string" or source == "" then
    error("spec needs `owner/repo` or `url`", 0)
  end
  if entry.opts ~= nil and type(entry.opts) ~= "table" then
    error(("%s: `opts` must be a table"):format(source), 0)
  end
  if entry.config ~= nil and type(entry.config) ~= "function" then
    error(("%s: `config` must be a function"):format(source), 0)
  end
  for _, k in ipairs { "name", "version", "tag", "commit", "branch", "dir" } do
    if entry[k] ~= nil and (type(entry[k]) ~= "string" or entry[k] == "") then
      error(("%s: `%s` must be a non-empty string"):format(source, k), 0)
    end
  end

  local url, id
  if source:match(GITHUB) then
    id = source:gsub("%.git$", "")
    url = "https://github.com/" .. id
  else
    url = M.normalize_url(source)
    id = url:match "^https?://github%.com/([^/]+/[^/]+)$" or url:gsub("^%a[%w+.-]*://", "")
  end

  local range
  if entry.version then
    range = semver.range(entry.version)
    if not range then
      error(("%s: invalid version range %q"):format(id, entry.version), 0)
    end
  end

  local local_dir = entry.dir ~= nil
  return {
    id = id,
    url = url,
    name = entry.name or (id:match "[^/]+$" or id),
    path = local_dir and expand(entry.dir) or (root .. "/" .. dir_name(id)),
    component = "jetpack." .. id,
    local_dir = local_dir,
    version = entry.version,
    range = range,
    tag = entry.tag,
    commit = entry.commit,
    branch = entry.branch,
    opts = entry.opts,
    config = entry.config,
  }
end

---Whether an entry takes part: `enabled` is not false, and a function it is
---gives a truthy answer.
---@param entry string|Jetpack.SpecInput
---@return boolean
local function enabled(entry)
  if type(entry) ~= "table" or entry.enabled == nil then
    return true
  end
  local e = entry.enabled
  if type(e) == "function" then
    return e() and true or false
  elseif type(e) ~= "boolean" then
    error(
      ("%s: `enabled` must be a boolean or a function"):format(tostring(entry[1] or entry.url)),
      0
    )
  end
  return e
end

---Normalize a list of specs, rejecting duplicates. Disabled entries are
---dropped first, so two entries for one plugin can pick by `enabled`.
---@param entries (string|Jetpack.SpecInput)[]
---@param root string
---@return Jetpack.Spec[] list
---@return table<string, Jetpack.Spec> by_id
---@return table<string, Jetpack.Spec> by_url keyed by `url_key`
function M.list(entries, root)
  if type(entries) ~= "table" then
    error("`spec` must be a list", 0)
  end
  local list, by_id, by_url = {}, {}, {}
  for _, entry in ipairs(entries) do
    if enabled(entry) then
      local s = M.normalize(entry, root)
      if by_id[s.id] then
        error(("duplicate spec: %s"):format(s.id), 0)
      end
      list[#list + 1] = s
      by_id[s.id] = s
      by_url[M.url_key(s.url)] = s
    end
  end
  return list, by_id, by_url
end

---What a spec resolves against, in priority order.
---@param s Jetpack.Spec
---@return "commit"|"tag"|"version"|"branch"|"default"
function M.kind(s)
  if s.commit then
    return "commit"
  elseif s.tag then
    return "tag"
  elseif s.range then
    return "version"
  elseif s.branch then
    return "branch"
  end
  return "default"
end

return M
