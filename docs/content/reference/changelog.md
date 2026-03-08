+++
title = "Changelog"
description = "Full version history for the BookLore Sync plugin."
weight = 4
+++

# Changelog

All notable changes to the BookLore Sync plugin are documented here.

---

## Unreleased

### Features

- **Hardcover rating sync:** Ratings can now be synced to [Hardcover](https://hardcover.app) in addition to BookLore. Configure your Hardcover API token and enable the toggle in **Settings → Sync Settings → Rating Sync → Hardcover rating sync**. Falls back to title/author search if no cached Hardcover ID is found.
- **Bookmark sync:** KOReader position bookmarks (without text selection) are now synced to BookLore via `POST /api/v1/bookmarks`. Enable in **Settings → Sync Settings → Annotations Sync → Sync bookmarks**.
- **Shelf sync:** Pull books from a named BookLore shelf directly to your device. Configure in **Settings → Sync Settings → Shelf Sync**. New settings: `booklore_shelf_name`, `download_dir`, `auto_sync_shelf_on_resume`, `delete_removed_shelf_books`.
- **Per-book tracking toggle:** Long-press any book in the file manager to enable or disable session tracking for that book individually without affecting the rest of your library.
- **WiFi confirmation prompt:** New `ask_wifi_enable` setting. When enabled, a confirmation dialog is shown before the plugin attempts to enable WiFi for a sync.
- **Book deletion sync:** Deleting a book via the file manager now sends a delete request to BookLore. Deletions are queued in `pending_deletions` and retried if offline.
- **Annotations destination "Both":** A new notes destination option sends annotations to both in-book (EPUB CFI) and BookLore note destinations simultaneously.
- **PDF mock CFI:** Annotations from PDF files can now be sent to the "In book" destination using a placeholder CFI, enabling BookLore to accept them without errors.
- **File manager long-press actions:** Long-pressing a book in the file manager now offers quick-access menu items: **Sync Annotations**, **Match Book**, **Sync Rating**, and **Enable/Disable Tracking**.
- **Manual Sync Only feedback:** Closing a book in Manual Sync Only mode shows a queued-count notification (sessions and annotations). An "invalid session" (too short, no progress) shows a brief "Session not saved: criteria not met" message when Silent Mode is off.
- **Resume cooldown and deferred sync:** Auto-sync on resume is rate-limited to once every 5 minutes. A background sync is scheduled to fire 15 seconds after resume to give the network time to reconnect. If the network connects before the timer fires, the sync triggers immediately.
- **Export Settings:** Plugin configuration can be exported to a JSON file for backup or sharing. Sensitive fields (server URL, username, password) are excluded. Available under **Settings → Preferences → Export Settings**.
- **Test connection hash probe:** The Test Connection action now also probes the `by-hash` endpoint to verify full API access, not just server reachability.

### Bug Fixes

- **Book menu:** Improved error handling in `setBookTracking` and `isBookTrackingEnabled` for books with missing cache entries.
- **Shelf sync:** Fixed download directory detection using KOReader's `home_dir` setting.
- **Sync popup:** Synced and skipped counts are now shown correctly for all item types, not only sessions.
- **Hardcover:** Fixed server URL reference used when fetching Hardcover book metadata.
- **Menu:** Hardcover menu item text corrected for the "Fetch Hardcover Book IDs" action.

### Breaking changes

- Database schema updated (migration runs automatically on first startup after update). New additions: `tracking_enabled` column in `book_cache`, `pending_deletions` table, `synced_bookmarks` table, `hardcover_id` column in `book_cache`.

---

## 3.4.0 (2026-02-22)

### Features

- **Ratings sync:** Ratings can now be synced to BookLore via `POST /api/v1/books/{id}/personal-info`. Enable in **Settings → Sync Settings → Ratings & Notes Sync → Sync ratings**.
- **Notes and highlights sync:** KOReader highlights and notes are synced to BookLore via `POST /api/v1/books/{id}/notes`. Colour mapping (KOReader → BookLore hex), EPUB CFI generation, and sync are all handled automatically. Enable in **Settings → Sync Settings → Ratings & Notes Sync → Sync notes**.
- **Ratings & Notes sync menu:** A dedicated **Ratings & Notes Sync** sub-menu groups all annotation-related sync toggles and settings under **Settings → Sync Settings**.
- **Deferred rating retry:** Ratings that cannot be submitted immediately (e.g. while offline or before the book ID is resolved) are stored in a `pending_ratings` queue and retried automatically.
- **Live in-memory rating support:** Ratings set during a reading session are kept in memory and submitted at sync time without requiring a database round-trip.
- **Session details view:** The session details screen now shows pending upload counts and additional sync state information.
- **Selective cache clear:** The clear-cache action now presents a category-level selection dialog, letting you choose which cache entries (book IDs, sessions, annotations, ratings) to clear rather than wiping everything at once.
- **Server URL sanitisation:** The server URL entered in settings is automatically trimmed and normalised (trailing slashes removed, scheme enforced) before use.
- **Connection test feedback:** The connection test dialog now reports specific failure reasons rather than a generic error message.
- **Metadata parser:** Internal metadata parser added to extract and normalise book metadata fields from KOReader document settings.

### Bug Fixes

- **Rating dialog:** Delayed keyboard display in the rating dialog to prevent crashes when running on Linux.
- **Sync:** Annotations whose CFI cannot be built are now marked as synced to prevent indefinite retry loops.
- **API:** Error messages from server responses are now extracted and surfaced correctly in all error dialogs.
- **Database:** Schema version updated and constraints on `pending_annotations` and `pending_ratings` tables relaxed for compatibility.

### Breaking changes

- Database schema updated to version 9. Migration runs automatically on first startup after update. New additions: `pending_annotations` table, `pending_ratings` table, book metadata columns in `book_cache`.

---

## 3.3.1 (2026-02-20)

### Bug Fixes

- **Reading session:** Corrected page retrieval method for EPUB format to return accurate page numbers.

---

## 3.3.0 (2026-02-19)

### Features

- **Sessions:** Added support for PDF and archive-type formats (CBZ, CBR) in addition to EPUB.

---

## 3.2.0 (2026-02-16)

### Features

- **Logging:** Implemented file-based logging with daily rotation and automatic cleanup of old files (keeps last 3).
- **Logging:** Enhanced file logger with proper initialisation and graceful closure handling.

### Bug Fixes

- **Database:** Improved journal mode handling (`TRUNCATE` instead of `WAL`) for better reliability on e-reader storage.

---

## 3.1.0 (2026-02-16)

### Features

- **API:** Added batch session upload endpoint (`POST /api/v1/reading-sessions/batch`) with intelligent batching of up to 100 sessions per request - 10–20× faster than individual uploads.

### Bug Fixes

- **Sync:** Fallback to individual upload on `403 Forbidden` response from the batch endpoint (compatibility with older server versions).
- **Sync:** Fixed handling of `nil` progress values in session processing and batch uploads.

---

## 3.0.0 (2026-02-16)

### Features

- **Auto-updater:** Full self-update system with GitHub integration, one-tap installation, automatic backup, rollback support, and daily update checks.

### Bug Fixes

- **Menu:** Fixed dynamic pending count display using `text_func` instead of static `text`.
- **Updater:** Fixed HTTP redirect handling for KOReader compatibility.
- **Updater:** Removed duplicate restart confirmation dialog.
- **Updater:** Fixed `lfs` library path resolution for KOReader.

### Breaking changes

- Database schema migrated from version 7 to 8. Migration runs automatically on first startup after update.

---

## 1.1.1 (2026-02-15)

### Bug Fixes

- Fixed version tag in GitHub release pipeline.

---

## 1.1.0 (2026-02-15)

### Features

- **Logging:** Added URL redaction (secure logs) to protect server addresses in shared log output.

---

## 1.0.0 – 1.0.5 (2026-02-15)

Initial public release series. Versions 1.0.1 through 1.0.5 were CI and release pipeline fixes.

### Features in 1.0.0

- Automatic session tracking on book open/close/suspend/resume
- Book fingerprinting with sample-based MD5 algorithm
- Book ID resolution and caching in SQLite
- Session validation (minimum duration and pages)
- Offline queue with retry logic and book ID resolution
- Batch upload support
- Settings UI (server URL, credentials, session thresholds)
- Dispatcher integration (toggle, sync, manual mode, test connection)
- Rating sync (KOReader scaled and select-at-complete modes)
- Highlights and notes sync with EPUB CFI generation
- Annotation colour mapping (KOReader → BookLore hex)
- SQLite database with schema versioning and migrations
- Progress decimal places configuration
- Silent mode and debug logging preferences
