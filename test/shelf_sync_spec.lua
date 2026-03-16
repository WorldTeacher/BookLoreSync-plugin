-- Tests for BookloreSync:syncFromBookloreShelf
-- Uses the synchronous Trapper stub so subprocesses run inline.
-- Per-test stubs for lfs, booklore_database, and booklore_api_client
-- are installed via package.preload before loading main.lua.

package.path = table.concat({
  "bookloresync.koplugin/?.lua",
  "bookloresync.koplugin/?/init.lua",
  package.path,
}, ";")

-- ── Global KOReader stubs ────────────────────────────────────────────────────

package.preload["logger"] = function()
  return { info = function() end, warn = function() end,
           err = function() end, dbg = function() end }
end

package.preload["datastorage"] = function()
  return { getSettingsDir = function() return "/tmp/test-settings" end,
           getDataDir     = function() return "/tmp/test-data" end }
end

package.preload["dispatcher"]           = function() return { registerAction = function() end } end
package.preload["apps/filemanager/filemanager"] = function() return { instance = nil } end
package.preload["ui/widget/eventlistener"]      = function() return {} end
package.preload["ui/widget/infomessage"]        = function() return { new = function(_, o) return o or {} end } end
package.preload["ui/widget/inputdialog"]        = function() return { new = function(_, o) return o or {} end } end
package.preload["ui/widget/confirmbox"]         = function() return { new = function(_, o) return o or {} end } end
package.preload["ui/widget/buttondialog"] = function()
  local BD = {}
  BD.__index = BD
  function BD:new(o) o = o or {}; return setmetatable(o, self) end
  function BD:setTitle(t) self.title = t end
  return BD
end
package.preload["ui/widget/menu"]               = function() return { new = function(_, o) return o or {} end } end
package.preload["ui/network/manager"]           = function() return { isOnline = function() return false end } end
package.preload["luasettings"]                  = function() return { open = function() return { readSetting = function() return nil end } end } end
package.preload["booklore_settings"]            = function() return { new = function() return {} end } end
package.preload["hardcover_api_client"]         = function() return { new = function() return {} end } end
package.preload["booklore_updater"]             = function() return { new = function() return {} end } end
package.preload["booklore_file_logger"]         = function() return { new = function() return {} end } end
package.preload["booklore_metadata_extractor"]  = function() return { new = function() return {} end } end
package.preload["json"]                         = function() return { encode = function() return "{}" end, decode = function() return {} end } end
package.preload["ffi/util"] = function()
  -- Synchronous subprocess stub: runInSubProcess calls fn inline.
  -- writeToFD stores data into fake_result; readAllFromFD returns it.
  local fake_result
  return {
    template = function(fmt, ...) local a={...}; return (fmt:gsub("%%(%d+)", function(i) return tostring(a[tonumber(i)] or "") end)) end,
    runInSubProcess = function(fn, _)
      pcall(fn, 1, 1)       -- fn calls writeToFD which sets fake_result
      return 1, 1            -- fake pid, fake fd
    end,
    isSubProcessDone        = function() return true end,
    getNonBlockingReadSize  = function() return 1 end,
    readAllFromFD           = function() return fake_result end,
    writeToFD               = function(_, data) fake_result = data end,
    terminateSubProcess     = function() end,
  }
end

package.preload["string.buffer"] = function()
  -- Passthrough stub: encode wraps the table, decode unwraps it.
  local M = {}
  function M.encode(t) return t end
  function M.decode(t) return t end
  return M
end

package.preload["gettext"] = function()
  -- Return a function that also supports T(fmt, ...) template substitution.
  local t = function(s) return s end
  return setmetatable({}, {
    __call = function(_, s) return s end,
    __index = function(_, k)
      if k == "T" then
        return function(fmt, ...) local a={...}; return (fmt:gsub("%%(%d+)", function(i) return tostring(a[tonumber(i)] or "") end)) end
      end
      return nil
    end,
  })
end

