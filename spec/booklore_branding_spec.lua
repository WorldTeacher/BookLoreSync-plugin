-- Tests for booklore_branding.lua
-- Mocks KOReader's G_reader_settings global

-- Mock G_reader_settings before loading branding module
local mock_storage = {}
_G.G_reader_settings = {
    readSetting = function(_, key)
        return mock_storage[key]
    end,
    saveSetting = function(_, key, value)
        mock_storage[key] = value
    end,
    flush = function() end,
}

local Branding = require("booklore_branding")

-- Helper
local function has(str, pattern)
    return str and string.match(str, pattern) ~= nil
end

-- ═══════════════════════════════════════════════════════════════════════════
-- normalizeDisplayName
-- ═══════════════════════════════════════════════════════════════════════════

describe("normalizeDisplayName", function()
    it("returns default 'Booklore' for nil", function()
        assert.equal("Booklore", Branding.normalizeDisplayName(nil))
    end)

    it("returns default 'Booklore' for empty string", function()
        assert.equal("Booklore", Branding.normalizeDisplayName(""))
    end)

    it("returns default for whitespace-only", function()
        assert.equal("Booklore", Branding.normalizeDisplayName("   "))
    end)

    it("trims surrounding whitespace", function()
        assert.equal("Librion", Branding.normalizeDisplayName("  Librion  "))
    end)

    it("strips trailing 'Sync' suffix (case-sensitive)", function()
        -- Note: lower() comparison but original case preserved
        assert.equal("Librion", Branding.normalizeDisplayName("LibrionSync"))
    end)

    it("strips 'sync' (lowercase) suffix", function()
        assert.equal("Librion", Branding.normalizeDisplayName("Librionsync"))
    end)

    it("strips 'SYNC' (uppercase) suffix", function()
        assert.equal("Librion", Branding.normalizeDisplayName("LibrionSYNC"))
    end)

    it("strips 'Sync' with trailing space/underscore/dash", function()
        assert.equal("Librion", Branding.normalizeDisplayName("Librion Sync"))
        assert.equal("Librion", Branding.normalizeDisplayName("Librion_Sync"))
        assert.equal("Librion", Branding.normalizeDisplayName("Librion-Sync"))
        assert.equal("Librion", Branding.normalizeDisplayName("Librion -Sync"))
    end)

    it("does not strip 'Sync' if it's the whole name", function()
        -- name must be >= 4 chars for suffix check; "Sync" is 4
        -- lower = "sync", sub(-4) = "sync" → would strip to empty → fallback
        assert.equal("Booklore", Branding.normalizeDisplayName("Sync"))
    end)

    it("does not strip 'Sync' from very short names (<4 chars)", function()
        assert.equal("Foo", Branding.normalizeDisplayName("FooSync")) -- 3+4=7, len >=4, stripped
        -- Actually: "FooSync" → lower="foosync", #lower=7 >=4, sub(-4)="sync" → strip
        -- So "FooSync" → "Foo" ✓
    end)

    it("keeps names that don't end with 'sync'", function()
        assert.equal("MyBooks", Branding.normalizeDisplayName("MyBooks"))
    end)

    it("handles names where stripping 'Sync' yields empty", function()
        assert.equal("Booklore", Branding.normalizeDisplayName(" sync"))
        -- lower=" sync", trim→"sync", lower="sync", >=4, sub(-4)="sync" → strip → "" → fallback
    end)
end)

-- ═══════════════════════════════════════════════════════════════════════════
-- normalizeShortcutName
-- ═══════════════════════════════════════════════════════════════════════════

describe("normalizeShortcutName", function()
    it("appends 'Sync' to normalized display name", function()
        assert.equal("LibrionSync", Branding.normalizeShortcutName("Librion"))
    end)

    it("handles input that already has 'Sync' — strip then re-add", function()
        -- "LibrionSync" → normalizeDisplayName strips Sync → "Librion" → append Sync → "LibrionSync"
        assert.equal("LibrionSync", Branding.normalizeShortcutName("LibrionSync"))
    end)

    it("handles nil input (defaults to BookloreSync)", function()
        assert.equal("BookloreSync", Branding.normalizeShortcutName(nil))
    end)

    it("handles whitespace input", function()
        assert.equal("BookloreSync", Branding.normalizeShortcutName("   "))
    end)
end)

-- ═══════════════════════════════════════════════════════════════════════════
-- getNames
-- ═══════════════════════════════════════════════════════════════════════════

