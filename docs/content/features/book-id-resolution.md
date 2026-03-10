+++
title = "Book ID Resolution"
description = "How the plugin identifies which book in your BookLore library corresponds to the file you are reading, including the ISBN fallback."
weight = 2
+++

# Book ID Resolution

Before a reading session, annotation, or rating can be uploaded to BookLore, the plugin must know the BookLore internal ID of the book you are reading. This page explains how that ID is resolved, including the automatic ISBN-based fallback that runs when the primary lookup fails.

---

## How to ensure a book is matched via ISBN

Use this when the hash lookup fails - for example, because the file on your device is a different conversion of the same book - and the book has an ISBN in your BookLore library.

**Prerequisites:**

- The book exists in your BookLore library with an ISBN.
- The file on your device has an ISBN embedded in its metadata (see below).
- The plugin is connected to your BookLore server.

---

## Step 1 - Embed the ISBN into the file using Calibre

ISBN matching requires the ISBN to be physically embedded inside the book file itself. KOReader reads this metadata when the file is opened; it is not enough for the ISBN to exist only on the server side.

The most reliable way to embed metadata is with [Calibre](https://calibre-ebook.com/):

1. Open your Calibre library and select the book.
2. Click **Edit metadata** (or press `E`) and confirm the ISBN field is populated. If it is not, use **Download metadata** to fetch it automatically.
3. Install (or confirm you have) the **Embed metadata** plugin via **Preferences → Plugins → Get new plugins**.
4. Right-click the book → **Embed metadata**. This writes the ISBN and other fields directly into the file.
5. Export the updated file to your device (right-click → **Send to device**, or copy the file manually from the Calibre library folder).

> **Note:** This step must be done before opening the book in KOReader for the first time. If the book is already cached on your device without an ISBN, you will need to delete the local cache entry from **Tools → BookLore Sync → Manage Cache** and re-open the file.

---

## Step 2 - Open the book in KOReader

Open the book normally. The plugin will:

1. Calculate the MD5 fingerprint of the file and query `GET /api/koreader/books/by-hash/:hash`.
2. If the hash lookup returns no match, automatically attempt an ISBN lookup (see below).
3. Cache the resolved book ID for all future sessions.

No additional action is required from you.

---

## How the ISBN fallback works

When the hash lookup returns no match and the device is connected to the network, the plugin:

1. Reads the ISBN from the book's in-memory metadata (`doc_props.identifiers`). ISBN-13 is preferred; ISBN-10 is used if no ISBN-13 is present.
2. Calls `GET /api/v1/books/search?isbn=<isbn>`.
3. Inspects the results for an **exact match only** - a result is accepted only when the server returns `matchScore == 1`. Partial matches are rejected.
4. If an exact match is found, the resolved book ID is cached and the session proceeds normally.

---

## What you will see

| Situation | On-screen message |
|-----------|-------------------|
| Hash matched | *(no message - proceeds silently)* |
| Hash failed, ISBN matched exactly | *(no message - proceeds silently)* |
| Hash failed, ISBN present but no exact match | `"No match found based on hash or ISBN. Does this book exist in your Booklore library?"` |
| Hash failed, no ISBN in file | `"No match found based on hash. Does this book exist in your Booklore library?"` |
| No network connection | *(no message - session saved locally, ID resolved on next sync)* |

---

## Why only exact matches are accepted

The ISBN search endpoint may return multiple candidates when an ISBN appears in more than one edition. Accepting a low-confidence match would silently associate your sessions with the wrong book. The `matchScore == 1` requirement ensures the result is unambiguous before the ID is committed to the local cache.

---

## Troubleshooting

**The ISBN is in Calibre but the fallback still fails.**

- Confirm you ran **Embed metadata** *after* editing the ISBN and that you copied the updated file to the device. Calibre's library database and the physical file are separate - editing the database does not update the file.
- Open the KOReader book info panel (long-press the book → **Book information**) and check whether the identifiers field lists an ISBN. If it does not, the metadata was not embedded.

**The fallback matched the wrong book.**

This should not happen because only `matchScore == 1` results are accepted. If it does, open a bug report and include the ISBN and the BookLore book IDs involved.

**The book has no ISBN.**

ISBN matching will not help. Add the exact same file to BookLore so the hash matches, or use the manual matching flow in **Tools → BookLore Sync → File Manager Actions → Match to BookLore book**.
