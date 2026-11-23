-- One process of the lock test: take the lock, log "in", hold it, log "out".
-- Usage: lua spec/support/lock_worker.lua <root> <log> <warp dir> <warden dir>
-- Prints "ran" or the refusal message.
local root, log, warp, warden = arg[1], arg[2], arg[3], arg[4]
dofile "spec/mocks/wezterm.lua"
local wezterm = require "wezterm"
wezterm._child = wezterm._real_child

local jetpack = require "jetpack.api"
jetpack.setup {
  root = root,
  lockfile = root .. "/../jetpack-lock.json",
  validate = false,
  spec = { { "sravioli/warp.wz", dir = warp }, { "sravioli/warden.wz", dir = warden } },
}

local function note(what)
  local f = assert(io.open(log, "a"))
  f:write(what, "\n")
  f:close()
end

local report = require("jetpack.ops").locked(function()
  note "in"
  os.execute "sleep 0.6"
  note "out"
  return {}
end)()
print(report[1] and report[1].detail or "ran")
