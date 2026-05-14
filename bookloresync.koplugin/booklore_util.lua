--[[--
Booklore Shared Utility Module

Pure functions used across multiple plugin modules.  No state, no dependencies
on KOReader UI widgets or the plugin's `self` table.  Functions that need
logging accept an optional callback.

@module koplugin.BookloreSync.util
--]]--

local Util = {}

-- ═══════════════════════════════════════════════════════════════════════════
-- URL redaction
-- ═══════════════════════════════════════════════════════════════════════════

--[[--
Redact URLs from a log message for secure logging.

@param message The log message that may contain URLs
@return string Message with URLs replaced by [REDACTED_URL]
--]]
function Util.redactUrls(message)
    if type(message) ~= "string" then
        message = tostring(message)
    end
    return message:gsub("https?://[^%s]+", "[REDACTED_URL]")
end

-- ═══════════════════════════════════════════════════════════════════════════
-- File hashing (Booklore FileFingerprint algorithm)
-- ═══════════════════════════════════════════════════════════════════════════

--[[--
Compute an MD5 hash of a book file using Booklore's FileFingerprint sampling.

Samples up to 12 1 KiB blocks at geometrically-spaced positions (1, 4, 16,
64, … bytes from the start) and returns the MD5 of the concatenated samples.

@param file_path string  Absolute path to the file
@return string|nil       MD5 hex digest, or nil on error
--]]
function Util.calculateBookHash(file_path)
    local file = io.open(file_path, "rb")
    if not file then
        return nil
    end

    local md5        = require("ffi/sha2").md5
    local base       = 1024
    local block_size = 1024
    local buffer     = {}

    local file_size = file:seek("end")
    file:seek("set", 0)

    for i = -1, 10 do
        local position = bit.lshift(base, 2 * i)
        if position >= file_size then break end
        file:seek("set", position)
        local chunk = file:read(block_size)
        if chunk then
            table.insert(buffer, chunk)
        end
    end

    file:close()
    return md5(table.concat(buffer))
end

-- ═══════════════════════════════════════════════════════════════════════════
-- Download path helpers
-- ═══════════════════════════════════════════════════════════════════════════

--[[--
Join a directory path and a filename, handling leading/trailing slashes.

@param dir  string  Base directory
@param name string  File name
@return string  Combined path
--]]
function Util.joinDownloadPath(dir, name)
    local base = tostring(dir or "")
    if base == "/" then
        return "/" .. name
    end
    base = base:gsub("/+$", "")
    if base == "" then
        return "/" .. name
    end
    return base .. "/" .. name
end

-- ═══════════════════════════════════════════════════════════════════════════
-- Filename sanitisation
-- ═══════════════════════════════════════════════════════════════════════════

--[[--
Remove filesystem-unsafe characters and normalise whitespace in a string.

@param str string  Raw string to sanitise
@return string  Sanitised string (may be empty)
--]]
function Util.sanitiseFilenameStem(str)
    local safe = tostring(str or "")
    safe = safe:gsub('[/\\:*?"<>|]', "")
    safe = safe:gsub("%s+", " ")
    safe = safe:gsub("^%s+", "")
    safe = safe:gsub("%s+$", "")
    return safe
end

--[[--
Generate a download filename for a shelf book.

When use_original_filename is true and the book has an original_filename field,
that is used as the stem.  Otherwise the book title is used.  Falls back to
"BookID_{id}.{extension}".

The final filename is at most ~155 characters (stem + id_tag + extension).

@param book                  table   Book object from Booklore API
@param use_original_filename boolean (optional) Prefer original_filename over title
@return string  Sanitised filename
--]]
function Util.generateFilename(book, use_original_filename)
    local extension = (book.extension or "epub"):lower()
    local ext_suffix = "." .. extension
    local id_tag     = "_" .. tostring(book.id)

    local stem = nil

    if use_original_filename and book.original_filename and book.original_filename ~= "" then
        stem = book.original_filename:match("^(.+)%.[^.]+$") or book.original_filename
    end

    if not stem or stem == "" then
        stem = book.title
    end

    if stem and stem ~= "" then
        local safe = Util.sanitiseFilenameStem(stem)
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

-- ═══════════════════════════════════════════════════════════════════════════
-- Rounding helpers
-- ═══════════════════════════════════════════════════════════════════════════

--[[--
Round a value to the nearest integer.

@param value number
@return number|nil
--]]
function Util.roundToInt(value)
    local n = tonumber(value)
    if not n then
        return nil
    end
    return math.floor(n + 0.5)
end

