# KOReader Metadata Extractor

## Overview

The `BookloreMetadataExtractor` module provides a unified interface for extracting KOReader-specific metadata from document settings. This includes user-generated data like ratings, highlights, notes, bookmarks, and reading status.

## Purpose

Unlike bibliographic metadata (title, author, ISBN), this extractor focuses on **KOReader's own metadata**:
- ⭐ **Ratings** (1-5 stars)
- 📝 **Notes/Annotations**
- ✨ **Highlights**
- 🔖 **Bookmarks**
- 📊 **Reading Status** (complete, reading, on_hold, abandoned)
- 📈 **Progress Tracking**
- 📚 **Reading Statistics**

## KOReader Metadata Storage

### DocSettings (.sdr folders)

KOReader stores per-document settings in sidecar directories:

```
/path/to/book.epub
/path/to/book.epub.sdr/
  └── metadata.epub.lua    ← Document settings file
```

The `metadata.*.lua` file contains a Lua table with all document-specific data.

### Storage Locations

KOReader supports multiple storage locations for DocSettings:

1. **Sidecar (.sdr folder)** - Next to the book file (default)
2. **DocSettings directory** - Centralized location by filename
3. **Hash-based directory** - Centralized location by file hash

The `DocSettings` module automatically handles all three locations.

## Metadata Structure

### Summary Section

```lua
["summary"] = {
    ["rating"] = 4,              -- 1-5 stars
    ["status"] = "reading",      -- complete, reading, on_hold, abandoned
    ["modified"] = "2026-02-20"  -- YYYY-MM-DD
}
```

### Annotations (Highlights & Notes)

```lua
["annotations"] = {
    {
        ["text"] = "Highlighted text goes here",
        ["note"] = "Optional annotation/note",
        ["datetime"] = "2026-02-20 14:30:45",
        ["page"] = 42,
        ["chapter"] = "Chapter 3: The Journey",
        ["color"] = "yellow",
        ["drawer"] = "lighten",
        ["pos0"] = "/body/div[2]/p[5].0",
        ["pos1"] = "/body/div[2]/p[5].120"
    },
    -- More annotations...
}
```

### Bookmarks

```lua
["bookmarks"] = {
    {
        ["page"] = 100,
        ["notes"] = "Important chapter",
        ["datetime"] = "2026-02-20 10:15:00",
        ["chapter"] = "Chapter 7",
        ["pos0"] = "/body/div[7]/h1.0",
        ["pos1"] = "/body/div[7]/h1.20"
    },
    -- More bookmarks...
}
```

### Statistics

```lua
["stats"] = {
    ["title"] = "Book Title",
    ["authors"] = "Author Name",
    ["series"] = "Series Name",
    ["language"] = "en",
    ["pages"] = 350,
    ["highlights"] = 15,
    ["notes"] = 7,
    ["performance_in_pages"] = {}
}
```

### Progress

```lua
["percent_finished"] = 0.42  -- 0.0 to 1.0
["last_xpointer"] = "/body/div[5]/p[12].0"
["last_page"] = 147
```

## Usage

### Initialization

```lua
local MetadataExtractor = require("booklore_metadata_extractor")

-- Create instance
local extractor = MetadataExtractor:new({
    secure_logs = false  -- Optional: enable path redaction in logs
})
```

### Get Rating

```lua
local rating = extractor:getRating(doc_path)
-- Returns: number (1-5) or nil
```

### Get Reading Status

```lua
local status = extractor:getStatus(doc_path)
-- Returns: "complete", "reading", "on_hold", "abandoned", or nil
```

### Get Highlights

```lua
local highlights = extractor:getHighlights(doc_path)
-- Returns: array of highlight objects
-- Each highlight has: text, note, datetime, page, chapter, color, drawer, pos0, pos1

for _, highlight in ipairs(highlights) do
    print("Highlight:", highlight.text)
    if highlight.note then
        print("Note:", highlight.note)
    end
    print("Page:", highlight.page)
end
```

