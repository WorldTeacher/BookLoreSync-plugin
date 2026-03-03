#!/usr/bin/env luajit
--[[--
Unit tests for BookloreSync pure helper functions in main.lua.
Copy-pasted from main.lua to avoid KOReader runtime dependencies.

Run with:  luajit test_main.lua
--]]--

-- ── Copy of color/style maps and functions from main.lua ─────────────────────

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

local KOREADER_STYLE_MAP = {
    lighten    = "highlight",
    underscore = "underline",
    strikeout  = "strikethrough",
    invert     = "highlight",     -- closest available
}

local BookloreSync = {}

function BookloreSync:colorToHex(color_name)
    if not color_name then return "#FFC107" end
    return KOREADER_COLOR_MAP[color_name:lower()] or "#FFC107"
end

function BookloreSync:drawerToStyle(drawer)
    if not drawer then return "highlight" end
    return KOREADER_STYLE_MAP[drawer:lower()] or "highlight"
end

function BookloreSync:_generateFilename(book)
    local extension = (book.extension or "epub"):lower()
    return "BookID_" .. tostring(book.id) .. "." .. extension
end

function BookloreSync:formatDuration(duration_seconds)
    duration_seconds = tonumber(duration_seconds)

    if not duration_seconds or duration_seconds < 0 then
        return "0s"
    end

    local hours   = math.floor(duration_seconds / 3600)
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

function BookloreSync:roundProgress(value)
    local multiplier = 10 ^ self.progress_decimal_places
    return math.floor(value * multiplier + 0.5) / multiplier
end

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

-- ── Test harness ──────────────────────────────────────────────────────────────

local pass, fail = 0, 0

local function check(label, got, expected)
    if got == expected then
        print("  PASS: " .. label)
        pass = pass + 1
    else
        print("  FAIL: " .. label)
        print("        expected: " .. tostring(expected))
        print("        got:      " .. tostring(got))
        fail = fail + 1
    end
end

-- ── colorToHex ────────────────────────────────────────────────────────────────

print("\n=== colorToHex ===")

-- All known KOReader color names
check("yellow → #FFC107",   BookloreSync:colorToHex("yellow"),  "#FFC107")
check("green  → #4ADE80",   BookloreSync:colorToHex("green"),   "#4ADE80")
check("cyan   → #38BDF8",   BookloreSync:colorToHex("cyan"),    "#38BDF8")
check("pink   → #F472B6",   BookloreSync:colorToHex("pink"),    "#F472B6")
check("orange → #FB923C",   BookloreSync:colorToHex("orange"),  "#FB923C")
check("red    → #FB923C",   BookloreSync:colorToHex("red"),     "#FB923C")
check("purple → #F472B6",   BookloreSync:colorToHex("purple"),  "#F472B6")
check("blue   → #38BDF8",   BookloreSync:colorToHex("blue"),    "#38BDF8")
check("gray   → #FFC107",   BookloreSync:colorToHex("gray"),    "#FFC107")
check("white  → #FFC107",   BookloreSync:colorToHex("white"),   "#FFC107")

-- nil → default yellow
check("nil → #FFC107 (default)",        BookloreSync:colorToHex(nil),         "#FFC107")

-- Unknown color → default yellow
check("unknown 'magenta' → #FFC107",    BookloreSync:colorToHex("magenta"),   "#FFC107")
check("empty string → #FFC107",         BookloreSync:colorToHex(""),          "#FFC107")

-- Case-insensitivity
check("'YELLOW' (upper) → #FFC107",     BookloreSync:colorToHex("YELLOW"),    "#FFC107")
check("'Yellow' (mixed) → #FFC107",     BookloreSync:colorToHex("Yellow"),    "#FFC107")
check("'GREEN' (upper) → #4ADE80",      BookloreSync:colorToHex("GREEN"),     "#4ADE80")
check("'Cyan' (mixed) → #38BDF8",       BookloreSync:colorToHex("Cyan"),      "#38BDF8")
check("'PINK' (upper) → #F472B6",       BookloreSync:colorToHex("PINK"),      "#F472B6")

-- ── drawerToStyle ─────────────────────────────────────────────────────────────

print("\n=== drawerToStyle ===")

-- All known KOReader drawer names
check("lighten    → highlight",      BookloreSync:drawerToStyle("lighten"),    "highlight")
check("underscore → underline",      BookloreSync:drawerToStyle("underscore"), "underline")
check("strikeout  → strikethrough",  BookloreSync:drawerToStyle("strikeout"),  "strikethrough")
check("invert     → highlight",      BookloreSync:drawerToStyle("invert"),     "highlight")

-- nil → default highlight
check("nil → highlight (default)",   BookloreSync:drawerToStyle(nil),          "highlight")

-- Unknown drawer → default highlight
check("unknown 'box' → highlight",   BookloreSync:drawerToStyle("box"),        "highlight")
check("empty string → highlight",    BookloreSync:drawerToStyle(""),           "highlight")

-- Case-insensitivity
check("'LIGHTEN' (upper) → highlight",      BookloreSync:drawerToStyle("LIGHTEN"),    "highlight")
check("'Underscore' (mixed) → underline",   BookloreSync:drawerToStyle("Underscore"), "underline")
check("'STRIKEOUT' (upper) → strikethrough",BookloreSync:drawerToStyle("STRIKEOUT"),  "strikethrough")
check("'INVERT' (upper) → highlight",       BookloreSync:drawerToStyle("INVERT"),     "highlight")

-- ── _generateFilename ─────────────────────────────────────────────────────────

print("\n=== _generateFilename ===")

local bs = BookloreSync