package.preload["ui/uimanager"] = function()
  return {
    scheduleIn     = function(_, _, fn) if fn then fn() end end,
    nextTick       = function(_, fn)    if fn then fn() end end,
    show           = function() end,
    close          = function() end,
    preventStandby = function() end,
    allowStandby   = function() end,
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

-- Trapper stub: synchronous, returns (completed, result) per real API contract.
package.preload["ui/trapper"] = function()
  return {
    wrap = function(_, fn)
      local co = coroutine.create(fn)
      repeat
        local ok, err = coroutine.resume(co)
        if not ok then error(err) end
      until coroutine.status(co) == "dead"
    end,
    info = function() end,
    dismissableRunInSubprocess = function(_, worker_fn, _)
      local ok, result = pcall(worker_fn)
      if not ok then return true, nil end   -- crash → completed=true, result=nil
      return true, result                   -- success → completed=true, result=<table>
    end,
  }
end

-- bit stub (Lua 5.4 doesn't have bit global; LuaJIT does).
-- calcHash uses bit.lshift - stub it so hash tests don't blow up.
if not _G.bit then
  _G.bit = {
    lshift = function(n, s) return math.floor(n * (2 ^ s)) end,
    rshift = function(n, s) return math.floor(n / (2 ^ s)) end,
    band   = function(a, b) return a & b end,
  }
end

package.preload["ffi/sha2"] = function()
  return { md5 = function(s) return "deadbeef" end }
end

-- These must be pre-stubbed so that require("main") at module-load time
-- doesn't try to load the real implementation (which needs KOReader C libs).
-- Per-test stubs installed in each `it` block override package.loaded at
-- the point when the subprocess closures call require() during sync.
package.preload["libs/libkoreader-lfs"] = function()
  return {
    attributes = function() return nil end,
    mkdir      = function() return true end,
    dir        = function() return function() return nil end end,
  }
end

package.preload["booklore_database"] = function()
  return { new = function() return {
    init = function() end, close = function() end,
    getBookByFilePath = function() return nil end,
  } end }
end

package.preload["booklore_api_client"] = function()
  return { new = function() return {
    init = function() end,
    getOrCreateShelf = function() return true, 1 end,
    getBooksInShelf  = function() return true, {} end,
    downloadBook     = function() return true end,
  } end }
end

-- ── Load BookloreSync ────────────────────────────────────────────────────────
-- Loaded once; per-test stubs override package.loaded before each test so
-- the subprocess closures (which call require() fresh) pick them up.

local BookloreSync = require("main")

-- ── Helpers ──────────────────────────────────────────────────────────────────

local function make_plugin(overrides)
  overrides = overrides or {}
  local p = setmetatable({
    sync_in_progress    = false,
    silent_messages     = true,  -- suppress UIManager:show in tests
    server_url          = "http://localhost:8080",
    booklore_username   = "testuser",
    booklore_password   = "testpass",
    booklore_shelf_name = "My Shelf",
    shelf_id            = nil,
    download_dir        = "/tmp/test-dl",
    delete_removed_shelf_books = false,
    secure_logs         = false,
    db = {
      db_path = "/tmp/test-settings/booklore-sync.sqlite",
      beginTransaction = function() end,
      commit           = function() end,
      rollback         = function() end,
      saveBookCache    = function() end,
      getBookByFilePath = function() return nil end,
      updateFilePath   = function() end,
    },
    settings = {
      saveSetting = function() end,
      flush       = function() end,
    },
    logInfo = function() end,
    logWarn = function() end,
    logErr  = function() end,
  }, { __index = BookloreSync })
  for k, v in pairs(overrides) do p[k] = v end
  return p
end

local function make_lfs_stub(opts)
  -- opts.download_dir_exists: bool (default true)
  -- opts.files: table of filepath -> bool (true = file exists)
  -- opts.dir_entries: list of filename strings yielded by lfs.dir("/tmp/test-dl")
  opts = opts or {}
  local dir_exists = opts.download_dir_exists ~= false
  local files = opts.files or {}
  local dir_entries = opts.dir_entries or {}
  return {
    attributes = function(path, attr)
      if attr == "mode" then
        if files[path] then return "file" end
        if path:find("/tmp/test-dl") and dir_exists then return "directory" end
        return nil
      end
      return nil
    end,
    mkdir = function() return true end,
    dir   = function(dirpath)
      if dirpath == "/tmp/test-dl" then
        local i = 0
        local all = { ".", ".." }
        for _, e in ipairs(dir_entries) do table.insert(all, e) end
        return function()
          i = i + 1
          return all[i]
        end
      end
      return function() return nil end
    end,
  }
end

local function make_api_stub(opts)
  opts = opts or {}
  -- opts.shelf_ok, opts.shelf_id, opts.books_ok, opts.books, opts.download_ok
  return {
    new = function()
      return {
        init = function() end,
        getOrCreateShelf = function()
          if opts.shelf_ok == false then
            return false, opts.shelf_error or "shelf error"
          end
          return true, opts.shelf_id or 42
        end,
        getBooksInShelf = function()
          if opts.books_ok == false then
            return false, opts.books_error or "books error"
          end
          return true, opts.books or {}
        end,
        downloadBook = function(_, book_id, filepath, ...)
          if opts.download_ok == false then
            return false, opts.download_error or "download failed"
          end
          -- Simulate creating the file
          local f = io.open(filepath, "w")
          if f then f:write("dummy"); f:close() end
          return true
        end,
      }
    end,
  }
end

local function make_db_stub(opts)
  opts = opts or {}
  -- opts.cached: filepath -> record | nil
  return {
    new = function()
      return {
        init = function() end,
        close = function() end,
        getBookByFilePath = function(_, fp)
          return opts.cached and opts.cached[fp] or nil
        end,
      }
    end,
  }
end

-- ── Tests ────────────────────────────────────────────────────────────────────

describe("BookloreSync:syncFromBookloreShelf", function()

  -- Reset per-test module stubs between tests
  after_each(function()
    package.loaded["libs/libkoreader-lfs"] = nil
    package.loaded["booklore_api_client"]  = nil
    package.loaded["booklore_database"]    = nil
    -- Restore to base stubs so the next test starts clean
    package.preload["libs/libkoreader-lfs"] = function()
      return { attributes = function() return nil end, mkdir = function() return true end, dir = function() return function() return nil end end }
    end
    package.preload["booklore_api_client"] = function()
      return { new = function() return { init = function() end, getOrCreateShelf = function() return true, 1 end, getBooksInShelf = function() return true, {} end, downloadBook = function() return true end } end }
    end
    package.preload["booklore_database"] = function()
      return { new = function() return { init = function() end, close = function() end, getBookByFilePath = function() return nil end } end }
    end
  end)

  -- ── Guard conditions ──────────────────────────────────────────────────────

  it("returns false immediately when sync already in progress", function()
    local p = make_plugin({ sync_in_progress = true })
    package.preload["libs/libkoreader-lfs"] = function() return make_lfs_stub() end

    local result, msg = p:syncFromBookloreShelf(true)
    assert.is_false(result)
    assert.is_not_nil(msg)
    assert.is_true(p.sync_in_progress)  -- guard returned early; flag was not cleared
  end)

  it("returns false when credentials are missing", function()
    local p = make_plugin({ booklore_username = "" })
    package.preload["libs/libkoreader-lfs"] = function() return make_lfs_stub() end

    local result, msg = p:syncFromBookloreShelf(true)
    assert.is_false(result)
    assert.is_not_nil(msg)
  end)

  -- ── Phase 1 error paths ───────────────────────────────────────────────────

  it("returns false when getOrCreateShelf fails", function()
    package.preload["libs/libkoreader-lfs"] = function() return make_lfs_stub() end
    package.preload["booklore_api_client"]  = function() return make_api_stub({ shelf_ok = false }) end
    package.preload["booklore_database"]    = function() return make_db_stub() end

    local p = make_plugin()
    local callback_called, callback_ok = false, nil
    p:syncFromBookloreShelf(true, function(ok) callback_called = true; callback_ok = ok end)

    assert.is_true(callback_called)
    assert.is_false(callback_ok)
    assert.is_false(p.sync_in_progress)
  end)

  it("returns false when getBooksInShelf fails", function()
    package.preload["libs/libkoreader-lfs"] = function() return make_lfs_stub() end
    package.preload["booklore_api_client"]  = function() return make_api_stub({ books_ok = false }) end
    package.preload["booklore_database"]    = function() return make_db_stub() end

    local p = make_plugin()
    local callback_ok = nil
    p:syncFromBookloreShelf(true, function(ok) callback_ok = ok end)

    assert.is_false(callback_ok)
    assert.is_false(p.sync_in_progress)
  end)

  it("succeeds with empty shelf and calls on_complete(true)", function()
    package.preload["libs/libkoreader-lfs"] = function() return make_lfs_stub() end
    package.preload["booklore_api_client"]  = function() return make_api_stub({ books = {} }) end
    package.preload["booklore_database"]    = function() return make_db_stub() end

    local p = make_plugin()
    local callback_ok = nil
    p:syncFromBookloreShelf(true, function(ok) callback_ok = ok end)

    assert.is_true(callback_ok)
    assert.is_false(p.sync_in_progress)
  end)

  -- ── Phase 1 happy path: shelf_id update ──────────────────────────────────

  it("updates shelf_id when it changes", function()
    package.preload["libs/libkoreader-lfs"] = function() return make_lfs_stub() end
    package.preload["booklore_api_client"]  = function() return make_api_stub({ shelf_id = 99, books = {} }) end
    package.preload["booklore_database"]    = function() return make_db_stub() end

    local p = make_plugin({ shelf_id = 1 })
    local saved_key, saved_val
    p.settings.saveSetting = function(_, k, v) saved_key = k; saved_val = v end
    p:syncFromBookloreShelf(true)

    assert.are.equal(99, p.shelf_id)
    assert.are.equal("shelf_id", saved_key)
    assert.are.equal(99, saved_val)
  end)

  -- ── Phase 2: per-book download loop ──────────────────────────────────────

  it("skips books that are already on disk and cached in DB", function()
    local filepath = "/tmp/test-dl/MyBook_1.epub"
    package.preload["libs/libkoreader-lfs"] = function()
      return make_lfs_stub({ files = { [filepath] = true } })
    end
    package.preload["booklore_api_client"] = function()
      return make_api_stub({
        books = { { id = 1, title = "MyBook", extension = "epub" } },
      })
    end
    package.preload["booklore_database"] = function()
      return make_db_stub({
        cached = { [filepath] = { book_id = 1 } },
      })
    end

    local p = make_plugin()
    local dl_count = 0
    p.db.saveBookCache = function() dl_count = dl_count + 1 end

    p:syncFromBookloreShelf(true)

    -- Cached file → no new DB writes
    assert.are.equal(0, dl_count)
    assert.is_false(p.sync_in_progress)
  end)

  it("downloads a missing book and queues a DB write", function()
    -- File does NOT exist on disk initially
    local filepath = "/tmp/test-dl/NewBook_7.epub"
    package.preload["libs/libkoreader-lfs"] = function()
      -- Before download: file absent; subprocess also checks - simulate absence
      return make_lfs_stub({ files = {} })
    end
    package.preload["booklore_api_client"] = function()
      return make_api_stub({
        books       = { { id = 7, title = "NewBook", extension = "epub" } },
        download_ok = true,
      })
    end
    package.preload["booklore_database"] = function()
      return make_db_stub()
    end

    local p = make_plugin()
    local saved = {}
    p.db.saveBookCache = function(_, fp, hash, bid, title, author, isbn10, isbn13)
      table.insert(saved, { fp = fp, bid = bid, title = title })
    end

    p:syncFromBookloreShelf(true)

    assert.are.equal(1, #saved)
    assert.are.equal(7, saved[1].bid)
    assert.are.equal("NewBook", saved[1].title)
    assert.is_false(p.sync_in_progress)
  end)

  it("counts download errors without aborting the loop", function()
    package.preload["libs/libkoreader-lfs"] = function()
      return make_lfs_stub({ files = {} })
    end
    package.preload["booklore_api_client"] = function()
      return make_api_stub({
        books       = { { id = 1, title = "Book1", extension = "epub" } },
        download_ok = false,
      })
    end
    package.preload["booklore_database"] = function()
      return make_db_stub()
    end

    local p = make_plugin()
    local callback_ok, callback_msg = nil, nil
    p:syncFromBookloreShelf(true, function(ok, msg) callback_ok = ok; callback_msg = msg end)

    -- Sync completes (ok=true) even when individual books error
    assert.is_true(callback_ok)
    assert.is_false(p.sync_in_progress)
  end)

  -- ── Phase 3: DB commit failure ────────────────────────────────────────────

  it("calls on_complete(false) when DB commit throws", function()
    package.preload["libs/libkoreader-lfs"] = function()
      return make_lfs_stub({ files = {} })
    end
    package.preload["booklore_api_client"] = function()
      return make_api_stub({
        books = { { id = 2, title = "Book2", extension = "epub" } },
      })
    end
    package.preload["booklore_database"] = function()
      return make_db_stub()
    end

    local p = make_plugin()
    p.db.commit = function() error("disk full") end

    local callback_ok = nil
    p:syncFromBookloreShelf(true, function(ok) callback_ok = ok end)

    assert.is_false(callback_ok)
    assert.is_false(p.sync_in_progress)
  end)

  -- ── Phase 3: deletion walk ────────────────────────────────────────────────

  it("deletion walk removes a file whose book ID is not on the shelf", function()
    -- Shelf has book id=3; disk has OldBook_5.epub (id=5, not on shelf)
    local old_file = "/tmp/test-dl/OldBook_5.epub"
    package.preload["libs/libkoreader-lfs"] = function()
      return make_lfs_stub({
        files       = { [old_file] = true },
        dir_entries = { "OldBook_5.epub" },
      })
    end
    package.preload["booklore_api_client"] = function()
      return make_api_stub({
        books = { { id = 3, title = "CurrentBook", extension = "epub" } },
      })
    end
    package.preload["booklore_database"] = function()
      return make_db_stub()
    end

    local p = make_plugin({ delete_removed_shelf_books = true })
    local removed = {}
    local real_remove = os.remove
    os.remove = function(path) table.insert(removed, path); return true end

    p:syncFromBookloreShelf(true)

    os.remove = real_remove
    assert.are.equal(1, #removed)
    assert.are.equal(old_file, removed[1])
    assert.is_false(p.sync_in_progress)
  end)

  it("deletion walk keeps a file whose book ID is still on the shelf", function()
    -- Shelf has book id=3; disk has CurrentBook_3.epub (id=3, still on shelf)
    local keep_file = "/tmp/test-dl/CurrentBook_3.epub"
    package.preload["libs/libkoreader-lfs"] = function()
      return make_lfs_stub({
        files       = { [keep_file] = true },
        dir_entries = { "CurrentBook_3.epub" },
      })
    end
    package.preload["booklore_api_client"] = function()
      return make_api_stub({
        books = { { id = 3, title = "CurrentBook", extension = "epub" } },
      })
    end
    package.preload["booklore_database"] = function()
      return make_db_stub()
    end

    local p = make_plugin({ delete_removed_shelf_books = true })
    local removed = {}
    local real_remove = os.remove
    os.remove = function(path) table.insert(removed, path); return true end

    p:syncFromBookloreShelf(true)

    os.remove = real_remove
    assert.are.equal(0, #removed)
    assert.is_false(p.sync_in_progress)
  end)

  it("deletion walk ignores files with no embedded book ID", function()
    -- A file without _id suffix (legacy or non-book file) must never be deleted
    local legacy_file = "/tmp/test-dl/SomeBook.epub"
    package.preload["libs/libkoreader-lfs"] = function()
      return make_lfs_stub({
        files       = { [legacy_file] = true },
        dir_entries = { "SomeBook.epub" },
      })
    end
    package.preload["booklore_api_client"] = function()
      return make_api_stub({ books = {} })
    end
    package.preload["booklore_database"] = function()
      return make_db_stub()
    end

    local p = make_plugin({ delete_removed_shelf_books = true })
    local removed = {}
    local real_remove = os.remove
    os.remove = function(path) table.insert(removed, path); return true end

    p:syncFromBookloreShelf(true)

    os.remove = real_remove
    assert.are.equal(0, #removed)
    assert.is_false(p.sync_in_progress)
  end)

  it("skips a book with no extension and counts it as an error", function()
    -- Book id=9 has no extension (bookType absent, no primaryFile.fileName).
    -- Sync must not crash; errors counter must be > 0 and callback still ok=true.
    package.preload["libs/libkoreader-lfs"] = function()
      return make_lfs_stub({ files = {} })
    end
    package.preload["booklore_api_client"] = function()
      return make_api_stub({
        books = {
          { id = 9, title = "Mystery", extension = nil },
        },
      })
    end
    package.preload["booklore_database"] = function()
      return make_db_stub()
    end

    local p = make_plugin()
    local warn_called = false
    p.logWarn = function(...) warn_called = true end
    local saved = {}
    p.db.saveBookCache = function(_, fp, hash, bid)
      table.insert(saved, bid)
    end
    local callback_ok = nil
    p:syncFromBookloreShelf(true, function(ok) callback_ok = ok end)

    -- No files downloaded for the nil-extension book
    assert.are.equal(0, #saved)
    -- A warning should have been emitted
    assert.is_true(warn_called)
    -- Sync overall still completes (errors don't abort the whole sync)
    assert.is_true(callback_ok)
    assert.is_false(p.sync_in_progress)
  end)

  it("migration renames an old-scheme file and updates the DB path", function()
    -- Disk has "MyBook.epub" (old name, no ID). Shelf has book id=1 title="MyBook".
    -- After sync the file should be renamed to "MyBook_1.epub".
    local old_file = "/tmp/test-dl/MyBook.epub"
    local new_file = "/tmp/test-dl/MyBook_1.epub"
    local files_on_disk = { [old_file] = true }
    package.preload["libs/libkoreader-lfs"] = function()
      return {
        attributes = function(path, attr)
          if attr == "mode" then
            if files_on_disk[path] then return "file" end
            if path == "/tmp/test-dl" then return "directory" end
            return nil
          end
          return nil
        end,
        mkdir = function() return true end,
        dir   = function() return function() return nil end end,
      }
    end
    package.preload["booklore_api_client"] = function()
      return make_api_stub({
        books = { { id = 1, title = "MyBook", extension = "epub" } },
      })
    end
    package.preload["booklore_database"] = function()
      return make_db_stub()
    end

    local p = make_plugin()
    local renamed_from, renamed_to
    local real_rename = os.rename
    os.rename = function(from, to)
      renamed_from = from
      renamed_to   = to
      -- simulate: old file disappears, new file appears
      files_on_disk[from] = nil
      files_on_disk[to]   = true
      return true
    end
    local db_updated_from, db_updated_to
    p.db.updateFilePath = function(_, old, new)
      db_updated_from = old
      db_updated_to   = new
    end

    p:syncFromBookloreShelf(true)

    os.rename = real_rename
    assert.are.equal(old_file, renamed_from)
    assert.are.equal(new_file, renamed_to)
    assert.are.equal(old_file, db_updated_from)
    assert.are.equal(new_file, db_updated_to)
    assert.is_false(p.sync_in_progress)
  end)

end)
