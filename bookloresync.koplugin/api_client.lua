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
}

function APIClient:new(o)
    o = o or {}
    setmetatable(o, self)
    self.__index = self
    return o
end

function APIClient:init(server_url, username, password)
    self.server_url = server_url
    self.username = username
    self.password = password
    
    -- Remove trailing slash from server URL
    if self.server_url and self.server_url:sub(-1) == "/" then
        self.server_url = self.server_url:sub(1, -2)
    end
    
    logger.info("BookloreSync API: Initialized with server:", self.server_url)
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
        logger.warn("BookloreSync API: Failed to parse JSON:", result)
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
        logger.err("BookloreSync API: Server URL not configured")
        return false, nil, "Server URL not configured"
    end
    
    -- Build full URL
    local url = self.server_url .. path
    logger.info("BookloreSync API:", method, url)
    
    -- Prepare headers
    local req_headers = headers or {}
    
    -- Add authentication if username/password provided
    if self.username and self.password then
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
        
        logger.dbg("BookloreSync API: Request body length:", #req_body)
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
    
    logger.info("BookloreSync API: Response code:", tostring(code))
    logger.dbg("BookloreSync API: Response length:", #response_text)
    
    -- Check for network/connection errors
    if not code then
        local error_msg = res or "Connection failed"
        logger.err("BookloreSync API: Network error:", error_msg)
        return false, nil, "Network error: " .. error_msg
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
    logger.warn("BookloreSync API: Request failed:", code, "-", error_message)
    
    return false, code, error_message
end

--[[--
Test authentication with the server

@return boolean success
@return string message (success message or detailed error)
--]]
function APIClient:testAuth()
    logger.info("BookloreSync API: Testing authentication")
    
    if not self.username or self.username == "" then
        return false, "Username not configured"
    end
    
    if not self.password or self.password == "" then
        return false, "Password not configured"
    end
    
    local success, code, response = self:request("GET", "/api/koreader/users/auth")
    
    if success then
        logger.info("BookloreSync API: Authentication successful")
        return true, "Authentication successful"
    else
        local error_detail = response or "Unknown error"
        if code then
            error_detail = "HTTP " .. tostring(code) .. ": " .. error_detail
        end
        logger.err("BookloreSync API: Authentication failed:", error_detail)
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
    logger.info("BookloreSync API: Looking up book by hash:", book_hash)
    
    local success, code, response = self:request("GET", "/api/koreader/books/by-hash/" .. book_hash)
    
    if success and type(response) == "table" then
        logger.info("BookloreSync API: Found book, ID:", response.id)
        return true, response
    else
        local error_msg = response or "Book not found"
        logger.warn("BookloreSync API: Book lookup failed:", error_msg)
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
    logger.info("BookloreSync API: Submitting reading session for book:", session_data.bookId or session_data.bookHash)
    
    local success, code, response = self:request("POST", "/api/v1/reading-sessions", session_data)
    
    if success then
        logger.info("BookloreSync API: Session submitted successfully")
        return true, "Session synced successfully"
    else
        local error_msg = response or "Failed to submit session"
        if code then
            error_msg = "HTTP " .. tostring(code) .. ": " .. error_msg
        end
        logger.warn("BookloreSync API: Session submission failed:", error_msg)
        return false, error_msg
    end
end

--[[--
Check server health/connectivity

@return boolean success
@return string message
--]]
function APIClient:checkHealth()
    logger.info("BookloreSync API: Checking server health")
    
    local success, code, response = self:request("GET", "/api/health")
    
    if success or (code and code >= 200 and code < 500) then
        -- Server is reachable (even if endpoint doesn't exist)
        logger.info("BookloreSync API: Server is reachable")
        return true, "Server is online"
    else
        local error_msg = response or "Server unreachable"
        logger.warn("BookloreSync API: Health check failed:", error_msg)
        return false, error_msg
    end
end

return APIClient
