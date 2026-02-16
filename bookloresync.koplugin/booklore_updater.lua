--[[--
Booklore Auto-Updater Module

Handles checking for updates and installing new versions from GitHub.
Uses GitHub API to fetch latest release, downloads ZIP asset, and
performs atomic installation with backup/rollback support.

@module koplugin.BookloreSync.updater
--]]

local logger = require("logger")
local http = require("socket.http")
local https = require("ssl.https")
local ltn12 = require("ltn12")
local json = require("json")
local DataStorage = require("datastorage")
local ffi = require("ffi")
local util = require("util")

local Updater = {
    -- Constants
    GITHUB_REPO = "WorldTeacher/BookLoreSync-plugin",
    GITHUB_API_BASE = "https://api.github.com",
    RELEASE_ASSET_NAME = "bookloresync.koplugin.zip",
    CACHE_DURATION = 3600,  -- 1 hour
    BACKUP_KEEP_COUNT = 3,
    HTTP_TIMEOUT = 10,
    
    -- Paths (initialized in init())
    plugin_dir = nil,
    backup_dir = nil,
    temp_dir = nil,
    
    -- Database reference
    db = nil,
}

function Updater:new(o)
    o = o or {}
    setmetatable(o, self)
    self.__index = self
    return o
end

--[[--
Initialize updater with paths and database reference

@param plugin_dir Path to the plugin directory
@param db Database instance for caching
--]]
function Updater:init(plugin_dir, db)
    self.plugin_dir = plugin_dir
    self.db = db
    
    -- Set up backup directory
    self.backup_dir = DataStorage:getDataDir() .. "/booklore-backups"
    
    -- Set up temp directory
    self.temp_dir = "/tmp/booklore-update-" .. tostring(os.time())
    
    logger.info("BookloreSync Updater: Initialized")
    logger.info("BookloreSync Updater: Plugin dir:", self.plugin_dir)
    logger.info("BookloreSync Updater: Backup dir:", self.backup_dir)
    logger.info("BookloreSync Updater: Temp dir:", self.temp_dir)
    
    -- Create backup directory if it doesn't exist
    os.execute("mkdir -p " .. self.backup_dir)
end

--[[--
Get current plugin version from plugin_version.lua

@return table Version information {version, version_type, git_commit, build_date}
--]]
function Updater:getCurrentVersion()
    local version_file = self.plugin_dir .. "/plugin_version.lua"
    
    local ok, version_info = pcall(dofile, version_file)
    if not ok then
        logger.err("BookloreSync Updater: Failed to read version file:", version_info)
        return {
            version = "0.0.0-dev",
            version_type = "development",
            git_commit = "unknown",
            build_date = "unknown"
        }
    end
    
    return version_info
end

--[[--
Parse semantic version string into components

@param version_string Version string like "1.2.3" or "v1.2.3"
@return table {major, minor, patch, is_dev} or nil if invalid
--]]
function Updater:parseVersion(version_string)
    if not version_string then
        return nil
    end
    
    -- Strip leading 'v' if present
    version_string = version_string:gsub("^v", "")
    
    -- Check for dev version
    if version_string:match("dev") then
        return {major = 0, minor = 0, patch = 0, is_dev = true}
    end
    
    -- Parse semantic version (X.Y.Z)
    local major, minor, patch = version_string:match("^(%d+)%.(%d+)%.(%d+)")
    
    if not major then
        logger.warn("BookloreSync Updater: Invalid version format:", version_string)
        return nil
    end
    
    return {
        major = tonumber(major),
        minor = tonumber(minor),
        patch = tonumber(patch),
        is_dev = false
    }
end

