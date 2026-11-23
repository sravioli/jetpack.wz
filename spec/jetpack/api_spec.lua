-- The public surface: setup, require, apply_to_config, and the install that
-- setup runs for missing clones. warp and warden are `dir` specs, so nothing
-- clones from the network.
local wezterm = require "wezterm"

local function sh(cmd)
  local h = io.popen(cmd .. " 2>&1")
  local out = h:read "*a"
  local ok = h:close()
  assert(ok, cmd .. "\n" .. out)
  return (out:gsub("%s+$", ""))
end

local warp_dir = sh "cd ../warp.wz && pwd"
local warden_dir = sh "cd ../warden.wz && pwd"

describe("jetpack.api", function()
  local jetpack, state, tmp, lockfile

  local function logged(fn)
    local out = {}
    for _, c in ipairs(wezterm._calls) do
      if c.fn == fn then
        out[#out + 1] = c.args[1]
      end
    end
    return out
  end

  local function setup(spec, extra)
    local opts = { root = tmp .. "/root", lockfile = lockfile, spec = spec }
    for k, v in pairs(extra or {}) do
      opts[k] = v
    end
    return jetpack.setup(opts)
  end

  local own = {
    { "sravioli/warp.wz", dir = warp_dir },
    { "sravioli/warden.wz", dir = warden_dir },
  }

  local function with_own(...)
    local spec = { ... }
    for _, o in ipairs(own) do
      spec[#spec + 1] = o
    end
    return spec
  end

  before_each(function()
    wezterm._reset()
    wezterm._child = wezterm._real_child
    tmp = sh "mktemp -d"
    lockfile = tmp .. "/jetpack-lock.json"
    for name in pairs(package.loaded) do
      if name:match "^jetpack" then
        package.loaded[name] = nil
      end
    end
    jetpack, state = require "jetpack.api", require "jetpack.state"
  end)

  after_each(function()
    sh(("rm -rf '%s'"):format(tmp))
  end)

  describe("setup", function()
    it("adds warp and warden when the spec lacks them, warp at 1.0 or newer", function()
      -- Their clones are missing, so make the install a no-op: another process holds the lock.
      sh(("mkdir -p '%s/root/.jetpack.lock'"):format(tmp))
      sh(("echo %d > '%s/root/.jetpack.lock/since'"):format(os.time(), tmp))
      setup {}
      assert.equal(">=1.0.0", state.by_id["sravioli/warp.wz"].version)
      assert.is_not_nil(state.by_id["sravioli/warden.wz"])
      assert.is_nil(state.by_id["sravioli/warden.wz"].version)
    end)

    it("keeps the spec the user wrote for warp", function()
      setup(with_own())
      assert.equal(warp_dir, state.by_id["sravioli/warp.wz"].path)
      assert.is_nil(state.by_id["sravioli/warp.wz"].version)
    end)

    it("returns the module, and rejects a bad option", function()
      assert.equal(jetpack, setup(with_own()))
      assert.has_error(function()
        jetpack.setup { spec = "nope" }
      end)
    end)
  end)

  describe("install of missing clones", function()
    local function missing_spec()
      return with_own { "file://" .. tmp .. "/none", name = "ghost", version = "*" }
    end

    it("installs nothing and writes nothing while another WezTerm holds the lock", function()
      sh(("mkdir -p '%s/root/.jetpack.lock'"):format(tmp))
      sh(("echo %d > '%s/root/.jetpack.lock/since'"):format(os.time(), tmp))
      local f = io.open(lockfile, "w")
      f:write '{ "version": 1, "plugins": { "keep/me": { "commit": "abc" } } }'
      f:close()
      local before = io.open(lockfile):read "*a"

      setup(missing_spec())

      assert.matches("another WezTerm is already working", table.concat(logged "log_error"))
      assert.equal(before, io.open(lockfile):read "*a")
    end)

    it("does not install, nor overwrite, a corrupt lockfile", function()
      local f = io.open(lockfile, "w")
      f:write "{ broken"
      f:close()
      setup(missing_spec())
      assert.matches("not installing anything", table.concat(logged "log_error"))
      assert.equal("{ broken", io.open(lockfile):read "*a")
      assert.is_nil(io.open(tmp .. "/root/.jetpack.lock"))
    end)

    it("releases the lock after installing, and logs a failed clone", function()
      setup(missing_spec())
      assert.matches("cannot install", table.concat(logged "log_error"))
      assert.is_nil(io.open(tmp .. "/root/.jetpack.lock/since"))
    end)
  end)

  describe("require", function()
    it("loads a managed plugin by id, name or URL", function()
      local dir = tmp .. "/demo"
      sh(
        ("mkdir -p '%s/plugin' && echo 'return { ok = true }' > '%s/plugin/init.lua'"):format(
          dir,
          dir
        )
      )
      setup(with_own { "acme/demo", dir = dir })
      local a = jetpack.require "acme/demo"
      assert.is_true(a.ok)
      assert.equal(a, jetpack.require "demo")
      assert.equal(a, jetpack.require "https://github.com/acme/demo")
    end)

    it("errors for a name that is not in the spec", function()
      setup(with_own())
      local ok, err = pcall(jetpack.require, "nobody/nothing")
      assert.is_false(ok)
      assert.matches("not in the spec", err)
    end)
  end)

  describe("apply_to_config", function()
    it("registers the picker key table under the configured name", function()
      setup(with_own(), { picker = { key_table = "my_picker" } })
      local c = jetpack.apply_to_config {}
      assert.is_table(c.key_tables.my_picker)
      assert.is_true(#c.key_tables.my_picker > 0)
    end)

    it("keeps key tables that are already there", function()
      setup(with_own())
      local c = jetpack.apply_to_config { key_tables = { mine = { { key = "a", action = "x" } } } }
      assert.is_table(c.key_tables.mine)
      assert.is_table(c.key_tables.jetpack_picker)
    end)
  end)

  describe("action", function()
    it("builds a key assignment for each view", function()
      for _, name in ipairs { "open", "update", "sync", "check" } do
        assert.is_not_nil(jetpack.action[name]())
      end
    end)
  end)

  it("status and orphans work with nothing installed", function()
    setup(with_own())
    local status = jetpack.status()
    assert.equal(#state.list, #status)
    assert.same({}, jetpack.orphans())
  end)
end)
