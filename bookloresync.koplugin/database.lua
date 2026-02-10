--[[--
Booklore Database Module

Provides SQLite database management with migration support for the Booklore plugin.

@module koplugin.BookloreSync.database
--]]--

local SQ3 = require("lua-ljsqlite3/init")
local DataStorage = require("datastorage")
local logger = require("logger")

local Database = {
    VERSION = 1,  -- Current database schema version
    db_path = nil,
    conn = nil,
}

-- Migration definitions
-- Each migration is a list of SQL statements to execute
Database.migrations = {
    -- Migration 1: Initial schema
    [1] = {
        -- Book cache table: stores file hashes and book IDs
        [[
            CREATE TABLE IF NOT EXISTS book_cache (
                id INTEGER PRIMARY KEY AUTOINCREMENT,
                file_path TEXT UNIQUE NOT NULL,
                file_hash TEXT NOT NULL,
                book_id INTEGER,
                title TEXT,
                author TEXT,
                last_accessed INTEGER,
                created_at INTEGER DEFAULT (strftime('%s', 'now')),
                updated_at INTEGER DEFAULT (strftime('%s', 'now'))
            )
        ]],
        [[
            CREATE INDEX IF NOT EXISTS idx_book_cache_file_path ON book_cache(file_path)
        ]],
        [[
            CREATE INDEX IF NOT EXISTS idx_book_cache_file_hash ON book_cache(file_hash)
        ]],
        [[
            CREATE INDEX IF NOT EXISTS idx_book_cache_book_id ON book_cache(book_id)
        ]],
        
        -- Pending sessions table: stores sessions waiting to be synced
        [[
            CREATE TABLE IF NOT EXISTS pending_sessions (
                id INTEGER PRIMARY KEY AUTOINCREMENT,
                book_id INTEGER,
                book_hash TEXT NOT NULL,
                book_type TEXT DEFAULT 'EPUB',
                start_time TEXT NOT NULL,
                end_time TEXT NOT NULL,
                duration_seconds INTEGER NOT NULL,
                start_progress REAL DEFAULT 0.0,
                end_progress REAL DEFAULT 0.0,
                progress_delta REAL DEFAULT 0.0,
                start_location TEXT,
                end_location TEXT,
                created_at INTEGER DEFAULT (strftime('%s', 'now')),
                retry_count INTEGER DEFAULT 0,
                last_retry_at INTEGER
            )
        ]],
        [[
            CREATE INDEX IF NOT EXISTS idx_pending_sessions_book_hash ON pending_sessions(book_hash)
        ]],
        
        -- Match history table: tracks book matching decisions
        [[
            CREATE TABLE IF NOT EXISTS match_history (
                id INTEGER PRIMARY KEY AUTOINCREMENT,
                file_hash TEXT NOT NULL,
                book_id INTEGER NOT NULL,
                match_method TEXT DEFAULT 'manual',
                confidence REAL DEFAULT 1.0,
                matched_at INTEGER DEFAULT (strftime('%s', 'now')),
                matched_title TEXT,
                matched_author TEXT
            )
        ]],
        [[
            CREATE INDEX IF NOT EXISTS idx_match_history_file_hash ON match_history(file_hash)
        ]],
        
        -- Schema version table
        [[
            CREATE TABLE IF NOT EXISTS schema_version (
                version INTEGER PRIMARY KEY,
                applied_at INTEGER DEFAULT (strftime('%s', 'now'))
            )
        ]],
    },
}

function Database:new(o)
    o = o or {}
    setmetatable(o, self)
    self.__index = self
    return o
end

function Database:init(db_name)
    db_name = db_name or "booklore-sync.sqlite"
    self.db_path = DataStorage:getSettingsDir() .. "/" .. db_name
    
    logger.info("BookloreSync Database: Initializing database at", self.db_path)
    
    -- Open database connection
    local conn = SQ3.open(self.db_path)
    if not conn then
        logger.err("BookloreSync Database: Failed to open database at", self.db_path)
        return false
    end
    
    self.conn = conn
    
    -- Enable foreign keys
    self.conn:exec("PRAGMA foreign_keys = ON")
    
    -- Set WAL mode for better concurrency
    self.conn:exec("PRAGMA journal_mode = WAL")
    
    -- Run migrations
    local success = self:runMigrations()
    if not success then
        logger.err("BookloreSync Database: Migration failed")
        return false
    end
    
    logger.info("BookloreSync Database: Initialization complete")
    return true
