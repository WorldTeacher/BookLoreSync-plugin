--[[--
Booklore KOReader Plugin

Syncs reading sessions to Booklore server via REST API.

@module koplugin.BookloreSync
--]]--

local DataStorage = require("datastorage")
local Device = require("device")
local Dispatcher = require("dispatcher")
local FileManager = require("apps/filemanager/filemanager")
local Event = require("ui/event")
local EventListener = require("ui/widget/eventlistener")
local InfoMessage = require("ui/widget/infomessage")
local InputDialog = require("ui/widget/inputdialog")
local LuaSettings = require("luasettings")
local NetworkMgr = require("ui/network/manager")
local UIManager = require("ui/uimanager")
local WidgetContainer = require("ui/widget/container/widgetcontainer")
local ConfirmBox = require("ui/widget/confirmbox")
local ButtonDialog = require("ui/widget/buttondialog")
local Menu = require("ui/widget/menu")
local json = require("json")
local Settings = require("booklore_settings")
local Database = require("booklore_database")
local APIClient = require("booklore_api_client")
local HardcoverClient = require("hardcover_api_client")
local Updater = require("booklore_updater")
local FileLogger = require("booklore_file_logger")
local MetadataExtractor = require("booklore_metadata_extractor")
local ShelfSyncModuleFactory = require("booklore_shelf_sync")
local ProgressSyncModuleFactory = require("booklore_progress_sync")
local UpdatesModuleFactory = require("booklore_updates_module")
local PendingSyncModuleFactory = require("booklore_pending_sync")
local MatchingModuleFactory = require("booklore_matching_module")
local DeletionModuleFactory = require("booklore_deletion_module")
local ok_branding, Branding = pcall(require, "booklore_branding")
if not ok_branding or type(Branding) ~= "table" then
    Branding = {
        apply = function(text)
            return text
        end,
        normalizeDisplayName = function(value)
            return (type(value) == "string" and value ~= "") and value or "Booklore"
        end,
        normalizeShortcutName = function(display_name)
            local base = Branding.normalizeDisplayName(display_name)
            local core = base:gsub("[%s_-]*[Ss][Yy][Nn][Cc]$", "")
            if core == "" then
                core = "Booklore"
            end
            return core .. "Sync"
        end,
        getNames = function(display_name)
            local resolved_display = Branding.normalizeDisplayName(display_name)
            local resolved_shortcut = Branding.normalizeShortcutName(resolved_display)
            return resolved_display, resolved_shortcut
        end,
        saveGlobalNames = function()
        end,
    }
end
local logger = require("logger")
local random = require("random")

local gettext = require("gettext")
local _raw = gettext
local function _(text)
    return Branding.apply(_raw(text))
end
local T = require("ffi/util").template
local ffi = require("ffi")
local ffiutil = require("ffi/util")
local lfs = require("libs/libkoreader-lfs")
local strbuf  = require("string.buffer")
local Trapper = require("ui/trapper")

local BookloreSync = WidgetContainer:extend{
    name = "bookloresync",
    is_doc_only = false,
}

local function nowMs()
    return math.floor(os.clock() * 1000)
end

-- Guard flag: ensure FileManager deletion hooks are only applied once per session.
-- Declared at module level so all plugin instances share the same flag.
local booklore_fm_patched = false

--[[--
Redact URLs from log message for secure logging

@param message The log message that may contain URLs
@return string Message with URLs redacted
--]]
---redactUrls.
local function redactUrls(message)
    if type(message) ~= "string" then
        message = tostring(message)
    end
    -- Match http:// or https:// URLs and replace them with [REDACTED_URL]
    return message:gsub("https?://[^%s]+", "[REDACTED_URL]")
end

-- Plugin logger wrappers - writes only to file logger
---BookloreSync:logInfo.
function BookloreSync:logInfo(...)
    local args = {...}
    for i = 1, #args do
        args[i] = redactUrls(args[i])
    end
    
    if self.log_to_file and self.file_logger then
        self.file_logger:write("INFO", table.unpack(args))
    end
end

---BookloreSync:logWarn.
function BookloreSync:logWarn(...)
    local args = {...}
    for i = 1, #args do
        args[i] = redactUrls(args[i])
    end
    
    if self.log_to_file and self.file_logger then
        self.file_logger:write("WARN", table.unpack(args))
    end
end

---BookloreSync:logErr.
function BookloreSync:logErr(...)
    local args = {...}
    for i = 1, #args do
        args[i] = redactUrls(args[i])
    end
    
    if self.log_to_file and self.file_logger then
        self.file_logger:write("ERROR", table.unpack(args))
    end
end

---BookloreSync:logDbg.
function BookloreSync:logDbg(...)
    local args = {...}
    for i = 1, #args do
        args[i] = redactUrls(args[i])
    end
    
    if self.log_to_file and self.file_logger then
        self.file_logger:write("DEBUG", table.unpack(args))
    else
        -- Silent fallback to native logger if file logger not initialized
        logger.dbg(table.unpack(args))
    end
end

local BATCH_UPLOAD_SIZE = 100  -- max sessions per batch upload
local PROGRESS_API_DEBOUNCE_SECONDS = 25
local DEFAULT_NETWORK_CONNECT_TIMEOUT_SECONDS = 15
local PROGRESS_SYNC_STRATEGY = {
    SILENT = "silent",
    PROMPT = "prompt",
    DISABLE = "disable",
}

local DEFAULT_SYNC_DELAY_AFTER_CONNECT_SECONDS = 0

local ShelfSyncModule = ShelfSyncModuleFactory.new({
    _ = _,
    T = T,
    UIManager = UIManager,
    InfoMessage = InfoMessage,
    ButtonDialog = ButtonDialog,
    json = json,
    Trapper = Trapper,
    ffiutil = ffiutil,
    strbuf = strbuf,
})

local ProgressSyncModule = ProgressSyncModuleFactory.new({
    Device = Device,
})

local UpdatesModule = UpdatesModuleFactory.new({
    _ = _,
    T = T,
    logger = logger,
    NetworkMgr = NetworkMgr,
    UIManager = UIManager,
    InfoMessage = InfoMessage,
    ButtonDialog = ButtonDialog,
    ConfirmBox = ConfirmBox,
})

local PendingSyncModule = PendingSyncModuleFactory.new({
    _ = _,
    T = T,
    json = json,
    UIManager = UIManager,
    InfoMessage = InfoMessage,
    Device = Device,
})

local MatchingModule = MatchingModuleFactory.new({
    _ = _,
    T = T,
    UIManager = UIManager,
    InfoMessage = InfoMessage,
    ConfirmBox = ConfirmBox,
    ButtonDialog = ButtonDialog,
})

local DeletionModule = DeletionModuleFactory.new({
    json = json,
    UIManager = UIManager,
})

--[[--

DbSettings - a LuaSettings-compatible wrapper backed by the plugin_settings
SQLite table.

All existing call sites (readSetting / saveSetting / flush) work without any
changes.  Writes are committed immediately to SQLite; flush() is a no-op.

@param db  Database  An initialised Database instance
--]]
local DbSettings = {}
DbSettings.__index = DbSettings

---DbSettings:new.
function DbSettings:new(db)
    local o = { _db = db }
    setmetatable(o, self)
    return o
end

---DbSettings:readSetting.
function DbSettings:readSetting(key)
    return self._db:getPluginSetting(key)
end

---DbSettings:saveSetting.
function DbSettings:saveSetting(key, value)
    local success = self._db:savePluginSetting(key, value)
    if not success then
        logger.err("BookloreSync: Failed to save setting:", key)
    end
    return success
end

---DbSettings:deleteSetting.
function DbSettings:deleteSetting(key)
    if type(self._db.deletePluginSetting) ~= "function" then
        logger.err("BookloreSync: deleteSetting not supported by database backend")
        return false
    end
    local success = self._db:deletePluginSetting(key)
    if not success then
        logger.err("BookloreSync: Failed to delete setting:", key)
    end
    return success
end

-- No-op: SQLite writes are atomic and immediate, no flush needed.
---DbSettings:flush.
function DbSettings:flush()
end

--[[--
Read the configured development-build download URL.

The URL is sourced from a plain text file in the plugin root:
  dev-build.location

The first non-empty line is used. The value must start with http:// or https://.

@return string|nil url
@return string|nil error_message
--]]
---BookloreSync:getDevBuildDownloadURL.
function BookloreSync:getDevBuildDownloadURL()
    if not self.plugin_dir or self.plugin_dir == "" then
        return nil, _("Plugin directory is not available")
    end

    local location_path = self.plugin_dir .. "/dev-build.location"
    local fh = io.open(location_path, "r")
    if not fh then
        return nil, T(_("Missing dev-build.location file:\n%1"), location_path)
    end

    local url = nil
    for line in fh:lines() do
        local trimmed = line:match("^%s*(.-)%s*$")
        if trimmed and trimmed ~= "" then
            url = trimmed
            break
        end
    end
    fh:close()

    if not url then
        return nil, _("dev-build.location is empty")
    end

    if not url:match("^https?://") then
        return nil, _("dev-build.location must contain an http(s) URL")
    end

    return url, nil
end

---BookloreSync:hasDevBuildLocationFile.
function BookloreSync:hasDevBuildLocationFile()
    if not self.plugin_dir or self.plugin_dir == "" then
        return false
    end

    local location_path = self.plugin_dir .. "/dev-build.location"
    local fh = io.open(location_path, "r")
    if not fh then
        return false
    end

    fh:close()
    return true
end

---BookloreSync:isAirplaneModeActive.
function BookloreSync:isAirplaneModeActive()
    if not G_reader_settings then
        return false
    end

    local candidate_keys = {
        "airplanemode",
        "airplane_mode",
        "airplaneMode",
    }

    for _, key in ipairs(candidate_keys) do
        local ok_apm, apm = pcall(function()
            return G_reader_settings:readSetting(key)
        end)

        if ok_apm and (apm == true or apm == 1 or apm == "1" or apm == "true") then
            return true
        end
    end

    return false
end

---BookloreSync:isAirplaneModePluginInstalled.
function BookloreSync:isAirplaneModePluginInstalled()
    local seen = {}
    local candidates = {}

    local function normalizePath(path)
        if type(path) ~= "string" then
            return nil
        end
        local trimmed = path:gsub("/*$", "")
        if trimmed == "" then
            return nil
        end
        return trimmed
    end

    local function addCandidate(path)
        local normalized = normalizePath(path)
        if not normalized or seen[normalized] then
            return
        end
        seen[normalized] = true
        table.insert(candidates, normalized)
    end

    local function addRootCandidates(root)
        local normalized_root = normalizePath(root)
        if not normalized_root then
            return
        end
        addCandidate(normalized_root .. "/plugins/airplanemode.koplugin")
        addCandidate(normalized_root .. "/airplanemode.koplugin")
    end

    addRootCandidates(DataStorage:getDataDir())
    addRootCandidates(DataStorage:getSettingsDir())

    local function parentDir(path)
        local normalized = normalizePath(path)
        if not normalized then
            return nil
        end
        local parent = normalized:match("^(.*)/[^/]+$")
        return normalizePath(parent)
    end

    if self and self.path then
        addRootCandidates(parentDir(self.path))
    end
    if self and self.plugin_dir then
        addRootCandidates(parentDir(self.plugin_dir))
    end

    for _, path in ipairs(candidates) do
        local attrs = lfs.attributes(path)
        if attrs and attrs.mode == "directory" then
            return true
        end
    end

    return false
end

---BookloreSync:getCurrentNetworkSSID.
-- Best-effort detection of the currently connected WiFi network name.
-- Returns the SSID string when available, or nil when unknown
-- (e.g. running on the emulator/desktop, no WiFi backend, etc.).
function BookloreSync:getCurrentNetworkSSID()
    if not NetworkMgr or type(NetworkMgr.getCurrentNetwork) ~= "function" then
        return nil
    end
    local ok, info = pcall(NetworkMgr.getCurrentNetwork, NetworkMgr)
    if not ok or type(info) ~= "table" then
        return nil
    end
    local ssid = info.ssid
    if type(ssid) ~= "string" or ssid == "" then
        return nil
    end
    return ssid
end

---BookloreSync:isOnConfiguredHomeNetwork.
-- True when automatic network switching is disabled (feature off → always allow),
-- or when enabled and the current SSID matches the configured one.
function BookloreSync:isOnConfiguredHomeNetwork()
    if not self.auto_network_switch_enabled then
        return true
    end
    local target = self.home_network_ssid
    if type(target) ~= "string" or target == "" then
        -- Feature enabled but unconfigured: do not gate sync, behave as before.
        return true
    end
    local current = self:getCurrentNetworkSSID()
    if not current then
        return false
    end
    return current == target
end

---BookloreSync:resolveServerUrl.
-- Returns the URL the plugin should currently use to reach Booklore.
-- The "preferred" URL is whichever fits the current state; if it isn't
-- configured, the other one is used as a fallback so a user with only a
-- single URL still gets a working setup regardless of the toggle.
--
-- State / preference matrix:
--   auto-switch off        → prefer local, fall back to remote
--   auto-switch on, home   → prefer local, fall back to remote
--   auto-switch on, away   → prefer remote, fall back to local
function BookloreSync:resolveServerUrl()
    local local_url  = self.local_server_url  or ""
    local remote_url = self.remote_server_url or ""

    local prefer_remote = false
    if self.auto_network_switch_enabled and not self:isOnConfiguredHomeNetwork() then
        prefer_remote = true
    end

    local preferred = prefer_remote and remote_url or local_url
    local fallback  = prefer_remote and local_url  or remote_url
    if preferred ~= "" then
        return preferred
    end
    return fallback
end

---BookloreSync:refreshEffectiveServerUrl.
-- Recomputes the effective URL and, if it changed, updates `self.server_url`
-- and reinitialises the API client so subsequent calls hit the right host.
-- Returns the effective URL.
function BookloreSync:refreshEffectiveServerUrl()
    local effective = self:resolveServerUrl() or ""
    if effective ~= (self.server_url or "") then
        self.server_url = effective
        if self.api and effective ~= "" then
            local ok = pcall(function()
                self.api:init(self.server_url, self.username, self.password, self.db)
            end)
            if not ok then
                -- Best effort; the next explicit api:init call will succeed.
            end
        end
    end
    return effective
end

---BookloreSync:isNetworkConnected.
function BookloreSync:isNetworkConnected()
    if not NetworkMgr then
        return false
    end

    local checks = {
        "isConnected",
        "isOnline",
    }

    for _, method in ipairs(checks) do
        if type(NetworkMgr[method]) == "function" then
            local ok, connected = pcall(NetworkMgr[method], NetworkMgr)
            if not ok then
                ok, connected = pcall(NetworkMgr[method])
            end
            if ok and connected then
                -- Opportunistically point the API client at the right host
                -- based on the current SSID before any sync call runs.
                pcall(function() self:refreshEffectiveServerUrl() end)
                return true
            end
        end
    end

    return false
end

---BookloreSync:showAirplaneModePluginMissingWarning.
function BookloreSync:showAirplaneModePluginMissingWarning()
    UIManager:show(InfoMessage:new{
        text = _("Airplanemode plugin is not installed"),
        timeout = 2,
    })
end

---BookloreSync:applyAirplaneModeSyncModeIntegration.
function BookloreSync:applyAirplaneModeSyncModeIntegration()
    if not self.airplanemode_sync_mode_enabled then
        return
    end

    if not self:isAirplaneModePluginInstalled() then
        return
    end

    local desired_mode = self:isAirplaneModeActive() and "manual" or "automatic"
    if self.sync_mode ~= desired_mode then
        self:logInfo("BookloreSync: Airplanemode integration switching sync mode to", desired_mode)
        self:setSyncMode(desired_mode)
    end
end

---BookloreSync:init.
function BookloreSync:init()
    if G_reader_settings:hasNot("device_id") then
        G_reader_settings:saveSetting("device_id", random.uuid())
    end

    -- Load plugin-specific translations into KOReader's global gettext singleton.
    -- KOReader uses a single shared gettext instance (textdomain "koreader"), so
    -- we patch in our own .mo file by calling loadMO() directly.  This must be
    -- done before any _() calls are evaluated at runtime.
    local gettext = require("gettext")
    local lang = gettext.current_lang
    if lang and lang ~= "C" and lang ~= "en" then
        -- Normalise e.g. "de_DE" → "de" as a fallback when exact match is absent
        local mo_path = self.path .. "/locale/" .. lang .. "/LC_MESSAGES/bookloresync.mo"
        local f = io.open(mo_path, "r")
        if f then
            f:close()
            if gettext.loadMO then gettext.loadMO(mo_path) end
        else
            -- Try short language code (e.g. "de" from "de_DE")
            local short_lang = lang:match("^(%a+)")
            if short_lang and short_lang ~= lang then
                mo_path = self.path .. "/locale/" .. short_lang .. "/LC_MESSAGES/bookloresync.mo"
                f = io.open(mo_path, "r")
                if f then
                    f:close()
                    if gettext.loadMO then gettext.loadMO(mo_path) end
                end
            end
        end
    end

    -- Bootstrap phase: open the legacy LuaSettings file so that settings needed
    -- before the database is ready (log_to_file) can be read.
    -- Once the database has been initialised and migration 10 has run, self.settings
    -- is replaced with a DbSettings wrapper so all subsequent reads and writes go
    -- directly to SQLite.  The LuaSettings file is deleted by the migration hook.
    local bootstrap_settings = LuaSettings:open(DataStorage:getSettingsDir() .. "/booklore.lua")
    self.settings = bootstrap_settings

    -- Initialize SQLite database (runs migrations, including migration 10 which
    -- copies booklore.lua → plugin_settings and deletes the source file)
    self.db = Database:new(self)
    local db_initialized = self.db:init()

    if not db_initialized then
        logger.err("BookloreSync: Failed to initialize database")
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

    -- Backwards-compat: `server_url` was historically the single configured
    -- URL. With automatic network switching it splits into a local and a
    -- remote URL. The legacy key is treated as the local URL when the new
    -- `local_server_url` key is absent.
    local legacy_server_url = self.settings:readSetting("server_url") or ""
    self.local_server_url   = self.settings:readSetting("local_server_url")
    if self.local_server_url == nil or self.local_server_url == "" then
        self.local_server_url = legacy_server_url
    end
    self.remote_server_url = self.settings:readSetting("remote_server_url") or ""
    self.username = self.settings:readSetting("username") or ""
    self.password = self.settings:readSetting("password") or ""

    -- Automatic network switching: when enabled, the plugin uses the
    -- local URL while connected to the configured home WiFi and falls back
    -- to the remote URL otherwise.
    self.auto_network_switch_enabled = self.settings:readSetting("auto_network_switch_enabled")
    if self.auto_network_switch_enabled == nil then
        self.auto_network_switch_enabled = false
    end
    self.home_network_ssid = self.settings:readSetting("home_network_ssid") or ""

    -- Compute the runtime effective URL. `self.server_url` remains the
    -- field every existing call site reads, but its value now depends on
    -- the current network when auto-switch is on.
    self.server_url = self:resolveServerUrl()

    local local_brand_display = self.settings:readSetting("booklore_brand_display_name")
    self.brand_display_name, self.brand_shortcut_name = Branding.getNames(local_brand_display)
    if local_brand_display and local_brand_display ~= "" then
        Branding.saveGlobalNames(self.brand_display_name)
    end

    self.is_enabled      = self.settings:readSetting("is_enabled")      or false
    self.log_to_file     = self.settings:readSetting("log_to_file")     or false
    self.silent_messages = self.settings:readSetting("silent_messages") or false

    self.min_duration             = self.settings:readSetting("min_duration")             or 30
    self.min_pages                = self.settings:readSetting("min_pages")                or 5
    self.session_detection_mode   = self.settings:readSetting("session_detection_mode")   or "duration" -- "duration" or "pages"
    self.progress_decimal_places  = self.settings:readSetting("progress_decimal_places")  or 2

    -- KOReader progress sync settings
    self.progress_sync_enabled = self.settings:readSetting("progress_sync_enabled")
    if self.progress_sync_enabled == nil then
        self.progress_sync_enabled = false
    end
    self.progress_sync_trigger = self.settings:readSetting("progress_sync_trigger") or "book_open_close"
    self.progress_sync_interval_pages = tonumber(self.settings:readSetting("progress_sync_interval_pages")) or 10
    self.progress_sync_page_updates_enabled = self.settings:readSetting("progress_sync_page_updates_enabled")
    if self.progress_sync_page_updates_enabled == nil then
        self.progress_sync_page_updates_enabled = true
    end
    if self.progress_sync_interval_pages < 1 then
        self.progress_sync_interval_pages = 1
    end
    if not self.progress_sync_page_updates_enabled then
        self.progress_sync_trigger = "book_open_close"
    else
        self.progress_sync_trigger = "each_n_pages"
    end
    self.progress_sync_set_read_on_rating = self.settings:readSetting("progress_sync_set_read_on_rating")
    if self.progress_sync_set_read_on_rating == nil then
        -- Backward-compat migration from previous experimental option name.
        self.progress_sync_set_read_on_rating = self.settings:readSetting("progress_sync_set_on_rating_manual")
    end
    if self.progress_sync_set_read_on_rating == nil then
        self.progress_sync_set_read_on_rating = false
    end
    self.progress_sync_normalize_session_locations = self.settings:readSetting("progress_sync_normalize_session_locations")
    if self.progress_sync_normalize_session_locations == nil then
        self.progress_sync_normalize_session_locations = false
    end
    self.progress_sync_last_push_ts = 0
    self.progress_sync_page_counter = 0
    self.progress_sync_last_page = -1
    self.progress_sync_page_update_primed = false
    self.progress_sync_last_page_turn_timestamp = 0
    self.progress_sync_ignore_next_page_event = false
    self.progress_sync_debounce_seconds = tonumber(self.settings:readSetting("progress_sync_debounce_seconds"))
    if self.progress_sync_debounce_seconds == nil then
        self.progress_sync_debounce_seconds = PROGRESS_API_DEBOUNCE_SECONDS
    end
    if self.progress_sync_debounce_seconds < 0 then
        self.progress_sync_debounce_seconds = 0
    end
    self.progress_sync_fasttrack_in_flight = false
    self.progress_sync_background_flush_scheduled = false
    self.progress_sync_background_flush_running = false
    self.progress_sync_background_idle_seconds = 2
    self.progress_sync_background_interval_seconds = 2
    self.progress_sync_device_id = G_reader_settings:readSetting("device_id")
    self.progress_pull_on_open = self.settings:readSetting("progress_pull_on_open")
    if self.progress_pull_on_open == nil then
        self.progress_pull_on_open = true
    end
    self.progress_pull_on_resume = self.settings:readSetting("progress_pull_on_resume")
    if self.progress_pull_on_resume == nil then
        self.progress_pull_on_resume = true
    end
    self.progress_sync_forward_strategy = self.settings:readSetting("progress_sync_forward_strategy") or PROGRESS_SYNC_STRATEGY.PROMPT
    self.progress_sync_backward_strategy = self.settings:readSetting("progress_sync_backward_strategy") or PROGRESS_SYNC_STRATEGY.DISABLE
    self.sync_delay_after_connect_seconds = tonumber(self.settings:readSetting("sync_delay_after_connect_seconds"))
    if self.sync_delay_after_connect_seconds == nil then
        self.sync_delay_after_connect_seconds = DEFAULT_SYNC_DELAY_AFTER_CONNECT_SECONDS
    end
    if self.sync_delay_after_connect_seconds < 0 then
        self.sync_delay_after_connect_seconds = 0
    end

    local legacy_force_push_on_suspend = self.settings:readSetting("force_push_session_on_suspend") or false
    local legacy_connect_network_on_suspend = self.settings:readSetting("connect_network_on_suspend") or false
    local legacy_manual_sync_only = self.settings:readSetting("manual_sync_only") or false
    self.sync_mode = self.settings:readSetting("sync_mode") -- "automatic" or "manual"
    self.network_connect_timeout_seconds = tonumber(self.settings:readSetting("network_connect_timeout_seconds"))
    if self.network_connect_timeout_seconds == nil then
        self.network_connect_timeout_seconds = DEFAULT_NETWORK_CONNECT_TIMEOUT_SECONDS
    end
    if self.network_connect_timeout_seconds < 1 then
        self.network_connect_timeout_seconds = 1
    end
    self.network_connect_run_until_connect = self.settings:readSetting("network_connect_run_until_connect")
    if self.network_connect_run_until_connect == nil then
        self.network_connect_run_until_connect = false
    end
    self.manual_sync_only = false
    self.force_push_session_on_suspend = false
    self.connect_network_on_suspend = false
    self.airplanemode_sync_mode_enabled = self.settings:readSetting("airplanemode_sync_mode_enabled")
    if self.airplanemode_sync_mode_enabled == nil then
        self.airplanemode_sync_mode_enabled = false
    end

    -- Shelf sync settings
    self.booklore_shelf_name         = self.settings:readSetting("booklore_shelf_name")  or "KOReader"
    self.shelf_id                    = self.settings:readSetting("shelf_id")
    self.download_dir                = self.settings:readSetting("download_dir")
                                       or self:_detectDefaultDownloadDir()
    self.auto_sync_shelf_on_resume   = self.settings:readSetting("auto_sync_shelf_on_resume")
    if self.auto_sync_shelf_on_resume == nil then
        self.auto_sync_shelf_on_resume = false  -- Default disabled
    end
    self.delete_removed_shelf_books  = self.settings:readSetting("delete_removed_shelf_books")
    if self.delete_removed_shelf_books == nil then
        self.delete_removed_shelf_books = false  -- Default disabled for safety
    end
    self.shelf_use_original_filename = self.settings:readSetting("shelf_use_original_filename")
    if self.shelf_use_original_filename == nil then
        self.shelf_use_original_filename = true  -- Default: use original server filename
    end
    self.delete_sdr_on_book_delete   = self.settings:readSetting("delete_sdr_on_book_delete")
    if self.delete_sdr_on_book_delete == nil then
        self.delete_sdr_on_book_delete = false  -- Default disabled for safety
    end
    self.min_free_space_mb = self.settings:readSetting("min_free_space_mb")
    if self.min_free_space_mb == nil then
        self.min_free_space_mb = 500  -- Default: 500MB minimum free space
    end

    -- Resume/wake-sync state (not persisted - reset each session)
    self.last_auto_sync_time  = 0     -- unix timestamp of last auto-sync (cooldown guard)
    self.needs_wake_sync      = false -- flagged by onResume; consumed by onNetworkConnected
    self.wake_sync_scheduled  = false -- prevents duplicate scheduled wake syncs

    -- Deferred close-flush state (phase 3)
    self.deferred_close_flush_requested = false
    self.deferred_close_flush_scheduled = false
    self.deferred_close_flush_running = false
    self.deferred_close_flush_seq = 0
    self.deferred_close_flush_last_queued_ms = 0
    self.deferred_close_flush_last_completed_ms = 0

    -- Enforce two-mode sync model and migrate legacy/custom settings.
    if self.sync_mode ~= "automatic" and self.sync_mode ~= "manual" then
        if legacy_manual_sync_only then
            self.sync_mode = "manual"
        elseif legacy_force_push_on_suspend and legacy_connect_network_on_suspend then
            self.sync_mode = "automatic"
        else
            -- Safety-first default for legacy/custom setups.
            self.sync_mode = "manual"
        end
    end
    self:setSyncMode(self.sync_mode)

    -- Remove retired setting keys from previous sync-mode model.
    if self.db and type(self.db.deletePluginSetting) == "function" then
        local ok_delete, delete_err = pcall(function()
            self.db:deletePluginSetting("ask_wifi_enable")
        end)
        if not ok_delete then
            self:logWarn("BookloreSync: Failed to delete retired setting ask_wifi_enable:", tostring(delete_err))
        end
    end

    self.historical_sync_ack = self.settings:readSetting("historical_sync_ack") or false

    self.booklore_username = self.settings:readSetting("booklore_username") or ""
    self.booklore_password = self.settings:readSetting("booklore_password") or ""
    self.hardcover_token   = self.settings:readSetting("hardcover_token")   or ""

    self.rating_sync_enabled                = self.settings:readSetting("rating_sync_enabled")                or false
    self.hardcover_rating_sync_enabled      = self.settings:readSetting("hardcover_rating_sync_enabled")      or false
    self.rating_sync_mode                   = self.settings:readSetting("rating_sync_mode")                   or "koreader_scaled"
    self.highlights_notes_sync_enabled = self.settings:readSetting("highlights_notes_sync_enabled") or false
    self.notes_destination             = self.settings:readSetting("notes_destination")             or "in_book"
    self.upload_strategy               = self.settings:readSetting("upload_strategy")               or "on_session"
    self.bookmarks_sync_enabled        = self.settings:readSetting("bookmarks_sync_enabled")        or false
    self.enable_spine_context_cache = self.settings:readSetting("enable_spine_context_cache")
    if self.enable_spine_context_cache == nil then
        self.enable_spine_context_cache = true
    end

    self.epub_context_cache = nil
    self.spine_cache_stats = {
        hit = 0,
        miss = 0,
    }

    self.current_session = nil
    
    if self.db then
        self.db:cleanupExpiredTokens()
    end

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

    self.api = APIClient:new(self)
    self.api:init(self.server_url, self.username, self.password, self.db)

    self.hc_api = HardcoverClient:new({ db = self.db, plugin = self })
    
    self.metadata_extractor = MetadataExtractor:new({plugin = self})
    self:logInfo("BookloreSync: Metadata extractor initialized")
    
    self.updater = Updater:new(self)
    
    local source = debug.getinfo(1, "S").source
    local plugin_dir = source:match("@(.*)/")
    if not plugin_dir or not plugin_dir:match("bookloresync%.koplugin$") then
        -- Fallback: use data directory
        plugin_dir = DataStorage:getDataDir() .. "/bookloresync.koplugin"
    end
    
    self.plugin_dir = plugin_dir
    self.updater:init(plugin_dir, self.db)
    
    self.auto_update_check = self.settings:readSetting("auto_update_check")
    if self.auto_update_check == nil then
        self.auto_update_check = true  -- Default enabled
    end

    self.use_dev_builds = self.settings:readSetting("use_dev_builds")
    if self.use_dev_builds == nil then
        self.use_dev_builds = false
    end

    if self.use_dev_builds and not self:hasDevBuildLocationFile() then
        self.use_dev_builds = false
        self.settings:saveSetting("use_dev_builds", false)
        self.settings:flush()
        self:logInfo("BookloreSync: Disabled dev-build channel (dev-build.location missing)")
    end
    
    self.last_update_check = self.settings:readSetting("last_update_check") or 0
    self.update_available = false
    
    if self.auto_update_check then
        UIManager:scheduleIn(5, function()
            self:autoCheckForUpdates()
        end)
    end
    
    self.ui.menu:registerToMainMenu(self)

    -- Register file manager long-press (hold) dialog buttons.
    -- Register on the FileManager CLASS table (not a live instance), matching the
    -- coverbrowser pattern: FileManager.addFileDialogButtons(FileManager, id, func).
    -- showFileDialog reads file_manager.file_dialog_added_buttons where file_manager is
    -- the live instance; Lua's __index chain finds the entry on the class table.
    -- Registration must be unconditional - init() is always called from the reader
    -- context where self.ui.file_chooser is nil.
    -- Row 1: primary actions
    FileManager.addFileDialogButtons(FileManager, "booklore_sync_actions_row1", function(file, is_file, _book_props)
        if not is_file then return nil end
        return {
            {
                text = _("Booklore Sync"),
                callback = function()
                    local fc = FileManager.instance and FileManager.instance.file_chooser
                    if fc and fc.file_dialog then UIManager:close(fc.file_dialog) end
                    self:_fileDialogBookloreSync(file)
                end,
            },
            {
                text = _("Match Book"),
                callback = function()
                    local fc = FileManager.instance and FileManager.instance.file_chooser
                    if fc and fc.file_dialog then UIManager:close(fc.file_dialog) end
                    self:fileDialogMatchBook(file)
                end,
            },
        }
    end)
    -- Row 2: data actions
    FileManager.addFileDialogButtons(FileManager, "booklore_sync_actions_row2", function(file, is_file, _book_props)
        if not is_file then return nil end
        return {
            {
                text = _("Show Stored Data"),
                callback = function()
                    local fc = FileManager.instance and FileManager.instance.file_chooser
                    if fc and fc.file_dialog then UIManager:close(fc.file_dialog) end
                    self:fileDialogShowStoredData(file)
                end,
            },
            {
                text = _("Extract from Sidecar"),
                callback = function()
                    local fc = FileManager.instance and FileManager.instance.file_chooser
                    if fc and fc.file_dialog then UIManager:close(fc.file_dialog) end
                    self:fileDialogExtractFromSidecar(file)
                end,
            },
        }
    end)
    -- Row 3: tracking + status actions
    FileManager.addFileDialogButtons(FileManager, "booklore_sync_actions_row3", function(file, is_file, _book_props)
        if not is_file then return nil end
        return {
            {
                text_func = function()
                    if self.db and not self.db:isBookTrackingEnabled(file) then
                        return _("Enable tracking")
                    end
                    return _("Disable tracking")
                end,
                callback = function()
                    local fc = FileManager.instance and FileManager.instance.file_chooser
                    if fc and fc.file_dialog then UIManager:close(fc.file_dialog) end
                    self:fileDialogToggleTracking(file)
                end,
            },
            {
                text = _("Set Reading Status"),
                callback = function()
                    local fc = FileManager.instance and FileManager.instance.file_chooser
                    if fc and fc.file_dialog then UIManager:close(fc.file_dialog) end
                    self:fileDialogSetReadingStatus(file)
                end,
            },
        }
    end)

    self:registerDispatcherActions()

    -- Patch FileManager deletion methods to notify Booklore when a book is
    -- deleted from the file browser.  Applied once per session via the module-
    -- level guard flag so multiple plugin reloads don't stack the patch.
    local booklore_self = self
    local ok_fm, FileManagerMod = pcall(require, "apps/filemanager/filemanager")
    if ok_fm and FileManagerMod and not booklore_fm_patched then
        booklore_fm_patched = true

        -- Single-file deletion
        local orig_deleteFile = FileManagerMod.deleteFile
        FileManagerMod.deleteFile = function(fm_self, file, is_file)
            local hash, stem, book_id = nil, nil, nil
            if is_file then
                hash, stem, book_id = booklore_self:preDeleteHook(file)
            end
            local result = orig_deleteFile(fm_self, file, is_file)
            if hash and stem then
                UIManager:scheduleIn(0.5, function()
                    booklore_self:notifyBookloreOnDeletion(hash, stem, book_id)
                end)
            end
            return result
        end

        -- Bulk-select deletion
        local orig_deleteSelectedFiles = FileManagerMod.deleteSelectedFiles
        FileManagerMod.deleteSelectedFiles = function(fm_self)
            local to_sync = {}
            for _, file in ipairs(fm_self.selected_files or {}) do
                local resolved = require("ffi/util").realpath(file)
                local h, s, b = booklore_self:preDeleteHook(resolved)
                if h then
                    table.insert(to_sync, { hash = h, stem = s, book_id = b })
                end
            end
            local result = orig_deleteSelectedFiles(fm_self)
            local delay = 0.5
            for _, item in ipairs(to_sync) do
                UIManager:scheduleIn(delay, function()
                    booklore_self:notifyBookloreOnDeletion(item.hash, item.stem, item.book_id)
                end)
                delay = delay + 0.5
            end
            return result
        end

        self:logInfo("BookloreSync: FileManager deletion hooks installed")
    end
end

---BookloreSync:onExit.
function BookloreSync:onExit()
    FileManager.removeFileDialogButtons(FileManager, "booklore_sync_actions_row1")
    FileManager.removeFileDialogButtons(FileManager, "booklore_sync_actions_row2")
    FileManager.removeFileDialogButtons(FileManager, "booklore_sync_actions_row3")

    if self.db then
        self.db:close()
    end
    
    if self.file_logger then
        self.file_logger:close()
    end
end

