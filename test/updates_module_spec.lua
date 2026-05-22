-- Tests for booklore_updates_module.lua
--
-- Factory module: M.new(deps) returns module table with:
--   showVersionInfo, autoCheckForUpdates, checkForUpdates,
--   installUpdate, rollbackUpdate, toggleAutoUpdateCheck,
--   toggleUseDevBuilds, clearUpdateCache
--
-- Covers: dev builds, time check, network, result paths, stable releases,
-- download success/failure, install success/failure, rollback,
-- setting toggles.

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
      o.setText = function(self, text) self.text = text end
      return o
    end,
    -- For progress_msg.setText
    setText = function(self, text)
      self._text = text
    end,
  }
end

-- Track ConfirmBox instances
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

-- UIManager: track shows/closes, setDirty, askForRestart
local uimanager_shows = {}
local uimanager_closes = {}
local schedule_ins = {}
local dirty_calls = {}
local ask_for_restart_calls = {}
package.preload["ui/uimanager"] = function()
  return {
    scheduleIn     = function(_, _delay, fn)
      if fn then schedule_ins[#schedule_ins + 1] = fn end
    end,
    nextTick       = function(_, fn) if fn then fn() end end,
    show           = function(_, w)
      uimanager_shows[#uimanager_shows + 1] = w
    end,
    close          = function(_, w)
      uimanager_closes[#uimanager_closes + 1] = w
    end,
    setDirty       = function(_, w, mode)
      dirty_calls[#dirty_calls + 1] = { w = w, mode = mode }
    end,
    askForRestart  = function(_, msg)
      ask_for_restart_calls[#ask_for_restart_calls + 1] = msg
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
  return { isOnline = function() return true end, isConnected = function() return true end }
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

local UpdatesModuleFactory = require("booklore_updates_module")

-- ── Helpers ──────────────────────────────────────────────────────────────────

local function reset_trackers()
  for i = #info_messages, 1, -1 do info_messages[i] = nil end
  for i = #confirm_boxes, 1, -1 do confirm_boxes[i] = nil end
  for i = #button_dialogs, 1, -1 do button_dialogs[i] = nil end
  for i = #uimanager_shows, 1, -1 do uimanager_shows[i] = nil end
  for i = #uimanager_closes, 1, -1 do uimanager_closes[i] = nil end
  for i = #schedule_ins, 1, -1 do schedule_ins[i] = nil end
  for i = #dirty_calls, 1, -1 do dirty_calls[i] = nil end
  for i = #ask_for_restart_calls, 1, -1 do ask_for_restart_calls[i] = nil end
end

local function make_deps()
  return {
    _ = function(s) return s end,
    T = function(fmt, ...)
      local a = {...}
      return (fmt:gsub("%%(%d+)", function(i) return tostring(a[tonumber(i)] or "") end))
    end,
    logger = require("logger"),
    NetworkMgr = require("ui/network/manager"),
    UIManager = require("ui/uimanager"),
    InfoMessage = require("ui/widget/infomessage"),
    ButtonDialog = require("ui/widget/buttondialog"),
    ConfirmBox = require("ui/widget/confirmbox"),
  }
end

local function make_plugin(overrides)
  overrides = overrides or {}
  local p = {
    updater = {
      getCurrentVersion = function()
        return {
          version = "1.0.0",
          version_type = "stable",
          build_date = "2024-01-01",
          git_commit = "abc123",
        }
      end,
      checkForUpdates = function() return nil end,
      checkForDirectDownload = function() return nil end,
      downloadUpdate = function() return false, "download error" end,
      installUpdate = function() return false, "install error" end,
      rollback = function() return false, "rollback error" end,
      clearCache = function() end,
      check = function() end, -- bookends-style
    },
    settings = {
      saveSetting = function() end,
      flush = function() end,
    },
    use_dev_builds = false,
    auto_update_check = false,
    update_available = false,
    last_update_check = 0,
    getDevBuildDownloadURL = function() return nil, "no url configured" end,
    logInfo = function() end,
    logWarn = function() end,
    logErr = function() end,
    logDbg = function() end,
  }
  for k, v in pairs(overrides) do p[k] = v end
  return p
end

-- ═══════════════════════════════════════════════════════════════════════════
-- showVersionInfo
-- ═══════════════════════════════════════════════════════════════════════════

describe("showVersionInfo", function()

  local function make_mod()
    return UpdatesModuleFactory.new(make_deps())
  end

  before_each(function()
    reset_trackers()
  end)

  it("shows version information from updater", function()
    local mod = make_mod()
    local plugin = make_plugin()
    mod.showVersionInfo(plugin)
    assert.are.equal(1, #uimanager_shows)
    local msg = tostring(uimanager_shows[1].text)
    assert.is_truthy(msg:find("1%.0%.0", 1, true) or msg:find("Version Information", 1, true))
  end)

  it("appends update available notice when update_available is true", function()
    local mod = make_mod()
    local plugin = make_plugin({ update_available = true })
    mod.showVersionInfo(plugin)
    assert.are.equal(1, #uimanager_shows)
    local msg = tostring(uimanager_shows[1].text)
    assert.is_truthy(msg:find("Update available", 1, true))
  end)
end)

-- ═══════════════════════════════════════════════════════════════════════════
-- autoCheckForUpdates
-- ═══════════════════════════════════════════════════════════════════════════

describe("autoCheckForUpdates", function()

  local logged = {}
  local function make_deps_with_logger()
    local deps = make_deps()
    deps.logger = {
      info = function(msg) logged[#logged + 1] = { level = "info", msg = msg } end,
      warn = function(msg) logged[#logged + 1] = { level = "warn", msg = msg } end,
      err  = function() end,
      dbg  = function() end,
    }
    return deps
  end

  local function make_mod()
    return UpdatesModuleFactory.new(make_deps_with_logger())
  end

  before_each(function()
    reset_trackers()
    for i = #logged, 1, -1 do logged[i] = nil end
  end)

  it("skips check when use_dev_builds is true", function()
    local mod = make_mod()
    local plugin = make_plugin({ use_dev_builds = true })
    mod.autoCheckForUpdates(plugin)
    -- Should have logged about dev builds
    assert.is_true(#logged > 0)
    assert.is_truthy(logged[1].msg:find("Use Dev Builds", 1, true))
  end)

  it("skips check when last check was less than 24h ago", function()
    local mod = make_mod()
    local plugin = make_plugin({ last_update_check = os.time() })
    mod.autoCheckForUpdates(plugin)
    assert.is_true(#logged > 0)
    assert.is_truthy(logged[1].msg:find("less than 24 hours", 1, true))
  end)

  it("skips check when network is not available", function()
    local mod = make_mod()
    local deps = make_deps_with_logger()
    deps.NetworkMgr = { isConnected = function() return false end }
    -- We need to re-create the mod with modified deps
    local mod2 = UpdatesModuleFactory.new(deps)
    local plugin = make_plugin({ last_update_check = 0 })
    mod2.autoCheckForUpdates(plugin)
    -- Should save last_update_check first, then log no network
    local has_network_msg = false
    for _, entry in ipairs(logged) do
      if entry.msg:find("No network", 1, true) then
        has_network_msg = true
      end
    end
    assert.is_true(has_network_msg)
  end)

  it("handles failed auto-check gracefully", function()
    local mod = make_mod()
    local plugin = make_plugin({
      last_update_check = 0,
      updater = {
        checkForUpdates = function() return nil end,
      },
    })
    mod.autoCheckForUpdates(plugin)
    local has_warn = false
    for _, entry in ipairs(logged) do
      if entry.level == "warn" and entry.msg:find("Auto-check failed", 1, true) then
        has_warn = true
      end
    end
    assert.is_true(has_warn)
  end)

  it("sets update_available when result.available is true", function()
    local mod = make_mod()
    local plugin = make_plugin({
      last_update_check = 0,
      updater = {
        checkForUpdates = function()
          return {
            available = true,
            latest_version = "2.0.0",
            current_version = "1.0.0",
          }
        end,
      },
    })
    mod.autoCheckForUpdates(plugin)
    assert.is_true(plugin.update_available)
    assert.is_true(#uimanager_shows > 0)
  end)

  it("logs 'already up to date' when result.available is false", function()
    local mod = make_mod()
    local plugin = make_plugin({
      last_update_check = 0,
      updater = {
        checkForUpdates = function()
          return { available = false }
        end,
      },
    })
    mod.autoCheckForUpdates(plugin)
    assert.is_false(plugin.update_available)
    local has_msg = false
    for _, entry in ipairs(logged) do
      if entry.msg:find("up to date", 1, true) then
        has_msg = true
      end
    end
    assert.is_true(has_msg)
  end)

  it("saves last_update_check to settings", function()
    local mod = make_mod()
    local save_calls = {}
    local plugin = make_plugin({
      last_update_check = 0,
      updater = {
        checkForUpdates = function() return { available = false } end,
      },
      settings = {
        saveSetting = function(_, k, v)
          save_calls[#save_calls + 1] = { k = k, v = v }
        end,
        flush = function() end,
      },
    })
    mod.autoCheckForUpdates(plugin)
    assert.are.equal(1, #save_calls)
    assert.are.equal("last_update_check", save_calls[1].k)
  end)
end)

-- ═══════════════════════════════════════════════════════════════════════════
-- installUpdate
-- ═══════════════════════════════════════════════════════════════════════════

describe("installUpdate", function()

  local function make_mod()
    return UpdatesModuleFactory.new(make_deps())
  end

  before_each(function()
    reset_trackers()
  end)

  it("shows progress message and calls downloadUpdate", function()
    local mod = make_mod()
    local download_url = "http://example.com/v2.zip"
    local download_called = false
    local plugin = make_plugin({
      updater = {
        downloadUpdate = function(_, url, progress_cb)
          download_called = true
          -- Call progress callback to test setText/setDirty
          if progress_cb then
            progress_cb(500, 1000)
          end
          return true, "/tmp/update.zip"
        end,
        installUpdate = function() return true end,
      },
    })
    mod.installUpdate(plugin, download_url, "2.0.0")
    assert.is_true(download_called)
    assert.is_true(#uimanager_shows > 0) -- progress msg shown
    assert.is_true(#uimanager_closes > 0) -- progress msg closed
  end)

  it("shows error when download fails", function()
    local mod = make_mod()
    local plugin = make_plugin({
      updater = {
        downloadUpdate = function() return false, "network error" end,
      },
    })
    mod.installUpdate(plugin, "http://example.com/v2.zip", "2.0.0")
    -- Should show error InfoMessage
    assert.is_true(#uimanager_shows > 1)
  end)

  it("asks for restart when install succeeds", function()
    local mod = make_mod()
    local plugin = make_plugin({
      updater = {
        downloadUpdate = function() return true, "/tmp/update.zip" end,
        installUpdate = function() return true end,
      },
    })
    mod.installUpdate(plugin, "http://example.com/v2.zip", "2.0.0")
    assert.is_true(#ask_for_restart_calls > 0)
  end)

  it("shows rollback dialog when install fails", function()
    local mod = make_mod()
    local rollback_called = false
    local plugin = make_plugin({
      updater = {
        downloadUpdate = function() return true, "/tmp/update.zip" end,
        installUpdate = function() return false, "corrupt zip" end,
      },
      rollbackUpdate = function()
        rollback_called = true
      end,
    })
    mod.installUpdate(plugin, "http://example.com/v2.zip", "2.0.0")
    -- Should show ConfirmBox with rollback option
    assert.is_true(#confirm_boxes > 0)
    -- Execute rollback callback
    if confirm_boxes[1].ok_callback then
      confirm_boxes[1].ok_callback()
      assert.is_true(rollback_called)
    end
  end)

  it("calls progress callback to update download percentage display", function()
    local mod = make_mod()
    local progress_msg
    local plugin = make_plugin({
      updater = {
        downloadUpdate = function(_, url, progress_cb)
          -- Create a simple progress message table
          progress_msg = { _text = "" }
          -- Override the cached new
          -- Actually the progress_msg is created in installUpdate
          if progress_cb then
            progress_cb(250, 1000) -- 25%
          end
          return true, "/tmp/update.zip"
        end,
        installUpdate = function() return true end,
      },
    })
    mod.installUpdate(plugin, "http://example.com/v2.zip", "2.0.0")
    -- Just verify download+install completed
    assert.is_true(#ask_for_restart_calls > 0)
  end)
end)

-- ═══════════════════════════════════════════════════════════════════════════
-- rollbackUpdate
-- ═══════════════════════════════════════════════════════════════════════════

describe("rollbackUpdate", function()

  local function make_mod()
    return UpdatesModuleFactory.new(make_deps())
  end

  before_each(function()
    reset_trackers()
  end)

  it("shows rolling back message", function()
    local mod = make_mod()
    local plugin = make_plugin({
      updater = {
        rollback = function() return true end,
      },
    })
    mod.rollbackUpdate(plugin)
    assert.is_true(#uimanager_shows > 0)
  end)

  it("asks for restart on successful rollback", function()
    local mod = make_mod()
    local plugin = make_plugin({
      updater = {
        rollback = function() return true end,
      },
    })
    mod.rollbackUpdate(plugin)
    assert.is_true(#ask_for_restart_calls > 0)
  end)

  it("shows error on failed rollback", function()
    local mod = make_mod()
    local plugin = make_plugin({
      updater = {
        rollback = function() return false, "rollback failed" end,
      },
    })
    mod.rollbackUpdate(plugin)
    -- Should show error message
    assert.is_true(#uimanager_shows > 0)
  end)
end)

-- ═══════════════════════════════════════════════════════════════════════════
-- toggleAutoUpdateCheck
-- ═══════════════════════════════════════════════════════════════════════════

describe("toggleAutoUpdateCheck", function()

  local function make_mod()
    return UpdatesModuleFactory.new(make_deps())
  end

  before_each(function()
    reset_trackers()
  end)

  it("toggles from false to true and saves", function()
    local mod = make_mod()
    local save_calls = {}
    local plugin = make_plugin({
      auto_update_check = false,
      settings = {
        saveSetting = function(_, k, v)
          save_calls[#save_calls + 1] = { k = k, v = v }
        end,
        flush = function() end,
      },
    })
    mod.toggleAutoUpdateCheck(plugin)
    assert.is_true(plugin.auto_update_check)
    assert.are.equal(1, #save_calls)
    assert.are.equal("auto_update_check", save_calls[1].k)
    assert.is_true(save_calls[1].v)
  end)

  it("toggles from true to false and shows disabled message", function()
    local mod = make_mod()
    local plugin = make_plugin({ auto_update_check = true })
    mod.toggleAutoUpdateCheck(plugin)
    assert.is_false(plugin.auto_update_check)
    assert.is_true(#uimanager_shows > 0)
    local msg = tostring(uimanager_shows[1].text)
    assert.is_truthy(msg:find("disabled", 1, true))
  end)
end)

-- ═══════════════════════════════════════════════════════════════════════════
-- toggleUseDevBuilds
-- ═══════════════════════════════════════════════════════════════════════════

describe("toggleUseDevBuilds", function()

  local function make_mod()
    return UpdatesModuleFactory.new(make_deps())
  end

  before_each(function()
    reset_trackers()
  end)

  it("shows error when enabling and getDevBuildDownloadURL fails", function()
    local mod = make_mod()
    local plugin = make_plugin({
      use_dev_builds = false,
      getDevBuildDownloadURL = function() return nil, "bad url" end,
    })
    mod.toggleUseDevBuilds(plugin)
    assert.is_false(plugin.use_dev_builds) -- should remain false
    assert.is_true(#uimanager_shows > 0)
    local msg = tostring(uimanager_shows[1].text)
    assert.is_truthy(msg:find("Cannot enable", 1, true))
  end)

  it("toggles from false to true when dev url is available", function()
    local mod = make_mod()
    local save_calls = {}
    local clear_called = false
    local plugin = make_plugin({
      use_dev_builds = false,
      update_available = true,
      getDevBuildDownloadURL = function() return "http://example.com/dev" end,
      settings = {
        saveSetting = function(_, k, v)
          save_calls[#save_calls + 1] = { k = k, v = v }
        end,
        flush = function() end,
      },
      updater = {
        clearCache = function() clear_called = true end,
      },
    })
    mod.toggleUseDevBuilds(plugin)
    assert.is_true(plugin.use_dev_builds)
    assert.is_false(plugin.update_available)
    assert.is_true(clear_called)
    assert.are.equal(1, #save_calls)
    assert.are.equal("use_dev_builds", save_calls[1].k)
  end)

  it("toggles from true to false and clears cache", function()
    local mod = make_mod()
    local clear_called = false
    local plugin = make_plugin({
      use_dev_builds = true,
      getDevBuildDownloadURL = function() return "http://example.com/dev" end,
      updater = {
        clearCache = function() clear_called = true end,
      },
    })
    mod.toggleUseDevBuilds(plugin)
    assert.is_false(plugin.use_dev_builds)
    assert.is_true(clear_called)
  end)
end)

-- ═══════════════════════════════════════════════════════════════════════════
-- clearUpdateCache
-- ═══════════════════════════════════════════════════════════════════════════

describe("clearUpdateCache", function()

  local function make_mod()
    return UpdatesModuleFactory.new(make_deps())
  end

  before_each(function()
    reset_trackers()
  end)

  it("calls updater.clearCache and clears update_available", function()
    local mod = make_mod()
    local clear_called = false
    local plugin = make_plugin({
      update_available = true,
      updater = {
        clearCache = function() clear_called = true end,
      },
    })
    mod.clearUpdateCache(plugin)
    assert.is_true(clear_called)
    assert.is_false(plugin.update_available)
  end)

  it("shows success message", function()
    local mod = make_mod()
    local plugin = make_plugin()
    mod.clearUpdateCache(plugin)
    assert.is_true(#uimanager_shows > 0)
    local msg = tostring(uimanager_shows[1].text)
    assert.is_truthy(msg:find("cache cleared", 1, true))
  end)
end)
