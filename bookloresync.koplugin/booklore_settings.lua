--[[--
Booklore Settings Module

Handles all user configuration for the Booklore KOReader plugin.

@module koplugin.BookloreSync.settings
--]]--

local InputDialog = require("ui/widget/inputdialog")
local UIManager = require("ui/uimanager")
local InfoMessage = require("ui/widget/infomessage")
local T = require("ffi/util").template
local _ = require("gettext")

local Settings = {}

function Settings:configureServerUrl(parent)
    local input_dialog
    input_dialog = InputDialog:new{
        title = _("Booklore Server URL"),
        input = parent.server_url,
        input_hint = "http://192.168.1.100:6060",
        buttons = {
            {
                {
                    text = _("Cancel"),
                    callback = function()
                        UIManager:close(input_dialog)
                    end,
                },
                {
                    text = _("Save"),
                    is_enter_default = true,
                    callback = function()
                        parent.server_url = input_dialog:getInputText()
                        parent.settings:saveSetting("server_url", parent.server_url)
                        parent.settings:flush()
                        
                        -- Reinitialize API client with new URL
                        if parent.api then
                            parent.api:init(parent.server_url, parent.username, parent.password, parent.db, parent.secure_logs)
                        end
                        
                        UIManager:close(input_dialog)
                        UIManager:show(InfoMessage:new{
                            text = _("Server URL saved"),
                            timeout = 1,
                        })
                    end,
                },
            },
        },
    }
    UIManager:show(input_dialog)
    input_dialog:onShowKeyboard()
end

function Settings:configureUsername(parent)
    local input_dialog
    input_dialog = InputDialog:new{
        title = _("KOReader Username"),
        input = parent.username,
        buttons = {
            {
                {
                    text = _("Cancel"),
                    callback = function()
                        UIManager:close(input_dialog)
                    end,
                },
                {
                    text = _("Save"),
                    is_enter_default = true,
                    callback = function()
                        parent.username = input_dialog:getInputText()
                        parent.settings:saveSetting("username", parent.username)
                        parent.settings:flush()
                        
                        -- Reinitialize API client with new username
                        if parent.api then
                            parent.api:init(parent.server_url, parent.username, parent.password, parent.db, parent.secure_logs)
                        end
                        
                        UIManager:close(input_dialog)
                        UIManager:show(InfoMessage:new{
                            text = _("Username saved"),
                            timeout = 1,
                        })
                    end,
                },
            },
        },
    }
    UIManager:show(input_dialog)
    input_dialog:onShowKeyboard()
end

function Settings:configurePassword(parent)
    local input_dialog
    input_dialog = InputDialog:new{
        title = _("KOReader Password"),
        input = parent.password,
        text_type = "password",
        buttons = {
            {
                {
                    text = _("Cancel"),
                    callback = function()
                        UIManager:close(input_dialog)
                    end,
                },
                {
                    text = _("Save"),
                    is_enter_default = true,
                    callback = function()
                        parent.password = input_dialog:getInputText()
                        parent.settings:saveSetting("password", parent.password)
                        parent.settings:flush()
                        
                        -- Reinitialize API client with new password
                        if parent.api then
                            parent.api:init(parent.server_url, parent.username, parent.password, parent.db, parent.secure_logs)
                        end
                        
                        UIManager:close(input_dialog)
                        UIManager:show(InfoMessage:new{
                            text = _("Password saved"),
                            timeout = 1,
                        })
                    end,
                },
            },
        },
    }
    UIManager:show(input_dialog)
    input_dialog:onShowKeyboard()
end

