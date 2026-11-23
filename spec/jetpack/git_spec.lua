-- Real git against throwaway local repositories; nothing touches the network.
local wezterm = require "wezterm"

local function sh(cmd)
  local h = io.popen(cmd .. " 2>&1")
  local out = h:read "*a"
  local ok = h:close()
  assert(ok, cmd .. "\n" .. out)
  return (out:gsub("%s+$", ""))
end

describe("jetpack.git", function()
  local git, spec, tmp, src, url

  local function commit(msg, tag)
    sh(("cd '%s' && echo %s >> f && git add -A && git commit -qm %s"):format(src, msg, msg))
    if tag then
      sh(("git -C '%s' tag %s"):format(src, tag))
    end
    return sh(("git -C '%s' rev-parse HEAD"):format(src))
  end

  ---@return Jetpack.Spec
  local function spec_of(fields)
    fields.path = tmp .. "/clone"
    return fields
  end

  before_each(function()
    wezterm._reset()
    wezterm._child = wezterm._real_child
    for name in pairs(package.loaded) do
      if name:match "^jetpack" then
        package.loaded[name] = nil
      end
    end
    git, spec = require "jetpack.git", require "jetpack.spec"
    tmp = sh "mktemp -d"
    src = tmp .. "/src"
    url = "file://" .. src
    sh(("git init -q -b main '%s'"):format(src))
    sh(("git -C '%s' config user.email t@t && git -C '%s' config user.name t"):format(src, src))
    sh(
      ("git -C '%s' config commit.gpgsign false && git -C '%s' config tag.gpgsign false"):format(
        src,
        src
      )
    )
  end)

  after_each(function()
    sh(("rm -rf '%s'"):format(tmp))
  end)

  it("clones, reads the head and the default branch", function()
    local c1 = commit "one"
    assert.is_true(git.clone(url, tmp .. "/clone"))
    assert.equal(c1, git.head(tmp .. "/clone"))
    assert.equal("main", git.default_branch(tmp .. "/clone"))
  end)

  it("reports a failed clone with git's message", function()
    local ok, err = git.clone("file://" .. tmp .. "/nope", tmp .. "/clone")
    assert.is_false(ok)
    assert.is_string(err)
  end)

  it("lists tags, resolves refs and checks out a commit", function()
    local c1 = commit("one", "1.0.0")
    commit("two", "1.1.0")
    local dir = tmp .. "/clone"
    git.clone(url, dir)
    table.sort(git.tags(dir))
    assert.same({ "1.0.0", "1.1.0" }, git.tags(dir))
    assert.equal(c1, git.commit(dir, "refs/tags/1.0.0"))
    assert.is_nil(git.commit(dir, "refs/tags/9.9.9"))
    assert.is_true(git.checkout(dir, c1))
    assert.equal(c1, git.head(dir))
    local ok, err = git.checkout(dir, "deadbeef")
    assert.is_false(ok)
    assert.is_string(err)
  end)

  it("fetches new commits and tags", function()
    commit "one"
    local dir = tmp .. "/clone"
    git.clone(url, dir)
    local c2 = commit("two", "2.0.0")
    assert.is_true(git.fetch(dir))
    assert.equal(c2, git.commit(dir, "refs/tags/2.0.0"))
  end)

  it("fetch_all fetches many clones and names the one that fails", function()
    commit "one"
    local dirs = { tmp .. "/a", tmp .. "/b", tmp .. "/c" }
    for _, d in ipairs(dirs) do
      git.clone(url, d)
    end
    local c2 = commit("two", "2.0.0")
    sh(("git -C '%s' remote set-url origin file:///nonexistent"):format(dirs[3]))
    local out = git.fetch_all(dirs)
    assert.is_false(out[dirs[1]])
    assert.is_false(out[dirs[2]])
    assert.is_string(out[dirs[3]])
    assert.equal(c2, git.commit(dirs[2], "refs/tags/2.0.0"))
    assert.same({}, git.fetch_all {})
  end)

  it("sees changed and untracked files, and unpushed commits", function()
    commit "one"
    local dir = tmp .. "/clone"
    git.clone(url, dir)
    sh(("git -C '%s' config user.email t@t && git -C '%s' config user.name t"):format(dir, dir))
    sh(("git -C '%s' config commit.gpgsign false"):format(dir))
    assert.is_false(git.dirty(dir))
    assert.is_nil(git.local_work(dir))

    sh(("echo x > '%s/new'"):format(dir))
    assert.is_false(git.dirty(dir)) -- untracked files do not make it dirty ...
    assert.matches("untracked", git.local_work(dir)) -- ... but they are local work

    sh(("rm '%s/new' && echo y >> '%s/f'"):format(dir, dir))
    assert.is_true(git.dirty(dir))
    sh(("git -C '%s' commit -qam local"):format(dir))
    assert.is_false(git.dirty(dir))
    assert.matches("not pushed", git.local_work(dir))
  end)

  it("local_work errs on the side of keeping a directory that is not a repo", function()
    sh(("mkdir -p '%s/plain'"):format(tmp))
    assert.is_string(git.local_work(tmp .. "/plain"))
  end)

  describe("resolve", function()
    local dir, c1, c2, c3

    before_each(function()
      c1 = commit("one", "1.0.0")
      c2 = commit("two", "1.2.0")
      c3 = commit("three", "2.0.0")
      dir = tmp .. "/clone"
      git.clone(url, dir)
    end)

    it("picks the newest tag in a range", function()
      local s = spec_of { version = "^1", range = require("jetpack.semver").range "^1" }
      local c, ref = git.resolve(s)
      assert.equal(c2, c)
      assert.equal("1.2.0", ref)
    end)

    it("says when no tag matches", function()
      local s = spec_of { version = "^3", range = require("jetpack.semver").range "^3" }
      local c, err = git.resolve(s)
      assert.is_nil(c)
      assert.matches("no tag matches", err)
    end)

    it("resolves a tag, and names a missing one", function()
      assert.equal(c1, (git.resolve(spec_of { tag = "1.0.0" })))
      local c, err = git.resolve(spec_of { tag = "nope" })
      assert.is_nil(c)
      assert.matches("tag not found", err)
    end)

    it("resolves a commit by prefix, and names a missing one", function()
      local c, ref = git.resolve(spec_of { commit = c2:sub(1, 10) })
      assert.equal(c2, c)
      assert.equal(c2:sub(1, 10), ref)
      c, ref = git.resolve(spec_of { commit = "deadbeef" })
      assert.is_nil(c)
      assert.matches("commit not found", ref)
    end)

    it("follows a branch, or the default branch", function()
      local c, ref = git.resolve(spec_of {})
      assert.equal(c3, c)
      assert.equal("main", ref)
      c, ref = git.resolve(spec_of { branch = "gone" })
      assert.is_nil(c)
      assert.matches("branch not found", ref)
    end)
  end)

  it("uses the configured git executable", function()
    require("jetpack.config").parse { git = "/nonexistent/git" }
    wezterm._child = function(argv)
      assert.equal("/nonexistent/git", argv[1])
      return wezterm._real_child(argv)
    end
    commit "one"
    git.clone(url, tmp .. "/clone")
  end)
end)
