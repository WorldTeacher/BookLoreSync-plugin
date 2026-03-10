+++
title = "File Manager Actions"
description = "Long-press context menu actions for individual books in the KOReader file browser."
weight = 7
+++

# File Manager Actions

The plugin adds three entries to the KOReader file manager's long-press (hold) context menu. These actions are available for any supported book file (EPUB, PDF, CBZ, CBR).

![KOReader long press menu](../book-long-press-menu.png)
---

## Booklore Sync

Manually sync a single book's data to the server without opening the book.

Tapping **Booklore Sync** opens a sub-dialog with three options:

| Option | Action |
|--------|--------|
| **Annotations** | Upload all pending highlights and notes for this book |
| **Rating** | Upload the KOReader star rating for this book |
| **Both** | Upload annotations and rating together |

![Confirmation Dialog for BookLore Sync](../lpm-bl-sync.png)

### Annotations

Before syncing, a confirmation dialog warns:

> **Will only sync to webUI, not in book, as spine is missing**

This is because the book is not currently open, so no live rendering context (spine) is available. Annotations are sent to BookLore's web interface - they appear in BookLore but cannot be injected back into the book file itself. Tap **Continue** to proceed.

The plugin reads annotations from the book's sidecar (`.sdr`) directory on disk and uploads any that have not already been synced. A toast shows how many were synced or failed.

> **Requirement:** The book must have been opened at least once so it has a local database entry, and it must already be matched to a BookLore book (see [Match Book](#match-book) below).

### Rating

Uploads the KOReader star rating for the book.

- In **KOReader Scaled** mode: reads the star rating from the book's `.sdr` metadata. If no rating has been set in KOReader, a message is shown instead.
- In **Select at Complete** mode: opens an interactive rating dialog so you can choose a rating to send now.

> **Requirement:** BookLore Account credentials must be configured.

### Both

Runs annotation sync and rating sync together and shows a combined result message. If the rating mode is **Select at Complete**, the annotation result is shown first, then the rating dialog opens.

---

## Match Book

Manually match a book file to its entry in the BookLore library.

Description: **accepts title or id**.

![Manual Match dialog](../manual_match_lpm.png)

Tapping **Match Book** opens an input dialog pre-filled with the book's title (or filename if no title is known). You can:

- **Edit the search term** and tap **Search** to find the book by title.
- **Enter a numeric BookLore ID** (e.g. `42`) and tap **Search** to match directly by ID - no confirmation dialog is shown.

**Title search** returns up to five results, each showing the title, author, and a match-score percentage. Tap a result to confirm the match.

If the book is already matched, a confirmation dialog asks whether to re-match it.

Once a match is confirmed, any pending sessions, ratings, annotations, and bookmarks for that book are uploaded immediately.

> **Requirement:** BookLore Account credentials must be configured and a network connection must be available.

---

## Enable / Disable Tracking

Toggles per-book session tracking on or off for the selected file.

The menu entry label changes dynamically:

- Shows **Disable tracking** when tracking is currently enabled for the book.
- Shows **Enable tracking** when tracking is currently disabled.

When tracking is disabled:

- No session is recorded when you open, close, or sleep while reading the book.
- No annotations or ratings are synced for the book.
- The book is silently skipped - no notification is shown.

The tracking state is stored in the local database (`tracking_enabled` column in `book_cache`) and persists across KOReader restarts.

> Disabling tracking does not remove sessions that were already recorded. Pending sessions already in the queue are kept and will be uploaded on the next sync. Only new sessions are suppressed.

See also: [Session Tracking → Per-book tracking toggle](@/features/session-tracking.md#per-book-tracking-toggle)