--[[--
Compare two version objects

@param v1 First version object from parseVersion()
@param v2 Second version object from parseVersion()
@return number -1 if v1 < v2, 0 if equal, 1 if v1 > v2
--]]
function Updater:compareVersions(v1, v2)
    if not v1 or not v2 then
        return 0
    end
    
    -- Dev versions are always older
    if v1.is_dev and not v2.is_dev then
        return -1
    end
    if not v1.is_dev and v2.is_dev then
        return 1
    end
    if v1.is_dev and v2.is_dev then
        return 0
    end
    
    -- Compare major version
    if v1.major < v2.major then return -1 end
    if v1.major > v2.major then return 1 end
    
    -- Compare minor version
    if v1.minor < v2.minor then return -1 end
    if v1.minor > v2.minor then return 1 end
    
    -- Compare patch version
    if v1.patch < v2.patch then return -1 end
    if v1.patch > v2.patch then return 1 end
    
    -- Versions are equal
    return 0
end

--[[--
Make HTTP GET request with timeout and redirect support

@param url URL to fetch
@param headers Optional headers table
@param max_redirects Maximum number of redirects to follow (default 5)
@return boolean success
@return string|nil response_text or error
@return number|nil HTTP status code
@return table|nil response headers
--]]
function Updater:_makeHttpRequest(url, headers, max_redirects)
    max_redirects = max_redirects or 5
    local redirect_count = 0
    local current_url = url
    
    while redirect_count <= max_redirects do
        logger.info("BookloreSync Updater: HTTP GET", current_url)
        
        local response_body = {}
        local request_headers = headers or {}
        
        -- Set User-Agent for GitHub API
        if not request_headers["User-Agent"] then
            request_headers["User-Agent"] = "BookloreSync-KOReader-Plugin"
        end
        
        -- Choose http or https based on URL
        local protocol = current_url:match("^https") and https or http
        
        -- Set timeout
        protocol.TIMEOUT = self.HTTP_TIMEOUT
        
        local response, code, response_headers = protocol.request{
            url = current_url,
            method = "GET",
            headers = request_headers,
            sink = ltn12.sink.table(response_body),
        }
        
        -- Check for network errors
        if type(code) ~= "number" then
            local error_msg = tostring(code)
            logger.err("BookloreSync Updater: HTTP request failed:", error_msg)
            return false, "Connection error: " .. error_msg, nil, nil
        end
        
        local response_text = table.concat(response_body)
        
        -- Handle redirects (3xx status codes)
        if code >= 300 and code < 400 then
            local location = response_headers and response_headers["location"]
            if not location then
                logger.err("BookloreSync Updater: Redirect without Location header")
                return false, "Redirect without location", code, response_headers
            end
            
            -- Handle relative redirects
            if location:sub(1, 1) == "/" then
                local base_url = current_url:match("^(https?://[^/]+)")
                location = base_url .. location
            end
            
            redirect_count = redirect_count + 1
            if redirect_count > max_redirects then
                logger.err("BookloreSync Updater: Too many redirects")
                return false, "Too many redirects", code, response_headers
            end
            
            logger.info("BookloreSync Updater: Following redirect to", location)
            current_url = location
            -- Continue loop to follow redirect
        elseif code >= 200 and code < 300 then
            -- Success
            return true, response_text, code, response_headers
        else
            -- Error
            logger.err("BookloreSync Updater: HTTP", code, "response")
            return false, response_text, code, response_headers
        end
    end
    
    -- Should never reach here
    return false, "Redirect loop", nil, nil
end

