local spec = require "jetpack.spec"

describe("jetpack.spec", function()
  it("expands owner/repo shorthand", function()
    local s = spec.normalize("sravioli/beacon.wz", "/r")
    assert.equal("sravioli/beacon.wz", s.id)
    assert.equal("https://github.com/sravioli/beacon.wz", s.url)
    assert.equal("beacon.wz", s.name)
    assert.equal("/r/sravioli__beacon.wz", s.path)
    assert.equal("default", spec.kind(s))
  end)

  it("normalizes GitHub URLs to the same id", function()
    local s = spec.normalize({ url = "https://github.com/sravioli/beacon.wz.git/" }, "/r")
    assert.equal("sravioli/beacon.wz", s.id)
    assert.equal("https://github.com/sravioli/beacon.wz", s.url)
  end)

  it("keys other URLs by the URL without scheme", function()
    local s = spec.normalize({ "file:///src/demo" }, "/r")
    assert.equal("/src/demo", s.id)
    assert.equal("/r/__src__demo", s.path)
  end)

  it("uses dir as the path for local checkouts", function()
    local s = spec.normalize({ "a/b", dir = "~/src/b/" }, "/r")
    assert.is_true(s.local_dir)
    assert.equal("/home/mock/src/b", s.path)
  end)

  it("resolves by commit, tag, version, branch, default", function()
    assert.equal("commit", spec.kind(spec.normalize({ "a/b", commit = "c", tag = "t" }, "/r")))
    assert.equal("tag", spec.kind(spec.normalize({ "a/b", tag = "t", version = "*" }, "/r")))
    assert.equal(
      "version",
      spec.kind(spec.normalize({ "a/b", version = "^1", branch = "x" }, "/r"))
    )
    assert.equal("branch", spec.kind(spec.normalize({ "a/b", branch = "x" }, "/r")))
  end)

  it("rejects bad input", function()
    assert.has_error(function()
      spec.normalize({ "a/b", version = "nope" }, "/r")
    end, 'a/b: invalid version range "nope"')
    assert.has_error(function()
      spec.normalize({ tag = "x" }, "/r")
    end)
    assert.has_error(function()
      spec.normalize({ "a/b", tag = 1 }, "/r")
    end)
    assert.has_error(function()
      spec.list({ "a/b", { url = "https://github.com/a/b" } }, "/r")
    end, "duplicate spec: a/b")
  end)

  it("indexes by id and case-insensitive URL", function()
    local _, by_id, by_url = spec.list({ "Owner/Repo" }, "/r")
    assert.truthy(by_id["Owner/Repo"])
    assert.truthy(by_url[spec.url_key "https://github.com/owner/repo.git"])
  end)

  describe("enabled", function()
    it("drops entries that are false or whose function says no", function()
      local list = spec.list({
        { "a/one", enabled = false },
        {
          "a/two",
          enabled = function()
            return false
          end,
        },
        {
          "a/three",
          enabled = function()
            return true
          end,
        },
        { "a/four", enabled = true },
        "a/five",
      }, "/r")
      local ids = {}
      for _, s in ipairs(list) do
        ids[#ids + 1] = s.id
      end
      assert.same({ "a/three", "a/four", "a/five" }, ids)
    end)

    it("lets two entries for one plugin pick by condition", function()
      local list = spec.list({
        { "a/b", enabled = false, version = "^1" },
        { "a/b", enabled = true, version = "^2" },
      }, "/r")
      assert.equal(1, #list)
      assert.equal("^2", list[1].version)
    end)

    it("rejects other types", function()
      assert.has_error(function()
        spec.list({ { "a/b", enabled = "yes" } }, "/r")
      end)
    end)
  end)

  describe("opts and config", function()
    it("are kept on the spec, and must be a table and a function", function()
      local f = function() end
      local s = spec.normalize({ "a/b", opts = { x = 1 }, config = f }, "/r")
      assert.same({ x = 1 }, s.opts)
      assert.equal(f, s.config)
      assert.has_error(function()
        spec.normalize({ "a/b", opts = "x" }, "/r")
      end)
      assert.has_error(function()
        spec.normalize({ "a/b", config = {} }, "/r")
      end)
    end)
  end)
end)
