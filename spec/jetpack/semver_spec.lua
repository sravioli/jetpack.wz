local semver = require "jetpack.semver"

describe("jetpack.semver", function()
  it("parses versions with an optional v and prerelease", function()
    assert.same({ major = 1, minor = 2, patch = 3 }, semver.parse "v1.2.3")
    assert.same({ major = 2, minor = 0, patch = 0, pre = "rc.1" }, semver.parse "2.0.0-rc.1+b5")
    assert.is_nil(semver.parse "1.2")
    assert.is_nil(semver.parse "release")
  end)

  it("orders prereleases before releases", function()
    local p = semver.parse
    assert.equal(-1, semver.compare(p "1.0.0-rc.1", p "1.0.0"))
    assert.equal(-1, semver.compare(p "1.0.0-alpha", p "1.0.0-alpha.1"))
    assert.equal(-1, semver.compare(p "1.0.0-alpha.2", p "1.0.0-alpha.10"))
    assert.equal(1, semver.compare(p "1.10.0", p "1.9.9"))
  end)

  local tags = { "0.1.0", "0.2.0", "0.2.5", "1.0.0", "1.4.2", "v2.0.0", "2.1.0-rc.1", "junk" }
  for range, want in pairs {
    ["*"] = "v2.0.0",
    ["^1"] = "1.4.2",
    ["^0.2"] = "0.2.5",
    ["^0.2.0"] = "0.2.5",
    ["~1.4"] = "1.4.2",
    ["~0.1"] = "0.1.0",
    ["1"] = "1.4.2",
    [">=0.2"] = "v2.0.0",
    ["2.1.0-rc.1"] = "2.1.0-rc.1",
    ["1.0.0"] = "1.0.0",
  } do
    it("picks " .. want .. " for " .. range, function()
      assert.equal(want, semver.best(assert(semver.range(range)), tags))
    end)
  end

  it("returns nil when nothing matches or the range is invalid", function()
    assert.is_nil(semver.best(semver.range "^3", tags))
    assert.is_nil(semver.range "latest")
    assert.is_nil(semver.range "^x")
  end)
end)
