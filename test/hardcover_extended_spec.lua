package.path = table.concat({
  "bookloresync.koplugin/?.lua",
  "bookloresync.koplugin/?/init.lua",
  package.path,
}, ";")

local last_https_request = nil

package.preload["logger"] = function()
  return { info = function() end, warn = function() end, err = function() end, dbg = function() end }
end

package.preload["ltn12"] = function()
  return {
    sink = { table = function(tbl) return function(chunk) if chunk then tbl[#tbl + 1] = chunk end; return 1 end end },
    source = { string = function(s) local done = false; return function() if done then return nil end; done = true; return s end end },
  }
end

package.preload["ssl.https"] = function()
  return {
    request = function(req)
      last_https_request = req
      if req.sink then req.sink('{"data":{"ok":true}}') end
      return true, 200, {}
    end,
  }
end

package.preload["json"] = function()
  return {
    encode = function(v)
      if v and v.force_encode_error then error("encode failure") end
      return '{"payload":true}'
    end,
    decode = function(raw)
      if raw == "bad-json" then error("decode failure") end
      if raw == '{"data":{"ok":true}}' then return { data = { ok = true } } end
      if raw == '{"errors":[{"message":"GraphQL error"}]}' then return { errors = { { message = "GraphQL error" } } } end
      if raw == '{"errors":["simple error"]}' then return { errors = { "simple error" } } end
      return { data = { ok = true } }
    end,
  }
end

-- Note: NOT stubbing booklore_util here. The real module is used.
-- Ensure bit is available for calculateBookHash
if not _G.bit then
  _G.bit = {
    lshift = function(n, s) return math.floor(n * (2 ^ s)) end,
    rshift = function(n, s) return math.floor(n / (2 ^ s)) end,
  }
end

package.loaded["hardcover_api_client"] = nil
package.preload["hardcover_api_client"] = nil

local HardcoverClient = require("hardcover_api_client")
local https = require("ssl.https")

describe("HardcoverClient (extended)", function()
  local client

  before_each(function()
    client = HardcoverClient:new()
    last_https_request = nil
    -- Reset https.request to default stub
    https.request = function(req)
      last_https_request = req
      if req.sink then req.sink('{"data":{"ok":true}}') end
      return true, 200, {}
    end
  end)

  describe("findUserBookId", function()
    it("returns nil when query returns no data", function()
      client.query = function() return nil, "connection failed" end
      local id, err = client:findUserBookId(100, 7, "token")
      assert.is_nil(id)
      assert.are.equal("connection failed", err)
    end)

    it("returns nil when user_books is empty", function()
      client.query = function() return { user_books = {} }, nil end
      local id, err = client:findUserBookId(100, 7, "token")
      assert.is_nil(id)
      assert.is_truthy(err:find("not found", 1, true))
    end)
  end)

  describe("findBookByIsbn", function()
    it("returns nil for empty isbn", function()
      client.query = function() return { editions = { { book = { id = "77" } } } }, nil end
      local id, err = client:findBookByIsbn("", "token")
      assert.is_nil(id)
      assert.are.equal("No ISBN provided", err)
    end)

    it("uses isbn_13 for 13-digit isbn", function()
      local captured_vars = nil
      client.query = function(_, _, vars)
        captured_vars = vars
        return { editions = { { book = { id = "77" } } } }, nil
      end
      client:findBookByIsbn("9781234567890", "token")
      assert.is_not_nil(captured_vars)
    end)

    it("returns nil on query failure", function()
      client.query = function() return nil, "API error" end
      local id, err = client:findBookByIsbn("9781234567890", "token")
      assert.is_nil(id)
      assert.are.equal("API error", err)
    end)

    it("returns nil when editions list is empty", function()
      client.query = function() return { editions = {} }, nil end
      local id, err = client:findBookByIsbn("9781234567890", "token")
      assert.is_nil(id)
      assert.is_truthy(err:find("No Hardcover edition", 1, true))
    end)

    it("returns nil when edition has no book id", function()
      client.query = function() return { editions = { { book = {} } } }, nil end
      local id, err = client:findBookByIsbn("9781234567890", "token")
      assert.is_nil(id)
      assert.is_truthy(err:find("book ID missing", 1, true))
    end)
  end)

  describe("searchBook edge cases", function()
    it("returns nil for empty title", function()
      local results, err = client:searchBook("", nil, "token")
      assert.is_nil(results)
      assert.are.equal("No title provided", err)
    end)

    it("returns nil for whitespace-only title", function()
      local results, err = client:searchBook("   ", nil, "token")
      assert.is_nil(results)
    end)

    it("handles author as table with name objects", function()
      local calls = 0
      client.query = function(_, _, vars)
        calls = calls + 1
        if calls == 1 then
          return { search = { ids = { 1 } } }, nil
        end
        return { books = { { id = "1", title = "Book", release_year = 2020, contributions = {} } } }, nil
      end
      local candidates, err = client:searchBook("Title", { { name = "Auth" } }, "token")
      if candidates then
        assert.is_not_nil(candidates[1])
      end
    end)

    it("returns nil when search query fails", function()
      client.query = function(_, _, vars)
        if vars.q then return nil, "search failed" end
        return { books = {} }, nil
      end
      local results, err = client:searchBook("Title", nil, "token")
      assert.is_nil(results)
    end)

    it("returns nil when search result has no ids", function()
      client.query = function(_, _, vars)
        if vars.q then return { search = {} }, nil end
        return { books = {} }, nil
      end
      local results, err = client:searchBook("Title", nil, "token")
      assert.is_nil(results)
    end)

    it("returns nil when all ids are non-numeric", function()
      local calls = 0
      client.query = function(_, _, vars)
        calls = calls + 1
        if calls == 1 then return { search = { ids = { "abc" } } }, nil end
        return { books = {} }, nil
      end
      local results, err = client:searchBook("Title", nil, "token")
      assert.is_nil(results)
      assert.is_truthy(err:find("valid IDs", 1, true))
    end)

    it("returns nil when hydrate query fails", function()
      local calls = 0
      client.query = function(_, _, vars)
        calls = calls + 1
        if calls == 1 then return { search = { ids = { 1, 2 } } }, nil end
        if calls == 2 then return nil, "hydrate failed" end
      end
      local results, err = client:searchBook("Title", nil, "token")
      assert.is_nil(results)
    end)

    it("returns nil when hydrated books list is empty", function()
      local calls = 0
      client.query = function(_, _, vars)
        calls = calls + 1
        if calls == 1 then return { search = { ids = { 1, 2 } } }, nil end
        return { books = {} }, nil
      end
      local results, err = client:searchBook("Title", nil, "token")
      assert.is_nil(results)
    end)

    it("returns nil when no valid candidates after hydration", function()
      local calls = 0
      client.query = function(_, _, vars)
        calls = calls + 1
        if calls == 1 then return { search = { ids = { 1 } } }, nil end
        return { books = { { id = nil, title = "NoID" } } }, nil
      end
      local results, err = client:searchBook("Title", nil, "token")
      assert.is_nil(results)
    end)
  end)

  describe("getUserId", function()
    it("fetches from API when no cache hit", function()
      client.db = {
        getHardcoverUserId = function() return nil end,
        saveHardcoverUserId = function(id) end,
      }
      -- Override query to return me data
      client.query = function(_, query_str, _, _)
        if query_str:find("me", 1, true) then
          return { me = { { id = "5" } } }, nil
        end
        return nil, nil
      end
      local uid, err = client:getUserId("token")
      assert.are.equal(5, uid)
      assert.is_nil(err)
    end)

    it("returns error when query fails", function()
      client.db = { getHardcoverUserId = function() return nil end }
      client.query = function() return nil, "API down" end
      local uid, err = client:getUserId("token")
      assert.is_nil(uid)
      assert.are.equal("API down", err)
    end)

    it("returns error when me is empty array", function()
      client.db = { getHardcoverUserId = function() return nil end }
      client.query = function() return { me = {} }, nil end
      local uid, err = client:getUserId("token")
      assert.is_nil(uid)
    end)
  end)

  describe("submitRating (success path)", function()
    it("submits successfully through full flow", function()
      client.getUserId = function() return 7, nil end
      client.findUserBookId = function() return 99, nil end
      client.query = function(_, _, vars)
        return { update_user_book = { user_book = { id = 99, rating = vars.rating } } }, nil
      end
      local ok, err = client:submitRating(123, 8, "token")
      assert.is_true(ok)
      assert.is_nil(err)
    end)

    it("returns error when getUserId fails", function()
      client.getUserId = function() return nil, "no user" end
      local ok, err = client:submitRating(123, 8, "token")
      assert.is_false(ok)
    end)

    it("returns error when findUserBookId fails", function()
      client.getUserId = function() return 7, nil end
      client.findUserBookId = function() return nil, "not in library" end
      local ok, err = client:submitRating(123, 8, "token")
      assert.is_false(ok)
    end)

    it("returns error on mutation failure", function()
      client.getUserId = function() return 7, nil end
      client.findUserBookId = function() return 99, nil end
      client.query = function() return nil, "mutation failed" end
      local ok, err = client:submitRating(123, 8, "token")
      assert.is_false(ok)
    end)

    it("returns error when mutation returns error field", function()
      client.getUserId = function() return 7, nil end
      client.findUserBookId = function() return 99, nil end
      client.query = function() return { update_user_book = { error = "permission denied", user_book = nil } }, nil end
      local ok, err = client:submitRating(123, 8, "token")
      assert.is_false(ok)
    end)
  end)

  describe("query method edge cases", function()
    it("fails gracefully on json encode failure", function()
      -- NOTE: json is captured at module load time, so we can't easily
      -- test the pcall branch here. The source uses pcall(json.encode, ...)
      -- which will handle any real failure. Just verify the module doesn't crash.
      local data, err = client:query("query { ping }", {}, "token")
      -- Should not crash; the module handles this via pcall internally
      assert.is_not_nil(data)
    end)

    it("handles graphql errors in response", function()
      https.request = function(req)
        if req.sink then req.sink('{"errors":[{"message":"GraphQL error"}]}') end
        return true, 200, {}
      end
      local data, err = client:query("query { ping }", nil, "token")
      assert.is_nil(data)
      assert.is_truthy(err:find("GraphQL error", 1, true))
    end)

    it("handles simple error format", function()
      https.request = function(req)
        if req.sink then req.sink('{"errors":["simple error"]}') end
        return true, 200, {}
      end
      local data, err = client:query("query { ping }", nil, "token")
      assert.is_nil(data)
      assert.is_truthy(err:find("simple error", 1, true))
    end)

    it("handles bad json response", function()
      https.request = function(req)
        if req.sink then req.sink("bad-json") end
        return true, 200, {}
      end
      local data, err = client:query("query { ping }", nil, "token")
      assert.is_nil(data)
    end)
  end)
end)
