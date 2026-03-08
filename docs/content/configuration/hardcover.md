+++
title = "Hardcover"
description = "Configure Hardcover.app integration for rating sync and book ID management."
weight = 5
+++

# Hardcover

Found at: **Tools → BookLore Sync → Hardcover**

Manages the connection between the plugin and your [Hardcover](https://hardcover.app) account. This menu has two items: loading your API token and fetching book IDs.

Hardcover integration is used for rating sync - see [Ratings](@/features/ratings.md#hardcover-rating-sync) for details on enabling it.

---

## Configure Hardcover Account

Loads your Hardcover API token from a file in the plugin folder.

**Setup steps:**

1. Go to **hardcover.app → Profile → API** and copy your JWT token.
2. Create a file named **`hardcover.token`** inside the plugin folder (`bookloresync.koplugin/hardcover.token`).
3. Paste the token into the file - one line, no extra whitespace.
4. Tap **Configure Hardcover Account**. The plugin reads the file and saves the token to settings.

If the file is missing or empty, an error dialog appears with the expected file path.

The token is not entered via a text field - it must be written to the file first.

---

## Fetch Hardcover Book IDs

Populates the local database with a Hardcover book ID for each matched book. This is required before rating sync can send ratings to Hardcover.

Run this once after setting up your Hardcover token and after your books are matched in BookLore.

**What it does:**

1. For every book in the local cache that already has a Hardcover ID stored, the book is skipped.
2. For remaining books, the plugin calls the BookLore API to retrieve the `hardcover_id` stored on the server. If found, it is saved locally.
3. For books where BookLore has no `hardcover_id`, the plugin falls back to searching Hardcover directly:
   - **ISBN-13 lookup** - unambiguous; the ID is saved automatically if found.
   - **Title/author search** - presents a list of candidates (up to 10). Tap the correct match or tap **Skip this book** to move on.

A summary is shown at the end with counts for stored, skipped, and failed books.

Requires BookLore server URL and credentials to be configured. See [Authentication](@/configuration/authentication.md).

---

## Credits

The Hardcover integration was heavily inspired by and referenced against [Billiam/hardcoverapp.koplugin](https://github.com/Billiam/hardcoverapp.koplugin). Many thanks to its author for the pioneering work on Hardcover/KOReader integration.