### Get Notes

```lua
local notes = extractor:getNotes(doc_path)
-- Returns: array of annotations that have notes attached
-- Each note has: text, note, datetime, page, chapter

for _, note in ipairs(notes) do
    print("Highlighted:", note.text)
    print("Note:", note.note)
end
```

### Get Bookmarks

```lua
local bookmarks = extractor:getBookmarks(doc_path)
-- Returns: array of bookmark objects
-- Each bookmark has: page, notes, datetime, chapter, pos0, pos1

for _, bookmark in ipairs(bookmarks) do
    print("Bookmark at page:", bookmark.page)
    if bookmark.notes then
        print("Notes:", bookmark.notes)
    end
end
```

### Get Progress

```lua
local progress = extractor:getProgress(doc_path)
-- Returns: number (0.0-1.0) or nil

if progress then
    print("Progress:", math.floor(progress * 100) .. "%")
end
```

### Get Statistics

```lua
local stats = extractor:getStats(doc_path)
-- Returns: stats table or nil

if stats then
    print("Title:", stats.title)
    print("Authors:", stats.authors)
    print("Pages:", stats.pages)
    print("Highlights:", stats.highlights)
    print("Notes:", stats.notes)
end
```

### Get All Metadata

```lua
local metadata = extractor:getAllMetadata(doc_path)
-- Returns: comprehensive metadata table

-- Available fields:
-- - rating (number or nil)
-- - status (string or nil)
-- - modified (string or nil)
-- - progress (number or nil)
-- - highlights (array)
-- - notes (array)
-- - bookmarks (array)
-- - stats (table or nil)
-- - last_position (string or nil)

print("Rating:", metadata.rating or "not set")
print("Highlights:", #metadata.highlights)
print("Notes:", #metadata.notes)
print("Bookmarks:", #metadata.bookmarks)
```

### Get Counts

```lua
local counts = extractor:getCounts(doc_path)
-- Returns: {highlights: number, notes: number, bookmarks: number}

print(string.format(
    "This book has %d highlights, %d notes, and %d bookmarks",
    counts.highlights,
    counts.notes,
    counts.bookmarks
))
```

## Writing Metadata

### Set Rating

```lua
local success = extractor:setRating(doc_path, 5)  -- 1-5 stars
if success then
    print("Rating set successfully")
end
```

### Set Reading Status

```lua
local success = extractor:setStatus(doc_path, "complete")
-- Valid statuses: "complete", "reading", "on_hold", "abandoned"

if success then
    print("Status updated")
end
```

## Integration Example

### Display Current Book Metadata

```lua
function BookloreSync:showCurrentBookMetadata()
    if not self.ui or not self.ui.document or not self.ui.document.file then
        UIManager:show(InfoMessage:new{
            text = _("No book currently open"),
            timeout = 2,
        })
        return
    end
    
    local doc_path = self.ui.document.file
    local metadata = self.metadata_extractor:getAllMetadata(doc_path)
    
    -- Format for display
    local lines = {}
    table.insert(lines, "📖 KOReader Metadata\n")
    
    -- Rating
    if metadata.rating then
        local stars = string.rep("⭐", metadata.rating)
        table.insert(lines, "Rating: " .. stars)
    end
    
    -- Status
    if metadata.status then
        table.insert(lines, "Status: " .. metadata.status)
    end
    
    -- Progress
    if metadata.progress then
        local pct = math.floor(metadata.progress * 100)
        table.insert(lines, "Progress: " .. pct .. "%")
    end
    
    -- Counts
    local counts = self.metadata_extractor:getCounts(doc_path)
    table.insert(lines, "Highlights: " .. counts.highlights)
    table.insert(lines, "Notes: " .. counts.notes)
    table.insert(lines, "Bookmarks: " .. counts.bookmarks)
    
    UIManager:show(InfoMessage:new{
        text = table.concat(lines, "\n"),
        timeout = 10,
    })
end
```

