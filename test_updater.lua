#!/usr/bin/env lua
--[[--
Unit tests for Booklore Updater pure functions:
  - parseVersion, compareVersions, formatBytes (original)
  - parseChangelogForVersion, cleanChangelog (added)

Copy-pasted from booklore_updater.lua to avoid KOReader runtime dependencies.

Run with:  lua test_updater.lua
--]]--

-- ── Functions under test ──────────────────────────────────────────────────────

local function parseVersion(version_string)
    if not version_string then
        return nil
    end

    version_string = version_string:gsub("^v", "")

    if version_string:match("dev") then
        return {major = 0, minor = 0, patch = 0, is_dev = true}
    end

    local major, minor, patch = version_string:match("^(%d+)%.(%d+)%.(%d+)")

    if not major then
        return nil
    end

    return {
        major = tonumber(major),
        minor = tonumber(minor),
        patch = tonumber(patch),
        is_dev = false
    }
end

local function compareVersions(v1, v2)
    if not v1 or not v2 then
        return 0
    end

    -- Dev versions are always older
    if v1.is_dev and not v2.is_dev then
        return -1
    end
    if not v1.is_dev and v2.is_dev then
        return 1
    end
    if v1.is_dev and v2.is_dev then
        return 0
    end

    -- Compare major version
    if v1.major < v2.major then return -1 end
    if v1.major > v2.major then return 1 end

    -- Compare minor version
    if v1.minor < v2.minor then return -1 end
    if v1.minor > v2.minor then return 1 end

    -- Compare patch version
    if v1.patch < v2.patch then return -1 end
    if v1.patch > v2.patch then return 1 end

    return 0
end

local function formatBytes(bytes)
    if not bytes or bytes == 0 then
        return "Unknown size"
    end

    if bytes < 1024 then
        return string.format("%d B", bytes)
    elseif bytes < 1024 * 1024 then
        return string.format("%.1f KB", bytes / 1024)
    else
        return string.format("%.1f MB", bytes / (1024 * 1024))
    end
end

local function parseChangelogForVersion(changelog_content, version)
    if not changelog_content or not version then
        return nil
    end

    local version_clean = version:gsub("^v", "")

    local lines = {}
    for line in changelog_content:gmatch("[^\r\n]+") do
        table.insert(lines, line)
    end

    local in_section = false
    local section_lines = {}

    for _, line in ipairs(lines) do
        if line:match("^##?%s+%[") then
            if line:match("%[" .. version_clean:gsub("%.", "%%.") .. "%]") then
                in_section = true
            else
                if in_section then
                    break
                end
            end
        elseif in_section then
            table.insert(section_lines, line)
        end
    end

    if #section_lines == 0 then
        return nil
    end

    local changelog_section = table.concat(section_lines, "\n")
    changelog_section = changelog_section:match("^%s*(.-)%s*$")

    return changelog_section
end

local function cleanChangelog(changelog_text)
    if not changelog_text then
        return ""
    end

    local lines = {}
    for line in changelog_text:gmatch("[^\r\n]+") do
        table.insert(lines, line)
    end

    local cleaned_lines = {}

    for _, line in ipairs(lines) do
        local cleaned_line = line

        -- Replace [text](url) markdown links with just the text
        cleaned_line = cleaned_line:gsub("%[([^%]]+)%]%(([^%)]+)%)", "%1")

        -- Remove inline commit hash references like (abc1234) or ([abc1234])
        cleaned_line = cleaned_line:gsub("%s*%(%[?[a-f0-9]+%]?%)%s*", " ")

        -- Remove bare URLs
        cleaned_line = cleaned_line:gsub("https?://[^%s]+", "")

        -- Collapse multiple spaces
        cleaned_line = cleaned_line:gsub("%s+", " ")

        -- Trim leading/trailing whitespace
        cleaned_line = cleaned_line:match("^%s*(.-)%s*$")

        if cleaned_line ~= "" then
            table.insert(cleaned_lines, cleaned_line)
        end
    end

    return table.concat(cleaned_lines, "\n")
end

-- ── Test harness ──────────────────────────────────────────────────────────────