--[[--
Get latest release information from GitHub API

@return table|nil Release info {version, download_url, changelog, published_at, size}
@return string|nil Error message if failed
--]]
function Updater:getLatestRelease()
    local url = string.format("%s/repos/%s/releases/latest",
        self.GITHUB_API_BASE, self.GITHUB_REPO)
    
    local success, response, code = self:_makeHttpRequest(url)
    
    if not success then
        return nil, "Failed to fetch release info: " .. tostring(response)
    end
    
    -- Parse JSON response
    local ok, release_data = pcall(json.decode, response)
    if not ok then
        logger.err("BookloreSync Updater: Failed to parse JSON:", release_data)
        return nil, "Invalid response from GitHub API"
    end
    
    -- Extract version from tag_name
    local version = release_data.tag_name
    if not version then
        return nil, "No tag_name in release data"
    end
    
    -- Find the ZIP asset
    local download_url = nil
    local asset_size = 0
    
    if release_data.assets then
        for _, asset in ipairs(release_data.assets) do
            if asset.name == self.RELEASE_ASSET_NAME then
                download_url = asset.browser_download_url
                asset_size = asset.size or 0
                break
            end
        end
    end
    
    if not download_url then
        return nil, "Release asset not found: " .. self.RELEASE_ASSET_NAME
    end
    
    return {
        version = version,
        download_url = download_url,
        changelog = release_data.body or "",
        published_at = release_data.published_at or "",
        size = asset_size
    }, nil
end

--[[--
Get cached release information from database

@return table|nil Cached release info or nil if expired/not found
--]]
function Updater:getCachedReleaseInfo()
    if not self.db then
        return nil
    end
    
    local cached_json = self.db:getUpdaterCache("latest_release")
    if not cached_json then
        return nil
    end
    
    -- Parse cached JSON
    local ok, release_info = pcall(json.decode, cached_json)
    if not ok then
        logger.warn("BookloreSync Updater: Failed to parse cached release info")
        return nil
    end
    
    logger.info("BookloreSync Updater: Using cached release info")
    return release_info
end

--[[--
Cache release information in database

@param release_info Release information table
@return boolean success
--]]
function Updater:cacheReleaseInfo(release_info)
    if not self.db then
        return false
    end
    
    local release_json = json.encode(release_info)
    return self.db:setUpdaterCache("latest_release", release_json)
end

--[[--
Clear cached release information

@return boolean success
--]]
function Updater:clearCache()
    if not self.db then
        return false
    end
    
    return self.db:clearUpdaterCache()
end

--[[--
Check for available updates

@param use_cache If true, use cached release info (if available and fresh)
@return table|nil {available, current_version, latest_version, release_info}
--]]
function Updater:checkForUpdates(use_cache)
    logger.info("BookloreSync Updater: Checking for updates (use_cache=" .. tostring(use_cache) .. ")")
    
    -- Get current version
    local current_info = self:getCurrentVersion()
    local current_version = current_info.version
    
    -- Get latest release (from cache or API)
    local release_info, error_msg
    
    if use_cache then
        release_info = self:getCachedReleaseInfo()
    end
    
    if not release_info then
        release_info, error_msg = self:getLatestRelease()
        if not release_info then
            logger.err("BookloreSync Updater: Failed to get latest release:", error_msg)
            return nil
        end
        
        -- Cache the result
        self:cacheReleaseInfo(release_info)
    end
    
    -- Parse versions
    local current_parsed = self:parseVersion(current_version)
    local latest_parsed = self:parseVersion(release_info.version)
    
    if not current_parsed or not latest_parsed then
        logger.err("BookloreSync Updater: Failed to parse versions")
        return nil
    end
    
    -- Compare versions
    local comparison = self:compareVersions(current_parsed, latest_parsed)
    local update_available = comparison < 0
    
    logger.info("BookloreSync Updater: Current version:", current_version)
    logger.info("BookloreSync Updater: Latest version:", release_info.version)
    logger.info("BookloreSync Updater: Update available:", update_available)
    
    return {
        available = update_available,
        current_version = current_version,
        latest_version = release_info.version,
        release_info = release_info
    }
end

--[[--
Format bytes as human-readable size

@param bytes Number of bytes
@return string Formatted size (e.g., "35.6 KB", "1.2 MB")
--]]
function Updater:formatBytes(bytes)
    if not bytes or bytes == 0 then
        return "Unknown size"
    end
    
    if bytes < 1024 then
        return string.format("%d B", bytes)
    elseif bytes < 1024 * 1024 then
        return string.format("%.1f KB", bytes / 1024)
    else
        return string.format("%.1f MB", bytes / (1024 * 1024))
    end
