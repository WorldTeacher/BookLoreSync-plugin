--[[--
Hardcover API Client Module

Handles all communication with the Hardcover GraphQL API including
authentication, book search, and rating submission.

@module koplugin.BookloreSync.hardcover_api_client
--]]--

local logger = require("logger")
local https  = require("ssl.https")
local ltn12  = require("ltn12")
local json   = require("json")

local HARDCOVER_API_URL = "https://api.hardcover.app/v1/graphql"

local HardcoverClient = {
    db = nil,  -- Database reference for user_id caching
}
HardcoverClient.__index = HardcoverClient

function HardcoverClient:new(o)
    o = o or {}
    setmetatable(o, self)
    return o
end

-- Minimal log helpers so callers don't need to pass a logger in.
function HardcoverClient:logInfo(...)
    logger.info(...)
end

function HardcoverClient:logWarn(...)
    logger.warn(...)
end

--[[--
Execute a GraphQL query or mutation against the Hardcover API.

All Hardcover API calls go through this function.

@param query      string  GraphQL query or mutation string
@param variables  table   Variables table (may be nil)
@param token      string  Hardcover JWT bearer token
@return table|nil  Parsed `data` table on success, nil on failure
@return string|nil Error message on failure
--]]
function HardcoverClient:query(query, variables, token)
    if not token or token == "" then
        return nil, "Hardcover token not configured"
    end

    local body_ok, body = pcall(json.encode, { query = query, variables = variables })
    if not body_ok then
        return nil, "Failed to encode GraphQL request: " .. tostring(body)
    end

    local req_headers = {
        ["Content-Type"]  = "application/json",
        ["Authorization"] = "Bearer " .. token,
        ["User-Agent"]    = "bookloresync.koplugin",
    }

    local response_body = {}
    local sink = ltn12.sink.table(response_body)

    https.TIMEOUT = 15
    local _, code, _ = https.request({
        url     = HARDCOVER_API_URL,
        method  = "POST",
        headers = req_headers,
        source  = ltn12.source.string(body),
        sink    = sink,
    })

    local response_text = table.concat(response_body)

    if type(code) ~= "number" then
        local msg = "Hardcover API connection error: " .. tostring(code or "unknown")
        self:logWarn("HardcoverClient:", msg)
        return nil, msg
    end

    if code < 200 or code >= 300 then
        self:logWarn("HardcoverClient: HTTP", code, "—", response_text)
        return nil, "Hardcover HTTP " .. tostring(code)
    end

    local ok, parsed = pcall(json.decode, response_text)
    if not ok or type(parsed) ~= "table" then
        self:logWarn("HardcoverClient: Failed to parse response:", response_text)
        return nil, "Failed to parse Hardcover response"
    end

    if parsed.errors then
        local first = parsed.errors[1]
        local msg = (type(first) == "table" and first.message) or tostring(first)
        self:logWarn("HardcoverClient: GraphQL error:", msg)
        return nil, msg
    end

    return parsed.data, nil
end

--[[--
Fetch the authenticated user's Hardcover user ID via the `me {}` query.

The result is persisted to the local SQLite database so subsequent calls
return immediately without a network round-trip.

@param token string  Hardcover JWT bearer token
@return number|nil  Integer user ID on success, nil on failure
@return string|nil  Error message on failure
--]]
function HardcoverClient:getUserId(token)
    if self.db then
        local cached = self.db:getHardcoverUserId()
        if cached then
            return cached, nil
        end
    end

    self:logInfo("HardcoverClient: Fetching user ID via me{} query")
    local data, err = self:query("{ me { id } }", nil, token)
    if not data then
        return nil, err
    end

    local me = data.me
    if not me or #me == 0 then
        return nil, "Hardcover me{} returned no user"
    end

    local user_id = tonumber(me[1].id)
    if not user_id then
        return nil, "Hardcover me{} returned non-numeric id"
    end

    self:logInfo("HardcoverClient: User ID:", user_id)
    if self.db then
        self.db:saveHardcoverUserId(user_id)
    end
    return user_id, nil
end

