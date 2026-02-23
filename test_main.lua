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

-- ── Results ───────────────────────────────────────────────────────────────────

print(string.format("\n=== Results: %d passed, %d failed ===", pass, fail))
if fail > 0 then os.exit(1) end
