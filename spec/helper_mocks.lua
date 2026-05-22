-- Minimal KOReader mocks for testing booklore_database.lua

-- logger
package.preload["logger"] = function()
    return {
        info = function() end,
        warn = function() end,
        err = function() end,
        dbg = function() end,
    }
end

-- datastorage
package.preload["datastorage"] = function()
    return {
        getSettingsDir = function() return "/tmp/test-booklore-settings" end
    }
end

-- luasettings
package.preload["luasettings"] = function()
    local LuaSettings = {}
    function LuaSettings:open(path)
        return {
            readSetting = function(_, key) return nil end,
            saveSetting = function() end,
            flush = function() end,
            close = function() end,
        }
    end
    return LuaSettings
end

-- ffi/sha2 — stub (tests don't require real hashing)
package.preload["ffi/sha2"] = function()
    return {
        md5 = function(data)
            return "mock_md5_" .. #data
        end
    }
end