function Settings:configureMinDuration(parent)
    local input_dialog
    input_dialog = InputDialog:new{
        title = _("Minimum Session Duration (seconds)"),
        input = tostring(parent.min_duration),
        input_hint = "30",
        input_type = "number",
        buttons = {
            {
                {
                    text = _("Cancel"),
                    callback = function()
                        UIManager:close(input_dialog)
                    end,
                },
                {
                    text = _("Save"),
                    is_enter_default = true,
                    callback = function()
                        local input_value = tonumber(input_dialog:getInputText())
                        if input_value and input_value > 0 then
                            parent.min_duration = input_value
                            parent.settings:saveSetting("min_duration", parent.min_duration)
                            parent.settings:flush()
                            UIManager:close(input_dialog)
                            UIManager:show(InfoMessage:new{
                                text = T(_("Minimum duration set to %1 seconds"), tostring(parent.min_duration)),
                                timeout = 2,
                            })
                        else
                            UIManager:show(InfoMessage:new{
                                text = _("Please enter a valid number greater than 0"),
                                timeout = 2,
                            })
                        end
                    end,
                },
            },
        },
    }
    UIManager:show(input_dialog)
    input_dialog:onShowKeyboard()
end

function Settings:configureMinPages(parent)
    local input_dialog
    input_dialog = InputDialog:new{
        title = _("Minimum Pages Read"),
        input = tostring(parent.min_pages),
        input_hint = "5",
        input_type = "number",
        buttons = {
            {
                {
                    text = _("Cancel"),
                    callback = function()
                        UIManager:close(input_dialog)
                    end,
                },
                {
                    text = _("Save"),
                    is_enter_default = true,
                    callback = function()
                        local input_value = tonumber(input_dialog:getInputText())
                        if input_value and input_value > 0 and input_value == math.floor(input_value) then
                            parent.min_pages = input_value
                            parent.settings:saveSetting("min_pages", parent.min_pages)
                            parent.settings:flush()
                            UIManager:close(input_dialog)
                            UIManager:show(InfoMessage:new{
                                text = T(_("Minimum pages set to %1"), tostring(parent.min_pages)),
                                timeout = 2,
                            })
                        else
                            UIManager:show(InfoMessage:new{
                                text = _("Please enter a valid integer greater than 0"),
                                timeout = 2,
                            })
                        end
                    end,
                },
            },
        },
    }
    UIManager:show(input_dialog)
    input_dialog:onShowKeyboard()
end

function Settings:configureProgressDecimalPlaces(parent)
    local input_dialog
    input_dialog = InputDialog:new{
        title = _("Progress Decimal Places (0-5)"),
        input = tostring(parent.progress_decimal_places),
        input_hint = "2",
        input_type = "number",
        buttons = {
            {
                {
                    text = _("Cancel"),
                    callback = function()
                        UIManager:close(input_dialog)
                    end,
                },
                {
                    text = _("Save"),
                    is_enter_default = true,
                    callback = function()
                        local input_value = tonumber(input_dialog:getInputText())
                        if input_value and input_value >= 0 and input_value <= 5 and input_value == math.floor(input_value) then
                            parent.progress_decimal_places = input_value
                            parent.settings:saveSetting("progress_decimal_places", parent.progress_decimal_places)
                            parent.settings:flush()
                            UIManager:close(input_dialog)
                            UIManager:show(InfoMessage:new{
                                text = T(_("Progress decimal places set to %1"), tostring(parent.progress_decimal_places)),
                                timeout = 2,
                            })
                        else
                            UIManager:show(InfoMessage:new{
                                text = _("Please enter a valid integer between 0 and 5"),
                                timeout = 2,
                            })
                        end
                    end,
                },
            },
        },
    }
    UIManager:show(input_dialog)
    input_dialog:onShowKeyboard()
end

function Settings:showVersion(parent)
    -- Load version information from _meta.lua and plugin_version.lua
    local version_info = require("plugin_version")
    local meta_info = require("_meta")
    
    local version_text = string.format(
        "Booklore Sync\n\nVersion: %s\nType: %s\nBuild Date: %s\nCommit: %s",
        meta_info.version or version_info.version or "unknown",
        version_info.version_type or "unknown",
        version_info.build_date or "unknown",
        version_info.git_commit or "unknown"
    )
    
    UIManager:show(InfoMessage:new{
        text = version_text,
        timeout = 5,
    })