end

--[[--
Download update file with progress callback and redirect support

@param url Download URL
@param progress_callback Function called with (bytes_downloaded, total_bytes)
@return boolean success
@return string zip_path or error message
--]]
function Updater:downloadUpdate(url, progress_callback)
    logger.info("BookloreSync Updater: Downloading from", url)
    
    -- Create temp directory
    os.execute("mkdir -p " .. self.temp_dir)
    
    local zip_path = self.temp_dir .. "/download.zip"
    
    -- Follow redirects manually to get final URL
    local final_url = url
    local max_redirects = 5
    local redirect_count = 0
    
    while redirect_count <= max_redirects do
        logger.info("BookloreSync Updater: Checking URL", final_url)
        
        -- Choose protocol
        local protocol = final_url:match("^https") and https or http
        protocol.TIMEOUT = 60  -- Longer timeout for downloads
        
        -- Make HEAD request to check for redirects
        local head_response = {}
        local response, code, response_headers = protocol.request{
            url = final_url,
            method = "HEAD",
            sink = ltn12.sink.table(head_response),
            headers = {
                ["User-Agent"] = "BookloreSync-KOReader-Plugin"
            }
        }
        
        if type(code) ~= "number" then
            return false, "Connection error: " .. tostring(code)
        end
        
        -- Handle redirects
        if code >= 300 and code < 400 then
            local location = response_headers and response_headers["location"]
            if not location then
                return false, "Redirect without location"
            end
            
            -- Handle relative redirects
            if location:sub(1, 1) == "/" then
                local base_url = final_url:match("^(https?://[^/]+)")
                location = base_url .. location
            end
            
            redirect_count = redirect_count + 1
            if redirect_count > max_redirects then
                return false, "Too many redirects"
            end
            
            logger.info("BookloreSync Updater: Following redirect to", location)
            final_url = location
        elseif code >= 200 and code < 300 then
            -- Found final URL, proceed with download
            break
        else
            return false, "HTTP error: " .. tostring(code)
        end
    end
    
    -- Now download from final URL
    logger.info("BookloreSync Updater: Downloading from final URL", final_url)
    
    local file = io.open(zip_path, "wb")
    if not file then
        return false, "Failed to create download file"
    end
    
    -- Track download progress
    local bytes_downloaded = 0
    local total_bytes = 0
    
    -- Custom sink to track progress
    local function progress_sink(chunk, err)
        if chunk then
            file:write(chunk)
            bytes_downloaded = bytes_downloaded + #chunk
            
            if progress_callback and total_bytes > 0 then
                progress_callback(bytes_downloaded, total_bytes)
            end
        end
        return 1
    end
    
    -- Choose protocol for final download
    local protocol = final_url:match("^https") and https or http
    protocol.TIMEOUT = 60
    
    -- Make GET request to download
    local response, code, response_headers = protocol.request{
        url = final_url,
        method = "GET",
        sink = progress_sink,
        headers = {
            ["User-Agent"] = "BookloreSync-KOReader-Plugin"
        }
    }
    
    file:close()
    
    -- Check for errors
    if type(code) ~= "number" then
        os.execute("rm -f " .. zip_path)
        return false, "Connection error: " .. tostring(code)
    end
    
    if code < 200 or code >= 300 then
        os.execute("rm -f " .. zip_path)
        return false, "HTTP error: " .. tostring(code)
    end
    
    -- Get file size (optional, for logging only)
    local ok, lfs = pcall(require, "libs/libkoreader-lfs")
    if ok and lfs then
        local attr = lfs.attributes(zip_path)
        if attr and attr.size then
            logger.info("BookloreSync Updater: Downloaded", attr.size, "bytes")
        end
    else
        logger.dbg("BookloreSync Updater: Download complete (file size unavailable)")
    end
    
    return true, zip_path
end

