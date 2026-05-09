package.path = table.concat({
  "bookloresync.koplugin/?.lua",
  "bookloresync.koplugin/?/init.lua",
  package.path,
}, ";")

package.preload["logger"] = function()
  return {
    info = function() end,
    warn = function() end,
    err = function() end,
    dbg = function() end,
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
    sink = { table = function(tbl)
      return function(chunk)
        if chunk then
          tbl[#tbl + 1] = chunk
        end
        return 1
      end
    end },
    source = { string = function(s)
      local done = false
      return function()
        if done then return nil end
        done = true
        return s
      end
    end }
  }
end

package.preload["ffi/sha2"] = function()
  return { md5 = function(s) return "md5-" .. tostring(s) end }
end

package.preload["json"] = function()
  local function decode(input)
    if input == '{"message":"ok"}' then
      return { message = "ok" }
    end
    if input == '{"message":"nope"}' then
      return { message = "nope" }
    end
    if input == '{"error":"bad"}' then
      return { error = "bad" }
    end
    if input == '{"error":{"message":"nested"}}' then
      return { error = { message = "nested" } }
    end
    if input == '{"detail":"details"}' then
      return { detail = "details" }
    end
    if input == '{"accessToken":"token-abc"}' then
      return { accessToken = "token-abc" }
    end
    if input == '[1,2,3]' then
      return { 1, 2, 3 }
    end
    error("invalid json")
  end

  return {
    decode = decode,
    encode = function() return "{}" end,
  }
end

local APIClient = require("booklore_api_client")

describe("APIClient helper methods", function()
  local client

  before_each(function()
    client = APIClient:new()
  end)

  it("encodes query strings", function()
    assert.are.equal("The+Name+of+the+Rose", client:_urlEncode("The Name of the Rose"))
    assert.are.equal("a%26b", client:_urlEncode("a&b"))
    assert.are.equal("", client:_urlEncode(nil))
  end)

  it("parses valid JSON and rejects invalid JSON", function()
    local parsed, err = client:parseJSON('{"message":"ok"}')
    assert.is_table(parsed)
    assert.are.equal("ok", parsed.message)
    assert.is_nil(err)

    local parsed_bad, err_bad = client:parseJSON("not-json")
    assert.is_nil(parsed_bad)
    assert.are.equal("Invalid JSON response", err_bad)
  end)

  it("injects default KOReader auth headers for generic requests", function()
    client:init("http://localhost:8080", "sync-user", "sync-pass")

    local http = require("socket.http")
    local captured
    http.request = function(req)
      captured = req
      return 1, 204, {}
    end

    local ok, code, response = client:request("GET", "/api/v1/test")
    assert.is_true(ok)
    assert.are.equal(204, code)
    assert.is_nil(response)
    assert.are.equal("sync-user", captured.headers["x-auth-user"])
    assert.are.equal("md5-sync-pass", captured.headers["x-auth-key"])
  end)

  it("allows opting out of default auth header injection", function()
    client:init("http://localhost:8080", "sync-user", "sync-pass")

    local http = require("socket.http")
    local captured
    http.request = function(req)
      captured = req
      return 1, 204, {}
    end

    local ok = client:request("GET", "/api/v1/test", nil, nil, { skip_default_auth = true })
    assert.is_true(ok)
    assert.is_nil(captured.headers["x-auth-user"])
    assert.is_nil(captured.headers["x-auth-key"])
  end)

  it("does not attach KOReader auth headers when logging in for Bearer token", function()
    client:init("http://localhost:8080", "sync-user", "sync-pass")

    local http = require("socket.http")
    local captured
    http.request = function(req)
      captured = req
      if req.sink then
        req.sink('{"accessToken":"token-abc"}')
      end
      return 1, 200, {}
    end

    local ok, token = client:loginBooklore("booklore-user", "booklore-pass")
    assert.is_true(ok)
    assert.are.equal("token-abc", token)
    assert.is_nil(captured.headers["x-auth-user"])
    assert.is_nil(captured.headers["x-auth-key"])
  end)

  it("extracts error messages from response payload", function()
    assert.are.equal("nope", client:extractErrorMessage('{"message":"nope"}', 400))
    assert.are.equal("bad", client:extractErrorMessage('{"error":"bad"}', 400))
    assert.are.equal("nested", client:extractErrorMessage('{"error":{"message":"nested"}}', 400))
    assert.are.equal("details", client:extractErrorMessage('{"detail":"details"}', 400))
  end)

  it("falls back to HTTP status text for empty/large payloads", function()
    local large = string.rep("x", 600)
    assert.are.equal("Unauthorized - Invalid credentials", client:extractErrorMessage(large, 401))
    assert.are.equal("HTTP 418", client:extractErrorMessage(large, 418))
  end)

  it("normalizes nested metadata into top-level fields", function()
    local book = { metadata = { isbn10 = "123", isbn13 = "456" } }
    local normalized = client:_normalizeBookObject(book)
    assert.are.equal("123", normalized.isbn10)
    assert.are.equal("456", normalized.isbn13)
  end)

  it("normalizes shelf books", function()
    local shelf = {
      metadata = {
        authors = { "Author One", "Author Two" },
        isbn10 = "111",
        isbn13 = "222",
      },
      bookType = "PDF",
    }

    local normalized = client:_normalizeShelfBookObject(shelf)
    assert.are.equal("Author One", normalized.author)
    assert.are.equal("111", normalized.isbn10)
    assert.are.equal("222", normalized.isbn13)
    assert.are.equal("pdf", normalized.extension)
  end)

  it("updates reading status for a book", function()
    local captured = {}

    client.getOrRefreshBearerToken = function(_, username, password)
      assert.are.equal("user", username)
      assert.are.equal("pass", password)
      return true, "token-1"
    end

    client.request = function(_, method, path, body, headers)
      captured.method = method
      captured.path = path
      captured.body = body
      captured.headers = headers
      return true, 200, {}
    end

    local ok, err = client:updateBookStatus({ 42 }, "partially_read", "user", "pass")
    assert.is_true(ok)
    assert.is_nil(err)
    assert.are.equal("POST", captured.method)
    assert.are.equal("/api/v1/books/status", captured.path)
    assert.are.equal("PARTIALLY_READ", captured.body.status)
    assert.are.equal(42, captured.body.bookIds[1])
    assert.are.equal("Bearer token-1", captured.headers["Authorization"])
  end)

  it("retries reading-status update after token refresh", function()
    local auth_calls = 0
    local request_calls = 0

    client.db = { deleteBearerToken = function() end }

    client.getOrRefreshBearerToken = function(_, _, _, force_refresh)
      auth_calls = auth_calls + 1
      if force_refresh then
        return true, "token-2"
      end
      return true, "token-1"
    end

    client.request = function(_, _, _, _, headers)
      request_calls = request_calls + 1
      if request_calls == 1 then
        return false, 401, "Unauthorized"
      end
      assert.are.equal("Bearer token-2", headers["Authorization"])
      return true, 200, {}
    end

    local ok, err = client:updateBookStatus(7, "UNREAD", "user", "pass")
    assert.is_true(ok)
    assert.is_nil(err)
    assert.are.equal(2, request_calls)
    assert.are.equal(2, auth_calls)
  end)

  it("resolves shelf source by explicit shelf id", function()
    client.getOrRefreshBearerToken = function()
      return true, "token-1"
    end

    client.request = function(_, method, path)
      assert.are.equal("GET", method)
      assert.are.equal("/api/v1/shelves", path)
      return true, 200, {
        { id = 7, name = "Private Shelf", publicShelf = false },
        { id = 9, name = "Public Shelf", publicShelf = true },
      }
    end

    local ok, source = client:resolveShelfSource(7, "Ignored", "user", "pass")
    assert.is_true(ok)
    assert.are.equal(7, source.id)
    assert.are.equal("Private Shelf", source.name)
    assert.is_true(source.is_private)
    assert.are.equal("id", source.source)
  end)

  it("fails shelf source resolution when explicit shelf id is inaccessible", function()
    client.getOrRefreshBearerToken = function()
      return true, "token-1"
    end

    client.request = function(_, method, path)
      assert.are.equal("GET", method)
      assert.are.equal("/api/v1/shelves", path)
      return true, 200, {
        { id = 9, name = "Public Shelf", publicShelf = true },
      }
    end

    local ok, err = client:resolveShelfSource(7, "Ignored", "user", "pass")
    assert.is_false(ok)
    assert.are.equal(404, err.code)
    assert.is_true(err.message:find("not accessible", 1, true) ~= nil)
  end)

  it("falls back to shelf name and creates the shelf when missing", function()
    local calls = 0
    client.getOrRefreshBearerToken = function()
      return true, "token-1"
    end

    client.request = function(_, method, path)
      calls = calls + 1
      if calls == 1 then
        assert.are.equal("GET", method)
        assert.are.equal("/api/v1/shelves", path)
        return true, 200, {}
      end
      assert.are.equal("POST", method)
      assert.are.equal("/api/v1/shelves", path)
      return true, 201, { id = 33, name = "KOReader" }
    end

    local ok, source = client:resolveShelfSource(nil, "KOReader", "user", "pass")
    assert.is_true(ok)
    assert.are.equal(33, source.id)
    assert.are.equal("KOReader", source.name)
    assert.are.equal("created", source.source)
  end)

  it("lists magic shelves", function()
    client.getOrRefreshBearerToken = function()
      return true, "token-1"
    end

    client.request = function(_, method, path)
      assert.are.equal("GET", method)
      assert.are.equal("/api/magic-shelves", path)
      return true, 200, {
        { id = 5, name = "Magic One" },
        { id = 6, name = "Magic Two" },
      }
    end

    local ok, shelves = client:getMagicShelves("user", "pass")
    assert.is_true(ok)
    assert.are.equal(2, #shelves)
    assert.are.equal(5, shelves[1].id)
  end)

  it("returns unsupported-version guidance when magic shelves endpoint is unavailable", function()
    client.getOrRefreshBearerToken = function()
      return true, "token-1"
    end

    client.request = function(_, method, path)
      assert.are.equal("GET", method)
      assert.are.equal("/api/magic-shelves", path)
      return false, 404, "Not Found"
    end

    local ok, err = client:getMagicShelves("user", "pass")
    assert.is_false(ok)
    assert.are.equal(404, err.code)
    assert.is_true(err.message:find("unsupported", 1, true) ~= nil)
  end)

  it("gets books in magic shelf and normalizes fields", function()
    local calls = 0
    client.getOrRefreshBearerToken = function()
      return true, "token-1"
    end

    client.request = function(_, method, path)
      calls = calls + 1
      assert.are.equal("GET", method)
      assert.are.equal("/api/v1/app/shelves/magic/8/books?page=0&size=100", path)
      return true, 200, {
        content = {
          {
            id = 77,
            authors = { "Magic Author" },
            primaryFileType = "EPUB",
          },
        },
        hasNext = false,
      }
    end

    local ok, books = client:getBooksInMagicShelf(8, "user", "pass")
    assert.is_true(ok)
    assert.are.equal(1, #books)
    assert.are.equal("Magic Author", books[1].author)
    assert.are.equal("epub", books[1].extension)
    assert.are.equal(1, calls)
  end)

  it("paginates magic shelf books when hasNext is true", function()
    client.getOrRefreshBearerToken = function()
      return true, "token-1"
    end

    local calls = 0
    client.request = function(_, method, path)
      calls = calls + 1
      assert.are.equal("GET", method)
      if calls == 1 then
        assert.are.equal("/api/v1/app/shelves/magic/8/books?page=0&size=100", path)
        return true, 200, {
          content = {
            { id = 1, title = "Page 1", authors = { "A" }, primaryFileType = "EPUB" },
          },
          hasNext = true,
        }
      end
      assert.are.equal("/api/v1/app/shelves/magic/8/books?page=1&size=100", path)
      return true, 200, {
        content = {
          { id = 2, title = "Page 2", authors = { "B" }, primaryFileType = "PDF" },
        },
        hasNext = false,
      }
    end

    local ok, books = client:getBooksInMagicShelf(8, "user", "pass")
    assert.is_true(ok)
    assert.are.equal(2, #books)
    assert.are.equal("epub", books[1].extension)
    assert.are.equal("pdf", books[2].extension)
  end)

  it("gets magic shelf book count from totalElements", function()
    client.getOrRefreshBearerToken = function()
      return true, "token-1"
    end

    client.request = function(_, method, path)
      assert.are.equal("GET", method)
      assert.are.equal("/api/v1/app/shelves/magic/8/books?page=0&size=1", path)
      return true, 200, {
        totalElements = 42,
        content = {
          { id = 100 },
        },
      }
    end

    local ok, count = client:getMagicShelfBookCount(8, "user", "pass")
    assert.is_true(ok)
    assert.are.equal(42, count)
  end)

  it("falls back to content length when totalElements is missing", function()
    client.getOrRefreshBearerToken = function()
      return true, "token-1"
    end

    client.request = function(_, method, path)
      assert.are.equal("GET", method)
      assert.are.equal("/api/v1/app/shelves/magic/8/books?page=0&size=1", path)
      return true, 200, {
        content = {
          { id = 100 },
        },
      }
    end

    local ok, count = client:getMagicShelfBookCount(8, "user", "pass")
    assert.is_true(ok)
    assert.are.equal(1, count)
  end)

  it("resolves magic shelf source by name", function()
    client.getOrRefreshBearerToken = function()
      return true, "token-1"
    end

    client.request = function(_, method, path)
      assert.are.equal("GET", method)
      assert.are.equal("/api/magic-shelves", path)
      return true, 200, {
        { id = 8, name = "Unread Books" },
        { id = 9, name = "Currently Reading" },
      }
    end

    local ok, source = client:resolveMagicShelfSource(nil, "currently reading", "user", "pass")
    assert.is_true(ok)
    assert.are.equal(9, source.id)
    assert.are.equal("Currently Reading", source.name)
    assert.are.equal("name", source.source)
  end)

  it("resolves magic shelf source by explicit id", function()
    client.getOrRefreshBearerToken = function()
      return true, "token-1"
    end

    client.request = function(_, method, path)
      assert.are.equal("GET", method)
      assert.are.equal("/api/magic-shelves", path)
      return true, 200, {
        { id = 8, name = "Unread Books" },
      }
    end

    local ok, source = client:resolveMagicShelfSource(8, "ignored", "user", "pass")
    assert.is_true(ok)
    assert.are.equal(8, source.id)
    assert.are.equal("Unread Books", source.name)
    assert.are.equal("id", source.source)
  end)
end)
