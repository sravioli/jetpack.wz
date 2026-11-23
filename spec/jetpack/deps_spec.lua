local wezterm = require "wezterm"

describe("jetpack.deps", function()
  local saved = {}

  before_each(function()
    wezterm._reset()
    for _, name in ipairs { "jetpack.deps", "warp.api", "warden.api" } do
      saved[name] = package.loaded[name]
      package.loaded[name] = nil
    end
  end)

  after_each(function()
    for name, mod in pairs(saved) do
      package.loaded[name] = mod
    end
    package.preload["warp.api"] = nil
  end)

  it("uses a module that is already on package.path", function()
    local deps = require "jetpack.deps"
    assert.is_table(deps.warp.filesystem)
  end)

  it("loads warden only when first asked, then keeps it", function()
    local deps = require "jetpack.deps"
    assert.is_nil(rawget(deps, "warden"))
    local warden = deps.warden
    assert.is_table(warden)
    assert.equal(warden, rawget(deps, "warden"))
  end)

  it("falls back to wezterm.plugin.require and names the plugin when that fails", function()
    package.preload["warp.api"] = function()
      error "not on the path"
    end
    local asked
    wezterm.plugin.require = function(url)
      asked = url
      error "offline"
    end
    local ok, err = pcall(require, "jetpack.deps")
    assert.is_false(ok)
    assert.equal("https://github.com/sravioli/warp.wz", asked)
    assert.matches("unable to load dependency warp: .*offline", err)
  end)

  it("takes WezTerm's copy past jetpack's hook so the first install can bootstrap", function()
    package.preload["warp.api"] = function()
      error "not on the path"
    end
    local hooked = false
    wezterm.plugin.__jetpack = {
      require = function()
        return { filesystem = "from wezterm" }
      end,
    }
    wezterm.plugin.require = function()
      hooked = true
      return {}
    end
    local deps = require "jetpack.deps"
    assert.equal("from wezterm", deps.warp.filesystem)
    assert.is_false(hooked)
  end)
end)
