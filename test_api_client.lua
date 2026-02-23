#!/usr/bin/env luajit
--[[--
Unit tests for APIClient pure helper functions.
Copy-pasted from booklore_api_client.lua to avoid KOReader runtime dependencies.

Run with:  luajit test_api_client.lua
--]]--

-- ── Minimal stubs ────────────────────────────────────────────────────────────

-- Minimal json stub (only decode is needed, implemented via load())
local json = {}
function json.decode(str)
    -- Use Lua's load() to evaluate a JSON-like object.
    -- This works for the simple well-formed objects used in tests.
    local fn, err = load("return " .. str:gsub('("?)([%w_]+)("?)%s*:', function(q1, k, q2, _)
        -- keys must be quoted for Lua table constructors
        return "[\"" .. k .. "\"]="
    end))
    if not fn then error("json.decode: " .. tostring(err)) end
    return fn()
end

-- Provide a real, lightweight JSON decoder using Lua's native capabilities.
-- Replace the stub above with a proper implementation that handles the test cases.
-- We support: objects {}, arrays [], strings, numbers, booleans, null.
do
    local function skip_ws(s, i)
        while i <= #s and s:sub(i,i):match("%s") do i = i + 1 end
        return i
    end

    local parse_value  -- forward declaration

    local function parse_string(s, i)
        -- i points to the opening "
        local j = i + 1
        local parts = {}
        while j <= #s do
            local c = s:sub(j,j)
            if c == '"' then
                return table.concat(parts), j + 1
            elseif c == '\\' then
                local e = s:sub(j+1,j+1)
                local escapes = {['"']='"',['\\']='\\',['/']=
                    '/',['n']='\n',['r']='\r',['t']='\t',['b']='\b',['f']='\f'}
                table.insert(parts, escapes[e] or e)
                j = j + 2
            else
                table.insert(parts, c)
                j = j + 1
            end
        end
        error("unterminated string")
    end

    local function parse_array(s, i)
        local arr = {}
        i = skip_ws(s, i + 1)
        if s:sub(i,i) == ']' then return arr, i + 1 end
        while true do
            local v
            v, i = parse_value(s, i)
            table.insert(arr, v)
            i = skip_ws(s, i)
            local c = s:sub(i,i)
            if c == ']' then return arr, i + 1 end
            if c ~= ',' then error("expected ',' or ']' in array") end
            i = skip_ws(s, i + 1)
        end
    end

    local function parse_object(s, i)
        local obj = {}
        i = skip_ws(s, i + 1)
        if s:sub(i,i) == '}' then return obj, i + 1 end
        while true do
            if s:sub(i,i) ~= '"' then error("expected string key") end
            local k
            k, i = parse_string(s, i)
            i = skip_ws(s, i)
            if s:sub(i,i) ~= ':' then error("expected ':'") end
            i = skip_ws(s, i + 1)
            local v
            v, i = parse_value(s, i)
            obj[k] = v
            i = skip_ws(s, i)
            local c = s:sub(i,i)
            if c == '}' then return obj, i + 1 end
            if c ~= ',' then error("expected ',' or '}' in object") end
            i = skip_ws(s, i + 1)
        end
    end

    parse_value = function(s, i)
        i = skip_ws(s, i)
        local c = s:sub(i,i)
        if c == '"' then
            return parse_string(s, i)
        elseif c == '{' then
            return parse_object(s, i)
        elseif c == '[' then
            return parse_array(s, i)
        elseif s:sub(i, i+3) == 'true' then
            return true, i + 4
        elseif s:sub(i, i+4) == 'false' then
            return false, i + 5
        elseif s:sub(i, i+3) == 'null' then
            return nil, i + 4
        else
            -- number
            local num_str = s:match("^-?%d+%.?%d*[eE]?[+-]?%d*", i)
            if num_str then
                return tonumber(num_str), i + #num_str
            end
            error("unexpected token at position " .. i .. ": " .. s:sub(i, i+10))
        end
    end

    function json.decode(str)
        if not str or str == "" then error("empty input") end
        local ok, result = pcall(function()
            local val, _ = parse_value(str, 1)
            return val
        end)
        if not ok then error(result) end
        return result
    end
end

-- ── Copy of APIClient pure functions ────────────────────────────────────────

local APIClient = {}

function APIClient:new(o)
    o = o or {}
    setmetatable(o, self)
    self.__index = self
    return o
end

function APIClient:logWarn(...) end
function APIClient:logErr(...)  end
function APIClient:logInfo(...) end
function APIClient:logDbg(...)  end

function APIClient:parseJSON(response_text)
    if not response_text or response_text == "" then
        return nil, "Empty response"
    end
    local success, result = pcall(json.decode, response_text)
    if not success then
        self:logWarn("BookloreSync API: Failed to parse JSON:", result)
        return nil, "Invalid JSON response"
    end
    return result, nil
