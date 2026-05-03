--[[--
Booklore API Client Module

Handles all communication with the Booklore server including authentication,
error handling, and request/response processing.

@module koplugin.BookloreSync.api_client
--]]--

local logger = require("logger")
local socket = require("socket")
local http = require("socket.http")
local https = require("ssl.https")
local ltn12 = require("ltn12")
local json = require("json")
local md5 = require("ffi/sha2").md5

local APIClient = {
    server_url = nil,
    username = nil,
    password = nil,
    timeout = 10,
    db = nil,  -- Database reference for token caching
}

---APIClient:new.
function APIClient:new(plugin)
    local o = {
        plugin = plugin
    }
    setmetatable(o, self)
    self.__index = self
    return o
end

---APIClient:init.
function APIClient:init(server_url, username, password, db)
    self.server_url = server_url
    self.username = username
    self.password = password
    self.db = db  -- Store database reference for token caching
    
    if self.server_url and self.server_url:sub(-1) == "/" then
        self.server_url = self.server_url:sub(1, -2)
    end
    
    self:logInfo("BookloreSync API: Initialized with server:", self.server_url)
end

---APIClient:logInfo.
function APIClient:logInfo(...)
    if self.plugin then
        self.plugin:logInfo(...)
    else
        logger.info(...)
    end
end

---APIClient:logWarn.
function APIClient:logWarn(...)
    if self.plugin then
        self.plugin:logWarn(...)
        return
    end
    logger.warn(...)
end

---APIClient:logErr.
function APIClient:logErr(...)
    if self.plugin then
        self.plugin:logErr(...)
        return
    end
    logger.err(...)
end

---APIClient:logDbg.
function APIClient:logDbg(...)
    if self.plugin then
        self.plugin:logDbg(...)
    else
        logger.dbg(...)
    end
end

--[[--
Parse JSON response with error handling

@param response_text The raw response text
@return table|nil Parsed JSON object or nil
@return string|nil Error message if parsing failed
--]]
---APIClient:parseJSON.
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

--[[--
Extract error message from response

Tries to get error message from various possible formats:
- JSON with "message" field
- JSON with "error" field
- Plain text response
- HTTP status code

@param response_text The raw response text
@param code HTTP status code
@return string User-friendly error message
--]]
---APIClient:extractErrorMessage.
function APIClient:extractErrorMessage(response_text, code)
    local json_data, parse_err = self:parseJSON(response_text)
    
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

