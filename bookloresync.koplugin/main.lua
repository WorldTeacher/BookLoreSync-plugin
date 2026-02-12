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
local UIManager = require("ui/uimanager")
local WidgetContainer = require("ui/widget/container/widgetcontainer")
local ConfirmBox = require("ui/widget/confirmbox")
local Settings = require("booklore_settings")
local Database = require("booklore_database")
local APIClient = require("booklore_api_client")
local logger = require("logger")

local _ = require("gettext")
local T = require("ffi/util").template

local BookloreSync = WidgetContainer:extend{
    name = "booklore",
    is_doc_only = false,
}

function BookloreSync:init()
    self.settings = LuaSettings:open(DataStorage:getSettingsDir() .. "/booklore.lua")
    
    -- Server configuration
    self.server_url = self.settings:readSetting("server_url") or ""
    self.username = self.settings:readSetting("username") or ""
    self.password = self.settings:readSetting("password") or ""
    
    -- General settings
    self.is_enabled = self.settings:readSetting("is_enabled") or false
    self.log_to_file = self.settings:readSetting("log_to_file") or false
    self.silent_messages = self.settings:readSetting("silent_messages") or false
    
    -- Session settings
    self.min_duration = self.settings:readSetting("min_duration") or 30
    self.min_pages = self.settings:readSetting("min_pages") or 5
    self.session_detection_mode = self.settings:readSetting("session_detection_mode") or "duration" -- "duration" or "pages"
    self.progress_decimal_places = self.settings:readSetting("progress_decimal_places") or 2
    
    -- Sync options
    self.force_push_session_on_suspend = self.settings:readSetting("force_push_session_on_suspend") or false
    self.connect_network_on_suspend = self.settings:readSetting("connect_network_on_suspend") or false
    self.manual_sync_only = self.settings:readSetting("manual_sync_only") or false
    
    -- Historical data tracking
    self.historical_sync_ack = self.settings:readSetting("historical_sync_ack") or false
    
    -- Current reading session tracking
    self.current_session = nil
    
    -- Initialize SQLite database
    self.db = Database:new()
    local db_initialized = self.db:init()
    
    if not db_initialized then
        logger.err("BookloreSync: Failed to initialize database")
        UIManager:show(InfoMessage:new{
            text = _("Failed to initialize Booklore database"),
            timeout = 3,
        })
    else
        -- Check if we need to migrate from old LuaSettings format
        local old_db_path = DataStorage:getSettingsDir() .. "/booklore_db.lua"
        local old_db_file = io.open(old_db_path, "r")
        
        if old_db_file then
            old_db_file:close()
            logger.info("BookloreSync: Found old database, checking if migration needed")
            
            -- Check if database is empty (needs migration)
            local stats = self.db:getBookCacheStats()
            if stats.total == 0 then
                logger.info("BookloreSync: Database is empty, migrating from LuaSettings")
                
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
                    logger.err("BookloreSync: Migration failed:", err)
                    UIManager:show(InfoMessage:new{
                        text = _("Failed to migrate old data. Check logs."),
                        timeout = 3,
                    })
                end
            end
        end
    end
    
    -- Initialize API client
    self.api = APIClient:new()
    self.api:init(self.server_url, self.username, self.password)
    
    -- Register menu
    self.ui.menu:registerToMainMenu(self)
    
    -- Register actions with Dispatcher for gesture manager integration
    self:registerDispatcherActions()
end

function BookloreSync:onExit()
    -- Close database connection when plugin exits
    if self.db then
        self.db:close()
    end
end

function BookloreSync:registerDispatcherActions()
    -- Register Toggle Sync action
    Dispatcher:registerAction("booklore_toggle_sync", {
        category = "none",
        event = "ToggleBookloreSync",
        title = _("Toggle Booklore Sync"),
        general = true,
    })
    
    -- Register Sync Pending Sessions action
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
    
    -- Register Test Connection action
    Dispatcher:registerAction("booklore_test_connection", {
        category = "none",
        event = "TestBookloreConnection",
        title = _("Test Booklore Connection"),
        general = true,
    })
end

-- Event handlers for Dispatcher actions
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
    
    -- If enabling manual_sync_only, disable force_push
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

