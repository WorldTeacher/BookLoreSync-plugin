+++
title = "Progress Sync"
description = "How KOReader reading position is synced to and from BookLore."
weight = 6
+++

# Progress Sync

Progress sync keeps your KOReader reading position aligned with BookLore. It can pull remote progress when you open or resume a book, and push local progress updates while you read.

> **Important:** Do not run this feature at the same time as KOReader's built-in progress sync for the same source. Both rely on the same underlying KOReader sync mechanisms and can interfere with each other. If you need KOReader's built-in sync, use it for a different source, or disable one of the two sync systems.

---

## What it syncs

Progress sync uses KOReader's sync endpoint and stores document-position snapshots keyed by file hash:

- **Pull:** `GET /api/koreader/syncs/progress/:book_hash`
- **Push:** `PUT /api/koreader/syncs/progress`

The synced payload includes:

- Document hash (`document`)
- Percentage (`percentage`)
- KOReader progress marker (`progress`)
- Timestamp (`timestamp`)
- Device info (`device`, `device_id`)

---

## Enable progress sync

Go to:

**Tools → BookLore Sync → What to Sync → Progress Sync**

Enable **Automatically sync progress**.

When disabled, no progress pull or push operations are performed.

---

## Pull behavior

Two toggles control when remote progress is checked:

| Setting | Default | Behavior |
|---------|---------|----------|
| Pull progress on book open | On | Checks remote progress when a book opens (only if Wi-Fi is already connected) |
| Pull progress on resume | On | Checks remote progress after wake/resume (only if Wi-Fi is already connected) |

If there is no remote progress for a book (`404` from the endpoint), this is treated as normal and reading continues with local state.

If remote progress exists but the fetched percentage is `0%`, the plugin skips applying it and does not show it as a sync target.

---

## Conflict strategy

When remote and local progress differ, the plugin applies one of three strategies:

- **Silently** - apply automatically.
- **Prompt** - ask for confirmation before applying.
- **Disable** - do not apply that direction.

You configure strategies separately for:

| Direction | Meaning |
|-----------|---------|
| Sync to a newer state | Remote progress is ahead of local |
| Sync to an older state | Remote progress is behind local |

Defaults:

- **Newer state:** Prompt
- **Older state:** Disable

---

## Push behavior

Progress is queued and uploaded in these situations:

| Trigger | Behavior |
|---------|----------|
| Book open | Queues a progress snapshot |
| Book close | Queues a progress snapshot |
| Every N pages | Queues periodic snapshots after the configured number of page turns |

Use **Periodically sync every # pages** to set the page-turn threshold:

- Minimum value is `1` page turn.
- To disable periodic updates, turn off **Periodic page-turn updates**.
- Open/close snapshots are still queued even when periodic updates are disabled.

To avoid excessive API traffic, page-triggered uploads are debounced (25 seconds minimum between pushes).

### Optional: normalize session locations

If your BookLore server page count differs from KOReader's internal page count, enable **Normalize session locations**.

When enabled, only session `startLocation` and `endLocation` are scaled to server page-count metadata before upload. Progress percentages are not modified.

---

## Set book to read on rating

When **Set book to read on rating** is enabled, submitting a rating also queues a forced `100%` progress state.

This is useful if your workflow treats rating as completion and you want BookLore to mark the book as read immediately.

---

## Queue and retries

Progress updates are stored in the local pending queue and are synced as part of **Sync Pending Now**.

- In queue summaries, progress items are shown as **`P`**.
- Failed progress uploads remain queued and retry on future sync runs.

Use **Sync & Cache → View Pending Sessions** to inspect pending and synced progress counts.

---

## Interaction with sync mode

If **Manual only (cache everything)** is active:

- Progress snapshots are still queued locally.
- No automatic upload is attempted.
- Upload occurs when you run **Sync Pending Now**.

In **Automatic** mode, pending progress is uploaded automatically by normal background sync triggers (session end, suspend, and resume), and can also be uploaded via manual sync actions.
