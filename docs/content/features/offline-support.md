+++
title = "Offline Support"
description = "How the plugin handles reading sessions when no network connection is available."
weight = 2
+++

# Offline Support

The plugin is designed to work fully offline. Sessions are always saved locally first and uploaded to the server when a connection is available. You never lose a reading session due to network unavailability.

---

## How the queue works

> Note: this assumes that the setup syncs immediately, instead of using manual upload

Every validated session is written to the `pending_sessions` table in the local SQLite database before any network request is attempted. The session remains there until it is successfully uploaded.

{% mermaid() %}
flowchart TD
    A["Book closed"]
    B["Session validated"]
    C["INSERT into pending_sessions"]
    D{"Network available?"}
    E["POST to server"]
    F["200 OK - move to historical_sessions"]
    G["Error - increment retry_count"]
    H["No network - stays in queue"]

    A --> B --> C --> D
    D -->|Yes| E
    E -->|Success| F
    E -->|Failure| G
    D -->|No| H
{% end %}

---

## Offline book ID resolution

When you open a book without a network connection, the plugin cannot look up the BookLore book ID. In this case, the session is saved with `book_id = NULL` and the file fingerprint (MD5 hash) is recorded instead.

When a sync is later attempted:

{% mermaid() %}
flowchart TD
    A["Sync triggered"]
    B["Find sessions where book_id = NULL"]
    C["Query server for book ID by hash"]
    D{"Book found on server?"}
    E["Store book_id and upload session"]
    F["Session stays in queue until book is matched"]

    A --> B --> C --> D
    D -->|Yes| E
    D -->|No| F
{% end %}

---

## Batch upload

When multiple sessions are pending, the plugin uploads them in a single batch request:

```
POST /api/v1/reading-sessions/batch
```

Up to **100 sessions per batch** are sent in one request. This is 10–20 times faster than individual uploads for large queues (e.g., after a week without a connection).


---

## Retry logic

Each pending session tracks a `retry_count` — the number of times upload has been attempted and failed. This counter is incremented on each failed attempt.

The retry count is visible when inspecting the database directly:

```sql
SELECT id, retry_count, book_id, duration_seconds FROM pending_sessions;
```

There is no automatic backoff or maximum retry limit — the plugin will keep retrying on every sync trigger until the session is successfully uploaded or manually cleared.

---

## Automatic sync triggers

Pending sessions are synced automatically in these situations:

| Trigger | Behaviour |
|---------|-----------|
| **Session end** | Sync attempted after every valid session (if not in Manual Sync Only mode) |
| **Device resume** | Silent background sync when device wakes from sleep |
| **Manual Sync Now** | Triggered by **Tools → BookLore Sync → Sync Now** |
| **Dispatcher action** | `SyncBooklorePending` can be assigned to a button or gesture |

---

## Inspecting the queue

To see how many sessions are waiting:

**Tools → BookLore Sync → Settings → Manage Sessions → View Details**

To view the raw data:

```bash
sqlite3 {your_koreader_installation}/settings/booklore-sync.sqlite \
  "SELECT id, book_hash, duration_seconds, retry_count, created_at FROM pending_sessions;"
```

---

## Clearing the queue

To discard all pending sessions:

**Tools → BookLore Sync → Settings → Manage Sessions → Clear Pending**

> **Warning:** This permanently deletes all queued sessions. They will not be uploaded to BookLore. Only use this to remove test data or sessions you do not want.