local passed = 0
local failed = 0

local function check(description, got, expected)
    if got == expected then
        print(string.format("  ✓ PASS: %s", description))
        passed = passed + 1
    else
        print(string.format("  ✗ FAIL: %s", description))
        print(string.format("          expected: %s", tostring(expected)))
        print(string.format("          got:      %s", tostring(got)))
        failed = failed + 1
    end
end

-- ── parseVersion ─────────────────────────────────────────────────────────────

print("\n=== Testing Version Parsing ===")

local function parsed_str(v)
    if not v then return "nil" end
    if v.is_dev then return "DEV" end
    return string.format("%d.%d.%d", v.major, v.minor, v.patch)
end

check("1.0.5 parses to 1.0.5",          parsed_str(parseVersion("1.0.5")),             "1.0.5")
check("v1.0.5 strips v prefix",         parsed_str(parseVersion("v1.0.5")),            "1.0.5")
check("2.1.3 parses to 2.1.3",          parsed_str(parseVersion("2.1.3")),             "2.1.3")
check("10.20.30 parses to 10.20.30",    parsed_str(parseVersion("10.20.30")),          "10.20.30")
check("0.0.0-dev → DEV",                parsed_str(parseVersion("0.0.0-dev")),         "DEV")
check("0.0.0-dev+hash → DEV",           parsed_str(parseVersion("0.0.0-dev+179f0b9")), "DEV")
check("nil → nil",                       parseVersion(nil),                             nil)
check("invalid string → nil",           parseVersion("not-a-version"),                 nil)

-- ── compareVersions ───────────────────────────────────────────────────────────

print("\n=== Testing Version Comparison ===")

local function cmp(a, b)
    return compareVersions(parseVersion(a), parseVersion(b))
end

check("1.0.5 < 1.0.6",                      cmp("1.0.5",           "1.0.6"),  -1)
check("1.0.6 > 1.0.5",                      cmp("1.0.6",           "1.0.5"),   1)
check("1.0.5 = 1.0.5",                      cmp("1.0.5",           "1.0.5"),   0)
check("2.0.0 > 1.9.9",                      cmp("2.0.0",           "1.9.9"),   1)
check("1.9.9 < 2.0.0",                      cmp("1.9.9",           "2.0.0"),  -1)
check("dev < 1.0.5",                         cmp("0.0.0-dev",       "1.0.5"),  -1)
check("1.0.5 > dev",                         cmp("1.0.5",           "0.0.0-dev"), 1)
check("dev = dev",                           cmp("0.0.0-dev",       "0.0.0-dev"), 0)
check("v1.0.5 < 1.0.6 (v prefix)",          cmp("v1.0.5",          "1.0.6"),  -1)
check("dev+hash < release",                  cmp("0.0.0-dev+179f0b9", "1.1.1"), -1)
check("minor bump: 1.1.0 > 1.0.9",          cmp("1.1.0",           "1.0.9"),   1)
check("equal major/minor, patch differs",   cmp("3.4.1",           "3.4.0"),   1)
check("nil v1 → 0",                          compareVersions(nil, parseVersion("1.0.0")), 0)
check("nil v2 → 0",                          compareVersions(parseVersion("1.0.0"), nil), 0)

-- ── formatBytes ───────────────────────────────────────────────────────────────

print("\n=== Testing Format Bytes ===")

check("0 bytes → Unknown size",     formatBytes(0),       "Unknown size")
check("nil → Unknown size",         formatBytes(nil),     "Unknown size")
check("500 bytes → 500 B",          formatBytes(500),     "500 B")
check("1023 bytes → 1023 B",        formatBytes(1023),    "1023 B")
check("1024 bytes → 1.0 KB",        formatBytes(1024),    "1.0 KB")
check("36419 bytes → 35.6 KB",      formatBytes(36419),   "35.6 KB")
check("1048576 bytes → 1.0 MB",     formatBytes(1048576), "1.0 MB")
check("2097152 bytes → 2.0 MB",     formatBytes(2097152), "2.0 MB")

