package.path = table.concat({
  "bookloresync.koplugin/?.lua",
  "bookloresync.koplugin/?/init.lua",
  package.path,
}, ";")

package.preload["logger"] = function()
  return {
    info = function() end,
    warn = function() end,
    err = function() end,
    dbg = function() end,
  }
end

package.preload["socket.http"] = function()
  return { request = function() return nil, "not implemented", {} end }
end

package.preload["ssl.https"] = function()
  return { request = function() return nil, "not implemented", {} end }
end

package.preload["ltn12"] = function()
  return {
    sink = { table = function(tbl)
      return function(chunk)
        if chunk then
          tbl[#tbl + 1] = chunk
        end
        return 1
      end
    end },
    source = { string = function(s)
      local done = false
      return function()
        if done then return nil end
        done = true
        return s
      end
    end }
  }
end

package.preload["json"] = function()
  return {
    decode = function() return {} end,
    encode = function() return "{}" end,
  }
end

package.preload["datastorage"] = function()
  return { getDataDir = function() return "/tmp" end }
end

package.preload["ffi"] = function()
  return {}
end

package.preload["util"] = function()
  return {}
end

local Updater = require("booklore_updater")

describe("Updater helper methods", function()
  local updater

  before_each(function()
    updater = Updater:new()
  end)

  it("parses semantic versions", function()
    local parsed = updater:parseVersion("v1.2.3")
    assert.is_table(parsed)
    assert.are.equal(1, parsed.major)
    assert.are.equal(2, parsed.minor)
    assert.are.equal(3, parsed.patch)
    assert.is_false(parsed.is_dev)
  end)

  it("treats dev builds as development versions", function()
    local parsed = updater:parseVersion("0.0.0-dev+abc")
    assert.is_table(parsed)
    assert.is_true(parsed.is_dev)
  end)

  it("rejects invalid versions", function()
    assert.is_nil(updater:parseVersion("not-a-version"))
  end)

  it("compares versions correctly", function()
    local old = updater:parseVersion("1.0.5")
    local new = updater:parseVersion("1.1.0")
    assert.are.equal(-1, updater:compareVersions(old, new))
    assert.are.equal(1, updater:compareVersions(new, old))
    assert.are.equal(0, updater:compareVersions(new, new))
  end)

  it("extracts changelog section for a specific version", function()
    local changelog = table.concat({
      "# [3.4.0] - 2025-01-15",
      "### Added",
      "- New sync mode",
      "",
      "# [3.3.0] - 2024-12-01",
      "### Added",
      "- Older entry",
    }, "\n")

    local section = updater:parseChangelogForVersion(changelog, "v3.4.0")
    assert.is_not_nil(section)
    assert.is_truthy(section:find("New sync mode", 1, true))
    assert.is_falsy(section:find("Older entry", 1, true))
  end)

  it("cleans markdown links and URLs from changelog", function()
    local cleaned = updater:cleanChangelog("- Fix [PR](https://example.org/pr/1) (deadbeef)")
    assert.are.equal("- Fix PR", cleaned)
  end)

  it("formats byte counts", function()
    assert.are.equal("Unknown size", updater:formatBytes(0))
    assert.are.equal("500 B", updater:formatBytes(500))
    assert.are.equal("1.0 KB", updater:formatBytes(1024))
    assert.are.equal("1.0 MB", updater:formatBytes(1024 * 1024))
  end)
end)
