--[[--
Booklore KOReader Metadata Extractor

Extracts KOReader-specific metadata from document settings:
- Ratings
- Highlights
- Notes/Annotations
- Bookmarks
- Reading status
- Custom metadata

Supports both .sdr folders and hash-based DocSettings.

@module koplugin.booklore_metadata_extractor
--]]--

local DocSettings = require("docsettings")
local logger = require("logger")

local BookloreMetadataExtractor = {}

--[[--
Initialize the metadata extractor

@param secure_logs Enable secure logging (default: false)
--]]
function BookloreMetadataExtractor:new(o)
    o = o or {}
    setmetatable(o, self)
    self.__index = self
    self.secure_logs = o.secure_logs or false
    return o
end

--[[--
Log message with secure logging support

@param level Log level (info, warn, err, dbg)
@param ... Log arguments
--]]
function BookloreMetadataExtractor:log(level, ...)
    local args = {...}
    if self.secure_logs then
        -- Redact file paths in secure mode
        for i = 1, #args do
            if type(args[i]) == "string" then
                args[i] = args[i]:gsub("/[^%s]+", "[PATH REDACTED]")
            end
        end
    end
    
    if level == "info" then
        logger.info("MetadataExtractor:", table.unpack(args))
    elseif level == "warn" then
        logger.warn("MetadataExtractor:", table.unpack(args))
    elseif level == "err" then
        logger.err("MetadataExtractor:", table.unpack(args))
    elseif level == "dbg" then
        logger.dbg("MetadataExtractor:", table.unpack(args))
    end
end

--[[--
Load DocSettings for a document

@param doc_path Full path to the document file
@return DocSettings object or nil if not found
--]]
function BookloreMetadataExtractor:loadDocSettings(doc_path)
    if not doc_path then
        self:log("warn", "No document path provided")
        return nil
    end
    
    local doc_settings = DocSettings:open(doc_path)
    if not doc_settings then
        self:log("dbg", "No DocSettings found for document")
        return nil
    end
    
    return doc_settings
end

--[[--
Get rating for a document

KOReader stores rating in summary.rating field (1-5 stars)

@param doc_path Full path to the document file
@return number|nil Rating (1-5) or nil if not set
--]]
function BookloreMetadataExtractor:getRating(doc_path)
    local doc_settings = self:loadDocSettings(doc_path)
    if not doc_settings then
        return nil
    end
    
    local summary = doc_settings:readSetting("summary")
    if summary and summary.rating then
        local rating = tonumber(summary.rating)
        self:log("dbg", "Found rating:", rating)
        return rating
    end
    
    return nil
end

--[[--
Get reading status for a document

KOReader stores status in summary.status field
Possible values: "complete", "reading", "on_hold", "abandoned"

@param doc_path Full path to the document file
@return string|nil Status or nil if not set
--]]
function BookloreMetadataExtractor:getStatus(doc_path)
    local doc_settings = self:loadDocSettings(doc_path)
    if not doc_settings then
        return nil
    end
    
    local summary = doc_settings:readSetting("summary")
    if summary and summary.status then
        self:log("dbg", "Found status:", summary.status)
        return summary.status
    end
    
    return nil
end

--[[--
Get modified date for a document

@param doc_path Full path to the document file
@return string|nil Date string (YYYY-MM-DD) or nil if not set
--]]
function BookloreMetadataExtractor:getModified(doc_path)
    local doc_settings = self:loadDocSettings(doc_path)
    if not doc_settings then
        return nil
    end
    
    local summary = doc_settings:readSetting("summary")
    if summary and summary.modified then
        return summary.modified
    end
    
    return nil
end

