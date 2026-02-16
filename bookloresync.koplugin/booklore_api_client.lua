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
    secure_logs = false,  -- Secure logging flag
}

--[[--
Redact URLs from log message for secure logging

@param message The log message that may contain URLs
@return string Message with URLs redacted
--]]
local function redactUrls(message)
    if type(message) ~= "string" then
        message = tostring(message)
    end
    -- Match http:// or https:// URLs and replace them with [URL REDACTED]
    return message:gsub("https?://[^%s]+", "[URL REDACTED]")
end

function APIClient:new(o)
    o = o or {}
    setmetatable(o, self)
    self.__index = self
    return o
end

function APIClient:init(server_url, username, password, db, secure_logs)
    self.server_url = server_url
    self.username = username
    self.password = password
    self.db = db  -- Store database reference for token caching
    self.secure_logs = secure_logs or false
    
    -- Remove trailing slash from server URL
    if self.server_url and self.server_url:sub(-1) == "/" then
        self.server_url = self.server_url:sub(1, -2)
    end
    
    self:logInfo("BookloreSync API: Initialized with server:", self.server_url)
end
-- Secure logger wrappers
function APIClient:logInfo(...)
    local args = {...}
    if self.secure_logs then
        for i = 1, #args do
            args[i] = redactUrls(args[i])
        end
    end
    logger.info(table.unpack(args))
end

function APIClient:logWarn(...)
    local args = {...}
    if self.secure_logs then
        for i = 1, #args do
            args[i] = redactUrls(args[i])
        end
    end
    logger.warn(table.unpack(args))
end

function APIClient:logErr(...)
    local args = {...}
    if self.secure_logs then
        for i = 1, #args do
            args[i] = redactUrls(args[i])
        end
    end
    logger.err(table.unpack(args))
end

function APIClient:logDbg(...)
    local args = {...}
    if self.secure_logs then
        for i = 1, #args do
            args[i] = redactUrls(args[i])
        end
    end
    logger.dbg(table.unpack(args))
end
--[[--
Parse JSON response with error handling

@param response_text The raw response text
@return table|nil Parsed JSON object or nil
@return string|nil Error message if parsing failed
--]]
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
function APIClient:extractErrorMessage(response_text, code)
    -- Try to parse as JSON first
    local json_data, parse_err = self:parseJSON(response_text)
    
    if json_data then
        -- Check common error message fields
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
    
    -- If JSON parsing failed or no message found, use response text or HTTP code
    if response_text and response_text ~= "" and #response_text < 500 then
        -- Use response text if it's reasonably short
        return response_text
    end
    
    -- Fall back to generic HTTP status message
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
    
    return status_messages[code] or "HTTP " .. tostring(code)
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
function APIClient:request(method, path, body, headers)
    if not self.server_url or self.server_url == "" then
        self:logErr("BookloreSync API: Server URL not configured")
        return false, nil, "Server URL not configured"
    end
    
    -- Build full URL
    local url = self.server_url .. path
    self:logInfo("BookloreSync API:", method, url)
    
    -- Prepare headers
    local req_headers = headers or {}
    
    -- Add authentication if username/password provided and no custom Authorization header
    if self.username and self.password and not req_headers["Authorization"] then
        local password_hash = md5(self.password)
        req_headers["x-auth-user"] = self.username
        req_headers["x-auth-key"] = password_hash
    end
    
    -- Prepare request body
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
    
    -- Prepare response capture
    local response_body = {}
    local sink = ltn12.sink.table(response_body)
    
    -- Choose HTTP or HTTPS
    local http_client = http
    if url:match("^https://") then
        http_client = https
    end
    
    -- Set timeout
    http_client.TIMEOUT = self.timeout
    
    -- Make request
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
    
    -- Process response
    local response_text = table.concat(response_body)
    
    self:logInfo("BookloreSync API: Response code:", tostring(code))
    self:logDbg("BookloreSync API: Response length:", #response_text)
    
    -- Check for network/connection errors
    if not code then
        local error_msg = res or "Connection failed"
        self:logErr("BookloreSync API: Network error:", error_msg)
        return false, nil, "Network error: " .. error_msg
    end
    
    -- Ensure code is a number (http client can return strings like "connection refused")
    if type(code) ~= "number" then
        local error_msg = tostring(code)
        self:logErr("BookloreSync API: Non-numeric response code:", error_msg)
        return false, nil, "Connection error: " .. error_msg
    end
    
    -- Success codes (2xx)
    if code >= 200 and code < 300 then
        -- Try to parse JSON response
        if response_text and response_text ~= "" then
            local json_data, parse_err = self:parseJSON(response_text)
            if json_data then
                return true, code, json_data
            else
                -- Not JSON, return raw text
                return true, code, response_text
            end
        else
            -- Empty success response
            return true, code, nil
        end
    end
    
    -- Error codes (4xx, 5xx)
    local error_message = self:extractErrorMessage(response_text, code)
    self:logWarn("BookloreSync API: Request failed:", code, "-", error_message)
    
    return false, code, error_message
end

--[[--
Test authentication with the server

@return boolean success
@return string message (success message or detailed error)
--]]
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
Get book by hash

@param book_hash The MD5 hash of the book file
@return boolean success
@return table|string book_data or error_message
--]]
function APIClient:getBookByHash(book_hash)
    self:logInfo("BookloreSync API: Looking up book by hash:", book_hash)
    
    local success, code, response = self:request("GET", "/api/koreader/books/by-hash/" .. book_hash)
    
    if success and type(response) == "table" then
        self:logInfo("BookloreSync API: Found book, ID:", response.id)
        
        -- Extract ISBN from metadata if present
        local isbn10 = nil
        local isbn13 = nil
        if response.metadata and type(response.metadata) == "table" then
            isbn10 = response.metadata.isbn10
            isbn13 = response.metadata.isbn13
        end
        
        -- Store ISBN in top-level response for easier access by caller
        response.isbn10 = isbn10
        response.isbn13 = isbn13
        
        if isbn10 or isbn13 then
            self:logInfo("BookloreSync API: Book has ISBN-10:", isbn10, "ISBN-13:", isbn13)
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
Check server health/connectivity