end

function Database:close()
    if self.conn then
        self.conn:close()
        self.conn = nil
        logger.info("BookloreSync Database: Connection closed")
    end
end

function Database:getCurrentVersion()
    -- Check if schema_version table exists
    local stmt = self.conn:prepare([[
        SELECT name FROM sqlite_master 
        WHERE type='table' AND name='schema_version'
    ]])
    
    if not stmt then
        return 0
    end
    
    local has_table = false
    for row in stmt:rows() do
        has_table = true
        break
    end
    stmt:close()
    
    if not has_table then
        return 0
    end
    
    -- Get current version
    stmt = self.conn:prepare("SELECT MAX(version) as version FROM schema_version")
    if not stmt then
        return 0
    end
    
    local version = 0
    for row in stmt:rows() do
        version = row[1] or 0
        break
    end
    stmt:close()
    
    return version
end

function Database:runMigrations()
    local current_version = self:getCurrentVersion()
    logger.info("BookloreSync Database: Current schema version:", current_version)
    logger.info("BookloreSync Database: Target schema version:", self.VERSION)
    
    if current_version >= self.VERSION then
        logger.info("BookloreSync Database: Schema is up to date")
        return true
    end
    
    -- Run migrations in order
    for version = current_version + 1, self.VERSION do
        logger.info("BookloreSync Database: Applying migration", version)
        
        local migration = self.migrations[version]
        if not migration then
            logger.err("BookloreSync Database: Migration", version, "not found")
            return false
        end
        
        -- Begin transaction
        self.conn:exec("BEGIN TRANSACTION")
        
        local success = true
        for i, sql in ipairs(migration) do
            logger.dbg("BookloreSync Database: Executing SQL statement", i, "of", #migration)
            local result = self.conn:exec(sql)
            if result ~= SQ3.OK then
                logger.err("BookloreSync Database: Failed to execute migration", version, "statement", i)
                logger.err("BookloreSync Database: SQL:", sql)
                logger.err("BookloreSync Database: Error:", self.conn:errmsg())
                success = false
                break
            end
        end
        
        if success then
            -- Record migration version
            local stmt = self.conn:prepare("INSERT INTO schema_version (version) VALUES (?)")
            if not stmt then
                logger.err("BookloreSync Database: Failed to prepare version insert:", self.conn:errmsg())
                self.conn:exec("ROLLBACK")
                return false
            end
            
            -- Ensure version is an integer
            version = tonumber(version)
            if not version then
                logger.err("BookloreSync Database: Version is not a number")
                stmt:close()
                self.conn:exec("ROLLBACK")
                return false
            end
            
            logger.dbg("BookloreSync Database: Binding version:", version, "type:", type(version))
            
            local bind_ok, bind_err = pcall(function()
                stmt:bind1(version)
            end)
            
            if not bind_ok then
                logger.err("BookloreSync Database: Bind failed:", bind_err)
                stmt:close()
                self.conn:exec("ROLLBACK")
                return false
            end
            
            logger.dbg("BookloreSync Database: Bind successful")
            
            local step_result = stmt:step()
            logger.dbg("BookloreSync Database: Step result:", step_result)
            stmt:close()
            
            if step_result ~= SQ3.DONE and step_result ~= SQ3.OK then
                logger.err("BookloreSync Database: Failed to insert version:", self.conn:errmsg())
                self.conn:exec("ROLLBACK")
                return false
            end
            
            -- Commit transaction
            self.conn:exec("COMMIT")
            logger.info("BookloreSync Database: Migration", version, "applied successfully")
        else
            -- Rollback transaction
            self.conn:exec("ROLLBACK")
            logger.err("BookloreSync Database: Migration", version, "failed, rolled back")
            return false
        end
    end
    
    return true
end

-- Book Cache operations

function Database:getBookByFilePath(file_path)
    local stmt = self.conn:prepare([[
        SELECT id, file_path, file_hash, book_id, title, author, last_accessed
        FROM book_cache
        WHERE file_path = ?
    ]])
    
    if not stmt then
        logger.err("BookloreSync Database: Failed to prepare statement:", self.conn:errmsg())
        return nil
    end
    
    stmt:bind1(file_path)
    
    local book = nil
    for row in stmt:rows() do
        book = {
            id = row[1],
            file_path = row[2],
            file_hash = row[3],
            book_id = row[4],
            title = row[5],
            author = row[6],
            last_accessed = row[7],
        }
        break
    end
    
    stmt:close()
    return book
end

function Database:getBookByHash(file_hash)
    local stmt = self.conn:prepare([[
        SELECT id, file_path, file_hash, book_id, title, author, last_accessed
        FROM book_cache
        WHERE file_hash = ?
        LIMIT 1
    ]])
    
    if not stmt then
        logger.err("BookloreSync Database: Failed to prepare statement:", self.conn:errmsg())
        return nil
    end
    
    stmt:bind1(file_hash)
    
    local book = nil
    for row in stmt:rows() do
        book = {
            id = row[1],
            file_path = row[2],
            file_hash = row[3],
            book_id = row[4],
            title = row[5],
            author = row[6],
            last_accessed = row[7],
        }
        break
    end
    
    stmt:close()
    return book
end

function Database:saveBookCache(file_path, file_hash, book_id, title, author)
    -- Ensure types are correct
    file_path = tostring(file_path or "")
    file_hash = tostring(file_hash or "")
    
    -- book_id can be nil (NULL) or must be a number
    if book_id ~= nil then
        book_id = tonumber(book_id)
        if not book_id then
            logger.warn("BookloreSync Database: Invalid book_id, setting to NULL")
            book_id = nil
        end
    end
    
    -- Try to update existing entry first
    local stmt = self.conn:prepare([[
        UPDATE book_cache 
        SET file_hash = ?, book_id = ?, title = ?, author = ?, 
            last_accessed = CAST(strftime('%s', 'now') AS INTEGER),
            updated_at = CAST(strftime('%s', 'now') AS INTEGER)
        WHERE file_path = ?
    ]])
    
    if not stmt then
        logger.err("BookloreSync Database: Failed to prepare update statement:", self.conn:errmsg())
        return false
    end
    
    stmt:bind1(file_hash)
    stmt:bind2(book_id)  -- Can be nil
    stmt:bind3(title)    -- Can be nil
    stmt:bind4(author)   -- Can be nil
    stmt:bind5(file_path)
    
    local result = stmt:step()
    local changes = self.conn:changes()
    stmt:close()
    
    if result ~= SQ3.DONE and result ~= SQ3.OK then
        logger.err("BookloreSync Database: Failed to update book cache:", self.conn:errmsg())
        return false
    end
    
    -- If no rows were updated, insert new entry
    if changes == 0 then
        stmt = self.conn:prepare([[
            INSERT INTO book_cache (file_path, file_hash, book_id, title, author, last_accessed)
            VALUES (?, ?, ?, ?, ?, CAST(strftime('%s', 'now') AS INTEGER))
        ]])
        
        if not stmt then
            logger.err("BookloreSync Database: Failed to prepare insert statement:", self.conn:errmsg())
            return false
        end
        
        stmt:bind1(file_path)
        stmt:bind2(file_hash)
        stmt:bind3(book_id)  -- Can be nil
        stmt:bind4(title)    -- Can be nil
        stmt:bind5(author)   -- Can be nil
        
        result = stmt:step()
        stmt:close()
        
        if result ~= SQ3.DONE and result ~= SQ3.OK then
            logger.err("BookloreSync Database: Failed to insert book cache:", self.conn:errmsg())
            return false
        end
    end
    
    return true
end

function Database:updateBookId(file_hash, book_id)
    local stmt = self.conn:prepare([[
        UPDATE book_cache 
        SET book_id = ?, updated_at = CAST(strftime('%s', 'now') AS INTEGER)
        WHERE file_hash = ?
    ]])
    
    if not stmt then
        logger.err("BookloreSync Database: Failed to prepare statement:", self.conn:errmsg())
        return false
    end
    
    stmt:bind1(book_id)
    stmt:bind2(file_hash)
    stmt:step()
    stmt:close()
    
    return true
end

function Database:getAllUnmatchedBooks()
    local stmt = self.conn:prepare([[
        SELECT id, file_path, file_hash, title, author
        FROM book_cache
        WHERE book_id IS NULL
        ORDER BY last_accessed DESC
    ]])
    
    if not stmt then
        logger.err("BookloreSync Database: Failed to prepare statement:", self.conn:errmsg())
        return {}
    end
    
    local books = {}
    for row in stmt:rows() do
        table.insert(books, {
            id = row[1],
            file_path = row[2],
            file_hash = row[3],
            title = row[4],
            author = row[5],
        })
    end
    
    stmt:close()
    return books
end

function Database:getBookCacheStats()
    local stmt = self.conn:prepare([[
        SELECT 
            COUNT(*) as total,
            COUNT(book_id) as matched,
            COUNT(*) - COUNT(book_id) as unmatched
        FROM book_cache
    ]])
    
    if not stmt then
        logger.err("BookloreSync Database: Failed to prepare statement:", self.conn:errmsg())
        return {total = 0, matched = 0, unmatched = 0}
    end
    
    local stats = {total = 0, matched = 0, unmatched = 0}
    for row in stmt:rows() do
        stats.total = row[1] or 0
        stats.matched = row[2] or 0
        stats.unmatched = row[3] or 0
        break
    end
    
    stmt:close()
    return stats
end

function Database:clearBookCache()
    self.conn:exec("DELETE FROM book_cache")
    logger.info("BookloreSync Database: Book cache cleared")
    return true
end

-- Pending Sessions operations

function Database:addPendingSession(session_data)
    local stmt = self.conn:prepare([[
        INSERT INTO pending_sessions (
            book_id, book_hash, book_type, start_time, end_time,
            duration_seconds, start_progress, end_progress, progress_delta,
            start_location, end_location
        ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
    ]])
    
    if not stmt then
        logger.err("BookloreSync Database: Failed to prepare statement:", self.conn:errmsg())
        return false
    end
    
    -- Use bind_blob for null handling
    if session_data.bookId then
        stmt:bind1(session_data.bookId)
    else
        stmt:bind1(nil)
    end
    
    stmt:bind2(session_data.bookHash or "")
    stmt:bind3(session_data.bookType or "EPUB")
    stmt:bind4(session_data.startTime or "")
    stmt:bind5(session_data.endTime or "")
    stmt:bind6(session_data.durationSeconds or 0)
    stmt:bind7(session_data.startProgress or 0.0)
    stmt:bind8(session_data.endProgress or 0.0)
    stmt:bind9(session_data.progressDelta or 0.0)
    stmt:bind10(session_data.startLocation or "0")
    stmt:bind11(session_data.endLocation or "0")
    
    local result = stmt:step()
    stmt:close()
    
    if result ~= SQ3.DONE and result ~= SQ3.OK then
        logger.err("BookloreSync Database: Failed to insert pending session:", self.conn:errmsg())
        return false
    end
    
    return true
end

function Database:getPendingSessions(limit)
    limit = limit or 100
    
    local stmt = self.conn:prepare([[
        SELECT id, book_id, book_hash, book_type, start_time, end_time,
               duration_seconds, start_progress, end_progress, progress_delta,
               start_location, end_location, retry_count
        FROM pending_sessions
        ORDER BY created_at ASC
        LIMIT ?
    ]])
    
    if not stmt then
        logger.err("BookloreSync Database: Failed to prepare statement:", self.conn:errmsg())
        return {}
    end
    
    stmt:bind1(limit)
    
    local sessions = {}
    for row in stmt:rows() do
        table.insert(sessions, {
            id = row[1],
            bookId = row[2],
            bookHash = row[3],
            bookType = row[4],
            startTime = row[5],
            endTime = row[6],
            durationSeconds = row[7],
            startProgress = row[8],
            endProgress = row[9],
            progressDelta = row[10],
            startLocation = row[11],
            endLocation = row[12],
            retryCount = row[13],
        })
    end
    
    stmt:close()
    return sessions
end

function Database:deletePendingSession(session_id)
    local stmt = self.conn:prepare("DELETE FROM pending_sessions WHERE id = ?")
    
    if not stmt then
        logger.err("BookloreSync Database: Failed to prepare statement:", self.conn:errmsg())
        return false
    end
    
    stmt:bind1(session_id)
    stmt:step()
    stmt:close()
    
    return true
end

function Database:clearPendingSessions()
    self.conn:exec("DELETE FROM pending_sessions")
    logger.info("BookloreSync Database: Pending sessions cleared")
    return true
end

function Database:getPendingSessionCount()
    local stmt = self.conn:prepare("SELECT COUNT(*) FROM pending_sessions")
    
    if not stmt then
        return 0
    end
    
    local count = 0
    for row in stmt:rows() do
        count = row[1] or 0
        break
    end
    
    stmt:close()
    return count
end

function Database:incrementSessionRetryCount(session_id)
    local stmt = self.conn:prepare([[
        UPDATE pending_sessions 
        SET retry_count = retry_count + 1,
            last_retry_at = CAST(strftime('%s', 'now') AS INTEGER)
        WHERE id = ?
    ]])
    
    if not stmt then
        logger.err("BookloreSync Database: Failed to prepare statement:", self.conn:errmsg())
        return false
    end
    
    stmt:bind1(session_id)
    stmt:step()
    stmt:close()
    
    return true
end

-- Match History operations

function Database:saveMatchHistory(file_hash, book_id, match_method, confidence, title, author)
    local stmt = self.conn:prepare([[
        INSERT INTO match_history (file_hash, book_id, match_method, confidence, matched_title, matched_author)
        VALUES (?, ?, ?, ?, ?, ?)
    ]])
    
    if not stmt then
        logger.err("BookloreSync Database: Failed to prepare statement:", self.conn:errmsg())
        return false
    end
    
    stmt:bind1(file_hash)
    stmt:bind2(book_id)
    stmt:bind3(match_method or "manual")
    stmt:bind4(confidence or 1.0)
    stmt:bind5(title)
    stmt:bind6(author)
    
    stmt:step()
    stmt:close()
    
    return true
end

function Database:getMatchHistory(file_hash)
    local stmt = self.conn:prepare([[
        SELECT id, book_id, match_method, confidence, matched_at, matched_title, matched_author
        FROM match_history
        WHERE file_hash = ?
        ORDER BY matched_at DESC
        LIMIT 1
    ]])
    
    if not stmt then
        logger.err("BookloreSync Database: Failed to prepare statement:", self.conn:errmsg())
        return nil
    end
    
    stmt:bind1(file_hash)
    
    local history = nil
    for row in stmt:rows() do
        history = {
            id = row[1],
            book_id = row[2],
            match_method = row[3],
            confidence = row[4],
            matched_at = row[5],
            matched_title = row[6],
            matched_author = row[7],
        }
        break
    end
    
    stmt:close()
    return history
end

-- Migration data from LuaSettings (for backward compatibility)

function Database:migrateFromLuaSettings(local_db)
    logger.info("BookloreSync Database: Starting migration from LuaSettings")
    
    local success = true
    
    -- Migrate book cache
    local book_cache = local_db:readSetting("book_cache") or {}
    local migrated_books = 0
    local failed_books = 0
    
    if book_cache.file_hashes and book_cache.book_ids then
        for file_path, file_hash in pairs(book_cache.file_hashes) do
            local book_id = book_cache.book_ids[file_hash]
            
            -- Debug logging
            logger.dbg("BookloreSync Database: Migrating book - path:", file_path, "hash:", file_hash, "id:", book_id, "type:", type(book_id))
            
            local ok, err = pcall(function()
                local result = self:saveBookCache(file_path, file_hash, book_id, nil, nil)
                if not result then
                    error("saveBookCache returned false")
                end
            end)
            
            if ok then
                migrated_books = migrated_books + 1
            else
                failed_books = failed_books + 1
                logger.err("BookloreSync Database: Failed to migrate book cache entry:", file_path, "error:", err)
            end
        end
    end
    
    logger.info("BookloreSync Database: Migrated", migrated_books, "book cache entries,", failed_books, "failed")
    
    -- Migrate pending sessions
    local pending_sessions = local_db:readSetting("pending_sessions") or {}
    local migrated_sessions = 0
    local failed_sessions = 0
    
    for i, session in ipairs(pending_sessions) do
        -- Validate session data before migrating
        if session.bookHash and session.startTime and session.endTime and session.durationSeconds then
            local result = self:addPendingSession(session)
            if result then
                migrated_sessions = migrated_sessions + 1
            else
                failed_sessions = failed_sessions + 1
                logger.warn("BookloreSync Database: Failed to migrate session", i)
            end
        else
            failed_sessions = failed_sessions + 1
            logger.warn("BookloreSync Database: Skipping invalid session", i, "- missing required fields")
        end
    end
    
    logger.info("BookloreSync Database: Migrated", migrated_sessions, "pending sessions,", failed_sessions, "failed/invalid")
    
    if failed_books > 0 or failed_sessions > 0 then
        logger.warn("BookloreSync Database: Migration completed with errors")
        success = false
    end
    
    return success
end

return Database
