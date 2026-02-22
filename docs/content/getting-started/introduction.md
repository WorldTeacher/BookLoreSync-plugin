+++
title = "Introduction"
description = "What the BookLore Sync plugin does and what formats it supports."
weight = 0
+++

# BookLore Sync

**BookLore Sync** is a [KOReader](https://github.com/koreader/koreader) plugin that automatically tracks your reading sessions and syncs them — along with ratings, highlights, and notes — to your self-hosted [BookLore](https://github.com/adityachandelgit/BookLore) server.

---

## What does it do?

When you read a book in KOReader, the plugin silently records your session — when you started, when you stopped, how many pages you covered, and your current progress. When you close the book (or the device wakes from sleep), it uploads that session to your BookLore server.

If you are offline, sessions are queued locally and uploaded the next time a connection is available.

Beyond session tracking, the plugin also supports:

- **Rating sync** — push your KOReader star rating to BookLore automatically, or pick a score on a 1–10 scale when you finish a book.
- **Highlights and notes sync** — upload annotations made in KOReader to BookLore, either attached to the passage (in-book) or as standalone notes on the book page.
- **Auto-update** — the plugin can check for and install updates from GitHub without leaving KOReader.

---

## Feature overview

| Feature | Status |
|---------|--------|
| Automatic session tracking | Fully implemented |
| Offline queue with auto-retry | Fully implemented |
| Batch session upload (up to 100) | Fully implemented |
| Book rating sync | Fully implemented |
| Highlights and notes sync | Fully implemented |
| EPUB CFI position for annotations | Fully implemented |
| Auto-update from GitHub | Fully implemented |
| Supported formats: EPUB, PDF, CBZ, CBR | Fully implemented |
| Manual sync mode | Fully implemented |
| SQLite local database with migrations | Fully implemented |

---

## Supported formats

The plugin works with any book format that KOReader can open:

- **EPUB** — full support, including EPUB CFI generation for precise annotation positioning
- **PDF** — page-based progress tracking
- **CBZ / CBR** — comic/archive formats with page-based tracking

---

## Quick navigation

- **New here?** Start with [Installation](/getting-started/installation/) and then [Quick Start](/getting-started/quick-start/).
- **Already installed?** Jump to [Configuration](/configuration/) to set up your server connection.
- **Looking for a specific feature?** Browse the [Features](/features/) section.
- **Something broken?** Check [Troubleshooting](/troubleshooting/common-issues/).
- **Need a settings reference?** See [Reference → Settings](/reference/settings/).
