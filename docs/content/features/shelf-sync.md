+++
title = "Shelf Sync"
description = "Downloading books from a BookLore shelf directly to your device, and keeping the shelf in sync when books are deleted locally."
weight = 5
+++

# Shelf Sync

Shelf sync is a two-way sync feature. On the **pull** side, the plugin downloads books from a named BookLore shelf to your e-reader, letting you manage your reading queue from the BookLore web UI. On the **push** side, when you delete a downloaded book from your device, the plugin automatically removes that book from the shelf in BookLore.

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

### Three-phase execution

Shelf sync runs in three phases. Each network operation happens in a subprocess so the UI thread is not blocked, but a modal status dialog is shown for the duration and the device is otherwise not usable:

| Phase | What happens |
|-------|-------------|
| **Phase 1** | A subprocess fetches the shelf from the server and retrieves the full book list. |
| **Phase 2** | For each book, a subprocess checks whether the file already exists and downloads it if not. The status dialog updates its title for each book. |
| **Phase 3** | Back on the UI thread, the local database is updated in a single transaction and (if enabled) any removed books are deleted from disk. |

A persistent **Cancel** button is shown throughout. Pressing it finishes the current book cleanly before stopping, so no partial downloads are left behind.

---

## Push side: local deletion → shelf removal

When you delete a book file from your device (via the KOReader file manager), the plugin unassigns that book from the BookLore shelf automatically:

```
POST /api/v1/books/shelves
{ "bookIds": [<id>], "shelvesToUnassign": [<shelf_id>] }
```

If the device is offline at the time of deletion, the removal is queued and retried the next time a sync runs.

---

## Prerequisites

- **BookLore credentials** configured (Bearer token authentication). See [Authentication](@/configuration/authentication.md).
- Sufficient local storage in the download directory.

> **Note:** If no shelf with the configured name exists in BookLore, the plugin creates it automatically on the first sync. By default the shelf is created as **public**.

---

## Setting up shelf sync

![KOReader Shelf sync settings](../shelf-sync.png)

1. Open **Tools → BookLore Sync → Shelf Sync**.
2. Review or change the **Shelf name** (default: `KOReader`). The plugin matches shelves case-insensitively.
3. Optionally change the **Download directory** (see [Download directory](#download-directory) below).
4. Optionally enable **Auto-sync shelf on wake** to download books automatically 15 seconds after the device wakes from suspend, once Wi-Fi is connected.
5. Optionally enable **Delete removed shelf books** to remove local files when a book is no longer on the shelf.

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

### Filenames

Downloaded books are saved with a filename derived from the book's **title** in BookLore:

- Filesystem-unsafe characters (`/ \ : * ? " < > |`) are stripped.
- Consecutive whitespace is collapsed.
- The title stem is truncated to 150 characters (including the file extension) if necessary.
- If no usable title is available, the filename falls back to `BookID_<id>.<extension>`.

---

## Triggering shelf sync

Shelf sync can be started in three ways:

| Method | How |
|--------|-----|
| **Manual** | **Tools → BookLore Sync → Shelf Sync → Sync from Booklore Shelf** |
| **Auto on wake** | Fires 15 seconds after device wake, once Wi-Fi is connected. Enable via **Tools → BookLore Sync → Shelf Sync → Auto-sync shelf on wake**. |
| **Dispatcher action** | Assign `booklore_sync_shelf` to a gesture or hardware button in **Settings → Gestures**. |

When shelf sync starts, a status dialog is shown with a **Cancel** button. The dialog title updates as each book is processed. The device UI is not usable during the sync - tapping outside the dialog does nothing.

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

## Shelf creation

If no shelf with the configured name exists in BookLore, the plugin creates it automatically on the first sync:

```
POST /api/v1/shelves
Content-Type: application/json

{ "name": "KOReader", "icon": "pi pi-shield", "iconType": "PRIME_NG", "publicShelf": true }
```

The shelf name defaults to `KOReader` and can be changed in settings. Changing the shelf name invalidates the cached shelf ID so the new name is resolved on the next sync.

> **Note:** Shelf creation only happens once. Changing visibility (public/private) of an existing shelf must be done in the BookLore web UI.

---

## Credits

Shelf sync was originally contributed by [cporcellijr/BookLoreSync-plugin](https://github.com/cporcellijr/BookLoreSync-plugin) and has since been significantly reworked with a three-phase subprocess architecture, title-based filenames, a two-way deletion flow, and a cancellable progress dialog.