--[[--
Round a 0..1 percentage ratio to 4 decimal places.

@param value number  0..1
@return number  Rounded ratio (clamped to 0..1)
--]]
function Util.roundKoreaderSyncPercentage(value)
    local n = tonumber(value) or 0
    if n < 0 then n = 0 end
    if n > 1 then n = 1 end
    return math.floor(n * 10000 + 0.5) / 10000
end

-- ═══════════════════════════════════════════════════════════════════════════
-- KOReader colour → hex / style mapping
-- ═══════════════════════════════════════════════════════════════════════════

-- Map KOReader colour names → Booklore's 5 supported highlight hex colours.
-- Unsupported colours are mapped to the nearest hue.
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
    invert     = "highlight",
}

--[[--
Convert a KOReader colour name to a hex string.

@param color_name string  KOReader colour name (e.g. "yellow")
@return string  Hex colour (e.g. "#FFC107")
--]]
function Util.colorToHex(color_name)
    if not color_name then return "#FFC107" end
    return KOREADER_COLOR_MAP[color_name:lower()] or "#FFC107"
end

--[[--
Convert a KOReader drawer name to a Booklore style string.

@param drawer string  KOReader drawer name (e.g. "lighten")
@return string  Booklore style (e.g. "highlight")
--]]
function Util.drawerToStyle(drawer)
    if not drawer then return "highlight" end
    return KOREADER_STYLE_MAP[drawer:lower()] or "highlight"
end

-- ═══════════════════════════════════════════════════════════════════════════
-- Timing
-- ═══════════════════════════════════════════════════════════════════════════

--[[--
Get the current script-run time in milliseconds (monotonic).

@return number  Milliseconds since start of script
--]]
function Util.getTimingNowMs()
    return math.floor(os.clock() * 1000)
end

-- ═══════════════════════════════════════════════════════════════════════════
-- Serialisation
-- ═══════════════════════════════════════════════════════════════════════════

--[[--
Stably serialise a value to a string for fingerprint comparison.

Tables are serialised with keys sorted so the output is deterministic.
--]]
function Util.stableSerializeValue(value)
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
            parts[#parts + 1] = tostring(k) .. "=" .. Util.stableSerializeValue(v)
        end
        table.sort(parts)
        return "{" .. table.concat(parts, ",") .. "}"
    end
    return tostring(value)
end

-- ═══════════════════════════════════════════════════════════════════════════
-- Timestamp formatting
-- ═══════════════════════════════════════════════════════════════════════════

--[[--
Convert a Unix timestamp to an ISO 8601 UTC string.

@param timestamp number  Unix timestamp
@return string  ISO 8601 string (e.g. "2026-05-14T19:30:00Z")
--]]
function Util.unixToISO8601(timestamp)
    local dt = os.date("!*t", tonumber(timestamp) or os.time())
    return string.format("%04d-%02d-%02dT%02d:%02d:%02dZ",
        dt.year, dt.month, dt.day,
        dt.hour, dt.min, dt.sec)
end

--[[--
Parse an ISO 8601 string to a Unix timestamp.

@param iso_string string  ISO 8601 string
@return number|nil  Unix timestamp, or nil if parsing failed
--]]
function Util.parseISO8601(iso_string)
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
    })
end

-- ═══════════════════════════════════════════════════════════════════════════
-- Logging helpers (shared boilerplate for modules that need log delegation)
-- ═══════════════════════════════════════════════════════════════════════════

--[[--
Write a log message via the plugin's file logger or fall back to KOReader's
native logger.  URLs are automatically redacted.

Usage:
    util.logInfo(plugin, "message", var)
    -- plugin may be nil; if nil, the native logger is used directly.

@param plugin table|nil  Plugin instance that has logInfo etc.
@param ...               Values to log
--]]
function Util.logInfo(plugin, ...)
    if plugin and plugin.logInfo then
        plugin:logInfo(Util.redactUrls(...))
    else
        local ok, logger = pcall(require, "logger")
        if ok then logger.info(...) end
    end
end

function Util.logWarn(plugin, ...)
    if plugin and plugin.logWarn then
        plugin:logWarn(Util.redactUrls(...))
    else
        local ok, logger = pcall(require, "logger")
        if ok then logger.warn(...) end
    end
end

function Util.logErr(plugin, ...)
    if plugin and plugin.logErr then
        plugin:logErr(Util.redactUrls(...))
    else
        local ok, logger = pcall(require, "logger")
        if ok then logger.err(...) end
    end
end

function Util.logDbg(plugin, ...)
    if plugin and plugin.logDbg then
        plugin:logDbg(Util.redactUrls(...))
    else
        local ok, logger = pcall(require, "logger")
        if ok then logger.dbg(...) end
    end
end

return Util
