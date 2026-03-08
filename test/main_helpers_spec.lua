local stubs = require("test.helpers.stub_koreader")
local restore_stubs = stubs.install()

local BookloreSync = require("main")
restore_stubs()

describe("BookloreSync helper methods", function()
  local plugin

  before_each(function()
    plugin = setmetatable({ progress_decimal_places = 1 }, { __index = BookloreSync })
  end)

  it("maps annotation colors to expected hex values", function()
    assert.are.equal("#FFC107", plugin:colorToHex("yellow"))
    assert.are.equal("#4ADE80", plugin:colorToHex("green"))
    assert.are.equal("#38BDF8", plugin:colorToHex("BLUE"))
    assert.are.equal("#FFC107", plugin:colorToHex("unknown"))
    assert.are.equal("#FFC107", plugin:colorToHex(nil))
  end)

  it("maps drawer names to styles", function()
    assert.are.equal("highlight", plugin:drawerToStyle("lighten"))
    assert.are.equal("underline", plugin:drawerToStyle("underscore"))
    assert.are.equal("strikethrough", plugin:drawerToStyle("strikeout"))
    assert.are.equal("highlight", plugin:drawerToStyle("unknown"))
  end)

  it("formats duration values", function()
    assert.are.equal("0s", plugin:formatDuration(nil))
    assert.are.equal("59s", plugin:formatDuration(59))
    assert.are.equal("1m 30s", plugin:formatDuration(90))
    assert.are.equal("1h 1m 1s", plugin:formatDuration(3661))
  end)

  it("rounds progress using configured decimal places", function()
    plugin.progress_decimal_places = 2
    assert.are.equal(33.33, plugin:roundProgress(33.333))
    assert.are.equal(33.34, plugin:roundProgress(33.335))
  end)

  it("detects book types from file extension", function()
    assert.are.equal("EPUB", plugin:getBookType(nil))
    assert.are.equal("PDF", plugin:getBookType("/books/manual.PDF"))
    assert.are.equal("CBX", plugin:getBookType("/comics/issue.cbz"))
    assert.are.equal("EPUB", plugin:getBookType("/books/novel.mobi"))
  end)

  it("builds deterministic download filenames", function()
    assert.are.equal("BookID_5.epub", plugin:_generateFilename({ id = 5, extension = "EPUB" }))
    assert.are.equal("BookID_7.epub", plugin:_generateFilename({ id = 7 }))
  end)
end)
