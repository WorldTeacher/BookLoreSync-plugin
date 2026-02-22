+++
title = "Changelog"
description = "Full version history for the BookLore Sync plugin."
weight = 4
+++

# Changelog

All notable changes to the BookLore Sync plugin are documented here.

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

- **API:** Added batch session upload endpoint (`POST /api/v1/reading-sessions/batch`) with intelligent batching of up to 100 sessions per request — 10–20× faster than individual uploads.

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
