local wezterm = require "wezterm"

describe("jetpack.hook", function()
  local hook, state, spec, tmp, managed

  before_each(function()
    wezterm._reset()
    for name in pairs(package.loaded) do
      if name:match "^jetpack" then
        package.loaded[name] = nil
      end
    end
    hook, state, spec = require "jetpack.hook", require "jetpack.state", require "jetpack.spec"
    tmp = os.tmpname()
    os.remove(tmp)
    os.execute(("mkdir -p '%s/clone/plugin'"):format(tmp))
    local f = io.open(tmp .. "/clone/plugin/init.lua", "w")
    f:write "local name, file = ...\nLOADS = (LOADS or 0) + 1\nreturn { component = name, file = file }\n"
    f:close()
    managed = spec.normalize({ "owner/demo.wz", dir = tmp .. "/clone" }, tmp)
    state.list = { managed }
    state.by_url = { [spec.url_key(managed.url)] = managed }
    _G.LOADS = 0
    wezterm._plugins =
      { { url = "https://github.com/x/other.wz", component = "c", plugin_dir = "/p" } }
  end)

  after_each(function()
    os.execute(("rm -rf '%s'"):format(tmp))
  end)

  it("loads managed URLs once, with the component name", function()
    hook.install()
    local mod = wezterm.plugin.require "https://github.com/owner/demo.wz.git"
    assert.equal("jetpack.owner/demo.wz", mod.component)
    assert.equal(tmp .. "/clone/plugin/init.lua", mod.file)
    assert.equal(mod, wezterm.plugin.require "https://github.com/OWNER/demo.wz")
    assert.equal(1, _G.LOADS)
  end)

  it("passes other URLs to the original require", function()
    hook.install()
    assert.has_error(function()
      wezterm.plugin.require "https://github.com/x/other.wz"
    end, "plugin.require disabled in specs: https://github.com/x/other.wz")
  end)

  it("lists managed plugins first, replacing WezTerm's clone of the same URL", function()
    wezterm._plugins[#wezterm._plugins + 1] =
      { url = "https://github.com/owner/demo.wz", component = "unpinned", plugin_dir = "/old" }
    hook.install()
    local list = wezterm.plugin.list()
    assert.equal(2, #list)
    assert.same(
      { url = managed.url, component = managed.component, plugin_dir = managed.path },
      list[1]
    )
    assert.equal("c", list[2].component)
  end)

  it("remembers plugins that load unpinned because no spec lists them", function()
    hook.install()
    for _ = 1, 2 do
      pcall(wezterm.plugin.require, "https://github.com/x/other.wz.git")
    end
    assert.same({ "https://github.com/x/other.wz" }, state.unmanaged_urls())
    local warned = 0
    for _, c in ipairs(wezterm._calls) do
      if c.fn == "log_warn" and c.args[1]:match "other.wz is not in the spec" then
        warned = warned + 1
      end
    end
    assert.equal(1, warned)
  end)

  it("falls back to WezTerm's copy of a missing clone, or refuses with strict", function()
    os.execute(("rm -rf '%s/clone'"):format(tmp))
    local fell_back
    wezterm.plugin.require = function(url)
      fell_back = url
      return { unpinned = true }
    end
    hook.install()
    assert.same({ unpinned = true }, wezterm.plugin.require "https://github.com/owner/demo.wz")
    assert.equal("https://github.com/owner/demo.wz", fell_back)
    assert.is_true(state.fallbacks["owner/demo.wz"])

    require("jetpack.config").parse { strict = true }
    assert.has_error(function()
      wezterm.plugin.require "https://github.com/owner/demo.wz"
    end, "[jetpack] owner/demo.wz is not installed and `strict` is on; run Sync or fix the spec")
  end)

  it("keeps WezTerm's entry while the pinned clone does not exist yet", function()
    -- First install: the plugin falls back to WezTerm's copy, whose bootstrap
    -- looks itself up in plugin.list().
    os.execute(("rm -rf '%s/clone'"):format(tmp))
    wezterm._plugins[#wezterm._plugins + 1] =
      { url = "https://github.com/owner/demo.wz", component = "wezterms", plugin_dir = "/old" }
    hook.install()
    local list = wezterm.plugin.list()
    assert.equal(2, #list)
    assert.equal("wezterms", list[2].component)
  end)

  it("wraps only once", function()
    hook.install()
    local wrapped = wezterm.plugin.require
    hook.install()
    assert.equal(wrapped, wezterm.plugin.require)
  end)

  it("prepends plugin/ to package.path once", function()
    local before = package.path
    hook.add_path(tmp .. "/clone")
    hook.add_path(tmp .. "/clone")
    assert.equal(
      tmp .. "/clone/plugin/?.lua;" .. tmp .. "/clone/plugin/?/init.lua;" .. before,
      package.path
    )
    package.path = before
  end)
end)
