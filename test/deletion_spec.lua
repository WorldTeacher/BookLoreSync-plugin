-- Tests for booklore_deletion_module.lua — preDeleteHook filename parsing
package.path = table.concat({
  "bookloresync.koplugin/?.lua",
  "bookloresync.koplugin/?/init.lua",
  package.path,
}, ";")

-- Stub KOReader deps the deletion module requires
package.preload["ffi/sha2"] = function()
  return { md5 = function(s) return "md5-" .. tostring(s):sub(1,8) end }
end

local DeletionFactory = require("booklore_deletion_module")

describe("deletion_module preDeleteHook", function()
  local mod, self

  before_each(function()
    -- Build a minimal self with just enough for preDeleteHook
    mod = DeletionFactory.new({
      json = { util = { InitArray = function(t) return t end } },
      UIManager = { scheduleIn = function(_, _, fn) if fn then fn() end end },
    })
    self = {
      db = nil,  -- no DB for pure filename tests
      logInfo = function() end,
      logWarn = function() end,
      logErr = function() end,
      calculateBookHash = function(self, filepath)
        return "hash-" .. tostring(filepath):match("([^/]+)$")
      end,
    }
  end)

  -- ── File extension detection ─────────────────────────────────────────────
  it("detects .epub extension", function()
    local hash, stem, book_id = mod.preDeleteHook(self, "/mnt/books/test.epub")
    assert.are.equal("hash-test.epub", hash)
    assert.are.equal("test", stem)
    assert.is_nil(book_id)
  end)

  it("detects .EPUB (uppercase) extension", function()
    local _, stem = mod.preDeleteHook(self, "/mnt/books/TEST.EPUB")
    assert.are.equal("TEST", stem)
  end)

  it("detects .Epub (mixed case) extension", function()
    local _, stem = mod.preDeleteHook(self, "/mnt/books/Test.Epub")
    assert.are.equal("Test", stem)
  end)

  it("detects .pdf extension", function()
    local _, stem = mod.preDeleteHook(self, "/mnt/books/doc.pdf")
    assert.are.equal("doc", stem)
  end)

  it("detects .cbz extension", function()
    local _, stem = mod.preDeleteHook(self, "/mnt/books/comic.cbz")
    assert.are.equal("comic", stem)
  end)

  it("detects .cbr extension", function()
    local _, stem = mod.preDeleteHook(self, "/mnt/books/comic.cbr")
    assert.are.equal("comic", stem)
  end)

  it("returns nil for unsupported extension", function()
    local hash, stem, book_id = mod.preDeleteHook(self, "/mnt/books/note.txt")
    assert.is_nil(hash)
    assert.is_nil(stem)
    assert.is_nil(book_id)
  end)

  it("returns nil for no extension", function()
    local hash, stem = mod.preDeleteHook(self, "/mnt/books/nofile")
    assert.is_nil(hash)
    assert.is_nil(stem)
  end)

  it("returns nil for nil filepath", function()
    local hash, stem, book_id = mod.preDeleteHook(self, nil)
    assert.is_nil(hash)
    assert.is_nil(stem)
    assert.is_nil(book_id)
  end)

  -- ── Stem extraction with paths ───────────────────────────────────────────
  it("extracts stem from full path", function()
    local _, stem = mod.preDeleteHook(self, "/mnt/ext1/Books/My Book.epub")
    assert.are.equal("My Book", stem)
  end)

  it("extracts stem with Windows-style backslashes", function()
    local _, stem = mod.preDeleteHook(self, "C:\\Books\\author.epub")
    assert.are.equal("author", stem)
  end)

  it("extracts stem from bare filename (no directory)", function()
    local _, stem = mod.preDeleteHook(self, "justfile.pdf")
    assert.are.equal("justfile", stem)
  end)

  -- ── Book ID parsing from filename ────────────────────────────────────────
  it("parses book ID from filename tag", function()
    local hash, stem, book_id = mod.preDeleteHook(self, "/mnt/books/Title_1234.epub")
    assert.are.equal("hash-Title_1234.epub", hash)
    assert.are.equal("Title_1234", stem)
    assert.are.equal(1234, book_id)
  end)

  it("parses book ID from filename with Author - Title format", function()
    local _, stem, book_id = mod.preDeleteHook(self, "/mnt/books/Author - Title_567.pdf")
    assert.are.equal("Author - Title_567", stem)
    assert.are.equal(567, book_id)
  end)

  it("handles filename with no ID tag", function()
    local _, stem, book_id = mod.preDeleteHook(self, "/mnt/books/NoID.epub")
    assert.are.equal("NoID", stem)
    assert.is_nil(book_id)
  end)

  it("handles filename where number is not at end", function()
    local _, stem, book_id = mod.preDeleteHook(self, "/mnt/books/Volume1_Edition2.epub")
    -- The ID parser looks for _DIGITS.ext at end; Volume1 is not underscore-prefixed
    assert.are.equal("Volume1_Edition2", stem)
    assert.is_nil(book_id)
  end)

  it("parses book_id from bare filename (no dir path)", function()
    local _, _, book_id = mod.preDeleteHook(self, "Book_99.cbz")
    assert.are.equal(99, book_id)
  end)

  -- ── Edge cases ───────────────────────────────────────────────────────────
  it("handles filename with multiple underscores before ID", function()
    local hash, stem, book_id = mod.preDeleteHook(self, "/mnt/The_Long_Title_42.epub")
    assert.are.equal("hash-The_Long_Title_42.epub", hash)
    assert.are.equal("The_Long_Title_42", stem)
    assert.are.equal(42, book_id)
  end)

  it("handles filename with only underscore and ID", function()
    local _, _, book_id = mod.preDeleteHook(self, "/mnt/_1.epub")
    assert.are.equal(1, book_id)
  end)
end)
