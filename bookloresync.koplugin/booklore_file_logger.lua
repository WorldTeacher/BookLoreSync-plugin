--[[--
Booklore File Logger Module

Provides file-based logging with daily rotation and automatic cleanup.
Keeps the last 3 log files.

@module koplugin.BookloreSync.file_logger
--]]--

local DataStorage = require("datastorage")
local logger = require("logger")

local FileLogger = {
    log_dir = nil,
    current_log_file = nil,
    current_date = nil,
    max_files = 3,
}

function FileLogger:new(o)
    o = o or {}
    setmetatable(o, self)
    self.__index = self
    return o
end

--[[--
Initialize the file logger

Creates the log directory if it doesn't exist and sets up daily rotation.

@return boolean success
--]]
function FileLogger:init()
    -- Set log directory to plugin directory
    self.log_dir = DataStorage:getDataDir() .. "/plugins/bookloresync.koplugin/logs"
    
    -- Create logs directory if it doesn't exist
    local mkdir_cmd = "mkdir -p " .. self.log_dir
    os.execute(mkdir_cmd)
    
    -- Check if directory was created successfully
    local test_file = io.open(self.log_dir .. "/.test", "w")
    if not test_file then
        logger.err("BookloreSync FileLogger: Failed to create log directory:", self.log_dir)
        return false
    end
    test_file:close()
    os.remove(self.log_dir .. "/.test")
    
    logger.info("BookloreSync FileLogger: Initialized, log directory:", self.log_dir)
    return true
end

--[[--
Get the current date string for log filenames

@return string Date in YYYY-MM-DD format
--]]
function FileLogger:getCurrentDate()
    return os.date("%Y-%m-%d")
end

--[[--
Get the log filename for a specific date

@param date string Date in YYYY-MM-DD format (optional, defaults to today)
@return string Full path to log file
--]]
function FileLogger:getLogFilePath(date)
    date = date or self:getCurrentDate()
    return self.log_dir .. "/booklore-" .. date .. ".log"
end

--[[--
Rotate old log files, keeping only the last N files

@return boolean success
--]]
function FileLogger:rotateLogs()
    -- Get all log files in the directory
    local log_files = {}
    local find_cmd = "find " .. self.log_dir .. " -name 'booklore-*.log' -type f | sort -r"
    local handle = io.popen(find_cmd)
    
    if not handle then
        logger.warn("BookloreSync FileLogger: Failed to list log files for rotation")
        return false
    end
    
    for file in handle:lines() do
        table.insert(log_files, file)
    end
    handle:close()
    
    -- Delete files beyond max_files
    if #log_files > self.max_files then
        logger.info("BookloreSync FileLogger: Rotating logs, found", #log_files, "files, keeping", self.max_files)
        
        for i = self.max_files + 1, #log_files do
            local deleted = os.remove(log_files[i])
            if deleted then
                logger.info("BookloreSync FileLogger: Deleted old log file:", log_files[i])
            else
                logger.warn("BookloreSync FileLogger: Failed to delete log file:", log_files[i])
            end
        end
    end
    
    return true
end

--[[--
Write a log entry to the current log file

Creates a new log file if the date has changed, and rotates old files.

@param level string Log level (INFO, WARN, ERROR, DEBUG)
@param ... Additional arguments to log
@return boolean success
--]]
function FileLogger:write(level, ...)
    if not self.log_dir then
        logger.warn("BookloreSync FileLogger: Logger not initialized, call init() first")
        return false
    end
    
    local current_date = self:getCurrentDate()
    
    -- Check if we need to create a new log file (date changed)
    if current_date ~= self.current_date then
        -- Close the current log file if open
        if self.current_log_file then
            self.current_log_file:close()
            self.current_log_file = nil
        end
        
        self.current_date = current_date
        
        -- Rotate old logs
        self:rotateLogs()
    end
    
    -- Open log file if not already open
    if not self.current_log_file then
        local log_path = self:getLogFilePath(current_date)
        self.current_log_file = io.open(log_path, "a")
        
        if not self.current_log_file then
            logger.err("BookloreSync FileLogger: Failed to open log file:", log_path)
            return false
        end
        
        -- Write header for new file
        self.current_log_file:write("=== Booklore Sync Log - " .. current_date .. " ===\n")
        self.current_log_file:flush()
    end
    
    -- Format the log message
    local timestamp = os.date("%Y-%m-%d %H:%M:%S")
    local args = {...}
    local message_parts = {}
    
    for i = 1, #args do
        table.insert(message_parts, tostring(args[i]))
    end
    
    local message = table.concat(message_parts, " ")
    local log_entry = string.format("[%s] [%s] %s\n", timestamp, level, message)
    
    -- Write to file
    self.current_log_file:write(log_entry)
    self.current_log_file:flush()
    
    return true
end

--[[--
Close the current log file

Should be called when the plugin is exiting.
--]]
function FileLogger:close()
    if self.current_log_file then
        self.current_log_file:close()
        self.current_log_file = nil
        logger.info("BookloreSync FileLogger: Closed log file")
    end
end

--[[--
Get the list of existing log files

@return table Array of log file paths (sorted newest first)
--]]
function FileLogger:getLogFiles()
    local log_files = {}
    local find_cmd = "find " .. self.log_dir .. " -name 'booklore-*.log' -type f | sort -r"
    local handle = io.popen(find_cmd)
    
    if not handle then
        return log_files
    end
    
    for file in handle:lines() do
        table.insert(log_files, file)
    end
    handle:close()
    
    return log_files
end

--[[--
Get the size of the current log file

@return number Size in bytes, or 0 if file doesn't exist
--]]
function FileLogger:getCurrentLogSize()
    if not self.log_dir then
        return 0
    end
    
    local log_path = self:getLogFilePath()
    local file = io.open(log_path, "r")
    
    if not file then
        return 0
    end
    
    local size = file:seek("end")
    file:close()
    
    return size or 0
end

--[[--
Clear all log files

@return boolean success
--]]
function FileLogger:clearAllLogs()
    if not self.log_dir then
        return false
    end
    
    -- Close current log file first
    if self.current_log_file then
        self.current_log_file:close()
        self.current_log_file = nil
    end
    
    local log_files = self:getLogFiles()
    
    for _, file in ipairs(log_files) do
        local deleted = os.remove(file)
        if deleted then
            logger.info("BookloreSync FileLogger: Deleted log file:", file)
        end
    end
    
    self.current_date = nil
    
    return true
end

return FileLogger
