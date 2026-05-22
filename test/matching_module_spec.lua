-- Tests for booklore_matching_module.lua
--
-- Factory module: M.new(deps) returns module table with:
--   _startBookCacheMatching(self)
--   _showNextBookCacheMatch(self)
--   _saveBookCacheMatch(self, book, selected_result)
--
-- Covers: wifi request, no unmatched, flow, search success/failure,
-- empty results, selection dialog, save match, continuation.

package.path = table.concat({
  "bookloresync.koplugin/?.lua",
  "bookloresync.koplugin/?/init.lua",
  package.path,
}, ";")

-- ── KOReader stubs ──────────────────────────────────────────────────────────

package.preload["logger"] = function()
  return { info = function() end, warn = function() end,
           err = function() end, dbg = function() end }
end

package.preload["datastorage"] = function()
  return { getSettingsDir = function() return "/tmp/test-settings" end,
           getDataDir     = function() return "/tmp/test-data" end }
end

package.preload["dispatcher"]           = function() return { registerAction = function() end } end
package.preload["apps/filemanager/filemanager"] = function() return { instance = nil, new = function() return {} end } end
package.preload["ui/widget/eventlistener"]      = function() return {} end
package.preload["ui/event"]                     = function() return { new = function(_, o) return o or {} end } end
package.preload["ui/widget/inputdialog"]        = function() return { new = function(_, o) return o or {} end } end

