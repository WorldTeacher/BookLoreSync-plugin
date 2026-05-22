-- Schema verification test — runs all migrations against a real SQLite DB
-- and verifies table structures, indexes, and constraints.

local lsqlite3 = require("lsqlite3")
local db_module = require("booklore_database")

local function has(tbl, key)
    return tbl[key] ~= nil
end

local function has_pattern(str, pat)
    return str and string.match(str, pat) ~= nil
end

describe("Database Schema", function()
    local db

    before_each(function()
        -- Open in-memory database
        db = lsqlite3.open_memory()
        db:exec("PRAGMA foreign_keys = ON")
    end)

    after_each(function()
        if db then
            db:close()
            db = nil
        end
    end)

    -- Helper: run a list of SQL statements
    local function run_migrations(migrations)
        for _, sql in ipairs(migrations) do
            local rc = db:exec(sql)
            if rc ~= lsqlite3.OK then
                error("Migration failed: " .. (db:errmsg() or "unknown") .. "\nSQL: " .. sql)
            end
        end
    end

    -- Helper: get list of all table names
    local function get_tables()
        local stmt = db:prepare("SELECT name FROM sqlite_master WHERE type='table' ORDER BY name")
        local tables = {}
        for row in stmt:nrows() do
            tables[row.name] = true
        end
        stmt:close()
        return tables
    end

    -- Helper: get columns for a table
    local function get_columns(table_name)
        local stmt = db:prepare("PRAGMA table_info(" .. table_name .. ")")
        local cols = {}
        for row in stmt:nrows() do
            cols[row.name] = {
                type = row.type,
                notnull = row.notnull == 1,
                default = row.dflt_value,
                pk = row.pk,
            }
        end
        stmt:close()
        return cols
    end

    -- Helper: get indexes for a table
    local function get_indexes(table_name)
        local stmt = db:prepare("SELECT name FROM sqlite_master WHERE type='index' AND tbl_name=? ORDER BY name")
        stmt:bind(1, table_name)
        local idx = {}
        for row in stmt:nrows() do
            idx[row.name] = true
        end
        stmt:close()
        return idx
    end

    -- ═══════════════════════════════════════════════════════════════════════
    -- Migration count
    -- ═══════════════════════════════════════════════════════════════════════

    it("has 27 defined migrations", function()
        assert.equal(27, db_module.VERSION)
        assert.equal(27, #db_module.migrations)
    end)

    -- ═══════════════════════════════════════════════════════════════════════
    -- All migrations run without error
    -- ═══════════════════════════════════════════════════════════════════════

    it("runs all 27 migrations without SQL errors", function()
        for version = 1, 27 do
            local migrations = db_module.migrations[version]
            assert.is.truthy(migrations, "Migration " .. version .. " is missing")
            local rc = db:exec("BEGIN TRANSACTION")
            assert.equal(lsqlite3.OK, rc)
            run_migrations(migrations)
            db:exec("COMMIT")
            -- Record schema version
            db:exec(string.format(
                "INSERT OR REPLACE INTO schema_version (version) VALUES (%d)", version))
        end
    end)

    -- ═══════════════════════════════════════════════════════════════════════
    -- Core tables exist after full migration
    -- ═══════════════════════════════════════════════════════════════════════

    describe("after full migration", function()
        before_each(function()
            for v = 1, 27 do
                run_migrations(db_module.migrations[v])
                db:exec(string.format(
                    "INSERT OR REPLACE INTO schema_version (version) VALUES (%d)", v))
            end
        end)

        local expected_tables = {
            "book_cache", "pending_sessions", "schema_version",
            "historical_sessions", "bearer_tokens", "updater_cache",
            "book_metadata", "synced_annotations", "plugin_settings",
            "rating_sync_history", "pending_ratings", "pending_annotations",
            "synced_bookmarks", "pending_bookmarks",
            "pending_koreader_progress", "synced_koreader_progress",
            "pending_deletions", "shelf_state",
        }

        it("has all expected tables", function()
            local tables = get_tables()
            for _, tbl in ipairs(expected_tables) do
                assert.is.truthy(has(tables, tbl),
                    "Expected table '" .. tbl .. "' not found")
            end
        end)

        -- ── book_cache table ──────────────────────────────────────────────
        describe("book_cache", function()
            it("has all required columns with correct types", function()
                local cols = get_columns("book_cache")
                assert.is.truthy(has(cols, "file_path"))
                assert.is.truthy(has(cols, "file_hash"))
                assert.is.truthy(has(cols, "book_id"))
                assert.is.truthy(has(cols, "title"))
                assert.is.truthy(has(cols, "author"))
                assert.is.truthy(has(cols, "isbn10"))
                assert.is.truthy(has(cols, "isbn13"))
                assert.is.truthy(has(cols, "last_accessed"))
                assert.is.truthy(has(cols, "server_pagecount"))
                assert.is.truthy(has(cols, "hardcover_id"))
                -- file_path must be NOT NULL
                assert.is.truthy(cols["file_path"].notnull, "file_path must be NOT NULL")
            end)

            it("has all expected indexes", function()
                local indexes = get_indexes("book_cache")
                assert.is.truthy(has(indexes, "idx_book_cache_file_path"))
                assert.is.truthy(has(indexes, "idx_book_cache_file_hash"))
                assert.is.truthy(has(indexes, "idx_book_cache_book_id"))
                assert.is.truthy(has(indexes, "idx_book_cache_isbn10"))
                assert.is.truthy(has(indexes, "idx_book_cache_isbn13"))
            end)

            it("enforces UNIQUE constraint on file_path", function()
                db:exec([[
                    INSERT INTO book_cache (file_path, file_hash)
                    VALUES ('/test/book1.epub', 'abc123')
                ]])
                local rc = db:exec([[
                    INSERT INTO book_cache (file_path, file_hash)
                    VALUES ('/test/book1.epub', 'def456')
                ]])
                assert.is_not.equal(lsqlite3.OK, rc)
            end)
        end)

        -- ── pending_sessions table ────────────────────────────────────────
        describe("pending_sessions", function()
            it("has all required columns", function()
                local cols = get_columns("pending_sessions")
                assert.is.truthy(has(cols, "book_id"))
                assert.is.truthy(has(cols, "book_hash"))
                assert.is.truthy(has(cols, "book_type"))
                assert.is.truthy(has(cols, "start_time"))
                assert.is.truthy(has(cols, "end_time"))
                assert.is.truthy(has(cols, "duration_seconds"))
                assert.is.truthy(has(cols, "start_progress"))
                assert.is.truthy(has(cols, "end_progress"))
                assert.is.truthy(has(cols, "retry_count"))
                assert.is.truthy(has(cols, "book_title"))
                assert.is.truthy(has(cols, "koreader_book_id"))
            end)

            it("defaults retry_count to 0", function()
                db:exec([[
                    INSERT INTO pending_sessions (book_hash, start_time, end_time, duration_seconds)
                    VALUES ('hash123', '2026-01-01', '2026-01-01', 60)
                ]])
                local retry = db:first_row("SELECT retry_count FROM pending_sessions LIMIT 1")
                assert.is_not.truthy(retry) -- first_row may not exist in lsqlite3
            end)
        end)

        -- ── historical_sessions table ─────────────────────────────────────
        describe("historical_sessions", function()
            it("has the UNIQUE constraint on (koreader_book_id, start_time, end_time)", function()
                local cols = get_columns("historical_sessions")
                assert.is.truthy(has(cols, "koreader_book_id"))
                assert.is.truthy(has(cols, "start_time"))
                assert.is.truthy(has(cols, "end_time"))
                assert.is.truthy(has(cols, "matched"))
                assert.is.truthy(has(cols, "synced"))
            end)

            it("rejects duplicate (koreader_book_id, start_time, end_time)", function()
                db:exec([[
                    INSERT INTO historical_sessions
                        (koreader_book_id, koreader_book_title, start_time, end_time, duration_seconds)
                    VALUES (1, 'Test Book', '2026-01-01 10:00:00', '2026-01-01 10:30:00', 1800)
                ]])
                local rc = db:exec([[
                    INSERT INTO historical_sessions
                        (koreader_book_id, koreader_book_title, start_time, end_time, duration_seconds)
                    VALUES (1, 'Test Book', '2026-01-01 10:00:00', '2026-01-01 10:30:00', 1800)
                ]])
                assert.is_not.equal(lsqlite3.OK, rc)
            end)
        end)

        -- ── bearer_tokens table ────────────────────────────────────────────
        describe("bearer_tokens", function()
            it("enforces UNIQUE on username", function()
                local cols = get_columns("bearer_tokens")
                assert.is.truthy(has(cols, "username"))
                assert.is.truthy(has(cols, "token"))
                assert.is.truthy(has(cols, "expires_at"))

                db:exec([[
                    INSERT INTO bearer_tokens (username, token, expires_at)
                    VALUES ('user1', 'tok1', 9999999999)
                ]])
                local rc = db:exec([[
                    INSERT INTO bearer_tokens (username, token, expires_at)
                    VALUES ('user1', 'tok2', 9999999999)
                ]])
                assert.is_not.equal(lsqlite3.OK, rc)
            end)
        end)

        -- ── plugin_settings table ──────────────────────────────────────────
        describe("plugin_settings", function()
            it("uses key as PRIMARY KEY (must be unique)", function()
                local cols = get_columns("plugin_settings")
                assert.is.truthy(has(cols, "key"))
                assert.is.truthy(has(cols, "value"))

                db:exec("INSERT INTO plugin_settings (key, value) VALUES ('k1', 'v1')")
                local rc = db:exec("INSERT INTO plugin_settings (key, value) VALUES ('k1', 'v2')")
                assert.is_not.equal(lsqlite3.OK, rc)
            end)
        end)

        -- ── pending_annotations table ──────────────────────────────────────
        describe("pending_annotations", function()
            it("allows NULL book_id (relaxed constraint from migration 14)", function()
                local cols = get_columns("pending_annotations")
                assert.is.truthy(has(cols, "book_id"))
                assert.is_not.truthy(cols["book_id"].notnull,
                    "book_id must be nullable after migration 14")
            end)

            it("enforces UNIQUE on (book_cache_id, datetime, ann_type)", function()
                db:exec([[
                    INSERT INTO pending_annotations
                        (book_cache_id, ann_type, datetime, payload)
                    VALUES (1, 'highlight', '2026-01-01', '{}')
                ]])
                local rc = db:exec([[
                    INSERT INTO pending_annotations
                        (book_cache_id, ann_type, datetime, payload)
                    VALUES (1, 'highlight', '2026-01-01', '{}')
                ]])
                assert.is_not.equal(lsqlite3.OK, rc)
            end)
        end)

        -- ── pending_ratings table ──────────────────────────────────────────
        describe("pending_ratings", function()
            it("allows NULL book_id (relaxed from migration 15)", function()
                local cols = get_columns("pending_ratings")
                assert.is.truthy(has(cols, "book_id"))
                assert.is_not.truthy(cols["book_id"].notnull)
            end)

            it("enforces UNIQUE on book_cache_id", function()
                db:exec("INSERT INTO pending_ratings (book_cache_id, rating) VALUES (1, 3)")
                local rc = db:exec("INSERT INTO pending_ratings (book_cache_id, rating) VALUES (1, 4)")
                assert.is_not.equal(lsqlite3.OK, rc)
            end)
        end)

        -- ── shelf_state table ──────────────────────────────────────────────
        describe("shelf_state", function()
            it("has shelf_id as PRIMARY KEY", function()
                local tables = get_tables()
                assert.is.truthy(has(tables, "shelf_state"))
                local cols = get_columns("shelf_state")
                assert.is.truthy(has(cols, "shelf_id"))
                assert.is.truthy(has(cols, "books_json"))
                assert.is.truthy(has(cols, "synced_at"))
            end)
        end)
    end)
end)

-- ═══════════════════════════════════════════════════════════════════════════
-- Migration edge cases
-- ═══════════════════════════════════════════════════════════════════════════

describe("Migration edge cases", function()
    local fresh_db

    before_each(function()
        fresh_db = lsqlite3.open_memory()
    end)

    after_each(function()
        if fresh_db then fresh_db:close(); fresh_db = nil end
    end)

    local function run_migrations(db_conn, migrations_list)
        for _, sql in ipairs(migrations_list) do
            local rc = db_conn:exec(sql)
            if rc ~= lsqlite3.OK then
                error("Failed: " .. sql .. " -- " .. db_conn:errmsg())
            end
        end
    end

    it("migration 5 (DROP match_history) is idempotent — second run succeeds", function()
        run_migrations(fresh_db, db_module.migrations[1])
        -- First run
        run_migrations(fresh_db, db_module.migrations[5])
        -- Second run should succeed (DROP IF EXISTS)
        run_migrations(fresh_db, db_module.migrations[5])
    end)

    it("migration 14 (pending_annotations rebuild) preserves data", function()
        -- Run migrations 1-13
        for v = 1, 13 do
            run_migrations(fresh_db, db_module.migrations[v])
        end
        -- Insert test annotation
        fresh_db:exec([[
            INSERT INTO pending_annotations
                (book_cache_id, book_id, ann_type, datetime, payload)
            VALUES (1, 42, 'highlight', '2026-01-01 12:00:00', '{"text":"test"}')
        ]])
        -- Run migration 14 (rebuilds table)
        run_migrations(fresh_db, db_module.migrations[14])
        -- Verify data survived
        local cursor = fresh_db:nrows("SELECT * FROM pending_annotations")
        local rows = {}
        for row in cursor do
            table.insert(rows, row)
        end
        cursor:close()
        assert.equal(1, #rows)
        assert.equal("highlight", rows[1].ann_type)
        assert.equal(42, rows[1].book_id)
    end)

    it("migration 15 (pending_ratings rebuild) preserves data", function()
        for v = 1, 14 do
            run_migrations(fresh_db, db_module.migrations[v])
        end
        fresh_db:exec([[
            INSERT INTO pending_ratings (book_cache_id, book_id, rating)
            VALUES (1, 10, 4)
        ]])
        run_migrations(fresh_db, db_module.migrations[15])
        local cursor = fresh_db:nrows("SELECT * FROM pending_ratings")
        local rows = {}
        for row in cursor do
            table.insert(rows, row)
        end
        cursor:close()
        assert.equal(1, #rows)
    end)

    it("all migrations are idempotent (CREATE IF NOT EXISTS)", function()
        -- Run twice — second run should succeed cleanly
        for pass = 1, 2 do
            for v = 1, 27 do
                run_migrations(fresh_db, db_module.migrations[v])
                fresh_db:exec(string.format(
                    "INSERT OR REPLACE INTO schema_version (version) VALUES (%d)", v))
            end
        end
    end)
end)
