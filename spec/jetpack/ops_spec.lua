-- Integration: real git against a local repository tagged 1.0.0, 1.1.0,
-- 2.0.0 and 2.1.0-rc.1. Nothing touches the network: warp is a `dir` spec.
local wezterm = require "wezterm"

local function sh(cmd)
  local h = io.popen(cmd .. " 2>&1")
  local out = h:read "*a"
  local ok = h:close()
  assert(ok, cmd .. "\n" .. out)
  return (out:gsub("%s+$", ""))
end

local function real_read_dir(p)
  local out = {}
  for line in sh(("ls -1A '%s'"):format(p)):gmatch "[^\n]+" do
    out[#out + 1] = p .. "/" .. line
  end
  return out
end

local warp_dir = sh "cd ../warp.wz && pwd"
local warden_dir = sh "cd ../warden.wz && pwd"

describe("jetpack operations (git)", function()
  local tmp, src, url, jetpack, ops, lockfile, children

  local function commit_tag(version)
    sh(("cd '%s' && printf 'return { version = %q }\\n' > plugin/init.lua"):format(src, version))
    sh(("cd '%s' && git add -A && git commit -qm %s && git tag %s"):format(src, version, version))
  end

  local function head(dir)
    return sh(("git -C '%s' rev-parse HEAD"):format(dir))
  end

  local function lock_of()
    return require("jetpack.lock").read(lockfile)
  end

  local function setup(extra)
    local s = { url = url, name = "demo", version = "^1" }
    for k, v in pairs(extra or {}) do
      s[k] = v or nil
    end
    return jetpack.setup {
      root = tmp .. "/root",
      lockfile = lockfile,
      spec = {
        s,
        { "sravioli/warp.wz", dir = warp_dir },
        { "sravioli/warden.wz", dir = warden_dir },
      },
    }
  end

  before_each(function()
    wezterm._reset()
    children = 0
    wezterm._child = function(argv)
      children = children + 1
      return wezterm._real_child(argv)
    end
    wezterm.read_dir = real_read_dir
    tmp = sh "mktemp -d"
    src = tmp .. "/src"
    url = "file://" .. src
    lockfile = tmp .. "/jetpack-lock.json"
    sh(("mkdir -p '%s/plugin' && git -C '%s' init -q -b main"):format(src, src))
    sh(("git -C '%s' config user.email t@t && git -C '%s' config user.name t"):format(src, src))
    sh(
      ("git -C '%s' config commit.gpgsign false && git -C '%s' config tag.gpgsign false"):format(
        src,
        src
      )
    )
    for _, v in ipairs { "1.0.0", "1.1.0", "2.0.0", "2.1.0-rc.1" } do
      commit_tag(v)
    end
    for name in pairs(package.loaded) do
      if name:match "^jetpack" then
        package.loaded[name] = nil
      end
    end
    jetpack = require "jetpack.api"
    ops = require "jetpack.ops"
  end)

  after_each(function()
    sh(("rm -rf '%s'"):format(tmp))
  end)

  it("installs a missing plugin on setup and locks the newest match", function()
    setup()
    local s = require("jetpack.state").by_id[src]
    assert.equal("1.1.0", lock_of()[src].ref)
    assert.equal(sh(("git -C '%s' rev-parse 1.1.0"):format(src)), head(s.path))
    assert.same({ version = "1.1.0" }, jetpack.require "demo")
  end)

  it("runs no git on a reload once everything is installed", function()
    setup()
    children = 0
    for name in pairs(package.loaded) do
      if name:match "^jetpack" then
        package.loaded[name] = nil
      end
    end
    jetpack = require "jetpack.api"
    setup()
    assert.equal(0, children)
    -- Validation loads warp and warden, but only after the pinned paths are
    -- on package.path: both resolve to their spec'd checkouts.
    assert.equal(warp_dir .. "/plugin/warp/api.lua", package.searchpath("warp.api", package.path))
    assert.equal(
      warden_dir .. "/plugin/warden/api.lua",
      package.searchpath("warden.api", package.path)
    )
    assert.is_nil(package.loaded["jetpack.ops"])
  end)

  it("checks without checking out, then updates when the range widens", function()
    setup()
    local s = require("jetpack.state").by_id[src]
    local before = head(s.path)
    local report = ops.check()
    assert.equal("current", report[1].action)
    assert.equal(before, head(s.path))

    setup { version = "*" }
    report = ops.check()
    assert.equal("available", report[1].action)
    assert.equal("2.0.0", report[1].detail)
    assert.equal(before, head(s.path))
    assert.equal("update", ops.status()[1].state)

    report = ops.update()
    assert.equal("updated", report[1].action)
    assert.equal("1.1.0 → 2.0.0", report[1].detail)
    assert.equal("2.0.0", lock_of()[src].ref)
    assert.equal("ok", ops.status()[1].state)
    assert.is_true(ops.changed(report))
  end)

  it("records the previous version on update and undoes back to it", function()
    setup()
    local s = require("jetpack.state").by_id[src]
    local before = head(s.path)
    setup { version = "*" }
    ops.update()
    local entry = lock_of()[src]
    assert.equal("2.0.0", entry.ref)
    assert.equal(before, entry.prev)
    assert.equal("1.1.0", entry.prev_ref)

    local report = ops.undo()
    assert.equal("undone", report[1].action)
    assert.equal("2.0.0 → 1.1.0", report[1].detail)
    assert.equal(before, head(s.path))
    entry = lock_of()[src]
    assert.equal("1.1.0", entry.ref)
    assert.is_nil(entry.prev)
    assert.is_true(ops.changed(report))
    -- Nothing left to undo: asked for by id, that is an error; for all, a no-op.
    assert.same({}, ops.undo())
    assert.equal("no earlier version recorded", ops.undo({ "demo" })[1].detail)
  end)

  it("refuses to run while another process holds the lock, and takes over a stale one", function()
    setup()
    local dir = tmp .. "/root/.jetpack.lock"
    sh(("mkdir '%s' && printf '%%d' %d > '%s/since'"):format(dir, os.time() - 30, dir))
    local report = ops.check()
    assert.equal(1, #report)
    assert.is_false(report[1].ok)
    assert.matches("^another WezTerm is already working on plugins %(for 3%ds%)$", report[1].detail)

    sh(("printf '%%d' %d > '%s/since'"):format(os.time() - ops.LOCK_STALE - 1, dir))
    report = ops.check()
    assert.equal("current", report[1].action)
    -- Released afterwards.
    assert.is_nil(io.open(dir .. "/since"))
  end)

  it("lists the commits an update would bring in", function()
    setup()
    assert.same({ nil, "check for updates first" }, { ops.changes(src) })
    setup { version = "*" }
    ops.check()
    local commits = ops.changes(src)
    assert.equal(1, #commits)
    assert.equal("2.0.0", commits[1].subject)
    assert.matches("^%x+$", commits[1].hash)
  end)

  it("fetches several plugins at once and reports a failure per plugin", function()
    local src2 = tmp .. "/src2"
    sh(("git clone -q '%s' '%s'"):format(src, src2))
    jetpack.setup {
      root = tmp .. "/root",
      lockfile = lockfile,
      spec = {
        { url = url, name = "demo", version = "*" },
        { url = "file://" .. src2, name = "two", version = "*" },
        { "sravioli/warp.wz", dir = warp_dir },
        { "sravioli/warden.wz", dir = warden_dir },
      },
    }
    local st = require "jetpack.state"
    -- Break the second plugin's remote; the first must still be checked.
    sh(("git -C '%s' remote set-url origin '%s/nowhere'"):format(st.by_id[src2].path, tmp))
    children = 0
    local report = ops.check()
    assert.equal("current", report[1].action)
    assert.is_false(report[2].ok)
    assert.matches("nowhere", report[2].detail)
    -- The fetches ran in one process (plus resolution), not one per plugin.
    local fetches = 0
    for _, argv in ipairs(wezterm._child_calls) do
      if argv[2] == "-C" and argv[4] == "fetch" then
        fetches = fetches + 1
      end
    end
    assert.equal(0, fetches)
    assert.is_nil(io.open(st.by_id[src].path .. "/.git/jetpack-fetch.rc"))
  end)

  it("reports health: git, files, hooks and where plugins load from", function()
    setup()
    local checks = ops.doctor()
    local text = {}
    local warnings = 0
    for _, c in ipairs(checks) do
      text[#text + 1] = c.level .. " " .. c.text
      if c.level == "warn" then
        warnings = warnings + 1
      end
    end
    local all = table.concat(text, "\n")
    assert.matches("ok git: .-git version", all)
    assert.matches("ok root: " .. tmp:gsub("%p", "%%%0") .. "/root", all)
    assert.matches("ok lockfile: .-%(1 plugin%)", all)
    assert.matches("ok plugin.require/list hooks: installed", all)
    assert.matches("ok demo: ok 1%.1%.0", all)
    assert.matches("ok warp%.wz: local", all)
    assert.equal(0, warnings)

    -- A plugin whose module resolves outside its pinned path is flagged.
    package.path = warp_dir .. "/plugin/?.lua;" .. package.path
    require("jetpack.state").by_id["sravioli/warp.wz"].path = tmp .. "/elsewhere"
    local flagged = false
    for _, c in ipairs(ops.doctor()) do
      if c.level == "warn" and c.text:match "^warp%.wz:.*resolves to" then
        flagged = true
      end
    end
    assert.is_true(flagged)
  end)

  it("restores the locked commit after a manual checkout", function()
    setup()
    local s = require("jetpack.state").by_id[src]
    sh(("git -C '%s' -c advice.detachedHead=false checkout -q 1.0.0"):format(s.path))
    assert.equal("drift", ops.status()[1].state)
    local report = ops.restore()
    assert.equal("restored", report[1].action)
    assert.equal("ok", ops.status()[1].state)
  end)

  it("never checks out over uncommitted changes", function()
    setup { version = "*" }
    local s = require("jetpack.state").by_id[src]
    sh(("printf 'x' >> '%s/plugin/init.lua'"):format(s.path))
    local report = ops.update()
    assert.is_false(report[1].ok)
    assert.equal("uncommitted changes", report[1].detail)
    assert.equal("dirty", ops.status()[1].state)
  end)

  it("sync reinstalls a deleted clone at the locked commit", function()
    setup()
    local s = require("jetpack.state").by_id[src]
    local locked = lock_of()[src].commit
    sh(("rm -rf '%s'"):format(s.path))
    assert.equal("missing", ops.status()[1].state)
    local report = ops.sync()
    assert.equal("installed", report[1].action)
    assert.equal(locked, head(s.path))
  end)

  it("pins tags and commits", function()
    setup { version = false, tag = "1.0.0" }
    assert.equal("1.0.0", lock_of()[src].ref)
    local c = sh(("git -C '%s' rev-parse 2.0.0"):format(src))
    setup { tag = false, commit = c }
    ops.update()
    assert.equal(c, lock_of()[src].commit)
  end)

  it("deletes a clone whose spec cannot resolve, so it never loads unpinned", function()
    setup { version = "^9" }
    local s = require("jetpack.state").by_id[src]
    assert.is_false(require("jetpack.hook").exists(s.path))
    assert.is_nil(lock_of()[src])
    assert.has_error(function()
      wezterm.plugin.require(url)
    end)
    local logged = false
    for _, c in ipairs(wezterm._calls) do
      if c.fn == "log_error" and tostring(c.args[1]):match "no tag matches %^9" then
        logged = true
      end
    end
    assert.is_true(logged)
  end)

  it("refuses to clean a clone with local work", function()
    setup()
    local root = tmp .. "/root"
    sh(("git clone -q '%s' '%s/wip'"):format(src, root))
    sh(("printf 'x' > '%s/wip/new-file'"):format(root))
    local report = ops.clean()
    assert.is_false(report[1].ok)
    assert.equal("has uncommitted or untracked files", report[1].detail)
    assert.truthy(io.open(root .. "/wip/new-file"))
    sh(("rm '%s/wip/new-file'"):format(root))
    sh(
      ("cd '%s/wip' && git -c user.email=t@t -c user.name=t -c commit.gpgsign=false commit -q --allow-empty -m local"):format(
        root
      )
    )
    report = ops.clean()
    assert.equal("has commits not pushed to any remote", report[1].detail)
  end)

  it("leaves dir specs alone and cleans only unlisted clones", function()
    setup()
    local root = tmp .. "/root"
    sh(("git clone -q '%s' '%s/orphan'"):format(src, root))
    sh(("mkdir -p '%s/not-a-clone'"):format(root))
    local status = ops.status()
    assert.equal("local", status[2].state)
    assert.same({ root .. "/orphan" }, ops.orphans())
    local report = ops.clean()
    assert.equal("removed", report[1].action)
    assert.same({}, ops.orphans())
    assert.equal("ok", ops.status()[1].state)
    assert.equal(0, #real_read_dir(root .. "/not-a-clone"))
  end)
end)