-- extension present → used lowercase
check("epub extension → BookID_1.epub",  bs:_generateFilename({ id = 1, extension = "epub" }), "BookID_1.epub")
check("EPUB (upper) → lowercase",        bs:_generateFilename({ id = 2, extension = "EPUB" }), "BookID_2.epub")
check("pdf extension",                   bs:_generateFilename({ id = 3, extension = "pdf"  }), "BookID_3.pdf")
check("PDF (upper) → lowercase",         bs:_generateFilename({ id = 4, extension = "PDF"  }), "BookID_4.pdf")
check("cbz extension",                   bs:_generateFilename({ id = 5, extension = "cbz"  }), "BookID_5.cbz")

-- missing extension → defaults to epub
check("no extension → epub default",     bs:_generateFilename({ id = 6 }),                     "BookID_6.epub")
check("nil extension → epub default",    bs:_generateFilename({ id = 7, extension = nil }),     "BookID_7.epub")

-- numeric id stringified correctly
check("large numeric id",                bs:_generateFilename({ id = 12345, extension = "epub" }), "BookID_12345.epub")

-- ── formatDuration ────────────────────────────────────────────────────────────

print("\n=== formatDuration ===")

-- edge cases
check("nil → 0s",                bs:formatDuration(nil),    "0s")
check("negative → 0s",           bs:formatDuration(-1),     "0s")
check("string 'abc' → 0s",       bs:formatDuration("abc"),  "0s")
check("0 → 0s",                  bs:formatDuration(0),      "0s")

-- seconds only
check("30s",                     bs:formatDuration(30),     "30s")
check("59s",                     bs:formatDuration(59),     "59s")

-- minutes only (exact)
check("1m",                      bs:formatDuration(60),     "1m")
check("2m",                      bs:formatDuration(120),    "2m")

-- minutes + seconds
check("1m 30s",                  bs:formatDuration(90),     "1m 30s")
check("5m 45s",                  bs:formatDuration(345),    "5m 45s")

-- hours only (exact)
check("1h",                      bs:formatDuration(3600),   "1h")
check("2h",                      bs:formatDuration(7200),   "2h")

-- hours + minutes
check("1h 30m",                  bs:formatDuration(5400),   "1h 30m")

-- hours + seconds (no minutes)
check("1h 1s",                   bs:formatDuration(3601),   "1h 1s")

-- hours + minutes + seconds
check("2h 3m 4s",                bs:formatDuration(7384),   "2h 3m 4s")

-- string numbers are coerced
check("string '90' → 1m 30s",   bs:formatDuration("90"),   "1m 30s")

-- ── roundProgress ─────────────────────────────────────────────────────────────

print("\n=== roundProgress ===")

-- 0 decimal places
bs.progress_decimal_places = 0
check("0dp: 0.0 → 0",        bs:roundProgress(0.0),   0)
check("0dp: 0.4 → 0",        bs:roundProgress(0.4),   0)
check("0dp: 0.5 → 1",        bs:roundProgress(0.5),   1)
check("0dp: 0.9 → 1",        bs:roundProgress(0.9),   1)
check("0dp: 99.9 → 100",     bs:roundProgress(99.9),  100)

-- 1 decimal place
bs.progress_decimal_places = 1
check("1dp: 0.0 → 0.0",      bs:roundProgress(0.0),   0.0)
check("1dp: 50.0 → 50.0",    bs:roundProgress(50.0),  50.0)
check("1dp: 50.04 → 50.0",   bs:roundProgress(50.04), 50.0)
check("1dp: 50.05 → 50.1",   bs:roundProgress(50.05), 50.1)
check("1dp: 99.99 → 100.0",  bs:roundProgress(99.99), 100.0)

-- 2 decimal places
bs.progress_decimal_places = 2
check("2dp: 33.333 → 33.33", bs:roundProgress(33.333), 33.33)
check("2dp: 33.335 → 33.34", bs:roundProgress(33.335), 33.34)

-- ── getBookType ───────────────────────────────────────────────────────────────

print("\n=== getBookType ===")

-- nil → EPUB
check("nil path → EPUB",                 bs:getBookType(nil),                     "EPUB")

-- EPUB variants
check(".epub → EPUB",                    bs:getBookType("/books/novel.epub"),      "EPUB")
check(".EPUB (upper) → EPUB",            bs:getBookType("/books/novel.EPUB"),      "EPUB")

-- PDF
check(".pdf → PDF",                      bs:getBookType("/books/manual.pdf"),      "PDF")
check(".PDF (upper) → PDF",              bs:getBookType("/books/manual.PDF"),      "PDF")

-- CBZ / CBR → CBX
check(".cbz → CBX",                      bs:getBookType("/comics/issue.cbz"),      "CBX")
check(".CBZ (upper) → CBX",              bs:getBookType("/comics/issue.CBZ"),      "CBX")
check(".cbr → CBX",                      bs:getBookType("/comics/issue.cbr"),      "CBX")
check(".CBR (upper) → CBX",              bs:getBookType("/comics/issue.CBR"),      "CBX")

-- unknown extension → EPUB (default)
check(".mobi → EPUB (default)",          bs:getBookType("/books/book.mobi"),       "EPUB")
check(".txt → EPUB (default)",           bs:getBookType("/books/notes.txt"),       "EPUB")

-- no extension → EPUB (default)
check("no extension → EPUB (default)",   bs:getBookType("/books/noextension"),     "EPUB")

-- path with dots in directory name
check("dots in dir, .pdf ext",           bs:getBookType("/my.docs/book.pdf"),      "PDF")

-- ── Results ───────────────────────────────────────────────────────────────────

print(string.format("\n=== Results: %d passed, %d failed ===", pass, fail))
if fail > 0 then os.exit(1) end
