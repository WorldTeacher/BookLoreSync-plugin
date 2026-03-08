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
end)
