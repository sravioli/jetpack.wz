local wezterm = require "wezterm"

describe("jetpack mosaic integrations", function()
  local state, lock, config, root

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
    state, lock = require "jetpack.state", require "jetpack.lock"
    local spec = require "jetpack.spec"
    state.list = {
      spec.normalize("a/one.wz", root),
      spec.normalize("a/two.wz", root),
      spec.normalize({ "a/dev.wz", dir = root }, root),
    }
    lock.write(config.get().lockfile, {
      ["a/one.wz"] = { commit = "111", ref = "1.0.0" },
      ["a/two.wz"] = { commit = "222", ref = "2.0.0" },
    })
  end)

  after_each(function()
    os.execute(("rm -rf '%s'"):format(root))
  end)

  local function build(name, opts)
    local descriptor = require("jetpack.mosaic." .. name)
    assert.equal(1, descriptor.api)
    assert.same({ "jetpack.progress" }, descriptor.events)
    return descriptor.new(opts or {})
  end

  it("jetpack.updates is hidden until a check finds something newer", function()
    local updates = build "updates"
    assert.same({ enabled = false }, updates())
    state.set_available("a/one.wz", { commit = "111", ref = "1.0.0", at = 1 })
    assert.same({ enabled = false }, updates())
    state.set_available("a/two.wz", { commit = "333", ref = "2.1.0", at = 1 })
    local out = updates()
    assert.is_true(out.enabled)
    assert.equal("1", out.text.value)
    assert.equal("*", out.icon.value)
    assert.equal("two.wz", build("updates", { names = true, icon = false })().text.value)
  end)

  it("jetpack.updates follows lockfile writes from this config", function()
    local updates = build "updates"
    state.set_available("a/two.wz", { commit = "333", ref = "2.1.0", at = 1 })
    assert.equal("1", updates().text.value)
    lock.write(config.get().lockfile, {
      ["a/one.wz"] = { commit = "111" },
      ["a/two.wz"] = { commit = "333" },
    })
    assert.same({ enabled = false }, updates())
  end)

  it("jetpack.progress shows the running operation without the prefix", function()
    local progress = build "progress"
    assert.is_true(state.progress_module)
    assert.same({ enabled = false }, progress())
    state.set_progress "jetpack: checking one.wz 1/2"
    assert.equal("checking one.wz 1/2", progress().text.value)
    assert.equal("jetpack: checking one.wz 1/2", build("progress", { prefix = true })().text.value)
    state.set_progress(nil)
    assert.same({ enabled = false }, progress())
  end)

  it("jetpack.progress ignores a stale line left by a replaced Lua state", function()
    local progress = build "progress"
    wezterm.GLOBAL["jetpack.progress"] = { text = "jetpack: updating x 1/9", at = os.time() - 500 }
    assert.same({ enabled = false }, progress())
  end)

  local function win(id)
    return {
      window_id = function()
        return id
      end,
    }
  end

  it("jetpack.status shows the view open in that window", function()
    local status = build "status"
    for _, name in ipairs { "a__one.wz", "a__two.wz" } do
      os.execute(
        ("mkdir -p '%s/%s/plugin' && touch '%s/%s/plugin/init.lua'"):format(root, name, root, name)
      )
    end
    assert.same({ enabled = false }, status(win(1)))
    state.set_view(1, "plugin list")
    assert.equal("plugin list", status(win(1)).text.value)
    assert.is_nil(status(win(1)).tint)
    -- Another window has no view open.
    assert.same({ enabled = false }, status(win(2)))
    state.set_view(1, nil)
    assert.same({ enabled = false }, status(win(1)))
  end)

  it("jetpack.status flags missing or unlocked plugins when no view is open", function()
    local status = build "status"
    -- Neither clone exists in the temp root; both are locked.
    local out = status(win(1))
    assert.equal("2 missing", out.text.value)
    assert.equal(4, out.tint)
    for _, name in ipairs { "a__one.wz", "a__two.wz" } do
      os.execute(
        ("mkdir -p '%s/%s/plugin' && touch '%s/%s/plugin/init.lua'"):format(root, name, root, name)
      )
    end
    lock.write(config.get().lockfile, { ["a/one.wz"] = { commit = "111" } })
    assert.equal("1 unlocked", status(win(1)).text.value)
    -- A view wins over the warning.
    state.set_view(1, "beacon.wz")
    assert.equal("beacon.wz", status(win(1)).text.value)
    assert.is_nil(status(win(1)).tint)
  end)

  it("routes auto progress to the module instead of the notice slot", function()
    build "progress"
    package.loaded["mosaic.api"] = {}
    local picker = require "jetpack.picker"
    local seen = {}
    local w = {
      toast_notification = function() end,
      window_id = function()
        return 1
      end,
      perform_action = function() end,
    }
    picker.run(w, {}, "checking", function()
      require("jetpack.ops").on_progress(1, 1, "one.wz", "checking")
      seen[#seen + 1] = state.get_progress()
      return {}
    end)
    package.loaded["mosaic.api"] = nil
    assert.same({ "jetpack: checking one.wz 1/1" }, seen)
    assert.is_nil(state.get_progress())
    local events = {}
    for _, e in ipairs(wezterm._emitted) do
      events[#events + 1] = e.name
    end
    assert.is_nil(table.concat(events, ","):find("mosaic-notify", 1, true))
    assert.truthy(table.concat(events, ","):find("jetpack.progress", 1, true))
  end)
end)
