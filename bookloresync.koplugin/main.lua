--[[--
Booklore KOReader Plugin

Syncs reading sessions to Booklore server via REST API.

@module koplugin.BookloreSync
--]]--

local DataStorage = require("datastorage")
local Dispatcher = require("dispatcher")
local EventListener = require("ui/widget/eventlistener")
local InfoMessage = require("ui/widget/infomessage")
local InputDialog = require("ui/widget/inputdialog")
local LuaSettings = require("luasettings")
local NetworkMgr = require("ui/network/manager")
local UIManager = require("ui/uimanager")
local WidgetContainer = require("ui/widget/container/widgetcontainer")
local ConfirmBox = require("ui/widget/confirmbox")
local ButtonDialog = require("ui/widget/buttondialog")
local json = require("json")
local Settings = require("booklore_settings")
local Database = require("booklore_database")
local APIClient = require("booklore_api_client")
local Updater = require("booklore_updater")
local FileLogger = require("booklore_file_logger")
local MetadataExtractor = require("booklore_metadata_extractor")
local logger = require("logger")

local _ = require("gettext")
local T = require("ffi/util").template

local BookloreSync = WidgetContainer:extend{
    name = "booklore",
    is_doc_only = false,
}

--[[--
Redact URLs from log message for secure logging

@param message The log message that may contain URLs
@return string Message with URLs redacted
--]]
local function redactUrls(message)
    if type(message) ~= "string" then
        message = tostring(message)
    end
    -- Match http:// or https:// URLs and replace them with [URL REDACTED]
    return message:gsub("https?://[^%s]+", "[URL REDACTED]")
end

-- Secure logger wrappers
function BookloreSync:logInfo(...)
    local args = {...}
    if self.secure_logs then
        for i = 1, #args do
            args[i] = redactUrls(args[i])
        end
    end
    logger.info(table.unpack(args))
    
    if self.log_to_file and self.file_logger then
        self.file_logger:write("INFO", table.unpack(args))
    end
end

function BookloreSync:logWarn(...)
    local args = {...}
    if self.secure_logs then
        for i = 1, #args do
            args[i] = redactUrls(args[i])
        end
    end
    logger.warn(table.unpack(args))
    if self.log_to_file and self.file_logger then
        self.file_logger:write("WARN", table.unpack(args))
    end
end

function BookloreSync:logErr(...)
    local args = {...}
    if self.secure_logs then
        for i = 1, #args do
            args[i] = redactUrls(args[i])
        end
    end
    logger.err(table.unpack(args))
    if self.log_to_file and self.file_logger then
        self.file_logger:write("ERROR", table.unpack(args))
    end
end

function BookloreSync:logDbg(...)
    local args = {...}
    if self.secure_logs then
        for i = 1, #args do
            args[i] = redactUrls(args[i])
        end
    end
    logger.dbg(table.unpack(args))
    if self.log_to_file and self.file_logger then
        self.file_logger:write("DEBUG", table.unpack(args))
    end
end

local BATCH_UPLOAD_SIZE = 100  -- max sessions per batch upload

--[[--
DbSettings — a LuaSettings-compatible wrapper backed by the plugin_settings
SQLite table.

All existing call sites (readSetting / saveSetting / flush) work without any
changes.  Writes are committed immediately to SQLite; flush() is a no-op.

@param db  Database  An initialised Database instance
--]]
local DbSettings = {}
DbSettings.__index = DbSettings

function DbSettings:new(db)
    local o = { _db = db }
    setmetatable(o, self)
    return o
end

function DbSettings:readSetting(key)
    return self._db:getPluginSetting(key)
end

function DbSettings:saveSetting(key, value)
    self._db:savePluginSetting(key, value)
end

-- No-op: SQLite writes are atomic and immediate, no flush needed.
function DbSettings:flush()
end

function BookloreSync:init()
    -- Bootstrap phase: open the legacy LuaSettings file so that settings needed
    -- before the database is ready (log_to_file, secure_logs) can be read.
    -- Once the database has been initialised and migration 10 has run, self.settings
    -- is replaced with a DbSettings wrapper so all subsequent reads and writes go
    -- directly to SQLite.  The LuaSettings file is deleted by the migration hook.
    local bootstrap_settings = LuaSettings:open(DataStorage:getSettingsDir() .. "/booklore.lua")
    self.settings = bootstrap_settings

    -- Read the two settings required before the DB is ready
    self.log_to_file  = self.settings:readSetting("log_to_file")  or false
    self.secure_logs  = self.settings:readSetting("secure_logs")  or false

    -- Initialize file logger if enabled (needs log_to_file / secure_logs)
    if self.log_to_file then
        self.file_logger = FileLogger:new()
        local logger_ok = self.file_logger:init()
        if logger_ok then
            self:logInfo("BookloreSync: File logging initialized")
        else
            self:logErr("BookloreSync: Failed to initialize file logger")
            self.file_logger = nil
        end
    end

    -- Initialize SQLite database (runs migrations, including migration 10 which
    -- copies booklore.lua → plugin_settings and deletes the source file)
    self.db = Database:new()
    local db_initialized = self.db:init()

    if not db_initialized then
        self:logErr("BookloreSync: Failed to initialize database")
        UIManager:show(InfoMessage:new{
            text = _("Failed to initialize Booklore database"),
            timeout = 3,
        })
        -- Fall back to the bootstrap LuaSettings so the plugin remains functional
    else
        -- Switch to the DB-backed settings wrapper.  All further readSetting /
        -- saveSetting / flush calls go through SQLite without any call-site changes.
        self.settings = DbSettings:new(self.db)

        -- Check if we need to migrate from old LuaSettings format
        local old_db_path = DataStorage:getSettingsDir() .. "/booklore_db.lua"
        local old_db_file = io.open(old_db_path, "r")

        if old_db_file then
            old_db_file:close()
            self:logInfo("BookloreSync: Found old database, checking if migration needed")

            -- Check if database is empty (needs migration)
            local stats = self.db:getBookCacheStats()
            if stats.total == 0 then
                self:logInfo("BookloreSync: Database is empty, migrating from LuaSettings")

                local ok, err = pcall(function()
                    local local_db = LuaSettings:open(old_db_path)
                    local success = self.db:migrateFromLuaSettings(local_db)

                    if success then
                        UIManager:show(InfoMessage:new{
                            text = _("Migrated data to new database format"),
                            timeout = 2,
                        })
                    else
                        UIManager:show(InfoMessage:new{
                            text = _("Migration completed with some errors. Check logs."),
                            timeout = 3,
                        })
                    end
                end)

                if not ok then
                    self:logErr("BookloreSync: Migration failed:", err)
                    UIManager:show(InfoMessage:new{
                        text = _("Failed to migrate old data. Check logs."),
                        timeout = 3,
                    })
                end
            end
        end
    end

    self.server_url = self.settings:readSetting("server_url") or ""
    self.username   = self.settings:readSetting("username")   or ""
    self.password   = self.settings:readSetting("password")   or ""

    self.is_enabled      = self.settings:readSetting("is_enabled")      or false
    self.log_to_file     = self.settings:readSetting("log_to_file")     or false
    self.silent_messages = self.settings:readSetting("silent_messages") or false
    self.secure_logs     = self.settings:readSetting("secure_logs")     or false

    self.min_duration             = self.settings:readSetting("min_duration")             or 30
    self.min_pages                = self.settings:readSetting("min_pages")                or 5
    self.session_detection_mode   = self.settings:readSetting("session_detection_mode")   or "duration" -- "duration" or "pages"
    self.progress_decimal_places  = self.settings:readSetting("progress_decimal_places")  or 2

    self.force_push_session_on_suspend = self.settings:readSetting("force_push_session_on_suspend") or false
    self.connect_network_on_suspend    = self.settings:readSetting("connect_network_on_suspend")    or false
    self.manual_sync_only              = self.settings:readSetting("manual_sync_only")              or false
    self.sync_mode                     = self.settings:readSetting("sync_mode") -- "automatic", "manual", or "custom"

    -- Migrate old settings to new preset system if needed
    if not self.sync_mode then
        if self.manual_sync_only then
            self.sync_mode = "manual"
        elseif self.force_push_session_on_suspend and self.connect_network_on_suspend then
            self.sync_mode = "automatic"
        else
            self.sync_mode = "custom"
        end
        self.settings:saveSetting("sync_mode", self.sync_mode)
    end

    self.historical_sync_ack = self.settings:readSetting("historical_sync_ack") or false

    self.booklore_username = self.settings:readSetting("booklore_username") or ""
    self.booklore_password = self.settings:readSetting("booklore_password") or ""

    self.extended_sync_enabled         = self.settings:readSetting("extended_sync_enabled")         or false
    self.rating_sync_enabled           = self.settings:readSetting("rating_sync_enabled")           or false
    self.rating_sync_mode              = self.settings:readSetting("rating_sync_mode")              or "koreader_scaled"
    self.highlights_notes_sync_enabled = self.settings:readSetting("highlights_notes_sync_enabled") or false
    self.notes_destination             = self.settings:readSetting("notes_destination")             or "in_book"
    self.upload_strategy               = self.settings:readSetting("upload_strategy")               or "on_session"

    self.current_session = nil
    
    if self.db then
        self.db:cleanupExpiredTokens()
    end
    
    self.api = APIClient:new()
    self.api:init(self.server_url, self.username, self.password, self.db, self.secure_logs)
    
    self.metadata_extractor = MetadataExtractor:new({secure_logs = self.secure_logs})
    self:logInfo("BookloreSync: Metadata extractor initialized")
    
    self.updater = Updater:new()
    
    local source = debug.getinfo(1, "S").source
    local plugin_dir = source:match("@(.*)/")
    if not plugin_dir or not plugin_dir:match("bookloresync%.koplugin$") then
        -- Fallback: use data directory
        plugin_dir = DataStorage:getDataDir() .. "/bookloresync.koplugin"
    end
    
    self.updater:init(plugin_dir, self.db)
    
    self.auto_update_check = self.settings:readSetting("auto_update_check")
    if self.auto_update_check == nil then
        self.auto_update_check = true  -- Default enabled
    end
    
    self.last_update_check = self.settings:readSetting("last_update_check") or 0
    self.update_available = false
    
    if self.auto_update_check then
        UIManager:scheduleIn(5, function()
            self:autoCheckForUpdates()
        end)
    end
    
    self.ui.menu:registerToMainMenu(self)
    
    self:registerDispatcherActions()
end

function BookloreSync:onExit()
    if self.db then
        self.db:close()
    end
    
    if self.file_logger then
        self.file_logger:close()
    end
end

function BookloreSync:registerDispatcherActions()
    Dispatcher:registerAction("booklore_toggle_sync", {
        category = "none",
        event = "ToggleBookloreSync",
        title = _("Toggle Booklore Sync"),
        general = true,
    })
    
    Dispatcher:registerAction("booklore_sync_pending", {
        category = "none",
        event = "SyncBooklorePending",
        title = _("Sync Booklore Pending Sessions"),
        general = true,
    })

    -- Register Manual Sync Only toggle action
    Dispatcher:registerAction("booklore_toggle_manual_sync_only", {
        category = "none",
        event = "ToggleBookloreManualSyncOnly",
        title = _("Toggle Booklore Manual Sync Only"),
        general = true,
    })
    
    Dispatcher:registerAction("booklore_test_connection", {
        category = "none",
        event = "TestBookloreConnection",
        title = _("Test Booklore Connection"),
        general = true,
    })
end

function BookloreSync:onToggleBookloreSync()
    self:toggleSync()
    return true
end

function BookloreSync:onSyncBooklorePending()
    local pending_count = self.db and self.db:getPendingSessionCount() or 0
    if pending_count > 0 and self.is_enabled then
        self:syncPendingSessions()
    else
        if pending_count == 0 then
            UIManager:show(InfoMessage:new{
                text = _("No pending sessions to sync"),
                timeout = 1,
            })
        end
    end
    return true
end

function BookloreSync:onTestBookloreConnection()
    self:testConnection()
    return true
end

function BookloreSync:onToggleBookloreManualSyncOnly()
    self:toggleManualSyncOnly()
    return true
end

function BookloreSync:toggleSync()
    self.is_enabled = not self.is_enabled
    self.settings:saveSetting("is_enabled", self.is_enabled)
    self.settings:flush()
    UIManager:show(InfoMessage:new{
        text = self.is_enabled and _("Booklore sync enabled") or _("Booklore sync disabled"),
        timeout = 1,
    })
end

function BookloreSync:toggleManualSyncOnly()
    self.manual_sync_only = not self.manual_sync_only
    self.settings:saveSetting("manual_sync_only", self.manual_sync_only)
    
    if self.manual_sync_only and self.force_push_session_on_suspend then
        self.force_push_session_on_suspend = false
        self.settings:saveSetting("force_push_session_on_suspend", false)
    end
    
    self.settings:flush()
    local message
    if self.manual_sync_only then
        message = _("Manual sync only: sessions will be cached until you sync pending sessions manually")
    else
        message = _("Manual sync only disabled: automatic syncing restored where enabled")
    end
    UIManager:show(InfoMessage:new{
        text = message,
        timeout = 2,
    })
end

function BookloreSync:setSyncMode(mode)
    self.sync_mode = mode
    self.settings:saveSetting("sync_mode", mode)
    
    -- Apply preset values
    if mode == "automatic" then
        self.manual_sync_only = false
        self.force_push_session_on_suspend = true
        self.connect_network_on_suspend = true
    elseif mode == "manual" then
        self.manual_sync_only = true
        self.force_push_session_on_suspend = false
        self.connect_network_on_suspend = false
    end
    -- custom mode: leave individual settings as-is
    
    if mode ~= "custom" then
        self.settings:saveSetting("manual_sync_only", self.manual_sync_only)
        self.settings:saveSetting("force_push_session_on_suspend", self.force_push_session_on_suspend)
        self.settings:saveSetting("connect_network_on_suspend", self.connect_network_on_suspend)
    end
    
    self.settings:flush()
end

function BookloreSync:viewSessionDetails()
    if not self.db then
        UIManager:show(InfoMessage:new{
            text = _("Database not initialized"),
            timeout = 2,
        })
        return
    end

    local stats       = self.db:getBookCacheStats()
    local sessions    = tonumber(self.db:getPendingSessionCount())    or 0
    local annotations = tonumber(self.db:getPendingAnnotationCount()) or 0
    local ratings     = tonumber(self.db:getPendingRatingCount())     or 0

    local total     = tonumber(stats.total)     or 0
    local matched   = tonumber(stats.matched)   or 0
    local unmatched = tonumber(stats.unmatched) or 0

    UIManager:show(InfoMessage:new{
        text = T(_(
            "Book cache\n" ..
            "  Total: %1  Matched: %2  Unmatched: %3\n" ..
            "\n" ..
            "Pending uploads\n" ..
            "  Sessions: %4\n" ..
            "  Annotations: %5\n" ..
            "  Ratings: %6"
        ), total, matched, unmatched, sessions, annotations, ratings),
    })
end

--[[--
Detect and store the KOReader sidecar (.sdr) path for the currently open book.

Looks up or creates a book_cache entry, then upserts the sdr_path into book_metadata.
Called silently from onReaderReady whenever a book is opened.
--]]
function BookloreSync:detectBookMetadataLocation()
    if not self.ui or not self.ui.document or not self.ui.document.file then
        return
    end

    local doc_path = self.ui.document.file
    self:logInfo("BookloreSync: Detecting metadata location for:", doc_path)

    -- Verify the sidecar is accessible via the metadata extractor
    local doc_settings = self.metadata_extractor:loadDocSettings(doc_path)
    if not doc_settings then
        self:logInfo("BookloreSync: No KOReader sidecar found for:", doc_path)
        return
    end

    -- Derive the .sdr folder path.
    -- DocSettings stores the sidecar in: <doc_dir>/<doc_filename>.sdr/
    local sdr_path = doc_path .. ".sdr"

    -- Ensure a book_cache entry exists for this file path
    local book_cache_id = self.db:getBookCacheIdByFilePath(doc_path)
    if not book_cache_id then
        -- No cache entry yet — create a minimal one using whatever we know
        local file_hash = ""
        if self.current_session and self.current_session.doc_path == doc_path then
            file_hash = self.current_session.file_hash or ""
        end
        local stats = self.metadata_extractor:getStats(doc_path)
        local title  = (stats and stats.title)   or ""
        local author = (stats and stats.authors) or ""
        self.db:saveBookCache(doc_path, file_hash, nil, title, author, nil, nil)
        book_cache_id = self.db:getBookCacheIdByFilePath(doc_path)
    end

    if not book_cache_id then
        self:logErr("BookloreSync: Failed to create book cache entry for metadata location")
        return
    end

    local ok = self.db:upsertBookMetadata(book_cache_id, { sdr_path = sdr_path })
    if ok then
        self:logInfo("BookloreSync: Stored sdr_path:", sdr_path, "for book_cache_id:", book_cache_id)
    else
        self:logErr("BookloreSync: Failed to store sdr_path for book_cache_id:", book_cache_id)
    end
end

--[[--
Sync the KOReader star rating (1-5) to Booklore, scaled to 1-10 by multiplying by 2.

Called silently at the end of a session when rating_sync_mode == "koreader_scaled".

@param doc_path      string       Full path to the document
@param book_id       number       Booklore book ID
@param live_rating   number|nil   Pre-read in-memory rating (1-5).  When provided,
                                  this value is used directly and the on-disk sidecar
                                  is NOT read.  Pass this when calling from
                                  onCloseDocument, where the sidecar has not yet been
                                  flushed by KOReader.
--]]
function BookloreSync:syncKOReaderRating(doc_path, book_id, live_rating)
    if not doc_path or not book_id then
        self:logWarn("BookloreSync: syncKOReaderRating called with missing arguments")
        return
    end
    if self.booklore_username == "" or self.booklore_password == "" then
        self:logWarn("BookloreSync: Rating sync skipped — Booklore credentials not configured")
        return
    end

    -- Check whether this book's rating has already been synced
    local book_cache_id = self.db:getBookCacheIdByFilePath(doc_path)
    if book_cache_id then
        local meta = self.db:getBookMetadata(book_cache_id)
        if meta and meta.rating_synced then
            self:logInfo("BookloreSync: Rating already synced for book_cache_id:", book_cache_id, "— skipping")
            return
        end
    end

    -- Use the pre-read live rating when available (avoids the stale-sidecar timing
    -- issue at onCloseDocument time).  Fall back to the on-disk read for all other
    -- call sites (e.g. syncPendingRatings deferred path, where the sidecar is fine).
    local rating_1_5
    if live_rating ~= nil then
        rating_1_5 = tonumber(live_rating)
        self:logInfo("BookloreSync: Using live in-memory rating:", rating_1_5)
    else
        rating_1_5 = self.metadata_extractor:getRating(doc_path)
    end

    if not rating_1_5 then
        self:logInfo("BookloreSync: No KOReader rating set for this book — skipping rating sync")
        return
    end

    local rating_scaled = math.floor(rating_1_5) * 2  -- 1-5 → 2,4,6,8,10
    -- Clamp to valid range just in case
    rating_scaled = math.max(1, math.min(10, rating_scaled))

    self:logInfo("BookloreSync: Syncing KOReader rating", rating_1_5, "-> scaled:", rating_scaled, "for book_id:", book_id)

    local ok, err = self.api:submitRating(book_id, rating_scaled, self.booklore_username, self.booklore_password)

    if ok then
        -- Persist rating + mark synced
        if not book_cache_id then
            book_cache_id = self.db:getBookCacheIdByFilePath(doc_path)
        end
        if book_cache_id then
            self.db:upsertBookMetadata(book_cache_id, { rating = rating_scaled, rating_synced = true })
            self.db:recordRatingSyncHistory(book_cache_id, rating_scaled, "success")
        end
        self:logInfo("BookloreSync: Rating synced successfully")
    else
        self:logWarn("BookloreSync: Failed to sync rating:", err)
        -- Ensure we have a book_cache_id to queue against
        if not book_cache_id then
            book_cache_id = self.db:getBookCacheIdByFilePath(doc_path)
        end
        if book_cache_id then
            -- Store rating value and clear synced flag so it shows as pending
            self.db:upsertBookMetadata(book_cache_id, { rating = rating_scaled, rating_synced = false })
            -- Add to the pending_ratings queue for retry on the next upload
            self.db:addPendingRating(book_cache_id, book_id, rating_scaled)
            self.db:recordRatingSyncHistory(book_cache_id, rating_scaled, "error", err)
            self:logInfo("BookloreSync: Rating queued for retry (book_cache_id:", book_cache_id, ")")
        end
    end
end

