+++
title = "Manage Sessions"
description = "Manually sync pending data, inspect queue state, resolve unmatched books, and clear local caches."
weight = 3
+++

# Manage Sessions

Found at: **Tools → BookLore Sync → Settings → Manage Sessions**

This menu contains five actions: Sync Pending Now, View Details, Match Unmatched Books, Clear Pending, and Clear Cache.

---

## Sync Pending Now

Immediately uploads all pending sessions, ratings, and annotations to the server.

The label shows the current queue sizes when items are waiting — for example **Sync Pending Now (3s, 1a, 2r)** means 3 sessions, 1 annotation, and 2 ratings are queued. The entry is greyed out when all three queues are empty.

Uploads proceed in three phases: ratings first, then annotations, then sessions. Sessions are sent in a batch of up to 100 at a time. Any session whose BookLore book ID is not yet known is resolved against the server first; if resolution fails, that session is skipped and retried next time.

When complete, a summary toast shows how many items were synced and how many failed.

> Failed items are never discarded automatically. They stay in the queue and are retried on every subsequent sync attempt.

---

## View Details

Displays a read-only summary of the current local database state. No data is modified.

| Section | What it shows |
|---------|--------------|
| Book cache | Total books seen, how many have a resolved BookLore ID (matched), and how many do not (unmatched) |
| Pending uploads | Count of sessions, annotations, and ratings waiting to be sent to the server |

The dialog stays open until you tap to dismiss it.

---

## Match Unmatched Books

Attempts to resolve books in the local cache that do not yet have a BookLore ID. The label shows the unmatched count when it is greater than zero — for example **Match Unmatched Books (4)**. The entry is greyed out when all books are already matched or the cache is empty.

A network connection is required. If the device is offline, a brief error toast is shown and nothing further happens.

**Automatic resolution**

The plugin queries the server for each unmatched book using its file fingerprint (MD5 hash). If the server recognises the book, the BookLore ID is stored in the local cache. Any pending sessions, ratings, and annotations for newly matched books are synced silently in the background.

**Manual resolution**

If automatic resolution finds no new matches but unmatched books remain, a confirmation dialog asks whether to proceed with manual matching. Tapping **Yes** steps through each unmatched book:

1. BookLore is searched by the book's title or filename.
2. Up to five results are shown with title, author, and a match-score percentage.
3. Tap a result to confirm the match, or tap **Skip this book** to leave it unmatched for now.

When a match is confirmed, the plugin immediately uploads any pending items for that book.

> Books that cannot be found on the server remain unmatched until the book is added to BookLore. Run **Match Unmatched Books** again after adding new books to your library.

---

## Clear Pending

Permanently discards items from the pending upload queues. The label shows the current queue sizes when items are waiting — for example **Clear Pending... (3s, 0a, 2r)**. The entry is greyed out when all queues are empty.

Tapping the entry opens a dialog listing only the queue types that currently have items, each pre-selected. Uncheck any type you want to keep, then tap **Clear Selected** to delete the checked queues. Tap **Cancel** to close without making any changes.

Already-synced sessions in `historical_sessions` and book–ID mappings in `book_cache` are not affected.

> **Warning:** Cleared items are permanently deleted and will not be uploaded to BookLore. There is no undo. Use this only to discard data you are sure you do not want — for example, test sessions from initial setup.

---

## Clear Cache

Removes all entries from the `book_cache` table. The entry is greyed out when the cache is already empty.

The cache stores the mapping between each local file and its BookLore book ID, along with the file fingerprint and metadata such as title, author, and ISBN. Clearing it does not affect pending sessions, ratings, or annotations.

The cache rebuilds automatically: the next time you open a book, the plugin recalculates its fingerprint, queries the server, and repopulates the cache entry.

> Use this after reorganising your library (for example, after moving many files to different folders) to force the plugin to rebuild all file-path-to-book mappings cleanly. No confirmation dialog is shown — the cache is cleared immediately.
