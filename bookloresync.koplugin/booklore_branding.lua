local Branding = {}

local DEFAULT_DISPLAY_NAME = "Booklore"
local DISPLAY_KEY = "booklore_brand_display_name"

local function trim(value)
    if type(value) ~= "string" then
        return nil
    end
    local normalized = value:gsub("^%s+", ""):gsub("%s+$", "")
    if normalized == "" then
        return nil
    end
    return normalized
end

local function ci_pattern(word)
    return (word:gsub("%a", function(char)
        return "[" .. char:lower() .. char:upper() .. "]"
    end))
end

local function read_global_setting(key)
    if not G_reader_settings or not G_reader_settings.readSetting then
        return nil
    end
    return G_reader_settings:readSetting(key)
end

local function write_global_setting(key, value)
    if not G_reader_settings or not G_reader_settings.saveSetting then
        return
    end
    G_reader_settings:saveSetting(key, value)
    if G_reader_settings.flush then
        G_reader_settings:flush()
    end
end

function Branding.normalizeDisplayName(value)
    local normalized = trim(value) or DEFAULT_DISPLAY_NAME
    local lower = normalized:lower()
    if #lower >= 4 and lower:sub(-4) == "sync" then
        local without_sync = normalized:sub(1, #normalized - 4)
        without_sync = without_sync:gsub("[%s_-]+$", "")
        return trim(without_sync) or DEFAULT_DISPLAY_NAME
    end
    return normalized
end

function Branding.normalizeShortcutName(display_name)
    return Branding.normalizeDisplayName(display_name) .. "Sync"
end

function Branding.getNames(display_name)
    local resolved_display = Branding.normalizeDisplayName(display_name or read_global_setting(DISPLAY_KEY))
    local resolved_shortcut = Branding.normalizeShortcutName(resolved_display)
    return resolved_display, resolved_shortcut
end

function Branding.saveGlobalNames(display_name)
    local resolved_display = Branding.normalizeDisplayName(display_name)
    write_global_setting(DISPLAY_KEY, resolved_display)
end

function Branding.apply(text, display_name)
    if type(text) ~= "string" then
        return text
    end

    local resolved_display, resolved_shortcut = Branding.getNames(display_name)

    -- Use placeholders to avoid re-replacing parts of already-replaced text.
    local mark_space = "\1BRAND_SPACE\1"
    local mark_short = "\1BRAND_SHORT\1"
    local mark_base = "\1BRAND_BASE\1"

    local result = text
    result = result:gsub(ci_pattern("booklore sync"), mark_space)
    result = result:gsub(ci_pattern("bookloresync"), mark_short)
    result = result:gsub(ci_pattern("booklore"), mark_base)

    -- "Booklore Sync" is treated as plugin display name with explicit Sync suffix.
    result = result:gsub(mark_space, resolved_display .. " Sync")
    -- Shortcut token is used for dispatcher/action style labels.
    result = result:gsub(mark_short, resolved_shortcut)
    result = result:gsub(mark_base, resolved_display)

    return result
end

return Branding
