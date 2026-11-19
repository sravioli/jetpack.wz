local wezterm = require "wezterm"

describe("jetpack.auto", function()
  local auto, config, ops, root, checks

  before_each(function()
    wezterm._reset()
    for name in pairs(package.loaded) do
      if name:match "^jetpack" then
        package.loaded[name] = nil
      end
    end
    root = os.tmpname()
    os.remove(root)
    os.execute(("mkdir -p '%s'"):format(root))
    config = require "jetpack.config"
    config.parse { root = root, lockfile = root .. "/jetpack-lock.json" }
    ops = require "jetpack.ops"
    checks = 0
    ops.check = function()
      checks = checks + 1
      return {}
    end
    auto = require "jetpack.auto"
  end)

  after_each(function()
    os.execute(("rm -rf '%s'"):format(root))
  end)

  local window = {
    window_id = function()
      return 1
    end,
  }

  it("checks once after the delay, then waits for the interval", function()
    auto.on_status(window, {})
    auto.on_status(window, {})
    assert.equal(1, #wezterm._timers)
    assert.equal(10, wezterm._timers[1].secs)
    assert.equal(0, checks)
    wezterm._run_timers()
    assert.equal(1, checks)
    local due = auto.next_check()
    assert.is_true(math.abs(due - (os.time() + 24 * 3600)) <= 1)
    -- Saved for other processes and restarts.
    local f = io.open(root .. "/.next-check")
    assert.equal(tostring(due), f:read "*a")
    f:close()
    auto.on_status(window, {})
    assert.equal(0, #wezterm._timers)
  end)

  it("skips a check another process already made", function()
    auto.on_status(window, {})
    local f = io.open(root .. "/.next-check", "w")
    f:write(tostring(os.time() + 3600))
    f:close()
    wezterm._run_timers()
    assert.equal(0, checks)
  end)

  it("does nothing when disabled", function()
    config.parse { root = root, auto_check = false }
    auto.on_status(window, {})
    assert.equal(0, #wezterm._timers)
  end)
end)
