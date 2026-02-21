--[[--
Booklore Database Module

Provides SQLite database management with migration support for the Booklore plugin.

@module koplugin.BookloreSync.database
--]]--

local SQ3 = require("lua-ljsqlite3/init")
local DataStorage = require("datastorage")
local LuaSettings = require("luasettings")
local logger = require("logger")

local Database = {
    VERSION = 12,  -- Current database schema version
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
    
    -- Migration 2: Historical sessions table
    [2] = {
        [[
            CREATE TABLE IF NOT EXISTS historical_sessions (
                id INTEGER PRIMARY KEY AUTOINCREMENT,
                koreader_book_id INTEGER NOT NULL,
                koreader_book_title TEXT NOT NULL,
                book_id INTEGER,
                book_hash TEXT,
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
                matched BOOLEAN DEFAULT 0,
                synced BOOLEAN DEFAULT 0,
                UNIQUE(koreader_book_id, start_time, end_time)
            )
        ]],
        [[
            CREATE INDEX IF NOT EXISTS idx_historical_koreader_book 
            ON historical_sessions(koreader_book_id)
        ]],
        [[
            CREATE INDEX IF NOT EXISTS idx_historical_matched 
            ON historical_sessions(matched)
        ]],
        [[
            CREATE INDEX IF NOT EXISTS idx_historical_book_id 
            ON historical_sessions(book_id)
        ]],
        [[
            CREATE INDEX IF NOT EXISTS idx_historical_book_hash 
            ON historical_sessions(book_hash)
        ]],
    },
    
    -- Migration 3: Add ISBN support to book_cache
    [3] = {
        -- Add ISBN-10 column
        [[
            ALTER TABLE book_cache ADD COLUMN isbn10 TEXT
        ]],
        -- Add ISBN-13 column
        [[
            ALTER TABLE book_cache ADD COLUMN isbn13 TEXT
        ]],
        -- Create index for ISBN-10 lookups
        [[
            CREATE INDEX IF NOT EXISTS idx_book_cache_isbn10 
            ON book_cache(isbn10)
        ]],
        -- Create index for ISBN-13 lookups
        [[
            CREATE INDEX IF NOT EXISTS idx_book_cache_isbn13 
            ON book_cache(isbn13)
        ]],
    },
    
    -- Migration 4: Bearer token cache table
    [4] = {
        -- Store Bearer tokens to avoid duplicate token errors
        [[
            CREATE TABLE IF NOT EXISTS bearer_tokens (
                id INTEGER PRIMARY KEY AUTOINCREMENT,
                username TEXT UNIQUE NOT NULL,
                token TEXT NOT NULL,
                created_at INTEGER DEFAULT (strftime('%s', 'now')),
                expires_at INTEGER NOT NULL
            )
        ]],
        [[
            CREATE INDEX IF NOT EXISTS idx_bearer_tokens_username 
            ON bearer_tokens(username)
        ]],
        [[
            CREATE INDEX IF NOT EXISTS idx_bearer_tokens_expires 
            ON bearer_tokens(expires_at)
        ]],
    },
    
    -- Migration 5: Remove unused match_history table
    [5] = {
        -- Drop the index first
        [[
            DROP INDEX IF EXISTS idx_match_history_file_hash
        ]],
        -- Then drop the table
        [[
            DROP TABLE IF EXISTS match_history
        ]],
    },
    
    -- Migration 6: Add book_title to pending_sessions
    [6] = {
        -- Add book_title column to store the title for archiving
        [[
            ALTER TABLE pending_sessions ADD COLUMN book_title TEXT
        ]],
    },
    
    -- Migration 7: Add koreader_book_id to pending_sessions
    [7] = {
        -- Add koreader_book_id column to store the KOReader book ID
        [[
            ALTER TABLE pending_sessions ADD COLUMN koreader_book_id INTEGER
        ]],
    },
    
    -- Migration 8: Add updater_cache table for caching GitHub release info
    [8] = {
        -- Create updater_cache table for caching release information
        [[
            CREATE TABLE IF NOT EXISTS updater_cache (
                key TEXT PRIMARY KEY,
                value TEXT NOT NULL,
                cached_at INTEGER NOT NULL
            )
        ]],
    },

    -- Migration 9: Extended sync tables (book metadata location, rating, annotations)
    [9] = {
        -- Store detected .sdr path and rating sync state per book
        [[
            CREATE TABLE IF NOT EXISTS book_metadata (
                id INTEGER PRIMARY KEY AUTOINCREMENT,
                book_cache_id INTEGER NOT NULL,
                sdr_path TEXT,
                rating INTEGER,
                rating_synced INTEGER DEFAULT 0,
                created_at INTEGER DEFAULT (strftime('%s', 'now')),
                updated_at INTEGER DEFAULT (strftime('%s', 'now')),
                UNIQUE(book_cache_id)
            )
        ]],
        [[
            CREATE INDEX IF NOT EXISTS idx_book_metadata_book_cache_id
            ON book_metadata(book_cache_id)
        ]],
        -- Deduplication tracker for uploaded highlights and notes
        [[
            CREATE TABLE IF NOT EXISTS synced_annotations (
                id INTEGER PRIMARY KEY AUTOINCREMENT,
                book_cache_id INTEGER NOT NULL,
                koreader_datetime TEXT NOT NULL,
                annotation_type TEXT NOT NULL,
                destination TEXT NOT NULL,
                server_id INTEGER,
                synced_at INTEGER,
                UNIQUE(book_cache_id, koreader_datetime, annotation_type)
            )
        ]],
        [[
            CREATE INDEX IF NOT EXISTS idx_synced_annotations_book
            ON synced_annotations(book_cache_id)
        ]],
    },

    -- Migration 10: Persist plugin settings in SQLite and add rating sync history
    [10] = {
        -- Key-value store that replaces the booklore.lua LuaSettings file.
        -- All plugin configuration (server URL, credentials, sync options, …) is
        -- stored here so that a single SQLite file contains the complete plugin state.
        [[
            CREATE TABLE IF NOT EXISTS plugin_settings (
                key        TEXT PRIMARY KEY,
                value      TEXT,
                updated_at INTEGER DEFAULT (strftime('%s', 'now'))
            )
        ]],

        -- Per-book audit trail of every rating that was successfully pushed to the
        -- Booklore server.  Complements the book_metadata.rating_synced flag with
        -- full history (value synced, timestamp, outcome).
        [[
            CREATE TABLE IF NOT EXISTS rating_sync_history (
                id            INTEGER PRIMARY KEY AUTOINCREMENT,
                book_cache_id INTEGER NOT NULL,
                rating        INTEGER NOT NULL,
                synced_at     INTEGER DEFAULT (strftime('%s', 'now')),
                status        TEXT    NOT NULL DEFAULT 'success',
                error_message TEXT,
                FOREIGN KEY(book_cache_id) REFERENCES book_cache(id)
            )
        ]],
        [[
            CREATE INDEX IF NOT EXISTS idx_rating_sync_history_book
            ON rating_sync_history(book_cache_id)
        ]],
    },

    -- Migration 11: Pending ratings queue
    -- Stores ratings that failed to sync so they can be retried on the next
    -- upload (session, note, or explicit sync trigger).
    [11] = {
        [[
            CREATE TABLE IF NOT EXISTS pending_ratings (
                id            INTEGER PRIMARY KEY AUTOINCREMENT,
                book_cache_id INTEGER NOT NULL UNIQUE,
                book_id       INTEGER NOT NULL,
                rating        INTEGER NOT NULL,
                retry_count   INTEGER DEFAULT 0,
                last_retry_at INTEGER,
                created_at    INTEGER DEFAULT (strftime('%s', 'now')),
                FOREIGN KEY(book_cache_id) REFERENCES book_cache(id)
            )
        ]],
        [[
            CREATE INDEX IF NOT EXISTS idx_pending_ratings_book_cache_id
            ON pending_ratings(book_cache_id)
        ]],
    },

    -- Migration 12: Deferred rating prompt flag on book_metadata
    -- When a book is completed (>=99%) but no Booklore book_id is known yet
    -- (server was offline at open time), we cannot show the rating dialog
    -- immediately.  This column acts as a reminder: once a book_id is resolved
    -- the next sync run will show the dialog (select_at_complete) or push the
    -- KOReader rating (koreader_scaled) automatically.
    [12] = {
        [[
            ALTER TABLE book_metadata ADD COLUMN pending_rating_prompt INTEGER DEFAULT 0
        ]],
    },
}

