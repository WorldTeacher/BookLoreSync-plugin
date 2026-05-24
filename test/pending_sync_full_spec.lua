-- Tests for booklore_pending_sync.lua (Pending Bookmarks, Deletions, Ratings, Annotations)
--
-- Factory module: M.new(deps) returns module table.
-- Covers syncPendingBookmarks, syncPendingDeletions, syncPendingRatings,
-- syncPendingAnnotations.
--
-- NOTE: syncPendingSessions (Phase 0-3 orchestrator) is tested via the
-- existing pending_sync_spec.lua and shelf_sync coverage; this file covers
-- the individual sub-sync functions with comprehensive branch coverage.

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
package.preload["device"]    = function()
  return { isAndroid = function() return false end, model = "KOReader-Test",
           home_dir = "/mnt/onboard" }
end
package.preload["luasettings"] = function()
  return { open = function() return { readSetting = function() return nil end, saveSetting = function() end, flush = function() end } end }
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

local scheduled_fns = {}
package.preload["ui/uimanager"] = function()
  return {
    scheduleIn     = function(_, _delay, fn)
      if fn then scheduled_fns[#scheduled_fns + 1] = fn end
    end,
    nextTick       = function(_, fn) if fn then fn() end end,
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

-- ── JSON decoder stub that actually parses simple JSON ─────────────────────

-- A minimal JSON decoder for test payloads.  Supports objects, arrays,
-- numbers, strings, and null.
local function make_json_stub()
  local function decode(input)
    local function err()
      error("invalid json in test: " .. tostring(input))
    end
    local pos = 1
    local function skip_space()
      while pos <= #input do
        local c = input:sub(pos, pos)
        if c == " " or c == "\t" or c == "\n" or c == "\r" then
          pos = pos + 1
        else
          break
        end
      end
    end
    local function parse_value()
      skip_space()
      if pos > #input then err() end
      local c = input:sub(pos, pos)
      if c == "{" then
        pos = pos + 1
        local obj = {}
        skip_space()
        if input:sub(pos, pos) == "}" then pos = pos + 1; return obj end
        while true do
          skip_space()
          if input:sub(pos, pos) ~= '"' then err() end
          local ks = pos + 1
          local ke = ks
          while ke <= #input and input:sub(ke, ke) ~= '"' do ke = ke + 1 end
          if ke > #input then err() end
          local key = input:sub(ks, ke - 1)
          pos = ke + 1
          skip_space()
          if input:sub(pos, pos) ~= ":" then err() end
          pos = pos + 1
          obj[key] = parse_value()
          skip_space()
          local nxt = input:sub(pos, pos)
          if nxt == "}" then pos = pos + 1; return obj end
          if nxt ~= "," then err() end
          pos = pos + 1
        end
      elseif c == "[" then
        pos = pos + 1
        local arr = {}
        skip_space()
        if input:sub(pos, pos) == "]" then pos = pos + 1; return arr end
        while true do
          arr[#arr + 1] = parse_value()
          skip_space()
          local nxt = input:sub(pos, pos)
          if nxt == "]" then pos = pos + 1; return arr end
          if nxt ~= "," then err() end
          pos = pos + 1
        end
      elseif c == '"' then
        pos = pos + 1
        local s = ""
        while pos <= #input do
          local cc = input:sub(pos, pos)
          if cc == '"' then pos = pos + 1; return s end
          if cc == "\\" then
            pos = pos + 1
            local esc = input:sub(pos, pos)
            if esc == '"' then s = s .. '"'
            elseif esc == "\\" then s = s .. "\\"
            elseif esc == "n" then s = s .. "\n"
            elseif esc == "t" then s = s .. "\t"
            else s = s .. esc
            end
          else
            s = s .. cc
          end
          pos = pos + 1
        end
        err()
      elseif c == "n" then
        if input:sub(pos, pos + 3) == "null" then pos = pos + 4; return nil end
        err()
      elseif c == "t" then
        if input:sub(pos, pos + 3) == "true" then pos = pos + 4; return true end
        err()
      elseif c == "f" then
        if input:sub(pos, pos + 4) == "false" then pos = pos + 5; return false end
        err()
      else
        local ns = pos
        while ns <= #input do
          local nc = input:sub(ns, ns)
          if nc >= "0" and nc <= "9" or nc == "-" or nc == "." or nc == "e" or nc == "E" or nc == "+" then
            ns = ns + 1
          else
            break
          end
        end
        if ns == pos then err() end
        local str = input:sub(pos, ns - 1)
        pos = ns
        return tonumber(str) or 0
      end
    end
    local result = parse_value()
    skip_space()
    return result
  end
  return {
    decode = decode,
    encode = function(t) return "{}" end,
    util = { InitArray = function(t) return t end },
  }
end

-- ── Load the module factory ─────────────────────────────────────────────────

local PendingSyncFactory = require("booklore_pending_sync")

local function run_scheduled()
  local pending = {}
  for _, fn in ipairs(scheduled_fns) do pending[#pending + 1] = fn end
  for i = #scheduled_fns, 1, -1 do scheduled_fns[i] = nil end
  for _, fn in ipairs(pending) do fn() end
end

local function reset_scheduled()
  for i = #scheduled_fns, 1, -1 do scheduled_fns[i] = nil end
end

-- ═══════════════════════════════════════════════════════════════════════════
-- syncPendingBookmarks
-- ═══════════════════════════════════════════════════════════════════════════

describe("syncPendingBookmarks", function()

  local function make_deps(custom_json)
    custom_json = custom_json or make_json_stub()
    return {
      _ = function(s) return s end,
      T = function(s) return s end,
      json = custom_json,
      UIManager = require("ui/uimanager"),
      InfoMessage = { new = function(_, o) return o or {} end },
      Device = require("device"),
    }
  end

  local function make_plugin(overrides)
    overrides = overrides or {}
    local p = {
      db = {
        getPendingBookmarks = function() return {} end,
        incrementBookmarkRetry = function() end,
        getBookIdByBookCacheId = function() return nil end,
        submitBookmark = function() return true, 1 end,
        markBookmarkSynced = function() end,
        deletePendingBookmark = function() end,
      },
      api = {
        init = function() end,
        submitBookmark = function() return true, 1 end,
      },
      booklore_username = "u",
      booklore_password = "p",
      logInfo = function() end,
      logWarn = function() end,
      logErr = function() end,
      logDbg = function() end,
    }
    for k, v in pairs(overrides) do p[k] = v end
    return p
  end

  before_each(function()
    reset_scheduled()
  end)

  it("returns 0,0 when no pending bookmarks exist", function()
    local mod = PendingSyncFactory.new(make_deps())
    local plugin = make_plugin()
    local synced, failed = mod.syncPendingBookmarks(plugin)
    assert.are.equal(0, synced)
    assert.are.equal(0, failed)
  end)

  it("returns 0,0 when pending is nil", function()
    local mod = PendingSyncFactory.new(make_deps())
    local plugin = make_plugin({ db = { getPendingBookmarks = function() return nil end } })
    local synced, failed = mod.syncPendingBookmarks(plugin)
    assert.are.equal(0, synced)
    assert.are.equal(0, failed)
  end)

  it("filters by book_cache_id when provided", function()
    local mod = PendingSyncFactory.new(make_deps())
    local submit_calls = {}
    local plugin = make_plugin({
      db = {
        getPendingBookmarks = function()
          return {
            { id = 1, book_cache_id = 10, book_id = 100, payload = '{"cfi":"/2","chapter":"ch1"}', datetime = "2024-01-01" },
            { id = 2, book_cache_id = 20, book_id = 200, payload = '{"cfi":"/3","chapter":"ch2"}', datetime = "2024-01-02" },
          }
        end,
        submitBookmark = function(_, bid, cfi, opts, u, p)
          submit_calls[#submit_calls + 1] = { bid = bid, cfi = cfi }
          return true, 42
        end,
        markBookmarkSynced = function() end,
        deletePendingBookmark = function() end,
        incrementBookmarkRetry = function() end,
      },
      api = {
        init = function() end,
        submitBookmark = function(_, bid, cfi, opts, u, p)
          submit_calls[#submit_calls + 1] = { bid = bid, cfi = cfi }
          return true, 42
        end,
      },
    })
    local synced, failed = mod.syncPendingBookmarks(plugin, true, 10)
    assert.are.equal(1, synced)
    assert.are.equal(0, failed)
    assert.are.equal(1, #submit_calls)
    assert.are.equal(100, submit_calls[1].bid)
  end)

  it("returns 0,0 when filter yields empty results", function()
    local mod = PendingSyncFactory.new(make_deps())
    local plugin = make_plugin({
      db = {
        getPendingBookmarks = function()
          return {
            { id = 1, book_cache_id = 10, book_id = 100, payload = "{}", datetime = "2024-01-01" },
          }
        end,
        incrementBookmarkRetry = function() end,
      },
    })
    local synced, failed = mod.syncPendingBookmarks(plugin, true, 99)
    assert.are.equal(0, synced)
    assert.are.equal(0, failed)
  end)

  it("handles decode errors (pcall failure) and increments retry", function()
    local mod = PendingSyncFactory.new(make_deps())
    local retry_calls = {}
    local plugin = make_plugin({
      db = {
        getPendingBookmarks = function()
          return {
            { id = 1, book_cache_id = 10, book_id = 100, payload = "invalid", datetime = "2024-01-01" },
          }
        end,
        incrementBookmarkRetry = function(_, row_id)
          retry_calls[#retry_calls + 1] = row_id
        end,
        getBookIdByBookCacheId = function() return nil end,
      },
    })
    local synced, failed = mod.syncPendingBookmarks(plugin)
    assert.are.equal(0, synced)
    assert.are.equal(1, failed)
    assert.are.equal(1, retry_calls[1])
  end)

  it("handles nil payload from decode and increments retry", function()
    local mod = PendingSyncFactory.new(make_deps())
    local retry_calls = {}
    local plugin = make_plugin({
      db = {
        getPendingBookmarks = function()
          return {
            { id = 1, book_cache_id = 10, book_id = 100, payload = "{}", datetime = "2024-01-01" },
          }
        end,
        incrementBookmarkRetry = function(_, row_id)
          retry_calls[#retry_calls + 1] = row_id
        end,
      },
    })
    -- Payload decode succeeds but payload.cfi is nil
    local synced, failed = mod.syncPendingBookmarks(plugin)
    assert.are.equal(0, synced)
    assert.are.equal(1, failed)
    assert.are.equal(1, #retry_calls)
  end)

  it("handles missing book_id by resolving from cache", function()
    local mod = PendingSyncFactory.new(make_deps())
    local plugin = make_plugin({
      db = {
        getPendingBookmarks = function()
          return {
            { id = 1, book_cache_id = 10, book_id = nil, payload = '{"cfi":"/2"}', datetime = "2024-01-01" },
          }
        end,
        getBookIdByBookCacheId = function(_, bc_id)
          if bc_id == 10 then return 100 end
          return nil
        end,
        submitBookmark = function() return true, 42 end,
        markBookmarkSynced = function() end,
        deletePendingBookmark = function() end,
        incrementBookmarkRetry = function() end,
      },
      api = {
        init = function() end,
        submitBookmark = function() return true, 42 end,
      },
    })
    local synced, failed = mod.syncPendingBookmarks(plugin)
    assert.are.equal(1, synced)
    assert.are.equal(0, failed)
  end)

  it("defers when book_id missing and cannot be resolved from cache", function()
    local mod = PendingSyncFactory.new(make_deps())
    local plugin = make_plugin({
      db = {
        getPendingBookmarks = function()
          return {
            { id = 1, book_cache_id = 10, book_id = nil, payload = '{"cfi":"/2"}', datetime = "2024-01-01" },
          }
        end,
        getBookIdByBookCacheId = function() return nil end,
        incrementBookmarkRetry = function() end,
      },
    })
    local synced, failed = mod.syncPendingBookmarks(plugin)
    assert.are.equal(0, synced)
    assert.are.equal(0, failed)
  end)

  it("submits bookmark and marks synced on success", function()
    local mod = PendingSyncFactory.new(make_deps())
    local mark_calls = {}
    local delete_calls = {}
    local plugin = make_plugin({
      db = {
        getPendingBookmarks = function()
          return {
            { id = 1, book_cache_id = 10, book_id = 100, payload = '{"cfi":"/2","chapter":"ch1"}', datetime = "2024-01-01" },
          }
        end,
        markBookmarkSynced = function(_, bc_id, dt, srv_id)
          mark_calls[#mark_calls + 1] = { bc_id = bc_id, dt = dt, srv_id = srv_id }
        end,
        deletePendingBookmark = function(_, row_id)
          delete_calls[#delete_calls + 1] = row_id
        end,
        incrementBookmarkRetry = function() end,
      },
      api = {
        init = function() end,
        submitBookmark = function() return true, 42 end,
      },
    })
    local synced, failed = mod.syncPendingBookmarks(plugin)
    assert.are.equal(1, synced)
    assert.are.equal(0, failed)
    assert.are.equal(1, #mark_calls)
    assert.are.equal(10, mark_calls[1].bc_id)
    assert.are.equal(42, mark_calls[1].srv_id)
    assert.are.equal(1, #delete_calls)
  end)

  it("handles 'already exists' response from server as success", function()
    local mod = PendingSyncFactory.new(make_deps())
    local mark_calls = {}
    local delete_calls = {}
    local plugin = make_plugin({
      db = {
        getPendingBookmarks = function()
          return {
            { id = 1, book_cache_id = 10, book_id = 100, payload = '{"cfi":"/2"}', datetime = "2024-01-01" },
          }
        end,
        markBookmarkSynced = function(_, bc_id, dt, srv_id)
          mark_calls[#mark_calls + 1] = { bc_id = bc_id, srv_id = srv_id }
        end,
        deletePendingBookmark = function(_, row_id)
          delete_calls[#delete_calls + 1] = row_id
        end,
        incrementBookmarkRetry = function() end,
      },
      api = {
        init = function() end,
        submitBookmark = function() return false, "Bookmark already exists" end,
      },
    })
    local synced, failed = mod.syncPendingBookmarks(plugin)
    assert.are.equal(1, synced)
    assert.are.equal(0, failed)
    assert.are.equal(1, #mark_calls)
    assert.is_nil(mark_calls[1].srv_id)
    assert.are.equal(1, #delete_calls)
  end)

  it("increments retry on generic API failure", function()
    local mod = PendingSyncFactory.new(make_deps())
    local retry_calls = {}
    local plugin = make_plugin({
      db = {
        getPendingBookmarks = function()
          return {
            { id = 1, book_cache_id = 10, book_id = 100, payload = '{"cfi":"/2"}', datetime = "2024-01-01" },
          }
        end,
        incrementBookmarkRetry = function(_, row_id)
          retry_calls[#retry_calls + 1] = row_id
        end,
      },
      api = {
        init = function() end,
        submitBookmark = function() return false, "server error" end,
      },
    })
    local synced, failed = mod.syncPendingBookmarks(plugin)
    assert.are.equal(0, synced)
    assert.are.equal(1, failed)
    assert.are.equal(1, #retry_calls)
  end)
end)

-- ═══════════════════════════════════════════════════════════════════════════
-- syncPendingDeletions
-- ═══════════════════════════════════════════════════════════════════════════

describe("syncPendingDeletions", function()

  local function make_deps()
    return {
      _ = function(s) return s end,
      T = function(s) return s end,
      json = make_json_stub(),
      UIManager = require("ui/uimanager"),
      InfoMessage = { new = function(_, o) return o or {} end },
      Device = require("device"),
    }
  end

  local function make_plugin(overrides)
    overrides = overrides or {}
    local p = {
      db = {
        getPendingDeletions = function() return {} end,
        removePendingDeletion = function() end,
        incrementDeletionRetry = function() end,
      },
      api = {
        init = function() end,
        getOrRefreshBearerToken = function() return true, "token-abc" end,
        getBookByHash = function() return true, { id = "42" } end,
        request = function() return true, 200, {} end,
      },
      booklore_username = "u",
      booklore_password = "p",
      booklore_source_shelf_id = "5",
      booklore_magic_shelf_id = nil,
      shelf_id = nil,
      logInfo = function() end,
      logWarn = function() end,
      logErr = function() end,
    }
    for k, v in pairs(overrides) do p[k] = v end
    return p
  end

  before_each(function()
    reset_scheduled()
  end)

  it("returns 0,0 when db is nil", function()
    local mod = PendingSyncFactory.new(make_deps())
    local plugin = make_plugin({ db = nil })
    local synced, failed = mod.syncPendingDeletions(plugin)
    assert.are.equal(0, synced)
    assert.are.equal(0, failed)
  end)

  it("returns 0,0 when no pending deletions exist", function()
    local mod = PendingSyncFactory.new(make_deps())
    local plugin = make_plugin()
    local synced, failed = mod.syncPendingDeletions(plugin)
    assert.are.equal(0, synced)
    assert.are.equal(0, failed)
  end)

  it("returns 0,0 when deletions is nil", function()
    local mod = PendingSyncFactory.new(make_deps())
    local plugin = make_plugin({ db = { getPendingDeletions = function() return nil end } })
    local synced, failed = mod.syncPendingDeletions(plugin)
    assert.are.equal(0, synced)
    assert.are.equal(0, failed)
  end)

  it("clears all deletions for magic-only config without API calls", function()
    local mod = PendingSyncFactory.new(make_deps())
    local remove_calls = {}
    local plugin = make_plugin({
      booklore_source_shelf_id = nil,
      shelf_id = nil,
      booklore_magic_shelf_id = 99,
      db = {
        getPendingDeletions = function()
          return { { id = 1, retry_count = 0 }, { id = 2, retry_count = 0 } }
        end,
        removePendingDeletion = function(_, del_id)
          remove_calls[#remove_calls + 1] = del_id
        end,
      },
    })
    local synced, failed = mod.syncPendingDeletions(plugin)
    assert.are.equal(2, synced)
    assert.are.equal(0, failed)
    assert.are.equal(2, #remove_calls)
  end)

  it("returns 0,0 for magic-only config with no deletions", function()
    local mod = PendingSyncFactory.new(make_deps())
    local plugin = make_plugin({
      booklore_source_shelf_id = nil,
      shelf_id = nil,
      booklore_magic_shelf_id = 99,
      db = {
        getPendingDeletions = function() return nil end,
      },
    })
    local synced, failed = mod.syncPendingDeletions(plugin)
    assert.are.equal(0, synced)
    assert.are.equal(0, failed)
  end)

  it("drops stale entries with retry_count > 10", function()
    local mod = PendingSyncFactory.new(make_deps())
    local remove_calls = {}
    local plugin = make_plugin({
      db = {
        getPendingDeletions = function()
          return {
            { id = 1, retry_count = 11, file_hash = "abc" },
            { id = 2, retry_count = 5, book_id = 42, file_hash = "def" },
          }
        end,
        removePendingDeletion = function(_, del_id)
          remove_calls[#remove_calls + 1] = del_id
        end,
        incrementDeletionRetry = function() end,
      },
    })
    local synced, failed = mod.syncPendingDeletions(plugin)
    -- Entry 1 is stale (removed), entry 2 succeeds via shelf unassign
    -- Both entries count: stale one is silently discarded (synced_count stays 0),
    -- but the code counts removing a stale entry as a sync. The second entry
    -- succeeds normally.
    assert.are.equal(1, synced)
    -- Entry 1 stale (retry>10) triggers removePendingDeletion, entry 2 also
    -- deletes from pending after processing
    assert.are.equal(0, failed)
    assert.are.equal(2, #remove_calls)
  end)

  it("resolves book_id via API by hash when no book_id", function()
    local mod = PendingSyncFactory.new(make_deps())
    local remove_calls = {}
    local plugin = make_plugin({
      db = {
        getPendingDeletions = function()
          return {
            { id = 1, retry_count = 0, book_id = nil, file_hash = "hash123" },
          }
        end,
        removePendingDeletion = function(_, del_id)
          remove_calls[#remove_calls + 1] = del_id
        end,
        incrementDeletionRetry = function() end,
      },
      api = {
        init = function() end,
        getOrRefreshBearerToken = function() return true, "token-abc" end,
        getBookByHash = function() return true, { id = "99" } end,
        request = function() return true, 200, {} end,
      },
    })
    local synced, failed = mod.syncPendingDeletions(plugin)
    assert.are.equal(1, synced)
    assert.are.equal(0, failed)
  end)

  it("discards when book_id cannot be resolved via hash API", function()
    local mod = PendingSyncFactory.new(make_deps())
    local remove_calls = {}
    local plugin = make_plugin({
      db = {
        getPendingDeletions = function()
          return {
            { id = 1, retry_count = 0, book_id = nil, file_hash = "hash123" },
          }
        end,
        removePendingDeletion = function(_, del_id)
          remove_calls[#remove_calls + 1] = del_id
        end,
        incrementDeletionRetry = function() end,
      },
      api = {
        init = function() end,
        getOrRefreshBearerToken = function() return true, "token-abc" end,
        getBookByHash = function() return false, nil end,
      },
    })
    -- book_id stays nil, discards silently
    local synced, failed = mod.syncPendingDeletions(plugin)
    assert.are.equal(1, synced)  -- discarded as success
    assert.are.equal(0, failed)
    assert.are.equal(1, #remove_calls)
  end)

  it("handles missing auth token by incrementing retry", function()
    local mod = PendingSyncFactory.new(make_deps())
    local retry_calls = {}
    local plugin = make_plugin({
      db = {
        getPendingDeletions = function()
          return {
            { id = 1, retry_count = 0, book_id = 42, file_hash = "hash123" },
          }
        end,
        incrementDeletionRetry = function(_, del_id)
          retry_calls[#retry_calls + 1] = del_id
        end,
        removePendingDeletion = function() end,
      },
      api = {
        init = function() end,
        getOrRefreshBearerToken = function() return false, "auth error" end,
      },
    })
    local synced, failed = mod.syncPendingDeletions(plugin)
    assert.are.equal(0, synced)
    assert.are.equal(1, failed)
    assert.are.equal(1, #retry_calls)
  end)

  it("handles missing shelf_id by incrementing retry", function()
    local mod = PendingSyncFactory.new(make_deps())
    local retry_calls = {}
    local plugin = make_plugin({
      db = {
        getPendingDeletions = function()
          return {
            { id = 1, retry_count = 0, book_id = 42, file_hash = "hash123" },
          }
        end,
        incrementDeletionRetry = function(_, del_id)
          retry_calls[#retry_calls + 1] = del_id
        end,
        removePendingDeletion = function() end,
      },
      api = {
        init = function() end,
        getOrRefreshBearerToken = function() return true, "token-abc" end,
      },
    })
    -- Explicitly nil out shelf_id fields (Lua constructor can't set nil)
    plugin.booklore_source_shelf_id = nil
    plugin.shelf_id = nil
    local synced, failed = mod.syncPendingDeletions(plugin)
    assert.are.equal(0, synced)
    assert.are.equal(1, failed)
    assert.are.equal(1, #retry_calls)
  end)

  it("succeeds on API request returning ok or code 200", function()
    local mod = PendingSyncFactory.new(make_deps())
    local remove_calls = {}
    local plugin = make_plugin({
      db = {
        getPendingDeletions = function()
          return {
            { id = 1, retry_count = 0, book_id = 42, file_hash = "hash123" },
          }
        end,
        removePendingDeletion = function(_, del_id)
          remove_calls[#remove_calls + 1] = del_id
        end,
        incrementDeletionRetry = function() end,
      },
      api = {
        init = function() end,
        getOrRefreshBearerToken = function() return true, "token-abc" end,
        request = function() return true, 200, {} end,
      },
    })
    local synced, failed = mod.syncPendingDeletions(plugin)
    assert.are.equal(1, synced)
    assert.are.equal(0, failed)
    assert.are.equal(1, #remove_calls)
  end)

  it("succeeds when code is 200 even if ok is false", function()
    local mod = PendingSyncFactory.new(make_deps())
    local remove_calls = {}
    local plugin = make_plugin({
      db = {
        getPendingDeletions = function()
          return {
            { id = 1, retry_count = 0, book_id = 42, file_hash = "hash123" },
          }
        end,
        removePendingDeletion = function(_, del_id)
          remove_calls[#remove_calls + 1] = del_id
        end,
        incrementDeletionRetry = function() end,
      },
      api = {
        init = function() end,
        getOrRefreshBearerToken = function() return true, "token-abc" end,
        request = function() return false, 200, {} end,
      },
    })
    local synced, failed = mod.syncPendingDeletions(plugin)
    assert.are.equal(1, synced)
    assert.are.equal(0, failed)
  end)

  it("increments retry on API failure", function()
    local mod = PendingSyncFactory.new(make_deps())
    local retry_calls = {}
    local plugin = make_plugin({
      db = {
        getPendingDeletions = function()
          return {
            { id = 1, retry_count = 0, book_id = 42, file_hash = "hash123" },
          }
        end,
        incrementDeletionRetry = function(_, del_id)
          retry_calls[#retry_calls + 1] = del_id
        end,
        removePendingDeletion = function() end,
      },
      api = {
        init = function() end,
        getOrRefreshBearerToken = function() return true, "token-abc" end,
        request = function() return false, 500, "error" end,
      },
    })
    local synced, failed = mod.syncPendingDeletions(plugin)
    assert.are.equal(0, synced)
    assert.are.equal(1, failed)
    assert.are.equal(1, #retry_calls)
  end)
end)

-- ═══════════════════════════════════════════════════════════════════════════
-- syncPendingRatings
-- ═══════════════════════════════════════════════════════════════════════════

describe("syncPendingRatings", function()

  local function make_deps()
    return {
      _ = function(s) return s end,
      T = function(s) return s end,
      json = make_json_stub(),
      UIManager = require("ui/uimanager"),
      InfoMessage = { new = function(_, o) return o or {} end },
      Device = require("device"),
    }
  end

  local function make_plugin(overrides)
    overrides = overrides or {}
    local p = {
      db = {
        getBooksPendingRatingPrompt = function() return {} end,
        getPendingRatings = function() return {} end,
        setPendingRatingPrompt = function() end,
        addPendingRating = function() end,
        getBookCacheById = function() return nil end,
        getBookMetadata = function() return nil end,
        isBookTrackingEnabled = function() return true end,
        upsertBookMetadata = function() end,
        recordRatingSyncHistory = function() end,
        deletePendingRating = function() end,
        incrementPendingRatingRetryCount = function() end,
      },
      api = {
        submitRating = function() return true end,
        init = function() end,
      },
      rating_sync_enabled = true,
      rating_sync_mode = "koreader_scaled",
      show_post_rating_recommendations = true,
      booklore_username = "u",
      booklore_password = "p",
      server_url = "http://localhost:8080",
      username = "u",
      password = "p",
      logInfo = function() end,
      logWarn = function() end,
      logErr = function() end,
      logDbg = function() end,
      refreshEffectiveServerUrl = function() end,
      syncKOReaderRating = function() end,
      scheduleRecommendationsAfterFinish = function() end,
    }
    for k, v in pairs(overrides) do p[k] = v end
    return p
  end

  before_each(function()
    reset_scheduled()
  end)

  it("returns 0,0 when db is nil", function()
    local mod = PendingSyncFactory.new(make_deps())
    local plugin = make_plugin({ db = nil })
    local synced, failed = mod.syncPendingRatings(plugin)
    assert.are.equal(0, synced)
    assert.are.equal(0, failed)
  end)

  it("returns 0,0 when rating_sync_enabled is false", function()
    local mod = PendingSyncFactory.new(make_deps())
    local plugin = make_plugin({ rating_sync_enabled = false })
    local synced, failed = mod.syncPendingRatings(plugin)
    assert.are.equal(0, synced)
    assert.are.equal(0, failed)
  end)

  it("returns 0,0 when no pending ratings and no deferred prompts", function()
    local mod = PendingSyncFactory.new(make_deps())
    local plugin = make_plugin()
    local synced, failed = mod.syncPendingRatings(plugin)
    assert.are.equal(0, synced)
    assert.are.equal(0, failed)
  end)

  describe("deferred rating prompts - koreader_scaled mode", function()

    it("syncs KOReader rating for deferred prompt with credentials", function()
      local mod = PendingSyncFactory.new(make_deps())
      local sync_calls = {}
      local schedule_calls = {}
      local clear_calls = {}
      local plugin = make_plugin({
        db = {
          getBooksPendingRatingPrompt = function()
            return {
              { book_cache_id = 1, book_id = 42, file_path = "/b.epub" },
            }
          end,
          getPendingRatings = function() return {} end,
          setPendingRatingPrompt = function(_, bc_id, flag)
            clear_calls[#clear_calls + 1] = { bc_id = bc_id, flag = flag }
          end,
        },
        syncKOReaderRating = function(_, fp, bid)
          sync_calls[#sync_calls + 1] = { fp = fp, bid = bid }
        end,
        scheduleRecommendationsAfterFinish = function(_, bid)
          schedule_calls[#schedule_calls + 1] = bid
        end,
      })
      local synced, failed = mod.syncPendingRatings(plugin)
      assert.are.equal(0, synced)
      assert.are.equal(0, failed)
      assert.are.equal(1, #sync_calls)
      assert.are.equal(42, sync_calls[1].bid)
      assert.are.equal(1, #clear_calls)
      assert.are.equal(42, schedule_calls[1])
    end)

    it("skips deferred KOReader rating sync when no credentials configured", function()
      local mod = PendingSyncFactory.new(make_deps())
      local sync_calls = {}
      local plugin = make_plugin({
        booklore_username = "",
        booklore_password = "",
        db = {
          getBooksPendingRatingPrompt = function()
            return {
              { book_cache_id = 1, book_id = 42, file_path = "/b.epub" },
            }
          end,
          getPendingRatings = function() return {} end,
          setPendingRatingPrompt = function() end,
        },
        syncKOReaderRating = function()
          sync_calls[#sync_calls + 1] = true
        end,
      })
      local synced, failed = mod.syncPendingRatings(plugin)
      assert.are.equal(0, synced)
      assert.are.equal(0, failed)
      -- syncKOReaderRating should NOT be called because credentials are empty
      assert.are.equal(0, #sync_calls)
    end)

    it("handles scheduleRecommendationsAfterFinish error gracefully", function()
      local mod = PendingSyncFactory.new(make_deps())
      local warned = false
      local plugin = make_plugin({
        db = {
          getBooksPendingRatingPrompt = function()
            return {
              { book_cache_id = 1, book_id = 42, file_path = "/b.epub" },
            }
          end,
          getPendingRatings = function() return {} end,
          setPendingRatingPrompt = function() end,
        },
        syncKOReaderRating = function() end,
        scheduleRecommendationsAfterFinish = function()
          error("rec failure")
        end,
        logWarn = function(_, msg)
          if tostring(msg):find("Failed to schedule deferred recommendations", 1, true) then
            warned = true
          end
        end,
      })
      local synced, failed = mod.syncPendingRatings(plugin)
      assert.are.equal(0, synced)
      assert.are.equal(0, failed)
      assert.is_true(warned)
    end)

    it("does not schedule recommendations when toggle is disabled", function()
      local mod = PendingSyncFactory.new(make_deps())
      local scheduled = false
      local plugin = make_plugin({
        show_post_rating_recommendations = false,
        db = {
          getBooksPendingRatingPrompt = function()
            return {
              { book_cache_id = 1, book_id = 42, file_path = "/b.epub" },
            }
          end,
          getPendingRatings = function() return {} end,
          setPendingRatingPrompt = function() end,
        },
        syncKOReaderRating = function() end,
        scheduleRecommendationsAfterFinish = function()
          scheduled = true
        end,
      })
      local synced, failed = mod.syncPendingRatings(plugin)
      assert.are.equal(0, synced)
      assert.are.equal(0, failed)
      assert.is_false(scheduled)
    end)
  end)

  describe("deferred rating prompts - select_at_complete mode", function()

    it("stamps book_id when rating metadata already captured", function()
      local mod = PendingSyncFactory.new(make_deps())
      local add_calls = {}
      local clear_calls = {}
      local schedule_calls = {}
      local plugin = make_plugin({
        rating_sync_mode = "select_at_complete",
        db = {
          getBooksPendingRatingPrompt = function()
            return {
              { book_cache_id = 1, book_id = 42, file_path = "/b.epub" },
            }
          end,
          getPendingRatings = function() return {} end,
          getBookMetadata = function() return { rating = 4 } end,
          addPendingRating = function(_, bc_id, bid, rating)
            add_calls[#add_calls + 1] = { bc_id = bc_id, bid = bid, rating = rating }
          end,
          setPendingRatingPrompt = function(_, bc_id, flag)
            clear_calls[#clear_calls + 1] = { bc_id = bc_id, flag = flag }
          end,
        },
        scheduleRecommendationsAfterFinish = function(_, bid)
          schedule_calls[#schedule_calls + 1] = bid
        end,
      })
      local synced, failed = mod.syncPendingRatings(plugin)
      assert.are.equal(0, synced)
      assert.are.equal(0, failed)
      assert.are.equal(1, #add_calls)
      assert.are.equal(1, #clear_calls)
      assert.are.equal(42, schedule_calls[1])
    end)

    it("schedules showRatingDialog when no rating metadata exists", function()
      local mod = PendingSyncFactory.new(make_deps())
      local scheduled_fns_before = #scheduled_fns
      local plugin = make_plugin({
        rating_sync_mode = "select_at_complete",
        db = {
          getBooksPendingRatingPrompt = function()
            return {
              { book_cache_id = 1, book_id = 42, file_path = "/b.epub" },
            }
          end,
          getPendingRatings = function() return {} end,
          getBookMetadata = function() return nil end,
          setPendingRatingPrompt = function() end,
        },
        showRatingDialog = function() end,
        scheduleRecommendationsAfterFinish = function() end,
      })
      local synced, failed = mod.syncPendingRatings(plugin)
      assert.are.equal(0, synced)
      assert.are.equal(0, failed)
      -- scheduleIn should have been called (we track it via scheduled_fns)
      assert.is_true(#scheduled_fns > scheduled_fns_before)
    end)
  end)

  describe("Phase 2 - retry pending ratings", function()

    it("skips rating when tracking disabled for book", function()
      local mod = PendingSyncFactory.new(make_deps())
      local plugin = make_plugin({
        db = {
          getBooksPendingRatingPrompt = function() return {} end,
          getPendingRatings = function()
            return {
              { id = 1, book_cache_id = 10, book_id = 100, rating = 4, retry_count = 0 },
            }
          end,
          getBookCacheById = function()
            return { file_path = "/b.epub" }
          end,
          isBookTrackingEnabled = function() return false end,
        },
      })
      local synced, failed = mod.syncPendingRatings(plugin)
      assert.are.equal(0, synced)
      assert.are.equal(0, failed)
    end)

    it("resolves book_id from cache when row has nil book_id", function()
      local mod = PendingSyncFactory.new(make_deps())
      local plugin = make_plugin({
        db = {
          getBooksPendingRatingPrompt = function() return {} end,
          getPendingRatings = function()
            return {
              { id = 1, book_cache_id = 10, book_id = nil, rating = 4, retry_count = 0 },
            }
          end,
          getBookCacheById = function(_, bc_id)
            if bc_id == 10 then return { book_id = 200 } end
            return nil
          end,
          upsertBookMetadata = function() end,
          recordRatingSyncHistory = function() end,
          deletePendingRating = function() end,
          incrementPendingRatingRetryCount = function() end,
          isBookTrackingEnabled = function() return true end,
        },
        api = {
          init = function() end,
          submitRating = function() return true end,
        },
      })
      local synced, failed = mod.syncPendingRatings(plugin)
      assert.are.equal(1, synced)
      assert.are.equal(0, failed)
    end)

    it("defers when book_id cannot be resolved", function()
      local mod = PendingSyncFactory.new(make_deps())
      local plugin = make_plugin({
        db = {
          getBooksPendingRatingPrompt = function() return {} end,
          getPendingRatings = function()
            return {
              { id = 1, book_cache_id = 10, book_id = nil, rating = 4, retry_count = 0 },
            }
          end,
          getBookCacheById = function() return nil end,
        },
      })
      local synced, failed = mod.syncPendingRatings(plugin)
      assert.are.equal(0, synced)
      assert.are.equal(0, failed)
    end)

    it("submits rating and records success", function()
      local mod = PendingSyncFactory.new(make_deps())
      local upsert_calls = {}
      local record_calls = {}
      local delete_calls = {}
      local plugin = make_plugin({
        db = {
          getBooksPendingRatingPrompt = function() return {} end,
          getPendingRatings = function()
            return {
              { id = 1, book_cache_id = 10, book_id = 100, rating = 4, retry_count = 0 },
            }
          end,
          getBookCacheById = function() return nil end,
          isBookTrackingEnabled = function() return true end,
          upsertBookMetadata = function(_, bc_id, data)
            upsert_calls[#upsert_calls + 1] = { bc_id = bc_id, data = data }
          end,
          recordRatingSyncHistory = function(_, bc_id, rating, status)
            record_calls[#record_calls + 1] = { bc_id = bc_id, rating = rating, status = status }
          end,
          deletePendingRating = function(_, row_id)
            delete_calls[#delete_calls + 1] = row_id
          end,
          incrementPendingRatingRetryCount = function() end,
        },
        api = {
          init = function() end,
          submitRating = function() return true end,
        },
      })
      local synced, failed = mod.syncPendingRatings(plugin)
      assert.are.equal(1, synced)
      assert.are.equal(0, failed)
      assert.are.equal(1, #upsert_calls)
      assert.are.equal(1, #record_calls)
      assert.are.equal("success", record_calls[1].status)
      assert.are.equal(1, #delete_calls)
    end)

    it("increments retry on submit failure and records error history", function()
      local mod = PendingSyncFactory.new(make_deps())
      local record_calls = {}
      local retry_calls = {}
      local plugin = make_plugin({
        db = {
          getBooksPendingRatingPrompt = function() return {} end,
          getPendingRatings = function()
            return {
              { id = 1, book_cache_id = 10, book_id = 100, rating = 4, retry_count = 0 },
            }
          end,
          getBookCacheById = function() return nil end,
          isBookTrackingEnabled = function() return true end,
          upsertBookMetadata = function() end,
          recordRatingSyncHistory = function(_, bc_id, rating, status, err)
            record_calls[#record_calls + 1] = { bc_id = bc_id, rating = rating, status = status, err = err }
          end,
          deletePendingRating = function() end,
          incrementPendingRatingRetryCount = function(_, row_id)
            retry_calls[#retry_calls + 1] = row_id
          end,
        },
        api = {
          init = function() end,
          submitRating = function() return false, "server error" end,
        },
      })
      local synced, failed = mod.syncPendingRatings(plugin)
      assert.are.equal(0, synced)
      assert.are.equal(1, failed)
      assert.are.equal(1, #record_calls)
      assert.are.equal("error", record_calls[1].status)
      assert.are.equal(1, #retry_calls)
    end)
  end)
end)

-- ═══════════════════════════════════════════════════════════════════════════
-- syncPendingAnnotations
-- ═══════════════════════════════════════════════════════════════════════════

describe("syncPendingAnnotations", function()

  local function make_deps()
    return {
      _ = function(s) return s end,
      T = function(s) return s end,
      json = make_json_stub(),
      UIManager = require("ui/uimanager"),
      InfoMessage = { new = function(_, o) return o or {} end },
      Device = require("device"),
    }
  end

  local function make_plugin(overrides)
    overrides = overrides or {}
    local p = {
      db = {
        getPendingAnnotations = function() return {} end,
        getBookCacheById = function() return nil end,
        isBookTrackingEnabled = function() return true end,
        deletePendingAnnotation = function() end,
        markAnnotationSynced = function() end,
        incrementPendingAnnotationRetryCount = function() end,
      },
      api = {
        init = function() end,
        submitHighlight = function() return true, 1 end,
        submitInBookNote = function() return true, 1 end,
        submitBookloreNote = function() return true, 1 end,
      },
      highlights_notes_sync_enabled = true,
      booklore_username = "u",
      booklore_password = "p",
      server_url = "http://localhost:8080",
      username = "u",
      password = "p",
      logInfo = function() end,
      logWarn = function() end,
      logErr = function() end,
      logDbg = function() end,
      refreshEffectiveServerUrl = function() end,
    }
    for k, v in pairs(overrides) do p[k] = v end
    return p
  end

  before_each(function()
    reset_scheduled()
  end)

  it("returns 0,0,0 when db is nil", function()
    local mod = PendingSyncFactory.new(make_deps())
    local plugin = make_plugin({ db = nil })
    local synced, failed, skipped = mod.syncPendingAnnotations(plugin)
    assert.are.equal(0, synced or 0)
    assert.are.equal(0, failed or 0)
    assert.are.equal(0, skipped or 0)
  end)

  it("returns 0,0,0 when highlights_notes_sync_enabled is false", function()
    local mod = PendingSyncFactory.new(make_deps())
    local plugin = make_plugin({ highlights_notes_sync_enabled = false })
    local synced, failed, skipped = mod.syncPendingAnnotations(plugin)
    assert.are.equal(0, synced or 0)
    assert.are.equal(0, failed or 0)
    assert.are.equal(0, skipped or 0)
  end)

  it("returns 0,0,0 when credentials are empty", function()
    local mod = PendingSyncFactory.new(make_deps())
    local plugin = make_plugin({ booklore_username = "", booklore_password = "" })
    local synced, failed, skipped = mod.syncPendingAnnotations(plugin)
    assert.are.equal(0, synced or 0)
    assert.are.equal(0, failed or 0)
    assert.are.equal(0, skipped or 0)
  end)

  it("returns 0,0,0 when no pending annotations exist", function()
    local mod = PendingSyncFactory.new(make_deps())
    local plugin = make_plugin()
    local synced, failed, skipped = mod.syncPendingAnnotations(plugin)
    assert.are.equal(0, synced or 0)
    assert.are.equal(0, failed or 0)
    assert.are.equal(0, skipped or 0)
  end)

  it("filters by book_cache_id when provided", function()
    local mod = PendingSyncFactory.new(make_deps())
    local plugin = make_plugin({
      db = {
        getPendingAnnotations = function()
          return {
            { id = 1, book_cache_id = 10, book_id = 100, ann_type = "highlight", payload = '{"cfi":"/2","text":"hi"}', datetime = "2024-01-01", retry_count = 0 },
            { id = 2, book_cache_id = 20, book_id = 200, ann_type = "highlight", payload = '{"cfi":"/3","text":"ho"}', datetime = "2024-01-02", retry_count = 0 },
          }
        end,
        getBookCacheById = function() return nil end,
        isBookTrackingEnabled = function() return true end,
        deletePendingAnnotation = function() end,
        markAnnotationSynced = function() end,
        incrementPendingAnnotationRetryCount = function() end,
      },
      api = {
        init = function() end,
        submitHighlight = function() return true, 1 end,
      },
    })
    local synced, failed, skipped = mod.syncPendingAnnotations(plugin, nil, 10)
    assert.are.equal(1, synced)
    assert.are.equal(0, failed)
    assert.are.equal(0, skipped)
  end)

  it("skips annotation when tracking disabled for book", function()
    local mod = PendingSyncFactory.new(make_deps())
    local plugin = make_plugin({
      db = {
        getPendingAnnotations = function()
          return {
            { id = 1, book_cache_id = 10, book_id = 100, ann_type = "highlight", payload = '{"cfi":"/2","text":"hi"}', datetime = "2024-01-01", retry_count = 0 },
          }
        end,
        getBookCacheById = function() return { file_path = "/b.epub" } end,
        isBookTrackingEnabled = function() return false end,
        deletePendingAnnotation = function() end,
        markAnnotationSynced = function() end,
        incrementPendingAnnotationRetryCount = function() end,
      },
    })
    local synced, failed, skipped = mod.syncPendingAnnotations(plugin)
    assert.are.equal(0, synced)
    assert.are.equal(0, failed)
    assert.are.equal(1, skipped)
  end)

  it("removes annotation when payload decode fails", function()
    local mod = PendingSyncFactory.new(make_deps())
    local delete_calls = {}
    local plugin = make_plugin({
      db = {
        getPendingAnnotations = function()
          return {
            { id = 1, book_cache_id = 10, book_id = 100, ann_type = "highlight", payload = "invalid", datetime = "2024-01-01", retry_count = 0 },
          }
        end,
        getBookCacheById = function() return nil end,
        isBookTrackingEnabled = function() return true end,
        deletePendingAnnotation = function(_, row_id)
          delete_calls[#delete_calls + 1] = row_id
        end,
        markAnnotationSynced = function() end,
        incrementPendingAnnotationRetryCount = function() end,
      },
    })
    local synced, failed, skipped = mod.syncPendingAnnotations(plugin)
    assert.are.equal(0, synced)
    assert.are.equal(0, failed)
    assert.are.equal(0, skipped)
    assert.are.equal(1, #delete_calls)
  end)

  it("defers when book_id unknown and cannot be resolved", function()
    local mod = PendingSyncFactory.new(make_deps())
    local plugin = make_plugin({
      db = {
        getPendingAnnotations = function()
          return {
            { id = 1, book_cache_id = 10, book_id = nil, ann_type = "highlight", payload = '{"cfi":"/2","text":"hi"}', datetime = "2024-01-01", retry_count = 0 },
          }
        end,
        getBookCacheById = function() return nil end,
        isBookTrackingEnabled = function() return true end,
        deletePendingAnnotation = function() end,
        markAnnotationSynced = function() end,
        incrementPendingAnnotationRetryCount = function() end,
      },
    })
    local synced, failed, skipped = mod.syncPendingAnnotations(plugin)
    assert.are.equal(0, synced)
    assert.are.equal(0, failed)
    assert.are.equal(1, skipped)
  end)

  it("resolves book_id from cache and proceeds", function()
    local mod = PendingSyncFactory.new(make_deps())
    local plugin = make_plugin({
      db = {
        getPendingAnnotations = function()
          return {
            { id = 1, book_cache_id = 10, book_id = nil, ann_type = "highlight", payload = '{"cfi":"/2","text":"hi"}', datetime = "2024-01-01", retry_count = 0 },
          }
        end,
        getBookCacheById = function(_, bc_id)
          if bc_id == 10 then return { book_id = 200 } end
          return nil
        end,
        isBookTrackingEnabled = function() return true end,
        deletePendingAnnotation = function() end,
        markAnnotationSynced = function() end,
        incrementPendingAnnotationRetryCount = function() end,
      },
      api = {
        init = function() end,
        submitHighlight = function() return true, 1 end,
      },
    })
    local synced, failed, skipped = mod.syncPendingAnnotations(plugin)
    assert.are.equal(1, synced)
    assert.are.equal(0, failed)
    assert.are.equal(0, skipped)
  end)

  -- ── Annotation types ──────────────────────────────────────────────────

  describe("highlight type", function()
    it("submits highlight with CFI successfully", function()
      local mod = PendingSyncFactory.new(make_deps())
      local submit_calls = {}
      local mark_calls = {}
      local plugin = make_plugin({
        db = {
          getPendingAnnotations = function()
            return {
              { id = 1, book_cache_id = 10, book_id = 100, ann_type = "highlight", payload = '{"cfi":"/2","text":"highlighted text","color":"yellow","style":"solid","chapter":"ch1"}', datetime = "2024-01-01", retry_count = 0 },
            }
          end,
          getBookCacheById = function() return nil end,
          isBookTrackingEnabled = function() return true end,
          deletePendingAnnotation = function() end,
          markAnnotationSynced = function(_, bc_id, dt, at, sid)
            mark_calls[#mark_calls + 1] = { bc_id = bc_id, at = at, sid = sid }
          end,
          incrementPendingAnnotationRetryCount = function() end,
        },
        api = {
          init = function() end,
          submitHighlight = function(_, bid, cfi, text, opts)
            submit_calls[#submit_calls + 1] = { bid = bid, cfi = cfi, text = text, opts = opts }
            return true, 42
          end,
        },
      })
      local synced, failed, skipped = mod.syncPendingAnnotations(plugin)
      assert.are.equal(1, synced)
      assert.are.equal(0, failed)
      assert.are.equal(0, skipped)
      assert.are.equal(1, #submit_calls)
      assert.are.equal(100, submit_calls[1].bid)
      assert.are.equal("/2", submit_calls[1].cfi)
      assert.are.equal(1, #mark_calls)
      assert.are.equal(42, mark_calls[1].sid)
    end)

    it("skips highlight when CFI is empty string", function()
      local mod = PendingSyncFactory.new(make_deps())
      local plugin = make_plugin({
        db = {
          getPendingAnnotations = function()
            return {
              { id = 1, book_cache_id = 10, book_id = 100, ann_type = "highlight", payload = '{"cfi":"","text":"hi"}', datetime = "2024-01-01", retry_count = 0 },
            }
          end,
          getBookCacheById = function() return nil end,
          isBookTrackingEnabled = function() return true end,
          deletePendingAnnotation = function() end,
          markAnnotationSynced = function() end,
          incrementPendingAnnotationRetryCount = function() end,
        },
      })
      local synced, failed, skipped = mod.syncPendingAnnotations(plugin)
      assert.are.equal(0, synced)
      assert.are.equal(0, failed)
      assert.are.equal(1, skipped)
    end)

    it("skips highlight when CFI is nil", function()
      local mod = PendingSyncFactory.new(make_deps())
      local plugin = make_plugin({
        db = {
          getPendingAnnotations = function()
            return {
              { id = 1, book_cache_id = 10, book_id = 100, ann_type = "highlight", payload = '{}', datetime = "2024-01-01", retry_count = 0 },
            }
          end,
          getBookCacheById = function() return nil end,
          isBookTrackingEnabled = function() return true end,
          deletePendingAnnotation = function() end,
          markAnnotationSynced = function() end,
          incrementPendingAnnotationRetryCount = function() end,
        },
      })
      local synced, failed, skipped = mod.syncPendingAnnotations(plugin)
      assert.are.equal(0, synced)
      assert.are.equal(0, failed)
      assert.are.equal(1, skipped)
    end)
  end)

  describe("in_book_note type", function()
    it("submits in-book note with CFI", function()
      local mod = PendingSyncFactory.new(make_deps())
      local submit_calls = {}
      local plugin = make_plugin({
        db = {
          getPendingAnnotations = function()
            return {
              { id = 1, book_cache_id = 10, book_id = 100, ann_type = "in_book_note", payload = '{"cfi":"/4","note":"my note","text":"selected","color":"blue","chapter":"ch2"}', datetime = "2024-01-01", retry_count = 0 },
            }
          end,
          getBookCacheById = function() return nil end,
          isBookTrackingEnabled = function() return true end,
          deletePendingAnnotation = function() end,
          markAnnotationSynced = function() end,
          incrementPendingAnnotationRetryCount = function() end,
        },
        api = {
          init = function() end,
          submitInBookNote = function(_, bid, cfi, note, opts)
            submit_calls[#submit_calls + 1] = { bid = bid, cfi = cfi, note = note, opts = opts }
            return true, 50
          end,
        },
      })
      local synced, failed, skipped = mod.syncPendingAnnotations(plugin)
      assert.are.equal(1, synced)
      assert.are.equal(0, failed)
      assert.are.equal(0, skipped)
      assert.are.equal(1, #submit_calls)
      assert.are.equal("/4", submit_calls[1].cfi)
    end)

    it("skips in-book note when CFI is empty", function()
      local mod = PendingSyncFactory.new(make_deps())
      local plugin = make_plugin({
        db = {
          getPendingAnnotations = function()
            return {
              { id = 1, book_cache_id = 10, book_id = 100, ann_type = "in_book_note", payload = '{"cfi":"","note":"x"}', datetime = "2024-01-01", retry_count = 0 },
            }
          end,
          getBookCacheById = function() return nil end,
          isBookTrackingEnabled = function() return true end,
          deletePendingAnnotation = function() end,
          markAnnotationSynced = function() end,
          incrementPendingAnnotationRetryCount = function() end,
        },
      })
      local synced, failed, skipped = mod.syncPendingAnnotations(plugin)
      assert.are.equal(0, synced)
      assert.are.equal(0, failed)
      assert.are.equal(1, skipped)
    end)
  end)

  describe("booklore_note type", function()
    it("submits Booklore note without CFI", function()
      local mod = PendingSyncFactory.new(make_deps())
      local submit_calls = {}
      local plugin = make_plugin({
        db = {
          getPendingAnnotations = function()
            return {
              { id = 1, book_cache_id = 10, book_id = 100, ann_type = "booklore_note", payload = '{"note":"web note","chapter":"ch3"}', datetime = "2024-01-01", retry_count = 0 },
            }
          end,
          getBookCacheById = function() return nil end,
          isBookTrackingEnabled = function() return true end,
          deletePendingAnnotation = function() end,
          markAnnotationSynced = function() end,
          incrementPendingAnnotationRetryCount = function() end,
        },
        api = {
          init = function() end,
          submitBookloreNote = function(_, bid, note, chapter)
            submit_calls[#submit_calls + 1] = { bid = bid, note = note, chapter = chapter }
            return true, 60
          end,
        },
      })
      local synced, failed, skipped = mod.syncPendingAnnotations(plugin)
      assert.are.equal(1, synced)
      assert.are.equal(0, failed)
      assert.are.equal(0, skipped)
      assert.are.equal(1, #submit_calls)
    end)
  end)

  describe("both_note type", function()
    it("submits both in-book and Booklore notes when CFI present", function()
      local mod = PendingSyncFactory.new(make_deps())
      local in_book_calls = {}
      local bl_calls = {}
      local plugin = make_plugin({
        db = {
          getPendingAnnotations = function()
            return {
              { id = 1, book_cache_id = 10, book_id = 100, ann_type = "both_note", payload = '{"cfi":"/5","note":"both","text":"sel","color":"red","chapter":"ch4"}', datetime = "2024-01-01", retry_count = 0 },
            }
          end,
          getBookCacheById = function() return nil end,
          isBookTrackingEnabled = function() return true end,
          deletePendingAnnotation = function() end,
          markAnnotationSynced = function() end,
          incrementPendingAnnotationRetryCount = function() end,
        },
        api = {
          init = function() end,
          submitInBookNote = function(_, bid, cfi, note, opts)
            in_book_calls[#in_book_calls + 1] = { bid = bid, cfi = cfi, note = note }
            return true, 70
          end,
          submitBookloreNote = function(_, bid, note, chapter)
            bl_calls[#bl_calls + 1] = { bid = bid, note = note, chapter = chapter }
            return true, 71
          end,
        },
      })
      local synced, failed, skipped = mod.syncPendingAnnotations(plugin)
      assert.are.equal(1, synced)
      assert.are.equal(0, failed)
      assert.are.equal(0, skipped)
      assert.are.equal(1, #in_book_calls)
      assert.are.equal(1, #bl_calls)
    end)

    it("submits only Booklore note when CFI missing for both_note", function()
      local mod = PendingSyncFactory.new(make_deps())
      local in_book_calls = {}
      local bl_calls = {}
      local plugin = make_plugin({
        db = {
          getPendingAnnotations = function()
            return {
              { id = 1, book_cache_id = 10, book_id = 100, ann_type = "both_note", payload = '{"note":"web only","chapter":"ch5"}', datetime = "2024-01-01", retry_count = 0 },
            }
          end,
          getBookCacheById = function() return nil end,
          isBookTrackingEnabled = function() return true end,
          deletePendingAnnotation = function() end,
          markAnnotationSynced = function() end,
          incrementPendingAnnotationRetryCount = function() end,
        },
        api = {
          init = function() end,
          submitInBookNote = function()
            in_book_calls[#in_book_calls + 1] = true
            return true, 70
          end,
          submitBookloreNote = function()
            bl_calls[#bl_calls + 1] = true
            return true, 71
          end,
        },
      })
      local synced, failed, skipped = mod.syncPendingAnnotations(plugin)
      assert.are.equal(1, synced)
      assert.are.equal(0, failed)
      assert.are.equal(0, skipped)
      assert.are.equal(0, #in_book_calls)
      assert.are.equal(1, #bl_calls)
    end)

    it("fails both_note when in-book passes but Booklore note fails", function()
      local mod = PendingSyncFactory.new(make_deps())
      local plugin = make_plugin({
        db = {
          getPendingAnnotations = function()
            return {
              { id = 1, book_cache_id = 10, book_id = 100, ann_type = "both_note", payload = '{"cfi":"/5","note":"both","chapter":"ch4"}', datetime = "2024-01-01", retry_count = 0 },
            }
          end,
          getBookCacheById = function() return nil end,
          isBookTrackingEnabled = function() return true end,
          deletePendingAnnotation = function() end,
          markAnnotationSynced = function() end,
          incrementPendingAnnotationRetryCount = function() end,
        },
        api = {
          init = function() end,
          submitInBookNote = function() return true, 70 end,
          submitBookloreNote = function() return false, "bl failed" end,
        },
      })
      local synced, failed, skipped = mod.syncPendingAnnotations(plugin)
      assert.are.equal(0, synced)
      assert.are.equal(1, failed)
      assert.are.equal(0, skipped)
    end)
  end)

  describe("unknown ann_type", function()
    it("removes annotation with unknown type", function()
      local mod = PendingSyncFactory.new(make_deps())
      local delete_calls = {}
      local plugin = make_plugin({
        db = {
          getPendingAnnotations = function()
            return {
              { id = 1, book_cache_id = 10, book_id = 100, ann_type = "unknown_type", payload = '{}', datetime = "2024-01-01", retry_count = 0 },
            }
          end,
          getBookCacheById = function() return nil end,
          isBookTrackingEnabled = function() return true end,
          deletePendingAnnotation = function(_, row_id)
            delete_calls[#delete_calls + 1] = row_id
          end,
          markAnnotationSynced = function() end,
          incrementPendingAnnotationRetryCount = function() end,
        },
      })
      local synced, failed, skipped = mod.syncPendingAnnotations(plugin)
      assert.are.equal(0, synced)
      assert.are.equal(0, failed)
      assert.are.equal(0, skipped)
      assert.are.equal(1, #delete_calls)
    end)
  end)

  describe("already exists handling", function()
    it("treats 'already exists' response as success for annotations", function()
      local mod = PendingSyncFactory.new(make_deps())
      local mark_calls = {}
      local delete_calls = {}
      local plugin = make_plugin({
        db = {
          getPendingAnnotations = function()
            return {
              { id = 1, book_cache_id = 10, book_id = 100, ann_type = "highlight", payload = '{"cfi":"/2","text":"hi"}', datetime = "2024-01-01", retry_count = 0 },
            }
          end,
          getBookCacheById = function() return nil end,
          isBookTrackingEnabled = function() return true end,
          markAnnotationSynced = function(_, bc_id, dt, at, sid)
            mark_calls[#mark_calls + 1] = { bc_id = bc_id, sid = sid }
          end,
          deletePendingAnnotation = function(_, row_id)
            delete_calls[#delete_calls + 1] = row_id
          end,
          incrementPendingAnnotationRetryCount = function() end,
        },
        api = {
          init = function() end,
          submitHighlight = function() return false, "Annotation already exists" end,
        },
      })
      local synced, failed, skipped = mod.syncPendingAnnotations(plugin)
      assert.are.equal(1, synced)
      assert.are.equal(0, failed)
      assert.are.equal(0, skipped)
      assert.are.equal(1, #mark_calls)
      assert.is_nil(mark_calls[1].sid)
      assert.are.equal(1, #delete_calls)
    end)
  end)

  describe("generic API failure", function()
    it("increments retry count on failure", function()
      local mod = PendingSyncFactory.new(make_deps())
      local retry_calls = {}
      local plugin = make_plugin({
        db = {
          getPendingAnnotations = function()
            return {
              { id = 1, book_cache_id = 10, book_id = 100, ann_type = "highlight", payload = '{"cfi":"/2","text":"hi"}', datetime = "2024-01-01", retry_count = 0 },
            }
          end,
          getBookCacheById = function() return nil end,
          isBookTrackingEnabled = function() return true end,
          deletePendingAnnotation = function() end,
          markAnnotationSynced = function() end,
          incrementPendingAnnotationRetryCount = function(_, row_id)
            retry_calls[#retry_calls + 1] = row_id
          end,
        },
        api = {
          init = function() end,
          submitHighlight = function() return false, "server error" end,
        },
      })
      local synced, failed, skipped = mod.syncPendingAnnotations(plugin)
      assert.are.equal(0, synced)
      assert.are.equal(1, failed)
      assert.are.equal(0, skipped)
      assert.are.equal(1, #retry_calls)
    end)
  end)
end)
