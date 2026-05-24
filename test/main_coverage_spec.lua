package.path = table.concat({
  "bookloresync.koplugin/?.lua",
  "bookloresync.koplugin/?/init.lua",
  package.path,
}, ";")

package.preload["logger"] = function()
  return { info = function() end, warn = function() end, err = function() end, dbg = function() end }
end
package.preload["datastorage"] = function()
  return { getSettingsDir = function() return "/tmp/test-settings" end, getDataDir = function() return "/tmp/test-data" end }
end
package.preload["dispatcher"] = function() return { registerAction = function() end } end
package.preload["apps/filemanager/filemanager"] = function()
  return { instance = nil, addFileDialogButtons = function() end, removeFileDialogButtons = function() end }
end
package.preload["ui/widget/eventlistener"] = function() return {} end
package.preload["ui/event"] = function() return { new = function(_, o) return o or {} end } end
package.preload["ui/widget/infomessage"] = function() return { new = function(_, o) return o or {} end } end
package.preload["ui/widget/inputdialog"] = function() return { new = function(_, o) return o or {} end } end
package.preload["ui/widget/confirmbox"] = function()
  local CB = {}; CB.__index = CB; function CB:new(o) o = o or {}; return setmetatable(o, self) end; return CB
end
package.preload["ui/widget/buttondialog"] = function()
  local BD = {}; BD.__index = BD; function BD:new(o) o = o or {}; return setmetatable(o, self) end; function BD:setTitle(t) self.title = t end; return BD
end
package.preload["ui/widget/menu"] = function() return { new = function(_, o) return o or {} end } end
package.preload["ui/network/manager"] = function()
  return { isOnline = function() return true end, isConnected = function() return true end,
           getNetworkInterfaceName = function() return "" end }
end
package.preload["ui/uimanager"] = function()
  return { scheduleIn = function(_, _, fn) if fn then fn() end end, nextTick = function(_, fn) if fn then fn() end end,
           show = function() end, close = function() end, setDirty = function() end, forceRePaint = function() end }
end
package.preload["ui/widget/container/widgetcontainer"] = function()
  local WC = {}; function WC:extend(o) o = o or {}; o.__index = o; setmetatable(o, self); self.__index = self; return o end; return WC
end
package.preload["ui/trapper"] = function()
  return { wrap = function(_, fn)
    local co = coroutine.create(fn); repeat local ok, err = coroutine.resume(co); if not ok then error(err) end until coroutine.status(co) == "dead"
  end, dismissableRunInSubprocess = function(_, fn, _) local ok, r = pcall(fn); if not ok then return true, nil end; return true, r end, info = function() end }
end

package.preload["json"] = function()
  return { encode = function(t) return "{}" end, decode = function(s) return {} end, util = { InitArray = function(t) return t end } }
end
package.preload["ffi/util"] = function()
  local fake_result; return {
    template = function(fmt, ...) local a={...}; return (fmt:gsub("%%(%d+)", function(i) return tostring(a[tonumber(i)] or "") end)) end,
    runInSubProcess = function(fn, _) pcall(fn, 1, 1); return 1, 1 end,
    isSubProcessDone = function() return true end, getNonBlockingReadSize = function() return 1 end,
    readAllFromFD = function() return fake_result end, writeToFD = function(_, data) fake_result = data end,
    terminateSubProcess = function() end,
  }
end
package.preload["libs/libkoreader-lfs"] = function()
  return { attributes = function() return nil end, mkdir = function() return true end,
           dir = function() return function() return nil end end, rmdir = function() return true end }
end
package.preload["ffi/sha2"] = function() return { md5 = function(s) return "deadbeef" end } end
package.preload["ffi"] = function()
  return { new = function() return { f_bsize = 4096, f_frsize = 4096, f_blocks = 1000000, f_bfree = 500000, f_bavail = 400000 } end,
           cdef = function() end, C = { statvfs = function() return 0 end } }
end
package.preload["random"] = function() return { random = function(_, _) return 1 end } end
package.preload["gettext"] = function() return function(s) return s end end
package.preload["string.buffer"] = function() local M={}; function M.encode(t) return t end; function M.decode(t) return t end; return M end
package.preload["device"] = function()
  return { model = "KOReader-Test", isAndroid = function() return false end, canOpenLink = function() return true end,
           openLink = function() end, performHapticFeedback = function() end, canExecuteScript = function() return true end }
end
package.preload["luasettings"] = function()
  return { open = function() return { readSetting = function() return nil end, saveSetting = function() end, flush = function() end } end }
end
package.preload["booklore_settings"] = function() return { new = function() return {} end } end
package.preload["hardcover_api_client"] = function() return { new = function() return {} end } end
package.preload["booklore_updater"] = function()
  return { new = function() return { getCurrentVersion = function() return {version="1",version_type="s",build_date="",git_commit=""} end,
    checkForUpdates = function() return nil end, checkForDirectDownload = function() return nil end,
    downloadUpdate = function() return false end, installUpdate = function() return false end, rollback = function() return false end,
    clearCache = function() end, check = function() end } end }