--[[--
Look up a Hardcover book ID by ISBN (ISBN-13 preferred, then ISBN-10).

Queries the `editions` table for an exact ISBN match and returns the
parent book's integer ID.

@param isbn   string  ISBN-13 or ISBN-10 (digits only, no hyphens)
@param token  string  Hardcover JWT bearer token
@return number|nil  Hardcover book_id on success, nil on failure
@return string|nil  Error message on failure
--]]
function HardcoverClient:findBookByIsbn(isbn, token)
    if not isbn or isbn == "" then
        return nil, "No ISBN provided"
    end

    isbn = isbn:gsub("[-% ]", "")
    local isbn_field = (#isbn == 13) and "isbn_13" or "isbn_10"

    self:logInfo("HardcoverClient: ISBN lookup —", isbn_field, "=", isbn)

    local query = [[
        query($isbn: String!) {
          editions(where: { ]] .. isbn_field .. [[: { _eq: $isbn } }, limit: 1) {
            book { id }
          }
        }
    ]]

    local data, err = self:query(query, { isbn = isbn }, token)
    if not data then
        return nil, err
    end

    local editions = data.editions
    if not editions or #editions == 0 then
        return nil, "No Hardcover edition found for ISBN " .. isbn
    end

    local book_id = tonumber(editions[1].book and editions[1].book.id)
    if not book_id then
        return nil, "Hardcover edition found but book ID missing"
    end

    self:logInfo("HardcoverClient: ISBN", isbn, "→ book_id", book_id)
    return book_id, nil
end

--[[--
Search Hardcover for a book by title (and optional author) and return up to 10
candidate results for the user to pick from.

Each result table contains:
  id     number  Hardcover book_id
  title  string  Book title
  author string  First contributing author name (may be "")
  year   string  Release year as string (may be "")

@param title   string  Book title
@param author  string  Author name (may be nil or table of {name=...} objects)
@param token   string  Hardcover JWT bearer token
@return table|nil   Array of candidate tables on success
@return string|nil  Error message on failure
--]]
function HardcoverClient:searchBook(title, author, token)
    if not title or title:match("^%s*$") then
        return nil, "No title provided"
    end

    -- Strip subtitle (everything after ': ')
    title = title:gsub(":%s*.+$", ""):gsub("^%s+", ""):gsub("%s+$", "")

    local search_str = title
    if author and type(author) == "table" then
        local first = author[1]
        author = (type(first) == "table" and first.name) or (type(first) == "string" and first) or nil
    end
    if author and author ~= "" then
        -- Normalise "Last, First" → "First Last" and strip remaining commas
        -- to avoid confusing the Hardcover search parser.
        author = author:gsub("^([^,]+),(%s*.+)$", function(last, rest)
            return rest:gsub("^%s+", "") .. " " .. last
        end)
        author = author:gsub(",", "")
        search_str = search_str .. " " .. author
    end

    self:logInfo("HardcoverClient: Title search —", search_str)

    local search_query = [[
        query($q: String!, $page: Int!) {
          search(query: $q, per_page: 10, page: $page, query_type: "Book") {
            ids
          }
        }
    ]]

    local data, err = self:query(search_query, { q = search_str, page = 1 }, token)
    if not data then
        return nil, err
    end

    local ids_raw = data.search and data.search.ids
    -- Guard: ids_raw must be an iterable table (some JSON decoders expose
    -- metatable methods as keys, so a plain truthiness check is insufficient)
    if type(ids_raw) ~= "table" then
        return nil, "No Hardcover search results for: " .. search_str
    end

    -- Take up to 10 IDs
    local ids = {}
    for _, id in ipairs(ids_raw) do
        local n = tonumber(id)
        if n then
            table.insert(ids, n)
            if #ids >= 10 then break end
        end
    end
    if #ids == 0 then
        return nil, "Hardcover search returned no valid IDs"
    end

    -- Hydrate: fetch title, author, year for each candidate
    local hydrate_query = [[
        query($ids: [Int!]) {
          books(where: { id: { _in: $ids } }, limit: 10) {
            id
            title
            release_year
            contributions(limit: 1) {
              author { name }
            }
          }
        }
    ]]
    local hdata, herr = self:query(hydrate_query, { ids = ids }, token)
    if not hdata then
        return nil, herr
    end

    local books = hdata.books
    if not books or #books == 0 then
        return nil, "Hardcover book hydration returned no results"
    end

    local candidates = {}
    for _, b in ipairs(books) do
        local book_id = tonumber(b.id)
        if book_id then
            local author_name = ""
            if b.contributions and b.contributions[1] and b.contributions[1].author then
                author_name = b.contributions[1].author.name or ""
            end
            local raw_year = rawget(b, "release_year")
            local year = (type(raw_year) == "number" or type(raw_year) == "string") and tostring(raw_year) or ""
            table.insert(candidates, {
                id     = book_id,
                title  = b.title or "",
                author = author_name,
                year   = year,
            })
            self:logInfo("HardcoverClient: Candidate —", book_id, b.title, author_name, year)
        end
    end

    if #candidates == 0 then
        return nil, "Hardcover hydration returned no valid candidates"
    end

    return candidates, nil
end

--[[--
Find the user's personal `user_book` record ID for a given Hardcover book.

This is the `user_books.id` field (not `book_id`) required by the
`update_user_book` rating mutation.  Returns nil when the book is not in
the user's Hardcover library.

@param hardcover_book_id  number  Hardcover book ID
@param user_id            number  Hardcover user ID
@param token              string  Hardcover JWT bearer token
@return number|nil  user_book.id on success, nil if not found or on error
@return string|nil  Error message on failure
--]]
function HardcoverClient:findUserBookId(hardcover_book_id, user_id, token)
    local query = [[
        query($bookId: Int!, $userId: Int!) {
          user_books(where: {
            book_id: { _eq: $bookId },
            user_id: { _eq: $userId }
          }, limit: 1) {
            id
          }
        }
    ]]

    local data, err = self:query(query,
        { bookId = hardcover_book_id, userId = user_id }, token)
    if not data then
        return nil, err
    end

    local ub = data.user_books
    if not ub or #ub == 0 then
        return nil, "Book not found in user's Hardcover library"
    end

    return tonumber(ub[1].id), nil
end

--[[--
Submit a rating to Hardcover for a book.

Flow:
  1. Resolve user_id via me{} (cached in SQLite after first call).
  2. Find the user_book.id for this book in the user's library.
  3. Send the update_user_book rating mutation.

Rating conversion: Booklore uses 1-10; Hardcover uses 0-5 (half-star
increments).  The conversion is hardcover_rating = booklore_rating / 2.

@param hardcover_id  number  Hardcover book ID (from book_cache.hardcover_id)
@param rating        number  Rating on Booklore's 1-10 scale
@param token         string  Hardcover JWT bearer token
@return boolean success
@return string|nil  Error message on failure
--]]
function HardcoverClient:submitRating(hardcover_id, rating, token)
    hardcover_id = tonumber(hardcover_id)
    rating       = tonumber(rating)

    if not hardcover_id then
        return false, "Invalid hardcover_id"
    end
    if not rating or rating < 1 or rating > 10 then
        return false, "Rating must be between 1 and 10"
    end
    if not token or token == "" then
        return false, "Hardcover token not configured"
    end

    -- Convert 1-10 → 0.5-5.0
    local hc_rating = rating / 2

    self:logInfo("HardcoverClient: submitRating — hardcover_id:", hardcover_id,
        "booklore_rating:", rating, "hc_rating:", hc_rating)

    -- Step 1: get user ID (cached after first call)
    local user_id, uid_err = self:getUserId(token)
    if not user_id then
        self:logWarn("HardcoverClient: Could not get user ID:", uid_err)
        return false, "Could not get Hardcover user ID: " .. tostring(uid_err)
    end

    -- Step 2: find user_book.id
    local user_book_id, ub_err = self:findUserBookId(hardcover_id, user_id, token)
    if not user_book_id then
        self:logWarn("HardcoverClient: No user_book record for hardcover_id",
            hardcover_id, "—", ub_err)
        return false, tostring(ub_err)
    end

    self:logInfo("HardcoverClient: Found user_book_id:", user_book_id,
        "for hardcover_id:", hardcover_id)

    -- Step 3: submit rating mutation
    local mutation = [[
        mutation($id: Int!, $rating: numeric) {
          update_user_book(id: $id, object: { rating: $rating }) {
            error
            user_book {
              id
              rating
            }
          }
        }
    ]]

    local data, merr = self:query(mutation,
        { id = user_book_id, rating = hc_rating }, token)
    if not data then
        self:logWarn("HardcoverClient: Rating mutation failed:", merr)
        return false, tostring(merr)
    end

    local result = data.update_user_book
    if result and result.error then
        self:logWarn("HardcoverClient: update_user_book error:", result.error)
        return false, tostring(result.error)
    end

    self:logInfo("HardcoverClient: Rating updated to", hc_rating,
        "for user_book_id", user_book_id)
    return true, nil
end

return HardcoverClient
