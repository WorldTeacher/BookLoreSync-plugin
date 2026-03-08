+++
title = "Shelf Sync"
description = "Downloading books from a BookLore shelf directly to your device."
weight = 5
+++

# Shelf Sync

The shelf sync feature pulls books from a named shelf in your BookLore library and downloads them directly to your e-reader. This lets you manage reading queues in BookLore's web UI and have new titles automatically appear on your device.

---

## How it works

{% mermaid() %}
flowchart TD
    A["Shelf sync triggered"]
    B["Look up shelf by name on server"]
    C["GET /api/v1/shelves - create if missing"]
    D["Fetch book list from shelf"]
    E["Compare with already-downloaded files"]
    F{"New books?"}
    G["Download each book to download_dir"]
    H["No action needed"]
    I{"Books removed from shelf?"}
    J["Delete local file (if delete_removed_shelf_books enabled)"]

    A --> B --> C --> D --> E --> F
    F -->|Yes| G
    F -->|No| H
    G --> I
    I -->|Yes| J
    I -->|No| H
{% end %}

---

## Prerequisites

- **BookLore account credentials** configured (Bearer token authentication). See [Authentication](@/configuration/authentication.md).
- A shelf exists in your BookLore library (the plugin will create one named `KOReader` automatically if it does not exist).
- Sufficient local storage in the download directory.

> **Note:** The BookLore shelf must be set to **public** for the plugin to read its contents.

---

## Setting up shelf sync

![KOReader SHelf sync](../shelf-sync.png)

1. Go to **Tools → BookLore Sync → Shelf Sync**.
2. Set the **Shelf name** (default: `KOReader`). The plugin will look for a shelf with exactly this name.
3. Optionally change the **Download directory** (see below).
4. Optionally enable **Auto-sync shelf on resume** to download books automatically when the device wakes.
5. Optionally enable **Delete removed shelf books** to remove local files when a book is removed from the shelf.

---

## Download directory

Books are saved to the download directory. The default path is chosen automatically based on your device:

| Device | Default path |
|--------|-------------|
| Kobo | `/mnt/onboard/Books` |
| Android | `/sdcard/Books` |
| Other | Plugin data directory |

You can override this path in **Settings → Shelf Sync → Download directory**.

---

## Triggering shelf sync

Shelf sync can be started in three ways:

| Method | How |
|--------|-----|
| **Manual** | **Tools → BookLore Sync → Sync Shelf** |
| **Auto on resume** | Enabled via **Settings → Shelf Sync → Auto-sync shelf on resume** |
| **Dispatcher action** | Assign `SyncBookloreShelf` to a gesture or button |

Shelf sync runs as a background task and will not block the UI while downloading.

---

## Removing books from the shelf

If **Delete removed shelf books** is enabled, any book that was previously downloaded as part of shelf sync but is no longer present on the shelf will be deleted from the local download directory when shelf sync runs.

> **Warning:** Enabling this setting will permanently delete local book files that have been removed from the shelf. Make sure your BookLore shelf represents your intended reading library before enabling it.

If this setting is disabled (the default), books already on the device are never deleted by shelf sync.

---

## Shelf creation

If no shelf with the configured name exists in BookLore, the plugin automatically creates it on first sync:

```
POST /api/v1/shelves
```

The shelf name defaults to `KOReader` and can be changed in settings before the first sync.

---

## Credits

Shelf sync is based on the implementation from [cporcellijr/BookLoreSync-plugin](https://github.com/cporcellijr/BookLoreSync-plugin), merged in with small adjustments.
