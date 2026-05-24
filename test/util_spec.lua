-- Tests for booklore_util.lua
-- busted parameter order: assert.is.string.match(pattern, string) — SWAPPED from string.match

local util = require("booklore_util")

-- Helper: check that string contains pattern (avoids luassert swapped-arg confusion)
local function has(str, pattern)
    return string.match(str, pattern) ~= nil
end

-- ═══════════════════════════════════════════════════════════════════════════
-- redactUrls
-- ═══════════════════════════════════════════════════════════════════════════

describe("redactUrls", function()
    it("redacts a single HTTP URL", function()
        local r = util.redactUrls("GET https://example.com/api/books")
        assert.is.truthy(has(r, "%[REDACTED_URL%]"))
        assert.is_not.truthy(has(r, "https://"))
    end)

    it("redacts multiple URLs and replaces both", function()
        local r = util.redactUrls("http://a.com and https://b.com/path?q=1")
        -- count [REDACTED_URL] occurrences
        local _, count = r:gsub("%[REDACTED_URL%]", "")
        assert.equal(2, count)
    end)

    it("joins multiple arguments with space before redacting", function()
        local r = util.redactUrls("GET", "https://example.com/api", "code 200")
        assert.is.truthy(has(r, "GET %[REDACTED_URL%] code 200"))
    end)

    it("leaves non-URL text unchanged", function()
        assert.equal("no urls here at all",
            util.redactUrls("no urls here at all"))
    end)

    it("handles empty input", function()
        assert.equal("", util.redactUrls())
    end)

    it("handles nil argument (tostring gives 'nil')", function()
        assert.equal("nil", util.redactUrls(nil))
    end)

    it("handles URL at end of string", function()
        local r = util.redactUrls("Loaded from https://example.com")
        assert.equal("Loaded from [REDACTED_URL]", r)
    end)

    it("redacts URLs with ports and userinfo", function()
        local r = util.redactUrls("proxy https://user:pass@host:8443/x")
        assert.is.truthy(has(r, "%[REDACTED_URL%]"))
        assert.is_not.truthy(has(r, "user:pass"))
    end)

    it("does not redact non-URL colon strings", function()
        local r = util.redactUrls("error at booklore_shelf_sync.lua:126")
        assert.is_not.truthy(has(r, "REDACTED"))
    end)
end)

-- ═══════════════════════════════════════════════════════════════════════════
-- joinDownloadPath
-- ═══════════════════════════════════════════════════════════════════════════

describe("joinDownloadPath", function()
    it("joins normal dir and name", function()
        assert.equal("/mnt/ext1/Books/book.epub",
            util.joinDownloadPath("/mnt/ext1/Books", "book.epub"))
    end)

    it("strips trailing slashes from dir", function()
        assert.equal("/mnt/ext1/Books/book.epub",
            util.joinDownloadPath("/mnt/ext1/Books///", "book.epub"))
    end)

    it("handles root directory '/'", function()
        assert.equal("/book.epub", util.joinDownloadPath("/", "book.epub"))
    end)

    it("handles empty dir string", function()
        assert.equal("/book.epub", util.joinDownloadPath("", "book.epub"))
    end)

    it("handles nil dir (tostring → '')", function()
        assert.equal("/book.epub", util.joinDownloadPath(nil, "book.epub"))
    end)

    it("preserves multi-level paths", function()
        assert.equal("/a/b/c/d.txt",
            util.joinDownloadPath("/a/b/c", "d.txt"))
    end)

    it("handles spaces in path", function()
        assert.equal("/mnt/ext1/KO Reader/test file.epub",
            util.joinDownloadPath("/mnt/ext1/KO Reader", "test file.epub"))
    end)

    it("handles German umlauts in path", function()
        assert.equal("/mnt/ext1/Bücher/test.epub",
            util.joinDownloadPath("/mnt/ext1/Bücher", "test.epub"))
    end)
end)

-- ═══════════════════════════════════════════════════════════════════════════
-- sanitiseFilenameStem
-- ═══════════════════════════════════════════════════════════════════════════

