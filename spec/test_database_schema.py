#!/usr/bin/env python3
"""Schema verification tests for booklore_database.lua migrations.
Extracts migration SQL using brace-depth tracking, runs against SQLite, verifies structure.
"""

import os
import re
import sqlite3

MIGRATIONS_FILE = os.path.join(
    os.path.dirname(os.path.abspath(__file__)),
    "..",
    "bookloresync.koplugin",
    "booklore_database.lua",
)


def extract_migrations(filepath):
    """Parse all [N] = { [[sql]], ... } blocks from the Database.migrations table."""
    with open(filepath) as f:
        content = f.read()

    db_match = re.search(r"Database\.migrations\s*=\s*\{", content)
    if not db_match:
        return {}

    start = db_match.end() - 1
    depth, i = 1, start + 1
    while i < len(content) and depth > 0:
        if content[i] == "{":
            depth += 1
        elif content[i] == "}":
            depth -= 1
        i += 1
    table_body = content[start + 1 : i - 1]

    positions = [
        (int(m.group(1)), m.end() - 1)
        for m in re.finditer(r"\[(\d+)\]\s*=\s*\{", table_body)
    ]

    migrations = {}
    for version, mig_start in positions:
        depth_mig, j = 1, mig_start + 1
        while j < len(table_body) and depth_mig > 0:
            if table_body[j] == "{":
                depth_mig += 1
            elif table_body[j] == "}":
                depth_mig -= 1
            j += 1

        mig_body = table_body[mig_start + 1 : j - 1]
        sqls = re.findall(r"\[\[(.*?)\]\]", mig_body, re.DOTALL)
        sqls = [s.strip() for s in sqls if s.strip()]
        migrations[version] = sqls

    return migrations


def assert_raises(db, sql, params=()):
    """Assert that executing SQL raises an IntegrityError or OperationalError."""
    try:
        db.execute(sql, params)
        return False
    except (sqlite3.IntegrityError, sqlite3.OperationalError):
        return True


