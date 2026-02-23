+++
title = "Sync Settings"
description = "Configure session detection, ratings, annotations, and sync triggers."
weight = 2
+++

# Sync Settings

Found at: **Tools → BookLore Sync → Settings → Sync Settings**

This menu contains four sections: Session Settings, Rating Sync, Annotations Sync, and Sync Triggers.

---

## Session Settings

### Detection Mode

**Options:** `Duration-based` (default) | `Pages-based`

Controls which threshold is used to decide whether a reading session is valid and worth uploading.

| Mode | Validation rule |
|------|----------------|
| Duration-based | Session must meet the **Minimum Duration** threshold |
| Pages-based | Session must meet the **Minimum Pages** threshold |

Only one mode is active at a time.

### Minimum Duration

**Default:** `30` seconds

Sessions shorter than this are discarded without being saved or uploaded. Prevents accidental micro-sessions (e.g. opening a book to check a page number) from appearing in your reading history.

Only active when Detection Mode is set to **Duration-based**.

### Minimum Pages

**Default:** `5` pages

Sessions where fewer pages were read than this value are discarded. Useful for formats where short time can still represent real progress (e.g. picture books, comics).

Only active when Detection Mode is set to **Pages-based**.

### Progress Decimal Places

**Default:** `2` &nbsp;|&nbsp; **Range:** 0 – 5

Controls how many decimal places are included in the progress percentage **sent to the server** at sync time. The full precision value is always stored in the local database; this setting only limits what is transmitted.

| Setting | Value sent |
|---------|------------|
| `0` | `42%` |
| `2` | `42.37%` (default) |
| `5` | `42.37185%` |

---

## Rating Sync

Requires **BookLore account credentials** to be configured. See [Authentication](@/configuration/authentication.md).

### Enable rating sync

Toggle on to push ratings to BookLore at the end of a reading session.

### KOReader rating (scaled ×2)

KOReader uses a 1–5 star scale. BookLore uses a 1–10 scale. When this mode is selected the plugin multiplies the KOReader star rating by 2 before sending it.

| KOReader stars | BookLore rating |
|---------------|----------------|
| 1 ★☆☆☆☆ | 2 |
| 2 ★★☆☆☆ | 4 |
| 3 ★★★☆☆ | 6 |
| 4 ★★★★☆ | 8 |
| 5 ★★★★★ | 10 |

The rating is read from the book's `.sdr` sidecar file. If no rating has been set in KOReader, no rating is synced.

### Select at complete

A 1–10 rating dialog is shown when you close a book that has reached 99% or more progress. Your selection is immediately synced to BookLore. Closing the dialog without selecting skips the rating for that session.
> To prevent some bugs, the dialog is shown with a ~2s delay and does not open the keyboard.

### Hardcover rating (planned)

A future mode will sync ratings to a [Hardcover](https://hardcover.app) account. Not yet implemented.

---

## Annotations Sync

> **Warning:** Annotation sync currently only works for EPUB files. Highlights and notes from PDF, CBZ, and other formats are not synced.

Requires **BookLore account credentials** to be configured. See [Authentication](@/configuration/authentication.md).

### Enable highlights and notes sync

Toggle on to upload KOReader highlights and notes to BookLore at the end of qualifying reading sessions.

The plugin tracks uploaded annotations in a deduplication table so the same highlight is never uploaded twice.

### Notes destination

| Option | Behaviour | Notes |
|--------|-----------|-------|
| **In book** | Notes are stored as in-book annotations attached to the highlighted passage. Requires EPUB CFI calculation. Best for reading in BookLore's reader view.| Currently tested with EPUB files only. |
| **In BookLore** | Notes are stored as standalone book notes on the BookLore book page, using the chapter title as the note title. Works for all file formats. |

### Upload strategy

| Option | Behaviour |
|--------|-----------|
| **Upload on session end** | Annotations are checked and queued after every qualifying reading session. Only new annotations are processed. Whether they upload immediately or are cached depends on your **Sync Triggers** setting (see below). |
| **Upload on read complete** | Annotations are only queued when progress reaches 99% or more. |

> **Note:** When **Sync Triggers** is set to **Manual only (cache everything)**, annotations are always cached locally regardless of this setting. They will only upload when you manually trigger a sync via **Manage Sessions → Sync Pending Now** or the `SyncBooklorePending` dispatcher action.

### Highlight colours

KOReader named colours are mapped to BookLore hex values:

| KOReader colour | BookLore hex | Colour |
|----------------|-------------|--------|
| Yellow | `#FFC107` | <span style="display:inline-block;width:1.2em;height:1.2em;background:#FFC107;border:1px solid #0003;border-radius:3px;vertical-align:middle;"></span> |
| Green | `#4ADE80` | <span style="display:inline-block;width:1.2em;height:1.2em;background:#4ADE80;border:1px solid #0003;border-radius:3px;vertical-align:middle;"></span> |
| Cyan | `#38BDF8` | <span style="display:inline-block;width:1.2em;height:1.2em;background:#38BDF8;border:1px solid #0003;border-radius:3px;vertical-align:middle;"></span> |
| Pink | `#F472B6` | <span style="display:inline-block;width:1.2em;height:1.2em;background:#F472B6;border:1px solid #0003;border-radius:3px;vertical-align:middle;"></span> |
| Orange | `#FB923C` | <span style="display:inline-block;width:1.2em;height:1.2em;background:#FB923C;border:1px solid #0003;border-radius:3px;vertical-align:middle;"></span> |
| Red | `#FB923C` (nearest match) | <span style="display:inline-block;width:1.2em;height:1.2em;background:#FB923C;border:1px solid #0003;border-radius:3px;vertical-align:middle;"></span> |
| Purple | `#F472B6` (nearest match) | <span style="display:inline-block;width:1.2em;height:1.2em;background:#F472B6;border:1px solid #0003;border-radius:3px;vertical-align:middle;"></span> |
| Blue | `#38BDF8` (nearest match) | <span style="display:inline-block;width:1.2em;height:1.2em;background:#38BDF8;border:1px solid #0003;border-radius:3px;vertical-align:middle;"></span> |
| Gray / White | `#FFC107` (fallback) | <span style="display:inline-block;width:1.2em;height:1.2em;background:#FFC107;border:1px solid #0003;border-radius:3px;vertical-align:middle;"></span> |

---

## Sync Triggers

Controls when the plugin attempts to upload pending data.

| Option | Behaviour |
|--------|-----------|
| **Automatic (sync on suspend + WiFi)** | Syncs when the device suspends. Automatically enables WiFi and waits for a connection before uploading. |
| **Manual only (cache everything)** | Never syncs automatically. All sessions, ratings, and annotations are queued locally until you trigger a manual sync via **Manage Sessions → Sync Pending Now** or the `SyncBooklorePending` dispatcher action. |
| **Custom** | Enables individual toggles for auto-sync on suspend and connect WiFi on suspend independently. |

The **Custom** option exposes two additional toggles:

- **Auto-sync on suspend** — upload the current session and all pending items when the device suspends.
- **Connect WiFi on suspend** — automatically enable WiFi and wait up to 15 seconds for a connection when the device suspends.
