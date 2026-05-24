package.path = table.concat({
  "bookloresync.koplugin/?.lua",
  "bookloresync.koplugin/?/init.lua",
  package.path,
}, ";")

package.preload["logger"] = function()
  return { info = function() end, warn = function() end, err = function() end, dbg = function() end }
end
package.preload["datastorage"] = function()
  return { getSettingsDir = function() return "/tmp" end, getDataDir = function() return "/tmp" end }
end
package.preload["dispatcher"] = function() return { registerAction = function() end } end
package.preload["apps/filemanager/filemanager"] = function() return { instance = nil } end
package.preload["ui/widget/eventlistener"] = function() return {} end
package.preload["ui/event"] = function() return { new = function(_, o) return o or {} end } end
package.preload["ui/widget/infomessage"] = function()
  return { new = function(_, o) o = o or {}; return o end }
end
package.preload["ui/widget/inputdialog"] = function() return { new = function(_, o) return o or {} end } end
package.preload["ui/widget/confirmbox"] = function()
  local CB = {}; CB.__index = CB
  function CB:new(o) o = o or {}; return setmetatable(o, self) end
  return CB
end
package.preload["ui/widget/buttondialog"] = function()
  local BD = {}; BD.__index = BD
  function BD:new(o) o = o or {}; return setmetatable(o, self) end
  function BD:setTitle(t) self.title = t end
  return BD
end
package.preload["ui/widget/menu"] = function() return { new = function(_, o) return o or {} end } end
package.preload["ui/network/manager"] = function()
  return { isOnline = function() return true end, isConnected = function() return true end,
           getNetworkInterfaceName = function() return "" end }
end
package.preload["ui/uimanager"] = function()
  return {
    scheduleIn = function(_, _, fn) if fn then fn() end end,
    nextTick = function(_, fn) if fn then fn() end end,
    show = function() end, close = function() end, forceRePaint = function() end,
  }
end
package.preload["ui/widget/container/widgetcontainer"] = function()
  local WC = {}; function WC:extend(o) o = o or {}; o.__index = o; setmetatable(o, self); self.__index = self; return o end
  return WC
end
package.preload["ui/trapper"] = function()
  return {
    wrap = function(_, fn) local co = coroutine.create(fn); repeat local ok,err = coroutine.resume(co); if not ok then error(err) end until coroutine.status(co) == "dead" end,
    dismissableRunInSubprocess = function(_, fn, _) local ok, r = pcall(fn); if not ok then return true, nil end; return true, r end,
    info = function() end,
  }
