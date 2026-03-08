+++
title = "Quick Start"
description = "Five steps to confirm your first reading session syncs to BookLore."
weight = 2
+++

# Quick Start

Requires the plugin to be [installed](@/getting-started/installation.md) and a server connection configured. Takes about five minutes.

---

## Step 1 - Open a book


Open any book in KOReader that exists in your BookLore library.

Behind the scenes, the plugin immediately:
- Calculates an MD5 fingerprint of the book file.
- Queries your BookLore server to resolve the book's ID using that fingerprint.
- Records your starting progress and the current timestamp.

> If the book is not found on the server, the session is still saved locally - the book ID will be resolved automatically the next time a connection is available.

---

## Step 2 - Read for at least 30 seconds

By default, sessions shorter than **30 seconds** are discarded. Read a few pages to ensure the session clears the validation threshold.

You can adjust this threshold later in **Settings → Sync Settings → Session Settings → Minimum Duration**.

---

## Step 3 - Close the book


Return to the KOReader home screen or library. The plugin triggers on book close and:

{% mermaid() %}
flowchart TD
    A["Book closed"]
    B["Calculate duration, progress delta, pages read"]
    C{"Passes validation?"}
    D["Discard session"]
    E["Save to local queue"]
    F["Notification shown"]
    G["Notification shown"]
    H["Upload to BookLore server"]

    A --> B --> C
    C -->|No| D --> G
    C -->|Yes| E --> F --> H
{% end %}

A notification is always shown on book close (unless Silent Mode is enabled). If the upload succeeds, the notification confirms the session was synced.

---

## Step 4 - Check BookLore

![Reading session showing up in BookLore](../bl-reading-session.png)

Open your BookLore web interface and navigate to the book you just read. The reading session should appear under the book's reading history, showing:

- Start and end timestamps
- Duration in seconds
- Progress percentage (start and end)
- Start and end page/location

---

## Step 5 - Check the pending queue (optional)


If the session did not appear, check whether it is still queued:

**Tools → BookLore Sync → Manage Sessions → View Details**

This shows the details of the database. You can manually trigger a sync from:

**Tools → BookLore Sync → Sync Pending Now**

If sessions remain stuck in the queue, see [Troubleshooting → Common Issues](@/troubleshooting/common-issues.md).

---

To set up ratings, highlights, and notes sync, continue to [Configuration → Sync Settings](@/configuration/session-tracking.md).