end

function Settings:buildConnectionMenu(parent)
    return {
        text = _("Setup & Connection"),
        sub_item_table = {
            {
                text = _("Server URL"),
                help_text = _("The URL of your Booklore server (e.g., http://192.168.1.100:6060). This is where reading sessions will be synced."),
                keep_menu_open = true,
                callback = function()
                    self:configureServerUrl(parent)
                end,
            },
            {
                text = _("Username"),
                help_text = _("Your Booklore username for authentication."),
                keep_menu_open = true,
                callback = function()
                    self:configureUsername(parent)
                end,
            },
            {
                text = _("Password"),
                help_text = _("Your Booklore password. This is stored locally and used to authenticate with the server."),
                keep_menu_open = true,
                callback = function()
                    self:configurePassword(parent)
                end,
            },
            {
                text = _("Test Connection"),
                help_text = _("Test the connection to your Booklore server to verify your credentials and network connectivity."),
                enabled_func = function()
                    return parent.server_url ~= "" and parent.username ~= ""
                end,
                callback = function()
                    parent:testConnection()
                end,
            },
        },
    }
end

function Settings:buildSyncingMenu(parent)
    return {
        text = _("Syncing"),
        sub_item_table = {
            -- Master toggle
            {
                text = _("Enable extended sync"),
                help_text = _("Enable extended sync features: rating sync, metadata location detection, and highlights/notes upload."),
                checked_func = function()
                    return parent.extended_sync_enabled
                end,
                callback = function()
                    parent.extended_sync_enabled = not parent.extended_sync_enabled
                    parent.settings:saveSetting("extended_sync_enabled", parent.extended_sync_enabled)
                    parent.settings:flush()
                    UIManager:show(InfoMessage:new{
                        text = parent.extended_sync_enabled
                            and _("Extended sync enabled")
                            or  _("Extended sync disabled"),
                        timeout = 2,
                    })
                end,
            },

            -- ── Rating ──────────────────────────────────────────────────────
            {
                text = _("── Rating ──"),
                enabled = false,
            },
            {
                text = _("Enable rating sync"),
                help_text = _("Sync the book rating to Booklore when a session ends."),
                enabled_func = function()
                    return parent.extended_sync_enabled
                end,
                checked_func = function()
                    return parent.rating_sync_enabled
                end,
                callback = function()
                    parent.rating_sync_enabled = not parent.rating_sync_enabled
                    parent.settings:saveSetting("rating_sync_enabled", parent.rating_sync_enabled)
                    parent.settings:flush()
                    UIManager:show(InfoMessage:new{
                        text = parent.rating_sync_enabled
                            and _("Rating sync enabled")
                            or  _("Rating sync disabled"),
                        timeout = 2,
                    })
                end,
            },
            {
                text = _("  KOReader rating (scaled ×2)"),
                help_text = _("Use the KOReader star rating (1-5) scaled to Booklore's 1-10 scale by multiplying by 2."),
                enabled_func = function()
                    return parent.extended_sync_enabled and parent.rating_sync_enabled
                end,
                checked_func = function()
                    return parent.rating_sync_mode == "koreader_scaled"
                end,
                callback = function()
                    parent.rating_sync_mode = "koreader_scaled"
                    parent.settings:saveSetting("rating_sync_mode", parent.rating_sync_mode)
                    parent.settings:flush()
                    UIManager:show(InfoMessage:new{
                        text = _("Rating mode: KOReader rating (scaled ×2)"),
                        timeout = 2,
                    })
                end,
                keep_menu_open = true,
            },
            {
                text = _("  Select at complete"),
                help_text = _("Show a 1-10 rating dialog when you finish reading a book (progress ≥ 99%)."),
                enabled_func = function()
                    return parent.extended_sync_enabled and parent.rating_sync_enabled
                end,
                checked_func = function()
                    return parent.rating_sync_mode == "select_at_complete"
                end,
                callback = function()
                    parent.rating_sync_mode = "select_at_complete"
                    parent.settings:saveSetting("rating_sync_mode", parent.rating_sync_mode)
                    parent.settings:flush()
                    UIManager:show(InfoMessage:new{
                        text = _("Rating mode: Select at complete"),
                        timeout = 2,
                    })
                end,
                keep_menu_open = true,
            },

            -- ── Metadata ────────────────────────────────────────────────────
            {
                text = _("── Metadata ──"),
                enabled = false,
            },
            {
                text = _("Detect book metadata location"),
                help_text = _("Detect and store the KOReader sidecar (.sdr) path for the currently open book so the plugin knows where to read metadata from."),
                enabled_func = function()
                    return parent.extended_sync_enabled
                        and parent.ui ~= nil
                        and parent.ui.document ~= nil
                        and parent.ui.document.file ~= nil
                end,
                callback = function()
                    parent:detectBookMetadataLocation()
                end,
            },

            -- ── Notes & Highlights ──────────────────────────────────────────
            {
                text = _("── Notes & Highlights ──"),
                enabled = false,
            },
            {
                text = _("Sync highlights and notes"),
                help_text = _("Upload KOReader highlights and notes to Booklore."),
                enabled_func = function()
                    return parent.extended_sync_enabled
                end,
                checked_func = function()
                    return parent.highlights_notes_sync_enabled
                end,
                callback = function()
                    parent.highlights_notes_sync_enabled = not parent.highlights_notes_sync_enabled
                    parent.settings:saveSetting("highlights_notes_sync_enabled", parent.highlights_notes_sync_enabled)
                    parent.settings:flush()
                    UIManager:show(InfoMessage:new{
                        text = parent.highlights_notes_sync_enabled
                            and _("Highlights & notes sync enabled")
                            or  _("Highlights & notes sync disabled"),
                        timeout = 2,
                    })
                end,
            },
            {
                text = _("  Notes destination: In book"),
                help_text = _("Send notes to the in-book reader view in Booklore (requires EPUB CFI position). Notes will appear attached to the highlighted passage."),
                enabled_func = function()
                    return parent.extended_sync_enabled and parent.highlights_notes_sync_enabled
                end,
                checked_func = function()
                    return parent.notes_destination == "in_book"
                end,
                callback = function()
                    parent.notes_destination = "in_book"
                    parent.settings:saveSetting("notes_destination", parent.notes_destination)
                    parent.settings:flush()
                    UIManager:show(InfoMessage:new{
                        text = _("Notes destination: In book"),
                        timeout = 2,
                    })
                end,
                keep_menu_open = true,
            },
            {
                text = _("  Notes destination: In Booklore"),
                help_text = _("Send notes to the Booklore book page (visible in the web UI). The chapter title is used as the note title."),
                enabled_func = function()
                    return parent.extended_sync_enabled and parent.highlights_notes_sync_enabled
                end,
                checked_func = function()
                    return parent.notes_destination == "in_booklore"
                end,
                callback = function()
                    parent.notes_destination = "in_booklore"
                    parent.settings:saveSetting("notes_destination", parent.notes_destination)
                    parent.settings:flush()
                    UIManager:show(InfoMessage:new{
                        text = _("Notes destination: In Booklore"),
                        timeout = 2,
                    })
                end,
                keep_menu_open = true,
            },

            -- ── Upload Strategy ─────────────────────────────────────────────
            {
                text = _("── Upload Strategy ──"),
                enabled = false,
            },
            {
                text = _("  On session upload"),
                help_text = _("Check for new highlights and notes each time a reading session ends. Only annotations not yet on the server will be sent."),
                enabled_func = function()
                    return parent.extended_sync_enabled and parent.highlights_notes_sync_enabled
                end,
                checked_func = function()
                    return parent.upload_strategy == "on_session"
                end,
                callback = function()
                    parent.upload_strategy = "on_session"
                    parent.settings:saveSetting("upload_strategy", parent.upload_strategy)
                    parent.settings:flush()
                    UIManager:show(InfoMessage:new{
                        text = _("Upload strategy: on session"),
                        timeout = 2,
                    })
                end,
                keep_menu_open = true,
            },
            {
                text = _("  On read complete"),
                help_text = _("Upload all highlights and notes only when progress reaches 99% or more. Runs once at the end of the final reading session."),
                enabled_func = function()
                    return parent.extended_sync_enabled and parent.highlights_notes_sync_enabled
                end,
                checked_func = function()
                    return parent.upload_strategy == "on_complete"
                end,
                callback = function()
                    parent.upload_strategy = "on_complete"
                    parent.settings:saveSetting("upload_strategy", parent.upload_strategy)
                    parent.settings:flush()
                    UIManager:show(InfoMessage:new{
                        text = _("Upload strategy: on read complete"),
                        timeout = 2,
                    })
                end,
                keep_menu_open = true,
            },
        },
    }
