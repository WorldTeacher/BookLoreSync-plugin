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

package.loaded["booklore_file_logger"] = nil
package.preload["booklore_file_logger"] = nil

local FileLogger = require("booklore_file_logger")

describe("FileLogger", function()
  local logger
  local temp_dir

  before_each(function()
    logger = FileLogger:new()
    temp_dir = "/tmp/booklore-test-logs"
    os.execute("rm -rf " .. temp_dir)
    os.execute("mkdir -p " .. temp_dir)
    logger.log_dir = temp_dir
    logger.max_files = 2
  end)

  after_each(function()
    logger:close()
    os.execute("rm -rf " .. temp_dir)
  end)

  it("builds log path from date", function()
    assert.are.equal(temp_dir .. "/booklore-2026-03-08.log", logger:getLogFilePath("2026-03-08"))
  end)

  it("writes log entries", function()
    local ok = logger:write("INFO", "hello", "world")
    assert.is_true(ok)

    local path = logger:getLogFilePath(logger.current_date)
    local f = io.open(path, "r")
    assert.is_not_nil(f)
    local content = f:read("*a")
    f:close()

    assert.is_truthy(content:find("Booklore Sync Log", 1, true))
    assert.is_truthy(content:find("hello world", 1, true))
  end)

  it("rotates old logs based on max_files", function()
    local f1 = io.open(temp_dir .. "/booklore-2026-03-01.log", "w"); f1:write("a"); f1:close()
    local f2 = io.open(temp_dir .. "/booklore-2026-03-02.log", "w"); f2:write("a"); f2:close()
    local f3 = io.open(temp_dir .. "/booklore-2026-03-03.log", "w"); f3:write("a"); f3:close()

    local ok = logger:rotateLogs()
    assert.is_true(ok)

    local files = logger:getLogFiles()
    assert.are.equal(2, #files)
    assert.is_truthy(files[1]:find("2026-03-03", 1, true))
    assert.is_truthy(files[2]:find("2026-03-02", 1, true))
  end)

  it("getCurrentDate returns YYYY-MM-DD format", function()
    local d = logger:getCurrentDate()
    assert.is.string(d)
    assert.is_truthy(d:match("^%d%d%d%d%-%d%d%-%d%d$") ~= nil)
  end)

  it("getLogFilePath defaults to today when no date given", function()
    local path = logger:getLogFilePath()
    local today = os.date("%Y-%m-%d")
    assert.are.equal(temp_dir .. "/booklore-" .. today .. ".log", path)
  end)

  it("getCurrentLogSize returns 0 for non-existent file", function()
    assert.are.equal(0, logger:getCurrentLogSize())
  end)

  it("getCurrentLogSize returns byte count after write", function()
    logger:write("INFO", "test")
    local size = logger:getCurrentLogSize()
    assert.is.truthy(size > 0)
  end)

  it("write returns false when logger not initialized (no log_dir)", function()
    local bare = FileLogger:new()
    local ok = bare:write("INFO", "test")
    assert.is_false(ok)
  end)

  it("write with multiple arguments joins them with spaces", function()
    logger:write("INFO", "hello", "world")
    local path = logger:getLogFilePath(logger.current_date)
    local f = io.open(path, "r")
    local content = f:read("*a")
    f:close()
    assert.is_truthy(content:find("hello world", 1, true))
  end)

  it("write handles nil argument gracefully", function()
    local ok = logger:write("INFO", nil)
    assert.is_true(ok)
  end)

  it("write produces properly formatted timestamp", function()
    logger:write("DEBUG", "test")
    local path = logger:getLogFilePath(logger.current_date)
    local f = io.open(path, "r")
    local content = f:read("*a")
    f:close()
    -- Should contain a timestamp in brackets followed by [DEBUG] test
    local has_timestamp = content:find("%[%d%d%d%d%-%d%d%-%d%d %d%d:%d%d:%d%d%]", 1, true) ~= nil
    local has_level = content:find("[DEBUG]", 1, true) ~= nil
    local has_msg = content:find("test", 1, true) ~= nil
    assert.is_truthy(has_timestamp or has_level)
    assert.is_truthy(has_msg)
  end)

  it("getLogFiles returns empty table when no log files exist", function()
    local files = logger:getLogFiles()
    assert.is_table(files)
    assert.are.equal(0, #files)
  end)

  it("_listLogFiles only matches booklore-YYYY-MM-DD.log pattern", function()
    -- Create files that should NOT match
    local bad1 = io.open(temp_dir .. "/booklore-2026-03-01.txt", "w"); bad1:close()
    local bad2 = io.open(temp_dir .. "/other-2026-03-01.log", "w"); bad2:close()
    local bad3 = io.open(temp_dir .. "/booklore-2026-0301.log", "w"); bad3:close()

    local files = logger:getLogFiles()
    -- None of the malformed files should match the log pattern
    for _, f in ipairs(files) do
      assert.is_truthy(f:find(".txt") == nil)
      assert.is_truthy(f:find("other-") == nil)
    end

    os.remove(temp_dir .. "/booklore-2026-03-01.txt")
    os.remove(temp_dir .. "/other-2026-03-01.log")
    os.remove(temp_dir .. "/booklore-2026-0301.log")
  end)

  it("rotateLogs does nothing when files <= max_files", function()
    local f1 = io.open(temp_dir .. "/booklore-2026-03-01.log", "w"); f1:close()
    local files_before = logger:getLogFiles()
    local ok = logger:rotateLogs()
    assert.is_true(ok)
    local files_after = logger:getLogFiles()
    assert.are.equal(#files_before, #files_after)
    os.remove(temp_dir .. "/booklore-2026-03-01.log")
  end)

  it("clearAllLogs removes all log files", function()
    local f1 = io.open(temp_dir .. "/booklore-2026-03-01.log", "w"); f1:close()
    local f2 = io.open(temp_dir .. "/booklore-2026-03-02.log", "w"); f2:close()
    local ok = logger:clearAllLogs()
    assert.is_true(ok)
    local files = logger:getLogFiles()
    assert.are.equal(0, #files)
  end)

  it("clearAllLogs returns false when log_dir not set", function()
    local bare = FileLogger:new()
    assert.is_false(bare:clearAllLogs())
  end)

  it("close is safe to call when no file open", function()
    local bare = FileLogger:new()
    bare.log_dir = temp_dir
    bare:close()  -- should not error
  end)

  it("close clears current_log_file handle", function()
    logger:write("INFO", "test")
    assert.is_not_nil(logger.current_log_file)
    logger:close()
    assert.is_nil(logger.current_log_file)
  end)
end)