---BookloreSync:registerDispatcherActions.
function BookloreSync:registerDispatcherActions()
    Dispatcher:registerAction("booklore_toggle_sync", {
        category = "none",
        event = "ToggleBookloreSync",
        title = _("BookLoreSync: Toggle Sync"),
        general = true,
    })
    
    Dispatcher:registerAction("booklore_sync_pending", {
        category = "none",
        event = "SyncBooklorePending",
        title = _("BookLoreSync: Sync Pending Items"),
        general = true,
    })

    -- Register Manual Sync Only toggle action
    Dispatcher:registerAction("booklore_toggle_manual_sync_only", {
        category = "none",
        event = "ToggleBookloreManualSyncOnly",
        title = _("BookLoreSync: Toggle Booklore Manual Sync Only"),
        general = true,
    })
    
    Dispatcher:registerAction("booklore_test_connection", {
        category = "none",
        event = "TestBookloreConnection",
        title = _("BookLoreSync: Test Connection"),
        general = true,
    })
    Dispatcher:registerAction("booklore_sync_shelf", {
        category = "none",
        event = "SyncBookloreShelf",
        title = _("BookLoreSync: Sync from Booklore Shelf"),
        general = true,
    })
    Dispatcher:registerAction("booklore_pull_current_book_progress", {
        category = "none",
        event = "PullBookloreCurrentBookProgress",
        title = _("BookLoreSync: Pull Current Book Progress"),
        general = true,
    })
    Dispatcher:registerAction("booklore_push_current_book_progress", {
        category = "none",
        event = "PushBookloreCurrentBookProgress",
        title = _("BookLoreSync: Push Current Book Progress"),
        general = true,
    })
end

---BookloreSync:onSyncBookloreShelf.
function BookloreSync:showWifiUnavailableInfo(wifi_text, airplane_text, timeout)
    local message = wifi_text
    if self:isAirplaneModeActive() then
        message = airplane_text or _("Airplane mode is enabled - network action skipped")
    end
    UIManager:show(InfoMessage:new{
        text = message,
        timeout = timeout or 2,
    })
end

---BookloreSync:onSyncBookloreShelf.
function BookloreSync:onSyncBookloreShelf()
    if not (self.booklore_username and self.booklore_username ~= "" and
            self.booklore_password and self.booklore_password ~= "") then
        UIManager:show(InfoMessage:new{
            text = _("Booklore credentials not configured"),
            timeout = 2,
        })
        return true
    end
    local was_connected = self:isNetworkConnected()

    self:_requestWifi(_("sync Booklore shelf"), function()
        self:syncFromBookloreShelf(false, function()
            if was_connected then
                return
            end

            -- Respect KOReader's global post-WiFi policy (leave on / turn off / prompt)
            -- after shelf sync actually completes.
            local handled = false
            if type(NetworkMgr.afterWifiAction) == "function" then
                local ok_after, after_err = pcall(function()
                    if type(NetworkMgr.setBeforeActionFlag) == "function" then
                        NetworkMgr:setBeforeActionFlag()
                    end
                    NetworkMgr:afterWifiAction()
                end)
                if ok_after then
                    handled = true
                    self:logInfo("BookloreSync: Shelf sync completed KOReader after-WiFi action")
                else
                    self:logWarn("BookloreSync: Shelf sync post-WiFi action failed:", tostring(after_err))
                end
            end

            if not handled then
                local ok_disconnect, disconnected = pcall(function()
                    return self:disconnectNetwork()
                end)
                if not ok_disconnect then
                    self:logWarn("BookloreSync: Shelf sync fallback WiFi disable crashed:", tostring(disconnected))
                elseif disconnected then
                    self:logInfo("BookloreSync: Shelf sync disabled WiFi via fallback")
                else
                    self:logWarn("BookloreSync: Shelf sync could not disable WiFi via fallback")
                end
            end
        end)
    end, function()
        self:showWifiUnavailableInfo(
            _("WiFi not enabled - shelf sync skipped"),
            _("Airplane mode is enabled - shelf sync skipped")
        )
    end)
    return true
end

---BookloreSync:hasOpenDocumentForProgressSync.
function BookloreSync:hasOpenDocumentForProgressSync()
    return self.ui and self.ui.document and self.ui.document.file and self.ui.document.file ~= ""
end

---BookloreSync:onPullBookloreCurrentBookProgress.
function BookloreSync:onPullBookloreCurrentBookProgress()
    if not self:hasOpenDocumentForProgressSync() then
        UIManager:show(InfoMessage:new{
            text = _("Open a book to pull progress"),
            timeout = 2,
        })
        return true
    end
    if not self.progress_sync_enabled then
        UIManager:show(InfoMessage:new{
            text = _("Progress sync is disabled"),
            timeout = 2,
        })
        return true
    end

    self:_requestWifi(_("pull current book progress"), function()
        self:pullKoreaderProgress(true)
    end, function()
        self:showWifiUnavailableInfo(
            _("WiFi not enabled - pull skipped"),
            _("Airplane mode is enabled - pull skipped")
        )
    end, {
        disable_wifi_when_done = true,
    })
    return true
end

---BookloreSync:onPushBookloreCurrentBookProgress.
function BookloreSync:onPushBookloreCurrentBookProgress()
    if not self:hasOpenDocumentForProgressSync() then
        UIManager:show(InfoMessage:new{
            text = _("Open a book to push progress"),
            timeout = 2,
        })
        return true
    end
    if not self.progress_sync_enabled then
        UIManager:show(InfoMessage:new{
            text = _("Progress sync is disabled"),
            timeout = 2,
        })
        return true
    end

    self:_requestWifi(_("push current book progress"), function()
        local payload, payload_err = self:buildCurrentKoreaderProgressPayload(os.time())
        if not payload then
            UIManager:show(InfoMessage:new{
                text = T(_("Could not build current progress payload: %1"), tostring(payload_err or "unknown error")),
                timeout = 2,
            })
            return
        end

        local ok, reason = self:pushCurrentKoreaderProgressDirect(payload)
        if ok then
            UIManager:show(InfoMessage:new{
                text = _("Current book progress pushed"),
                timeout = 2,
            })
        else
            UIManager:show(InfoMessage:new{
                text = T(_("Failed to push progress: %1"), tostring(reason or "unknown error")),
                timeout = 2,
            })
        end
    end, function()
        self:showWifiUnavailableInfo(
            _("WiFi not enabled - push skipped"),
            _("Airplane mode is enabled - push skipped")
        )
    end, {
        disable_wifi_when_done = true,
    })
    return true
end

---BookloreSync:onToggleBookloreSync.
function BookloreSync:onToggleBookloreSync()
    self:toggleSync()
    return true
end

---BookloreSync:onSyncBooklorePending.
function BookloreSync:onSyncBooklorePending()
    local sessions    = tonumber(self.db and self.db:getPendingSessionCount())    or 0
    local annotations = tonumber(self.db and self.db:getPendingAnnotationCount()) or 0
    local ratings     = tonumber(self.db and self.db:getPendingRatingCount())     or 0
    local bookmarks   = tonumber(self.db and self.db:getPendingBookmarkCount())   or 0
    local progress    = tonumber(self.db and self.db:getPendingKoreaderProgressCount()) or 0
    local pending_count = sessions + annotations + ratings + bookmarks + progress
    if pending_count > 0 and self.is_enabled then
        self:_requestWifi(_("sync pending items"), function()
            self:syncPendingSessions()
        end, function()
            self:showWifiUnavailableInfo(
                _("WiFi not enabled - pending items remain queued"),
                _("Airplane mode is enabled - pending items remain queued")
            )
        end, {
            disable_wifi_when_done = true,
        })
    else
        if pending_count == 0 then
            UIManager:show(InfoMessage:new{
                text = _("No pending items to sync"),
                timeout = 1,
            })
        end
    end
    return true
end

---BookloreSync:onTestBookloreConnection.
function BookloreSync:onTestBookloreConnection()
    self:testConnection()
    return true
end

---BookloreSync:onToggleBookloreManualSyncOnly.
function BookloreSync:onToggleBookloreManualSyncOnly()
    self:toggleManualSyncOnly()
    return true
end

---BookloreSync:toggleSync.
function BookloreSync:toggleSync()
    self.is_enabled = not self.is_enabled
    self.settings:saveSetting("is_enabled", self.is_enabled)
    self.settings:flush()
    UIManager:show(InfoMessage:new{
        text = self.is_enabled and _("Booklore sync enabled") or _("Booklore sync disabled"),
        timeout = 1,
    })
end

---BookloreSync:toggleManualSyncOnly.
function BookloreSync:toggleManualSyncOnly()
    self.manual_sync_only = not self.manual_sync_only
    self.settings:saveSetting("manual_sync_only", self.manual_sync_only)
    
    if self.manual_sync_only and self.force_push_session_on_suspend then
        self.force_push_session_on_suspend = false
        self.settings:saveSetting("force_push_session_on_suspend", false)
    end
    
    self.settings:flush()
    self:setSyncMode(self.manual_sync_only and "manual" or "automatic")
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

---BookloreSync:setSyncMode.
function BookloreSync:setSyncMode(mode)
    local resolved_mode = (mode == "automatic") and "automatic" or "manual"
    self.sync_mode = resolved_mode
    self.settings:saveSetting("sync_mode", resolved_mode)

    if resolved_mode == "automatic" then
        self.manual_sync_only = false
        self.force_push_session_on_suspend = true
        self.connect_network_on_suspend = true
    else
        self.manual_sync_only = true
        self.force_push_session_on_suspend = false
        self.connect_network_on_suspend = false
    end

    self.settings:saveSetting("manual_sync_only", self.manual_sync_only)
    self.settings:saveSetting("force_push_session_on_suspend", self.force_push_session_on_suspend)
    self.settings:saveSetting("connect_network_on_suspend", self.connect_network_on_suspend)
    self.settings:flush()
end

---BookloreSync:viewSessionDetails.
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
    local bookmarks   = tonumber(self.db:getPendingBookmarkCount())   or 0
    local progress    = tonumber(self.db:getPendingKoreaderProgressCount()) or 0
    local synced_progress = tonumber(self.db:getSyncedKoreaderProgressCount()) or 0

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
            "  Ratings: %6\n" ..
            "  Bookmarks: %7\n" ..
            "  Progress: %8\n" ..
            "\n" ..
            "Progress history\n" ..
            "  Synced progress rows: %9"
        ), total, matched, unmatched, sessions, annotations, ratings, bookmarks, progress, synced_progress),
    })
end

--[[--
Recursively delete a directory and all its contents.

@param path  Absolute path to the directory to remove.
@return true on success, false + error string on failure.
--]]
---BookloreSync:_deleteDirRecursive.
function BookloreSync:_deleteDirRecursive(path)
    if not path or path == "" or path == "/" then
        return false, "invalid path"
    end
    local mode = lfs.attributes(path, "mode")
    if mode == nil then
        return true  -- already gone
    end
    if mode == "file" then
        local ok, err = os.remove(path)
        return ok, err
    end
    if mode ~= "directory" then
        return false, "not a file or directory: " .. path
    end
    for entry in lfs.dir(path) do
        if entry ~= "." and entry ~= ".." then
            local child = path .. "/" .. entry
            local ok, err = self:_deleteDirRecursive(child)
            if not ok then
                return false, err
            end
        end
    end
    local ok, err = lfs.rmdir(path)
    return ok, err
end

--[[--
Get available disk space for a given path.

Uses POSIX statvfs to check filesystem statistics.

@param path  Absolute path to check (file or directory)
@return number  Available bytes on success
@return nil, string  nil + error message on failure
--]]
---BookloreSync:getAvailableSpace.
function BookloreSync:getAvailableSpace(path)
    if not path or path == "" then
        return nil, "Invalid path"
    end

    -- Define statvfs structure and function if not already defined
    local ok, _ = pcall(function()
        ffi.cdef[[
            struct statvfs {
                unsigned long f_bsize;    /* Filesystem block size */
                unsigned long f_frsize;   /* Fragment size */
                uint64_t      f_blocks;   /* Size of fs in f_frsize units */
                uint64_t      f_bfree;    /* Number of free blocks */
                uint64_t      f_bavail;   /* Number of free blocks for unprivileged users */
                uint64_t      f_files;    /* Number of inodes */
                uint64_t      f_ffree;    /* Number of free inodes */
                uint64_t      f_favail;   /* Number of free inodes for unprivileged users */
                unsigned long f_fsid;     /* Filesystem ID */
                unsigned long f_flag;     /* Mount flags */
                unsigned long f_namemax;  /* Maximum filename length */
            };
            int statvfs(const char *path, struct statvfs *buf);
        ]]
    end)
    
    if not ok then
        -- statvfs already defined, this is fine
    end

    -- Create buffer for statvfs structure
    local buf = ffi.new("struct statvfs")
    
    -- Call statvfs
    local result = ffi.C.statvfs(path, buf)
    
    if result ~= 0 then
        local err_msg = "statvfs failed for path: " .. path
        self:logErr("BookloreSync: getAvailableSpace -", err_msg)
        return nil, err_msg
    end

    -- Calculate available bytes: f_bavail * f_frsize
    -- f_bavail is the number of blocks available to non-root users
    -- f_frsize is the fragment size (fundamental block size)
    local available_bytes = tonumber(buf.f_bavail) * tonumber(buf.f_frsize)
    
    self:logDbg("BookloreSync: getAvailableSpace - path:", path, "available:", available_bytes, "bytes")
    
    return available_bytes
end

--[[--
Find all .sdr sidecar directories that exist on disk for a given document path.

KOReader supports three sidecar storage locations:
  - "doc"  : beside the book file (<book_path>.sdr)
  - "dir"  : in a central docsettings directory (DataStorage:getDocSettingsDir())
  - "hash" : in a hash-based directory (DataStorage:getDocSettingsHashDir())

Used by the book-deletion path to collect every residual sidecar directory so
they can all be removed.  The configured preferred location is listed first.

@param doc_path  Absolute path to the document file.
@return          Table of existing sidecar dir paths (may be empty), preferred location first.
--]]
---BookloreSync:getSdrPaths.
function BookloreSync:getSdrPaths(doc_path)
    if not doc_path or doc_path == "" then return {} end

    local found = {}

    local ok_ds, DocSettings = pcall(require, "docsettings")
    if ok_ds and DocSettings and DocSettings.getSidecarDir then
        -- Check all three locations; force_location=nil for the first call so
        -- DocSettings reads G_reader_settings and returns the preferred path.
        ---addIfDir.
        local function addIfDir(sdr)
            if sdr and sdr ~= "" and lfs.attributes(sdr, "mode") == "directory" then
                for _, existing in ipairs(found) do
                    if existing == sdr then return end
                end
                table.insert(found, sdr)
            end
        end
        -- Preferred location first (no force_location → reads G_reader_settings)
        local ok_p, sdr = pcall(DocSettings.getSidecarDir, DocSettings, doc_path)
        if ok_p then addIfDir(sdr) end
        -- Then scan the remaining explicit locations for any residual directories
        for _, location in ipairs({ "doc", "dir", "hash" }) do
            local ok_l, sdr_l = pcall(DocSettings.getSidecarDir, DocSettings, doc_path, location)
            if ok_l then addIfDir(sdr_l) end
        end
        if #found > 0 then return found end
    end

    -- Fallback: beside-book path only
    local beside = doc_path .. ".sdr"
    if lfs.attributes(beside, "mode") == "directory" then
        table.insert(found, beside)
    end

    return found
end

--[[--
Detect and store the KOReader sidecar (.sdr) path for the currently open book.

Looks up or creates a book_cache entry, then upserts the sdr_path into
book_metadata.  Called silently from onReaderReady whenever a book is opened.

The DB is checked first: if a non-empty sdr_path is already stored for this
book the function returns immediately.

The sidecar path is obtained via DocSettings:getSidecarDir(doc_path) with no
forced location argument so it reads G_reader_settings directly, identical to
how KOReader itself resolves the path.  This is correct on first open and on
all three storage modes ("doc", "dir", "hash").
--]]
---BookloreSync:detectBookMetadataLocation.
function BookloreSync:detectBookMetadataLocation()
    if not self.ui or not self.ui.document or not self.ui.document.file then
        return
    end

    local doc_path = self.ui.document.file
    self:logInfo("BookloreSync: Detecting metadata location for:", doc_path)

    -- Check whether we already have a valid sdr_path in the database.
    local book_cache_id = self.db:getBookCacheIdByFilePath(doc_path)
    if book_cache_id then
        local meta = self.db:getBookMetadata(book_cache_id)
        if meta and meta.sdr_path and meta.sdr_path ~= "" then
            self:logInfo("BookloreSync: sdr_path already cached in DB:", meta.sdr_path)
            return
        end
    end

    -- Ask DocSettings for the sidecar directory the same way KOReader does:
    -- no force_location argument → reads G_reader_settings("document_metadata_folder")
    -- and computes the correct path for "doc", "dir", or "hash" immediately,
    -- without any disk scan or fallback guessing.
    local ok_ds, DocSettings = pcall(require, "docsettings")
    if not ok_ds or not DocSettings or not DocSettings.getSidecarDir then
        self:logInfo("BookloreSync: DocSettings not available, skipping sdr_path detection")
        return
    end

    local ok_p, sdr_path = pcall(DocSettings.getSidecarDir, DocSettings, doc_path)
    if not ok_p or not sdr_path or sdr_path == "" then
        self:logInfo("BookloreSync: Could not determine sdr_path for:", doc_path)
        return
    end
    self:logInfo("BookloreSync: sdr_path from DocSettings:getSidecarDir:", sdr_path)

    -- Ensure a book_cache entry exists (may not exist for a first-ever open).
    if not book_cache_id then
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
---BookloreSync:syncKOReaderRating.
function BookloreSync:syncKOReaderRating(doc_path, book_id, live_rating)
    if not doc_path or not book_id then
        self:logWarn("BookloreSync: syncKOReaderRating called with missing arguments")
        return
    end
    if self.booklore_username == "" or self.booklore_password == "" then
        self:logWarn("BookloreSync: Rating sync skipped - Booklore credentials not configured")
        return
    end

    -- Check whether this book's rating has already been synced
    local book_cache_id = self.db:getBookCacheIdByFilePath(doc_path)
    if book_cache_id then
        local meta = self.db:getBookMetadata(book_cache_id)
        if meta and meta.rating_synced then
            self:logInfo("BookloreSync: Rating already synced for book_cache_id:", book_cache_id, "- skipping")
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
        self:logInfo("BookloreSync: No KOReader rating set for this book - skipping rating sync")
        return
    end

    local rating_scaled = math.floor(rating_1_5) * 2  -- 1-5 → 2,4,6,8,10
    -- Clamp to valid range just in case
    rating_scaled = math.max(1, math.min(10, rating_scaled))

    -- Optional behavior: when a rating is present, mark book as read for
    -- progress sync by queuing a forced 100% progress state.
    local cached_for_hash = self.db:getBookByFilePath(doc_path)
    local forced_hash = cached_for_hash and cached_for_hash.file_hash or nil
    self:queueReadProgressOnRating(doc_path, forced_hash)

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

    -- Hardcover rating sync: run in addition to Booklore if enabled and a
    -- hardcover_id is stored for this book.
    if self.hardcover_rating_sync_enabled then
        if not self.hardcover_token or self.hardcover_token == "" then
            self:logWarn("BookloreSync: Hardcover rating sync enabled but no token configured - skipping")
        else
            local hc_id
            -- Re-use book_cache_id if already resolved above, otherwise look it up now.
            local cache_id = book_cache_id or self.db:getBookCacheIdByFilePath(doc_path)
            if cache_id then
                local cache_row = self.db:getBookCacheById(cache_id)
                hc_id = cache_row and cache_row.hardcover_id
            end

            if hc_id then
                self:logInfo("BookloreSync: Syncing rating to Hardcover - hardcover_id:", hc_id,
                    "rating:", rating_scaled)
                local hc_ok, hc_err = self.hc_api:submitRating(hc_id, rating_scaled, self.hardcover_token)
                if hc_ok then
                    self:logInfo("BookloreSync: Hardcover rating synced successfully")
                else
                    self:logWarn("BookloreSync: Hardcover rating sync failed:", tostring(hc_err))
                end
            else
                self:logInfo("BookloreSync: Hardcover rating sync enabled but no hardcover_id found for this book - skipping")
            end
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
---BookloreSync:showRatingDialog.
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
            self:logInfo("BookloreSync: Rating already synced - skipping dialog")
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

                        -- Always queue into pending_ratings so the rating
                        -- survives a failed or deferred network call and is
                        -- visible to the "Sync Pending Now" path.  The queue
                        -- entry is removed by syncPendingRatings on success.
                        if bcid then
                            self.db:addPendingRating(bcid, book_id, value)
                        end

                        -- Optional behavior: submitting a rating can force
                        -- progress to be synced as "read" (100%).
                        local forced_hash = nil
                        local cached_row = self.db:getBookByFilePath(doc_path)
                        if cached_row then
                            forced_hash = cached_row.file_hash
                        end
                        self:queueReadProgressOnRating(doc_path, forced_hash)

                        if not book_id then
                            -- book_id not yet known - queued above with nil
                            -- book_id; uploaded once the book is matched.
                            UIManager:show(InfoMessage:new{
                                text = T(_("Rating %1/10 saved (will sync once book is matched)"), value),
                                timeout = 2,
                            })
                        elseif self.manual_sync_only then
                            -- User chose "manual only" sync trigger - do not
                            -- attempt any network call automatically.
                            self:logInfo("BookloreSync: manual_sync_only - rating queued, skipping auto-upload")
                            UIManager:show(InfoMessage:new{
                                text = T(_("Rating %1/10 saved (use 'Sync Pending Now' to upload)"), value),
                                timeout = 2,
                            })
                        elseif self.booklore_username == "" or self.booklore_password == "" then
                            -- No credentials yet - rating stays in the queue.
                            UIManager:show(InfoMessage:new{
                                text = T(_("Rating %1/10 saved (will retry on next sync)"), value),
                                timeout = 2,
                            })
                        else
                            -- book_id known, not manual-only, credentials
                            -- present - attempt an immediate upload, honouring
                            -- the "ask to enable WiFi" setting via _requestWifi.
                            local snap_bcid  = bcid
                            local snap_value = value
                            self:_requestWifi(_("upload rating"), function()
                                local ok, err = self.api:submitRating(
                                    book_id, snap_value,
                                    self.booklore_username, self.booklore_password
                                )
                                if ok then
                                    if snap_bcid then
                                        self.db:markRatingSynced(snap_bcid)
                                        self.db:recordRatingSyncHistory(snap_bcid, snap_value, "success")
                                        -- Remove from pending queue now that it is synced.
                                        self.db:deletePendingRatingByBookCacheId(snap_bcid)
                                    end
                                    UIManager:show(InfoMessage:new{
                                        text = T(_("Rating %1/10 saved and synced"), snap_value),
                                        timeout = 2,
                                    })
                                    -- Hardcover rating sync (in addition to Booklore).
                                    if self.hardcover_rating_sync_enabled then
                                        if not self.hardcover_token or self.hardcover_token == "" then
                                            self:logWarn("BookloreSync: Hardcover rating sync enabled but no token configured - skipping")
                                        else
                                            local hc_id
                                            if snap_bcid then
                                                local cache_row = self.db:getBookCacheById(snap_bcid)
                                                hc_id = cache_row and cache_row.hardcover_id
                                            end
                                            if hc_id then
                                                self:logInfo("BookloreSync: Syncing rating to Hardcover - hardcover_id:", hc_id, "rating:", snap_value)
                                                local hc_ok, hc_err = self.hc_api:submitRating(hc_id, snap_value, self.hardcover_token)
                                                if hc_ok then
                                                    self:logInfo("BookloreSync: Hardcover rating synced successfully")
                                                else
                                                    self:logWarn("BookloreSync: Hardcover rating sync failed:", tostring(hc_err))
                                                end
                                            else
                                                self:logInfo("BookloreSync: Hardcover rating sync enabled but no hardcover_id found - skipping")
                                            end
                                        end
                                    end
                                else
                                    self:logWarn("BookloreSync: Rating submit failed:", err)
                                    -- Rating stays in pending_ratings (queued above); record failure.
                                    if snap_bcid then
                                        self.db:recordRatingSyncHistory(snap_bcid, snap_value, "error", err)
                                    end
                                    UIManager:show(InfoMessage:new{
                                        text = T(_("Rating %1/10 saved (will retry on next sync)"), snap_value),
                                        timeout = 2,
                                    })
                                end
                            end, function()
                                -- User declined WiFi prompt - rating stays queued.
                                self:logInfo("BookloreSync: WiFi request declined - rating queued for later upload")
                                UIManager:show(InfoMessage:new{
                                    text = T(_("Rating %1/10 saved (will sync when WiFi is available)"), value),
                                    timeout = 2,
                                })
                            end)
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
---BookloreSync:colorToHex.
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
---BookloreSync:drawerToStyle.
function BookloreSync:drawerToStyle(drawer)
    if not drawer then return "highlight" end
    return KOREADER_STYLE_MAP[drawer:lower()] or "highlight"
end

function BookloreSync:getTimingNowMs()
    return nowMs()
end

function BookloreSync:getDocumentFingerprint(_document, file_path)
    local normalized_path = file_path or ""
    local size = 0
    local mtime = 0

    if normalized_path ~= "" then
        local lfs = require("libs/libkoreader-lfs")
        size = tonumber(lfs.attributes(normalized_path, "size")) or 0
        mtime = tonumber(lfs.attributes(normalized_path, "modification")) or 0
    end

    return string.format("%s|%d|%d", normalized_path, size, mtime)
end

function BookloreSync:logSpineCacheEvent(event_name, reason, file_path, extra)
    if event_name == "spine_cache_hit" then
        self.spine_cache_stats.hit = (self.spine_cache_stats.hit or 0) + 1
        self:logInfo(
            "BookloreSync:",
            "spine_cache_hit",
            "count=", tostring(self.spine_cache_stats.hit),
            "spine_rebuild_reason=", tostring(reason or "none"),
            "path=", tostring(file_path or "")
        )
    else
        self.spine_cache_stats.miss = (self.spine_cache_stats.miss or 0) + 1
        self:logInfo(
            "BookloreSync:",
            "spine_cache_miss",
            "count=", tostring(self.spine_cache_stats.miss),
            "spine_rebuild_reason=", tostring(reason or "unknown"),
            "path=", tostring(file_path or ""),
            extra and ("extra=" .. tostring(extra)) or ""
        )
    end
end

function BookloreSync:invalidateEpubContext(reason, expected_path)
    if not self.epub_context_cache then
        return
    end

    if expected_path and self.epub_context_cache.doc_path ~= expected_path then
        return
    end

    self:logInfo(
        "BookloreSync: Invalidating EPUB context cache",
        "reason=", tostring(reason or "unknown"),
        "path=", tostring(self.epub_context_cache.doc_path or "")
    )
    self.epub_context_cache = nil
end