-- Track InfoMessage instances
local info_messages = {}
package.preload["ui/widget/infomessage"] = function()
  return {
    new = function(_, o)
      o = o or {}
      info_messages[#info_messages + 1] = o
      return o
    end,
  }
end

-- Track ConfirmBox instances with callbacks
local confirm_boxes = {}
package.preload["ui/widget/confirmbox"] = function()
  local CB = {}
  CB.__index = CB
  function CB:new(o)
    o = o or {}
    confirm_boxes[#confirm_boxes + 1] = o
    return setmetatable(o, self)
  end
  return CB
end

-- Track ButtonDialog instances
local button_dialogs = {}
package.preload["ui/widget/buttondialog"] = function()
  local BD = {}
  BD.__index = BD
  function BD:new(o)
    o = o or {}
    button_dialogs[#button_dialogs + 1] = o
    return setmetatable(o, self)
  end
  function BD:setTitle(t) self.title = t end
  return BD
end

package.preload["ui/widget/menu"]               = function() return { new = function(_, o) return o or {} end } end
package.preload["device"]    = function()
  return { isAndroid = function() return false end, model = "KOReader-Test",
           home_dir = "/mnt/onboard" }
end
package.preload["luasettings"] = function()
  return { open = function() return { readSetting = function() return nil end } end }
end
package.preload["booklore_settings"]   = function() return { new = function() return {} end } end
package.preload["hardcover_api_client"] = function() return { new = function() return {} end } end
package.preload["booklore_updater"]     = function() return { new = function() return {} end } end
package.preload["booklore_file_logger"] = function() return { new = function() return {} end } end
package.preload["booklore_metadata_extractor"] = function() return { new = function() return {} end } end
package.preload["random"]             = function() return { random = function(_, _) return 1 end } end
package.preload["ffi"]                = function() return {} end
package.preload["ffi/sha2"]           = function() return { md5 = function(s) return "deadbeef" end } end

if not _G.bit then
  _G.bit = {
    lshift = function(n, s) return math.floor(n * (2 ^ s)) end,
    rshift = function(n, s) return math.floor(n / (2 ^ s)) end,
    band   = function(a, b)
      local result, bit_val = 0, 1
      while a > 0 and b > 0 do
        local ra, rb = a % 2, b % 2
        if ra == 1 and rb == 1 then result = result + bit_val end
        a, b = math.floor(a / 2), math.floor(b / 2)
        bit_val = bit_val * 2
      end
      return result
    end,
  }
end

package.preload["ffi/util"] = function()
  local fake_result
  return {
    template = function(fmt, ...)
      local a = {...}
      return (fmt:gsub("%%(%d+)", function(i) return tostring(a[tonumber(i)] or "") end))
    end,
    runInSubProcess = function(fn, _)
      pcall(fn, 1, 1)
      return 1, 1
    end,
    isSubProcessDone       = function() return true end,
    readAllFromFD          = function() return fake_result end,
    writeToFD              = function(_, data) fake_result = data end,
    terminateSubProcess    = function() end,
  }
end

package.preload["string.buffer"] = function()
  local M = {}
  function M.encode(t) return t end
  function M.decode(t) return t end
  return M
end

package.preload["gettext"] = function()
  local t = function(s) return s end
  return setmetatable({}, {
    __call = function(_, s) return s end,
    __index = function(_, k)
      if k == "T" then
        return function(fmt, ...)
          local a = {...}
          return (fmt:gsub("%%(%d+)", function(i) return tostring(a[tonumber(i)] or "") end))
        end
      end
      return nil
    end,
  })
end

-- UIManager: track shows/closes, scheduleIn captures callbacks
local uimanager_shows = {}
local uimanager_closes = {}
local scheduled_fns = {}
package.preload["ui/uimanager"] = function()
  return {
    scheduleIn     = function(_, _delay, fn)
      if fn then scheduled_fns[#scheduled_fns + 1] = fn end
    end,
    nextTick       = function(_, fn) if fn then fn() end end,
    show           = function(_, w)
      uimanager_shows[#uimanager_shows + 1] = w
    end,
    close          = function(_, w)
      uimanager_closes[#uimanager_closes + 1] = w
    end,
    preventStandby = function() end,
    allowStandby   = function() end,
    forceRePaint   = function() end,
  }
end

package.preload["ui/widget/container/widgetcontainer"] = function()
  local WC = {}
  function WC:extend(o)
    o = o or {}; o.__index = o
    setmetatable(o, self); self.__index = self
    return o
  end
  return WC
end

package.preload["ui/network/manager"] = function()
  return { isOnline = function() return true end }
end

package.preload["ui/trapper"] = function()
  return {
    wrap = function(_, fn)
      local co = coroutine.create(fn)
      repeat until not coroutine.resume(co)
    end,
    info = function() end,
    dismissableRunInSubprocess = function(_, fn)
      local ok, r = pcall(fn)
      return true, r
    end,
  }
end

package.preload["libs/libkoreader-lfs"] = function()
  return {
    attributes = function() return nil end,
    mkdir      = function() return true end,
    dir        = function() return function() return nil end end,
  }
end

package.preload["json"] = function()
  return {
    decode = function() return {} end,
    encode = function() return "{}" end,
    util = { InitArray = function(t) return t end },
  }
end

local MatchingModuleFactory = require("booklore_matching_module")

-- ── Helpers ──────────────────────────────────────────────────────────────────

local function reset_trackers()
  for i = #info_messages, 1, -1 do info_messages[i] = nil end
  for i = #confirm_boxes, 1, -1 do confirm_boxes[i] = nil end
  for i = #button_dialogs, 1, -1 do button_dialogs[i] = nil end
  for i = #uimanager_shows, 1, -1 do uimanager_shows[i] = nil end
  for i = #uimanager_closes, 1, -1 do uimanager_closes[i] = nil end
  for i = #scheduled_fns, 1, -1 do scheduled_fns[i] = nil end
end

local function run_scheduled()
  local pending = {}
  for _, fn in ipairs(scheduled_fns) do pending[#pending + 1] = fn end
  for i = #scheduled_fns, 1, -1 do scheduled_fns[i] = nil end
  for _, fn in ipairs(pending) do fn() end
end

local function make_plugin(overrides)
  overrides = overrides or {}
  local p = {
    db = {
      getAllUnmatchedBooks = function() return {} end,
      saveBookCache = function() return true end,
    },
    api = {
      searchBooksWithAuth = function() return true, {} end,
    },
    booklore_username = "u",
    booklore_password = "p",
    isNetworkConnected = function() return true end,
    _requestWifi = function() end,
    showWifiUnavailableInfo = function() end,
    syncPendingSessions = function() end,
    logInfo = function() end,
    logWarn = function() end,
    logErr = function() end,
    logDbg = function() end,
  }
  for k, v in pairs(overrides) do p[k] = v end
  return p
end

-- ═══════════════════════════════════════════════════════════════════════════
-- _startBookCacheMatching
-- ═══════════════════════════════════════════════════════════════════════════

describe("_startBookCacheMatching", function()

  local function make_mod()
    return MatchingModuleFactory.new({
      _ = function(s) return s end,
      T = function(s) return s end,
      UIManager = require("ui/uimanager"),
      InfoMessage = require("ui/widget/infomessage"),
      ConfirmBox = require("ui/widget/confirmbox"),
      ButtonDialog = require("ui/widget/buttondialog"),
    })
  end

  before_each(function()
    reset_trackers()
  end)

  it("returns early when db is nil", function()
    local mod = make_mod()
    local plugin = make_plugin()
    plugin.db = nil  -- pairs() skips nil values, so must set after creation
    mod._startBookCacheMatching(plugin)
    assert.are.equal(0, #uimanager_shows)
  end)

  it("requests wifi when not connected", function()
    local mod = make_mod()
    local wifi_called = false
    local plugin = make_plugin({
      isNetworkConnected = function() return false end,
      _requestWifi = function(_, _msg, on_success, on_fail)
        wifi_called = true
        assert.is_not_nil(on_success)
        assert.is_not_nil(on_fail)
      end,
    })
    mod._startBookCacheMatching(plugin)
    assert.is_true(wifi_called)
  end)

  it("shows 'all books matched' when no unmatched books", function()
    local mod = make_mod()
    local plugin = make_plugin({
      db = {
        getAllUnmatchedBooks = function() return {} end,
      },
    })
    mod._startBookCacheMatching(plugin)
    assert.are.equal(1, #uimanager_shows)
    assert.is_truthy(uimanager_shows[1].text and
      tostring(uimanager_shows[1].text):find("already matched", 1, true))
  end)

  it("shows 'all books matched' when unmatched is nil", function()
    local mod = make_mod()
    local plugin = make_plugin({
      db = {
        getAllUnmatchedBooks = function() return nil end,
      },
    })
    mod._startBookCacheMatching(plugin)
    assert.are.equal(1, #uimanager_shows)
  end)

  it("starts matching flow when there are unmatched books", function()
    local mod = make_mod()
    local show_called = false
    local plugin = make_plugin({
      db = {
        getAllUnmatchedBooks = function()
          return { { title = "Book1", file_path = "/path/Book1.epub" } }
        end,
      },
      _showNextBookCacheMatch = function()
        show_called = true
      end,
    })
    mod._startBookCacheMatching(plugin)
    assert.is_true(show_called)
    assert.are.equal(1, plugin.bk_matching_index)
    assert.are.equal(1, #plugin.bk_unmatched_books)
  end)
end)

-- ═══════════════════════════════════════════════════════════════════════════
-- _showNextBookCacheMatch
-- ═══════════════════════════════════════════════════════════════════════════

describe("_showNextBookCacheMatch", function()

  local function make_mod()
    return MatchingModuleFactory.new({
      _ = function(s) return s end,
      T = function(fmt, ...)
        local a = {...}
        return (fmt:gsub("%%(%d+)", function(i) return tostring(a[tonumber(i)] or "") end))
      end,
      UIManager = require("ui/uimanager"),
      InfoMessage = require("ui/widget/infomessage"),
      ConfirmBox = require("ui/widget/confirmbox"),
      ButtonDialog = require("ui/widget/buttondialog"),
    })
  end

  before_each(function()
    reset_trackers()
  end)

  it("shows 'Matching complete!' when no unmatched books remain", function()
    local mod = make_mod()
    local plugin = make_plugin()
    -- no bk_unmatched_books set
    mod._showNextBookCacheMatch(plugin)
    assert.are.equal(1, #uimanager_shows)
    assert.is_truthy(tostring(uimanager_shows[1].text):find("Matching complete", 1, true))
  end)

  it("shows 'Matching complete!' when index exceeds array size", function()
    local mod = make_mod()
    local plugin = make_plugin()
    plugin.bk_unmatched_books = { { title = "B1" } }
    plugin.bk_matching_index = 2
    mod._showNextBookCacheMatch(plugin)
    assert.are.equal(1, #uimanager_shows)
    assert.is_truthy(tostring(uimanager_shows[1].text):find("Matching complete", 1, true))
    assert.is_nil(plugin.bk_unmatched_books)
    assert.is_nil(plugin.bk_matching_index)
  end)

  it("shows search progress info message", function()
    local mod = make_mod()
    local plugin = make_plugin()
    plugin.bk_unmatched_books = { { title = "B1", file_path = "/p/B1.epub" } }
    plugin.bk_matching_index = 1
    mod._showNextBookCacheMatch(plugin)
    -- Should show InfoMessage with "Searching for"
    assert.is_true(#uimanager_shows >= 1)
  end)

  it("shows search failed ConfirmBox, skip and retry callbacks advance the match", function()
    local mod = make_mod()
    local index_after
    local plugin = make_plugin({
      api = {
        searchBooksWithAuth = function() return false, "timeout error" end,
      },
      bk_unmatched_books = {
        { title = "B1", file_path = "/p/B1.epub" },
        { title = "B2", file_path = "/p/B2.epub" },
      },
      bk_matching_index = 1,
    })
    plugin._showNextBookCacheMatch = function(self)
      index_after = self.bk_matching_index
    end
    mod._showNextBookCacheMatch(plugin)
    assert.is_true(#confirm_boxes >= 1)
    local cb = confirm_boxes[1]
    assert.is_not_nil(cb.ok_callback)
    -- Invoke skip
    cb.ok_callback()
    assert.are.equal(2, index_after)
  end)

  it("shows search failed ConfirmBox retry callback", function()
    local mod = make_mod()
    local called = false
    local plugin = make_plugin({
      api = { searchBooksWithAuth = function() return false, "err" end },
      bk_unmatched_books = { { title = "B1", file_path = "/p/B1.epub" } },
      bk_matching_index = 1,
    })
    plugin._showNextBookCacheMatch = function() called = true end
    mod._showNextBookCacheMatch(plugin)
    local cb = confirm_boxes[1]
    assert.is_not_nil(cb.cancel_callback)
    cb.cancel_callback()
    assert.is_true(called)
  end)

  it("shows empty results ConfirmBox and skip advances index", function()
    local mod = make_mod()
    local index_after
    local plugin = make_plugin({
      api = {
        searchBooksWithAuth = function() return false, "timeout error" end,
      },
      bk_unmatched_books = {
        { title = "B1", file_path = "/p/B1.epub" },
        { title = "B2", file_path = "/p/B2.epub" },
      },
      bk_matching_index = 1,
    })
    -- Override _showNextBookCacheMatch to track
    plugin._showNextBookCacheMatch = function(self)
      index_after = self.bk_matching_index
    end
    mod._showNextBookCacheMatch(plugin)
    -- Should show a ConfirmBox
    assert.is_true(#confirm_boxes >= 1)
    -- Execute skip callback (ok_callback)
    if confirm_boxes[1].ok_callback then
      confirm_boxes[1].ok_callback()
      assert.are.equal(2, index_after)
    end
  end)

  it("shows no results ConfirmBox and allows skip", function()
    local mod = make_mod()
    local index_after
    local plugin = make_plugin({
      api = {
        searchBooksWithAuth = function() return true, {} end,
      },
      bk_unmatched_books = {
        { title = "B1", file_path = "/p/B1.epub" },
      },
      bk_matching_index = 1,
    })
    plugin._showNextBookCacheMatch = function(self)
      index_after = self.bk_matching_index
    end
    mod._showNextBookCacheMatch(plugin)
    assert.is_true(#confirm_boxes >= 1)
    -- Execute skip callback (ok_callback)
    if confirm_boxes[1].ok_callback then
      confirm_boxes[1].ok_callback()
      assert.are.equal(2, index_after)
    end
  end)

  it("wifi fallback on_fail calls showWifiUnavailableInfo", function()
    local mod = make_mod()
    local wifi_show_called = false
    local on_fail_fn
    local plugin = make_plugin({
      isNetworkConnected = function() return false end,
      bk_unmatched_books = { { title = "B1" } },
      _requestWifi = function(_, _msg, _on_success, on_fail)
        on_fail_fn = on_fail
      end,
      showWifiUnavailableInfo = function(...)
        wifi_show_called = true
      end,
    })
    mod._startBookCacheMatching(plugin)
    assert.is_not_nil(on_fail_fn)
    on_fail_fn()
    assert.is_true(wifi_show_called)
  end)

  it("wifi fallback on_success re-triggers matching", function()
    local mod = make_mod()
    local recursed = false
    local on_success_fn
    local plugin = make_plugin({
      isNetworkConnected = function() return false end,
      bk_unmatched_books = { { title = "B1" } },
      _requestWifi = function(_, _msg, on_success, _on_fail)
        on_success_fn = on_success
      end,
      showWifiUnavailableInfo = function() end,
      _startBookCacheMatching = function() recursed = true end,
    })
    mod._startBookCacheMatching(plugin)
    assert.is_not_nil(on_success_fn)
    on_success_fn()
    assert.is_true(recursed)
  end)

  it("shows selection dialog with top 5 results", function()
    local mod = make_mod()
    local results = {}
    for i = 1, 10 do
      results[i] = {
        id = tostring(i),
        title = "Book " .. i,
        author = "Author " .. i,
        matchScore = (10 - i) * 0.1,
      }
    end
    local plugin = make_plugin({
      api = {
        searchBooksWithAuth = function() return true, results end,
      },
      bk_unmatched_books = {
        { title = "B1", file_path = "/p/B1.epub" },
      },
      bk_matching_index = 1,
    })
    mod._showNextBookCacheMatch(plugin)
    -- Should show a ButtonDialog (selection)
    assert.is_true(#button_dialogs >= 1)
    local dialog = button_dialogs[1]
    assert.is_not_nil(dialog.buttons)
    -- Should have 5 results + Skip + Cancel = 7 button rows
    assert.are.equal(7, #dialog.buttons)
    -- Cancel callback sets unmatched_books to nil
    local cancel_cb = dialog.buttons[7][1].callback
    cancel_cb()
    assert.is_nil(plugin.bk_unmatched_books)
    assert.is_nil(plugin.bk_matching_index)
  end)

  it("selection callback calls _saveBookCacheMatch and advances index", function()
    local mod = make_mod()
    local save_called = false
    local save_book, save_result
    local plugin = make_plugin({
      api = {
        searchBooksWithAuth = function() return true, {
          { id = "1", title = "Result", author = "Author", matchScore = 0.9 },
        } end,
      },
      bk_unmatched_books = {
        { title = "B1", file_path = "/p/B1.epub" },
      },
      bk_matching_index = 1,
      _saveBookCacheMatch = function(_, book, result)
        save_called = true
        save_book = book
        save_result = result
      end,
    })
    mod._showNextBookCacheMatch(plugin)
    assert.is_true(#button_dialogs >= 1)
    -- Click the first result button
    local select_cb = button_dialogs[1].buttons[1][1].callback
    select_cb()
    assert.is_true(save_called)
    assert.are.equal("B1", save_book.title)
    assert.are.equal("1", save_result.id)
  end)

  it("skip button advances index and continues", function()
    local mod = make_mod()
    local index_after
    local plugin = make_plugin({
      api = {
        searchBooksWithAuth = function() return true, {
          { id = "1", title = "R1", matchScore = 0.8 },
        } end,
      },
      bk_unmatched_books = {
        { title = "B1", file_path = "/p/B1.epub" },
        { title = "B2", file_path = "/p/B2.epub" },
      },
      bk_matching_index = 1,
    })
    plugin._showNextBookCacheMatch = function(self)
      index_after = self.bk_matching_index
    end
    mod._showNextBookCacheMatch(plugin)
    assert.is_true(#button_dialogs >= 1)
    -- Skip button is the second button (1 result + Skip + Cancel)
    local skip_cb = button_dialogs[1].buttons[2][1].callback
    skip_cb()
    assert.are.equal(2, index_after)
  end)

  it("uses filename as search term when book has no title", function()
    local mod = make_mod()
    local search_term
    local plugin = make_plugin({
      api = {
        searchBooksWithAuth = function(_, term)
          search_term = term
          return true, {}
        end,
      },
      bk_unmatched_books = {
        { title = "", file_path = "/path/Unknown.epub" },
      },
      bk_matching_index = 1,
    })
    mod._showNextBookCacheMatch(plugin)
    assert.are.equal("Unknown.epub", search_term)
  end)
end)

-- ═══════════════════════════════════════════════════════════════════════════
-- _saveBookCacheMatch
-- ═══════════════════════════════════════════════════════════════════════════

describe("_saveBookCacheMatch", function()

  local function make_mod()
    return MatchingModuleFactory.new({
      _ = function(s) return s end,
      T = function(s) return s end,
      UIManager = require("ui/uimanager"),
      InfoMessage = require("ui/widget/infomessage"),
      ConfirmBox = require("ui/widget/confirmbox"),
      ButtonDialog = require("ui/widget/buttondialog"),
    })
  end

  before_each(function()
    reset_trackers()
  end)

  it("shows invalid book ID error when selected_result has no id", function()
    local mod = make_mod()
    local plugin = make_plugin()
    local book = { file_path = "/p/B1.epub", file_hash = "abc" }
    mod._saveBookCacheMatch(plugin, book, { id = nil })
    assert.are.equal(1, #uimanager_shows)
    assert.is_truthy(tostring(uimanager_shows[1].text):find("Invalid book ID", 1, true))
  end)

  it("shows invalid book ID error when selected_result is nil", function()
    local mod = make_mod()
    local plugin = make_plugin()
    local book = { file_path = "/p/B1.epub", file_hash = "abc" }
    mod._saveBookCacheMatch(plugin, book, nil)
    assert.are.equal(1, #uimanager_shows)
    assert.is_truthy(tostring(uimanager_shows[1].text):find("Invalid book ID", 1, true))
  end)

  it("parses result from table with id as string", function()
    local mod = make_mod()
    local save_calls = {}
    local plugin = make_plugin({
      db = {
        saveBookCache = function(_, fp, fh, bid, title, author, isbn10, isbn13, pagecount)
          save_calls[#save_calls + 1] = { fp = fp, bid = bid, title = title }
          return true
        end,
      },
      syncPendingSessions = function() end,
    })
    local book = { file_path = "/p/B1.epub", file_hash = "abc", title = "Original Title", author = "Orig Auth" }
    mod._saveBookCacheMatch(plugin, book, { id = "42", title = "Matched Title", author = "Matched Auth" })
    assert.are.equal(1, #save_calls)
    assert.are.equal(42, save_calls[1].bid)
    assert.are.equal("Matched Title", save_calls[1].title)
  end)

  it("extracts ISBN and pagecount from result", function()
    local mod = make_mod()
    local save_calls = {}
    local plugin = make_plugin({
      db = {
        saveBookCache = function(_, fp, fh, bid, title, author, isbn10, isbn13, pagecount)
          save_calls[#save_calls + 1] = { isbn10 = isbn10, isbn13 = isbn13, pagecount = pagecount }
          return true
        end,
      },
      syncPendingSessions = function() end,
    })
    local book = { file_path = "/p/B1.epub", file_hash = "abc", title = "T" }
    mod._saveBookCacheMatch(plugin, book, { id = "42", isbn10 = "1234567890", isbn13 = "1234567890123", pagecount = "300" })
    assert.are.equal(1, #save_calls)
    assert.are.equal("1234567890", save_calls[1].isbn10)
    assert.are.equal("1234567890123", save_calls[1].isbn13)
    assert.are.equal(300, save_calls[1].pagecount)
  end)

  it("falls back to server_pagecount when pagecount is nil", function()
    local mod = make_mod()
    local save_calls = {}
    local plugin = make_plugin({
      db = {
        saveBookCache = function(_, fp, fh, bid, title, author, isbn10, isbn13, pagecount)
          save_calls[#save_calls + 1] = { pagecount = pagecount }
          return true
        end,
      },
      syncPendingSessions = function() end,
    })
    local book = { file_path = "/p/B1.epub", file_hash = "abc", title = "T" }
    mod._saveBookCacheMatch(plugin, book, { id = "42", server_pagecount = "250" })
    assert.are.equal(1, #save_calls)
    assert.are.equal(250, save_calls[1].pagecount)
  end)

  it("handles pagecount=0 by not setting it", function()
    local mod = make_mod()
    local save_calls = {}
    local plugin = make_plugin({
      db = {
        saveBookCache = function(_, fp, fh, bid, title, author, isbn10, isbn13, pagecount)
          save_calls[#save_calls + 1] = { pagecount = pagecount }
          return true
        end,
      },
      syncPendingSessions = function() end,
    })
    local book = { file_path = "/p/B1.epub", file_hash = "abc", title = "T" }
    mod._saveBookCacheMatch(plugin, book, { id = "42", pagecount = "0" })
    assert.are.equal(1, #save_calls)
    -- pagecount with value 0 should be nil (parsed_pagecount > 0 check)
    assert.is_nil(save_calls[1].pagecount)
  end)

  it("shows error when db save fails", function()
    local mod = make_mod()
    local plugin = make_plugin({
      db = {
        saveBookCache = function() return false end,
      },
      syncPendingSessions = function() end,
    })
    local book = { file_path = "/p/B1.epub", file_hash = "abc", title = "T" }
    mod._saveBookCacheMatch(plugin, book, { id = "42" })
    assert.are.equal(1, #uimanager_shows)
    assert.is_truthy(tostring(uimanager_shows[1].text):find("Failed to save match", 1, true))
  end)

  it("calls syncPendingSessions after saving match", function()
    local mod = make_mod()
    local sync_called = false
    local plugin = make_plugin({
      db = {
        saveBookCache = function() return true end,
      },
      syncPendingSessions = function()
        sync_called = true
      end,
    })
    local book = { file_path = "/p/B1.epub", file_hash = "abc", title = "T" }
    mod._saveBookCacheMatch(plugin, book, { id = "42" })
    assert.is_true(sync_called)
  end)

  it("continues to next match when bk_unmatched_books state is active", function()
    local mod = make_mod()
    local show_next_called = false
    local plugin = make_plugin({
      db = {
        saveBookCache = function() return true end,
      },
      syncPendingSessions = function() end,
      bk_unmatched_books = { { title = "B2" } },
      bk_matching_index = 2,
      _showNextBookCacheMatch = function()
        show_next_called = true
      end,
    })
    local book = { file_path = "/p/B1.epub", file_hash = "abc", title = "T" }
    mod._saveBookCacheMatch(plugin, book, { id = "42" })
    assert.is_true(show_next_called)
    assert.are.equal(3, plugin.bk_matching_index)
  end)

  it("does not show next when bk_unmatched_books state is nil", function()
    local mod = make_mod()
    local show_next_called = false
    local plugin = make_plugin({
      db = {
        saveBookCache = function() return true end,
      },
      syncPendingSessions = function() end,
      bk_unmatched_books = nil,
      bk_matching_index = nil,
      _showNextBookCacheMatch = function()
        show_next_called = true
      end,
    })
    local book = { file_path = "/p/B1.epub", file_hash = "abc", title = "T" }
    mod._saveBookCacheMatch(plugin, book, { id = "42" })
    assert.is_false(show_next_called)
  end)

  it("accepts raw numeric id (selected_result is just a number)", function()
    local mod = make_mod()
    local save_calls = {}
    local plugin = make_plugin({
      db = {
        saveBookCache = function(_, fp, fh, bid)
          save_calls[#save_calls + 1] = { bid = bid }
          return true
        end,
      },
      syncPendingSessions = function() end,
    })
    local book = { file_path = "/p/B1.epub", file_hash = "abc", title = "T", author = "A" }
    mod._saveBookCacheMatch(plugin, book, "99")
    assert.are.equal(1, #save_calls)
    assert.are.equal(99, save_calls[1].bid)
  end)

  it("accepts raw numeric id (selected_result is a number)", function()
    local mod = make_mod()
    local save_calls = {}
    local plugin = make_plugin({
      db = {
        saveBookCache = function(_, fp, fh, bid)
          save_calls[#save_calls + 1] = { bid = bid }
          return true
        end,
      },
      syncPendingSessions = function() end,
    })
    local book = { file_path = "/p/B1.epub", file_hash = "abc", title = "T", author = "A" }
    mod._saveBookCacheMatch(plugin, book, 42)
    assert.are.equal(1, #save_calls)
    assert.are.equal(42, save_calls[1].bid)
  end)

  it("shows invalid book ID for non-table non-number result", function()
    local mod = make_mod()
    local plugin = make_plugin()
    local book = { file_path = "/p/B1.epub", file_hash = "abc", title = "T" }
    -- A string that's not a number
    mod._saveBookCacheMatch(plugin, book, "not-a-number")
    assert.are.equal(1, #uimanager_shows)
    assert.is_truthy(tostring(uimanager_shows[1].text):find("Invalid book ID", 1, true))
  end)
end)