@return boolean success
@return string message
--]]
function APIClient:checkHealth()
    self:logInfo("BookloreSync API: Checking server health")
    
    local success, code, response = self:request("GET", "/api/health")
    
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
function APIClient:searchBooks(title)
    self:logInfo("BookloreSync API: Searching books with title:", title)
    
    -- URL encode the title
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
function APIClient:getOrRefreshBearerToken(username, password, force_refresh)
    force_refresh = force_refresh or false
    
    -- Try to use cached token first (unless force refresh)
    if not force_refresh and self.db then
        local cached_token, expires_at = self.db:getBearerToken(username)
        if cached_token then
            -- Check if token will expire within 1 day (86400 seconds)
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
    
    -- No cached token or force refresh - login to get new token
    self:logInfo("BookloreSync API: Getting new Bearer token for:", username)
    local success, token = self:loginBooklore(username, password)
    
    if success and token then
        -- Save token to cache
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
function APIClient:validateBearerToken(token)
    -- Try to make a simple request with the token
    local headers = {
        ["Authorization"] = "Bearer " .. token
    }
    
    -- Use a lightweight endpoint to test the token
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
function APIClient:searchBooksWithAuth(title, username, password)
    self:logInfo("BookloreSync API: Searching books with Booklore auth, title:", title)
    
    -- Get or refresh cached Bearer token
    local login_success, token = self:getOrRefreshBearerToken(username, password)
    
    if not login_success then
        self:logErr("BookloreSync API: Failed to get Bearer token:", token)
        return false, token or "Authentication failed"
    end
    
    -- URL encode the title
    local encoded_title = self:_urlEncode(title)
    local endpoint = "/api/v1/books/search?title=" .. encoded_title
    
    -- Make request with Bearer token
    local headers = {
        ["Authorization"] = "Bearer " .. token
    }
    
    local success, code, response = self:request("GET", endpoint, nil, headers)
    
    -- If we get 401/403, token might be invalid - retry with fresh token
    if not success and (code == 401 or code == 403) then
        self:logWarn("BookloreSync API: Token rejected (401/403), refreshing and retrying")
        
        -- Delete cached token and get fresh one
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
        
        -- Normalize each book object to extract ISBN from metadata
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
function APIClient:searchBooksByIsbn(isbn, username, password)
    self:logInfo("BookloreSync API: Searching books by ISBN:", isbn)
    
    -- Get or refresh cached Bearer token
    local login_success, token = self:getOrRefreshBearerToken(username, password)
    
    if not login_success then
        self:logErr("BookloreSync API: Failed to get Bearer token:", token)
        return false, token or "Authentication failed"
    end
    
    -- URL encode the ISBN
    local encoded_isbn = self:_urlEncode(isbn)
    local endpoint = "/api/v1/books/search?isbn=" .. encoded_isbn
    
    -- Make request with Bearer token
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
        
        -- Normalize each book object to extract ISBN from metadata
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
function APIClient:getBookByHashWithAuth(book_hash, username, password)
    self:logInfo("BookloreSync API: Looking up book by hash with Booklore auth:", book_hash)
    
    -- Get or refresh cached Bearer token
    local login_success, token = self:getOrRefreshBearerToken(username, password)
    
    if not login_success then
        self:logErr("BookloreSync API: Failed to get Bearer token:", token)
        return false, "Authentication failed"
    end
    
    -- Make request with Bearer token
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
        
        -- Extract ISBN from metadata if present
        local isbn10 = nil
        local isbn13 = nil
        if response.metadata and type(response.metadata) == "table" then
            isbn10 = response.metadata.isbn10
            isbn13 = response.metadata.isbn13
        end
        
        -- Store ISBN in top-level response for easier access by caller
        response.isbn10 = isbn10
        response.isbn13 = isbn13
        
        if isbn10 or isbn13 then
            self:logInfo("BookloreSync API: Book has ISBN-10:", isbn10, "ISBN-13:", isbn13)
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
Normalize book object by extracting ISBN from metadata to top level

@param book Book object from API
@return table Normalized book object with isbn10/isbn13 at top level
--]]
function APIClient:_normalizeBookObject(book)
    if not book or type(book) ~= "table" then
        return book
    end
    
    -- Extract ISBN from metadata if present
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

return APIClient