end

function Settings:buildPreferencesMenu(parent)
    return {
        text = _("Preferences"),
        sub_item_table = {
            {
                text = _("Silent mode"),
                help_text = _("Suppress all messages related to sessions being cached. The plugin will continue to work normally in the background."),
                checked_func = function()
                    return parent.silent_messages
                end,
                callback = function()
                    parent.silent_messages = not parent.silent_messages
                    parent.settings:saveSetting("silent_messages", parent.silent_messages)
                    parent.settings:flush()
                    UIManager:show(InfoMessage:new{
                        text = parent.silent_messages and _("Silent mode enabled") or _("Silent mode disabled"),
                        timeout = 2,
                    })
                end,
            },
            {
                text = _("Debug logging"),
                help_text = _("Enable detailed logging to files for debugging purposes. Logs are saved daily to the plugin's logs directory. The last 3 log files are kept automatically."),
                checked_func = function()
                    return parent.log_to_file
                end,
                callback = function()
                    parent.log_to_file = not parent.log_to_file
                    parent.settings:saveSetting("log_to_file", parent.log_to_file)
                    parent.settings:flush()
                    
                    -- Initialize or close file logger based on new setting
                    if parent.log_to_file then
                        if not parent.file_logger then
                            local FileLogger = require("booklore_file_logger")
                            parent.file_logger = FileLogger:new()
                            local logger_ok = parent.file_logger:init()
                            if logger_ok then
                                parent:logInfo("BookloreSync: File logging enabled")
                            else
                                parent:logErr("BookloreSync: Failed to initialize file logger")
                                parent.file_logger = nil
                            end
                        end
                    else
                        if parent.file_logger then
                            parent.file_logger:close()
                            parent.file_logger = nil
                        end
                    end
                    
                    UIManager:show(InfoMessage:new{
                        text = parent.log_to_file and _("Debug logging enabled") or _("Debug logging disabled"),
                        timeout = 2,
                    })
                end,
            },
            {
                text = _("Secure logs"),
                help_text = _("Redact URLs from logs to protect sensitive information. When enabled, all URLs in log messages will be replaced with [URL REDACTED] so logs can be safely shared."),
                checked_func = function()
                    return parent.secure_logs
                end,
                callback = function()
                    parent.secure_logs = not parent.secure_logs
                    parent.settings:saveSetting("secure_logs", parent.secure_logs)
                    parent.settings:flush()
                    UIManager:show(InfoMessage:new{
                        text = parent.secure_logs and _("Secure logging enabled") or _("Secure logging disabled"),
                        timeout = 2,
                    })
                end,
            },
        },
    }
end

return Settings
