+++
title = "Changelog"
description = "Full version history for the BookLore Sync plugin."
weight = 4
+++

# Changelog

All notable changes to the BookLore Sync plugin are documented here.

---

## 4.0.1 - 4.2.0

### Features

- **Progress sync actions:** Added dispatcher actions for **Pull Current Book Progress** and **Push Current Book Progress** so progress can be triggered manually from gestures/buttons.
- **Progress location normalization:** Added optional normalization of session start/end locations to server page-count scale, plus metadata re-sync support for better page alignment.

### Improvements

- **Shelf sync naming:** Updated menu labels from "Shelf Downloads" to **Shelf Sync** for clearer navigation.
- **Sync/runtime performance:** Reduced overhead in sync paths (including periodic progress updates and exit handling).
- **Sync Behavior menu:** Grouped WiFi connection options under **Sync Behavior → Networking** for clearer configuration flow.
- **Network tuning controls:** Added configurable WiFi connect timeout, optional "run until connect" mode, and post-connect sync delay for slow networks.

### Bug fixes

- **Progress pull safety:** Remote KOReader progress entries at `0%` are ignored during pull, so they are not offered as a sync target and do not overwrite local state.
- **Progress prompt precision:** Progress conflict prompts now show percentage values with one decimal place.
- **Stored Data session counts:** The **Show Stored Data** view now reports reading session totals correctly for synced/pending entries.
- **Network wait compatibility:** Added fallback sleep handling for KOReader builds where `ffi/util.sleep` is unavailable during WiFi connect wait.

---

## 4.0.0 (2026-04-05)

### Features

- **KOReader progress sync:** Added document-position sync with pull-on-open/resume, push-on-open/close, optional periodic page-turn updates, configurable forward/backward conflict strategies, and progress queue processing in `Sync Pending Now`.
- **Updater file preservation:** Auto-update now preserves and restores user-specific files across installs (`hardcover.token`, `dev-build.location`).
- **Shelf sync storage guard:** Added pre-download free-space checks with configurable minimum free space (`min_free_space_mb`, default `500 MB`).
- **Shelf delta cache management:** Added shelf state caching for delta-based syncs plus **Force full re-sync** to clear cached shelf state and run a full pass.
- **Advanced data tools:** Added **Re-match All Books in Cache** and selective **Clear Synced History** options (historical sessions, synced annotations, synced bookmarks, rating sync history, synced progress).
- **Per-book tools expanded:** File manager long-press menu now includes additional diagnostic actions (**Show Stored Data**, **Extract from Sidecar**) alongside sync/match/tracking actions.

### Improvements

- **Settings input handling:** Minimum duration and minimum pages inputs now use streamlined validation/error handling.
- **Session management UX:** Pending/synced summaries now include progress queue/history counts where relevant.
- **Plugin naming alignment:** Internal/release naming was aligned to `bookloresync` to match KOReader plugin expectations.
- **Settings menu organization:** Reordered top-level settings and renamed key sections for task-first navigation (**Enable Sync**, **Connection Setup**, **What to Sync**, **Sync Behavior**, **Sync & Cache**, **Shelf Sync**, **Import & Matching**, **Integrations**, **Appearance & Diagnostics**, **About & Updates**).

### Documentation

- **Required for this PR:** Updated docs and menu-path references to match the reorganized settings structure and labels.

### Bug Fixes

- **Updater restore reliability:** Improved error handling during restoration of preserved user files after update.

### Breaking changes

- Database schema updated to **v24** (migration runs automatically on first startup after update). Additions include progress-sync tables/history and new management helpers used by advanced clear/rematch flows.

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
