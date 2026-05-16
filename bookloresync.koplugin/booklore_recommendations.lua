--[[--
Booklore Post-Finish Recommendations Module

When the user finishes a book and returns to the file browser, this module:

  1. Fetches up to N recommended books via
     GET /api/v1/books/{id}/recommendations?limit=N
  2. Shows a selection dialog of recommended titles.
  3. On tap, shows a per-book details dialog with title, authors,
     description and metadata, plus three buttons:
       - "Return to recommendations" — go back to the list dialog
       - "Close"                     — dismiss everything
       - "Fetch"                     — download the book, store metadata,
                                       then ask whether to start reading it.

Designed as a factory module mirroring booklore_shelf_sync /
booklore_matching_module: M.new(deps) returns a table whose functions take
the active BookloreSync plugin instance as the first argument.

@module koplugin.BookloreSync.recommendations
--]]--

local M = {}

function M.new(deps)
    local _ = deps._
    local T = deps.T
    local UIManager = deps.UIManager
    local InfoMessage = deps.InfoMessage
    local ConfirmBox = deps.ConfirmBox
    local ButtonDialog = deps.ButtonDialog
    local Menu = deps.Menu
    local ffiutil = deps.ffiutil
    local strbuf  = deps.strbuf
    local util = require("booklore_util")

    local module = {}

    local DEFAULT_LIMIT = 10
    local DEFAULT_DELAY_S = 3

    -- Read a value from book or from book.metadata (Booklore nests most
    -- descriptive fields under `metadata`).
    local function meta(book, ...)
        local md = type(book.metadata) == "table" and book.metadata or nil
        for i = 1, select("#", ...) do
            local key = select(i, ...)
            if book[key] ~= nil and book[key] ~= "" then
                return book[key]
            end
            if md and md[key] ~= nil and md[key] ~= "" then
                return md[key]
            end
        end
        return nil
    end

    local function joinAuthors(value)
        if type(value) == "table" then
            local list = {}
            for _, a in ipairs(value) do
                if type(a) == "string" and a ~= "" then
                    table.insert(list, a)
                elseif type(a) == "table" and a.name and a.name ~= "" then
                    table.insert(list, a.name)
                end
            end
            return table.concat(list, ", ")
        end
        if type(value) == "string" then
            return value
        end
        return ""
    end

    local function getTitle(book)
        return meta(book, "title") or _("Untitled")
    end

    local function getAuthors(book)
        return joinAuthors(meta(book, "authors", "author"))
    end

    local function sortRecommendations(results)
        table.sort(results, function(a, b)
            local a_score = tonumber(a and a.matchScore)
            local b_score = tonumber(b and b.matchScore)

            if a_score and b_score and a_score ~= b_score then
                return a_score > b_score
            end
            if a_score and not b_score then
                return true
            end
            if b_score and not a_score then
                return false
            end

            local a_title = getTitle(a):lower()
            local b_title = getTitle(b):lower()
            if a_title ~= b_title then
                return a_title < b_title
            end

            return tostring(a and a.id or "") < tostring(b and b.id or "")
        end)
    end

    -- Build a short one-line label for the recommendations list.
    local function buildListLabel(book)
        local title = getTitle(book)
        local subtitle = meta(book, "subtitle")
        if subtitle and subtitle ~= "" then
            title = title .. ": " .. subtitle
        end
        if book.matchScore then
            title = title .. string.format(" (%.0f%%)", tonumber(book.matchScore) * 100)
        end
        local author = getAuthors(book)
        if author ~= "" then
            return title .. "\n" .. author
        end
        return title
    end

    -- Format the descriptive details body shown in the per-book dialog.
    local function buildDetailsText(book)
        local parts = {}
        table.insert(parts, getTitle(book))

        local subtitle = meta(book, "subtitle")
        if subtitle and subtitle ~= "" then
            table.insert(parts, subtitle)
        end

        local author = getAuthors(book)
        if author ~= "" then
            table.insert(parts, T(_("by %1"), author))
        end

        local series = meta(book, "seriesName", "series")
        if series and series ~= "" then
            local series_text = tostring(series)
            local series_num = meta(book, "seriesNumber", "series_number")
            if series_num and series_num ~= "" then
                series_text = series_text .. " #" .. tostring(series_num)
            end
            table.insert(parts, T(_("Series: %1"), series_text))
        end

        local publisher = meta(book, "publisher")
        if publisher and publisher ~= "" then
            table.insert(parts, T(_("Publisher: %1"), publisher))
        end

        local published = meta(book, "publishedDate", "published_date")
        if published and published ~= "" then
            table.insert(parts, T(_("Published: %1"), tostring(published)))
        end

        -- pagecount has been promoted from metadata.pageCount by _normalizeBookObject.
        local pagecount = book.pagecount or meta(book, "pageCount", "pagecount")
        if pagecount then
            table.insert(parts, T(_("Pages: %1"), tostring(pagecount)))
        end

        local language = meta(book, "language")
        if language and language ~= "" then
            table.insert(parts, T(_("Language: %1"), language))
        end

        local isbn13 = meta(book, "isbn13")
        local isbn10 = meta(book, "isbn10")
        if isbn13 and isbn13 ~= "" then
            table.insert(parts, T(_("ISBN-13: %1"), isbn13))
        elseif isbn10 and isbn10 ~= "" then
            table.insert(parts, T(_("ISBN-10: %1"), isbn10))
        end

        local desc = meta(book, "description")
        if desc and desc ~= "" then
            -- Strip basic HTML tags and collapse whitespace for readability.
            desc = tostring(desc):gsub("<[^>]+>", ""):gsub("%s+", " "):gsub("^%s+", ""):gsub("%s+$", "")
            if #desc > 800 then
                desc = desc:sub(1, 800) .. "…"
            end
            table.insert(parts, "")
            table.insert(parts, desc)
        end

        return table.concat(parts, "\n")
    end

    -- Public: schedule a non-blocking fetch + display after the book closes.
    -- Called from main.lua's onCloseDocument when conditions match.
    function module.scheduleAfterFinish(self, book_id, delay_seconds)
        if not book_id then return false end
        if not self.show_post_rating_recommendations then
            self:logInfo("BookloreSync: Recommendations not scheduled — post-finish recommendations toggle is disabled")
            return false
        end

        local delay = tonumber(delay_seconds) or DEFAULT_DELAY_S
        if delay < 0 then delay = 0 end

        -- Guard against duplicate scheduling for the same book in a session.
        self._last_recommendations_book_id = self._last_recommendations_book_id or {}
        local now = os.time()
        local prev = self._last_recommendations_book_id[book_id]
        if prev and (now - prev) < 30 then
            -- Recently scheduled for this book; don't double-trigger.
            self:logInfo("BookloreSync: Recommendations already scheduled recently for book", book_id)
            return false
        end
        self._last_recommendations_book_id[book_id] = now

        UIManager:scheduleIn(delay, function()
            module.show(self, book_id)
        end)
        self:logInfo("BookloreSync: Recommendations scheduled in", delay, "s for book", book_id)
        return true
    end

    -- Public: fetch & show the recommendations list dialog now.
    --
    -- @param force_show boolean|nil  When true, bypasses the
    --        show_post_rating_recommendations toggle. Used by manual
    --        entry points (e.g. file manager long-press action).
    function module.show(self, book_id, force_show)
        if not book_id then return end
        if not force_show and not self.show_post_rating_recommendations then
            self:logInfo("BookloreSync: Recommendations skipped - post-finish toggle disabled")
            return
        end

        if not self.booklore_username or self.booklore_username == ""
        or not self.booklore_password or self.booklore_password == "" then
            self:logInfo("BookloreSync: Recommendations skipped - no Booklore credentials")
            return
        end

        if not self:isNetworkConnected() then
            self:logInfo("BookloreSync: Recommendations skipped - offline")
            return
        end

        self:refreshEffectiveServerUrl()
        self.api:init(self.server_url, self.username, self.password, self.db)

        local loading = InfoMessage:new{ text = _("Loading recommendations…"), timeout = 1 }
        UIManager:show(loading)

        local ok, results = self.api:getBookRecommendations(
            book_id, self.booklore_username, self.booklore_password, DEFAULT_LIMIT
        )
        UIManager:close(loading)

        if not ok then
            local err = (type(results) == "string" and results) or _("Unknown error")
            self:logWarn("BookloreSync: Recommendations fetch failed:", err)
            UIManager:show(InfoMessage:new{
                text = T(_("Could not load recommendations: %1"), tostring(err)),
                timeout = 3,
            })
            return
        end

        if not results or #results == 0 then
            UIManager:show(InfoMessage:new{
                text = _("No recommendations available for this book"),
                timeout = 2,
            })
            return
        end

        sortRecommendations(results)

        module.showListDialog(self, book_id, results)
    end

    -- Show the list of recommendations as a Menu (scrollable).
    function module.showListDialog(self, source_book_id, results)
        local item_table = {}
        for _, book in ipairs(results) do
            table.insert(item_table, {
                text = buildListLabel(book),
                book = book,
            })
        end

        local list_menu
        list_menu = Menu:new{
            title = _("Recommendations"),
            item_table = item_table,
            single_line = false,
            multilines_show_more_text = true,
            fullscreen = true,
            onMenuSelect = function(menu_widget, item)
                UIManager:close(list_menu)
                module.showDetailsDialog(self, source_book_id, results, item.book)
            end,
        }
        UIManager:show(list_menu)
        self._recommendations_list_dialog = list_menu
    end

    -- Show details for a single recommendation with action buttons.
    function module.showDetailsDialog(self, source_book_id, results, book)
        local body = buildDetailsText(book)

        local details_dialog
        details_dialog = ButtonDialog:new{
            title = body,
            buttons = {
                {
                    {
                        text = _("Return to recommendations"),
                        callback = function()
                            UIManager:close(details_dialog)
                            module.showListDialog(self, source_book_id, results)
                        end,
                    },
                },
                {
                    {
                        text = _("Close"),
                        callback = function()
                            UIManager:close(details_dialog)
                        end,
                    },
                    {
                        text = _("Fetch"),
                        callback = function()
                            UIManager:close(details_dialog)
                            module.fetchBook(self, source_book_id, results, book)
                        end,
                    },
                },
            },
        }
        UIManager:show(details_dialog)
    end

    -- Download a recommended book in a subprocess so the UI thread stays
    -- responsive on e-ink, with cancel support.
    function module.fetchBook(self, source_book_id, results, book)
        if not book or not book.id then
            UIManager:show(InfoMessage:new{
                text = _("Recommendation has no book ID — cannot fetch"),
                timeout = 2,
            })
            return
        end

        if not self:isNetworkConnected() then
            UIManager:show(InfoMessage:new{
                text = _("WiFi not enabled — cannot download"),
                timeout = 2,
            })
            return
        end

        local lfs = require("libs/libkoreader-lfs")

        -- Ensure download dir exists.
        local download_dir = self.download_dir
        if not download_dir or download_dir == "" then
            UIManager:show(InfoMessage:new{
                text = _("Download directory not configured"),
                timeout = 2,
            })
            return
        end
        if lfs.attributes(download_dir, "mode") ~= "directory" then
            local ok_mkdir = lfs.mkdir(download_dir)
            if not ok_mkdir then
                UIManager:show(InfoMessage:new{
                    text = T(_("Cannot create download directory: %1"), download_dir),
                    timeout = 3,
                })
                return
            end
        end

        -- Resolve extension and original filename from primaryFile (per
        -- OpenAPI); fall back to top-level fields, then to "epub".
        local pf = type(book.primaryFile) == "table" and book.primaryFile or {}
        if not book.extension or book.extension == "" then
            book.extension = (pf.extension and pf.extension ~= "")
                and pf.extension
                or (pf.bookType and pf.bookType:lower())
                or "epub"
        end
        if not book.original_filename or book.original_filename == "" then
            if pf.fileName and pf.fileName ~= "" then
                book.original_filename = pf.fileName
            end
        end

        local filename = self:_generateFilename(book)
        local filepath = util.joinDownloadPath(download_dir, filename)

        -- Check if the book is already cached in the database (downloaded
        -- via a previous shelf sync under a different filename, for example).
        if self.db then
            local cached = self.db:getBookByBookId(tonumber(book.id))
            if cached and cached.file_path then
                local cached_mode = lfs.attributes(cached.file_path, "mode")
                if cached_mode == "file" then
                    local exists_here = lfs.attributes(filepath, "mode") == "file"
                    if not exists_here then
                        self:logInfo("BookloreSync: Recommendation already in cache at:", cached.file_path)
                        module.promptOpen(self, cached.file_path, book)
                        return
                    end
                end
            end
        end

        -- If the file already exists at the computed path, skip the download
        -- and go straight to the open prompt.
        if lfs.attributes(filepath, "mode") == "file" then
            self:logInfo("BookloreSync: Recommendation already on disk:", filepath)
            module.persistMetadata(self, filepath, book)
            module.promptOpen(self, filepath, book)
            return
        end

        self:refreshEffectiveServerUrl()

        -- Capture plain-value closures for the subprocess fork.
        local cap_book_id   = tonumber(book.id)
        local cap_filepath  = filepath
        local cap_username  = self.booklore_username
        local cap_password  = self.booklore_password
        local cap_server    = self.server_url
        local cap_db_name   = self.db and self.db.db_path:match("([^/]+)$") or "booklore-sync.sqlite"

        -- Show a progress dialog with a Cancel button.
        local cancelled = false
        local progress_dialog
        progress_dialog = ButtonDialog:new{
            dismissable = false,
            title = T(_("Downloading recommendation…\n\n%1"), book.title or tostring(book.id)),
            buttons = {{ {
                text = _("Cancel"),
                callback = function()
                    cancelled = true
                    pcall(UIManager.close, UIManager, progress_dialog)
                    progress_dialog = nil
                end,
            } }},
        }
        UIManager:show(progress_dialog)

        -- Launch the subprocess: it creates its own DB/API instances and
        -- downloads the book, then writes the result (ok, err) via FD.
        local pid, read_fd = ffiutil.runInSubProcess(function(_, write_fd)
            local ChildDB  = require("booklore_database")
            local ChildAPI = require("booklore_api_client")
            local child_logger = {
                logInfo = function() end, logWarn = function() end,
                logErr  = function() end, logDbg  = function() end,
            }
            local child_db = ChildDB:new(child_logger)
            child_db:init(cap_db_name)
            local child_api = ChildAPI:new(child_logger)
            child_api:init(cap_server, cap_username, cap_password, child_db)
            local ok, err = child_api:downloadBook(cap_book_id, cap_filepath, cap_username, cap_password)
            child_db:close()
            local results = strbuf.encode({ ok = ok, err = err })
            ffiutil.writeToFD(write_fd, results, true)
        end, true)

        if not pid then
            -- Fork failed — clean up the progress dialog and report the error.
            if progress_dialog then
                UIManager:close(progress_dialog)
                progress_dialog = nil
            end
            self:logErr("BookloreSync: Failed to fork download subprocess for recommendation")
            UIManager:show(InfoMessage:new{
                text = _("Could not start the download process"),
                timeout = 3,
            })
            return
        end

        -- Poll subprocess completion.  Between polls the event loop runs so
        -- e-ink rendering (button presses, Cancel callback) stays alive.
        local function pollSubprocess()
            if cancelled then
                -- User cancelled — check if the subprocess is done yet.
                if not ffiutil.isSubProcessDone(pid) then
                    -- Poll again; the dialog is already closed.
                    UIManager:scheduleIn(0.3, pollSubprocess)
                    return
                end
                -- Subprocess finished after cancel — discard the result.
                ffiutil.readAllFromFD(read_fd)
                os.remove(cap_filepath)
                self:logInfo("BookloreSync: Recommendation download cancelled for", cap_book_id)
                return
            end

            if not ffiutil.isSubProcessDone(pid) then
                -- Still downloading — poll again.
                UIManager:scheduleIn(0.3, pollSubprocess)
                return
            end

            -- Subprocess finished — read result.
            if progress_dialog then
                UIManager:close(progress_dialog)
                progress_dialog = nil
            end

            local result_str = ffiutil.readAllFromFD(read_fd)
            local ok_dec, decoded = pcall(strbuf.decode, result_str)
            local dl_ok = false
            local dl_err = nil
            if ok_dec and type(decoded) == "table" then
                dl_ok = decoded.ok
                dl_err = decoded.err
            end

            if not dl_ok then
                self:logWarn("BookloreSync: Recommendation download failed:", tostring(dl_err))
                UIManager:show(ConfirmBox:new{
                    text = T(_("Download failed: %1\n\nReturn to recommendations?"), tostring(dl_err or _("Unknown error"))),
                    ok_text = _("Yes"),
                    cancel_text = _("Close"),
                    ok_callback = function()
                        module.showListDialog(self, source_book_id, results)
                    end,
                })
                return
            end

            module.persistMetadata(self, filepath, book)
            module.promptOpen(self, filepath, book)
        end

        -- Start polling after a short delay so the progress dialog renders
        -- before the first poll fires.
        UIManager:scheduleIn(0.3, pollSubprocess)
    end

    -- Compute the file hash and persist book_cache + metadata for the new file.
    function module.persistMetadata(self, filepath, book)
        if not self.db then return end

        local hash = ""
        local ok_hash, computed = pcall(function()
            return self:calculateBookHash(filepath)
        end)
        if ok_hash and type(computed) == "string" then
            hash = computed
        end

        local md = type(book.metadata) == "table" and book.metadata or {}
        local isbn10 = book.isbn10 or md.isbn10 or nil
        local isbn13 = book.isbn13 or md.isbn13 or nil
        local hardcover_id = tonumber(book.hardcover_id)
            or tonumber(book.hardcoverId)
            or tonumber(md.hardcoverBookId)
            or tonumber(md.hardcoverId)
            or tonumber(md.hardcover_id)
        local pagecount = tonumber(book.pagecount)
            or tonumber(md.pageCount) or tonumber(md.pagecount)

        local author = joinAuthors(book.authors or book.author or md.authors)
        if author == "" then author = nil end
        local title = book.title or md.title

        local saved = self.db:saveBookCache(
            filepath, hash, tonumber(book.id),
            title, author, isbn10, isbn13, pagecount
        )
        if not saved then
            self:logWarn("BookloreSync: Failed to save book_cache for downloaded recommendation:", filepath)
        else
            self:logInfo("BookloreSync: Saved recommendation metadata for", filepath, "book_id:", book.id)
            if hardcover_id and hardcover_id > 0 then
                self.db:updateHardcoverId(hash, hardcover_id)
            end
        end

        -- Refresh the file manager so the new book appears immediately.
        local ok_fm, FM = pcall(require, "apps/filemanager/filemanager")
        if ok_fm and FM and FM.instance and FM.instance.reinit then
            pcall(function() FM.instance:reinit(self.download_dir) end)
        end
    end

    -- Ask the user whether to start reading the freshly downloaded book.
    function module.promptOpen(self, filepath, book)
        local title = (book and getTitle(book)) or filepath:match("([^/]+)$") or filepath
        if title == _("Untitled") then
            title = filepath:match("([^/]+)$") or filepath
        end
        UIManager:show(ConfirmBox:new{
            text = T(_("\"%1\" downloaded.\n\nOpen it now?"), title),
            ok_text = _("Yes"),
            cancel_text = _("No"),
            ok_callback = function()
                local ok_ru, ReaderUI = pcall(require, "apps/reader/readerui")
                if not ok_ru or not ReaderUI then
                    UIManager:show(InfoMessage:new{
                        text = _("Could not open ReaderUI"),
                        timeout = 2,
                    })
                    return
                end
                local ok_show, err = pcall(function()
                    ReaderUI:showReader(filepath)
                end)
                if not ok_show then
                    self:logWarn("BookloreSync: ReaderUI:showReader failed:", tostring(err))
                    UIManager:show(InfoMessage:new{
                        text = T(_("Could not open book: %1"), tostring(err)),
                        timeout = 3,
                    })
                end
            end,
        })
    end

    return module
end

return M
