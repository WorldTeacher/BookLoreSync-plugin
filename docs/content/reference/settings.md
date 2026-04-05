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
| `is_enabled` | boolean | `false` | Master on/off switch for all session tracking |
| `min_duration` | integer | `30` | Minimum session duration in seconds for a session to be saved |
| `min_pages` | integer | `5` | Minimum pages read for a session to be saved (used in pages detection mode) |
| `session_detection_mode` | string | `"duration"` | Validation mode: `"duration"` or `"pages"` |
| `progress_decimal_places` | integer | `2` | Decimal places in progress percentages sent to the server during sync (0–5); local storage always uses full precision |

---

## KOReader progress sync settings

| Key | Type | Default | Description |
|-----|------|---------|-------------|
| `progress_sync_enabled` | boolean | `false` | Master toggle for KOReader document-position sync |
| `progress_pull_on_open` | boolean | `true` | Pull remote progress when opening a book (if already connected) |
| `progress_pull_on_resume` | boolean | `true` | Pull remote progress after resume (if already connected) |
| `progress_sync_trigger` | string | `"book_open_close"` | Push mode selector (`"book_open_close"` or `"each_n_pages"`) |
| `progress_sync_interval_pages` | integer | `10` | Number of page turns before periodic progress update; minimum is `1` |
| `progress_sync_page_updates_enabled` | boolean | `true` | Enable or disable periodic page-turn updates (open/close snapshots are always queued) |
| `progress_sync_forward_strategy` | string | `"prompt"` | Strategy when remote progress is newer: `"silent"`, `"prompt"`, or `"disable"` |
| `progress_sync_backward_strategy` | string | `"disable"` | Strategy when remote progress is older: `"silent"`, `"prompt"`, or `"disable"` |
| `progress_sync_set_read_on_rating` | boolean | `false` | Queue forced 100% progress when rating is submitted |

---

## Sync mode settings

| Key | Type | Default | Description |
|-----|------|---------|-------------|
| `sync_mode` | string | *(derived)* | High-level sync mode: `"automatic"` (sync on suspend + WiFi enabled), `"manual"` (queue only; sync via **Sync & Cache → Sync Pending Now**), or `"custom"` (manual configuration of the two flags below). Derived from `manual_sync_only` and `force_push_session_on_suspend`/`connect_network_on_suspend` on first run; saved explicitly after that. |
| `manual_sync_only` | boolean | `false` | When `true`, sessions are queued but not auto-uploaded; requires manual **Sync & Cache → Sync Pending Now**. Set automatically when `sync_mode` is `"manual"`. |
| `force_push_session_on_suspend` | boolean | `false` | When `true`, triggers `syncPendingSessions` on device suspend. Set automatically when `sync_mode` is `"automatic"`; also available as a custom toggle when `sync_mode` is `"custom"`. |
| `connect_network_on_suspend` | boolean | `false` | When `true`, enables WiFi before syncing on suspend (works in conjunction with `force_push_session_on_suspend`). Set automatically when `sync_mode` is `"automatic"`; also available as a custom toggle when `sync_mode` is `"custom"`. |
| `ask_wifi_enable` | boolean | `false` | When `true`, shows a confirmation dialog before enabling WiFi for a sync. In the UI this toggle is disabled while `sync_mode` is `"manual"`. |

---

## Shelf sync settings

| Key | Type | Default | Description |
|-----|------|---------|-------------|
| `booklore_shelf_name` | string | `"KOReader"` | Name of the BookLore shelf to sync from; created automatically if it does not exist |
| `shelf_id` | integer | `nil` | Cached ID of the resolved shelf (set automatically after first sync) |
| `download_dir` | string | *(auto)* | Local directory where downloaded books are saved; resolved from KOReader's `home_dir` setting, then device default, then known platform paths (`/mnt/onboard/Books`, `/sdcard/Books`). Always a `Books` subdirectory. |
| `auto_sync_shelf_on_resume` | boolean | `false` | Automatically run shelf sync 15 seconds after the device wakes from suspend, once Wi-Fi is connected |
| `delete_removed_shelf_books` | boolean | `false` | Delete local book files when they are removed from the shelf |
| `shelf_use_original_filename` | boolean | `true` | Save downloaded books using the server's original filename (stem + `_<id>`) instead of deriving the name from the book title |
| `delete_sdr_on_book_delete` | boolean | `false` | When deleting a shelf book, also delete its `.sdr` sidecar directory. Only applies when `delete_removed_shelf_books` is also `true` |
| `min_free_space_mb` | integer | `500` | Minimum free disk space threshold (in MB) required before downloading shelf books |

---

## Rating sync settings

| Key | Type | Default | Description |
|-----|------|---------|-------------|
| `rating_sync_enabled` | boolean | `false` | Enable or disable rating sync to BookLore |
| `rating_sync_mode` | string | `"koreader_scaled"` | Rating mode: `"koreader_scaled"` (×2 conversion) or `"select_at_complete"` (manual 1–10 dialog) |
| `hardcover_token` | string | `""` | Hardcover API token for syncing ratings to Hardcover |
| `hardcover_rating_sync_enabled` | boolean | `false` | Enable or disable rating sync to Hardcover (requires `hardcover_token`) |

---

## Annotation sync settings

| Key | Type | Default | Description |
|-----|------|---------|-------------|
| `highlights_notes_sync_enabled` | boolean | `false` | Enable or disable highlights and notes sync |
| `bookmarks_sync_enabled` | boolean | `false` | Enable or disable bookmark sync (position markers without text) |
| `notes_destination` | string | `"in_book"` | Where to store notes: `"in_book"`, `"in_booklore"`, or `"both"` |
| `upload_strategy` | string | `"on_session"` | When to upload: `"on_session"` (after every session) or `"on_complete"` (at ≥99% progress) |

---

## Preference settings

| Key | Type | Default | Description |
|-----|------|---------|-------------|
| `silent_messages` | boolean | `false` | Suppress session-related popup notifications |
| `log_to_file` | boolean | `false` | Enable file-based debug logging with daily rotation |
| `booklore_brand_display_name` | string | `"Booklore"` | Custom plugin display name used for UI branding; trailing `Sync` is normalized away and shortcut naming is derived automatically |

---

## Auto-update settings

| Key | Type | Default | Description |
|-----|------|---------|-------------|
| `auto_update_check` | boolean | `true` | Check for updates once per day at startup |
| `use_dev_builds` | boolean | `false` | Use the dev-build update channel defined by `dev-build.location` instead of stable GitHub releases |
| `last_update_check` | integer | `0` | Unix timestamp of the last update check (set automatically) |

---

## Notes on types

- **boolean** values are stored as `"true"` or `"false"` strings in the `plugin_settings` table and converted at read time.
- **integer** values are stored as string representations and converted with `tonumber()`.
- All settings use the `DbSettings` wrapper which provides a `LuaSettings`-compatible `readSetting` / `saveSetting` / `flush` interface backed by SQLite.
