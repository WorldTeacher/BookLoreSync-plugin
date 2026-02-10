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
local Settings = require("settings")
local Database = require("database")
local logger = require("logger")

local _ = require("gettext")
local T = require("ffi/util").template

-- Load version information
local version_info = require("version")

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
    self.progress_decimal_places = self.settings:readSetting("progress_decimal_places") or 2
    
    -- Sync options
    self.force_push_session_on_suspend = self.settings:readSetting("force_push_session_on_suspend") or false
    self.connect_network_on_suspend = self.settings:readSetting("connect_network_on_suspend") or false
    self.manual_sync_only = self.settings:readSetting("manual_sync_only") or false
    
    -- Historical data tracking
    self.historical_sync_ack = self.settings:readSetting("historical_sync_ack") or false
    
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
                text = _("Minimum Session Duration"),
                help_text = _("Set the minimum number of seconds a reading session must last to be synced. Sessions shorter than this will be discarded. Default is 30 seconds."),
                keep_menu_open = true,
                callback = function()
                    Settings:configureMinDuration(self)
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
    
    -- About/Version menu item
    table.insert(base_menu, {
        text = _("About"),
        keep_menu_open = true,
        callback = function()
            local version_text = T(_("Booklore Sync\n\nVersion: %1\nType: %2\nBuild: %3\nCommit: %4\n\nSyncs reading sessions to Booklore server."),
                version_info.version,
                version_info.version_type,
                version_info.build_date,
                version_info.git_commit)
            
            UIManager:show(InfoMessage:new{
                text = version_text,
                timeout = 5,
            })
        end,
    })
    
    menu_items.booklore_sync = {
        text = _("Booklore Sync"),
        sorting_hint = "tools",
        sub_item_table = base_menu,
    }
end

-- Placeholder stub functions (to be implemented in future steps)
function BookloreSync:testConnection()
    UIManager:show(InfoMessage:new{
        text = _("Test connection - not yet implemented"),
        timeout = 2,
    })
end

function BookloreSync:syncPendingSessions()
    UIManager:show(InfoMessage:new{
        text = _("Sync pending sessions - not yet implemented"),
        timeout = 2,
    })
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