def run_tests():
    migrations = extract_migrations(MIGRATIONS_FILE)
    assert len(migrations) == 28, (
        f"Expected 28, got {len(migrations)}: {sorted(migrations.keys())}"
    )
    print(f"OK  Extracted {len(migrations)} migrations (v1-v28)")

    # ── Apply all migrations ────────────────────────────────────────────────
    db = sqlite3.connect(":memory:")
    for v in range(1, 29):
        assert v in migrations, f"Migration {v} missing"
        for sql in migrations[v]:
            db.execute(sql)
        db.execute("INSERT OR REPLACE INTO schema_version (version) VALUES (?)", (v,))
    print("OK  All 28 migrations apply without SQL errors")

    # ── Tables ──────────────────────────────────────────────────────────────
    expected = {
        "book_cache",
        "pending_sessions",
        "schema_version",
        "historical_sessions",
        "bearer_tokens",
        "updater_cache",
        "book_metadata",
        "synced_annotations",
        "plugin_settings",
        "rating_sync_history",
        "pending_ratings",
        "pending_annotations",
        "synced_bookmarks",
        "pending_bookmarks",
        "pending_koreader_progress",
        "synced_koreader_progress",
        "pending_deletions",
        "shelf_state",
    }
    cur = db.execute("SELECT name FROM sqlite_master WHERE type='table'")
    tables = {r[0] for r in cur.fetchall()}
    assert expected <= tables, f"Missing: {expected - tables}"
    print(f"OK  All {len(expected)} tables present")

    # ── book_cache: UNIQUE file_path, NOT NULL ──────────────────────────────
    db.execute(
        "INSERT INTO book_cache (file_path, file_hash) VALUES (?,?)",
        ("/t/a.epub", "h1"),
    )
    assert assert_raises(
        db,
        "INSERT INTO book_cache (file_path, file_hash) VALUES (?,?)",
        ("/t/a.epub", "h2"),
    ), "UNIQUE file_path not enforced"
    assert assert_raises(
        db,
        "INSERT INTO book_cache (file_hash) VALUES (?)",
        ("h3",),
    ), "file_path NOT NULL not enforced"
    print("OK  book_cache: UNIQUE + NOT NULL constraints enforced")

    # ── historical_sessions: UNIQUE (koreader_book_id, start_time, end_time) ─
    db.execute("""INSERT INTO historical_sessions
        (koreader_book_id,koreader_book_title,start_time,end_time,duration_seconds)
        VALUES (1,'T','2026-01-01 10:00','2026-01-01 10:30',1800)""")
    assert assert_raises(
        db,
        """INSERT INTO historical_sessions
        (koreader_book_id,koreader_book_title,start_time,end_time,duration_seconds)
        VALUES (1,'T','2026-01-01 10:00','2026-01-01 10:30',1800)""",
    ), "UNIQUE not enforced"
    print("OK  historical_sessions: UNIQUE constraint enforced")

    # ── bearer_tokens: UNIQUE username ──────────────────────────────────────
    db.execute(
        "INSERT INTO bearer_tokens (username,token,expires_at) VALUES (?,?,?)",
        ("u", "t", 9e9),
    )
    assert assert_raises(
        db,
        "INSERT INTO bearer_tokens (username,token,expires_at) VALUES (?,?,?)",
        ("u", "t2", 9e9),
    ), "UNIQUE on username not enforced"

    # ── plugin_settings: PRIMARY KEY on key ─────────────────────────────────
    db.execute("INSERT INTO plugin_settings (key,value) VALUES (?,?)", ("k", "v"))
    assert assert_raises(
        db,
        "INSERT INTO plugin_settings (key,value) VALUES (?,?)",
        ("k", "v2"),
    ), "PRIMARY KEY not enforced"

    # ── pending_annotations: nullable book_id + UNIQUE ──────────────────────
    cur = db.execute("PRAGMA table_info(pending_annotations)")
    cols = {r[1]: {"notnull": r[3]} for r in cur.fetchall()}
    assert "book_id" in cols and not cols["book_id"]["notnull"], (
        "book_id must be nullable after migration 14"
    )

    db.execute(
        "INSERT INTO pending_annotations (book_cache_id,ann_type,datetime,payload) VALUES (?,?,?,?)",
        (1, "highlight", "2026-01-01", "{}"),
    )
    assert assert_raises(
        db,
        """INSERT INTO pending_annotations
        (book_cache_id,ann_type,datetime,payload) VALUES (?,?,?,?)""",
        (1, "highlight", "2026-01-01", "{}"),
    ), "UNIQUE not enforced"
    print("OK  pending_annotations: nullable book_id + UNIQUE constraint")

    # ── pending_ratings: nullable book_id + UNIQUE book_cache_id ────────────
    cur = db.execute("PRAGMA table_info(pending_ratings)")
    cols = {r[1]: {"notnull": r[3]} for r in cur.fetchall()}
    assert not cols["book_id"]["notnull"], "book_id must be nullable after migration 15"

    db.execute(
        "INSERT INTO pending_ratings (book_cache_id,rating) VALUES (?,?)",
        (1, 3),
    )
    assert assert_raises(
        db,
        "INSERT INTO pending_ratings (book_cache_id,rating) VALUES (?,?)",
        (1, 4),
    ), "UNIQUE on book_cache_id not enforced"
    print("OK  pending_ratings: nullable book_id + UNIQUE on book_cache_id")

    # ── shelf_state structure ───────────────────────────────────────────────
    cur = db.execute("PRAGMA table_info(shelf_state)")
    cols = {r[1] for r in cur.fetchall()}
    assert {"shelf_id", "books_json", "synced_at"} <= cols, (
        f"Missing columns in shelf_state: {cols}"
    )
    print("OK  shelf_state: all expected columns present")

    # ── Migration 14 data preservation ──────────────────────────────────────
    db2 = sqlite3.connect(":memory:")
    for v in range(1, 14):
        for sql in migrations[v]:
            db2.execute(sql)
    db2.execute("""INSERT INTO pending_annotations
        (book_cache_id,book_id,ann_type,datetime,payload)
        VALUES (1,42,'highlight','2026-01-01 12:00','{"text":"test"}')""")
    for sql in migrations[14]:
        db2.execute(sql)
    rows = db2.execute("SELECT * FROM pending_annotations").fetchall()
    assert len(rows) == 1, f"Migration 14 lost data: got {len(rows)} rows"
    # Query by name to avoid position dependency
    row = db2.execute("SELECT ann_type, book_id FROM pending_annotations").fetchone()
    assert row[0] == "highlight", f"Wrong ann_type: {row[0]}"
    assert row[1] == 42, f"Wrong book_id: {row[1]}"
    db2.close()
    print("OK  Migration 14: data preserved after table rebuild")

    # ── Migration 15 data preservation ──────────────────────────────────────
    db3 = sqlite3.connect(":memory:")
    for v in range(1, 15):
        for sql in migrations[v]:
            db3.execute(sql)
    db3.execute(
        "INSERT INTO pending_ratings (book_cache_id,book_id,rating) VALUES (1,10,4)",
    )
    for sql in migrations[15]:
        db3.execute(sql)
    assert len(db3.execute("SELECT 1 FROM pending_ratings").fetchall()) == 1
    db3.close()
    print("OK  Migration 15: data preserved after table rebuild")

    db.close()
    print("\n  ALL 11 test groups passed")


if __name__ == "__main__":
    run_tests()
