+++
title = "Import Reading History"
description = "Extract and match historical reading sessions from KOReader's statistics database."
weight = 4
+++

# Import Reading History

Found at: **Tools → BookLore Sync → Import Reading History**

Imports your existing reading history from KOReader's built-in statistics database into BookLore. This is a one-time setup process - normal sessions recorded after the plugin is installed are handled automatically.

The recommended order is: **Extract → Match → (check statistics) → Sync**.

---

## Extract Sessions from KOReader

Reads KOReader's statistics database and converts page-level reading data into sessions, which are stored in the plugin's local database.

A confirmation dialog is shown before extraction. If sessions have already been extracted, a second warning appears before running again, since re-running will add duplicate sessions.

Run this step once before any other action in this menu.

---

## Match Books with Booklore


![KOReader UI with matching menu, showing results for a title](../manual_match_page.png)

Matches extracted sessions to books on your BookLore server.

The process runs in two phases:

1. **Auto-sync** - Sessions already matched during extraction (by file hash) are uploaded immediately.
2. **Manual matching** - For each unmatched book the plugin attempts to find a match automatically using three strategies in order:
   - **ISBN** - searches by ISBN-13 or ISBN-10 if embedded in the file metadata. If a match is found you are shown a confirmation dialog with "Proceed" / "Manual Match" / "Skip" options.
   - **Hash** - queries the server by the file's MD5 hash. Auto-accepted if a match is returned.
   - **Title search** - falls back to a title search and presents up to 5 results with match scores. Tap a result to confirm; tap "Skip this book" or "Cancel matching" to move on.

   Once confirmed, the sessions for that book are uploaded immediately.

Requires BookLore credentials and server URL to be configured. See [Authentication](@/configuration/authentication.md).

---

## View Match Statistics

![Historical Session Stats](../synced_stats.png)

Displays a summary of the imported history:

| Field | Description |
|-------|-------------|
| Total sessions | All sessions extracted from KOReader |
| Matched sessions | Sessions linked to a BookLore book |
| Unmatched sessions | Sessions with no BookLore match yet |
| Synced sessions | Sessions that have been uploaded to the server |

---

## Re-sync All Historical

Re-uploads all previously synced historical sessions to the server. Sessions that previously failed with a 404 (book not found) are marked for re-matching rather than re-uploaded.

Use this if you reset your BookLore library or need to rebuild server-side reading history.

Requires BookLore credentials and server URL to be configured.

---

## Sync Re-matched Sessions

Uploads sessions that were previously marked for re-matching (due to 404 errors) and have since been matched to valid books via **Match Books with Booklore**.

Run this after completing a re-match pass to push the newly matched sessions to the server.

Requires BookLore credentials and server URL to be configured.

---

## Manual Matching

Iterates over all books in the local cache that have no BookLore match yet, and lets you match them one at a time.

For each unmatched book an input dialog is shown, pre-filled with the book's cached title. You can:

- **Edit the title** and press Search to search BookLore by title - up to 5 results are shown with match scores; tap a result to confirm the match.
- **Enter a numeric ID** instead of a title to fetch a specific book directly from BookLore by its ID. The match is saved immediately without a confirmation step.
- **Skip** the current book and move to the next.
- **Cancel** to exit the matching flow entirely.

After a match is confirmed the book's `book_id` is written to the local cache and any pending sessions for that book are synced automatically.

Requires BookLore credentials and server URL to be configured. See [Authentication](@/configuration/authentication.md).
