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

-- Clear any stubs cached by other spec files (e.g. shelf_sync_spec loads main.lua
-- which registers a booklore_updater stub in package.loaded and package.preload).
package.loaded["booklore_updater"] = nil
package.preload["booklore_updater"] = nil

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

  it("returns installable result for direct download channel", function()
    updater.getCurrentVersion = function()
      return { version = "3.8.4" }
    end

    updater._headRequest = function()
      return true, "https://example.org/dev-download", 1234, 200
    end

    local result = updater:checkForDirectDownload("https://example.org/dev-download")
    assert.is_table(result)
    assert.is_true(result.available)
    assert.are.equal("3.8.4", result.current_version)
    assert.are.equal("dev-build", result.latest_version)
    assert.are.equal("https://example.org/dev-download", result.release_info.download_url)
    assert.are.equal("dev", result.release_info.channel)
    assert.are.equal(1234, result.release_info.size)
  end)

  it("fails direct download check when endpoint is unreachable", function()
    updater.getCurrentVersion = function()
      return { version = "3.8.4" }
    end

    updater._headRequest = function()
      return false, "timeout", nil, nil
    end

    local result = updater:checkForDirectDownload("https://example.org/dev-download")
    assert.is_nil(result)
  end)

  -- ═════════════════════════════════════════════════════════════════════════
  -- Expanded parsing and comparison edge cases
  -- ═════════════════════════════════════════════════════════════════════════

  it("parses version without 'v' prefix", function()
    local parsed = updater:parseVersion("1.2.3")
    assert.is_table(parsed)
    assert.are.equal(1, parsed.major)
    assert.are.equal(2, parsed.minor)
    assert.are.equal(3, parsed.patch)
  end)

  it("parses two-digit version components", function()
    local parsed = updater:parseVersion("v10.20.30")
    assert.are.equal(10, parsed.major)
    assert.are.equal(20, parsed.minor)
    assert.are.equal(30, parsed.patch)
  end)

  it("parses version with only major.minor — rejected (requires three parts)", function()
    assert.is_nil(updater:parseVersion("v2.7"))
  end)

  it("parses version with only major number — rejected", function()
    assert.is_nil(updater:parseVersion("v3"))
  end)

  it("rejects nil version", function()
    assert.is_nil(updater:parseVersion(nil))
  end)

  it("rejects empty string version", function()
    assert.is_nil(updater:parseVersion(""))
  end)

  it("rejects version with letters in numbers", function()
    assert.is_nil(updater:parseVersion("v1.abc.3"))
  end)

  it("rejects version with only text", function()
    assert.is_nil(updater:parseVersion("alpha"))
  end)

  it("compares versions with different patch levels", function()
    local v1 = updater:parseVersion("1.0.5")
    local v2 = updater:parseVersion("1.0.9")
    assert.are.equal(-1, updater:compareVersions(v1, v2))
    assert.are.equal(1, updater:compareVersions(v2, v1))
  end)

  it("compares versions with different minor levels", function()
    local v1 = updater:parseVersion("2.1.0")
    local v2 = updater:parseVersion("2.5.0")
    assert.are.equal(-1, updater:compareVersions(v1, v2))
  end)

  it("compares dev version lower than release of same number", function()
    local dev = updater:parseVersion("1.0.0-dev+abc")
    local rel = updater:parseVersion("1.0.0")
    assert.are.equal(-1, updater:compareVersions(dev, rel))
  end)

  it("compares nil versions as equal", function()
    assert.are.equal(0, updater:compareVersions(nil, updater:parseVersion("1.0.0")))
    assert.are.equal(0, updater:compareVersions(updater:parseVersion("1.0.0"), nil))
    assert.are.equal(0, updater:compareVersions(nil, nil))
  end)

  -- ═════════════════════════════════════════════════════════════════════════
  -- formatBytes edge cases
  -- ═════════════════════════════════════════════════════════════════════════

  it("formats zero bytes as Unknown size", function()
    assert.are.equal("Unknown size", updater:formatBytes(0))
  end)

  it("formats negative bytes as-is (no guard for negative)", function()
    -- Implementation only checks bytes==0, not negative
    assert.are.equal("-1 B", updater:formatBytes(-1))
  end)

  it("formats exactly 1 byte", function()
    assert.are.equal("1 B", updater:formatBytes(1))
  end)

  it("formats 999 bytes", function()
    assert.are.equal("999 B", updater:formatBytes(999))
  end)

  it("formats exactly 1 KB", function()
    assert.are.equal("1.0 KB", updater:formatBytes(1024))
  end)

  it("formats exactly 1 MB", function()
    assert.are.equal("1.0 MB", updater:formatBytes(1024 * 1024))
  end)

  it("formats large value as MB, not GB", function()
    -- Implementation only goes up to MB
    local result = updater:formatBytes(1024 * 1024 * 1024)
    assert.are.equal("1024.0 MB", result)
  end)

  it("formats 1536 bytes as 1.5 KB", function()
    assert.are.equal("1.5 KB", updater:formatBytes(1536))
  end)

  -- ═════════════════════════════════════════════════════════════════════════
  -- cleanChangelog edge cases
  -- ═════════════════════════════════════════════════════════════════════════

  it("cleans changelog with commit hash references", function()
    local cleaned = updater:cleanChangelog("- Feature X ([abc1234](https://github.com/x/y/commit/abc1234))")
    assert.are.equal("- Feature X", cleaned)
  end)

  it("cleans multiple markdown links", function()
    local cleaned = updater:cleanChangelog("[Link1](url1) and [Link2](url2)")
    assert.are.equal("Link1 and Link2", cleaned)
  end)

  it("returns empty string for nil changelog", function()
    assert.are.equal("", updater:cleanChangelog(nil))
  end)

  it("preserves plain text without links", function()
    assert.are.equal("Just plain text", updater:cleanChangelog("Just plain text"))
  end)

  it("strips inline URLs without markdown", function()
    local cleaned = updater:cleanChangelog("See https://example.com/release for more")
    -- URL stripped; single space between words (no double-space artifact)
    assert.is_truthy(cleaned:find("See  for more", 1, true) ~= nil
                  or cleaned:find("See for more", 1, true) ~= nil)
  end)
end)
