-- Tests for booklore_progress_sync.lua
--
-- Factory module: M.new(deps) returns module table with:
--   roundKoreaderSyncPercentage, roundToInt, getCurrentKoreaderSyncProgress,
--   getCurrentDocumentHashForProgress, buildCurrentKoreaderProgressPayload,
--   pushCurrentKoreaderProgressDirect
--
-- Covers: paged vs rolling document, session hash, db cache, computed hash,
-- disabled progress sync, missing document, missing hash, validation,
-- network check, API call, db save.

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
package.preload["ui/widget/infomessage"]        = function() return { new = function(_, o) return o or {} end } end
package.preload["ui/widget/confirmbox"]         = function() return { new = function(_, o) return o or {} end } end
package.preload["ui/widget/buttondialog"] = function()
  local BD = {}
  BD.__index = BD
  function BD:new(o) o = o or {}; return setmetatable(o, self) end
  function BD:setTitle(t) self.title = t end
  return BD
end
package.preload["ui/widget/menu"]               = function() return { new = function(_, o) return o or {} end } end
package.preload["ui/network/manager"]           = function() return { isOnline = function() return true end, isConnected = function() return true end } end
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

package.preload["ui/uimanager"] = function()
  return {
    scheduleIn     = function() end,
    nextTick       = function() end,
    show           = function() end,
    close          = function() end,
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

-- ── Load the module factory ─────────────────────────────────────────────────

local ProgressSyncFactory = require("booklore_progress_sync")

-- ── Helpers ──────────────────────────────────────────────────────────────────

local function make_plugin(overrides)
  overrides = overrides or {}
  local p = {
    ui = nil,
    db = nil,
    api = nil,
    current_session = nil,
    progress_sync_enabled = true,
    progress_sync_device_id = "device-001",
    isNetworkConnected = function() return true end,
    calculateBookHash = function() return "computed-hash" end,
    roundKoreaderSyncPercentage = function(_, val)
      local n = tonumber(val) or 0
      if n < 0 then n = 0 end
      if n > 1 then n = 1 end
      return math.floor(n * 10000 + 0.5) / 10000
    end,
    logInfo = function() end,
    logWarn = function() end,
    logErr = function() end,
    getCurrentDocumentHashForProgress = function() return "test-book-hash" end,
    getCurrentKoreaderSyncProgress = function()
      return 0.5, "50", "50"
    end,
  }
  for k, v in pairs(overrides) do p[k] = v end
  return p
end

-- ═══════════════════════════════════════════════════════════════════════════
-- roundKoreaderSyncPercentage
-- ═══════════════════════════════════════════════════════════════════════════

describe("roundKoreaderSyncPercentage", function()

  local function make_mod()
    return ProgressSyncFactory.new({
      Device = require("device"),
    })
  end

  it("rounds 0.5 to 0.5", function()
    local mod = make_mod()
    assert.are.equal(0.5, mod.roundKoreaderSyncPercentage(nil, 0.5))
  end)

  it("clamps negative values to 0", function()
    local mod = make_mod()
    assert.are.equal(0, mod.roundKoreaderSyncPercentage(nil, -0.5))
  end)

  it("clamps values > 1 to 1", function()
    local mod = make_mod()
    assert.are.equal(1, mod.roundKoreaderSyncPercentage(nil, 1.5))
  end)

  it("rounds to 4 decimal places", function()
    local mod = make_mod()
    local result = mod.roundKoreaderSyncPercentage(nil, 0.12345678)
    assert.are.equal(0.1235, result)
  end)

  it("handles nil input as 0", function()
    local mod = make_mod()
    assert.are.equal(0, mod.roundKoreaderSyncPercentage(nil, nil))
  end)

  it("handles string input", function()
    local mod = make_mod()
    assert.are.equal(0.5, mod.roundKoreaderSyncPercentage(nil, "0.5"))
  end)

  it("returns 0 for non-numeric string", function()
    local mod = make_mod()
    assert.are.equal(0, mod.roundKoreaderSyncPercentage(nil, "abc"))
  end)
end)

-- ═══════════════════════════════════════════════════════════════════════════
-- roundToInt
-- ═══════════════════════════════════════════════════════════════════════════

describe("roundToInt", function()

  local function make_mod()
    return ProgressSyncFactory.new({
      Device = require("device"),
    })
  end

  it("rounds 0.5 to 1", function()
    local mod = make_mod()
    assert.are.equal(1, mod.roundToInt(nil, 0.5))
  end)

  it("rounds 0.4 to 0", function()
    local mod = make_mod()
    assert.are.equal(0, mod.roundToInt(nil, 0.4))
  end)

  it("returns nil for nil input", function()
    local mod = make_mod()
    assert.is_nil(mod.roundToInt(nil, nil))
  end)

  it("returns nil for non-numeric string", function()
    local mod = make_mod()
    assert.is_nil(mod.roundToInt(nil, "abc"))
  end)

  it("parses numeric string", function()
    local mod = make_mod()
    assert.are.equal(5, mod.roundToInt(nil, "4.6"))
  end)
end)

-- ═══════════════════════════════════════════════════════════════════════════
-- getCurrentKoreaderSyncProgress
-- ═══════════════════════════════════════════════════════════════════════════

describe("getCurrentKoreaderSyncProgress", function()

  local function make_mod()
    return ProgressSyncFactory.new({
      Device = require("device"),
    })
  end

  it("returns 0 / '0' / '0' when no ui is set", function()
    local mod = make_mod()
    local plugin = make_plugin()
    local pct, prog, loc = mod.getCurrentKoreaderSyncProgress(plugin)
    assert.are.equal(0, pct)
    assert.are.equal("0", prog)
    assert.are.equal("0", loc)
  end)

  it("reads from paged document (has_pages = true)", function()
    local mod = make_mod()
    local plugin = make_plugin({
      ui = {
        document = {
          info = { has_pages = true },
        },
        paging = {
          getLastPercent = function() return 0.75 end,
          getLastProgress = function() return "75" end,
        },
      },
    })
    local pct, prog, loc = mod.getCurrentKoreaderSyncProgress(plugin)
    assert.are.equal(0.75, pct)
    assert.are.equal("75", prog)
  end)

  it("reads from rolling document", function()
    local mod = make_mod()
    local plugin = make_plugin({
      ui = {
        document = {
          info = { has_pages = false },
        },
        rolling = {
          getLastPercent = function() return 0.5 end,
          getLastProgress = function() return "50" end,
        },
      },
    })
    local pct, prog, loc = mod.getCurrentKoreaderSyncProgress(plugin)
    assert.are.equal(0.5, pct)
    assert.are.equal("50", prog)
  end)

  it("uses xpointer for rolling document progress_value when available", function()
    local mod = make_mod()
    local plugin = make_plugin({
      ui = {
        document = {
          info = { has_pages = false },
          getXPointer = function() return "/6/2/1" end,
        },
        rolling = {
          getLastPercent = function() return 0.6 end,
          getLastProgress = function() return "60" end,
        },
      },
    })
    local pct, prog, loc = mod.getCurrentKoreaderSyncProgress(plugin)
    assert.are.equal(0.6, pct)
    assert.are.equal("/6/2/1", prog)
    assert.are.equal("/6/2/1", loc)
  end)

  it("reads xpointer from doc_settings as fallback", function()
    local mod = make_mod()
    local plugin = make_plugin({
      ui = {
        document = {
          info = { has_pages = false },
          -- no getXPointer
        },
        doc_settings = {
          readSetting = function(_, key)
            if key == "last_xpointer" then return "/3/1" end
            return nil
          end,
        },
        rolling = {
          getLastPercent = function() return 0.3 end,
          getLastProgress = function() return "30" end,
        },
      },
    })
    local pct, prog, loc = mod.getCurrentKoreaderSyncProgress(plugin)
    assert.are.equal(0.3, pct)
    assert.are.equal("/3/1", prog)
  end)

  it("handles paging getLastPercent returning nil", function()
    local mod = make_mod()
    local plugin = make_plugin({
      ui = {
        document = { info = { has_pages = true } },
        paging = {
          getLastPercent = function() return nil end,
          getLastProgress = function() return "80" end,
        },
      },
    })
    local pct, prog = mod.getCurrentKoreaderSyncProgress(plugin)
    assert.are.equal(0, pct)
    assert.are.equal("80", prog)
  end)

  it("handles rolling with nil methods gracefully", function()
    local mod = make_mod()
    local plugin = make_plugin({
      ui = {
        document = { info = { has_pages = false } },
        rolling = {},
      },
    })
    local pct, prog, loc = mod.getCurrentKoreaderSyncProgress(plugin)
    assert.are.equal(0, pct)
    assert.are.equal("0", prog)
  end)
end)

-- ═══════════════════════════════════════════════════════════════════════════
-- getCurrentDocumentHashForProgress
-- ═══════════════════════════════════════════════════════════════════════════

describe("getCurrentDocumentHashForProgress", function()

  local function make_mod()
    return ProgressSyncFactory.new({
      Device = require("device"),
    })
  end

  it("returns nil when no document is open", function()
    local mod = make_mod()
    local plugin = make_plugin()
    local hash = mod.getCurrentDocumentHashForProgress(plugin)
    assert.is_nil(hash)
  end)

  it("returns session hash when available", function()
    local mod = make_mod()
    local plugin = make_plugin({
      ui = {
        document = { file = "/path/book.epub" },
      },
      current_session = {
        file_hash = "session-hash-123",
      },
    })
    local hash = mod.getCurrentDocumentHashForProgress(plugin)
    assert.are.equal("session-hash-123", hash)
  end)

  it("returns hash from db cache when no session hash", function()
    local mod = make_mod()
    local plugin = make_plugin({
      ui = {
        document = { file = "/path/book.epub" },
      },
      current_session = {},
      db = {
        getBookByFilePath = function() return { file_hash = "db-hash-456" } end,
      },
    })
    local hash = mod.getCurrentDocumentHashForProgress(plugin)
    assert.are.equal("db-hash-456", hash)
  end)

  it("computes hash via calculateBookHash when not cached", function()
    local mod = make_mod()
    local save_calls = {}
    local plugin = make_plugin({
      ui = {
        document = { file = "/path/book.epub" },
      },
      current_session = {},
      db = {
        getBookByFilePath = function() return { title = "Book", author = "Auth" } end,
        saveBookCache = function(_, fp, hash, bid, title, author)
          save_calls[#save_calls + 1] = { fp = fp, hash = hash, bid = bid }
        end,
      },
      calculateBookHash = function() return "computed-hash-789" end,
    })
    local hash = mod.getCurrentDocumentHashForProgress(plugin)
    assert.are.equal("computed-hash-789", hash)
    assert.are.equal(1, #save_calls)
  end)

  it("returns nil when calculateBookHash also fails", function()
    local mod = make_mod()
    local plugin = make_plugin({
      ui = {
        document = { file = "/path/book.epub" },
      },
      current_session = {},
      db = {
        getBookByFilePath = function() return nil end,
      },
      calculateBookHash = function() return nil end,
    })
    local hash = mod.getCurrentDocumentHashForProgress(plugin)
    assert.is_nil(hash)
  end)

  it("returns nil when computed hash is empty", function()
    local mod = make_mod()
    local plugin = make_plugin({
      ui = {
        document = { file = "/path/book.epub" },
      },
      current_session = {},
      db = {
        getBookByFilePath = function() return nil end,
      },
      calculateBookHash = function() return "" end,
    })
    local hash = mod.getCurrentDocumentHashForProgress(plugin)
    assert.is_nil(hash)
  end)

  it("does not save to db when db is nil even with computed hash", function()
    local mod = make_mod()
    local plugin = make_plugin({
      ui = {
        document = { file = "/path/book.epub" },
      },
      current_session = {},
      db = nil,
      calculateBookHash = function() return "computed" end,
    })
    local hash = mod.getCurrentDocumentHashForProgress(plugin)
    assert.are.equal("computed", hash)
  end)
end)

-- ═══════════════════════════════════════════════════════════════════════════
-- buildCurrentKoreaderProgressPayload
-- ═══════════════════════════════════════════════════════════════════════════

describe("buildCurrentKoreaderProgressPayload", function()

  local function make_mod()
    return ProgressSyncFactory.new({
      Device = require("device"),
    })
  end

  it("returns nil, error when progress_sync_enabled is false", function()
    local mod = make_mod()
    local plugin = make_plugin({ progress_sync_enabled = false })
    local payload, err = mod.buildCurrentKoreaderProgressPayload(plugin)
    assert.is_nil(payload)
    assert.is_not_nil(err)
    assert.is_truthy(err:find("disabled", 1, true))
  end)

  it("returns nil, error when no open document", function()
    local mod = make_mod()
    local plugin = make_plugin()
    local payload, err = mod.buildCurrentKoreaderProgressPayload(plugin)
    assert.is_nil(payload)
    assert.is_not_nil(err)
    assert.is_truthy(err:find("No open document", 1, true))
  end)

  it("returns nil, error when no document file path", function()
    local mod = make_mod()
    local plugin = make_plugin({
      ui = { document = { file = "" } },
    })
    local payload, err = mod.buildCurrentKoreaderProgressPayload(plugin)
    assert.is_nil(payload)
    assert.is_not_nil(err)
    assert.is_truthy(err:find("No open document", 1, true))
  end)

  it("returns nil, error when hash is missing", function()
    local mod = make_mod()
    local plugin = make_plugin()
    plugin.ui = { document = { file = "/path/book.epub" } }
    plugin.current_session = {}
    plugin.db = nil
    plugin.calculateBookHash = function() return nil end
    -- Override to simulate hash not found
    plugin.getCurrentDocumentHashForProgress = function() return nil end
    local payload, err = mod.buildCurrentKoreaderProgressPayload(plugin)
    assert.is_nil(payload)
    assert.is_not_nil(err)
    assert.is_truthy(err:find("Missing book hash", 1, true))
  end)

  it("builds valid payload with all fields", function()
    local mod = make_mod()
    local plugin = make_plugin({
      ui = {
        document = { file = "/path/book.epub" },
        paging = {
          getLastPercent = function() return 0.42 end,
          getLastProgress = function() return "42" end,
        },
        info = { has_pages = true },
      },
      current_session = {
        file_hash = "session-hash",
      },
      db = {
        getBookCacheIdByFilePath = function() return 99 end,
      },
    })
    local payload, err = mod.buildCurrentKoreaderProgressPayload(plugin)
    assert.is_nil(err)
    assert.is_not_nil(payload)
    assert.are.equal("test-book-hash", payload.document)
    assert.are.equal(0.5, payload.percentage)
    assert.are.equal("50", payload.progress)
    assert.are.equal("KOReader-Test", payload.device)
    assert.are.equal("device-001", payload.device_id)
    assert.are.equal(99, payload.book_cache_id)
    assert.is_not_nil(payload.timestamp)
  end)

  it("uses os.time as default timestamp when none provided", function()
    local mod = make_mod()
    local plugin = make_plugin({
      ui = {
        document = { file = "/path/book.epub" },
      },
      current_session = { file_hash = "h" },
    })
    local payload = mod.buildCurrentKoreaderProgressPayload(plugin)
    assert.are.equal(os.time(), payload.timestamp)
  end)

  it("uses the provided timestamp", function()
    local mod = make_mod()
    local plugin = make_plugin({
      ui = {
        document = { file = "/path/book.epub" },
      },
      current_session = { file_hash = "h" },
    })
    local payload = mod.buildCurrentKoreaderProgressPayload(plugin, 12345)
    assert.are.equal(12345, payload.timestamp)
  end)

  it("uses 'unknown' device_id when progress_sync_device_id is not set", function()
    local mod = make_mod()
    local plugin = make_plugin()
    plugin.ui = { document = { file = "/path/book.epub" } }
    plugin.current_session = { file_hash = "h" }
    plugin.progress_sync_device_id = nil  -- pairs() skips nil, so set after creation
    local payload = mod.buildCurrentKoreaderProgressPayload(plugin)
    assert.are.equal("unknown", payload.device_id)
  end)
end)

-- ═══════════════════════════════════════════════════════════════════════════
-- pushCurrentKoreaderProgressDirect
-- ═══════════════════════════════════════════════════════════════════════════

describe("pushCurrentKoreaderProgressDirect", function()

  local function make_mod()
    return ProgressSyncFactory.new({
      Device = require("device"),
    })
  end

  local function make_plugin(overrides)
    overrides = overrides or {}
    local p = {
      api = {
        updateKoReaderProgress = function() return true, "ok" end,
      },
      db = {
        markKoreaderProgressSynced = function() end,
      },
      isNetworkConnected = function() return true end,
      logInfo = function() end,
      logWarn = function() end,
      logErr = function() end,
    }
    for k, v in pairs(overrides) do p[k] = v end
    return p
  end

  it("returns false, error when payload is not a table", function()
    local mod = make_mod()
    local plugin = make_plugin()
    local ok, err = mod.pushCurrentKoreaderProgressDirect(plugin, "not-a-table")
    assert.is_false(ok)
    assert.is_not_nil(err)
  end)

  it("returns false, error when api is nil", function()
    local mod = make_mod()
    local plugin = make_plugin()
    plugin.api = nil  -- pairs() skips nil, must set after creation
    local ok, err = mod.pushCurrentKoreaderProgressDirect(plugin, {})
    assert.is_false(ok)
    assert.is_not_nil(err)
    assert.is_truthy(err:find("API client not initialized", 1, true))
  end)

  it("returns false, error when network is not connected", function()
    local mod = make_mod()
    local plugin = make_plugin({ isNetworkConnected = function() return false end })
    local ok, err = mod.pushCurrentKoreaderProgressDirect(plugin, {})
    assert.is_false(ok)
    assert.is_not_nil(err)
    assert.is_truthy(err:find("WiFi is not connected", 1, true))
  end)

  it("returns false, error when API call fails", function()
    local mod = make_mod()
    local plugin = make_plugin({
      api = {
        updateKoReaderProgress = function() return false, "api error" end,
      },
    })
    local ok, err = mod.pushCurrentKoreaderProgressDirect(plugin, { book_cache_id = 1 })
    assert.is_false(ok)
    assert.are.equal("api error", err)
  end)

  it("saves to db and returns true on success", function()
    local mod = make_mod()
    local db_calls = {}
    local plugin = make_plugin({
      api = {
        updateKoReaderProgress = function() return true, "ok" end,
      },
      db = {
        markKoreaderProgressSynced = function(_, data)
          db_calls[#db_calls + 1] = data
        end,
      },
    })
    local payload = {
      book_cache_id = 10,
      book_hash = "hash123",
      document = "hash123",
      progress = "50",
      location = "50",
      percentage = 0.5,
      device = "KOReader",
      device_id = "dev-1",
      timestamp = 1000,
    }
    local ok, err = mod.pushCurrentKoreaderProgressDirect(plugin, payload)
    assert.is_true(ok)
    assert.are.equal("ok", err)
    assert.are.equal(1, #db_calls)
    assert.are.equal(10, db_calls[1].book_cache_id)
  end)

  it("does not save to db when db is nil", function()
    local mod = make_mod()
    local plugin = make_plugin({
      api = {
        updateKoReaderProgress = function() return true, "ok" end,
      },
      db = nil,
    })
    local ok, err = mod.pushCurrentKoreaderProgressDirect(plugin, { book_cache_id = 1 })
    assert.is_true(ok)
  end)

  it("extracts progress from location field when progress is missing", function()
    local mod = make_mod()
    local db_calls = {}
    local plugin = make_plugin({
      api = {
        updateKoReaderProgress = function() return true, "ok" end,
      },
      db = {
        markKoreaderProgressSynced = function(_, data)
          db_calls[#db_calls + 1] = data
        end,
      },
    })
    local ok, err = mod.pushCurrentKoreaderProgressDirect(plugin, {
      book_cache_id = 1,
      book_hash = "h",
      document = "h",
      location = "42",
      percentage = 0.42,
      device = "KO",
      device_id = "d",
      timestamp = 1,
    })
    assert.is_true(ok)
    assert.are.equal("42", db_calls[1].progress)
  end)
end)
