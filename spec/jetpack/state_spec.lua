local wezterm = require "wezterm"

describe("jetpack.state", function()
  local state, lock, tmp

  local function fresh()
    wezterm._reset()
    for name in pairs(package.loaded) do
      if name:match "^jetpack" then
        package.loaded[name] = nil
      end
    end
    state, lock = require "jetpack.state", require "jetpack.lock"
  end

  local function plugins(...)
    local spec = require "jetpack.spec"
    local list, by_id, by_url = spec.list({ ... }, "/root")
    state.list, state.by_id, state.by_url = list, by_id, by_url
  end

  before_each(function()
    fresh()
    tmp = os.tmpname()
    require("jetpack.config").parse { lockfile = tmp }
  end)

  after_each(function()
    os.remove(tmp)
  end)

  it("keeps the last check per plugin in wezterm.GLOBAL", function()
    assert.is_nil(state.get_available "a/b")
    state.set_available("a/b", { commit = "abc", ref = "1.0.0", at = 5, junk = 1 })
    assert.same({ commit = "abc", ref = "1.0.0", at = 5 }, state.get_available "a/b")
    assert.is_not_nil(wezterm.GLOBAL["jetpack.available:a/b"])
    state.set_available("a/b", nil)
    assert.is_nil(state.get_available "a/b")
  end)

  it("keeps the check in a local table when there is no wezterm.GLOBAL", function()
    local saved = wezterm.GLOBAL
    wezterm.GLOBAL = nil
    state.set_available("a/b", { commit = "abc", at = 1 })
    assert.equal("abc", state.get_available("a/b").commit)
    state.set_progress "working"
    assert.equal("working", state.get_progress())
    wezterm.GLOBAL = saved
  end)

  it("expires progress after the TTL and clears it with nil", function()
    assert.is_nil(state.get_progress())
    state.set_progress "checking a 1/2"
    assert.equal("checking a 1/2", state.get_progress())
    state.set_progress(nil)
    assert.is_nil(state.get_progress())
    wezterm.GLOBAL["jetpack.progress"] = { text = "old", at = os.time() - state.PROGRESS_TTL - 5 }
    assert.is_nil(state.get_progress())
  end)

  it("lists plugins that loaded without a spec, minus the ones a spec now names", function()
    plugins "a/b"
    for _, url in ipairs {
      "https://github.com/x/y",
      "https://github.com/a/b",
      "https://github.com/p/q",
    } do
      require("jetpack.hook").note_unmanaged(url)
    end
    assert.same({ "https://github.com/x/y", "https://github.com/p/q" }, state.unmanaged_urls())
  end)

  describe("pending_updates", function()
    it("names plugins whose checked commit differs from the locked one", function()
      plugins("a/one", "a/two", "a/three", "a/four")
      lock.write(tmp, {
        ["a/one"] = { commit = "111" },
        ["a/two"] = { commit = "222" },
        ["a/three"] = { commit = "333" },
      })
      state.set_available("a/one", { commit = "111", at = 1 }) -- same: no update
      state.set_available("a/two", { commit = "999", at = 1 }) -- newer
      state.set_available("a/four", { commit = "444", at = 1 }) -- not locked yet
      assert.same({ "two", "four" }, state.pending_updates())
    end)

    it("ignores local checkouts", function()
      plugins { "a/loc", dir = "/somewhere" }
      state.set_available("a/loc", { commit = "999", at = 1 })
      assert.same({}, state.pending_updates())
    end)

    it("reports nothing when the lockfile cannot be read", function()
      local f = io.open(tmp, "w")
      f:write "{ broken"
      f:close()
      plugins "a/one"
      state.set_available("a/one", { commit = "1", at = 1 })
      assert.same({}, state.pending_updates())
    end)
  end)

  it("counts missing, unlocked and local plugins without running git", function()
    local dir = os.tmpname()
    os.remove(dir)
    os.execute(("mkdir -p '%s/plugin' && echo 'return 1' > '%s/plugin/init.lua'"):format(dir, dir))
    plugins("a/gone", "a/fresh", { "a/loc", dir = "/x" })
    -- a/fresh: cloned (point its path at a real plugin dir) but not in the lockfile
    state.by_id["a/fresh"].path = dir
    lock.write(tmp, { ["a/gone"] = { commit = "1" } })
    assert.same({ total = 3, missing = 1, unlocked = 1, local_count = 1 }, state.summary())
    os.execute(("rm -rf '%s'"):format(dir))
  end)

  it("remembers the open view per window", function()
    assert.is_nil(state.get_view(1))
    state.set_view(1, "plugin list")
    assert.equal("plugin list", state.get_view(1))
    assert.is_nil(state.get_view(2))
    assert.is_nil(state.get_view(nil))
    state.set_view(1, nil)
    assert.is_nil(state.get_view(1))
  end)
end)
