+++
title = "Annotations"
description = "Syncing highlights and notes from KOReader to BookLore."
weight = 4
+++

# Annotations

The annotations sync feature uploads highlights and notes you make in KOReader to your BookLore library. Annotations are deduplicated — the same highlight is never uploaded twice.

---

## Prerequisites

Annotation sync requires:

- The **BookLore account credentials** configured for Bearer token authentication. See [Authentication](@/configuration/authentication.md).
- **Sync highlights and notes** toggled on in **Settings → Annotations**.

---

## What gets synced

| KOReader element | Synced to BookLore |
|-----------------|-------------------|
| Highlighted text (any colour) | Annotation with the highlighted text and colour |
| Note attached to a highlight | Annotation comment, or standalone book note (depending on destination) |
| Chapter/section context | Used as the note title when destination is "In BookLore" |

Bookmarks (without text selection) are not currently synced.

---

## Notes destination

### In book

Notes are stored as in-book annotations directly attached to the highlighted passage. This makes them visible when reading the book in BookLore's built-in reader.

This mode requires the plugin to convert KOReader's internal position format (`xpointer`) to a standard **EPUB CFI** (Canonical Fragment Identifier) string, which BookLore uses to anchor the annotation to the correct location in the document.

API endpoint used:
```
POST /api/v1/annotations
```

> EPUB CFI generation is only supported for EPUB files. For PDF and comic formats, use "In BookLore" mode.

### In BookLore

Notes are stored as standalone book notes visible on the BookLore book page (the web UI book detail view), not inside the reader. The chapter title is used as the note title.

API endpoints used:
```
POST /api/v2/book-notes   (in-book notes with position)
POST /api/v1/book-notes   (standalone BookLore notes)
```

This mode works for all file formats.

---

## EPUB CFI generation

For EPUB files, the plugin generates a Canonical Fragment Identifier (CFI) for each highlight, allowing BookLore to display the annotation at the precise location in the document.

{% mermaid() %}
flowchart TD
    A["EPUB file opened"]
    B["Read OPF spine and build spine item map"]
    C["Parse KOReader xpointer position"]
    D["Combine spine index, element path, char offset"]
    E["Output EPUB CFI string"]

    A --> B --> C --> D --> E
{% end %}

This happens entirely on-device — no server-side processing required.

---

## Highlight colours

KOReader supports named highlight colours. The plugin maps these to the nearest hex colour used by BookLore's annotation system:

| KOReader colour | BookLore hex | Swatch |
|----------------|-------------|--------|
| Yellow | `#FFC107` | <span style="display:inline-block;width:1.2em;height:1.2em;background:#FFC107;border:1px solid #0003;border-radius:3px;vertical-align:middle;"></span> |
| Green | `#4ADE80` | <span style="display:inline-block;width:1.2em;height:1.2em;background:#4ADE80;border:1px solid #0003;border-radius:3px;vertical-align:middle;"></span> |
| Cyan | `#38BDF8` | <span style="display:inline-block;width:1.2em;height:1.2em;background:#38BDF8;border:1px solid #0003;border-radius:3px;vertical-align:middle;"></span> |
| Pink | `#F472B6` | <span style="display:inline-block;width:1.2em;height:1.2em;background:#F472B6;border:1px solid #0003;border-radius:3px;vertical-align:middle;"></span> |
| Orange | `#FB923C` | <span style="display:inline-block;width:1.2em;height:1.2em;background:#FB923C;border:1px solid #0003;border-radius:3px;vertical-align:middle;"></span> |
| Red | `#FB923C` (nearest) | <span style="display:inline-block;width:1.2em;height:1.2em;background:#FB923C;border:1px solid #0003;border-radius:3px;vertical-align:middle;"></span> |
| Purple | `#F472B6` (nearest) | <span style="display:inline-block;width:1.2em;height:1.2em;background:#F472B6;border:1px solid #0003;border-radius:3px;vertical-align:middle;"></span> |
| Blue | `#38BDF8` (nearest) | <span style="display:inline-block;width:1.2em;height:1.2em;background:#38BDF8;border:1px solid #0003;border-radius:3px;vertical-align:middle;"></span> |
| Gray / White | `#FFC107` (fallback) | <span style="display:inline-block;width:1.2em;height:1.2em;background:#FFC107;border:1px solid #0003;border-radius:3px;vertical-align:middle;"></span> |

---

## Upload strategy

### Upload on session end

Annotations are checked and uploaded after every valid reading session. Only annotations not yet recorded in the `synced_annotations` deduplication table are sent.

This is the recommended strategy for most users — your annotations are always up to date on the server without any manual action.

### Upload on read complete

Annotations are only uploaded when reading progress reaches **99% or more**. This sends all annotations for the book in one batch when you finish it, rather than incrementally throughout reading.

Use this if you prefer not to sync partial highlights (e.g., you frequently highlight and then delete).

---

## Deduplication

The `synced_annotations` table records every annotation that has been successfully uploaded:
- A unique identifier derived from the book ID, annotation position, and text content.
- The timestamp of the upload.

On each sync, only annotations not found in this table are uploaded. This prevents duplicate annotations from appearing in BookLore if you sync the same book on multiple occasions.

---

## Pending annotations

If an annotation upload fails, it is stored in the `pending_annotations` table and retried on the next sync trigger. You can see the count of pending annotations in:

**Tools → BookLore Sync → Settings → Manage Sessions → View Details**