### Menu Integration

```lua
{
    text = _("Show Current Book Metadata"),
    help_text = _("Display KOReader metadata for the currently open book"),
    enabled_func = function()
        return self.ui and self.ui.document and self.ui.document.file
    end,
    callback = function()
        self:showCurrentBookMetadata()
    end,
}
```

## API Reference

### Constructor

#### `MetadataExtractor:new(options)`

Create a new metadata extractor instance.

**Parameters:**
- `options` (table, optional):
  - `secure_logs` (boolean): Enable path redaction in logs (default: false)

**Returns:** MetadataExtractor instance

**Example:**
```lua
local extractor = MetadataExtractor:new({secure_logs = true})
```

### Reading Methods

#### `getRating(doc_path)`

Get book rating (1-5 stars).

**Parameters:**
- `doc_path` (string): Full path to document file

**Returns:** number (1-5) or nil

---

#### `getStatus(doc_path)`

Get reading status.

**Parameters:**
- `doc_path` (string): Full path to document file

**Returns:** string ("complete", "reading", "on_hold", "abandoned") or nil

---

#### `getModified(doc_path)`

Get last modification date.

**Parameters:**
- `doc_path` (string): Full path to document file

**Returns:** string (YYYY-MM-DD) or nil

---

#### `getHighlights(doc_path)`

Get all highlights.

**Parameters:**
- `doc_path` (string): Full path to document file

**Returns:** array of highlight objects (empty array if none)

**Highlight object fields:**
- `text` (string): Highlighted text
- `note` (string, optional): Annotation/note
- `datetime` (string): Creation timestamp
- `page` (number): Page number
- `chapter` (string): Chapter name
- `color` (string): Highlight color
- `drawer` (string): Highlight style
- `pos0`, `pos1` (string): Position markers

---

#### `getNotes(doc_path)`

Get only annotations with notes attached.

**Parameters:**
- `doc_path` (string): Full path to document file

**Returns:** array of note objects (empty array if none)

---

#### `getBookmarks(doc_path)`

Get all bookmarks.

**Parameters:**
- `doc_path` (string): Full path to document file

**Returns:** array of bookmark objects (empty array if none)

---

#### `getProgress(doc_path)`

Get reading progress percentage.

**Parameters:**
- `doc_path` (string): Full path to document file

**Returns:** number (0.0-1.0) or nil

---

#### `getStats(doc_path)`

Get reading statistics.

**Parameters:**
- `doc_path` (string): Full path to document file

**Returns:** stats table or nil

---

#### `getLastPosition(doc_path)`

Get last reading position.

**Parameters:**
- `doc_path` (string): Full path to document file

**Returns:** string (xpointer or page) or nil

---

#### `getAllMetadata(doc_path)`

Get comprehensive metadata.

**Parameters:**
- `doc_path` (string): Full path to document file

**Returns:** metadata table with all available fields

---

#### `getCounts(doc_path)`

Get quick counts without loading full data.

**Parameters:**
- `doc_path` (string): Full path to document file

**Returns:** table `{highlights: number, notes: number, bookmarks: number}`

### Writing Methods

#### `setRating(doc_path, rating)`

Set or update book rating.

**Parameters:**
- `doc_path` (string): Full path to document file
- `rating` (number): Rating value (1-5)

**Returns:** boolean (success status)

---

#### `setStatus(doc_path, status)`

Set or update reading status.

**Parameters:**
- `doc_path` (string): Full path to document file
- `status` (string): Status value ("complete", "reading", "on_hold", "abandoned")

**Returns:** boolean (success status)

## DocSettings Integration

The extractor uses KOReader's official `DocSettings` module, which:
- ✅ Handles all three storage locations (.sdr, docsettings, hash-based)
- ✅ Automatically selects the most recent version
- ✅ Supports backup files (.old)
- ✅ Thread-safe file operations
- ✅ Atomic writes with flush()

## Error Handling

