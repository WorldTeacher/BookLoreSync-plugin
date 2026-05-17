+++
title = "Recommendations"
description = "Post-finish book recommendations from your BookLore server."
weight = 9
+++

# Recommendations

The plugin can show book recommendations when you finish a book, fetched from your BookLore server. You can browse similar titles, view details, and download recommended books directly — all without leaving KOReader.

![Recommendations flow diagram](../recommendations-flow.png)

---

## How it works

When you close a book that has reached **99% or more progress** and the recommendations toggle is enabled:

1. The plugin calls `GET /api/v1/books/{id}/recommendations?limit=10` on your BookLore server, fetching up to 10 similar titles.
2. After a short delay (3 seconds), a **Recommendations** dialog appears with the list of recommended books, sorted by match score.
3. Tapping a title opens a details dialog showing:
   - **Title** and **subtitle**
   - **Author(s)**
   - **Series** name and number
   - **Publisher** and **published date**
   - **Page count** and **language**
   - **ISBN-13** / **ISBN-10** (when available)
   - **Description** (HTML stripped, truncated at 800 characters)
4. From the details dialog you can:
   - **Return to recommendations** — go back to the list
   - **Fetch** — download the book to your device, then ask whether to open it
   - **Close** — dismiss the dialog

### Duplicate guard

The module prevents the recommendations dialog from appearing more than once within 30 seconds for the same book, so rapid close-and-reopen cycles won't spam you.

---

## Enabling recommendations

Found at: **Tools → BookLore Sync → What to Sync → Recommendations**

| Setting | Default | Description |
|---------|---------|-------------|
| Show recommendations after finishing a book | Off | When enabled, finishing a book (≥99% progress) fetches and displays recommendations. |

The toggle is independent of rating sync — you can use recommendations with or without the rating feature enabled.

---

## Triggering manually

You can also fetch recommendations for any matched book on demand:

**From the file manager:** Long-press a book file and select **Get recommendations**. This bypasses the toggle setting and works even if the automatic post-finish feature is disabled, as long as the book has been matched to a BookLore entry.

**Requirements for manual triggering:**
- The book must be registered in the local database (open it once first)
- The book must be matched to a BookLore book entry
- BookLore account credentials must be configured
- A network connection must be available

---

## Downloading recommendations

When you tap **Fetch** on a recommended book:

1. The plugin checks your configured download directory (same as shelf sync's `download_dir`).
2. If the file already exists locally, it skips the download and asks whether to open it.
3. Otherwise, it downloads the book from BookLore using the authenticated download endpoint.
4. After a successful download, metadata (title, author, ISBN, page count, hash) is saved to the local database, so the book is immediately recognised and matched.
5. A confirmation dialog asks whether to open the book now.

The downloaded file uses the same filename convention as shelf-synced books (see [Shelf Sync](@/features/shelf-sync.md)).

> **Note:** Recommendations download to the same location as shelf-synced books (`download_dir`). If you use shelf sync, make sure this directory has enough free space for additional downloads.

---

## Requirements

| Requirement | Details |
|-------------|---------|
| **BookLore server** | Version supporting `GET /api/v1/books/{id}/recommendations` |
| **BookLore account credentials** | Configured in Connection Setup (used for Bearer auth) |
| **Book must be matched** | The finished book must have a resolved BookLore book ID |
| **Network connection** | Recommendations are fetched live — no offline queue for this feature |

---

## Limitations

- **No offline queue** — Recommendations are fetched at the moment the book is closed. If you're offline, they are silently skipped.
- **No caching** — Each fetch calls the server live. Repeatedly closing and reopening the same book will make a new request each time (subject to the 30-second duplicate guard).
- **Depends on server** — The quality and availability of recommendations depends entirely on your BookLore server's recommendations engine. If the server returns no results, a "No recommendations available" message is shown.