-- ── parseChangelogForVersion ──────────────────────────────────────────────────

print("\n=== Testing parseChangelogForVersion ===")

local SAMPLE_CHANGELOG = [[
# [3.4.0] - 2025-01-15
### Added
- New sync mode

### Fixed
- Token refresh bug

# [3.3.0] - 2024-12-01
### Added
- ISBN search support

# [1.0.0] - 2024-01-01
### Added
- Initial release
]]

local section_340 = parseChangelogForVersion(SAMPLE_CHANGELOG, "3.4.0")
check("extracts body for 3.4.0",
    section_340 and section_340:find("New sync mode") ~= nil, true)

check("section does not bleed into 3.3.0",
    section_340 and section_340:find("ISBN search") == nil, true)

local section_330 = parseChangelogForVersion(SAMPLE_CHANGELOG, "3.3.0")
check("extracts body for 3.3.0",
    section_330 and section_330:find("ISBN search") ~= nil, true)

-- v-prefix stripped
local section_v = parseChangelogForVersion(SAMPLE_CHANGELOG, "v3.3.0")
check("'v' prefix stripped from version",
    section_v and section_v:find("ISBN search") ~= nil, true)

-- Missing version → nil
check("missing version → nil",
    parseChangelogForVersion(SAMPLE_CHANGELOG, "9.9.9"), nil)

-- nil content → nil
check("nil content → nil",
    parseChangelogForVersion(nil, "3.4.0"), nil)

-- nil version → nil
check("nil version → nil",
    parseChangelogForVersion(SAMPLE_CHANGELOG, nil), nil)

-- Dots in version are treated as literals (not regex wildcards)
local tricky_log = "# [1.0.0]\n- real\n# [1X0X0]\n- fake\n"
local tricky = parseChangelogForVersion(tricky_log, "1.0.0")
check("dots in version escaped (no false match on 1X0X0)",
    tricky and tricky:find("real") ~= nil and tricky:find("fake") == nil, true)

-- Single-version changelog (no following heading to stop at)
local single = parseChangelogForVersion("# [2.0.0]\n### Added\n- Feature A\n", "2.0.0")
check("single version changelog extracted",
    single and single:find("Feature A") ~= nil, true)

-- ── cleanChangelog ────────────────────────────────────────────────────────────

print("\n=== Testing cleanChangelog ===")

-- nil → empty string
check("nil input → empty string", cleanChangelog(nil), "")

-- Markdown link [text](url) → text only
check("markdown link → text only",
    cleanChangelog("- Fixed [the bug](https://github.com/repo/issues/1)"),
    "- Fixed the bug")

-- Inline commit hash (hex only, 7 chars) removed
local no_hash = cleanChangelog("- Fix token refresh (a1b2c3d)")
check("commit hash reference removed",
    no_hash:find("a1b2c3d") == nil, true)

-- Bare URL removed
local no_url = cleanChangelog("See https://example.com for details")
check("bare URL removed", no_url:find("https://") == nil, true)

-- Normal lines preserved
local normal = cleanChangelog("### Added\n- New ISBN search feature")
check("normal lines preserved",
    normal:find("### Added") ~= nil and normal:find("New ISBN search feature") ~= nil, true)

-- Empty lines are dropped
local no_blank = cleanChangelog("line one\n\nline two")
check("blank lines dropped", no_blank:find("\n\n") == nil, true)

-- Multiple spaces collapsed
check("multiple spaces collapsed",
    cleanChangelog("too   many    spaces"), "too many spaces")

-- Leading/trailing whitespace trimmed from each line
check("leading whitespace trimmed",
    cleanChangelog("   trimmed   "), "trimmed")

-- Combined: link + commit hash in same line
local combined = cleanChangelog("- See [PR #42](https://github.com/r/p/pull/42) (deadbeef)")
check("combined link + hash cleaned",
    combined:find("https://") == nil and combined:find("deadbeef") == nil, true)

-- ── Summary ───────────────────────────────────────────────────────────────────

print(string.format("\n=== Results: %d passed, %d failed ===\n", passed, failed))
os.exit(failed == 0 and 0 or 1)
