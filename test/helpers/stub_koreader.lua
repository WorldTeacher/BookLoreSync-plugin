local STUB_KEYS = {
  "logger",
  "datastorage",
  "dispatcher",
  "apps/filemanager/filemanager",
  "ui/widget/eventlistener",
  "ui/widget/infomessage",
  "ui/widget/inputdialog",
  "luasettings",
  "ui/network/manager",
  "ui/uimanager",
  "ui/widget/container/widgetcontainer",
  "ui/widget/confirmbox",
  "ui/widget/buttondialog",
  "ui/widget/menu",
  "json",
  "booklore_settings",
  "booklore_database",
  "booklore_api_client",
  "hardcover_api_client",
  "booklore_updater",
  "booklore_file_logger",
  "booklore_metadata_extractor",
  "gettext",
  "ffi/util",
  "ui/trapper",
}

local function install()
  local original = {}
  for _, k in ipairs(STUB_KEYS) do
    original[k] = package.preload[k]
  end

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

  package.preload["datastorage"] = function()
    return {
      getSettingsDir = function() return "/tmp" end,
      getDataDir = function() return "/tmp" end,
    }
  end

  package.preload["dispatcher"] = function()
    return { registerAction = function() end }
  end

  package.preload["apps/filemanager/filemanager"] = function()
    return { instance = nil }
  end

  package.preload["ui/widget/eventlistener"] = function()
    return {}
  end

  package.preload["ui/widget/infomessage"] = function()
    return { new = function(_, o) return o or {} end }
  end

  package.preload["ui/widget/inputdialog"] = function()
    return { new = function(_, o) return o or {} end }
  end

  package.preload["luasettings"] = function()
    return { open = function() return { readSetting = function() return nil end } end }
  end

  package.preload["ui/network/manager"] = function()
    return { isOnline = function() return false end }
  end

  package.preload["ui/uimanager"] = function()
    return {
      scheduleIn = function(_, _, fn) if fn then fn() end end,
      nextTick = function(_, fn) if fn then fn() end end,
      show = function() end,
      close = function() end,
    }
  end

  package.preload["ui/widget/container/widgetcontainer"] = function()
    local WidgetContainer = {}
    function WidgetContainer:extend(o)
      o = o or {}
      o.__index = o
      setmetatable(o, self)
      self.__index = self
      return o
    end
    return WidgetContainer
  end

  package.preload["ui/widget/confirmbox"] = function()
    return { new = function(_, o) return o or {} end }
  end

  package.preload["ui/widget/buttondialog"] = function()
    return { new = function(_, o) return o or {} end }
  end

  package.preload["ui/widget/menu"] = function()
    return { new = function(_, o) return o or {} end }
  end

  package.preload["json"] = function()
    return {
      encode = function() return "{}" end,
      decode = function() return {} end,
    }
  end

  package.preload["booklore_settings"] = function()
    return { new = function() return {} end }
  end

  package.preload["booklore_database"] = function()
    return { new = function() return {} end }
  end

  package.preload["booklore_api_client"] = function()
    return { new = function() return {} end }
  end

  package.preload["hardcover_api_client"] = function()
    return { new = function() return {} end }
  end

  package.preload["booklore_updater"] = function()
    return { new = function() return {} end }
  end

  package.preload["booklore_file_logger"] = function()
    return { new = function() return {} end }
  end

  package.preload["booklore_metadata_extractor"] = function()
    return { new = function() return {} end }
  end

  package.preload["gettext"] = function()
    return function(s) return s end
  end

  package.preload["ffi/util"] = function()
    return { template = function(fmt, ...)
      local args = { ... }
      return (fmt:gsub("%%(%d+)", function(idx)
        return tostring(args[tonumber(idx)] or "")
      end))
    end }
  end

  -- Minimal Trapper stub: runs everything synchronously on the test thread.
  -- wrap() calls the coroutine directly; dismissableRunInSubprocess() calls
  -- the worker inline and returns its result (no fork, no UIManager needed).
  package.preload["ui/trapper"] = function()
    return {
      wrap = function(_, fn)
        local co = coroutine.create(fn)
        local ok, err = coroutine.resume(co)
        if not ok then error(err) end
      end,
      info = function() end,
      -- Returns (completed, result) matching Trapper's real API contract:
      --   completed=false  → user dismissed (cancelled)
      --   completed=true, result=nil → subprocess crashed with no output
      --   completed=true, result=<table> → success
      dismissableRunInSubprocess = function(_, worker_fn, _)
        local ok, result = pcall(worker_fn)
        if not ok then
          -- Subprocess "crashed" — return completed=true, result=nil
          return true, nil
        end
        return true, result
      end,
    }
  end

  return function()
    for _, k in ipairs(STUB_KEYS) do
      package.preload[k] = original[k]
    end
  end
end

return {
  install = install,
}
