package.path = table.concat({
  "bookloresync.koplugin/?.lua",
  "bookloresync.koplugin/?/init.lua",
  package.path,
}, ";")

package.preload["logger"] = function()
  return { info = function() end, warn = function() end, err = function() end, dbg = function() end }
end
package.preload["device"] = function()
  return { isAndroid = function() return false end, model = "KOReader-Test" }
end
package.preload["ui/uimanager"] = function()
  return { scheduleIn = function(_, _, fn) if fn then fn() end end, nextTick = function(_, fn) if fn then fn() end end, show = function() end, close = function() end, forceRePaint = function() end }
end
package.preload["json"] = function()
  return { decode = function() return {} end, encode = function() return "{}" end, util = { InitArray = function(t) return t end } }
end

-- Stubs for deps consumed by the progress factory
local ProgressSyncFactory = require("booklore_progress_sync")

describe("ProgressSync additional coverage", function()
  local mod

  before_each(function()
    mod = ProgressSyncFactory.new({
      Device = require("device"),
    })
  end)

  it("pushCurrentKoreaderProgressDirect returns false when api is nil", function()
    local plugin = {
      api = nil,
      isNetworkConnected = function() return true end,
      progress_sync_enabled = true,
      db = { markKoreaderProgressSynced = function() end },
      logInfo = function() end,
      logWarn = function() end,
      logErr = function() end,
      getCurrentDocumentHashForProgress = function() return "hash" end,
      getCurrentKoreaderSyncProgress = function() return 0.5, "50", "50" end,
      roundKoreaderSyncPercentage = function(_, v) return v end,
      ui = { document = { file = "/p/b.epub" } },
      current_session = { file_hash = "h" },
      progress_sync_device_id = "d1",
      calculateBookHash = function() return "h" end,
    }
    local ok, err = mod.pushCurrentKoreaderProgressDirect(plugin, { book_cache_id = 1, book_hash = "h", percentage = 0.5, progress = "50", location = "50", device = "KOReader", device_id = "d1", timestamp = 100 })
    assert.is_false(ok)
    assert.is_not_nil(err)
  end)

  it("roundKoreaderSyncPercentage clamps correctly", function()
    assert.are.equal(0, mod.roundKoreaderSyncPercentage(nil, -1))
    assert.are.equal(0.5000, mod.roundKoreaderSyncPercentage(nil, 0.5))
    assert.are.equal(1, mod.roundKoreaderSyncPercentage(nil, 1.5))
  end)

  it("roundToInt returns nil for nil", function()
    assert.is_nil(mod.roundToInt(nil, nil))
    assert.are.equal(5, mod.roundToInt(nil, 5.2))
  end)
end)
