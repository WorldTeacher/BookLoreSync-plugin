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
    -- Fallback (no title): BookID_{id}.ext - ID already embedded, no extra tag
    assert.are.equal("BookID_5.epub", plugin:_generateFilename({ id = 5, extension = "EPUB" }))
    assert.are.equal("BookID_7.epub", plugin:_generateFilename({ id = 7 }))
    -- Title present: "{safe_title}_{id}.ext"
    assert.are.equal("My Book_3.epub",  plugin:_generateFilename({ id = 3, title = "My Book",  extension = "epub" }))
    assert.are.equal("The Hobbit_42.epub", plugin:_generateFilename({ id = 42, title = "The Hobbit", extension = "epub" }))
    -- Title with filesystem-unsafe chars is sanitized before appending _id
    assert.are.equal("My Book_9.epub", plugin:_generateFilename({ id = 9, title = "My: Book?", extension = "epub" }))
  end)

  it("detects likely URLs", function()
    assert.is_true(plugin:isLikelyUrl("http://booklore.local:6060"))
    assert.is_true(plugin:isLikelyUrl("https://example.com"))
    assert.is_false(plugin:isLikelyUrl("192.168.1.50:6060"))
    assert.is_false(plugin:isLikelyUrl("booklore.local"))
  end)

  it("normalizes URL input with optional scheme prefix", function()
    assert.are.equal("http://192.168.1.50:6060", plugin:normalizeUrlInput("192.168.1.50:6060", true))
    assert.are.equal("https://booklore.example", plugin:normalizeUrlInput("https://booklore.example/", true))
    assert.are.equal("booklore.local:6060", plugin:normalizeUrlInput(" booklore.local:6060 ", false))
  end)

  local function withReaderSettings(values, fn)
    local original_reader_settings = G_reader_settings
    G_reader_settings = {
      readSetting = function(_, key)
        return values[key]
      end,
    }

    local ok, err = pcall(fn)
    G_reader_settings = original_reader_settings
    if not ok then
      error(err)
    end
  end

  it("detects airplane mode across supported setting keys", function()
    withReaderSettings({ airplanemode = false, airplane_mode = true }, function()
      assert.is_true(plugin:isAirplaneModeActive())
    end)
  end)

  it("treats string and numeric airplane values as enabled", function()
    withReaderSettings({ airplanemode = "1" }, function()
      assert.is_true(plugin:isAirplaneModeActive())
    end)
  end)

  it("selects effective server URL based on network match", function()
    plugin.server_url = "https://booklore.example"
    plugin.local_server_url = "192.168.1.50:6060"
    plugin.local_network_name = "homewifi"
    plugin.auto_url_switch_enabled = true
    plugin.getCurrentNetworkName = function() return "HomeWiFi" end

    local url, reason = plugin:getEffectiveServerUrl()
    assert.are.equal("http://192.168.1.50:6060", url)
    assert.are.equal("local_network_match", reason)
  end)

  it("falls back to primary URL when local network mismatches", function()
    plugin.server_url = "https://booklore.example"
    plugin.local_server_url = "192.168.1.50:6060"
    plugin.local_network_name = "homewifi"
    plugin.auto_url_switch_enabled = true
    plugin.getCurrentNetworkName = function() return "OfficeWiFi" end

    local url, reason = plugin:getEffectiveServerUrl()
    assert.are.equal("https://booklore.example", url)
    assert.are.equal("local_network_mismatch", reason)
  end)

end)
