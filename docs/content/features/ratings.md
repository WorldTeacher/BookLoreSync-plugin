+++
title = "Ratings"
description = "Syncing book ratings from KOReader to BookLore."
weight = 3
+++

# Ratings

The rating sync feature pushes your book ratings from KOReader to your BookLore library automatically, so your ratings are always in sync without manual data entry.

---

## Prerequisites

Rating sync requires:

- The **BookLore account credentials** to be configured (for Bearer token authentication). See [Authentication](/configuration/authentication/).
- **Enable rating sync** toggled on in **Settings → Rating**.

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

The rating is read from the book's KOReader `.sdr` sidecar file (the `summary.rating` field). If no rating has been set in KOReader, nothing is synced.

The rating is pushed at the end of a reading session using:

```
PUT /api/v1/books/personal-rating
Body: { "ids": [book_id], "rating": <value> }
```

### Select at complete

When this mode is active, a rating dialog appears when you close a book that has **99% or more reading progress** — that is, when you finish reading it.

![Koreader Rating Dialog](../koreader-rating-dialog.png)

The dialog shows a 1–10 picker. Tap a number to submit the rating immediately. If you dismiss the dialog without selecting, no rating is synced for that session.

> The dialog is delayed by ~2s and  deliberately does not auto-open the software keyboard, for compatibility with certain devices where keyboard auto-opening during document close can cause display issues.

---

## Deduplication

The plugin tracks which books have already had a rating synced using the `rating_sync_history` table. Once a rating has been submitted for a book, that book cannot be re-rated. For the **Select at complete** mode, if a book is opened and closed multiple times while progress remains in the 99%–100% range without a rating being submitted, the dialog will appear each time until a rating is selected.

---

## Retry on failure

If a rating upload fails (e.g., a network error), the rating is added to the `pending_ratings` table and retried on the next sync.

---

## Planned: Hardcover rating

A future mode will sync ratings to a [Hardcover](https://hardcover.app) account. This is not yet implemented and appears in the settings menu as a disabled option labelled "Hardcover rating (coming soon)".

---

## Disabling rating sync

To stop rating sync, toggle off **Enable rating sync** in:

**Tools → BookLore Sync → Settings → Rating → Enable rating sync**

Pending ratings already in the queue will not be uploaded after disabling.
