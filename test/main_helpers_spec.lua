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

  it("treats stale remote progress that is behind local as equal", function()
    local direction = plugin:evaluateKoreaderProgressDirection(
      { percentage = 0.04, progress = "40", timestamp = 1715004000 },
      { percentage = 0.045, progress = "45", timestamp = 1715007600 }
    )

    assert.are.equal("equal", direction)
  end)

  it("keeps backward direction when remote progress is behind but newer", function()
    local direction = plugin:evaluateKoreaderProgressDirection(
      { percentage = 0.04, progress = "40", timestamp = 1715007600 },
      { percentage = 0.045, progress = "45", timestamp = 1715004000 }
    )

    assert.are.equal("backward", direction)
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

  it("hydrates local cache for unopened files before matching", function()
    local saved_args
    local hydrated_row = {
      id = 77,
      file_path = "/books/new.epub",
      file_hash = "hash-1",
      book_id = nil,
      title = "Sidecar Title",
      author = "A, B",
    }
    plugin.db = {
      getBookByFilePath = function(_, fp)
        if fp == "/books/new.epub" and saved_args then
          return hydrated_row
        end
        return nil
      end,
      saveBookCache = function(_, file_path, file_hash, book_id, title, author)
        saved_args = {
          file_path = file_path,
          file_hash = file_hash,
          book_id = book_id,
          title = title,
          author = author,
        }
        return true
      end,
      getBookCacheIdByFilePath = function() return 77 end,
      upsertBookMetadata = function(_, book_cache_id, fields)
        assert.are.equal(77, book_cache_id)
        assert.is_truthy(fields.sdr_path)
      end,
    }
    plugin.metadata_extractor = {
      getStats = function()
        return { title = "Sidecar Title", authors = { "A", "B" } }
      end,
    }
    plugin.calculateBookHash = function() return "hash-1" end

    package.loaded["docsettings"] = nil
    package.preload["docsettings"] = function()
      return {
        getSidecarDir = function(_, file_path)
          return file_path .. ".sdr"
        end,
      }
    end

    local row, err = plugin:_ensureBookCachedForFile("/books/new.epub")

    assert.is_nil(err)
    assert.are.equal(hydrated_row, row)
    assert.are.equal("/books/new.epub", saved_args.file_path)
    assert.are.equal("hash-1", saved_args.file_hash)
    assert.are.equal("Sidecar Title", saved_args.title)
    assert.are.equal("A, B", saved_args.author)
  end)

  it("fileDialogMatchBook proceeds without prior open when cache hydrate succeeds", function()
    local interactive_called = false
    plugin.db = {
      getBookByFilePath = function()
        return { id = 5, file_path = "/books/new.epub", title = "New", book_id = nil }
      end,
      saveBookCache = function() return true end,
      getBookCacheIdByFilePath = function() return 5 end,
      upsertBookMetadata = function() end,
    }
    plugin.settings = {
      readSetting = function(_, key)
        if key == "booklore_username" then return "u" end
        if key == "booklore_password" then return "p" end
        return ""
      end,
    }
    plugin.calculateBookHash = function() return "h" end
    plugin.metadata_extractor = { getStats = function() return nil end }
    plugin._matchSingleBookInteractive = function(_, book)
      interactive_called = true
      assert.are.equal("/books/new.epub", book.file_path)
    end

    package.loaded["docsettings"] = nil
    package.preload["docsettings"] = function()
      return { getSidecarDir = function() return "/books/new.epub.sdr" end }
    end

    plugin:fileDialogMatchBook("/books/new.epub")
    assert.is_true(interactive_called)
  end)

end)
