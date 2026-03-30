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

local fallback_logger = {
    logInfo = function(_, ...) logger.info(...) end,
    logWarn = function(_, ...) logger.warn(...) end,
    logErr = function(_, ...) logger.err(...) end,
    logDbg = function(_, ...) logger.dbg(...) end,
}

local function copy_file(src_path, dst_path)
    local src_file, src_err = io.open(src_path, "rb")
    if not src_file then
        return false, src_err or "unable to open source file"
    end

    local content = src_file:read("*a")
    local read_err = nil
    if content == nil then
        read_err = "unable to read source file"
    end

    local src_close_ok, src_close_err = src_file:close()
    if not src_close_ok then
        return false, src_close_err or "unable to close source file"
    end

    if read_err then
        return false, read_err
    end

    local dst_file, dst_err = io.open(dst_path, "wb")
    if not dst_file then
        return false, dst_err or "unable to open destination file"
    end

    local write_ok, write_err = dst_file:write(content)
    local dst_close_ok, dst_close_err = dst_file:close()

    if not write_ok then
        return false, write_err or "unable to write destination file"
    end

    if not dst_close_ok then
        return false, dst_close_err or "unable to close destination file"
    end

    return true, nil
end

local Updater = {
    GITHUB_REPO = "WorldTeacher/BookLoreSync-plugin",
    GITHUB_API_BASE = "https://api.github.com",
    RELEASE_ASSET_NAME = "bookloresync.koplugin.zip",
    CACHE_DURATION = 3600,  -- 1 hour
    BACKUP_KEEP_COUNT = 3,
    HTTP_TIMEOUT = 10,
    
    plugin_dir = nil,
    backup_dir = nil,
    temp_dir = nil,
    
    db = nil,
}

---Updater:new.
function Updater:new(plugin)
    local o = {
        plugin = plugin or fallback_logger
    }
    setmetatable(o, self)
    self.__index = self
    return o
end

--[[--
Initialize updater with paths and database reference

@param plugin_dir Path to the plugin directory
@param db Database instance for caching
--]]
---Updater:init.
function Updater:init(plugin_dir, db)
    self.plugin_dir = plugin_dir
    self.db = db
    
    self.backup_dir = DataStorage:getDataDir() .. "/booklore-backups"
    
    -- Set up temp directory inside KOReader data dir (writable on all platforms including Android)
    self.temp_dir = DataStorage:getDataDir() .. "/booklore-temp-" .. tostring(os.time())
    
    self.plugin:logInfo("BookloreSync Updater: Initialized")
    self.plugin:logInfo("BookloreSync Updater: Plugin dir:", self.plugin_dir)
    self.plugin:logInfo("BookloreSync Updater: Backup dir:", self.backup_dir)
    self.plugin:logInfo("BookloreSync Updater: Temp dir:", self.temp_dir)
    
    os.execute("mkdir -p " .. self.backup_dir)
end

