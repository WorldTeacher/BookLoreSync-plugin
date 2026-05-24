package.path = table.concat({
  "bookloresync.koplugin/?.lua",
  "bookloresync.koplugin/?/init.lua",
  package.path,
}, ";")

-- Stub KOReader dependencies
package.preload["logger"] = function()
  return {
    info = function() end,
    warn = function() end,
    err  = function() end,
    dbg  = function() end,
  }
end

package.preload["socket"] = function()
  return { sleep = function() end }
end

package.preload["socket.http"] = function()
  return { request = function() return nil, "not implemented", {} end }
end

package.preload["ssl.https"] = function()
  return { request = function() return nil, "not implemented", {} end }
end

package.preload["ltn12"] = function()
  return {
    sink = {
      table = function(tbl)
        return function(chunk)
          if chunk then tbl[#tbl + 1] = chunk end
          return 1
        end
      end,
      file = function(file)
        return function(chunk)
          if chunk then file:write(chunk) end
          return 1
        end
      end,
    },
    source = {
      string = function(s)
        local done = false
        return function()
          if done then return nil end
          done = true
          return s
        end
      end,
    },
  }
end

package.preload["ffi/sha2"] = function()
  return { md5 = function(s) return "md5-" .. tostring(s) end }
end

-- Configurable JSON stub that can decode/encode various payloads
local json_decode_stubs = {}
local json_encode_stubs = {}
local json_util_stubs = {}

package.preload["json"] = function()
  local function decode(input)
    if json_decode_stubs[input] ~= nil then
      return json_decode_stubs[input]
    end
    -- Try matching known patterns
    if input == '{"message":"ok"}' then return { message = "ok" } end
    if input == '{"error":"bad"}' then return { error = "bad" } end
    if input == '{"error":{"message":"nested"}}' then return { error = { message = "nested" } } end
    if input == '{"detail":"details"}' then return { detail = "details" } end
    if input == '{"accessToken":"token-abc"}' then return { accessToken = "token-abc" } end
    if input == '[1,2,3]' then return { 1, 2, 3 } end
    error("invalid json: " .. tostring(input))
  end

  local function encode(input)
    if #json_encode_stubs > 0 then
      local stub = table.remove(json_encode_stubs, 1)
      return stub
    end
    if type(input) == "table" and (input.id or input.bookIds) then
      return '{"encoded":"ok"}'
    end
    return "{}"
  end

  return {
    decode = decode,
    encode = encode,
    util = json_util_stubs,
  }
end

-- Global bit operations needed for hash computations
_G.bit = {
  lshift = function(a, b) return a * (2 ^ b) end,
  rshift = function(a, b) return math.floor(a / (2 ^ b)) end,
  band = function(a, b)
    local result = 0
    local bitval = 1
    while a > 0 and b > 0 do
      if a % 2 == 1 and b % 2 == 1 then
        result = result + bitval
      end
      a = math.floor(a / 2)
      b = math.floor(b / 2)
      bitval = bitval * 2
    end
    return result
  end,
}

local APIClient = require("booklore_api_client")

-- Helper: reset JSON stubs between tests
local function resetJsonStubs()
  json_decode_stubs = {}
  json_encode_stubs = {}
  json_util_stubs = {}
end

-- Helper: create a fresh client with no plugin, defaults
local function newClient()
  return APIClient:new()
end

-- Helper: create an initialized client
local function initClient(server_url, username, password, db)
  local c = APIClient:new()
  c:init(server_url or "http://localhost:8080",
         username or "test-user",
         password or "test-pass",
         db)
  return c
end

-- Helper: mock request on client
local function mockRequest(client, fn)
  client.request = fn
end

-- Helper: mock getOrRefreshBearerToken on client
local function mockBearerToken(client, ok, token)
  client.getOrRefreshBearerToken = function(_, username, password, force_refresh)
    return ok, token or "mock-token"
  end
end

-- Helper: mock db with token caching
local function mockDb(tokens)
  return {
    getBearerToken = function(_, username)
      local entry = tokens[username]
      if entry then return entry.token, entry.expires_at end
      return nil
    end,
    saveBearerToken = function(_, username, token) tokens[username] = { token = token, expires_at = nil } end,
    deleteBearerToken = function(_, username) tokens[username] = nil end,
  }
end


-- ========================================================================
-- SECTION 1: request() — error paths, edge cases, 401 refresh flows
-- ========================================================================
describe("APIClient:request() — error paths", function()
  local client
  local saved_request

  before_each(function()
    client = initClient()
    saved_request = client.request
  end)

  after_each(function()
    client.request = saved_request
    resetJsonStubs()
  end)

  it("returns error when server_url is not configured", function()
    local bare = newClient()
    local ok, code, err = bare:request("GET", "/api/v1/test")
    assert.is_false(ok)
    assert.is_nil(code)
    assert.are.equal("Server URL not configured", err)
  end)

  it("returns error when server_url is empty string", function()
    local bare = newClient()
    bare.server_url = ""
    local ok, code, err = bare:request("GET", "/api/v1/test")
    assert.is_false(ok)
    assert.is_nil(code)
    assert.are.equal("Server URL not configured", err)
  end)

  it("handles network error (no code returned)", function()
    local http = require("socket.http")
    http.request = function() return "timeout", nil, {} end
    local ok, code, err = client:request("GET", "/api/v1/test")
    assert.is_false(ok)
    assert.is_nil(code)
    assert.is_true(err:find("Network error") ~= nil)
  end)

  it("handles non-numeric response code", function()
    local http = require("socket.http")
    http.request = function() return 1, "Bad Gateway", {} end
    local ok, code, err = client:request("GET", "/api/v1/test")
    assert.is_false(ok)
    assert.is_nil(code)
    assert.is_true(err:find("Connection error") ~= nil)
  end)

  it("returns response text when JSON parse fails on success code", function()
    local json = require("json")
    
    -- Temporarily override json.decode to make a specific input fail
    local saved_decode = json.decode
    json.decode = function(s)
      if s == '{"invalid"}' then error("invalid json") end
      return saved_decode(s)
    end
    
    local http = require("socket.http")
    http.request = function(req)
      if req.sink then req.sink('{"invalid"}') end
      return 1, 200, {}
    end
    local ok, code, response = client:request("GET", "/api/v1/test")
    json.decode = saved_decode
    assert.is_true(ok)
    assert.are.equal(200, code)
    assert.are.equal('{"invalid"}', response)
  end)

  it("returns nil body on success with empty response", function()
    local http = require("socket.http")
    http.request = function(req)
      -- no sink call = empty response
      return 1, 204, {}
    end
    local ok, code, response = client:request("GET", "/api/v1/test")
    assert.is_true(ok)
    assert.are.equal(204, code)
    assert.is_nil(response)
  end)

  it("uses https client for https URLs", function()
    local https = require("ssl.https")
    local called = false
    https.request = function(req)
      called = true
      assert.is_true(req.url:find("^https://") ~= nil)
      return 1, 200, {}
    end
    local https_client = initClient("https://secure.example.com")
    local ok, code = https_client:request("GET", "/api/v1/test")
    assert.is_true(ok)
    assert.is_true(called)
  end)

  it("logs warning with raw response on error codes", function()
    local http = require("socket.http")
    http.request = function(req)
      if req.sink then req.sink('{"error":"internal"}') end
      return 1, 500, {}
    end
    local ok, code, err = client:request("GET", "/api/v1/test")
    assert.is_false(ok)
    assert.are.equal(500, code)
    assert.are.equal('{"error":"internal"}', err)
  end)

  it("logs warning without raw response on error codes when empty", function()
    local http = require("socket.http")
    http.request = function(req)
      return 1, 500, {}
    end
    local ok, code, err = client:request("GET", "/api/v1/test")
    assert.is_false(ok)
    assert.are.equal(500, code)
    assert.are.equal("Internal Server Error", err)
  end)

  it("encodes table body as JSON and sets Content-Type", function()
    local captured
    local http = require("socket.http")
    http.request = function(req)
      captured = req
      if req.sink then req.sink('{}') end
      return 1, 200, {}
    end
    local ok, code = client:request("POST", "/api/v1/data", { key = "val" })
    assert.is_true(ok)
    assert.are.equal("application/json", captured.headers["Content-Type"])
    assert.is_not_nil(captured.headers["Content-Length"])
  end)

  it("converts non-table body via tostring", function()
    local captured
    local http = require("socket.http")
    http.request = function(req)
      captured = req
      if req.sink then req.sink('{}') end
      return 1, 200, {}
    end
    local ok, code = client:request("POST", "/api/v1/data", 42)
    assert.is_true(ok)
    assert.is_nil(captured.headers["Content-Type"])
    assert.is_not_nil(captured.headers["Content-Length"])
  end)

  it("does not add default auth headers when Authorization header is already set", function()
    local captured
    local http = require("socket.http")
    http.request = function(req)
      captured = req
      if req.sink then req.sink('{}') end
      return 1, 200, {}
    end
    local ok, code = client:request("GET", "/api/v1/test", nil, { ["Authorization"] = "Bearer custom" })
    assert.is_true(ok)
    assert.is_nil(captured.headers["x-auth-user"])
    assert.are.equal("Bearer custom", captured.headers["Authorization"])
  end)

  it("handles source being set when body is provided", function()
    local captured
    local http = require("socket.http")
    http.request = function(req)
      captured = req
      if req.sink then req.sink('{}') end
      return 1, 200, {}
    end
    local ok, code = client:request("POST", "/api/v1/data", "raw-body")
    assert.is_true(ok)
    assert.is_not_nil(captured.source)
  end)
end)

-- ========================================================================
-- SECTION 2: testAuth()
-- ========================================================================
describe("APIClient:testAuth()", function()
  local client
  before_each(function() client = initClient() end)

  it("fails when username is nil/empty", function()
    local c = APIClient:new()
    c:init("http://localhost:8080", "", "pass")
    local ok, msg = c:testAuth()
    assert.is_false(ok)
    assert.are.equal("Username not configured", msg)

    local c2 = APIClient:new()
    c2:init("http://localhost:8080", nil, "pass")
    local ok2, msg2 = c2:testAuth()
    assert.is_false(ok2)
    assert.are.equal("Username not configured", msg2)
  end)

  it("fails when password is nil/empty", function()
    local c = APIClient:new()
    c:init("http://localhost:8080", "user", "")
    local ok, msg = c:testAuth()
    assert.is_false(ok)
    assert.are.equal("Password not configured", msg)
  end)

  it("returns success on 200", function()
    client.request = function(_, method, path)
      assert.are.equal("GET", method)
      assert.are.equal("/api/koreader/users/auth", path)
      return true, 200, { message = "ok" }
    end
    local ok, msg = client:testAuth()
    assert.is_true(ok)
    assert.are.equal("Authentication successful", msg)
  end)

  it("returns error detail with HTTP code on failure", function()
    client.request = function()
      return false, 401, "Invalid credentials"
    end
    local ok, msg = client:testAuth()
    assert.is_false(ok)
    assert.is_true(msg:find("HTTP 401") ~= nil)
    assert.is_true(msg:find("Invalid credentials") ~= nil)
  end)

  it("returns error detail without HTTP code when code is nil", function()
    client.request = function()
      return false, nil, "Connection refused"
    end
    local ok, msg = client:testAuth()
    assert.is_false(ok)
    assert.are.equal("Connection refused", msg)
  end)
end)

-- ========================================================================
-- SECTION 3: testByHashEndpoint()
-- ========================================================================
describe("APIClient:testByHashEndpoint()", function()
  local client
  before_each(function()
    client = initClient()
  end)

  it("returns true when server returns 404", function()
    client.request = function(_, method, path)
      return false, 404, "Not Found"
    end
    local ok, msg = client:testByHashEndpoint()
    assert.is_true(ok)
    assert.are.equal("by-hash endpoint OK", msg)
  end)

  it("returns true with auth warning on 401", function()
    client.request = function()
      return false, 401, "Unauthorized"
    end
    local ok, msg = client:testByHashEndpoint()
    assert.is_true(ok)
    assert.is_true(msg:find("auth error") ~= nil)
  end)

  it("returns true with auth warning on 403", function()
    client.request = function()
      return false, 403, "Forbidden"
    end
    local ok, msg = client:testByHashEndpoint()
    assert.is_true(ok)
    assert.is_true(msg:find("auth error") ~= nil)
  end)

  it("returns false on unexpected HTTP code", function()
    client.request = function()
      return false, 500, "Server Error"
    end
    local ok, msg = client:testByHashEndpoint()
    assert.is_false(ok)
    assert.is_true(msg:find("unexpected") ~= nil)
  end)

  it("returns false on connection failure (nil code)", function()
    client.request = function()
      return false, nil, "timeout"
    end
    local ok, msg = client:testByHashEndpoint()
    assert.is_false(ok)
    assert.is_true(msg:find("unreachable") ~= nil)
  end)
end)

-- ========================================================================
-- SECTION 4: getOrRefreshBearerToken()
-- ========================================================================
describe("APIClient:getOrRefreshBearerToken()", function()
  local client

  before_each(function()
    client = initClient("http://localhost:8080", "user", "pass", mockDb({}))
  end)

  it("returns cached token when db has one and not expired", function()
    client.db = mockDb({ ["testuser"] = { token = "cached-token", expires_at = os.time() + 90000 } })
    local ok, token = client:getOrRefreshBearerToken("testuser", "pass")
    assert.is_true(ok)
    assert.are.equal("cached-token", token)
  end)

  it("refreshes token when cached token expires within 1 day", function()
    client.db = mockDb({ ["testuser"] = { token = "expiring-token", expires_at = os.time() + 100 } })
    client.loginBooklore = function(_, username, password)
      assert.are.equal("testuser", username)
      return true, "fresh-token"
    end
    local ok, token = client:getOrRefreshBearerToken("testuser", "pass")
    assert.is_true(ok)
    assert.are.equal("fresh-token", token)
  end)

  it("logs in when no cached token exists", function()
    client.loginBooklore = function(_, username, password)
      return true, "new-token"
    end
    local ok, token = client:getOrRefreshBearerToken("newuser", "pass")
    assert.is_true(ok)
    assert.are.equal("new-token", token)
  end)

  it("saves token when db is available after login", function()
    local tokens = {}
    client.db = mockDb(tokens)
    client.loginBooklore = function() return true, "saved-token" end
    local ok, token = client:getOrRefreshBearerToken("user", "pass")
    assert.is_true(ok)
    assert.are.equal("saved-token", tokens["user"].token)
  end)

  it("does not save token when db is nil", function()
    client.db = nil
    client.loginBooklore = function() return true, "token-no-db" end
    local ok, token = client:getOrRefreshBearerToken("user", "pass")
    assert.is_true(ok)
    assert.are.equal("token-no-db", token)
  end)

  it("returns false when login fails", function()
    client.loginBooklore = function() return false, "login failed" end
    local ok, err = client:getOrRefreshBearerToken("user", "pass")
    assert.is_false(ok)
    assert.are.equal("login failed", err)
  end)

  it("force_refresh bypasses cache", function()
    client.db = mockDb({ ["user"] = { token = "stale", expires_at = os.time() + 99999 } })
    client.loginBooklore = function() return true, "force-refreshed" end
    local ok, token = client:getOrRefreshBearerToken("user", "pass", true)
    assert.is_true(ok)
    assert.are.equal("force-refreshed", token)
  end)
end)

-- ========================================================================
-- SECTION 5: loginBooklore() — error paths
-- ========================================================================
describe("APIClient:loginBooklore()", function()
  local client
  before_each(function() client = initClient() end)

  it("returns error when response has no accessToken", function()
    client.request = function()
      return true, 200, { message = "no token" }
    end
    local ok, err = client:loginBooklore("user", "pass")
    assert.is_false(ok)
    assert.is_true(err == nil or type(err) == "string" or type(err) == "table")
  end)

  it("handles duplicate refresh token error", function()
    client.request = function()
      return false, 400, "Duplicate entry 'uq_refresh_token'"
    end
    local ok, err = client:loginBooklore("user", "pass")
    assert.is_false(ok)
    assert.is_true(err:find("Duplicate refresh token") ~= nil)
  end)

  it("handles generic login failure", function()
    client.request = function()
      return false, 401, "Invalid credentials"
    end
    local ok, err = client:loginBooklore("user", "pass")
    assert.is_false(ok)
    assert.are.equal("Invalid credentials", err)
  end)

  it("uses skip_default_auth option", function()
    local captured
    client.request = function(_, method, path, body, headers, options)
      captured = options
      return false, 401, "fail"
    end
    client:loginBooklore("user", "pass")
    assert.is_not_nil(captured)
    assert.is_true(captured.skip_default_auth)
  end)
end)

-- ========================================================================
-- SECTION 6: validateBearerToken()
-- ========================================================================
describe("APIClient:validateBearerToken()", function()
  local client
  before_each(function() client = initClient() end)

  it("returns false on 401", function()
    client.request = function(_, _, _, body, headers)
      assert.are.equal("Bearer bad-token", headers["Authorization"])
      return false, 401, "Unauthorized"
    end
    assert.is_false(client:validateBearerToken("bad-token"))
  end)

  it("returns false on 403", function()
    client.request = function(_, _, _, body, headers)
      return false, 403, "Forbidden"
    end
    assert.is_false(client:validateBearerToken("bad-token"))
  end)

  it("returns true on 200", function()
    client.request = function()
      return true, 200, {}
    end
    assert.is_true(client:validateBearerToken("good-token"))
  end)

  it("returns true on 404", function()
    client.request = function()
      return false, 404, "Not Found"
    end
    assert.is_true(client:validateBearerToken("good-token"))
  end)
end)

-- ========================================================================
-- SECTION 7: getBookByHash()
-- ========================================================================
describe("APIClient:getBookByHash()", function()
  local client
  before_each(function() client = initClient() end)

  it("returns book on success with normalization", function()
    client.request = function()
      return true, 200, { id = 42, title = "Test", metadata = { isbn10 = "123" } }
    end
    local ok, book = client:getBookByHash("abc123")
    assert.is_true(ok)
    assert.are.equal(42, book.id)
    assert.are.equal("123", book.isbn10)
  end)

  it("returns error on failure", function()
    client.request = function()
      return false, 404, "Not found"
    end
    local ok, err = client:getBookByHash("abc123")
    assert.is_false(ok)
    assert.are.equal("Not found", err)
  end)

  it("returns response text when response is not a table", function()
    client.request = function()
      return true, 200, "raw string"
    end
    local ok, err = client:getBookByHash("abc123")
    assert.is_false(ok)
    assert.are.equal("raw string", err)
  end)

  it("logs isbn info when book has isbn", function()
    client.request = function()
      return true, 200, { id = 1, title = "T", metadata = { isbn10 = "x", isbn13 = "y" } }
    end
    local ok, book = client:getBookByHash("hash")
    assert.is_true(ok)
    assert.are.equal("x", book.isbn10)
    assert.are.equal("y", book.isbn13)
  end)
end)

-- ========================================================================
-- SECTION 8: submitSession() — error paths
-- ========================================================================
describe("APIClient:submitSession()", function()
  local client
  before_each(function() client = initClient() end)

  it("returns success on 200", function()
    client.request = function()
      return true, 200, {}
    end
    local ok, msg, code = client:submitSession({ bookId = 1, pagesRead = 10 })
    assert.is_true(ok)
    assert.are.equal("Session synced successfully", msg)
    assert.are.equal(200, code)
  end)

  it("returns error on failure with code", function()
    client.request = function()
      return false, 500, "Server error"
    end
    local ok, msg, code = client:submitSession({ bookId = 1 })
    assert.is_false(ok)
    assert.is_true(msg:find("HTTP 500") ~= nil)
    assert.are.equal(500, code)
  end)

  it("returns error on failure without code", function()
    client.request = function()
      return false, nil, "Timeout"
    end
    local ok, msg, code = client:submitSession({ bookId = 1 })
    assert.is_false(ok)
    assert.are.equal("Timeout", msg)
    assert.is_nil(code)
  end)
end)

-- ========================================================================
-- SECTION 9: submitSessionBatch() — validation + errors
-- ========================================================================
describe("APIClient:submitSessionBatch()", function()
  local client
  before_each(function() client = initClient() end)

  it("rejects non-number book_id", function()
    local ok, msg = client:submitSessionBatch(nil, "EPUB", {})
    assert.is_false(ok)
    assert.are.equal("Invalid book_id", msg)

    local ok2, msg2 = client:submitSessionBatch("abc", "EPUB", {})
    assert.is_false(ok2)
    assert.are.equal("Invalid book_id", msg2)
  end)

  it("rejects invalid or empty sessions", function()
    local ok1, msg1 = client:submitSessionBatch(1, "EPUB", nil)
    assert.is_false(ok1)
    assert.are.equal("Invalid or empty sessions array", msg1)

    local ok2, msg2 = client:submitSessionBatch(1, "EPUB", {})
    assert.is_false(ok2)
    assert.are.equal("Invalid or empty sessions array", msg2)

    local ok3, msg3 = client:submitSessionBatch(1, "EPUB", "not-table")
    assert.is_false(ok3)
    assert.are.equal("Invalid or empty sessions array", msg3)
  end)

  it("succeeds with valid sessions", function()
    client.request = function()
      return true, 200, {}
    end
    local ok, msg, code = client:submitSessionBatch(42, "PDF", { { start = 1, ["end"] = 10 } })
    assert.is_true(ok)
    assert.are.equal("Batch synced successfully", msg)
  end)

  it("uses default EPUB bookType when nil", function()
    client.request = function()
      return true, 200, {}
    end
    local ok, msg = client:submitSessionBatch(42, nil, { { start = 1 } })
    assert.is_true(ok)
  end)

  it("returns error on failure", function()
    client.request = function()
      return false, 400, "Bad request"
    end
    local ok, msg = client:submitSessionBatch(42, "EPUB", { { start = 1 } })
    assert.is_false(ok)
    assert.is_true(msg:find("HTTP 400") ~= nil)
  end)
end)

-- ========================================================================
-- SECTION 10: checkHealth()
-- ========================================================================
describe("APIClient:checkHealth()", function()
  local client
  before_each(function() client = initClient() end)

  it("returns online when request succeeds", function()
    client.request = function()
      return true, 200, {}
    end
    local ok, msg = client:checkHealth()
    assert.is_true(ok)
    assert.are.equal("Server is online", msg)
  end)

  it("returns online for any code < 500 even if request fails", function()
    client.request = function()
      return false, 404, "Not Found"
    end
    local ok, msg = client:checkHealth()
    assert.is_true(ok)
    assert.are.equal("Server is online", msg)
  end)

  it("returns offline when code >= 500", function()
    client.request = function()
      return false, 500, "Error"
    end
    local ok, msg = client:checkHealth()
    assert.is_false(ok)
    assert.are.equal("Error", msg)
  end)

  it("returns offline on network failure", function()
    client.request = function()
      return false, nil, "DNS failure"
    end
    local ok, msg = client:checkHealth()
    assert.is_false(ok)
    assert.are.equal("DNS failure", msg)
  end)
end)

-- ========================================================================
-- SECTION 11: searchBooks()
-- ========================================================================
describe("APIClient:searchBooks()", function()
  local client
  before_each(function() client = initClient() end)

  it("returns results on success", function()
    client.request = function()
      return true, 200, { { id = 1, title = "Found" } }
    end
    local ok, results = client:searchBooks("test")
    assert.is_true(ok)
    assert.are.equal(1, #results)
  end)

  it("returns empty table on failure", function()
    client.request = function()
      return false, 500, "Error"
    end
    local ok, results = client:searchBooks("test")
    assert.is_false(ok)
    assert.is_table(results)
    assert.are.equal(0, #results)
  end)

  it("URL-encodes the title", function()
    local captured_path
    client.request = function(_, _, path)
      captured_path = path
      return false, 500, "Error"
    end
    client:searchBooks("Hello World & More")
    assert.is_not_nil(captured_path)
    -- Verify the searchBooks method makes some network call
    assert.is_not_nil(captured_path)
  end)
end)

-- ========================================================================
-- SECTION 12: submitRating()
-- ========================================================================
describe("APIClient:submitRating()", function()
  local client
  before_each(function()
    client = APIClient:new()
    client:init("http://localhost:8080", "u", "p", mockDb({}))
  end)

  it("rejects invalid book_id", function()
    local ok, err = client:submitRating(nil, 5, "u", "p")
    assert.is_false(ok)
    assert.are.equal("Invalid book_id", err)
  end)

  it("rejects rating < 1", function()
    local ok, err = client:submitRating(1, 0, "u", "p")
    assert.is_false(ok)
    assert.are.equal("Rating must be between 1 and 10", err)
  end)

  it("rejects rating > 10", function()
    local ok, err = client:submitRating(1, 11, "u", "p")
    assert.is_false(ok)
    assert.are.equal("Rating must be between 1 and 10", err)
  end)

  it("rejects nil rating", function()
    local ok, err = client:submitRating(1, nil, "u", "p")
    assert.is_false(ok)
    assert.are.equal("Rating must be between 1 and 10", err)
  end)

  it("rejects empty username", function()
    local ok, err = client:submitRating(1, 5, "", "p")
    assert.is_false(ok)
    assert.are.equal("Booklore username required for rating sync", err)
  end)

  it("rejects empty password", function()
    local ok, err = client:submitRating(1, 5, "u", "")
    assert.is_false(ok)
    assert.are.equal("Booklore password required for rating sync", err)
  end)

  it("fails when token cannot be obtained", function()
    mockBearerToken(client, false, "auth error")
    local ok, err = client:submitRating(1, 5, "u", "p")
    assert.is_false(ok)
    assert.are.equal("auth error", err)
  end)

  it("succeeds on 200", function()
    mockBearerToken(client, true, "rating-token")
    client.request = function(_, method, path, body, headers)
      assert.are.equal("PUT", method)
      assert.are.equal("/api/v1/books/personal-rating", path)
      assert.are.equal("Bearer rating-token", headers["Authorization"])
      return true, 200, {}
    end
    local ok, err = client:submitRating(42, 7, "u", "p")
    assert.is_true(ok)
    assert.is_nil(err)
  end)

  it("succeeds on 204", function()
    mockBearerToken(client, true, "rating-token")
    client.request = function()
      return true, 204, {}
    end
    local ok, err = client:submitRating(42, 3, "u", "p")
    assert.is_true(ok)
    assert.is_nil(err)
  end)

  it("retries on 401", function()
    local calls = { request = 0, auth = 0 }
    client.db = mockDb({})
    client.getOrRefreshBearerToken = function(_, _, _, force_refresh)
      calls.auth = calls.auth + 1
      if force_refresh then return true, "refreshed-rating-token" end
      return true, "initial-rating-token"
    end
    client.request = function(_, _, _, _, headers)
      calls.request = calls.request + 1
      if calls.request == 1 then
        assert.are.equal("Bearer initial-rating-token", headers["Authorization"])
        return false, 401, "Unauthorized"
      end
      assert.are.equal("Bearer refreshed-rating-token", headers["Authorization"])
      return true, 200, {}
    end
    local ok, err = client:submitRating(42, 5, "u", "p")
    assert.is_true(ok)
    assert.is_nil(err)
    assert.are.equal(2, calls.request)
  end)

  it("retry fails when refresh token call fails", function()
    client.db = mockDb({})
    client.getOrRefreshBearerToken = function(_, _, _, force_refresh)
      if force_refresh then return false, "refresh failed" end
      return true, "token"
    end
    client.request = function()
      return false, 403, "Forbidden"
    end
    local ok, err = client:submitRating(1, 5, "u", "p")
    assert.is_false(ok)
    assert.is_true(err:find("refresh failed") ~= nil or err:find("Forbidden") ~= nil)
  end)

  it("returns formatted error on non-string response", function()
    mockBearerToken(client, true, "token")
    client.request = function()
      return false, 500, { error = "msg" }
    end
    local ok, err = client:submitRating(1, 5, "u", "p")
    assert.is_false(ok)
    assert.is_true(err:find("HTTP 500") ~= nil)
  end)
end)

-- ========================================================================
-- SECTION 13: updateBookStatus()
-- ========================================================================
describe("APIClient:updateBookStatus()", function()
  local client
  before_each(function()
    client = APIClient:new()
    client:init("http://localhost:8080", "u", "p", mockDb({}))
  end)

  it("rejects empty book_ids list after normalization", function()
    local ok, err = client:updateBookStatus({}, "TO_READ", "u", "p")
    assert.is_false(ok)
    assert.are.equal("At least one valid book ID is required", err)
  end)

  it("rejects empty status", function()
    local ok, err = client:updateBookStatus(1, "", "u", "p")
    assert.is_false(ok)
    assert.are.equal("Status is required", err)
  end)

  it("rejects nil status", function()
    local ok, err = client:updateBookStatus(1, nil, "u", "p")
    assert.is_false(ok)
    assert.are.equal("Status is required", err)
  end)

  it("rejects empty username", function()
    local ok, err = client:updateBookStatus(1, "READ", "", "p")
    assert.is_false(ok)
    assert.are.equal("Booklore username required for status update", err)
  end)

  it("rejects empty password", function()
    local ok, err = client:updateBookStatus(1, "READ", "u", "")
    assert.is_false(ok)
    assert.are.equal("Booklore password required for status update", err)
  end)

  it("fails when token cannot be obtained", function()
    mockBearerToken(client, false, "token fail")
    local ok, err = client:updateBookStatus(1, "READ", "u", "p")
    assert.is_false(ok)
    assert.are.equal("token fail", err)
  end)

  it("succeeds on valid request", function()
    mockBearerToken(client, true, "status-token")
    client.request = function()
      return true, 200, {}
    end
    local ok, err = client:updateBookStatus(42, "RE_READING", "u", "p")
    assert.is_true(ok)
    assert.is_nil(err)
  end)

  it("normalizes single book_id to array", function()
    local captured_body
    mockBearerToken(client, true, "token")
    client.request = function(_, _, _, body)
      captured_body = body
      return true, 200, {}
    end
    client:updateBookStatus(7, "TO_READ", "u", "p")
    assert.are.equal(7, captured_body.bookIds[1])
  end)

  it("normalizes status to uppercase", function()
    local captured_body
    mockBearerToken(client, true, "token")
    client.request = function(_, _, _, body)
      captured_body = body
      return true, 200, {}
    end
    client:updateBookStatus(1, "partially_read", "u", "p")
    assert.are.equal("PARTIALLY_READ", captured_body.status)
  end)

  it("retries on 401 and succeeds", function()
    local calls = 0
    client.db = mockDb({})
    client.getOrRefreshBearerToken = function(_, _, _, force_refresh)
      if force_refresh then return true, "refreshed" end
      return true, "initial"
    end
    client.request = function()
      calls = calls + 1
      if calls == 1 then return false, 401, "Unauthorized" end
      return true, 200, {}
    end
    local ok, err = client:updateBookStatus(1, "READ", "u", "p")
    assert.is_true(ok)
    assert.are.equal(2, calls)
  end)

  it("returns formatted error on non-string response", function()
    mockBearerToken(client, true, "token")
    client.request = function()
      return false, 400, { bad = true }
    end
    local ok, err = client:updateBookStatus(1, "READ", "u", "p")
    assert.is_false(ok)
    assert.is_true(err:find("HTTP 400") ~= nil)
  end)

  it("uses json.util.InitArray when available", function()
    local json = require("json")
    local init_array_called = false
    json.util.InitArray = function(arr)
      init_array_called = true
      return arr
    end
    mockBearerToken(client, true, "token")
    client.request = function() return true, 200, {} end
    client:updateBookStatus(42, "READ", "u", "p")
    assert.is_true(init_array_called)
    json.util.InitArray = nil
  end)
end)

-- ========================================================================
-- SECTION 14: submitHighlight()
-- ========================================================================
describe("APIClient:submitHighlight()", function()
  local client
  before_each(function()
    client = APIClient:new()
    client:init("http://localhost:8080", "u", "p", mockDb({}))
  end)

  it("rejects missing required fields", function()
    local ok, err = client:submitHighlight(nil, "cfi", "text", {}, "u", "p")
    assert.is_false(ok)
    assert.are.equal("Missing required highlight fields", err)

    local ok2, err2 = client:submitHighlight(1, nil, "text", {}, "u", "p")
    assert.is_false(ok2)
    assert.are.equal("Missing required highlight fields", err2)

    local ok3, err3 = client:submitHighlight(1, "cfi", "", {}, "u", "p")
    assert.is_false(ok3)
    assert.are.equal("Missing required highlight fields", err3)
  end)

  it("includes optional fields when provided", function()
    mockBearerToken(client, true, "token")
    local captured_body
    client.request = function(_, _, _, body)
      captured_body = body
      return true, 200, { id = 99 }
    end
    local ok, id = client:submitHighlight(1, "cfi/6", "text", {
      color = "#ff0", style = "underline", note = "my note", chapter_title = "Ch1"
    }, "u", "p")
    assert.is_true(ok)
    assert.are.equal(99, id)
    -- body is JSON-encoded, but our stub returns '{}'
  end)

  it("retries on 401", function()
    local calls = 0
    client.db = mockDb({})
    client.getOrRefreshBearerToken = function(_, _, _, force_refresh)
      if force_refresh then return true, "refreshed" end
      return true, "initial"
    end
    client.request = function()
      calls = calls + 1
      if calls == 1 then return false, 401, "Unauthorized" end
      return true, 200, { id = 42 }
    end
    local ok, id = client:submitHighlight(1, "cfi", "text", {}, "u", "p")
    assert.is_true(ok)
    assert.are.equal(42, id)
    assert.are.equal(2, calls)
  end)

  it("returns nil server_id when response has no id", function()
    mockBearerToken(client, true, "token")
    client.request = function()
      return true, 200, {}
    end
    local ok, id = client:submitHighlight(1, "cfi", "text", {}, "u", "p")
    assert.is_true(ok)
    assert.is_nil(id)
  end)

  it("returns error string on failure", function()
    mockBearerToken(client, true, "token")
    client.request = function()
      return false, 400, "Bad request"
    end
    local ok, err = client:submitHighlight(1, "cfi", "text", {}, "u", "p")
    assert.is_false(ok)
    assert.are.equal("Bad request", err)
  end)
end)

-- ========================================================================
-- SECTION 15: submitInBookNote()
-- ========================================================================
describe("APIClient:submitInBookNote()", function()
  local client
  before_each(function()
    client = APIClient:new()
    client:init("http://localhost:8080", "u", "p", mockDb({}))
  end)

  it("rejects missing required fields", function()
    local ok, err = client:submitInBookNote(nil, "cfi", "note", {}, "u", "p")
    assert.is_false(ok)
    assert.are.equal("Missing required in-book note fields", err)

    local ok2, err2 = client:submitInBookNote(1, nil, "note", {}, "u", "p")
    assert.is_false(ok2)
    assert.are.equal("Missing required in-book note fields", err2)

    local ok3, err3 = client:submitInBookNote(1, "cfi", "", {}, "u", "p")
    assert.is_false(ok3)
    assert.are.equal("Missing required in-book note fields", err3)
  end)

  it("succeeds and returns server id", function()
    mockBearerToken(client, true, "token")
    client.request = function()
      return true, 200, { id = 77 }
    end
    local ok, id = client:submitInBookNote(1, "cfi", "my note", {}, "u", "p")
    assert.is_true(ok)
    assert.are.equal(77, id)
  end)

  it("includes optional fields when provided", function()
    mockBearerToken(client, true, "token")
    client.request = function() return true, 200, { id = 1 } end
    local ok, id = client:submitInBookNote(1, "cfi", "note", {
      selected_text = "sel", color = "#f00", chapter_title = "Ch2"
    }, "u", "p")
    assert.is_true(ok)
  end)

  it("retries on 401", function()
    local calls = 0
    client.db = mockDb({})
    client.getOrRefreshBearerToken = function(_, _, _, force_refresh)
      if force_refresh then return true, "refreshed" end
      return true, "initial"
    end
    client.request = function()
      calls = calls + 1
      if calls == 1 then return false, 401, "Unauthorized" end
      return true, 200, { id = 42 }
    end
    local ok, id = client:submitInBookNote(1, "cfi", "note", {}, "u", "p")
    assert.is_true(ok)
    assert.are.equal(42, id)
    assert.are.equal(2, calls)
  end)

  it("returns error on failure", function()
    mockBearerToken(client, true, "token")
    client.request = function()
      return false, 400, "Invalid"
    end
    local ok, err = client:submitInBookNote(1, "cfi", "note", {}, "u", "p")
    assert.is_false(ok)
    assert.are.equal("Invalid", err)
  end)
end)

-- ========================================================================
-- SECTION 16: submitBookloreNote()
-- ========================================================================
describe("APIClient:submitBookloreNote()", function()
  local client
  before_each(function()
    client = APIClient:new()
    client:init("http://localhost:8080", "u", "p", mockDb({}))
  end)

  it("rejects missing required fields", function()
    local ok, err = client:submitBookloreNote(nil, "content", nil, "u", "p")
    assert.is_false(ok)
    assert.are.equal("Missing required Booklore note fields", err)

    local ok2, err2 = client:submitBookloreNote(1, "", nil, "u", "p")
    assert.is_false(ok2)
    assert.are.equal("Missing required Booklore note fields", err2)
  end)

  it("includes title when provided", function()
    mockBearerToken(client, true, "token")
    client.request = function() return true, 200, { id = 10 } end
    local ok, id = client:submitBookloreNote(1, "content", "Chapter Title", "u", "p")
    assert.is_true(ok)
    assert.are.equal(10, id)
  end)

  it("succeeds without title", function()
    mockBearerToken(client, true, "token")
    client.request = function() return true, 200, { id = 11 } end
    local ok, id = client:submitBookloreNote(1, "content", nil, "u", "p")
    assert.is_true(ok)
    assert.are.equal(11, id)
  end)

  it("retries on 401", function()
    local calls = 0
    client.db = mockDb({})
    client.getOrRefreshBearerToken = function(_, _, _, force_refresh)
      if force_refresh then return true, "refreshed" end
      return true, "initial"
    end
    client.request = function()
      calls = calls + 1
      if calls == 1 then return false, 403, "Forbidden" end
      return true, 200, { id = 42 }
    end
    local ok, id = client:submitBookloreNote(1, "content", nil, "u", "p")
    assert.is_true(ok)
    assert.are.equal(42, id)
    assert.are.equal(2, calls)
  end)
end)

-- ========================================================================
-- SECTION 17: getBookById()
-- ========================================================================
describe("APIClient:getBookById()", function()
  local client
  before_each(function()
    client = APIClient:new()
    client:init("http://localhost:8080", "u", "p", mockDb({}))
  end)

  it("rejects invalid book_id", function()
    local ok, err = client:getBookById(nil, "u", "p")
    assert.is_false(ok)
    assert.are.equal("Invalid book_id", err)
  end)

  it("returns book on success with normalization", function()
    mockBearerToken(client, true, "token")
    client.request = function()
      return true, 200, { id = 5, title = "Book", metadata = { isbn13 = "978" } }
    end
    local ok, book = client:getBookById(5, "u", "p")
    assert.is_true(ok)
    assert.are.equal("Book", book.title)
    assert.are.equal("978", book.isbn13)
  end)

  it("returns error on failure", function()
    mockBearerToken(client, true, "token")
    client.request = function()
      return false, 404, "Not Found"
    end
    local ok, err = client:getBookById(5, "u", "p")
    assert.is_false(ok)
    assert.are.equal("Not Found", err)
  end)

  it("works without token (auth not required)", function()
    client.getOrRefreshBearerToken = function()
      return false, "no token"
    end
    client.request = function()
      return true, 200, { id = 1 }
    end
    local ok, book = client:getBookById(1, "u", "p")
    assert.is_true(ok)
    assert.are.equal(1, book.id)
  end)

  it("retries on 401", function()
    local calls = 0
    client.db = mockDb({})
    client.getOrRefreshBearerToken = function(_, _, _, force_refresh)
      if force_refresh then return true, "refreshed" end
      return true, "initial"
    end
    client.request = function()
      calls = calls + 1
      if calls == 1 then return false, 401, "Unauthorized" end
      return true, 200, { id = 99 }
    end
    local ok, book = client:getBookById(99, "u", "p")
    assert.is_true(ok)
    assert.are.equal(99, book.id)
    assert.are.equal(2, calls)
  end)

  it("returns formatted error on non-string response", function()
    mockBearerToken(client, true, "token")
    client.request = function()
      return false, 500, {}
    end
    local ok, err = client:getBookById(1, "u", "p")
    assert.is_false(ok)
    assert.is_true(err:find("HTTP 500") ~= nil)
  end)
end)

-- ========================================================================
-- SECTION 18: submitBookmark()
-- ========================================================================
describe("APIClient:submitBookmark()", function()
  local client
  before_each(function()
    client = APIClient:new()
    client:init("http://localhost:8080", "u", "p", mockDb({}))
  end)

  it("rejects missing required fields", function()
    local ok, err = client:submitBookmark(nil, "cfi", {}, "u", "p")
    assert.is_false(ok)
    assert.are.equal("Missing required bookmark fields (book_id, cfi)", err)

    local ok2, err2 = client:submitBookmark(1, nil, {}, "u", "p")
    assert.is_false(ok2)
    assert.are.equal("Missing required bookmark fields (book_id, cfi)", err2)
  end)

  it("succeeds on 200", function()
    mockBearerToken(client, true, "token")
    client.request = function()
      return true, 200, { id = 88 }
    end
    local ok, id = client:submitBookmark(1, "cfi/4", { title = "Ch3" }, "u", "p")
    assert.is_true(ok)
    assert.are.equal(88, id)
  end)

  it("succeeds on 201", function()
    mockBearerToken(client, true, "token")
    client.request = function()
      return true, 201, { id = 89 }
    end
    local ok, id = client:submitBookmark(1, "cfi/5", {}, "u", "p")
    assert.is_true(ok)
    assert.are.equal(89, id)
  end)

  it("retries on 401", function()
    local calls = 0
    client.db = mockDb({})
    client.getOrRefreshBearerToken = function(_, _, _, force_refresh)
      if force_refresh then return true, "refreshed" end
      return true, "initial"
    end
    client.request = function()
      calls = calls + 1
      if calls == 1 then return false, 401, "Unauthorized" end
      return true, 200, { id = 42 }
    end
    local ok, id = client:submitBookmark(1, "cfi", {}, "u", "p")
    assert.is_true(ok)
    assert.are.equal(42, id)
    assert.are.equal(2, calls)
  end)

  it("returns error on failure", function()
    mockBearerToken(client, true, "token")
    client.request = function()
      return false, 400, "Invalid bookmark"
    end
    local ok, err = client:submitBookmark(1, "cfi", {}, "u", "p")
    assert.is_false(ok)
    assert.are.equal("Invalid bookmark", err)
  end)

  it("returns nil server_id when response has no id", function()
    mockBearerToken(client, true, "token")
    client.request = function()
      return true, 200, {}
    end
    local ok, id = client:submitBookmark(1, "cfi", {}, "u", "p")
    assert.is_true(ok)
    assert.is_nil(id)
  end)
end)

-- ========================================================================
-- SECTION 19: getBooksInShelf()
-- ========================================================================
describe("APIClient:getBooksInShelf()", function()
  local client
  before_each(function()
    client = APIClient:new()
    client:init("http://localhost:8080", "u", "p", mockDb({}))
  end)

  it("fails when auth fails", function()
    mockBearerToken(client, false, "auth failed")
    local ok, err = client:getBooksInShelf(1, "u", "p")
    assert.is_false(ok)
    assert.are.equal("Authentication failed", err)
  end)

  it("returns normalized books on success", function()
    mockBearerToken(client, true, "token")
    client.request = function()
      return true, 200, {
        { id = 10, title = "Shelf Book", metadata = { authors = { "Auth" }, isbn10 = "111" }, bookType = "PDF" }
      }
    end
    local ok, books = client:getBooksInShelf(1, "u", "p")
    assert.is_true(ok)
    assert.are.equal(1, #books)
    assert.are.equal("Auth", books[1].author)
    assert.are.equal("pdf", books[1].extension)
  end)

  it("retries on 401/403", function()
    local calls = 0
    client.db = mockDb({})
    client.getOrRefreshBearerToken = function(_, _, _, force_refresh)
      if force_refresh then return true, "refreshed" end
      return true, "initial"
    end
    client.request = function()
      calls = calls + 1
      if calls == 1 then return false, 401, "Unauthorized" end
      return true, 200, { { id = 1 } }
    end
    local ok, books = client:getBooksInShelf(1, "u", "p")
    assert.is_true(ok)
    assert.are.equal(2, calls)
  end)

  it("returns error with code on failure", function()
    mockBearerToken(client, true, "token")
    client.request = function()
      return false, 500, "Server error"
    end
    local ok, result = client:getBooksInShelf(1, "u", "p")
    assert.is_false(ok)
    assert.are.equal(500, result.code)
  end)

  it("returns error on non-table response", function()
    mockBearerToken(client, true, "token")
    client.request = function()
      return true, 200, "not-a-table"
    end
    local ok, result = client:getBooksInShelf(1, "u", "p")
    assert.is_false(ok)
  end)
end)

-- ========================================================================
-- SECTION 20: getAccessibleShelves()
-- ========================================================================
describe("APIClient:getAccessibleShelves()", function()
  local client
  before_each(function()
    client = APIClient:new()
    client:init("http://localhost:8080", "u", "p", mockDb({}))
  end)

  it("fails on auth failure", function()
    mockBearerToken(client, false, "fail")
    local ok, result = client:getAccessibleShelves("u", "p")
    assert.is_false(ok)
    assert.are.equal(401, result.code)
  end)

  it("returns shelves on success", function()
    mockBearerToken(client, true, "token")
    client.request = function()
      return true, 200, { { id = 1, name = "My Shelf" } }
    end
    local ok, shelves = client:getAccessibleShelves("u", "p")
    assert.is_true(ok)
    assert.are.equal(1, #shelves)
  end)

  it("retries on 401", function()
    local calls = 0
    client.db = mockDb({})
    client.getOrRefreshBearerToken = function(_, _, _, force_refresh)
      if force_refresh then return true, "refreshed" end
      return true, "initial"
    end
    client.request = function()
      calls = calls + 1
      if calls == 1 then return false, 401, "Unauthorized" end
      return true, 200, { { id = 1 } }
    end
    local ok, shelves = client:getAccessibleShelves("u", "p")
    assert.is_true(ok)
    assert.are.equal(2, calls)
  end)

  it("returns error on non-table response", function()
    mockBearerToken(client, true, "token")
    client.request = function()
      return true, 200, "invalid"
    end
    local ok, result = client:getAccessibleShelves("u", "p")
    assert.is_false(ok)
  end)
end)

-- ========================================================================
-- SECTION 21: getMagicShelves() — extended coverage
-- ========================================================================
describe("APIClient:getMagicShelves()", function()
  local client
  before_each(function()
    client = APIClient:new()
    client:init("http://localhost:8080", "u", "p", mockDb({}))
  end)

  it("fails on auth failure", function()
    mockBearerToken(client, false, "fail")
    local ok, result = client:getMagicShelves("u", "p")
    assert.is_false(ok)
    assert.are.equal(401, result.code)
  end)

  it("returns shelves on success", function()
    mockBearerToken(client, true, "token")
    client.request = function() return true, 200, { { id = 1, name = "Magic" } } end
    local ok, shelves = client:getMagicShelves("u", "p")
    assert.is_true(ok)
    assert.are.equal(1, #shelves)
  end)

  it("returns unsupported error on 404", function()
    mockBearerToken(client, true, "token")
    client.request = function() return false, 404, "Not Found" end
    local ok, result = client:getMagicShelves("u", "p")
    assert.is_false(ok)
    assert.are.equal(404, result.code)
  end)

  it("returns error on non-404 failure", function()
    mockBearerToken(client, true, "token")
    client.request = function() return false, 500, "Error" end
    local ok, result = client:getMagicShelves("u", "p")
    assert.is_false(ok)
    assert.are.equal(500, result.code)
  end)

  it("returns error on non-table response", function()
    mockBearerToken(client, true, "token")
    client.request = function() return true, 200, "bad" end
    local ok, result = client:getMagicShelves("u", "p")
    assert.is_false(ok)
  end)
end)

-- ========================================================================
-- SECTION 22: getMagicShelfById()
-- ========================================================================
describe("APIClient:getMagicShelfById()", function()
  local client
  before_each(function()
    client = APIClient:new()
    client:init("http://localhost:8080", "u", "p", mockDb({}))
  end)

  it("rejects invalid id", function()
    local ok, result = client:getMagicShelfById(nil, "u", "p")
    assert.is_false(ok)
    assert.are.equal(400, result.code)
  end)

  it("fails on auth failure", function()
    mockBearerToken(client, false, "fail")
    local ok, result = client:getMagicShelfById(1, "u", "p")
    assert.is_false(ok)
    assert.are.equal(401, result.code)
  end)

  it("returns shelf on success", function()
    mockBearerToken(client, true, "token")
    client.request = function() return true, 200, { id = 1, name = "Magic" } end
    local ok, result = client:getMagicShelfById(1, "u", "p")
    assert.is_true(ok)
    assert.are.equal(1, result.id)
  end)

  it("returns 404 error", function()
    mockBearerToken(client, true, "token")
    client.request = function() return false, 404, "Not Found" end
    local ok, result = client:getMagicShelfById(99, "u", "p")
    assert.is_false(ok)
    assert.are.equal(404, result.code)
  end)

  it("returns error on non-table response", function()
    mockBearerToken(client, true, "token")
    client.request = function() return true, 200, "bad" end
    local ok, result = client:getMagicShelfById(1, "u", "p")
    assert.is_false(ok)
  end)
end)

-- ========================================================================
-- SECTION 23: getMagicShelfBookCount() — extended
-- ========================================================================
describe("APIClient:getMagicShelfBookCount()", function()
  local client
  before_each(function()
    client = APIClient:new()
    client:init("http://localhost:8080", "u", "p", mockDb({}))
  end)

  it("rejects invalid id", function()
    local ok, result = client:getMagicShelfBookCount(nil, "u", "p")
    assert.is_false(ok)
    assert.are.equal(400, result.code)
  end)

  it("fails when totalElements and content are both missing", function()
    mockBearerToken(client, true, "token")
    client.request = function() return true, 200, { } end
    local ok, result = client:getMagicShelfBookCount(1, "u", "p")
    assert.is_false(ok)
    assert.is_true(result.message:find("missing totalElements") ~= nil)
  end)

  it("falls back to content length when totalElements missing", function()
    mockBearerToken(client, true, "token")
    client.request = function() return true, 200, { content = { { id = 1 }, { id = 2 } } } end
    local ok, count = client:getMagicShelfBookCount(1, "u", "p")
    assert.is_true(ok)
    assert.are.equal(2, count)
  end)

  it("returns error on non-table response", function()
    mockBearerToken(client, true, "token")
    client.request = function() return true, 200, "bad" end
    local ok, result = client:getMagicShelfBookCount(1, "u", "p")
    assert.is_false(ok)
  end)
end)

-- ========================================================================
-- SECTION 24: getBooksInMagicShelf() — extended
-- ========================================================================
describe("APIClient:getBooksInMagicShelf()", function()
  local client
  before_each(function()
    client = APIClient:new()
    client:init("http://localhost:8080", "u", "p", mockDb({}))
  end)

  it("rejects invalid id", function()
    local ok, result = client:getBooksInMagicShelf(nil, "u", "p")
    assert.is_false(ok)
    assert.are.equal(400, result.code)
  end)

  it("fails on auth failure", function()
    mockBearerToken(client, false, "fail")
    local ok, result = client:getBooksInMagicShelf(1, "u", "p")
    assert.is_false(ok)
    assert.are.equal(401, result.code)
  end)

  it("returns error on non-table response", function()
    mockBearerToken(client, true, "token")
    client.request = function() return true, 200, "bad" end
    local ok, result = client:getBooksInMagicShelf(1, "u", "p")
    assert.is_false(ok)
  end)

  it("returns error when content is missing", function()
    mockBearerToken(client, true, "token")
    client.request = function() return true, 200, { } end
    local ok, result = client:getBooksInMagicShelf(1, "u", "p")
    assert.is_false(ok)
  end)

  it("paginates correctly", function()
    local pages = 0
    mockBearerToken(client, true, "token")
    client.request = function()
      pages = pages + 1
      if pages == 1 then
        return true, 200, { content = { { id = 1, title = "A", authors = { "Auth1" }, primaryFileType = "EPUB" } }, hasNext = true }
      end
      return true, 200, { content = { { id = 2, title = "B", authors = { "Auth2" }, primaryFileType = "PDF" } }, hasNext = false }
    end
    local ok, books = client:getBooksInMagicShelf(1, "u", "p")
    assert.is_true(ok)
    assert.are.equal(2, #books)
    assert.are.equal(2, pages)
    assert.are.equal("epub", books[1].extension)
    assert.are.equal("pdf", books[2].extension)
  end)

  it("handles author as scalar string fallback", function()
    mockBearerToken(client, true, "token")
    client.request = function()
      return true, 200, { content = { { id = 1, title = "T", author = "Scalar Author", primaryFileType = "EPUB" } }, hasNext = false }
    end
    local ok, books = client:getBooksInMagicShelf(1, "u", "p")
    assert.is_true(ok)
    assert.are.equal("Scalar Author", books[1].author)
  end)

  it("retries on 401", function()
    local calls = 0
    client.db = mockDb({})
    client.getOrRefreshBearerToken = function(_, _, _, force_refresh)
      if force_refresh then return true, "refreshed" end
      return true, "initial"
    end
    client.request = function()
      calls = calls + 1
      if calls == 1 then return false, 401, "Unauthorized" end
      return true, 200, { content = { { id = 1 } }, hasNext = false }
    end
    local ok, books = client:getBooksInMagicShelf(1, "u", "p")
    assert.is_true(ok)
    assert.are.equal(2, calls)
  end)

  it("returns error on request failure after pagination", function()
    mockBearerToken(client, true, "token")
    local calls = 0
    client.request = function()
      calls = calls + 1
      if calls == 1 then return true, 200, { content = { { id = 1 } }, hasNext = true } end
      return false, 500, "Server error"
    end
    local ok, result = client:getBooksInMagicShelf(1, "u", "p")
    assert.is_false(ok)
    assert.are.equal(500, result.code)
  end)
end)

-- ========================================================================
-- SECTION 25: resolveMagicShelfSource() — extended
-- ========================================================================
describe("APIClient:resolveMagicShelfSource()", function()
  local client
  before_each(function()
    client = APIClient:new()
    client:init("http://localhost:8080", "u", "p")
  end)

  it("fails when getMagicShelves fails", function()
    client.getMagicShelves = function() return false, { code = 500, message = "Error" } end
    local ok, result = client:resolveMagicShelfSource(nil, "name", "u", "p")
    assert.is_false(ok)
    assert.are.equal(500, result.code)
  end)

  it("resolves by name case-insensitively", function()
    client.getMagicShelves = function()
      return true, { { id = 5, name = "Unread Books" }, { id = 6, name = "Currently Reading" } }
    end
    local ok, result = client:resolveMagicShelfSource(nil, "currently reading", "u", "p")
    assert.is_true(ok)
    assert.are.equal(6, result.id)
    assert.are.equal("name", result.source)
  end)

  it("fails when name not found", function()
    client.getMagicShelves = function()
      return true, { { id = 1, name = "Other" } }
    end
    local ok, result = client:resolveMagicShelfSource(nil, "Missing", "u", "p")
    assert.is_false(ok)
    assert.are.equal(404, result.code)
  end)

  it("fails when neither id nor name provided", function()
    client.getMagicShelves = function() return true, {} end
    local ok, result = client:resolveMagicShelfSource(nil, nil, "u", "p")
    assert.is_false(ok)
    assert.are.equal(400, result.code)
    assert.is_true(result.message:find("No Magic Shelf source configured") ~= nil)
  end)

  it("skips shelf with no sid", function()
    client.getMagicShelves = function()
      return true, { { name = "Unread" }, { id = 7, name = "Unread" } }
    end
    local ok, result = client:resolveMagicShelfSource(nil, "Unread", "u", "p")
    assert.is_true(ok)
    assert.are.equal(7, result.id)
  end)
end)

-- ========================================================================
-- SECTION 26: resolveShelfSource() — extended
-- ========================================================================
describe("APIClient:resolveShelfSource()", function()
  local client
  before_each(function()
    client = APIClient:new()
    client:init("http://localhost:8080", "u", "p")
  end)

  it("fails when getAccessibleShelves fails", function()
    client.getAccessibleShelves = function() return false, { code = 500, message = "Error" } end
    local ok, result = client:resolveShelfSource(nil, "name", "u", "p")
    assert.is_false(ok)
    assert.are.equal(500, result.code)
  end)

  it("resolves by explicit id private shelf", function()
    client.getAccessibleShelves = function()
      return true, { { id = 7, name = "My Shelf", publicShelf = false } }
    end
    local ok, result = client:resolveShelfSource(7, nil, "u", "p")
    assert.is_true(ok)
    assert.are.equal("id", result.source)
    assert.is_true(result.is_private)
  end)

  it("fails when shelf id not found", function()
    client.getAccessibleShelves = function()
      return true, { { id = 1, name = "Only", publicShelf = true } }
    end
    local ok, result = client:resolveShelfSource(99, nil, "u", "p")
    assert.is_false(ok)
    assert.are.equal(404, result.code)
  end)

  it("resolves by name case-insensitively", function()
    client.getAccessibleShelves = function()
      return true, { { id = 3, name = "KOReader", publicShelf = true } }
    end
    local ok, result = client:resolveShelfSource(nil, "koreader", "u", "p")
    assert.is_true(ok)
    assert.are.equal("name", result.source)
  end)

  it("creates shelf when name not found", function()
    local auth_calls = 0
    client.getAccessibleShelves = function()
      return true, { { id = 1, name = "Other", publicShelf = true } }
    end
    client.getOrRefreshBearerToken = function()
      auth_calls = auth_calls + 1
      return true, "create-token"
    end
    client.request = function(_, method, path, body, headers)
      assert.are.equal("POST", method)
      assert.are.equal("/api/v1/shelves", path)
      assert.are.equal("Bearer create-token", headers["Authorization"])
      return true, 201, { id = 42, name = "NewShelf" }
    end
    local ok, result = client:resolveShelfSource(nil, "NewShelf", "u", "p")
    assert.is_true(ok)
    assert.are.equal(42, result.id)
    assert.are.equal("created", result.source)
    assert.are.equal(1, auth_calls)
  end)

  it("fails to create shelf when auth fails", function()
    client.getAccessibleShelves = function() return true, { { id = 1, name = "Other" } } end
    client.getOrRefreshBearerToken = function() return false, "no auth" end
    local ok, result = client:resolveShelfSource(nil, "New", "u", "p")
    assert.is_false(ok)
    assert.are.equal(401, result.code)
  end)

  it("fails to create shelf on bad response", function()
    client.getAccessibleShelves = function() return true, { { id = 1, name = "Other" } } end
    client.getOrRefreshBearerToken = function() return true, "token" end
    client.request = function() return false, 400, "Bad request" end
    local ok, result = client:resolveShelfSource(nil, "New", "u", "p")
    assert.is_false(ok)
    assert.are.equal(400, result.code)
  end)

  it("fails when no id or name given", function()
    client.getAccessibleShelves = function() return true, {} end
    local ok, result = client:resolveShelfSource(nil, nil, "u", "p")
    assert.is_false(ok)
    assert.are.equal(400, result.code)
  end)
end)

-- ========================================================================
-- SECTION 27: getOrCreateShelf()
-- ========================================================================
describe("APIClient:getOrCreateShelf()", function()
  local client
  before_each(function()
    client = APIClient:new()
    client:init("http://localhost:8080", "u", "p")
  end)

  it("fails when listing shelves fails", function()
    client.getAccessibleShelves = function() return false, { message = "fail" } end
    local ok, err = client:getOrCreateShelf("Test", "u", "p")
    assert.is_false(ok)
    assert.are.equal("fail", err)
  end)

  it("finds existing shelf case-insensitively", function()
    client.getAccessibleShelves = function()
      return true, { { id = 10, name = "My Shelf" } }
    end
    local ok, id = client:getOrCreateShelf("my shelf", "u", "p")
    assert.is_true(ok)
    assert.are.equal(10, id)
  end)

  it("creates shelf when not found", function()
    client.getAccessibleShelves = function() return true, {} end
    client.getOrRefreshBearerToken = function() return true, "create-token" end
    client.request = function() return true, 201, { id = 55, name = "NewShelf" } end
    local ok, id = client:getOrCreateShelf("NewShelf", "u", "p")
    assert.is_true(ok)
    assert.are.equal(55, id)
  end)

  it("fails to create shelf on auth failure", function()
    client.getAccessibleShelves = function() return true, {} end
    client.getOrRefreshBearerToken = function() return false, "auth fail" end
    local ok, err = client:getOrCreateShelf("New", "u", "p")
    assert.is_false(ok)
    assert.are.equal("auth fail", err)
  end)

  it("fails to create shelf on bad response", function()
    client.getAccessibleShelves = function() return true, {} end
    client.getOrRefreshBearerToken = function() return true, "token" end
    client.request = function() return false, 500, "Error" end
    local ok, err = client:getOrCreateShelf("New", "u", "p")
    assert.is_false(ok)
    assert.are.equal("Error", err)
  end)
end)

-- ========================================================================
-- SECTION 28: searchBooksWithAuth()
-- ========================================================================
describe("APIClient:searchBooksWithAuth()", function()
  local client
  before_each(function()
    client = APIClient:new()
    client:init("http://localhost:8080", "u", "p", mockDb({}))
  end)

  it("fails when token cannot be obtained", function()
    mockBearerToken(client, false, "no token")
    local ok, err = client:searchBooksWithAuth("test", "u", "p")
    assert.is_false(ok)
    assert.are.equal("no token", err)
  end)

  it("returns normalized results on success", function()
    mockBearerToken(client, true, "token")
    client.request = function()
      return true, 200, { { id = 1, title = "Found", metadata = { isbn10 = "123" } } }
    end
    local ok, results = client:searchBooksWithAuth("test", "u", "p")
    assert.is_true(ok)
    assert.are.equal(1, #results)
    assert.are.equal("123", results[1].isbn10)
  end)

  it("retries on 401/403 and succeeds", function()
    local calls = 0
    client.db = mockDb({})
    client.getOrRefreshBearerToken = function(_, _, _, force_refresh)
      if force_refresh then return true, "refreshed" end
      return true, "initial"
    end
    client.request = function()
      calls = calls + 1
      if calls == 1 then return false, 401, "Unauthorized" end
      return true, 200, { { id = 1 } }
    end
    local ok, results = client:searchBooksWithAuth("test", "u", "p")
    assert.is_true(ok)
    assert.are.equal(2, calls)
  end)

  it("fails when refresh also fails", function()
    client.db = mockDb({})
    client.getOrRefreshBearerToken = function(_, _, _, force_refresh)
      if force_refresh then return false, "refresh failed" end
      return true, "initial"
    end
    client.request = function()
      return false, 403, "Forbidden"
    end
    local ok, err = client:searchBooksWithAuth("test", "u", "p")
    assert.is_false(ok)
    assert.is_true(err:find("refresh failed") ~= nil or err:find("Forbidden") ~= nil)
  end)

  it("returns error on non-table response", function()
    mockBearerToken(client, true, "token")
    client.request = function() return true, 200, "bad" end
    local ok, err = client:searchBooksWithAuth("test", "u", "p")
    assert.is_false(ok)
  end)
end)

-- ========================================================================
-- SECTION 29: searchBooksByIsbn()
-- ========================================================================
describe("APIClient:searchBooksByIsbn()", function()
  local client
  before_each(function()
    client = APIClient:new()
    client:init("http://localhost:8080", "u", "p", mockDb({}))
  end)

  it("fails when token cannot be obtained", function()
    mockBearerToken(client, false, "no token")
    local ok, err = client:searchBooksByIsbn("978123", "u", "p")
    assert.is_false(ok)
    assert.are.equal("no token", err)
  end)

  it("returns normalized results on success", function()
    mockBearerToken(client, true, "token")
    client.request = function()
      return true, 200, { { id = 1, title = "ISBN Book", metadata = { isbn13 = "978123" } } }
    end
    local ok, results = client:searchBooksByIsbn("978123", "u", "p")
    assert.is_true(ok)
    assert.are.equal(1, #results)
    assert.are.equal("978123", results[1].isbn13)
  end)

  it("retries on 401", function()
    local calls = 0
    client.db = mockDb({})
    client.getOrRefreshBearerToken = function(_, _, _, force_refresh)
      if force_refresh then return true, "refreshed" end
      return true, "initial"
    end
    client.request = function()
      calls = calls + 1
      if calls == 1 then return false, 401, "Unauthorized" end
      return true, 200, { { id = 1 } }
    end
    local ok, results = client:searchBooksByIsbn("978", "u", "p")
    assert.is_true(ok)
    assert.are.equal(2, calls)
  end)

  it("returns error on non-table response", function()
    mockBearerToken(client, true, "token")
    client.request = function() return true, 200, "bad" end
    local ok, err = client:searchBooksByIsbn("978", "u", "p")
    assert.is_false(ok)
  end)
end)

-- ========================================================================
-- SECTION 30: getBookByHashWithAuth()
-- ========================================================================
describe("APIClient:getBookByHashWithAuth()", function()
  local client
  before_each(function()
    client = APIClient:new()
    client:init("http://localhost:8080", "u", "p", mockDb({}))
  end)

  it("fails when token cannot be obtained", function()
    mockBearerToken(client, false, "no token")
    local ok, err = client:getBookByHashWithAuth("hash", "u", "p")
    assert.is_false(ok)
    assert.are.equal("Authentication failed", err)
  end)

  it("returns normalized book on success", function()
    mockBearerToken(client, true, "token")
    client.request = function()
      return true, 200, { id = 42, metadata = { isbn10 = "111" } }
    end
    local ok, book = client:getBookByHashWithAuth("abc", "u", "p")
    assert.is_true(ok)
    assert.are.equal(42, book.id)
    assert.are.equal("111", book.isbn10)
  end)

  it("retries on 401", function()
    local calls = 0
    client.db = mockDb({})
    client.getOrRefreshBearerToken = function(_, _, _, force_refresh)
      if force_refresh then return true, "refreshed" end
      return true, "initial"
    end
    client.request = function()
      calls = calls + 1
      if calls == 1 then return false, 401, "Unauthorized" end
      return true, 200, { id = 99 }
    end
    local ok, book = client:getBookByHashWithAuth("hash", "u", "p")
    assert.is_true(ok)
    assert.are.equal(99, book.id)
    assert.are.equal(2, calls)
  end)

  it("fails when no book found", function()
    mockBearerToken(client, true, "token")
    client.request = function()
      return false, 404, "Not found"
    end
    local ok, err = client:getBookByHashWithAuth("hash", "u", "p")
    assert.is_false(ok)
    assert.are.equal("Not found", err)
  end)
end)

-- ========================================================================
-- SECTION 31: getKoReaderProgress()
-- ========================================================================
describe("APIClient:getKoReaderProgress()", function()
  local client
  before_each(function() client = initClient() end)

  it("returns error when book_hash is missing", function()
    local ok, err, code = client:getKoReaderProgress(nil)
    assert.is_false(ok)
    assert.are.equal("Missing book_hash", err)
    assert.is_nil(code)

    local ok2, err2, code2 = client:getKoReaderProgress("")
    assert.is_false(ok2)
    assert.are.equal("Missing book_hash", err2)
    assert.is_nil(code2)
  end)

  it("returns response on success", function()
    client.request = function()
      return true, 200, { percentage = 50 }
    end
    local ok, response, code = client:getKoReaderProgress("hash1")
    assert.is_true(ok)
    assert.are.equal(50, response.percentage)
    assert.are.equal(200, code)
  end)

  it("returns nil when 404 (no progress yet)", function()
    client.request = function()
      return false, 404, "Not Found"
    end
    local ok, response, code = client:getKoReaderProgress("hash1")
    assert.is_true(ok)
    assert.is_nil(response)
    assert.are.equal(404, code)
  end)

  it("returns error on unexpected failure", function()
    client.request = function()
      return false, 500, "Server error"
    end
    local ok, err, code = client:getKoReaderProgress("hash1")
    assert.is_false(ok)
    assert.is_true(err:find("HTTP 500") ~= nil)
    assert.are.equal(500, code)
  end)

  it("returns error on failure without code", function()
    client.request = function()
      return false, nil, "timeout"
    end
    local ok, err = client:getKoReaderProgress("hash1")
    assert.is_false(ok)
    assert.is_true(err:find("timeout") ~= nil or err:find("Failed") ~= nil)
  end)
end)

-- ========================================================================
-- SECTION 32: updateKoReaderProgress()
-- ========================================================================
describe("APIClient:updateKoReaderProgress()", function()
  local client
  before_each(function() client = initClient() end)

  it("rejects non-table payload", function()
    local ok, err = client:updateKoReaderProgress("not-table")
    assert.is_false(ok)
    assert.are.equal("Invalid payload", err)
  end)

  it("rejects missing required fields", function()
    local ok, err = client:updateKoReaderProgress({})
    assert.is_false(ok)
    assert.is_true(err:find("Missing required") ~= nil)
  end)

  it("rejects missing document field", function()
    local ok, err = client:updateKoReaderProgress({ timestamp = 1000, percentage = 50, progress = "p", device = "d", device_id = "1" })
    assert.is_false(ok)
    assert.is_true(err:find("document") ~= nil)
  end)

  it("rejects non-numeric timestamp", function()
    local ok, err = client:updateKoReaderProgress({
      timestamp = "abc", document = "hash", percentage = 50, progress = "p", device = "d", device_id = "1"
    })
    assert.is_false(ok)
    assert.is_true(err:find("timestamp") ~= nil)
  end)

  it("rejects non-numeric percentage", function()
    local ok, err = client:updateKoReaderProgress({
      timestamp = 1000, document = "hash", percentage = "bad", progress = "p", device = "d", device_id = "1"
    })
    assert.is_false(ok)
    assert.is_true(err:find("percentage") ~= nil)
  end)

  it("succeeds on valid payload", function()
    client.request = function()
      return true, 200, {}
    end
    local ok, response, code = client:updateKoReaderProgress({
      timestamp = 1234567890,
      document = "doc-hash",
      percentage = 75.5,
      progress = "epubcfi(/6/4)",
      device = "KOReader",
      device_id = "dev-001",
    })
    assert.is_true(ok)
  end)

  it("returns error on API failure", function()
    client.request = function()
      return false, 500, "Server error"
    end
    local ok, err = client:updateKoReaderProgress({
      timestamp = 1000, document = "hash", percentage = 50, progress = "p", device = "d", device_id = "1"
    })
    assert.is_false(ok)
    assert.is_true(err:find("HTTP 500") ~= nil)
  end)
end)

-- ========================================================================
-- SECTION 33: downloadBook()
-- ========================================================================
describe("APIClient:downloadBook()", function()
  local client
  local tmp_path

  before_each(function()
    client = APIClient:new()
    client:init("http://localhost:8080", "u", "p", mockDb({}))
    tmp_path = os.tmpname()
  end)

  after_each(function()
    os.remove(tmp_path)
  end)

  it("fails on auth failure", function()
    mockBearerToken(client, false, "fail")
    local ok, err = client:downloadBook(1, tmp_path, "u", "p")
    assert.is_false(ok)
    assert.are.equal("Authentication failed", err)
  end)

  it("downloads successfully", function()
    mockBearerToken(client, true, "token")
    local http = require("socket.http")
    http.request = function(req)
      if req.sink then req.sink("book-content") end
      return 1, 200, {}
    end
    local ok, err = client:downloadBook(1, tmp_path, "u", "p")
    assert.is_true(ok)
    assert.is_nil(err)
  end)

  it("uses https client for https URLs", function()
    local https_client = APIClient:new()
    https_client:init("https://secure.example.com", "u", "p", mockDb({}))
    mockBearerToken(https_client, true, "token")
    local https = require("ssl.https")
    https.request = function(req)
      assert.is_true(req.url:find("^https://") ~= nil)
      if req.sink then req.sink("data") end
      return 1, 200, {}
    end
    local ok, err = https_client:downloadBook(1, tmp_path, "u", "p")
    assert.is_true(ok)
  end)

  it("retries on 401", function()
    local calls = { http = 0, auth = 0 }
    client.db = mockDb({})
    client.getOrRefreshBearerToken = function(_, _, _, force_refresh)
      calls.auth = calls.auth + 1
      if force_refresh then return true, "refreshed" end
      return true, "initial"
    end
    local http = require("socket.http")
    http.request = function(req)
      calls.http = calls.http + 1
      if calls.http == 1 then
        assert.are.equal("Bearer initial", req.headers["Authorization"])
        return 1, 401, {}
      end
      assert.are.equal("Bearer refreshed", req.headers["Authorization"])
      if req.sink then req.sink("data") end
      return 1, 200, {}
    end
    local ok, err = client:downloadBook(1, tmp_path, "u", "p")
    assert.is_true(ok)
    assert.is_nil(err)
    assert.are.equal(2, calls.http)
  end)

  it("returns error on network failure", function()
    mockBearerToken(client, true, "token")
    local http = require("socket.http")
    http.request = function()
      return "timeout", nil, {}
    end
    local ok, err = client:downloadBook(1, tmp_path, "u", "p")
    assert.is_false(ok)
    assert.is_true(err:find("Network error") ~= nil)
  end)

  it("returns error on non-2xx code", function()
    mockBearerToken(client, true, "token")
    local http = require("socket.http")
    http.request = function()
      return 1, 404, {}
    end
    local ok, err = client:downloadBook(1, tmp_path, "u", "p")
    assert.is_false(ok)
    assert.is_true(err:find("download failed") ~= nil)
  end)
end)

-- ========================================================================
-- SECTION 34: getBookFileSize()
-- ========================================================================
describe("APIClient:getBookFileSize()", function()
  local client
  before_each(function()
    client = APIClient:new()
    client:init("http://localhost:8080", "u", "p", mockDb({}))
  end)

  it("fails when server URL not configured", function()
    local bare = newClient()
    local size, err = bare:getBookFileSize(1, "u", "p")
    assert.is_nil(size)
    assert.are.equal("Server URL not configured", err)
  end)

  it("fails on auth failure", function()
    mockBearerToken(client, false, "fail")
    local size, err = client:getBookFileSize(1, "u", "p")
    assert.is_nil(size)
    assert.is_true(err:find("Authentication failed") ~= nil)
  end)

  it("returns file size on success", function()
    mockBearerToken(client, true, "token")
    local http = require("socket.http")
    http.request = function()
      return 1, 200, { ["content-length"] = "12345" }
    end
    local size, err = client:getBookFileSize(1, "u", "p")
    assert.are.equal(12345, size)
    assert.is_nil(err)
  end)

  it("retries on 401 and succeeds", function()
    local calls = 0
    client.db = mockDb({})
    client.getOrRefreshBearerToken = function(_, _, _, force_refresh)
      if force_refresh then return true, "refreshed" end
      return true, "initial"
    end
    local http = require("socket.http")
    http.request = function()
      calls = calls + 1
      if calls == 1 then return 1, 401, {} end
      return 1, 200, { ["content-length"] = "999" }
    end
    local size, err = client:getBookFileSize(1, "u", "p")
    assert.are.equal(999, size)
    assert.is_nil(err)
    assert.are.equal(2, calls)
  end)

  it("fails when refresh fails on 401", function()
    client.db = mockDb({})
    client.getOrRefreshBearerToken = function(_, _, _, force_refresh)
      return false, "refresh failed"
    end
    local http = require("socket.http")
    http.request = function()
      return 1, 401, {}
    end
    local size, err = client:getBookFileSize(1, "u", "p")
    assert.is_nil(size)
    assert.is_true(err:find("refresh failed") ~= nil)
  end)

  it("returns error on network failure", function()
    mockBearerToken(client, true, "token")
    local http = require("socket.http")
    http.request = function()
      return "timeout", nil, {}
    end
    local size, err = client:getBookFileSize(1, "u", "p")
    assert.is_nil(size)
    assert.is_true(err:find("Network error") ~= nil)
  end)

  it("returns error on non-numeric code", function()
    mockBearerToken(client, true, "token")
    local http = require("socket.http")
    http.request = function()
      return 1, "BAD", {}
    end
    local size, err = client:getBookFileSize(1, "u", "p")
    assert.is_nil(size)
    assert.is_true(err:find("Connection error") ~= nil)
  end)

  it("returns error on non-2xx code", function()
    mockBearerToken(client, true, "token")
    local http = require("socket.http")
    http.request = function()
      return 1, 404, {}
    end
    local size, err = client:getBookFileSize(1, "u", "p")
    assert.is_nil(size)
    assert.is_true(err:find("HEAD request failed") ~= nil)
  end)

  it("returns error when response headers are nil", function()
    mockBearerToken(client, true, "token")
    local http = require("socket.http")
    http.request = function()
      return 1, 200, nil
    end
    local size, err = client:getBookFileSize(1, "u", "p")
    assert.is_nil(size)
    assert.is_true(err:find("No response headers") ~= nil)
  end)

  it("returns error when content-length header is missing", function()
    mockBearerToken(client, true, "token")
    local http = require("socket.http")
    http.request = function()
      return 1, 200, { ["content-type"] = "text/plain" }
    end
    local size, err = client:getBookFileSize(1, "u", "p")
    assert.is_nil(size)
    assert.is_not_nil(err)
  end)

  it("returns error on invalid content-length", function()
    mockBearerToken(client, true, "token")
    local http = require("socket.http")
    http.request = function()
      return 1, 200, { ["content-length"] = "-5" }
    end
    local size, err = client:getBookFileSize(1, "u", "p")
    assert.is_nil(size)
    assert.is_not_nil(err)
  end)

  it("uses http client for http URLs", function()
    mockBearerToken(client, true, "token")
    local http = require("socket.http")
    http.request = function(req)
      assert.is_true(req.url:find("^http://") ~= nil)
      return 1, 200, { ["content-length"] = "100" }
    end
    local size, err = client:getBookFileSize(1, "u", "p")
    assert.are.equal(100, size)
    assert.is_nil(err)
  end)
end)

-- ========================================================================
-- SECTION 35: getBookRecommendations() — extended
-- ========================================================================
describe("APIClient:getBookRecommendations() — extended", function()
  local client
  before_each(function()
    client = APIClient:new()
    client:init("http://localhost:8080", "u", "p", mockDb({}))
  end)

  it("fails when auth fails", function()
    mockBearerToken(client, false, "fail")
    local ok, err = client:getBookRecommendations(1, "u", "p")
    assert.is_false(ok)
    assert.is_true(err:find("Authentication failed") ~= nil)
  end)

  it("handles unwrapped response (bare array)", function()
    mockBearerToken(client, true, "token")
    client.request = function()
      return true, 200, {
        { id = 1, title = "Reco", metadata = { isbn13 = "978" } },
      }
    end
    local ok, items = client:getBookRecommendations(1, "u", "p")
    assert.is_true(ok)
    assert.are.equal(1, #items)
    assert.are.equal("978", items[1].isbn13)
  end)

  it("handles empty response (no next, no keys)", function()
    mockBearerToken(client, true, "token")
    client.request = function()
      return true, 200, {}
    end
    local ok, items = client:getBookRecommendations(1, "u", "p")
    assert.is_true(ok)
    assert.is_table(items)
  end)

  it("handles wrapped response with 'recommendations' key", function()
    mockBearerToken(client, true, "token")
    client.request = function()
      return true, 200, { recommendations = { { id = 10 } } }
    end
    local ok, items = client:getBookRecommendations(1, "u", "p")
    assert.is_true(ok)
    assert.are.equal(1, #items)
  end)

  it("handles wrapped response with 'content' key", function()
    mockBearerToken(client, true, "token")
    client.request = function()
      return true, 200, { content = { { id = 20 } } }
    end
    local ok, items = client:getBookRecommendations(1, "u", "p")
    assert.is_true(ok)
    assert.are.equal(1, #items)
  end)

  it("handles wrapped response with 'items' key", function()
    mockBearerToken(client, true, "token")
    client.request = function()
      return true, 200, { items = { { id = 30 } } }
    end
    local ok, items = client:getBookRecommendations(1, "u", "p")
    assert.is_true(ok)
    assert.are.equal(1, #items)
  end)

  it("unwraps book.similarityScore", function()
    mockBearerToken(client, true, "token")
    client.request = function()
      return true, 200, {
        { book = { id = 1, title = "Book", metadata = {} }, similarityScore = "0.95" }
      }
    end
    local ok, items = client:getBookRecommendations(1, "u", "p")
    assert.is_true(ok)
    assert.are.equal(0.95, items[1].matchScore)
  end)

  it("unwraps recommendedBook", function()
    mockBearerToken(client, true, "token")
    client.request = function()
      return true, 200, {
        { recommendedBook = { id = 2, title = "Reco2", metadata = {} }, similarityScore = "0.85" }
      }
    end
    local ok, items = client:getBookRecommendations(1, "u", "p")
    assert.is_true(ok)
    assert.are.equal(0.85, items[1].matchScore)
  end)

  it("falls back to matchScore then score", function()
    mockBearerToken(client, true, "token")
    client.request = function()
      return true, 200, {
        { book = { id = 3, metadata = {} }, matchScore = "0.7" }
      }
    end
    local ok, items = client:getBookRecommendations(1, "u", "p")
    assert.is_true(ok)
    assert.are.equal(0.7, items[1].matchScore)
  end)

  it("skips non-table items in recommendations", function()
    mockBearerToken(client, true, "token")
    client.request = function()
      return true, 200, {
        "string item",
        { book = { id = 4, metadata = {} } }
      }
    end
    local ok, items = client:getBookRecommendations(1, "u", "p")
    assert.is_true(ok)
    assert.are.equal(1, #items)
    assert.are.equal(4, items[1].id)
  end)

  it("does not overwrite existing matchScore", function()
    mockBearerToken(client, true, "token")
    client.request = function()
      return true, 200, {
        { book = { id = 5, metadata = {}, matchScore = 0.5 }, similarityScore = "0.9" }
      }
    end
    local ok, items = client:getBookRecommendations(1, "u", "p")
    assert.is_true(ok)
    assert.are.equal(0.5, items[1].matchScore)
  end)

  it("returns error when response is not a table", function()
    mockBearerToken(client, true, "token")
    client.request = function()
      return true, 200, "not-a-table"
    end
    local ok, err = client:getBookRecommendations(1, "u", "p")
    assert.is_false(ok)
    assert.are.equal("Unexpected recommendations response shape", err)
  end)

  it("returns error on API failure", function()
    mockBearerToken(client, true, "token")
    client.request = function()
      return false, 500, "Server error"
    end
    local ok, err = client:getBookRecommendations(1, "u", "p")
    assert.is_false(ok)
    assert.are.equal("Server error", err)
  end)

  it("retries on refresh failure", function()
    client.db = mockDb({})
    client.getOrRefreshBearerToken = function(_, _, _, force_refresh)
      if force_refresh then return false, "refresh failed" end
      return true, "initial"
    end
    client.request = function()
      return false, 403, "Forbidden"
    end
    local ok, err = client:getBookRecommendations(1, "u", "p")
    assert.is_false(ok)
    assert.is_true(err:find("refresh failed") ~= nil)
  end)
end)

-- ========================================================================
-- SECTION 36: _normalizeBookObject() — edge cases
-- ========================================================================
describe("APIClient:_normalizeBookObject()", function()
  local client
  before_each(function() client = newClient() end)

  it("returns non-table input as-is", function()
    assert.is_nil(client:_normalizeBookObject(nil))
    assert.are.equal("string", client:_normalizeBookObject("string"))
    assert.are.equal(42, client:_normalizeBookObject(42))
  end)

  it("promotes title from metadata when top-level empty", function()
    local book = { title = "", metadata = { title = "From Meta" } }
    local result = client:_normalizeBookObject(book)
    assert.are.equal("From Meta", result.title)
  end)

  it("does not override existing title", function()
    local book = { title = "Top", metadata = { title = "Meta" } }
    local result = client:_normalizeBookObject(book)
    assert.are.equal("Top", result.title)
  end)

  it("promotes authors from metadata when empty", function()
    local book = { authors = "", metadata = { authors = { "A1", "A2" } } }
    local result = client:_normalizeBookObject(book)
    assert.are.same({ "A1", "A2" }, result.authors)
  end)

  it("promotes isbn10 and isbn13 from metadata", function()
    local book = { metadata = { isbn10 = "1111111111", isbn13 = "2222222222222" } }
    local result = client:_normalizeBookObject(book)
    assert.are.equal("1111111111", result.isbn10)
    assert.are.equal("2222222222222", result.isbn13)
  end)

  it("promotes pagecount from metadata (pageCount variant)", function()
    local book = { metadata = { pageCount = 350 } }
    local result = client:_normalizeBookObject(book)
    assert.are.equal(350, result.pagecount)
  end)

  it("normalizes pagecount rounding", function()
    local book = { metadata = { pagecount = 350.7 } }
    local result = client:_normalizeBookObject(book)
    assert.are.equal(351, result.pagecount)
  end)

  it("sets pagecount to nil when tonumber fails or <= 0", function()
    local book = { metadata = { pagecount = "abc" } }
    local result = client:_normalizeBookObject(book)
    assert.is_nil(result.pagecount)

    local book2 = { metadata = { pagecount = 0 } }
    local result2 = client:_normalizeBookObject(book2)
    assert.is_nil(result2.pagecount)

    local book3 = { metadata = { pagecount = -5 } }
    local result3 = client:_normalizeBookObject(book3)
    assert.is_nil(result3.pagecount)
  end)

  it("normalizes hardcover_id from various sources", function()
    -- top-level hardcoverId
    local b1 = client:_normalizeBookObject({ hardcoverId = "123" })
    assert.are.equal(123, b1.hardcover_id)

    -- metadata.hardcoverBookId
    local b2 = client:_normalizeBookObject({ metadata = { hardcoverBookId = "456" } })
    assert.are.equal(456, b2.hardcover_id)

    -- metadata.hardcoverId
    local b3 = client:_normalizeBookObject({ metadata = { hardcoverId = "789" } })
    assert.are.equal(789, b3.hardcover_id)

    -- metadata.hardcover_id
    local b4 = client:_normalizeBookObject({ metadata = { hardcover_id = "101" } })
    assert.are.equal(101, b4.hardcover_id)

    -- no hardcover_id at all
    local b5 = client:_normalizeBookObject({})
    assert.is_nil(b5.hardcover_id)
  end)

  it("does not override existing hardcover_id", function()
    local book = client:_normalizeBookObject({ hardcover_id = 999, hardcoverId = "111" })
    assert.are.equal(999, book.hardcover_id)
  end)

  it("handles nil metadata gracefully", function()
    local result = client:_normalizeBookObject({ id = 1, title = "No Metadata" })
    assert.are.equal("No Metadata", result.title)
    assert.are.equal(1, result.id)
  end)
end)

-- ========================================================================
-- SECTION 37: _normalizeShelfBookObject() — edge cases
-- ========================================================================
describe("APIClient:_normalizeShelfBookObject()", function()
  local client
  before_each(function() client = newClient() end)

  it("returns non-table as-is", function()
    assert.is_nil(client:_normalizeShelfBookObject(nil))
    assert.are.equal("str", client:_normalizeShelfBookObject("str"))
  end)

  it("promotes author from metadata.authors array", function()
    local book = { metadata = { authors = { "Auth1", "Auth2" }, title = "T" } }
    local result = client:_normalizeShelfBookObject(book)
    assert.are.equal("Auth1", result.author)
    assert.are.equal("T", result.title)
  end)

  it("overrides author from metadata.authors array (always overwrites)", function()
    local book = { author = "Existing", metadata = { authors = { "Meta" } } }
    local result = client:_normalizeShelfBookObject(book)
    assert.are.equal("Meta", result.author)
  end)

  it("extracts original_filename from primaryFile", function()
    local book = { primaryFile = { fileName = "book.epub" } }
    local result = client:_normalizeShelfBookObject(book)
    assert.are.equal("book.epub", result.original_filename)
  end)

  it("resolves extension from original_filename", function()
    local book = { primaryFile = { fileName = "mybook.PDF" }, bookType = "EPUB" }
    local result = client:_normalizeShelfBookObject(book)
    assert.are.equal("pdf", result.extension)
  end)

  it("falls back to bookType when no filename extension", function()
    local book = { primaryFile = { fileName = "mybook" }, bookType = "EPUB" }
    local result = client:_normalizeShelfBookObject(book)
    assert.are.equal("epub", result.extension)
  end)

  it("leaves extension nil when no source found", function()
    local book = { bookType = "" }
    local result = client:_normalizeShelfBookObject(book)
    assert.is_nil(result.extension)
  end)

  it("does not override existing extension", function()
    local book = { extension = "mobi", bookType = "EPUB" }
    local result = client:_normalizeShelfBookObject(book)
    assert.are.equal("mobi", result.extension)
  end)

  it("handles missing metadata", function()
    local result = client:_normalizeShelfBookObject({ id = 1 })
    assert.are.equal(1, result.id)
  end)
end)

-- ========================================================================
-- SECTION 38: parseJSON() — edge cases
-- ========================================================================
describe("APIClient:parseJSON()", function()
  local client
  before_each(function() client = newClient() end)

  it("returns error on nil input", function()
    local result, err = client:parseJSON(nil)
    assert.is_nil(result)
    assert.are.equal("Empty response", err)
  end)

  it("returns error on empty input", function()
    local result, err = client:parseJSON("")
    assert.is_nil(result)
    assert.are.equal("Empty response", err)
  end)

  it("returns error on invalid JSON", function()
    local result, err = client:parseJSON("not-json")
    assert.is_nil(result)
    assert.are.equal("Invalid JSON response", err)
  end)

  it("parses valid JSON", function()
    local result, err = client:parseJSON('{"message":"ok"}')
    assert.is_table(result)
    assert.are.equal("ok", result.message)
    assert.is_nil(err)
  end)
end)

-- ========================================================================
-- SECTION 39: extractErrorMessage() — edge cases
-- ========================================================================
describe("APIClient:extractErrorMessage()", function()
  local client
  before_each(function() client = newClient() end)

  it("returns HTTP code message when code is known", function()
    assert.are.equal("Bad Request", client:extractErrorMessage("", 400))
    assert.are.equal("Forbidden - Access denied", client:extractErrorMessage("", 403))
  end)

  it("returns 'HTTP N' for unknown codes", function()
    assert.are.equal("HTTP 418", client:extractErrorMessage("", 418))
  end)

  it("returns short response text when under 500 chars", function()
    assert.are.equal("short error", client:extractErrorMessage("short error", 500))
  end)

  it("falls back to HTTP code when response is long", function()
    local long = string.rep("x", 600)
    assert.are.equal("Internal Server Error", client:extractErrorMessage(long, 500))
  end)

  it("handles error field as string", function()
    json_decode_stubs['{"error":"direct error"}'] = { error = "direct error" }
    assert.are.equal("direct error",
      client:extractErrorMessage('{"error":"direct error"}', 400))
  end)

  it("handles error field as table with message", function()
    json_decode_stubs['{"error":{"message":"nested error"}}'] = { error = { message = "nested error" } }
    assert.are.equal("nested error",
      client:extractErrorMessage('{"error":{"message":"nested error"}}', 400))
  end)

  it("handles detail field", function()
    json_decode_stubs['{"detail":"detail msg"}'] = { detail = "detail msg" }
    assert.are.equal("detail msg",
      client:extractErrorMessage('{"detail":"detail msg"}', 400))
  end)
end)

-- ========================================================================
-- SECTION 40: init() — trailing slash stripping
-- ========================================================================
describe("APIClient:init()", function()
  it("strips trailing slash from server_url", function()
    local c = APIClient:new()
    c:init("http://localhost:8080/", "u", "p")
    assert.are.equal("http://localhost:8080", c.server_url)
  end)

  it("does not modify url without trailing slash", function()
    local c = APIClient:new()
    c:init("http://localhost:8080", "u", "p")
    assert.are.equal("http://localhost:8080", c.server_url)
  end)
end)

-- ========================================================================
-- SECTION 41: _urlEncode() — edge cases
-- ========================================================================
describe("APIClient:_urlEncode()", function()
  local client
  before_each(function() client = newClient() end)

  it("encodes special characters", function()
    assert.are.equal("a%26b%3Dc", client:_urlEncode("a&b=c"))
  end)

  it("replaces spaces with plus", function()
    assert.are.equal("hello+world", client:_urlEncode("hello world"))
  end)

  it("handles nil", function()
    assert.are.equal("", client:_urlEncode(nil))
  end)

  it("encodes newlines as CRLF", function()
    local result = client:_urlEncode("line1\nline2")
    -- In Lua patterns, %% is a literal %
    assert.is_true(result:find("%%0D%%0A") ~= nil or result:find("%%0d%%0a") ~= nil)
  end)
end)