--[[--
Validate ZIP file structure

@param zip_path Path to ZIP file
@return boolean valid
@return string|nil error message
--]]
function Updater:_validateZipStructure(zip_path)
    logger.info("BookloreSync Updater: Validating ZIP structure")
    
    -- List ZIP contents
    local list_cmd = string.format("unzip -l '%s' 2>&1", zip_path)
    local handle = io.popen(list_cmd)
    local output = handle:read("*a")
    handle:close()
    
    -- Check for required files
    local has_main = output:match("bookloresync%.koplugin/main%.lua")
    local has_meta = output:match("bookloresync%.koplugin/_meta%.lua")
    
    if not has_main then
        return false, "Invalid ZIP: missing main.lua"
    end
    
    if not has_meta then
        return false, "Invalid ZIP: missing _meta.lua"
    end
    
    logger.info("BookloreSync Updater: ZIP structure is valid")
    return true, nil
end

--[[--
Extract ZIP file to destination directory

@param zip_path Path to ZIP file
@param dest_dir Destination directory
@return boolean success
@return string|nil error message
--]]
function Updater:_extractZip(zip_path, dest_dir)
    logger.info("BookloreSync Updater: Extracting to", dest_dir)
    
    -- Create destination directory
    os.execute("mkdir -p " .. dest_dir)
    
    -- Extract ZIP
    local extract_cmd = string.format("unzip -q -o '%s' -d '%s' 2>&1", zip_path, dest_dir)
    local handle = io.popen(extract_cmd)
    local output = handle:read("*a")
    local success = handle:close()
    
    if not success then
        logger.err("BookloreSync Updater: Extraction failed:", output)
        return false, "Failed to extract ZIP: " .. output
    end
    
    return true, nil
end

--[[--
Backup current plugin version

@return boolean success
@return string backup_path or error message
--]]
function Updater:backupCurrentVersion()
    local current_info = self:getCurrentVersion()
    local timestamp = os.date("%Y%m%d-%H%M%S")
    local backup_name = string.format("bookloresync-%s-%s", current_info.version, timestamp)
    local backup_path = self.backup_dir .. "/" .. backup_name
    
    logger.info("BookloreSync Updater: Backing up to", backup_path)
    
    -- Create backup using cp -r
    local backup_cmd = string.format("cp -r '%s' '%s' 2>&1", self.plugin_dir, backup_path)
    local handle = io.popen(backup_cmd)
    local output = handle:read("*a")
    local success = handle:close()
    
    if not success then
        logger.err("BookloreSync Updater: Backup failed:", output)
        return false, "Backup failed: " .. output
    end
    
    logger.info("BookloreSync Updater: Backup created successfully")
    
    -- Cleanup old backups
    self:cleanupOldBackups(self.BACKUP_KEEP_COUNT)
    
    return true, backup_path
end

--[[--
Install update from ZIP file (atomic operation)

@param zip_path Path to downloaded ZIP file
@return boolean success
@return string|nil error message
--]]
function Updater:installUpdate(zip_path)
    logger.info("BookloreSync Updater: Installing update from", zip_path)
    
    -- Step 1: Validate ZIP structure
    local valid, error_msg = self:_validateZipStructure(zip_path)
    if not valid then
        return false, error_msg
    end
    
    -- Step 2: Extract to temp directory
    local extract_dir = self.temp_dir .. "/extracted"
    local success, error_msg = self:_extractZip(zip_path, extract_dir)
    if not success then
        return false, error_msg
    end
    
    -- Step 3: Verify extracted plugin directory exists
    local new_plugin_dir = extract_dir .. "/bookloresync.koplugin"
    local test_file = io.open(new_plugin_dir .. "/main.lua", "r")
    if not test_file then
        return false, "Extracted plugin directory not found"
    end
    test_file:close()
    
    -- Step 4: Backup current version
    success, error_msg = self:backupCurrentVersion()
    if not success then
        return false, "Backup failed: " .. error_msg
    end
    
    -- Step 5: Remove old plugin directory
    logger.info("BookloreSync Updater: Removing old plugin directory")
    local remove_cmd = string.format("rm -rf '%s' 2>&1", self.plugin_dir)
    local handle = io.popen(remove_cmd)
    local output = handle:read("*a")
    success = handle:close()
    
    if not success then
        logger.err("BookloreSync Updater: Failed to remove old plugin:", output)
        return false, "Failed to remove old plugin: " .. output
    end
    
    -- Step 6: Move new version to plugin location
    logger.info("BookloreSync Updater: Installing new version")
    local install_cmd = string.format("mv '%s' '%s' 2>&1", new_plugin_dir, self.plugin_dir)
    handle = io.popen(install_cmd)
    output = handle:read("*a")
    success = handle:close()
    
    if not success then
        logger.err("BookloreSync Updater: Failed to install new version:", output)
        return false, "Failed to install new version: " .. output
    end
    
    -- Step 7: Cleanup temp files
    self:cleanupTempFiles()
    
    logger.info("BookloreSync Updater: Installation completed successfully")
    return true, nil