--[[--
Get current plugin version from plugin_version.lua

@return table Version information {version, version_type, git_commit, build_date}
--]]
---Updater:getCurrentVersion.
function Updater:getCurrentVersion()
    local version_file = self.plugin_dir .. "/plugin_version.lua"
    
    local ok, version_info = pcall(dofile, version_file)
    if not ok then
        self.plugin:logErr("BookloreSync Updater: Failed to read version file:", version_info)
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
---Updater:parseVersion.
function Updater:parseVersion(version_string)
    if not version_string then
        return nil
    end
    
    version_string = version_string:gsub("^v", "")
    
    if version_string:match("dev") then
        return {major = 0, minor = 0, patch = 0, is_dev = true}
    end
    
    local major, minor, patch = version_string:match("^(%d+)%.(%d+)%.(%d+)")
    
    if not major then
        self.plugin:logWarn("BookloreSync Updater: Invalid version format:", version_string)
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
---Updater:compareVersions.
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
    
    if v1.major < v2.major then return -1 end
    if v1.major > v2.major then return 1 end
    
    if v1.minor < v2.minor then return -1 end
    if v1.minor > v2.minor then return 1 end
    
    if v1.patch < v2.patch then return -1 end
    if v1.patch > v2.patch then return 1 end
    
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
---Updater:_makeHttpRequest.
function Updater:_makeHttpRequest(url, headers, max_redirects)
    max_redirects = max_redirects or 5
    local redirect_count = 0
    local current_url = url
    
    while redirect_count <= max_redirects do
        self.plugin:logInfo("BookloreSync Updater: HTTP GET", current_url)
        
        local response_body = {}
        local request_headers = headers or {}
        
        if not request_headers["User-Agent"] then
            request_headers["User-Agent"] = "BookloreSync-KOReader-Plugin"
        end
        
        local protocol = current_url:match("^https") and https or http
        
        protocol.TIMEOUT = self.HTTP_TIMEOUT
        
        local response, code, response_headers = protocol.request{
            url = current_url,
            method = "GET",
            headers = request_headers,
            sink = ltn12.sink.table(response_body),
        }
        
        if type(code) ~= "number" then
            local error_msg = tostring(code)
            self.plugin:logErr("BookloreSync Updater: HTTP request failed:", error_msg)
            return false, "Connection error: " .. error_msg, nil, nil
        end
        
        local response_text = table.concat(response_body)
        
        if code >= 300 and code < 400 then
            local location = response_headers and response_headers["location"]
            if not location then
                self.plugin:logErr("BookloreSync Updater: Redirect without Location header")
                return false, "Redirect without location", code, response_headers
            end
            
            if location:sub(1, 1) == "/" then
                local base_url = current_url:match("^(https?://[^/]+)")
                location = base_url .. location
            end
            
            redirect_count = redirect_count + 1
            if redirect_count > max_redirects then
                self.plugin:logErr("BookloreSync Updater: Too many redirects")
                return false, "Too many redirects", code, response_headers
            end
            
            self.plugin:logInfo("BookloreSync Updater: Following redirect to", location)
            current_url = location
        elseif code >= 200 and code < 300 then
            return true, response_text, code, response_headers
        else
            self.plugin:logErr("BookloreSync Updater: HTTP", code, "response")
            return false, response_text, code, response_headers
        end
    end
    
    -- Should never reach here
    return false, "Redirect loop", nil, nil
end

--[[--
Get latest release information from GitHub API

@return table|nil Release info {version, download_url, changelog, changelog_url, published_at, size}
@return string|nil Error message if failed
--]]
---Updater:getLatestRelease.
function Updater:getLatestRelease()
    local url = string.format("%s/repos/%s/releases/latest",
        self.GITHUB_API_BASE, self.GITHUB_REPO)
    
    local success, response, code = self:_makeHttpRequest(url)
    
    if not success then
        return nil, "Failed to fetch release info: " .. tostring(response)
    end
    
    local ok, release_data = pcall(json.decode, response)
    if not ok then
        self.plugin:logErr("BookloreSync Updater: Failed to parse JSON:", release_data)
        return nil, "Invalid response from GitHub API"
    end
    
    local version = release_data.tag_name
    if not version then
        return nil, "No tag_name in release data"
    end
    
    local download_url = nil
    local asset_size = 0
    local changelog_url = nil
    
    if release_data.assets then
        for _, asset in ipairs(release_data.assets) do
            if asset.name == self.RELEASE_ASSET_NAME then
                download_url = asset.browser_download_url
                asset_size = asset.size or 0
            elseif asset.name == "CHANGELOG.md" then
                changelog_url = asset.browser_download_url
                self.plugin:logInfo("BookloreSync Updater: Found CHANGELOG.md in release assets")
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
        changelog_url = changelog_url,
        published_at = release_data.published_at or "",
        size = asset_size
    }, nil
end

