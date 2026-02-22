+++
title = "Settings Reference"
description = "Complete list of all plugin settings, their types, defaults, and descriptions."
weight = 1
+++

# Settings Reference

All settings are stored in the `plugin_settings` table of the local SQLite database. They can be inspected with:

```sql
SELECT key, value FROM plugin_settings ORDER BY key;
```

Settings are read and written via the menus in **Tools → BookLore Sync → Settings**. You should not need to edit them manually.

---

## Connection settings

| Key | Type | Default | Description |
|-----|------|---------|-------------|
| `server_url` | string | `""` | Base URL of the BookLore server (e.g., `http://192.168.1.100:6060`) |
| `username` | string | `""` | KOReader account username (used for MD5-authenticated endpoints) |
| `password` | string | `""` | KOReader account password (stored in plain text; hashed to MD5 on the fly when sent in requests) |
| `booklore_username` | string | `""` | BookLore account username (used for Bearer token authentication) |
| `booklore_password` | string | `""` | BookLore account password (used to obtain JWT; not stored as a hash) |

---

## Session tracking settings

| Key | Type | Default | Description |
|-----|------|---------|-------------|
| `is_enabled` | boolean | `true` | Master on/off switch for all session tracking |
| `min_duration` | integer | `30` | Minimum session duration in seconds for a session to be saved |
| `min_pages` | integer | `5` | Minimum pages read for a session to be saved (used in pages detection mode) |
| `session_detection_mode` | string | `"duration"` | Validation mode: `"duration"` or `"pages"` |
| `progress_decimal_places` | integer | `2` | Decimal places in progress percentages sent to the server during sync (0–5); local storage always uses full precision |

---

## Sync mode settings

| Key | Type | Default | Description |
|-----|------|---------|-------------|
| `manual_sync_only` | boolean | `false` | When `true`, sessions are queued but not auto-uploaded; requires manual **Sync Now** |
| `force_push_session_on_suspend` | boolean | `false` | Reserved; behaviour not yet implemented |
| `connect_network_on_suspend` | boolean | `false` | Reserved; behaviour not yet implemented |

---

## Rating sync settings

| Key | Type | Default | Description |
|-----|------|---------|-------------|
| `rating_sync_enabled` | boolean | `false` | Enable or disable rating sync |
| `rating_sync_mode` | string | `"koreader_scaled"` | Rating mode: `"koreader_scaled"` (×2 conversion) or `"select_at_complete"` (manual 1–10 dialog) |

---

## Annotation sync settings

| Key | Type | Default | Description |
|-----|------|---------|-------------|
| `highlights_notes_sync_enabled` | boolean | `false` | Enable or disable highlights and notes sync |
| `notes_destination` | string | `"in_book"` | Where to store notes: `"in_book"` (EPUB CFI annotation) or `"in_booklore"` (standalone book note) |
| `upload_strategy` | string | `"on_session"` | When to upload: `"on_session"` (after every session) or `"on_complete"` (at ≥99% progress) |

---

## Preference settings

| Key | Type | Default | Description |
|-----|------|---------|-------------|
| `silent_messages` | boolean | `false` | Suppress session-related popup notifications |
| `log_to_file` | boolean | `false` | Enable file-based debug logging with daily rotation |
| `secure_logs` | boolean | `false` | Redact URLs from all log output |

---

## Auto-update settings

| Key | Type | Default | Description |
|-----|------|---------|-------------|
| `auto_update_check` | boolean | `true` | Check for updates once per day at startup |
| `last_update_check` | integer | `0` | Unix timestamp of the last update check (set automatically) |

---

## Notes on types

- **boolean** values are stored as `"true"` or `"false"` strings in the `plugin_settings` table and converted at read time.
- **integer** values are stored as string representations and converted with `tonumber()`.
- All settings use the `DbSettings` wrapper which provides a `LuaSettings`-compatible `readSetting` / `saveSetting` / `flush` interface backed by SQLite.
