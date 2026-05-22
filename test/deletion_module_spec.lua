package.path = table.concat({
  "bookloresync.koplugin/?.lua",
  "bookloresync.koplugin/?/init.lua",
  package.path,
}, ";")

package.preload["logger"] = function()
  return { info = function() end, warn = function() end, err = function() end, dbg = function() end }
end

-- Stubs for deps
local test_json = { encode = function(v) return "{}" end, decode = function(s) return {} end }
test_json.util = { InitArray = function(t) return t end }
local test_UIManager = { show = function() end, close = function() end, scheduleIn = function(_, _, fn) if fn then fn() end end }
local test_ = function(s) return s end

-- Deletion module
local M = require("booklore_deletion_module")
local mod = M.new({ json = test_json, UIManager = test_UIManager })

describe("DeletionModule", function()
  describe("preDeleteHook", function()
    it("returns nil,nil,nil for nil filepath", function()
      local h, s, bid = mod.preDeleteHook(nil, nil)
      assert.is_nil(h)
      assert.is_nil(s)
      assert.is_nil(bid)
    end)

    it("returns nil for non-ebook extension", function()
      local h, s, bid = mod.preDeleteHook(nil, "/tmp/readme.txt")
      assert.is_nil(h)
    end)

    it("matches epub, pdf, cbz, cbr", function()
      local plugin = {
        calculateBookHash = function() return "hash123" end,
        logInfo = function() end,
        logWarn = function() end,
        db = nil,
      }
      local h, s, bid = mod.preDeleteHook(plugin, "/tmp/book.epub")
      assert.are.equal("hash123", h)
      assert.are.equal("book", s)

      h, s, bid = mod.preDeleteHook(plugin, "/tmp/doc.pdf")
      assert.are.equal("doc", s)

      h, s, bid = mod.preDeleteHook(plugin, "/tmp/comic.cbz")
      assert.are.equal("comic", s)

      h, s, bid = mod.preDeleteHook(plugin, "/tmp/comic.cbr")
      assert.are.equal("comic", s)
    end)

    it("looks up book_id from db when available", function()
      local plugin = {
        calculateBookHash = function() return "hash456" end,
        logInfo = function() end,
        logWarn = function() end,
        db = {
          getBookByFilePath = function(_, fp)
            if fp == "/tmp/test.epub" then return { book_id = 42, file_hash = "hash456" } end
            return nil
          end,
        },
      }
      local h, s, bid = mod.preDeleteHook(plugin, "/tmp/test.epub")
      assert.are.equal(42, bid)
    end)

    it("parses book_id from filename when not in db", function()
      local plugin = {
        calculateBookHash = function() return "hash789" end,
        logInfo = function() end,
        logWarn = function() end,
        db = { getBookByFilePath = function() return nil end },
      }
      local h, s, bid = mod.preDeleteHook(plugin, "/tmp/book_123.epub")
      assert.are.equal(123, bid)
    end)

    it("returns nil when hash computation fails", function()
      local plugin = {
        calculateBookHash = function() return nil end,
        logInfo = function() end,
        logWarn = function() end,
        db = nil,
      }
      local h, s, bid = mod.preDeleteHook(plugin, "/tmp/book.epub")
      assert.is_nil(h)
    end)
  end)

  describe("notifyBookloreOnDeletion", function()
    it("returns when plugin is not enabled", function()
      local result = mod.notifyBookloreOnDeletion({ is_enabled = false }, nil, nil, nil)
      assert.is_nil(result)
    end)

    it("returns when credentials are missing", function()
      local result = mod.notifyBookloreOnDeletion({ is_enabled = true, booklore_username = "", booklore_password = "" }, nil, nil, nil)
      assert.is_nil(result)
    end)

    it("returns early for magic-only shelf config", function()
      local plugin = {
        is_enabled = true,
        booklore_username = "u",
        booklore_password = "p",
        booklore_sync_source_type = "magic",
        isNetworkConnected = function() return true end,
        logInfo = function() end,
        logWarn = function() end,
      }
      local result = mod.notifyBookloreOnDeletion(plugin, "hash", "stem", nil)
      assert.is_nil(result)
    end)

    it("queues deletion when offline and not from_queue", function()
      local saved = nil
      local plugin = {
        is_enabled = true,
        booklore_username = "u",
        booklore_password = "p",
        booklore_source_shelf_id = 5,
        shelf_id = 5,
        isNetworkConnected = function() return false end,
        logInfo = function() end,
        logWarn = function() end,
        db = { savePendingDeletion = function(h, s, bid) saved = { h, s, bid } end },
      }
      mod.notifyBookloreOnDeletion(plugin, "hash", "stem", 42)
      assert.is_not_nil(saved)
    end)

    it("handles empty shelf_id gracefully (schedules async)", function()
      local plugin = {
        is_enabled = true,
        booklore_username = "u",
        booklore_password = "p",
        isNetworkConnected = function() return true end,
        logInfo = function() end,
        logWarn = function() end,
        logErr = function() end,
        db = { savePendingDeletion = function() end },
        api = {
          searchBooksWithAuth = function() return true, {} end,
          getOrRefreshBearerToken = function() return true, "token" end,
          request = function() return true, 200, {} end,
        },
      }
      -- Should schedule via UIManager:scheduleIn (runs synchronously in stub)
      local re = mod.notifyBookloreOnDeletion(plugin, "hash", "Book Name", nil)
      assert.is_nil(re)
    end)
  end)
end)
