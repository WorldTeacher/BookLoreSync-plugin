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
local Settings = require("booklore_settings")
local Database = require("booklore_database")
local APIClient = require("booklore_api_client")
local Updater = require("booklore_updater")
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
    
    -- Booklore login credentials for historical data matching
    self.booklore_username = self.settings:readSetting("booklore_username") or ""
    self.booklore_password = self.settings:readSetting("booklore_password") or ""
    
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
    
    -- Clean up expired bearer tokens
    if self.db then
        self.db:cleanupExpiredTokens()
    end
    
    -- Initialize API client
    self.api = APIClient:new()
    self.api:init(self.server_url, self.username, self.password, self.db)
    
    -- Initialize updater
    self.updater = Updater:new()
    
    -- Detect plugin directory from current file path
    local source = debug.getinfo(1, "S").source
    local plugin_dir = source:match("@(.*)/")
    if not plugin_dir or not plugin_dir:match("bookloresync%.koplugin$") then
        -- Fallback: use data directory
        plugin_dir = DataStorage:getDataDir() .. "/bookloresync.koplugin"
    end
    
    self.updater:init(plugin_dir, self.db)
    
    -- Auto-update check settings
    self.auto_update_check = self.settings:readSetting("auto_update_check")
    if self.auto_update_check == nil then
        self.auto_update_check = true  -- Default enabled
    end
    
    self.last_update_check = self.settings:readSetting("last_update_check") or 0
    self.update_available = false  -- Flag for menu badge
    
    -- Schedule auto-check for updates (5-second delay, once per day)
    if self.auto_update_check then
        UIManager:scheduleIn(5, function()
            self:autoCheckForUpdates()
        end)
    end
    
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
    
    -- Historical Data submenu
    table.insert(base_menu, {
        text = _("Historical Data"),
        sub_item_table = {
            {
                text = _("Booklore Login"),
                help_text = _("Configure Booklore username and password for accessing the books/search endpoint."),
                callback = function()
                    self:configureBookloreLogin()
                end,
            },
            {
                text = _("Copy Sessions from KOReader"),
                help_text = _("One-time extraction of reading sessions from KOReader's statistics database. This reads page statistics and groups them into sessions. Run this first before matching."),
                enabled_func = function()
                    return self.is_enabled
                end,
                callback = function()
                    self:copySessionsFromKOReader()
                end,
            },
            {
                text = _("Match Historical Data"),
                help_text = _("Match extracted sessions with books on Booklore server. For each unmatched book, searches by title and lets you select the correct match. Matched sessions are automatically synced."),
                enabled_func = function()
                    return self.server_url ~= "" and self.booklore_username ~= "" and self.booklore_password ~= "" and self.is_enabled
                end,
                callback = function()
                    self:matchHistoricalData()
                end,
            },
            {
                text = _("Re-sync Historical Data"),
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
            {
                text = _("View Historical Statistics"),
                help_text = _("Display statistics about historical sessions: total sessions extracted, matched sessions, unmatched sessions, and synced sessions."),
                callback = function()
                    self:viewMatchStatistics()
                end,
            },
        },
    })
    
    -- About & Updates submenu
    table.insert(base_menu, {
        text = self.update_available and _("About & Updates ⚠") or _("About & Updates"),
        sub_item_table = {
            {
                text = _("Version Information"),
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

-- Booklore login configuration for historical data
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
                        
                        -- Now prompt for password
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
                                            
                                            -- Save settings
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
    self.api:init(self.server_url, self.username, self.password, self.db)
    
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
        -- PDF or image-based format
        local current_page = self.ui.document:getCurrentPage()
        local total_pages = self.ui.document:getPageCount()
        if total_pages > 0 then
            -- Store raw percentage with maximum precision
            progress = (current_page / total_pages) * 100
        end
        location = tostring(current_page)
    elseif self.ui.rolling then
        -- EPUB or reflowable format
        local cur_page = self.ui.document:getCurrentPage()
        local total_pages = self.ui.document:getPageCount()
        if total_pages > 0 then
            -- Store raw percentage with maximum precision
            progress = (cur_page / total_pages) * 100
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
        return nil, nil, nil
    end
    
    logger.info("BookloreSync: Looking up book ID for hash:", book_hash)
    
    -- Check database cache first
    local cached_book = self.db:getBookByHash(book_hash)
    if cached_book and cached_book.book_id then
        logger.info("BookloreSync: Found book ID in database cache:", cached_book.book_id)
        return cached_book.book_id, cached_book.isbn10, cached_book.isbn13
    end
    
    -- Not in cache, query server
    logger.info("BookloreSync: Book ID not in cache, querying server")
    
    local success, book_data = self.api:getBookByHash(book_hash)
    
    if not success then
        logger.warn("BookloreSync: Failed to get book from server (offline or error)")
        return nil, nil, nil
    end
    
    if not book_data or not book_data.id then
        logger.info("BookloreSync: Book not found on server")
        return nil, nil, nil
    end
    
    -- Ensure book_id is a number (API might return string)
    local book_id = tonumber(book_data.id)
    if not book_id then
        logger.warn("BookloreSync: Invalid book ID from server:", book_data.id)
        return nil, nil, nil
    end
    
    -- Extract ISBN fields from server response
    local isbn10 = book_data.isbn10 or nil
    local isbn13 = book_data.isbn13 or nil
    
    logger.info("BookloreSync: Found book ID on server:", book_id)
    logger.info("BookloreSync: Book data from server includes ISBN-10:", isbn10, "ISBN-13:", isbn13)
    
    -- Update cache with the book ID and ISBN fields we found
    if cached_book then
        -- We have the hash cached but didn't have the book_id
        -- Use saveBookCache to update all fields including ISBN
        self.db:saveBookCache(
            cached_book.file_path, 
            book_hash, 
            book_id, 
            book_data.title or cached_book.title, 
            book_data.author or cached_book.author,
            isbn10,
            isbn13
        )
        logger.info("BookloreSync: Updated database cache with book ID and ISBN")
    end
    
    -- Return both book_id and ISBN data so caller can save if needed
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
            
            -- Try to look up book ID from server by hash (only if network available)
            local isbn10, isbn13
            if NetworkMgr:isConnected() then
                logger.info("BookloreSync: Network connected, looking up book on server")
                book_id, isbn10, isbn13 = self:getBookIdByHash(file_hash)
                
                if book_id then
                    logger.info("BookloreSync: Book ID found on server:", book_id)
                    if isbn10 or isbn13 then
                        logger.info("BookloreSync: Book has ISBN-10:", isbn10, "ISBN-13:", isbn13)
                    end
                else
                    logger.info("BookloreSync: Book not found on server (not in library)")
                end
            else
                logger.info("BookloreSync: No network connection, skipping server lookup")
                logger.info("BookloreSync: Book will be cached locally and resolved when online")
            end
            
            -- Cache the book info in database (including ISBN if available)
            logger.info("BookloreSync: Calling saveBookCache with:")
            logger.info("  file_path:", file_path, "type:", type(file_path))
            logger.info("  file_hash:", file_hash, "type:", type(file_hash))
            logger.info("  book_id:", book_id, "type:", type(book_id))
            logger.info("  isbn10:", isbn10, "isbn13:", isbn13)
            
            local ok, result = pcall(function()
                return self.db:saveBookCache(file_path, file_hash, book_id, nil, nil, isbn10, isbn13)
            end)
            
            if not ok then
                logger.err("BookloreSync: Error in saveBookCache:", result)
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
    
    -- Get book title and KOReader book ID from statistics database
    local koreader_book_id = nil
    local book_title = nil
    
    if file_hash then
        local koreader_book = self:_getKOReaderBookByHash(file_hash)
        if koreader_book then
            koreader_book_id = koreader_book.koreader_book_id
            book_title = koreader_book.koreader_book_title
            logger.info("BookloreSync: Found in KOReader stats - ID:", koreader_book_id, "Title:", book_title)
        end
    end
    
    -- Fallback: extract from filename if not found in KOReader database
    if not book_title then
        book_title = file_path:match("([^/]+)$") or file_path
        book_title = book_title:gsub("%.[^.]+$", "")  -- Remove extension
        logger.info("BookloreSync: Using filename as title:", book_title)
    end
    
    -- Create session tracking object
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
    
    logger.info("BookloreSync: Session started for '", book_title, "' at", start_progress, "% (location:", start_location, ")")
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
    
    -- Calculate progress delta (store with maximum precision)
    local progress_delta = end_progress - self.current_session.start_progress
    
    -- Format timestamp for API (ISO 8601)
    local function formatTimestamp(unix_time)
        return os.date("!%Y-%m-%dT%H:%M:%SZ", unix_time)
    end
    
    -- Prepare session data
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
Attempt to connect to network with timeout

This function tries to enable WiFi and wait for network connection.
Used when "Connect network on suspend" is enabled.

@return boolean true if connected, false otherwise
--]]
function BookloreSync:connectNetwork()
    local Device = require("device")
    
    -- Check if device has network capability
    if not Device:hasWifiToggle() then
        logger.warn("BookloreSync: Device does not support WiFi toggle")
        return false
    end
    
    -- Check if already connected
    if Device.isOnline and Device:isOnline() then
        logger.info("BookloreSync: Network already connected")
        return true
    end
    
    logger.info("BookloreSync: Attempting to connect to network")
    
    -- Turn on WiFi if it's off
    if not Device:isConnected() then
        logger.info("BookloreSync: Enabling WiFi")
        Device:setWifiState(true)
    end
    
    -- Wait up to 15 seconds for connection
    local timeout = 15
    local elapsed = 0
    local check_interval = 0.5
    
    while elapsed < timeout do
        if Device.isOnline and Device:isOnline() then
            logger.info("BookloreSync: Network connected successfully after", elapsed, "seconds")
            return true
        end
        
        -- Sleep for check_interval seconds
        local ffiutil = require("ffi/util")
        ffiutil.sleep(check_interval)
        elapsed = elapsed + check_interval
    end
    
    logger.warn("BookloreSync: Network connection timeout after", timeout, "seconds")
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
    
    -- Always end current session and queue it
    self:endSession({ silent = true, force_queue = true })
    
    -- Check if force push on suspend is enabled
    if self.force_push_session_on_suspend then
        logger.info("BookloreSync: Force push on suspend enabled")
        
        -- Check if we should connect to network first
        if self.connect_network_on_suspend then
            logger.info("BookloreSync: Attempting to connect to network before sync")
            local network_ok = self:connectNetwork()
            
            if not network_ok then
                logger.warn("BookloreSync: Network connection failed, will attempt sync anyway")
            end
        end
        
        -- Force sync all pending sessions silently
        logger.info("BookloreSync: Force syncing pending sessions on suspend")
        self:syncPendingSessions(true) -- true = silent mode
    else
        logger.info("BookloreSync: Force push on suspend disabled, sessions will sync on resume")
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
    
    logger.info("BookloreSync: Device resuming")
    
    -- Try to sync pending sessions in the background
    if not self.manual_sync_only then
        logger.info("BookloreSync: Attempting background sync on resume")
        self:syncPendingSessions(true) -- silent sync
        
        -- Try to resolve book IDs for cached books (if we have network now)
        if NetworkMgr:isConnected() then
            logger.info("BookloreSync: Network available, checking for unmatched books")
            self:resolveUnmatchedBooks(true) -- silent mode
        end
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
    self.api:init(self.server_url, self.username, self.password, self.db)
    
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
        
        -- Prepare session data for API (apply decimal rounding here)
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
        
        logger.info("BookloreSync: Submitting session", i, "- Book ID:", session.bookId, 
                    "Duration:", duration_formatted)
        
        -- Submit to server
        local success, message = self.api:submitSession(session_data)
        
        if success then
            synced_count = synced_count + 1
            -- Archive to historical_sessions before deleting
            local archived = self.db:archivePendingSession(session.id)
            if not archived then
                logger.warn("BookloreSync: Failed to archive session", i, "to historical_sessions")
            end
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

--[[--
Resolve book IDs for cached books that don't have them yet
Queries the server for books cached while offline
@param silent boolean Don't show UI messages if true
--]]
function BookloreSync:resolveUnmatchedBooks(silent)
    silent = silent or false
    
    if not self.db then
        logger.err("BookloreSync: Database not initialized")
        return
    end
    
    if not NetworkMgr:isConnected() then
        logger.info("BookloreSync: No network connection, skipping book resolution")
        return
    end
    
    -- Get books without book_id
    local unmatched_books = self.db:getAllUnmatchedBooks()
    
    if #unmatched_books == 0 then
        logger.info("BookloreSync: No unmatched books to resolve")
        return
    end
    
    logger.info("BookloreSync: Resolving", #unmatched_books, "unmatched books")
    
    -- Update API client with current credentials
    self.api:init(self.server_url, self.username, self.password, self.db)
    
    local resolved_count = 0
    
    for _, book in ipairs(unmatched_books) do
        if book.file_hash and book.file_hash ~= "" then
            logger.info("BookloreSync: Resolving book:", book.file_path)
            
            local book_id, isbn10, isbn13 = self:getBookIdByHash(book.file_hash)
            
            if book_id then
                logger.info("BookloreSync: Resolved book ID:", book_id)
                -- Update cache with found book_id
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
                logger.info("BookloreSync: Book not found on server")
            end
        end
    end
    
    logger.info("BookloreSync: Resolved", resolved_count, "of", #unmatched_books, "books")
    
    if not silent and resolved_count > 0 and not self.silent_messages then
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
    -- Show processing message
    UIManager:show(InfoMessage:new{
        text = _("Extracting sessions from KOReader database..."),
        timeout = 1,
    })
    
    -- 1. Find statistics.sqlite3
    local stats_db_path = self:_findKOReaderStatisticsDB()
    if not stats_db_path then
        UIManager:show(InfoMessage:new{
            text = _("KOReader statistics database not found"),
            timeout = 3,
        })
        return
    end
    
    logger.info("BookloreSync: Found statistics database at:", stats_db_path)
    
    -- 2. Open statistics database
    local SQ3 = require("lua-ljsqlite3/init")
    local stats_conn = SQ3.open(stats_db_path)
    if not stats_conn then
        UIManager:show(InfoMessage:new{
            text = _("Failed to open statistics database"),
            timeout = 3,
        })
        return
    end
    
    -- 3. Get all books
    local books = self:_getKOReaderBooks(stats_conn)
    logger.info("BookloreSync: Found", #books, "books in statistics")
    
    -- 4. Calculate sessions for each book
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
    
    -- 5. Store in database
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
        -- KOReader stores timestamps as Unix epoch integers (may be cdata)
        -- Strip "LL" suffix from cdata string representation if present
        local timestamp_str = tostring(stat.start_time):gsub("LL$", "")
        local timestamp = tonumber(timestamp_str)
        if not timestamp then
            logger.warn("BookloreSync: Failed to parse timestamp:", stat.start_time)
            goto continue
        end
        
        -- Convert to ISO 8601 for Booklore API
        local iso_time = self:_unixToISO8601(timestamp)
        
        -- Calculate progress as 0-100 percentage (consistent with live sessions)
        local progress = (stat.total_pages and stat.total_pages > 0) 
            and ((stat.page / stat.total_pages) * 100) or 0
        
        if not current_session then
            -- Start first session
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
                local progress_delta = current_session.end_progress - current_session.start_progress
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
                -- Continue current session
                current_session.end_time = iso_time
                current_session.end_timestamp = timestamp
                current_session.end_progress = progress
                current_session.end_page = stat.page
                current_session.duration_seconds = current_session.duration_seconds + (stat.duration or 0)
            end
        end
        
        ::continue::
    end
    
    -- Save final session
    if current_session then
        local progress_delta = current_session.end_progress - current_session.start_progress
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
    
    -- Try auto-matching with priority: Hash → ISBN → File Path
    local book_id = nil
    local matched = 0
    
    if book.md5 and book.md5 ~= "" then
        -- Priority 1: Check by hash
        local cached_book = self.db:getBookByHash(book.md5)
        if cached_book and cached_book.book_id then
            book_id = cached_book.book_id
            matched = 1
            logger.info("BookloreSync: Auto-matched historical book by hash:", book.title, "→ ID:", book_id)
        else
            -- Priority 2: Check by ISBN (if we have cached ISBN for this hash)
            if cached_book and (cached_book.isbn13 or cached_book.isbn10) then
                local isbn_match = self.db:findBookIdByIsbn(cached_book.isbn10, cached_book.isbn13)
                if isbn_match and isbn_match.book_id then
                    book_id = isbn_match.book_id
                    matched = 1
                    logger.info("BookloreSync: Auto-matched historical book by ISBN:", book.title, "→ ID:", book_id)
                end
            end
        end
    end
    
    -- Priority 3: Check by file path (if book file exists)
    if not book_id and book.file and book.file ~= "" then
        local file_cached = self.db:getBookByFilePath(book.file)
        if file_cached and file_cached.book_id then
            book_id = file_cached.book_id
            matched = 1
            logger.info("BookloreSync: Auto-matched historical book by file path:", book.title, "→ ID:", book_id)
        end
    end
    
    -- Add book metadata to each session
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
    -- Query all books from KOReader statistics database
    local books = {}
    
    local stmt = conn:prepare("SELECT id, title, authors, md5 FROM book")
    
    if not stmt then
        logger.err("BookloreSync: Failed to prepare statement:", conn:errmsg())
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
    -- Query KOReader statistics database to get book ID and title by hash
    if not file_hash or file_hash == "" then
        return nil
    end
    
    local stats_db_path = self:_findKOReaderStatisticsDB()
    if not stats_db_path then
        logger.dbg("BookloreSync: Statistics database not found")
        return nil
    end
    
    local SQ3 = require("lua-ljsqlite3/init")
    local stats_conn = SQ3.open(stats_db_path)
    if not stats_conn then
        logger.warn("BookloreSync: Failed to open statistics database")
        return nil
    end
    
    local stmt = stats_conn:prepare("SELECT id, title FROM book WHERE md5 = ?")
    if not stmt then
        logger.warn("BookloreSync: Failed to prepare statement:", stats_conn:errmsg())
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
    -- Query page statistics for a specific book
    local stats = {}
    
    local stmt = conn:prepare([[
        SELECT start_time, duration, total_pages, page 
        FROM page_stat_data 
        WHERE id_book = ? 
        ORDER BY start_time
    ]])
    
    if not stmt then
        logger.err("BookloreSync: Failed to prepare statement:", conn:errmsg())
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
    -- Convert Unix timestamp to ISO 8601 string
    -- Example: 1707648600 -> "2024-02-11T10:30:00Z"
    local date_table = os.date("!*t", timestamp)
    return string.format("%04d-%02d-%02dT%02d:%02d:%02dZ",
        date_table.year, date_table.month, date_table.day,
        date_table.hour, date_table.min, date_table.sec)
end

function BookloreSync:_parseISO8601(iso_string)
    -- Convert ISO 8601 timestamp to Unix time
    -- Example: "2024-02-11T10:30:00Z" -> 1707648600
    
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
    -- Detect book format from title extension
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
    -- Format duration like: "5m 9s", "1h 23m 45s", "45s"
    -- Only include non-zero parts
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
        logger.info("BookloreSync: Found", #matched_unsynced_books, 
                   "books with auto-matched but unsynced sessions")
        self:_autoSyncMatchedSessions(matched_unsynced_books)
        return
    end
    
    -- PHASE 2: Manual matching for truly unmatched books (no book_id)
    self:_startManualMatching()
end

function BookloreSync:_autoSyncMatchedSessions(books)
    -- Auto-sync sessions for books that were matched during extraction
    -- Shows progress indicator similar to re-sync feature
    
    if not books or #books == 0 then
        self:_startManualMatching()
        return
    end
    
    local total_books = #books
    local total_sessions = 0
    for _, book in ipairs(books) do
        total_sessions = total_sessions + book.unsynced_session_count
    end
    
    logger.info("BookloreSync: Auto-syncing", total_sessions, "sessions from", total_books, "matched books")
    
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
        
        UIManager:show(InfoMessage:new{
            text = result_text,
            timeout = 4,
        })
        
        logger.info("BookloreSync: Auto-sync complete - synced:", self.autosync_total_synced,
                   "failed:", self.autosync_total_failed)
        
        -- Clean up state
        self.autosync_books = nil
        self.autosync_index = nil
        self.autosync_total_synced = nil
        self.autosync_total_failed = nil
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
        logger.warn("BookloreSync: No unsynced sessions found for book:", book.koreader_book_title)
        self.autosync_index = self.autosync_index + 1
        self:_syncNextMatchedBook()
        return
    end
    
    -- Sync sessions for this book
    local synced_count = 0
    local failed_count = 0
    
    for _, session in ipairs(sessions) do
        local start_progress = session.start_progress or 0
        local end_progress = session.end_progress or 0
        local progress_delta = session.progress_delta or (end_progress - start_progress)
        local duration_formatted = self:_formatDuration(session.duration_seconds or 0)
        
        local success, message = self.api:submitSession({
            bookId = session.book_id,
            bookType = session.book_type,
            startTime = session.start_time,
            endTime = session.end_time,
            durationSeconds = session.duration_seconds,
            durationFormatted = duration_formatted,
            startProgress = start_progress,
            endProgress = end_progress,
            progressDelta = progress_delta,
            startLocation = session.start_location,
            endLocation = session.end_location,
        })
        
        if success then
            self.db:markHistoricalSessionSynced(session.id)
            synced_count = synced_count + 1
        else
            failed_count = failed_count + 1
            logger.warn("BookloreSync: Failed to sync session for book:", book.koreader_book_title, "Error:", message)
        end
    end
    
    -- Update totals
    self.autosync_total_synced = self.autosync_total_synced + synced_count
    self.autosync_total_failed = self.autosync_total_failed + failed_count
    
    logger.info("BookloreSync: Auto-synced", synced_count, "sessions for:", book.koreader_book_title,
               "(", failed_count, "failed)")
    
    -- Move to next book
    self.autosync_index = self.autosync_index + 1
    self:_syncNextMatchedBook()
end

function BookloreSync:_startManualMatching()
    -- Phase 2: Manual matching for books without book_id
    local unmatched = self.db:getUnmatchedHistoricalBooks()
    
    if not unmatched or #unmatched == 0 then
        UIManager:show(InfoMessage:new{
            text = _("All historical sessions are matched and synced!"),
            timeout = 3,
        })
        return
    end
    
    logger.info("BookloreSync: Starting manual matching for", #unmatched, "books")
    
    -- Start matching process with first unmatched book
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
            logger.info("BookloreSync: Found cached book_id for unmatched book, auto-syncing:", book.koreader_book_title)
            
            -- Mark sessions as matched
            local match_success = self.db:markHistoricalSessionsMatched(book.koreader_book_id, cached_book.book_id)
            
            if not match_success then
                logger.err("BookloreSync: Failed to mark sessions as matched for auto-sync")
                self.matching_index = self.matching_index + 1
                self:_showNextBookMatch()
                return
            end
            
            -- Get sessions and sync directly using the helper function
            local sessions = self.db:getHistoricalSessionsForBook(book.koreader_book_id)
            
            if sessions and #sessions > 0 then
                self:_syncHistoricalSessions(book, sessions, progress_text)
            else
                logger.warn("BookloreSync: No sessions found for auto-matched book")
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
                    
                    logger.info("BookloreSync: ISBN search failed or no results, continuing to hash lookup")
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
    
    local ButtonDialog = require("ui/widget/buttondialog")
    
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
    
    local ButtonDialog = require("ui/widget/buttondialog")
    
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
    
    -- Search by title
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
    
    -- Add match options
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
    
    -- Add skip button
    table.insert(buttons, {{
        text = _("Skip this book"),
        callback = function()
            UIManager:close(self.match_dialog)
            self.matching_index = self.matching_index + 1
            self:_showNextBookMatch()
        end,
    }})
    
    -- Add cancel button
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
    -- Extract book_id from selected_result (can be object or just ID for auto-match)
    local book_id = type(selected_result) == "table" and selected_result.id or selected_result
    local book_title = type(selected_result) == "table" and selected_result.title or book.koreader_book_title
    local isbn10 = type(selected_result) == "table" and selected_result.isbn10 or nil
    local isbn13 = type(selected_result) == "table" and selected_result.isbn13 or nil
    
    logger.info("BookloreSync: Saving match with ISBN-10:", isbn10, "ISBN-13:", isbn13)
    
    -- Mark sessions as matched
    local success = self.db:markHistoricalSessionsMatched(book.koreader_book_id, book_id)
    
    if not success then
        UIManager:show(InfoMessage:new{
            text = _("Failed to save match to database"),
            timeout = 3,
        })
        return
    end
    
    -- Store matched book in book_cache for future syncs
    -- Use the hash from the book record (from historical_sessions)
    if book.book_hash and book.book_hash ~= "" then
        -- Use the hash as a pseudo file path for historical books
        local cache_path = "historical://" .. book.book_hash
        self.db:saveBookCache(cache_path, book.book_hash, book_id, book_title, nil, isbn10, isbn13)
        logger.info("BookloreSync: Cached matched book:", book_title, "with ID:", book_id)
    end
    
    -- Get matched sessions
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
    
    -- Use the helper function to sync sessions
    self:_syncHistoricalSessions(book, sessions, nil)
end

function BookloreSync:_syncHistoricalSessions(book, sessions, progress_text)
    -- Helper function to sync historical sessions for a matched book
    -- Used by both _saveMatchAndSync and auto-sync in _showNextBookMatch
    local synced_count = 0
    local failed_count = 0
    
    for _, session in ipairs(sessions) do
        if not session.synced or session.synced == 0 then
            local start_progress = session.start_progress or 0
            local end_progress = session.end_progress or 0
            local progress_delta = session.progress_delta or (end_progress - start_progress)
            
            -- Format duration
            local duration_formatted = self:_formatDuration(session.duration_seconds or 0)
            
            -- Apply decimal rounding based on config
            local success = self.api:submitSession({
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
            
            if success then
                self.db:markHistoricalSessionSynced(session.id)
                synced_count = synced_count + 1
            else
                failed_count = failed_count + 1
            end
        end
    end
    
    -- Show results
    local result_text = T(_("Synced %1 sessions for:\n%2"), synced_count, book.koreader_book_title)
    if progress_text then
        result_text = result_text .. "\n\n" .. progress_text
    end
    if failed_count > 0 then
        result_text = result_text .. T(_("\n\n%1 sessions failed to sync"), failed_count)
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
    
    logger.info("BookloreSync: Re-syncing", #sessions, "historical sessions")
    
    -- Show initial progress message
    local progress_msg = InfoMessage:new{
        text = T(_("Re-syncing historical sessions...\n\n0 / %1 completed"), #sessions),
    }
    UIManager:show(progress_msg)
    
    local synced_count = 0
    local failed_count = 0
    local not_found_count = 0
    
    for i, session in ipairs(sessions) do
        -- Update progress every 10 sessions or on last session
        if i % 10 == 0 or i == #sessions then
            UIManager:close(progress_msg)
            progress_msg = InfoMessage:new{
                text = T(_("Re-syncing historical sessions...\n\n%1 / %2 completed\n\nSynced: %3\nFailed: %4\n404 errors: %5"),
                    i, #sessions, synced_count, failed_count, not_found_count),
            }
            UIManager:show(progress_msg)
            UIManager:forceRePaint()
        end
        
        local start_progress = session.start_progress or 0
        local end_progress = session.end_progress or 0
        local progress_delta = session.progress_delta or (end_progress - start_progress)
        
        -- Format duration
        local duration_formatted = self:_formatDuration(session.duration_seconds or 0)
        
        -- Submit session with decimal rounding based on config
        local success, message, code = self.api:submitSession({
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
        
        if success then
            synced_count = synced_count + 1
            logger.info("BookloreSync: Re-synced session", i, "of", #sessions)
        else
            -- Check if it's a 404 (book not found)
            if code == 404 then
                logger.warn("BookloreSync: Book ID", session.book_id, "not found (404), marking for re-matching")
                self.db:markHistoricalSessionUnmatched(session.id)
                not_found_count = not_found_count + 1
            else
                logger.warn("BookloreSync: Failed to re-sync session", i, ":", message)
                failed_count = failed_count + 1
            end
        end
    end
    
    -- Close the progress message
    UIManager:close(progress_msg)
    
    -- Show results
    local result_text = T(_("Re-sync complete!\n\nSuccessfully synced: %1\nFailed: %2\nMarked for re-matching (404): %3"), 
        synced_count, failed_count, not_found_count)
    
    if not_found_count > 0 then
        result_text = result_text .. _("\n\nUse 'Match Historical Data' to re-match sessions with 404 errors.")
    end
    
    UIManager:show(InfoMessage:new{
        text = result_text,
        timeout = 5,
    })
    
    logger.info("BookloreSync: Re-sync complete - synced:", synced_count, 
                "failed:", failed_count, "not found:", not_found_count)
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
    
    logger.info("BookloreSync: Syncing", #sessions, "re-matched sessions")
    
    -- Use the existing helper function to sync these sessions
    self:_syncHistoricalSessions(sessions, function(synced_count)
        UIManager:show(InfoMessage:new{
            text = T(_("Successfully synced %1 re-matched session(s)"), synced_count),
            timeout = 3,
        })
    end)
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
        
        -- Show confirmation dialog
        UIManager:show(ConfirmBox:new{
            text = T(_([[Update available!

Current version: %1
Latest version: %2

Download size: %3

Install update now?]]),
                result.current_version,
                result.latest_version,
                size_text),
            ok_text = _("Install"),
            ok_callback = function()
                self:installUpdate(result.release_info.download_url, result.latest_version)
            end,
        })
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
