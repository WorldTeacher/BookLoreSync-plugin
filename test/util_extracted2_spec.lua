package.path = table.concat({
  "bookloresync.koplugin/?.lua",
  "bookloresync.koplugin/?/init.lua",
  package.path,
}, ";")

package.preload["logger"] = function()
  return { info = function() end, warn = function() end, err = function() end, dbg = function() end }
end
package.preload["ffi/sha2"] = function() return { md5 = function(s) return "deadbeef" end } end

describe("Util.stableSerializeValue", function()
    it("returns empty string for nil", function()
        local util = require("booklore_util")
        assert.are.equal("", util.stableSerializeValue(nil))
    end)
    it("serializes booleans", function()
        local util = require("booklore_util")
        assert.are.equal("true", util.stableSerializeValue(true))
        assert.are.equal("false", util.stableSerializeValue(false))
    end)
    it("serializes numbers", function()
        local util = require("booklore_util")
        assert.are.equal("42", util.stableSerializeValue(42))
        assert.are.equal("3.14", util.stableSerializeValue(3.14))
    end)
    it("serializes strings", function()
        local util = require("booklore_util")
        assert.are.equal("hello", util.stableSerializeValue("hello"))
    end)
    it("serializes tables stably", function()
        local util = require("booklore_util")
        local result = util.stableSerializeValue({b=2, a=1})
        assert.are.equal("{a=1,b=2}", result)
    end)
    it("serializes nested tables", function()
        local util = require("booklore_util")
        local result = util.stableSerializeValue({x={y=1}, z=2})
        assert.is.truthy(result:match("^%{"))
        assert.is.truthy(result:match("%}$"))
    end)
end)

