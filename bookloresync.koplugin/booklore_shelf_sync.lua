local M = {}

function M.new(deps)
    local _ = deps._
    local T = deps.T
    local UIManager = deps.UIManager
    local InfoMessage = deps.InfoMessage
    local ButtonDialog = deps.ButtonDialog
    local json = deps.json
    local Trapper = deps.Trapper
    local ffiutil = deps.ffiutil
    local strbuf = deps.strbuf

    local module = {}

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
        local extension = (book.extension or "epub"):lower()
        local ext_suffix = "." .. extension
        local id_tag = "_" .. tostring(book.id)
        local title = book.title
        if title and title ~= "" then
            local safe = title
                :gsub('[/\\:*?"<>|]', "")
                :gsub("%s+", " ")
                :gsub("^%s+", "")
                :gsub("%s+$", "")
            if safe ~= "" then
                local max_stem = 150 - #id_tag - #ext_suffix
                if #safe > max_stem then
                    safe = safe:sub(1, max_stem):gsub("%s+$", "")
                end
                return safe .. id_tag .. ext_suffix
            end
        end
        return "BookID_" .. tostring(book.id) .. ext_suffix
    end


    function module.syncFromBookloreShelf(self, silent, on_complete)
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

    -- Ensure download directory exists
    local lfs = require("libs/libkoreader-lfs")
    if lfs.attributes(self.download_dir, "mode") ~= "directory" then
        local ok_mkdir = lfs.mkdir(self.download_dir)
        if not ok_mkdir then
            local msg = T(_("Cannot create download directory: %1"), self.download_dir)
            self:logErr("BookloreSync: syncFromBookloreShelf -", msg)
            if not silent and not self.silent_messages then
                UIManager:show(InfoMessage:new{ text = msg, timeout = 3 })
            end
            if on_complete then on_complete(false, msg) end
            return false, msg
        end
    end

    self.sync_in_progress = true
    self:logInfo("BookloreSync: syncFromBookloreShelf - starting Trapper sync")

    -- Capture all subprocess inputs as plain values now, before the fork.
    -- The child process gets a copy of Lua state - writes to self are invisible
    -- to the parent, and self.db / self.api must not be used across the fork
    -- boundary (file-descriptor aliasing, socket state, etc.).
    local server_url      = self.server_url
    local username        = self.booklore_username
    local password        = self.booklore_password
    local shelf_name      = self.booklore_shelf_name
    -- Database:init(db_name) always prepends DataStorage:getSettingsDir() + "/",
    -- so pass the bare filename rather than the already-absolute db_path.
    local db_name         = self.db.db_path:match("([^/]+)$") or "booklore-sync.sqlite"
    local download_dir    = self.download_dir
    local delete_removed  = self.delete_removed_shelf_books
    local use_original_filename = self.shelf_use_original_filename
    local delete_sdr      = self.delete_sdr_on_book_delete
    -- Logging config: captured so subprocesses can write to the same log file.
    local sub_log_to_file = self.log_to_file and self.file_logger ~= nil
    local sub_log_dir     = sub_log_to_file and self.file_logger.log_dir or nil

    -- Helper: inline hash calculation for subprocess use.
    -- Mirrors BookloreSync:calculateBookHash but with no self dependency.
    ---calcHash.
    local function calcHash(file_path)
        local file = io.open(file_path, "rb")
        if not file then return nil end
        local md5        = require("ffi/sha2").md5
        local base       = 1024
        local block_size = 1024
        local buffer     = {}
        local file_size  = file:seek("end")
        file:seek("set", 0)
        for i = -1, 10 do
            local position = bit.lshift(base, 2 * i)
            if position >= file_size then break end
            file:seek("set", position)
            local chunk = file:read(block_size)
            if chunk then table.insert(buffer, chunk) end
        end
        file:close()
        return md5(table.concat(buffer))
    end

    -- Helper: generate filename - pure Lua, no self, same logic as _generateFilename.
    -- Precondition: book.extension must already be set (non-nil, non-empty).
    ---genFilename.
    local function genFilename(book)
        local extension = book.extension:lower()
        local ext_suffix = "." .. extension
        local id_tag     = "_" .. tostring(book.id)

        -- If user chose original filename and the server provided one, use it.
        -- Strip the extension from the original filename, sanitize the stem,
        -- then append "_id" so the book ID is embedded in every downloaded file.
        if use_original_filename and book.original_filename and book.original_filename ~= "" then
            -- Strip the trailing extension (last ".something") to get the stem.
            local orig_stem = book.original_filename:match("^(.+)%.[^.]+$")
                           or book.original_filename
            local safe = orig_stem
                :gsub('[/\\:*?"<>|]', "")
                :gsub("%s+", " ")
                :gsub("^%s+", "")
                :gsub("%s+$", "")
            if safe ~= "" then
                local max_stem = 150 - #id_tag - #ext_suffix
                if #safe > max_stem then
                    safe = safe:sub(1, max_stem):gsub("%s+$", "")
                end
                return safe .. id_tag .. ext_suffix
            end
        end

        -- Default: derive filename from title.
        local title = book.title
        if title and title ~= "" then
            local safe = title
                :gsub('[/\\:*?"<>|]', "")
                :gsub("%s+", " ")
                :gsub("^%s+", "")
                :gsub("%s+$", "")
            if safe ~= "" then
                -- Reserve room for the "_id" tag so the total stays under 150 chars
                local max_stem = 150 - #id_tag - #ext_suffix
                if #safe > max_stem then
                    safe = safe:sub(1, max_stem):gsub("%s+$", "")
                end
                return safe .. id_tag .. ext_suffix
            end
        end
        -- Fallback: "BookID_" already embeds the id; no extra tag needed.
        return "BookID_" .. tostring(book.id) .. ext_suffix
    end

    -- Build a lightweight plugin stub for use inside subprocesses.
    -- Subprocesses are forked copies of the Lua VM - they cannot use the parent's
    -- self.file_logger (different fd, different state), but they CAN open the same
    -- log file in append mode and write to it directly.  The log directory already
    -- exists (created by the parent's FileLogger:init), so no setup is needed.
    -- The filename pattern matches FileLogger:getLogFilePath() exactly so that
    -- subprocess entries land in the same rotating file as parent entries.
    -- Method signatures use (_, ...) because Database/API call these via colon
    -- syntax (self.plugin:logInfo(...)), which passes self as the first argument.
    ---makeSubprocessPlugin.
    local function makeSubprocessPlugin()
        if not sub_log_to_file or not sub_log_dir then
            local noop = function() end
            return { logInfo = noop, logWarn = noop, logErr = noop, logDbg = noop }
        end
        local log_path = sub_log_dir .. "/" .. os.date("booklore-%Y-%m-%d.log")
        local log_file = io.open(log_path, "a")
        ---write.
        local function write(level, ...)
            if not log_file then return end
            local args = {...}
            local parts = {}
            for i = 1, #args do parts[i] = tostring(args[i]) end
            log_file:write(string.format("[%s] [%s] %s\n",
                os.date("%Y-%m-%d %H:%M:%S"), level, table.concat(parts, " ")))
            log_file:flush()
        end
        return {
            logInfo = function(_, ...) write("INFO",  ...) end,
            logWarn = function(_, ...) write("WARN",  ...) end,
            logErr  = function(_, ...) write("ERROR", ...) end,
            logDbg  = function(_, ...) write("DEBUG", ...) end,
        }
    end

    -- Trapper:wrap() hands control to a coroutine on the UI thread.
     -- Trapper:wrap() provides the coroutine context needed for coroutine.yield().
     -- We do NOT use Trapper's TrapWidget machinery for cancellation - instead we
     -- poll the subprocess ourselves and honour cancel_requested set by the dialog.
     Trapper:wrap(function()
        -- runSubprocess: fork fn(), poll until done, yield control to UIManager
        -- between checks.  No TrapWidget is created, so no gesture can cancel
        -- the sync except the explicit Cancel button in status_dialog.
        -- Returns completed (bool), result (table).
        local _coroutine = coroutine.running()
        ---runSubprocess.
        local function runSubprocess(fn)
            local pid, read_fd = ffiutil.runInSubProcess(function(_, write_fd)
                local results = table.pack(fn())
                local ok, str = pcall(strbuf.encode, results)
                if ok then ffiutil.writeToFD(write_fd, str, true) end
            end, true)
            if not pid then return false, nil end
            local check_interval = 0.125
            local check_num = 0
            while true do
                check_num = check_num + 1
                if check_interval < 1 and check_num % 10 == 0 then
                    check_interval = math.min(check_interval * 2, 1)
                end
                local resume_func = function() coroutine.resume(_coroutine) end
                UIManager:scheduleIn(check_interval, resume_func)
                coroutine.yield()
                local done  = ffiutil.isSubProcessDone(pid)
                local ready = read_fd and ffiutil.getNonBlockingReadSize(read_fd) ~= 0
                if done or ready then
                    local result
                    if ready then
                        local str = ffiutil.readAllFromFD(read_fd)
                        local ok, t = pcall(strbuf.decode, str)
                        if ok and t then result = table.unpack(t, 1, t.n) end
                        if not done then
                            ---collect.
                            local function collect()
                                if not ffiutil.isSubProcessDone(pid) then
                                    UIManager:scheduleIn(1, collect)
                                end
                            end
                            UIManager:scheduleIn(1, collect)
                        end
                    else
                        ffiutil.readAllFromFD(read_fd)
                    end
                    return true, result
                end
            end
        end


        -- Show a persistent status dialog with an explicit Cancel button.
        -- dismissable=false means tapping outside the dialog does nothing,
        -- so the user cannot accidentally cancel by tapping the screen.
        -- Cancel during Phase 2 completes the current book before stopping.
        local cancel_requested = false
        local status_dialog
        status_dialog = ButtonDialog:new{
            dismissable = false,
            title = _("Fetching book list from shelf..."),
            buttons = {{ {
                text = _("Cancel"),
                callback = function()
                    cancel_requested = true
                    UIManager:close(status_dialog)
                end,
            } }},
        }
        UIManager:show(status_dialog)

        -- ── Phase 1: fetch shelf metadata (single subprocess) ──────────────
        local fetch_completed, fetch_result = runSubprocess(function()
            -- Child process: no UIManager calls allowed here.
            local ChildDB  = require("booklore_database")
            local ChildAPI = require("booklore_api_client")
            local child_plugin = makeSubprocessPlugin()
            local child_db = ChildDB:new(child_plugin)
            child_db:init(db_name)
            local child_api = ChildAPI:new(child_plugin)
            child_api:init(server_url, username, password, child_db)

            local shelf_ok, shelf_id = child_api:getOrCreateShelf(shelf_name, username, password)
            if not shelf_ok then
                child_db:close()
                return { success = false, error = tostring(shelf_id or "Failed to get/create shelf") }
            end

            local books_ok, books = child_api:getBooksInShelf(shelf_id, username, password)
            if not books_ok then
                child_db:close()
                return { success = false, error = tostring(books or "Failed to retrieve books from shelf") }
            end

            -- Read the cached shelf state so the parent can compute the delta.
            local cached_state = child_db:getShelfState(shelf_id)
            child_db:close()

            return { success = true, shelf_id = shelf_id, books = books or {}, cached_state = cached_state }
        end)

        -- completed=false means subprocess fork failed
        if not fetch_completed then
            UIManager:close(status_dialog)
            self.sync_in_progress = false
            if not silent and not self.silent_messages then
                UIManager:show(InfoMessage:new{ text = _("Sync cancelled"), timeout = 2 })
            end
            if on_complete then on_complete(false, _("Sync cancelled")) end
            return
        end

        -- completed=true but no result table means the subprocess crashed without output
        if type(fetch_result) ~= "table" then
            UIManager:close(status_dialog)
            self.sync_in_progress = false
            local msg = _("Sync failed: subprocess returned no data")
            self:logErr("BookloreSync: syncFromBookloreShelf - phase 1 returned no data")
            if not silent and not self.silent_messages then
                UIManager:show(InfoMessage:new{ text = msg, timeout = 4 })
            end
            if on_complete then on_complete(false, msg) end
            return
        end

        if not fetch_result.success then
            UIManager:close(status_dialog)
            self.sync_in_progress = false
            local msg = T(_("Sync failed: %1"), fetch_result.error or "unknown error")
            self:logErr("BookloreSync: syncFromBookloreShelf - phase 1 error:", fetch_result.error)
            if not silent and not self.silent_messages then
                UIManager:show(InfoMessage:new{ text = msg, timeout = 4 })
            end
            if on_complete then on_complete(false, msg) end
            return
        end

        -- Update shelf_id if it changed (parent-thread write, safe)
        local new_shelf_id = fetch_result.shelf_id
        if new_shelf_id ~= self.shelf_id then
            self.shelf_id = new_shelf_id
            self.settings:saveSetting("shelf_id", self.shelf_id)
            self.settings:flush()
        end

        local books = fetch_result.books
        if type(books) ~= "table" or #books == 0 then
            UIManager:close(status_dialog)
            self.sync_in_progress = false
            local msg = _("Shelf is empty - no books to sync")
            -- Shelf is now confirmed empty - save that state so the next sync
            -- also exits fast (no books to add; everything already removed).
            self.db:saveShelfState(new_shelf_id, "[]")
            if not silent and not self.silent_messages then
                UIManager:show(InfoMessage:new{ text = msg, timeout = 3 })
            end
            if on_complete then on_complete(true, msg) end
            return
        end

        -- ── Delta computation: diff current shelf against cached state ──────
        -- Build a lookup of the previously known shelf contents (by book ID).
        -- An absent cache means this is the first sync: treat every book as new.
        local prev_books = {}  -- book_id (number) → book object from last sync
        local cached_state = fetch_result.cached_state
        if cached_state and type(cached_state.books_json) == "string" then
            local ok_dec, decoded = pcall(json.decode, cached_state.books_json)
            if ok_dec and type(decoded) == "table" then
                for _, b in ipairs(decoded) do
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

        local curr_books = {}  -- book_id (number) → book object from current API response
        for _, b in ipairs(books) do
            local bid = tonumber(b.id)
            if bid then curr_books[bid] = b end
        end

        local books_to_download = {}   -- new additions: in current but not in previous
        local books_to_delete   = {}   -- removals: in previous but not in current (IDs only)

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

        local first_sync = (next(prev_books) == nil)  -- no cached state at all
        local total_new  = #books_to_download
        local total_del  = #books_to_delete

        self:logInfo(string.format(
            "BookloreSync: delta - total=%d new=%d removed=%d first_sync=%s",
            #books, total_new, total_del, tostring(first_sync)
        ))

        -- ── Phase 2: per-book download loop (only new additions) ───────────
        local downloaded   = 0
        local skipped      = 0
        local errors       = 0
        local new_books    = {}   -- accumulate DB writes for Phase 3
        local space_error_info = nil  -- Track space error details for final notification

        -- Update dialog title to show what we actually need to do.
        if total_new == 0 and total_del == 0 then
            status_dialog:setTitle(_("Shelf up to date - nothing to do"))
        else
            status_dialog:setTitle(T(_("Syncing shelf: %1 new, %2 removed"), total_new, total_del))
        end

        -- Helper: flush accumulated DB writes and report cancellation.
        ---cancelSync.
        local function cancelSync(books_done)
            self:logInfo("BookloreSync: sync cancelled by user after", books_done, "books")
            self.sync_in_progress = false
            if #new_books > 0 then
                self.db:beginTransaction()
                local ok_partial = pcall(function()
                    for _, nb in ipairs(new_books) do
                        self.db:saveBookCache(nb.filepath, nb.hash, nb.book_id,
                            nb.title, nb.author, nb.isbn10, nb.isbn13)
                    end
                end)
                if ok_partial then self.db:commit() else self.db:rollback() end
            end
            if not silent and not self.silent_messages then
                UIManager:show(InfoMessage:new{
                    text = T(_("Sync cancelled after %1 of %2 books"), books_done, total_new),
                    timeout = 3,
                })
            end
            -- Do NOT save shelf state: sync is incomplete.
            if on_complete then on_complete(false, _("Sync cancelled")) end
        end

        for i, book in ipairs(books_to_download) do
            local book_id = tonumber(book.id)
            if not book_id then goto book_continue end

            if not book.extension or book.extension == "" then
                self:logWarn("BookloreSync: skipping book", book_id,
                    "- extension unknown (bookType and originalFilename both absent)")
                errors = errors + 1
                goto book_continue
            end

            local filename = genFilename(book)
            local filepath = download_dir .. "/" .. filename

            -- ── Migration: rename old-scheme files to the new ID-tagged name ───
            if lfs.attributes(filepath, "mode") ~= "file" then
                local extension = book.extension:lower()
                local ext_suffix = "." .. extension
                local id_tag     = "_" .. tostring(book_id)
                local old_safe_title = book.title and book.title
                    :gsub('[/\\:*?"<>|]', "")
                    :gsub("%s+", " ")
                    :gsub("^%s+", "")
                    :gsub("%s+$", "") or ""
                local old_max_stem = 150 - #ext_suffix
                if #old_safe_title > old_max_stem then
                    old_safe_title = old_safe_title:sub(1, old_max_stem):gsub("%s+$", "")
                end
                local orig_stem = (book.original_filename or ""):match("^(.+)%.[^.]+$")
                               or book.original_filename or ""
                local old_safe_orig = orig_stem
                    :gsub('[/\\:*?"<>|]', "")
                    :gsub("%s+", " ")
                    :gsub("^%s+", "")
                    :gsub("%s+$", "")
                if #old_safe_orig > old_max_stem then
                    old_safe_orig = old_safe_orig:sub(1, old_max_stem):gsub("%s+$", "")
                end
                local candidates = {}
                if old_safe_title ~= "" then
                    table.insert(candidates, download_dir .. "/" .. old_safe_title .. ext_suffix)
                end
                if old_safe_orig ~= "" and old_safe_orig ~= old_safe_title then
                    table.insert(candidates, download_dir .. "/" .. old_safe_orig .. ext_suffix)
                end
                table.insert(candidates, download_dir .. "/BookID_" .. tostring(book_id) .. ext_suffix)
                for _, old_path in ipairs(candidates) do
                    if old_path ~= filepath and lfs.attributes(old_path, "mode") == "file" then
                        local ok_mv = os.rename(old_path, filepath)
                        if ok_mv then
                            self:logInfo("BookloreSync: migrated file", old_path, "->", filepath)
                            if self.db and self.db.updateFilePath then
                                self.db:updateFilePath(old_path, filepath)
                            end
                        else
                            self:logWarn("BookloreSync: failed to migrate file", old_path, "->", filepath)
                        end
                        break
                    end
                end
            end

            local already_exists = lfs.attributes(filepath, "mode") == "file"

            -- ── Check disk space before downloading ─────────────────────────────
            if not already_exists then
                local file_size, size_err = self.api:getBookFileSize(book_id, self.booklore_username, self.booklore_password)
                if not file_size then
                    self:logWarn("BookloreSync: could not get file size for book", book_id, ":", size_err or "unknown error")
                else
                    local available_bytes, space_err = self:getAvailableSpace(download_dir)
                    if not available_bytes then
                        self:logErr("BookloreSync: could not check available space:", space_err or "unknown error")
                    else
                        local min_free_bytes = self.min_free_space_mb * 1024 * 1024
                        local required_bytes = file_size + min_free_bytes

                        if available_bytes < required_bytes then
                            local available_mb = math.floor(available_bytes / (1024 * 1024))
                            local file_size_mb = math.floor(file_size / (1024 * 1024) * 100) / 100
                            local required_mb = math.floor(required_bytes / (1024 * 1024))

                            space_error_info = {
                                book_title = book.title or "Unknown",
                                available_mb = available_mb,
                                file_size_mb = file_size_mb,
                                min_free_mb = self.min_free_space_mb,
                                required_mb = required_mb,
                                books_downloaded = downloaded,
                                books_total = total_new,
                            }

                            self:logWarn("BookloreSync: insufficient disk space for book", book_id,
                                "- available:", available_mb, "MB, required:", required_mb, "MB")
                            break
                        end
                    end
                end
            end

            -- Update the dialog title to show current book progress.
            if already_exists then
                status_dialog:setTitle(T(_("Skipping: %1 (%2/%3)"), book.title or "Unknown", i, total_new))
            else
                status_dialog:setTitle(T(_("Downloading: %1 (%2/%3)"), book.title or "Unknown", i, total_new))
            end

            -- Capture loop-local values for the closure (Lua upvalue semantics)
            local cap_book_id  = book_id
            local cap_filepath = filepath
            local cap_title    = book.title
            local cap_author   = book.author
            local cap_isbn10   = book.isbn10
            local cap_isbn13   = book.isbn13

            local book_completed, book_result = runSubprocess(function()
                -- Child: check / download / hash one book.
                if lfs.attributes(cap_filepath, "mode") == "file" then
                    -- File already on disk; check if it needs a cache entry
                    local ChildDB2 = require("booklore_database")
                    local child_plugin2 = makeSubprocessPlugin()
                    local child_db2 = ChildDB2:new(child_plugin2)
                    child_db2:init(db_name)
                    local cached = child_db2:getBookByFilePath(cap_filepath)
                    child_db2:close()
                    if cached then
                        return { status = "skipped" }
                    end
                    -- Not cached yet: compute hash so parent can save it
                    local hash = calcHash(cap_filepath)
                    return { status = "skipped_uncached", hash = hash }
                end

                -- Download the file
                local ChildDB3  = require("booklore_database")
                local ChildAPI3 = require("booklore_api_client")
                local child_plugin3 = makeSubprocessPlugin()
                local child_db3 = ChildDB3:new(child_plugin3)
                child_db3:init(db_name)
                local child_api3 = ChildAPI3:new(child_plugin3)
                child_api3:init(server_url, username, password, child_db3)

                local dl_ok, dl_err = child_api3:downloadBook(cap_book_id, cap_filepath, username, password)
                child_db3:close()

                if not dl_ok then
                    return { status = "error", error = tostring(dl_err or "download failed") }
                end

                local hash = calcHash(cap_filepath)
                return { status = "downloaded", hash = hash }
            end)

            -- completed=false means the subprocess fork failed
            if not book_completed then
                UIManager:close(status_dialog)
                cancelSync(i - 1)
                return
            end

            -- Cancel button was pressed: current book just finished cleanly, stop now.
            if cancel_requested then
                if type(book_result) == "table" then
                    if book_result.status == "downloaded" then
                        downloaded = downloaded + 1
                        table.insert(new_books, {
                            filepath = cap_filepath, hash = book_result.hash,
                            book_id  = cap_book_id,  title = cap_title,
                            author   = cap_author,   isbn10 = cap_isbn10, isbn13 = cap_isbn13,
                        })
                    elseif book_result.status == "skipped_uncached" then
                        skipped = skipped + 1
                        table.insert(new_books, {
                            filepath = cap_filepath, hash = book_result.hash,
                            book_id  = cap_book_id,  title = cap_title,
                            author   = cap_author,   isbn10 = cap_isbn10, isbn13 = cap_isbn13,
                        })
                    elseif book_result.status == "skipped" then
                        skipped = skipped + 1
                    end
                end
                cancelSync(i)
                return
            end

            -- If subprocess crashed with no output, treat as an error for this book
            if type(book_result) ~= "table" then
                self:logWarn("BookloreSync: subprocess returned no data for book:", cap_title)
                errors = errors + 1
                goto book_continue
            end

            if book_result.status == "downloaded" then
                downloaded = downloaded + 1
                table.insert(new_books, {
                    filepath = cap_filepath, hash = book_result.hash,
                    book_id  = cap_book_id,  title = cap_title,
                    author   = cap_author,   isbn10 = cap_isbn10, isbn13 = cap_isbn13,
                })
            elseif book_result.status == "skipped_uncached" then
                skipped = skipped + 1
                table.insert(new_books, {
                    filepath = cap_filepath, hash = book_result.hash,
                    book_id  = cap_book_id,  title = cap_title,
                    author   = cap_author,   isbn10 = cap_isbn10, isbn13 = cap_isbn13,
                })
            elseif book_result.status == "skipped" then
                skipped = skipped + 1
            else
                self:logWarn("BookloreSync: Download failed for book:", cap_title, book_result.error)
                errors = errors + 1
            end

            ::book_continue::
        end

        UIManager:close(status_dialog)

        -- ── Phase 3: DB writes + optional deletions (parent/UI thread) ─────
        local deleted = 0

        self.db:beginTransaction()
        local ok_commit, err_commit = pcall(function()
            for _, nb in ipairs(new_books) do
                self.db:saveBookCache(nb.filepath, nb.hash, nb.book_id,
                    nb.title, nb.author, nb.isbn10, nb.isbn13)
            end

            if delete_removed then
                if not first_sync then
                    -- Delta path: we know exactly which book IDs were removed.
                    -- Look up their file paths from the DB and delete directly,
                    -- avoiding a full directory walk.
                    for _, removed_id in ipairs(books_to_delete) do
                        local cached = self.db:getBookByBookId(removed_id)
                        if cached and cached.file_path then
                            local fp = cached.file_path
                            if lfs.attributes(fp, "mode") == "file" then
                                if os.remove(fp) then
                                    deleted = deleted + 1
                                    if delete_sdr then
                                        local sdr_dirs = self:getSdrPaths(fp)
                                        for _, sdr_dir in ipairs(sdr_dirs) do
                                            self:logInfo("BookloreSync: Deleting sidecar:", sdr_dir)
                                            local ok_rm, err_rm = self:_deleteDirRecursive(sdr_dir)
                                            if not ok_rm then
                                                self:logErr("BookloreSync: Failed to delete sidecar:", sdr_dir, err_rm)
                                            end
                                        end
                                    end
                                else
                                    errors = errors + 1
                                end
                            end
                        end
                    end
                else
                    -- First sync (no previous state): fall back to the directory
                    -- walk so any orphan files from before the plugin managed this
                    -- folder are still cleaned up.
                    local shelf_book_ids = {}
                    for bid in pairs(curr_books) do shelf_book_ids[bid] = true end
                    for entry in lfs.dir(download_dir) do
                        if entry ~= "." and entry ~= ".." then
                            local fp = download_dir .. "/" .. entry
                            if lfs.attributes(fp, "mode") == "file" then
                                local cached = self.db and self.db:getBookByFilePath(fp)
                                local lid = cached and cached.book_id
                                if lid and not shelf_book_ids[lid] then
                                    if os.remove(fp) then
                                        deleted = deleted + 1
                                        if delete_sdr then
                                            local sdr_dirs = self:getSdrPaths(fp)
                                            for _, sdr_dir in ipairs(sdr_dirs) do
                                                self:logInfo("BookloreSync: Deleting sidecar:", sdr_dir)
                                                local ok_rm, err_rm = self:_deleteDirRecursive(sdr_dir)
                                                if not ok_rm then
                                                    self:logErr("BookloreSync: Failed to delete sidecar:", sdr_dir, err_rm)
                                                end
                                            end
                                        end
                                    else
                                        errors = errors + 1
                                    end
                                end
                            end
                        end
                    end
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
            self:logErr("BookloreSync: syncFromBookloreShelf - phase 3 commit error:", err_commit)
            self.sync_in_progress = false
            local msg = T(_("Sync failed: %1"), tostring(err_commit))
            if not silent and not self.silent_messages then
                UIManager:show(InfoMessage:new{ text = msg, timeout = 4 })
            end
            -- Do NOT save shelf state: sync failed.
            if on_complete then on_complete(false, msg) end
            return
        end

        -- Persist the current shelf contents as the new baseline for the next
        -- delta sync.  Only saved after a fully successful commit so that a
        -- partial/cancelled sync does not corrupt the cached state.
        -- json.encode the full current book list (not just the delta).
        if not space_error_info then
            local ok_enc, books_json = pcall(json.encode, books)
            if ok_enc and books_json then
                self.db:saveShelfState(new_shelf_id, books_json)
                self:logInfo("BookloreSync: shelf state saved for shelf_id", new_shelf_id)
            else
                self:logWarn("BookloreSync: could not encode shelf state for caching")
            end
        end

        self.sync_in_progress = false

        -- ── Show space error notification if sync stopped due to insufficient space ───
        if space_error_info then
            local ConfirmBox = require("ui/widget/confirmbox")
            local space_msg = T(
                _("No space left on device\n\n" ..
                  "Book: %1\n" ..
                  "File size: %2 MB\n" ..
                  "Available space: %3 MB\n" ..
                  "Required space: %4 MB (file + %5 MB buffer)\n\n" ..
                  "Downloaded %6 of %7 books before stopping."),
                space_error_info.book_title,
                space_error_info.file_size_mb,
                space_error_info.available_mb,
                space_error_info.required_mb,
                space_error_info.min_free_mb,
                space_error_info.books_downloaded,
                space_error_info.books_total
            )

            if not silent and not self.silent_messages then
                UIManager:show(ConfirmBox:new{
                    text = space_msg,
                    ok_text = _("Close"),
                    ok_callback = function()
                        -- Just close the dialog
                    end,
                })
            end

            if on_complete then
                on_complete(false, _("Sync stopped: insufficient disk space"))
            end
            return
        end

        local final_msg = T(
            _("Sync complete!\n\nDownloaded: %1\nSkipped: %2\nDeleted: %3\nErrors: %4"),
            downloaded, skipped, deleted, errors
        )
        self:logInfo("BookloreSync: syncFromBookloreShelf -", final_msg)

        if not silent and not self.silent_messages then
            UIManager:show(InfoMessage:new{ text = final_msg, timeout = 5 })
        end

        if downloaded > 0 then
            local ok_fm, FM = pcall(require, "apps/filemanager/filemanager")
            if ok_fm and FM and FM.instance then
                FM.instance:reinit(self.download_dir)
            end
        end

        if on_complete then on_complete(true, final_msg) end
    end)

    -- Trapper:wrap() returns immediately; the coroutine is driven by UIManager.
    return true
    end

    return module
end

return M
