local M = {}

function M.new(deps)
    local _ = deps._
    local T = deps.T
    local UIManager = deps.UIManager
    local InfoMessage = deps.InfoMessage
    local ButtonDialog = deps.ButtonDialog
    local json = deps.json
    local ffiutil = deps.ffiutil
    local strbuf = deps.strbuf
    local util = require("booklore_util")

    local module = {}

    local function joinDownloadPath(dir, name)
        return util.joinDownloadPath(dir, name)
    end

    local function ensureDirExists(path)
        local lfs = require("libs/libkoreader-lfs")
        local current = tostring(path or "")
        if current == "" then return false end

        if lfs.attributes(current, "mode") == "directory" then
            return true
        end

        local parts = {}
        for part in current:gmatch("[^/]+") do
            table.insert(parts, part)
        end

        local prefix = current:sub(1, 1) == "/" and "/" or ""
        local cursor = prefix
        for _, part in ipairs(parts) do
            if cursor == "" or cursor == "/" then
                cursor = prefix .. part
            else
                cursor = cursor .. "/" .. part
            end
            if lfs.attributes(cursor, "mode") ~= "directory" then
                local ok = lfs.mkdir(cursor)
                if not ok and lfs.attributes(cursor, "mode") ~= "directory" then
                    return false
                end
            end
        end

        return lfs.attributes(current, "mode") == "directory"
    end

    --[[--
    Check whether a book_id is still present in the other shelf's cached state.
    If so, we should NOT delete the local file — the other shelf still needs it.
    --]]
    local function bookIdStillOnOtherShelf(self, current_target, book_id)
        local other_shelf_id
        local other_target
        if current_target == "magic" then
            other_shelf_id = tonumber(self.booklore_source_shelf_id) or tonumber(self.shelf_id)
            other_target = "regular"
        else
            other_shelf_id = tonumber(self.booklore_magic_shelf_id)
            other_target = "magic"
        end
        if not other_shelf_id then
            return false  -- no other shelf configured
        end
        local state = self.db:getShelfState(other_shelf_id, other_target)
        if not state or type(state.books_json) ~= "string" then
            return false  -- no cached state for other shelf
        end
        local ok_dec, decoded = pcall(json.decode, state.books_json)
        if not ok_dec or type(decoded) ~= "table" then
            return false
        end
        for _, b in ipairs(decoded) do
            if tonumber(b.id) == book_id then
                return true
            end
        end
        return false
    end

    function module.detectDefaultDownloadDir(_self)
        local lfs = require("libs/libkoreader-lfs")

        local koreader_home
        if G_reader_settings and G_reader_settings.readSetting then
            koreader_home = G_reader_settings:readSetting("home_dir")
        end
        if not koreader_home then
            local ok_dev, Device = pcall(require, "device")
            if ok_dev and Device and Device.home_dir then
                koreader_home = Device.home_dir
            end
        end
        if koreader_home and lfs.attributes(koreader_home, "mode") == "directory" then
            return koreader_home .. "/Books"
        end

        if lfs.attributes("/mnt/onboard", "mode") == "directory" then
            return "/mnt/onboard/Books"
        elseif lfs.attributes("/sdcard", "mode") == "directory" then
            return "/sdcard/Books"
        else
            return "/Books"
        end
    end

    function module.generateFilename(_self, book)
        local use_original = _self and _self.shelf_use_original_filename
        return util.generateFilename(book, use_original)
    end

    -- generateFilename delegates to util.generateFilename (shared logic).
    -- File hashing uses util.calculateBookHash inside the download loop.
    function module.syncFromBookloreShelf(self, silent, on_complete, sync_target, suppress_summary)
    if silent == nil then silent = (self.ui and self.ui.document and true or false) end

    if self.sync_in_progress then
        self:logWarn("BookloreSync: Sync already in progress, skipping duplicate call")
        local msg = _("Sync already in progress")
        if not silent and not self.silent_messages then
            UIManager:show(InfoMessage:new{ text = msg, timeout = 2 })
        end
        if on_complete then on_complete(false, msg) end
        return false, msg
    end

    if not self.booklore_username or self.booklore_username == "" or
       not self.booklore_password or self.booklore_password == "" then
        local msg = _("Booklore credentials not configured. Please configure your Booklore account first.")
        if not silent and not self.silent_messages then
            UIManager:show(InfoMessage:new{ text = msg, timeout = 3 })
        end
        if on_complete then on_complete(false, msg) end
        return false, msg
    end

    local target = tostring(sync_target or "regular")
    if target ~= "regular" and target ~= "magic" then
        target = "regular"
    end

    local download_dir
    if target == "magic" and self.magic_separate_folder then
        download_dir = self.magic_download_dir
    else
        download_dir = self.download_dir
    end

    -- Ensure download directory exists
    local lfs = require("libs/libkoreader-lfs")
    if not ensureDirExists(download_dir) then
        local msg = T(_("Cannot create download directory: %1"), download_dir)
        self:logErr("BookloreSync: syncFromBookloreShelf -", msg)
        if not silent and not self.silent_messages then
            UIManager:show(InfoMessage:new{ text = msg, timeout = 3 })
        end
        if on_complete then on_complete(false, msg) end
        return false, msg
    end

    self.sync_in_progress = true
    self._shelf_sync_cancelled = nil
    self:logInfo("BookloreSync: syncFromBookloreShelf - starting sync")

    -- Capture simple-type values for subprocess use (closures don't cross fork).
    local server_url      = self.server_url
    local sub_username    = self.booklore_username
    local sub_password    = self.booklore_password
    local db_name         = self.db.db_path:match("([^/]+)$") or "booklore-sync.sqlite"

    local delete_removed  = self.delete_removed_shelf_books
    local use_original_filename = self.shelf_use_original_filename
    local delete_sdr      = self.delete_sdr_on_book_delete

    -- ── Phase 0: resolve credentials and refresh API client ────────────────
    self:refreshEffectiveServerUrl()
    self.api:init(self.server_url, self.username, self.password, self.db)

    local progress_widget  = nil  -- single InfoMessage reused for the whole sync
    local result = { synced = 0, skipped = 0, failed = 0, deleted = 0, errors = {} }

    -- ── Helper: show / update the progress InfoMessage ──────────────────────
    -- Shows download index, book title, and when progress info is provided,
    -- a percentage bar with byte counts.  progress = { bytes=N, total_bytes=N }
    local function showProgress(idx, total, book_title, progress)
        if silent then return end

        local short_title = book_title or "?"
        local max_short = tonumber(self.short_title_length) or 30
        if max_short < 5 then max_short = 5 end
        if #short_title > max_short then short_title = short_title:sub(1, max_short) .. "..." end

        local lines = {}
        lines[#lines + 1] = T(_("Downloading  %1 / %2"), idx, total)
        lines[#lines + 1] = ""
        lines[#lines + 1] = short_title

        if progress and progress.total_bytes and progress.total_bytes > 0 then
            local pct = math.min(100, math.floor(progress.bytes / progress.total_bytes * 100))
            local bar_w = tonumber(self.progress_bar_width) or 20
            if bar_w < 5 then bar_w = 5 end
            if bar_w > 60 then bar_w = 60 end
            local filled = math.floor(pct / 100 * bar_w)
            if filled > bar_w then filled = bar_w end
            lines[#lines + 1] = ""
            -- Block characters: █ (U+2588) = filled, ░ (U+2591) = empty.
            -- Rendered as UTF-8 byte sequences for KOReader's e-ink font stack.
            local bar = string.rep("\226\150\136", filled) .. string.rep("\226\150\145", bar_w - filled)
            lines[#lines + 1] = bar
            lines[#lines + 1] = ""
            local mb_dl = progress.bytes / (1024 * 1024)
            local mb_total = progress.total_bytes / (1024 * 1024)
            lines[#lines + 1] = T(_("%1 / %2 MB  (%3%)"),
                string.format("%.1f", mb_dl),
                string.format("%.1f", mb_total),
                pct)
        elseif progress and progress.bytes and progress.bytes > 0 then
            local mb_dl = progress.bytes / (1024 * 1024)
            lines[#lines + 1] = ""
            lines[#lines + 1] = T(_("Downloaded: %1 MB"), string.format("%.1f", mb_dl))
        end

        local self_for_callback = self
        if progress_widget then
            -- Update existing dialog's title if possible
            -- InfoMessage doesn't have setTitle — if that fails close it and
            -- fall through to create a ButtonDialog instead.
            local ok = pcall(progress_widget.setTitle, progress_widget, table.concat(lines, "\n"))
            if ok then
                return
            end
            pcall(UIManager.close, UIManager, progress_widget)
        end

        progress_widget = ButtonDialog:new{
            dismissable = false,
            title = table.concat(lines, "\n"),
            buttons = {{ {
                text = _("Stop syncing"),
                callback = function()
                    self_for_callback._shelf_sync_cancelled = true
                    -- Dialog stays open so the user sees the current download finish.
                end,
            } }},
        }
        UIManager:show(progress_widget)
    end

    local function closeProgress()
        if progress_widget then
            pcall(UIManager.close, UIManager, progress_widget)
            progress_widget = nil
        end
    end

    -- ── Helper: finish sync (cleanup + summary + refresh + on_complete) ─────
    local function finishSync(success)
        closeProgress()
        self.sync_in_progress = false

        -- Refresh file manager so new books appear immediately
        -- and removed books disappear. Do this before showing the summary
        -- dialog so the dialog paints on top of the refreshed state.
        if result.synced > 0 or result.deleted > 0 then
            local ok_fm, FM = pcall(require, "apps/filemanager/filemanager")
            if ok_fm and FM and FM.instance then
                FM.instance:reinit(download_dir)
            end
        end

        local ok = (success == nil) or success
        local total_msg = T(_("Shelf sync: %1 downloaded, %2 skipped, %3 failed"),
            result.synced, result.skipped, result.failed)
        self:logInfo("BookloreSync: syncFromBookloreShelf -", total_msg)
        if on_complete then on_complete(ok, total_msg) end

        -- Show the summary dialog when sync was triggered manually (not silent) and not suppressed for chained syncs.
        if not silent and not suppress_summary then
            UIManager:scheduleIn(0, function()
                local lines = {}
                lines[#lines + 1] = _("Shelf Sync Complete")
                if result.synced > 0 then
                    lines[#lines + 1] = T(_("Downloaded:  %1"), result.synced)
                end
                if result.skipped > 0 then
                    lines[#lines + 1] = T(_("Already on device:  %1"), result.skipped)
                end
                if result.deleted > 0 then
                    lines[#lines + 1] = T(_("Removed:  %1"), result.deleted)
                end
                if result.failed > 0 then
                    lines[#lines + 1] = T(_("Failed:  %1"), result.failed)
                end
                if result.synced == 0 and result.failed == 0 and result.deleted == 0 then
                    lines[#lines + 1] = ""
                    lines[#lines + 1] = _("Everything is up to date.")
                end
                if #result.errors > 0 then
                    lines[#lines + 1] = ""
                    local first_err = tostring(result.errors[1] or "")
                    if #first_err > 120 then first_err = first_err:sub(1, 120) .. "..." end
                    if first_err ~= "" then
                        lines[#lines + 1] = first_err
                    end
                end
                UIManager:show(InfoMessage:new{
                    text    = table.concat(lines, "\n"),
                    timeout = 8,
                })
                UIManager:forceRePaint()
            end)
        end
    end

    -- ── Phase 1: fetch shelf books + cached state ──────────────────────────
    -- We call the API directly from the UI thread. This is a single short
    -- request — the brief freeze is acceptable.
    local shelf_id
    local books = nil
    local cached_state = nil

    if not silent and not self.silent_messages then
        progress_widget = InfoMessage:new{
            text = _("Fetching book list from shelf..."),
            timeout = 600,
        }
        UIManager:show(progress_widget)
        UIManager:forceRePaint()
    end

    if target == "magic" then
        local magic_ok, magic_source = self.api:resolveMagicShelfSource(
            self.booklore_magic_shelf_id, self.booklore_magic_shelf_name,
            self.booklore_username, self.booklore_password)
        if not magic_ok then
            closeProgress()
            local err_code = type(magic_source) == "table" and magic_source.code or nil
            local err_msg = type(magic_source) == "table" and magic_source.message or tostring(magic_source)
            local mapped
            if err_code == 401 then
                mapped = _("Authentication failed while accessing shelf. Please re-check your BookLore credentials.")
            elseif err_code == 403 then
                mapped = _("Shelf access denied. The selected shelf may be private or not shared with this account.")
            elseif err_code == 404 then
                mapped = _("Configured shelf is not accessible. Verify the shelf ID/name in Shelf Sync settings.")
            end
            local msg = mapped and T(_("Sync failed: %1"), mapped)
                or T(_("Sync failed: %1"), err_msg)
            self:logErr("BookloreSync: syncFromBookloreShelf -", err_msg)
            self.sync_in_progress = false
            if not silent and not self.silent_messages then
                UIManager:show(InfoMessage:new{ text = msg, timeout = 4 })
            end
            if on_complete then on_complete(false, msg) end
            return
        end
        shelf_id = tonumber(magic_source.id)
        if not shelf_id then
            closeProgress()
            local msg = _("Resolved magic shelf source missing shelf id")
            self:logErr("BookloreSync: syncFromBookloreShelf -", msg)
            self.sync_in_progress = false
            if not silent and not self.silent_messages then
                UIManager:show(InfoMessage:new{ text = msg, timeout = 4 })
            end
            if on_complete then on_complete(false, msg) end
            return
        end
        if magic_source.name and magic_source.name ~= "" then
            self.booklore_shelf_name = magic_source.name
            self.booklore_magic_shelf_name = magic_source.name
            self.settings:saveSetting("booklore_shelf_name", self.booklore_shelf_name)
            self.settings:saveSetting("booklore_magic_shelf_name", self.booklore_magic_shelf_name)
            self.settings:flush()
        end
        local books_ok
        books_ok, books = self.api:getBooksInMagicShelf(shelf_id, self.booklore_username, self.booklore_password)
        if not books_ok then
            closeProgress()
            local err_msg = type(books) == "table" and books.message or tostring(books)
            local msg = T(_("Sync failed: %1"), err_msg)
            self:logErr("BookloreSync: syncFromBookloreShelf -", err_msg)
            self.sync_in_progress = false
            if not silent and not self.silent_messages then
                UIManager:show(InfoMessage:new{ text = msg, timeout = 4 })
            end
            if on_complete then on_complete(false, msg) end
            return
        end
    else
        local source_ok, source = self.api:resolveShelfSource(
            self.booklore_source_shelf_id, self.booklore_source_shelf_name,
            self.booklore_username, self.booklore_password)
        if not source_ok then
            closeProgress()
            local err_code = type(source) == "table" and source.code or nil
            local err_msg = type(source) == "table" and source.message or tostring(source)
            local mapped
            if err_code == 401 then
                mapped = _("Authentication failed while accessing shelf. Please re-check your BookLore credentials.")
            elseif err_code == 403 then
                mapped = _("Shelf access denied. The selected shelf may be private or not shared with this account.")
            elseif err_code == 404 then
                mapped = _("Configured shelf is not accessible. Verify the shelf ID/name in Shelf Sync settings.")
            end
            local msg = mapped and T(_("Sync failed: %1"), mapped)
                or T(_("Sync failed: %1"), err_msg)
            self:logErr("BookloreSync: syncFromBookloreShelf -", err_msg)
            self.sync_in_progress = false
            if not silent and not self.silent_messages then
                UIManager:show(InfoMessage:new{ text = msg, timeout = 4 })
            end
            if on_complete then on_complete(false, msg) end
            return
        end
        shelf_id = tonumber(source.id)
        if not shelf_id then
            closeProgress()
            local msg = _("Resolved shelf source missing shelf id")
            self:logErr("BookloreSync: syncFromBookloreShelf -", msg)
            self.sync_in_progress = false
            if not silent and not self.silent_messages then
                UIManager:show(InfoMessage:new{ text = msg, timeout = 4 })
            end
            if on_complete then on_complete(false, msg) end
            return
        end
        if source.name and source.name ~= "" then
            self.booklore_source_shelf_name = source.name
            self.settings:saveSetting("booklore_source_shelf_name", self.booklore_source_shelf_name)
            self.settings:flush()
        end
        local books_ok
        books_ok, books = self.api:getBooksInShelf(shelf_id, self.booklore_username, self.booklore_password)
        if not books_ok then
            closeProgress()
            local err_msg = type(books) == "table" and books.message or tostring(books)
            local msg = T(_("Sync failed: %1"), err_msg)
            self:logErr("BookloreSync: syncFromBookloreShelf -", err_msg)
            self.sync_in_progress = false
            if not silent and not self.silent_messages then
                UIManager:show(InfoMessage:new{ text = msg, timeout = 4 })
            end
            if on_complete then on_complete(false, msg) end
            return
        end
    end

    -- Keep legacy shelf_id pointer aligned to the regular shelf only.
    -- This avoids using a magic shelf id in regular-shelf deletion/unassign paths.
    if target == "regular" and shelf_id ~= self.shelf_id then
        self.shelf_id = shelf_id
        self.settings:saveSetting("shelf_id", self.shelf_id)
        self.settings:flush()
    end

    -- Read cached shelf state for delta computation
    cached_state = self.db:getShelfState(shelf_id, target)

    -- ── Delta computation: diff current shelf against cached state ──────────
    local prev_books = {}
    if cached_state and type(cached_state.books_json) == "string" then
        local ok_dec, decoded = pcall(json.decode, cached_state.books_json)
        if ok_dec and type(decoded) == "table" then
            for _i, b in ipairs(decoded) do
                local bid = tonumber(b.id)
                if bid then prev_books[bid] = b end
            end
            self:logInfo("BookloreSync: delta - previous shelf state has", #decoded, "books, synced_at:", cached_state.synced_at)
        else
            self:logWarn("BookloreSync: delta - could not decode cached shelf JSON, forcing full sync")
        end
    else
        self:logInfo("BookloreSync: delta - no cached shelf state, performing full sync")
    end

    local curr_books = {}
    for _i, b in ipairs(books) do
        local bid = tonumber(b.id)
        if bid then curr_books[bid] = b end
    end

    local books_to_download = {}
    local books_to_delete   = {}

    for bid, b in pairs(curr_books) do
        if not prev_books[bid] then
            table.insert(books_to_download, b)
        end
    end
    for bid in pairs(prev_books) do
        if not curr_books[bid] then
            table.insert(books_to_delete, bid)
        end
    end

    local first_sync = (next(prev_books) == nil)
    local total_new  = #books_to_download
    local total_del  = #books_to_delete

    self:logInfo(string.format(
        "BookloreSync: delta - total=%d new=%d removed=%d first_sync=%s",
        #books, total_new, total_del, tostring(first_sync)
    ))

    -- Nothing to do at all — finish immediately.
    if total_new == 0 and total_del == 0 then
        -- Sanity check 1: if the shelf has books but their files are missing
        -- from disk, the files were likely removed externally.  Don't trust
        -- the delta — re-queue all books for download.
        if #books > 0 then
            local lfs_local = require("libs/libkoreader-lfs")
            local any_missing = false
            for _i, b in ipairs(books) do
                local bid = tonumber(b.id)
                if bid then
                    local cached = nil
                    if self.db.getBookByBookIdInDir then
                        cached = self.db:getBookByBookIdInDir(bid, download_dir)
                    end
                    if (not cached or not cached.file_path) and self.db.getBookByBookId then
                        cached = self.db:getBookByBookId(bid)
                    end
                    if not cached or not cached.file_path
                        or lfs_local.attributes(cached.file_path, "mode") ~= "file" then
                        any_missing = true
                        break
                    end
                end
            end
            if any_missing then
                self:logWarn("BookloreSync: shelf is up to date per cache but " .. tostring(#books) .. " book(s) missing from disk - re-queuing all books")
                books_to_download = {}
                for _i, b in ipairs(books) do
                    table.insert(books_to_download, b)
                end
                total_new = #books_to_download
                -- Also clear the cached shelf state so the next delta is clean
                self.db:clearShelfState(shelf_id, target)
            end
        end

        -- Sanity check 2: if cache says no delta but local stale files remain in
        -- the active download directory, remove them when delete_removed is enabled.
        -- This catches stale local rows/files that are outside the current shelf
        -- state but were not part of the immediate prev->curr delta.
        local stale_deleted = 0
        if total_new == 0 and delete_removed and self.db.getAllCachedBooks then
            local lfs_local = require("libs/libkoreader-lfs")
            local all_cached = self.db:getAllCachedBooks() or {}
            local dir_prefix = tostring(download_dir or ""):gsub("/+$", "") .. "/"
            for _i, cached in ipairs(all_cached) do
                local bid = cached and tonumber(cached.book_id)
                local fp = cached and tostring(cached.file_path or "") or ""
                if bid and fp ~= "" and fp:sub(1, #dir_prefix) == dir_prefix
                    and lfs_local.attributes(fp, "mode") == "file"
                    and not curr_books[bid]
                    and not bookIdStillOnOtherShelf(self, target, bid) then
                    if os.remove(fp) then
                        stale_deleted = stale_deleted + 1
                        if delete_sdr then
                            local sdr_dirs = self:getSdrPaths(fp)
                            for _j, sdr_dir in ipairs(sdr_dirs) do
                                local ok_rm, err_rm = self:_deleteDirRecursive(sdr_dir)
                                if not ok_rm then
                                    self:logErr("BookloreSync: Failed to delete sidecar: " .. tostring(sdr_dir) .. " | " .. tostring(err_rm))
                                end
                            end
                        end
                    else
                        result.failed = result.failed + 1
                    end
                end
            end
            if stale_deleted > 0 then
                result.deleted = (result.deleted or 0) + stale_deleted
                self:logWarn("BookloreSync: removed stale local shelf file(s): " .. tostring(stale_deleted))
            end
        end

        if total_new == 0 then
            -- Persist shelf state (updates synced_at timestamp even when nothing changed)
            local ok_enc, books_json = pcall(json.encode, books)
            if ok_enc and books_json then
                self.db:saveShelfState(shelf_id, target, books_json)
                self:logInfo('BookloreSync: shelf state saved for shelf_id', shelf_id)
            end

            if stale_deleted > 0 then
                finishSync(true)
                return
            end

            closeProgress()
            self:logInfo("BookloreSync: syncFromBookloreShelf - shelf up to date")
            self.sync_in_progress = false
            if on_complete then on_complete(true, _("Shelf up to date")) end
            if not silent then
                UIManager:scheduleIn(0, function()
                    UIManager:show(InfoMessage:new{
                        text = _("Shelf up to date - Everything is already synced."),
                        timeout = 3,
                    })
                    UIManager:forceRePaint()
                end)
            end
            return
        end
    end

    -- ── Phase 2: sequential download loop ───────────────────────────────────
    -- Each book is downloaded via a direct API call (no subprocess).
    -- We use UIManager:scheduleIn to stagger the downloads one-by-one,
    -- keeping the UI responsive between them.
    local function showDeletingProgress()
        if progress_widget then
            progress_widget.dismiss_callback = nil
            pcall(UIManager.close, UIManager, progress_widget)
            progress_widget = nil
        end
        if not silent and not self.silent_messages then
            progress_widget = InfoMessage:new{
                text = _("Cleaning up removed books..."),
                timeout = 600,
            }
            UIManager:show(progress_widget)
            UIManager:forceRePaint()
        end
    end

    local function showDeletionSummary(deleted_count)
        if deleted_count > 0 then
            result.deleted = deleted_count
        end
        -- If there were downloads, finishSync handles the summary.
        -- If only deletions happened, show a compact message.
        if result.synced == 0 then
            finishSync()
        end
    end

    -- Build a download queue (filtered from books_to_download)
    local download_queue = {}
    for _i, book in ipairs(books_to_download) do
        local book_id = tonumber(book.id)
        if book_id then
            if not book.extension or book.extension == "" then
                self:logWarn("BookloreSync: skipping book", book_id,
                    "- extension unknown (bookType and originalFilename both absent)")
                result.failed = result.failed + 1
                -- skip
            else
                local filename = util.generateFilename(book, use_original_filename)
                local filepath = joinDownloadPath(download_dir, filename)

                -- Check existing file on disk
                local lfs_local = require("libs/libkoreader-lfs")
                local already_exists = lfs_local.attributes(filepath, "mode") == "file"

                if already_exists then
                    -- Check if we already have it cached; if so skip entirely
                    local cached = self.db:getBookByFilePath(filepath)
                    if cached then
                        result.skipped = result.skipped + 1
                        self:logInfo("BookloreSync: skip (already cached):", filepath)
                    else
                        -- File exists but not cached — compute hash
                        local hash = util.calculateBookHash(filepath)
                        self.db:saveBookCache(filepath, hash, book_id, book.title, book.author)
                        result.skipped = result.skipped + 1
                        self:logInfo("BookloreSync: cached existing file:", filepath)
                    end
                else
                    -- Migration: check for old-scheme file (without _id suffix)
                    local book_title = book.title or ""
                    local safe_title = ""
                    if book_title ~= "" then
                        safe_title = book_title
                            :gsub('[/\\\\:*?"<>|]', "")
                            :gsub("%s+", " ")
                            :gsub("^%s+", "")
                            :gsub("%s+$", "")
                    end
                    local old_filepath = safe_title ~= ""
                        and joinDownloadPath(download_dir, safe_title .. "." .. book.extension:lower())
                        or ""
                    if old_filepath ~= "" and old_filepath ~= filepath
                        and lfs_local.attributes(old_filepath, "mode") == "file" then
                        local rename_ok = os.rename(old_filepath, filepath)
                        if rename_ok then
                            self.db:updateFilePath(old_filepath, filepath)
                            local cached = self.db:getBookByFilePath(filepath)
                            if cached then
                                result.skipped = result.skipped + 1
                            else
                                local hash = util.calculateBookHash(filepath)
                                self.db:saveBookCache(filepath, hash, book_id, book.title, book.author)
                                result.skipped = result.skipped + 1
                            end
                            self:logInfo("BookloreSync: migrated old-scheme file:", old_filepath, "->", filepath)
                            goto skip_queue
                        end
                    end

                    -- Need to download — queue it
                    -- Check disk space first (best-effort) and capture file size
                    -- for progress display.
                    local file_size, size_err = self.api:getBookFileSize(book_id, self.booklore_username, self.booklore_password)
                    if file_size then
                        local available_bytes, space_err = self:getAvailableSpace(download_dir)
                        if available_bytes then
                            local min_free_bytes = self.min_free_space_mb * 1024 * 1024
                            if available_bytes < file_size + min_free_bytes then
                                local available_mb = math.floor(available_bytes / (1024 * 1024))
                                local file_size_mb = math.floor(file_size / (1024 * 1024) * 100) / 100
                                self:logWarn("BookloreSync: insufficient disk space for book", book_id,
                                    "- available:", available_mb, "MB, file:", file_size_mb, "MB")
                                result.failed = result.failed + 1
                                result.errors[#result.errors + 1] = T(_("Insufficient disk space for: %1"), book.title or tostring(book_id))
                                goto skip_queue
                            end
                        end
                    end

                    table.insert(download_queue, {
                        book      = book,
                        book_id   = book_id,
                        filepath  = filepath,
                        title     = book.title or filename,
                        file_size_bytes = file_size or nil,
                    })
                end
            end
        end
        ::skip_queue::
    end

    -- Phase 3: delete removed books BEFORE any downloads -----
    -- Deletions are instant file operations. Running them upfront avoids
    -- timing issues with the async download loop.
    local deleted = 0
    if delete_removed then
        if not first_sync then
            -- Delta-path deletion: remove every local file in the active download
            -- directory whose book_id disappeared from this shelf.
            local removed_lookup = {}
            for _i, removed_id in ipairs(books_to_delete) do
                local bid = tonumber(removed_id)
                if bid then
                    removed_lookup[bid] = true
                end
            end

            local dir_prefix = tostring(download_dir or ""):gsub("/+$", "") .. "/"
            local seen_path = {}

            local function queueDeletePath(fp, bid)
                fp = tostring(fp or "")
                if fp == "" then return end
                if fp:sub(1, #dir_prefix) ~= dir_prefix then return end
                if seen_path[fp] then return end
                seen_path[fp] = true
                if lfs.attributes(fp, "mode") ~= "file" then return end

                if bid and bookIdStillOnOtherShelf(self, target, bid) then
                    self:logInfo("BookloreSync: delta skip deletion of bookId=" .. tostring(bid) .. " - still on other shelf")
                    return
                end

                if os.remove(fp) then
                    deleted = deleted + 1
                    if delete_sdr then
                        local sdr_dirs = self:getSdrPaths(fp)
                        for _j, sdr_dir in ipairs(sdr_dirs) do
                            local ok_rm, err_rm = self:_deleteDirRecursive(sdr_dir)
                            if not ok_rm then
                                self:logErr("BookloreSync: Failed to delete sidecar: " .. tostring(sdr_dir) .. " | " .. tostring(err_rm))
                            end
                        end
                    end
                else
                    result.failed = result.failed + 1
                end
            end

            -- Pass 1: bulk scan (captures multiple rows per book_id when present)
            if self.db.getAllCachedBooks then
                local all_cached = self.db:getAllCachedBooks() or {}
                for _i, cached in ipairs(all_cached) do
                    local bid = cached and tonumber(cached.book_id)
                    if bid and removed_lookup[bid] then
                        queueDeletePath(cached.file_path, bid)
                    end
                end
            end

            -- Pass 2: per-id fallback (covers lightweight DB stubs and single-row lookups)
            for _i, removed_id in ipairs(books_to_delete) do
                local bid = tonumber(removed_id)
                local cached = nil
                if self.db.getBookByBookIdInDir then
                    cached = self.db:getBookByBookIdInDir(removed_id, download_dir)
                end
                if (not cached or not cached.file_path) and self.db.getBookByBookId then
                    cached = self.db:getBookByBookId(removed_id)
                end
                if cached and cached.file_path then
                    queueDeletePath(cached.file_path, bid)
                end
            end
        else
            local shelf_book_ids = {}
            for bid in pairs(curr_books) do shelf_book_ids[bid] = true end
            for entry in lfs.dir(download_dir) do
                if entry ~= "." and entry ~= ".." then
                    local fp = joinDownloadPath(download_dir, entry)
                    if lfs.attributes(fp, "mode") == "file" then
                        local cached = self.db and self.db:getBookByFilePath(fp)
                        local lid = cached and cached.book_id
                        if lid and not shelf_book_ids[lid] then
                            -- First-sync cross-check: if the other shelf has this book, keep the file.
                            if bookIdStillOnOtherShelf(self, target, lid) then
                                self:logInfo("BookloreSync: first-sync skip deletion of bookId=" .. tostring(lid) .. " - still on other shelf")
                            else
                                if os.remove(fp) then
                                    deleted = deleted + 1
                                    if delete_sdr then
                                        local sdr_dirs = self:getSdrPaths(fp)
                                        for _j, sdr_dir in ipairs(sdr_dirs) do
                                            local ok_rm, err_rm = self:_deleteDirRecursive(sdr_dir)
                                            if not ok_rm then
                                                self:logErr('BookloreSync: Failed to delete sidecar: ' .. tostring(sdr_dir) .. ' | ' .. tostring(err_rm))
                                            end
                                        end
                                    end
                                else
                                    result.failed = result.failed + 1
                                end
                            end
                        end
                    end
                end
            end
        end
    end
    result.deleted = deleted

    -- Nothing to download and no state to save when errors exist
    if #download_queue == 0 then
        if #result.errors == 0 then
            -- Persist shelf state for next delta
            local ok_enc, books_json = pcall(json.encode, books)
            if ok_enc and books_json then
                self.db:saveShelfState(shelf_id, target, books_json)
                self:logInfo('BookloreSync: shelf state saved for shelf_id', shelf_id)
            end
            finishSync(true)
        else
            finishSync(false)
        end
        return
    end

    -- ── Download loop (schedule-driven) ──────────────────────────────────────
    local total_dl = #download_queue
    local idx = 0
    local new_books = {}

    local function startNextDownload()
        if self._shelf_sync_cancelled then
            -- Save what we have so far
            if #new_books > 0 then
                self.db:beginTransaction()
                pcall(function()
                    for _i, nb in ipairs(new_books) do
                        self.db:saveBookCache(nb.filepath, nb.hash, nb.book_id,
                            nb.title, nb.author, nb.isbn10, nb.isbn13, nb.server_pagecount)
                        if nb.hardcover_id and nb.hardcover_id > 0 then
                            self.db:updateHardcoverId(nb.hash, nb.hardcover_id)
                        end
                    end
                end)
                self.db:commit()
            end
            closeProgress()
            result.cancelled = true

            -- Deletions already handled before the download loop.
            result.deleted = deleted

            self.sync_in_progress = false
            -- Run reinit and on_complete before showing the dialog so that
            -- it paints on a clean event loop tick on e-ink.
            if result.synced > 0 or result.deleted > 0 then
                local ok_fm, FM = pcall(require, "apps/filemanager/filemanager")
                if ok_fm and FM and FM.instance then
                    FM.instance:reinit(download_dir)
                end
            end
            if on_complete then on_complete(false, _("Sync cancelled")) end
            if not silent then
                UIManager:scheduleIn(0, function()
                    local lines = {}
                    lines[#lines + 1] = _("Shelf Sync Complete")
                    if result.synced > 0 then
                        lines[#lines + 1] = T(_("Downloaded:  %1"), result.synced)
                    end
                    if result.skipped > 0 then
                        lines[#lines + 1] = T(_("Already on device:  %1"), result.skipped)
                    end
                    if deleted > 0 then
                        lines[#lines + 1] = T(_("Removed:  %1"), deleted)
                    end
                    if result.failed > 0 then
                        lines[#lines + 1] = T(_("Failed:  %1"), result.failed)
                    end
                    lines[#lines + 1] = ""
                    lines[#lines + 1] = _("(Cancelled by user)")
                    UIManager:show(InfoMessage:new{
                        text = table.concat(lines, "\n"),
                        timeout = 6,
                    })
                    UIManager:forceRePaint()
                end)
            end
            return
        end

        idx = idx + 1
        if idx > total_dl then
            -- All downloads done -- DB commit + finish
            closeProgress()

            -- DB commit for downloaded books
            local ok_commit = true
            local err_commit = nil
            if #new_books > 0 then
                self.db:beginTransaction()
                ok_commit, err_commit = pcall(function()
                    for _i, nb in ipairs(new_books) do
                        self.db:saveBookCache(nb.filepath, nb.hash, nb.book_id,
                            nb.title, nb.author, nb.isbn10, nb.isbn13, nb.server_pagecount)
                        if nb.hardcover_id and nb.hardcover_id > 0 then
                            self.db:updateHardcoverId(nb.hash, nb.hardcover_id)
                        end
                    end
                end)
                if ok_commit then
                    local ok_c, err_c = pcall(function() self.db:commit() end)
                    if not ok_c then
                        ok_commit = false
                        err_commit = err_c
                    end
                end
                if not ok_commit then
                    self.db:rollback()
                    self:logErr("BookloreSync: syncFromBookloreShelf - DB commit error:", err_commit)
                    self.sync_in_progress = false
                    local msg = T(_("Sync failed: %1"), tostring(err_commit))
                    if not silent and not self.silent_messages then
                        UIManager:show(InfoMessage:new{ text = msg, timeout = 4 })
                    end
                    if on_complete then on_complete(false, msg) end
                    return
                end
            end

            -- Deletions already handled before the download loop.
            -- Persist shelf state now that downloads are complete.
            local ok_enc, books_json = pcall(json.encode, books)
            if ok_enc and books_json then
                self.db:saveShelfState(shelf_id, target, books_json)
                self:logInfo('BookloreSync: shelf state saved for shelf_id', shelf_id)
            end
            finishSync(true)
            return
        end

        local item = download_queue[idx]

        -- Expected size for progress bar: prefer the queue-time file size
        -- (obtained via HEAD request), fall back to book metadata.
        local expected_bytes = item.file_size_bytes
        if not expected_bytes then
            local book_meta = item.book or {}
            local meta_kb = tonumber(book_meta.fileSizeKb) or tonumber(book_meta.file_size_kb) or nil
            if meta_kb and meta_kb > 0 then
                expected_bytes = meta_kb * 1024
            end
        end
        local lfs_local = require("libs/libkoreader-lfs")

        -- Show initial progress before the subprocess starts.
        if not silent then
            showProgress(idx, total_dl, item.title, { bytes = 0, total_bytes = expected_bytes })
        end

        -- Capture loop-local values as plain types (closures don't survive fork).
        local cap_book_id  = item.book_id
        local cap_filepath = item.filepath
        local cap_title    = item.title
        local cap_book     = item.book
        local cap_username = self.booklore_username
        local cap_password = self.booklore_password
        local cap_server_url = server_url
        local cap_db_name  = db_name

        -- ── Launch subprocess to download the book ────────────────────────────
        -- The child process gets its own DB/API instances.  The parent polls
        -- via scheduleIn, keeping the event loop alive so progress renders on
        -- e-ink.
        local pid, read_fd = ffiutil.runInSubProcess(function(_, write_fd)
            local ChildDB = require("booklore_database")
            local ChildAPI = require("booklore_api_client")
            local child_logger = {
                logInfo = function() end, logWarn = function() end,
                logErr  = function() end, logDbg  = function() end,
            }
            local child_db = ChildDB:new(child_logger)
            child_db:init(cap_db_name)
            local child_api = ChildAPI:new(child_logger)
            child_api:init(cap_server_url, cap_username, cap_password, child_db)
            local ok, err = child_api:downloadBook(cap_book_id, cap_filepath, cap_username, cap_password)
            child_db:close()
            local results = strbuf.encode({ ok = ok, err = err })
            ffiutil.writeToFD(write_fd, results, true)
        end, true)

        if not pid then
            result.failed = result.failed + 1
            local err_msg = "Failed to fork subprocess for bookId=" .. tostring(cap_book_id)
            result.errors[#result.errors + 1] = err_msg
            self:logErr("BookloreSync: failed to fork subprocess for bookId=", tostring(cap_book_id))
            UIManager:scheduleIn(0.5, startNextDownload)
            return
        end

        -- ── Poll subprocess progress ──────────────────────────────────────────
        -- Every poll tick we check the temp file size (file is written in-place
        -- by downloadBook, so we read the destination file's current size).
        -- Between polls the event loop runs, so showProgress() renders on e-ink.
        local function pollDownload()
            -- Check cancel: don't abort mid-download (no partial files),
            -- but cancel will be picked up on the next startNextDownload tick.
            if self._shelf_sync_cancelled then
                -- Let the subprocess finish; we'll discard at the boundary.
            end

            -- Update progress from current file size on disk.
            if not silent then
                local attr = lfs_local.attributes(cap_filepath)
                if attr and attr.mode == "file" then
                    showProgress(idx, total_dl, cap_title, {
                        bytes = attr.size,
                        total_bytes = expected_bytes,
                    })
                end
            end

            if ffiutil.isSubProcessDone(pid) then
                -- Subprocess finished — read result.
                local result_str = ffiutil.readAllFromFD(read_fd)
                local ok_dec, decoded = pcall(strbuf.decode, result_str)
                local dl_ok = false
                local dl_err = nil
                if ok_dec and type(decoded) == "table" then
                    dl_ok = decoded.ok
                    dl_err = decoded.err
                end

                if dl_ok then
                    -- If cancelled, don't count or persist this download.
                    if self._shelf_sync_cancelled then
                        self:logInfo("BookloreSync: downloaded bookId=" .. tostring(cap_book_id) .. " but sync was cancelled")
                    else
                        local hash_raw = util.calculateBookHash(cap_filepath)
                        local hash = hash_raw or ""
                        if not hash_raw then
                            self:logWarn("BookloreSync: could not compute hash for", cap_filepath)
                        end
                        local book = cap_book or {}
                        local metadata = type(book.metadata) == "table" and book.metadata or {}
                        local isbn10 = book.isbn10 or metadata.isbn10 or nil
                        local isbn13 = book.isbn13 or metadata.isbn13 or nil
                        local hardcover_id = tonumber(book.hardcover_id)
                            or tonumber(book.hardcoverId)
                            or tonumber(metadata.hardcoverBookId)
                            or tonumber(metadata.hardcoverId)
                            or tonumber(metadata.hardcover_id)
                        local pagecount = tonumber(book.pagecount)
                            or tonumber(book.server_pagecount)
                            or tonumber(metadata.pagecount)
                            or tonumber(metadata.pageCount)

                        table.insert(new_books, {
                            filepath = cap_filepath,
                            hash     = hash,
                            book_id  = cap_book_id,
                            title    = book.title,
                            author   = book.author or book.authors,
                            isbn10   = isbn10,
                            isbn13   = isbn13,
                            hardcover_id = hardcover_id,
                            server_pagecount = pagecount,
                        })
                        result.synced = result.synced + 1
                        self:logInfo("BookloreSync: downloaded bookId=" .. tostring(cap_book_id) .. " to " .. cap_filepath)
                    end
                else
                    if not self._shelf_sync_cancelled then
                        result.failed = result.failed + 1
                    end
                    local err_msg = "Failed to download bookId=" .. tostring(cap_book_id) .. ": " .. tostring(dl_err)
                    result.errors[#result.errors + 1] = err_msg
                    self:logWarn("BookloreSync:", err_msg)
                end

                -- Show final progress state, then schedule next download.
                if not silent then
                    local final_attr = lfs_local.attributes(cap_filepath)
                    local final_bytes = final_attr and final_attr.mode == "file" and final_attr.size or 0
                    showProgress(idx, total_dl, cap_title, {
                        bytes = final_bytes,
                        total_bytes = expected_bytes,
                    })
                end
                UIManager:scheduleIn(1, startNextDownload)
                return
            end

            -- Still downloading — poll again in 0.5s.
            UIManager:scheduleIn(0.5, pollDownload)
        end

        -- Start polling after a short delay so the initial progress widget
        -- has time to render before the first poll fires.
        UIManager:scheduleIn(0.3, pollDownload)
    end

    -- Kick off the download loop
    if not silent then
        showProgress(1, total_dl, download_queue[1].title)
    end

    -- Schedule the first download with a short delay so the progress
    -- InfoMessage renders before the blocking API call.
    UIManager:scheduleIn(0.5, startNextDownload)

    -- Return immediately — downloads proceed asynchronously via scheduleIn.
    return true
    end

    return module
end

return M