All methods handle errors gracefully:
- Missing DocSettings file → returns nil or empty array
- Corrupted data → logs warning, returns default value
- Invalid parameters → logs warning, returns nil/false
- File access errors → returns nil or empty array

No exceptions are thrown; errors are logged only.

## Performance

- **Fast**: DocSettings caching by KOReader
- **Lightweight**: Only loads requested data
- **No blocking**: File I/O is minimal
- **Memory efficient**: No global caches

## Secure Logging

When `secure_logs = true`:
- File paths are redacted: `/path/to/book.epub` → `[PATH REDACTED]`
- Safe for public logs
- Useful for privacy-conscious deployments

## Testing

### Manual Testing

1. Open a book in KOReader
2. Add some highlights, notes, and bookmarks
3. Set a rating (tap top-right menu → Rating)
4. Mark reading status
5. Navigate to **Tools → Booklore Sync → Manage Sessions**
6. Tap **"Show Current Book Metadata"**
7. Verify all metadata is displayed correctly

### Expected Output

```
📖 KOReader Metadata

Rating: ⭐⭐⭐⭐ (4/5)
Status: 📖 reading
Progress: 42%

Highlights: 15
Notes: 7
Bookmarks: 3

Title: Example Book
Authors: John Doe
Pages: 350

Last Modified: 2026-02-20
```

## Troubleshooting

### No metadata returned

**Symptom**: All fields are nil, counts are 0

**Causes:**
1. Book never opened in KOReader
2. No .sdr folder created yet
3. DocSettings location changed

**Solutions:**
1. Open book and read for a few seconds
2. Add a highlight or bookmark (forces .sdr creation)
3. Check `.sdr` folder exists next to book file

### Highlights/notes missing

**Symptom**: `getHighlights()` returns empty array but you know they exist

**Causes:**
1. Highlights not saved yet
2. Different DocSettings location
3. File moved since highlights were created

**Solutions:**
1. Ensure highlights were saved (not just created)
2. Check all three DocSettings locations
3. Use hash-based DocSettings for portable metadata

### Rating not saved

**Symptom**: `setRating()` returns true but rating not persisting

**Causes:**
1. DocSettings not flushed
2. File system read-only
3. Insufficient permissions

**Solutions:**
1. Code calls `flush()` automatically - check logs
2. Verify file system is writable
3. Check file permissions on .sdr folder

## Future Enhancements

Potential additions (not yet implemented):

1. **Highlight export** - Export to Markdown/HTML
2. **Bulk operations** - Process multiple books
3. **Metadata sync** - Sync between devices
4. **Search** - Find highlights by keyword
5. **Statistics** - Reading time, words highlighted, etc.
6. **Cloud backup** - Backup annotations to server

## Implementation Notes

### DocSettings Module

Uses KOReader's built-in `DocSettings` module:
```lua
local DocSettings = require("docsettings")
local doc_settings = DocSettings:open(doc_path)
```

This handles all complexity of storage locations and file formats.

### Data Format

All data is stored as Lua tables serialized to `.lua` files:
```lua
-- metadata.epub.lua
return {
    ["summary"] = {...},
    ["annotations"] = {...},
    ["bookmarks"] = {...},
    -- ... more settings
}
```

### Modification Safety

When writing metadata:
1. Loads existing settings
2. Modifies specific field
3. Saves entire table back
4. Calls `flush()` to persist

This preserves all other settings.

## References

- **KOReader DocSettings**: `frontend/docsettings.lua`
- **Annotation Format**: `frontend/apps/reader/modules/readerhighlight.lua`
- **Bookmark Format**: `frontend/apps/reader/modules/readerbookmark.lua`
- **Summary Format**: KOReader's collection management
- **Storage Locations**: See DataStorage module

## License

Same as parent plugin (Booklore KOReader Plugin).

---

**Last Updated**: February 20, 2026  
**Version**: 1.0.0  
**Status**: Production ready ✅