--[[--
Fetch changelog file content from URL

@param changelog_url URL to the changelog file
@return string|nil Changelog text or nil if failed
@return string|nil Error message if failed
--]]
---Updater:fetchChangelog.
function Updater:fetchChangelog(changelog_url)
    if not changelog_url then
        return nil, "No changelog URL provided"
    end
    
    self.plugin:logInfo("BookloreSync Updater: Fetching changelog from", changelog_url)
    
    local success, response, code = self:_makeHttpRequest(changelog_url)
    
    if not success then
        self.plugin:logErr("BookloreSync Updater: Failed to fetch changelog:", response)
        return nil, "Failed to fetch changelog: " .. tostring(response)
    end
    
    return response, nil
end

--[[--
Parse CHANGELOG.md content to extract section for a specific version

@param changelog_content Full CHANGELOG.md content
@param version Version to extract (e.g., "3.2.0" or "v3.2.0")
@return string|nil Extracted changelog section or nil if not found
--]]
---Updater:parseChangelogForVersion.
function Updater:parseChangelogForVersion(changelog_content, version)
    if not changelog_content or not version then
        return nil
    end
    
    local version_clean = version:gsub("^v", "")
    
    local lines = {}
    for line in changelog_content:gmatch("[^\r\n]+") do
        table.insert(lines, line)
    end
    
    local in_section = false
    local section_lines = {}
    
    for _, line in ipairs(lines) do
        if line:match("^##?%s+%[") then
            if line:match("%[" .. version_clean:gsub("%.", "%%.") .. "%]") then
                in_section = true
            else
                if in_section then
                    break
                end
            end
        elseif in_section then
            table.insert(section_lines, line)
        end
    end
    
    if #section_lines == 0 then
        self.plugin:logWarn("BookloreSync Updater: No changelog found for version", version_clean)
        return nil
    end
    
    local changelog_section = table.concat(section_lines, "\n")
    
    changelog_section = changelog_section:match("^%s*(.-)%s*$")
    
    self.plugin:logInfo("BookloreSync Updater: Extracted", #changelog_section, "bytes for version", version_clean)
    return changelog_section
end

--[[--
Clean changelog content by removing links and commit references

@param changelog_text Changelog text with markdown links
@return string Cleaned changelog text
--]]
---Updater:cleanChangelog.
function Updater:cleanChangelog(changelog_text)
    if not changelog_text then
        return ""
    end
    
    local lines = {}
    for line in changelog_text:gmatch("[^\r\n]+") do
        table.insert(lines, line)
    end
    
    local cleaned_lines = {}
    
    for _, line in ipairs(lines) do
        local cleaned_line = line
        
        cleaned_line = cleaned_line:gsub("%[([^%]]+)%]%(([^%)]+)%)", "%1")
        
        cleaned_line = cleaned_line:gsub("%s*%(%[?[a-f0-9]+%]?%)%s*", " ")
        
        cleaned_line = cleaned_line:gsub("https?://[^%s]+", "")
        
        cleaned_line = cleaned_line:gsub("%s+", " ")
        
        cleaned_line = cleaned_line:match("^%s*(.-)%s*$")
        
        if cleaned_line ~= "" then
            table.insert(cleaned_lines, cleaned_line)
        end
    end
    
    return table.concat(cleaned_lines, "\n")
end

--[[--
Get cached release information from database

@return table|nil Cached release info or nil if expired/not found
--]]
---Updater:getCachedReleaseInfo.
function Updater:getCachedReleaseInfo()
    if not self.db then
        return nil
    end
    
    local cached_json = self.db:getUpdaterCache("latest_release")
    if not cached_json then
        return nil
    end
    
    local ok, release_info = pcall(json.decode, cached_json)
    if not ok then
        self.plugin:logWarn("BookloreSync Updater: Failed to parse cached release info")
        return nil
    end
    
    self.plugin:logInfo("BookloreSync Updater: Using cached release info")
    return release_info
end

--[[--
Cache release information in database

@param release_info Release information table
@return boolean success
--]]
---Updater:cacheReleaseInfo.
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
---Updater:clearCache.
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
---Updater:checkForUpdates.
function Updater:checkForUpdates(use_cache)
    self.plugin:logInfo("BookloreSync Updater: Checking for updates (use_cache=" .. tostring(use_cache) .. ")")
    
    local current_info = self:getCurrentVersion()
    local current_version = current_info.version
    
    local release_info, error_msg
    
    if use_cache then
        release_info = self:getCachedReleaseInfo()
    end
    
    if not release_info then
        release_info, error_msg = self:getLatestRelease()
        if not release_info then
            self.plugin:logErr("BookloreSync Updater: Failed to get latest release:", error_msg)
            return nil
        end
        
        self:cacheReleaseInfo(release_info)
    end
    
    local current_parsed = self:parseVersion(current_version)
    local latest_parsed = self:parseVersion(release_info.version)
    
    if not current_parsed or not latest_parsed then
        self.plugin:logErr("BookloreSync Updater: Failed to parse versions")
        return nil
    end
    
    local comparison = self:compareVersions(current_parsed, latest_parsed)
    local update_available = comparison < 0
    
    self.plugin:logInfo("BookloreSync Updater: Current version:", current_version)
    self.plugin:logInfo("BookloreSync Updater: Latest version:", release_info.version)
    self.plugin:logInfo("BookloreSync Updater: Update available:", update_available)
    
    return {
        available = update_available,
        current_version = current_version,
        latest_version = release_info.version,
        release_info = release_info
    }
end

--[[--
Probe a direct download endpoint with HEAD and follow redirects.

@param url string
@param max_redirects number|nil
@return boolean success
@return string|nil final_url_or_error
@return number|nil content_length
@return number|nil http_status
--]]
---Updater:_headRequest.
function Updater:_headRequest(url, max_redirects)
    local final_url = url
    max_redirects = max_redirects or 5
    local redirect_count = 0

    while redirect_count <= max_redirects do
        local protocol = final_url:match("^https") and https or http
        protocol.TIMEOUT = self.HTTP_TIMEOUT

        local response_body = {}
        local response, code, response_headers = protocol.request{
            url = final_url,
            method = "HEAD",
            headers = {
                ["User-Agent"] = "BookloreSync-KOReader-Plugin"
            },
            sink = ltn12.sink.table(response_body),
        }

        if type(code) ~= "number" then
            return false, tostring(code), nil, nil
        end

        if code >= 300 and code < 400 then
            local location = response_headers and response_headers["location"]
            if not location then
                return false, "Redirect without location", nil, code
            end

            if location:sub(1, 1) == "/" then
                local base_url = final_url:match("^(https?://[^/]+)")
                location = base_url .. location
            end

            redirect_count = redirect_count + 1
            if redirect_count > max_redirects then
                return false, "Too many redirects", nil, code
            end

            self.plugin:logInfo("BookloreSync Updater: Following redirect to", location)
            final_url = location
        elseif code >= 200 and code < 300 then
            local cl = response_headers and (response_headers["content-length"] or response_headers["Content-Length"])
            local content_length = tonumber(cl) or 0
            return true, final_url, content_length, code
        else
            return false, "HTTP " .. tostring(code), nil, code
        end
    end

    return false, "Redirect loop", nil, nil
end

--[[--
Build an update result for a direct download endpoint.

This mode is intended for development build feeds where a stable semantic
version comparison is not meaningful. The endpoint URL is treated as an
installable update source whenever it is reachable.

@param download_url string URL that returns a ZIP when downloaded
@return table|nil {available, current_version, latest_version, release_info}
--]]
---Updater:checkForDirectDownload.
function Updater:checkForDirectDownload(download_url)
    self.plugin:logInfo("BookloreSync Updater: Checking direct download URL")

    local current_info = self:getCurrentVersion()
    local current_version = current_info.version

    if not download_url or download_url == "" then
        self.plugin:logErr("BookloreSync Updater: Direct download URL is empty")
        return nil
    end

    -- Validate endpoint reachability with HEAD to avoid downloading the ZIP
    -- during update checks.
    local success, final_url_or_error, content_length, code = self:_headRequest(download_url, 5)
    if not success then
        self.plugin:logErr("BookloreSync Updater: Direct download endpoint check failed:", tostring(final_url_or_error))
        return nil
    end

    local final_url = final_url_or_error
    self.plugin:logInfo("BookloreSync Updater: Direct endpoint reachable, status:", code, "bytes:", content_length)

    local release_info = {
        version = "dev-build",
        download_url = final_url,
        changelog = "",
        changelog_url = nil,
        published_at = "",
        size = content_length,
        channel = "dev",
    }

    return {
        available = true,
        current_version = current_version,
        latest_version = "dev-build",
        release_info = release_info,
    }
end

--[[--
Format bytes as human-readable size

@param bytes Number of bytes
@return string Formatted size (e.g., "35.6 KB", "1.2 MB")
--]]
---Updater:formatBytes.
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
---Updater:downloadUpdate.
function Updater:downloadUpdate(url, progress_callback)
    self.plugin:logInfo("BookloreSync Updater: Downloading from", url)
    
    os.execute("mkdir -p " .. self.temp_dir)
    
    local zip_path = self.temp_dir .. "/download.zip"
    
    -- Follow redirects manually to get final URL
    local final_url = url
    local max_redirects = 5
    local redirect_count = 0
    
    while redirect_count <= max_redirects do
        self.plugin:logInfo("BookloreSync Updater: Checking URL", final_url)
        
        local protocol = final_url:match("^https") and https or http
        protocol.TIMEOUT = 60  -- Longer timeout for downloads
        
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
        
        if code >= 300 and code < 400 then
            local location = response_headers and response_headers["location"]
            if not location then
                return false, "Redirect without location"
            end
            
            if location:sub(1, 1) == "/" then
                local base_url = final_url:match("^(https?://[^/]+)")
                location = base_url .. location
            end
            
            redirect_count = redirect_count + 1
            if redirect_count > max_redirects then
                return false, "Too many redirects"
            end
            
            self.plugin:logInfo("BookloreSync Updater: Following redirect to", location)
            final_url = location
        elseif code >= 200 and code < 300 then
            break
        else
            return false, "HTTP error: " .. tostring(code)
        end
    end
    
    -- Now download from final URL
    self.plugin:logInfo("BookloreSync Updater: Downloading from final URL", final_url)
    
    local file = io.open(zip_path, "wb")
    if not file then
        return false, "Failed to create download file"
    end
    
    local bytes_downloaded = 0
    local total_bytes = 0
    
    ---progress_sink.
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
    
    local protocol = final_url:match("^https") and https or http
    protocol.TIMEOUT = 60
    
    local response, code, response_headers = protocol.request{
        url = final_url,
        method = "GET",
        sink = progress_sink,
        headers = {
            ["User-Agent"] = "BookloreSync-KOReader-Plugin"
        }
    }
    
    file:close()
    
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
            self.plugin:logInfo("BookloreSync Updater: Downloaded", attr.size, "bytes")
        end
    else
        self.plugin:logDbg("BookloreSync Updater: Download complete (file size unavailable)")
    end
    
    return true, zip_path
end

--[[--
Validate ZIP file structure

@param zip_path Path to ZIP file
@return boolean valid
@return string|nil error message
--]]
---Updater:_validateZipStructure.
function Updater:_validateZipStructure(zip_path)
    self.plugin:logInfo("BookloreSync Updater: Validating ZIP structure")
    
    local list_cmd = string.format("unzip -l '%s' 2>&1", zip_path)
    local handle = io.popen(list_cmd)
    local output = handle:read("*a")
    handle:close()
    
    local has_main = output:match("bookloresync%.koplugin/main%.lua")
    local has_meta = output:match("bookloresync%.koplugin/_meta%.lua")
    
    if not has_main then
        return false, "Invalid ZIP: missing main.lua"
    end
    
    if not has_meta then
        return false, "Invalid ZIP: missing _meta.lua"
    end
    
    self.plugin:logInfo("BookloreSync Updater: ZIP structure is valid")
    return true, nil
end

--[[--
Extract ZIP file to destination directory

@param zip_path Path to ZIP file
@param dest_dir Destination directory
@return boolean success
@return string|nil error message
--]]
---Updater:_extractZip.
function Updater:_extractZip(zip_path, dest_dir)
    self.plugin:logInfo("BookloreSync Updater: Extracting to", dest_dir)
    
    os.execute("mkdir -p " .. dest_dir)
    
    local extract_cmd = string.format("unzip -q -o '%s' -d '%s' 2>&1", zip_path, dest_dir)
    local handle = io.popen(extract_cmd)
    local output = handle:read("*a")
    local success = handle:close()
    
    if not success then
        self.plugin:logErr("BookloreSync Updater: Extraction failed:", output)
        return false, "Failed to extract ZIP: " .. output
    end
    
    return true, nil
end

--[[--
Backup current plugin version

@return boolean success
@return string backup_path or error message
--]]
---Updater:backupCurrentVersion.
function Updater:backupCurrentVersion()
    local current_info = self:getCurrentVersion()
    local timestamp = os.date("%Y%m%d-%H%M%S")
    local backup_name = string.format("bookloresync-%s-%s", current_info.version, timestamp)
    local backup_path = self.backup_dir .. "/" .. backup_name
    
    self.plugin:logInfo("BookloreSync Updater: Backing up to", backup_path)
    
    local backup_cmd = string.format("cp -r '%s' '%s' 2>&1", self.plugin_dir, backup_path)
    local handle = io.popen(backup_cmd)
    local output = handle:read("*a")
    local success = handle:close()
    
    if not success then
        self.plugin:logErr("BookloreSync Updater: Backup failed:", output)
        return false, "Backup failed: " .. output
    end
    
    self.plugin:logInfo("BookloreSync Updater: Backup created successfully")
    
    self:cleanupOldBackups(self.BACKUP_KEEP_COUNT)
    
    return true, backup_path
end

--[[--
Preserve user-specific files before replacing plugin directory

@return boolean success
@return table|string List of preserved filenames or error message
--]]
---Updater:_preserveUserFiles.
function Updater:_preserveUserFiles()
    local files_to_preserve = {
        "hardcover.token",
        "dev-build.location",
    }

    local preserved_dir = self.temp_dir .. "/preserved-user-files"
    os.execute(string.format("mkdir -p '%s'", preserved_dir))

    local preserved_files = {}

    for _, filename in ipairs(files_to_preserve) do
        local source_path = self.plugin_dir .. "/" .. filename
        local source_file = io.open(source_path, "r")
        if source_file then
            source_file:close()

            local dest_path = preserved_dir .. "/" .. filename
            local success, copy_err = copy_file(source_path, dest_path)

            if not success then
                self.plugin:logErr("BookloreSync Updater: Failed to preserve", filename, copy_err)
                return false, "Failed to preserve " .. filename .. ": " .. tostring(copy_err)
            end

            table.insert(preserved_files, filename)
            self.plugin:logInfo("BookloreSync Updater: Preserved", filename)
        end
    end

    return true, preserved_files
end

--[[--
Restore preserved user-specific files after installing new plugin version

@param preserved_files table List of filenames to restore
@return boolean success
@return string|nil error message
--]]
---Updater:_restoreUserFiles.
function Updater:_restoreUserFiles(preserved_files)
    if not preserved_files or #preserved_files == 0 then
        return true, nil
    end

    local preserved_dir = self.temp_dir .. "/preserved-user-files"

    for _, filename in ipairs(preserved_files) do
        local source_path = preserved_dir .. "/" .. filename
        local dest_path = self.plugin_dir .. "/" .. filename

        local success, copy_err = copy_file(source_path, dest_path)
        if not success then
            self.plugin:logErr("BookloreSync Updater: Failed to restore", filename, copy_err)
            return false, "Failed to restore " .. filename .. ": " .. tostring(copy_err)
        end

        local remove_ok, remove_err = os.remove(source_path)
        if not remove_ok then
            self.plugin:logErr("BookloreSync Updater: Failed to remove preserved source", filename, remove_err)
            return false, "Failed to restore " .. filename .. ": " .. tostring(remove_err)
        end

        self.plugin:logInfo("BookloreSync Updater: Restored", filename)
    end

    return true, nil
end

--[[--
Install update from ZIP file (atomic operation)

@param zip_path Path to downloaded ZIP file
@return boolean success
@return string|nil error message
--]]
---Updater:installUpdate.
function Updater:installUpdate(zip_path)
    self.plugin:logInfo("BookloreSync Updater: Installing update from", zip_path)
    local preserved_files = nil
    
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

    -- Step 5: Preserve user-specific files that should survive directory replacement
    success, preserved_files = self:_preserveUserFiles()
    if not success then
        return false, preserved_files
    end
    
    -- Step 6: Remove old plugin directory
    self.plugin:logInfo("BookloreSync Updater: Removing old plugin directory")
    local remove_cmd = string.format("rm -rf '%s' 2>&1", self.plugin_dir)
    local handle = io.popen(remove_cmd)
    local output = handle:read("*a")
    success = handle:close()
    
    if not success then
        self.plugin:logErr("BookloreSync Updater: Failed to remove old plugin:", output)
        return false, "Failed to remove old plugin: " .. output
    end
    
    -- Step 7: Move new version to plugin location
    self.plugin:logInfo("BookloreSync Updater: Installing new version")
    local install_cmd = string.format("mv '%s' '%s' 2>&1", new_plugin_dir, self.plugin_dir)
    handle = io.popen(install_cmd)
    output = handle:read("*a")
    success = handle:close()
    
    if not success then
        self.plugin:logErr("BookloreSync Updater: Failed to install new version:", output)
        return false, "Failed to install new version: " .. output
    end

    -- Step 8: Restore preserved user-specific files into fresh plugin directory
    success, error_msg = self:_restoreUserFiles(preserved_files)
    if not success then
        return false, error_msg
    end
    
    -- Step 9: Cleanup temp files
    self:cleanupTempFiles()
    
    self.plugin:logInfo("BookloreSync Updater: Installation completed successfully")
    return true, nil
end

--[[--
Rollback to most recent backup

@return boolean success
@return string|nil error message
--]]
---Updater:rollback.
function Updater:rollback()
    self.plugin:logInfo("BookloreSync Updater: Rolling back to previous version")
    
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
    
    self.plugin:logInfo("BookloreSync Updater: Restoring from", backup_path)
    
    os.execute(string.format("rm -rf '%s'", self.plugin_dir))
    
    local restore_cmd = string.format("cp -r '%s' '%s' 2>&1", backup_path, self.plugin_dir)
    handle = io.popen(restore_cmd)
    output = handle:read("*a")
    local success = handle:close()
    
    if not success then
        self.plugin:logErr("BookloreSync Updater: Rollback failed:", output)
        return false, "Rollback failed: " .. output
    end
    
    self.plugin:logInfo("BookloreSync Updater: Rollback completed successfully")
    return true, nil
end

--[[--
Cleanup temporary download files

@return boolean success
--]]
---Updater:cleanupTempFiles.
function Updater:cleanupTempFiles()
    self.plugin:logInfo("BookloreSync Updater: Cleaning up temp files")
    os.execute(string.format("rm -rf '%s'", self.temp_dir))
    return true
end

--[[--
Cleanup old backups, keeping only the most recent N

@param keep_count Number of backups to keep (default: 3)
@return number Number of backups deleted
--]]
---Updater:cleanupOldBackups.
function Updater:cleanupOldBackups(keep_count)
    keep_count = keep_count or self.BACKUP_KEEP_COUNT
    
    self.plugin:logInfo("BookloreSync Updater: Cleaning up old backups (keeping", keep_count, ")")
    
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
    
    local deleted_count = 0
    for i = keep_count + 1, #backups do
        local backup_path = self.backup_dir .. "/" .. backups[i]
        self.plugin:logInfo("BookloreSync Updater: Deleting old backup:", backups[i])
        os.execute(string.format("rm -rf '%s'", backup_path))
        deleted_count = deleted_count + 1
    end
    
    return deleted_count
end

return Updater
