+++
title = "Introduction"
description = "What the BookLore Sync plugin does and what formats it supports."
weight = 0
+++

# BookLore Sync

![KOReader Tool menu](../koreader-menu-main.png)

**BookLore Sync** is a [KOReader](https://github.com/koreader/koreader) plugin that automatically tracks your reading sessions and syncs them - along with ratings, highlights, and notes - to your self-hosted [BookLore](https://github.com/adityachandelgit/BookLore) server.

---

## What does it do?

When you read a book in KOReader, the plugin silently records your session - when you started, when you stopped, how many pages you covered, and your current progress. When you close the book (or the device wakes from sleep), it uploads that session to your BookLore server.

If you are offline, sessions are queued locally and uploaded the next time a connection is available.

Beyond session tracking, the plugin also supports:

- **Rating sync** - push your KOReader star rating to BookLore automatically, or pick a score on a 1–10 scale when you finish a book. Ratings can also be synced to your [Hardcover](https://hardcover.app) account.
- **Highlights, notes, and bookmark sync** - upload annotations and position bookmarks made in KOReader to BookLore, either attached to the passage (in-book) or as standalone notes on the book page.
- **Shelf sync** - pull books from a named BookLore shelf directly to your device for offline reading.
- **Per-book tracking toggle** - disable session tracking for individual books (reference books, cookbooks, etc.) without affecting the rest of your library.
- **Book deletion sync** - removing a book from KOReader notifies BookLore to remove it from your library too.
- **Auto-update** - the plugin can check for and install updates from GitHub without leaving KOReader.

---

## Feature overview

| Feature | Status |
|---------|--------|
| Automatic session tracking | Fully implemented |
| Offline queue with auto-retry | Fully implemented |
| Batch session upload (up to 100) | Fully implemented |
| Book rating sync to BookLore | Fully implemented |
| Book rating sync to Hardcover | Fully implemented |
| Highlights and notes sync | Fully implemented (EPUB + PDF with mock CFI) |
| Bookmark sync | Fully implemented |
| Annotations destination: In book / In BookLore / Both | Fully implemented |
| Shelf sync (download books from BookLore shelf) | Fully implemented |
| Per-book tracking toggle | Fully implemented |
| Book deletion sync | Fully implemented |
| File manager long-press actions | Fully implemented |
| EPUB CFI position for annotations | EPUB only |
| Auto-update from GitHub | Fully implemented |
| Supported formats: EPUB, PDF, CBZ, CBR | Fully implemented |
| Manual sync mode | Fully implemented |
| SQLite local database with migrations | Fully implemented |

---

## Format compatibility

| Feature | EPUB | PDF | CBZ / CBR |
|---------|:----:|:---:|:---------:|
| Session tracking | ✅ | ✅ | ✅ |
| Offline queue & auto-retry | ✅ | ✅ | ✅ |
| Batch session upload | ✅ | ✅ | ✅ |
| Rating sync | ✅ | ✅ | ✅ |
| Highlights & notes sync | ✅ | ✅ (mock CFI) | ❌ Not supported |
| Bookmark sync | ✅ | ✅ | ❌ Not supported |
| CFI annotation positioning | ✅ Full | ⚠️ Mock placeholder | ❌ |
| Manual sync mode | ✅ | ✅ | ✅ |
| Auto-update | ✅ | ✅ | ✅ |

> **Note on PDF annotations:** PDF highlights are accepted by BookLore using a mock CFI placeholder and stored in your BookLore notebook. However, they do not appear on the PDF itself in KOReader - there's no precise in-reader positioning for PDF annotations.

---

## Supported formats

The plugin works with any book format that KOReader can open:

- **EPUB** - full support, including EPUB CFI generation for precise annotation positioning.
- **PDF** - page-based progress tracking, rating sync, and annotation sync with mock CFI.
- **CBZ / CBR** - comic/archive formats with page-based tracking. Annotations are not supported.