end

--[[--
Rollback to most recent backup

@return boolean success
@return string|nil error message
--]]
function Updater:rollback()
    logger.info("BookloreSync Updater: Rolling back to previous version")
    
    -- Find most recent backup
    local list_cmd = string.format("ls -t '%s' 2>&1", self.backup_dir)
    local handle = io.popen(list_cmd)
    local output = handle:read("*a")
    handle:close()
    
    local backups = {}
    for backup in output:gmatch("[^\n]+") do
        if backup:match("^bookloresync%-") then
            table.insert(backups, backup)
        end
    end
    
    if #backups == 0 then
        return false, "No backups found"
    end
    
    local latest_backup = backups[1]
    local backup_path = self.backup_dir .. "/" .. latest_backup
    
    logger.info("BookloreSync Updater: Restoring from", backup_path)
    
    -- Remove current plugin
    os.execute(string.format("rm -rf '%s'", self.plugin_dir))
    
    -- Restore backup
    local restore_cmd = string.format("cp -r '%s' '%s' 2>&1", backup_path, self.plugin_dir)
    handle = io.popen(restore_cmd)
    output = handle:read("*a")
    local success = handle:close()
    
    if not success then
        logger.err("BookloreSync Updater: Rollback failed:", output)
        return false, "Rollback failed: " .. output
    end
    
    logger.info("BookloreSync Updater: Rollback completed successfully")
    return true, nil
end

--[[--
Cleanup temporary download files

@return boolean success
--]]
function Updater:cleanupTempFiles()
    logger.info("BookloreSync Updater: Cleaning up temp files")
    os.execute(string.format("rm -rf '%s'", self.temp_dir))
    return true
end

--[[--
Cleanup old backups, keeping only the most recent N

@param keep_count Number of backups to keep (default: 3)
@return number Number of backups deleted
--]]
function Updater:cleanupOldBackups(keep_count)
    keep_count = keep_count or self.BACKUP_KEEP_COUNT
    
    logger.info("BookloreSync Updater: Cleaning up old backups (keeping", keep_count, ")")
    
    -- List backups sorted by modification time (newest first)
    local list_cmd = string.format("ls -t '%s' 2>&1", self.backup_dir)
    local handle = io.popen(list_cmd)
    local output = handle:read("*a")
    handle:close()
    
    local backups = {}
    for backup in output:gmatch("[^\n]+") do
        if backup:match("^bookloresync%-") then
            table.insert(backups, backup)
        end
    end
    
    -- Delete old backups
    local deleted_count = 0
    for i = keep_count + 1, #backups do
        local backup_path = self.backup_dir .. "/" .. backups[i]
        logger.info("BookloreSync Updater: Deleting old backup:", backups[i])
        os.execute(string.format("rm -rf '%s'", backup_path))
        deleted_count = deleted_count + 1
    end
    
    return deleted_count
end

return Updater
