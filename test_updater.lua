#!/usr/bin/env lua
--[[--
Test script for Booklore Updater version comparison logic
Tests the core version parsing and comparison functions
--]]

-- Standalone version of parseVersion
local function parseVersion(version_string)
    if not version_string then
        return nil
    end
    
    -- Strip leading 'v' if present
    version_string = version_string:gsub("^v", "")
    
    -- Check for dev version
    if version_string:match("dev") then
        return {major = 0, minor = 0, patch = 0, is_dev = true}
    end
    
    -- Parse semantic version (X.Y.Z)
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

-- Standalone version of compareVersions
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
    
    -- Versions are equal
    return 0
end

-- Standalone version of formatBytes
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

-- Test version parsing
print("\n=== Testing Version Parsing ===")
local test_versions = {
    "1.0.5",
    "v1.0.5",
    "2.1.3",
    "0.0.0-dev",
    "0.0.0-dev+179f0b9",
    "10.20.30",
}

for _, version_str in ipairs(test_versions) do
    local parsed = parseVersion(version_str)
    if parsed then
        if parsed.is_dev then
            print(string.format("  %s -> DEV VERSION", version_str))
        else
            print(string.format("  %s -> %d.%d.%d", version_str, parsed.major, parsed.minor, parsed.patch))
        end
    else
        print(string.format("  %s -> INVALID", version_str))
    end
end

-- Test version comparison
print("\n=== Testing Version Comparison ===")
local test_cases = {
    {"1.0.5", "1.0.6", -1, "1.0.5 < 1.0.6"},
    {"1.0.6", "1.0.5", 1, "1.0.6 > 1.0.5"},
    {"1.0.5", "1.0.5", 0, "1.0.5 = 1.0.5"},
    {"2.0.0", "1.9.9", 1, "2.0.0 > 1.9.9"},
    {"1.9.9", "2.0.0", -1, "1.9.9 < 2.0.0"},
    {"0.0.0-dev", "1.0.5", -1, "dev < 1.0.5"},
    {"1.0.5", "0.0.0-dev", 1, "1.0.5 > dev"},
    {"v1.0.5", "1.0.6", -1, "v1.0.5 < 1.0.6"},
    {"0.0.0-dev+179f0b9", "1.1.1", -1, "current dev < 1.1.1 (should trigger update)"},
}

local passed = 0
local failed = 0

for _, test in ipairs(test_cases) do
    local v1_str, v2_str, expected, description = test[1], test[2], test[3], test[4]
    local v1 = parseVersion(v1_str)
    local v2 = parseVersion(v2_str)
    local result = compareVersions(v1, v2)
    
    if result == expected then
        print(string.format("  ✓ PASS: %s", description))
        passed = passed + 1
    else
        print(string.format("  ✗ FAIL: %s (expected %d, got %d)", description, expected, result))
        failed = failed + 1
    end
end

print(string.format("\nResults: %d passed, %d failed", passed, failed))

-- Test format bytes
print("\n=== Testing Format Bytes ===")
local byte_tests = {
    {0, "Unknown size"},
    {500, "500 B"},
    {1024, "1.0 KB"},
    {36419, "35.6 KB"},
    {1048576, "1.0 MB"},
    {2097152, "2.0 MB"},
}

for _, test in ipairs(byte_tests) do
    local bytes, expected = test[1], test[2]
    local result = formatBytes(bytes)
    if result == expected then
        print(string.format("  ✓ %d bytes -> %s", bytes, result))
    else
        print(string.format("  ✗ %d bytes -> %s (expected %s)", bytes, result, expected))
    end
end

-- Test real-world scenario: current local version vs GitHub latest
print("\n=== Real-World Test ===")
local current_local = "0.0.0-dev+179f0b9"
local github_latest = "1.1.1"

local v_local = parseVersion(current_local)
local v_github = parseVersion(github_latest)
local comparison = compareVersions(v_local, v_github)

print(string.format("  Current local version: %s", current_local))
print(string.format("  GitHub latest version: %s", github_latest))
print(string.format("  Comparison result: %d", comparison))

if comparison < 0 then
    print("  ✓ Update should be offered (local < remote)")
elseif comparison > 0 then
    print("  ✗ ERROR: Local appears newer than remote!")
else
    print("  ✗ ERROR: Versions appear equal!")
end

print("\n=== All Tests Complete ===\n")

-- Return exit code
os.exit(failed == 0 and 0 or 1)
