local wezterm = require "wezterm"

describe("jetpack.config validation (warden)", function()
  local config

  before_each(function()
    wezterm._reset()
    for name in pairs(package.loaded) do
      if name:match "^jetpack" then
        package.loaded[name] = nil
      end
    end
    config = require "jetpack.config"
  end)

  local function warnings()
    local out = {}
    for _, c in ipairs(wezterm._calls) do
      if c.fn == "log_warn" then
        out[#out + 1] = c.args[1]
      end
    end
    return out
  end

  it("warns about a misspelt spec field instead of ignoring it", function()
    config.validate { spec = { "a/b", { "c/d", verison = "^1" } } }
    local w = warnings()
    assert.equal(1, #w)
    assert.matches("spec%[2%] %(c/d%): verison", w[1])
  end)

  it("warns about unknown options, at any depth", function()
    config.validate { roots = "/x", picker = { titel = "x", keys = { updte = { key = "u" } } } }
    local all = table.concat(warnings(), "\n")
    assert.matches("roots", all)
    assert.matches("titel", all)
    assert.matches("updte", all)
  end)

  it("raises on a wrong type or value", function()
    assert.has_error(function()
      config.validate { picker = { progress = "sideways" } }
    end)
    assert.has_error(function()
      config.validate { spec = { { "a/b", tag = 3 } } }
    end)
    assert.has_error(function()
      config.validate { auto_check = { interval_hours = 0 } }
    end)
  end)

  it("accepts a full, valid configuration", function()
    config.validate {
      spec = { "a/b", { "c/d", version = "^1", name = "d" }, { url = "https://x/y" } },
      root = "/r",
      strict = true,
      auto_check = false,
      picker = {
        progress = "mosaic",
        keys = { copy = false, update = { key = "u", mods = "CTRL" } },
      },
    }
    assert.same({}, warnings())
  end)

  it("skips validation, with a warning, when warden cannot load", function()
    package.loaded["jetpack.deps"] = setmetatable({}, {
      __index = function()
        error "unable to load dependency warden"
      end,
    })
    config.validate { picker = { progress = "sideways" } }
    local w = warnings()
    assert.equal(1, #w)
    assert.matches("^%[jetpack%] validation skipped: warden.wz is unavailable", w[1])
    package.loaded["jetpack.deps"] = nil
  end)

  it("parses strict, validate and auto_check", function()
    local cfg =
      config.parse { strict = true, validate = false, auto_check = { interval_hours = 6 } }
    assert.is_true(cfg.strict)
    assert.is_false(cfg.validate)
    assert.same({ enabled = true, interval_hours = 6, delay_seconds = 10 }, cfg.auto_check)
    assert.is_false(config.parse({ auto_check = false }).auto_check.enabled)
  end)
end)