end
package.preload["json"] = function()
  local function enc(v)
    local t = type(v)
    if t == "nil" then return "null"
    elseif t == "boolean" or t == "number" then return tostring(v)
    elseif t == "string" then return '"' .. v:gsub('"', '\\"') .. '"'
    elseif t == "table" then
      if #v > 0 then local p={}; for _,x in ipairs(v) do p[#p+1]=enc(x) end; return "["..table.concat(p,",").."]" end
      local p={}; for k,val in pairs(v) do p[#p+1] = '"'..tostring(k)..'":'..enc(val) end; return "{"..table.concat(p,",").."}"
    end; return "null"
  end
  return { encode = enc, decode = function() return {} end, util = { InitArray = function(t) return t end } }
end
package.preload["ffi/util"] = function()
  local fake_result
  return {
    template = function(fmt, ...) local a={...}; return (fmt:gsub("%%(%d+)", function(i) return tostring(a[tonumber(i)] or "") end)) end,
    runInSubProcess = function(fn, _) pcall(fn, 1, 1); return 1, 1 end,
    isSubProcessDone = function() return true end, getNonBlockingReadSize = function() return 1 end,
    readAllFromFD = function() return fake_result end, writeToFD = function(_, data) fake_result = data end,
    terminateSubProcess = function() end,
  }
end
package.preload["libs/libkoreader-lfs"] = function()
  return { attributes = function() return nil end, mkdir = function() return true end, dir = function() return function() return nil end end }
end
package.preload["ffi/sha2"] = function() return { md5 = function(s) return "deadbeef" end } end
package.preload["ffi"] = function() return {} end
package.preload["random"] = function() return { random = function(_, _) return 1 end } end
package.preload["booklore_settings"] = function() return { new = function() return {} end } end
package.preload["hardcover_api_client"] = function() return { new = function() return {} end } end
package.preload["booklore_updater"] = function() return { new = function() return {} end } end
package.preload["booklore_file_logger"] = function() return { new = function() return {} end } end
package.preload["booklore_metadata_extractor"] = function() return { new = function() return {} end } end
package.preload["booklore_database"] = function() return { new = function() return { init = function() end, close = function() end,
  getBookByFilePath = function() return nil end, getShelfState = function() return nil end, saveShelfState = function() end,
  clearShelfState = function() end, getBookByBookId = function() return nil end, isBookTrackingEnabled = function() return true end,
} end } end
package.preload["booklore_api_client"] = function()
  return { new = function() return { init = function() end, getOrCreateShelf = function() return true, 1 end,
    getBooksInShelf = function() return true, {} end, downloadBook = function() return true end,
    resolveShelfSource = function() return true, { id = 1, name = "Shelf" } end, request = function() return true, 200, {} end,
    getOrRefreshBearerToken = function() return true, "token" end, submitRating = function() return true end,
    updateKoReaderProgress = function() return true end, submitBookmark = function() return true, 1 end,
    submitHighlight = function() return true end, searchBooksWithAuth = function() return true, {} end,
    getBookRecommendations = function() return true, {} end, getBookByHash = function() return true, { id = "1" } end,
  } end }
end
package.preload["gettext"] = function()
  local t = function(s) return s end
  return setmetatable({}, { __call = function(_, s) return s end, __index = function(_, k) if k == "T" then return function(fmt, ...) local a={...}; return (fmt:gsub("%%(%d+)", function(i) return tostring(a[tonumber(i)] or "") end)) end end; return nil end })
end
package.preload["string.buffer"] = function() local M={}; function M.encode(t) return t end; function M.decode(t) return t end; return M end
package.preload["device"] = function()
  return { model = "KOReader-Test", isAndroid = function() return false end, canOpenLink = function() return true end, openLink = function() end }
end
if not _G.bit then _G.bit = { lshift = function(n,s) return n * (2^s) end, rshift = function(n,s) return math.floor(n / (2^s)) end } end

local UpdatesModuleFactory = require("booklore_updates_module")
local ProgressSyncFactory = require("booklore_progress_sync")
local MatchingModuleFactory = require("booklore_matching_module")

local uimanager_shows = {}
local UIManager = require("ui/uimanager")
UIManager.show = function(_, widget) uimanager_shows[#uimanager_shows + 1] = widget end
local confirm_boxes = {}
local CB = require("ui/widget/confirmbox")
local orig_new = CB.new
CB.new = function(_, o) o = o or {}; confirm_boxes[#confirm_boxes+1] = o; return setmetatable(o, CB) end

local function reset_trackers()
  for i = #uimanager_shows, 1, -1 do uimanager_shows[i] = nil end
  for i = #confirm_boxes, 1, -1 do confirm_boxes[i] = nil end
end

local function make_deps()
  return { _ = function(s) return s end, T = function(fmt, ...) local a={...}; return (fmt:gsub("%%(%d+)", function(i) return tostring(a[tonumber(i)] or "") end)) end,
    logger = require("logger"), NetworkMgr = require("ui/network/manager"), UIManager = UIManager,
    InfoMessage = require("ui/widget/infomessage"), ButtonDialog = require("ui/widget/buttondialog"),
    ConfirmBox = CB, json = require("json"), Device = require("device"), _ = require("gettext"),
    ffiutil = require("ffi/util"), strbuf = require("string.buffer"),
  }
end

-- ═══════════ updates coverage ═══════════
describe("updates: targeted coverage", function()
  before_each(function() reset_trackers() end)

  it("installUpdate failure shows rollback confirm", function()
    local mod = UpdatesModuleFactory.new(make_deps())
    local plugin = { updater = { downloadUpdate = function() return true,"/tmp/u.zip" end, installUpdate = function() return false,"err" end },
      settings = { saveSetting = function() end, flush = function() end },
      logInfo = function() end, logWarn = function() end, logErr = function() end, logDbg = function() end, rollbackUpdate = function() end }
    mod.installUpdate(plugin, "http://dl", "2.0.0")
    assert.is_true(#uimanager_shows > 0)
  end)

  it("rollbackUpdate failure shows error", function()
    local mod = UpdatesModuleFactory.new(make_deps())
    local plugin = { updater = { rollback = function() return false, "err" end },
      settings = { saveSetting = function() end, flush = function() end },
      logInfo = function() end, logWarn = function() end, logErr = function() end, logDbg = function() end }
    mod.rollbackUpdate(plugin)
    assert.is_true(#uimanager_shows > 0)
  end)

  it("toggleUseDevBuilds fails when no dev URL", function()
    local mod = UpdatesModuleFactory.new(make_deps())
    local plugin = { use_dev_builds = false, getDevBuildDownloadURL = function() return nil,"no url" end,
      settings = { saveSetting = function() end, flush = function() end }, updater = { clearCache = function() end },
      logInfo = function() end, logWarn = function() end, logErr = function() end, logDbg = function() end }
    mod.toggleUseDevBuilds(plugin)
    assert.is_false(plugin.use_dev_builds)
  end)

  it("checkForUpdates not-connected shows message", function()
    local mod = UpdatesModuleFactory.new(make_deps())
    local plugin = { use_dev_builds = false,
      updater = { getCurrentVersion = function() return {version="1",version_type="s",build_date="",git_commit=""} end },
      settings = { saveSetting = function() end, flush = function() end },
      logInfo = function() end, logWarn = function() end, logErr = function() end, logDbg = function() end }
    -- Temporarily override NetworkMgr to return not connected
    make_deps().NetworkMgr.isConnected = function() return false end
    mod.checkForUpdates(plugin, false)
    assert.is_true(#uimanager_shows > 0)
  end)
end)

-- ═══════════ progress coverage ═══════════
describe("progress: targeted coverage", function()
  it("pushCurrent returns false when payload not a table", function()
    local mod = ProgressSyncFactory.new({ Device = require("device") })
    local plugin = { api = { updateKoReaderProgress = function() return true end },
      isNetworkConnected = function() return true end, db = { markKoreaderProgressSynced = function() end },
      logInfo = function() end, logWarn = function() end, logErr = function() end }
    local ok,err = mod.pushCurrentKoreaderProgressDirect(plugin, "not-a-table")
    assert.is_false(ok); assert.is_not_nil(err)
  end)
end)

-- ═══════════ matching coverage ═══════════
describe("matching: targeted coverage", function()
  before_each(function() reset_trackers() end)

  it("wifi fallback triggers on_success and on_fail callbacks", function()
    local mod = MatchingModuleFactory.new({ _ = function(s) return s end,
      T = function(fmt, ...) local a={...}; return (fmt:gsub("%%(%d+)", function(i) return tostring(a[tonumber(i)] or "") end)) end,
      UIManager = UIManager, InfoMessage = require("ui/widget/infomessage"),
      ConfirmBox = CB, ButtonDialog = require("ui/widget/buttondialog"),
    })
    local success_called, fail_called = false, false
    local successes, on_fail_fn
    local plugin = { isNetworkConnected = function() return false end,
      db = { getAllUnmatchedBooks = function() return { { title = "B1" } } end },
      _requestWifi = function(_, _, on_success, on_fail)
        successes = on_success; on_fail_fn = on_fail
      end,
      showWifiUnavailableInfo = function() fail_called = true end,
      _startBookCacheMatching = function() success_called = true end,
      logInfo = function() end, logWarn = function() end, logErr = function() end,
    }
    mod._startBookCacheMatching(plugin)
    -- Execute on_success
    assert.is_not_nil(successes); successes(); assert.is_true(success_called)
    -- Execute on_fail
    assert.is_not_nil(on_fail_fn); on_fail_fn(); assert.is_true(fail_called)
  end)
end)
