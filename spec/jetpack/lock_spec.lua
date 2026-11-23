local lock = require "jetpack.lock"

describe("jetpack.lock", function()
  it("encodes sorted, one plugin per line", function()
    local text = lock.encode {
      ["b/b"] = { commit = "222", ref = "1.0.0" },
      ["a/a"] = { commit = "111" },
    }
    assert.equal(
      '{\n  "version": 1,\n  "plugins": {\n'
        .. '    "a/a": { "commit": "111" },\n'
        .. '    "b/b": { "commit": "222", "ref": "1.0.0" }\n  }\n}\n',
      text
    )
    assert.equal('{\n  "version": 1,\n  "plugins": {}\n}\n', lock.encode {})
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

  it("reads the 0.x format (no version) and rewrites it as version 1", function()
    local path = os.tmpname()
    local f = io.open(path, "w")
    f:write '{\n  "a/b": { "commit": "abc", "ref": "1.0.0" }\n}\n'
    f:close()
    local data = lock.read(path)
    assert.same({ ["a/b"] = { commit = "abc", ref = "1.0.0" } }, data)
    assert.is_true(lock.write(path, data))
    f = io.open(path)
    local text = f:read "*a"
    f:close()
    assert.truthy(text:find('"version": 1', 1, true))
    assert.same(data, lock.read(path))
    os.remove(path)
  end)

  it("refuses a lockfile from a newer jetpack", function()
    local path = os.tmpname()
    local f = io.open(path, "w")
    f:write(('{ "version": %d, "plugins": {} }'):format(lock.VERSION + 1))
    f:close()
    local ok, err = pcall(lock.read, path)
    assert.is_false(ok)
    assert.truthy(err:find("Update jetpack", 1, true))
    os.remove(path)
  end)
end)