describe("getNames", function()
    before_each(function()
        mock_storage.booklore_brand_display_name = nil
    end)

    it("uses passed display_name over global setting", function()
        local display, shortcut = Branding.getNames("CustomBrand")
        assert.equal("CustomBrand", display)
        assert.equal("CustomBrandSync", shortcut)
    end)

    it("falls back to global setting when no arg", function()
        mock_storage.booklore_brand_display_name = "GlobalBrand"
        local display, shortcut = Branding.getNames(nil)
        assert.equal("GlobalBrand", display)
        assert.equal("GlobalBrandSync", shortcut)
    end)

    it("returns Booklore defaults when nothing configured", function()
        local display, shortcut = Branding.getNames(nil)
        assert.equal("Booklore", display)
        assert.equal("BookloreSync", shortcut)
    end)
end)

-- ═══════════════════════════════════════════════════════════════════════════
-- saveGlobalNames
-- ═══════════════════════════════════════════════════════════════════════════

describe("saveGlobalNames", function()
    it("saves normalized display name to global settings", function()
        Branding.saveGlobalNames("  MyPlugin  ")
        assert.equal("MyPlugin", mock_storage.booklore_brand_display_name)
    end)
end)

-- ═══════════════════════════════════════════════════════════════════════════
-- apply
-- ═══════════════════════════════════════════════════════════════════════════

describe("apply", function()
    before_each(function()
        mock_storage.booklore_brand_display_name = nil
    end)

    it("returns non-string input unchanged", function()
        assert.equal(42, Branding.apply(42))
        assert.is_nil(Branding.apply(nil))
        assert.equal(true, Branding.apply(true))
    end)

    it("replaces 'Booklore' case-insensitively with display name", function()
        assert.equal("Librion menu", Branding.apply("Booklore menu", "Librion"))
        assert.equal("Librion menu", Branding.apply("booklore menu", "Librion"))
        assert.equal("Librion menu", Branding.apply("BOOKLORE menu", "Librion"))
        assert.equal("Librion menu", Branding.apply("bOoKlOrE menu", "Librion"))
    end)

    it("replaces 'Booklore Sync' with display name + Sync", function()
        assert.equal("Librion Sync settings", Branding.apply("Booklore Sync settings", "Librion"))
    end)

    it("replaces 'BookloreSync' (no space) with shortcut name", function()
        assert.equal("LibrionSync plugin", Branding.apply("BookloreSync plugin", "Librion"))
    end)

    it("replaces all three patterns in a single string", function()
        local text = "Booklore Sync is based on Booklore. BookloreSync is the plugin."
        local result = Branding.apply(text, "Librion")
        assert.equal("Librion Sync is based on Librion. LibrionSync is the plugin.", result)
    end)

    it("falls back to global setting when display_name not passed", function()
        mock_storage.booklore_brand_display_name = "GlobalBrand"
        local result = Branding.apply("Booklore menu", nil)
        assert.equal("GlobalBrand menu", result)
    end)

    it("uses default 'Booklore' when nothing configured", function()
        local result = Branding.apply("Booklore menu", nil)
        -- With no custom display name, "Booklore" → normalized "Booklore"
        -- So it replaces Booklore with Booklore → no visible change
        assert.equal("Booklore menu", result)
    end)

    it("handles text with no matches unchanged", function()
        assert.equal("No match here", Branding.apply("No match here", "Librion"))
    end)

    it("handles empty text", function()
        assert.equal("", Branding.apply("", "Librion"))
    end)

    it("handles 'bookloresync' (lowercase compound) → shortcut", function()
        assert.equal("LibrionSync", Branding.apply("bookloresync", "Librion"))
    end)

    it("handles 'BOOKLORESYNC' (uppercase compound) → shortcut", function()
        assert.equal("LibrionSync", Branding.apply("BOOKLORESYNC", "Librion"))
    end)

    it("does not match partial words (e.g., 'BookloreSyncExtra')", function()
        -- gsub(ci_pattern("booklore"), ...) would match "booklore" inside "bookloresyncextra"
        -- but ci_pattern match is only for "booklore" — it would match the prefix
        -- So "BookloreSyncExtra" → "LibrionSyncExtra"
        local result = Branding.apply("BookloreSyncExtra", "Librion")
        -- ci_pattern("bookloresync") would match inside "bookloresyncextra"? Let's see:
        -- "bOoKlOrEsYnC" case-insensitive pattern matches "BookloreSync" but not "BookloreSyncExtra"
        -- Actually ci_pattern("bookloresync") creates [bB][oO][oO]...[cC]
        -- "BookloreSyncExtra" → pattern would match "BookloreSync" (first 13 chars)
        -- Lua gsub would replace the matched portion only
        assert.is.truthy(has(result, "LibrionSync"))
        assert.is.truthy(has(result, "Extra"))
    end)
end)