--[[--
Make HTTP request with improved error handling

@param method HTTP method (GET, POST, etc.)
@param path API endpoint path (without server URL)
@param body Request body (optional, for POST/PUT)
@param headers Additional headers (optional)
@return boolean success
@return number|nil HTTP status code
@return table|string|nil Response data or error message
--]]
---APIClient:request.
function APIClient:request(method, path, body, headers)
    if not self.server_url or self.server_url == "" then
        self:logErr("BookloreSync API: Server URL not configured")
        return false, nil, "Server URL not configured"
    end
    
    local url = self.server_url .. path
    self:logInfo("BookloreSync API:", method, url)
    
    local req_headers = headers or {}
    
    -- Add authentication if username/password provided and no custom Authorization header
    if self.username and self.password and not req_headers["Authorization"] then
        local password_hash = md5(self.password)
        req_headers["x-auth-user"] = self.username
        req_headers["x-auth-key"] = password_hash
    end
    
    local req_body = nil
    local source = nil
    
    if body then
        if type(body) == "table" then
            req_body = json.encode(body)
            req_headers["Content-Type"] = "application/json"
        else
            req_body = tostring(body)
        end
        
        req_headers["Content-Length"] = tostring(#req_body)
        source = ltn12.source.string(req_body)
        
        self:logDbg("BookloreSync API: Request body length:", #req_body)
    end
    
    local response_body = {}
    local sink = ltn12.sink.table(response_body)
    
    local http_client = http
    if url:match("^https://") then
        http_client = https
    end
    
    http_client.TIMEOUT = self.timeout
    
    local req_args = {
        url = url,
        method = method,
        headers = req_headers,
        sink = sink,
    }
    
    if source then
        req_args.source = source
    end
    
    local res, code, response_headers = http_client.request(req_args)
    
    local response_text = table.concat(response_body)
    
    self:logInfo("BookloreSync API: Response code:", tostring(code))
    self:logDbg("BookloreSync API: Response length:", #response_text)
    
    if not code then
        local error_msg = res or "Connection failed"
        self:logErr("BookloreSync API: Network error:", error_msg)
        return false, nil, "Network error: " .. error_msg
    end
    
    if type(code) ~= "number" then
        local error_msg = tostring(code)
        self:logErr("BookloreSync API: Non-numeric response code:", error_msg)
        return false, nil, "Connection error: " .. error_msg
    end
    
    if code >= 200 and code < 300 then
        if response_text and response_text ~= "" then
            local json_data, parse_err = self:parseJSON(response_text)
            if json_data then
                return true, code, json_data
            else
                return true, code, response_text
            end
        else
            return true, code, nil
        end
    end
    
    local error_message = self:extractErrorMessage(response_text, code)
    if response_text and response_text ~= "" then
        self:logWarn("BookloreSync API: Request failed:", code, "-", error_message, "| Raw response:", response_text)
    else
        self:logWarn("BookloreSync API: Request failed:", code, "-", error_message, "| Raw response: (empty)")
    end
    
    return false, code, error_message
end

--[[--
Test authentication with the server

@return boolean success
@return string message (success message or detailed error)
--]]
---APIClient:testAuth.
function APIClient:testAuth()
    self:logInfo("BookloreSync API: Testing authentication")
    
    if not self.username or self.username == "" then
        return false, "Username not configured"
    end
    
    if not self.password or self.password == "" then
        return false, "Password not configured"
    end
    
    local success, code, response = self:request("GET", "/api/koreader/users/auth")
    
    if success then
        self:logInfo("BookloreSync API: Authentication successful")
        return true, "Authentication successful"
    else
        local error_detail = response or "Unknown error"
        if code then
            error_detail = "HTTP " .. tostring(code) .. ": " .. error_detail
        end
        self:logErr("BookloreSync API: Authentication failed:", error_detail)
        return false, error_detail
    end
end

--[[--
Probe the by-hash endpoint to verify server compatibility.

Sends a GET request to /api/koreader/books/by-hash/<random_hash>.
A functioning server returns 404 (book not found), which confirms the
endpoint exists and is reachable.  Any non-404 HTTP failure (e.g. 401,
500) or a network/connection error is surfaced as an incompatibility.

@return boolean endpoint_ok   true if the endpoint is reachable
@return string  message       human-readable result or error detail
--]]
---APIClient:testByHashEndpoint.
function APIClient:testByHashEndpoint()
    -- Generate a pseudo-random 32-char hex hash that will never match a real book.
    -- We use os.time() mixed with a fixed salt so it varies per call without
    -- requiring an external random library.
    local salt = 0xDEADBEEF
    local t = os.time()
    local probe_hash = string.format("%08x%08x%08x%08x",
        t,
        (t * 6364136223846793005) % 0x100000000,
        salt,
        ((t + salt) * 1442695040888963407) % 0x100000000)

    self:logInfo("BookloreSync API: Probing by-hash endpoint with hash:", probe_hash)

    local _, code, _ = self:request("GET", "/api/koreader/books/by-hash/" .. probe_hash)

    if code == 404 then
        -- Expected: endpoint exists, book simply not found.
        self:logInfo("BookloreSync API: by-hash endpoint reachable (404 as expected)")
        return true, "by-hash endpoint OK"
    elseif code == 401 or code == 403 then
        local msg = "by-hash endpoint reachable but returned HTTP " .. tostring(code) .. " (auth error)"
        self:logWarn("BookloreSync API:", msg)
        -- The endpoint exists; auth issues are a separate problem.
        return true, msg
    elseif code then
        local msg = "by-hash endpoint returned unexpected HTTP " .. tostring(code)
        self:logWarn("BookloreSync API:", msg)
        return false, msg
    else
        local msg = "by-hash endpoint unreachable (connection failed)"
        self:logErr("BookloreSync API:", msg)
        return false, msg
    end
end

--[[--
Get book by hash

@param book_hash The MD5 hash of the book file
@return boolean success
@return table|string book_data or error_message
--]]
---APIClient:getBookByHash.
function APIClient:getBookByHash(book_hash)
    self:logInfo("BookloreSync API: Looking up book by hash:", book_hash)
    
    local success, code, response = self:request("GET", "/api/koreader/books/by-hash/" .. book_hash)
    
    if success and type(response) == "table" then
        self:logInfo("BookloreSync API: Found book, ID:", response.id)
        
        response = self:_normalizeBookObject(response)
        
        if response.isbn10 or response.isbn13 then
            self:logInfo("BookloreSync API: Book has ISBN-10:", response.isbn10, "ISBN-13:", response.isbn13)
        else
            self:logInfo("BookloreSync API: Book has no ISBN data")
        end
        
        return true, response
    else
        local error_msg = response or "Book not found"
        self:logWarn("BookloreSync API: Book lookup failed:", error_msg)
        return false, error_msg
    end
end

--[[--
Submit reading session

@param session_data Table containing session information
@return boolean success
@return string message (success or error message)
--]]
---APIClient:submitSession.
function APIClient:submitSession(session_data)
    self:logInfo("BookloreSync API: Submitting reading session for book:", session_data.bookId or session_data.bookHash)
    
    local success, code, response = self:request("POST", "/api/v1/reading-sessions", session_data)
    
    if success then
        self:logInfo("BookloreSync API: Session submitted successfully")
        return true, "Session synced successfully", code
    else
        local error_msg = response or "Failed to submit session"
        if code then
            error_msg = "HTTP " .. tostring(code) .. ": " .. error_msg
        end
        self:logWarn("BookloreSync API: Session submission failed:", error_msg)
        return false, error_msg, code
    end
end

--[[--
Fetch KOReader progress for a document hash.

Endpoint: GET /api/koreader/syncs/progress/:book_hash

@param book_hash string  Document hash used by KOReader sync protocol
@return boolean success
@return table|string|nil response table on success, error message otherwise
@return number|nil code HTTP status code
--]]
---APIClient:getKoReaderProgress.
function APIClient:getKoReaderProgress(book_hash)
    if not book_hash or book_hash == "" then
        return false, "Missing book_hash", nil
    end

    self:logInfo("BookloreSync API: Getting KOReader progress for hash:", book_hash)

    local success, code, response = self:request("GET", "/api/koreader/syncs/progress/" .. tostring(book_hash))

    if success then
        return true, response, code
    end

    if code == 404 then
        -- Not found is a valid state: no progress stored yet.
        return true, nil, code
    end

    local err = response or "Failed to fetch KOReader progress"
    if code then
        err = "HTTP " .. tostring(code) .. ": " .. tostring(err)
    end
    self:logWarn("BookloreSync API: getKoReaderProgress failed:", err)
    return false, err, code
end

--[[--
Update KOReader progress for a document hash.

Endpoint: PUT /api/koreader/syncs/progress

Payload fields:
  timestamp, document, percentage, progress, device, device_id

@param payload table  Progress payload
@return boolean success
@return string|table|nil response_message_or_body
@return number|nil code HTTP status code
--]]
---APIClient:updateKoReaderProgress.
function APIClient:updateKoReaderProgress(payload)
    if type(payload) ~= "table" then
        return false, "Invalid payload", nil
    end

    local required = {
        "timestamp", "document", "percentage", "progress", "device", "device_id",
    }
    for _, key in ipairs(required) do
        if payload[key] == nil or payload[key] == "" then
            return false, "Missing required progress field: " .. key, nil
        end
    end

    local timestamp = tonumber(payload.timestamp)
    if not timestamp then
        return false, "Invalid progress field: timestamp must be numeric", nil
    end

    local percentage = tonumber(payload.percentage)
    if not percentage then
        return false, "Invalid progress field: percentage must be numeric", nil
    end

    self:logInfo("BookloreSync API: Updating KOReader progress for hash:", tostring(payload.document))

    local body = {
        timestamp = timestamp,
        document = tostring(payload.document),
        percentage = percentage,
        progress = tostring(payload.progress),
        device = tostring(payload.device),
        device_id = tostring(payload.device_id),
    }

    local success, code, response = self:request("PUT", "/api/koreader/syncs/progress", body)

    if success then
        return true, response, code
    end

    local err = response or "Failed to update KOReader progress"
    if code then
        err = "HTTP " .. tostring(code) .. ": " .. tostring(err)
    end
    self:logWarn("BookloreSync API: updateKoReaderProgress failed:", err)
    return false, err, code
end

--[[--
Submit batch of reading sessions for a single book

Submits multiple sessions in a single request for improved performance.
Automatically falls back to individual uploads if batch endpoint is not available (404).

Uses KOReader x-auth-user/x-auth-key authentication, consistent with the
single-session endpoint.

@param book_id Booklore book ID (number)
@param book_type Book type (string): "EPUB", "PDF", etc.
@param sessions Array of session objects (table), max 100 sessions recommended
@return boolean success
@return string message (success or error message)
@return number|nil code HTTP status code
--]]
---APIClient:submitSessionBatch.
function APIClient:submitSessionBatch(book_id, book_type, sessions)
    -- Validation
    if not book_id or type(book_id) ~= "number" then
        self:logErr("BookloreSync API: Invalid book_id for batch upload:", book_id)
        return false, "Invalid book_id", nil
    end
    
    if not sessions or type(sessions) ~= "table" or #sessions == 0 then
        self:logErr("BookloreSync API: Invalid or empty sessions array for batch upload")
        return false, "Invalid or empty sessions array", nil
    end
    
    self:logInfo("BookloreSync API: Submitting batch of", #sessions, "sessions for book:", book_id)
    
    local payload = {
        bookId = book_id,
        bookType = book_type or "EPUB",
        sessions = sessions
    }
    
    -- Uses KOReader x-auth-user/x-auth-key auth (injected automatically by request())
    self:logInfo("BookloreSync API: Batch upload auth method: x-auth-user/x-auth-key")
    local success, code, response = self:request("POST", "/api/v1/reading-sessions/batch", payload)
    
    if success then
        self:logInfo("BookloreSync API: Batch submitted successfully -", #sessions, "sessions")
        return true, "Batch synced successfully", code
    else
        local error_msg = response or "Failed to submit batch"
        if code then
            error_msg = "HTTP " .. tostring(code) .. ": " .. error_msg
        end
        self:logWarn("BookloreSync API: Batch submission failed:", error_msg)
        return false, error_msg, code
    end
end

--[[--
Check server health/connectivity

@return boolean success
@return string message
--]]
---APIClient:checkHealth.
function APIClient:checkHealth()
    self:logInfo("BookloreSync API: Checking server health")
    
    local success, code, response = self:request("GET", "/api/v1/healthcheck")
    
    if success or (code and code >= 200 and code < 500) then
        -- Server is reachable (even if endpoint doesn't exist)
        self:logInfo("BookloreSync API: Server is reachable")
        return true, "Server is online"
    else
        local error_msg = response or "Server unreachable"
        self:logWarn("BookloreSync API: Health check failed:", error_msg)
        return false, error_msg
    end
end

--[[--
Search books by title (fuzzy match)

@param title Book title to search for
@return boolean success
@return table|string matches or error message
--]]
---APIClient:searchBooks.
function APIClient:searchBooks(title)
    self:logInfo("BookloreSync API: Searching books with title:", title)
    
    local encoded_title = self:_urlEncode(title)
    local endpoint = "/api/v1/books/search?title=" .. encoded_title
    
    local success, code, response = self:request("GET", endpoint)
    
    if success and type(response) == "table" then
        self:logInfo("BookloreSync API: Found", #response, "matches")
        return true, response
    else
        local error_msg = response or "No matches found"
        self:logWarn("BookloreSync API: Book search failed:", error_msg)
        return false, {}
    end
end

--[[--
Login to Booklore API and get Bearer token

@param username Booklore username
@param password Booklore password (plain text)
@return boolean success
@return string|nil token or error message
--]]
---APIClient:loginBooklore.
function APIClient:loginBooklore(username, password)
    self:logInfo("BookloreSync API: Logging in to Booklore with username:", username)
    
    local endpoint = "/api/v1/auth/login"
    local body = {
        username = username,
        password = password
    }
    
    -- Make request without auth headers (login doesn't need auth)
    local success, code, response = self:request("POST", endpoint, body)
    
    if success and type(response) == "table" and response.accessToken then
        self:logInfo("BookloreSync API: Successfully obtained Bearer token")
        return true, response.accessToken
    else
        local error_msg = response or "Login failed"
        
        -- Check for duplicate token error (server-side bug)
        if type(error_msg) == "string" and error_msg:find("Duplicate entry") and error_msg:find("uq_refresh_token") then
            self:logWarn("BookloreSync API: Duplicate refresh token error (server-side bug)")
            error_msg = "Server error: Duplicate refresh token. This is a server-side bug. Workaround: Try logging out and back in on the Booklore web interface, or restart the Booklore server to clear stale tokens."
        end
        
        self:logWarn("BookloreSync API: Booklore login failed:", error_msg)
        return false, error_msg
    end
end

--[[--
Get or refresh cached Bearer token

Attempts to use cached token first. If cached token doesn't exist or is expired,
or if force_refresh is true, logs in to get a new token.

Proactively refreshes tokens that will expire within 1 day to avoid mid-operation
token expiration.

@param username Booklore username
@param password Booklore password (plain text)
@param force_refresh If true, bypass cache and get new token
@return boolean success
@return string|nil token or error message
--]]
---APIClient:getOrRefreshBearerToken.
function APIClient:getOrRefreshBearerToken(username, password, force_refresh)
    force_refresh = force_refresh or false
    
    if not force_refresh and self.db then
        local cached_token, expires_at = self.db:getBearerToken(username)
        if cached_token then
            -- Proactively refresh to avoid mid-operation expiration
            if expires_at and (expires_at - os.time()) < 86400 then
                self:logInfo("BookloreSync API: Token expires soon, refreshing for:", username)
                force_refresh = true
            else
                self:logInfo("BookloreSync API: Using cached Bearer token for:", username)
                return true, cached_token
            end
        end
    end
    
    self:logInfo("BookloreSync API: Getting new Bearer token for:", username)
    local success, token = self:loginBooklore(username, password)
    
    if success and token then
        if self.db then
            self.db:saveBearerToken(username, token)
        end
        return true, token
    else
        return false, token  -- token contains error message
    end
end

--[[--
Validate Bearer token by making a test request

@param token Bearer token to validate
@return boolean valid (true if token works)
--]]
---APIClient:validateBearerToken.
function APIClient:validateBearerToken(token)
    local headers = {
        ["Authorization"] = "Bearer " .. token
    }
    
    local success, code, response = self:request("GET", "/api/v1/books/search?title=test&limit=1", nil, headers)
    
    -- Token is valid if request succeeds (200) or returns 404 (endpoint exists but no results)
    -- Token is invalid if we get 401/403 (unauthorized)
    if code == 401 or code == 403 then
        self:logWarn("BookloreSync API: Bearer token is invalid (401/403)")
        return false
    end
    
    return true
end

--[[--
Search books by title with custom authentication credentials

@param title Book title to search for
@param username Booklore username
@param password Booklore password
@return boolean success
@return table|string matches or error message
--]]
---APIClient:searchBooksWithAuth.
function APIClient:searchBooksWithAuth(title, username, password)
    self:logInfo("BookloreSync API: Searching books with Booklore auth, title:", title)
    
    local login_success, token = self:getOrRefreshBearerToken(username, password)
    
    if not login_success then
        self:logErr("BookloreSync API: Failed to get Bearer token:", token)
        return false, token or "Authentication failed"
    end
    
    local encoded_title = self:_urlEncode(title)
    local endpoint = "/api/v1/books/search?title=" .. encoded_title
    
    local headers = {
        ["Authorization"] = "Bearer " .. token
    }
    
    local success, code, response = self:request("GET", endpoint, nil, headers)
    
    -- If we get 401/403, token might be invalid - retry with fresh token
    if not success and (code == 401 or code == 403) then
        self:logWarn("BookloreSync API: Token rejected (401/403), refreshing and retrying")
        
        if self.db then
            self.db:deleteBearerToken(username)
        end
        
        local refresh_success, new_token = self:getOrRefreshBearerToken(username, password, true)
        if refresh_success then
            headers["Authorization"] = "Bearer " .. new_token
            success, code, response = self:request("GET", endpoint, nil, headers)
        else
            return false, new_token or "Authentication failed after refresh"
        end
    end
    
    if success and type(response) == "table" then
        self:logInfo("BookloreSync API: Found", #response, "matches")
        
        for i, book in ipairs(response) do
            response[i] = self:_normalizeBookObject(book)
        end
        
        return true, response
    else
        local error_msg = response or "No matches found"
        self:logWarn("BookloreSync API: Book search failed:", error_msg)
        return false, error_msg
    end
end

--[[--
Search books by ISBN with custom authentication credentials

@param isbn ISBN-10 or ISBN-13 to search for
@param username Booklore username
@param password Booklore password
@return boolean success
@return table|string matches or error message
--]]
---APIClient:searchBooksByIsbn.
function APIClient:searchBooksByIsbn(isbn, username, password)
    self:logInfo("BookloreSync API: Searching books by ISBN:", isbn)
    
    local login_success, token = self:getOrRefreshBearerToken(username, password)
    
    if not login_success then
        self:logErr("BookloreSync API: Failed to get Bearer token:", token)
        return false, token or "Authentication failed"
    end
    
    local encoded_isbn = self:_urlEncode(isbn)
    local endpoint = "/api/v1/books/search?isbn=" .. encoded_isbn
    
    local headers = {
        ["Authorization"] = "Bearer " .. token
    }
    
    local success, code, response = self:request("GET", endpoint, nil, headers)
    
    -- If we get 401/403, token might be invalid - retry with fresh token
    if not success and (code == 401 or code == 403) then
        self:logWarn("BookloreSync API: Token rejected (401/403), refreshing and retrying")
        
        if self.db then
            self.db:deleteBearerToken(username)
        end
        
        local refresh_success, new_token = self:getOrRefreshBearerToken(username, password, true)
        if refresh_success then
            headers["Authorization"] = "Bearer " .. new_token
            success, code, response = self:request("GET", endpoint, nil, headers)
        else
            return false, new_token or "Authentication failed after refresh"
        end
    end
    
    if success and type(response) == "table" then
        self:logInfo("BookloreSync API: Found", #response, "ISBN matches")
        
        for i, book in ipairs(response) do
            response[i] = self:_normalizeBookObject(book)
        end
        
        return true, response
    else
        local error_msg = response or "No ISBN matches found"
        self:logWarn("BookloreSync API: ISBN search failed:", error_msg)
        return false, error_msg
    end
end

--[[--
Get book by hash with Bearer token authentication

@param book_hash MD5 hash of the book
@param username Booklore username
@param password Booklore password
@return boolean success
@return table|string book data or error message
--]]
---APIClient:getBookByHashWithAuth.
function APIClient:getBookByHashWithAuth(book_hash, username, password)
    self:logInfo("BookloreSync API: Looking up book by hash with Booklore auth:", book_hash)
    
    local login_success, token = self:getOrRefreshBearerToken(username, password)
    
    if not login_success then
        self:logErr("BookloreSync API: Failed to get Bearer token:", token)
        return false, "Authentication failed"
    end
    
    local headers = {
        ["Authorization"] = "Bearer " .. token
    }
    
    local success, code, response = self:request("GET", "/api/v1/books/by-hash/" .. book_hash, nil, headers)
    
    -- If we get 401/403, token might be invalid - retry with fresh token
    if not success and (code == 401 or code == 403) then
        self:logWarn("BookloreSync API: Token rejected (401/403), refreshing and retrying")
        
        if self.db then
            self.db:deleteBearerToken(username)
        end
        
        local refresh_success, new_token = self:getOrRefreshBearerToken(username, password, true)
        if refresh_success then
            headers["Authorization"] = "Bearer " .. new_token
            success, code, response = self:request("GET", "/api/v1/books/by-hash/" .. book_hash, nil, headers)
        else
            return false, new_token or "Authentication failed after refresh"
        end
    end
    
    if success and type(response) == "table" then
        self:logInfo("BookloreSync API: Found book by hash, ID:", response.id)
        
        response = self:_normalizeBookObject(response)
        
        if response.isbn10 or response.isbn13 then
            self:logInfo("BookloreSync API: Book has ISBN-10:", response.isbn10, "ISBN-13:", response.isbn13)
        end
        
        return true, response
    else
        local error_msg = response or "Book not found"
        self:logWarn("BookloreSync API: Book by hash lookup failed:", error_msg)
        return false, error_msg
    end
end

--[[--
URL encode a string

@param str String to encode
@return string URL encoded string
--]]
---APIClient:_urlEncode.
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

--[[--
Normalize book object by promoting fields from nested metadata to top level

Booklore's /api/v1/ endpoints nest title, authors, and ISBNs under a
`metadata` sub-object, while the /api/koreader/ endpoints return them at
the top level. This function promotes the fields so all callers can access
them uniformly as book.title, book.authors, book.isbn10, book.isbn13.

@param book Book object from API
@return table Normalized book object with metadata fields at top level
--]]
---APIClient:_normalizeBookObject.
function APIClient:_normalizeBookObject(book)
    if not book or type(book) ~= "table" then
        return book
    end
    
    if book.metadata and type(book.metadata) == "table" then
        if not book.title or book.title == "" then
            book.title = book.metadata.title
        end
        if not book.authors or book.authors == "" then
            book.authors = book.metadata.authors
        end
        if not book.isbn10 then
            book.isbn10 = book.metadata.isbn10
        end
        if not book.isbn13 then
            book.isbn13 = book.metadata.isbn13
        end
        if not book.pagecount then
            book.pagecount = book.metadata.pagecount or book.metadata.pageCount
        end
    end

    if book.pagecount ~= nil then
        local normalized_pagecount = tonumber(book.pagecount)
        if normalized_pagecount and normalized_pagecount > 0 then
            book.pagecount = math.floor(normalized_pagecount + 0.5)
        else
            book.pagecount = nil
        end
    end

    -- Normalise hardcover_id: accept all known field names from the API.
    -- The /api/v1/books/<id> endpoint returns metadata.hardcoverBookId (capital B).
    -- Earlier endpoints used top-level hardcoverId or metadata.hardcoverId / hardcover_id.
    if not book.hardcover_id then
        if book.hardcoverId then
            book.hardcover_id = tonumber(book.hardcoverId)
        elseif book.metadata and book.metadata.hardcoverBookId then
            book.hardcover_id = tonumber(book.metadata.hardcoverBookId)
        elseif book.metadata and book.metadata.hardcoverId then
            book.hardcover_id = tonumber(book.metadata.hardcoverId)
        elseif book.metadata and book.metadata.hardcover_id then
            book.hardcover_id = tonumber(book.metadata.hardcover_id)
        end
    end
    
    return book
end

--[[--
Submit a personal rating for a single book to Booklore.

Uses Bearer token auth (same credentials as historical data import).

Endpoint: PUT /api/v1/books/personal-rating
Body: { "ids": [book_id], "rating": rating }

@param book_id number  The Booklore book ID
@param rating  number  Rating value (1-10)
@param username string Booklore username for Bearer token
@param password string Booklore password for Bearer token
@return boolean success
@return string|nil error message on failure
--]]
---APIClient:submitRating.
function APIClient:submitRating(book_id, rating, username, password)
    book_id = tonumber(book_id)
    rating  = tonumber(rating)

    if not book_id then
        return false, "Invalid book_id"
    end
    if not rating or rating < 1 or rating > 10 then
        return false, "Rating must be between 1 and 10"
    end
    if not username or username == "" then
        return false, "Booklore username required for rating sync"
    end
    if not password or password == "" then
        return false, "Booklore password required for rating sync"
    end

    self:logInfo("BookloreSync API: Submitting rating", rating, "for book_id", book_id)

    local token_ok, token = self:getOrRefreshBearerToken(username, password, false)
    if not token_ok then
        self:logErr("BookloreSync API: Could not obtain Bearer token for rating:", token)
        return false, token or "Failed to obtain auth token"
    end

    local body = json.encode({ ids = { book_id }, rating = rating })

    local headers = {
        ["Authorization"] = "Bearer " .. token,
        ["Content-Type"]  = "application/json",
    }

    local success, code, response = self:request("PUT", "/api/v1/books/personal-rating", body, headers)

    -- If token rejected, delete cache, get a fresh token and retry once
    if not success and (code == 401 or code == 403) then
        self:logWarn("BookloreSync API: Token rejected (" .. tostring(code) .. ") for rating, refreshing and retrying")
        if self.db then
            self.db:deleteBearerToken(username)
        end
        local refresh_ok, new_token = self:getOrRefreshBearerToken(username, password, true)
        if refresh_ok then
            headers["Authorization"] = "Bearer " .. new_token
            success, code, response = self:request("PUT", "/api/v1/books/personal-rating", body, headers)
        else
            return false, new_token or "Authentication failed after refresh"
        end
    end

    if success and (code == 200 or code == 204) then
        self:logInfo("BookloreSync API: Rating submitted successfully for book_id", book_id)
        return true, nil
    else
        local err_msg = (type(response) == "string" and response ~= "") and response or ("HTTP " .. tostring(code))
        self:logWarn("BookloreSync API: Failed to submit rating:", err_msg)
        return false, err_msg
    end
end

--[[--
Update reading status for one or more books.

Endpoint: POST /api/v1/books/status
Body: { "bookIds": [book_id, ...], "status": "UNREAD" }

@param book_ids table|number  One book ID or an array of book IDs
@param status string          Status value (must be uppercase)
@param username string        Booklore username for Bearer token
@param password string        Booklore password for Bearer token
@return boolean success
@return string|nil error message on failure
--]]
---APIClient:updateBookStatus.
function APIClient:updateBookStatus(book_ids, status, username, password)
    if type(book_ids) ~= "table" then
        book_ids = { book_ids }
    end

    local normalized_ids = {}
    for _, book_id in ipairs(book_ids) do
        local id = tonumber(book_id)
        if id then
            table.insert(normalized_ids, id)
        end
    end

    if #normalized_ids == 0 then
        return false, "At least one valid book ID is required"
    end

    status = tostring(status or ""):upper()
    if status == "" then
        return false, "Status is required"
    end

    if not username or username == "" then
        return false, "Booklore username required for status update"
    end
    if not password or password == "" then
        return false, "Booklore password required for status update"
    end

    local token_ok, token = self:getOrRefreshBearerToken(username, password, false)
    if not token_ok then
        return false, token or "Failed to obtain auth token"
    end

    local body_ids = normalized_ids
    if json.util and json.util.InitArray then
        body_ids = json.util.InitArray(normalized_ids)
    end

    local body = {
        bookIds = body_ids,
        status = status,
    }
    local headers = {
        ["Authorization"] = "Bearer " .. token,
        ["Content-Type"] = "application/json",
    }

    local success, code, response = self:request("POST", "/api/v1/books/status", body, headers)

    if not success and (code == 401 or code == 403) then
        if self.db then self.db:deleteBearerToken(username) end
        local ref_ok, new_token = self:getOrRefreshBearerToken(username, password, true)
        if ref_ok then
            headers["Authorization"] = "Bearer " .. new_token
            success, code, response = self:request("POST", "/api/v1/books/status", body, headers)
        else
            return false, new_token or "Authentication failed after refresh"
        end
    end

    if success then
        self:logInfo("BookloreSync API: Updated book status to", status, "for", #normalized_ids, "book(s)")
        return true, nil
    end

    local err_msg = (type(response) == "string" and response ~= "") and response or ("HTTP " .. tostring(code))
    self:logWarn("BookloreSync API: Failed to update book status:", err_msg)
    return false, err_msg
end

--[[--

Endpoint: POST /api/v1/annotations
Required body fields: bookId, cfi, text
Optional: color (hex), style, note, chapterTitle

@param book_id       number
@param cfi           string  epubcfi(pos0,pos1)
@param text          string  highlighted text
@param opts          table   { color, style, note, chapter_title }
@param username      string
@param password      string
@return boolean success
@return number|string  server annotation id on success, error message on failure
--]]
---APIClient:submitHighlight.
function APIClient:submitHighlight(book_id, cfi, text, opts, username, password)
    opts = opts or {}

    if not book_id or not cfi or not text or text == "" then
        return false, "Missing required highlight fields"
    end

    local token_ok, token = self:getOrRefreshBearerToken(username, password, false)
    if not token_ok then
        return false, token or "Failed to obtain auth token"
    end

    local body_tbl = {
        bookId = tonumber(book_id),
        cfi    = cfi,
        text   = text,
    }
    if opts.color        and opts.color ~= ""        then body_tbl.color        = opts.color        end
    if opts.style        and opts.style ~= ""        then body_tbl.style        = opts.style        end
    if opts.note         and opts.note ~= ""         then body_tbl.note         = opts.note         end
    if opts.chapter_title and opts.chapter_title ~= "" then body_tbl.chapterTitle = opts.chapter_title end

    local body = json.encode(body_tbl)
    local headers = {
        ["Authorization"] = "Bearer " .. token,
        ["Content-Type"]  = "application/json",
    }

    local success, code, response = self:request("POST", "/api/v1/annotations", body, headers)

    if not success and (code == 401 or code == 403) then
        if self.db then self.db:deleteBearerToken(username) end
        local ref_ok, new_token = self:getOrRefreshBearerToken(username, password, true)
        if ref_ok then
            headers["Authorization"] = "Bearer " .. new_token
            success, code, response = self:request("POST", "/api/v1/annotations", body, headers)
        else
            return false, new_token or "Authentication failed after refresh"
        end
    end

    if success and code == 200 then
        local server_id = type(response) == "table" and response.id or nil
        self:logInfo("BookloreSync API: Highlight submitted, server id:", server_id)
        return true, server_id
    else
        local err = (type(response) == "string" and response ~= "") and response or ("HTTP " .. tostring(code))
        self:logWarn("BookloreSync API: Failed to submit highlight:", err)
        return false, err
    end
end

--[[--
Submit an in-book note (v2) to Booklore.

Endpoint: POST /api/v2/book-notes
Required body fields: bookId, cfi, noteContent
Optional: selectedText, color (hex), chapterTitle

@param book_id        number
@param cfi            string  epubcfi(pos0,pos1)
@param note_content   string  the note text
@param opts           table   { selected_text, color, chapter_title }
@param username       string
@param password       string
@return boolean success
@return number|string  server note id on success, error message on failure
--]]
---APIClient:submitInBookNote.
function APIClient:submitInBookNote(book_id, cfi, note_content, opts, username, password)
    opts = opts or {}

    if not book_id or not cfi or not note_content or note_content == "" then
        return false, "Missing required in-book note fields"
    end

    local token_ok, token = self:getOrRefreshBearerToken(username, password, false)
    if not token_ok then
        return false, token or "Failed to obtain auth token"
    end

    local body_tbl = {
        bookId      = tonumber(book_id),
        cfi         = cfi,
        noteContent = note_content,
    }
    if opts.selected_text  and opts.selected_text ~= ""  then body_tbl.selectedText  = opts.selected_text  end
    if opts.color          and opts.color ~= ""          then body_tbl.color          = opts.color          end
    if opts.chapter_title  and opts.chapter_title ~= ""  then body_tbl.chapterTitle   = opts.chapter_title  end

    local body = json.encode(body_tbl)
    local headers = {
        ["Authorization"] = "Bearer " .. token,
        ["Content-Type"]  = "application/json",
    }

    local success, code, response = self:request("POST", "/api/v2/book-notes", body, headers)

    if not success and (code == 401 or code == 403) then
        if self.db then self.db:deleteBearerToken(username) end
        local ref_ok, new_token = self:getOrRefreshBearerToken(username, password, true)
        if ref_ok then
            headers["Authorization"] = "Bearer " .. new_token
            success, code, response = self:request("POST", "/api/v2/book-notes", body, headers)
        else
            return false, new_token or "Authentication failed after refresh"
        end
    end

    if success and code == 200 then
        local server_id = type(response) == "table" and response.id or nil
        self:logInfo("BookloreSync API: In-book note submitted, server id:", server_id)
        return true, server_id
    else
        local err = (type(response) == "string" and response ~= "") and response or ("HTTP " .. tostring(code))
        self:logWarn("BookloreSync API: Failed to submit in-book note:", err)
        return false, err
    end
end

--[[--
Submit a Booklore (web-UI) note to Booklore.

Endpoint: POST /api/v1/book-notes
Required body fields: bookId, content
Optional: title

@param book_id   number
@param content   string  the note text
@param title     string|nil  chapter title used as note title
@param username  string
@param password  string
@return boolean success
@return number|string  server note id on success, error message on failure
--]]
---APIClient:submitBookloreNote.
function APIClient:submitBookloreNote(book_id, content, title, username, password)
    if not book_id or not content or content == "" then
        return false, "Missing required Booklore note fields"
    end

    local token_ok, token = self:getOrRefreshBearerToken(username, password, false)
    if not token_ok then
        return false, token or "Failed to obtain auth token"
    end

    local body_tbl = {
        bookId  = tonumber(book_id),
        content = content,
    }
    if title and title ~= "" then body_tbl.title = title end

    local body = json.encode(body_tbl)
    local headers = {
        ["Authorization"] = "Bearer " .. token,
        ["Content-Type"]  = "application/json",
    }

    local success, code, response = self:request("POST", "/api/v1/book-notes", body, headers)

    if not success and (code == 401 or code == 403) then
        if self.db then self.db:deleteBearerToken(username) end
        local ref_ok, new_token = self:getOrRefreshBearerToken(username, password, true)
        if ref_ok then
            headers["Authorization"] = "Bearer " .. new_token
            success, code, response = self:request("POST", "/api/v1/book-notes", body, headers)
        else
            return false, new_token or "Authentication failed after refresh"
        end
    end

    if success and code == 200 then
        local server_id = type(response) == "table" and response.id or nil
        self:logInfo("BookloreSync API: Booklore note submitted, server id:", server_id)
        return true, server_id
    else
        local err = (type(response) == "string" and response ~= "") and response or ("HTTP " .. tostring(code))
        self:logWarn("BookloreSync API: Failed to submit Booklore note:", err)
        return false, err
    end
end

--[[--
Fetch a single book's metadata from Booklore by its book ID.

Used to pull fields like hardcoverId that may not have been present at match time.

Endpoint: GET /api/v1/books/<book_id>

@param book_id  number  Booklore book ID
@param username string  Booklore username (Bearer token auth)
@param password string  Booklore password (Bearer token auth)
@return boolean success
@return table|string  normalised book object on success, error message on failure
--]]
---APIClient:getBookById.
function APIClient:getBookById(book_id, username, password)
    book_id = tonumber(book_id)
    if not book_id then
        return false, "Invalid book_id"
    end

    self:logInfo("BookloreSync API: Fetching metadata for book_id:", book_id)

    local headers = {}
    local token_ok, token = self:getOrRefreshBearerToken(username, password)
    if token_ok then
        headers["Authorization"] = "Bearer " .. token
    end

    local success, code, response = self:request("GET", "/api/v1/books/" .. tostring(book_id), nil, headers)

    if not success and (code == 401 or code == 403) then
        self:logWarn("BookloreSync API: Token rejected (" .. tostring(code) .. ") for getBookById, refreshing")
        if self.db then self.db:deleteBearerToken(username) end
        local refresh_ok, new_token = self:getOrRefreshBearerToken(username, password, true)
        if refresh_ok then
            headers["Authorization"] = "Bearer " .. new_token
            success, code, response = self:request("GET", "/api/v1/books/" .. tostring(book_id), nil, headers)
        else
            return false, new_token or "Authentication failed"
        end
    end

    if success and type(response) == "table" then
        response = self:_normalizeBookObject(response)
        self:logInfo("BookloreSync API: Got metadata for book_id:", book_id,
            "hardcover_id:", tostring(response.hardcover_id))
        return true, response
    else
        local err = (type(response) == "string" and response ~= "") and response
                    or ("HTTP " .. tostring(code or "?"))
        self:logWarn("BookloreSync API: getBookById failed:", err)
        return false, err
    end
end

--[[--
Submit a bookmark to Booklore.

Endpoint: POST /api/v1/bookmarks

@param book_id     number  Booklore book ID
@param cfi         string  EPUB CFI (or mock CFI for PDF) identifying the bookmark position
@param opts        table   Optional fields: chapter_title, notes
@param username    string
@param password    string
@return boolean, number|string  success flag + server id or error message
--]]
---APIClient:submitBookmark.
function APIClient:submitBookmark(book_id, cfi, opts, username, password)
    opts = opts or {}

    if not book_id or not cfi then
        return false, "Missing required bookmark fields (book_id, cfi)"
    end

    local token_ok, token = self:getOrRefreshBearerToken(username, password, false)
    if not token_ok then
        return false, token or "Failed to obtain auth token"
    end

    local body_tbl = {
        bookId      = tonumber(book_id),
        cfi         = cfi,
        positionMs  = nil,
        trackIndex  = nil,
        title       = (opts.title and opts.title ~= "") and opts.title or nil,
    }

    local body = json.encode(body_tbl)
    local headers = {
        ["Authorization"] = "Bearer " .. token,
        ["Content-Type"]  = "application/json",
    }

    local success, code, response = self:request("POST", "/api/v1/bookmarks", body, headers)

    if not success and (code == 401 or code == 403) then
        if self.db then self.db:deleteBearerToken(username) end
        local ref_ok, new_token = self:getOrRefreshBearerToken(username, password, true)
        if ref_ok then
            headers["Authorization"] = "Bearer " .. new_token
            success, code, response = self:request("POST", "/api/v1/bookmarks", body, headers)
        else
            return false, new_token or "Authentication failed after refresh"
        end
    end

    if success and (code == 200 or code == 201) then
        local server_id = type(response) == "table" and response.id or nil
        self:logInfo("BookloreSync API: Bookmark submitted, server id:", server_id)
        return true, server_id
    else
        local err = (type(response) == "string" and response ~= "") and response or ("HTTP " .. tostring(code))
        self:logWarn("BookloreSync API: Failed to submit bookmark:", err)
        return false, err
    end
end

-- ── Shelf sync API helpers ────────────────────────────────────────────────────

--[[--
Normalise a book object returned by the shelf endpoint.

The shelf endpoint returns a slightly different shape from the rest of the API:
  - authors live in `metadata.authors` (array of strings)
  - file type is in `bookType` ("EPUB", "PDF") rather than `extension`
  - ISBNs are nested under `metadata`

This function promotes those fields to the top level so the rest of the
plugin can use them uniformly.

@param book table  Raw book object from the shelf API
@return table  Normalised book object (same table, mutated in-place)
--]]
---APIClient:_normalizeShelfBookObject.
function APIClient:_normalizeShelfBookObject(book)
    if not book or type(book) ~= "table" then return book end

    if book.metadata and type(book.metadata) == "table" then
        -- Title lives under metadata on the shelf endpoint
        book.title = book.title or book.metadata.title
        -- First author as scalar string
        if book.metadata.authors and type(book.metadata.authors) == "table"
           and #book.metadata.authors > 0 then
            book.author = book.metadata.authors[1]
        end
        book.isbn10 = book.isbn10 or book.metadata.isbn10
        book.isbn13 = book.isbn13 or book.metadata.isbn13
    end

    -- Extract original server filename from primaryFile if present.
    -- Do this before the extension resolution below so we can use the
    -- filename's own extension as the most reliable source of truth.
    if book.primaryFile and type(book.primaryFile) == "table" then
        book.original_filename = book.primaryFile.fileName
    end

    -- Resolve extension in priority order:
    --   1. Extension embedded in the original server filename (most reliable –
    --      it is the actual file the server will serve).
    --   2. bookType field (e.g. "EPUB", "PDF").
    --   3. Nothing – leave book.extension as nil so callers can skip the book
    --      rather than silently saving it with the wrong extension.
    if not book.extension then
        if book.original_filename and book.original_filename ~= "" then
            local ext = book.original_filename:match("%.([^.]+)$")
            if ext and ext ~= "" then
                book.extension = ext:lower()
            end
        end
        if not book.extension and book.bookType and book.bookType ~= "" then
            book.extension = book.bookType:lower()
        end
    end

    return book
end

--[[--
Fetch all books in a given shelf.

@param shelf_id  number  Shelf ID
@param username  string
@param password  string
@return boolean success
@return table|string  Array of normalised book objects, or error message
--]]
---APIClient:getBooksInShelf.
function APIClient:getBooksInShelf(shelf_id, username, password)
    self:logInfo("BookloreSync API: getBooksInShelf - shelf_id:", shelf_id)

    local token_ok, token = self:getOrRefreshBearerToken(username, password)
    if not token_ok then
        self:logErr("BookloreSync API: getBooksInShelf - auth failed:", token)
        return false, "Authentication failed"
    end

    local headers = { ["Authorization"] = "Bearer " .. token }
    local ok, code, response = self:request("GET", "/api/v1/shelves/" .. shelf_id .. "/books", nil, headers)

    if not ok and (code == 401 or code == 403) then
        self:logWarn("BookloreSync API: getBooksInShelf - token rejected, refreshing")
        if self.db then self.db:deleteBearerToken(username) end
        local ref_ok, new_token = self:getOrRefreshBearerToken(username, password, true)
        if ref_ok then
            headers["Authorization"] = "Bearer " .. new_token
            ok, code, response = self:request("GET", "/api/v1/shelves/" .. shelf_id .. "/books", nil, headers)
        end
    end

    if ok and type(response) == "table" then
        self:logInfo("BookloreSync API: getBooksInShelf - found", #response, "books")
        for i, book in ipairs(response) do
            response[i] = self:_normalizeShelfBookObject(book)
        end
        return true, response
    end

    local err_msg = (type(response) == "string" and response) or ("HTTP " .. tostring(code))
    self:logWarn("BookloreSync API: getBooksInShelf failed:", err_msg)
    return false, err_msg
end

--[[--
Find an existing shelf by name (case-insensitive), or create it if absent.

@param name      string  Shelf name to find or create
@param username  string
@param password  string
@return boolean success
@return number|string  shelf_id on success, error message on failure
--]]
---APIClient:getOrCreateShelf.
function APIClient:getOrCreateShelf(name, username, password)
    self:logInfo("BookloreSync API: getOrCreateShelf - name:", name)

    local token_ok, token = self:getOrRefreshBearerToken(username, password)
    if not token_ok then
        self:logErr("BookloreSync API: getOrCreateShelf - auth failed:", token)
        return false, token
    end

    local headers = { ["Authorization"] = "Bearer " .. token }
    local ok, code, response = self:request("GET", "/api/v1/shelves", nil, headers)

    if not ok and (code == 401 or code == 403) then
        if self.db then self.db:deleteBearerToken(username) end
        local ref_ok, new_token = self:getOrRefreshBearerToken(username, password, true)
        if ref_ok then
            headers["Authorization"] = "Bearer " .. new_token
            ok, code, response = self:request("GET", "/api/v1/shelves", nil, headers)
        end
    end

    if not ok or type(response) ~= "table" then
        local err_msg = (type(response) == "string" and response) or ("HTTP " .. tostring(code))
        self:logWarn("BookloreSync API: getOrCreateShelf - could not list shelves:", err_msg)
        return false, err_msg
    end

    -- Search for existing shelf (case-insensitive)
    local name_lower = name:lower()
    for _, shelf in ipairs(response) do
        if shelf.name and shelf.name:lower() == name_lower then
            self:logInfo("BookloreSync API: Found existing shelf:", shelf.name, "id:", shelf.id)
            return true, tonumber(shelf.id)
        end
    end

    -- Create it
    self:logInfo("BookloreSync API: Shelf not found, creating:", name)
   local body = json.encode({ name = name, icon = "pi pi-shield", iconType = "PRIME_NG", publicShelf = true })
    local create_headers = {
        ["Authorization"] = "Bearer " .. token,
        ["Content-Type"]  = "application/json",
    }
    local c_ok, c_code, c_resp = self:request("POST", "/api/v1/shelves", body, create_headers)

    if c_ok and c_code == 201 and type(c_resp) == "table" and c_resp.id then
        self:logInfo("BookloreSync API: Created shelf:", name, "id:", c_resp.id)
        return true, tonumber(c_resp.id)
    end

    local c_err = (type(c_resp) == "string" and c_resp) or ("HTTP " .. tostring(c_code))
    self:logWarn("BookloreSync API: Shelf creation failed:", c_err)
    return false, c_err
end

--[[--
Download a book file from Booklore to a local path.

Uses streaming download (ltn12 sink.file) to avoid loading the entire
file into memory.

@param book_id   number  Booklore book ID
@param save_path string  Absolute destination path
@param username  string
@param password  string
@return boolean success
@return string|nil  Error message on failure, nil on success
--]]
---APIClient:downloadBook.
function APIClient:downloadBook(book_id, save_path, username, password)
    self:logInfo("BookloreSync API: downloadBook - id:", book_id, "->", save_path)

    local token_ok, token = self:getOrRefreshBearerToken(username, password)
    if not token_ok then
        self:logErr("BookloreSync API: downloadBook - auth failed:", token)
        return false, "Authentication failed"
    end

    local url = self.server_url .. "/api/v1/books/" .. book_id .. "/download"
    local http_client = url:match("^https://") and https or http

    local file, open_err = io.open(save_path, "wb")
    if not file then
        self:logErr("BookloreSync API: downloadBook - cannot open file:", open_err)
        return false, "Cannot create file: " .. tostring(open_err)
    end

    local req_args = {
        url     = url,
        method  = "GET",
        headers = { ["Authorization"] = "Bearer " .. token },
        sink    = ltn12.sink.file(file),
    }
    http_client.TIMEOUT = self.timeout

    local res, code, _ = http_client.request(req_args)

    -- Retry on 401/403
    if type(code) == "number" and (code == 401 or code == 403) then
        self:logWarn("BookloreSync API: downloadBook - token rejected, refreshing")
        if self.db then self.db:deleteBearerToken(username) end
        local ref_ok, new_token = self:getOrRefreshBearerToken(username, password, true)
        if ref_ok then
            -- Re-open file (sink may be in bad state after partial write)
            file:close()
            file, open_err = io.open(save_path, "wb")
            if file then
                req_args.headers = { ["Authorization"] = "Bearer " .. new_token }
                req_args.sink    = ltn12.sink.file(file)
                res, code, _     = http_client.request(req_args)
            end
        end
    end

    if not code then
        os.remove(save_path)
        local err_msg = "Network error: " .. tostring(res)
        self:logErr("BookloreSync API: downloadBook failed:", err_msg)
        return false, err_msg
    end

    if type(code) == "number" and code >= 200 and code < 300 then
        self:logInfo("BookloreSync API: downloadBook - success")
        return true, nil
    end

    os.remove(save_path)
    local err_msg = "HTTP " .. tostring(code) .. ": download failed"
    self:logErr("BookloreSync API: downloadBook failed:", err_msg)
    return false, err_msg
end

--[[--
Get the file size of a book by making an HTTP HEAD request.

This function makes a HEAD request to the book download endpoint to retrieve
the Content-Length header without downloading the full file.

@param book_id   number  Book ID
@param username  string  Username for authentication
@param password  string  Password for authentication
@return number|nil       File size in bytes on success, nil on failure
@return string|nil       Error message on failure, nil on success
--]]
---APIClient:getBookFileSize.
function APIClient:getBookFileSize(book_id, username, password)
    self:logInfo("BookloreSync API: getBookFileSize - id:", book_id)

    if not self.server_url or self.server_url == "" then
        self:logErr("BookloreSync API: getBookFileSize - server URL not configured")
        return nil, "Server URL not configured"
    end

    local token_ok, token = self:getOrRefreshBearerToken(username, password)
    if not token_ok then
        self:logErr("BookloreSync API: getBookFileSize - auth failed:", token)
        return nil, "Authentication failed: " .. tostring(token)
    end

    local url = self.server_url .. "/api/v1/books/" .. book_id .. "/download"
    local http_client = url:match("^https://") and https or http

    local response_body = {}
    local req_args = {
        url     = url,
        method  = "HEAD",
        headers = { ["Authorization"] = "Bearer " .. token },
        sink    = ltn12.sink.table(response_body),
    }
    http_client.TIMEOUT = self.timeout

    local res, code, response_headers = http_client.request(req_args)
    local refresh_attempted = false

    -- Retry on 401/403
    if type(code) == "number" and (code == 401 or code == 403) then
        refresh_attempted = true
        self:logWarn("BookloreSync API: getBookFileSize - token rejected, refreshing")
        if self.db then self.db:deleteBearerToken(username) end
        local ref_ok, new_token = self:getOrRefreshBearerToken(username, password, true)
        if not ref_ok then
            local err_msg = "Authentication refresh failed: " .. tostring(new_token)
            self:logErr("BookloreSync API: getBookFileSize failed:", err_msg)
            return nil, err_msg
        end
        req_args.headers = { ["Authorization"] = "Bearer " .. new_token }
        res, code, response_headers = http_client.request(req_args)
    end

    if not code then
        local prefix = refresh_attempted and "Network error after token refresh: " or "Network error: "
        local err_msg = prefix .. tostring(res)
        self:logErr("BookloreSync API: getBookFileSize failed:", err_msg)
        return nil, err_msg
    end

    if type(code) ~= "number" then
        local err_msg = "Connection error: " .. tostring(code)
        self:logErr("BookloreSync API: getBookFileSize failed:", err_msg)
        return nil, err_msg
    end

    if code < 200 or code >= 300 then
        local suffix = refresh_attempted and " after token refresh" or ""
        local err_msg = "HTTP " .. tostring(code) .. ": HEAD request failed" .. suffix
        self:logErr("BookloreSync API: getBookFileSize failed:", err_msg)
        return nil, err_msg
    end

    -- Extract Content-Length from response headers
    if not response_headers then
        local err_msg = "No response headers received"
        self:logErr("BookloreSync API: getBookFileSize failed:", err_msg)
        return nil, err_msg
    end

    -- HTTP headers can be in various cases (content-length, Content-Length, etc.)
    local content_length = response_headers["content-length"] 
                        or response_headers["Content-Length"]
                        or response_headers["CONTENT-LENGTH"]
    
    if not content_length then
        local err_msg = "Content-Length header not found in response"
        self:logErr("BookloreSync API: getBookFileSize failed:", err_msg)
        return nil, err_msg
    end

    local file_size = tonumber(content_length)
    if not file_size or file_size < 0 then
        local err_msg = "Invalid Content-Length: " .. tostring(content_length)
        self:logErr("BookloreSync API: getBookFileSize failed:", err_msg)
        return nil, err_msg
    end

    self:logInfo("BookloreSync API: getBookFileSize - success, size:", file_size, "bytes")
    return file_size, nil
end

return APIClient
