+++
title = "First Session Walkthrough"
description = "A detailed look at what happens under the hood when you open and close a book."
weight = 3
+++

# First Session Walkthrough

This page explains in detail what the plugin does from the moment you open a book to the moment a session appears in BookLore. Understanding this helps you diagnose issues and make the most of the configuration options.

---

## The session lifecycle

{% mermaid() %}
flowchart TD
    A["Open book"]
    A1["Calculate MD5 fingerprint"]
    A2["Query server for book ID"]
    A3["Record start time, progress"]
    B["Reading"]
    C["Session ends"]
    C1["Record end time, progress"]
    C2["Calculate duration, pages,   delta"]
    D{"Passes validation?"}
    E["Discard session"]
    F["Save to pending_sessions"]
    G{"Manual Sync Only?"}
    H["Upload to server"]
    H2["Stays in queue"]

    A --> A1 --> A2 --> A3 --> B
    B -->|"Close book or device sleep"| C
    C --> C1 --> C2 --> D
    D -->|"No"| E
    D -->|"Yes"| F
    F --> G
    G -->|"No"| H
    G -->|"Yes"| H2
{% end %}

---

## Book fingerprinting

Every book is identified by an MD5 fingerprint computed from a sample of its contents. This is the same algorithm used by BookLore's KOReader sync endpoint — it does not read the whole file, just strategic byte ranges, so it is fast even on large files.

The fingerprint is cached in the local database so it is only calculated once per file. If you move a book file to a different path, the cache is updated automatically.

---

## Book ID resolution

The plugin maps the file fingerprint to a BookLore internal book ID using:

```
GET /api/koreader/books/by-hash/:hash
```

The result is cached in the `book_cache` SQLite table alongside the file path, title, isbn10, isbn13 and author.

If the server is unreachable when you open the book, the session is saved with `book_id = NULL`. When the plugin next attempts to sync (on resume, on the next session end, or via manual sync), it re-queries the server using the cached hash to resolve the ID before uploading.

---

## Progress tracking

Progress is recorded as a percentage from 0.0 to 100.

- **EPUB**: reported by KOReader's EPUB rendering engine as a fractional position in the document.
- **PDF / CBZ / CBR**: calculated as `(current_page / total_pages) * 100`.

Progress is always stored locally at full precision. The decimal places setting (default: 2, range: 0–5) is applied at sync time to limit the precision of the value sent to the BookLore server. 

---

## Suspend and resume

When the device goes to sleep (suspend), the plugin behaves as if the book was closed:

- The current session is ended and validated.
- If valid, it is saved to the queue and a sync attempt is made.

When the device wakes up (resume):

- A new session starts from the current position.
- Any pending sessions in the queue are synced silently in the background. (Depends on settings)

This means a single uninterrupted reading period that spans a suspend/resume cycle is recorded as **two sessions**: one before sleep, one after.

---

## Batch upload

When multiple sessions are pending (e.g., after extended offline use), the plugin uploads them in a single batch request of up to 100 sessions at a time:

```
POST /api/v1/reading-sessions/batch
```

---

## Where data is stored

All local data lives in a single SQLite database:

```
{your_koreader_installation}/settings/booklore-sync.sqlite
```

Key tables:

| Table | Contents |
|-------|----------|
| `book_cache` | File path, hash, book_id, etc |
| `pending_sessions` | Sessions waiting to be uploaded |
| `historical_sessions` | Sessions successfully uploaded (archive) |
| `plugin_settings` | All plugin configuration key-value pairs |
| `synced_annotations` | Deduplication record for uploaded highlights/notes |
| `bearer_tokens` | Cached JWT token for extended API features |

See [Reference → Settings](@/reference/settings.md) for a full list of configuration keys stored in `plugin_settings`.