end

function APIClient:extractErrorMessage(response_text, code)
    local json_data, _ = self:parseJSON(response_text)

    if json_data then
        if json_data.message then
            return json_data.message
        elseif json_data.error then
            if type(json_data.error) == "string" then
                return json_data.error
            elseif type(json_data.error) == "table" and json_data.error.message then
                return json_data.error.message
            end
        elseif json_data.detail then
            return json_data.detail
        end
    end

    if response_text and response_text ~= "" and #response_text < 500 then
        return response_text
    end

    local status_messages = {
        [400] = "Bad Request",
        [401] = "Unauthorized - Invalid credentials",
        [403] = "Forbidden - Access denied",
        [404] = "Not Found",
        [500] = "Internal Server Error",
        [502] = "Bad Gateway",
        [503] = "Service Unavailable",
        [504] = "Gateway Timeout",
    }

    return status_messages[code] or ("HTTP " .. tostring(code))
end

function APIClient:_urlEncode(str)
    if not str then return "" end
    str = string.gsub(str, "\n", "\r\n")
    str = string.gsub(str, "([^%w %-%_%.])",
        function(c)
            return string.format("%%%02X", string.byte(c))
        end)
    str = string.gsub(str, " ", "+")
    return str
end

function APIClient:_normalizeBookObject(book)
    if not book or type(book) ~= "table" then
        return book
    end
    if book.metadata and type(book.metadata) == "table" then
        if not book.isbn10 then
            book.isbn10 = book.metadata.isbn10
        end
        if not book.isbn13 then
            book.isbn13 = book.metadata.isbn13
        end
    end
    return book
end

-- ── Test harness ─────────────────────────────────────────────────────────────

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

local client = APIClient:new()

-- ── _urlEncode ────────────────────────────────────────────────────────────────

print("\n=== _urlEncode ===")

check("nil input → empty string",      client:_urlEncode(nil),            "")
check("empty string → empty string",   client:_urlEncode(""),             "")
check("plain ASCII unchanged",         client:_urlEncode("hello"),        "hello")
check("space → +",                     client:_urlEncode("hello world"),  "hello+world")
check("multiple spaces",               client:_urlEncode("a b c"),        "a+b+c")
check("& encoded",                     client:_urlEncode("a&b"),          "a%26b")
check("= encoded",                     client:_urlEncode("a=b"),          "a%3Db")
check("/ encoded",                     client:_urlEncode("a/b"),          "a%2Fb")
check("# encoded",                     client:_urlEncode("a#b"),          "a%23b")
check("? encoded",                     client:_urlEncode("a?b"),          "a%3Fb")
check("+ encoded",                     client:_urlEncode("a+b"),          "a%2Bb")
check("@ encoded",                     client:_urlEncode("a@b"),          "a%40b")
check("dot preserved",                 client:_urlEncode("a.b"),          "a.b")
check("hyphen preserved",              client:_urlEncode("a-b"),          "a-b")
check("underscore preserved",          client:_urlEncode("a_b"),          "a_b")
check("digits preserved",              client:_urlEncode("abc123"),       "abc123")
check("mixed title query",
    client:_urlEncode("The Name of the Rose"),
    "The+Name+of+the+Rose")
check("special chars in title",
    client:_urlEncode("Harry Potter & The Philosopher's Stone"),
    "Harry+Potter+%26+The+Philosopher%27s+Stone")
check("colon encoded",                 client:_urlEncode("Vol: 1"),       "Vol%3A+1")
check("newline → %0D%0A",             client:_urlEncode("a\nb"),         "a%0D%0Ab")

-- ── parseJSON ─────────────────────────────────────────────────────────────────

print("\n=== parseJSON ===")

local result, err

result, err = client:parseJSON(nil)
check("nil → nil result",             result, nil)
check("nil → error message",          err,    "Empty response")

result, err = client:parseJSON("")
check("empty string → nil result",    result, nil)
check("empty string → error message", err,    "Empty response")

result, err = client:parseJSON("not json {{{{")
check("invalid JSON → nil result",    result, nil)
check("invalid JSON → error string",  err,    "Invalid JSON response")

result, err = client:parseJSON('{"message":"ok"}')
check("valid object → table",         type(result), "table")
check("valid object → message field", result and result.message, "ok")
check("valid object → no error",      err, nil)

