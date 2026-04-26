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

  it("resolves server URL with auto-switch disabled", function()
    plugin.auto_network_switch_enabled = false
    plugin.local_server_url = "http://local"
    plugin.remote_server_url = "https://remote"

    assert.are.equal("http://local", plugin:resolveServerUrl())

    plugin.local_server_url = ""
    assert.are.equal("https://remote", plugin:resolveServerUrl())
  end)

  it("resolves server URL with auto-switch enabled on home network", function()
    plugin.auto_network_switch_enabled = true
    plugin.home_network_ssid = "HomeWiFi"
    plugin.local_server_url = "http://local"
    plugin.remote_server_url = "https://remote"
    plugin.getCurrentNetworkSSID = function()
      return "HomeWiFi"
    end

    assert.are.equal("http://local", plugin:resolveServerUrl())

    plugin.local_server_url = ""
    assert.are.equal("https://remote", plugin:resolveServerUrl())
  end)

  it("resolves server URL with auto-switch enabled away from home network", function()
    plugin.auto_network_switch_enabled = true
    plugin.home_network_ssid = "HomeWiFi"
    plugin.local_server_url = "http://local"
    plugin.remote_server_url = "https://remote"
    plugin.getCurrentNetworkSSID = function()
      return "CoffeeShop"
    end

    assert.are.equal("https://remote", plugin:resolveServerUrl())

    plugin.remote_server_url = ""
    assert.are.equal("http://local", plugin:resolveServerUrl())
  end)

  it("falls back to local preference when auto-switch enabled without configured SSID", function()
    plugin.auto_network_switch_enabled = true
    plugin.home_network_ssid = ""
    plugin.local_server_url = "http://local"
    plugin.remote_server_url = "https://remote"
    plugin.getCurrentNetworkSSID = function()
      return "SomeNetwork"
    end

    assert.is_true(plugin:isOnConfiguredHomeNetwork())
    assert.are.equal("http://local", plugin:resolveServerUrl())
  end)

  it("refreshes effective server URL and reinitializes API when URL changes", function()
    local init_calls = {}

    plugin.api = {
      init = function(_, url, username, password, db)
        table.insert(init_calls, {
          url = url,
          username = username,
          password = password,
          db = db,
        })
      end,
    }

    plugin.username = "reader"
    plugin.password = "secret"
    plugin.db = { name = "db" }
    plugin.server_url = "http://old"
    plugin.local_server_url = "http://local"
    plugin.remote_server_url = "https://remote"
    plugin.auto_network_switch_enabled = false

    assert.are.equal("http://local", plugin:refreshEffectiveServerUrl())
    assert.are.equal("http://local", plugin.server_url)
    assert.are.equal(1, #init_calls)
    assert.are.equal("http://local", init_calls[1].url)

    -- No URL change -> no additional init call
    assert.are.equal("http://local", plugin:refreshEffectiveServerUrl())
    assert.are.equal(1, #init_calls)
  end)

end)
