package.path = table.concat({
  "bookloresync.koplugin/?.lua",
  "bookloresync.koplugin/?/init.lua",
  package.path,
}, ";")

local last_https_request = nil

package.preload["logger"] = function()
  return {
    info = function() end,
    warn = function() end,
    err = function() end,
    dbg = function() end,
  }
end

package.preload["ltn12"] = function()
  return {
    sink = {
      table = function(tbl)
        return function(chunk)
          if chunk then
            tbl[#tbl + 1] = chunk
          end
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

package.preload["ssl.https"] = function()
  return {
    request = function(req)
      last_https_request = req
      if req.sink then
        req.sink('{"data":{"ok":true}}')
      end
      return true, 200, {}
    end,
  }
end

package.preload["json"] = function()
  return {
    encode = function(v)
      if v and v.force_encode_error then
        error("encode failure")
      end
      return '{"payload":true}'
    end,
    decode = function(raw)
      if raw == "bad-json" then
        error("decode failure")
      end
      return { data = { ok = true } }
    end,
  }
end

local HardcoverClient = require("hardcover_api_client")

describe("HardcoverClient", function()
  local client

  before_each(function()
    client = HardcoverClient:new()
    last_https_request = nil
  end)

  it("fails fast when token is missing", function()
    local data, err = client:query("query { me { id } }", nil, nil)
    assert.is_nil(data)
    assert.are.equal("Hardcover token not configured", err)
  end)

  it("builds graphql request and returns parsed data", function()
    local data, err = client:query("query { ping }", { a = 1 }, "jwt-token")
    assert.is_nil(err)
    assert.is_table(data)
    assert.is_truthy(last_https_request)
    assert.are.equal("POST", last_https_request.method)
    assert.are.equal("https://api.hardcover.app/v1/graphql", last_https_request.url)
    assert.are.equal("Bearer jwt-token", last_https_request.headers["Authorization"])
  end)

  it("returns connection errors", function()
    package.loaded["ssl.https"].request = function() return nil, "timeout", {} end
    local data, err = client:query("query { ping }", nil, "jwt")
    assert.is_nil(data)
    assert.is_truthy(err:find("connection error", 1, true))
  end)

  it("returns HTTP status errors", function()
    package.loaded["ssl.https"].request = function(req)
      if req.sink then req.sink("nope") end
      return true, 503, {}
    end
    local data, err = client:query("query { ping }", nil, "jwt")
    assert.is_nil(data)
    assert.are.equal("Hardcover HTTP 503", err)
  end)

  it("uses cached user id when available", function()
    client.db = {
      getHardcoverUserId = function() return 42 end,
      saveHardcoverUserId = function() end,
    }

    local uid, err = client:getUserId("token")
    assert.is_nil(err)
    assert.are.equal(42, uid)
  end)

  it("finds books by isbn", function()
    client.query = function(_, _, vars)
      assert.are.equal("9781234567890", vars.isbn)
      return { editions = { { book = { id = "77" } } } }, nil
    end

    local id, err = client:findBookByIsbn("978-1234567890", "token")
    assert.is_nil(err)
    assert.are.equal(77, id)
  end)

  it("searches and hydrates candidate books", function()
    local calls = 0
    client.query = function(_, _, vars)
      calls = calls + 1
      if calls == 1 then
        assert.are.equal("Title Author Name", vars.q)
        return { search = { ids = { 100, 101 } } }, nil
      end
      return {
        books = {
          {
            id = "100",
            title = "Title",
            release_year = 2024,
            contributions = { { author = { name = "Author" } } },
          },
        }
      }, nil
    end

    local candidates, err = client:searchBook("Title: Subtitle", "Name, Author", "token")
    assert.is_nil(err)
    assert.are.equal(1, #candidates)
    assert.are.equal(100, candidates[1].id)
    assert.are.equal("Title", candidates[1].title)
    assert.are.equal("Author", candidates[1].author)
    assert.are.equal("2024", candidates[1].year)
  end)

  it("validates submitRating arguments", function()
    local ok1, err1 = client:submitRating(nil, 8, "token")
    local ok2, err2 = client:submitRating(11, 0, "token")
    local ok3, err3 = client:submitRating(11, 8, "")

    assert.is_false(ok1)
    assert.are.equal("Invalid hardcover_id", err1)
    assert.is_false(ok2)
    assert.are.equal("Rating must be between 1 and 10", err2)
    assert.is_false(ok3)
    assert.are.equal("Hardcover token not configured", err3)
  end)

  it("submits rating via user book record", function()
    local observed_rating = nil
    client.getUserId = function() return 7, nil end
    client.findUserBookId = function() return 99, nil end
    client.query = function(_, _, vars)
      observed_rating = vars.rating
      return { update_user_book = { user_book = { id = 99, rating = vars.rating } } }, nil
    end

    local ok, err = client:submitRating(123, 9, "token")
    assert.is_true(ok)
    assert.is_nil(err)
    assert.are.equal(4.5, observed_rating)
  end)
end)
