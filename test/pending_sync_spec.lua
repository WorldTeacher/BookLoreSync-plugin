local stubs = require("test.helpers.stub_koreader")
local restore_stubs = stubs.install()

local PendingSyncFactory = require("booklore_pending_sync")
restore_stubs()

describe("Pending rating recommendation scheduling", function()
  local PendingSync

  before_each(function()
    PendingSync = PendingSyncFactory.new({
      _ = function(s) return s end,
      T = function(s) return s end,
      json = {
        decode = function() return {} end,
        util = { InitArray = function(arr) return arr end },
      },
      UIManager = {
        scheduleIn = function(_, fn)
          if fn then fn() end
        end,
      },
      InfoMessage = { new = function(_, o) return o or {} end },
      Device = { isTouchDevice = function() return true end },
    })
  end)

  it("schedules recommendations for deferred KOReader-scaled rating sync", function()
    local sync_calls = {}
    local scheduled_book_id
    local clear_calls = {}

    local plugin = {
      db = {
        getBooksPendingRatingPrompt = function()
          return {
            { book_cache_id = 9, book_id = 42, file_path = "/books/finished.epub" },
          }
        end,
        setPendingRatingPrompt = function(_, book_cache_id, flag)
          table.insert(clear_calls, { book_cache_id = book_cache_id, flag = flag })
        end,
        getPendingRatings = function()
          return {}
        end,
      },
      rating_sync_enabled = true,
      rating_sync_mode = "koreader_scaled",
      show_post_rating_recommendations = true,
      booklore_username = "reader",
      booklore_password = "secret",
      syncKOReaderRating = function(_, file_path, book_id)
        table.insert(sync_calls, { file_path = file_path, book_id = book_id })
      end,
      scheduleRecommendationsAfterFinish = function(_, book_id)
        scheduled_book_id = book_id
      end,
      logInfo = function() end,
      logWarn = function() end,
      logErr = function() end,
    }

    local synced, failed = PendingSync.syncPendingRatings(plugin, true)

    assert.are.equal(0, synced)
    assert.are.equal(0, failed)
    assert.are.equal(1, #sync_calls)
    assert.are.equal(42, sync_calls[1].book_id)
    assert.are.equal(42, scheduled_book_id)
    assert.are.same({ { book_cache_id = 9, flag = false } }, clear_calls)
  end)

  it("does not schedule recommendations when feature toggle is disabled", function()
    local scheduled = false

    local plugin = {
      db = {
        getBooksPendingRatingPrompt = function()
          return {
            { book_cache_id = 9, book_id = 42, file_path = "/books/finished.epub" },
          }
        end,
        setPendingRatingPrompt = function() end,
        getPendingRatings = function()
          return {}
        end,
      },
      rating_sync_enabled = true,
      rating_sync_mode = "koreader_scaled",
      show_post_rating_recommendations = false,
      booklore_username = "reader",
      booklore_password = "secret",
      syncKOReaderRating = function() end,
      scheduleRecommendationsAfterFinish = function()
        scheduled = true
      end,
      logInfo = function() end,
      logWarn = function() end,
      logErr = function() end,
    }

    local synced, failed = PendingSync.syncPendingRatings(plugin, true)

    assert.are.equal(0, synced)
    assert.are.equal(0, failed)
    assert.is_false(scheduled)
  end)

  it("keeps deferred sync non-blocking when recommendation scheduling fails", function()
    local warning_logged = false

    local plugin = {
      db = {
        getBooksPendingRatingPrompt = function()
          return {
            { book_cache_id = 9, book_id = 42, file_path = "/books/finished.epub" },
          }
        end,
        setPendingRatingPrompt = function() end,
        getPendingRatings = function()
          return {}
        end,
      },
      rating_sync_enabled = true,
      rating_sync_mode = "koreader_scaled",
      show_post_rating_recommendations = true,
      booklore_username = "reader",
      booklore_password = "secret",
      syncKOReaderRating = function() end,
      scheduleRecommendationsAfterFinish = function()
        error("boom")
      end,
      logInfo = function() end,
      logWarn = function(_, msg)
        if tostring(msg):find("Failed to schedule deferred recommendations", 1, true) then
          warning_logged = true
        end
      end,
      logErr = function() end,
    }

    local synced, failed = PendingSync.syncPendingRatings(plugin, true)

    assert.are.equal(0, synced)
    assert.are.equal(0, failed)
    assert.is_true(warning_logged)
  end)
end)
