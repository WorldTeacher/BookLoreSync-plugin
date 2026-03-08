+++
title = "Ratings"
description = "Syncing book ratings from KOReader to BookLore and Hardcover."
weight = 3
+++

# Ratings

Rating sync pushes your book ratings from KOReader to your BookLore library. Optionally, ratings can also be synced to your [Hardcover](https://hardcover.app) account.

---

## Prerequisites

Rating sync requires:

- The **BookLore account credentials** to be configured (for Bearer token authentication). See [Authentication](@/configuration/authentication.md).
- **Enable rating sync** toggled on in **Settings → Sync Settings → Rating Sync**.

---

## Rating modes

### KOReader rating (scaled ×2)

KOReader uses a 1–5 star rating. BookLore uses a 1–10 scale. This mode multiplies the KOReader star rating by 2 to convert it:

| KOReader | BookLore |
|----------|----------|
| ★☆☆☆☆ (1 star) | 2 |
| ★★☆☆☆ (2 stars) | 4 |
| ★★★☆☆ (3 stars) | 6 |
| ★★★★☆ (4 stars) | 8 |
| ★★★★★ (5 stars) | 10 |

The rating is read from the `summary.rating` field of KOReader's `DocSettings`. When syncing at book-close time, the live in-memory `DocSettings` object is used directly. In all other cases (e.g. deferred sync of pending sessions), the `.sdr` sidecar file on disk is read as a fallback. If no rating has been set in KOReader, nothing is synced.

The rating is pushed at the end of a reading session using:

```
PUT /api/v1/books/personal-rating
Body: { "ids": [book_id], "rating": <value> }
```

### Select at complete

When this mode is active, a rating dialog appears when you close a book that has **99% or more reading progress** - that is, when you finish reading it.

![Koreader Rating Dialog](../koreader-rating-dialog.png)

The dialog shows a 1–10 picker. Tap a number to submit the rating immediately. If you dismiss the dialog without selecting, no rating is synced for that session.

> The dialog is delayed by ~2s and deliberately does not auto-open the software keyboard, for compatibility with certain devices where keyboard auto-opening during document close can cause display issues.

---

## Hardcover rating sync

The plugin can sync ratings to your [Hardcover](https://hardcover.app) account in parallel with (or independently of) BookLore.

### Setup

1. Create a file named **`hardcover.token`** in the plugin folder and paste your Hardcover API token into it (get it from **hardcover.app → Profile → API**).
2. Tap **Tools → BookLore Sync → Hardcover → Configure Hardcover Account** to load the token.
3. Run **Tools → BookLore Sync → Hardcover → Fetch Hardcover Book IDs** to populate Hardcover IDs for your matched books.
4. Toggle on **Hardcover rating sync** in **Sync Settings → Rating Sync**. This toggle is only available when **Enable rating sync** is also on.

See [Hardcover configuration](@/configuration/hardcover.md) for full setup details.

### Fetch Hardcover Book IDs

Before ratings can sync, each book needs a Hardcover ID stored locally. Run **Tools → BookLore Sync → Hardcover → Fetch Hardcover Book IDs** to populate these. The process runs in three stages:

1. **BookLore metadata** - pulls `hardcover_id` from BookLore for each matched book and stores it locally.
2. **ISBN search** - for books without an ID from stage 1, queries the Hardcover GraphQL API by ISBN-13.
3. **Title/author search** - for books still without an ID, searches Hardcover by title and author. Tap the correct match from the list or skip the book.

IDs only need to be fetched once per book. Re-running skips books that already have an ID stored.

### How it works

When a rating is ready to sync, the plugin:

1. Looks up the book's Hardcover ID in the local database cache.
2. If found, converts the BookLore rating (1–10) to a Hardcover rating (0–5) by dividing by 2 (e.g. a BookLore rating of 8 → Hardcover 4.0 stars), then submits it via the Hardcover GraphQL API.
3. If no Hardcover ID is stored, sync is skipped for that book and a warning is logged. There is no runtime fallback search - run **Fetch Hardcover Book IDs** beforehand to populate missing IDs.

The token is validated before any Hardcover API call is made. If validation fails, Hardcover sync is skipped for that session and a warning is logged.

---

## Deduplication

The plugin tracks which books have already had a rating synced using the `rating_sync_history` table. Once a rating has been submitted for a book, that book cannot be re-rated. For the **Select at complete** mode, if a book is opened and closed multiple times while progress remains in the 99%–100% range without a rating being submitted, the dialog will appear each time until a rating is selected.

---

## Retry on failure

If a rating upload fails (e.g., a network error), the rating is added to the `pending_ratings` table and retried on the next sync.

---

## Disabling rating sync

To stop rating sync, toggle off **Enable rating sync** in:

**Tools → BookLore Sync → Sync Settings → Rating Sync → Enable rating sync**

Pending ratings already in the queue will not be uploaded after disabling.