function BookloreSync:addToMainMenu(menu_items)
    local base_menu = Settings:buildMenu(self)
    
    -- Session Management submenu
    table.insert(base_menu, {
        text = _("Session Management"),
        sub_item_table = {
            {
                text = _("Session Detection Mode"),
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
                    },
                },
            },
            {
                text = _("Minimum Session Duration"),
                help_text = _("Set the minimum number of seconds a reading session must last to be synced. Sessions shorter than this will be discarded. Default is 30 seconds. Only applies when using duration-based detection."),
                keep_menu_open = true,
                callback = function()
                    Settings:configureMinDuration(self)
                end,
            },
            {
                text = _("Minimum Pages Read"),
                help_text = _("Set the minimum number of pages that must be read in a session for it to be synced. Default is 1 page. Only applies when using pages-based detection."),
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
            {
                text = _("Sync Pending Sessions"),
                help_text = _("Manually sync all sessions that failed to upload previously. Sessions are cached locally when the network is unavailable and synced automatically on resume."),
                enabled_func = function()
                    return self.db and self.db:getPendingSessionCount() > 0
                end,
                callback = function()
                    self:syncPendingSessions()
                end,
            },
            {
                text = _("Clear Pending Sessions"),
                help_text = _("Delete all locally cached sessions that are waiting to be synced. Use this if you want to discard pending sessions instead of uploading them."),
                enabled_func = function()
                    return self.db and self.db:getPendingSessionCount() > 0
                end,
                callback = function()
                    if self.db then
                        self.db:clearPendingSessions()
                        UIManager:show(InfoMessage:new{
                            text = _("Pending sessions cleared"),
                            timeout = 2,
                        })
                    end
                end,
            },
            {
                text = _("View Pending Count"),
                help_text = _("Display the number of reading sessions currently cached locally and waiting to be synced to the server."),
                callback = function()
                    local count = self.db and self.db:getPendingSessionCount() or 0
                    count = tonumber(count) or 0
                    UIManager:show(InfoMessage:new{
                        text = T(_("%1 sessions pending sync"), count),
                        timeout = 2,
                    })
                end,
            },
            {
                text = _("View Cache Status"),
                help_text = _("Display statistics about the local cache: number of book hashes cached, file paths cached, and pending sessions. The cache improves performance by avoiding redundant hash calculations."),
                callback = function()
                    if not self.db then
                        UIManager:show(InfoMessage:new{
                            text = _("Database not initialized"),
                            timeout = 2,
                        })
                        return
                    end
                    
                    local stats = self.db:getBookCacheStats()
                    local pending_count = self.db:getPendingSessionCount()
                    
                    -- Convert cdata to Lua numbers
                    local total = tonumber(stats.total) or 0
                    local matched = tonumber(stats.matched) or 0
                    local unmatched = tonumber(stats.unmatched) or 0
                    local pending = tonumber(pending_count) or 0
                    
                    UIManager:show(InfoMessage:new{
                        text = T(_("Total books: %1\nMatched: %2\nUnmatched: %3\nPending sessions: %4"), 
                            total, matched, unmatched, pending),
                        timeout = 3,
                    })
                end,
            },
            {
                text = _("Clear Local Cache"),
                help_text = _("Delete all cached book hashes and file path mappings. This will not affect pending sessions. The cache will be rebuilt as you read. Use this if you encounter book identification issues."),
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
    
    -- Sync Options submenu
    table.insert(base_menu, {
        text = _("Sync Options"),
        sub_item_table = {
            {
                text = _("Only manual syncs"),
                help_text = _("Cache all sessions and prevent automatic syncing. Use 'Sync Pending Sessions' (menu or gesture) when you want to upload. Mutually exclusive with 'Force push on suspend'."),
                checked_func = function()
                    return self.manual_sync_only
                end,
                callback = function()
                    self:toggleManualSyncOnly()
                end,
            },
            {
                text = _("Force push session on suspend"),
                help_text = _("Automatically sync the current reading session and all pending sessions when the device suspends. Enables 'Connect network on suspend' option and requires network connectivity. Mutually exclusive with 'Only manual syncs'."),
                checked_func = function()
                    return self.force_push_session_on_suspend
                end,
                callback = function()
                    self.force_push_session_on_suspend = not self.force_push_session_on_suspend
                    self.settings:saveSetting("force_push_session_on_suspend", self.force_push_session_on_suspend)
                    
                    -- If enabling force_push, disable manual_sync_only
                    if self.force_push_session_on_suspend and self.manual_sync_only then
                        self.manual_sync_only = false
                        self.settings:saveSetting("manual_sync_only", false)
                    end
                    
                    self.settings:flush()
                    UIManager:show(InfoMessage:new{
                        text = self.force_push_session_on_suspend and _("Will force push session on suspend if network available") or _("Force push on suspend disabled"),
                        timeout = 2,
                    })
                end,
            },
            {
                text = _("Connect network on suspend"),
                help_text = _("Automatically enable WiFi and attempt to connect when the device suspends. Waits up to 15 seconds for connection. Useful for syncing when going offline."),
                checked_func = function()
                    return self.connect_network_on_suspend
                end,
                callback = function()
                    self.connect_network_on_suspend = not self.connect_network_on_suspend
                    self.settings:saveSetting("connect_network_on_suspend", self.connect_network_on_suspend)
                    self.settings:flush()
                    UIManager:show(InfoMessage:new{
                        text = self.connect_network_on_suspend and _("Will enable and scan for network on suspend (15s timeout)") or _("Connect network on suspend disabled"),
                        timeout = 2,
                    })
                end,
            },
        },
    })
    
    -- Historical Data submenu (NEW)
    table.insert(base_menu, {
        text = _("Historical Data"),
        sub_item_table = {
            {
                text = _("Sync Historical Data"),
                help_text = _("One-time sync of all reading sessions from KOReader's statistics database. This reads from statistics.sqlite3 and uploads historical sessions. Warning: May create duplicate sessions if run multiple times."),
                enabled_func = function()
                    return self.server_url ~= "" and self.username ~= "" and self.is_enabled
                end,
                callback = function()
                    self:syncHistoricalData()
                end,
            },
            {
                text = _("Match Historical Data"),
                help_text = _("Scan local books and match them with Booklore server entries. Search by title and select the correct match from server results. This helps identify books for accurate session tracking."),
                enabled_func = function()
                    return self.server_url ~= "" and self.username ~= "" and self.is_enabled
                end,
                callback = function()
                    self:matchHistoricalData()
                end,
            },
            {
                text = _("View Match Statistics"),
                help_text = _("Display statistics about book matching: number of books matched to Booklore entries, unmatched books, and matching progress."),
                callback = function()
                    self:viewMatchStatistics()
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

-- Connection testing
function BookloreSync:testConnection()
    UIManager:show(InfoMessage:new{
        text = _("Testing connection..."),
        timeout = 1,
    })
    
    -- Validate configuration
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
    
    -- Update API client with current credentials
    self.api:init(self.server_url, self.username, self.password)
    
    -- Test authentication
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
    -- Convert to number in case it's cdata from SQLite
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
        -- Pages-based detection
        if pages_read < self.min_pages then
            return false, string.format("Insufficient pages read (%d < %d)", pages_read, self.min_pages)
        end
    else
        -- Duration-based detection (default)
        if duration_seconds < self.min_duration then
            return false, string.format("Session too short (%ds < %ds)", duration_seconds, self.min_duration)
        end
        
        -- Also check pages for duration mode (must have progressed)
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

@return number progress (0-100)
@return string location (page number or position)
--]]
function BookloreSync:getCurrentProgress()
    if not self.ui or not self.ui.document then
        return 0, "0"
    end
    
    local progress = 0
    local location = "0"
    
    if self.ui.document.info and self.ui.document.info.has_pages then
        -- PDF or image-based format
        local current_page = self.ui.document:getCurrentPage()
        local total_pages = self.ui.document:getPageCount()
        if total_pages > 0 then
            progress = self:roundProgress((current_page / total_pages) * 100)
        end
        location = tostring(current_page)
    elseif self.ui.rolling then
        -- EPUB or reflowable format
        local cur_page = self.ui.document:getCurrentPage()
        local total_pages = self.ui.document:getPageCount()
        if total_pages > 0 then
            progress = self:roundProgress((cur_page / total_pages) * 100)
        end
        location = tostring(cur_page)
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
        elseif ext == "DJVU" then
            return "DJVU"
        elseif ext == "CBZ" or ext == "CBR" then
            return "COMIC"
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
    logger.info("BookloreSync: Calculating MD5 hash for:", file_path)
    
    local file = io.open(file_path, "rb")
    if not file then
        logger.warn("BookloreSync: Could not open file for hashing")
        return nil
    end
    
    local md5 = require("ffi/sha2").md5
    local base = 1024
    local block_size = 1024
    local buffer = {}
    
    -- Get file size
    local file_size = file:seek("end")
    file:seek("set", 0)
    
    logger.info("BookloreSync: File size:", file_size)
    
    -- Sample file at specific positions (matching Booklore's FileFingerprint algorithm)
    -- Positions: base << (2*i) for i from -1 to 10
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
    
    logger.info("BookloreSync: Hash calculated:", hash)
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
        logger.warn("BookloreSync: No book hash provided to getBookIdByHash")
        return nil
    end
    
    logger.info("BookloreSync: Looking up book ID for hash:", book_hash)
    
    -- Check database cache first
    local cached_book = self.db:getBookByHash(book_hash)
    if cached_book and cached_book.book_id then
        logger.info("BookloreSync: Found book ID in database cache:", cached_book.book_id)
        return cached_book.book_id
    end
    
    -- Not in cache, query server
    logger.info("BookloreSync: Book ID not in cache, querying server")
    
    local success, book_data = self.api:getBookByHash(book_hash)
    
    if not success then
        logger.warn("BookloreSync: Failed to get book from server (offline or error)")
        return nil
    end
    
    if not book_data or not book_data.id then
        logger.info("BookloreSync: Book not found on server")
        return nil
    end
    
    -- Ensure book_id is a number (API might return string)
    local book_id = tonumber(book_data.id)
    if not book_id then
        logger.warn("BookloreSync: Invalid book ID from server:", book_data.id)
        return nil
    end
    
    logger.info("BookloreSync: Found book ID on server:", book_id)
    
    -- Update cache with the book ID we found
    if cached_book then
        -- We have the hash cached but didn't have the book_id
        self.db:updateBookId(book_hash, book_id)
        logger.info("BookloreSync: Updated database cache with book ID")
    end
    
    return book_id
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
        logger.warn("BookloreSync: No document available to start session")
        return
    end
    
    local file_path = self.ui.document.file
    if not file_path then
        logger.warn("BookloreSync: No file path available")
        return
    end
    
    -- Ensure file_path is a string
    file_path = tostring(file_path)
    
    logger.info("BookloreSync: ========== Starting session ==========")
    logger.info("BookloreSync: File:", file_path)
    logger.info("BookloreSync: File path type:", type(file_path))
    logger.info("BookloreSync: File path length:", #file_path)
    
    -- Check database for this file
    logger.info("BookloreSync: Calling getBookByFilePath...")
    local ok, cached_book = pcall(function()
        return self.db:getBookByFilePath(file_path)
    end)
    
    if not ok then
        logger.err("BookloreSync: Error in getBookByFilePath:", cached_book)
        logger.err("  file_path:", file_path)
        return
    end
    
    logger.info("BookloreSync: getBookByFilePath completed")
    local file_hash = nil
    local book_id = nil
    
    if cached_book then
        logger.info("BookloreSync: Found book in cache - ID:", cached_book.book_id, "Hash:", cached_book.file_hash)
        file_hash = cached_book.file_hash
        -- Ensure book_id from cache is a number (defensive programming)
        book_id = cached_book.book_id and tonumber(cached_book.book_id) or nil
    else
        logger.info("BookloreSync: Book not in cache, calculating hash")
        -- Calculate hash for new book
        file_hash = self:calculateBookHash(file_path)
        
        if not file_hash then
            logger.warn("BookloreSync: Failed to calculate book hash, continuing without hash")
        else
            logger.info("BookloreSync: Hash calculated:", file_hash)
            
            -- Try to look up book ID from server by hash
            book_id = self:getBookIdByHash(file_hash)
            
            if book_id then
                logger.info("BookloreSync: Book ID found on server:", book_id)
            else
                logger.info("BookloreSync: Book not found on server (offline or not in library)")
            end
            
            -- Cache the book info in database
            logger.info("BookloreSync: Calling cacheBook with:")
            logger.info("  file_path:", file_path, "type:", type(file_path))
            logger.info("  file_hash:", file_hash, "type:", type(file_hash))
            logger.info("  book_id:", book_id, "type:", type(book_id))
            
            local ok, result = pcall(function()
                return self.db:cacheBook(file_path, file_hash, book_id)
            end)
            
            if not ok then
                logger.err("BookloreSync: Error in cacheBook:", result)
                logger.err("  file_path:", file_path)
                logger.err("  file_hash:", file_hash)
                logger.err("  book_id:", book_id)
            else
                if result then
                    logger.info("BookloreSync: Book cached in database successfully")
                else
                    logger.warn("BookloreSync: Failed to cache book in database")
                end
            end
        end
    end
    
    -- Get current reading position
    local start_progress, start_location = self:getCurrentProgress()
    
    -- Create session tracking object
    self.current_session = {
        file_path = file_path,
        book_id = book_id,
        file_hash = file_hash,
        start_time = os.time(),
        start_progress = start_progress,
        start_location = start_location,
        book_type = self:getBookType(file_path),
    }
    
    logger.info("BookloreSync: Session started at", start_progress, "% (location:", start_location, ")")
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
        logger.info("BookloreSync: No active session to end")
        return
    end
    
    logger.info("BookloreSync: ========== Ending session ==========")
    
    -- Get current reading position
    local end_progress, end_location = self:getCurrentProgress()
    local end_time = os.time()
    local duration_seconds = end_time - self.current_session.start_time
    
    -- Calculate pages read (absolute difference in locations)
    local pages_read = 0
    local start_loc = tonumber(self.current_session.start_location) or 0
    local end_loc = tonumber(end_location) or 0
    pages_read = math.abs(end_loc - start_loc)
    
    logger.info("BookloreSync: Duration:", duration_seconds, "s, Pages read:", pages_read)
    logger.info("BookloreSync: Progress:", self.current_session.start_progress, "% ->", end_progress, "%")
    
    -- Validate session
    local valid, reason = self:validateSession(duration_seconds, pages_read)
    if not valid then
        logger.info("BookloreSync: Session invalid -", reason)
        self.current_session = nil
        return
    end
    
    -- Calculate progress delta
    local progress_delta = self:roundProgress(end_progress - self.current_session.start_progress)
    
    -- Format timestamp for API (ISO 8601)
    local function formatTimestamp(unix_time)
        return os.date("!%Y-%m-%dT%H:%M:%SZ", unix_time)
    end
    
    -- Prepare session data
    local session_data = {
        bookId = self.current_session.book_id,
        bookHash = self.current_session.file_hash,
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
    
    logger.info("BookloreSync: Session valid - Duration:", duration_seconds, "s, Progress delta:", progress_delta, "%")
    
    -- Save to pending sessions database
    local success = self.db:addPendingSession(session_data)
    
    if success then
        logger.info("BookloreSync: Session saved to pending queue")
        
        if not silent and not self.silent_messages then
            local pending_count = self.db:getPendingSessionCount()
            UIManager:show(InfoMessage:new{
                text = T(_("Session saved (%1 pending)"), tonumber(pending_count) or 0),
                timeout = 2,
            })
        end
        
        -- If not in manual-only mode and not forced to queue, try to sync
        if not force_queue and not self.manual_sync_only then
            logger.info("BookloreSync: Attempting automatic sync")
            self:syncPendingSessions(true) -- silent sync
        end
    else
        logger.err("BookloreSync: Failed to save session to database")
        if not silent then
            UIManager:show(InfoMessage:new{
                text = _("Failed to save reading session"),
                timeout = 2,
            })
        end
    end
    
    -- Clear current session
    self.current_session = nil
end

-- Event Handlers

--[[--
Handler for when a document is opened and ready
--]]
function BookloreSync:onReaderReady()
    logger.info("BookloreSync: Reader ready")
    self:startSession()
    return false -- Allow other plugins to process this event
end

--[[--
Handler for when a document is closed
--]]
function BookloreSync:onCloseDocument()
    if not self.is_enabled then
        return false
    end
    
    logger.info("BookloreSync: Document closing")
    self:endSession({ silent = false, force_queue = false })
    return false
end

--[[--
Handler for when the device is about to suspend
--]]
function BookloreSync:onSuspend()
    if not self.is_enabled then
        return false
    end
    
    logger.info("BookloreSync: Device suspending")
    self:endSession({ silent = true, force_queue = true })
    return false
end

--[[--
Handler for when the device resumes from suspend
--]]
function BookloreSync:onResume()
    if not self.is_enabled then
        return false
    end
    
    logger.info("BookloreSync: Device resuming")
    
    -- Try to sync pending sessions in the background
    if not self.manual_sync_only then
        logger.info("BookloreSync: Attempting background sync on resume")
        self:syncPendingSessions(true) -- silent sync
    end
    
    -- If a book is currently open, start a new session
    if self.ui and self.ui.document then
        logger.info("BookloreSync: Book is open, starting new session")
        self:startSession()
    end
    
    return false
end

function BookloreSync:syncPendingSessions(silent)
    silent = silent or false
    
    if not self.db then
        logger.err("BookloreSync: Database not initialized")
        if not silent then
            UIManager:show(InfoMessage:new{
                text = _("Database not initialized"),
                timeout = 2,
            })
        end
        return
    end
    
    local pending_count = self.db:getPendingSessionCount()
    pending_count = tonumber(pending_count) or 0
    
    if pending_count == 0 then
        logger.info("BookloreSync: No pending sessions to sync")
        if not silent then
            UIManager:show(InfoMessage:new{
                text = _("No pending sessions to sync"),
                timeout = 2,
            })
        end
        return
    end
    
    logger.info("BookloreSync: Starting sync of", pending_count, "pending sessions")
    
    if not silent and not self.silent_messages then
        UIManager:show(InfoMessage:new{
            text = T(_("Syncing %1 pending sessions..."), pending_count),
            timeout = 2,
        })
    end
    
    -- Update API client with current credentials
    self.api:init(self.server_url, self.username, self.password)
    
    -- Get pending sessions from database
    local sessions = self.db:getPendingSessions(100) -- Sync up to 100 at a time
    
    local synced_count = 0
    local failed_count = 0
    local resolved_count = 0
    
    for i, session in ipairs(sessions) do
        logger.info("BookloreSync: Processing pending session", i, "of", #sessions)
        
        -- If session has hash but no bookId, try to resolve it now
        if session.bookHash and not session.bookId then
            logger.info("BookloreSync: Attempting to resolve book ID for hash:", session.bookHash)
            
            -- Check if we have it in cache first
            local cached_book = self.db:getBookByHash(session.bookHash)
            if cached_book and cached_book.book_id then
                session.bookId = cached_book.book_id
                logger.info("BookloreSync: Resolved book ID from cache:", session.bookId)
                resolved_count = resolved_count + 1
            else
                -- Try to fetch from server
                local success, book_data = self.api:getBookByHash(session.bookHash)
                if success and book_data and book_data.id then
                    -- Ensure book_id is a number (API might return string)
                    local book_id = tonumber(book_data.id)
                    if book_id then
                        session.bookId = book_id
                        -- Cache the result
                        self.db:updateBookId(session.bookHash, book_id)
                        logger.info("BookloreSync: Resolved book ID from server:", book_id)
                        resolved_count = resolved_count + 1
                    else
                        logger.warn("BookloreSync: Invalid book ID from server:", book_data.id)
                        self.db:incrementSessionRetryCount(session.id)
                        failed_count = failed_count + 1
                        goto continue
                    end
                else
                    logger.warn("BookloreSync: Failed to resolve book ID, will retry later")
                    -- Increment retry count and skip this session
                    self.db:incrementSessionRetryCount(session.id)
                    failed_count = failed_count + 1
                    goto continue
                end
            end
        end
        
        -- Ensure we have a book ID before submitting
        if not session.bookId then
            logger.warn("BookloreSync: Session", i, "has no book ID, skipping")
            self.db:incrementSessionRetryCount(session.id)
            failed_count = failed_count + 1
            goto continue
        end
        
        -- Add formatted duration to session data
        local duration_formatted = self:formatDuration(session.durationSeconds)
        
        -- Prepare session data for API (remove internal fields)
        local session_data = {
            bookId = session.bookId,
            bookType = session.bookType,
            startTime = session.startTime,
            endTime = session.endTime,
            durationSeconds = session.durationSeconds,
            durationFormatted = duration_formatted,
            startProgress = session.startProgress,
            endProgress = session.endProgress,
            progressDelta = session.progressDelta,
            startLocation = session.startLocation,
            endLocation = session.endLocation,
        }
        
        logger.info("BookloreSync: Submitting session", i, "- Book ID:", session.bookId, 
                    "Duration:", duration_formatted)
        
        -- Submit to server
        local success, message = self.api:submitSession(session_data)
        
        if success then
            synced_count = synced_count + 1
            -- Delete from pending sessions
            self.db:deletePendingSession(session.id)
            logger.info("BookloreSync: Session", i, "synced successfully")
        else
            failed_count = failed_count + 1
            logger.warn("BookloreSync: Session", i, "failed to sync:", message)
            -- Increment retry count
            self.db:incrementSessionRetryCount(session.id)
        end
        
        ::continue::
    end
    
    logger.info("BookloreSync: Sync complete - synced:", synced_count, 
                "failed:", failed_count, "resolved:", resolved_count)
    
    if not silent and not self.silent_messages then
        local message
        if synced_count > 0 and failed_count > 0 then
            message = T(_("Synced %1 sessions, %2 failed"), synced_count, failed_count)
        elseif synced_count > 0 then
            message = T(_("All %1 sessions synced successfully!"), synced_count)
        else
            message = _("All sync attempts failed - check connection")
        end
        
        UIManager:show(InfoMessage:new{
            text = message,
            timeout = 3,
        })
    end
    
    return synced_count, failed_count
end

function BookloreSync:syncHistoricalData()
    local function startSync()
        self.historical_sync_ack = true
        self.settings:saveSetting("historical_sync_ack", self.historical_sync_ack)
        self.settings:flush()
        self:_runHistoricalDataSync()
    end

    if not self.historical_sync_ack then
        UIManager:show(ConfirmBox:new{
            text = _("This should only be run once. Any run after this will cause sessions to show up multiple times in booklore"),
            ok_text = _("Sync now"),
            cancel_text = _("Cancel"),
            ok_callback = function()
                startSync()
            end,
        })
        return
    end

    UIManager:show(ConfirmBox:new{
        text = _("You already synced historical data. Are you sure you want to sync again and possibly create duplicate entries?"),
        ok_text = _("Sync again"),
        cancel_text = _("Cancel"),
        ok_callback = function()
            startSync()
        end,
    })
end

function BookloreSync:_runHistoricalDataSync()
    UIManager:show(InfoMessage:new{
        text = _("Historical data sync - not yet implemented"),
        timeout = 2,
    })
end

function BookloreSync:matchHistoricalData()
    UIManager:show(InfoMessage:new{
        text = _("Match historical data - not yet implemented (Step 2)"),
        timeout = 2,
    })
end

function BookloreSync:viewMatchStatistics()
    if not self.db then
        UIManager:show(InfoMessage:new{
            text = _("Database not initialized"),
            timeout = 2,
        })
        return
    end
    
    local stats = self.db:getBookCacheStats()
    
    -- Convert cdata to Lua numbers for template function
    local total = tonumber(stats.total) or 0
    local matched = tonumber(stats.matched) or 0
    local unmatched = tonumber(stats.unmatched) or 0
    
    UIManager:show(InfoMessage:new{
        text = T(_("Match Statistics:\n\nTotal cached books: %1\nMatched to Booklore: %2\nUnmatched books: %3"), 
            total, matched, unmatched),
        timeout = 4,
    })
end

return BookloreSync