describe("sanitiseFilenameStem", function()
    it("removes filesystem-unsafe characters (colon, slash, etc.)", function()
        -- gsub with '' removes chars entirely — no space substitution
        assert.equal("TestBook", util.sanitiseFilenameStem('Test:/Book*?"<>|'))
    end)

    it("removes backslashes and forward slashes (no replacement)", function()
        assert.equal("pathfilename", util.sanitiseFilenameStem("path\\file/name"))
    end)

    it("collapses multiple spaces into one", function()
        assert.equal("a b c", util.sanitiseFilenameStem("a   b    c"))
    end)

    it("trims leading and trailing whitespace", function()
        assert.equal("hello", util.sanitiseFilenameStem("   hello   "))
    end)

    it("handles empty string", function()
        assert.equal("", util.sanitiseFilenameStem(""))
    end)

    it("handles nil input", function()
        assert.equal("", util.sanitiseFilenameStem(nil))
    end)

    it("returns empty for string of only unsafe chars", function()
        assert.equal("", util.sanitiseFilenameStem('/:*?"<>|\\'))
    end)

    it("preserves Unicode / non-ASCII characters", function()
        local s = util.sanitiseFilenameStem("Bücher über Äonen")
        assert.is.truthy(has(s, "ü"))
        assert.is.truthy(has(s, "Ä"))
    end)

    it("preserves digits and hyphens", function()
        assert.equal("Book-123", util.sanitiseFilenameStem("Book-123"))
    end)

    it("preserves dots (no special meaning in stems)", function()
        assert.equal("Dr. Who", util.sanitiseFilenameStem("Dr. Who"))
    end)
end)

-- ═══════════════════════════════════════════════════════════════════════════
-- generateFilename
-- ═══════════════════════════════════════════════════════════════════════════

