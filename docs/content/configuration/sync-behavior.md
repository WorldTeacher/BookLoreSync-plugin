+++
title = "Sync Behavior"
description = "Choose sync mode and configure WiFi connection behavior for sync actions."
weight = 3
+++

# Sync Behavior

Use this page to configure **when** sync runs and **how** the plugin handles WiFi for network actions.

Found at: **Tools → BookLore Sync → Sync Behavior**

---

## What this guide does

This guide helps you:

1. Choose between automatic and manual queue-only sync mode.
2. Tune WiFi/network timing for slow or unstable connections.
3. Verify that sync behavior matches your device/network conditions.

---

## Prerequisites

- Plugin is enabled.
- Connection credentials are already configured in [Connection Setup](@/configuration/authentication.md).

---

## Steps

## 1. Choose a sync mode

Open **Tools → BookLore Sync → Sync Behavior** and choose one mode:

- **Automatic (sync on suspend when connected)**
  - Queues session/progress on suspend and attempts sync on suspend/resume **only when WiFi is already connected**.
  - Suspend/resume background sync does **not** enable WiFi; if disconnected, data stays queued for the next trigger.
  - Manual actions (for example **Sync Pending Now**) can still auto-enable/connect WiFi when invoked explicitly.

- **Manual only (cache everything)**
  - Always queues data locally.
  - No automatic upload; you run **Sync Pending Now** when ready.

## 2. Configure networking behavior

Open **Tools → BookLore Sync → Sync Behavior → Networking**.

- **WiFi connect timeout (seconds)**
  - Maximum wait after requesting WiFi connect.
  - Increase on slower devices/networks.

- **Run until connect**
  - Disables plugin-side timeout and waits until WiFi connects (or KOReader/network stack times out).
  - Useful when fixed timeout is too short.

- **Sync delay after connect**
  - Waits additional time after WiFi reports connected before sending sync requests.
  - Useful when DNS/routing is not ready immediately after connect.

---

## Verification / expected result

- In **Automatic** mode, you should see pending counts stay low under normal connectivity.
- In **Manual only** mode, pending items should accumulate until you run **Sync Pending Now**.
- If networking tuning is correct, manual sync should stop failing with early WiFi timeout/connectivity errors.

You can confirm queue state at:

**Tools → BookLore Sync → Sync & Cache → View Pending Sessions**

---

## Next steps

- For queue operations and manual upload tools, see [Sync & Cache](@/configuration/manage-sessions.md).
- For offline and retry behavior, see [Offline Support](@/features/offline-support.md).
- For exact setting keys and defaults, see [Settings Reference](@/reference/settings.md).