--[[--
Show a non-blocking 1-10 rating dialog after a book is completed.

Called after endSession() when rating_sync_mode == "select_at_complete" and
progress reached >= 99%.

@param doc_path  string  Full path to the document
@param book_id   number  Booklore book ID
--]]
function BookloreSync:showRatingDialog(doc_path, book_id)
    if not doc_path then
        self:logWarn("BookloreSync: showRatingDialog called without doc_path")
        return
    end
    -- book_id may be nil when the server was offline at book-close time.
    -- In that case we still show the dialog so the user can record their rating
    -- now; the value is stored locally and the pending_rating_prompt flag
    -- (set by the caller) ensures the upload happens on the next sync once
    -- the book_id has been resolved.

    -- Don't show dialog if already rated and synced
    local book_cache_id = self.db:getBookCacheIdByFilePath(doc_path)
    if book_cache_id then
        local meta = self.db:getBookMetadata(book_cache_id)
        if meta and meta.rating_synced then
            self:logInfo("BookloreSync: Rating already synced — skipping dialog")
            return
        end
    end

    local rating_dialog
    rating_dialog = InputDialog:new{
        title = _("Rate this book (1-10)"),
        input = "",
        input_hint = "1-10",
        input_type = "number",
        buttons = {
            {
                {
                    text = _("Cancel"),
                    callback = function()
                        UIManager:close(rating_dialog)
                    end,
                },
                {
                    text = _("Submit"),
                    is_enter_default = true,
                    callback = function()
                        local value = tonumber(rating_dialog:getInputText())
                        if not value or value < 1 or value > 10 or value ~= math.floor(value) then
                            UIManager:show(InfoMessage:new{
                                text = _("Please enter a whole number between 1 and 10"),
                                timeout = 2,
                            })
                            return
                        end

                        UIManager:close(rating_dialog)

                        -- Store in DB
                        local bcid = self.db:getBookCacheIdByFilePath(doc_path)
                        if not bcid then
                            -- Create minimal cache entry if missing
                            self.db:saveBookCache(doc_path, "", nil, nil, nil, nil, nil)
                            bcid = self.db:getBookCacheIdByFilePath(doc_path)
                        end
                        if bcid then
                            self.db:storeRating(bcid, value)
                        end

                        if not book_id then
                            -- book_id not yet known — store rating locally and queue
                            -- it in pending_ratings (with nil book_id) so it is
                            -- uploaded once the book is matched on the next sync.
                            if bcid then
                                self.db:addPendingRating(bcid, nil, value)
                            end
                            UIManager:show(InfoMessage:new{
                                text = T(_("Rating %1/10 saved (will sync once book is matched)"), value),
                                timeout = 2,
                            })
                        -- Attempt to submit immediately if credentials are available
                        elseif self.booklore_username ~= "" and self.booklore_password ~= "" then
                            local ok, err = self.api:submitRating(
                                book_id, value,
                                self.booklore_username, self.booklore_password
                            )
                            if ok then
                                if bcid then
                                    self.db:markRatingSynced(bcid)
                                    self.db:recordRatingSyncHistory(bcid, value, "success")
                                end
                                UIManager:show(InfoMessage:new{
                                    text = T(_("Rating %1/10 saved and synced"), value),
                                    timeout = 2,
                                })
                            else
                                self:logWarn("BookloreSync: Rating submit failed:", err)
                                -- Queue for retry on the next upload trigger
                                if bcid then
                                    self.db:addPendingRating(bcid, book_id, value)
                                    self.db:recordRatingSyncHistory(bcid, value, "error", err)
                                end
                                UIManager:show(InfoMessage:new{
                                    text = T(_("Rating %1/10 saved (will retry on next sync)"), value),
                                    timeout = 2,
                                })
                            end
                        else
                            -- No credentials yet — the rating is stored locally;
                            -- queue it so it is sent once credentials are configured.
                            if bcid then
                                self.db:addPendingRating(bcid, book_id, value)
                            end
                            UIManager:show(InfoMessage:new{
                                text = T(_("Rating %1/10 saved (will retry on next sync)"), value),
                                timeout = 2,
                            })
                        end
                    end,
                },
            },
        },
    }
    UIManager:show(rating_dialog)
    -- Do NOT call rating_dialog:onShowKeyboard() here.
    -- Showing the software keyboard immediately after a document close event
    -- (or during a document transition triggered by "open next book") causes a
    -- Wayland EGL surface assertion crash on Linux desktop and can cause
    -- similar instability on e-ink devices.  The user can tap the input field
    -- to open the keyboard manually; the dialog itself is immediately visible.
end

-- ── Highlights & Notes Sync ────────────────────────────────────────────────