describe("generateFilename", function()
    local base_book = { id = 42, title = "Der Prozess", extension = "epub" }

    it("generates filename from title + id", function()
        assert.equal("Der Prozess_42.epub", util.generateFilename(base_book))
    end)

    it("uses original_filename when flag is true", function()
        local b = { id = 42, title = "Short", extension = "pdf", original_filename = "original.pdf" }
        assert.equal("original_42.pdf", util.generateFilename(b, true))
    end)

    it("falls back to title when original_filename is empty with flag", function()
        local b = { id = 1, title = "Fallback", extension = "mobi", original_filename = "" }
        assert.equal("Fallback_1.mobi", util.generateFilename(b, true))
    end)

    it("uses title when original_filename flag is false", function()
        local b = { id = 1, title = "Title", extension = "epub", original_filename = "ignored.pdf" }
        assert.equal("Title_1.epub", util.generateFilename(b, false))
    end)

    it("falls back to BookID_ pattern when title is nil", function()
        local b = { id = 77, extension = "epub" }
        assert.equal("BookID_77.epub", util.generateFilename(b))
    end)

    it("falls back to BookID_ when title is empty string", function()
        local b = { id = 77, title = "", extension = "epub" }
        assert.equal("BookID_77.epub", util.generateFilename(b))
    end)

    it("defaults extension to epub when missing", function()
        local b = { id = 5, title = "No Ext" }
        assert.equal("No Ext_5.epub", util.generateFilename(b))
    end)

    it("lowercases extension", function()
        local b = { id = 5, title = "Test", extension = "PDF" }
        assert.equal("Test_5.pdf", util.generateFilename(b))
    end)

    it("sanitises title before using as stem (strip unsafe chars)", function()
        local b = { id = 1, title = 'A:B*C?"D' }
        assert.equal("ABCD_1.epub", util.generateFilename(b))
    end)

    it("strips extension from original_filename to get stem", function()
        local b = { id = 99, title = "Wrong", original_filename = "correct_name.epub" }
        assert.equal("correct_name_99.epub", util.generateFilename(b, true))
    end)

    it("uses full original_filename if no dot extension", function()
        local b = { id = 99, title = "Wrong", original_filename = "noextension" }
        assert.equal("noextension_99.epub", util.generateFilename(b, true))
    end)

    it("truncates very long titles to stay within ~160 chars", function()
        local long = string.rep("A", 200)
        local b = { id = 999, title = long, extension = "epub" }
        local result = util.generateFilename(b)
        assert.is.truthy(#result <= 160)
        assert.is.truthy(has(result, "_999%.epub$"))
    end)

    it("truncation removes trailing whitespace after cut", function()
        local long = "Title with trailing spaces   " .. string.rep("A", 180)
        local b = { id = 1, title = long, extension = "epub" }
        local result = util.generateFilename(b)
        assert.is_not.truthy(has(result, "%s+_1%.epub$"))
    end)

    it("handles string book id via concatenation", function()
        local b = { id = "string_id", title = "T", extension = "epub" }
        local result = util.generateFilename(b)
        assert.is.truthy(has(result, "_string_id%.epub$"))
    end)

    it("handles nil extension → defaults to epub", function()
        local b = { id = 1, title = "X", extension = nil }
        assert.is.truthy(has(util.generateFilename(b), "%.epub$"))
    end)
end)

-- ═══════════════════════════════════════════════════════════════════════════
-- roundToInt
-- ═══════════════════════════════════════════════════════════════════════════

describe("roundToInt", function()
    it("rounds .5 up", function()
        assert.equal(4, util.roundToInt(3.5))
    end)

    it("rounds .4 down", function()
        assert.equal(3, util.roundToInt(3.4))
    end)

    it("rounds .6 up", function()
        assert.equal(4, util.roundToInt(3.6))
    end)

    it("handles integers", function()
        assert.equal(7, util.roundToInt(7))
    end)

    it("handles negative numbers (floor(n+0.5) = floor(-3.0) = -3)", function()
        assert.equal(-3, util.roundToInt(-3.4))
        assert.equal(-3, util.roundToInt(-3.5))
        assert.equal(-4, util.roundToInt(-3.6))
    end)

    it("handles zero", function()
        assert.equal(0, util.roundToInt(0))
        assert.equal(0, util.roundToInt(0.0))
    end)

    it("returns nil for nil input", function()
        assert.is_nil(util.roundToInt(nil))
    end)

    it("returns nil for non-numeric string", function()
        assert.is_nil(util.roundToInt("hello"))
    end)

    it("handles very large numbers", function()
        local n = util.roundToInt(9999999999.5)
        assert.equal(10000000000, n)
    end)
end)

-- ═══════════════════════════════════════════════════════════════════════════
-- roundKoreaderSyncPercentage
-- ═══════════════════════════════════════════════════════════════════════════

describe("roundKoreaderSyncPercentage", function()
    it("rounds to 4 decimal places", function()
        assert.equal(0.1235, util.roundKoreaderSyncPercentage(0.12345678))
    end)

    it("clamps values above 1 to 1", function()
        assert.equal(1.0, util.roundKoreaderSyncPercentage(1.5))
    end)

    it("clamps values below 0 to 0", function()
        assert.equal(0.0, util.roundKoreaderSyncPercentage(-0.1))
    end)

    it("handles 0", function()
        assert.equal(0.0, util.roundKoreaderSyncPercentage(0))
    end)

    it("handles exactly 1", function()
        assert.equal(1.0, util.roundKoreaderSyncPercentage(1))
    end)

    it("handles nil → returns 0", function()
        assert.equal(0.0, util.roundKoreaderSyncPercentage(nil))
    end)

    it("handles string number", function()
        assert.is.truthy(util.roundKoreaderSyncPercentage("0.5") > 0)
    end)

    it("handles edge: 0.00005 rounds to 0.0001", function()
        assert.equal(0.0001, util.roundKoreaderSyncPercentage(0.00005))
    end)

    it("handles edge: 0.99995 rounds to 1.0", function()
        assert.equal(1.0, util.roundKoreaderSyncPercentage(0.99995))
    end)
end)

-- ═══════════════════════════════════════════════════════════════════════════
-- colorToHex
-- ═══════════════════════════════════════════════════════════════════════════

describe("colorToHex", function()
    it("maps known colours to hex", function()
        assert.equal("#FFC107", util.colorToHex("yellow"))
        assert.equal("#4ADE80", util.colorToHex("green"))
        assert.equal("#38BDF8", util.colorToHex("cyan"))
        assert.equal("#F472B6", util.colorToHex("pink"))
        assert.equal("#FB923C", util.colorToHex("orange"))
    end)

    it("maps red → orange (nearest warm hue)", function()
        assert.equal("#FB923C", util.colorToHex("red"))
    end)

    it("maps purple → pink (nearest violet hue)", function()
        assert.equal("#F472B6", util.colorToHex("purple"))
    end)

    it("maps blue → cyan (nearest cool hue)", function()
        assert.equal("#38BDF8", util.colorToHex("blue"))
    end)

    it("maps gray/white → yellow (neutral fallback)", function()
        assert.equal("#FFC107", util.colorToHex("gray"))
        assert.equal("#FFC107", util.colorToHex("white"))
    end)

    it("is case-insensitive", function()
        assert.equal("#FFC107", util.colorToHex("YELLOW"))
        assert.equal("#FFC107", util.colorToHex("Yellow"))
    end)

    it("returns yellow for unknown colour", function()
        assert.equal("#FFC107", util.colorToHex("magenta"))
    end)

    it("returns yellow for nil", function()
        assert.equal("#FFC107", util.colorToHex(nil))
    end)
end)

-- ═══════════════════════════════════════════════════════════════════════════
-- drawerToStyle
-- ═══════════════════════════════════════════════════════════════════════════

describe("drawerToStyle", function()
    it("maps lighten → highlight", function()
        assert.equal("highlight", util.drawerToStyle("lighten"))
    end)

    it("maps underscore → underline", function()
        assert.equal("underline", util.drawerToStyle("underscore"))
    end)

    it("maps strikeout → strikethrough", function()
        assert.equal("strikethrough", util.drawerToStyle("strikeout"))
    end)

    it("maps invert → highlight", function()
        assert.equal("highlight", util.drawerToStyle("invert"))
    end)

    it("is case-insensitive", function()
        assert.equal("underline", util.drawerToStyle("UNDERSCORE"))
    end)

    it("returns highlight for unknown drawer", function()
        assert.equal("highlight", util.drawerToStyle("dotted"))
    end)

    it("returns highlight for nil", function()
        assert.equal("highlight", util.drawerToStyle(nil))
    end)
end)

-- ═══════════════════════════════════════════════════════════════════════════
-- stableSerializeValue
-- ═══════════════════════════════════════════════════════════════════════════

describe("stableSerializeValue", function()
    it("serializes nil as empty string", function()
        assert.equal("", util.stableSerializeValue(nil))
    end)

    it("serializes booleans", function()
        assert.equal("true", util.stableSerializeValue(true))
        assert.equal("false", util.stableSerializeValue(false))
    end)

    it("serializes numbers", function()
        assert.equal("42", util.stableSerializeValue(42))
        assert.equal("3.14", util.stableSerializeValue(3.14))
    end)

    it("serializes strings", function()
        assert.equal("hello", util.stableSerializeValue("hello"))
    end)

    it("serializes empty table to {}", function()
        assert.equal("{}", util.stableSerializeValue({}))
    end)

    it("serializes flat table with sorted keys", function()
        local r = util.stableSerializeValue({ b = 2, a = 1, c = 3 })
        assert.equal("{a=1,b=2,c=3}", r)
    end)

    it("serializes nested tables recursively", function()
        local r = util.stableSerializeValue({ x = { b = 2, a = 1 } })
        assert.equal("{x={a=1,b=2}}", r)
    end)

    it("handles mixed key types (string + number keys)", function()
        local r = util.stableSerializeValue({ [1] = "one", name = "test" })
        assert.is.truthy(has(r, "1=one"))
        assert.is.truthy(has(r, "name=test"))
    end)
end)

-- ═══════════════════════════════════════════════════════════════════════════
-- unixToISO8601
-- ═══════════════════════════════════════════════════════════════════════════

describe("unixToISO8601", function()
    it("formats a known timestamp", function()
        local result = util.unixToISO8601(1747246200)
        assert.is.truthy(has(result, "^%d%d%d%d%-%d%d%-%d%dT%d%d:%d%d:%d%dZ$"))
    end)

    it("returns a string with Z suffix", function()
        local now = os.time()
        local result = util.unixToISO8601(now)
        assert.is.truthy(has(result, "Z$"))
    end)

    it("handles borderline epoch (0) → 1970-01-01T00:00:00Z UTC", function()
        local result = util.unixToISO8601(0)
        assert.is.truthy(has(result, "^1970%-01%-01T"))
    end)

    it("handles nil → uses os.time()", function()
        local result = util.unixToISO8601(nil)
        assert.is.truthy(has(result, "^%d%d%d%d%-"))
    end)
end)

-- ═══════════════════════════════════════════════════════════════════════════
-- parseISO8601
-- ═══════════════════════════════════════════════════════════════════════════

describe("parseISO8601", function()
    it("parses a valid ISO 8601 string", function()
        local ts = util.parseISO8601("2026-05-14T19:30:00Z")
        assert.is.truthy(ts)
        assert.is.truthy(ts > 0)
    end)

    it("returns nil for nil input", function()
        assert.is_nil(util.parseISO8601(nil))
    end)

    it("returns nil for malformed string", function()
        assert.is_nil(util.parseISO8601("not a date"))
    end)

    it("returns nil for empty string", function()
        assert.is_nil(util.parseISO8601(""))
    end)
end)

-- ═══════════════════════════════════════════════════════════════════════════
-- getTimingNowMs
-- ═══════════════════════════════════════════════════════════════════════════

describe("getTimingNowMs", function()
    it("returns a positive number", function()
        assert.is.number(util.getTimingNowMs())
        assert.is.truthy(util.getTimingNowMs() > 0)
    end)

    it("is monotonic (two calls → increasing or equal)", function()
        local t1 = util.getTimingNowMs()
        for _ = 1, 50000 do end
        local t2 = util.getTimingNowMs()
        assert.is.truthy(t2 >= t1)
    end)
end)