--[[--
Get highlights for a document

KOReader stores highlights in annotations array
Each highlight contains:
- text: highlighted text
- note: optional note/annotation
- datetime: creation timestamp
- page: page number
- pos0, pos1: position markers
- chapter: chapter name
- drawer: highlight style
- color: highlight color

@param doc_path Full path to the document file
@return table Array of highlights, empty table if none
--]]
function BookloreMetadataExtractor:getHighlights(doc_path)
    local doc_settings = self:loadDocSettings(doc_path)
    if not doc_settings then
        return {}
    end
    
    local annotations = doc_settings:readSetting("annotations")
    if not annotations or type(annotations) ~= "table" then
        return {}
    end
    
    local highlights = {}
    for _, annotation in ipairs(annotations) do
        if annotation.text then
            table.insert(highlights, {
                text = annotation.text,
                note = annotation.note,
                datetime = annotation.datetime,
                page = annotation.page,
                chapter = annotation.chapter,
                color = annotation.color or "yellow",
                drawer = annotation.drawer or "lighten",
                pos0 = annotation.pos0,
                pos1 = annotation.pos1,
            })
        end
    end
    
    self:log("dbg", "Found", #highlights, "highlights")
    return highlights
end

--[[--
Get notes/annotations for a document

Returns only annotations that have notes attached

@param doc_path Full path to the document file
@return table Array of notes, empty table if none
--]]
function BookloreMetadataExtractor:getNotes(doc_path)
    local doc_settings = self:loadDocSettings(doc_path)
    if not doc_settings then
        return {}
    end
    
    local annotations = doc_settings:readSetting("annotations")
    if not annotations or type(annotations) ~= "table" then
        return {}
    end
    
    local notes = {}
    for _, annotation in ipairs(annotations) do
        if annotation.note and annotation.note ~= "" then
            table.insert(notes, {
                text = annotation.text or "",
                note = annotation.note,
                datetime = annotation.datetime,
                page = annotation.page,
                chapter = annotation.chapter,
            })
        end
    end
    
    self:log("dbg", "Found", #notes, "notes")
    return notes
end

--[[--
Get bookmarks for a document

KOReader stores bookmarks in bookmarks array
Each bookmark contains:
- page: page number
- notes: optional note
- datetime: creation timestamp
- pos0, pos1: position markers
- chapter: chapter name

@param doc_path Full path to the document file
@return table Array of bookmarks, empty table if none
--]]
function BookloreMetadataExtractor:getBookmarks(doc_path)
    local doc_settings = self:loadDocSettings(doc_path)
    if not doc_settings then
        return {}
    end
    
    local bookmarks = doc_settings:readSetting("bookmarks")
    if not bookmarks or type(bookmarks) ~= "table" then
        return {}
    end
    
    local result = {}
    for _, bookmark in ipairs(bookmarks) do
        table.insert(result, {
            page = bookmark.page,
            notes = bookmark.notes,
            datetime = bookmark.datetime,
            chapter = bookmark.chapter,
            pos0 = bookmark.pos0,
            pos1 = bookmark.pos1,
        })
    end
    
    self:log("dbg", "Found", #result, "bookmarks")
    return result
end

--[[--
Get reading progress percentage

@param doc_path Full path to the document file
@return number|nil Progress (0.0-1.0) or nil if not available
--]]
function BookloreMetadataExtractor:getProgress(doc_path)
    local doc_settings = self:loadDocSettings(doc_path)
    if not doc_settings then
        return nil
    end
    
    local progress = doc_settings:readSetting("percent_finished")
    if progress then
        self:log("dbg", "Found progress:", progress)
        return tonumber(progress)
    end
    
    return nil
end

--[[--
Get statistics for a document

Returns the stats field which contains:
- title, authors, series, language
- pages: total page count
- highlights: number of highlights
- notes: number of notes

@param doc_path Full path to the document file
@return table|nil Stats table or nil if not available
--]]
function BookloreMetadataExtractor:getStats(doc_path)
    local doc_settings = self:loadDocSettings(doc_path)
    if not doc_settings then
        return nil
    end
    
    local stats = doc_settings:readSetting("stats")
    if stats and type(stats) == "table" then
        self:log("dbg", "Found stats for:", stats.title or "unknown")
        return stats
    end
    
    return nil
end

--[[--
Get last reading position

@param doc_path Full path to the document file
@return string|nil xpointer or page position
--]]
function BookloreMetadataExtractor:getLastPosition(doc_path)
    local doc_settings = self:loadDocSettings(doc_path)
    if not doc_settings then
        return nil
    end
    
    local last_xpointer = doc_settings:readSetting("last_xpointer")
    if last_xpointer then
        return last_xpointer
    end
    
    local last_page = doc_settings:readSetting("last_page")
    if last_page then
        return tostring(last_page)
    end
    
    return nil
end

--[[--
Get all metadata for a document

Returns comprehensive metadata including:
- rating
- status
- modified
- progress
- highlights (array)
- notes (array)
- bookmarks (array)
- stats (table)
- last_position

@param doc_path Full path to the document file
@return table Metadata table (fields may be nil)
--]]
function BookloreMetadataExtractor:getAllMetadata(doc_path)
    if not doc_path then
        self:log("warn", "No document path provided")
        return {}
    end
    
    local metadata = {
        doc_path = doc_path,
        rating = self:getRating(doc_path),
        status = self:getStatus(doc_path),
        modified = self:getModified(doc_path),
        progress = self:getProgress(doc_path),
        highlights = self:getHighlights(doc_path),
        notes = self:getNotes(doc_path),
        bookmarks = self:getBookmarks(doc_path),
        stats = self:getStats(doc_path),
        last_position = self:getLastPosition(doc_path),
    }
    
    self:log("info", "Extracted metadata:", 
        #metadata.highlights, "highlights,",
        #metadata.notes, "notes,",
        #metadata.bookmarks, "bookmarks,",
        "rating:", metadata.rating or "none",
        "status:", metadata.status or "none"
    )
    
    return metadata
end

--[[--
Count highlights and notes

@param doc_path Full path to the document file
@return table {highlights: number, notes: number, bookmarks: number}
--]]
function BookloreMetadataExtractor:getCounts(doc_path)
    local doc_settings = self:loadDocSettings(doc_path)
    if not doc_settings then
        return {highlights = 0, notes = 0, bookmarks = 0}
    end
    
    local counts = {highlights = 0, notes = 0, bookmarks = 0}
    
    local annotations = doc_settings:readSetting("annotations")
    if annotations and type(annotations) == "table" then
        for _, annotation in ipairs(annotations) do
            if annotation.text then
                counts.highlights = counts.highlights + 1
            end
            if annotation.note and annotation.note ~= "" then
                counts.notes = counts.notes + 1
            end
        end
    end
    
    local bookmarks = doc_settings:readSetting("bookmarks")
    if bookmarks and type(bookmarks) == "table" then
        counts.bookmarks = #bookmarks
    end
    
    return counts
end

--[[--
Update or set rating for a document

@param doc_path Full path to the document file
@param rating Rating value (1-5)
@return boolean Success status
--]]
function BookloreMetadataExtractor:setRating(doc_path, rating)
    if not doc_path then
        self:log("warn", "No document path provided")
        return false
    end
    
    if not rating or rating < 1 or rating > 5 then
        self:log("warn", "Invalid rating value:", rating)
        return false
    end
    
    local doc_settings = self:loadDocSettings(doc_path)
    if not doc_settings then
        self:log("warn", "Could not load DocSettings")
        return false
    end
    
    local summary = doc_settings:readSetting("summary") or {}
    summary.rating = rating
    doc_settings:saveSetting("summary", summary)
    doc_settings:flush()
    
    self:log("info", "Set rating to:", rating)
    return true
end

--[[--
Update or set reading status for a document

@param doc_path Full path to the document file
@param status Status value ("complete", "reading", "on_hold", "abandoned")
@return boolean Success status
--]]
function BookloreMetadataExtractor:setStatus(doc_path, status)
    if not doc_path then
        self:log("warn", "No document path provided")
        return false
    end
    
    local valid_statuses = {
        complete = true,
        reading = true,
        on_hold = true,
        abandoned = true,
    }
    
    if not valid_statuses[status] then
        self:log("warn", "Invalid status value:", status)
        return false
    end
    
    local doc_settings = self:loadDocSettings(doc_path)
    if not doc_settings then
        self:log("warn", "Could not load DocSettings")
        return false
    end
    
    local summary = doc_settings:readSetting("summary") or {}
    summary.status = status
    summary.modified = os.date("%Y-%m-%d")
    doc_settings:saveSetting("summary", summary)
    doc_settings:flush()
    
    self:log("info", "Set status to:", status)
    return true
end

return BookloreMetadataExtractor