-- Post-migration hooks (Lua functions run AFTER the SQL transaction commits).
-- Each hook receives the Database instance as its only argument.
-- Return true on success, false on failure (failure is logged but non-fatal
-- so that the schema version is still recorded and the migration is not retried).
Database.migration_hooks = {
    -- Migration 10: copy all settings from booklore.lua into plugin_settings,
    -- then delete the LuaSettings file so it is no longer used.
    [10] = function(db)
        local settings_path = DataStorage:getSettingsDir() .. "/booklore.lua"
        local f = io.open(settings_path, "r")
        if not f then
            logger.info("BookloreSync Database: Migration 10 hook: booklore.lua not found, skipping import")
            return true
        end
        f:close()

        logger.info("BookloreSync Database: Migration 10 hook: importing settings from booklore.lua")

        local ok, lua_settings = pcall(function()
            return LuaSettings:open(settings_path)
        end)
        if not ok or not lua_settings then
            logger.err("BookloreSync Database: Migration 10 hook: failed to open booklore.lua:", lua_settings)
            return false
        end

        -- All known settings keys with their storage types.
        -- "bool" values are stored as "true"/"false" strings; numbers as their
        -- decimal string representation; everything else as plain strings.
        local keys = {
            "server_url", "username", "password",
            "is_enabled", "log_to_file", "silent_messages", "secure_logs",
            "min_duration", "min_pages", "session_detection_mode",
            "progress_decimal_places",
            "force_push_session_on_suspend", "connect_network_on_suspend",
            "manual_sync_only", "sync_mode",
            "historical_sync_ack",
            "booklore_username", "booklore_password",
            "extended_sync_enabled", "rating_sync_enabled", "rating_sync_mode",
            "highlights_notes_sync_enabled", "notes_destination", "upload_strategy",
            "auto_update_check", "last_update_check",
        }

        local imported = 0
        local stmt = db.conn:prepare([[
            INSERT OR REPLACE INTO plugin_settings (key, value, updated_at)
            VALUES (?, ?, CAST(strftime('%s', 'now') AS INTEGER))
        ]])
        if not stmt then
            logger.err("BookloreSync Database: Migration 10 hook: failed to prepare INSERT:", db.conn:errmsg())
            return false
        end

        for _, key in ipairs(keys) do
            local raw = lua_settings:readSetting(key)
            if raw ~= nil then
                -- Serialise to string: booleans become "true"/"false", numbers
                -- become their decimal string, everything else stays as-is.
                local value_str
                local t = type(raw)
                if t == "boolean" then
                    value_str = raw and "true" or "false"
                elseif t == "number" then
                    value_str = tostring(raw)
                elseif t == "string" then
                    value_str = raw
                else
                    -- Skip unsupported types (tables, etc.)
                    logger.warn("BookloreSync Database: Migration 10 hook: skipping key", key, "with unsupported type", t)
                    goto continue
                end

                local bind_ok, bind_err = pcall(function()
                    stmt:bind(key, value_str)
                end)
                if bind_ok then
                    local step_result = stmt:step()
                    stmt:reset()
                    if step_result == SQ3.DONE or step_result == SQ3.OK then
                        imported = imported + 1
                    else
                        logger.warn("BookloreSync Database: Migration 10 hook: failed to insert key", key)
                    end
                else
                    logger.warn("BookloreSync Database: Migration 10 hook: bind failed for key", key, ":", bind_err)
                end
                ::continue::
            end
        end
        stmt:close()

        logger.info("BookloreSync Database: Migration 10 hook: imported", imported, "settings")

        -- Delete the original LuaSettings file now that settings live in the DB
        local remove_ok, remove_err = os.remove(settings_path)
        if remove_ok then
            logger.info("BookloreSync Database: Migration 10 hook: deleted booklore.lua")
        else
            -- Non-fatal: the file may have been removed already, or permissions
            -- may prevent deletion on some e-reader configurations.
            logger.warn("BookloreSync Database: Migration 10 hook: could not delete booklore.lua:", remove_err)
        end

        return true
    end,
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
    
    -- Checkpoint any existing WAL file before changing journal mode
    -- This is necessary when migrating from WAL mode to TRUNCATE mode
    -- Without this, the journal_mode change may fail with "database is locked"
    local checkpoint_ok, checkpoint_err = pcall(function()
        self.conn:exec("PRAGMA wal_checkpoint(TRUNCATE)")
    end)
    if not checkpoint_ok then
        -- Not fatal - there may be no WAL file, or db might be locked by another instance
        logger.dbg("BookloreSync Database: WAL checkpoint skipped:", checkpoint_err)
    end
    
    -- Use TRUNCATE journal mode for reliability on e-readers
    -- - Avoids WAL checkpoint issues on Android-based devices
    -- - Faster than DELETE mode (journal file reused, not deleted)
    -- - More reliable on unexpected power loss or process termination
    -- - No separate WAL/SHM files to manage
    local journal_ok, journal_err = pcall(function()
        self.conn:exec("PRAGMA journal_mode = TRUNCATE")
    end)
    
    if not journal_ok then
        logger.warn("BookloreSync Database: Could not set TRUNCATE mode:", journal_err)
        logger.warn("This may happen if another KOReader instance is using the database.")
        logger.warn("The database will continue using its current journal mode.")
        -- Continue anyway - the database will use whatever mode it's already in
        -- This is non-fatal; TRUNCATE is preferred but not required for operation
    else
        logger.dbg("BookloreSync Database: Successfully set TRUNCATE journal mode")
    end
    
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
        version = tonumber(row[1]) or 0
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
                stmt:bind(version)
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

            -- Run optional post-migration Lua hook (non-fatal on failure)
            local hook = self.migration_hooks and self.migration_hooks[version]
            if hook then
                logger.info("BookloreSync Database: Running post-migration hook for version", version)
                local hook_ok, hook_err = pcall(hook, self)
                if not hook_ok then
                    logger.err("BookloreSync Database: Post-migration hook", version, "threw an error:", hook_err)
                elseif hook_err == false then
                    logger.warn("BookloreSync Database: Post-migration hook", version, "reported failure (non-fatal)")
                else
                    logger.info("BookloreSync Database: Post-migration hook", version, "completed successfully")
                end
            end
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
    logger.dbg("BookloreSync Database: getBookByFilePath called")
    logger.dbg("  file_path:", file_path, "type:", type(file_path))
    
    -- Ensure file_path is a string
    file_path = tostring(file_path)
    
    local stmt = self.conn:prepare([[
        SELECT id, file_path, file_hash, book_id, title, author, last_accessed, isbn10, isbn13
        FROM book_cache
        WHERE file_path = ?
    ]])
    
    if not stmt then
        logger.err("BookloreSync Database: Failed to prepare statement:", self.conn:errmsg())
        return nil
    end
    
    logger.dbg("BookloreSync Database: About to bind file_path:", file_path, "type:", type(file_path))
    
    -- bind() takes values in order, not (index, value)
    local bind_ok, bind_err = pcall(function()
        stmt:bind(file_path)
    end)
    
    if not bind_ok then
        logger.err("BookloreSync Database: Failed to bind file_path:", bind_err)
        stmt:close()
        return nil
    end
    
    logger.dbg("BookloreSync Database: Bind successful, executing query")
    
    local book = nil
    for row in stmt:rows() do
        book = {
            id = tonumber(row[1]),
            file_path = tostring(row[2]),
            file_hash = tostring(row[3]),
            book_id = row[4] and tonumber(row[4]) or nil,
            title = row[5] and tostring(row[5]) or nil,
            author = row[6] and tostring(row[6]) or nil,
            last_accessed = row[7] and tonumber(row[7]) or nil,
            isbn10 = row[8] and tostring(row[8]) or nil,
            isbn13 = row[9] and tostring(row[9]) or nil,
        }
        break
    end
    
    stmt:close()
    return book
end

function Database:getBookByHash(file_hash)
    local stmt = self.conn:prepare([[
        SELECT id, file_path, file_hash, book_id, title, author, last_accessed, isbn10, isbn13
        FROM book_cache
        WHERE file_hash = ?
        LIMIT 1
    ]])
    
    if not stmt then
        logger.err("BookloreSync Database: Failed to prepare statement:", self.conn:errmsg())
        return nil
    end
    
    stmt:bind(file_hash)
    
    local book = nil
    for row in stmt:rows() do
        book = {
            id = tonumber(row[1]),
            file_path = tostring(row[2]),
            file_hash = tostring(row[3]),
            book_id = row[4] and tonumber(row[4]) or nil,
            title = row[5] and tostring(row[5]) or nil,
            author = row[6] and tostring(row[6]) or nil,
            last_accessed = row[7] and tonumber(row[7]) or nil,
            isbn10 = row[8] and tostring(row[8]) or nil,
            isbn13 = row[9] and tostring(row[9]) or nil,
        }
        break
    end
    
    stmt:close()
    return book
end

function Database:getBookByBookId(book_id)
    -- Ensure book_id is a number
    book_id = tonumber(book_id)
    if not book_id then
        logger.err("BookloreSync Database: Invalid book_id provided to getBookByBookId")
        return nil
    end
    
    local stmt = self.conn:prepare([[
        SELECT id, file_path, file_hash, book_id, title, author, last_accessed
        FROM book_cache
        WHERE book_id = ?
        LIMIT 1
    ]])
    
    if not stmt then
        logger.err("BookloreSync Database: Failed to prepare statement:", self.conn:errmsg())
        return nil
    end
    
    stmt:bind(book_id)
    
    local book = nil
    for row in stmt:rows() do
        book = {
            id = tonumber(row[1]),
            file_path = tostring(row[2]),
            file_hash = tostring(row[3]),
            book_id = row[4] and tonumber(row[4]) or nil,
            title = row[5] and tostring(row[5]) or nil,
            author = row[6] and tostring(row[6]) or nil,
            last_accessed = row[7] and tonumber(row[7]) or nil,
        }
        break
    end
    
    stmt:close()
    return book
end

function Database:saveBookCache(file_path, file_hash, book_id, title, author, isbn10, isbn13)
    -- Ensure types are correct
    file_path = tostring(file_path or "")
    file_hash = tostring(file_hash or "")
    
    -- Validate inputs - don't save if both file_path and file_hash are empty
    if file_path == "" and file_hash == "" then
        logger.warn("BookloreSync Database: Cannot save book cache with empty file_path and file_hash")
        return false
    end
    
    -- Debug logging
    logger.dbg("BookloreSync Database: saveBookCache called with:")
    logger.dbg("  file_path:", file_path, "type:", type(file_path))
    logger.dbg("  file_hash:", file_hash, "type:", type(file_hash))
    logger.dbg("  book_id:", book_id, "type:", type(book_id))
    logger.dbg("  title:", title, "type:", type(title))
    logger.dbg("  author:", author, "type:", type(author))
    logger.dbg("  isbn10:", isbn10, "type:", type(isbn10))
    logger.dbg("  isbn13:", isbn13, "type:", type(isbn13))
    
    -- book_id can be nil (NULL) or must be a number
    if book_id ~= nil then
        local original_book_id = book_id
        book_id = tonumber(book_id)
        if not book_id then
            logger.warn("BookloreSync Database: Invalid book_id, setting to NULL. Original value:", original_book_id, "type:", type(original_book_id))
            book_id = nil
        end
    end
    
    logger.dbg("BookloreSync Database: After conversion, book_id:", book_id, "type:", type(book_id))
    
    -- Use INSERT OR REPLACE to upsert in one operation
    -- The UNIQUE constraint on file_path ensures we don't get duplicates
    local stmt = self.conn:prepare([[
        INSERT OR REPLACE INTO book_cache (file_path, file_hash, book_id, title, author, isbn10, isbn13, last_accessed)
        VALUES (?, ?, ?, ?, ?, ?, ?, CAST(strftime('%s', 'now') AS INTEGER))
    ]])
    
    if not stmt then
        logger.err("BookloreSync Database: Failed to prepare statement:", self.conn:errmsg())
        return false
    end
    
    stmt:bind(file_path, file_hash, book_id, title, author, isbn10, isbn13)
    
    local result = stmt:step()
    stmt:close()
    
    if result ~= SQ3.DONE and result ~= SQ3.OK then
        logger.err("BookloreSync Database: Failed to save book cache:", self.conn:errmsg())
        return false
    end
    
    logger.dbg("BookloreSync Database: Book cache saved successfully")
    return true
end

-- Convenience method for caching a book
function Database:cacheBook(file_path, file_hash, book_id)
    return self:saveBookCache(file_path, file_hash, book_id, nil, nil, nil, nil)
end

function Database:updateBookId(file_hash, book_id)
    -- Ensure book_id is a number
    if book_id ~= nil then
        book_id = tonumber(book_id)
        if not book_id then
            logger.warn("BookloreSync Database: Invalid book_id in updateBookId, aborting")
            return false
        end
    end
    
    local stmt = self.conn:prepare([[
        UPDATE book_cache 
        SET book_id = ?, updated_at = CAST(strftime('%s', 'now') AS INTEGER)
        WHERE file_hash = ?
    ]])
    
    if not stmt then
        logger.err("BookloreSync Database: Failed to prepare statement:", self.conn:errmsg())
        return false
    end
    
    stmt:bind(book_id, file_hash)
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
            id = tonumber(row[1]),
            file_path = tostring(row[2]),
            file_hash = tostring(row[3]),
            title = row[4] and tostring(row[4]) or nil,
            author = row[5] and tostring(row[5]) or nil,
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
        stats.total = tonumber(row[1]) or 0
        stats.matched = tonumber(row[2]) or 0
        stats.unmatched = tonumber(row[3]) or 0
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
    -- Ensure book_id is a number if present
    local book_id = session_data.bookId
    if book_id ~= nil then
        book_id = tonumber(book_id)
        if not book_id then
            logger.warn("BookloreSync Database: Invalid bookId in session_data, setting to NULL")
            book_id = nil
        end
    end
    
    -- Ensure duration_seconds is a number
    local duration_seconds = tonumber(session_data.durationSeconds) or 0
    
    local stmt = self.conn:prepare([[
        INSERT INTO pending_sessions (
            book_id, book_hash, book_title, koreader_book_id, book_type, start_time, end_time,
            duration_seconds, start_progress, end_progress, progress_delta,
            start_location, end_location
        ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
    ]])
    
    if not stmt then
        logger.err("BookloreSync Database: Failed to prepare statement:", self.conn:errmsg())
        return false
    end
    
    stmt:bind(
        book_id,
        session_data.bookHash or "",
        session_data.bookTitle or "Unknown",
        session_data.koreaderBookId,  -- Can be nil
        session_data.bookType or "EPUB",
        session_data.startTime or "",
        session_data.endTime or "",
        duration_seconds,
        session_data.startProgress or 0.0,
        session_data.endProgress or 0.0,
        session_data.progressDelta or 0.0,
        session_data.startLocation or "0",
        session_data.endLocation or "0"
    )
    
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
        SELECT id, book_id, book_hash, book_title, koreader_book_id, book_type, start_time, end_time,
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
    
    stmt:bind(limit)
    
    local sessions = {}
    for row in stmt:rows() do
        table.insert(sessions, {
            id = tonumber(row[1]),
            bookId = row[2] and tonumber(row[2]) or nil,
            bookHash = tostring(row[3]),
            bookTitle = row[4] and tostring(row[4]) or "Unknown",
            koreaderBookId = row[5] and tonumber(row[5]) or nil,
            bookType = tostring(row[6]),
            startTime = tostring(row[7]),
            endTime = tostring(row[8]),
            durationSeconds = tonumber(row[9]),
            startProgress = tonumber(row[10]),
            endProgress = tonumber(row[11]),
            progressDelta = tonumber(row[12]),
            startLocation = tostring(row[13]),
            endLocation = tostring(row[14]),
            retryCount = tonumber(row[15]),
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
    
    stmt:bind(session_id)
    stmt:step()
    stmt:close()
    
    return true
end

function Database:archivePendingSession(session_id)
    -- Archive a pending session to historical_sessions before deletion
    -- This provides a backup in case of data loss
    
    -- First, get the pending session data
    local get_stmt = self.conn:prepare([[
        SELECT 
            book_id, book_hash, book_title, koreader_book_id, book_type, start_time, end_time,
            duration_seconds, start_progress, end_progress, progress_delta,
            start_location, end_location
        FROM pending_sessions
        WHERE id = ?
    ]])
    
    if not get_stmt then
        logger.err("BookloreSync Database: Failed to prepare select statement:", self.conn:errmsg())
        return false
    end
    
    get_stmt:bind(session_id)
    
    local session_data = nil
    for row in get_stmt:rows() do
        session_data = {
            book_id = row[1] and tonumber(row[1]) or nil,
            book_hash = tostring(row[2] or ""),
            book_title = row[3] and tostring(row[3]) or "Unknown",
            koreader_book_id = row[4] and tonumber(row[4]) or nil,
            book_type = tostring(row[5] or "EPUB"),
            start_time = tostring(row[6]),
            end_time = tostring(row[7]),
            duration_seconds = tonumber(row[8]) or 0,
            start_progress = tonumber(row[9]) or 0,
            end_progress = tonumber(row[10]) or 0,
            progress_delta = tonumber(row[11]) or 0,
            start_location = tostring(row[12] or ""),
            end_location = tostring(row[13] or ""),
        }
        break
    end
    
    get_stmt:close()
    
    if not session_data then
        logger.warn("BookloreSync Database: No pending session found with id:", session_id)
        return false
    end
    
    -- Use the stored title and koreader_book_id directly
    local book_title = session_data.book_title
    local koreader_book_id = session_data.koreader_book_id or 0
    local insert_stmt = self.conn:prepare([[
        INSERT INTO historical_sessions (
            koreader_book_id, koreader_book_title, book_id, book_hash,
            book_type, start_time, end_time, duration_seconds,
            start_progress, end_progress, progress_delta,
            start_location, end_location, matched, synced
        ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, 1, 1)
    ]])
    
    if not insert_stmt then
        logger.err("BookloreSync Database: Failed to prepare insert statement:", self.conn:errmsg())
        return false
    end
    
    insert_stmt:bind(
        koreader_book_id,
        book_title,
        session_data.book_id,
        session_data.book_hash,
        session_data.book_type,
        session_data.start_time,
        session_data.end_time,
        session_data.duration_seconds,
        session_data.start_progress,
        session_data.end_progress,
        session_data.progress_delta,
        session_data.start_location,
        session_data.end_location
    )
    
    local result = insert_stmt:step()
    insert_stmt:close()
    
    if result == SQ3.DONE or result == SQ3.OK then
        logger.info("BookloreSync Database: Archived pending session to historical_sessions")
        return true
    else
        logger.err("BookloreSync Database: Failed to archive pending session:", self.conn:errmsg())
        return false
    end
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
        count = tonumber(row[1]) or 0
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
    
    stmt:bind(session_id)
    stmt:step()
    stmt:close()
    
    return true
end

-- Historical Session Functions

function Database:getUnmatchedHistoricalBooks()
    -- Get books that have at least one session without a book_id
    -- This excludes books where all sessions were successfully auto-matched
    local stmt = self.conn:prepare([[
        SELECT 
            koreader_book_id,
            koreader_book_title,
            book_hash,
            COUNT(*) as session_count
        FROM historical_sessions
        WHERE book_id IS NULL
        GROUP BY koreader_book_id
        ORDER BY koreader_book_title
    ]])
    
    if not stmt then
        logger.err("BookloreSync Database: Failed to prepare statement:", self.conn:errmsg())
        return {}
    end
    
    local books = {}
    for row in stmt:rows() do
        table.insert(books, {
            koreader_book_id = tonumber(row[1]),
            koreader_book_title = tostring(row[2]),
            book_hash = tostring(row[3] or ""),
            session_count = tonumber(row[4]),
        })
    end
    
    stmt:close()
    return books
end

function Database:getMatchedUnsyncedBooks()
    -- Get books that have sessions with book_id but not yet synced
    -- These are typically books auto-matched during extraction
    local stmt = self.conn:prepare([[
        SELECT 
            koreader_book_id,
            koreader_book_title,
            book_id,
            COUNT(*) as unsynced_session_count
        FROM historical_sessions
        WHERE book_id IS NOT NULL AND synced = 0
        GROUP BY koreader_book_id
        ORDER BY koreader_book_title
    ]])
    
    if not stmt then
        logger.err("BookloreSync Database: Failed to prepare statement:", self.conn:errmsg())
        return {}
    end
    
    local books = {}
    for row in stmt:rows() do
        table.insert(books, {
            koreader_book_id = tonumber(row[1]),
            koreader_book_title = tostring(row[2]),
            book_id = tonumber(row[3]),
            unsynced_session_count = tonumber(row[4]),
        })
    end
    
    stmt:close()
    return books
end

function Database:getHistoricalSessionsForBook(koreader_book_id)
    local stmt = self.conn:prepare([[
        SELECT 
            id, book_id, book_type, start_time, end_time,
            duration_seconds, start_progress, end_progress, progress_delta,
            start_location, end_location, synced
        FROM historical_sessions
        WHERE koreader_book_id = ? AND matched = 1
        ORDER BY start_time
    ]])
    
    if not stmt then
        logger.err("BookloreSync Database: Failed to prepare statement:", self.conn:errmsg())
        return {}
    end
    
    stmt:bind(koreader_book_id)
    
    local sessions = {}
    for row in stmt:rows() do
        table.insert(sessions, {
            id = tonumber(row[1]),
            book_id = tonumber(row[2]),
            book_type = tostring(row[3]),
            start_time = tostring(row[4]),
            end_time = tostring(row[5]),
            duration_seconds = tonumber(row[6]),
            start_progress = tonumber(row[7]),
            end_progress = tonumber(row[8]),
            progress_delta = tonumber(row[9]),
            start_location = tostring(row[10]),
            end_location = tostring(row[11]),
            synced = tonumber(row[12]) or 0,
        })
    end
    
    stmt:close()
    return sessions
end

function Database:getHistoricalSessionsForBookUnsynced(koreader_book_id)
    -- Get only unsynced sessions for a specific book
    -- Used during auto-sync phase of Match Historical Data
    local stmt = self.conn:prepare([[
        SELECT 
            id, book_id, book_type, start_time, end_time,
            duration_seconds, start_progress, end_progress, progress_delta,
            start_location, end_location, synced
        FROM historical_sessions
        WHERE koreader_book_id = ? AND book_id IS NOT NULL AND synced = 0
        ORDER BY start_time
    ]])
    
    if not stmt then
        logger.err("BookloreSync Database: Failed to prepare statement:", self.conn:errmsg())
        return {}
    end
    
    stmt:bind(koreader_book_id)
    
    local sessions = {}
    for row in stmt:rows() do
        table.insert(sessions, {
            id = tonumber(row[1]),
            book_id = tonumber(row[2]),
            book_type = tostring(row[3]),
            start_time = tostring(row[4]),
            end_time = tostring(row[5]),
            duration_seconds = tonumber(row[6]),
            start_progress = tonumber(row[7]),
            end_progress = tonumber(row[8]),
            progress_delta = tonumber(row[9]),
            start_location = tostring(row[10] or ""),
            end_location = tostring(row[11] or ""),
            synced = tonumber(row[12]) or 0,
        })
    end
    
    stmt:close()
    return sessions
end

function Database:markHistoricalSessionsMatched(koreader_book_id, book_id)
    local stmt = self.conn:prepare([[
        UPDATE historical_sessions 
        SET matched = 1, book_id = ?
        WHERE koreader_book_id = ?
    ]])
    
    if not stmt then
        logger.err("BookloreSync Database: Failed to prepare statement:", self.conn:errmsg())
        return false
    end
    
    stmt:bind(book_id, koreader_book_id)
    local result = stmt:step()
    stmt:close()
    
    return result == SQ3.DONE or result == SQ3.OK
end

function Database:addHistoricalSessions(sessions)
    if #sessions == 0 then
        return true
    end
    
    local stmt = self.conn:prepare([[
        INSERT OR IGNORE INTO historical_sessions (
            koreader_book_id, koreader_book_title, book_id, book_hash,
            book_type, start_time, end_time, duration_seconds,
            start_progress, end_progress, progress_delta,
            start_location, end_location, matched
        ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
    ]])
    
    if not stmt then
        logger.err("BookloreSync Database: Failed to prepare statement:", self.conn:errmsg())
        return false
    end
    
    local success_count = 0
    for _, session in ipairs(sessions) do
        stmt:bind(
            session.koreader_book_id,
            session.koreader_book_title,
            session.book_id,
            session.book_hash or "",
            session.book_type or "EPUB",
            session.start_time,
            session.end_time,
            session.duration_seconds,
            session.start_progress,
            session.end_progress,
            session.progress_delta,
            session.start_location or "",
            session.end_location or "",
            session.matched or 0
        )
        
        local result = stmt:step()
        if result == SQ3.DONE or result == SQ3.OK then
            success_count = success_count + 1
        end
        stmt:reset()
    end
    
    stmt:close()
    logger.info("BookloreSync Database: Inserted", success_count, "of", #sessions, "historical sessions")
    return success_count == #sessions
end

function Database:getHistoricalSessionStats()
    local stmt = self.conn:prepare([[
        SELECT 
            COUNT(*) as total,
            SUM(CASE WHEN matched = 1 THEN 1 ELSE 0 END) as matched,
            SUM(CASE WHEN matched = 0 THEN 1 ELSE 0 END) as unmatched,
            SUM(CASE WHEN synced = 1 THEN 1 ELSE 0 END) as synced
        FROM historical_sessions
    ]])
    
    if not stmt then
        return {total_sessions = 0, matched_sessions = 0, unmatched_sessions = 0, synced_sessions = 0}
    end
    
    local stats = {}
    for row in stmt:rows() do
        stats = {
            total_sessions = tonumber(row[1]) or 0,
            matched_sessions = tonumber(row[2]) or 0,
            unmatched_sessions = tonumber(row[3]) or 0,
            synced_sessions = tonumber(row[4]) or 0,
        }
        break
    end
    
    stmt:close()
    return stats
end

function Database:markHistoricalSessionSynced(session_id)
    local stmt = self.conn:prepare([[
        UPDATE historical_sessions 
        SET synced = 1
        WHERE id = ?
    ]])
    
    if not stmt then
        logger.err("BookloreSync Database: Failed to prepare statement:", self.conn:errmsg())
        return false
    end
    
    stmt:bind(session_id)
    local result = stmt:step()
    stmt:close()
    
    return result == SQ3.DONE or result == SQ3.OK
end

function Database:markHistoricalSessionUnmatched(session_id)
    -- Mark a session as unmatched and not synced (for re-matching after 404)
    local stmt = self.conn:prepare([[
        UPDATE historical_sessions 
        SET matched = 0, synced = 0, book_id = NULL
        WHERE id = ?
    ]])
    
    if not stmt then
        logger.err("BookloreSync Database: Failed to prepare statement:", self.conn:errmsg())
        return false
    end
    
    stmt:bind(session_id)
    local result = stmt:step()
    stmt:close()
    
    return result == SQ3.DONE or result == SQ3.OK
end

function Database:getAllSyncedHistoricalSessions()
    -- Get all synced historical sessions for re-sync
    local stmt = self.conn:prepare([[
        SELECT 
            id, koreader_book_id, koreader_book_title, book_id, book_type,
            start_time, end_time, duration_seconds, start_progress, end_progress,
            progress_delta, start_location, end_location
        FROM historical_sessions
        WHERE synced = 1 AND book_id IS NOT NULL
        ORDER BY start_time
    ]])
    
    if not stmt then
        logger.err("BookloreSync Database: Failed to prepare statement:", self.conn:errmsg())
        return {}
    end
    
    local sessions = {}
    for row in stmt:rows() do
        table.insert(sessions, {
            id = tonumber(row[1]),
            koreader_book_id = tonumber(row[2]),
            koreader_book_title = tostring(row[3]),
            book_id = tonumber(row[4]),
            book_type = tostring(row[5]),
            start_time = tostring(row[6]),
            end_time = tostring(row[7]),
            duration_seconds = tonumber(row[8]),
            start_progress = tonumber(row[9]),
            end_progress = tonumber(row[10]),
            progress_delta = tonumber(row[11]),
            start_location = tostring(row[12] or ""),
            end_location = tostring(row[13] or ""),
        })
    end
    
    stmt:close()
    return sessions
end

function Database:getMatchedUnsyncedHistoricalSessions()
    -- Get sessions that are matched (have book_id) but not yet synced
    -- These are typically sessions that were re-matched after a 404 error
    local stmt = self.conn:prepare([[
        SELECT 
            id, koreader_book_id, koreader_book_title, book_id, book_type,
            start_time, end_time, duration_seconds, start_progress, end_progress,
            progress_delta, start_location, end_location
        FROM historical_sessions
        WHERE matched = 1 AND synced = 0 AND book_id IS NOT NULL
        ORDER BY start_time
    ]])
    
    if not stmt then
        logger.err("BookloreSync Database: Failed to prepare statement:", self.conn:errmsg())
        return {}
    end
    
    local sessions = {}
    for row in stmt:rows() do
        table.insert(sessions, {
            id = tonumber(row[1]),
            koreader_book_id = tonumber(row[2]),
            koreader_book_title = tostring(row[3]),
            book_id = tonumber(row[4]),
            book_type = tostring(row[5]),
            start_time = tostring(row[6]),
            end_time = tostring(row[7]),
            duration_seconds = tonumber(row[8]),
            start_progress = tonumber(row[9]),
            end_progress = tonumber(row[10]),
            progress_delta = tonumber(row[11]),
            start_location = tostring(row[12] or ""),
            end_location = tostring(row[13] or ""),
        })
    end
    
    stmt:close()
    return sessions
end

function Database:hasHistoricalSessions()
    local stmt = self.conn:prepare("SELECT COUNT(*) FROM historical_sessions LIMIT 1")
    
    if not stmt then
        return false
    end
    
    local has_sessions = false
    for row in stmt:rows() do
        has_sessions = tonumber(row[1]) > 0
        break
    end
    
    stmt:close()
    return has_sessions
end

function Database:findBookIdByHash(md5_hash)
    if not md5_hash or md5_hash == "" then
        return nil
    end
    
    local stmt = self.conn:prepare([[
        SELECT book_id, title, author
        FROM book_cache
        WHERE file_hash = ? AND book_id IS NOT NULL
        LIMIT 1
    ]])
    
    if not stmt then
        return nil
    end
    
    stmt:bind(md5_hash)
    
    local result = nil
    for row in stmt:rows() do
        result = {
            book_id = tonumber(row[1]),
            title = tostring(row[2] or ""),
            author = tostring(row[3] or ""),
        }
        break
    end
    
    stmt:close()
    return result
end

--[[--
Find book_id by ISBN (prefers ISBN-13 over ISBN-10)

@param isbn10 ISBN-10 string (optional)
@param isbn13 ISBN-13 string (optional)
@return table|nil Returns {book_id, title, author, file_hash, isbn10, isbn13} or nil
--]]
function Database:findBookIdByIsbn(isbn10, isbn13)
    -- Prefer ISBN-13 if both provided
    if isbn13 and isbn13 ~= "" then
        local stmt = self.conn:prepare([[
            SELECT book_id, title, author, file_hash, isbn10, isbn13
            FROM book_cache
            WHERE isbn13 = ? AND book_id IS NOT NULL
            LIMIT 1
        ]])
        
        if not stmt then
            logger.err("BookloreSync Database: Failed to prepare isbn13 lookup:", self.conn:errmsg())
            return nil
        end
        
        stmt:bind(isbn13)
        
        for row in stmt:rows() do
            local result = {
                book_id = row[1] and tonumber(row[1]) or nil,
                title = row[2] and tostring(row[2]) or nil,
                author = row[3] and tostring(row[3]) or nil,
                file_hash = row[4] and tostring(row[4]) or nil,
                isbn10 = row[5] and tostring(row[5]) or nil,
                isbn13 = row[6] and tostring(row[6]) or nil,
            }
            stmt:close()
            return result
        end
        stmt:close()
    end
    
    -- Fallback to ISBN-10 if ISBN-13 not found or not provided
    if isbn10 and isbn10 ~= "" then
        local stmt = self.conn:prepare([[
            SELECT book_id, title, author, file_hash, isbn10, isbn13
            FROM book_cache
            WHERE isbn10 = ? AND book_id IS NOT NULL
            LIMIT 1
        ]])
        
        if not stmt then
            logger.err("BookloreSync Database: Failed to prepare isbn10 lookup:", self.conn:errmsg())
            return nil
        end
        
        stmt:bind(isbn10)
        
        for row in stmt:rows() do
            local result = {
                book_id = row[1] and tonumber(row[1]) or nil,
                title = row[2] and tostring(row[2]) or nil,
                author = row[3] and tostring(row[3]) or nil,
                file_hash = row[4] and tostring(row[4]) or nil,
                isbn10 = row[5] and tostring(row[5]) or nil,
                isbn13 = row[6] and tostring(row[6]) or nil,
            }
            stmt:close()
            return result
        end
        stmt:close()
    end
    
    return nil
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

-- Bearer Token Management Functions

function Database:saveBearerToken(username, token)
    -- Save or update Bearer token for a user
    -- Token expires in 4 weeks (28 days)
    local expires_at = os.time() + (28 * 24 * 60 * 60)  -- 4 weeks from now
    
    -- Delete old token first to avoid unique constraint issues
    local delete_stmt = self.conn:prepare("DELETE FROM bearer_tokens WHERE username = ?")
    if delete_stmt then
        delete_stmt:bind(username)
        delete_stmt:step()
        delete_stmt:close()
    end
    
    -- Insert new token
    local stmt = self.conn:prepare([[
        INSERT INTO bearer_tokens (username, token, expires_at)
        VALUES (?, ?, ?)
    ]])
    
    if not stmt then
        logger.err("BookloreSync Database: Failed to prepare statement:", self.conn:errmsg())
        return false
    end
    
    stmt:bind(username, token, expires_at)
    local result = stmt:step()
    stmt:close()
    
    if result == SQ3.DONE or result == SQ3.OK then
        logger.info("BookloreSync Database: Saved Bearer token for user:", username)
        return true
    else
        logger.err("BookloreSync Database: Failed to save Bearer token:", self.conn:errmsg())
        return false
    end
end

function Database:getBearerToken(username)
    -- Get cached Bearer token if it exists and hasn't expired
    -- Returns token and expires_at timestamp for proactive refresh checking
    local stmt = self.conn:prepare([[
        SELECT token, expires_at
        FROM bearer_tokens
        WHERE username = ? AND expires_at > ?
        LIMIT 1
    ]])
    
    if not stmt then
        logger.err("BookloreSync Database: Failed to prepare statement:", self.conn:errmsg())
        return nil, nil
    end
    
    local current_time = os.time()
    stmt:bind(username, current_time)
    
    local token = nil
    local expires_at = nil
    for row in stmt:rows() do
        token = tostring(row[1])
        expires_at = tonumber(row[2])
        local time_remaining = expires_at - current_time
        logger.info("BookloreSync Database: Found cached Bearer token for", username, 
                   "- expires in", math.floor(time_remaining / 86400), "days")
        break
    end
    
    stmt:close()
    return token, expires_at
end

function Database:deleteBearerToken(username)
    -- Delete cached Bearer token (used when token is invalid)
    local stmt = self.conn:prepare("DELETE FROM bearer_tokens WHERE username = ?")
    
    if not stmt then
        logger.err("BookloreSync Database: Failed to prepare statement:", self.conn:errmsg())
        return false
    end
    
    stmt:bind(username)
    stmt:step()
    stmt:close()
    
    logger.info("BookloreSync Database: Deleted Bearer token for user:", username)
    return true
end

function Database:cleanupExpiredTokens()
    -- Clean up expired tokens (maintenance function)
    local stmt = self.conn:prepare("DELETE FROM bearer_tokens WHERE expires_at <= ?")
    
    if not stmt then
        logger.err("BookloreSync Database: Failed to prepare statement:", self.conn:errmsg())
        return false
    end
    
    stmt:bind(os.time())
    stmt:step()
    stmt:close()
    
    logger.info("BookloreSync Database: Cleaned up expired Bearer tokens")
    return true
end

--[[--
Get cached value from updater_cache if not expired

@param key Cache key
@return string|nil Cached value (JSON string) or nil if expired/not found
--]]
function Database:getUpdaterCache(key)
    local stmt = self.conn:prepare("SELECT value, cached_at FROM updater_cache WHERE key = ?")
    
    if not stmt then
        logger.err("BookloreSync Database: Failed to prepare statement:", self.conn:errmsg())
        return nil
    end
    
    stmt:bind(key)
    local row = stmt:step()
    stmt:close()
    
    if not row then
        return nil
    end
    
    local value = tostring(row[1])
    local cached_at = tonumber(row[2])
    local current_time = os.time()
    
    -- Check if cache is expired (older than 1 hour)
    if current_time - cached_at > 3600 then
        logger.info("BookloreSync Database: Cache expired for key:", key)
        return nil
    end
    
    logger.info("BookloreSync Database: Retrieved cached value for key:", key)
    return value
end

--[[--
Save value to updater_cache with current timestamp

@param key Cache key
@param value Value to cache (JSON string)
@return boolean success
--]]
function Database:setUpdaterCache(key, value)
    local stmt = self.conn:prepare("INSERT OR REPLACE INTO updater_cache (key, value, cached_at) VALUES (?, ?, ?)")
    
    if not stmt then
        logger.err("BookloreSync Database: Failed to prepare statement:", self.conn:errmsg())
        return false
    end
    
    stmt:bind(key, value, os.time())
    stmt:step()
    stmt:close()
    
    logger.info("BookloreSync Database: Cached value for key:", key)
    return true
end

--[[--
Clear all cached updater data

@return boolean success
--]]
function Database:clearUpdaterCache()
    local stmt = self.conn:prepare("DELETE FROM updater_cache")
    
    if not stmt then
        logger.err("BookloreSync Database: Failed to prepare statement:", self.conn:errmsg())
        return false
    end
    
    stmt:step()
    stmt:close()
    
    logger.info("BookloreSync Database: Cleared updater cache")
    return true
end

-- Book Metadata (Extended Sync) Functions

--[[--
Get the book_cache id for a given file path.

@param file_path Full path to the document file
@return number|nil The book_cache.id or nil if not found
--]]
function Database:getBookCacheIdByFilePath(file_path)
    if not file_path then
        return nil
    end
    file_path = tostring(file_path)

    local stmt = self.conn:prepare([[
        SELECT id FROM book_cache WHERE file_path = ? LIMIT 1
    ]])
    if not stmt then
        logger.err("BookloreSync Database: Failed to prepare getBookCacheIdByFilePath:", self.conn:errmsg())
        return nil
    end

    local ok, err = pcall(function() stmt:bind(file_path) end)
    if not ok then
        logger.err("BookloreSync Database: Bind failed in getBookCacheIdByFilePath:", err)
        stmt:close()
        return nil
    end

    local id = nil
    for row in stmt:rows() do
        id = tonumber(row[1])
        break
    end
    stmt:close()
    return id
end

--[[--
Upsert a row in book_metadata for the given book_cache_id.

@param book_cache_id The book_cache.id to link to
@param fields Table with any of: sdr_path, rating, rating_synced, pending_rating_prompt
@return boolean success
--]]
function Database:upsertBookMetadata(book_cache_id, fields)
    if not book_cache_id then
        logger.err("BookloreSync Database: upsertBookMetadata called without book_cache_id")
        return false
    end
    book_cache_id = tonumber(book_cache_id)
    if not book_cache_id then
        logger.err("BookloreSync Database: Invalid book_cache_id in upsertBookMetadata")
        return false
    end

    fields = fields or {}

    -- Check whether a row already exists
    local check_stmt = self.conn:prepare([[
        SELECT id FROM book_metadata WHERE book_cache_id = ? LIMIT 1
    ]])
    if not check_stmt then
        logger.err("BookloreSync Database: Failed to prepare check in upsertBookMetadata:", self.conn:errmsg())
        return false
    end
    check_stmt:bind(book_cache_id)
    local existing_id = nil
    for row in check_stmt:rows() do
        existing_id = tonumber(row[1])
        break
    end
    check_stmt:close()

    if existing_id then
        -- Build a dynamic UPDATE
        local sets = { "updated_at = CAST(strftime('%s', 'now') AS INTEGER)" }
        local binds = {}
        if fields.sdr_path ~= nil then
            table.insert(sets, "sdr_path = ?")
            table.insert(binds, tostring(fields.sdr_path))
        end
        if fields.rating ~= nil then
            table.insert(sets, "rating = ?")
            table.insert(binds, tonumber(fields.rating))
        end
        if fields.rating_synced ~= nil then
            table.insert(sets, "rating_synced = ?")
            table.insert(binds, fields.rating_synced and 1 or 0)
        end
        if fields.pending_rating_prompt ~= nil then
            table.insert(sets, "pending_rating_prompt = ?")
            table.insert(binds, fields.pending_rating_prompt and 1 or 0)
        end
        table.insert(binds, book_cache_id)

        local sql = "UPDATE book_metadata SET " .. table.concat(sets, ", ") .. " WHERE book_cache_id = ?"
        local stmt = self.conn:prepare(sql)
        if not stmt then
            logger.err("BookloreSync Database: Failed to prepare UPDATE in upsertBookMetadata:", self.conn:errmsg())
            return false
        end
        local ok, err = pcall(function() stmt:bind(table.unpack(binds)) end)
        if not ok then
            logger.err("BookloreSync Database: Bind failed in upsertBookMetadata UPDATE:", err)
            stmt:close()
            return false
        end
        local result = stmt:step()
        stmt:close()
        return result == SQ3.DONE or result == SQ3.OK
    else
        -- INSERT
        local stmt = self.conn:prepare([[
            INSERT INTO book_metadata (book_cache_id, sdr_path, rating, rating_synced, pending_rating_prompt)
            VALUES (?, ?, ?, ?, ?)
        ]])
        if not stmt then
            logger.err("BookloreSync Database: Failed to prepare INSERT in upsertBookMetadata:", self.conn:errmsg())
            return false
        end
        local ok, err = pcall(function()
            stmt:bind(
                book_cache_id,
                fields.sdr_path and tostring(fields.sdr_path) or nil,
                fields.rating and tonumber(fields.rating) or nil,
                (fields.rating_synced ~= nil) and (fields.rating_synced and 1 or 0) or 0,
                (fields.pending_rating_prompt ~= nil) and (fields.pending_rating_prompt and 1 or 0) or 0
            )
        end)
        if not ok then
            logger.err("BookloreSync Database: Bind failed in upsertBookMetadata INSERT:", err)
            stmt:close()
            return false
        end
        local result = stmt:step()
        stmt:close()
        return result == SQ3.DONE or result == SQ3.OK
    end
end

--[[--
Get the book_metadata row for a given book_cache_id.

@param book_cache_id The book_cache.id
@return table|nil {id, book_cache_id, sdr_path, rating, rating_synced, pending_rating_prompt} or nil
--]]
function Database:getBookMetadata(book_cache_id)
    if not book_cache_id then return nil end
    book_cache_id = tonumber(book_cache_id)
    if not book_cache_id then return nil end

    local stmt = self.conn:prepare([[
        SELECT id, book_cache_id, sdr_path, rating, rating_synced, pending_rating_prompt
        FROM book_metadata
        WHERE book_cache_id = ?
        LIMIT 1
    ]])
    if not stmt then
        logger.err("BookloreSync Database: Failed to prepare getBookMetadata:", self.conn:errmsg())
        return nil
    end
    stmt:bind(book_cache_id)

    local meta = nil
    for row in stmt:rows() do
        meta = {
            id                    = tonumber(row[1]),
            book_cache_id         = tonumber(row[2]),
            sdr_path              = row[3] and tostring(row[3]) or nil,
            rating                = row[4] and tonumber(row[4]) or nil,
            rating_synced         = (tonumber(row[5]) or 0) == 1,
            pending_rating_prompt = (tonumber(row[6]) or 0) == 1,
        }
        break
    end
    stmt:close()
    return meta
end

--[[--
Store a rating (1-10) for a book, clearing the synced flag.

@param book_cache_id The book_cache.id
@param rating integer 1-10
@return boolean success
--]]
function Database:storeRating(book_cache_id, rating)
    return self:upsertBookMetadata(book_cache_id, { rating = rating, rating_synced = false })
end

--[[--
Mark the rating for a book as synced to the server.

@param book_cache_id The book_cache.id
@return boolean success
--]]
function Database:markRatingSynced(book_cache_id)
    return self:upsertBookMetadata(book_cache_id, { rating_synced = true })
end

--[[--
Mark a book as needing a deferred rating prompt.

Called when a book is completed (>=99%) but no Booklore book_id is known
yet (server was offline at open time).  The next sync run will check for
this flag and show the dialog / push the KOReader rating once a book_id
has been resolved.

@param book_cache_id integer  book_cache.id
@return boolean success
--]]
function Database:setPendingRatingPrompt(book_cache_id, value)
    return self:upsertBookMetadata(book_cache_id, { pending_rating_prompt = (value ~= false) })
end

--[[--
Return all book_cache rows that have a pending_rating_prompt set and a
known book_id so that the caller can act on them.

@return table  Array of {book_cache_id, book_id, file_path}
--]]
function Database:getBooksPendingRatingPrompt()
    local stmt = self.conn:prepare([[
        SELECT bm.book_cache_id, bc.book_id, bc.file_path
        FROM book_metadata bm
        JOIN book_cache bc ON bc.id = bm.book_cache_id
        WHERE bm.pending_rating_prompt = 1
          AND bc.book_id IS NOT NULL
    ]])
    if not stmt then
        logger.err("BookloreSync Database: Failed to prepare getBooksPendingRatingPrompt:", self.conn:errmsg())
        return {}
    end

    local rows = {}
    for row in stmt:rows() do
        table.insert(rows, {
            book_cache_id = tonumber(row[1]),
            book_id       = tonumber(row[2]),
            file_path     = row[3] and tostring(row[3]) or nil,
        })
    end
    stmt:close()
    return rows
end

-- Pending Ratings Queue

--[[--
Add a rating to the pending_ratings queue.

Called when a rating sync attempt fails so it can be retried on the next
upload trigger (session, note, or explicit sync).

Upserts by book_cache_id so duplicate failures don't grow the table —
only the latest rating value is kept pending.

@param book_cache_id integer  book_cache.id
@param book_id       integer  Booklore book ID
@param rating        integer  1-10 rating value
@return boolean success
--]]
function Database:addPendingRating(book_cache_id, book_id, rating)
    if not book_cache_id or not book_id or not rating then
        logger.err("BookloreSync Database: addPendingRating called with missing args")
        return false
    end
    book_cache_id = tonumber(book_cache_id)
    book_id       = tonumber(book_id)
    rating        = tonumber(rating)
    if not book_cache_id or not book_id or not rating then
        logger.err("BookloreSync Database: addPendingRating: non-numeric argument")
        return false
    end

    -- Upsert: if a pending rating already exists for this book, update the
    -- value and reset the retry counter so the latest rating wins.
    local stmt = self.conn:prepare([[
        INSERT INTO pending_ratings (book_cache_id, book_id, rating, retry_count, created_at)
        VALUES (?, ?, ?, 0, CAST(strftime('%s', 'now') AS INTEGER))
        ON CONFLICT(book_cache_id) DO UPDATE SET
            book_id       = excluded.book_id,
            rating        = excluded.rating,
            retry_count   = 0,
            last_retry_at = NULL
    ]])
    if not stmt then
        logger.err("BookloreSync Database: Failed to prepare addPendingRating:", self.conn:errmsg())
        return false
    end

    local ok, err = pcall(function()
        stmt:bind(book_cache_id, book_id, rating)
    end)
    if not ok then
        logger.err("BookloreSync Database: Bind failed in addPendingRating:", err)
        stmt:close()
        return false
    end

    local result = stmt:step()
    stmt:close()
    if result ~= SQ3.DONE and result ~= SQ3.OK then
        logger.err("BookloreSync Database: addPendingRating step failed:", self.conn:errmsg())
        return false
    end
    return true
end

--[[--
Return all rows from the pending_ratings queue.

@return table  Array of {id, book_cache_id, book_id, rating, retry_count}
--]]
function Database:getPendingRatings()
    local stmt = self.conn:prepare([[
        SELECT id, book_cache_id, book_id, rating, retry_count
        FROM pending_ratings
        ORDER BY created_at ASC
    ]])
    if not stmt then
        logger.err("BookloreSync Database: Failed to prepare getPendingRatings:", self.conn:errmsg())
        return {}
    end

    local rows = {}
    for row in stmt:rows() do
        table.insert(rows, {
            id            = tonumber(row[1]),
            book_cache_id = tonumber(row[2]),
            book_id       = tonumber(row[3]),
            rating        = tonumber(row[4]),
            retry_count   = tonumber(row[5]) or 0,
        })
    end
    stmt:close()
    return rows
end

--[[--
Return the number of ratings currently in the pending queue.

@return integer
--]]
function Database:getPendingRatingCount()
    local stmt = self.conn:prepare("SELECT COUNT(*) FROM pending_ratings")
    if not stmt then
        logger.err("BookloreSync Database: Failed to prepare getPendingRatingCount:", self.conn:errmsg())
        return 0
    end
    local count = 0
    for row in stmt:rows() do
        count = tonumber(row[1]) or 0
        break
    end
    stmt:close()
    return count
end

--[[--
Remove a successfully-synced rating from the pending queue.

@param id integer  pending_ratings.id
@return boolean success
--]]
function Database:deletePendingRating(id)
    if not id then
        logger.err("BookloreSync Database: deletePendingRating called without id")
        return false
    end
    id = tonumber(id)
    if not id then return false end

    local stmt = self.conn:prepare("DELETE FROM pending_ratings WHERE id = ?")
    if not stmt then
        logger.err("BookloreSync Database: Failed to prepare deletePendingRating:", self.conn:errmsg())
        return false
    end

    local ok, err = pcall(function() stmt:bind(id) end)
    if not ok then
        logger.err("BookloreSync Database: Bind failed in deletePendingRating:", err)
        stmt:close()
        return false
    end

    local result = stmt:step()
    stmt:close()
    return result == SQ3.DONE or result == SQ3.OK
end

--[[--
Increment the retry counter for a pending rating.

@param id integer  pending_ratings.id
@return boolean success
--]]
function Database:incrementPendingRatingRetryCount(id)
    if not id then return false end
    id = tonumber(id)
    if not id then return false end

    local stmt = self.conn:prepare([[
        UPDATE pending_ratings
        SET retry_count = retry_count + 1,
            last_retry_at = CAST(strftime('%s', 'now') AS INTEGER)
        WHERE id = ?
    ]])
    if not stmt then
        logger.err("BookloreSync Database: Failed to prepare incrementPendingRatingRetryCount:", self.conn:errmsg())
        return false
    end

    local ok, err = pcall(function() stmt:bind(id) end)
    if not ok then
        logger.err("BookloreSync Database: Bind failed in incrementPendingRatingRetryCount:", err)
        stmt:close()
        return false
    end

    local result = stmt:step()
    stmt:close()
    return result == SQ3.DONE or result == SQ3.OK
end

-- Annotation / Highlight Sync Helpers

--[[--
Check whether a KOReader annotation has already been synced.

Uniqueness key: (book_cache_id, koreader_datetime, annotation_type)

@param book_cache_id  number  book_cache.id
@param koreader_datetime  string  annotation datetime from sidecar (e.g. "2026-02-20 18:08:13")
@param annotation_type   string  "highlight", "in_book_note", or "booklore_note"
@return boolean  true if already synced
--]]
function Database:isAnnotationSynced(book_cache_id, koreader_datetime, annotation_type)
    if not book_cache_id or not koreader_datetime or not annotation_type then
        return false
    end
    book_cache_id = tonumber(book_cache_id)
    if not book_cache_id then return false end

    local stmt = self.conn:prepare([[
        SELECT COUNT(*) FROM synced_annotations
        WHERE book_cache_id = ? AND koreader_datetime = ? AND annotation_type = ?
        LIMIT 1
    ]])
    if not stmt then
        logger.err("BookloreSync Database: Failed to prepare isAnnotationSynced:", self.conn:errmsg())
        return false
    end

    local ok, err = pcall(function()
        stmt:bind(book_cache_id, tostring(koreader_datetime), tostring(annotation_type))
    end)
    if not ok then
        logger.err("BookloreSync Database: Bind failed in isAnnotationSynced:", err)
        stmt:close()
        return false
    end

    local count = 0
    for row in stmt:rows() do
        count = tonumber(row[1]) or 0
        break
    end
    stmt:close()
    return count > 0
end

--[[--
Record that a KOReader annotation has been synced to the server.

@param book_cache_id     number  book_cache.id
@param koreader_datetime string  annotation datetime from sidecar
@param annotation_type   string  "highlight", "in_book_note", or "booklore_note"
@param server_id         number|nil  ID returned by the server (optional)
@return boolean success
--]]
function Database:markAnnotationSynced(book_cache_id, koreader_datetime, annotation_type, server_id)
    if not book_cache_id or not koreader_datetime or not annotation_type then
        logger.err("BookloreSync Database: markAnnotationSynced called with missing args")
        return false
    end
    book_cache_id = tonumber(book_cache_id)
    if not book_cache_id then return false end

    local stmt = self.conn:prepare([[
        INSERT OR IGNORE INTO synced_annotations
            (book_cache_id, koreader_datetime, annotation_type, destination, server_id, synced_at)
        VALUES (?, ?, ?, ?, ?, CAST(strftime('%s', 'now') AS INTEGER))
    ]])
    if not stmt then
        logger.err("BookloreSync Database: Failed to prepare markAnnotationSynced:", self.conn:errmsg())
        return false
    end

    -- destination mirrors annotation_type for now
    local ok, err = pcall(function()
        stmt:bind(
            book_cache_id,
            tostring(koreader_datetime),
            tostring(annotation_type),
            tostring(annotation_type),
            server_id and tonumber(server_id) or nil
        )
    end)
    if not ok then
        logger.err("BookloreSync Database: Bind failed in markAnnotationSynced:", err)
        stmt:close()
        return false
    end

    local result = stmt:step()
    stmt:close()
    return result == SQ3.DONE or result == SQ3.OK
end

-- Plugin Settings helpers

--[[--
Read a single plugin setting from the plugin_settings table.

Values are stored as TEXT.  Boolean strings ("true"/"false") and numeric
strings are returned as their native Lua types so that callers can use
the result exactly as they would a LuaSettings:readSetting() value.

@param key string  Setting key
@return string|number|boolean|nil  Typed value, or nil if not present
--]]
function Database:getPluginSetting(key)
    if not key then return nil end
    key = tostring(key)

    local stmt = self.conn:prepare([[
        SELECT value FROM plugin_settings WHERE key = ? LIMIT 1
    ]])
    if not stmt then
        logger.err("BookloreSync Database: Failed to prepare getPluginSetting:", self.conn:errmsg())
        return nil
    end

    local ok, err = pcall(function() stmt:bind(key) end)
    if not ok then
        logger.err("BookloreSync Database: Bind failed in getPluginSetting:", err)
        stmt:close()
        return nil
    end

    local raw = nil
    for row in stmt:rows() do
        raw = row[1]  -- may be nil if the column value is NULL
        break
    end
    stmt:close()

    if raw == nil then return nil end

    -- Deserialise: booleans stored as "true"/"false", numbers as decimal strings
    if raw == "true"  then return true  end
    if raw == "false" then return false end
    local n = tonumber(raw)
    if n ~= nil then return n end
    return raw  -- plain string
end

--[[--
Write (insert-or-replace) a single plugin setting to the plugin_settings table.

Booleans are serialised as "true"/"false", numbers as their decimal string
representation.  nil values are stored as a SQL NULL.

@param key   string  Setting key
@param value string|number|boolean|nil  Value to store
@return boolean success
--]]
function Database:savePluginSetting(key, value)
    if not key then
        logger.err("BookloreSync Database: savePluginSetting called without key")
        return false
    end
    key = tostring(key)

    local value_str
    if value == nil then
        value_str = nil
    else
        local t = type(value)
        if t == "boolean" then
            value_str = value and "true" or "false"
        elseif t == "number" then
            value_str = tostring(value)
        elseif t == "string" then
            value_str = value
        else
            logger.err("BookloreSync Database: savePluginSetting: unsupported type", t, "for key", key)
            return false
        end
    end

    local stmt = self.conn:prepare([[
        INSERT OR REPLACE INTO plugin_settings (key, value, updated_at)
        VALUES (?, ?, CAST(strftime('%s', 'now') AS INTEGER))
    ]])
    if not stmt then
        logger.err("BookloreSync Database: Failed to prepare savePluginSetting:", self.conn:errmsg())
        return false
    end

    local ok, err = pcall(function() stmt:bind(key, value_str) end)
    if not ok then
        logger.err("BookloreSync Database: Bind failed in savePluginSetting:", err)
        stmt:close()
        return false
    end

    local result = stmt:step()
    stmt:close()
    return result == SQ3.DONE or result == SQ3.OK
end

--[[--
Return all plugin settings as a key→value Lua table.

Values are deserialised to their native Lua types (boolean, number, or string)
using the same rules as getPluginSetting().

@return table  { key = value, ... }
--]]
function Database:getAllPluginSettings()
    local settings = {}
    local stmt = self.conn:prepare("SELECT key, value FROM plugin_settings")
    if not stmt then
        logger.err("BookloreSync Database: Failed to prepare getAllPluginSettings:", self.conn:errmsg())
        return settings
    end

    for row in stmt:rows() do
        local k = row[1] and tostring(row[1]) or nil
        local raw = row[2]
        if k then
            if raw == nil then
                settings[k] = nil
            elseif raw == "true" then
                settings[k] = true
            elseif raw == "false" then
                settings[k] = false
            else
                local n = tonumber(raw)
                settings[k] = (n ~= nil) and n or tostring(raw)
            end
        end
    end
    stmt:close()
    return settings
end

-- Rating Sync History helpers

--[[--
Record a rating sync attempt in rating_sync_history.

@param book_cache_id  number   book_cache.id
@param rating         number   Rating value that was synced (1-10)
@param status         string   "success" or "error"  (default "success")
@param error_message  string|nil  Error detail when status is "error"
@return boolean success
--]]
function Database:recordRatingSyncHistory(book_cache_id, rating, status, error_message)
    if not book_cache_id or not rating then
        logger.err("BookloreSync Database: recordRatingSyncHistory called with missing args")
        return false
    end
    book_cache_id = tonumber(book_cache_id)
    rating        = tonumber(rating)
    if not book_cache_id or not rating then
        logger.err("BookloreSync Database: recordRatingSyncHistory: invalid book_cache_id or rating")
        return false
    end
    status = status or "success"

    local stmt = self.conn:prepare([[
        INSERT INTO rating_sync_history (book_cache_id, rating, status, error_message)
        VALUES (?, ?, ?, ?)
    ]])
    if not stmt then
        logger.err("BookloreSync Database: Failed to prepare recordRatingSyncHistory:", self.conn:errmsg())
        return false
    end

    local ok, err = pcall(function()
        stmt:bind(
            book_cache_id,
            rating,
            tostring(status),
            error_message and tostring(error_message) or nil
        )
    end)
    if not ok then
        logger.err("BookloreSync Database: Bind failed in recordRatingSyncHistory:", err)
        stmt:close()
        return false
    end

    local result = stmt:step()
    stmt:close()
    return result == SQ3.DONE or result == SQ3.OK
end

--[[--
Retrieve the rating sync history for a given book.

@param book_cache_id  number  book_cache.id
@return table  Array of { id, book_cache_id, rating, synced_at, status, error_message }
--]]
function Database:getRatingSyncHistory(book_cache_id)
    local rows = {}
    if not book_cache_id then return rows end
    book_cache_id = tonumber(book_cache_id)
    if not book_cache_id then return rows end

    local stmt = self.conn:prepare([[
        SELECT id, book_cache_id, rating, synced_at, status, error_message
        FROM rating_sync_history
        WHERE book_cache_id = ?
        ORDER BY synced_at DESC
    ]])
    if not stmt then
        logger.err("BookloreSync Database: Failed to prepare getRatingSyncHistory:", self.conn:errmsg())
        return rows
    end

    local ok, err = pcall(function() stmt:bind(book_cache_id) end)
    if not ok then
        logger.err("BookloreSync Database: Bind failed in getRatingSyncHistory:", err)
        stmt:close()
        return rows
    end

    for row in stmt:rows() do
        table.insert(rows, {
            id            = tonumber(row[1]),
            book_cache_id = tonumber(row[2]),
            rating        = tonumber(row[3]),
            synced_at     = tonumber(row[4]),
            status        = row[5] and tostring(row[5]) or "success",
            error_message = row[6] and tostring(row[6]) or nil,
        })
    end
    stmt:close()
    return rows
end

return Database