result, err = client:parseJSON('[1,2,3]')
check("valid array → table",          type(result), "table")
check("valid array length",           result and #result, 3)
check("valid array → no error",       err, nil)

result, err = client:parseJSON('{"error":{"message":"nested error"}}')
check("nested error object → table",  type(result), "table")
check("nested error message field",   result and result.error and result.error.message, "nested error")

-- ── extractErrorMessage ───────────────────────────────────────────────────────

print("\n=== extractErrorMessage ===")

-- JSON with "message" field
check("JSON message field",
    client:extractErrorMessage('{"message":"Book not found"}', 404),
    "Book not found")

-- JSON with "error" string field
check("JSON error string field",
    client:extractErrorMessage('{"error":"Unauthorized"}', 401),
    "Unauthorized")

-- JSON with nested error.message
check("JSON nested error.message",
    client:extractErrorMessage('{"error":{"message":"Token expired"}}', 401),
    "Token expired")

-- JSON with "detail" field
check("JSON detail field",
    client:extractErrorMessage('{"detail":"Validation failed"}', 400),
    "Validation failed")

-- Spring-style error: has "message" key
check("Spring error with message key",
    client:extractErrorMessage(
        '{"message":"Failed to convert value of type \'java.lang.String\' to required type \'long\'"}',
        400),
    "Failed to convert value of type 'java.lang.String' to required type 'long'")

-- Plain text response (short, < 500 chars)
check("plain text response",
    client:extractErrorMessage("Service unavailable", 503),
    "Service unavailable")

-- Long plain text (>= 500 chars) → fall back to status code map
local long_text = string.rep("x", 500)
check("long plain text → status code fallback",
    client:extractErrorMessage(long_text, 500),
    "Internal Server Error")

-- nil response → status code map
check("nil response + 400",  client:extractErrorMessage(nil, 400),  "Bad Request")
check("nil response + 401",  client:extractErrorMessage(nil, 401),  "Unauthorized - Invalid credentials")
check("nil response + 403",  client:extractErrorMessage(nil, 403),  "Forbidden - Access denied")
check("nil response + 404",  client:extractErrorMessage(nil, 404),  "Not Found")
check("nil response + 500",  client:extractErrorMessage(nil, 500),  "Internal Server Error")
check("nil response + 502",  client:extractErrorMessage(nil, 502),  "Bad Gateway")
check("nil response + 503",  client:extractErrorMessage(nil, 503),  "Service Unavailable")
check("nil response + 504",  client:extractErrorMessage(nil, 504),  "Gateway Timeout")

-- Unknown code → "HTTP NNN"
check("unknown code 418",
    client:extractErrorMessage(nil, 418),
    "HTTP 418")

-- ── _normalizeBookObject ──────────────────────────────────────────────────────

print("\n=== _normalizeBookObject ===")

-- nil input → nil back
check("nil input → nil",
    client:_normalizeBookObject(nil), nil)

-- non-table input → returned as-is
check("string input → string",
    client:_normalizeBookObject("hello"), "hello")

-- book with nested metadata.isbn10/isbn13 → promoted to top level
local book1 = { id = 1, metadata = { isbn10 = "0451524934", isbn13 = "9780451524935" } }
local norm1 = client:_normalizeBookObject(book1)
check("isbn10 promoted from metadata",  norm1.isbn10, "0451524934")
check("isbn13 promoted from metadata",  norm1.isbn13, "9780451524935")
check("original id preserved",          norm1.id,     1)

-- book that already has top-level isbn10/isbn13 → not overwritten
local book2 = {
    id = 2,
    isbn10 = "existing10",
    isbn13 = "existing13",
    metadata = { isbn10 = "should_not_overwrite", isbn13 = "should_not_overwrite" }
}
local norm2 = client:_normalizeBookObject(book2)
check("existing isbn10 not overwritten", norm2.isbn10, "existing10")
check("existing isbn13 not overwritten", norm2.isbn13, "existing13")

-- book with no metadata table → isbn10/isbn13 remain nil
local book3 = { id = 3, title = "Test Book" }
local norm3 = client:_normalizeBookObject(book3)
check("no metadata → isbn10 nil",  norm3.isbn10, nil)
check("no metadata → isbn13 nil",  norm3.isbn13, nil)

-- book with metadata = non-table (edge case) → safe, no crash
local book4 = { id = 4, metadata = "string_metadata" }
local norm4 = client:_normalizeBookObject(book4)
check("metadata is string → isbn10 nil", norm4.isbn10, nil)
check("metadata is string → no crash",   norm4.id,     4)

-- book with partial metadata (only isbn13)
local book5 = { id = 5, metadata = { isbn13 = "9780743273565" } }
local norm5 = client:_normalizeBookObject(book5)
check("partial metadata: isbn13 promoted", norm5.isbn13, "9780743273565")
check("partial metadata: isbn10 nil",      norm5.isbn10, nil)

-- ── Results ───────────────────────────────────────────────────────────────────

print(string.format("\n=== Results: %d passed, %d failed ===", pass, fail))
if fail > 0 then os.exit(1) end
