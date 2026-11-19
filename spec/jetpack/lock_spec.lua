local lock = require "jetpack.lock"

describe("jetpack.lock", function()
  it("encodes sorted, one plugin per line", function()
    local text = lock.encode {
      ["b/b"] = { commit = "222", ref = "1.0.0" },
      ["a/a"] = { commit = "111" },
    }
    assert.equal(
      '{\n  "a/a": { "commit": "111" },\n  "b/b": { "commit": "222", "ref": "1.0.0" }\n}\n',
      text
    )
    assert.equal("{}\n", lock.encode {})
  end)

  it("round-trips through a file byte for byte", function()
    local path = os.tmpname()
    local data = { ["x/y"] = { commit = "abc", ref = "main" }, ["a/b"] = { commit = "def" } }
    assert.is_true(lock.write(path, data))
    assert.same(data, lock.read(path))
    local f = io.open(path)
    local first = f:read "*a"
    f:close()
    assert.equal(lock.encode(lock.read(path)), first)
    os.remove(path)
  end)

  it("writes atomically without warp's write_file", function()
    local fs = require("jetpack.deps").warp.filesystem
    local saved = fs.write_file
    fs.write_file = nil
    local path = os.tmpname()
    local data = { ["a/b"] = { commit = "abc", ref = "1.0.0" } }
    local ok, err = lock.write(path, data)
    fs.write_file = saved
    assert.is_true(ok, err)
    assert.same(data, lock.read(path))
    os.remove(path)
  end)

  it("treats a missing or empty file as empty and refuses corrupt JSON", function()
    assert.same({}, lock.read "/nonexistent/jetpack-lock.json")
    local path = os.tmpname()
    assert.same({}, lock.read(path))
    local f = io.open(path, "w")
    f:write "{ not json"
    f:close()
    assert.has_error(function()
      lock.read(path)
    end)
    os.remove(path)
  end)
end)
