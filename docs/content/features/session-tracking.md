+++
title = "Session Tracking"
description = "How reading sessions are detected, validated, and recorded."
weight = 1
+++

# Session Tracking

Session tracking is the core feature of the plugin. Every time you read a book in KOReader, the plugin records a reading session and uploads it to your BookLore server.

---

## What is a reading session?

A reading session is a single continuous reading period - from when you open (or resume) a book to when you close it (or the device sleeps). Each session contains:

| Field | Description |
|-------|-------------|
| `start_time` | ISO 8601 timestamp when reading began |
| `end_time` | ISO 8601 timestamp when reading ended |
| `duration_seconds` | Total seconds elapsed |
| `start_progress` | Progress percentage at the start |
| `end_progress` | Progress percentage at the end |
| `progress_delta` | Difference between end and start progress |
| `start_location` | Page number or position at the start |
| `end_location` | Page number or position at the end |
| `duration_formatted` | `duration_seconds` formatted to eg. 5m 4s |

---

## Supported formats

| Format | Progress method |
|--------|----------------|
| EPUB | Fractional document position from KOReader's rendering engine |
| PDF | `(current_page / total_pages) × 100` |
| CBZ | `(current_page / total_pages) × 100` |
| CBR | `(current_page / total_pages) × 100` |

---

## Session events

The plugin hooks into four KOReader events:

| Event | Trigger | Action |
|-------|---------|--------|
| `onReaderReady` | Book opens | Start new session |
| `onCloseDocument` | Book closes | End session, validate, queue |
| `onSuspend` | Device sleeps | End session, validate, queue |
| `onResume` | Device wakes | Start new session, sync pending |

---

## Session validation

Before a session is saved, it is validated against the thresholds you configure.

**Detection mode: `duration`** (default)

The session is kept if:
- `duration_seconds ≥ min_duration` (default: 30 seconds)
- `pages_read > 0` (at least one page was turned)

**Detection mode: `pages`**

The session is kept if:
- `pages_read ≥ min_pages` (default: 5 pages)

Sessions that fail validation are discarded immediately and never written to the database.

> In duration mode, a session where no pages were turned (e.g., you opened the book but did not scroll or turn a page) is always discarded, regardless of how long the book was open.

---

## Suspend and resume behaviour

{% mermaid() %}
flowchart LR
    subgraph sleep ["Device sleeps - onSuspend"]
        S1["End session at suspend timestamp"]
        S2["Validate and save to queue"]
        S3["Sync attempt (if enabled)"]
        S1 --> S2 --> S3
    end

    subgraph wake ["Device wakes - onResume"]
        W1["Start new session from current position"]
        W2["Deferred wake sync scheduled (15s delay)"]
        W3["Silent background sync of pending sessions"]
        W1 --> W2 --> W3
    end

    sleep -->|"Two separate sessions recorded"| wake
{% end %}

This means a reading period that spans a sleep event is split into **two sessions**: one before sleep, one after. Both sessions are uploaded to BookLore separately.

### Resume cooldown

To avoid flooding the server when a device suspends and resumes rapidly (e.g., repeated short sleep events), the plugin enforces a **5-minute cooldown** between auto-syncs triggered by resume. If a resume event occurs within 5 minutes of the last auto-sync, the sync is deferred rather than run immediately.

### Deferred wake sync

When the device wakes, the plugin schedules a sync to run **15 seconds after resume**. This gives the network time to reconnect before the upload is attempted. If the network is not yet available after 15 seconds, the session stays queued and will be picked up when connectivity is detected.

### Network-connected sync

If the plugin is waiting for network and the device reports a new connection (via the `onNetworkConnected` event), any deferred wake sync is triggered immediately without waiting for the full 15-second timer.

---

## Duration formatting

Session durations are displayed in human-readable format in notifications:

```
45s
2m 30s
1h 5m 9s
```

---

## Book fingerprinting

Each book is identified by an MD5 fingerprint computed from strategic byte samples of the file. This is the same algorithm used by BookLore's KOReader integration endpoint.

The fingerprint is:
- Computed once per file and cached in the local database.
- Used to look up the BookLore book ID from the server.
- Used to resolve the book ID for sessions that were saved offline.

If a book file is renamed or moved, the plugin detects the new path and updates the cache entry.

If the hash lookup returns no match, the plugin automatically attempts a second lookup using the ISBN embedded in the book file's metadata. Only an exact match is accepted. See [Book ID Resolution](@/features/book-id-resolution.md) for how this works and how to prepare your files.

---

## Progress precision

Progress is always stored locally at full precision. The decimal places setting (default: 2, range: 0–5) is applied at sync time - it controls how many decimal places are sent to the BookLore server, not how many are kept in the local database.

Increase this value if your BookLore server reports noticeably rounded progress values for very long books.

See [Configuration → Session Tracking](@/configuration/session-tracking.md#progress-decimal-places) to change this setting.

---

## Per-book tracking toggle


You can disable session tracking for individual books without turning off the plugin globally. This is useful for reference books, cookbooks, or any book where you do not want reading history recorded.

**To toggle tracking for a book:**

1. Long-press the book in the file manager.
2. Select **Enable tracking** or **Disable tracking** from the context menu.

When tracking is disabled for a book:
- No session is saved when you close or suspend the device while reading it.
- No annotations or ratings are synced.
- The book is silently skipped - no notification is shown.

The tracking state is stored per-book in the local database (`tracking_enabled` column in `book_cache`) and persists across restarts.

---

## Session feedback


After a session ends, the plugin may show a brief notification:

| Result | Message shown | Condition |
|--------|--------------|-----------|
| Session saved / queued | `"Session saved"` with annotation count | Manual Sync Only mode; not in silent mode |
| Criteria not met | `"Session not saved: criteria not met"` | Session failed validation (too short or no progress); not in silent mode |
| Tracking disabled | *(no message)* | Book has tracking disabled |

All session notifications are suppressed when **Silent Mode** is enabled in preferences.

---

## Book deletion notification

When you delete a book from the file manager (via the long-press menu), the plugin sends a deletion event to BookLore:

```
DELETE /api/v1/books/{id}
```

If the book's server ID is not yet known (e.g., it was never synced), or if the device is offline, the deletion is stored in the `pending_deletions` table and retried on the next sync.

This keeps your BookLore library in sync with your device - books you remove locally are also removed from the server.
