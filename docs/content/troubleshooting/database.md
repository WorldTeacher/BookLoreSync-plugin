+++
title = "Database"
description = "How to inspect and reset the plugin's local SQLite database."
weight = 3
+++

# Database

The plugin stores all its data in a single SQLite database file named `booklore-sync.sqlite`, located inside KOReader's settings directory. The exact path depends on your platform — see the [Database location table](#database-location-on-different-platforms) below.

This file contains pending sessions, book cache, annotations, ratings, settings, and bearer tokens.

---

## Viewing the database

Use the `sqlite3` command-line tool to inspect the database. Substitute the path for your platform from the [table below](#database-location-on-different-platforms).

```bash
# Linux / macOS
sqlite3 {your_koreader_installation}/settings/booklore-sync.sqlite

# Android (via ADB shell or terminal emulator)
sqlite3 /sdcard/koreader/settings/booklore-sync.sqlite

# Kobo (via SSH)
sqlite3 /mnt/onboard/.adds/koreader/settings/booklore-sync.sqlite

# Kindle (via SSH)
sqlite3 /mnt/us/koreader/settings/booklore-sync.sqlite
```

### Useful queries

**View all tables:**
```sql
.tables
```

**View the schema:**
```sql
.schema
```

**Pending sessions (not yet uploaded):**
```sql
SELECT id, book_hash, duration_seconds, retry_count, created_at
FROM pending_sessions
ORDER BY created_at DESC;
```

**Cached books:**
```sql
SELECT file_path, file_hash, book_id, title, author
FROM book_cache
ORDER BY updated_at DESC;
```

**Current plugin settings:**
```sql
SELECT key, value FROM plugin_settings ORDER BY key;
```

**Synced annotations (deduplication record):**
```sql
SELECT book_id, annotation_id, synced_at
FROM synced_annotations
ORDER BY synced_at DESC
LIMIT 20;
```

**Pending ratings:**
```sql
SELECT * FROM pending_ratings;
```

**Pending annotations:**
```sql
SELECT id, book_id, created_at FROM pending_annotations ORDER BY created_at DESC;
```

**Current Bearer token:**
```sql
SELECT username, expires_at FROM bearer_tokens;
```

**Schema version:**
```sql
SELECT * FROM schema_version;
```

---

## Database schema version

The database uses a migration framework to evolve its schema safely across plugin updates. The current schema version is tracked in the `schema_version` table.

When you update the plugin, any required migrations run automatically on the first KOReader start after the update. You do not need to do anything manually.

If a migration fails (which should not happen under normal circumstances), the plugin will log an error and may fall back to a previous schema. Check the log and report the issue.

---

## Resetting the database

> **Warning:** Resetting the database permanently deletes all cached data, pending sessions, and settings. You will need to re-enter your server URL and credentials.

To reset:

{% mermaid() %}
flowchart TD
    A["1. Close KOReader completely"]
    B["2. Delete booklore-sync.sqlite"]
    C["3. Restart KOReader"]
    D["Fresh database created - re-enter credentials"]

    A --> B --> C --> D
{% end %}

The plugin will create a fresh database on the next startup and prompt you to configure it again.

**Partial reset options** (available from within KOReader, no data loss for settings):

| Action | Menu path | What it clears |
|--------|-----------|---------------|
| Clear book cache | Manage Sessions → Clear Cache | `book_cache` table only |
| Clear pending sessions | Manage Sessions → Clear Pending | `pending_sessions`, `pending_ratings`, `pending_annotations` tables |

---

## Database location on different platforms

| Platform | Path |
|----------|------|
| Linux / Android (KOReader) | `{your_koreader_installation}/settings/booklore-sync.sqlite` |
| Kindle | `/mnt/us/koreader/settings/booklore-sync.sqlite` |
| Kobo | `.kobo/koreader/settings/booklore-sync.sqlite` |

The exact path depends on where KOReader stores its settings on your device. Look for `koreader/settings/` on your device's storage.

---

## Backing up the database

The database file can be copied like any other file. To back up your reading history before a device reset:

```bash
cp {your_koreader_installation}/settings/booklore-sync.sqlite ~/backup/booklore-sync-$(date +%Y%m%d).sqlite
```

To restore, copy the backup file back to the original location before starting KOReader.