-- Map KOReader color names → Booklore's 5 supported highlight hex colors.
-- Booklore supports: yellow (#FFC107), green (#4ADE80), cyan (#38BDF8),
--                    pink (#F472B6), orange (#FB923C).
-- Unsupported KOReader colors are mapped to the nearest hue:
--   red → orange (warm), purple → pink (violet/magenta), blue → cyan (cool),
--   gray → yellow (neutral fallback), white → yellow (neutral fallback)
local KOREADER_COLOR_MAP = {
    yellow  = "#FFC107",
    green   = "#4ADE80",
    cyan    = "#38BDF8",
    pink    = "#F472B6",
    orange  = "#FB923C",
    red     = "#FB923C",   -- → orange (nearest warm hue)
    purple  = "#F472B6",   -- → pink (nearest violet/magenta hue)
    blue    = "#38BDF8",   -- → cyan (nearest cool hue)
    gray    = "#FFC107",   -- → yellow (neutral fallback)
    white   = "#FFC107",   -- → yellow (neutral fallback)
}

-- Map KOReader drawer names → Booklore style strings
local KOREADER_STYLE_MAP = {
    lighten    = "highlight",
    underscore = "underline",
    strikeout  = "strikethrough",
    invert     = "highlight",     -- closest available
}

--[[--
Convert a KOReader color name to a hex string.
Falls back to yellow (#FFC107) for unknown names.

@param color_name string  KOReader color name (e.g. "yellow")
@return string hex color (e.g. "#FFC107")
--]]
function BookloreSync:colorToHex(color_name)
    if not color_name then return "#FFC107" end
    return KOREADER_COLOR_MAP[color_name:lower()] or "#FFC107"
end

--[[--
Convert a KOReader drawer name to a Booklore style string.
Falls back to "highlight" for unknown names.

@param drawer string  KOReader drawer name (e.g. "lighten")
@return string Booklore style
--]]
function BookloreSync:drawerToStyle(drawer)
    if not drawer then return "highlight" end
    return KOREADER_STYLE_MAP[drawer:lower()] or "highlight"
end

-- ── EPUB CFI conversion ────────────────────────────────────────────────────

-- Void/self-closing HTML elements (never have children)
local HTML_VOID_TAGS = {
    area=true, base=true, br=true, col=true, embed=true, hr=true,
    img=true, input=true, link=true, meta=true, param=true,
    source=true, track=true, wbr=true,
}

--[[--
Count the ordinal position (1-based, among ALL element siblings) of the Nth
occurrence of `element_name` within `html_content`, and return the element's
`id` attribute value if present.

This performs a shallow scan (depth 0 only) of the direct children of the
element whose raw innerHTML is `html_content`.  It correctly skips over
nested markup by tracking nesting depth.

@param html_content string  Raw inner-HTML of a parent element
@param element_name string  Tag name to locate (case-insensitive)
@param nth           number  1-based occurrence index among same-name siblings
@return number|nil  1-based ordinal among ALL direct-child elements, or nil
@return string|nil  value of the `id` attribute on that element, or nil
--]]
local function findNthElementOrdinal(html_content, element_name, nth)
    element_name = element_name:lower()
    local depth    = 0
    local ordinal  = 0   -- total element children seen so far (at depth 0)
    local found    = 0   -- occurrences of element_name seen at depth 0

    local i = 1
    local len = #html_content
    while i <= len do
        -- Find the next tag
        local tag_start, tag_end, full_tag = html_content:find("(<[^>]+>)", i)
        if not tag_start then break end

        local is_closing      = full_tag:sub(1, 2) == "</"
        local is_self_closing = full_tag:sub(-2) == "/>"
        local tag_name = full_tag:match("^</?([%a][%w%-]*)")
        if tag_name then
            tag_name = tag_name:lower()
        end

        if is_closing then
            depth = depth - 1
        else
            local void = HTML_VOID_TAGS[tag_name] or false
            if depth == 0 then
                ordinal = ordinal + 1
                if tag_name == element_name then
                    found = found + 1
                    if found == nth then
                        -- Extract id attribute if present
                        local elem_id = full_tag:match('%sid=["\']([^"\']+)["\']')
                        return ordinal, elem_id
                    end
                end
            end
            if not void and not is_self_closing then
                depth = depth + 1
            end
        end

        i = tag_end + 1
    end
    return nil, nil
end

--[[--
Extract the inner HTML content of the Nth occurrence of `element_name`
among the direct children of `html_content`.

@param html_content string
@param element_name string
@param nth           number  1-based
@return string|nil  inner HTML, or nil
--]]
local function extractNthElementContent(html_content, element_name, nth)
    element_name = element_name:lower()
    local depth   = 0
    local found   = 0
    local in_target      = false
    local target_depth   = nil
    local content_start  = nil

    local i   = 1
    local len = #html_content
    while i <= len do
        local tag_start, tag_end, full_tag = html_content:find("(<[^>]+>)", i)
        if not tag_start then break end

        local is_closing     = full_tag:sub(1, 2) == "</"
        local is_self_closing = full_tag:sub(-2) == "/>"
        local tag_name = full_tag:match("^</?([%a][%w%-]*)")
        if tag_name then tag_name = tag_name:lower() end

        local void = HTML_VOID_TAGS[tag_name] or false

        if is_closing then
            depth = depth - 1
            if in_target and depth == target_depth then
                -- End of the element we're extracting
                return html_content:sub(content_start, tag_start - 1)
            end
        else
            if depth == 0 and tag_name == element_name then
                found = found + 1
                if found == nth then
                    in_target    = true
                    target_depth = depth
                    content_start = tag_end + 1
                end
            end
            if not void and not is_self_closing then
                depth = depth + 1
            end
        end

        i = tag_end + 1
    end
    return nil
end

--[[--
Build the EPUB CFI spine map for an open EPUB document.

Reads META-INF/container.xml, then the OPF manifest/spine, via the
CREngine `getDocumentFileContent` method available while the document
is open.

@param document  CreDocument instance (self.ui.document)
@return table|nil  Array of href strings, 1-indexed = DocFragment index.
                   Returns nil on any read/parse failure.
--]]
function BookloreSync:buildEpubSpineMap(document)
    if not document or not document.getDocumentFileContent then
        return nil
    end

    -- 1. Read container.xml to find OPF path
    local container_xml = document:getDocumentFileContent("META-INF/container.xml")
    if not container_xml then
        self:logWarn("BookloreSync: Could not read META-INF/container.xml")
        return nil
    end

    local opf_path = container_xml:match('full%-path=["\']([^"\']+)["\']')
    if not opf_path then
        self:logWarn("BookloreSync: Could not find OPF path in container.xml")
        return nil
    end

    -- Determine the directory that contains the OPF (for resolving relative hrefs)
    local opf_dir = opf_path:match("^(.*)/[^/]+$") or ""

    -- 2. Read OPF
    local opf = document:getDocumentFileContent(opf_path)
    if not opf then
        self:logWarn("BookloreSync: Could not read OPF:", opf_path)
        return nil
    end

    -- 3. Parse manifest: id -> href
    local manifest = {}
    for attrs in opf:gmatch("<item%s+([^>]+)>") do
        local id_  = attrs:match('%bid=["\']([^"\']+)["\']')
        local href = attrs:match('%bhref=["\']([^"\']+)["\']')
        if id_ and href then
            -- Resolve relative to OPF directory
            if opf_dir ~= "" then
                manifest[id_] = opf_dir .. "/" .. href
            else
                manifest[id_] = href
            end
        end
    end

    -- 4. Build ordered spine list
    local spine = {}
    for idref in opf:gmatch('<itemref[^>]+idref=["\']([^"\']+)["\']') do
        local href = manifest[idref]
        table.insert(spine, href)  -- spine[1] = DocFragment[1]
    end

    if #spine == 0 then
        self:logWarn("BookloreSync: Empty spine in OPF")
        return nil
    end

    self:logInfo("BookloreSync: Built EPUB spine map with", #spine, "items")
    return spine
end

--[[--
Convert a single KOReader CREngine xpointer to a list of CFI step strings
for the intra-document portion (after the `!`).

KOReader xpointer text-node formats handled:
  text().N      — first (only) text node, character offset N
  text()[K].N   — Kth text node among mixed content, character offset N

In CFI, text nodes are addressed as odd-numbered children:
  text node K  →  /(2K-1):N
  (first/only text node = /1:N)

Element steps include an ID assertion when the element carries an `id`
attribute, e.g. `/4[myid]`.

@param xpointer       string      KOReader xpointer string
@param spine          table       Spine href array from buildEpubSpineMap()
@param document       CreDocument Open document instance
@param html_cache     table       Mutable table used to cache spine HTML
@return table|nil   Array of CFI step strings (each "/N", "/N[id]", or ":N"),
                    plus metadata fields:
                      .spine_step  number  (the /6/N part)
                    Returns nil on any parse failure.
--]]
function BookloreSync:xpointerToCfiPath(xpointer, spine, document, html_cache)
    if not xpointer or not spine or not document then return nil end
    html_cache = html_cache or {}

    -- Extract DocFragment index and the inner path after it
    local frag_idx_s, inner_path = xpointer:match("^/body/DocFragment%[(%d+)%](.*)")
    if not frag_idx_s then
        self:logWarn("BookloreSync: xpointer does not match expected format:", xpointer)
        return nil
    end

    local frag_idx   = tonumber(frag_idx_s)
    local spine_step = frag_idx * 2

    if frag_idx < 1 or frag_idx > #spine then
        self:logWarn("BookloreSync: DocFragment index out of range:", frag_idx, "(spine size:", #spine, ")")
        return nil
    end

    local href = spine[frag_idx]
    if not href then
        self:logWarn("BookloreSync: No href for DocFragment[" .. frag_idx .. "]")
        return nil
    end

    local html = html_cache[href]
    if not html then
        html = document:getDocumentFileContent(href)
        if not html then
            self:logWarn("BookloreSync: Could not read spine item:", href)
            return nil
        end
        html_cache[href] = html
    end

    -- Split inner_path into components, e.g.
    --   /body/div/p[7]/text().0      → {"body","div","p[7]","text().0"}
    --   /body/p[30]/text()[2].92     → {"body","p[30]","text()[2].92"}
    local parts = {}
    for part in inner_path:gmatch("[^/]+") do
        table.insert(parts, part)
    end

    local steps = {}           -- CFI step strings, e.g. "/4", "/6[myid]", ":5"
    local current_content = html

    for idx, part in ipairs(parts) do
        -- ── text node: text().N or text()[K].N ──────────────────────────────
        -- text().N  → first text node → /1:N
        local offset_s = part:match("^text%(%)%.(%d+)$")
        if offset_s then
            table.insert(steps, "/1")
            table.insert(steps, ":" .. offset_s)
            break
        end

        -- text()[K].N  → Kth text node → /(2K-1):N
        local k_s, offset2_s = part:match("^text%(%)%[(%d+)%]%.(%d+)$")
        if k_s then
            local k = tonumber(k_s)
            table.insert(steps, "/" .. (2 * k - 1))
            table.insert(steps, ":" .. offset2_s)
            break
        end

        -- ── element step: name[N] or name ───────────────────────────────────
        local elem_name, elem_idx_s = part:match("^([%a][%w%-]*)%[(%d+)%]$")
        if not elem_name then
            elem_name  = part:match("^([%a][%w%-]*)$")
            elem_idx_s = "1"
        end
        if not elem_name then
            self:logWarn("BookloreSync: Unrecognised xpointer component:", part)
            return nil
        end
        local elem_idx = tonumber(elem_idx_s)

        -- Special case: "body" as the first inner component is always /4
        if elem_name:lower() == "body" and idx == 1 then
            table.insert(steps, "/4")
            local body_content = current_content:match("<[Bb][Oo][Dd][Yy][^>]*>(.*)</%s*[Bb][Oo][Dd][Yy]%s*>")
            current_content = body_content or ""
        else
            local ordinal, elem_id = findNthElementOrdinal(current_content, elem_name, elem_idx)
            if not ordinal then
                self:logWarn(string.format(
                    "BookloreSync: Could not find %s[%d] in xpointer at step %d (%s)",
                    elem_name, elem_idx, idx, xpointer))
                return nil
            end
            local step = "/" .. (ordinal * 2)
            if elem_id and elem_id ~= "" then
                step = step .. "[" .. elem_id .. "]"
            end
            table.insert(steps, step)

            local child_content = extractNthElementContent(current_content, elem_name, elem_idx)
            current_content = child_content or ""
        end
    end

    -- Attach metadata needed by buildCfi
    steps.spine_step = spine_step
    return steps
end

--[[--
Build an EPUB CFI range string from two KOReader xpointers.

Produces the correct three-part range form:
  epubcfi(shared-path , start-relative , end-relative)

where `shared-path` is the common element ancestor prefix (up to and
including the last shared element step), and `start-relative` /
`end-relative` are the diverging suffixes (text-node step + offset).

@param pos0       string      KOReader start xpointer
@param pos1       string      KOReader end xpointer
@param spine      table|nil
@param document   object|nil
@param html_cache table|nil
@return string|nil  e.g. "epubcfi(/6/22!/4/16[myid]/1:0,/1:112)"
--]]
function BookloreSync:buildCfi(pos0, pos1, spine, document, html_cache)
    if not pos0 or not pos1 then return nil end
    if not spine or not document then
        self:logWarn("BookloreSync: buildCfi called without spine/document — skipping")
        return nil
    end

    html_cache = html_cache or {}

    local steps0 = self:xpointerToCfiPath(pos0, spine, document, html_cache)
    local steps1 = self:xpointerToCfiPath(pos1, spine, document, html_cache)
    if not steps0 or not steps1 then return nil end

    -- Build full intra-doc path strings (e.g. "/4/2/28[id]/1:0")
    -- steps are an array of strings like "/4", "/6[foo]", "/1", ":0"
    -- The spine prefix is "/6/<spine_step>!"
    local function stepsToPath(steps)
        local spine_prefix = "/6/" .. steps.spine_step .. "!"
        local inner = table.concat(steps)
        return spine_prefix .. inner
    end

    local path0 = stepsToPath(steps0)
    local path1 = stepsToPath(steps1)

    -- Find the longest common prefix at step boundaries.
    -- We compare element steps (entries starting with "/") until they diverge,
    -- then the remainder of each becomes the relative start/end.
    --
    -- Strategy: walk both step arrays together. Stop at the first step that
    -- differs (or when one array runs out). Everything before that is the
    -- shared path; from that index onward is the relative suffix for each.

    -- Normalise: include spine_step as the first logical step for comparison
    local function buildStepList(steps)
        local list = { "/6/" .. steps.spine_step .. "!" }
        for _, s in ipairs(steps) do
            table.insert(list, s)
        end
        return list
    end

    local list0 = buildStepList(steps0)
    local list1 = buildStepList(steps1)

    -- Find the split point: last index where both lists agree
    local shared_len = 0
    local min_len = math.min(#list0, #list1)
    for i = 1, min_len do
        if list0[i] == list1[i] then
            shared_len = i
        else
            break
        end
    end

    -- Offset steps (":N") and the text-node step immediately preceding them
    -- must never be part of the shared path — they are always terminal and
    -- belong to the relative start/end parts.
    -- Case 1: the shared boundary itself is an offset step (":N")
    if shared_len > 0 and list0[shared_len]:sub(1,1) == ":" then
        shared_len = shared_len - 1
    end
    -- Case 2: the first diverging step is an offset (":N"), meaning the last
    -- shared step is the paired text-node step ("/1", "/3", …) — pull it out.
    local next_idx = shared_len + 1
    if shared_len > 0
        and list0[next_idx] and list0[next_idx]:sub(1,1) == ":"
        and list1[next_idx] and list1[next_idx]:sub(1,1) == ":"
    then
        shared_len = shared_len - 1
    end

    -- Reconstruct shared path and relative suffixes
    local shared_parts = {}
    for i = 1, shared_len do
        table.insert(shared_parts, list0[i])
    end

    local rel0_parts = {}
    for i = shared_len + 1, #list0 do
        table.insert(rel0_parts, list0[i])
    end

    local rel1_parts = {}
    for i = shared_len + 1, #list1 do
        table.insert(rel1_parts, list1[i])
    end

    local shared = table.concat(shared_parts)
    local rel0   = table.concat(rel0_parts)
    local rel1   = table.concat(rel1_parts)

    -- If the relative parts are empty (identical xpointers), fall back to
    -- a simple single-location CFI.
    if rel0 == "" and rel1 == "" then
        return "epubcfi(" .. path0 .. ")"
    end

    return "epubcfi(" .. shared .. "," .. rel0 .. "," .. rel1 .. ")"
end

--[[--
Sync all highlights and notes for a document to Booklore.

Reads the .sdr sidecar annotations array, skips already-synced entries
(via synced_annotations DB table), and posts each new item to the
appropriate API endpoint based on the notes_destination setting.

Highlights (no note field) → POST /api/v1/annotations
Notes with destination "in_book" → POST /api/v2/book-notes
Notes with destination "in_booklore" → POST /api/v1/book-notes

@param doc_path  string      Full path to the document file
@param book_id   number      Booklore book ID
@param document  CreDocument Open CREngine document (still available in onCloseDocument).
                             Required for EPUB CFI generation; highlights/in-book notes
                             are skipped if nil (Booklore-notes still work without it).
--]]
function BookloreSync:syncHighlightsAndNotes(doc_path, book_id, document)
    if not doc_path then
        self:logWarn("BookloreSync: syncHighlightsAndNotes called without doc_path")
        return
    end
    if not self.extended_sync_enabled or not self.highlights_notes_sync_enabled then
        return
    end
    if self.booklore_username == "" or self.booklore_password == "" then
        self:logWarn("BookloreSync: Highlights/notes sync skipped — credentials not configured")
        return
    end

    -- book_id may be nil when the server was offline at open time.
    -- In that case we skip API calls but still compute CFIs (while the doc is
    -- open) and queue every annotation into pending_annotations so they are
    -- submitted on the next sync once the book_id has been resolved.
    local queue_only = (book_id == nil)

    local annotations = self.metadata_extractor:getHighlights(doc_path)
    if not annotations or #annotations == 0 then
        self:logInfo("BookloreSync: No annotations found for:", doc_path)
        return
    end

    self:logInfo("BookloreSync: Syncing", #annotations, "annotations for book_id:", book_id)

    -- Build EPUB spine map (needed for CFI generation).
    -- Only attempt this for EPUB files where the document is still open.
    local spine = nil
    local is_epub = doc_path:lower():match("%.epub$") ~= nil
    if is_epub and document then
        spine = self:buildEpubSpineMap(document)
        if not spine then
            self:logWarn("BookloreSync: Could not build EPUB spine map — highlights/in-book notes will be skipped")
        end
    end

    -- Shared HTML cache for spine items (avoids re-reading the same file for each annotation)
    local html_cache = {}

    -- Ensure we have a book_cache_id (create minimal cache entry if needed)
    local book_cache_id = self.db:getBookCacheIdByFilePath(doc_path)
    if not book_cache_id then
        self.db:saveBookCache(doc_path, "", nil, nil, nil, nil, nil)
        book_cache_id = self.db:getBookCacheIdByFilePath(doc_path)
    end
    if not book_cache_id then
        self:logWarn("BookloreSync: Could not obtain book_cache_id for highlights sync")
        return
    end

    local notes_dest    = self.notes_destination or "in_book"
    local synced_count  = 0
    local skipped_count = 0
    local failed_count  = 0

    for _, ann in ipairs(annotations) do
        local datetime = ann.datetime or ""
        if datetime == "" then
            self:logWarn("BookloreSync: Skipping annotation with no datetime")
            skipped_count = skipped_count + 1
            goto continue
        end

        local has_note = ann.note and ann.note ~= ""

        -- Determine type key for dedup tracking
        local ann_type
        if not has_note then
            ann_type = "highlight"
        elseif notes_dest == "in_book" then
            ann_type = "in_book_note"
        else
            ann_type = "booklore_note"
        end

        -- Skip if already synced
        if self.db:isAnnotationSynced(book_cache_id, datetime, ann_type) then
            self:logInfo("BookloreSync: Annotation already synced, skipping:", datetime)
            skipped_count = skipped_count + 1
            goto continue
        end

        -- Wrap per-annotation processing in pcall so a malformed xpointer or
        -- unexpected nil never crashes the close-document flow.
        local ann_ok, ann_err = pcall(function()
            local ok, server_id
            local cfi  -- computed below and reused in payload

            if not has_note then
                -- ── Pure highlight ──────────────────────────────────────────────
                cfi = self:buildCfi(ann.pos0, ann.pos1, spine, document, html_cache)
                if not cfi then
                    self:logWarn("BookloreSync: Could not build CFI for highlight at:", datetime)
                    skipped_count = skipped_count + 1
                    return
                end
                if not queue_only then
                    ok, server_id = self.api:submitHighlight(
                        book_id, cfi, ann.text,
                        {
                            color         = self:colorToHex(ann.color),
                            style         = self:drawerToStyle(ann.drawer),
                            chapter_title = ann.chapter,
                        },
                        self.booklore_username, self.booklore_password
                    )
                end

            elseif notes_dest == "in_book" then
                -- ── In-book note (v2) ────────────────────────────────────────────
                cfi = self:buildCfi(ann.pos0, ann.pos1, spine, document, html_cache)
                if not cfi then
                    self:logWarn("BookloreSync: Could not build CFI for in-book note at:", datetime)
                    skipped_count = skipped_count + 1
                    return
                end
                if not queue_only then
                    ok, server_id = self.api:submitInBookNote(
                        book_id, cfi, ann.note,
                        {
                            selected_text = ann.text,
                            color         = self:colorToHex(ann.color),
                            chapter_title = ann.chapter,
                        },
                        self.booklore_username, self.booklore_password
                    )
                end

            else
                -- ── Booklore (web-UI) note ───────────────────────────────────────
                if not queue_only then
                    ok, server_id = self.api:submitBookloreNote(
                        book_id, ann.note, ann.chapter,
                        self.booklore_username, self.booklore_password
                    )
                end
            end

            if queue_only then
                -- No book_id yet — queue for retry with full CFI cached in payload.
                local pending_payload = json.encode({
                    ann_type   = ann_type,
                    datetime   = datetime,
                    text       = ann.text,
                    note       = ann.note,
                    chapter    = ann.chapter,
                    color      = self:colorToHex(ann.color),
                    style      = self:drawerToStyle(ann.drawer),
                    cfi        = cfi,
                    pos0       = ann.pos0,
                    pos1       = ann.pos1,
                    notes_dest = notes_dest,
                })
                self.db:addPendingAnnotation(book_cache_id, nil, ann_type, datetime, pending_payload)
                failed_count = failed_count + 1
            elseif ok then
                self.db:markAnnotationSynced(book_cache_id, datetime, ann_type, server_id)
                synced_count = synced_count + 1
            else
                self:logWarn("BookloreSync: Failed to sync annotation at:", datetime, "-", server_id)
                failed_count = failed_count + 1
                -- Queue for retry so it is not silently dropped.
                -- Cache the already-computed CFI in the payload so the retry
                -- path does not need a live document.
                local pending_payload = json.encode({
                    ann_type   = ann_type,
                    datetime   = datetime,
                    text       = ann.text,
                    note       = ann.note,
                    chapter    = ann.chapter,
                    color      = self:colorToHex(ann.color),
                    style      = self:drawerToStyle(ann.drawer),
                    cfi        = cfi,
                    pos0       = ann.pos0,
                    pos1       = ann.pos1,
                    notes_dest = notes_dest,
                })
                self.db:addPendingAnnotation(book_cache_id, book_id, ann_type, datetime, pending_payload)
            end
        end)

        if not ann_ok then
            self:logErr("BookloreSync: Unexpected error processing annotation at:", datetime, "-", ann_err)
            failed_count = failed_count + 1
            -- Queue for retry even when the pcall itself fails, so the
            -- annotation is not lost.  Use a minimal payload (no CFI) — the
            -- retry path will skip annotations it cannot re-submit.
            local ok_enc, pending_payload = pcall(json.encode, {
                ann_type   = ann_type,
                datetime   = datetime,
                text       = ann.text,
                note       = ann.note,
                chapter    = ann.chapter,
                color      = self:colorToHex(ann.color),
                style      = self:drawerToStyle(ann.drawer),
                pos0       = ann.pos0,
                pos1       = ann.pos1,
                notes_dest = notes_dest,
            })
            if ok_enc and pending_payload then
                self.db:addPendingAnnotation(book_cache_id, book_id, ann_type, datetime, pending_payload)
            end
        end

        ::continue::
    end

    self:logInfo(string.format(
        "BookloreSync: Highlights/notes sync done — synced:%d  skipped:%d  failed:%d",
        synced_count, skipped_count, failed_count
    ))
end

function BookloreSync:addToMainMenu(menu_items)
    local base_menu = {}
    
    table.insert(base_menu, {
        text = _("Enable Sync"),
        help_text = _("Enable or disable automatic syncing of reading sessions to Booklore server. When disabled, no sessions will be tracked or synced."),
        checked_func = function()
            return self.is_enabled
        end,
        callback = function()
            self.is_enabled = not self.is_enabled
            self.settings:saveSetting("is_enabled", self.is_enabled)
            self.settings:flush()
            UIManager:show(InfoMessage:new{
                text = self.is_enabled and _("Booklore sync enabled") or _("Booklore sync disabled"),
                timeout = 2,
            })
        end,
    })
    
    table.insert(base_menu, Settings:buildAuthMenu(self))
    
    table.insert(base_menu, {
        text = _("Sync Settings"),
        sub_item_table = {
            -- Session Settings submenu
            {
                text = _("Session Settings"),
                help_text = _("Configure how reading sessions are detected and recorded."),
                sub_item_table = {
                    {
                        text = _("Detection Mode"),
                        help_text = _("Choose how sessions are validated: Duration-based (minimum seconds) or Pages-based (minimum pages read). Default is duration-based."),
                        sub_item_table = {
                            {
                                text = _("Duration-based"),
                                help_text = _("Sessions must last a minimum number of seconds. Good for general reading tracking."),
                                checked_func = function()
                                    return self.session_detection_mode == "duration"
                                end,
                                callback = function()
                                    self.session_detection_mode = "duration"
                                    self.settings:saveSetting("session_detection_mode", self.session_detection_mode)
                                    self.settings:flush()
                                    UIManager:show(InfoMessage:new{
                                        text = _("Session detection set to duration-based"),
                                        timeout = 2,
                                    })
                                end,
                                keep_menu_open = true,
                            },
                            {
                                text = _("Pages-based"),
                                help_text = _("Sessions must include a minimum number of pages read. Better for avoiding accidental sessions."),
                                checked_func = function()
                                    return self.session_detection_mode == "pages"
                                end,
                                callback = function()
                                    self.session_detection_mode = "pages"
                                    self.settings:saveSetting("session_detection_mode", self.session_detection_mode)
                                    self.settings:flush()
                                    UIManager:show(InfoMessage:new{
                                        text = _("Session detection set to pages-based"),
                                        timeout = 2,
                                    })
                                end,
                                keep_menu_open = true,
                            },
                        },
                    },
                    {
                        text = _("Minimum Duration (seconds)"),
                        help_text = _("Set the minimum number of seconds a reading session must last to be synced. Sessions shorter than this will be discarded. Default is 30 seconds. Only applies when using duration-based detection."),
                        enabled_func = function()
                            return self.session_detection_mode == "duration"
                        end,
                        keep_menu_open = true,
                        callback = function()
                            Settings:configureMinDuration(self)
                        end,
                    },
                    {
                        text = _("Minimum Pages Read"),
                        help_text = _("Set the minimum number of pages that must be read in a session for it to be synced. Default is 1 page. Only applies when using pages-based detection."),
                        enabled_func = function()
                            return self.session_detection_mode == "pages"
                        end,
                        keep_menu_open = true,
                        callback = function()
                            Settings:configureMinPages(self)
                        end,
                    },
                    {
                        text = _("Progress Decimal Places"),
                        help_text = _("Set the number of decimal places to use when reporting reading progress percentage (0-5). Higher precision may be useful for large books. Default is 2."),
                        keep_menu_open = true,
                        callback = function()
                            Settings:configureProgressDecimalPlaces(self)
                        end,
                    },
                },
            },

            -- Rating submenu
            Settings:buildRatingMenu(self),

            -- Annotations submenu
            Settings:buildAnnotationsMenu(self),

            -- ── Sync Triggers ────────────────────────────────────────────────
            {
                text = _("── Sync Triggers ──"),
                enabled = false,
            },
            {
                text = _("Automatic (sync on suspend + WiFi)"),
                help_text = _("Automatically sync sessions when device suspends. Enables WiFi and attempts connection before syncing."),
                checked_func = function()
                    return self.sync_mode == "automatic"
                end,
                callback = function()
                    self:setSyncMode("automatic")
                    UIManager:show(InfoMessage:new{
                        text = _("Sync mode set to Automatic"),
                        timeout = 2,
                    })
                end,
                keep_menu_open = true,
            },
            {
                text = _("Manual only (cache everything)"),
                help_text = _("Cache all sessions and prevent automatic syncing. Use 'Sync Pending Now' when ready to upload."),
                checked_func = function()
                    return self.sync_mode == "manual"
                end,
                callback = function()
                    self:setSyncMode("manual")
                    UIManager:show(InfoMessage:new{
                        text = _("Sync mode set to Manual only"),
                        timeout = 2,
                    })
                end,
                keep_menu_open = true,
            },
            {
                text = _("Custom"),
                help_text = _("Configure individual sync options manually."),
                checked_func = function()
                    return self.sync_mode == "custom"
                end,
                callback = function()
                    self:setSyncMode("custom")
                    UIManager:show(InfoMessage:new{
                        text = _("Sync mode set to Custom"),
                        timeout = 2,
                    })
                end,
                keep_menu_open = true,
            },
            {
                text = _("Custom Options:"),
                enabled_func = function()
                    return self.sync_mode == "custom"
                end,
                enabled = false,
            },
            {
                text = _("  Auto-sync on suspend"),
                help_text = _("Automatically sync the current reading session and all pending sessions when the device suspends."),
                enabled_func = function()
                    return self.sync_mode == "custom"
                end,
                checked_func = function()
                    return self.force_push_session_on_suspend
                end,
                callback = function()
                    self.force_push_session_on_suspend = not self.force_push_session_on_suspend
                    self.settings:saveSetting("force_push_session_on_suspend", self.force_push_session_on_suspend)
                    self.settings:flush()
                    UIManager:show(InfoMessage:new{
                        text = self.force_push_session_on_suspend and _("Auto-sync on suspend enabled") or _("Auto-sync on suspend disabled"),
                        timeout = 2,
                    })
                end,
            },
            {
                text = _("  Connect WiFi on suspend"),
                help_text = _("Automatically enable WiFi and attempt to connect when the device suspends. Waits up to 15 seconds for connection."),
                enabled_func = function()
                    return self.sync_mode == "custom"
                end,
                checked_func = function()
                    return self.connect_network_on_suspend
                end,
                callback = function()
                    self.connect_network_on_suspend = not self.connect_network_on_suspend
                    self.settings:saveSetting("connect_network_on_suspend", self.connect_network_on_suspend)
                    self.settings:flush()
                    UIManager:show(InfoMessage:new{
                        text = self.connect_network_on_suspend and _("Connect WiFi on suspend enabled") or _("Connect WiFi on suspend disabled"),
                        timeout = 2,
                    })
                end,
            },
        },
    })

    table.insert(base_menu, {
        text = _("Manage Sessions"),
        sub_item_table = {
            {
                text_func = function()
                    if not self.db then return _("Sync Pending Now") end
                    local sessions     = tonumber(self.db:getPendingSessionCount())     or 0
                    local annotations  = tonumber(self.db:getPendingAnnotationCount())  or 0
                    local ratings      = tonumber(self.db:getPendingRatingCount())      or 0
                    local total = sessions + annotations + ratings
                    if total == 0 then
                        return _("Sync Pending Now")
                    end
                    local parts = {}
                    if sessions    > 0 then table.insert(parts, T(_("%1 S"),  sessions))    end
                    if annotations > 0 then table.insert(parts, T(_("%1 A"),  annotations)) end
                    if ratings     > 0 then table.insert(parts, T(_("%1 R"),  ratings))     end
                    return T(_("Sync Pending Now (%1)"), table.concat(parts, ", "))
                end,
                help_text = _("Manually upload all pending items that failed to sync previously — reading sessions, annotations (highlights and notes), and ratings. Items are cached locally when the network is unavailable."),
                enabled_func = function()
                    if not self.db then return false end
                    local sessions     = tonumber(self.db:getPendingSessionCount())     or 0
                    local annotations  = tonumber(self.db:getPendingAnnotationCount())  or 0
                    local ratings      = tonumber(self.db:getPendingRatingCount())      or 0
                    return (sessions + annotations + ratings) > 0
                end,
                callback = function()
                    self:syncPendingSessions()
                end,
            },
            {
                text = _("View Details"),
                help_text = _("Display statistics about the local cache: number of book hashes cached, file paths cached, and pending sessions."),
                keep_menu_open = true,
                callback = function()
                    self:viewSessionDetails()
                end,
            },
            {
                text_func = function()
                    if not self.db then return _("Match Unmatched Books") end
                    local stats = self.db:getBookCacheStats()
                    local n = stats and stats.unmatched or 0
                    if n == 0 then return _("Match Unmatched Books") end
                    return T(_("Match Unmatched Books (%1)"), n)
                end,
                help_text = _("Query the Booklore server to resolve book IDs for any cached books that were opened while the server was offline. Requires a network connection."),
                keep_menu_open = true,
                enabled_func = function()
                    if not self.db then return false end
                    local stats = self.db:getBookCacheStats()
                    return stats and stats.unmatched > 0
                end,
                callback = function()
                    if not NetworkMgr:isConnected() then
                        UIManager:show(InfoMessage:new{
                            text = _("No network connection"),
                            timeout = 2,
                        })
                        return
                    end
                    local resolved = self:resolveUnmatchedBooks(false)
                    if not resolved or resolved == 0 then
                        local stats = self.db:getBookCacheStats()
                        local remaining = stats and stats.unmatched or 0
                        if remaining > 0 then
                            UIManager:show(ConfirmBox:new{
                                text = T(_("No new matches found (%1 still unmatched).\n\nDo you want to manually match the books?"), remaining),
                                ok_text = _("Yes"),
                                cancel_text = _("No"),
                                ok_callback = function()
                                    self:_startBookCacheMatching()
                                end,
                            })
                        else
                            UIManager:show(InfoMessage:new{
                                text = _("All books matched"),
                                timeout = 2,
                            })
                        end
                    end
                end,
            },
            {
                text_func = function()
                    if not self.db then return _("Clear Pending...") end
                    local s = tonumber(self.db:getPendingSessionCount())    or 0
                    local a = tonumber(self.db:getPendingAnnotationCount()) or 0
                    local r = tonumber(self.db:getPendingRatingCount())     or 0
                    if (s + a + r) == 0 then return _("Clear Pending...") end
                    local parts = {}
                    if s > 0 then table.insert(parts, T(_("%1 S"), s)) end
                    if a > 0 then table.insert(parts, T(_("%1 A"), a)) end
                    if r > 0 then table.insert(parts, T(_("%1 R"), r)) end
                    return T(_("Clear Pending... (%1)"), table.concat(parts, ", "))
                end,
                help_text = _("Choose which types of pending items to delete from the local queue: sessions, annotations (highlights/notes), and/or ratings."),
                enabled_func = function()
                    if not self.db then return false end
                    local s = tonumber(self.db:getPendingSessionCount())    or 0
                    local a = tonumber(self.db:getPendingAnnotationCount()) or 0
                    local r = tonumber(self.db:getPendingRatingCount())     or 0
                    return (s + a + r) > 0
                end,
                callback = function()
                    self:showClearPendingDialog()
                end,
            },
            {
                text = _("Clear Cache"),
                help_text = _("Delete all cached book hashes and file path mappings. This will not affect pending sessions. The cache will be rebuilt as you read."),
                enabled_func = function()
                    if not self.db then
                        return false
                    end
                    local stats = self.db:getBookCacheStats()
                    return stats.total > 0
                end,
                callback = function()
                    if self.db then
                        self.db:clearBookCache()
                        UIManager:show(InfoMessage:new{
                            text = _("Local book cache cleared"),
                            timeout = 2,
                        })
                    end
                end,
            },
        },
    })

    table.insert(base_menu, {
        text = _("Import Reading History"),
        sub_item_table = {
            {
                text = _("Extract Sessions from KOReader"),
                help_text = _("One-time extraction of reading sessions from KOReader's statistics database. This reads page statistics and groups them into sessions. Run this first before matching."),
                enabled_func = function()
                    return self.is_enabled
                end,
                callback = function()
                    self:copySessionsFromKOReader()
                end,
            },
            {
                text = _("Match Books with Booklore"),
                help_text = _("Match extracted sessions with books on Booklore server. For each unmatched book, searches by title and lets you select the correct match. Matched sessions are automatically synced."),
                enabled_func = function()
                    return self.server_url ~= "" and self.booklore_username ~= "" and self.booklore_password ~= "" and self.is_enabled
                end,
                callback = function()
                    self:matchHistoricalData()
                end,
            },
            {
                text = _("View Match Statistics"),
                help_text = _("Display statistics about historical sessions: total sessions extracted, matched sessions, unmatched sessions, and synced sessions."),
                callback = function()
                    self:viewMatchStatistics()
                end,
            },
            {
                text = _("Re-sync All Historical"),
                help_text = _("Re-sync all previously synced historical sessions to the server. Sessions with invalid book IDs (404 errors) will be marked for re-matching."),
                enabled_func = function()
                    return self.server_url ~= "" and self.booklore_username ~= "" and self.booklore_password ~= "" and self.is_enabled
                end,
                callback = function()
                    self:resyncHistoricalData()
                end,
            },
            {
                text = _("Sync Re-matched Sessions"),
                help_text = _("Sync sessions that were previously marked for re-matching (404 errors) and have now been matched to valid books."),
                enabled_func = function()
                    return self.server_url ~= "" and self.booklore_username ~= "" and self.booklore_password ~= "" and self.is_enabled
                end,
                callback = function()
                    self:syncRematchedSessions()
                end,
            },
        },
    })
    
    table.insert(base_menu, Settings:buildPreferencesMenu(self))
    
    table.insert(base_menu, {
        text = self.update_available and _("About & Updates ⚠") or _("About & Updates"),
        sub_item_table = {
            {
                text = _("Plugin Information"),
                keep_menu_open = true,
                callback = function()
                    self:showVersionInfo()
                end,
            },
            {
                text = self.update_available and _("Check for Updates ⚠ Update Available!") or _("Check for Updates"),
                keep_menu_open = true,
                callback = function()
                    self:checkForUpdates(false)  -- silent=false
                end,
            },
            {
                text = _("Auto-check on Startup"),
                checked_func = function()
                    return self.auto_update_check
                end,
                callback = function()
                    self:toggleAutoUpdateCheck()
                end,
            },
            {
                text = _("Clear Update Cache"),
                help_text = _("Force a fresh check by clearing cached release info"),
                keep_menu_open = true,
                callback = function()
                    self:clearUpdateCache()
                end,
            },
        },
    })
    
    menu_items.booklore_sync = {
        text = _("Booklore Sync"),
        sorting_hint = "tools",
        sub_item_table = base_menu,
    }
end

function BookloreSync:configureBookloreLogin()
    local username_input
    username_input = InputDialog:new{
        title = _("Booklore Username"),
        input = self.booklore_username,
        input_hint = _("Enter Booklore username"),
        buttons = {
            {
                {
                    text = _("Cancel"),
                    callback = function()
                        UIManager:close(username_input)
                    end,
                },
                {
                    text = _("Next"),
                    is_enter_default = true,
                    callback = function()
                        self.booklore_username = username_input:getInputText()
                        UIManager:close(username_input)
                        
                        local password_input
                        password_input = InputDialog:new{
                            title = _("Booklore Password"),
                            input = self.booklore_password,
                            input_hint = _("Enter Booklore password"),
                            text_type = "password",
                            buttons = {
                                {
                                    {
                                        text = _("Cancel"),
                                        callback = function()
                                            UIManager:close(password_input)
                                        end,
                                    },
                                    {
                                        text = _("Save"),
                                        is_enter_default = true,
                                        callback = function()
                                            self.booklore_password = password_input:getInputText()
                                            UIManager:close(password_input)
                                            self.settings:saveSetting("booklore_username", self.booklore_username)
                                            self.settings:saveSetting("booklore_password", self.booklore_password)
                                            self.settings:flush()
                                            
                                            UIManager:show(InfoMessage:new{
                                                text = _("Booklore login credentials saved"),
                                                timeout = 2,
                                            })
                                        end,
                                    },
                                },
                            },
                        }
                        UIManager:show(password_input)
                        password_input:onShowKeyboard()
                    end,
                },
            },
        },
    }
    UIManager:show(username_input)
    username_input:onShowKeyboard()
end

function BookloreSync:testConnection()
    UIManager:show(InfoMessage:new{
        text = _("Testing connection..."),
        timeout = 1,
    })
    
    if not self.server_url or self.server_url == "" then
        UIManager:show(InfoMessage:new{
            text = _("Error: Server URL not configured"),
            timeout = 3,
        })
        return
    end
    
    if not self.username or self.username == "" then
        UIManager:show(InfoMessage:new{
            text = _("Error: Username not configured"),
            timeout = 3,
        })
        return
    end
    
    if not self.password or self.password == "" then
        UIManager:show(InfoMessage:new{
            text = _("Error: Password not configured"),
            timeout = 3,
        })
        return
    end
    
    self.api:init(self.server_url, self.username, self.password, self.db, self.secure_logs)
    
    local success, message = self.api:testAuth()
    
    if success then
        UIManager:show(InfoMessage:new{
            text = _("✓ Connection successful!\n\nAuthentication verified."),
            timeout = 3,
        })
    else
        UIManager:show(InfoMessage:new{
            text = T(_("✗ Connection failed\n\n%1"), message),
            timeout = 5,
        })
    end
end

--[[--
Format duration in seconds to a human-readable string

@param duration_seconds Number of seconds
@return string Formatted duration (e.g., "1h 5m 9s", "45m 30s", "15s")
--]]
function BookloreSync:formatDuration(duration_seconds)
    duration_seconds = tonumber(duration_seconds)
    
    if not duration_seconds or duration_seconds < 0 then
        return "0s"
    end
    
    local hours = math.floor(duration_seconds / 3600)
    local minutes = math.floor((duration_seconds % 3600) / 60)
    local seconds = duration_seconds % 60
    
    local parts = {}
    
    if hours > 0 then
        table.insert(parts, string.format("%dh", hours))
    end
    
    if minutes > 0 then
        table.insert(parts, string.format("%dm", minutes))
    end
    
    if seconds > 0 or #parts == 0 then
        table.insert(parts, string.format("%ds", seconds))
    end
    
    return table.concat(parts, " ")
end

--[[--
Validate if a session should be recorded based on detection mode

@param duration_seconds Number of seconds the session lasted
@param pages_read Number of pages read during the session
@return boolean should_record
@return string reason (if should_record is false)
--]]
function BookloreSync:validateSession(duration_seconds, pages_read)
    if self.session_detection_mode == "pages" then
        if pages_read < self.min_pages then
            return false, string.format("Insufficient pages read (%d < %d)", pages_read, self.min_pages)
        end
    else
        if duration_seconds < self.min_duration then
            return false, string.format("Session too short (%ds < %ds)", duration_seconds, self.min_duration)
        end
        
        if pages_read <= 0 then
            return false, "No progress made"
        end
    end
    
    return true, "Session valid"
end

--[[--
Round progress to configured decimal places

@param value Progress value to round
@return number Rounded progress value
--]]
function BookloreSync:roundProgress(value)
    local multiplier = 10 ^ self.progress_decimal_places
    return math.floor(value * multiplier + 0.5) / multiplier
end

--[[--
Get current reading progress and location

Returns raw percentage with maximum precision.
Rounding is applied later during API sync based on config.

@return number progress (0-100) with maximum precision
@return string location (page number or position)
--]]
function BookloreSync:getCurrentProgress()
    if not self.ui or not self.ui.document then
        return 0, "0"
    end
    
    local progress = 0
    local location = "0"
    
    if self.ui.document.info and self.ui.document.info.has_pages then
        -- PDF or image-based format (PDF, CBZ, CBR, DJVU)
        local current_page = nil
        if self.view and self.view.state and self.view.state.page then
            current_page = self.view.state.page
        elseif self.ui.paging then
            current_page = self.ui.paging:getCurrentPage()
        end
        
        local total_pages = self.ui.document:getPageCount()
        
        if current_page and total_pages and total_pages > 0 then
            progress = (current_page / total_pages) * 100
            location = tostring(current_page)
        end
    elseif self.ui.rolling then
        local cur_page = self.ui.document:getCurrentPage()
        local total_pages = self.ui.document:getPageCount()
        if cur_page and total_pages and total_pages > 0 then
            progress = (cur_page / total_pages) * 100
            location = tostring(cur_page)
        end
    end
    
    return progress, location
end

--[[--
Get book type from file extension

@param file_path Path to the book file
@return string Book type (EPUB, PDF, etc.)
--]]
function BookloreSync:getBookType(file_path)
    if not file_path then
        return "EPUB"
    end
    
    local ext = file_path:match("^.+%.(.+)$")
    if ext then
        ext = ext:upper()
        if ext == "PDF" then
            return "PDF"
        elseif ext == "CBZ" or ext == "CBR" then
            return "CBX"
        end
    end
    
    return "EPUB"
end

--[[--
Calculate MD5 hash of a book file using sample-based fingerprinting

Uses the same algorithm as Booklore's FileFingerprint:
- Samples chunks at positions: base << (2*i) for i from -1 to 10
- Each chunk is 1024 bytes
- Concatenates all sampled chunks and calculates MD5 hash

@param file_path Path to the book file
@return string MD5 hash or nil on error
--]]
function BookloreSync:calculateBookHash(file_path)
    self:logInfo("BookloreSync: Calculating MD5 hash for:", file_path)
    
    local file = io.open(file_path, "rb")
    if not file then
        self:logWarn("BookloreSync: Could not open file for hashing")
        return nil
    end
    
    local md5 = require("ffi/sha2").md5
    local base = 1024
    local block_size = 1024
    local buffer = {}
    
    local file_size = file:seek("end")
    file:seek("set", 0)
    
    self:logInfo("BookloreSync: File size:", file_size)
    
    -- Sample file at specific positions (matching Booklore's FileFingerprint algorithm)
    for i = -1, 10 do
        local position = bit.lshift(base, 2 * i)
        
        if position >= file_size then
            break
        end
        
        file:seek("set", position)
        local chunk = file:read(block_size)
        if chunk then
            table.insert(buffer, chunk)
        end
    end
    
    file:close()
    
    -- Calculate MD5 of all sampled chunks
    local combined_data = table.concat(buffer)
    local hash = md5(combined_data)
    
    self:logInfo("BookloreSync: Hash calculated:", hash)
    return hash
end

--[[--
Look up book ID from server by file hash

Checks database cache first, then queries the server if not found.
Caches successful lookups in the database.

@param book_hash MD5 hash of the book file
@return number Book ID from server or nil if not found
--]]
function BookloreSync:getBookIdByHash(book_hash)
    if not book_hash then
        self:logWarn("BookloreSync: No book hash provided to getBookIdByHash")
        return nil, nil, nil
    end
    
    self:logInfo("BookloreSync: Looking up book ID for hash:", book_hash)
    
    local cached_book = self.db:getBookByHash(book_hash)
    if cached_book and cached_book.book_id then
        self:logInfo("BookloreSync: Found book ID in database cache:", cached_book.book_id)
        return cached_book.book_id, cached_book.isbn10, cached_book.isbn13
    end
    
    self:logInfo("BookloreSync: Book ID not in cache, querying server")
    
    local success, book_data = self.api:getBookByHash(book_hash)
    
    if not success then
        self:logWarn("BookloreSync: Failed to get book from server (offline or error)")
        return nil, nil, nil
    end
    
    if not book_data or not book_data.id then
        self:logInfo("BookloreSync: Book not found on server")
        return nil, nil, nil
    end
    
    local book_id = tonumber(book_data.id)
    if not book_id then
        self:logWarn("BookloreSync: Invalid book ID from server:", book_data.id)
        return nil, nil, nil
    end
    
    local isbn10 = book_data.isbn10 or nil
    local isbn13 = book_data.isbn13 or nil
    
    self:logInfo("BookloreSync: Found book ID on server:", book_id)
    self:logInfo("BookloreSync: Book data from server includes ISBN-10:", isbn10, "ISBN-13:", isbn13)
    
    if cached_book then
        self.db:saveBookCache(
            cached_book.file_path, 
            book_hash, 
            book_id, 
            book_data.title or cached_book.title, 
            book_data.author or cached_book.author,
            isbn10,
            isbn13
        )
        self:logInfo("BookloreSync: Updated database cache with book ID and ISBN")
    end
    
    return book_id, isbn10, isbn13
end

--[[--
Start tracking a reading session

Called when a document is opened
--]]
function BookloreSync:startSession()
    if not self.is_enabled then
        return
    end
    
    if not self.ui or not self.ui.document then
        self:logWarn("BookloreSync: No document available to start session")
        return
    end
    
    local file_path = self.ui.document.file
    if not file_path then
        self:logWarn("BookloreSync: No file path available")
        return
    end
    
    file_path = tostring(file_path)
    
    self:logInfo("BookloreSync: ========== Starting session ==========")
    self:logInfo("BookloreSync: File:", file_path)
    self:logInfo("BookloreSync: File path type:", type(file_path))
    self:logInfo("BookloreSync: File path length:", #file_path)
    
    self:logInfo("BookloreSync: Calling getBookByFilePath...")
    local ok, cached_book = pcall(function()
        return self.db:getBookByFilePath(file_path)
    end)
    
    if not ok then
        self:logErr("BookloreSync: Error in getBookByFilePath:", cached_book)
        self:logErr("  file_path:", file_path)
        return
    end
    
    self:logInfo("BookloreSync: getBookByFilePath completed")
    local file_hash = nil
    local book_id = nil
    
    if cached_book then
        self:logInfo("BookloreSync: Found book in cache - ID:", cached_book.book_id, "Hash:", cached_book.file_hash)
        file_hash = cached_book.file_hash
        book_id = cached_book.book_id and tonumber(cached_book.book_id) or nil
    else
        self:logInfo("BookloreSync: Book not in cache, calculating hash")
            file_hash = self:calculateBookHash(file_path)
        
        if not file_hash then
            self:logWarn("BookloreSync: Failed to calculate book hash, continuing without hash")
        else
            self:logInfo("BookloreSync: Hash calculated:", file_hash)
            
            local isbn10, isbn13
            if NetworkMgr:isConnected() then
                self:logInfo("BookloreSync: Network connected, looking up book on server")
                book_id, isbn10, isbn13 = self:getBookIdByHash(file_hash)
                
                if book_id then
                    self:logInfo("BookloreSync: Book ID found on server:", book_id)
                    if isbn10 or isbn13 then
                        self:logInfo("BookloreSync: Book has ISBN-10:", isbn10, "ISBN-13:", isbn13)
                    end
                else
                    self:logInfo("BookloreSync: Book not found on server (not in library)")
                end
            else
                self:logInfo("BookloreSync: No network connection, skipping server lookup")
                self:logInfo("BookloreSync: Book will be cached locally and resolved when online")
            end
            
            local ok, result = pcall(function()
                return self.db:saveBookCache(file_path, file_hash, book_id, nil, nil, isbn10, isbn13)
            end)
            
            if not ok then
                self:logErr("BookloreSync: Error in saveBookCache:", result)
                self:logErr("  file_path:", file_path)
                self:logErr("  file_hash:", file_hash)
                self:logErr("  book_id:", book_id)
            else
                if result then
                    self:logInfo("BookloreSync: Book cached in database successfully")
                else
                    self:logWarn("BookloreSync: Failed to cache book in database")
                end
            end
        end
    end
    
    local start_progress, start_location = self:getCurrentProgress()
    
    local koreader_book_id = nil
    local book_title = nil
    
    if file_hash then
        local koreader_book = self:_getKOReaderBookByHash(file_hash)
        if koreader_book then
            koreader_book_id = koreader_book.koreader_book_id
            book_title = koreader_book.koreader_book_title
            self:logInfo("BookloreSync: Found in KOReader stats - ID:", koreader_book_id, "Title:", book_title)
        end
    end
    
    if not book_title then
        book_title = file_path:match("([^/]+)$") or file_path
        book_title = book_title:gsub("%.[^.]+$", "")  -- Remove extension
        self:logInfo("BookloreSync: Using filename as title:", book_title)
    end
    
    self.current_session = {
        file_path = file_path,
        book_id = book_id,
        file_hash = file_hash,
        book_title = book_title,
        koreader_book_id = koreader_book_id,
        start_time = os.time(),
        start_progress = start_progress,
        start_location = start_location,
        book_type = self:getBookType(file_path),
    }
    
    self:logInfo("BookloreSync: Session started for '", book_title, "' at", start_progress, "% (location:", start_location, ")")
end

--[[--
End the current reading session and save to database

Called when document closes, device suspends, or returns to menu

@param options Table with options:
  - silent: Don't show UI messages
  - force_queue: Always queue instead of trying to sync
--]]
function BookloreSync:endSession(options)
    options = options or {}
    local silent = options.silent or false
    local force_queue = options.force_queue or self.manual_sync_only
    
    if not self.current_session then
        self:logInfo("BookloreSync: No active session to end")
        return
    end
    
    self:logInfo("BookloreSync: ========== Ending session ==========")
    
    local end_progress, end_location = self:getCurrentProgress()
    local end_time = os.time()
    local duration_seconds = end_time - self.current_session.start_time
    
    local pages_read = 0
    local start_loc = tonumber(self.current_session.start_location) or 0
    local end_loc = tonumber(end_location) or 0
    pages_read = math.abs(end_loc - start_loc)
    
    self:logInfo("BookloreSync: Duration:", duration_seconds, "s, Pages read:", pages_read)
    self:logInfo("BookloreSync: Progress:", self.current_session.start_progress, "% ->", end_progress, "%")
    
    local valid, reason = self:validateSession(duration_seconds, pages_read)
    if not valid then
        self:logInfo("BookloreSync: Session invalid -", reason)
        self.current_session = nil
        return
    end
    
    local progress_delta = end_progress - self.current_session.start_progress
    
    local function formatTimestamp(unix_time)
        return os.date("!%Y-%m-%dT%H:%M:%SZ", unix_time)
    end
    
    local session_data = {
        bookId = self.current_session.book_id,
        bookHash = self.current_session.file_hash,
        bookTitle = self.current_session.book_title,
        koreaderBookId = self.current_session.koreader_book_id,
        bookType = self.current_session.book_type,
        startTime = formatTimestamp(self.current_session.start_time),
        endTime = formatTimestamp(end_time),
        durationSeconds = duration_seconds,
        startProgress = self.current_session.start_progress,
        endProgress = end_progress,
        progressDelta = progress_delta,
        startLocation = self.current_session.start_location,
        endLocation = end_location,
    }
    
    self:logInfo("BookloreSync: Session valid - Duration:", duration_seconds, "s, Progress delta:", progress_delta, "%")
    
    local success = self.db:addPendingSession(session_data)
    
    if success then
        self:logInfo("BookloreSync: Session saved to pending queue")
        
        if not silent and not self.silent_messages then
            local pending_count = self.db:getPendingSessionCount()
            UIManager:show(InfoMessage:new{
                text = T(_("Session saved (%1 pending)"), tonumber(pending_count) or 0),
                timeout = 2,
            })
        end
        
        if not force_queue and not self.manual_sync_only then
            self:logInfo("BookloreSync: Attempting automatic sync")
            self:syncPendingSessions(true) -- silent sync
        end
    else
        self:logErr("BookloreSync: Failed to save session to database")
        if not silent then
            UIManager:show(InfoMessage:new{
                text = _("Failed to save reading session"),
                timeout = 2,
            })
        end
    end
    
    self.current_session = nil
end

-- Event Handlers

--[[--
Handler for when a document is opened and ready
--]]
function BookloreSync:onReaderReady()
    self:logInfo("BookloreSync: Reader ready")
    self:startSession()
    self:detectBookMetadataLocation()
    return false -- Allow other plugins to process this event
end

--[[--
Handler for when a document is closed
--]]
function BookloreSync:onCloseDocument()
    if not self.is_enabled then
        return false
    end

    self:logInfo("BookloreSync: Document closing")

    local pre_file_path = self.current_session and self.current_session.file_path
    local pre_book_id   = self.current_session and self.current_session.book_id
    local pre_end_progress = nil
    if self.current_session then
        pre_end_progress = self:getCurrentProgress()
    end

    -- Read the live in-memory KOReader star rating NOW, while the document is
    -- still open and self.ui.doc_settings is valid.  KOReader flushes doc_settings
    -- to the .sdr sidecar AFTER this event fires, so reading from disk here would
    -- always return a stale (or absent) value.
    local pre_live_rating = nil
    if self.ui and self.ui.doc_settings then
        local ok_r, summary = pcall(function()
            return self.ui.doc_settings:readSetting("summary")
        end)
        if ok_r and summary and summary.rating then
            pre_live_rating = tonumber(summary.rating)
            self:logInfo("BookloreSync: Captured live in-memory rating:", pre_live_rating)
        end
    end

    self:endSession({ silent = false, force_queue = false })

    if self.extended_sync_enabled and self.rating_sync_enabled and pre_file_path then
        local mode = self.rating_sync_mode or "koreader_scaled"
        if pre_book_id then
            -- Normal path: Booklore book ID is known, act immediately.
            if mode == "koreader_scaled" then
                -- Silent, immediate — pass the live in-memory rating so the stale
                -- on-disk sidecar is never consulted during this close event.
                self:syncKOReaderRating(pre_file_path, pre_book_id, pre_live_rating)
            elseif mode == "select_at_complete" then
                -- Only prompt when the book is considered finished (>= 99 %)
                if pre_end_progress and pre_end_progress >= 99 then
                    UIManager:scheduleIn(2, function()
                        self:showRatingDialog(pre_file_path, pre_book_id)
                    end)
                end
            end
        elseif pre_end_progress and pre_end_progress >= 99 then
            -- book_id not yet known (server was offline at open time).
            -- Store a deferred flag so the next sync run handles it once the
            -- book ID has been resolved.
            local book_cache_id = self.db:getBookCacheIdByFilePath(pre_file_path)
            if not book_cache_id then
                -- Create a minimal cache entry so we have somewhere to hang the flag
                self.db:saveBookCache(pre_file_path, "", nil, nil, nil, nil, nil)
                book_cache_id = self.db:getBookCacheIdByFilePath(pre_file_path)
            end
            if book_cache_id then
                self.db:setPendingRatingPrompt(book_cache_id, true)
                self:logInfo("BookloreSync: Book completed but no book_id yet — deferred rating prompt stored")
            end
            -- For select_at_complete: show the dialog immediately so the user
            -- can record their rating now.  The rating is stored locally and the
            -- pending_rating_prompt flag ensures it is pushed on the next sync
            -- once the book_id has been resolved.
            if mode == "select_at_complete" then
                local path_copy = pre_file_path
                UIManager:scheduleIn(2, function()
                    self:showRatingDialog(path_copy, nil)
                end)
            end
        end
    end

    -- Highlights & notes sync
    -- NOTE: self.ui.document is still open here (CloseDocument fires before closeDocument()).
    -- We pass it to syncHighlightsAndNotes so it can read EPUB internals for CFI generation.
    -- pre_book_id may be nil (server offline at open time); syncHighlightsAndNotes will
    -- still queue all annotations into pending_annotations so they are retried once the
    -- book_id is resolved.
    if self.extended_sync_enabled and self.highlights_notes_sync_enabled and pre_file_path then
        local strategy = self.upload_strategy or "on_session"
        local open_doc = self.ui and self.ui.document
        -- "On session": fire on every close
        if strategy == "on_session" then
            self:syncHighlightsAndNotes(pre_file_path, pre_book_id, open_doc)
        -- "On read complete": fire only when progress >= 99 %
        elseif strategy == "on_complete" and pre_end_progress and pre_end_progress >= 99 then
            self:syncHighlightsAndNotes(pre_file_path, pre_book_id, open_doc)
        end
    end

    return false
end

--[[--
Attempt to connect to network with timeout

This function tries to enable WiFi and wait for network connection.
Used when "Connect network on suspend" is enabled.

@return boolean true if connected, false otherwise
--]]
function BookloreSync:connectNetwork()
    local Device = require("device")
    
    if not Device:hasWifiToggle() then
        self:logWarn("BookloreSync: Device does not support WiFi toggle")
        return false
    end
    
    if Device.isOnline and Device:isOnline() then
        self:logInfo("BookloreSync: Network already connected")
        return true
    end
    
    self:logInfo("BookloreSync: Attempting to connect to network")
    
    if not Device:isConnected() then
        self:logInfo("BookloreSync: Enabling WiFi")
        Device:setWifiState(true)
    end
    
    local timeout = 15
    local elapsed = 0
    local check_interval = 0.5
    
    while elapsed < timeout do
        if Device.isOnline and Device:isOnline() then
            self:logInfo("BookloreSync: Network connected successfully after", elapsed, "seconds")
            return true
        end
        
        local ffiutil = require("ffi/util")
        ffiutil.sleep(check_interval)
        elapsed = elapsed + check_interval
    end
    
    self:logWarn("BookloreSync: Network connection timeout after", timeout, "seconds")
    return false
end

--[[--
Handler for when the device is about to suspend
--]]
function BookloreSync:onSuspend()
    if not self.is_enabled then
        return false
    end
    
    self:logInfo("BookloreSync: Device suspending")
    
    self:endSession({ silent = true, force_queue = true })
    
    if self.force_push_session_on_suspend then
        self:logInfo("BookloreSync: Force push on suspend enabled")
        
        if self.connect_network_on_suspend then
            self:logInfo("BookloreSync: Attempting to connect to network before sync")
            local network_ok = self:connectNetwork()
            
            if not network_ok then
                self:logWarn("BookloreSync: Network connection failed, will attempt sync anyway")
            end
        end
        
        self:logInfo("BookloreSync: Force syncing pending sessions on suspend")
        self:syncPendingSessions(true)
    else
        self:logInfo("BookloreSync: Force push on suspend disabled, sessions will sync on resume")
    end
    
    return false
end

--[[--
Handler for when the device resumes from suspend
--]]
function BookloreSync:onResume()
    if not self.is_enabled then
        return false
    end
    
    self:logInfo("BookloreSync: Device resuming")
    
    if not self.manual_sync_only then
        self:logInfo("BookloreSync: Attempting background sync on resume")
        self:syncPendingSessions(true)
        
        if NetworkMgr:isConnected() then
            self:logInfo("BookloreSync: Network available, checking for unmatched books")
            self:resolveUnmatchedBooks(true) -- silent mode
        end
    end
    
    if self.ui and self.ui.document then
        self:logInfo("BookloreSync: Book is open, starting new session")
        self:startSession()
    end
    
    return false
end

--[[--
Retry all ratings that are sitting in the pending_ratings queue, and
process any deferred rating prompts whose book_id has now been resolved.

Called automatically at the start of every syncPendingSessions() run so
that a failed or deferred rating is uploaded on the very next successful
connection, regardless of whether the trigger was a session, a note, or
an explicit sync.

@param silent boolean  Suppress UI feedback (default false)
@return integer synced_count, integer failed_count
--]]
function BookloreSync:syncPendingRatings(silent)
    silent = silent or false

    if not self.db then
        self:logErr("BookloreSync: syncPendingRatings — database not initialised")
        return 0, 0
    end

    -- Respect the user's rating-sync toggle: if they disabled rating sync
    -- after queueing ratings, do not submit anything.
    if not self.extended_sync_enabled or not self.rating_sync_enabled then
        self:logInfo("BookloreSync: Rating sync disabled — skipping pending ratings")
        return 0, 0
    end

    -- ── Phase 1: deferred rating prompts ─────────────────────────────────
    -- These are books that were completed while the book_id was unknown.
    -- Now that the cache may have been updated, check if a book_id exists.
    local deferred = self.db:getBooksPendingRatingPrompt()
    if #deferred > 0 then
        self:logInfo("BookloreSync: Processing", #deferred, "deferred rating prompt(s)")
        local mode = self.rating_sync_mode or "koreader_scaled"
        for _, row in ipairs(deferred) do
            self:logInfo("BookloreSync: Deferred rating prompt — book_id:", row.book_id,
                         "file:", row.file_path)
            if mode == "koreader_scaled" then
                -- Push the KOReader star rating silently now that we have a book_id.
                -- syncKOReaderRating will either sync successfully, queue the rating
                -- in pending_ratings on failure, or return early (no rating set /
                -- already synced / no credentials).  Only clear the deferred flag
                -- if we actually had credentials to attempt the call — otherwise
                -- leave the flag so the next sync retries.
                if self.booklore_username ~= "" and self.booklore_password ~= "" then
                    self:syncKOReaderRating(row.file_path, row.book_id)
                    -- Flag cleared below: rating was either sent or queued for retry
                    -- in pending_ratings, so the deferred-prompt entry is no longer needed.
                    self.db:setPendingRatingPrompt(row.book_cache_id, false)
                else
                    self:logWarn("BookloreSync: Deferred rating skipped — Booklore credentials not configured")
                    -- Leave flag set; will retry on the next sync once credentials are added.
                end
            elseif mode == "select_at_complete" then
                -- If the user already submitted a rating via the immediate dialog
                -- (shown at book-close time), it is now sitting in pending_ratings
                -- with a nil book_id.  Now that we have the real book_id, update
                -- the pending row so Phase 2 can upload it without re-prompting.
                local meta = self.db:getBookMetadata(row.book_cache_id)
                if meta and meta.rating then
                    -- Rating already captured — just stamp the resolved book_id
                    -- onto the pending_ratings row and clear the deferred flag.
                    self.db:addPendingRating(row.book_cache_id, row.book_id, meta.rating)
                    self.db:setPendingRatingPrompt(row.book_cache_id, false)
                    self:logInfo("BookloreSync: Stamped book_id", row.book_id,
                                 "onto pending rating for book_cache_id:", row.book_cache_id)
                else
                    -- No rating stored yet — show the dialog now that we have a book_id.
                    -- Clear the flag before scheduling so the dialog is not re-shown
                    -- on subsequent syncs.
                    local file_path = row.file_path
                    local book_id   = row.book_id
                    self.db:setPendingRatingPrompt(row.book_cache_id, false)
                    UIManager:scheduleIn(2, function()
                        self:showRatingDialog(file_path, book_id)
                    end)
                end
            end
        end
    end

    -- ── Phase 2: retry previously-failed rating submissions ──────────────
    local pending = self.db:getPendingRatings()
    if #pending == 0 then
        self:logInfo("BookloreSync: No pending ratings to sync")
        return 0, 0
    end

    self:logInfo("BookloreSync: Retrying", #pending, "pending rating(s)")

    self.api:init(self.server_url, self.username, self.password, self.db, self.secure_logs)

    local synced_count = 0
    local failed_count = 0

    for _, row in ipairs(pending) do
        self:logInfo("BookloreSync: Submitting pending rating — book_id:", row.book_id,
                     "rating:", row.rating, "(retry #" .. (row.retry_count + 1) .. ")")

        -- Resolve book_id if it was nil when the rating was first queued.
        local book_id = row.book_id
        if not book_id then
            local bc = self.db:getBookCacheById(row.book_cache_id)
            book_id = bc and bc.book_id or nil
            if not book_id then
                self:logInfo("BookloreSync: book_id still unknown for pending rating id:", row.id, "— will retry later")
                goto continue_rating
            end
            self:logInfo("BookloreSync: Resolved book_id", book_id, "for pending rating id:", row.id)
        end

        local ok, err = self.api:submitRating(
            book_id, row.rating,
            self.booklore_username, self.booklore_password
        )

        if ok then
            synced_count = synced_count + 1
            -- Mark rating as synced in book_metadata and record the outcome
            self.db:upsertBookMetadata(row.book_cache_id, { rating = row.rating, rating_synced = true })
            self.db:recordRatingSyncHistory(row.book_cache_id, row.rating, "success")
            -- Remove from the pending queue
            self.db:deletePendingRating(row.id)
            self:logInfo("BookloreSync: Pending rating synced successfully (id:", row.id, ")")
        else
            failed_count = failed_count + 1
            self:logWarn("BookloreSync: Pending rating sync failed (id:", row.id, "):", err)
            self.db:recordRatingSyncHistory(row.book_cache_id, row.rating, "error", err)
            self.db:incrementPendingRatingRetryCount(row.id)
        end

        ::continue_rating::
    end

    self:logInfo("BookloreSync: Pending ratings sync complete — synced:", synced_count, "failed:", failed_count)
    return synced_count, failed_count
end

--[[--
Retry all annotations that previously failed to upload.

Reads every row from `pending_annotations`, attempts to re-submit each one
using the stored JSON payload, and removes successfully-uploaded rows.
Rows that fail again have their retry_count incremented and remain queued.

This is called automatically at the start of every syncPendingSessions() run
and can also be triggered directly (e.g. from a manual sync button).

Note: CFI-dependent annotations (highlights and in-book notes) require a
CFI string in the payload.  If the stored payload contains pos0/pos1 fields
but no pre-computed CFI, this path cannot rebuild the CFI because the EPUB
document is no longer open.  Those rows will remain pending until the book is
opened again and syncHighlightsAndNotes() succeeds.

@param silent boolean  If true, do not show UI messages
@return integer synced_count
@return integer failed_count
--]]
function BookloreSync:syncPendingAnnotations(silent)
    silent = silent or false

    if not self.db then
        self:logErr("BookloreSync: syncPendingAnnotations — database not initialised")
        return 0, 0
    end

    if not self.highlights_notes_sync_enabled then
        self:logInfo("BookloreSync: Annotation sync disabled — skipping pending annotations")
        return 0, 0
    end

    if self.booklore_username == "" or self.booklore_password == "" then
        self:logInfo("BookloreSync: Pending annotations skipped — Booklore credentials not configured")
        return 0, 0
    end

    local pending = self.db:getPendingAnnotations()
    if #pending == 0 then
        self:logInfo("BookloreSync: No pending annotations to sync")
        return 0, 0
    end

    self:logInfo("BookloreSync: Retrying", #pending, "pending annotation(s)")

    self.api:init(self.server_url, self.username, self.password, self.db, self.secure_logs)

    local synced_count = 0
    local failed_count = 0

    for _, row in ipairs(pending) do
        self:logInfo("BookloreSync: Retrying pending annotation — id:", row.id,
                     "type:", row.ann_type, "datetime:", row.datetime,
                     "(retry #" .. (row.retry_count + 1) .. ")")

        local ok_dec, payload = pcall(json.decode, row.payload)
        if not ok_dec or type(payload) ~= "table" then
            self:logErr("BookloreSync: Failed to decode pending annotation payload (id:", row.id, ") — removing")
            self.db:deletePendingAnnotation(row.id)
            goto continue_ann
        end

        local book_id = row.book_id
        if not book_id then
            local bc = self.db:getBookCacheById(row.book_cache_id)
            book_id = bc and bc.book_id or nil
            if not book_id then
                self:logInfo("BookloreSync: book_id still unknown for pending annotation id:", row.id, "— will retry later")
                goto continue_ann
            end
            self:logInfo("BookloreSync: Resolved book_id", book_id, "for pending annotation id:", row.id)
        end

        local ok, server_id

        if row.ann_type == "highlight" then
            -- Highlights require a CFI.  Without an open document we cannot
            -- recompute it from pos0/pos1, so skip if the payload has no cfi.
            -- (When the book is opened next time syncHighlightsAndNotes will
            -- pick it up fresh and the pending row will be superseded.)
            local cfi = payload.cfi
            if not cfi or cfi == "" then
                self:logInfo("BookloreSync: Skipping pending highlight (no CFI available) — id:", row.id)
                goto continue_ann
            end
            ok, server_id = self.api:submitHighlight(
                book_id, cfi, payload.text,
                {
                    color         = payload.color,
                    style         = payload.style,
                    chapter_title = payload.chapter,
                },
                self.booklore_username, self.booklore_password
            )

        elseif row.ann_type == "in_book_note" then
            local cfi = payload.cfi
            if not cfi or cfi == "" then
                self:logInfo("BookloreSync: Skipping pending in-book note (no CFI available) — id:", row.id)
                goto continue_ann
            end
            ok, server_id = self.api:submitInBookNote(
                book_id, cfi, payload.note,
                {
                    selected_text = payload.text,
                    color         = payload.color,
                    chapter_title = payload.chapter,
                },
                self.booklore_username, self.booklore_password
            )

        elseif row.ann_type == "booklore_note" then
            ok, server_id = self.api:submitBookloreNote(
                book_id, payload.note, payload.chapter,
                self.booklore_username, self.booklore_password
            )

        else
            self:logWarn("BookloreSync: Unknown ann_type in pending_annotations (id:", row.id, "):", row.ann_type, "— removing")
            self.db:deletePendingAnnotation(row.id)
            goto continue_ann
        end

        if ok then
            synced_count = synced_count + 1
            -- Record as synced so syncHighlightsAndNotes skips it in future
            self.db:markAnnotationSynced(row.book_cache_id, row.datetime, row.ann_type, server_id)
            self.db:deletePendingAnnotation(row.id)
            self:logInfo("BookloreSync: Pending annotation synced (id:", row.id, ")")
        else
            failed_count = failed_count + 1
            self:logWarn("BookloreSync: Pending annotation retry failed (id:", row.id, "):", server_id)
            self.db:incrementPendingAnnotationRetryCount(row.id)
        end

        ::continue_ann::
    end

    self:logInfo("BookloreSync: Pending annotations sync complete — synced:", synced_count, "failed:", failed_count)
    return synced_count, failed_count
end

--[[--
Show a toggle-selection dialog for clearing pending items.

Presents three toggleable rows (Sessions, Annotations, Ratings), each
showing its current queue count.  After the user confirms, all selected
types are deleted from the database and a summary InfoMessage is shown.
--]]
function BookloreSync:showClearPendingDialog()
    if not self.db then return end

    local s_count = tonumber(self.db:getPendingSessionCount())    or 0
    local a_count = tonumber(self.db:getPendingAnnotationCount()) or 0
    local r_count = tonumber(self.db:getPendingRatingCount())     or 0

    local sel = {
        sessions    = s_count > 0,
        annotations = a_count > 0,
        ratings     = r_count > 0,
    }

    local dialog
    local function buildDialog()
        local function toggle_label(active, label, count)
            local check = active and "[x]" or "[ ]"
            return T(_("%1 %2 (%3)"), check, label, count)
        end

        local any_selected = sel.sessions or sel.annotations or sel.ratings

        local buttons = {}

        if s_count > 0 then
            table.insert(buttons, {{
                text = toggle_label(sel.sessions, _("Sessions"), s_count),
                callback = function()
                    sel.sessions = not sel.sessions
                    UIManager:close(dialog)
                    dialog = buildDialog()
                    UIManager:show(dialog)
                end,
            }})
        end

        if a_count > 0 then
            table.insert(buttons, {{
                text = toggle_label(sel.annotations, _("Annotations"), a_count),
                callback = function()
                    sel.annotations = not sel.annotations
                    UIManager:close(dialog)
                    dialog = buildDialog()
                    UIManager:show(dialog)
                end,
            }})
        end

        if r_count > 0 then
            table.insert(buttons, {{
                text = toggle_label(sel.ratings, _("Ratings"), r_count),
                callback = function()
                    sel.ratings = not sel.ratings
                    UIManager:close(dialog)
                    dialog = buildDialog()
                    UIManager:show(dialog)
                end,
            }})
        end

        table.insert(buttons, {
            {
                text = _("Clear Selected"),
                enabled = any_selected,
                callback = function()
                    UIManager:close(dialog)
                    local cleared = {}
                    if sel.sessions    then self.db:clearPendingSessions();    table.insert(cleared, _("Sessions"))    end
                    if sel.annotations then self.db:clearPendingAnnotations(); table.insert(cleared, _("Annotations")) end
                    if sel.ratings     then self.db:clearPendingRatings();     table.insert(cleared, _("Ratings"))     end
                    if #cleared > 0 then
                        UIManager:show(InfoMessage:new{
                            text = T(_("Cleared: %1"), table.concat(cleared, ", ")),
                            timeout = 2,
                        })
                    end
                end,
            },
            {
                text = _("Cancel"),
                callback = function()
                    UIManager:close(dialog)
                end,
            },
        })

        return ButtonDialog:new{
            title = _("Clear Pending Items"),
            buttons = buttons,
        }
    end

    dialog = buildDialog()
    UIManager:show(dialog)
end

function BookloreSync:syncPendingSessions(silent)
    silent = silent or false

    if not self.db then
        self:logErr("BookloreSync: Database not initialized")
        if not silent then
            UIManager:show(InfoMessage:new{
                text = _("Database not initialized"),
                timeout = 2,
            })
        end
        return
    end

    local ratings_synced, ratings_failed = self:syncPendingRatings(true)
    ratings_synced = tonumber(ratings_synced) or 0
    ratings_failed = tonumber(ratings_failed) or 0

    local ann_synced, ann_failed = self:syncPendingAnnotations(true)
    ann_synced = tonumber(ann_synced) or 0
    ann_failed = tonumber(ann_failed) or 0

    local pending_count = self.db:getPendingSessionCount()
    pending_count = tonumber(pending_count) or 0

    if pending_count == 0 then
        self:logInfo("BookloreSync: No pending sessions to sync")
        if not silent then
            local parts = {}
            if ratings_synced + ratings_failed > 0 then
                parts[#parts + 1] = T(_("R: %1 synced"), ratings_synced)
                if ratings_failed > 0 then
                    parts[#parts + 1] = T(_("%1 failed"), ratings_failed)
                end
            end
            if ann_synced + ann_failed > 0 then
                parts[#parts + 1] = T(_("A: %1 synced"), ann_synced)
                if ann_failed > 0 then
                    parts[#parts + 1] = T(_("%1 failed"), ann_failed)
                end
            end
            local msg
            if #parts > 0 then
                msg = table.concat(parts, "\n") .. "\n" .. _("S: none pending.")
            else
                msg = _("No pending items to sync")
            end
            UIManager:show(InfoMessage:new{
                text = msg,
                timeout = 2,
            })
        end
        return
    end
    
    self:logInfo("BookloreSync: Starting sync of", pending_count, "pending sessions")
    
    if not silent then
        UIManager:show(InfoMessage:new{
            text = T(_("Syncing %1 pending S..."), pending_count),
            timeout = 2,
        })
    end
    
    self.api:init(self.server_url, self.username, self.password, self.db, self.secure_logs)
    
    local sessions = self.db:getPendingSessions(100)
    
    local synced_count = 0
    local failed_count = 0
    local resolved_count = 0
    
    for i, session in ipairs(sessions) do
        self:logInfo("BookloreSync: Processing pending session", i, "of", #sessions)
        
        if session.bookHash and not session.bookId then
            self:logInfo("BookloreSync: Attempting to resolve book ID for hash:", session.bookHash)
            
            local cached_book = self.db:getBookByHash(session.bookHash)
            if cached_book and cached_book.book_id then
                session.bookId = cached_book.book_id
                self:logInfo("BookloreSync: Resolved book ID from cache:", session.bookId)
                resolved_count = resolved_count + 1
            else
                local success, book_data = self.api:getBookByHash(session.bookHash)
                if success and book_data and book_data.id then
                    local book_id = tonumber(book_data.id)
                    if book_id then
                        session.bookId = book_id
                        -- Cache the result
                        self.db:updateBookId(session.bookHash, book_id)
                        self:logInfo("BookloreSync: Resolved book ID from server:", book_id)
                        resolved_count = resolved_count + 1
                    else
                        self:logWarn("BookloreSync: Invalid book ID from server:", book_data.id)
                        self.db:incrementSessionRetryCount(session.id)
                        failed_count = failed_count + 1
                        goto continue
                    end
                else
                    self:logWarn("BookloreSync: Failed to resolve book ID, will retry later")
                    -- Increment retry count and skip this session
                    self.db:incrementSessionRetryCount(session.id)
                    failed_count = failed_count + 1
                    goto continue
                end
            end
        end
        
        if not session.bookId then
            self:logWarn("BookloreSync: Session", i, "has no book ID, skipping")
            self.db:incrementSessionRetryCount(session.id)
            failed_count = failed_count + 1
            goto continue
        end
        
        local duration_formatted = self:formatDuration(session.durationSeconds)
        
        local session_data = {
            bookId = session.bookId,
            bookType = session.bookType,
            startTime = session.startTime,
            endTime = session.endTime,
            durationSeconds = session.durationSeconds,
            durationFormatted = duration_formatted,
            startProgress = self:roundProgress(session.startProgress),
            endProgress = self:roundProgress(session.endProgress),
            progressDelta = self:roundProgress(session.progressDelta),
            startLocation = session.startLocation,
            endLocation = session.endLocation,
        }
        
        self:logInfo("BookloreSync: Submitting session", i, "- Book ID:", session.bookId, 
                    "Duration:", duration_formatted)
        
        local success, message = self.api:submitSession(session_data)
        
        if success then
            synced_count = synced_count + 1
            local archived = self.db:archivePendingSession(session.id)
            if not archived then
                self:logWarn("BookloreSync: Failed to archive session", i, "to historical_sessions")
            end
            self.db:deletePendingSession(session.id)
            self:logInfo("BookloreSync: Session", i, "synced successfully")
        else
            failed_count = failed_count + 1
            self:logWarn("BookloreSync: Session", i, "failed to sync:", message)
            self.db:incrementSessionRetryCount(session.id)
        end
        
        ::continue::
    end
    
    self:logInfo("BookloreSync: Sync complete - synced:", synced_count, 
                "failed:", failed_count, "resolved:", resolved_count)
    
    if not silent then
        local parts = {}
        if synced_count > 0 and failed_count > 0 then
            parts[#parts + 1] = T(_("S: %1 synced, %2 failed"), synced_count, failed_count)
        elseif synced_count > 0 then
            parts[#parts + 1] = T(_("S: %1 synced"), synced_count)
        else
            parts[#parts + 1] = _("S: all failed — check connection")
        end
        if ratings_synced + ratings_failed > 0 then
            if ratings_failed > 0 then
                parts[#parts + 1] = T(_("R: %1 synced, %2 failed"), ratings_synced, ratings_failed)
            else
                parts[#parts + 1] = T(_("R: %1 synced"), ratings_synced)
            end
        end
        if ann_synced + ann_failed > 0 then
            if ann_failed > 0 then
                parts[#parts + 1] = T(_("A: %1 synced, %2 failed"), ann_synced, ann_failed)
            else
                parts[#parts + 1] = T(_("A: %1 synced"), ann_synced)
            end
        end
        UIManager:show(InfoMessage:new{
            text = table.concat(parts, "\n"),
            timeout = 3,
        })
    end
    
    return synced_count, failed_count
end

--[[--
Manual matching flow for book_cache entries with no book_id.

Iterates over every unmatched book_cache row and, for each one, tries:
  1. Title search on the server → user picks from results
  2. User can skip a book

On a confirmed match the book_id is written back into book_cache so that
subsequent syncPendingAnnotations / syncPendingRatings / syncPendingSessions
runs can resolve and upload the queued items automatically.
--]]

function BookloreSync:_startBookCacheMatching()
    if not self.db then return end
    local unmatched = self.db:getAllUnmatchedBooks()
    if not unmatched or #unmatched == 0 then
        UIManager:show(InfoMessage:new{
            text = _("All books are already matched"),
            timeout = 2,
        })
        return
    end
    self:logInfo("BookloreSync: Starting manual book-cache matching for", #unmatched, "books")
    self.bk_matching_index = 1
    self.bk_unmatched_books = unmatched
    self:_showNextBookCacheMatch()
end

function BookloreSync:_showNextBookCacheMatch()
    if not self.bk_unmatched_books or
       self.bk_matching_index > #self.bk_unmatched_books then
        UIManager:show(InfoMessage:new{
            text = _("Matching complete!"),
            timeout = 2,
        })
        self.bk_unmatched_books = nil
        self.bk_matching_index  = nil
        return
    end

    local book        = self.bk_unmatched_books[self.bk_matching_index]
    local progress    = T(_("Book %1 of %2"),
                          self.bk_matching_index, #self.bk_unmatched_books)
    local search_term = book.title and book.title ~= "" and book.title
                        or book.file_path:match("([^/]+)$") or ""

    UIManager:show(InfoMessage:new{
        text = T(_("Searching for: %1\n\n%2"), search_term, progress),
        timeout = 1,
    })

    local success, results = self.api:searchBooksWithAuth(
        search_term, self.booklore_username, self.booklore_password
    )

    if not success then
        local err = type(results) == "string" and results or _("Unknown error")
        UIManager:show(ConfirmBox:new{
            text = T(_("Search failed for:\n%1\n\nError: %2\n\nSkip this book?"),
                     search_term, err),
            ok_text     = _("Skip"),
            cancel_text = _("Retry"),
            ok_callback = function()
                self.bk_matching_index = self.bk_matching_index + 1
                self:_showNextBookCacheMatch()
            end,
            cancel_callback = function()
                self:_showNextBookCacheMatch()
            end,
        })
        return
    end

    if not results or #results == 0 then
        UIManager:show(ConfirmBox:new{
            text = T(_("No matches found for:\n%1\n\n%2\n\nSkip this book?"),
                     search_term, progress),
            ok_text = _("Skip"),
            ok_callback = function()
                self.bk_matching_index = self.bk_matching_index + 1
                self:_showNextBookCacheMatch()
            end,
            cancel_callback = function()
                self:_showNextBookCacheMatch()
            end,
        })
        return
    end

    -- Show selection dialog
    local top_results = {}
    for i = 1, math.min(5, #results) do
        top_results[i] = results[i]
    end

    local buttons = {}
    for i, result in ipairs(top_results) do
        local score = result.matchScore
            and string.format(" (%.0f%%)", result.matchScore * 100)
            or ""
        local label = result.title .. score
        if result.author and result.author ~= "" then
            label = label .. "\n" .. result.author
        end
        table.insert(buttons, {{
            text = label,
            callback = function()
                UIManager:close(self.bk_match_dialog)
                self:_saveBookCacheMatch(book, result)
            end,
        }})
    end
    table.insert(buttons, {{
        text = _("Skip this book"),
        callback = function()
            UIManager:close(self.bk_match_dialog)
            self.bk_matching_index = self.bk_matching_index + 1
            self:_showNextBookCacheMatch()
        end,
    }})
    table.insert(buttons, {{
        text = _("Cancel matching"),
        callback = function()
            UIManager:close(self.bk_match_dialog)
            self.bk_unmatched_books = nil
            self.bk_matching_index  = nil
        end,
    }})

    self.bk_match_dialog = ButtonDialog:new{
        title = T(_("Select match for:\n%1\n\n%2"), search_term, progress),
        buttons = buttons,
    }
    UIManager:show(self.bk_match_dialog)
end

--[[--
Save a manually confirmed book_cache match and trigger a pending-items sync.

Writes the resolved book_id (and ISBNs) back into book_cache, then kicks off
syncPendingSessions so that any annotations / ratings / sessions that were
queued while the book was unmatched are uploaded immediately.
--]]
function BookloreSync:_saveBookCacheMatch(book, selected_result)
    local book_id    = type(selected_result) == "table"
                       and tonumber(selected_result.id) or tonumber(selected_result)
    local book_title = type(selected_result) == "table" and selected_result.title or nil
    local isbn10     = type(selected_result) == "table" and selected_result.isbn10 or nil
    local isbn13     = type(selected_result) == "table" and selected_result.isbn13 or nil

    if not book_id then
        UIManager:show(InfoMessage:new{
            text = _("Invalid book ID — match not saved"),
            timeout = 2,
        })
        return
    end

    -- Stamp book_id (and optional ISBNs) into book_cache
    local ok = self.db:saveBookCache(
        book.file_path, book.file_hash or "",
        book_id, book_title or book.title, book.author,
        isbn10, isbn13
    )

    if not ok then
        UIManager:show(InfoMessage:new{
            text = _("Failed to save match to database"),
            timeout = 2,
        })
        return
    end

    self:logInfo("BookloreSync: Saved manual match — file:", book.file_path,
                 "book_id:", book_id)

    -- Advance to the next unmatched book
    self.bk_matching_index = self.bk_matching_index + 1

    -- Kick off a sync so pending annotations/ratings/sessions for this book
    -- are uploaded right away.  Run silently so the UI just shows the next
    -- book-match dialog without interruption.
    self:syncPendingSessions(true)

    -- Show the next match
    self:_showNextBookCacheMatch()
end

--[[--
Resolve book IDs for cached books that don't have them yet
Queries the server for books cached while offline
@param silent boolean Don't show UI messages if true
--]]
function BookloreSync:resolveUnmatchedBooks(silent)
    silent = silent or false
    
    if not self.db then
        self:logErr("BookloreSync: Database not initialized")
        return
    end
    
    if not NetworkMgr:isConnected() then
        self:logInfo("BookloreSync: No network connection, skipping book resolution")
        return
    end
    
    local unmatched_books = self.db:getAllUnmatchedBooks()
    
    if #unmatched_books == 0 then
        self:logInfo("BookloreSync: No unmatched books to resolve")
        return
    end
    
    self:logInfo("BookloreSync: Resolving", #unmatched_books, "unmatched books")
    
    self.api:init(self.server_url, self.username, self.password, self.db, self.secure_logs)
    
    local resolved_count = 0
    
    for _, book in ipairs(unmatched_books) do
        if book.file_hash and book.file_hash ~= "" then
            self:logInfo("BookloreSync: Resolving book:", book.file_path)
            
            local book_id, isbn10, isbn13 = self:getBookIdByHash(book.file_hash)
            
            if book_id then
                self:logInfo("BookloreSync: Resolved book ID:", book_id)
                self.db:saveBookCache(
                    book.file_path,
                    book.file_hash,
                    book_id,
                    book.title,
                    book.author,
                    isbn10,
                    isbn13
                )
                resolved_count = resolved_count + 1
            else
                self:logInfo("BookloreSync: Book not found on server")
            end
        end
    end
    
    self:logInfo("BookloreSync: Resolved", resolved_count, "of", #unmatched_books, "books")
    
    if not silent and resolved_count > 0 then
        UIManager:show(InfoMessage:new{
            text = T(_("Resolved %1 books from server"), resolved_count),
            timeout = 2,
        })
    end
    
    return resolved_count
end

function BookloreSync:copySessionsFromKOReader()
    -- Check if already run
    if self.db:hasHistoricalSessions() then
        UIManager:show(ConfirmBox:new{
            text = _("Historical sessions already extracted. Re-running will add duplicate sessions. Continue?"),
            ok_text = _("Continue"),
            cancel_text = _("Cancel"),
            ok_callback = function()
                self:_extractHistoricalSessions()
            end,
        })
        return
    end
    
    -- Show initial warning
    UIManager:show(ConfirmBox:new{
        text = _("This will extract reading sessions from KOReader's statistics database.\n\nThis should only be done once to avoid duplicates.\n\nContinue?"),
        ok_text = _("Extract Sessions"),
        cancel_text = _("Cancel"),
        ok_callback = function()
            self:_extractHistoricalSessions()
        end,
    })
end

function BookloreSync:_extractHistoricalSessions()
    UIManager:show(InfoMessage:new{
        text = _("Extracting sessions from KOReader database..."),
        timeout = 1,
    })
    
    local stats_db_path = self:_findKOReaderStatisticsDB()
    if not stats_db_path then
        UIManager:show(InfoMessage:new{
            text = _("KOReader statistics database not found"),
            timeout = 3,
        })
        return
    end
    
    self:logInfo("BookloreSync: Found statistics database at:", stats_db_path)
    
    local SQ3 = require("lua-ljsqlite3/init")
    local stats_conn = SQ3.open(stats_db_path)
    if not stats_conn then
        UIManager:show(InfoMessage:new{
            text = _("Failed to open statistics database"),
            timeout = 3,
        })
        return
    end
    
    local books = self:_getKOReaderBooks(stats_conn)
    self:logInfo("BookloreSync: Found", #books, "books in statistics")
    
    local all_sessions = {}
    local books_with_sessions = 0
    
    for i, book in ipairs(books) do
        local page_stats = self:_getPageStats(stats_conn, book.id)
        
        if #page_stats > 0 then
            local sessions = self:_calculateSessionsFromPageStats(page_stats, book)
            
            -- Filter out 0% progress sessions
            local valid_sessions = {}
            for _, session in ipairs(sessions) do
                if session.progress_delta > 0 then
                    table.insert(valid_sessions, session)
                end
            end
            
            if #valid_sessions > 0 then
                for _, session in ipairs(valid_sessions) do
                    table.insert(all_sessions, session)
                end
                books_with_sessions = books_with_sessions + 1
            end
        end
    end
    
    stats_conn:close()
    
    if #all_sessions > 0 then
        local success = self.db:addHistoricalSessions(all_sessions)
        
        if success then
            UIManager:show(InfoMessage:new{
                text = T(_("Found %1 reading sessions from %2 books\n\nStored in database"), 
                         #all_sessions, books_with_sessions),
                timeout = 4,
            })
        else
            UIManager:show(InfoMessage:new{
                text = _("Failed to store sessions in database"),
                timeout = 3,
            })
        end
    else
        UIManager:show(InfoMessage:new{
            text = _("No reading sessions found in KOReader database"),
            timeout = 3,
        })
    end
end

function BookloreSync:_calculateSessionsFromPageStats(page_stats, book)
    -- Implements 5-minute gap logic to group page reads into sessions
    -- Based on bookloresessionmigration.py lines 61-131
    if not page_stats or #page_stats == 0 then
        return {}
    end
    
    local sessions = {}
    local current_session = nil
    local SESSION_GAP_SECONDS = 300  -- 5 minutes
    
    for _, stat in ipairs(page_stats) do
        local timestamp_str = tostring(stat.start_time):gsub("LL$", "")
        local timestamp = tonumber(timestamp_str)
        if not timestamp then
            self:logWarn("BookloreSync: Failed to parse timestamp:", stat.start_time)
            goto continue
        end
        
        local iso_time = self:_unixToISO8601(timestamp)
        
        local progress = (stat.total_pages and stat.total_pages > 0) 
            and ((stat.page / stat.total_pages) * 100) or 0
        
        if not current_session then
            current_session = {
                start_time = iso_time,
                end_time = iso_time,
                start_timestamp = timestamp,
                end_timestamp = timestamp,
                start_progress = progress,
                end_progress = progress,
                start_page = stat.page,
                end_page = stat.page,
                duration_seconds = stat.duration or 0,
            }
        else
            local gap = timestamp - current_session.end_timestamp
            
            if gap > SESSION_GAP_SECONDS then
                -- Save current session if progress increased
                local start_progress = current_session.start_progress or 0
                local end_progress = current_session.end_progress or 0
                local progress_delta = end_progress - start_progress
                if progress_delta > 0 then
                    table.insert(sessions, {
                        start_time = current_session.start_time,
                        end_time = current_session.end_time,
                        duration_seconds = current_session.duration_seconds,
                        start_progress = current_session.start_progress,
                        end_progress = current_session.end_progress,
                        progress_delta = progress_delta,
                        start_location = tostring(current_session.start_page),
                        end_location = tostring(current_session.end_page),
                    })
                end
                
                -- Start new session
                current_session = {
                    start_time = iso_time,
                    end_time = iso_time,
                    start_timestamp = timestamp,
                    end_timestamp = timestamp,
                    start_progress = progress,
                    end_progress = progress,
                    start_page = stat.page,
                    end_page = stat.page,
                    duration_seconds = stat.duration or 0,
                }
            else
                current_session.end_time = iso_time
                current_session.end_timestamp = timestamp
                current_session.end_progress = progress
                current_session.end_page = stat.page
                current_session.duration_seconds = current_session.duration_seconds + (stat.duration or 0)
            end
        end
        
        ::continue::
    end
    
    if current_session then
        local start_progress = current_session.start_progress or 0
        local end_progress = current_session.end_progress or 0
        local progress_delta = end_progress - start_progress
        if progress_delta > 0 then
            table.insert(sessions, {
                start_time = current_session.start_time,
                end_time = current_session.end_time,
                duration_seconds = current_session.duration_seconds,
                start_progress = current_session.start_progress,
                end_progress = current_session.end_progress,
                progress_delta = progress_delta,
                start_location = tostring(current_session.start_page),
                end_location = tostring(current_session.end_page),
            })
        end
    end
    
    local book_id = nil
    local matched = 0
    
    if book.md5 and book.md5 ~= "" then
        local cached_book = self.db:getBookByHash(book.md5)
        if cached_book and cached_book.book_id then
            book_id = cached_book.book_id
            matched = 1
            self:logInfo("BookloreSync: Auto-matched historical book by hash:", book.title, "→ ID:", book_id)
        else
            if cached_book and (cached_book.isbn13 or cached_book.isbn10) then
                local isbn_match = self.db:findBookIdByIsbn(cached_book.isbn10, cached_book.isbn13)
                if isbn_match and isbn_match.book_id then
                    book_id = isbn_match.book_id
                    matched = 1
                    self:logInfo("BookloreSync: Auto-matched historical book by ISBN:", book.title, "→ ID:", book_id)
                end
            end
        end
    end
    
    if not book_id and book.file and book.file ~= "" then
        local file_cached = self.db:getBookByFilePath(book.file)
        if file_cached and file_cached.book_id then
            book_id = file_cached.book_id
            matched = 1
            self:logInfo("BookloreSync: Auto-matched historical book by file path:", book.title, "→ ID:", book_id)
        end
    end
    
    for _, session in ipairs(sessions) do
        session.koreader_book_id = book.id
        session.koreader_book_title = book.title
        session.book_id = book_id
        session.book_hash = book.md5
        session.book_type = self:_detectBookType(book)
        session.matched = matched
    end
    
    return sessions
end

function BookloreSync:_findKOReaderStatisticsDB()
    -- The statistics database is in the KOReader settings directory
    local stats_path = DataStorage:getSettingsDir() .. "/statistics.sqlite3"
    
    local f = io.open(stats_path, "r")
    if f then
        f:close()
        return stats_path
    end
    
    return nil
end

function BookloreSync:_getKOReaderBooks(conn)
    local books = {}
    
    local stmt = conn:prepare("SELECT id, title, authors, md5 FROM book")
    
    if not stmt then
        self:logErr("BookloreSync: Failed to prepare statement:", conn:errmsg())
        return books
    end
    
    for row in stmt:rows() do
        table.insert(books, {
            id = tonumber(row[1]),
            title = tostring(row[2] or ""),
            authors = tostring(row[3] or ""),
            md5 = tostring(row[4] or ""),
        })
    end
    
    stmt:close()
    return books
end

function BookloreSync:_getKOReaderBookByHash(file_hash)
    if not file_hash or file_hash == "" then
        return nil
    end
    
    local stats_db_path = self:_findKOReaderStatisticsDB()
    if not stats_db_path then
        self:logDbg("BookloreSync: Statistics database not found")
        return nil
    end
    
    local SQ3 = require("lua-ljsqlite3/init")
    local stats_conn = SQ3.open(stats_db_path)
    if not stats_conn then
        self:logWarn("BookloreSync: Failed to open statistics database")
        return nil
    end
    
    local stmt = stats_conn:prepare("SELECT id, title FROM book WHERE md5 = ?")
    if not stmt then
        self:logWarn("BookloreSync: Failed to prepare statement:", stats_conn:errmsg())
        stats_conn:close()
        return nil
    end
    
    stmt:bind(file_hash)
    
    local book_info = nil
    for row in stmt:rows() do
        book_info = {
            koreader_book_id = tonumber(row[1]),
            koreader_book_title = tostring(row[2] or "Unknown"),
        }
        break
    end
    
    stmt:close()
    stats_conn:close()
    
    return book_info
end

function BookloreSync:_getPageStats(conn, book_id)
    local stats = {}
    
    local stmt = conn:prepare([[
        SELECT start_time, duration, total_pages, page 
        FROM page_stat_data 
        WHERE id_book = ? 
        ORDER BY start_time
    ]])
    
    if not stmt then
        self:logErr("BookloreSync: Failed to prepare statement:", conn:errmsg())
        return stats
    end
    
    stmt:bind(book_id)
    
    for row in stmt:rows() do
        table.insert(stats, {
            start_time = tostring(row[1] or ""),
            duration = tonumber(row[2]) or 0,
            total_pages = tonumber(row[3]) or 0,
            page = tonumber(row[4]) or 0,
        })
    end
    
    stmt:close()
    return stats
end

function BookloreSync:_unixToISO8601(timestamp)
    local date_table = os.date("!*t", timestamp)
    return string.format("%04d-%02d-%02dT%02d:%02d:%02dZ",
        date_table.year, date_table.month, date_table.day,
        date_table.hour, date_table.min, date_table.sec)
end

function BookloreSync:_parseISO8601(iso_string)
    if not iso_string then return nil end
    
    local year, month, day, hour, min, sec = iso_string:match(
        "(%d+)-(%d+)-(%d+)%a(%d+):(%d+):(%d+)"
    )
    
    if not year then return nil end
    
    return os.time({
        year = tonumber(year),
        month = tonumber(month),
        day = tonumber(day),
        hour = tonumber(hour),
        min = tonumber(min),
        sec = tonumber(sec),
        isdst = false,
    })
end

function BookloreSync:_detectBookType(book)
    local title = book.title or ""
    local lower_title = title:lower()
    
    if lower_title:match("%.pdf$") then
        return "PDF"
    elseif lower_title:match("%.cbz$") then
        return "CBZ"
    elseif lower_title:match("%.cbr$") then
        return "CBR"
    elseif lower_title:match("%.djvu$") then
        return "DJVU"
    else
        return "EPUB"
    end
end

function BookloreSync:_formatDuration(seconds)
    local parts = {}
    
    local hours = math.floor(seconds / 3600)
    local mins = math.floor((seconds % 3600) / 60)
    local secs = seconds % 60
    
    if hours > 0 then
        table.insert(parts, string.format("%dh", hours))
    end
    if mins > 0 then
        table.insert(parts, string.format("%dm", mins))
    end
    if secs > 0 or #parts == 0 then  -- Always show seconds if duration is 0
        table.insert(parts, string.format("%ds", secs))
    end
    
    return table.concat(parts, " ")
end

--[[--
Group sessions by book_id for batch upload

@param sessions Array of session objects
@return table Grouped sessions { book_id = {book_type = ..., sessions = {...}} }
--]]
function BookloreSync:_groupSessionsByBook(sessions)
    local grouped = {}
    
    for _, session in ipairs(sessions) do
        local book_id = session.book_id
        if book_id then
            if not grouped[book_id] then
                grouped[book_id] = {
                    book_type = session.book_type,
                    sessions = {}
                }
            end
            table.insert(grouped[book_id].sessions, session)
        end
    end
    
    return grouped
end

--[[--
Submit a single session to the server

@param session Session object with all required fields
@return boolean success
@return string message
@return number|nil code
--]]
function BookloreSync:_submitSingleSession(session)
    local start_progress = session.start_progress or 0
    local end_progress = session.end_progress or 0
    local progress_delta = session.progress_delta or (end_progress - start_progress)
    
    local duration_formatted = self:_formatDuration(session.duration_seconds or 0)
    
    return self.api:submitSession({
        bookId = session.book_id,
        bookType = session.book_type,
        startTime = session.start_time,
        endTime = session.end_time,
        durationSeconds = session.duration_seconds,
        durationFormatted = duration_formatted,
        startProgress = self:roundProgress(start_progress),
        endProgress = self:roundProgress(end_progress),
        progressDelta = self:roundProgress(progress_delta),
        startLocation = session.start_location,
        endLocation = session.end_location,
    })
end

--[[--
Upload sessions with intelligent batching

Uses batch upload for 2+ sessions, individual for single session.
Automatically splits large batches into chunks of BATCH_UPLOAD_SIZE.
Falls back to individual upload if batch endpoint returns 404.

@param book_id Booklore book ID
@param book_type Book type (EPUB, PDF, etc.)
@param sessions Array of session objects to upload
@return number synced_count Number of successfully synced sessions
@return number failed_count Number of failed sessions
@return number not_found_count Number of 404 errors (book not found)
--]]
function BookloreSync:_uploadSessionsWithBatching(book_id, book_type, sessions)
    local synced_count = 0
    local failed_count = 0
    local not_found_count = 0
    
    -- Handle empty input
    if not sessions or #sessions == 0 then
        return synced_count, failed_count, not_found_count
    end
    
    if #sessions == 1 then
        local session = sessions[1]
        local success, message, code = self:_submitSingleSession(session)
        
        if success then
            self.db:markHistoricalSessionSynced(session.id)
            synced_count = 1
        elseif code == 404 then
            self:logWarn("BookloreSync: Book ID", book_id, "not found on server (404), marking session for re-matching")
            self.db:markHistoricalSessionUnmatched(session.id)
            not_found_count = 1
        else
            failed_count = 1
        end
        
        return synced_count, failed_count, not_found_count
    end
    
    local batch_size = BATCH_UPLOAD_SIZE
    local total_sessions = #sessions
    local batch_count = math.ceil(total_sessions / batch_size)
    
    self:logInfo("BookloreSync: Uploading", total_sessions, "sessions in", batch_count, "batch(es) for book:", book_id)
    
    for batch_num = 1, batch_count do
        local start_idx = (batch_num - 1) * batch_size + 1
        local end_idx = math.min(batch_num * batch_size, total_sessions)
        local batch_sessions = {}
        
        for i = start_idx, end_idx do
            local session = sessions[i]
            local start_progress = session.start_progress or 0
            local end_progress = session.end_progress or 0
            local progress_delta = session.progress_delta or (end_progress - start_progress)
            
            table.insert(batch_sessions, {
                startTime = session.start_time,
                endTime = session.end_time,
                durationSeconds = session.duration_seconds,
                durationFormatted = self:_formatDuration(session.duration_seconds or 0),
                startProgress = self:roundProgress(start_progress),
                endProgress = self:roundProgress(end_progress),
                progressDelta = self:roundProgress(progress_delta),
                startLocation = session.start_location,
                endLocation = session.end_location,
            })
        end
        
        -- Try batch upload
        self:logInfo("BookloreSync: Attempting batch", batch_num, "of", batch_count, "with", (end_idx - start_idx + 1), "sessions")
        local success, message, code = self.api:submitSessionBatch(book_id, book_type, batch_sessions)
        self:logInfo("BookloreSync: Batch", batch_num, "result - success:", tostring(success), "code:", tostring(code or "nil"), "message:", tostring(message or "nil"))
        
        if success then
            for i = start_idx, end_idx do
                self.db:markHistoricalSessionSynced(sessions[i].id)
                synced_count = synced_count + 1
            end
            self:logInfo("BookloreSync: Batch", batch_num, "of", batch_count, "uploaded successfully (" .. (end_idx - start_idx + 1) .. " sessions)")
        elseif code == 404 or code == 403 then
            -- Server doesn't have batch endpoint (404/403) OR book not found (404)
            -- Fallback to individual upload to determine which
            self:logWarn("BookloreSync: Batch returned", code, "falling back to individual upload for batch", batch_num)
            
            for i = start_idx, end_idx do
                local session = sessions[i]
                local single_success, single_message, single_code = self:_submitSingleSession(session)
                
                if single_success then
                    self.db:markHistoricalSessionSynced(session.id)
                    synced_count = synced_count + 1
                elseif single_code == 404 then
                    self:logWarn("BookloreSync: Book ID", book_id, "not found on server (404), marking session for re-matching")
                    self.db:markHistoricalSessionUnmatched(session.id)
                    not_found_count = not_found_count + 1
                else
                    failed_count = failed_count + 1
                end
            end
        else
            -- Other error: all sessions in batch failed
            self:logErr("BookloreSync: Batch upload failed for batch", batch_num, "of", batch_count, 
                       "(" .. (end_idx - start_idx + 1) .. " sessions) - Error:", message, "Code:", tostring(code or "nil"))
            failed_count = failed_count + (end_idx - start_idx + 1)
        end
    end
    
    return synced_count, failed_count, not_found_count
end

function BookloreSync:matchHistoricalData()
    if not self.db then
        UIManager:show(InfoMessage:new{
            text = _("Database not initialized"),
            timeout = 2,
        })
        return
    end
    
    if not self.db:hasHistoricalSessions() then
        UIManager:show(InfoMessage:new{
            text = _("No historical sessions found. Please copy sessions from KOReader first."),
            timeout = 3,
        })
        return
    end
    
    -- PHASE 1: Auto-sync sessions that were matched during extraction
    local matched_unsynced_books = self.db:getMatchedUnsyncedBooks()
    
    if matched_unsynced_books and #matched_unsynced_books > 0 then
        self:logInfo("BookloreSync: Found", #matched_unsynced_books, 
                   "books with auto-matched but unsynced sessions")
        self:_autoSyncMatchedSessions(matched_unsynced_books)
        return
    end
    
    -- PHASE 2: Manual matching for truly unmatched books (no book_id)
    self:_startManualMatching()
end

function BookloreSync:_autoSyncMatchedSessions(books)
    if not books or #books == 0 then
        self:_startManualMatching()
        return
    end
    
    local total_books = #books
    local total_sessions = 0
    for _, book in ipairs(books) do
        total_sessions = total_sessions + book.unsynced_session_count
    end
    
    self:logInfo("BookloreSync: Auto-syncing", total_sessions, "sessions from", total_books, "matched books")
    
    -- Initialize progress indicator
    local progress_msg = InfoMessage:new{
        text = T(_("Auto-syncing matched sessions...\n\n0 / %1 books\n0 / %2 sessions\n\nSynced: 0\nFailed: 0"),
            total_books, total_sessions),
    }
    UIManager:show(progress_msg)
    
    -- Initialize sync state
    self.autosync_books = books
    self.autosync_index = 1
    self.autosync_total_synced = 0
    self.autosync_total_failed = 0
    self.autosync_total_not_found = 0
    self.autosync_total_books = total_books
    self.autosync_total_sessions = total_sessions
    self.autosync_progress_msg = progress_msg
    
    -- Start syncing
    self:_syncNextMatchedBook()
end

function BookloreSync:_syncNextMatchedBook()
    if not self.autosync_books or self.autosync_index > #self.autosync_books then
        -- Auto-sync phase complete
        UIManager:close(self.autosync_progress_msg)
        
        local result_text = T(_("Auto-sync complete!\n\nBooks processed: %1\nSessions synced: %2\nFailed: %3"), 
                             #self.autosync_books,
                             self.autosync_total_synced, 
                             self.autosync_total_failed)
        
        -- Add not found count if any
        if self.autosync_total_not_found and self.autosync_total_not_found > 0 then
            result_text = result_text .. T(_("\nMarked for re-matching (404): %1"), self.autosync_total_not_found)
        end
        
        UIManager:show(InfoMessage:new{
            text = result_text,
            timeout = 4,
        })
        
        self:logInfo("BookloreSync: Auto-sync complete - synced:", self.autosync_total_synced,
                   "failed:", self.autosync_total_failed, "not found:", self.autosync_total_not_found or 0)
        
        self.autosync_books = nil
        self.autosync_index = nil
        self.autosync_total_synced = nil
        self.autosync_total_failed = nil
        self.autosync_total_not_found = nil
        self.autosync_total_books = nil
        self.autosync_total_sessions = nil
        self.autosync_progress_msg = nil
        
        -- Proceed to Phase 2: Manual matching
        self:_startManualMatching()
        return
    end
    
    local book = self.autosync_books[self.autosync_index]
    
    -- Update progress indicator
    UIManager:close(self.autosync_progress_msg)
    self.autosync_progress_msg = InfoMessage:new{
        text = T(_("Auto-syncing matched sessions...\n\n%1 / %2 books\n%3 / %4 sessions\n\nSynced: %5\nFailed: %6\n\nCurrent: %7"),
            self.autosync_index, 
            self.autosync_total_books,
            self.autosync_total_synced + self.autosync_total_failed,
            self.autosync_total_sessions,
            self.autosync_total_synced,
            self.autosync_total_failed,
            book.koreader_book_title),
    }
    UIManager:show(self.autosync_progress_msg)
    UIManager:forceRePaint()
    
    -- Get unsynced sessions for this book
    local sessions = self.db:getHistoricalSessionsForBookUnsynced(book.koreader_book_id)
    
    if not sessions or #sessions == 0 then
        self:logWarn("BookloreSync: No unsynced sessions found for book:", book.koreader_book_title)
        self.autosync_index = self.autosync_index + 1
        self:_syncNextMatchedBook()
        return
    end
    
    -- Sync sessions for this book using batch upload
    local synced_count, failed_count, not_found_count = 
        self:_uploadSessionsWithBatching(
            sessions[1].book_id,
            sessions[1].book_type,
            sessions
        )
    
    -- Update totals
    self.autosync_total_synced = self.autosync_total_synced + synced_count
    self.autosync_total_failed = self.autosync_total_failed + failed_count
    self.autosync_total_not_found = (self.autosync_total_not_found or 0) + not_found_count
    
    self:logInfo("BookloreSync: Auto-synced", synced_count, "sessions for:", book.koreader_book_title,
               "(", failed_count, "failed,", not_found_count, "not found)")
    
    -- Move to next book
    self.autosync_index = self.autosync_index + 1
    self:_syncNextMatchedBook()
end

function BookloreSync:_startManualMatching()
    local unmatched = self.db:getUnmatchedHistoricalBooks()
    
    if not unmatched or #unmatched == 0 then
        UIManager:show(InfoMessage:new{
            text = _("All historical sessions are matched and synced!"),
            timeout = 3,
        })
        return
    end
    
    self:logInfo("BookloreSync: Starting manual matching for", #unmatched, "books")
    
    self.matching_index = 1
    self.unmatched_books = unmatched
    self:_showNextBookMatch()
end

function BookloreSync:_showNextBookMatch()
    if not self.unmatched_books or self.matching_index > #self.unmatched_books then
        UIManager:show(InfoMessage:new{
            text = _("Matching complete!"),
            timeout = 2,
        })
        return
    end
    
    local book = self.unmatched_books[self.matching_index]
    local progress_text = T(_("Book %1 of %2"), self.matching_index, #self.unmatched_books)
    
    -- PRIORITY 0: Check if book already has book_id cached (auto-sync without confirmation)
    -- This happens when sessions were extracted with enhanced auto-matching enabled
    if book.book_hash and book.book_hash ~= "" then
        local cached_book = self.db:getBookByHash(book.book_hash)
        
        if cached_book and cached_book.book_id then
            self:logInfo("BookloreSync: Found cached book_id for unmatched book, auto-syncing:", book.koreader_book_title)
            
            local match_success = self.db:markHistoricalSessionsMatched(book.koreader_book_id, cached_book.book_id)
            
            if not match_success then
                self:logErr("BookloreSync: Failed to mark sessions as matched for auto-sync")
                self.matching_index = self.matching_index + 1
                self:_showNextBookMatch()
                return
            end
            
            local sessions = self.db:getHistoricalSessionsForBook(book.koreader_book_id)
            
            if sessions and #sessions > 0 then
                self:_syncHistoricalSessions(book, sessions, progress_text)
            else
                self:logWarn("BookloreSync: No sessions found for auto-matched book")
                self.matching_index = self.matching_index + 1
                self:_showNextBookMatch()
            end
            return
        end
    end
    
    -- PRIORITY 1: Check for ISBN in cache and search by ISBN
    if book.book_hash and book.book_hash ~= "" then
        local cached_book = self.db:getBookByHash(book.book_hash)
        
        if cached_book then
            -- Check if we have ISBN data for this book
            if (cached_book.isbn13 and cached_book.isbn13 ~= "") or 
               (cached_book.isbn10 and cached_book.isbn10 ~= "") then
                
                if self.booklore_username and self.booklore_password then
                    UIManager:show(InfoMessage:new{
                        text = T(_("Looking up by ISBN: %1\n\n%2"), 
                            book.koreader_book_title, progress_text),
                        timeout = 1,
                    })
                    
                    -- Prefer ISBN-13, fall back to ISBN-10
                    local search_isbn = cached_book.isbn13 or cached_book.isbn10
                    local isbn_type = cached_book.isbn13 and "isbn13" or "isbn10"
                    
                    local success, results = self.api:searchBooksByIsbn(
                        search_isbn,
                        self.booklore_username,
                        self.booklore_password
                    )
                    
                    if success and results and #results > 0 then
                        -- Take first result (should be exact match)
                        self:_confirmIsbnMatch(book, results[1], isbn_type)
                        return
                    end
                    
                    self:logInfo("BookloreSync: ISBN search failed or no results, continuing to hash lookup")
                end
            end
            
            -- PRIORITY 2: Check if book_id already cached (local hash match)
            if cached_book.book_id then
                self:_confirmAutoMatch(book, cached_book.book_id)
                return
            end
        end
    end
    
    -- PRIORITY 3: Check server by hash
    if book.book_hash and book.book_hash ~= "" then
        if self.booklore_username and self.booklore_password then
            UIManager:show(InfoMessage:new{
                text = T(_("Looking up by hash: %1\n\n%2"), 
                    book.koreader_book_title, progress_text),
                timeout = 1,
            })
            
            local success, server_book = self.api:getBookByHashWithAuth(
                book.book_hash, 
                self.booklore_username, 
                self.booklore_password
            )
            
            if success and server_book then
                self:_confirmHashMatch(book, server_book)
                return
            end
        end
    end
    
    -- PRIORITY 4: Fall back to title search
    self:_performManualSearch(book)
end

function BookloreSync:_confirmAutoMatch(book, book_id)
    local progress_text = T(_("Book %1 of %2"), self.matching_index, #self.unmatched_books)
    
    -- Get book title from cache
    local book_title = "Unknown Book"
    local cached_book = self.db:getBookByBookId(book_id)
    if cached_book then
        book_title = cached_book.title
    end
    
    UIManager:show(ConfirmBox:new{
        text = T(_("Auto-matched by MD5 hash:\n\nKOReader: %1\n\nBooklore: %2\n\n%3\n\nAccept this match?"),
            book.koreader_book_title, book_title, progress_text),
        ok_text = _("Accept"),
        cancel_text = _("Skip"),
        ok_callback = function()
            self:_saveMatchAndSync(book, book_id)
        end,
        cancel_callback = function()
            self.matching_index = self.matching_index + 1
            self:_showNextBookMatch()
        end,
    })
end

function BookloreSync:_confirmHashMatch(book, server_book)
    local progress_text = T(_("Book %1 of %2"), self.matching_index, #self.unmatched_books)
    
    self.hash_match_dialog = ButtonDialog:new{
        title = T(_("Found by hash:\n\n%1\n\n%2"), server_book.title or "Unknown", progress_text),
        buttons = {
            {
                {
                    text = _("Proceed"),
                    callback = function()
                        UIManager:close(self.hash_match_dialog)
                        self:_saveMatchAndSync(book, server_book)
                    end,
                },
            },
            {
                {
                    text = _("Manual Match"),
                    callback = function()
                        UIManager:close(self.hash_match_dialog)
                        self:_performManualSearch(book)
                    end,
                },
            },
            {
                {
                    text = _("Skip"),
                    callback = function()
                        UIManager:close(self.hash_match_dialog)
                        self.matching_index = self.matching_index + 1
                        self:_showNextBookMatch()
                    end,
                },
            },
        },
    }
    
    UIManager:show(self.hash_match_dialog)
end

function BookloreSync:_confirmIsbnMatch(book, server_book, matched_isbn_type)
    local progress_text = T(_("Book %1 of %2"), self.matching_index, #self.unmatched_books)
    
    -- Show which ISBN type matched (ISBN-10 or ISBN-13)
    local isbn_indicator = matched_isbn_type == "isbn13" and "📚 ISBN-13" or "📖 ISBN-10"
    
    self.isbn_match_dialog = ButtonDialog:new{
        title = T(_("%1\n\nFound: %2\n\n%3"), 
            isbn_indicator,
            server_book.title or "Unknown", 
            progress_text),
        buttons = {
            {
                {
                    text = _("Proceed"),
                    callback = function()
                        UIManager:close(self.isbn_match_dialog)
                        self:_saveMatchAndSync(book, server_book)
                    end,
                },
            },
            {
                {
                    text = _("Manual Match"),
                    callback = function()
                        UIManager:close(self.isbn_match_dialog)
                        self:_performManualSearch(book)
                    end,
                },
            },
            {
                {
                    text = _("Skip"),
                    callback = function()
                        UIManager:close(self.isbn_match_dialog)
                        self.matching_index = self.matching_index + 1
                        self:_showNextBookMatch()
                    end,
                },
            },
        },
    }
    
    UIManager:show(self.isbn_match_dialog)
end

function BookloreSync:_performManualSearch(book)
    local progress_text = T(_("Book %1 of %2"), self.matching_index, #self.unmatched_books)
    
    UIManager:show(InfoMessage:new{
        text = T(_("Searching for: %1\n\n%2"), book.koreader_book_title, progress_text),
        timeout = 1,
    })
    
    local success, results = self.api:searchBooksWithAuth(book.koreader_book_title, self.booklore_username, self.booklore_password)
    
    if not success then
        -- Get error message (results contains error message on failure)
        local error_msg = type(results) == "string" and results or "Unknown error"
        
        UIManager:show(ConfirmBox:new{
            text = T(_("Search failed for:\n%1\n\nError: %2\n\n%3\n\nSkip this book?"), 
                book.koreader_book_title, error_msg, progress_text),
            ok_text = _("Skip"),
            cancel_text = _("Retry"),
            ok_callback = function()
                self.matching_index = self.matching_index + 1
                self:_showNextBookMatch()
            end,
            cancel_callback = function()
                -- Retry the same book
                self:_showNextBookMatch()
            end,
        })
        return
    end
    
    if not results or #results == 0 then
        UIManager:show(ConfirmBox:new{
            text = T(_("No matches found for:\n%1\n\n%2\n\nSkip this book?"), 
                book.koreader_book_title, progress_text),
            ok_callback = function()
                self.matching_index = self.matching_index + 1
                self:_showNextBookMatch()
            end,
        })
        return
    end
    
    self:_showMatchSelectionDialog(book, results)
end

function BookloreSync:_showMatchSelectionDialog(book, results)
    local progress_text = T(_("Book %1 of %2"), self.matching_index, #self.unmatched_books)
    
    -- Limit to top 5 results
    local top_results = {}
    for i = 1, math.min(5, #results) do
        table.insert(top_results, results[i])
    end
    
    local buttons = {}
    
    for i, result in ipairs(top_results) do
        table.insert(buttons, {{
            text = T(_("%1. %2 (Score: %3)"), i, result.title, 
                string.format("%.0f%%", (result.matchScore or 0) * 100)),
            callback = function()
                UIManager:close(self.match_dialog)
                self:_saveMatchAndSync(book, result)
            end,
        }})
    end
    
    table.insert(buttons, {{
        text = _("Skip this book"),
        callback = function()
            UIManager:close(self.match_dialog)
            self.matching_index = self.matching_index + 1
            self:_showNextBookMatch()
        end,
    }})
    
    table.insert(buttons, {{
        text = _("Cancel matching"),
        callback = function()
            UIManager:close(self.match_dialog)
        end,
    }})
    
    self.match_dialog = ButtonDialog:new{
        title = T(_("Select match for:\n%1\n\n%2 sessions found\n\n%3"), 
            book.koreader_book_title, book.session_count, progress_text),
        buttons = buttons,
    }
    
    UIManager:show(self.match_dialog)
end

function BookloreSync:_saveMatchAndSync(book, selected_result)
    local book_id = type(selected_result) == "table" and selected_result.id or selected_result
    local book_title = type(selected_result) == "table" and selected_result.title or book.koreader_book_title
    local isbn10 = type(selected_result) == "table" and selected_result.isbn10 or nil
    local isbn13 = type(selected_result) == "table" and selected_result.isbn13 or nil
    
    self:logInfo("BookloreSync: Saving match with ISBN-10:", isbn10, "ISBN-13:", isbn13)
    
    local success = self.db:markHistoricalSessionsMatched(book.koreader_book_id, book_id)
    
    if not success then
        UIManager:show(InfoMessage:new{
            text = _("Failed to save match to database"),
            timeout = 3,
        })
        return
    end
    
    if book.book_hash and book.book_hash ~= "" then
        -- Use the hash as a pseudo file path for historical books
        local cache_path = "historical://" .. book.book_hash
        self.db:saveBookCache(cache_path, book.book_hash, book_id, book_title, nil, isbn10, isbn13)
        self:logInfo("BookloreSync: Cached matched book:", book_title, "with ID:", book_id)
    end
    
    local sessions = self.db:getHistoricalSessionsForBook(book.koreader_book_id)
    
    if not sessions or #sessions == 0 then
        UIManager:show(InfoMessage:new{
            text = _("No sessions found to sync"),
            timeout = 2,
        })
        self.matching_index = self.matching_index + 1
        self:_showNextBookMatch()
        return
    end
    
    self:_syncHistoricalSessions(book, sessions, nil)
end

function BookloreSync:_syncHistoricalSessions(book, sessions, progress_text)
    if not sessions or #sessions == 0 then
        UIManager:show(InfoMessage:new{
            text = _("No sessions found to sync"),
            timeout = 2,
        })
        self.matching_index = self.matching_index + 1
        self:_showNextBookMatch()
        return
    end
    
    -- Filter out already-synced sessions
    local unsynced_sessions = {}
    for _, session in ipairs(sessions) do
        if not session.synced or session.synced == 0 then
            table.insert(unsynced_sessions, session)
        end
    end
    
    if #unsynced_sessions == 0 then
        UIManager:show(InfoMessage:new{
            text = _("All sessions already synced"),
            timeout = 2,
        })
        self.matching_index = self.matching_index + 1
        self:_showNextBookMatch()
        return
    end
    
    -- Use batch upload helper
    local synced_count, failed_count, not_found_count = 
        self:_uploadSessionsWithBatching(
            unsynced_sessions[1].book_id,
            unsynced_sessions[1].book_type,
            unsynced_sessions
        )
    
    -- Show results
    local result_text = T(_("Synced %1 sessions for:\n%2"), synced_count, book.koreader_book_title)
    if progress_text then
        result_text = result_text .. "\n\n" .. progress_text
    end
    if failed_count > 0 then
        result_text = result_text .. T(_("\n\n%1 sessions failed to sync"), failed_count)
    end
    if not_found_count > 0 then
        result_text = result_text .. T(_("\n\n%1 sessions marked for re-matching (404)"), not_found_count)
    end
    
    UIManager:show(InfoMessage:new{
        text = result_text,
        timeout = 2,
    })
    
    -- Move to next book
    self.matching_index = self.matching_index + 1
    self:_showNextBookMatch()
end

function BookloreSync:viewMatchStatistics()
    if not self.db then
        UIManager:show(InfoMessage:new{
            text = _("Database not initialized"),
            timeout = 2,
        })
        return
    end
    
    local stats = self.db:getHistoricalSessionStats()
    
    if not stats then
        UIManager:show(InfoMessage:new{
            text = _("Failed to retrieve statistics"),
            timeout = 2,
        })
        return
    end
    
    -- Convert cdata to Lua numbers for template function
    local total = tonumber(stats.total_sessions) or 0
    local matched = tonumber(stats.matched_sessions) or 0
    local unmatched = tonumber(stats.unmatched_sessions) or 0
    local synced = tonumber(stats.synced_sessions) or 0
    
    if total == 0 then
        UIManager:show(InfoMessage:new{
            text = _("No historical sessions found.\n\nPlease copy sessions from KOReader first."),
            timeout = 3,
        })
        return
    end
    
    UIManager:show(InfoMessage:new{
        text = T(_("Historical Session Statistics:\n\nTotal sessions: %1\nMatched sessions: %2\nUnmatched sessions: %3\nSynced to server: %4"), 
            total, matched, unmatched, synced),
        timeout = 5,
    })
end

function BookloreSync:resyncHistoricalData()
    if not self.db then
        UIManager:show(InfoMessage:new{
            text = _("Database not initialized"),
            timeout = 2,
        })
        return
    end
    
    -- Show confirmation dialog
    UIManager:show(ConfirmBox:new{
        text = _("This will re-sync all previously synced historical sessions to the server.\n\nSessions with invalid book IDs (404 errors) will be marked for re-matching.\n\nContinue?"),
        ok_text = _("Re-sync"),
        cancel_text = _("Cancel"),
        ok_callback = function()
            self:_performResyncHistoricalData()
        end,
    })
end

function BookloreSync:_performResyncHistoricalData()
    -- Get all synced historical sessions
    local sessions = self.db:getAllSyncedHistoricalSessions()
    
    if not sessions or #sessions == 0 then
        UIManager:show(InfoMessage:new{
            text = _("No synced historical sessions found to re-sync"),
            timeout = 3,
        })
        return
    end
    
    -- Group sessions by book_id
    local grouped = self:_groupSessionsByBook(sessions)
    
    -- Count total books and sessions
    local total_books = 0
    local total_sessions = #sessions
    for _ in pairs(grouped) do
        total_books = total_books + 1
    end
    
    self:logInfo("BookloreSync: Re-syncing", total_sessions, "sessions from", total_books, "books")
    
    -- Show initial progress
    local progress_msg = InfoMessage:new{
        text = T(_("Re-syncing historical sessions...\n\n0 / %1 books (0 sessions)"), total_books),
    }
    UIManager:show(progress_msg)
    
    local books_completed = 0
    local total_synced = 0
    local total_failed = 0
    local total_not_found = 0
    
    -- Upload each book's sessions as batch
    for book_id, book_data in pairs(grouped) do
        books_completed = books_completed + 1
        
        -- Batch upload sessions for this book
        local synced, failed, not_found = 
            self:_uploadSessionsWithBatching(book_id, book_data.book_type, book_data.sessions)
        
        total_synced = total_synced + synced
        total_failed = total_failed + failed
        total_not_found = total_not_found + not_found
        
        self:logInfo("BookloreSync: Book", book_id, "- synced:", synced, 
                    "failed:", failed, "not found:", not_found)
        
        -- Update progress after each book
        UIManager:close(progress_msg)
        progress_msg = InfoMessage:new{
            text = T(_("Re-syncing historical sessions...\n\n%1 / %2 books (%3 sessions synced)\n\nSynced: %4\nFailed: %5\n404 errors: %6"),
                books_completed, total_books, total_synced + total_failed + total_not_found,
                total_synced, total_failed, total_not_found),
        }
        UIManager:show(progress_msg)
        UIManager:forceRePaint()
    end
    
    -- Close progress, show results
    UIManager:close(progress_msg)
    
    local result_text = T(_("Re-sync complete!\n\nSuccessfully synced: %1\nFailed: %2\nMarked for re-matching (404): %3"), 
        total_synced, total_failed, total_not_found)
    
    if total_not_found > 0 then
        result_text = result_text .. _("\n\nUse 'Match Historical Data' to re-match sessions with 404 errors.")
    end
    
    UIManager:show(InfoMessage:new{
        text = result_text,
        timeout = 5,
    })
    
    self:logInfo("BookloreSync: Re-sync complete - synced:", total_synced, 
                "failed:", total_failed, "not found:", total_not_found)
end

function BookloreSync:syncRematchedSessions()
    -- Sync sessions that were previously marked for re-matching (404 errors)
    -- and have now been matched to valid books
    if not self.db then
        UIManager:show(InfoMessage:new{
            text = _("Database not initialized"),
            timeout = 2,
        })
        return
    end
    
    -- Get matched but unsynced sessions
    local sessions = self.db:getMatchedUnsyncedHistoricalSessions()
    
    if not sessions or #sessions == 0 then
        UIManager:show(InfoMessage:new{
            text = _("No re-matched sessions found to sync"),
            timeout = 3,
        })
        return
    end
    
    self:logInfo("BookloreSync: Syncing", #sessions, "re-matched sessions")
    
    -- Group by book and batch upload
    local grouped = self:_groupSessionsByBook(sessions)
    
    local total_synced = 0
    local total_failed = 0
    local total_not_found = 0
    
    for book_id, book_data in pairs(grouped) do
        local synced, failed, not_found = 
            self:_uploadSessionsWithBatching(book_id, book_data.book_type, book_data.sessions)
        
        total_synced = total_synced + synced
        total_failed = total_failed + failed
        total_not_found = total_not_found + not_found
    end
    
    -- Show results
    local result_text = T(_("Successfully synced %1 re-matched session(s)"), total_synced)
    if total_failed > 0 then
        result_text = result_text .. T(_("\n\n%1 sessions failed"), total_failed)
    end
    if total_not_found > 0 then
        result_text = result_text .. T(_("\n\n%1 sessions marked for re-matching (404)"), total_not_found)
    end
    
    UIManager:show(InfoMessage:new{
        text = result_text,
        timeout = 3,
    })
    
    self:logInfo("BookloreSync: Re-matched sync complete - synced:", total_synced,
                "failed:", total_failed, "not found:", total_not_found)
end

--[[--
Show version information dialog
--]]
function BookloreSync:showVersionInfo()
    local version_info = self.updater:getCurrentVersion()
    
    local text = T(_([[Version Information

Current Version: %1
Version Type: %2
Build Date: %3
Git Commit: %4]]),
        version_info.version,
        version_info.version_type,
        version_info.build_date,
        version_info.git_commit
    )
    
    -- Add update status if known
    if self.update_available then
        text = text .. _("\n\n⚠ Update available!")
    end
    
    UIManager:show(InfoMessage:new{
        text = text,
        timeout = 10,
    })
end

--[[--
Auto-check for updates (runs once per day, silent mode)
--]]
function BookloreSync:autoCheckForUpdates()
    -- Check if 24 hours passed since last check
    local now = os.time()
    if now - self.last_update_check < 86400 then
        logger.info("BookloreSync Updater: Auto-check skipped (last check was less than 24 hours ago)")
        return
    end
    
    -- Update last check timestamp
    self.last_update_check = now
    self.settings:saveSetting("last_update_check", now)
    self.settings:flush()
    
    -- Check network
    if not NetworkMgr:isConnected() then
        logger.info("BookloreSync Updater: No network, skipping auto-check")
        return
    end
    
    logger.info("BookloreSync Updater: Running auto-check for updates")
    
    -- Check for updates (use cache)
    local result = self.updater:checkForUpdates(true)
    
    if not result then
        logger.warn("BookloreSync Updater: Auto-check failed")
        return
    end
    
    if result.available then
        -- Set flag for menu badge
        self.update_available = true
        
        logger.info("BookloreSync Updater: Update available:", result.latest_version)
        
        -- Show notification
        UIManager:show(InfoMessage:new{
            text = T(_([[BookloreSync update available!

Current: %1
Latest: %2

Go to Tools → Booklore Sync → About & Updates to install.]]),
                result.current_version, result.latest_version),
            timeout = 8,
        })
    else
        logger.info("BookloreSync Updater: Already up to date")
    end
end

--[[--
Check for updates (manual or auto)

@param silent If true, only show message when update available
--]]
function BookloreSync:checkForUpdates(silent)
    -- Check network
    if not NetworkMgr:isConnected() then
        if not silent then
            UIManager:show(InfoMessage:new{
                text = _("No network connection.\n\nPlease connect to check for updates."),
                timeout = 3,
            })
        end
        return
    end
    
    -- Show "Checking..." message
    if not silent then
        UIManager:show(InfoMessage:new{
            text = _("Checking for updates..."),
            timeout = 1,
        })
    end
    
    -- Check for updates (use cache if silent, fresh if manual)
    local result = self.updater:checkForUpdates(silent)
    
    if not result then
        if not silent then
            UIManager:show(InfoMessage:new{
                text = _("Failed to check for updates.\n\nPlease try again later."),
                timeout = 3,
            })
        end
        return
    end
    
    if result.available then
        -- Update available
        self.update_available = true
        
        local size_text = self.updater:formatBytes(result.release_info.size)
        
        -- Build button list
        local buttons = {
            {
                {
                    text = _("Install"),
                    callback = function()
                        UIManager:close(self.update_dialog)
                        self:installUpdate(result.release_info.download_url, result.latest_version)
                    end,
                },
            },
        }
        
        -- Add changelog button if available
        if result.release_info.changelog_url then
            table.insert(buttons, {
                {
                    text = _("View Changelog"),
                    callback = function()
                        UIManager:close(self.update_dialog)
                        self:showChangelog(result.release_info.changelog_url, result.latest_version, result.release_info)
                    end,
                },
            })
        end
        
        -- Add cancel button
        table.insert(buttons, {
            {
                text = _("Cancel"),
                callback = function()
                    UIManager:close(self.update_dialog)
                end,
            },
        })
        
        -- Show update dialog with buttons
        self.update_dialog = ButtonDialog:new{
            title = T(_([[Update available!

Current version: %1
Latest version: %2

Download size: %3]]),
                result.current_version,
                result.latest_version,
                size_text),
            buttons = buttons,
        }
        
        UIManager:show(self.update_dialog)
    else
        -- No update available
        self.update_available = false
        
        if not silent then
            UIManager:show(InfoMessage:new{
                text = T(_("You're up to date!\n\nCurrent version: %1"), result.current_version),
                timeout = 3,
            })
        end
    end
end

--[[--
Show changelog for the new version

@param changelog_url URL to download changelog from
@param version Version number
@param release_info Full release info object for showing update dialog again
--]]
function BookloreSync:showChangelog(changelog_url, version, release_info)
    -- Show loading message
    local loading_msg = InfoMessage:new{
        text = _("Loading changelog..."),
    }
    UIManager:show(loading_msg)
    
    -- Fetch full CHANGELOG.md content from URL
    local full_changelog_content, error_msg = self.updater:fetchChangelog(changelog_url)
    
    UIManager:close(loading_msg)
    
    -- Check if we got the changelog file
    if not full_changelog_content then
        UIManager:show(InfoMessage:new{
            text = T(_("Failed to load changelog:\n%1"), error_msg or "Unknown error"),
            timeout = 3,
        })
        -- Show update dialog again after error
        self:checkForUpdates(true)
        return
    end
    
    -- Parse the CHANGELOG.md to extract just this version's section
    local changelog_text = self.updater:parseChangelogForVersion(full_changelog_content, version)
    
    if not changelog_text or changelog_text == "" then
        -- Fallback to showing the whole changelog if parsing failed
        logger.warn("BookloreSync: Could not parse version-specific changelog, showing full file")
        changelog_text = full_changelog_content
    end
    
    -- Clean changelog by removing links and commit references
    changelog_text = self.updater:cleanChangelog(changelog_text)
    
    -- Show changelog in a scrollable text widget
    local Screen = require("device").screen
    local TextViewer = require("ui/widget/textviewer")
    
    local changelog_viewer
    changelog_viewer = TextViewer:new{
        title = T(_("Changelog - Version %1"), version),
        text = changelog_text,
        width = math.floor(Screen:getWidth() * 0.8),
        height = math.floor(Screen:getHeight() * 0.7),
        buttons_table = {
            {
                {
                    text = _("Install Update"),
                    callback = function()
                        UIManager:close(changelog_viewer)
                        self:installUpdate(release_info.download_url, version)
                    end,
                },
            },
            {
                {
                    text = _("Close"),
                    callback = function()
                        UIManager:close(changelog_viewer)
                    end,
                },
            },
        },
    }
    
    UIManager:show(changelog_viewer)
end

--[[--
Install update from download URL

@param download_url URL to download ZIP from
@param version Version being installed
--]]
function BookloreSync:installUpdate(download_url, version)
    -- Show initial progress message
    local progress_msg = InfoMessage:new{
        text = _("Downloading update...\n0%"),
    }
    UIManager:show(progress_msg)
    
    -- Download with progress callback
    local success, zip_path_or_error = self.updater:downloadUpdate(
        download_url,
        function(bytes_downloaded, total_bytes)
            -- Update progress message
            if total_bytes > 0 then
                local progress = math.floor((bytes_downloaded / total_bytes) * 100)
                progress_msg:setText(T(_("Downloading update...\n%1%%"), progress))
                UIManager:setDirty(progress_msg, "ui")
            end
        end
    )
    
    UIManager:close(progress_msg)
    
    if not success then
        UIManager:show(InfoMessage:new{
            text = T(_("Download failed:\n%1"), zip_path_or_error),
            timeout = 5,
        })
        return
    end
    
    -- Show installation progress
    UIManager:show(InfoMessage:new{
        text = _("Installing update..."),
        timeout = 2,
    })
    
    -- Install update (includes backup)
    success, error_msg = self.updater:installUpdate(zip_path_or_error)
    
    if success then
        -- Success! Ask for restart with custom message
        UIManager:askForRestart(T(_([[Update installed successfully!

Version %1 is ready.

Restart KOReader now?]]), version))
    else
        -- Installation failed, offer rollback
        UIManager:show(ConfirmBox:new{
            text = T(_([[Installation failed:
%1

Rollback to previous version?]]), error_msg),
            ok_text = _("Rollback"),
            ok_callback = function()
                self:rollbackUpdate()
            end,
            cancel_text = _("Cancel"),
        })
    end
end

--[[--
Rollback to previous version after failed update
--]]
function BookloreSync:rollbackUpdate()
    UIManager:show(InfoMessage:new{
        text = _("Rolling back to previous version..."),
        timeout = 2,
    })
    
    local success, error_msg = self.updater:rollback()
    
    if success then
        -- Rollback successful, ask for restart
        UIManager:askForRestart(_("Rollback successful!\n\nRestart KOReader now?"))
    else
        UIManager:show(InfoMessage:new{
            text = T(_("Rollback failed:\n%1"), error_msg),
            timeout = 5,
        })
    end
end

--[[--
Toggle auto-update check setting
--]]
function BookloreSync:toggleAutoUpdateCheck()
    self.auto_update_check = not self.auto_update_check
    self.settings:saveSetting("auto_update_check", self.auto_update_check)
    self.settings:flush()
    
    UIManager:show(InfoMessage:new{
        text = self.auto_update_check and 
            _("Auto-update check enabled.\n\nWill check once per day on startup.") or
            _("Auto-update check disabled."),
        timeout = 2,
    })
end

--[[--
Clear update cache to force fresh check
--]]
function BookloreSync:clearUpdateCache()
    self.updater:clearCache()
    self.update_available = false
    
    UIManager:show(InfoMessage:new{
        text = _("Update cache cleared.\n\nNext check will fetch fresh data."),
        timeout = 2,
    })
end

return BookloreSync
