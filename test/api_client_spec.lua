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
end)