end
package.preload["booklore_file_logger"] = function() return { new = function() return {} end } end
package.preload["booklore_metadata_extractor"] = function() return { new = function() return {} end } end
package.preload["booklore_database"] = function()
  return { new = function() return { init = function() end, close = function() end,
    getBookByFilePath = function() return nil end, getBookByBookId = function() return nil end,
    isBookTrackingEnabled = function() return true end, getHardcoverUserId = function() return nil end,
    saveHardcoverUserId = function() end, deleteBearerToken = function() end,
    getShelfState = function() return nil end, saveShelfState = function() end, clearShelfState = function() end } end }
end
package.preload["booklore_api_client"] = function()
  return { new = function() return { init = function() end, getOrCreateShelf = function() return true, 1 end,
    getBooksInShelf = function() return true, {} end, downloadBook = function() return true end,
    resolveShelfSource = function() return true, { id = 1 } end, request = function() return true, 200, {} end,
    getOrRefreshBearerToken = function() return true, "token" end, submitRating = function() return true end,
    updateKoReaderProgress = function() return true end, submitBookmark = function() return true, 1 end,
    submitHighlight = function() return true end, searchBooksWithAuth = function() return true, {} end,
    getBookRecommendations = function() return true, {} end, getBookByHash = function() return true, { id = "1" } end,
    getBookFileSize = function() return 1000, nil end } end }
end

if not _G.bit then _G.bit = { lshift = function(n,s) return n * (2^s) end, rshift = function(n,s) return math.floor(n / (2^s)) end } end

local BookloreSync = require("main")

describe("main.lua: additional coverage", function()
  describe("getDevBuildDownloadURL", function()
    it("returns nil when no plugin_dir", function()
      local p = setmetatable({ plugin_dir = nil }, { __index = BookloreSync })
      local url, err = p:getDevBuildDownloadURL()
      assert.is_nil(url)
      assert.is_not_nil(err)
    end)
  end)

  describe("hasDevBuildLocationFile", function()
    it("returns false when file does not exist", function()
      local p = setmetatable({}, { __index = BookloreSync })
      assert.is_false(p:hasDevBuildLocationFile())
    end)
  end)

  describe("isAirplaneModeActive", function()
    it("returns false by default", function()
      local p = setmetatable({
        isAirplaneModePluginInstalled = function() return false end,
      }, { __index = BookloreSync })
      assert.is_false(p:isAirplaneModeActive())
    end)
  end)

  describe("hasOpenDocumentForProgressSync", function()
    it("returns nil when no document open", function()
      local p = setmetatable({ ui = nil }, { __index = BookloreSync })
      assert.is_nil(p:hasOpenDocumentForProgressSync())
    end)
  end)

  describe("onExit", function()
    it("calls file_logger close when available", function()
      local closed = false
      local p = setmetatable({
        file_logger = { close = function() closed = true end },
        settings = { close = function() end },
      }, { __index = BookloreSync })
      p:onExit()
      assert.is_true(closed)
    end)
  end)

  describe("setSyncMode", function()
    it("sets manual_sync_only flag when mode is not automatic", function()
      local p = setmetatable({
        settings = { saveSetting = function() end, flush = function() end },
      }, { __index = BookloreSync })
      p:setSyncMode("prompt")
      assert.is_true(p.manual_sync_only)
    end)

    it("sets automatic mode correctly", function()
      local p = setmetatable({
        settings = { saveSetting = function() end, flush = function() end },
      }, { __index = BookloreSync })
      p:setSyncMode("automatic")
      assert.are.equal("automatic", p.sync_mode)
      assert.is_false(p.manual_sync_only)
    end)
  end)

  describe("isOnConfiguredHomeNetwork", function()
    it("returns true when home_network_ssid is empty", function()
      local p = setmetatable({
        home_network_ssid = "",
        getCurrentNetworkSSID = function() return "AnyNetwork" end,
      }, { __index = BookloreSync })
      assert.is_true(p:isOnConfiguredHomeNetwork())
    end)
  end)

  describe("calculateBookHash", function()
    it("delegates to util and returns hash", function()
      local p = setmetatable({}, { __index = BookloreSync })
      local hash = p:calculateBookHash("/nonexistent/book.epub")
      -- Should not crash; will return nil for nonexistent file
      assert.is_nil(hash)
    end)
  end)

  describe("toggleSync", function()
    it("flips the is_enabled flag", function()
      local p = setmetatable({
        is_enabled = true,
        settings = { saveSetting = function() end, flush = function() end },
        logInfo = function() end,
      }, { __index = BookloreSync })
      p:toggleSync()
      assert.is_false(p.is_enabled)
    end)
  end)

  describe("toggleManualSyncOnly", function()
    it("flips the manual sync flag", function()
      local p = setmetatable({
        manual_sync_only = false,
        settings = { saveSetting = function() end, flush = function() end },
      }, { __index = BookloreSync })
      p:toggleManualSyncOnly()
      assert.is_true(p.manual_sync_only)
    end)
  end)

  describe("colorToHex", function()
    it("maps colors to hex", function()
      local p = setmetatable({}, { __index = BookloreSync })
      assert.are.equal("#FFC107", p:colorToHex("yellow"))
      assert.are.equal("#FFC107", p:colorToHex(nil))
    end)
  end)

  describe("drawerToStyle", function()
    it("maps drawers to styles", function()
      local p = setmetatable({}, { __index = BookloreSync })
      assert.are.equal("highlight", p:drawerToStyle("lighten"))
    end)
  end)
end)
