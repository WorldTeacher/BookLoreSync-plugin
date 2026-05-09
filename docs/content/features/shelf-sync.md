+++
title = "Shelf Sync"
description = "Downloading books from a BookLore shelf directly to your device, and keeping the shelf in sync when books are deleted locally."
weight = 5
+++

# Shelf Sync

Shelf sync is a two-way sync feature. On the **pull** side, the plugin downloads books from a BookLore shelf source (standard shelf or Magic Shelf) to your e-reader, letting you manage your reading queue from the BookLore web UI. On the **push** side (standard shelves only), when you delete a downloaded book from your device, the plugin removes that book from the configured shelf in BookLore.

---

## How it works

{% mermaid() %}
flowchart TD
    A["Shelf sync triggered"]
    B["Phase 1: Fetch shelf metadata (subprocess)"]
    C["GET /api/v1/shelves - find shelf by name (case-insensitive)"]
    D{"Shelf found?"}
    E["POST /api/v1/shelves - create shelf"]
    F["GET /api/v1/shelves/{id}/books - fetch book list"]
    G["Phase 2: Per-book download loop (subprocess per book)"]
    H{"File already on disk?"}
    I["Skip - update local cache if missing"]
    J["Download book to download_dir"]
    K["Phase 3: DB writes + optional deletions (UI thread)"]
    L{"delete_removed_shelf_books enabled?"}
    M["Delete local files no longer on shelf"]
    N["Sync complete - show summary"]

    A --> B --> C --> D
    D -->|Yes| F
    D -->|No| E --> F
    F --> G
    G --> H
    H -->|Yes| I
    H -->|No| J
    I --> K
    J --> K
    K --> L
    L -->|Yes| M --> N
    L -->|No| N
{% end %}

> **Note:** The diagram shows the standard-shelf fetch path. For Magic Shelves, phase 1 resolves the Magic Shelf source and fetches books through the Magic Shelf endpoints.

### Three-phase execution

Shelf sync runs in three phases. Each network operation happens in a subprocess so the UI thread is not blocked, but a modal status dialog is shown for the duration and the device is otherwise not usable:

| Phase | What happens |
|-------|-------------|
| **Phase 1** | A subprocess fetches the shelf from the server and retrieves the full book list. |
| **Phase 2** | For each book, a subprocess checks whether the file already exists and downloads it if not. The status dialog updates its title for each book. |
| **Phase 3** | Back on the UI thread, the local database is updated in a single transaction and (if enabled) any removed books are deleted from disk. |

A persistent **Cancel** button is shown throughout. Pressing it finishes the current book cleanly before stopping, so no partial downloads are left behind.

---

## Push side (standard shelves): local deletion → shelf removal

When you delete a book file from your device (via the KOReader file manager), the plugin unassigns that book from the configured **standard shelf source** automatically:

```
POST /api/v1/books/shelves
{ "bookIds": [<id>], "shelvesToUnassign": [<shelf_id>] }
```

If the device is offline at the time of deletion, the removal is queued and retried the next time a sync runs.

> **Note:** Magic Shelves are computed views. They are not directly assign/unassign targets, so this push-side unassign flow applies to standard shelves only.

---

## Prerequisites

- **BookLore credentials** configured (Bearer token authentication). See [Connection Setup](@/configuration/authentication.md).
- Sufficient local storage in the download directory.

> **Note:** For **standard shelf sources**, if no shelf with the configured name exists in BookLore, the plugin creates it automatically on first sync (as **public** by default). Magic Shelf sources are not auto-created.

---

## Setting up shelf sync

![KOReader Shelf sync settings](../shelf-sync.png)

1. Open **Tools → BookLore Sync → Shelf Sync**.
2. Open **Select Shelf**.
3. Choose **Select shelf (Standard + Magic)** to load all accessible standard and Magic shelves, then pick one.
4. Optionally edit the source name manually:
   - **Shelf source name** when using a standard shelf source.
   - **Magic Shelf name** when using a Magic shelf source.
5. Optionally change the **Download directory** (see [Download directory](#download-directory) below).
6. Optionally enable **Auto-sync shelf on wake** to download books automatically 15 seconds after the device wakes from suspend, once Wi-Fi is connected.
7. Optionally enable **Delete removed shelf books** to remove local files when a book is no longer on the shelf.
8. Optionally enable **Use original server filename** (default: **on**) to save downloaded books using the server's own filename instead of deriving it from the book title.
9. Optionally enable **Also delete sidecar (.sdr) on removal** to also remove the KOReader reading-progress folder when a book is deleted. This option is only active when **Delete removed shelf books** is also enabled.

### Shelf source resolution behavior

Shelf source resolution depends on source type:

| Source type | Resolution order |
|------------|------------------|
| **Standard** | 1) Explicit shelf ID (if set), 2) shelf name (case-insensitive), 3) create standard shelf by name if not found |
| **Magic** | 1) Explicit Magic Shelf ID (if set), 2) Magic Shelf name (case-insensitive) |

The selector stores both source type and source ID. If you manually change a source name, the stored source ID is cleared and resolved again on the next sync.

---

## Download directory

Books are saved into a `Books` subdirectory, resolved in this order:

| Priority | Source | Example path |
|----------|--------|-------------|
| 1 | KOReader home dir setting | `<home_dir>/Books` |
| 2 | Device default home dir | `<device_home>/Books` |
| 3 | Known platform path - Kobo | `/mnt/onboard/Books` |
| 4 | Known platform path - Android | `/sdcard/Books` |
| 5 | Fallback | `/Books` |

You can override this path via **Tools → BookLore Sync → Shelf Sync → Download dir**.

A **Reset** button in that dialog restores the automatically detected path.

### Storage guard (minimum free space)

Before each download, the plugin checks available disk space and enforces a minimum-free-space threshold.

- **Default threshold:** `500 MB`
- **Menu path:** **Tools → BookLore Sync → Shelf Sync → Minimum free space**

If available space drops below the threshold, shelf sync stops before starting the next download.

### Filenames

Every downloaded filename has the BookLore **book ID appended to the stem** (e.g., `My Book_42.epub`). This tag is embedded regardless of the filename mode chosen below, and it is what the plugin uses to identify previously-downloaded files during subsequent syncs - so renaming or moving a file without preserving the `_<id>` suffix will cause it to be downloaded again.

The plugin supports two filename modes, selectable via **Tools → BookLore Sync → Shelf Sync → Use original server filename**:

| Mode | How the filename is formed | Default? |
|------|---------------------------|----------|
| **Original server filename** (enabled) | Takes the filename stored on the BookLore server (the primary file's original name), strips its extension, appends `_<id>`, and re-adds the extension. | ✓ Yes |
| **Title-derived** (disabled) | Sanitises the book title from BookLore metadata, appends `_<id>`, and adds the extension. | No |

In both modes:

- Filesystem-unsafe characters (`/ \ : * ? " < > |`) are stripped from the stem.
- Consecutive whitespace is collapsed.
- The stem is truncated so the total filename (including the `_<id>` suffix and extension) stays under 150 characters.
- If neither the original filename nor the title produces a usable stem, the filename falls back to `BookID_<id>.<extension>`.

---

## Triggering shelf sync

Shelf sync can be started in three ways:

| Method | How |
|--------|-----|
| **Manual** | **Tools → BookLore Sync → Shelf Sync → Sync from Booklore Shelf** |
| **Auto on wake** | Fires 15 seconds after device wake, once Wi-Fi is connected. Enable via **Tools → BookLore Sync → Shelf Sync → Auto-sync shelf on wake**. |
| **Dispatcher action** | Assign `booklore_sync_shelf` to a gesture or hardware button in **Settings → Gestures**. |

If WiFi is disconnected when manual or dispatcher-triggered shelf sync starts, the plugin attempts to enable/connect WiFi automatically first.

When shelf sync starts, a status dialog is shown with a **Cancel** button. The dialog title updates as each book is processed. The device UI is not usable during the sync - tapping outside the dialog does nothing.

### Full vs delta sync

Shelf sync uses cached shelf state to run incrementally (delta-based) after the first successful run.

- **Normal sync** compares the current shelf with cached state and processes only changes.
- **Force full re-sync** clears cached shelf state first, then runs a complete sync pass.

Use **Force full re-sync** after manual filesystem changes (for example, if downloaded files were deleted outside the plugin and you want them re-downloaded).

---

## Cancelling a running sync

A **Cancel** button is shown in the status dialog during sync. Tapping it:

1. Sets a cancellation flag.
2. Waits for the **current book** to finish downloading cleanly.
3. Flushes all completed book cache entries to the database.
4. Shows a summary of how many books were processed before cancellation.

Cancelling does **not** leave partial or corrupt book files on disk.

---

## Removing books from the shelf

If **Delete removed shelf books** is enabled, any book that was previously downloaded via shelf sync but is no longer present on the shelf will be deleted from the local download directory when shelf sync runs.

> **Warning:** Enabling this setting will permanently delete local book files that are no longer on the shelf. Make sure your BookLore shelf represents your intended reading library before enabling it.

If this setting is disabled (the default), books already on the device are never deleted automatically.

---

## Standard shelf creation

If no shelf with the configured name exists in BookLore, the plugin creates it automatically on the first sync:

```
POST /api/v1/shelves
Content-Type: application/json

{ "name": "KOReader", "icon": "pi pi-shield", "iconType": "PRIME_NG", "publicShelf": true }
```

The shelf name defaults to `KOReader` and can be changed in settings. Changing the shelf name invalidates the cached shelf ID so the new name is resolved on the next sync.

> **Note:** Shelf creation only happens once. Changing visibility (public/private) of an existing shelf must be done in the BookLore web UI.

---

## SDR sidecar detection

When a book is downloaded via shelf sync, the plugin records its [SDR sidecar path](@/features/session-tracking.md#sdr-detection) in the local database as soon as the file is first opened. This is the same database-backed detection used by the session tracker.

When **Delete removed shelf books** is enabled and a book is deleted during sync, the plugin also deletes all matching `.sdr` sidecar directories (using the stored path plus a disk scan for all three KOReader sidecar locations: beside the file, in the `metadata` folder, and the hash-named folder), provided **Also delete sidecar (.sdr) on removal** is also enabled.

---

## Credits

Shelf sync was originally created in a fork made by [cporcellijr](https://github.com/cporcellijr) and has since been significantly reworked with a three-phase subprocess architecture, ID-tagged filenames with original-filename and title-derived modes, improved SDR sidecar detection and cleanup, a two-way deletion flow, and a cancellable progress dialog.
