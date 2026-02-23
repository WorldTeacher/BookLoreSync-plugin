+++
title = "Session Tracking"
description = "How reading sessions are detected, validated, and recorded."
weight = 1
+++

# Session Tracking

Session tracking is the core feature of the plugin. Every time you read a book in KOReader, the plugin records a reading session and uploads it to your BookLore server.

---

## What is a reading session?

A reading session is a single continuous reading period — from when you open (or resume) a book to when you close it (or the device sleeps). Each session contains:

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
- `progress_delta > 0`

**Detection mode: `pages`**

The session is kept if:
- `pages_read ≥ min_pages` (default: 5 pages)
- `progress_delta > 0`

Sessions that fail validation are discarded immediately and never written to the database.

> A session where progress did not advance at all (e.g., you opened the book at position X and closed it still at X) carries no useful information and is always discarded, regardless of duration or pages.

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
        W2["Silent background sync of pending sessions (if enabled)"]
        W1 --> W2
    end

    sleep -->|"Two separate sessions recorded"| wake
{% end %}

This means a reading period that spans a sleep event is split into **two sessions**: one before sleep, one after. Both sessions are uploaded to BookLore separately.

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

---

## Progress precision

Progress is always stored locally at full precision. The decimal places setting (default: 2, range: 0–5) is applied at sync time — it controls how many decimal places are sent to the BookLore server, not how many are kept in the local database.

For most use cases the default of 2 is fine. Increase it if your BookLore server reports noticeably rounded progress values for very long books.

See [Configuration → Session Tracking](@/configuration/session-tracking.md#progress-decimal-places) to change this setting.