function BookloreSync:getOrBuildEpubContext(document, file_path)
    if not document then
        return nil
    end

    local fingerprint = self:getDocumentFingerprint(document, file_path)

    if not self.enable_spine_context_cache then
        self:logSpineCacheEvent("spine_cache_miss", "feature_disabled", file_path)
        local build_started_ms = self:getTimingNowMs()
        local spine_map = self:buildEpubSpineMap(document)
        local elapsed_ms = self:getTimingNowMs() - build_started_ms
        if not spine_map then
            return nil
        end
        self:logInfo("BookloreSync: spine_context_build_ms=", tostring(elapsed_ms), "path=", tostring(file_path or ""))
        return {
            spine_map = spine_map,
            fingerprint = fingerprint,
            doc_path = file_path,
            built_at_ms = self:getTimingNowMs(),
            spine_count = #spine_map,
        }
    end

    local cache = self.epub_context_cache
    if cache and cache.doc_path == file_path and cache.fingerprint == fingerprint and cache.spine_map then
        self:logSpineCacheEvent("spine_cache_hit", "cache_match", file_path)
        return cache
    end

    local rebuild_reason = "cache_empty"
    if cache and cache.doc_path ~= file_path then
        rebuild_reason = "document_switched"
    elseif cache and cache.doc_path == file_path and cache.fingerprint ~= fingerprint then
        rebuild_reason = "fingerprint_changed"
    end

    self:logSpineCacheEvent("spine_cache_miss", rebuild_reason, file_path)
    local build_started_ms = self:getTimingNowMs()
    local spine_map = self:buildEpubSpineMap(document)
    local elapsed_ms = self:getTimingNowMs() - build_started_ms
    if not spine_map then
        return nil
    end

    self.epub_context_cache = {
        spine_map = spine_map,
        fingerprint = fingerprint,
        doc_path = file_path,
        built_at_ms = self:getTimingNowMs(),
        spine_count = #spine_map,
    }

    self:logInfo(
        "BookloreSync:",
        "spine_context_build_ms=", tostring(elapsed_ms),
        "spine_count=", tostring(#spine_map),
        "path=", tostring(file_path or "")
    )

    return self.epub_context_cache
end

local function stableSerializeValue(value)
    local t = type(value)
    if value == nil then
        return ""
    end
    if t == "boolean" or t == "number" or t == "string" then
        return tostring(value)
    end
    if t == "table" then
        local parts = {}
        for k, v in pairs(value) do
            parts[#parts + 1] = tostring(k) .. "=" .. stableSerializeValue(v)
        end
        table.sort(parts)
        return "{" .. table.concat(parts, ",") .. "}"
    end
    return tostring(value)
end

function BookloreSync:getSyncFingerprintKey(kind, book_cache_id)
    if not kind or not book_cache_id then
        return nil
    end
    return "sync_fp_" .. tostring(kind) .. "_" .. tostring(book_cache_id)
end

function BookloreSync:getStoredSyncFingerprint(kind, book_cache_id)
    if not self.settings then
        return nil
    end
    local key = self:getSyncFingerprintKey(kind, book_cache_id)
    if not key then
        return nil
    end
    local value = self.settings:readSetting(key)
    if value == nil then
        return nil
    end
    value = tostring(value)
    if value == "" then
        return nil
    end
    return value
end

function BookloreSync:setStoredSyncFingerprint(kind, book_cache_id, value)
    if not self.settings then
        return false
    end
    local key = self:getSyncFingerprintKey(kind, book_cache_id)
    if not key then
        return false
    end
    return self.settings:saveSetting(key, value)
end

function BookloreSync:clearStoredSyncFingerprint(kind, book_cache_id)
    if not self.settings then
        return false
    end
    local key = self:getSyncFingerprintKey(kind, book_cache_id)
    if not key then
        return false
    end
    return self.settings:saveSetting(key, nil)
end

function BookloreSync:hashSyncTokens(tokens)
    if not tokens then
        return nil
    end
    if #tokens == 0 then
        return "empty"
    end
    table.sort(tokens)
    local ok_sha2, sha2 = pcall(require, "ffi/sha2")
    if not ok_sha2 or not sha2 or type(sha2.md5) ~= "function" then
        self:logWarn("BookloreSync: Sync fingerprint hashing unavailable")
        return nil
    end
    return sha2.md5(table.concat(tokens, "\n"))
end

function BookloreSync:computeAnnotationsFingerprint(annotations)
    if not annotations then
        return nil
    end
    local tokens = {}
    for _, ann in ipairs(annotations) do
        local token = table.concat({
            stableSerializeValue(ann.datetime),
            stableSerializeValue(ann.datetime_updated),
            stableSerializeValue(ann.text),
            stableSerializeValue(ann.note),
            stableSerializeValue(ann.page),
            stableSerializeValue(ann.chapter),
            stableSerializeValue(ann.color),
            stableSerializeValue(ann.drawer),
            stableSerializeValue(ann.pos0),
            stableSerializeValue(ann.pos1),
        }, "|")
        tokens[#tokens + 1] = token
    end
    return self:hashSyncTokens(tokens)
end

function BookloreSync:computeBookmarksFingerprint(bookmarks)
    if not bookmarks then
        return nil
    end
    local tokens = {}
    for _, bm in ipairs(bookmarks) do
        local token = table.concat({
            stableSerializeValue(bm.datetime),
            stableSerializeValue(bm.datetime_updated),
            stableSerializeValue(bm.notes),
            stableSerializeValue(bm.pos0),
            stableSerializeValue(bm.pos1),
            stableSerializeValue(bm.page),
        }, "|")
        tokens[#tokens + 1] = token
    end
    return self:hashSyncTokens(tokens)
end

function BookloreSync:parseKoreaderDateTime(datetime_str)
    if not datetime_str or datetime_str == "" then
        return nil
    end
    local y, m, d, hh, mm, ss = tostring(datetime_str):match("^(%d%d%d%d)%-(%d%d)%-(%d%d) (%d%d):(%d%d):(%d%d)$")
    if not y then
        return nil
    end
    return os.time({
        year = tonumber(y),
        month = tonumber(m),
        day = tonumber(d),
        hour = tonumber(hh),
        min = tonumber(mm),
        sec = tonumber(ss),
    })
end

function BookloreSync:getEntryChangedAt(entry)
    if not entry then
        return nil
    end
    local updated_at = self:parseKoreaderDateTime(entry.datetime_updated)
    if updated_at then
        return updated_at
    end
    return self:parseKoreaderDateTime(entry.datetime)
end

function BookloreSync:filterEntriesBySessionStart(entries, session_start_time)
    if not entries or not session_start_time then
        return entries or {}, 0
    end

    local threshold = tonumber(session_start_time) or 0
    if threshold <= 0 then
        return entries, 0
    end

    local filtered = {}
    local skipped = 0
    local adjusted_threshold = threshold - 1

    for _, entry in ipairs(entries) do
        local changed_at = self:getEntryChangedAt(entry)
        if changed_at == nil or changed_at >= adjusted_threshold then
            filtered[#filtered + 1] = entry
        else
            skipped = skipped + 1
        end
    end

    return filtered, skipped
end

function BookloreSync:shouldSkipNoopSync(kind, book_cache_id, current_fp, pending_count)
    if not kind or not book_cache_id then
        return false, "no_cache_id"
    end
    if not current_fp then
        return false, "fingerprint_unavailable"
    end
    pending_count = tonumber(pending_count) or 0
    if pending_count > 0 then
        return false, "pending_exists"
    end
    local stored_fp = self:getStoredSyncFingerprint(kind, book_cache_id)
    if not stored_fp then
        return false, "no_marker"
    end
    if stored_fp ~= current_fp then
        return false, "fingerprint_changed"
    end
    return true, "fingerprint_match_no_pending"
end

function BookloreSync:updateNoopSyncMarker(kind, book_cache_id, current_fp, failed_count, queued_count, queue_only)
    if not kind or not book_cache_id or not current_fp then
        return
    end

    local failed = tonumber(failed_count) or 0
    local queued = tonumber(queued_count) or 0

    if queue_only or failed > 0 or queued > 0 then
        self:clearStoredSyncFingerprint(kind, book_cache_id)
        self:logInfo(
            "BookloreSync: No-op marker invalidated",
            "kind=", tostring(kind),
            "book_cache_id=", tostring(book_cache_id),
            "reason=dirty_or_unsynced"
        )
        return
    end

    local pending_count = 0
    if kind == "annotations" and self.db and type(self.db.getPendingAnnotationCountForBook) == "function" then
        pending_count = tonumber(self.db:getPendingAnnotationCountForBook(book_cache_id)) or 0
    elseif kind == "bookmarks" and self.db and type(self.db.getPendingBookmarkCountForBook) == "function" then
        pending_count = tonumber(self.db:getPendingBookmarkCountForBook(book_cache_id)) or 0
    end

    if pending_count > 0 then
        self:clearStoredSyncFingerprint(kind, book_cache_id)
        self:logInfo(
            "BookloreSync: No-op marker invalidated",
            "kind=", tostring(kind),
            "book_cache_id=", tostring(book_cache_id),
            "reason=pending_exists"
        )
        return
    end

    self:setStoredSyncFingerprint(kind, book_cache_id, current_fp)
    self:logInfo(
        "BookloreSync: No-op marker updated",
        "kind=", tostring(kind),
        "book_cache_id=", tostring(book_cache_id),
        "reason=sync_clean"
    )
end

function BookloreSync:createCloseSyncContext(params)
    params = params or {}

    local ctx = {
        created_at_ms = self:getTimingNowMs(),
        close_started_ms = tonumber(params.close_started_ms) or self:getTimingNowMs(),
        session_started_at = tonumber(params.session_started_at),
        doc_path = params.doc_path,
        file_hash = params.file_hash,
        book_id = params.book_id,
        end_progress = params.end_progress,
        document = params.document,
        doc_settings = params.doc_settings,
        live_annotations = params.live_annotations,
        live_bookmarks = params.live_bookmarks,
        book_cache_id = nil,
        epub_context = nil,
    }

    if ctx.doc_path and self.db then
        ctx.book_cache_id = self.db:getBookCacheIdByFilePath(ctx.doc_path)
        if not ctx.book_cache_id then
            self.db:saveBookCache(ctx.doc_path, ctx.file_hash or "", nil, nil, nil, nil, nil)
            ctx.book_cache_id = self.db:getBookCacheIdByFilePath(ctx.doc_path)
        end
    end

    local is_epub = ctx.doc_path and ctx.doc_path:lower():match("%.epub$") ~= nil
    if is_epub and ctx.document then
        ctx.epub_context = self:getOrBuildEpubContext(ctx.document, ctx.doc_path)
    end

    self:logInfo(
        "BookloreSync: Close context created",
        "path=", tostring(ctx.doc_path or ""),
        "book_id=", tostring(ctx.book_id),
        "book_cache_id=", tostring(ctx.book_cache_id),
        "has_epub_context=", tostring(ctx.epub_context ~= nil),
        "session_started_at=", tostring(ctx.session_started_at),
        "annotations=", tostring(ctx.live_annotations and #ctx.live_annotations or 0),
        "bookmarks=", tostring(ctx.live_bookmarks and #ctx.live_bookmarks or 0)
    )

    return ctx
end

function BookloreSync:releaseCloseSyncContext(ctx, reason)
    if not ctx then
        return
    end

    local elapsed_ms = self:getTimingNowMs() - (tonumber(ctx.created_at_ms) or self:getTimingNowMs())
    self:logInfo(
        "BookloreSync: Close context released",
        "reason=", tostring(reason or "unknown"),
        "path=", tostring(ctx.doc_path or ""),
        "elapsed_ms=", tostring(elapsed_ms)
    )
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
---findNthElementOrdinal.
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
---extractNthElementContent.
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
---BookloreSync:buildEpubSpineMap.
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
  text().N      - first (only) text node, character offset N
  text()[K].N   - Kth text node among mixed content, character offset N

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
---BookloreSync:xpointerToCfiPath.
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

        -- ── void element with offset: name[N].offset  (e.g. br[112].0) ────────
        -- CREngine emits this when a highlight is anchored to/after a void
        -- element (br, img, hr, etc.) that has no text children.
        -- CFI equivalent: step to the element itself, then apply the offset.
        local void_name, void_idx_s, void_offset_s = part:match("^([%a][%w%-]*)%[(%d+)%]%.(%d+)$")
        if void_name and HTML_VOID_TAGS[void_name:lower()] then
            local void_idx = tonumber(void_idx_s)
            local ordinal, elem_id = findNthElementOrdinal(current_content, void_name, void_idx)
            if not ordinal then
                self:logWarn(string.format(
                    "BookloreSync: Could not find %s[%d] in xpointer at step %d (%s)",
                    void_name, void_idx, idx, xpointer))
                return nil
            end
            local step = "/" .. (ordinal * 2)
            if elem_id and elem_id ~= "" then
                step = step .. "[" .. elem_id .. "]"
            end
            table.insert(steps, step)
            table.insert(steps, ":" .. void_offset_s)
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
Build a mock EPUB CFI for a PDF page number.

PDF files do not have an EPUB spine, so a true CFI cannot be computed.
This function generates a synthetic CFI of the form:
  epubcfi(/6/<page*2>!/4/2/1:0,/1:0)
where <page*2> is an even step index derived from the 1-based page number.
This gives Booklore enough information to identify the approximate location
(page N) without breaking CFI parsing.

@param page  number  1-based page number
@return string       Synthetic CFI string
--]]
---BookloreSync:buildMockPdfCfi.
function BookloreSync:buildMockPdfCfi(page)
    local page_num = tonumber(page) or 1
    -- Even step: page 1 → /2, page 2 → /4, etc.
    local spine_step = page_num * 2
    return string.format("epubcfi(/6/%d!/4/2/1:0,/1:0)", spine_step)
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
---BookloreSync:buildCfi.
function BookloreSync:buildCfi(pos0, pos1, spine, document, html_cache)
    if not pos0 or not pos1 then return nil end
    if not spine or not document then
        self:logWarn("BookloreSync: buildCfi called without spine/document - skipping")
        return nil
    end

    html_cache = html_cache or {}

    local steps0 = self:xpointerToCfiPath(pos0, spine, document, html_cache)
    local steps1 = self:xpointerToCfiPath(pos1, spine, document, html_cache)
    if not steps0 or not steps1 then return nil end

    -- Build full intra-doc path strings (e.g. "/4/2/28[id]/1:0")
    -- steps are an array of strings like "/4", "/6[foo]", "/1", ":0"
    -- The spine prefix is "/6/<spine_step>!"
    ---stepsToPath.
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
    ---buildStepList.
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
    -- must never be part of the shared path - they are always terminal and
    -- belong to the relative start/end parts.
    -- Case 1: the shared boundary itself is an offset step (":N")
    if shared_len > 0 and list0[shared_len]:sub(1,1) == ":" then
        shared_len = shared_len - 1
    end
    -- Case 2: the first diverging step is an offset (":N"), meaning the last
    -- shared step is the paired text-node step ("/1", "/3", …) - pull it out.
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

Reads the annotations array, skips already-synced entries
(via synced_annotations DB table), and posts each new item to the
appropriate API endpoint based on the notes_destination setting.

Highlights (no note field) → POST /api/v1/annotations
Notes with destination "in_book" → POST /api/v2/book-notes
Notes with destination "in_booklore" → POST /api/v1/book-notes
Notes with destination "both" → POST /api/v2/book-notes + POST /api/v1/book-notes
PDF/CBZ highlights and notes → mock CFI (epubcfi(/6/<page*2>!/4/2/1:0,/1:0))

@param doc_path        string      Full path to the document file
@param book_id         number      Booklore book ID
@param document        CreDocument Open CREngine document (still available in onCloseDocument).
                                   Required for EPUB CFI generation; highlights/in-book notes
                                   are skipped if nil (Booklore-notes still work without it).
@param doc_settings    DocSettings Live in-memory DocSettings object (fallback annotation source).
@param live_annotations table|nil  Raw annotation array from ReaderAnnotation.annotations.
                                   When provided this takes highest priority, bypassing doc_settings
                                   entirely.  KOReader only writes annotations into doc_settings
                                   during the SaveSettings event, which fires AFTER CloseDocument,
                                   so doc_settings.data["annotations"] is stale at close time.
                                   Passing self.ui.annotation.annotations directly avoids this race.
--]]
---BookloreSync:syncHighlightsAndNotes.
function BookloreSync:syncHighlightsAndNotes(doc_path, book_id, document, doc_settings, live_annotations, close_ctx)
    local sync_started_ms = self:getTimingNowMs()
    if not doc_path then
        self:logWarn("BookloreSync: syncHighlightsAndNotes called without doc_path")
        return 0, 0, 0
    end
    if not self.highlights_notes_sync_enabled then
        return 0, 0, 0
    end
    if self.booklore_username == "" or self.booklore_password == "" then
        self:logWarn("BookloreSync: Highlights/notes sync skipped - credentials not configured")
        return 0, 0, 0
    end

    -- book_id may be nil when the server was offline at open time.
    -- In that case we skip API calls but still compute CFIs (while the doc is
    -- open) and queue every annotation into pending_annotations so they are
    -- submitted on the next sync once the book_id has been resolved.
    -- Also queue when manual_sync_only is enabled (cache everything mode).
    local queue_only = (book_id == nil) or self.manual_sync_only

    -- Annotation source priority (highest to lowest):
    --
    -- 1. live_annotations - the raw ReaderAnnotation.annotations table captured
    --    directly from self.ui.annotation before CloseDocument.  This is the only
    --    source that is guaranteed to be current at close time: KOReader stores
    --    annotations in ReaderAnnotation's own in-memory array and only copies
    --    them into doc_settings during the SaveSettings event, which fires AFTER
    --    CloseDocument on the standard close path (self.dialog == self).  Reading
    --    doc_settings["annotations"] at CloseDocument time therefore returns stale
    --    or absent data on real devices.
    --
    -- 2. doc_settings - live in-memory DocSettings object.  Used as a fallback
    --    when live_annotations is not available (e.g. older KOReader builds that
    --    lack self.ui.annotation, or future call sites we haven't updated yet).
    --
    -- 3. on-disk sidecar - last resort for retry/manual-sync paths where no live
    --    objects are available and the sidecar has already been flushed.
    if close_ctx and type(close_ctx) == "table" then
        doc_path = close_ctx.doc_path or doc_path
        book_id = close_ctx.book_id or book_id
        document = close_ctx.document or document
        doc_settings = close_ctx.doc_settings or doc_settings
        if type(close_ctx.live_annotations) == "table" then
            live_annotations = close_ctx.live_annotations
        end
    end

    local annotations
    if live_annotations and type(live_annotations) == "table" then
        -- Map ReaderAnnotation items → the normalised shape the rest of this
        -- function expects.  The fields are identical, so this is a straight copy
        -- with defaults applied for any absent optional fields.
        annotations = {}
        for _, ann in ipairs(live_annotations) do
            -- Bookmarks share the same array but lack pos0/color - skip them
            if ann.text and ann.pos0 then
                table.insert(annotations, {
                    text     = ann.text,
                    note     = ann.note,
                    datetime = ann.datetime,
                    page     = ann.page,
                    chapter  = ann.chapter,
                    color    = ann.color  or "yellow",
                    drawer   = ann.drawer or "lighten",
                    pos0     = ann.pos0,
                    pos1     = ann.pos1,
                })
            end
        end
        self:logInfo(string.format("BookloreSync: Annotations read from live ReaderAnnotation module (%d)", #annotations))
    elseif doc_settings then
        annotations = self.metadata_extractor:getHighlightsFromDocSettings(doc_settings)
        self:logInfo(string.format("BookloreSync: Annotations read from live in-memory doc_settings (%d)", #annotations))
    else
        annotations = self.metadata_extractor:getHighlights(doc_path)
        self:logInfo(string.format("BookloreSync: Annotations read from on-disk sidecar (%d)", #annotations))
    end
    if not annotations or #annotations == 0 then
        self:logInfo("BookloreSync: No annotations found for:", doc_path)
        return 0, 0, 0
    end

    local session_started_at = close_ctx and tonumber(close_ctx.session_started_at) or nil
    local filtered_annotations, skipped_pre_session = self:filterEntriesBySessionStart(annotations, session_started_at)
    if skipped_pre_session > 0 then
        self:logInfo(
            "BookloreSync: Session-window filter applied",
            "component=annotations",
            "session_started_at=", tostring(session_started_at),
            "skipped=", tostring(skipped_pre_session),
            "kept=", tostring(#filtered_annotations)
        )
    end
    annotations = filtered_annotations
    if #annotations == 0 then
        self:logInfo(
            "BookloreSync: No-op skipped",
            "component=annotations",
            "reason=no_entries_in_session_window",
            "path=", tostring(doc_path or "")
        )
        return 0, 0, 0
    end

    self:logInfo("BookloreSync: Syncing", #annotations, "annotations for book_id:", book_id)

    -- Build EPUB spine map (needed for CFI generation).
    -- Only attempt this for EPUB files where the document is still open.
    local spine = nil
    local is_epub = doc_path:lower():match("%.epub$") ~= nil
    local is_pdf  = doc_path:lower():match("%.pdf$")  ~= nil
    local epub_ctx = close_ctx and close_ctx.epub_context or nil
    if is_epub and document then
        if not epub_ctx then
            epub_ctx = self:getOrBuildEpubContext(document, doc_path)
        end
        spine = epub_ctx and epub_ctx.spine_map or nil
        if not spine then
            self:logWarn("BookloreSync: Could not build EPUB spine map - highlights/in-book notes will be skipped")
        end
    end

    -- Shared HTML cache for spine items (avoids re-reading the same file for each annotation)
    local html_cache = {}

    -- Ensure we have a book_cache_id (create minimal cache entry if needed)
    local book_cache_id = close_ctx and close_ctx.book_cache_id or nil
    if close_ctx and close_ctx.doc_path == doc_path and close_ctx.book_id == nil then
        close_ctx.book_id = book_id
    end
    local used_close_ctx = close_ctx and close_ctx.doc_path == doc_path
    if used_close_ctx then
        self:logInfo("BookloreSync: syncHighlightsAndNotes using shared close context", "path=", tostring(doc_path))
    end
    if not book_cache_id then
        book_cache_id = self.db:getBookCacheIdByFilePath(doc_path)
    end
    if not book_cache_id then
        self.db:saveBookCache(doc_path, "", nil, nil, nil, nil, nil)
        book_cache_id = self.db:getBookCacheIdByFilePath(doc_path)
    end
    if not book_cache_id then
        self:logWarn("BookloreSync: Could not obtain book_cache_id for highlights sync")
        return 0, 0, 0
    end
    if close_ctx and close_ctx.doc_path == doc_path then
        close_ctx.book_cache_id = book_cache_id
    end

    local current_annotations_fp = self:computeAnnotationsFingerprint(annotations)
    local pending_ann_count = tonumber(self.db:getPendingAnnotationCountForBook(book_cache_id)) or 0
    local should_skip_noop, skip_reason = self:shouldSkipNoopSync("annotations", book_cache_id, current_annotations_fp, pending_ann_count)
    if should_skip_noop then
        local elapsed_ms = self:getTimingNowMs() - sync_started_ms
        self:logInfo(
            "BookloreSync: No-op skipped",
            "component=annotations",
            "reason=", tostring(skip_reason),
            "book_cache_id=", tostring(book_cache_id),
            "path=", tostring(doc_path or ""),
            "syncHighlightsAndNotes_total_ms=", tostring(elapsed_ms)
        )
        return 0, 0, 0
    end
    self:logInfo(
        "BookloreSync: No-op marker bypass",
        "component=annotations",
        "reason=", tostring(skip_reason),
        "book_cache_id=", tostring(book_cache_id)
    )

    local notes_dest    = self.notes_destination or "in_book"
    local synced_count  = 0
    local skipped_count = 0
    local failed_count  = 0
    local queued_count  = 0

    for _, ann in ipairs(annotations) do
        local datetime = ann.datetime or ""
        if datetime == "" then
            self:logWarn("BookloreSync: Skipping annotation with no datetime")
            skipped_count = skipped_count + 1
        else
            local has_note = ann.note and ann.note ~= ""

            -- Determine type key for dedup tracking
            local ann_type
            if not has_note then
                ann_type = "highlight"
            elseif notes_dest == "in_book" then
                ann_type = "in_book_note"
            elseif notes_dest == "both" then
                ann_type = "both_note"
            else
                ann_type = "booklore_note"
            end

            -- Skip if already synced
            if self.db:isAnnotationSynced(book_cache_id, datetime, ann_type) then
                self:logInfo("BookloreSync: Annotation already synced, skipping:", datetime)
                skipped_count = skipped_count + 1
            else
                -- Wrap per-annotation processing in pcall so a malformed xpointer or
                -- unexpected nil never crashes the close-document flow.
                local ann_ok, ann_err = pcall(function()
                    local ok, server_id
                    local cfi  -- computed below and reused in payload

                    -- Build a CFI for this annotation.
                    -- For EPUB: use the full xpointer-based CFI via buildCfi.
                    -- For PDF: use a mock CFI anchored to the page number.
                    -- For other formats: no CFI available.
                    ---resolveCfi.
                    local function resolveCfi()
                        if is_epub and spine then
                            local cfi = self:buildCfi(ann.pos0, ann.pos1, spine, document, html_cache)
                            if not cfi and ann.page then
                                -- Some large/complex EPUBs emit xpointers that cannot be
                                -- resolved reliably against raw spine HTML (e.g. deep
                                -- DocFragment/body paths with transformed nodes). Fall
                                -- back to a page-anchored synthetic CFI so in-book sync
                                -- can still proceed instead of being dropped.
                                cfi = self:buildMockPdfCfi(ann.page)
                                self:logWarn("BookloreSync: Falling back to page-based CFI for annotation at", tostring(datetime), "page", tostring(ann.page))
                            end
                            return cfi
                        elseif is_pdf and ann.page then
                            return self:buildMockPdfCfi(ann.page)
                        end
                        return nil
                    end

                    if not has_note then
                        -- ── Pure highlight ──────────────────────────────────────────────
                        cfi = resolveCfi()
                        if not cfi then
                            self.db:markAnnotationSynced(book_cache_id, datetime, ann_type, nil)
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
                        cfi = resolveCfi()
                        if not cfi then
                            self.db:markAnnotationSynced(book_cache_id, datetime, ann_type, nil)
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

                    elseif notes_dest == "both" then
                        -- ── Both: in-book note + Booklore web-UI note ───────────────────
                        cfi = resolveCfi()
                        local in_book_ok, in_book_id
                        local bl_ok, bl_id
                        local requires_in_book = cfi ~= nil and cfi ~= ""
                        if not queue_only then
                            if requires_in_book then
                                in_book_ok, in_book_id = self.api:submitInBookNote(
                                    book_id, cfi, ann.note,
                                    {
                                        selected_text = ann.text,
                                        color         = self:colorToHex(ann.color),
                                        chapter_title = ann.chapter,
                                    },
                                    self.booklore_username, self.booklore_password
                                )
                                if not in_book_ok then
                                    self:logWarn("BookloreSync: 'Both' - in-book note failed:", in_book_id)
                                end
                            else
                                self:logInfo("BookloreSync: 'Both' - no CFI available, skipping in-book note")
                            end
                            bl_ok, bl_id = self.api:submitBookloreNote(
                                book_id, ann.note, ann.chapter,
                                self.booklore_username, self.booklore_password
                            )
                            if not bl_ok then
                                self:logWarn("BookloreSync: 'Both' - Booklore note failed:", bl_id)
                            end
                        end
                        -- In "both" mode, keep retrying until every required destination
                        -- has succeeded. If no CFI exists, only the Booklore note is required.
                        ok = (requires_in_book and in_book_ok and bl_ok) or ((not requires_in_book) and bl_ok) or false
                        server_id = in_book_id or bl_id

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
                        -- No book_id yet or manual_sync_only mode - queue for retry with full CFI cached in payload.
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
                        if self.manual_sync_only then
                            queued_count = queued_count + 1
                        else
                            failed_count = failed_count + 1
                        end
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
                    -- annotation is not lost.  Use a minimal payload (no CFI) - the
                    -- retry path will skip annotations it cannot re-submit.
                    local ok_enc, pending_payload = pcall(json.encode, {
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
                    if ok_enc and pending_payload then
                        self.db:addPendingAnnotation(book_cache_id, book_id, ann_type, datetime, pending_payload)
                    end
                end
            end
        end
    end

    if self.manual_sync_only and queued_count > 0 then
        self:logInfo(string.format(
            "BookloreSync: Highlights/notes cached - queued:%d  skipped:%d",
            queued_count, skipped_count
        ))
    else
        self:logInfo(string.format(
            "BookloreSync: Highlights/notes sync done - synced:%d  skipped:%d  failed:%d  queued:%d",
            synced_count, skipped_count, failed_count, queued_count
        ))
    end

    local elapsed_ms = self:getTimingNowMs() - sync_started_ms
    self:logInfo("BookloreSync: syncHighlightsAndNotes_total_ms=", tostring(elapsed_ms), "path=", tostring(doc_path))

    self:updateNoopSyncMarker("annotations", book_cache_id, current_annotations_fp, failed_count, queued_count, queue_only)

    return synced_count, queued_count, failed_count
end

--[[--
File manager long-press: Sync all annotations for a single book.
Looks up the book in the local DB, then calls syncHighlightsAndNotes.
Requires the book to have been opened at least once so it has a book_cache entry.
--]]

--[[--
Refresh Booklore credentials from DB into memory.

File-dialog actions are registered on the FileManager CLASS table, meaning the
closure's `self` may be a different plugin instance than the one the user
configured credentials from (Reader vs FileManager context).  Call this at the
top of every fileDialog* function to ensure the latest saved credentials are
always in memory before use.

@return string, string  username, password (may be "" if not configured)
--]]
---BookloreSync:_refreshCredentials.
function BookloreSync:_refreshCredentials()
    if not self.db then return "", "" end
    local username = self.settings:readSetting("booklore_username") or ""
    local password = self.settings:readSetting("booklore_password") or ""
    self.booklore_username = username
    self.booklore_password = password
    return username, password
end

---BookloreSync:fileDialogSyncAnnotations.
function BookloreSync:fileDialogSyncAnnotations(file_path)
    if not self.db then
        UIManager:show(InfoMessage:new{ text = _("Booklore: database not initialised") })
        return
    end
    if not self.highlights_notes_sync_enabled then
        UIManager:show(InfoMessage:new{ text = _("Booklore: annotation sync is disabled in settings") })
        return
    end
    local username, password = self:_refreshCredentials()
    if username == "" or password == "" then
        UIManager:show(InfoMessage:new{ text = _("Booklore: credentials not configured") })
        return
    end

    local book = self.db:getBookByFilePath(file_path)
    if not book then
        UIManager:show(InfoMessage:new{
            text = _("Booklore: book not found in local database.\nOpen the book first to register it."),
        })
        return
    end
    if not book.book_id then
        UIManager:show(InfoMessage:new{
            text = _("Booklore: book is not yet matched to Booklore.\nUse \"Match Book\" first."),
        })
        return
    end

    self:refreshEffectiveServerUrl()
    self.api:init(self.server_url, self.username, self.password, self.db)

    UIManager:show(InfoMessage:new{
        text = _("Booklore: syncing annotations…"),
        timeout = 1,
    })

    -- Step 1: read the SDR and queue/submit any unqueued annotations for this
    -- book.  syncHighlightsAndNotes falls back to the on-disk sidecar when no
    -- live document is open.
    self:syncHighlightsAndNotes(file_path, book.book_id, nil, nil, nil)

    -- Step 2: retry any rows in pending_annotations that belong to this book.
    local book_cache_id = book.id
    local synced, failed = self:syncPendingAnnotations(false, book_cache_id)
    local msg
    if synced > 0 then
        msg = T(_("Booklore: synced %1 annotation(s), %2 failed"), synced, failed)
    elseif failed > 0 then
        msg = T(_("Booklore: %1 annotation(s) failed to sync"), failed)
    else
        msg = _("Booklore: no pending annotations to sync for this book.\nAnnotations are captured when you close the book.")
    end
    UIManager:show(InfoMessage:new{ text = msg, timeout = 3 })
end

--[[--
File manager long-press: Match a single book to Booklore.
Uses the existing interactive book-cache matching flow but scoped to one book.
--]]
---BookloreSync:fileDialogMatchBook.
function BookloreSync:fileDialogMatchBook(file_path)
    if not self.db then
        UIManager:show(InfoMessage:new{ text = _("Booklore: database not initialised") })
        return
    end
    -- Re-read credentials from DB in case they were saved from a different
    -- plugin context (Reader vs FileManager) after this instance was initialised.
    local username, password = self:_refreshCredentials()
    if username == "" or password == "" then
        UIManager:show(InfoMessage:new{ text = _("Booklore: credentials not configured") })
        return
    end

    local book = self.db:getBookByFilePath(file_path)
    if not book then
        UIManager:show(InfoMessage:new{
            text = _("Booklore: book not found in local database.\nOpen the book first to register it."),
        })
        return
    end
    if book.book_id then
        UIManager:show(ConfirmBox:new{
            text = T(_("Booklore: this book is already matched (id %1).\nRe-match it?"), book.book_id),
            ok_text = _("Re-match"),
            ok_callback = function()
                self:_matchSingleBookInteractive(book)
            end,
        })
        return
    end

    self:_matchSingleBookInteractive(book)
end

--[[--
Internal: run the interactive match dialog for a single book_cache row.
--]]
---BookloreSync:_matchSingleBook.
function BookloreSync:_matchSingleBook(book)
    self:refreshEffectiveServerUrl()
    self.api:init(self.server_url, self.username, self.password, self.db)

    local search_term = book.title and book.title ~= "" and book.title
                        or book.file_path:match("([^/]+)$") or ""

    UIManager:show(InfoMessage:new{
        text = T(_("Booklore: searching for: %1"), search_term),
        timeout = 1,
    })

    local success, results = self.api:searchBooksWithAuth(
        search_term, self.booklore_username, self.booklore_password
    )

    if not success then
        local err = type(results) == "string" and results or _("Unknown error")
        UIManager:show(InfoMessage:new{
            text = T(_("Booklore: search failed: %1"), err),
        })
        return
    end

    if not results or #results == 0 then
        UIManager:show(InfoMessage:new{
            text = T(_("Booklore: no matches found for:\n%1"), search_term),
        })
        return
    end

    local top_results = {}
    for i = 1, math.min(5, #results) do
        top_results[i] = results[i]
    end

    local buttons = {}
    for _, result in ipairs(top_results) do
        local score = result.matchScore
            and string.format(" (%.0f%%)", result.matchScore * 100)
            or ""
        local label = result.title .. score
        if result.author and result.author ~= "" then
            label = label .. "\n" .. result.author
        end
        local r = result
        table.insert(buttons, {{
            text = label,
            callback = function()
                UIManager:close(self.bk_match_dialog)
                self:_saveBookCacheMatch(book, r)
            end,
        }})
    end
    table.insert(buttons, {{
        text = _("Cancel"),
        callback = function()
            UIManager:close(self.bk_match_dialog)
        end,
    }})

    self.bk_match_dialog = ButtonDialog:new{
        title = T(_("Select match for:\n%1"), search_term),
        buttons = buttons,
    }
    UIManager:show(self.bk_match_dialog)
end

--[[--
Internal: interactive single-book match with an editable InputDialog.

Unlike _matchSingleBook (which fires an immediate silent search), this
function first shows an InputDialog pre-filled with the book's title so
the user can adjust the search term or enter a numeric Booklore ID before
the search runs.  Used from fileDialogMatchBook (long-press menu).

@param book  table  Row from getBookByFilePath()
--]]
---BookloreSync:_matchSingleBookInteractive.
function BookloreSync:_matchSingleBookInteractive(book)
    local default_term = (book.title and book.title ~= "") and book.title
                         or book.file_path:match("([^/]+)$") or ""

    local input_dialog
    input_dialog = InputDialog:new{
        title   = T(_("Match book:\n%1"), default_term),
        description = _("accepts title or id"),
        input   = default_term,
        buttons = {
            {
                {
                    text = _("Cancel"),
                    callback = function()
                        UIManager:close(input_dialog)
                    end,
                },
                {
                    text             = _("Search"),
                    is_enter_default = true,
                    callback         = function()
                        local term = input_dialog:getInputText()
                        UIManager:close(input_dialog)
                        if not term or term == "" then return end

                        -- Pure integer → fetch by ID and save immediately
                        if term:match("^%d+$") then
                            local id = tonumber(term)
                            local ok, result = self.api:getBookById(
                                id, self.booklore_username, self.booklore_password)
                            if not ok or not result then
                                UIManager:show(ConfirmBox:new{
                                    text        = T(_("Booklore: no book found with ID %1.\nRetry?"), id),
                                    ok_text     = _("Retry"),
                                    cancel_text = _("Cancel"),
                                    ok_callback = function()
                                        self:_matchSingleBookInteractive(book)
                                    end,
                                })
                                return
                            end
                            self:_saveBookCacheMatch(book, result)
                            return
                        end

                        -- Text → search by title
                        UIManager:show(InfoMessage:new{
                            text    = T(_("Booklore: searching for: %1"), term),
                            timeout = 1,
                        })
                        local ok, results = self.api:searchBooksWithAuth(
                            term, self.booklore_username, self.booklore_password)
                        if not ok then
                            local err = type(results) == "string" and results or _("Unknown error")
                            UIManager:show(ConfirmBox:new{
                                text        = T(_("Booklore: search failed: %1\nRetry?"), err),
                                ok_text     = _("Retry"),
                                cancel_text = _("Cancel"),
                                ok_callback = function()
                                    self:_matchSingleBookInteractive(book)
                                end,
                            })
                            return
                        end
                        if not results or #results == 0 then
                            UIManager:show(ConfirmBox:new{
                                text        = T(_("Booklore: no results for:\n%1\nRetry?"), term),
                                ok_text     = _("Retry"),
                                cancel_text = _("Cancel"),
                                ok_callback = function()
                                    self:_matchSingleBookInteractive(book)
                                end,
                            })
                            return
                        end

                        local top_results = {}
                        for i = 1, math.min(5, #results) do
                            top_results[i] = results[i]
                        end
                        local buttons = {}
                        for _, result in ipairs(top_results) do
                            local score = result.matchScore
                                and string.format(" (%.0f%%)", result.matchScore * 100) or ""
                            local label = result.title .. score
                            if result.author and result.author ~= "" then
                                label = label .. "\n" .. result.author
                            end
                            local r = result
                            table.insert(buttons, {{
                                text     = label,
                                callback = function()
                                    UIManager:close(self.bk_match_dialog)
                                    self:_saveBookCacheMatch(book, r)
                                end,
                            }})
                        end
                        table.insert(buttons, {{
                            text     = _("Cancel"),
                            callback = function()
                                UIManager:close(self.bk_match_dialog)
                            end,
                        }})

                        self.bk_match_dialog = ButtonDialog:new{
                            title   = T(_("Select match for:\n%1"), term),
                            buttons = buttons,
                        }
                        UIManager:show(self.bk_match_dialog)
                    end,
                },
            },
        },
    }
    UIManager:show(input_dialog)
end

--[[--
File manager long-press: Sync the KOReader star rating for a single book.
--]]
---BookloreSync:fileDialogSyncRating.
function BookloreSync:fileDialogSyncRating(file_path)
    if not self.db then
        UIManager:show(InfoMessage:new{ text = _("Booklore: database not initialised") })
        return
    end
    local username, password = self:_refreshCredentials()
    if username == "" or password == "" then
        UIManager:show(InfoMessage:new{ text = _("Booklore: credentials not configured") })
        return
    end

    local book = self.db:getBookByFilePath(file_path)
    if not book then
        UIManager:show(InfoMessage:new{
            text = _("Booklore: book not found in local database.\nOpen the book first to register it."),
        })
        return
    end
    if not book.book_id then
        UIManager:show(InfoMessage:new{
            text = _("Booklore: book is not yet matched to Booklore.\nUse \"Match Book\" first."),
        })
        return
    end

    self:refreshEffectiveServerUrl()
    self.api:init(self.server_url, self.username, self.password, self.db)

    local mode = self.rating_sync_mode or "koreader_scaled"

    if mode == "select_at_complete" then
        -- Manual mode: let the user enter a rating via the standard dialog.
        self:showRatingDialog(file_path, book.book_id)
        return
    end

    -- koreader_scaled: verify a star rating actually exists before trying to sync.
    local existing_rating = self.metadata_extractor:getRating(file_path)
    if not existing_rating then
        UIManager:show(InfoMessage:new{
            text = _("Booklore: this book has not been rated in KOReader yet.\nSet a star rating and try again."),
        })
        return
    end

    -- syncKOReaderRating requires a live_rating or reads from doc_settings;
    -- pass nil so it reads from the stored sdr/doc_settings for this path.
    self:syncKOReaderRating(file_path, book.book_id, nil)
end

--[[--
Long-press menu: show a ButtonDialog letting the user choose which sync to run.

Choices: Annotations, Rating, Both.  "Both" runs annotation sync inline first,
then rating sync; a single combined InfoMessage reports the outcome.
For "Both" with select_at_complete rating mode, the annotation result is shown
first, then the rating InputDialog is opened afterwards.
--]]
---BookloreSync:_fileDialogBookloreSync.
function BookloreSync:_fileDialogBookloreSync(file_path)
    if not self.db then
        UIManager:show(InfoMessage:new{ text = _("Booklore: database not initialised") })
        return
    end
    local username, password = self:_refreshCredentials()
    if username == "" or password == "" then
        UIManager:show(InfoMessage:new{ text = _("Booklore: credentials not configured") })
        return
    end

    local sync_dialog
    sync_dialog = ButtonDialog:new{
        title   = _("Booklore Sync"),
        buttons = {
            {{
                text     = _("Annotations"),
                callback = function()
                    UIManager:close(sync_dialog)
                    UIManager:show(ConfirmBox:new{
                        text = _("Will only sync to webUI, not in book, as spine is missing"),
                        ok_text = _("Continue"),
                        ok_callback = function()
                            self:fileDialogSyncAnnotations(file_path)
                        end,
                    })
                end,
            }},
            {{
                text     = _("Rating"),
                callback = function()
                    UIManager:close(sync_dialog)
                    self:fileDialogSyncRating(file_path)
                end,
            }},
            {{
                text     = _("Both"),
                callback = function()
                    UIManager:close(sync_dialog)
                    self:_fileDialogSyncBoth(file_path)
                end,
            }},
            {{
                text     = _("Cancel"),
                callback = function()
                    UIManager:close(sync_dialog)
                end,
            }},
        },
    }
    UIManager:show(sync_dialog)
end

--[[--
Internal: run annotation sync and rating sync together and report a combined result.
--]]
---BookloreSync:_fileDialogSyncBoth.
function BookloreSync:_fileDialogSyncBoth(file_path)
    -- ── Prerequisites ────────────────────────────────────────────────────
    local book = self.db:getBookByFilePath(file_path)
    if not book then
        UIManager:show(InfoMessage:new{
            text = _("Booklore: book not found in local database.\nOpen the book first to register it."),
        })
        return
    end
    if not book.book_id then
        UIManager:show(InfoMessage:new{
            text = _("Booklore: book is not yet matched to Booklore.\nUse \"Match Book\" first."),
        })
        return
    end

    self:refreshEffectiveServerUrl()
    self.api:init(self.server_url, self.username, self.password, self.db)

    local book_cache_id = book.id

    -- ── Annotations ──────────────────────────────────────────────────────
    local ann_parts = {}
    if self.highlights_notes_sync_enabled then
        -- Step 1: read SDR and queue/submit unqueued annotations for this book.
        self:syncHighlightsAndNotes(file_path, book.book_id, nil, nil, nil)
        -- Step 2: retry any remaining pending rows for this book only.
        local synced, failed = self:syncPendingAnnotations(false, book_cache_id)
        synced = tonumber(synced) or 0
        failed = tonumber(failed) or 0
        if synced > 0 or failed > 0 then
            ann_parts[#ann_parts + 1] = T(_("Annotations: %1 synced, %2 failed"), synced, failed)
        else
            ann_parts[#ann_parts + 1] = _("Annotations: none pending")
        end
    else
        ann_parts[#ann_parts + 1] = _("Annotations: disabled in settings")
    end

    if self.bookmarks_sync_enabled then
        local bm_synced, bm_failed = self:syncPendingBookmarks(false, book_cache_id)
        bm_synced = tonumber(bm_synced) or 0
        bm_failed = tonumber(bm_failed) or 0
        if bm_synced > 0 or bm_failed > 0 then
            ann_parts[#ann_parts + 1] = T(_("Bookmarks: %1 synced, %2 failed"), bm_synced, bm_failed)
        end
    end

    -- ── Rating ───────────────────────────────────────────────────────────
    local mode = self.rating_sync_mode or "koreader_scaled"

    if mode == "select_at_complete" then
        -- Show annotation summary first, then open the rating dialog.
        UIManager:show(InfoMessage:new{
            text    = table.concat(ann_parts, "\n"),
            timeout = 3,
        })
        self:showRatingDialog(file_path, book.book_id)
        return
    end

    -- koreader_scaled: sync inline and add to the summary.
    local existing_rating = self.metadata_extractor:getRating(file_path)
    if not existing_rating then
        ann_parts[#ann_parts + 1] = _("Rating: not rated in KOReader yet")
    else
        local ok_r = self:syncKOReaderRating(file_path, book.book_id, nil)
        -- syncKOReaderRating does not return a value; check rating_synced flag
        local bcid = self.db:getBookCacheIdByFilePath(file_path)
        local meta = bcid and self.db:getBookMetadata(bcid)
        if meta and meta.rating_synced then
            ann_parts[#ann_parts + 1] = _("Rating: synced")
        else
            ann_parts[#ann_parts + 1] = _("Rating: sync failed or already synced")
        end
    end

    UIManager:show(InfoMessage:new{
        text    = table.concat(ann_parts, "\n"),
        timeout = 4,
    })
end

--[[--
File manager long-press: set Booklore reading status for a single matched book.

@param file_path string  Absolute path to the book file
--]]
---BookloreSync:fileDialogSetReadingStatus.
function BookloreSync:fileDialogSetReadingStatus(file_path)
    if not self.db then
        UIManager:show(InfoMessage:new{ text = _("Booklore: database not initialised") })
        return
    end

    local username, password = self:_refreshCredentials()
    if username == "" or password == "" then
        UIManager:show(InfoMessage:new{ text = _("Booklore: credentials not configured") })
        return
    end

    local book = self.db:getBookByFilePath(file_path)
    if not book then
        UIManager:show(InfoMessage:new{
            text = _("Booklore: book not found in local database.\nOpen the book first to register it."),
        })
        return
    end
    if not book.book_id then
        UIManager:show(InfoMessage:new{
            text = _("Booklore: book is not yet matched to Booklore.\nUse \"Match Book\" first."),
        })
        return
    end

    local status_dialog
    local status_options = {
        { label = _("Unread"), value = "UNREAD" },
        { label = _("Paused"), value = "PAUSED" },
        { label = _("Partially read"), value = "PARTIALLY_READ" },
        { label = _("Abandoned"), value = "ABANDONED" },
        { label = _("Won't read"), value = "WONT_READ" },
    }
    local buttons = {}

    for _, option in ipairs(status_options) do
        local selected_option = option
        table.insert(buttons, {{
            text = selected_option.label,
            callback = function()
                UIManager:close(status_dialog)
                self:_fileDialogApplyReadingStatus(file_path, selected_option.value, selected_option.label)
            end,
        }})
    end

    table.insert(buttons, {{
        text = _("Cancel"),
        callback = function()
            UIManager:close(status_dialog)
        end,
    }})

    status_dialog = ButtonDialog:new{
        title = _("Set Reading Status"),
        buttons = buttons,
    }
    UIManager:show(status_dialog)
end

--[[--
Apply selected Booklore reading status for a single matched book.

@param file_path string  Absolute path to the book file
@param status string     Uppercase Booklore status value
@param label string      Human-readable status label for UI
--]]
---BookloreSync:_fileDialogApplyReadingStatus.
function BookloreSync:_fileDialogApplyReadingStatus(file_path, status, label)
    local username, password = self:_refreshCredentials()
    if username == "" or password == "" then
        UIManager:show(InfoMessage:new{ text = _("Booklore: credentials not configured") })
        return
    end

    local book = self.db and self.db:getBookByFilePath(file_path)
    local book_id = book and tonumber(book.book_id)
    if not book_id then
        UIManager:show(InfoMessage:new{
            text = _("Booklore: book is not yet matched to Booklore.\nUse \"Match Book\" first."),
        })
        return
    end

    self:refreshEffectiveServerUrl()
    self.api:init(self.server_url, self.username, self.password, self.db)

    local ok, err = self.api:updateBookStatus({ book_id }, status, username, password)
    if ok then
        UIManager:show(InfoMessage:new{
            text = T(_("Booklore: reading status set to %1"), label),
            timeout = 3,
        })
        return
    end

    UIManager:show(InfoMessage:new{
        text = T(_("Booklore: failed to update reading status (%1)"), tostring(err or _("Unknown error"))),
        timeout = 3,
    })
end

--[[--
Toggle tracking for a book from the file manager long-press menu.

When tracking is disabled the book's cache row is updated immediately
(or created with tracking_enabled=0 if the book has never been opened).
Pending sessions already in the queue are left untouched - they will be
skipped by getPendingSessions until tracking is re-enabled.

@param file_path string  Absolute path to the book file
--]]
---BookloreSync:fileDialogToggleTracking.
function BookloreSync:fileDialogToggleTracking(file_path)
    if not self.db then
        UIManager:show(InfoMessage:new{ text = _("Booklore: database not initialised"), timeout = 2 })
        return
    end

    local currently_enabled = self.db:isBookTrackingEnabled(file_path)
    local new_state = not currently_enabled

    -- Ensure there is a cache row to update. If the book has never been opened,
    -- saveBookCache creates one with defaults; setBookTracking then flips the flag.
    local book = self.db:getBookByFilePath(file_path)
    if not book then
        local stem = file_path:match("([^/\\]+)%.[^%.]+$") or file_path:match("([^/\\]+)$")
        self.db:saveBookCache(file_path, "", nil, stem, nil, nil, nil)
    end

    local ok = self.db:setBookTracking(file_path, new_state)
    if ok then
        UIManager:show(InfoMessage:new{
            text = new_state
                and T(_("Tracking enabled for:\n%1"), file_path:match("([^/\\]+)$") or file_path)
                or  T(_("Tracking disabled for:\n%1\n\nSessions will not be uploaded."),
                       file_path:match("([^/\\]+)$") or file_path),
            timeout = 3,
        })
    else
        UIManager:show(InfoMessage:new{
            text = _("Booklore: failed to update tracking setting"),
            timeout = 2,
        })
    end
end

--[[--
Show stored data counts for the selected book.

Displays a summary of synced and pending sessions, annotations, and bookmarks
stored locally in the Booklore database for the given file.

@param file_path string  Absolute path to the book file
--]]
---BookloreSync:fileDialogShowStoredData.
function BookloreSync:fileDialogShowStoredData(file_path)
    if not self.db then
        UIManager:show(InfoMessage:new{ text = _("Booklore: database not initialised"), timeout = 2 })
        return
    end

    local book = self.db:getBookByFilePath(file_path)
    if not book then
        UIManager:show(InfoMessage:new{
            text = _("Booklore: no local record found for this book.\nOpen the book first to register it."),
            timeout = 3,
        })
        return
    end

    local book_cache_id = book.id

    local session_counts = self.db:getStoredSessionCountsForBook(
        book_cache_id,
        book.book_id,
        book.file_hash
    )
    local synced_sessions = tonumber(session_counts.synced) or 0
    local unsynced_sessions = tonumber(session_counts.pending) or 0
    local total_sessions = tonumber(session_counts.total) or (synced_sessions + unsynced_sessions)

    -- Annotations
    local synced_ann   = self.db:getSyncedAnnotationCountForBook(book_cache_id)
    local pending_ann  = self.db:getPendingAnnotationCountForBook(book_cache_id)

    -- Bookmarks
    local synced_bm    = self.db:getSyncedBookmarkCountForBook(book_cache_id)
    local pending_bm   = self.db:getPendingBookmarkCountForBook(book_cache_id)

    local book_title = book.title or (file_path:match("([^/]+)$") or file_path):gsub("%.[^.]+$", "")
    local is_matched = (book.book_id ~= nil)

    local lines = {}
    table.insert(lines, book_title)
    table.insert(lines, string.rep("-", 40))
    table.insert(lines, "")
    if is_matched then
        table.insert(lines, _("Server ID:") .. " " .. tostring(book.book_id))
        local server_pagecount = tonumber(book.server_pagecount)
        if server_pagecount and server_pagecount > 0 then
            table.insert(lines, _("Server pagecount:") .. " " .. tostring(server_pagecount))
        else
            table.insert(lines, _("Server pagecount:") .. " " .. _("(unknown)"))
        end
    else
        table.insert(lines, _("Server ID:") .. " " .. _("(not matched)"))
        table.insert(lines, _("Server pagecount:") .. " " .. _("(not matched)"))
    end
    table.insert(lines, "")
    table.insert(lines, "── " .. _("Reading Sessions") .. " ──")
    table.insert(lines, _("  Synced:  ") .. tostring(synced_sessions))
    table.insert(lines, _("  Pending: ") .. tostring(unsynced_sessions))
    table.insert(lines, _("  Total:   ") .. tostring(total_sessions))
    table.insert(lines, "")
    table.insert(lines, "── " .. _("Annotations") .. " ──")
    table.insert(lines, _("  Synced:  ") .. tostring(synced_ann))
    table.insert(lines, _("  Pending: ") .. tostring(pending_ann))
    table.insert(lines, _("  Total:   ") .. tostring(synced_ann + pending_ann))
    table.insert(lines, "")
    table.insert(lines, "── " .. _("Bookmarks") .. " ──")
    table.insert(lines, _("  Synced:  ") .. tostring(synced_bm))
    table.insert(lines, _("  Pending: ") .. tostring(pending_bm))
    table.insert(lines, _("  Total:   ") .. tostring(synced_bm + pending_bm))

    local TextViewer = require("ui/widget/textviewer")
    local Screen = require("device").screen
    UIManager:show(TextViewer:new{
        title = _("Stored Data"),
        text = table.concat(lines, "\n"),
        width = math.floor(Screen:getWidth() * 0.85),
        height = math.floor(Screen:getHeight() * 0.7),
    })
end

--[[--
Extract annotations and bookmarks from the sidecar file and push them to Booklore.

Reads the KOReader sidecar (.sdr) for the given book, shows detected counts, then
(after confirmation) calls syncHighlightsAndNotes + syncBookmarks followed by the
pending-queue flushes.

For unmatched books the user is offered to match the book first before syncing.

@param file_path string  Absolute path to the book file
--]]
---BookloreSync:fileDialogExtractFromSidecar.
function BookloreSync:fileDialogExtractFromSidecar(file_path)
    if not self.db then
        UIManager:show(InfoMessage:new{ text = _("Booklore: database not initialised"), timeout = 2 })
        return
    end

    -- Read sidecar counts first (fast, no network)
    local counts = self.metadata_extractor:getCounts(file_path)
    local total_sidecar = (counts.highlights or 0) + (counts.notes or 0) + (counts.bookmarks or 0)

    if total_sidecar == 0 then
        UIManager:show(InfoMessage:new{
            text = _("Booklore: no annotations or bookmarks found in sidecar for this book."),
            timeout = 3,
        })
        return
    end

    local book = self.db:getBookByFilePath(file_path)

    -- Book not yet in the local cache → create a stub so the user can match it
    if not book then
        local stem = (file_path:match("([^/\\]+)%.[^%.]+$") or file_path:match("([^/\\]+)$") or "Unknown")
        self.db:saveBookCache(file_path, "", nil, stem, nil, nil, nil)
        book = self.db:getBookByFilePath(file_path)
    end

    local counts_text = T(_("Highlights: %1\nNotes: %2\nBookmarks: %3"),
        tostring(counts.highlights or 0),
        tostring(counts.notes or 0),
        tostring(counts.bookmarks or 0))

    -- Book not matched to a Booklore server book → offer to match first
    if not book or not book.book_id then
        UIManager:show(ConfirmBox:new{
            text = T(_("Sidecar data detected:\n\n%1\n\nThis book is not yet matched to Booklore.\nMatch it now to enable sync?"),
                counts_text),
            ok_text = _("Match Book"),
            ok_callback = function()
                self:fileDialogMatchBook(file_path)
            end,
        })
        return
    end

    -- Book is matched → confirm then sync
    local book_cache_id = book.id
    local server_book_id = book.book_id

    UIManager:show(ConfirmBox:new{
        text = T(_("Sidecar data detected:\n\n%1\n\nSync these to Booklore now?"), counts_text),
        ok_text = _("Sync"),
        ok_callback = function()
            -- Sync annotations (highlights + notes)
            self:syncHighlightsAndNotes(file_path, server_book_id, nil, nil, nil)
            self:syncPendingAnnotations(false, book_cache_id)

            -- Sync bookmarks
            self:syncBookmarks(file_path, server_book_id, nil, nil, nil)
            self:syncPendingBookmarks(false, book_cache_id)
        end,
    })
end

---BookloreSync:addToMainMenu.
function BookloreSync:addToMainMenu(menu_items)
    self:applyAirplaneModeSyncModeIntegration()

    local function showSectionHelp(title, body)
        UIManager:show(InfoMessage:new{
            text = T(_("%1\n\n%2"), title, body),
        })
    end

    local base_menu = {}
    
    local enable_sync_menu = {
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
    }
    
    local auth_menu = Settings:buildAuthMenu(self)
    auth_menu.hold_callback = function()
        showSectionHelp(
            _("Connection Setup"),
            _("Set server URL, KOReader credentials, Booklore credentials, and run connection tests.")
        )
    end
    table.insert(base_menu, enable_sync_menu)
    table.insert(base_menu, auth_menu)

    local session_validation_menu = {
        text = _("Reading Sessions"),
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
    }

    local sync_mode_menu = {
        text = _("Sync Mode"),
        help_text = _("Choose between automatic syncing and manual queue-only mode."),
        sub_item_table = {
            {
                text = _("Networking"),
                help_text = _("Configure WiFi connection behavior for sync actions."),
                sub_item_table = {
                    {
                        text_func = function()
                            return T(_("WiFi connect timeout (seconds) (%1)"), tostring(self.network_connect_timeout_seconds or DEFAULT_NETWORK_CONNECT_TIMEOUT_SECONDS))
                        end,
                        help_text = _("How long to wait for WiFi to become connected after enabling it, before giving up. Increase this on slower devices."),
                        enabled_func = function()
                            return not self.network_connect_run_until_connect
                        end,
                        keep_menu_open = true,
                        callback = function()
                            Settings:configureNetworkConnectTimeout(self)
                        end,
                    },
                    {
                        text = _("Sync delay after connect"),
                        help_text = _("Wait this many seconds after network becomes connected before running sync requests. Useful on devices where routing/DNS is not immediately ready after WiFi connect."),
                        keep_menu_open = true,
                        callback = function()
                            Settings:configureSyncDelayAfterConnect(self)
                        end,
                    },
                    {
                        text = _("Run until connect"),
                        help_text = _("Disable plugin-side connect timeout and wait until WiFi connects or the underlying network stack times out on its own."),
                        checked_func = function()
                            return self.network_connect_run_until_connect
                        end,
                        keep_menu_open = true,
                        callback = function()
                            self.network_connect_run_until_connect = not self.network_connect_run_until_connect
                            self.settings:saveSetting("network_connect_run_until_connect", self.network_connect_run_until_connect)
                            self.settings:flush()
                        end,
                    },
                },
            },
            {
                text = _("Automatic (sync on suspend when connected)"),
                help_text = _("Automatically sync sessions on suspend and resume only when WiFi is already connected. The plugin does not enable WiFi on suspend; if disconnected, data stays queued until the next sync trigger."),
                checked_func = function()
                    self:applyAirplaneModeSyncModeIntegration()
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
                    self:applyAirplaneModeSyncModeIntegration()
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
        },
    }

    local progress_sync_menu = {
        text = _("Progress Sync"),
        help_text = _("Configure KOReader document-position sync with Booklore."),
        sub_item_table = {
            {
                text = _("General"),
                sub_item_table = {
                    {
                        text = _("Automatically sync progress"),
                        help_text = _("Automatically keep document position in sync across devices."),
                        checked_func = function()
                            return self.progress_sync_enabled
                        end,
                        callback = function()
                            self.progress_sync_enabled = not self.progress_sync_enabled
                            self.settings:saveSetting("progress_sync_enabled", self.progress_sync_enabled)
                            self.settings:flush()
                            UIManager:show(InfoMessage:new{
                                text = self.progress_sync_enabled and _("Automatic progress sync enabled") or _("Automatic progress sync disabled"),
                                timeout = 2,
                            })
                        end,
                    },
                    {
                        text = _("Pull progress on book open"),
                        help_text = _("When WiFi is already connected, check for remote progress when opening a book."),
                        checked_func = function()
                            return self.progress_pull_on_open
                        end,
                        enabled_func = function()
                            return self.progress_sync_enabled
                        end,
                        callback = function()
                            self.progress_pull_on_open = not self.progress_pull_on_open
                            self.settings:saveSetting("progress_pull_on_open", self.progress_pull_on_open)
                            self.settings:flush()
                        end,
                        keep_menu_open = true,
                    },
                    {
                        text = _("Pull progress on resume"),
                        help_text = _("When WiFi is already connected, check for remote progress after wake/resume."),
                        checked_func = function()
                            return self.progress_pull_on_resume
                        end,
                        enabled_func = function()
                            return self.progress_sync_enabled
                        end,
                        callback = function()
                            self.progress_pull_on_resume = not self.progress_pull_on_resume
                            self.settings:saveSetting("progress_pull_on_resume", self.progress_pull_on_resume)
                            self.settings:flush()
                        end,
                        keep_menu_open = true,
                    },
                    {
                        text = _("Pull progress now"),
                        help_text = _("Immediately pull progress for the currently open book."),
                        enabled_func = function()
                            return self.progress_sync_enabled
                        end,
                        callback = function()
                            self:onPullBookloreCurrentBookProgress()
                        end,
                        keep_menu_open = true,
                    },
                    {
                        text = _("Push progress now"),
                        help_text = _("Immediately push progress for the currently open book."),
                        enabled_func = function()
                            return self.progress_sync_enabled
                        end,
                        callback = function()
                            self:onPushBookloreCurrentBookProgress()
                        end,
                        keep_menu_open = true,
                    },
                },
                keep_menu_open = true,
            },
            {
                text = _("Conflict handling"),
                help_text = _("Control how incoming progress updates are applied."),
                enabled_func = function()
                    return self.progress_sync_enabled
                end,
                sub_item_table = {
                    {
                        text_func = function()
                            return T(_("Sync to a newer state (%1)"), self:getProgressStrategyName(self.progress_sync_forward_strategy))
                        end,
                        sub_item_table = {
                            {
                                text = _("Silently"),
                                checked_func = function()
                                    return self.progress_sync_forward_strategy == PROGRESS_SYNC_STRATEGY.SILENT
                                end,
                                callback = function()
                                    self:setProgressSyncForwardStrategy(PROGRESS_SYNC_STRATEGY.SILENT)
                                end,
                            },
                            {
                                text = _("Prompt"),
                                checked_func = function()
                                    return self.progress_sync_forward_strategy == PROGRESS_SYNC_STRATEGY.PROMPT
                                end,
                                callback = function()
                                    self:setProgressSyncForwardStrategy(PROGRESS_SYNC_STRATEGY.PROMPT)
                                end,
                            },
                            {
                                text = _("Disable"),
                                checked_func = function()
                                    return self.progress_sync_forward_strategy == PROGRESS_SYNC_STRATEGY.DISABLE
                                end,
                                callback = function()
                                    self:setProgressSyncForwardStrategy(PROGRESS_SYNC_STRATEGY.DISABLE)
                                end,
                            },
                        },
                        keep_menu_open = true,
                    },
                    {
                        text_func = function()
                            return T(_("Sync to an older state (%1)"), self:getProgressStrategyName(self.progress_sync_backward_strategy))
                        end,
                        sub_item_table = {
                            {
                                text = _("Silently"),
                                checked_func = function()
                                    return self.progress_sync_backward_strategy == PROGRESS_SYNC_STRATEGY.SILENT
                                end,
                                callback = function()
                                    self:setProgressSyncBackwardStrategy(PROGRESS_SYNC_STRATEGY.SILENT)
                                end,
                            },
                            {
                                text = _("Prompt"),
                                checked_func = function()
                                    return self.progress_sync_backward_strategy == PROGRESS_SYNC_STRATEGY.PROMPT
                                end,
                                callback = function()
                                    self:setProgressSyncBackwardStrategy(PROGRESS_SYNC_STRATEGY.PROMPT)
                                end,
                            },
                            {
                                text = _("Disable"),
                                checked_func = function()
                                    return self.progress_sync_backward_strategy == PROGRESS_SYNC_STRATEGY.DISABLE
                                end,
                                callback = function()
                                    self:setProgressSyncBackwardStrategy(PROGRESS_SYNC_STRATEGY.DISABLE)
                                end,
                            },
                        },
                        keep_menu_open = true,
                    },
                },
                keep_menu_open = true,
            },
            {
                text = _("Update frequency"),
                enabled_func = function()
                    return self.progress_sync_enabled
                end,
                sub_item_table = {
                    {
                        text = _("Periodic page-turn updates"),
                        help_text = _("Enable or disable periodic page-turn progress updates. Book-open and book-close positions are always stored."),
                        checked_func = function()
                            return self.progress_sync_page_updates_enabled
                        end,
                        keep_menu_open = true,
                        callback = function()
                            self.progress_sync_page_updates_enabled = not self.progress_sync_page_updates_enabled
                            self.progress_sync_trigger = self.progress_sync_page_updates_enabled and "each_n_pages" or "book_open_close"
                            self.settings:saveSetting("progress_sync_page_updates_enabled", self.progress_sync_page_updates_enabled)
                            self.settings:saveSetting("progress_sync_trigger", self.progress_sync_trigger)
                            self.settings:flush()
                            UIManager:show(InfoMessage:new{
                                text = self.progress_sync_page_updates_enabled and _("Periodic page-turn updates enabled") or _("Periodic page-turn updates disabled"),
                                timeout = 2,
                            })
                        end,
                    },
                    {
                        text_func = function()
                            return T(_("Periodically sync every # pages (%1)"), tostring(self.progress_sync_interval_pages or 1))
                        end,
                        help_text = _("How many page turns before a periodic sync update is queued. Minimum is 1 when periodic updates are enabled."),
                        enabled_func = function()
                            return self.progress_sync_page_updates_enabled
                        end,
                        keep_menu_open = true,
                        callback = function()
                            local SpinWidget = require("ui/widget/spinwidget")
                            local widget = SpinWidget:new{
                                text = _("This value determines how many page turns it takes to update book progress.\nMinimum value is 1."),
                                value = self.progress_sync_interval_pages or 1,
                                value_min = 1,
                                value_max = 999,
                                value_step = 1,
                                value_hold_step = 10,
                                ok_text = _("Set"),
                                title_text = _("Number of pages before update"),
                                default_value = 10,
                                callback = function(spin)
                                    local n = math.floor(tonumber(spin.value) or 1)
                                    if n < 1 then n = 1 end
                                    self.progress_sync_interval_pages = n
                                    self.progress_sync_trigger = self.progress_sync_page_updates_enabled and "each_n_pages" or "book_open_close"
                                    self.settings:saveSetting("progress_sync_interval_pages", n)
                                    self.settings:saveSetting("progress_sync_trigger", self.progress_sync_trigger)
                                    self.settings:flush()
                                end,
                            }
                            UIManager:show(widget)
                        end,
                    },
                },
                keep_menu_open = true,
            },
        },
    }

    local what_to_sync_advanced_menu = {
        text = _("Advanced"),
        sub_item_table = {
            {
                text = _("Normalize session locations"),
                help_text = _("When enabled, start/end session locations are converted to the server page-count scale so the displayed book page is correct instead of using KOReader-provided pages. This needs page count metadata from the server, which can be re-synced in Sync & Cache -> Advanced. Progress percentages are unchanged."),
                checked_func = function()
                    return self.progress_sync_normalize_session_locations
                end,
                callback = function()
                    self.progress_sync_normalize_session_locations = not self.progress_sync_normalize_session_locations
                    self.settings:saveSetting("progress_sync_normalize_session_locations", self.progress_sync_normalize_session_locations)
                    self.settings:flush()
                    UIManager:show(InfoMessage:new{
                        text = self.progress_sync_normalize_session_locations
                            and _("Session location normalization enabled")
                            or _("Session location normalization disabled"),
                        timeout = 2,
                    })
                end,
                keep_menu_open = true,
            },
            {
                text = _("Set book to read on rating"),
                help_text = _("When a rating is submitted, queue progress as 100% for sync, even if the real reading progress is lower."),
                checked_func = function()
                    return self.progress_sync_set_read_on_rating
                end,
                callback = function()
                    self.progress_sync_set_read_on_rating = not self.progress_sync_set_read_on_rating
                    self.settings:saveSetting("progress_sync_set_read_on_rating", self.progress_sync_set_read_on_rating)
                    self.settings:flush()
                    UIManager:show(InfoMessage:new{
                        text = self.progress_sync_set_read_on_rating and _("Set book to read on rating enabled") or _("Set book to read on rating disabled"),
                        timeout = 2,
                    })
                end,
                keep_menu_open = true,
            },
        },
    }

    local annotations_menu = Settings:buildAnnotationsMenu(self)
    local bookmarks_menu = Settings:buildBookmarksMenu(self)
    local annotations_and_bookmarks_menu = {
        text = _("Annotations & Bookmarks"),
        help_text = _("Configure syncing of highlights, notes, and bookmarks to Booklore."),
        sub_item_table = {},
    }
    for i, item in ipairs(annotations_menu.sub_item_table or {}) do
        table.insert(annotations_and_bookmarks_menu.sub_item_table, item)
        if i == 1 and bookmarks_menu.sub_item_table and bookmarks_menu.sub_item_table[1] then
            table.insert(annotations_and_bookmarks_menu.sub_item_table, bookmarks_menu.sub_item_table[1])
        end
    end
    if #annotations_and_bookmarks_menu.sub_item_table == 0 and bookmarks_menu.sub_item_table and bookmarks_menu.sub_item_table[1] then
        table.insert(annotations_and_bookmarks_menu.sub_item_table, bookmarks_menu.sub_item_table[1])
    end

    local sync_behavior_menu = {
        text = _("Sync Behavior"),
        sub_item_table = sync_mode_menu.sub_item_table,
        hold_callback = function()
            showSectionHelp(
                _("Sync Behavior"),
                _("Choose automatic syncing or manual queue-only mode.")
            )
        end,
    }

    local what_to_sync_menu = {
        text = _("What to Sync"),
        sub_item_table = {
            session_validation_menu,
            progress_sync_menu,
            Settings:buildRatingMenu(self),
            annotations_and_bookmarks_menu,
            {
                text = "────────────────",
                enabled = false,
            },
            what_to_sync_advanced_menu,
        },
        hold_callback = function()
            showSectionHelp(
                _("What to Sync"),
                _("Configure reading session rules, progress sync, rating sync, annotations, and bookmarks.")
            )
        end,
    }

    local shelf_sync_menu = {
        text = _("Shelf Sync"),
        sub_item_table = {
            {
                text = _("Sync from Booklore Shelf"),
                help_text = _("Download books from your Booklore shelf into the local download directory. Books already present are skipped."),
                callback = function()
                    self:onSyncBookloreShelf()
                end,
            },
            {
                text = _("Force full re-sync"),
                help_text = _("Clear the cached shelf state and perform a full sync pass. Useful after manually deleting downloaded books so the plugin re-downloads them."),
                callback = function()
                    if self.db and self.shelf_id then
                        self.db:clearShelfState(self.shelf_id)
                    end
                    self:onSyncBookloreShelf()
                end,
            },
            {
                text = _("Auto-sync shelf on wake"),
                help_text = _("Automatically pull the Booklore shelf 15 seconds after the device wakes from suspend, once WiFi is connected."),
                checked_func = function()
                    return self.auto_sync_shelf_on_resume
                end,
                callback = function()
                    self.auto_sync_shelf_on_resume = not self.auto_sync_shelf_on_resume
                    self.settings:saveSetting("auto_sync_shelf_on_resume", self.auto_sync_shelf_on_resume)
                    self.settings:flush()
                    UIManager:show(InfoMessage:new{
                        text = self.auto_sync_shelf_on_resume
                            and _("Auto-sync shelf on wake enabled")
                            or  _("Auto-sync shelf on wake disabled"),
                        timeout = 2,
                    })
                end,
            },
            {
                text = _("Delete removed shelf books"),
                help_text = _("When syncing, delete local files (in the download directory) whose BookID is no longer on the Booklore shelf. Disabled by default for safety."),
                checked_func = function()
                    return self.delete_removed_shelf_books
                end,
                callback = function()
                    self.delete_removed_shelf_books = not self.delete_removed_shelf_books
                    self.settings:saveSetting("delete_removed_shelf_books", self.delete_removed_shelf_books)
                    self.settings:flush()
                    UIManager:show(InfoMessage:new{
                        text = self.delete_removed_shelf_books
                            and _("Delete removed shelf books enabled - local files not on shelf will be removed during sync")
                            or  _("Delete removed shelf books disabled"),
                        timeout = 2,
                    })
                end,
            },
            {
                text = _("Use original server filename"),
                help_text = _("Save downloaded books using the original filename from the Booklore server instead of deriving the name from the book title."),
                checked_func = function()
                    return self.shelf_use_original_filename
                end,
                callback = function()
                    self.shelf_use_original_filename = not self.shelf_use_original_filename
                    self.settings:saveSetting("shelf_use_original_filename", self.shelf_use_original_filename)
                    self.settings:flush()
                    UIManager:show(InfoMessage:new{
                        text = self.shelf_use_original_filename
                            and _("Will use original server filename when downloading")
                            or  _("Will use book title as filename when downloading"),
                        timeout = 2,
                    })
                end,
            },
            {
                text = _("Also delete sidecar (.sdr) on removal"),
                help_text = _("When a shelf book is deleted during sync, also delete its KOReader sidecar directory (.sdr folder containing reading progress, highlights, etc.). Only applies when 'Delete removed shelf books' is also enabled. Disabled by default."),
                enabled_func = function()
                    return self.delete_removed_shelf_books
                end,
                checked_func = function()
                    return self.delete_sdr_on_book_delete
                end,
                callback = function()
                    self.delete_sdr_on_book_delete = not self.delete_sdr_on_book_delete
                    self.settings:saveSetting("delete_sdr_on_book_delete", self.delete_sdr_on_book_delete)
                    self.settings:flush()
                    UIManager:show(InfoMessage:new{
                        text = self.delete_sdr_on_book_delete
                            and _("Sidecar (.sdr) deletion enabled")
                            or  _("Sidecar (.sdr) deletion disabled"),
                        timeout = 2,
                    })
                end,
            },
            {
                text_func = function()
                    return T(_("Shelf name: %1"), self.booklore_shelf_name)
                end,
                help_text = _("Name of the Booklore shelf to sync. The shelf is created automatically if it does not exist."),
                keep_menu_open = true,
                callback = function()
                    local dialog
                    dialog = InputDialog:new{
                        title   = _("Booklore shelf name"),
                        input   = self.booklore_shelf_name,
                        buttons = {{
                            {
                                text     = _("Cancel"),
                                callback = function() UIManager:close(dialog) end,
                            },
                            {
                                text     = _("Save"),
                                is_enter_default = true,
                                callback = function()
                                    local val = dialog:getInputText()
                                    if val and val ~= "" then
                                        self.booklore_shelf_name = val
                                        self.settings:saveSetting("booklore_shelf_name", val)
                                        -- Invalidate cached shelf_id so it is re-resolved
                                        self.shelf_id = nil
                                        self.settings:saveSetting("shelf_id", nil)
                                        self.settings:flush()
                                    end
                                    UIManager:close(dialog)
                                end,
                            },
                        }},
                    }
                    UIManager:show(dialog)
                    dialog:onShowKeyboard()
                end,
            },
            {
                text_func = function()
                    return T(_("Download dir: %1"), self.download_dir)
                end,
                help_text = _("Local directory where shelf books are downloaded. Detected automatically from device type; override here if needed."),
                keep_menu_open = true,
                callback = function()
                    local dialog
                    dialog = InputDialog:new{
                        title   = _("Download directory"),
                        input   = self.download_dir,
                        buttons = {{
                            {
                                text     = _("Cancel"),
                                callback = function() UIManager:close(dialog) end,
                            },
                            {
                                text     = _("Reset"),
                                callback = function()
                                    self.download_dir = self:_detectDefaultDownloadDir()
                                    self.settings:saveSetting("download_dir", self.download_dir)
                                    self.settings:flush()
                                    UIManager:close(dialog)
                                    UIManager:show(InfoMessage:new{
                                        text = T(_("Reset to: %1"), self.download_dir),
                                        timeout = 2,
                                    })
                                end,
                            },
                            {
                                text     = _("Save"),
                                is_enter_default = true,
                                callback = function()
                                    local val = dialog:getInputText()
                                    if val and val ~= "" then
                                        self.download_dir = val
                                        self.settings:saveSetting("download_dir", val)
                                        self.settings:flush()
                                    end
                                    UIManager:close(dialog)
                                end,
                            },
                        }},
                    }
                    UIManager:show(dialog)
                    dialog:onShowKeyboard()
                end,
            },
            {
                text_func = function()
                    return T(_("Minimum free space: %1 MB"), self.min_free_space_mb)
                end,
                help_text = _("Minimum free disk space (in MB) required before downloading books. Sync will stop if available space drops below this threshold. Default: 500 MB"),
                keep_menu_open = true,
                callback = function()
                    local dialog
                    dialog = InputDialog:new{
                        title   = _("Minimum free space (MB)"),
                        input   = tostring(self.min_free_space_mb),
                        input_type = "number",
                        buttons = {{
                            {
                                text     = _("Cancel"),
                                callback = function() UIManager:close(dialog) end,
                            },
                            {
                                text     = _("Save"),
                                is_enter_default = true,
                                callback = function()
                                    local val = tonumber(dialog:getInputText())
                                    if val and val >= 0 then
                                        self.min_free_space_mb = val
                                        self.settings:saveSetting("min_free_space_mb", val)
                                        self.settings:flush()
                                        UIManager:show(InfoMessage:new{
                                            text = T(_("Minimum free space set to %1 MB"), val),
                                            timeout = 2,
                                        })
                                    end
                                    UIManager:close(dialog)
                                end,
                            },
                        }},
                    }
                    UIManager:show(dialog)
                    dialog:onShowKeyboard()
                end,
            },
        },
        hold_callback = function()
            showSectionHelp(
                _("Shelf Sync"),
                _("Configure two-way Booklore shelf sync, storage location, file naming, and cleanup behavior.")
            )
        end,
    }

    local sync_cache_menu = {
        text = _("Sync & Cache"),
        sub_item_table = {
            {
                text_func = function()
                    if not self.db then return _("Sync Pending Now") end
                    local sessions     = tonumber(self.db:getPendingSessionCount())     or 0
                    local annotations  = tonumber(self.db:getPendingAnnotationCount())  or 0
                    local ratings      = tonumber(self.db:getPendingRatingCount())      or 0
                    local bookmarks    = tonumber(self.db:getPendingBookmarkCount())    or 0
                    local progress     = tonumber(self.db:getPendingKoreaderProgressCount()) or 0
                    local total = sessions + annotations + ratings + bookmarks + progress
                    if total == 0 then
                        return _("Sync Pending Now")
                    end
                    local parts = {}
                    if sessions    > 0 then table.insert(parts, T(_("%1 S"),  sessions))    end
                    if annotations > 0 then table.insert(parts, T(_("%1 A"),  annotations)) end
                    if ratings     > 0 then table.insert(parts, T(_("%1 R"),  ratings))     end
                    if bookmarks   > 0 then table.insert(parts, T(_("%1 B"),  bookmarks))   end
                    if progress    > 0 then table.insert(parts, T(_("%1 P"),  progress))    end
                    return T(_("Sync Pending Now (%1)"), table.concat(parts, ", "))
                end,
                help_text = _("Manually upload all pending items that failed to sync previously - reading sessions, annotations (highlights and notes), ratings, bookmarks, and progress. Items are cached locally when the network is unavailable."),
                enabled_func = function()
                    if not self.db then return false end
                    local sessions     = tonumber(self.db:getPendingSessionCount())     or 0
                    local annotations  = tonumber(self.db:getPendingAnnotationCount())  or 0
                    local ratings      = tonumber(self.db:getPendingRatingCount())      or 0
                    local bookmarks    = tonumber(self.db:getPendingBookmarkCount())    or 0
                    local progress     = tonumber(self.db:getPendingKoreaderProgressCount()) or 0
                    return (sessions + annotations + ratings + bookmarks + progress) > 0
                end,
                callback = function()
                    self:_requestWifi(_("sync pending items"), function()
                        self:syncPendingSessions()
                    end, function()
                        self:showWifiUnavailableInfo(
                            _("WiFi not enabled - pending items remain queued"),
                            _("Airplane mode is enabled - pending items remain queued")
                        )
                    end, {
                        disable_wifi_when_done = true,
                    })
                end,
            },
            {
                text = _("View Pending Sessions"),
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
                    self:_requestWifi(_("resolve unmatched books"), function()
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
                    end, function()
                        self:showWifiUnavailableInfo(
                            _("WiFi not enabled - matching skipped"),
                            _("Airplane mode is enabled - matching skipped")
                        )
                    end)
                end,
            },
            {
                text_func = function()
                    if not self.db then return _("Clear Pending...") end
                    local s = tonumber(self.db:getPendingSessionCount())    or 0
                    local a = tonumber(self.db:getPendingAnnotationCount()) or 0
                    local r = tonumber(self.db:getPendingRatingCount())     or 0
                    local b = tonumber(self.db:getPendingBookmarkCount())   or 0
                    local p = tonumber(self.db:getPendingKoreaderProgressCount()) or 0
                    if (s + a + r + b + p) == 0 then return _("Clear Pending...") end
                    local parts = {}
                    if s > 0 then table.insert(parts, T(_("%1 S"), s)) end
                    if a > 0 then table.insert(parts, T(_("%1 A"), a)) end
                    if r > 0 then table.insert(parts, T(_("%1 R"), r)) end
                    if b > 0 then table.insert(parts, T(_("%1 B"), b)) end
                    if p > 0 then table.insert(parts, T(_("%1 P"), p)) end
                    return T(_("Clear Pending... (%1)"), table.concat(parts, ", "))
                end,
                help_text = _("Choose which types of pending items to delete from the local queue: sessions, annotations (highlights/notes), ratings, bookmarks, and/or progress."),
                enabled_func = function()
                    if not self.db then return false end
                    local s = tonumber(self.db:getPendingSessionCount())    or 0
                    local a = tonumber(self.db:getPendingAnnotationCount()) or 0
                    local r = tonumber(self.db:getPendingRatingCount())     or 0
                    local b = tonumber(self.db:getPendingBookmarkCount())   or 0
                    local p = tonumber(self.db:getPendingKoreaderProgressCount()) or 0
                    return (s + a + r + b + p) > 0
                end,
                callback = function()
                    self:showClearPendingDialog()
                end,
            },
            {
                text = _("Clear Cache"),
                help_text = _("Delete cached book mappings AND related synced history (synced annotations, synced bookmarks, rating sync history, and stored metadata). This broad clear is required because those tables reference book_cache via foreign keys. Cache rows still referenced by pending queues (annotations/ratings/bookmarks) are retained to preserve queued sync data. Pending queues are not affected."),
                enabled_func = function()
                    if not self.db then
                        return false
                    end
                    local stats = self.db:getBookCacheStats()
                    return stats.total > 0
                end,
                callback = function()
                    if self.db then
                        local ok = self.db:clearBookCache()
                        if ok then
                            UIManager:show(InfoMessage:new{
                                text = _("Local book cache cleared"),
                                timeout = 2,
                            })
                        else
                            UIManager:show(InfoMessage:new{
                                text = _("Failed to clear local book cache"),
                                timeout = 3,
                            })
                        end
                    end
                end,
            },
            {
                text = _("Advanced"),
                help_text = _("Advanced data management options. Use with care."),
                sub_item_table = {
                    {
                        text = _("Re-match All Books in Cache"),
                        help_text = _("Run this when you re-created the library and all IDs have changed. Resets all stored book IDs and re-resolves them from the server."),
                        callback = function()
                            self:rematchAllBooksInCache()
                        end,
                    },
                    {
                        text = _("Re-sync Stored Metadata"),
                        help_text = _("Re-fetch metadata for all cached books that already have a Booklore ID. Updates fields like server pagecount for existing cache entries."),
                        callback = function()
                            self:resyncStoredMetadata()
                        end,
                    },
                    {
                        text_func = function()
                            if not self.db then return _("Clear...") end
                            local hs = tonumber(self.db:getHistoricalSessionCount())  or 0
                            local sa = tonumber(self.db:getSyncedAnnotationCount())   or 0
                            local sb = tonumber(self.db:getSyncedBookmarkCount())     or 0
                            local rh = tonumber(self.db:getRatingSyncHistoryCount())  or 0
                            local sp = tonumber(self.db:getSyncedKoreaderProgressCount()) or 0
                            if (hs + sa + sb + rh + sp) == 0 then return _("Clear...") end
                            return T(_("Clear... (%1)"), hs + sa + sb + rh + sp)
                        end,
                        help_text = _("Clear historical sessions, synced annotation records, synced bookmark records, synced progress records, and/or rating sync history."),
                        callback = function()
                            self:showClearAdvancedDialog()
                        end,
                    },
                },
            },
        },
        hold_callback = function()
            showSectionHelp(
                _("Sync & Cache"),
                _("Sync pending items now, inspect queue/cache, match unmatched books, and clear local data.")
            )
        end,
    }

    table.insert(base_menu, what_to_sync_menu)
    table.insert(base_menu, sync_behavior_menu)
    table.insert(base_menu, sync_cache_menu)
    table.insert(base_menu, shelf_sync_menu)

    local import_matching_items = {
        {
            text = _("Extract Historical Data"),
            help_text = _("One-time extraction of reading sessions from KOReader's statistics database. This reads page statistics and groups them into sessions. Run this first before matching."),
            enabled_func = function()
                return self.is_enabled
            end,
            callback = function()
                self:copySessionsFromKOReader()
            end,
        },
        {
            text = _("Match Historical Sessions"),
            help_text = _("Match extracted sessions with books on Booklore server. For each unmatched book, searches by title and lets you select the correct match. Matched sessions are automatically synced."),
            enabled_func = function()
                return self.server_url ~= "" and self.booklore_username ~= "" and self.booklore_password ~= "" and self.is_enabled
            end,
            callback = function()
                self:_requestWifi(_("match historical sessions"), function()
                    self:matchHistoricalData()
                end, function()
                    self:showWifiUnavailableInfo(
                        _("WiFi not enabled - historical matching skipped"),
                        _("Airplane mode is enabled - historical matching skipped")
                    )
                end)
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
                self:_requestWifi(_("re-sync all historical sessions"), function()
                    self:resyncHistoricalData()
                end, function()
                    self:showWifiUnavailableInfo(
                        _("WiFi not enabled - historical re-sync skipped"),
                        _("Airplane mode is enabled - historical re-sync skipped")
                    )
                end, {
                    disable_wifi_when_done = true,
                })
            end,
        },
        {
            text = _("Sync Re-matched Sessions"),
            help_text = _("Sync sessions that were previously marked for re-matching (404 errors) and have now been matched to valid books."),
            enabled_func = function()
                return self.server_url ~= "" and self.booklore_username ~= "" and self.booklore_password ~= "" and self.is_enabled
            end,
            callback = function()
                self:_requestWifi(_("sync re-matched sessions"), function()
                    self:syncRematchedSessions()
                end, function()
                    self:showWifiUnavailableInfo(
                        _("WiFi not enabled - re-matched sync skipped"),
                        _("Airplane mode is enabled - re-matched sync skipped")
                    )
                end, {
                    disable_wifi_when_done = true,
                })
            end,
        },
        {
            text = _("Manual Matching"),
            help_text = _("Manually search for and match a book to a Booklore entry."),
            callback = function()
                self:_requestWifi(_("manual matching"), function()
                    self:manualMatching()
                end, function()
                    self:showWifiUnavailableInfo(
                        _("WiFi not enabled - manual matching skipped"),
                        _("Airplane mode is enabled - manual matching skipped")
                    )
                end)
            end,
        },
    }

    local hardcover_menu = {
        text = _("Hardcover"),
        help_text = _("Configure Hardcover.app integration and sync book metadata."),
        sub_item_table = {
            {
                text = _("Configure Hardcover Account"),
                help_text = _("Load your Hardcover API token from the hardcover.token file in the plugin folder. Create the file and paste your token into it (get it from hardcover.app → Profile → API), then tap here to load it."),
                keep_menu_open = true,
                callback = function()
                    Settings:configureHardcoverToken(self)
                end,
            },
            {
                text = _("Fetch Hardcover Book IDs"),
                help_text = _("Fetch metadata from the Booklore server for every matched book and store any Hardcover book IDs returned. For books without a Hardcover ID in Booklore, searches Hardcover by ISBN or title and lets you select the correct match."),
                keep_menu_open = true,
                callback = function()
                    self:fetchAndStoreHardcoverIds()
                end,
            },
        },
    }

    local airplanemode_menu = {
        text = _("Airplanemode plugin"),
        help_text = _("Integrate Booklore sync mode with KOReader's Airplanemode plugin."),
        sub_item_table = {
            {
                text = _("Switch sync mode based on airplane status"),
                help_text = _("When entering file manager: if airplane mode is ON, set sync mode to Manual; if OFF, set sync mode to Automatic."),
                checked_func = function()
                    return self.airplanemode_sync_mode_enabled
                end,
                enabled_func = function()
                    return self:isAirplaneModePluginInstalled()
                end,
                callback = function()
                    if not self:isAirplaneModePluginInstalled() then
                        self:showAirplaneModePluginMissingWarning()
                        return
                    end

                    self.airplanemode_sync_mode_enabled = not self.airplanemode_sync_mode_enabled
                    self.settings:saveSetting("airplanemode_sync_mode_enabled", self.airplanemode_sync_mode_enabled)
                    self.settings:flush()

                    if self.airplanemode_sync_mode_enabled then
                        UIManager:show(InfoMessage:new{
                            text = _("Airplanemode integration enabled. This overrides Sync Mode based on airplane status."),
                            timeout = 3,
                        })
                        self:applyAirplaneModeSyncModeIntegration()
                    end
                end,
                keep_menu_open = true,
            },
            {
                text = _("Airplanemode plugin not installed"),
                enabled_func = function()
                    return not self:isAirplaneModePluginInstalled()
                end,
                callback = function()
                    self:showAirplaneModePluginMissingWarning()
                end,
                keep_menu_open = true,
            },
        },
    }

    local import_matching_menu = {
        text = _("Import & Matching"),
        sub_item_table = import_matching_items,
        hold_callback = function()
            showSectionHelp(
                _("Import & Matching"),
                _("Import historical KOReader sessions and match them to Booklore books for upload.")
            )
        end,
    }

    local integrations_menu = {
        text = _("Integrations"),
        sub_item_table = {
            hardcover_menu,
            airplanemode_menu,
        },
        hold_callback = function()
            showSectionHelp(
                _("Integrations"),
                _("Configure external integrations, including Hardcover and Airplanemode plugin integration.")
            )
        end,
    }

    local appearance_diagnostics_menu = Settings:buildPreferencesMenu(self)
    appearance_diagnostics_menu.hold_callback = function()
        showSectionHelp(
            _("Appearance & Diagnostics"),
            _("Configure silent mode, log-to-file diagnostics, settings export, and plugin naming.")
        )
    end

    table.insert(base_menu, import_matching_menu)
    table.insert(base_menu, integrations_menu)
    table.insert(base_menu, appearance_diagnostics_menu)

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
        hold_callback = function()
            showSectionHelp(
                _("About & Updates"),
                _("View plugin version details and manage update checks, channels, and update cache.")
            )
        end,
    })

    if self:hasDevBuildLocationFile() then
        local about_updates_menu = base_menu[#base_menu]
        table.insert(about_updates_menu.sub_item_table, 4, {
            text = _("Use Dev Builds"),
            help_text = _("Install development builds from dev-build.location in the plugin folder."),
            checked_func = function()
                return self.use_dev_builds
            end,
            callback = function()
                self:toggleUseDevBuilds()
            end,
        })
    end

    menu_items.booklore_sync = {
        text = _("Booklore Sync"),
        sorting_hint = "tools",
        sub_item_table = base_menu,
    }
end

---BookloreSync:configureBookloreLogin.
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

---BookloreSync:testConnection.
function BookloreSync:testConnection()
    UIManager:show(InfoMessage:new{
        text = _("Testing connection..."),
        timeout = 1,
    })

    -- Keep runtime URL selection in sync with current network state
    -- before running auth checks and showing test details.
    self:refreshEffectiveServerUrl()
    
    if not self.server_url or self.server_url == "" then
        UIManager:show(InfoMessage:new{
            text = _("Error: Server URL not configured"),
            timeout = 3,
        })
        return
    end
    
    -- Test KOReader user authentication
    local koreader_success = false
    local koreader_message = ""
    
    if self.username and self.username ~= "" and self.password and self.password ~= "" then
        self.api:init(self.server_url, self.username, self.password, self.db)
        koreader_success, koreader_message = self.api:testAuth()
    else
        koreader_message = _("KOReader credentials not configured")
    end
    
    -- Test Booklore user authentication
    local booklore_success = false
    local booklore_message = ""
    local booklore_token = nil
    
    if self.booklore_username and self.booklore_username ~= "" and 
       self.booklore_password and self.booklore_password ~= "" then
        booklore_success, booklore_token = self.api:loginBooklore(self.booklore_username, self.booklore_password)
        
        if booklore_success and booklore_token then
            -- Store the bearer token
            if self.db then
                self.db:saveBearerToken(self.booklore_username, booklore_token)
            end
            booklore_message = _("Booklore login successful")
        else
            booklore_message = booklore_token or _("Booklore login failed")
        end
    else
        booklore_message = _("Booklore credentials not configured")
    end
    
    -- Test by-hash endpoint compatibility (critical for plugin operation)
    local hash_endpoint_ok = false
    local hash_endpoint_message = ""

    if koreader_success or booklore_success then
        -- Only probe if at least one auth check passed so the server is reachable
        hash_endpoint_ok, hash_endpoint_message = self.api:testByHashEndpoint()
    else
        hash_endpoint_message = _("Skipped (no successful auth)")
    end

    -- Build result message
    local connection_type = _("Not configured")
    local local_url = self.local_server_url or ""
    local remote_url = self.remote_server_url or ""
    local prefer_remote = self.auto_network_switch_enabled and not self:isOnConfiguredHomeNetwork()

    if prefer_remote then
        if remote_url ~= "" then
            connection_type = _("Remote")
        elseif local_url ~= "" then
            connection_type = _("Local (fallback)")
        end
    else
        if local_url ~= "" then
            connection_type = _("Local")
        elseif remote_url ~= "" then
            connection_type = _("Remote (fallback)")
        end
    end

    local result_parts = {}
    table.insert(result_parts, T(_("Connection type: %1"), connection_type))
    
    if koreader_success then
        table.insert(result_parts, T(_("✓ KOReader: %1"), _("Success")))
    else
        table.insert(result_parts, T(_("✗ KOReader: %1"), koreader_message))
    end
    
    if booklore_success then
        table.insert(result_parts, T(_("✓ Booklore: %1"), _("Success")))
    else
        table.insert(result_parts, T(_("✗ Booklore: %1"), booklore_message))
    end

    if hash_endpoint_ok then
        table.insert(result_parts, T(_("✓ by-hash endpoint: %1"), _("OK")))
    else
        table.insert(result_parts, T(_("✗ by-hash endpoint: %1"), hash_endpoint_message))
    end
    
    local overall_success = koreader_success or booklore_success
    local result_text = table.concat(result_parts, "\n")

    if not hash_endpoint_ok and (koreader_success or booklore_success) then
        result_text = result_text .. "\n\n" .. _("Warning: the by-hash endpoint is unavailable. Book matching will not work. Please update your Booklore server.")
    end
    
    UIManager:show(InfoMessage:new{
        text = result_text,
        timeout = (overall_success and hash_endpoint_ok) and 4 or 6,
    })
end

--[[--
Format duration in seconds to a human-readable string

@param duration_seconds Number of seconds
@return string Formatted duration (e.g., "1h 5m 9s", "45m 30s", "15s")
--]]
---BookloreSync:formatDuration.
function BookloreSync:formatDuration(duration_seconds)
    duration_seconds = tonumber(duration_seconds)
    
    if not duration_seconds or duration_seconds < 0 then
        return _("0s")
    end
    
    local hours = math.floor(duration_seconds / 3600)
    local minutes = math.floor((duration_seconds % 3600) / 60)
    local seconds = duration_seconds % 60
    
    local parts = {}
    
    if hours > 0 then
        table.insert(parts, T(_("%1h"), hours))
    end
    
    if minutes > 0 then
        table.insert(parts, T(_("%1m"), minutes))
    end
    
    if seconds > 0 or #parts == 0 then
        table.insert(parts, T(_("%1s"), seconds))
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
---BookloreSync:validateSession.
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
---BookloreSync:roundProgress.
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
---BookloreSync:getCurrentProgress.
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
Round KOReader sync percentage ratio to 4 decimals.

@param value number 0..1
@return number rounded ratio
--]]
---BookloreSync:roundKoreaderSyncPercentage.
function BookloreSync:roundKoreaderSyncPercentage(value)
    return ProgressSyncModule.roundKoreaderSyncPercentage(self, value)
end

--[[--
Round a numeric value to the nearest integer.

@param value any
@return number|nil
--]]
---BookloreSync:roundToInt.
function BookloreSync:roundToInt(value)
    return ProgressSyncModule.roundToInt(self, value)
end

--[[--
Normalize a KOReader location page to the server page space.

@param location any
@param koreader_pagecount number|nil
@param server_pagecount number|nil
@return string normalized_location
--]]
---BookloreSync:normalizeSessionLocationForServer.
function BookloreSync:normalizeSessionLocationForServer(location, koreader_pagecount, server_pagecount)
    local location_num = tonumber(location)
    local k_count = tonumber(koreader_pagecount)
    local s_count = tonumber(server_pagecount)

    if not location_num then
        return tostring(location or "0")
    end

    if not k_count or k_count <= 0 or not s_count or s_count <= 0 then
        return tostring(location)
    end

    local scaled = location_num * (s_count / k_count)
    local normalized = self:roundToInt(scaled) or location_num
    if normalized < 1 then normalized = 1 end
    if normalized > s_count then normalized = s_count end
    return tostring(normalized)
end

---BookloreSync:normalizeSessionLocationFromProgress.
function BookloreSync:normalizeSessionLocationFromProgress(progress_percent, server_pagecount, fallback_location)
    local s_count = tonumber(server_pagecount)
    local progress = tonumber(progress_percent)
    if not s_count or s_count <= 0 or not progress then
        return tostring(fallback_location or "0")
    end

    local ratio = progress / 100
    if ratio < 0 then ratio = 0 end
    if ratio > 1 then ratio = 1 end

    local normalized = self:roundToInt(ratio * s_count) or 1
    if normalized < 1 then normalized = 1 end
    if normalized > s_count then normalized = s_count end
    return tostring(normalized)
end

---BookloreSync:normalizeSessionLocationWithFallback.
function BookloreSync:normalizeSessionLocationWithFallback(location, koreader_pagecount, server_pagecount, progress_percent)
    local k_count = tonumber(koreader_pagecount)
    local s_count = tonumber(server_pagecount)
    if k_count and k_count > 0 and s_count and s_count > 0 then
        return self:normalizeSessionLocationForServer(location, k_count, s_count)
    end

    return self:normalizeSessionLocationFromProgress(progress_percent, s_count, location)
end

--[[--
Resolve server pagecount for a pending session.

@param session table
@return number|nil
--]]
---BookloreSync:getServerPagecountForSession.
function BookloreSync:getServerPagecountForSession(session)
    if not self.db or type(session) ~= "table" then
        return nil
    end

    local session_book = nil
    local book_hash = session.bookHash or session.book_hash
    if book_hash and book_hash ~= "" then
        session_book = self.db:getBookByHash(book_hash)
    end
    local book_id = session.bookId or session.book_id
    if not session_book and book_id then
        session_book = self.db:getBookByBookId(book_id)
    end

    local server_pagecount = session_book and tonumber(session_book.server_pagecount) or nil
    if server_pagecount and server_pagecount > 0 then
        return math.floor(server_pagecount + 0.5)
    end
    return nil
end

--[[--
Get KOReader sync progress payload fields.

Uses KOReader's own progress primitives (paging/rolling getLastProgress and
getLastPercent) so `progress` is the canonical spline/xpointer for reflowable
documents, while `percentage` is a 0..1 ratio rounded to four decimals.

@return number percentage_ratio (0..1, rounded to 4 decimals)
@return string progress_value (page/xpointer as expected by KOReader sync API)
@return string location_value (legacy mirror kept for local DB compatibility)
--]]
---BookloreSync:getCurrentKoreaderSyncProgress.
function BookloreSync:getCurrentKoreaderSyncProgress()
    return ProgressSyncModule.getCurrentKoreaderSyncProgress(self)
end

--[[--
Get the current document hash for KOReader progress sync.

Uses current_session hash when available, then DB cache, then computes hash.

@return string|nil
--]]
---BookloreSync:getCurrentDocumentHashForProgress.
function BookloreSync:getCurrentDocumentHashForProgress()
    return ProgressSyncModule.getCurrentDocumentHashForProgress(self)
end

--[[--
Build a KOReader progress payload for the currently open document.

@param timestamp number|nil unix timestamp; defaults to os.time()
@return table|nil payload
@return string|nil error_message
--]]
---BookloreSync:buildCurrentKoreaderProgressPayload.
function BookloreSync:buildCurrentKoreaderProgressPayload(timestamp)
    return ProgressSyncModule.buildCurrentKoreaderProgressPayload(self, timestamp)
end

--[[--
Push KOReader progress directly to Booklore without queueing.

On success, this also updates synced_koreader_progress locally.

@param payload table
@return boolean ok
@return string|table|nil reason
--]]
---BookloreSync:pushCurrentKoreaderProgressDirect.
function BookloreSync:pushCurrentKoreaderProgressDirect(payload)
    return ProgressSyncModule.pushCurrentKoreaderProgressDirect(self, payload)
end

---BookloreSync:requestFastTrackProgressPush.
function BookloreSync:requestFastTrackProgressPush(payload)
    if self.progress_sync_fasttrack_in_flight then
        self:logDbg("BookloreSync: Fast-track progress push skipped - in flight")
        return false
    end

    self.progress_sync_fasttrack_in_flight = true
    UIManager:scheduleIn(0, function()
        local ok, err = pcall(function()
            local done = self:pushCurrentKoreaderProgressFastTrack(payload)
            if done then
                self.progress_sync_last_push_ts = os.time()
            end
        end)
        if not ok then
            self:logWarn("BookloreSync: Fast-track progress push background task failed:", tostring(err))
        end
        self.progress_sync_fasttrack_in_flight = false
    end)

    return true
end

---BookloreSync:scheduleBackgroundProgressFlush.
function BookloreSync:scheduleBackgroundProgressFlush(reason)
    if self.progress_sync_background_flush_scheduled then
        self:logDbg("BookloreSync: Progress background flush already scheduled, reason:", tostring(reason or "unknown"))
        return false
    end

    self.progress_sync_background_flush_scheduled = true
    local interval = tonumber(self.progress_sync_background_interval_seconds) or 2
    if interval < 1 then interval = 1 end

    self:logInfo("BookloreSync: Scheduling background progress flush in", tostring(interval), "s; reason:", tostring(reason or "unknown"))
    UIManager:scheduleIn(interval, function()
        self.progress_sync_background_flush_scheduled = false
        self:runBackgroundProgressFlush(reason)
    end)
    return true
end

---BookloreSync:runBackgroundProgressFlush.
function BookloreSync:runBackgroundProgressFlush(reason)
    if self.progress_sync_background_flush_running then
        self:logDbg("BookloreSync: Background progress flush skipped - already running")
        return false
    end
    if not self.progress_sync_enabled or self.manual_sync_only then
        return false
    end
    if not self:isNetworkConnected() then
        self:logDbg("BookloreSync: Background progress flush skipped - offline")
        return false
    end

    local now = os.time()
    local idle_for = now - (tonumber(self.progress_sync_last_page_turn_timestamp) or now)
    local idle_needed = tonumber(self.progress_sync_background_idle_seconds) or 2
    if idle_for < idle_needed then
        self:logDbg("BookloreSync: Background progress flush deferred - reader active (idle", tostring(idle_for), "s)")
        self:scheduleBackgroundProgressFlush("reader_active")
        return false
    end

    self.progress_sync_background_flush_running = true
    UIManager:scheduleIn(0, function()
        local ok, synced, failed = pcall(function()
            return self:syncPendingKoreaderProgress(true, 1)
        end)

        if ok then
            self:logInfo("BookloreSync: Background progress flush done; reason=", tostring(reason or "unknown"), "synced=", tostring(synced or 0), "failed=", tostring(failed or 0))
            if (tonumber(synced) or 0) > 0 then
                self.progress_sync_last_push_ts = os.time()
            end
            if self.db and (self.db:getPendingKoreaderProgressCount() or 0) > 0 then
                self:scheduleBackgroundProgressFlush("pending_remaining")
            end
        else
            self:logWarn("BookloreSync: Background progress flush crashed:", tostring(synced))
        end

        self.progress_sync_background_flush_running = false
    end)

    return true
end

--[[--
Push current KOReader progress immediately (no full pending sync pipeline).

Used by periodic page-turn updates to avoid running unrelated sync phases
(sessions/ratings/annotations/bookmarks) on every interval.

Falls back to queueing when direct push cannot be performed.

@return boolean delivered_or_queued
--]]
---BookloreSync:pushCurrentKoreaderProgressFastTrack.
function BookloreSync:pushCurrentKoreaderProgressFastTrack(payload)
    local payload_err = nil
    if not payload then
        payload, payload_err = self:buildCurrentKoreaderProgressPayload(os.time())
    end
    if not payload then
        self:logWarn("BookloreSync: Fast-track progress payload build failed:", tostring(payload_err or "unknown"))
        return false
    end

    local ok, reason = self:pushCurrentKoreaderProgressDirect(payload)
    if ok then
        self:logInfo("BookloreSync: Fast-track progress push succeeded for hash:", tostring(payload.document))
        return true
    end

    self:logWarn("BookloreSync: Fast-track progress push failed, queueing instead:", tostring(reason or "unknown"))
    return self:queueCurrentKoreaderProgress()
end

--[[--
Build KOReader progress payload from an explicit page number.

This avoids relying on getLastProgress()/getLastPercent() during rapid page
turns, which can lag on some devices and only update after turning stops.

@param page number|string current page from page-update event
@param timestamp number|nil unix timestamp
@return table|nil payload
@return string|nil error_message
--]]
---BookloreSync:buildKoreaderProgressPayloadForPage.
function BookloreSync:buildKoreaderProgressPayloadForPage(page, timestamp)
    if not self.progress_sync_enabled then
        return nil, "Progress sync disabled"
    end

    local file_path = self.ui and self.ui.document and self.ui.document.file or nil
    if not file_path then
        return nil, "No open document"
    end

    local page_num = tonumber(page)
    if not page_num or page_num < 1 then
        return nil, "Invalid page"
    end

    local total_pages = self.ui and self.ui.document and self.ui.document.getPageCount and tonumber(self.ui.document:getPageCount()) or nil
    if not total_pages or total_pages <= 0 then
        return nil, "Invalid page count"
    end

    local book_hash = self:getCurrentDocumentHashForProgress()
    if not book_hash then
        return nil, "Book hash unavailable"
    end

    if page_num > total_pages then
        page_num = total_pages
    end

    local percentage_ratio = self:roundKoreaderSyncPercentage(page_num / total_pages)
    local progress_value = tostring(page_num)
    local ts = tonumber(timestamp) or os.time()
    local device_name = Device and Device.model or "KOReader"
    local device_id = tostring(self.progress_sync_device_id or "unknown")
    local book_cache_id = self.db and self.db:getBookCacheIdByFilePath(file_path) or nil

    return {
        timestamp = ts,
        document = tostring(book_hash),
        percentage = percentage_ratio,
        progress = progress_value,
        device = device_name,
        device_id = device_id,
        book_hash = tostring(book_hash),
        book_cache_id = book_cache_id,
        location = progress_value,
    }, nil
end

--[[--
Queue local KOReader progress into pending_koreader_progress.

@return boolean queued
--]]
---BookloreSync:queueCurrentKoreaderProgress.
function BookloreSync:queueCurrentKoreaderProgress()
    if not self.progress_sync_enabled then
        return false
    end
    if not self.db then
        self:logWarn("BookloreSync: queueCurrentKoreaderProgress skipped - database not initialized")
        return false
    end

    local file_path = self.ui and self.ui.document and self.ui.document.file or nil
    if not file_path then
        return false
    end

    local book_hash = self:getCurrentDocumentHashForProgress()
    if not book_hash then
        self:logWarn("BookloreSync: queueCurrentKoreaderProgress skipped - no book hash")
        return false
    end

    local percentage_ratio, progress_value, location = self:getCurrentKoreaderSyncProgress()
    local timestamp = os.time()

    local book_cache_id = self.db:getBookCacheIdByFilePath(file_path)

    local payload = {
        book_cache_id = book_cache_id,
        book_hash = book_hash,
        progress = tostring(progress_value or "0"),
        percentage = percentage_ratio,
        location = tostring(location or "0"),
        device = Device and Device.model or "KOReader",
        device_id = self.progress_sync_device_id,
        timestamp = timestamp,
    }

    local ok = self.db:addPendingKoreaderProgress(payload)
    if ok then
        self:logInfo("BookloreSync: Queued KOReader progress for hash:", book_hash, "percentage:", percentage_ratio)
    else
        self:logWarn("BookloreSync: Failed to queue KOReader progress for hash:", book_hash)
    end
    return ok
end

---BookloreSync:queueKoreaderProgressPayload.
function BookloreSync:queueKoreaderProgressPayload(payload)
    if not self.progress_sync_enabled then
        return false
    end
    if not self.db or type(payload) ~= "table" then
        return false
    end

    local queued = self.db:addPendingKoreaderProgress({
        book_cache_id = payload.book_cache_id,
        book_hash = tostring(payload.book_hash or payload.document or ""),
        progress = tostring(payload.progress or payload.location or "0"),
        percentage = tonumber(payload.percentage) or 0,
        location = tostring(payload.location or payload.progress or "0"),
        device = tostring(payload.device or (Device and Device.model) or "KOReader"),
        device_id = tostring(payload.device_id or self.progress_sync_device_id or "unknown"),
        timestamp = tonumber(payload.timestamp) or os.time(),
    })

    if queued then
        self:logInfo("BookloreSync: Queued periodic progress for background flush; hash:", tostring(payload.book_hash or payload.document), "percentage:", tostring(payload.percentage))
    end
    return queued
end

--[[--
Queue a forced "read" progress state (100%) for the current book.

Used by rating workflows when "set book to read on rating" is enabled.

@param file_path string|nil
@param book_hash string|nil
@return boolean queued
--]]
---BookloreSync:queueReadProgressOnRating.
function BookloreSync:queueReadProgressOnRating(file_path, book_hash)
    if not self.progress_sync_enabled or not self.progress_sync_set_read_on_rating then
        return false
    end
    if not self.db then
        return false
    end

    local path = file_path or (self.ui and self.ui.document and self.ui.document.file) or nil
    local hash = book_hash or self:getCurrentDocumentHashForProgress()
    if not hash then
        return false
    end

    local book_cache_id = path and self.db:getBookCacheIdByFilePath(path) or nil
    local payload = {
        book_cache_id = book_cache_id,
        book_hash = hash,
        progress = "100",
        percentage = 1,
        location = "100",
        device = Device and Device.model or "KOReader",
        device_id = self.progress_sync_device_id,
        timestamp = os.time(),
    }

    local ok = self.db:addPendingKoreaderProgress(payload)
    if ok then
        self:logInfo("BookloreSync: Queued forced read progress (100%) on rating for hash:", hash)
    end
    return ok
end

---BookloreSync:getProgressStrategyName.
function BookloreSync:getProgressStrategyName(strategy)
    if strategy == PROGRESS_SYNC_STRATEGY.SILENT then
        return _("Silently")
    elseif strategy == PROGRESS_SYNC_STRATEGY.PROMPT then
        return _("Prompt")
    end
    return _("Disable")
end

---BookloreSync:setProgressSyncForwardStrategy.
function BookloreSync:setProgressSyncForwardStrategy(strategy)
    self.progress_sync_forward_strategy = strategy
    self.settings:saveSetting("progress_sync_forward_strategy", strategy)
    self.settings:flush()
end

---BookloreSync:setProgressSyncBackwardStrategy.
function BookloreSync:setProgressSyncBackwardStrategy(strategy)
    self.progress_sync_backward_strategy = strategy
    self.settings:saveSetting("progress_sync_backward_strategy", strategy)
    self.settings:flush()
end

---BookloreSync:getLocalKoreaderProgressState.
function BookloreSync:getLocalKoreaderProgressState()
    local pct_ratio, progress_value = self:getCurrentKoreaderSyncProgress()
    return {
        percentage = tonumber(pct_ratio) or 0,
        progress = tostring(progress_value or "0"),
        timestamp = tonumber(self.progress_sync_last_page_turn_timestamp) or 0,
    }
end

---BookloreSync:evaluateKoreaderProgressDirection.
function BookloreSync:evaluateKoreaderProgressDirection(remote, local_state)
    local remote_ts = tonumber(remote and remote.timestamp) or 0
    local local_ts = tonumber(local_state and local_state.timestamp) or 0
    local remote_pct = tonumber(remote and remote.percentage) or 0
    local local_pct = tonumber(local_state and local_state.percentage) or 0
    local remote_progress = tostring(remote and (remote.progress or remote.location) or "")
    local local_progress = tostring(local_state and local_state.progress or "")

    if remote_progress ~= "" and remote_progress == local_progress then
        return "equal"
    end

    -- Prefer progress magnitude first so server catch-up is not blocked by
    -- local open-time timestamps.
    if remote_pct > local_pct then
        return "forward"
    end

    if remote_pct < local_pct then
        if remote_ts > 0 and local_ts > 0 then
            if remote_ts < local_ts then
                return "backward"
            end
            return "forward"
        end
        return "backward"
    end

    if remote_ts > 0 and local_ts > 0 then
        if remote_ts > local_ts then return "forward" end
        if remote_ts < local_ts then return "backward" end
        return "equal"
    end

    return "equal"
end

---BookloreSync:shouldApplyRemoteKoreaderProgress.
function BookloreSync:shouldApplyRemoteKoreaderProgress(remote, local_state)
    local direction = self:evaluateKoreaderProgressDirection(remote, local_state)
    local strategy = nil
    if direction == "forward" then
        strategy = self.progress_sync_forward_strategy or PROGRESS_SYNC_STRATEGY.PROMPT
    elseif direction == "backward" then
        strategy = self.progress_sync_backward_strategy or PROGRESS_SYNC_STRATEGY.DISABLE
    else
        strategy = PROGRESS_SYNC_STRATEGY.DISABLE
    end
    return direction, strategy
end

---BookloreSync:confirmApplyRemoteKoreaderProgress.
function BookloreSync:confirmApplyRemoteKoreaderProgress(remote, direction, on_accept)
    if type(on_accept) ~= "function" then
        return false
    end

    local percent = string.format("%.1f", (tonumber(remote.percentage) or 0) * 100)
    local device_name = tostring(remote.device or _("Unknown device"))
    local prompt
    if direction == "forward" then
        prompt = T(_("Sync to latest location %1% from device '%2'?"), percent, device_name)
    else
        prompt = T(_("Sync to previous location %1% from device '%2'?"), percent, device_name)
    end

    UIManager:show(ConfirmBox:new{
        text = prompt,
        ok_callback = function()
            on_accept()
        end,
    })
    return true
end

---BookloreSync:fetchRemoteKoreaderProgress.
function BookloreSync:fetchRemoteKoreaderProgress(book_hash, interactive)
    local ok, body = self.api:getKoReaderProgress(book_hash)
    if not ok then
        if interactive then
            UIManager:show(InfoMessage:new{
                text = T(_("Failed to pull progress: %1"), tostring(body or "unknown error")),
                timeout = 2,
            })
        end
        return false, nil
    end
    if not body then
        if interactive then
            UIManager:show(InfoMessage:new{
                text = _("No remote progress found"),
                timeout = 2,
            })
        end
        return true, nil
    end
    return true, body
end

---BookloreSync:storeRemoteKoreaderSyncState.
function BookloreSync:storeRemoteKoreaderSyncState(book_hash, remote)
    local file_path = self.ui and self.ui.document and self.ui.document.file or nil
    local bcid = file_path and self.db and self.db:getBookCacheIdByFilePath(file_path) or nil
    self.db:markKoreaderProgressSynced({
        book_cache_id = bcid,
        book_hash = book_hash,
        progress = tostring(remote.progress or remote.location or "0"),
        percentage = tonumber(remote.percentage) or 0,
        location = tostring(remote.location or remote.progress or "0"),
        remote_device = remote.device,
        remote_device_id = remote.device_id,
        remote_timestamp = (tonumber(remote.timestamp) or 0) > 0 and tonumber(remote.timestamp) or nil,
    })
end

--[[--
Apply remote KOReader progress to current document.

@param remote table response payload from /api/koreader/syncs/progress/:hash
@return boolean applied
--]]
---BookloreSync:applyRemoteKoreaderProgress.
function BookloreSync:applyRemoteKoreaderProgress(remote)
    if type(remote) ~= "table" then return false end

    local target = remote.progress or remote.location
    if not target then
        return false
    end

    local page_num = tonumber(target)
    if page_num then
        self.progress_sync_ignore_next_page_event = true
        self.ui:handleEvent(Event:new("GotoPage", page_num))
        self:logInfo("BookloreSync: Applied remote KOReader progress page:", page_num)
        return true
    end

    if not (self.ui and self.ui.document and self.ui.document.info and self.ui.document.info.has_pages) then
        self.progress_sync_ignore_next_page_event = true
        self.ui:handleEvent(Event:new("GotoXPointer", tostring(target)))
        self:logInfo("BookloreSync: Applied remote KOReader progress xpointer")
        return true
    end

    return false
end

--[[--
Pull remote KOReader progress and optionally apply if newer.

@param interactive boolean
@return boolean handled
--]]
---BookloreSync:pullKoreaderProgress.
function BookloreSync:pullKoreaderProgress(interactive)
    interactive = interactive or false

    if not self.progress_sync_enabled then
        return false
    end
    if not self.username or self.username == "" or not self.password or self.password == "" then
        return false
    end

    local book_hash = self:getCurrentDocumentHashForProgress()
    if not book_hash then
        return false
    end

    if not self:isNetworkConnected() then
        self:logInfo("BookloreSync: pullKoreaderProgress skipped - WiFi not connected")
        return false
    end

    local ok, body = self:fetchRemoteKoreaderProgress(book_hash, interactive)
    if not ok or not body then
        return false
    end

    if body.device_id and self.progress_sync_device_id and body.device_id == self.progress_sync_device_id then
        if interactive then
            UIManager:show(InfoMessage:new{
                text = _("Latest progress is coming from this device."),
                timeout = 2,
            })
        end
        return false
    end

    local remote_percentage = tonumber(body.percentage) or 0
    if remote_percentage <= 0 then
        self:logInfo("BookloreSync: pullKoreaderProgress skipped - remote progress is 0%")
        if interactive then
            UIManager:show(InfoMessage:new{
                text = _("Remote progress is at 0%; keeping current location."),
                timeout = 2,
            })
        end
        return false
    end

    local local_state = self:getLocalKoreaderProgressState()
    local direction, strategy = self:shouldApplyRemoteKoreaderProgress(body, local_state)
    if direction == "equal" or strategy == PROGRESS_SYNC_STRATEGY.DISABLE then
        if interactive then
            UIManager:show(InfoMessage:new{
                text = _("The progress has already been synchronized."),
                timeout = 2,
            })
        end
        return false
    end

    ---do_apply.
    local function do_apply()
        local applied = self:applyRemoteKoreaderProgress(body)
        if applied then
            self:storeRemoteKoreaderSyncState(book_hash, body)
        end
        return applied
    end

    if interactive then
        do_apply()
        return true
    end

    if strategy == PROGRESS_SYNC_STRATEGY.SILENT then
        return do_apply()
    end

    if strategy == PROGRESS_SYNC_STRATEGY.PROMPT then
        return self:confirmApplyRemoteKoreaderProgress(body, direction, do_apply)
    end

    return false
end

--[[--
Get book type from file extension

@param file_path Path to the book file
@return string Book type (EPUB, PDF, etc.)
--]]
---BookloreSync:getBookType.
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
---BookloreSync:calculateBookHash.
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
---BookloreSync:getBookIdByHash.
function BookloreSync:getBookIdByHash(book_hash)
    if not book_hash then
        self:logWarn("BookloreSync: No book hash provided to getBookIdByHash")
        return nil, nil, nil
    end
    
    self:logInfo("BookloreSync: Looking up book ID for hash:", book_hash)
    
    local cached_book = self.db:getBookByHash(book_hash)
    if cached_book and cached_book.book_id then
        if cached_book.server_pagecount and tonumber(cached_book.server_pagecount) and tonumber(cached_book.server_pagecount) > 0 then
            self:logInfo("BookloreSync: Found book ID in database cache:", cached_book.book_id)
            return cached_book.book_id, cached_book.isbn10, cached_book.isbn13, cached_book.server_pagecount
        end
        self:logInfo("BookloreSync: Cached book has no server pagecount, refreshing from server")
    end
    
    self:logInfo("BookloreSync: Book ID not in cache, querying server")
    
    local success, book_data = self.api:getBookByHash(book_hash)
    
    if not success then
        self:logWarn("BookloreSync: Failed to get book from server (offline or error)")
        return nil, nil, nil, nil
    end
    
    if not book_data or not book_data.id then
        self:logInfo("BookloreSync: Book not found on server")
        return nil, nil, nil, nil
    end
    
    local book_id = tonumber(book_data.id)
    if not book_id then
        self:logWarn("BookloreSync: Invalid book ID from server:", book_data.id)
        return nil, nil, nil, nil
    end

    local isbn10 = book_data.isbn10 or nil
    local isbn13 = book_data.isbn13 or nil
    local server_pagecount = tonumber(book_data.pagecount)
    if server_pagecount and server_pagecount > 0 then
        server_pagecount = math.floor(server_pagecount + 0.5)
    else
        server_pagecount = nil
    end
    
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
            isbn13,
            server_pagecount
        )
        self:logInfo("BookloreSync: Updated database cache with book ID and ISBN")
    end

    return book_id, isbn10, isbn13, server_pagecount
end

--[[--
Extract ISBN from KOReader doc settings for a given file.

Checks the "identifiers" setting (a string that may contain multiple
identifiers, e.g. "isbn:9781423137139,uuid:abc-123") for an isbn: entry.

Uses the live in-memory self.ui.doc_settings when available (required at
book-open time, since KOReader has not yet flushed settings to the .sdr
sidecar). Falls back to loading from disk via metadata_extractor for
contexts where the document is no longer open.

ISBN-13 is preferred; ISBN-10 is used as a fallback.

@param file_path string Full path to the document file
@return string|nil Raw ISBN digits (without "isbn:" prefix), or nil if not found
--]]
---BookloreSync:_extractIsbnFromDocSettings.
function BookloreSync:_extractIsbnFromDocSettings(file_path)
    local doc_settings
    if self.ui and self.ui.doc_settings then
        self:logDbg("BookloreSync: Using live in-memory doc_settings for ISBN extraction")
        doc_settings = self.ui.doc_settings
    else
        self:logDbg("BookloreSync: Falling back to on-disk sidecar for ISBN extraction")
        doc_settings = self.metadata_extractor:loadDocSettings(file_path)
    end

    if not doc_settings then
        self:logDbg("BookloreSync: No doc settings found for ISBN extraction")
        return nil
    end

    local doc_props = doc_settings:readSetting("doc_props")
    if type(doc_props) ~= "table" then
        self:logDbg("BookloreSync: No doc_props found in doc settings")
        return nil
    end

    local identifiers = doc_props.identifiers
    if type(identifiers) ~= "string" then
        self:logDbg("BookloreSync: No identifiers string found in doc_props")
        return nil
    end

    local isbn = identifiers:match("isbn:(%d%d%d%d%d%d%d%d%d%d%d%d%d)")
              or identifiers:match("isbn:(%d%d%d%d%d%d%d%d%d%d)")
    if isbn then
        self:logInfo("BookloreSync: Found ISBN in doc settings:", isbn)
        return isbn
    end

    self:logInfo("BookloreSync: No ISBN entry found in identifiers:", identifiers)
    return nil
end

--[[--
Start tracking a reading session

Called when a document is opened
--]]
---BookloreSync:startSession.
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

        -- First open can have hash cached locally but no server-resolved ID yet.
        -- If network is available, resolve now so we do not need a second open.
        if file_hash and file_hash ~= "" and not book_id and self:isNetworkConnected() then
            self:logInfo("BookloreSync: Cache entry has no book_id, resolving from server now")
            local resolved_book_id, isbn10, isbn13, server_pagecount = self:getBookIdByHash(file_hash)
            if resolved_book_id then
                book_id = resolved_book_id
                local save_ok = self.db:saveBookCache(file_path, file_hash, book_id,
                    cached_book.title, cached_book.author, isbn10, isbn13, server_pagecount)
                if save_ok then
                    self:logInfo("BookloreSync: Cache updated with resolved book_id on open:", book_id)
                end
            else
                self:logInfo("BookloreSync: Could not resolve book_id for cached hash on open")
            end
        end
    else
        self:logInfo("BookloreSync: Book not in cache, calculating hash")
            file_hash = self:calculateBookHash(file_path)
        
        if not file_hash then
            self:logWarn("BookloreSync: Failed to calculate book hash, continuing without hash")
        else
            self:logInfo("BookloreSync: Hash calculated:", file_hash)
            
            local isbn10, isbn13, server_pagecount
            if self:isNetworkConnected() then
                self:logInfo("BookloreSync: Network connected, looking up book on server")
                book_id, isbn10, isbn13, server_pagecount = self:getBookIdByHash(file_hash)
                
                if book_id then
                    self:logInfo("BookloreSync: Book ID found on server:", book_id)
                    if isbn10 or isbn13 then
                        self:logInfo("BookloreSync: Book has ISBN-10:", isbn10, "ISBN-13:", isbn13)
                    end
                else
                    self:logInfo("BookloreSync: Book not found on server by hash, trying ISBN fallback")
                    local isbn = self:_extractIsbnFromDocSettings(file_path)
                    if isbn then
                        self:logInfo("BookloreSync: Attempting ISBN search for:", isbn)
                        local isbn_success, isbn_results = self.api:searchBooksByIsbn(
                            isbn, self.booklore_username, self.booklore_password)
                        local matched_id = nil
                        if isbn_success and isbn_results and #isbn_results > 0 then
                            for _, result in ipairs(isbn_results) do
                                if result.matchScore == 1 then
                                    matched_id = tonumber(result.id)
                                    break
                                end
                            end
                        end
                        if matched_id then
                            book_id = matched_id
                            self:logInfo("BookloreSync: Book ID resolved via ISBN search:", book_id)
                        else
                            self:logWarn("BookloreSync: ISBN search returned no exact match (matchScore=1)")
                            UIManager:show(InfoMessage:new{
                                text    = _("No match found based on hash or ISBN.\nDoes this book exist in your Booklore library?"),
                                timeout = 5,
                            })
                        end
                    else
                        self:logInfo("BookloreSync: No ISBN available in doc settings")
                        -- We only show this when actually connected so we know the server
                        -- was reached and genuinely has no book with this hash.
                        UIManager:show(InfoMessage:new{
                            text    = _("No match found based on hash.\nDoes this book exist in your Booklore library?"),
                            timeout = 5,
                        })
                    end
                end
            else
                self:logInfo("BookloreSync: No network connection, skipping server lookup")
                self:logInfo("BookloreSync: Book will be cached locally and resolved when online")
            end
            
            local ok, result = pcall(function()
                return self.db:saveBookCache(file_path, file_hash, book_id, nil, nil, isbn10, isbn13, server_pagecount)
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
    local koreader_pagecount = nil
    if self.ui and self.ui.document and self.ui.document.getPageCount then
        local pc = tonumber(self.ui.document:getPageCount())
        if pc and pc > 0 then
            koreader_pagecount = math.floor(pc + 0.5)
        end
    end
    
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
        koreader_pagecount = koreader_pagecount,
    }
    
    self:logInfo("BookloreSync: Session started for '", book_title, "' at", start_progress, "% (location:", start_location, ")")

    -- Re-initialize API client at session start so periodic progress pushes do
    -- not pay init cost on every page-based sync trigger.
    if self.api then
        self:refreshEffectiveServerUrl()
        self.api:init(self.server_url, self.username, self.password, self.db)
    end
end

--[[--
End the current reading session and save to database

Called when document closes, device suspends, or returns to menu

@param options Table with options:
  - silent: Don't show UI messages
  - force_queue: Always queue instead of trying to sync
--]]
---BookloreSync:endSession.
function BookloreSync:endSession(options)
    options = options or {}
    local silent = options.silent or false
    local force_queue = options.force_queue or self.manual_sync_only
    
    if not self.current_session then
        self:logInfo("BookloreSync: No active session to end")
        return "no_session"
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
        return "invalid", reason
    end

    -- Per-book tracking check: if the user has disabled tracking for this
    -- book, discard the session silently (don't add to pending_sessions).
    if self.db and self.current_session.file_path
       and not self.db:isBookTrackingEnabled(self.current_session.file_path) then
        self:logInfo("BookloreSync: Tracking disabled for this book, discarding session:",
                     self.current_session.file_path)
        self.current_session = nil
        return "tracking_disabled"
    end
    
    local progress_delta = end_progress - self.current_session.start_progress
    
    ---formatTimestamp.
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
        koreaderPagecount = self.current_session.koreader_pagecount,
    }
    
    self:logInfo("BookloreSync: Session valid - Duration:", duration_seconds, "s, Progress delta:", progress_delta, "%")
    
    local success = self.db:addPendingSession(session_data)

    if success then
        self:logInfo("BookloreSync: Session saved to pending queue")
        -- Toast and sync are intentionally suppressed here.
        -- onCloseDocument is responsible for triggering syncPendingSessions
        -- after rating and annotations have also been queued, and only once
        -- book_id is confirmed.  This prevents a premature sync that would
        -- race with those two queuing steps.
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
    return success and "saved" or "db_error"
end

-- Event Handlers

--[[--
Handler for when a document is opened and ready
--]]
---BookloreSync:onReaderReady.
function BookloreSync:onReaderReady()
    self:logInfo("BookloreSync: Reader ready")
    self:applyAirplaneModeSyncModeIntegration()

    if self.ui and self.ui.document and self.ui.document.file then
        local open_path = self.ui.document.file
        if self.epub_context_cache and self.epub_context_cache.doc_path ~= open_path then
            self:invalidateEpubContext("document_open_switch")
        end
    end

    self:startSession()
    self:detectBookMetadataLocation()

    -- Reset per-document progress counters.
    self.progress_sync_page_counter = 0
    if self.ui and self.ui.getCurrentPage then
        self.progress_sync_last_page = self.ui:getCurrentPage() or -1
    else
        self.progress_sync_last_page = -1
    end
    self.progress_sync_page_update_primed = false
    self.progress_sync_last_page_turn_timestamp = os.time()

    -- Pull-only on open: allow remote catch-up without recording local state.
    if self.progress_sync_enabled and self.progress_pull_on_open and self:isNetworkConnected() then
        self:pullKoreaderProgress(false)
    end

    -- Do not queue local progress on open.
    -- Local state is recorded by periodic page-update triggers and on close.
    return false -- Allow other plugins to process this event
end

--[[--
Track page turns for KOReader progress sync when trigger is set to every N pages.
--]]
---BookloreSync:onPageUpdate.
function BookloreSync:onPageUpdate(page)
    if not self.is_enabled or not self.progress_sync_enabled then
        return false
    end
    if page == nil then
        return false
    end

    if self.progress_sync_ignore_next_page_event then
        self.progress_sync_ignore_next_page_event = false
        return false
    end

    -- Prime the page-update baseline once per open so initial render updates
    -- do not count as a user page turn or trigger a progress push.
    if not self.progress_sync_page_update_primed then
        self.progress_sync_page_update_primed = true
        self.progress_sync_last_page = page
        return false
    end

    if self.progress_sync_last_page ~= page then
        self.progress_sync_last_page = page
        self.progress_sync_last_page_turn_timestamp = os.time()
        self.progress_sync_page_counter = (self.progress_sync_page_counter or 0) + 1
    end

    if not self.progress_sync_page_updates_enabled then
        return false
    end

    local threshold = tonumber(self.progress_sync_interval_pages) or 10
    if threshold < 1 then
        threshold = 1
    end
    if threshold <= 0 then
        return false
    end
    if self.progress_sync_page_counter < threshold then
        return false
    end

    self.progress_sync_page_counter = 0

    local payload = nil
    if self.ui and self.ui.document and self.ui.document.info and self.ui.document.info.has_pages then
        payload = self:buildKoreaderProgressPayloadForPage(page, os.time())
    end

    local debounce_seconds = tonumber(self.progress_sync_debounce_seconds)
    if debounce_seconds == nil then
        debounce_seconds = PROGRESS_API_DEBOUNCE_SECONDS
    end
    if debounce_seconds < 0 then
        debounce_seconds = 0
    end
    local now = os.time()
    if debounce_seconds > 0 and now - (self.progress_sync_last_push_ts or 0) < debounce_seconds then
        return false
    end

    if self.manual_sync_only then
        local queued = payload and self:queueKoreaderProgressPayload(payload) or self:queueCurrentKoreaderProgress()
        if queued then
            self.progress_sync_last_push_ts = now
        end
    else
        self:_requestWifi(_("sync reading progress"), function()
            local queued = payload and self:queueKoreaderProgressPayload(payload) or self:queueCurrentKoreaderProgress()
            if queued then
                self:scheduleBackgroundProgressFlush("page_update")
            end
        end, function()
            self:logInfo("BookloreSync: WiFi request declined on page-update progress sync - queueing")
            local queued = payload and self:queueKoreaderProgressPayload(payload) or self:queueCurrentKoreaderProgress()
            if queued then
                self.progress_sync_last_push_ts = os.time()
            end
        end)
    end

    return false
end

--[[--
Handler for when a document is closed
--]]
---BookloreSync:onCloseDocument.
function BookloreSync:onCloseDocument()
    if not self.is_enabled then
        return false
    end

    local close_started_ms = self:getTimingNowMs()
    local function closeReturn(value)
        local elapsed_ms = self:getTimingNowMs() - close_started_ms
        self:logInfo("BookloreSync: onCloseDocument_total_ms=", tostring(elapsed_ms))
        return value
    end

    self:logInfo("BookloreSync: Document closing")

    local pre_file_path = self.current_session and self.current_session.file_path
    local pre_file_hash = self.current_session and self.current_session.file_hash
    local pre_book_id   = self.current_session and self.current_session.book_id
    local pre_session_started_at = self.current_session and self.current_session.start_time
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

    -- ── Step 1: Resolve book_id ───────────────────────────────────────────
    -- book_id is the prerequisite gate for all network activity.
    -- If it was not resolved at book-open time (server offline, first seen),
    -- attempt one final lookup now while we still have the hash in memory.
    -- If resolution succeeds, propagate the ID back into current_session and
    -- the DB cache so subsequent steps see it as known.
    if not pre_book_id and pre_file_hash and pre_file_hash ~= "" then
        self:logInfo("BookloreSync: book_id unknown at close - attempting final resolution (hash:", pre_file_hash, ")")
        if self:isNetworkConnected() then
            -- Check cache first (may have been populated by a background sync)
            local cached = self.db:getBookByHash(pre_file_hash)
            if cached and cached.book_id then
                pre_book_id = tonumber(cached.book_id)
                self:logInfo("BookloreSync: book_id resolved from cache at close:", pre_book_id)
            else
                local resolved_book_id, isbn10, isbn13, server_pagecount = self:getBookIdByHash(pre_file_hash)
                if resolved_book_id then
                    pre_book_id = tonumber(resolved_book_id)
                    self.db:saveBookCache(
                        pre_file_path,
                        pre_file_hash,
                        pre_book_id,
                        nil,
                        nil,
                        isbn10,
                        isbn13,
                        server_pagecount
                    )
                    self:logInfo("BookloreSync: book_id resolved from server at close:", pre_book_id)
                else
                    self:logWarn("BookloreSync: book_id could not be resolved at close - all data will be stored locally only")
                end
            end
            -- Propagate back so endSession() stores the resolved ID in pending_sessions
            if pre_book_id and self.current_session then
                self.current_session.book_id = pre_book_id
            end
        else
            self:logInfo("BookloreSync: Offline at close - book_id resolution deferred to next sync")
        end
    end

    -- ── Step 2: Queue session ─────────────────────────────────────────────
    -- Always use force_queue=true + silent=true here.  The combined result
    -- toast and the network sync happen below (step 5), after rating and
    -- annotations have also been queued, so this call purely persists the
    -- session data and never triggers a premature sync.
    local session_status, session_reason = self:endSession({ silent = true, force_queue = true })

    -- Show "criteria not met" feedback immediately when the session was
    -- discarded at close (not on suspend/resume paths which pass silent=true
    -- themselves; those don't reach this code path anyway).
    if session_status == "invalid" and not self.silent_messages then
        UIManager:show(InfoMessage:new{
            text    = _("Session not saved: criteria not met"),
            timeout = 3,
        })
        return closeReturn(false)
    end

    -- Per-book tracking disabled: endSession already discarded the session.
    -- Safeguard here to ensure rating/annotation/bookmark paths are skipped
    -- as well on the immediate close-document flow.
    if session_status == "tracking_disabled" then
        self:logInfo("BookloreSync: Tracking disabled for this book - skipping rating/annotation sync on close")
        return closeReturn(false)
    end

    -- ── Step 3: Queue / sync rating ───────────────────────────────────────
    self:logInfo(string.format(
        "BookloreSync: Close flags - highlights_notes=%s  rating=%s  file_path=%s",
        tostring(self.highlights_notes_sync_enabled),
        tostring(self.rating_sync_enabled),
        tostring(pre_file_path ~= nil)
    ))
    if self.rating_sync_enabled and pre_file_path then
        local mode = self.rating_sync_mode or "koreader_scaled"

        -- Ensure we have a book_cache_id for deferred storage paths below.
        local rating_book_cache_id = self.db:getBookCacheIdByFilePath(pre_file_path)
        if not rating_book_cache_id then
            self.db:saveBookCache(pre_file_path, pre_file_hash or "", nil, nil, nil, nil, nil)
            rating_book_cache_id = self.db:getBookCacheIdByFilePath(pre_file_path)
        end

        if pre_book_id then
            -- book_id is known - act immediately.
            if mode == "koreader_scaled" then
                -- Pass the live in-memory rating to avoid stale-sidecar reads.
                self:syncKOReaderRating(pre_file_path, pre_book_id, pre_live_rating)
            elseif mode == "select_at_complete" then
                if pre_end_progress and pre_end_progress >= 99 then
                    UIManager:scheduleIn(2, function()
                        self:showRatingDialog(pre_file_path, pre_book_id)
                    end)
                end
            end
        else
            -- book_id is still unknown - store everything locally, sync nothing.
            if mode == "koreader_scaled" and pre_live_rating and rating_book_cache_id then
                -- Queue the scaled rating for retry once book_id is resolved.
                local rating_scaled = math.max(1, math.min(10, math.floor(pre_live_rating) * 2))
                self.db:upsertBookMetadata(rating_book_cache_id, { rating = rating_scaled, rating_synced = false })
                self.db:addPendingRating(rating_book_cache_id, nil, rating_scaled)
                self:logInfo("BookloreSync: koreader_scaled rating queued (no book_id) - scaled:", rating_scaled)
            elseif mode == "select_at_complete" and pre_end_progress and pre_end_progress >= 99 then
                -- Mark deferred so next sync shows/uploads the rating once book_id resolves.
                if rating_book_cache_id then
                    self.db:setPendingRatingPrompt(rating_book_cache_id, true)
                    self:logInfo("BookloreSync: Book completed but no book_id yet - deferred rating prompt stored")
                end
                -- Show the dialog immediately so the user can record the rating now.
                local path_copy = pre_file_path
                UIManager:scheduleIn(2, function()
                    self:showRatingDialog(path_copy, nil)
                end)
            end
        end
    end

    -- ── Step 4: Queue / sync annotations ─────────────────────────────────
    -- self.ui.document is still open here (CloseDocument fires before
    -- closeDocument()), so we can build EPUB CFIs from the live document.
    -- When pre_book_id is nil, syncHighlightsAndNotes operates in queue_only
    -- mode: it computes CFIs (while the doc is open) and stores everything in
    -- pending_annotations without making any network calls.
    local ann_synced_now, ann_queued_now, ann_failed_now = 0, 0, 0
    local bm_synced_now, bm_queued_now, bm_failed_now = 0, 0, 0
    local close_ctx = nil
    if self.highlights_notes_sync_enabled and pre_file_path then
        local strategy = self.upload_strategy or "on_session"
        local open_doc      = self.ui and self.ui.document
        local live_settings = self.ui and self.ui.doc_settings

        -- Capture annotations directly from the ReaderAnnotation module.
        -- KOReader stores annotations in ReaderAnnotation's own in-memory table
        -- (self.ui.annotation.annotations) and only copies them into doc_settings
        -- during the SaveSettings event - which fires AFTER CloseDocument on the
        -- standard close path (when self.dialog == self in ReaderUI:onClose).
        -- Reading doc_settings:readSetting("annotations") at this point therefore
        -- returns stale or missing data on real devices.  The authoritative live
        -- source is self.ui.annotation.annotations.
        local live_annotations = nil
        if self.ui and self.ui.annotation and self.ui.annotation.annotations then
            live_annotations = self.ui.annotation.annotations
            self:logInfo("BookloreSync: Captured", #live_annotations, "annotations from ReaderAnnotation module")
        else
            self:logInfo("BookloreSync: ReaderAnnotation module not available - will fall back to doc_settings / sidecar")
        end

        -- Derive bookmarks from the same live annotations array.
        -- KOReader stores both highlights and bookmarks in a single "annotations"
        -- array (in doc_settings and in self.ui.annotation.annotations).
        -- Bookmarks are entries without pos0/color/drawer; their "page" field
        -- is the XPointer position (same format as pos0 on highlights).
        local live_bookmarks = nil
        if live_annotations then
            live_bookmarks = {}
            for _, ann in ipairs(live_annotations) do
                if not ann.pos0 and not ann.color then
                    table.insert(live_bookmarks, {
                        pos0     = ann.page,  -- XPointer string doubles as pos0
                        pageno   = ann.pageno,
                        notes    = ann.text,
                        datetime = ann.datetime,
                        chapter  = ann.chapter,
                    })
                end
            end
            if #live_bookmarks > 0 then
                self:logInfo("BookloreSync: Derived", #live_bookmarks, "bookmarks from live annotations array")
            else
                self:logInfo("BookloreSync: No bookmarks found in live annotations array - will fall back to doc_settings / sidecar")
                live_bookmarks = nil
            end
        end

        close_ctx = self:createCloseSyncContext({
            close_started_ms = close_started_ms,
            session_started_at = pre_session_started_at,
            doc_path = pre_file_path,
            file_hash = pre_file_hash,
            book_id = pre_book_id,
            end_progress = pre_end_progress,
            document = open_doc,
            doc_settings = live_settings,
            live_annotations = live_annotations,
            live_bookmarks = live_bookmarks,
        })

        if strategy == "on_session" then
            ann_synced_now, ann_queued_now, ann_failed_now =
                self:syncHighlightsAndNotes(pre_file_path, pre_book_id, open_doc, live_settings, live_annotations, close_ctx)
        elseif strategy == "on_complete" and pre_end_progress and pre_end_progress >= 99 then
            ann_synced_now, ann_queued_now, ann_failed_now =
                self:syncHighlightsAndNotes(pre_file_path, pre_book_id, open_doc, live_settings, live_annotations, close_ctx)
        end
        ann_synced_now  = tonumber(ann_synced_now)  or 0
        ann_queued_now  = tonumber(ann_queued_now)  or 0
        ann_failed_now  = tonumber(ann_failed_now)  or 0

        -- Sync bookmarks (same strategy gate as annotations)
        if strategy == "on_session" or (strategy == "on_complete" and pre_end_progress and pre_end_progress >= 99) then
            bm_synced_now, bm_queued_now, bm_failed_now =
                self:syncBookmarks(pre_file_path, pre_book_id, open_doc, live_settings, live_bookmarks, close_ctx)
        end
        bm_synced_now = tonumber(bm_synced_now) or 0
        bm_queued_now = tonumber(bm_queued_now) or 0
        bm_failed_now = tonumber(bm_failed_now) or 0
    end

    -- ── Step 5: Fast-close deferred flush ──────────────────────────────────
    -- Close handler now persists all pending work first and defers heavy
    -- network flush slightly, so close returns quickly on large books.
    -- Existing pending queues and syncPendingSessions pipeline are reused.
    local progress_queued_now = false
    if self.progress_sync_enabled then
        progress_queued_now = self:queueCurrentKoreaderProgress()
    end

    if not self.manual_sync_only then
        local deferred_scheduled = false
        local ok_defer, defer_err = pcall(function()
            deferred_scheduled = self:scheduleDeferredCloseFlush("close_document")
        end)
        if not ok_defer then
            self:logErr("BookloreSync: Failed to schedule deferred close flush:", tostring(defer_err))
            -- Fail-safe: keep pre-phase behaviour so pending session/progress
            -- are still uploaded in automatic mode if deferred scheduling breaks.
            self:_requestWifi(_("upload session and annotations"), function()
                self:syncPendingSessions(false)
            end, function()
                self:logInfo("BookloreSync: WiFi request declined at close (fallback immediate sync path)")
            end)
        end
        if pre_book_id then
            self:logInfo("BookloreSync: book_id known - deferred post-close flush", "scheduled=", tostring(deferred_scheduled))
        else
            self:logInfo("BookloreSync: book_id unknown - data stored locally, deferred flush will retry later")
        end

        if not self.silent_messages then
            local parts
            if pre_book_id then
                parts = { _("Booklore Sync: Saved locally") }
                parts[#parts + 1] = _("S: 1 queued")
                if ann_synced_now > 0 then
                    parts[#parts + 1] = T(_("A: %1 synced now"), ann_synced_now)
                end
                if ann_queued_now > 0 then
                    parts[#parts + 1] = T(_("A: %1 queued"), ann_queued_now)
                end
                if bm_synced_now > 0 then
                    parts[#parts + 1] = T(_("B: %1 synced now"), bm_synced_now)
                end
                if bm_queued_now > 0 then
                    parts[#parts + 1] = T(_("B: %1 queued"), bm_queued_now)
                end
                if bm_failed_now > 0 then
                    parts[#parts + 1] = T(_("B: %1 failed now"), bm_failed_now)
                end
                if progress_queued_now then
                    parts[#parts + 1] = _("P: 1 queued")
                end
                parts[#parts + 1] = _("Will flush shortly after close")
            else
                parts = { _("Book not found in Booklore - saved locally") }
                parts[#parts + 1] = _("S: 1 cached")
                if ann_queued_now > 0 then
                    parts[#parts + 1] = T(_("A: %1 cached"), ann_queued_now)
                end
                if bm_queued_now > 0 then
                    parts[#parts + 1] = T(_("B: %1 cached"), bm_queued_now)
                end
                if pre_live_rating and self.rating_sync_enabled then
                    parts[#parts + 1] = _("R: 1 cached")
                end
                if progress_queued_now then
                    parts[#parts + 1] = _("P: 1 cached")
                end
                parts[#parts + 1] = _("Will sync automatically when matched")
            end
            UIManager:show(InfoMessage:new{
                text = table.concat(parts, "\n"),
                timeout = 3,
            })
        end
    elseif session_status == "saved" and not self.silent_messages then
        -- Manual sync only mode: session was queued, inform the user.
        self:logInfo("BookloreSync: manual_sync_only - session queued, notifying user")
        local parts = { _("Booklore Sync: Session saved") }
        parts[#parts + 1] = _("S: 1 queued")
        if ann_queued_now > 0 then
            parts[#parts + 1] = T(_("A: %1 queued"), ann_queued_now)
        end
        if bm_queued_now > 0 then
            parts[#parts + 1] = T(_("B: %1 queued"), bm_queued_now)
        end
        if progress_queued_now then
            parts[#parts + 1] = _("P: 1 queued")
        end
        parts[#parts + 1] = _("Use 'Sync Pending Now' to upload")
        UIManager:show(InfoMessage:new{
            text    = table.concat(parts, "\n"),
            timeout = 3,
        })
    end

    local close_book_cache_id = nil
    if pre_file_path and self.db then
        close_book_cache_id = self.db:getBookCacheIdByFilePath(pre_file_path)
    end
    if close_book_cache_id and self.db then
        local pending_ann = tonumber(self.db:getPendingAnnotationCountForBook(close_book_cache_id)) or 0
        local pending_bm = tonumber(self.db:getPendingBookmarkCountForBook(close_book_cache_id)) or 0
        if pending_ann == 0 and pending_bm == 0 then
            self:invalidateEpubContext("close_document_no_pending_context_needed", pre_file_path)
        else
            self:logInfo(
                "BookloreSync: Retaining EPUB context cache after close",
                "pending_annotations=", tostring(pending_ann),
                "pending_bookmarks=", tostring(pending_bm),
                "path=", tostring(pre_file_path or "")
            )
        end
    else
        self:invalidateEpubContext("close_document_no_cache_id", pre_file_path)
    end

    self:releaseCloseSyncContext(close_ctx, "onCloseDocument_complete")
    self:applyAirplaneModeSyncModeIntegration()

    return closeReturn(false)
end

--[[--
Attempt to connect to network with timeout

This function tries to enable WiFi and wait for network connection.
Used when "Connect network on suspend" is enabled.

@return boolean true if connected, false otherwise
--]]
---BookloreSync:connectNetwork.
function BookloreSync:connectNetwork()
    if self:isAirplaneModeActive() then
        self:logWarn("BookloreSync: Refusing network connect while airplane mode is active")
        return false
    end

    if self:isNetworkConnected() then
        self:logInfo("BookloreSync: Network already connected")
        return true
    end

    self:logInfo("BookloreSync: Attempting to connect to network")

    local tried_enable = false
    local manager_calls = {
        { "turnOnWifi" },
        { "enableWifi" },
        { "setWifiEnabled", true },
        { "setWifiState", true },
        { "requestWifiOn" },
        { "reconnect" },
        { "obtainIP" },
    }

    local unpack_fn = table.unpack or unpack
    for _, call in ipairs(manager_calls) do
        local method = call[1]
        if type(NetworkMgr[method]) == "function" then
            local args = {}
            for i = 2, #call do
                args[#args + 1] = call[i]
            end
            self:logInfo("BookloreSync: Trying NetworkMgr method:", method)
            local ok_call, call_result = pcall(NetworkMgr[method], NetworkMgr, unpack_fn(args))
            if ok_call then
                tried_enable = true
                if call_result ~= false then
                    break
                end
            else
                self:logWarn("BookloreSync: NetworkMgr method failed:", method, tostring(call_result))
            end
        end
    end

    if not tried_enable then
        self:logWarn("BookloreSync: No supported NetworkMgr WiFi-enable method found")
        return false
    end

    local ok_ffi, ffiutil = pcall(require, "ffi/util")
    local sleep_fn = nil
    if ok_ffi and ffiutil and type(ffiutil.sleep) == "function" then
        sleep_fn = ffiutil.sleep
    else
        -- Fallback for KOReader builds where ffi/util.sleep is unavailable.
        local ok_ffi_core, ffi = pcall(require, "ffi")
        if ok_ffi_core and ffi then
            pcall(function()
                ffi.cdef([[ unsigned int usleep(unsigned int usec); ]])
            end)
            if ffi.C and ffi.C.usleep then
                sleep_fn = function(seconds)
                    local usec = math.floor((tonumber(seconds) or 0) * 1000000)
                    if usec < 0 then usec = 0 end
                    ffi.C.usleep(usec)
                end
                self:logInfo("BookloreSync: Using ffi.usleep fallback for network wait")
            end
        end
    end
    local sleep_available = type(sleep_fn) == "function"

    local timeout = tonumber(self.network_connect_timeout_seconds) or DEFAULT_NETWORK_CONNECT_TIMEOUT_SECONDS
    if timeout < 1 then
        timeout = 1
    end
    local run_until_connect = self.network_connect_run_until_connect == true
    local elapsed = 0
    local check_interval = 0.5

    while run_until_connect or elapsed < timeout do
        if self:isNetworkConnected() then
            self:logInfo("BookloreSync: Network connected successfully after", elapsed, "seconds")
            return true
        end

        if sleep_available then
            local ok_sleep, sleep_err = pcall(sleep_fn, check_interval)
            if not ok_sleep then
                self:logWarn("BookloreSync: Sleep call failed while waiting for network:", tostring(sleep_err))
                break
            end
        else
            -- Some KOReader builds do not expose ffiutil.sleep().
            -- In that case, avoid crashing and fall back to a single best-effort
            -- connectivity check after requesting WiFi.
            self:logWarn("BookloreSync: Sleep utility unavailable while waiting for network")
            if self:isNetworkConnected() then
                self:logInfo("BookloreSync: Network connected successfully (fallback check)")
                return true
            end
            break
        end
        elapsed = elapsed + check_interval
    end

    if run_until_connect then
        self:logWarn("BookloreSync: Network connect wait ended before connection was established")
    else
        self:logWarn("BookloreSync: Network connection timeout after", timeout, "seconds")
    end
    return false
end

---BookloreSync:disconnectNetwork.
function BookloreSync:disconnectNetwork()
    if not NetworkMgr then
        return false
    end

    local manager_calls = {
        { "turnOffWifi" },
        { "disableWifi" },
        { "setWifiEnabled", false },
        { "setWifiState", false },
        { "requestWifiOff" },
        { "disconnect" },
        { "releaseIP" },
    }

    local unpack_fn = table.unpack or unpack
    local attempted = false

    for _, call in ipairs(manager_calls) do
        local method = call[1]
        if type(NetworkMgr[method]) == "function" then
            local args = {}
            for i = 2, #call do
                args[#args + 1] = call[i]
            end
            attempted = true
            self:logInfo("BookloreSync: Trying NetworkMgr WiFi-disable method:", method)
            local ok_call, call_result = pcall(NetworkMgr[method], NetworkMgr, unpack_fn(args))
            if ok_call and call_result ~= false then
                return true
            elseif not ok_call then
                self:logWarn("BookloreSync: NetworkMgr WiFi-disable method failed:", method, tostring(call_result))
            end
        end
    end

    if not attempted then
        self:logWarn("BookloreSync: No supported NetworkMgr WiFi-disable method found")
    end

    return false
end

--[[--
Ensure WiFi is available, then run the action.

Behavior is automatic-only: if WiFi is already connected `on_confirm` is
called immediately; otherwise the plugin attempts to enable/connect WiFi via
`connectNetwork()`, then calls `on_confirm` only when connected.

@param context    Short description of the action that needs WiFi.
@param on_confirm Callback invoked when WiFi is (or becomes) available.
@param on_deny    Callback invoked when WiFi cannot be enabled (may be nil).
@param opts       Optional table; set `disable_wifi_when_done=true` to
                  request a best-effort WiFi disable after successful run
                  when WiFi was initially disconnected.
--]]--
---BookloreSync:_requestWifi.
function BookloreSync:_requestWifi(context, on_confirm, on_deny, opts)
    local deny_callback_provided = type(on_deny) == "function"

    if type(on_confirm) ~= "function" then
        on_confirm = function() end
    end
    on_deny = on_deny or function() end

    ---safeInvoke.
    local function safeInvoke(cb, label)
        local ok, err = pcall(cb)
        if not ok then
            self:logErr("BookloreSync: Error during", label, ":", tostring(err))
            UIManager:show(InfoMessage:new{
                text = _("Booklore Sync failed unexpectedly. See logs."),
                timeout = 3,
            })
            return false
        end
        return true
    end

    if self:isAirplaneModeActive() then
        self:logInfo("BookloreSync: Airplane mode active; skipping WiFi request for:", context or "<unknown>")
        if not deny_callback_provided then
            UIManager:show(InfoMessage:new{
                text = _("Airplane mode is enabled - network sync skipped"),
                timeout = 2,
            })
        end
        safeInvoke(on_deny, "WiFi deny callback")
        return
    end

    local was_connected = self:isNetworkConnected()

    local function maybeDisableWifiAfterAction()
        if not (opts and opts.disable_wifi_when_done) then
            return
        end
        if was_connected then
            return
        end

        -- Prefer KOReader's native before/after WiFi-action lifecycle so the
        -- global "Action when done with Wi-Fi" setting (leave on/turn off/prompt)
        -- is respected and network events are emitted consistently.
        if type(NetworkMgr.afterWifiAction) == "function" then
            local ok_after, after_err = pcall(function()
                if type(NetworkMgr.setBeforeActionFlag) == "function" then
                    NetworkMgr:setBeforeActionFlag()
                end
                NetworkMgr:afterWifiAction()
            end)
            if ok_after then
                self:logInfo("BookloreSync: Completed KOReader after-WiFi action")
                return
            end
            self:logWarn("BookloreSync: afterWifiAction failed, falling back to direct disable:", tostring(after_err))
        end

        local ok_disconnect, disconnected = pcall(function()
            return self:disconnectNetwork()
        end)
        if not ok_disconnect then
            self:logWarn("BookloreSync: WiFi disable after action crashed:", tostring(disconnected))
            return
        end
        if disconnected then
            self:logInfo("BookloreSync: WiFi disabled after action completion")
        else
            self:logWarn("BookloreSync: Could not disable WiFi after action completion")
        end
    end

    -- WiFi already up - proceed immediately without any prompt.
    local connected_before_request = self:isNetworkConnected()

    if connected_before_request then
        safeInvoke(on_confirm, "WiFi confirm callback")
        maybeDisableWifiAfterAction()
        return
    end

    self:logInfo("BookloreSync: Auto-enabling WiFi for:", context or "<unknown>")
    local ok_connect, ok = pcall(function()
        return self:connectNetwork()
    end)
    if not ok_connect then
        self:logErr("BookloreSync: WiFi auto-enable attempt crashed:", tostring(ok))
        UIManager:show(InfoMessage:new{
            text    = _("Failed to enable WiFi"),
            timeout = 2,
        })
        safeInvoke(on_deny, "WiFi deny callback")
        return
    end
    if ok then
        local delay_seconds = tonumber(self.sync_delay_after_connect_seconds) or DEFAULT_SYNC_DELAY_AFTER_CONNECT_SECONDS
        if delay_seconds > 0 then
            self:logInfo("BookloreSync: Delaying sync after connect for", tostring(delay_seconds), "seconds")
            local ok_sleep, local_ffiutil = pcall(require, "ffi/util")
            if ok_sleep and local_ffiutil and type(local_ffiutil.sleep) == "function" then
                pcall(local_ffiutil.sleep, delay_seconds)
            else
                UIManager:scheduleIn(delay_seconds, function()
                    safeInvoke(on_confirm, "WiFi confirm callback")
                    maybeDisableWifiAfterAction()
                end)
                return
            end
        end
        safeInvoke(on_confirm, "WiFi confirm callback")
        maybeDisableWifiAfterAction()
    else
        self:logWarn("BookloreSync: WiFi auto-enable failed")
        UIManager:show(InfoMessage:new{
            text    = _("Could not connect to WiFi"),
            timeout = 2,
        })
        safeInvoke(on_deny, "WiFi deny callback")
    end
end

function BookloreSync:getPendingSyncTotals()
    if not self.db then
        return {
            sessions = 0,
            annotations = 0,
            ratings = 0,
            bookmarks = 0,
            progress = 0,
            deletions = 0,
            total = 0,
        }
    end

    local function safeCount(method_name)
        local fn = self.db and self.db[method_name]
        if type(fn) ~= "function" then
            return 0
        end
        local ok, value = pcall(fn, self.db)
        if not ok then
            self:logWarn("BookloreSync: Failed to read pending count", tostring(method_name), tostring(value))
            return 0
        end
        return tonumber(value) or 0
    end

    local sessions = safeCount("getPendingSessionCount")
    local annotations = safeCount("getPendingAnnotationCount")
    local ratings = safeCount("getPendingRatingCount")
    local bookmarks = safeCount("getPendingBookmarkCount")
    local progress = safeCount("getPendingKoreaderProgressCount")

    local deletions = 0
    if type(self.db.getPendingDeletionCount) == "function" then
        deletions = safeCount("getPendingDeletionCount")
    elseif type(self.db.getPendingDeletions) == "function" then
        local ok_del, rows = pcall(self.db.getPendingDeletions, self.db)
        if ok_del and type(rows) == "table" then
            deletions = #rows
        elseif not ok_del then
            self:logWarn("BookloreSync: Failed to read pending deletions", tostring(rows))
        end
    end

    local total = sessions + annotations + ratings + bookmarks + progress + deletions
    return {
        sessions = sessions,
        annotations = annotations,
        ratings = ratings,
        bookmarks = bookmarks,
        progress = progress,
        deletions = deletions,
        total = total,
    }
end

function BookloreSync:scheduleDeferredCloseFlush(reason)
    if self.manual_sync_only or not self.is_enabled then
        return false
    end

    local totals = self:getPendingSyncTotals()

    if totals.total == 0 then
        self.deferred_close_flush_requested = false
        self.deferred_close_flush_scheduled = false
        self.deferred_close_flush_running = false
        self:logInfo(
            "BookloreSync: No-op skipped",
            "component=deferred_close_flush",
            "reason=no_pending_items",
            "trigger=", tostring(reason or "unknown"),
            "outcome=noop_skipped"
        )
        return false
    end

    self.deferred_close_flush_requested = true
    self.deferred_close_flush_last_queued_ms = self:getTimingNowMs()

    if self.deferred_close_flush_scheduled or self.deferred_close_flush_running then
        self:logInfo(
            "BookloreSync: Deferred close flush already queued/running - coalescing",
            "reason=", tostring(reason or "unknown"),
            "pending_total=", tostring(totals.total)
        )
        return true
    end

    self.deferred_close_flush_scheduled = true
    self.deferred_close_flush_seq = (tonumber(self.deferred_close_flush_seq) or 0) + 1
    local seq = self.deferred_close_flush_seq

    self:logInfo(
        "BookloreSync: Deferred close flush scheduled",
        "seq=", tostring(seq),
        "reason=", tostring(reason or "unknown"),
        "pending_total=", tostring(totals.total),
        "outcome=queued_on_close"
    )

    UIManager:scheduleIn(1, function()
        self.deferred_close_flush_scheduled = false

        if not self.deferred_close_flush_requested then
            self:logInfo("BookloreSync: Deferred close flush cancelled before run", "seq=", tostring(seq))
            return
        end
        if self.deferred_close_flush_running then
            self:logInfo("BookloreSync: Deferred close flush skipped - already running", "seq=", tostring(seq))
            return
        end

        local run_started_ms = self:getTimingNowMs()
        local lag_ms = run_started_ms - (tonumber(self.deferred_close_flush_last_queued_ms) or run_started_ms)

        self:logInfo(
            "BookloreSync: Deferred close flush starting",
            "seq=", tostring(seq),
            "queue_to_start_ms=", tostring(lag_ms)
        )

        self.deferred_close_flush_running = true
        self:_requestWifi(_("upload session and annotations"), function()
            local flush_started_ms = self:getTimingNowMs()
            self:syncPendingSessions(false)
            local flush_elapsed_ms = self:getTimingNowMs() - flush_started_ms
            self.deferred_close_flush_last_completed_ms = self:getTimingNowMs()
            self.deferred_close_flush_requested = false
            self.deferred_close_flush_running = false
            self:logInfo(
                "BookloreSync: Deferred close flush finished",
                "seq=", tostring(seq),
                "flush_elapsed_ms=", tostring(flush_elapsed_ms),
                "close_to_flush_done_ms=", tostring(self.deferred_close_flush_last_completed_ms - (tonumber(self.deferred_close_flush_last_queued_ms) or self.deferred_close_flush_last_completed_ms)),
                "outcome=flushed_after_close"
            )
        end, function()
            self.deferred_close_flush_running = false
            self:logInfo(
                "BookloreSync: Deferred close flush postponed",
                "seq=", tostring(seq),
                "reason=wifi_not_enabled_or_declined"
            )
        end)
    end)

    return true
end

--[[--
Handler for when the device is about to suspend
--]]
---BookloreSync:onSuspend.
function BookloreSync:onSuspend()
    if not self.is_enabled then
        return false
    end

    self:applyAirplaneModeSyncModeIntegration()
    
    self:logInfo("BookloreSync: Device suspending")

    -- Snapshot book_id before endSession() clears self.current_session.
    local pre_book_id = self.current_session and self.current_session.book_id

    self:endSession({ silent = true, force_queue = true })

    -- ── Capture bookmarks and annotations while the document is still open ──
    -- onCloseDocument is NOT fired on suspend; the book stays open in memory.
    -- We therefore mirror its annotation/bookmark harvesting here so that
    -- anything the user added during this reading session is queued before
    -- the device goes to sleep.
    if self.ui and self.ui.document then
        local doc_path     = self.ui.document.file
        local open_doc     = self.ui.document
        local live_settings = self.ui and self.ui.doc_settings

        -- book_id from snapshot or cache (best-effort; nil is fine – both sync
        -- functions operate in queue_only mode when book_id is absent)
        local book_id = pre_book_id
        if not book_id and doc_path then
            local cache_id = self.db and self.db:getBookCacheIdByFilePath(doc_path)
            if cache_id then
                local cached = self.db:getBookCacheById(cache_id)
                if cached then book_id = cached.book_id end
            end
        end

        -- Grab live annotations from the in-memory ReaderAnnotation module.
        -- KOReader only flushes these to the .sdr sidecar after CloseDocument,
        -- so reading from disk here would return stale / missing data.
        local live_annotations = nil
        if self.ui.annotation and self.ui.annotation.annotations then
            live_annotations = self.ui.annotation.annotations
            self:logInfo("BookloreSync: Suspend - captured", #live_annotations,
                         "annotations from ReaderAnnotation module")
        else
            self:logInfo("BookloreSync: Suspend - ReaderAnnotation not available, will fall back to sidecar")
        end

        -- Derive bookmarks: entries without pos0/color are plain bookmarks.
        local live_bookmarks = nil
        if live_annotations then
            live_bookmarks = {}
            for _, ann in ipairs(live_annotations) do
                if not ann.pos0 and not ann.color then
                    table.insert(live_bookmarks, {
                        pos0     = ann.page,
                        pageno   = ann.pageno,
                        notes    = ann.text,
                        datetime = ann.datetime,
                        chapter  = ann.chapter,
                    })
                end
            end
            if #live_bookmarks > 0 then
                self:logInfo("BookloreSync: Suspend - derived", #live_bookmarks, "bookmarks")
            else
                self:logInfo("BookloreSync: Suspend - no bookmarks in live annotations array")
                live_bookmarks = nil
            end
        end

        if doc_path then
            if self.highlights_notes_sync_enabled then
                local strategy = self.upload_strategy or "on_session"
                if strategy == "on_session" then
                    self:logInfo("BookloreSync: Suspend - queuing annotations")
                    self:syncHighlightsAndNotes(doc_path, book_id, open_doc, live_settings, live_annotations)
                    self:logInfo("BookloreSync: Suspend - queuing bookmarks")
                    self:syncBookmarks(doc_path, book_id, open_doc, live_settings, live_bookmarks)
                end
            end
        end
    end

    if self.force_push_session_on_suspend then
        self:logInfo("BookloreSync: Force push on suspend enabled")

        -- In automatic suspend-sync mode, queue current progress right now and
        -- flush immediately so session/progress are uploaded on suspend instead
        -- of waiting for deferred wake/close pipelines.
        if self.progress_sync_enabled then
            local queued_progress = self:queueCurrentKoreaderProgress()
            self:logInfo("BookloreSync: Suspend progress queue result:", tostring(queued_progress))
        end

        if self.connect_network_on_suspend then
            if self:isNetworkConnected() then
                self:logInfo("BookloreSync: Network ready - force syncing pending sessions/progress on suspend")
                self:syncPendingSessions(true)
            else
                self:logInfo("BookloreSync: Network not connected on suspend - skip connect attempt, data remains queued")
            end
        else
            self:logInfo("BookloreSync: Force syncing pending sessions/progress on suspend")
            self:syncPendingSessions(true)
        end
    else
        self:logInfo("BookloreSync: Force push on suspend disabled, sessions will sync on resume")
    end
    
    return false
end

--[[--
Handler for when the device resumes from suspend
--]]
---BookloreSync:onResume.
function BookloreSync:onResume()
    if not self.is_enabled then
        return false
    end

    self:applyAirplaneModeSyncModeIntegration()

    self:logInfo("BookloreSync: Device resuming")

    -- Cooldown guard: skip auto-sync if we ran one less than 5 minutes ago.
    -- Exception: if sessions/progress are pending, force a resume sync to avoid
    -- leaving deferred close data queued until a later trigger.
    local totals = self:getPendingSyncTotals()
    local pending_sessions = tonumber(totals and totals.sessions) or 0
    local pending_progress = tonumber(totals and totals.progress) or 0
    local has_pending_resume_critical = (pending_sessions > 0) or (pending_progress > 0)

    local now = os.time()
    local cooldown_active = self.last_auto_sync_time and (now - self.last_auto_sync_time) < 300
    if cooldown_active and not has_pending_resume_critical then
        self:logInfo("BookloreSync: Skipping resume auto-sync (cooldown active, last run",
                     (now - self.last_auto_sync_time), "s ago)")
    else
        self.last_auto_sync_time = now

        if not self.manual_sync_only then
            if cooldown_active and has_pending_resume_critical then
                self:logInfo(
                    "BookloreSync: Cooldown overridden on resume due to pending items",
                    "sessions=", tostring(pending_sessions),
                    "progress=", tostring(pending_progress)
                )
            else
                self:logInfo("BookloreSync: Attempting background sync on resume")
            end

            local function runResumeSyncNow()
                -- Safer ordering on resume: pull first, then push pending.
                -- Avoids uploading stale local progress before reading remote.
                if self.progress_sync_enabled and self.progress_pull_on_resume and self:isNetworkConnected() then
                    self:pullKoreaderProgress(false)
                end

                self:syncPendingSessions(true)

                -- Flag a deferred wake-sync so the shelf can be updated once
                -- the network is fully up. If WiFi is already connected,
                -- schedule it directly; otherwise onNetworkConnected will pick it up.
                if self.auto_sync_shelf_on_resume then
                    self.needs_wake_sync = true
                    if self:isNetworkConnected() then
                        self:logInfo("BookloreSync: WiFi already connected on resume, scheduling delayed wake sync")
                        self:_scheduleWakeSync()
                    end
                end

                self:logInfo("BookloreSync: Checking for unmatched books")
                self:resolveUnmatchedBooks(true)
            end

            if self:isNetworkConnected() then
                runResumeSyncNow()
            else
                self:logInfo("BookloreSync: Resume sync skipped (network disconnected, no connect attempt)")
            end
        end
    end

    if self.ui and self.ui.document then
        self:logInfo("BookloreSync: Book is open, starting new session")
        self:startSession()
    end

    return false
end

--[[--
Schedule a deferred shelf sync 15 seconds after wake.

The delay avoids colliding with KOReader's own post-wake network
activity (DNS, time sync, etc.).  A module-level flag prevents
duplicate timers from stacking up.
--]]
---BookloreSync:_scheduleWakeSync.
function BookloreSync:_scheduleWakeSync()
    if not self.needs_wake_sync then return end
    if self.wake_sync_scheduled then
        self:logInfo("BookloreSync: Wake sync already scheduled, skipping duplicate")
        return
    end

    self.wake_sync_scheduled = true
    self:logInfo("BookloreSync: Scheduling wake sync in 15 seconds")

    UIManager:scheduleIn(15, function()
        self.wake_sync_scheduled = false

        if not self.needs_wake_sync then return end
        if not self.is_enabled then
            self:logInfo("BookloreSync: Wake sync cancelled (plugin disabled)")
            self.needs_wake_sync = false
            return
        end
        if not self:isNetworkConnected() then
            self:logInfo("BookloreSync: Wake sync postponed (network disconnected)")
            return
        end

        self.needs_wake_sync = false
        self:logInfo("BookloreSync: Running delayed wake sync")
        self:syncFromBookloreShelf(true)
    end)
end

--[[--
Handler for when the network becomes available.

If a wake-triggered sync was deferred because WiFi wasn't ready at
resume time, kick it off now that we're connected.
--]]
---BookloreSync:onNetworkConnected.
function BookloreSync:onNetworkConnected()
    if not self.is_enabled then return false end

    -- A network just came up: pick the right host (local vs remote) for
    -- the SSID we landed on before any deferred sync runs.
    pcall(function() self:refreshEffectiveServerUrl() end)

    if self.deferred_close_flush_requested then
        self:logInfo("BookloreSync: Network connected with deferred close flush pending - scheduling")
        self:scheduleDeferredCloseFlush("network_connected")
    end

    if not self.needs_wake_sync then return false end

    self:logInfo("BookloreSync: Network connected with wake sync pending - scheduling")
    self:_scheduleWakeSync()
    return false
end

--[[--
Sync bookmarks for a document to Booklore.

Reads the bookmark list from the live in-memory ReaderBookmark module
(self.ui.bookmark.bookmarks) if available, otherwise falls back to the
on-disk sidecar.  Each bookmark is deduplicated via synced_bookmarks
and queued in pending_bookmarks when offline or no book_id is known.

For EPUB files a full CFI is built from pos0/pos1 when available.
For PDF files a mock CFI anchored to the page number is used.

@param doc_path         string       Full path to the document file
@param book_id          number|nil   Booklore book ID (nil = queue-only mode)
@param document         object|nil   Live CREngine document (for EPUB CFI)
@param doc_settings     table|nil    Live in-memory DocSettings object (fallback when live_bookmarks is absent)
@param live_bookmarks   table|nil    Raw bookmark array from ReaderBookmark.bookmarks
@return integer synced_count, integer queued_count, integer failed_count
--]]
---BookloreSync:syncBookmarks.
function BookloreSync:syncBookmarks(doc_path, book_id, document, doc_settings, live_bookmarks, close_ctx)
    local sync_started_ms = self:getTimingNowMs()
    if not doc_path then
        self:logWarn("BookloreSync: syncBookmarks called without doc_path")
        return 0, 0, 0
    end
    if not self.bookmarks_sync_enabled then
        return 0, 0, 0
    end
    if self.booklore_username == "" or self.booklore_password == "" then
        self:logWarn("BookloreSync: Bookmark sync skipped - credentials not configured")
        return 0, 0, 0
    end

    if close_ctx and type(close_ctx) == "table" then
        doc_path = close_ctx.doc_path or doc_path
        book_id = close_ctx.book_id or book_id
        document = close_ctx.document or document
        doc_settings = close_ctx.doc_settings or doc_settings
        if type(close_ctx.live_bookmarks) == "table" then
            live_bookmarks = close_ctx.live_bookmarks
        end
    end

    local queue_only = (book_id == nil) or self.manual_sync_only

    -- Resolve bookmark list: live module → live doc_settings → on-disk sidecar
    local bookmarks
    if live_bookmarks and type(live_bookmarks) == "table" and #live_bookmarks > 0 then
        bookmarks = live_bookmarks
        self:logInfo(string.format("BookloreSync: Bookmarks from live ReaderBookmark module (%d)", #bookmarks))
    else
        -- Try live doc_settings first (avoids I/O), fall back to opening sidecar
        -- directly if doc_settings doesn't have the bookmarks key populated.
        if doc_settings then
            bookmarks = self.metadata_extractor:getBookmarksFromDocSettings(doc_settings)
            if #bookmarks > 0 then
                self:logInfo(string.format("BookloreSync: Bookmarks from live in-memory doc_settings (%d)", #bookmarks))
            else
                self:logInfo("BookloreSync: doc_settings had no bookmarks - falling back to on-disk sidecar")
                bookmarks = self.metadata_extractor:getBookmarks(doc_path)
                self:logInfo(string.format("BookloreSync: Bookmarks from on-disk sidecar (%d)", #bookmarks))
            end
        else
            bookmarks = self.metadata_extractor:getBookmarks(doc_path)
            self:logInfo(string.format("BookloreSync: Bookmarks from on-disk sidecar (%d)", #bookmarks))
        end
    end

    if not bookmarks or #bookmarks == 0 then
        self:logInfo("BookloreSync: No bookmarks found for:", doc_path)
        return 0, 0, 0
    end

    local session_started_at = close_ctx and tonumber(close_ctx.session_started_at) or nil
    local filtered_bookmarks, skipped_pre_session = self:filterEntriesBySessionStart(bookmarks, session_started_at)
    if skipped_pre_session > 0 then
        self:logInfo(
            "BookloreSync: Session-window filter applied",
            "component=bookmarks",
            "session_started_at=", tostring(session_started_at),
            "skipped=", tostring(skipped_pre_session),
            "kept=", tostring(#filtered_bookmarks)
        )
    end
    bookmarks = filtered_bookmarks
    if #bookmarks == 0 then
        self:logInfo(
            "BookloreSync: No-op skipped",
            "component=bookmarks",
            "reason=no_entries_in_session_window",
            "path=", tostring(doc_path or "")
        )
        return 0, 0, 0
    end

    -- Build EPUB spine map for CFI resolution
    local spine = nil
    local html_cache = {}
    local is_epub = doc_path:lower():match("%.epub$") ~= nil
    local is_pdf  = doc_path:lower():match("%.pdf$")  ~= nil
    local epub_ctx = close_ctx and close_ctx.epub_context or nil
    if is_epub and document then
        if not epub_ctx then
            epub_ctx = self:getOrBuildEpubContext(document, doc_path)
        end
        spine = epub_ctx and epub_ctx.spine_map or nil
        if not spine then
            self:logWarn("BookloreSync: Could not build EPUB spine map for bookmarks - will skip EPUB CFI")
        end
    end

    -- Ensure book_cache_id
    local book_cache_id = close_ctx and close_ctx.book_cache_id or nil
    local used_close_ctx = close_ctx and close_ctx.doc_path == doc_path
    if used_close_ctx then
        self:logInfo("BookloreSync: syncBookmarks using shared close context", "path=", tostring(doc_path))
    end
    if not book_cache_id then
        book_cache_id = self.db:getBookCacheIdByFilePath(doc_path)
    end
    if not book_cache_id then
        self.db:saveBookCache(doc_path, "", nil, nil, nil, nil, nil)
        book_cache_id = self.db:getBookCacheIdByFilePath(doc_path)
    end
    if not book_cache_id then
        self:logWarn("BookloreSync: Could not obtain book_cache_id for bookmark sync")
        return 0, 0, 0
    end
    if close_ctx and close_ctx.doc_path == doc_path then
        close_ctx.book_cache_id = book_cache_id
    end

    local current_bookmarks_fp = self:computeBookmarksFingerprint(bookmarks)
    local pending_bm_count = tonumber(self.db:getPendingBookmarkCountForBook(book_cache_id)) or 0
    local should_skip_noop, skip_reason = self:shouldSkipNoopSync("bookmarks", book_cache_id, current_bookmarks_fp, pending_bm_count)
    if should_skip_noop then
        local elapsed_ms = self:getTimingNowMs() - sync_started_ms
        self:logInfo(
            "BookloreSync: No-op skipped",
            "component=bookmarks",
            "reason=", tostring(skip_reason),
            "book_cache_id=", tostring(book_cache_id),
            "path=", tostring(doc_path or ""),
            "syncBookmarks_total_ms=", tostring(elapsed_ms)
        )
        return 0, 0, 0
    end
    self:logInfo(
        "BookloreSync: No-op marker bypass",
        "component=bookmarks",
        "reason=", tostring(skip_reason),
        "book_cache_id=", tostring(book_cache_id)
    )

    local synced_count  = 0
    local queued_count  = 0
    local failed_count  = 0

    for _, bm in ipairs(bookmarks) do
        local datetime = bm.datetime or ""
        if datetime == "" then
            self:logWarn("BookloreSync: Skipping bookmark with no datetime")
            goto bm_continue
        end

        -- Deduplicate
        if self.db:isBookmarkSynced(book_cache_id, datetime) then
            self:logInfo("BookloreSync: Bookmark already synced, skipping:", datetime)
            goto bm_continue
        end

        local bm_ok, bm_err = pcall(function()
            -- Resolve CFI
            local cfi
            if is_epub and spine and bm.pos0 and bm.pos1 then
                cfi = self:buildCfi(bm.pos0, bm.pos1, spine, document, html_cache)
            elseif is_epub and spine and bm.pos0 then
                -- Single-position bookmark: use pos0 for both endpoints
                cfi = self:buildCfi(bm.pos0, bm.pos0, spine, document, html_cache)
            elseif is_pdf and bm.page then
                cfi = self:buildMockPdfCfi(bm.page)
            end

            if not cfi and is_epub and bm.page then
                cfi = self:buildMockPdfCfi(bm.page)
                self:logWarn("BookloreSync: Falling back to page-based CFI for bookmark at", tostring(datetime), "page", tostring(bm.page))
            end

            if not cfi then
                self:logInfo("BookloreSync: No CFI for bookmark at:", datetime, "- queuing without CFI")
                -- Queue with a page-based fallback so it can be retried later
                local pending_payload = json.encode({
                    datetime      = datetime,
                    page          = bm.page,
                    notes         = bm.notes,
                    chapter       = bm.chapter,
                    pos0          = bm.pos0,
                    pos1          = bm.pos1,
                })
                self.db:addPendingBookmark(book_cache_id, book_id, datetime, pending_payload)
                failed_count = failed_count + 1
                return
            end

            local opts = {
                title = bm.chapter,
            }

            if queue_only then
                local pending_payload = json.encode({
                    datetime = datetime,
                    cfi      = cfi,
                    page     = bm.page,
                    notes    = bm.notes,
                    chapter  = bm.chapter,
                    pos0     = bm.pos0,
                    pos1     = bm.pos1,
                })
                self.db:addPendingBookmark(book_cache_id, book_id, datetime, pending_payload)
                if self.manual_sync_only then
                    queued_count = queued_count + 1
                else
                    failed_count = failed_count + 1
                end
                return
            end

            local ok, server_id = self.api:submitBookmark(
                book_id, cfi, opts,
                self.booklore_username, self.booklore_password
            )

            if ok then
                self.db:markBookmarkSynced(book_cache_id, datetime, server_id)
                synced_count = synced_count + 1
            else
                self:logWarn("BookloreSync: Failed to sync bookmark at:", datetime, "-", server_id)
                failed_count = failed_count + 1
                local pending_payload = json.encode({
                    datetime = datetime,
                    cfi      = cfi,
                    page     = bm.page,
                    notes    = bm.notes,
                    chapter  = bm.chapter,
                    pos0     = bm.pos0,
                    pos1     = bm.pos1,
                })
                self.db:addPendingBookmark(book_cache_id, book_id, datetime, pending_payload)
            end
        end)

        if not bm_ok then
            self:logErr("BookloreSync: Unexpected error processing bookmark at:", datetime, "-", bm_err)
            failed_count = failed_count + 1
        end

        ::bm_continue::
    end

    self:logInfo(string.format(
        "BookloreSync: Bookmark sync complete - synced=%d queued=%d failed=%d",
        synced_count, queued_count, failed_count
    ))
    local elapsed_ms = self:getTimingNowMs() - sync_started_ms
    self:logInfo("BookloreSync: syncBookmarks_total_ms=", tostring(elapsed_ms), "path=", tostring(doc_path))

    self:updateNoopSyncMarker("bookmarks", book_cache_id, current_bookmarks_fp, failed_count, queued_count, queue_only)

    return synced_count, queued_count, failed_count
end

--[[--
Retry all pending bookmarks from the pending_bookmarks queue.

@param silent         boolean     Suppress UI feedback (default false)
@param book_cache_id  integer|nil If set, only process rows for this book_cache_id
@return integer synced_count, integer failed_count
--]]
---BookloreSync:syncPendingBookmarks.
function BookloreSync:syncPendingBookmarks(silent, book_cache_id)
    return PendingSyncModule.syncPendingBookmarks(self, silent, book_cache_id)
end

--[[--
Detect a sensible default download directory for the current device.

Resolution order:
  1. KOReader's configured home directory (G_reader_settings "home_dir")
  2. Device.home_dir (set by KOReader at startup for the current platform)
  3. /mnt/onboard/Books  - Kobo internal storage
  4. /sdcard/Books       - Android
  5. /Books              - generic fallback

The result is always a "Books" subdirectory so downloaded shelf files
don't litter the root of the user's home.

@return string  Absolute path (directory may not yet exist)
--]]
---BookloreSync:_detectDefaultDownloadDir.
function BookloreSync:_detectDefaultDownloadDir()
    return ShelfSyncModule.detectDefaultDownloadDir(self)
end

--[[--
Download all books from the configured Booklore shelf into `download_dir`.

This is the "pull" side of two-way shelf sync.  On the "push" side, books
deleted locally are removed from the shelf via notifyBookloreOnDeletion.

New books on the shelf are downloaded; books already present locally are
skipped (their cache entry is created/updated if missing).

When `delete_removed_shelf_books` is true, local files in `download_dir`
whose BookID is no longer on the shelf are deleted.

@param silent boolean  Suppress UI messages (default: auto from context)
@param on_complete function|nil  Optional callback(success, message)
--]]
---BookloreSync:syncFromBookloreShelf.
function BookloreSync:syncFromBookloreShelf(silent, on_complete)
    return ShelfSyncModule.syncFromBookloreShelf(self, silent, on_complete)
end

--[[--
Generate a filename for a shelf book download.

Uses the book title as the filename, sanitized of filesystem-unsafe characters
and truncated so the full filename (including extension) is at most 150 chars.
Falls back to "BookID_{id}.{extension}" when no usable title is available.

@param book table  Book object from Booklore API
@return string
--]]
---BookloreSync:_generateFilename.
function BookloreSync:_generateFilename(book)
    return ShelfSyncModule.generateFilename(self, book)
end

--[[--
Called from the patched FileManager.deleteFile / deleteSelectedFiles so we can
read the file contents (to compute the hash) while the file still exists.

Supported formats: EPUB, PDF, CBZ, CBR.  Other formats are ignored.

@param filepath string  Full path to the file about to be deleted
@return hash string|nil, stem string|nil, book_id number|nil
--]]
---BookloreSync:preDeleteHook.
function BookloreSync:preDeleteHook(filepath)
    return DeletionModule.preDeleteHook(self, filepath)
end

--[[--
Notify Booklore that a book has been deleted locally.

Unassigns the book from the configured Booklore shelf via
POST /api/v1/books/shelves with shelvesToUnassign=[shelf_id].
The book record itself is NOT deleted from Booklore.

If offline or the server is unreachable the operation is queued in
pending_deletions and retried on the next syncPendingSessions() run.

All errors are swallowed so a network failure never surfaces as a user-
visible error during file deletion.

@param hash           string      MD5 hash of the deleted file
@param stem           string      Filename stem (used for title-based fallback search)
@param cached_book_id number|nil  Booklore book ID if known
@param from_queue     boolean     True when called from syncPendingDeletions (skip re-queue on failure)
--]]
---BookloreSync:notifyBookloreOnDeletion.
function BookloreSync:notifyBookloreOnDeletion(hash, stem, cached_book_id, from_queue)
    return DeletionModule.notifyBookloreOnDeletion(self, hash, stem, cached_book_id, from_queue)
end

--[[--
Retry all pending shelf-unassignments from the pending_deletions queue.

Called automatically during syncPendingSessions() as Phase 2c.
Each entry unassigns the book from the configured shelf via
POST /api/v1/books/shelves.  The book record itself is NOT deleted.
Entries retried more than 10 times are dropped.

@param silent boolean  Suppress UI feedback (default false)
@return integer synced_count, integer failed_count
--]]
---BookloreSync:syncPendingDeletions.
function BookloreSync:syncPendingDeletions(silent)
    return PendingSyncModule.syncPendingDeletions(self, silent)
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
---BookloreSync:syncPendingRatings.
function BookloreSync:syncPendingRatings(silent)
    return PendingSyncModule.syncPendingRatings(self, silent)
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

@param silent         boolean   If true, do not show UI messages
@param book_cache_id  integer|nil  If set, only process rows for this book_cache_id
@return integer synced_count
@return integer failed_count
--]]
---BookloreSync:syncPendingAnnotations.
function BookloreSync:syncPendingAnnotations(silent, book_cache_id)
    return PendingSyncModule.syncPendingAnnotations(self, silent, book_cache_id)
end

--[[--
Re-match all books in the cache after a library re-creation.

Resets the Booklore book_id on every book in book_cache (and all linked
pending items) to NULL, then immediately calls resolveUnmatchedBooks() to
re-resolve them from the server.  This is the correct recovery action when
the user has wiped and re-created their Booklore library so that all book IDs
have changed.
--]]
---BookloreSync:rematchAllBooksInCache.
function BookloreSync:rematchAllBooksInCache()
    if not self.db then return end
    UIManager:show(ConfirmBox:new{
        text = _("This will reset all stored book IDs and re-resolve them from the server.\n\nRun this when you re-created the library and all IDs have changed.\n\nContinue?"),
        ok_text = _("Reset & Re-match"),
        cancel_text = _("Cancel"),
        ok_callback = function()
            local ok = self.db:resetAllBookIds()
            if not ok then
                UIManager:show(InfoMessage:new{
                    text = _("Failed to reset book IDs. Check logs."),
                    timeout = 3,
                })
                return
            end
            UIManager:show(InfoMessage:new{
                text = _("All book IDs reset. Resolving from server..."),
                timeout = 2,
            })
            UIManager:scheduleIn(0.5, function()
                self:_requestWifi(_("re-match all books in cache"), function()
                    self:resolveUnmatchedBooks(false)
                end, function()
                    self:showWifiUnavailableInfo(
                        _("WiFi not enabled. Books will be re-matched on next sync."),
                        _("Airplane mode is enabled. Books will be re-matched on next sync."),
                        3
                    )
                end)
            end)
        end,
    })
end

--[[--
Re-fetch metadata for cached books that are already matched.

This updates cached server metadata (for example server pagecount) without
resetting existing matches.
--]]
---BookloreSync:resyncStoredMetadata.
function BookloreSync:resyncStoredMetadata()
    if not self.db then
        return
    end

    UIManager:show(ConfirmBox:new{
        text = _("This will re-fetch metadata for all matched cached books from the server.\n\nUse this to refresh stored metadata such as server pagecount.\n\nContinue?"),
        ok_text = _("Re-sync Metadata"),
        cancel_text = _("Cancel"),
        ok_callback = function()
            self:_requestWifi(_("re-sync stored metadata"), function()
                self:_runStoredMetadataResync()
            end, function()
                self:showWifiUnavailableInfo(
                    _("WiFi not enabled. Metadata refresh skipped."),
                    _("Airplane mode is enabled. Metadata refresh skipped."),
                    3
                )
            end, {
                disable_wifi_when_done = true,
            })
        end,
    })
end

---BookloreSync:_runStoredMetadataResync.
function BookloreSync:_runStoredMetadataResync()
    if not self.db then
        return
    end

    self:refreshEffectiveServerUrl()
    self.api:init(self.server_url, self.username, self.password, self.db)

    local books = self.db:getAllCachedBooks() or {}
    local total_matched = 0
    local refreshed = 0
    local failed = 0

    for _, book in ipairs(books) do
        local existing_book_id = tonumber(book.book_id)
        if existing_book_id and existing_book_id > 0 and book.file_hash and book.file_hash ~= "" then
            total_matched = total_matched + 1

            local resolved_book_id, isbn10, isbn13, server_pagecount = self:getBookIdByHash(book.file_hash)
            if resolved_book_id then
                local ok = self.db:saveBookCache(
                    book.file_path,
                    book.file_hash,
                    resolved_book_id,
                    book.title,
                    book.author,
                    isbn10,
                    isbn13,
                    server_pagecount
                )
                if ok then
                    refreshed = refreshed + 1
                else
                    failed = failed + 1
                end
            else
                failed = failed + 1
            end
        end
    end

    if total_matched == 0 then
        UIManager:show(InfoMessage:new{
            text = _("No matched cached books found."),
            timeout = 2,
        })
        return
    end

    UIManager:show(InfoMessage:new{
        text = T(_("Metadata refresh complete: %1 updated, %2 failed."), refreshed, failed),
        timeout = 3,
    })
end

--[[--
Show a toggle-selection dialog for clearing synced history records.

Presents toggleable rows for Historical Sessions, Synced Annotations,
Synced Bookmarks, and Rating Sync History.  Only rows whose table is
non-empty are shown.  When the user confirms, the selected data types
are deleted from the database and a summary InfoMessage is shown.
--]]
---BookloreSync:showClearAdvancedDialog.
function BookloreSync:showClearAdvancedDialog()
    if not self.db then return end

    local hs_count = tonumber(self.db:getHistoricalSessionCount())  or 0
    local sa_count = tonumber(self.db:getSyncedAnnotationCount())   or 0
    local sb_count = tonumber(self.db:getSyncedBookmarkCount())     or 0
    local rh_count = tonumber(self.db:getRatingSyncHistoryCount())  or 0
    local sp_count = tonumber(self.db:getSyncedKoreaderProgressCount()) or 0

    if (hs_count + sa_count + sb_count + rh_count + sp_count) == 0 then
        UIManager:show(InfoMessage:new{
            text = _("Nothing to clear"),
            timeout = 2,
        })
        return
    end

    local sel = {
        historical  = hs_count > 0,
        annotations = sa_count > 0,
        bookmarks   = sb_count > 0,
        ratings     = rh_count > 0,
        progress    = sp_count > 0,
    }

    local dialog
    ---buildDialog.
    local function buildDialog()
        ---toggle_label.
        local function toggle_label(active, label, count)
            local check = active and "[x]" or "[ ]"
            return T(_("%1 %2 (%3)"), check, label, count)
        end

        local any_selected = sel.historical or sel.annotations or sel.bookmarks or sel.ratings or sel.progress

        local buttons = {}

        if hs_count > 0 then
            table.insert(buttons, {{
                text = toggle_label(sel.historical, _("Historical Sessions"), hs_count),
                callback = function()
                    sel.historical = not sel.historical
                    UIManager:close(dialog)
                    dialog = buildDialog()
                    UIManager:show(dialog)
                end,
            }})
        end

        if sa_count > 0 then
            table.insert(buttons, {{
                text = toggle_label(sel.annotations, _("Synced Annotations"), sa_count),
                callback = function()
                    sel.annotations = not sel.annotations
                    UIManager:close(dialog)
                    dialog = buildDialog()
                    UIManager:show(dialog)
                end,
            }})
        end

        if sb_count > 0 then
            table.insert(buttons, {{
                text = toggle_label(sel.bookmarks, _("Synced Bookmarks"), sb_count),
                callback = function()
                    sel.bookmarks = not sel.bookmarks
                    UIManager:close(dialog)
                    dialog = buildDialog()
                    UIManager:show(dialog)
                end,
            }})
        end

        if rh_count > 0 then
            table.insert(buttons, {{
                text = toggle_label(sel.ratings, _("Rating Sync History"), rh_count),
                callback = function()
                    sel.ratings = not sel.ratings
                    UIManager:close(dialog)
                    dialog = buildDialog()
                    UIManager:show(dialog)
                end,
            }})
        end

        if sp_count > 0 then
            table.insert(buttons, {{
                text = toggle_label(sel.progress, _("Synced Progress"), sp_count),
                callback = function()
                    sel.progress = not sel.progress
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
                    if sel.historical  then self.db:clearHistoricalSessions(); table.insert(cleared, _("Historical Sessions"))  end
                    if sel.annotations then self.db:clearSyncedAnnotations();  table.insert(cleared, _("Synced Annotations"))   end
                    if sel.bookmarks   then self.db:clearSyncedBookmarks();    table.insert(cleared, _("Synced Bookmarks"))     end
                    if sel.ratings     then self.db:clearRatingSyncHistory();  table.insert(cleared, _("Rating Sync History"))  end
                    if sel.progress    then self.db:clearSyncedKoreaderProgress(); table.insert(cleared, _("Synced Progress")) end
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
            title = _("Clear Synced History"),
            buttons = buttons,
        }
    end

    dialog = buildDialog()
    UIManager:show(dialog)
end

--[[--
Show a toggle-selection dialog for clearing pending items.

Presents three toggleable rows (Sessions, Annotations, Ratings), each
showing its current queue count.  After the user confirms, all selected
types are deleted from the database and a summary InfoMessage is shown.
--]]
---BookloreSync:showClearPendingDialog.
function BookloreSync:showClearPendingDialog()
    if not self.db then return end

    local s_count = tonumber(self.db:getPendingSessionCount())    or 0
    local a_count = tonumber(self.db:getPendingAnnotationCount()) or 0
    local r_count = tonumber(self.db:getPendingRatingCount())     or 0
    local b_count = tonumber(self.db:getPendingBookmarkCount())   or 0
    local p_count = tonumber(self.db:getPendingKoreaderProgressCount()) or 0

    local sel = {
        sessions    = s_count > 0,
        annotations = a_count > 0,
        ratings     = r_count > 0,
        bookmarks   = b_count > 0,
        progress    = p_count > 0,
    }

    local dialog
    ---buildDialog.
    local function buildDialog()
        ---toggle_label.
        local function toggle_label(active, label, count)
            local check = active and "[x]" or "[ ]"
            return T(_("%1 %2 (%3)"), check, label, count)
        end

        local any_selected = sel.sessions or sel.annotations or sel.ratings or sel.bookmarks or sel.progress

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

        if b_count > 0 then
            table.insert(buttons, {{
                text = toggle_label(sel.bookmarks, _("Bookmarks"), b_count),
                callback = function()
                    sel.bookmarks = not sel.bookmarks
                    UIManager:close(dialog)
                    dialog = buildDialog()
                    UIManager:show(dialog)
                end,
            }})
        end

        if p_count > 0 then
            table.insert(buttons, {{
                text = toggle_label(sel.progress, _("Progress"), p_count),
                callback = function()
                    sel.progress = not sel.progress
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
                    if sel.bookmarks   then self.db:clearPendingBookmarks();   table.insert(cleared, _("Bookmarks"))   end
                    if sel.progress    then self.db:clearPendingKoreaderProgress(); table.insert(cleared, _("Progress")) end
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

--[[--
Upload pending KOReader progress rows.

Each row is sent to /api/koreader/syncs/progress as the latest state for the
book hash. On success we archive the synced state and delete the pending row.
On failure we increment retry_count and keep it queued.

@param silent boolean
@return integer synced_count, integer failed_count
--]]
---BookloreSync:syncPendingKoreaderProgress.
function BookloreSync:syncPendingKoreaderProgress(silent, max_rows)
    return PendingSyncModule.syncPendingKoreaderProgress(self, silent, max_rows)
end

---BookloreSync:syncPendingSessions.
function BookloreSync:syncPendingSessions(silent)
    return PendingSyncModule.syncPendingSessions(self, silent)
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

---BookloreSync:_startBookCacheMatching.
function BookloreSync:_startBookCacheMatching()
    return MatchingModule._startBookCacheMatching(self)
end

---BookloreSync:_showNextBookCacheMatch.
function BookloreSync:_showNextBookCacheMatch()
    return MatchingModule._showNextBookCacheMatch(self)
end

--[[--
Save a manually confirmed book_cache match and trigger a pending-items sync.

Writes the resolved book_id (and ISBNs) back into book_cache, then kicks off
syncPendingSessions so that any annotations / ratings / sessions that were
queued while the book was unmatched are uploaded immediately.
--]]
---BookloreSync:_saveBookCacheMatch.
function BookloreSync:_saveBookCacheMatch(book, selected_result)
    return MatchingModule._saveBookCacheMatch(self, book, selected_result)
end

--[[--
Resolve book IDs for cached books that don't have them yet
Queries the server for books cached while offline
@param silent boolean Don't show UI messages if true
--]]
---BookloreSync:resolveUnmatchedBooks.
function BookloreSync:resolveUnmatchedBooks(silent)
    silent = silent or false
    
    if not self.db then
        self:logErr("BookloreSync: Database not initialized")
        return
    end
    
    if not self:isNetworkConnected() then
        self:logInfo("BookloreSync: No network connection, skipping book resolution")
        return
    end
    
    local unmatched_books = self.db:getAllUnmatchedBooks() or {}

    if #unmatched_books == 0 then
        self:logInfo("BookloreSync: No unmatched books to resolve")
        return
    end
    
    self:logInfo("BookloreSync: Resolving", #unmatched_books, "unmatched books")
    
    self.api:init(self.server_url, self.username, self.password, self.db)
    
    local resolved_count = 0
    
    for _, book in ipairs(unmatched_books) do
        if book.file_hash and book.file_hash ~= "" then
            self:logInfo("BookloreSync: Resolving book:", book.file_path)
            
            local book_id, isbn10, isbn13, server_pagecount = self:getBookIdByHash(book.file_hash)
            
            if book_id then
                self:logInfo("BookloreSync: Resolved book ID:", book_id)
                self.db:saveBookCache(
                    book.file_path,
                    book.file_hash,
                    book_id,
                    book.title,
                    book.author,
                    isbn10,
                    isbn13,
                    server_pagecount
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

---BookloreSync:copySessionsFromKOReader.
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

---BookloreSync:_extractHistoricalSessions.
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

---BookloreSync:_calculateSessionsFromPageStats.
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
        else
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
        end
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

---BookloreSync:_findKOReaderStatisticsDB.
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

---BookloreSync:_getKOReaderBooks.
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

---BookloreSync:_getKOReaderBookByHash.
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

---BookloreSync:_getPageStats.
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

---BookloreSync:_unixToISO8601.
function BookloreSync:_unixToISO8601(timestamp)
    local date_table = os.date("!*t", timestamp)
    return string.format("%04d-%02d-%02dT%02d:%02d:%02dZ",
        date_table.year, date_table.month, date_table.day,
        date_table.hour, date_table.min, date_table.sec)
end

---BookloreSync:_parseISO8601.
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

---BookloreSync:_detectBookType.
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

---BookloreSync:_formatDuration.
function BookloreSync:_formatDuration(seconds)
    local parts = {}
    
    local hours = math.floor(seconds / 3600)
    local mins = math.floor((seconds % 3600) / 60)
    local secs = seconds % 60
    
    if hours > 0 then
        table.insert(parts, T(_("%1h"), hours))
    end
    if mins > 0 then
        table.insert(parts, T(_("%1m"), mins))
    end
    if secs > 0 or #parts == 0 then  -- Always show seconds if duration is 0
        table.insert(parts, T(_("%1s"), secs))
    end
    
    return table.concat(parts, " ")
end

--[[--
Group sessions by book_id for batch upload

@param sessions Array of session objects
@return table Grouped sessions { book_id = {book_type = ..., sessions = {...}} }
--]]
---BookloreSync:_groupSessionsByBook.
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
---BookloreSync:_submitSingleSession.
function BookloreSync:_submitSingleSession(session)
    local start_progress = session.start_progress or 0
    local end_progress = session.end_progress or 0
    local progress_delta = session.progress_delta or (end_progress - start_progress)
    
    local duration_formatted = self:_formatDuration(session.duration_seconds or 0)
    
    local start_location = session.start_location
    local end_location = session.end_location
    if self.progress_sync_normalize_session_locations then
        local server_pagecount = self:getServerPagecountForSession(session)
        start_location = self:normalizeSessionLocationWithFallback(
            session.start_location,
            session.koreader_pagecount,
            server_pagecount,
            start_progress
        )
        end_location = self:normalizeSessionLocationWithFallback(
            session.end_location,
            session.koreader_pagecount,
            server_pagecount,
            end_progress
        )
    end

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
        startLocation = start_location,
        endLocation = end_location,
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
---BookloreSync:_uploadSessionsWithBatching.
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
            
            local start_location = session.start_location
            local end_location = session.end_location
            if self.progress_sync_normalize_session_locations then
                local server_pagecount = self:getServerPagecountForSession(session)
                start_location = self:normalizeSessionLocationWithFallback(
                    session.start_location,
                    session.koreader_pagecount,
                    server_pagecount,
                    start_progress
                )
                end_location = self:normalizeSessionLocationWithFallback(
                    session.end_location,
                    session.koreader_pagecount,
                    server_pagecount,
                    end_progress
                )
            end

            table.insert(batch_sessions, {
                startTime = session.start_time,
                endTime = session.end_time,
                durationSeconds = session.duration_seconds,
                durationFormatted = self:_formatDuration(session.duration_seconds or 0),
                startProgress = self:roundProgress(start_progress),
                endProgress = self:roundProgress(end_progress),
                progressDelta = self:roundProgress(progress_delta),
                startLocation = start_location,
                endLocation = end_location,
            })
        end
        
        -- Try batch upload
        self:logInfo("BookloreSync: Attempting batch", batch_num, "of", batch_count, "with", (end_idx - start_idx + 1), "sessions for booklore_book_id:", book_id)
        local success, message, code = self.api:submitSessionBatch(book_id, book_type, batch_sessions)
        self:logInfo("BookloreSync: Batch", batch_num, "result - booklore_book_id:", book_id, "success:", tostring(success), "code:", tostring(code or "nil"), "message:", tostring(message or "nil"))
        
        if success then
            for i = start_idx, end_idx do
                self.db:markHistoricalSessionSynced(sessions[i].id)
                synced_count = synced_count + 1
            end
            self:logInfo("BookloreSync: Batch", batch_num, "of", batch_count, "uploaded successfully (" .. (end_idx - start_idx + 1) .. " sessions) for booklore_book_id:", book_id)
        elseif code == 404 then
            -- Server doesn't have batch endpoint OR book not found; fallback to
            -- individual upload to determine which
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
                       "booklore_book_id:", book_id, "(" .. (end_idx - start_idx + 1) .. " sessions) - Error:", message, "Code:", tostring(code or "nil"))
            failed_count = failed_count + (end_idx - start_idx + 1)
        end
    end
    
    return synced_count, failed_count, not_found_count
end

---BookloreSync:matchHistoricalData.
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

---BookloreSync:_autoSyncMatchedSessions.
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

---BookloreSync:_syncNextMatchedBook.
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

---BookloreSync:_startManualMatching.
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

---BookloreSync:_showNextBookMatch.
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
                self:logInfo("BookloreSync: Hash match found for:", book.koreader_book_title, "-> Booklore:", server_book.title, "(auto-accepting)")
                self:_saveMatchAndSync(book, server_book)
                return
            end
        end
    end
    
    -- PRIORITY 4: Fall back to title search
    self:_performManualSearch(book)
end

---BookloreSync:_confirmAutoMatch.
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

---BookloreSync:_confirmIsbnMatch.
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

---BookloreSync:_performManualSearch.
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

---BookloreSync:_showMatchSelectionDialog.
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

---BookloreSync:_saveMatchAndSync.
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

---BookloreSync:_syncHistoricalSessions.
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

---BookloreSync:viewMatchStatistics.
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

---BookloreSync:resyncHistoricalData.
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

---BookloreSync:_performResyncHistoricalData.
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

---BookloreSync:syncRematchedSessions.
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
Manual Matching - iterate over all unmatched books one by one.

For each unmatched book an InputDialog is shown pre-filled with the book's
cached title. The user can edit the term or enter a numeric Booklore ID.
Submitting a pure integer fetches the book by ID and saves immediately;
submitting text searches by title and shows a selection dialog.
--]]
---BookloreSync:manualMatching.
function BookloreSync:manualMatching()
    if not self.db then
        UIManager:show(InfoMessage:new{ text = _("Booklore: database not initialised") })
        return
    end
    if self.booklore_username == "" or self.booklore_password == "" then
        UIManager:show(InfoMessage:new{ text = _("Booklore: credentials not configured") })
        return
    end

    if not self:isNetworkConnected() then
        self:_requestWifi(_("manual matching"), function()
            self:manualMatching()
        end, function()
            self:showWifiUnavailableInfo(
                _("WiFi not enabled - manual matching skipped"),
                _("Airplane mode is enabled - manual matching skipped")
            )
        end)
        return
    end

    local unmatched = self.db:getAllUnmatchedBooks()
    if not unmatched or #unmatched == 0 then
        UIManager:show(InfoMessage:new{
            text = _("Booklore: no unmatched books found"),
            timeout = 2,
        })
        return
    end

    self.api:init(self.server_url, self.username, self.password, self.db)
    self.bk_matching_index  = 1
    self.bk_unmatched_books = unmatched
    self:_showManualMatchDialog(unmatched[1])
end

--[[--
Internal: show an InputDialog for a single unmatched book, then search or
fetch by ID and let the user confirm the match.  On success, advances the
iterator and recurses for the next unmatched book.

@param book  table  Row from getAllUnmatchedBooks()
--]]
---BookloreSync:_showManualMatchDialog.
function BookloreSync:_showManualMatchDialog(book)
    local default_term = (book.title and book.title ~= "") and book.title
                         or book.file_path:match("([^/]+)$") or ""
    local total   = self.bk_unmatched_books and #self.bk_unmatched_books or 1
    local current = self.bk_matching_index or 1
    local progress = T(_("Book %1 of %2"), current, total)

    local input_dialog
    input_dialog = InputDialog:new{
        title       = T(_("Match book (%1)\n%2"), progress, default_term),
        description = _("Enter Title / BookLore ID"),
        input       = default_term,
        buttons = {
            {
                {
                    text = _("Cancel"),
                    callback = function()
                        UIManager:close(input_dialog)
                        self.bk_unmatched_books = nil
                        self.bk_matching_index  = nil
                    end,
                },
                {
                    text = _("Skip"),
                    callback = function()
                        UIManager:close(input_dialog)
                        self.bk_matching_index = (self.bk_matching_index or 1) + 1
                        if self.bk_unmatched_books and
                           self.bk_matching_index <= #self.bk_unmatched_books then
                            self:_showManualMatchDialog(
                                self.bk_unmatched_books[self.bk_matching_index])
                        else
                            UIManager:show(InfoMessage:new{
                                text    = _("Booklore: manual matching complete"),
                                timeout = 2,
                            })
                            self.bk_unmatched_books = nil
                            self.bk_matching_index  = nil
                        end
                    end,
                },
                {
                    text             = _("Search"),
                    is_enter_default = true,
                    callback         = function()
                        local term = input_dialog:getInputText()
                        UIManager:close(input_dialog)
                        if not term or term == "" then return end

                        -- Pure integer → fetch by ID
                        if term:match("^%d+$") then
                            local id = tonumber(term)
                            local ok, result = self.api:getBookById(
                                id, self.booklore_username, self.booklore_password)
                            if not ok or not result then
                                UIManager:show(ConfirmBox:new{
                                    text        = T(_("Booklore: no book found with ID %1.\nRetry?"), id),
                                    ok_text     = _("Retry"),
                                    cancel_text = _("Skip"),
                                    ok_callback = function()
                                        self:_showManualMatchDialog(book)
                                    end,
                                    cancel_callback = function()
                                        self.bk_matching_index = (self.bk_matching_index or 1) + 1
                                        if self.bk_unmatched_books and
                                           self.bk_matching_index <= #self.bk_unmatched_books then
                                            self:_showManualMatchDialog(
                                                self.bk_unmatched_books[self.bk_matching_index])
                                        else
                                            UIManager:show(InfoMessage:new{
                                                text    = _("Booklore: manual matching complete"),
                                                timeout = 2,
                                            })
                                            self.bk_unmatched_books = nil
                                            self.bk_matching_index  = nil
                                        end
                                    end,
                                })
                                return
                            end
                            -- Save immediately (no confirm for ID path)
                            self:_saveBookCacheMatch(book, result)
                            self.bk_matching_index = (self.bk_matching_index or 1) + 1
                            if self.bk_unmatched_books and
                               self.bk_matching_index <= #self.bk_unmatched_books then
                                self:_showManualMatchDialog(
                                    self.bk_unmatched_books[self.bk_matching_index])
                            else
                                UIManager:show(InfoMessage:new{
                                    text    = _("Booklore: manual matching complete"),
                                    timeout = 2,
                                })
                                self.bk_unmatched_books = nil
                                self.bk_matching_index  = nil
                            end
                            return
                        end

                        -- Text → search by title
                        local ok, results = self.api:searchBooksWithAuth(
                            term, self.booklore_username, self.booklore_password)
                        if not ok then
                            local err = type(results) == "string" and results or _("Unknown error")
                            UIManager:show(ConfirmBox:new{
                                text        = T(_("Booklore: search failed: %1\nRetry?"), err),
                                ok_text     = _("Retry"),
                                cancel_text = _("Skip"),
                                ok_callback = function()
                                    self:_showManualMatchDialog(book)
                                end,
                                cancel_callback = function()
                                    self.bk_matching_index = (self.bk_matching_index or 1) + 1
                                    if self.bk_unmatched_books and
                                       self.bk_matching_index <= #self.bk_unmatched_books then
                                        self:_showManualMatchDialog(
                                            self.bk_unmatched_books[self.bk_matching_index])
                                    else
                                        UIManager:show(InfoMessage:new{
                                            text    = _("Booklore: manual matching complete"),
                                            timeout = 2,
                                        })
                                        self.bk_unmatched_books = nil
                                        self.bk_matching_index  = nil
                                    end
                                end,
                            })
                            return
                        end
                        if not results or #results == 0 then
                            UIManager:show(ConfirmBox:new{
                                text        = T(_("Booklore: no results for:\n%1\nRetry?"), term),
                                ok_text     = _("Retry"),
                                cancel_text = _("Skip"),
                                ok_callback = function()
                                    self:_showManualMatchDialog(book)
                                end,
                                cancel_callback = function()
                                    self.bk_matching_index = (self.bk_matching_index or 1) + 1
                                    if self.bk_unmatched_books and
                                       self.bk_matching_index <= #self.bk_unmatched_books then
                                        self:_showManualMatchDialog(
                                            self.bk_unmatched_books[self.bk_matching_index])
                                    else
                                        UIManager:show(InfoMessage:new{
                                            text    = _("Booklore: manual matching complete"),
                                            timeout = 2,
                                        })
                                        self.bk_unmatched_books = nil
                                        self.bk_matching_index  = nil
                                    end
                                end,
                            })
                            return
                        end

                        -- Build selection dialog
                        local top_results = {}
                        for i = 1, math.min(5, #results) do
                            top_results[i] = results[i]
                        end
                        local buttons = {}
                        for _, result in ipairs(top_results) do
                            local score = result.matchScore
                                and string.format(" (%.0f%%)", result.matchScore * 100) or ""
                            local label = result.title .. score
                            if result.author and result.author ~= "" then
                                label = label .. "\n" .. result.author
                            end
                            local r = result
                            table.insert(buttons, {{
                                text     = label,
                                callback = function()
                                    UIManager:close(self.bk_match_dialog)
                                    self:_saveBookCacheMatch(book, r)
                                    self.bk_matching_index = (self.bk_matching_index or 1) + 1
                                    if self.bk_unmatched_books and
                                       self.bk_matching_index <= #self.bk_unmatched_books then
                                        self:_showManualMatchDialog(
                                            self.bk_unmatched_books[self.bk_matching_index])
                                    else
                                        UIManager:show(InfoMessage:new{
                                            text    = _("Booklore: manual matching complete"),
                                            timeout = 2,
                                        })
                                        self.bk_unmatched_books = nil
                                        self.bk_matching_index  = nil
                                    end
                                end,
                            }})
                        end
                        table.insert(buttons, {{
                            text     = _("Skip"),
                            callback = function()
                                UIManager:close(self.bk_match_dialog)
                                self.bk_matching_index = (self.bk_matching_index or 1) + 1
                                if self.bk_unmatched_books and
                                   self.bk_matching_index <= #self.bk_unmatched_books then
                                    self:_showManualMatchDialog(
                                        self.bk_unmatched_books[self.bk_matching_index])
                                else
                                    UIManager:show(InfoMessage:new{
                                        text    = _("Booklore: manual matching complete"),
                                        timeout = 2,
                                    })
                                    self.bk_unmatched_books = nil
                                    self.bk_matching_index  = nil
                                end
                            end,
                        }})
                        table.insert(buttons, {{
                            text     = _("Cancel"),
                            callback = function()
                                UIManager:close(self.bk_match_dialog)
                                self.bk_unmatched_books = nil
                                self.bk_matching_index  = nil
                            end,
                        }})

                        self.bk_match_dialog = ButtonDialog:new{
                            title   = T(_("Select match for:\n%1\n\n%2"), term, progress),
                            buttons = buttons,
                        }
                        UIManager:show(self.bk_match_dialog)
                    end,
                },
            },
        },
    }
    UIManager:show(input_dialog)
end

--[[--
Show version information dialog
--]]
---BookloreSync:showVersionInfo.
function BookloreSync:showVersionInfo()
    return UpdatesModule.showVersionInfo(self)
end

--[[--
Auto-check for updates (runs once per day, silent mode)
--]]
---BookloreSync:autoCheckForUpdates.
function BookloreSync:autoCheckForUpdates()
    return UpdatesModule.autoCheckForUpdates(self)
end

--[[--
Check for updates (manual or auto)

@param silent If true, only show message when update available
--]]
---BookloreSync:checkForUpdates.
function BookloreSync:checkForUpdates(silent)
    return UpdatesModule.checkForUpdates(self, silent)
end

--[[--
Show changelog for the new version

@param changelog_url URL to download changelog from
@param version Version number
@param release_info Full release info object for showing update dialog again
--]]
---BookloreSync:showChangelog.
function BookloreSync:showChangelog(changelog_url, version, release_info)
    return UpdatesModule.showChangelog(self, changelog_url, version, release_info)
end

--[[--
Install update from download URL

@param download_url URL to download ZIP from
@param version Version being installed
--]]
---BookloreSync:installUpdate.
function BookloreSync:installUpdate(download_url, version)
    return UpdatesModule.installUpdate(self, download_url, version)
end

--[[--
Rollback to previous version after failed update
--]]
---BookloreSync:rollbackUpdate.
function BookloreSync:rollbackUpdate()
    return UpdatesModule.rollbackUpdate(self)
end

--[[--
Toggle auto-update check setting
--]]
---BookloreSync:toggleAutoUpdateCheck.
function BookloreSync:toggleAutoUpdateCheck()
    return UpdatesModule.toggleAutoUpdateCheck(self)
end

--[[--
Toggle development-build update channel.

Requires a valid dev-build.location file in the plugin directory.
--]]
---BookloreSync:toggleUseDevBuilds.
function BookloreSync:toggleUseDevBuilds()
    return UpdatesModule.toggleUseDevBuilds(self)
end

--[[--
Clear update cache to force fresh check
--]]
---BookloreSync:clearUpdateCache.
function BookloreSync:clearUpdateCache()
    return UpdatesModule.clearUpdateCache(self)
end

--[[--
Debug action: fetch metadata from Booklore for every matched book and
persist any hardcover_id values returned.

Iterates all book_cache rows that have a book_id, calls
APIClient:getBookById() for each, and stores the hardcover_id via
Database:updateHardcoverId() when present.

Shows a summary InfoMessage when done.
--]]
---BookloreSync:fetchAndStoreHardcoverIds.
function BookloreSync:fetchAndStoreHardcoverIds()
    if not self.server_url or self.server_url == "" then
        UIManager:show(InfoMessage:new{
            text = _("Booklore URL is not configured."),
            timeout = 3,
        })
        return
    end
    if not self.booklore_username or self.booklore_username == "" then
        UIManager:show(InfoMessage:new{
            text = _("Booklore credentials are not configured."),
            timeout = 3,
        })
        return
    end

    self:refreshEffectiveServerUrl()
    self.api:init(self.server_url, self.username, self.password, self.db)

    local booklore_msg = InfoMessage:new{
        text = _("Fetching book metadata from Booklore…"),
        timeout = 2,
    }
    UIManager:show(booklore_msg)

    -- Collect all book_cache rows that have a book_id
    local books = self.db:getAllMatchedBooks()
    if not books or #books == 0 then
        UIManager:show(InfoMessage:new{
            text = _("No matched books found in the local cache."),
            timeout = 3,
        })
        return
    end

    local total    = #books
    local updated  = 0
    local skipped  = 0
    local failed   = 0

    -- Books with no hardcover_id from Booklore; candidates for Hardcover fallback search.
    -- Each entry: { file_hash, isbn13, isbn10, title, authors }
    local fallback_candidates = {}

    for _, book in ipairs(books) do
        -- Skip books that already have a valid hardcover_id stored locally.
        if book.hardcover_id and book.hardcover_id > 0 then
            skipped = skipped + 1
            self:logInfo("BookloreSync: hardcover_id already stored for book_id", book.book_id, "- skipping")
        else
            local ok, data = self.api:getBookById(
                book.book_id,
                self.booklore_username,
                self.booklore_password
            )

            if ok and data then
                local hc_id = data.hardcover_id
                if hc_id then
                    local saved = self.db:updateHardcoverId(book.file_hash, hc_id)
                    if saved then
                        updated = updated + 1
                        self:logInfo("BookloreSync: Stored hardcover_id", hc_id,
                            "for book_id", book.book_id, "hash", book.file_hash)
                    else
                        failed = failed + 1
                        self:logWarn("BookloreSync: Failed to save hardcover_id for book_id", book.book_id)
                    end
                else
                    self:logInfo("BookloreSync: No hardcover_id in Booklore response for book_id", book.book_id)
                    -- Flatten authors: may be a table of {name=...} objects or a plain string
                    local author_str
                    if type(data.authors) == "table" then
                        local names = {}
                        for _, a in ipairs(data.authors) do
                            if type(a) == "table" and a.name then
                                table.insert(names, a.name)
                            elseif type(a) == "string" then
                                table.insert(names, a)
                            end
                        end
                        author_str = #names > 0 and names[1] or nil
                    else
                        author_str = data.authors ~= "" and data.authors or nil
                    end
                    table.insert(fallback_candidates, {
                        file_hash = book.file_hash,
                        isbn13    = data.isbn13,
                        isbn10    = data.isbn10,
                        title     = data.title,
                        authors   = author_str,
                    })
                end
            else
                failed = failed + 1
                self:logWarn("BookloreSync: getBookById failed for book_id", book.book_id, "-", tostring(data))
            end
        end
    end

    -- Hardcover fallback: for books where Booklore returned no hardcover_id,
    -- present search results one at a time for the user to confirm.
    local hc_found = 0
    self:logInfo("BookloreSync: Hardcover fallback - token set:", (self.hardcover_token ~= ""),
        "candidates:", #fallback_candidates)

    UIManager:close(booklore_msg)

    if not (self.hardcover_token and self.hardcover_token ~= "" and #fallback_candidates > 0) then
        skipped = skipped + #fallback_candidates
        local summary = T(_(
            "Metadata fetch complete.\n\n" ..
            "Books checked: %1\n" ..
            "Hardcover IDs stored: %2\n" ..
            "No Hardcover ID: %3\n" ..
            "Errors: %4"
        ), total, updated, skipped, failed)
        UIManager:show(InfoMessage:new{ text = summary })
        return
    end

    self:logInfo("BookloreSync: Starting Hardcover selector for",
        #fallback_candidates, "books")

    -- Throttle: 500 ms between Hardcover API requests (conservative rate limit)
    local HC_REQUEST_DELAY = 0.5

    -- Recursive callback: processes candidates[i], shows selector, advances on choice.
    -- selector is forward-declared here so the closures inside process_next can reference it.
    local selector
    local process_next
    process_next = function(i)
        if i > #fallback_candidates then
            -- All done - show summary
            local summary
            if hc_found > 0 then
                summary = T(_(
                    "Metadata fetch complete.\n\n" ..
                    "Books checked: %1\n" ..
                    "Hardcover IDs stored (Booklore): %2\n" ..
                    "Hardcover IDs stored (manual match): %3\n" ..
                    "No Hardcover ID found: %4\n" ..
                    "Errors: %5"
                ), total, updated, hc_found, skipped, failed)
            else
                summary = T(_(
                    "Metadata fetch complete.\n\n" ..
                    "Books checked: %1\n" ..
                    "Hardcover IDs stored: %2\n" ..
                    "No Hardcover ID: %3\n" ..
                    "Errors: %4"
                ), total, updated + hc_found, skipped, failed)
            end
            UIManager:show(InfoMessage:new{ text = summary })
            return
        end

        local cand = fallback_candidates[i]
        local n    = #fallback_candidates

        -- Show a progress InfoMessage while searching
        local searching_msg = InfoMessage:new{
            text = T(_("Searching Hardcover…\n\n(%1 / %2)  %3"),
                i, n, cand.title or ""),
        }
        UIManager:show(searching_msg)
        UIManager:forceRePaint()

        -- Step 1: ISBN-13 lookup (no selector needed - ISBNs are unambiguous)
        local isbn = cand.isbn13
        if isbn and isbn ~= "" then
            local hc_id, isbn_err = self.hc_api:findBookByIsbn(isbn, self.hardcover_token)
            if hc_id then
                self:logInfo("BookloreSync: Hardcover ISBN match →", hc_id, "for", cand.title)
                UIManager:close(searching_msg)
                local saved = self.db:updateHardcoverId(cand.file_hash, hc_id)
                if saved then
                    hc_found = hc_found + 1
                else
                    failed = failed + 1
                end
                UIManager:scheduleIn(HC_REQUEST_DELAY, function()
                    process_next(i + 1)
                end)
                return
            else
                self:logInfo("BookloreSync: ISBN-13 lookup failed, falling back to title search:", tostring(isbn_err))
            end
        end

        -- Step 2: title+author search → present candidates to user
        if not (cand.title and cand.title ~= "") then
            UIManager:close(searching_msg)
            self:logInfo("BookloreSync: No title for candidate, skipping")
            skipped = skipped + 1
            UIManager:scheduleIn(HC_REQUEST_DELAY, function()
                process_next(i + 1)
            end)
            return
        end

        local candidates, search_err = self.hc_api:searchBook(
            cand.title, cand.authors, self.hardcover_token)

        UIManager:close(searching_msg)

        if not candidates then
            self:logInfo("BookloreSync: Hardcover search failed:", tostring(search_err))
            skipped = skipped + 1
            UIManager:scheduleIn(HC_REQUEST_DELAY, function()
                process_next(i + 1)
            end)
            return
        end

        -- Build item_table for Menu: one entry per candidate + Skip entry
        local item_table = {}
        local selection_made = false  -- guard: close_callback fires after item selection too
        for _, result in ipairs(candidates) do
            local label = result.title
            if result.year ~= "" then
                label = label .. " (" .. result.year .. ")"
            end
            if result.author ~= "" then
                label = label .. " - " .. result.author
            end
            table.insert(item_table, {
                text        = label,
                chosen_id   = result.id,
            })
        end
        -- Skip entry (chosen_id == nil signals skip)
        table.insert(item_table, { text = _("Skip this book") })

        local book_label = cand.title or ""
        if cand.authors and cand.authors ~= "" then
            book_label = book_label .. " - " .. cand.authors
        end

        selector = Menu:new{
            title                    = T(_("Match Hardcover book (%1/%2)"), i, n),
            subtitle                 = book_label,
            item_table               = item_table,
            single_line              = false,
            multilines_show_more_text = true,
            fullscreen               = true,
            onMenuSelect             = function(menu, item)
                selection_made = true
                UIManager:close(selector)
                if item.chosen_id then
                    self:logInfo("BookloreSync: User selected hardcover_id", item.chosen_id,
                        "for", cand.title)
                    local saved = self.db:updateHardcoverId(cand.file_hash, item.chosen_id)
                    if saved then
                        hc_found = hc_found + 1
                    else
                        failed = failed + 1
                    end
                    UIManager:scheduleIn(HC_REQUEST_DELAY, function()
                        process_next(i + 1)
                    end)
                else
                    -- Skip selected
                    skipped = skipped + 1
                    process_next(i + 1)
                end
            end,
            close_callback = function()
                -- Only treat as skip when user dismissed without picking
                if not selection_made then
                    skipped = skipped + 1
                    process_next(i + 1)
                end
            end,
        }
        UIManager:show(selector)
    end

    -- Bootstrap the recursive chain
    process_next(1)
end

return BookloreSync
