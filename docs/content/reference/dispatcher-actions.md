+++
title = "Dispatcher Actions"
description = "KOReader dispatcher actions provided by the plugin that can be assigned to buttons and gestures."
weight = 3
+++

# Dispatcher Actions

The plugin registers four actions with KOReader's dispatcher system. These can be assigned to hardware buttons, touch gestures, or KOReader profiles.

---

## Available actions

| Action name | Dispatcher key | Description |
|-------------|---------------|-------------|
| Toggle BookLore Sync | `ToggleBookloreSync` | Enables or disables the plugin. When disabled, no sessions are tracked. Toggle again to re-enable. |
| Sync Pending Sessions | `SyncBooklorePending` | Triggers an immediate upload of all pending sessions, ratings, and annotations in the local queue. |
| Toggle Manual Sync Only | `ToggleBookloreManualSyncOnly` | Switches between automatic sync (upload after each session) and manual sync (upload only when you trigger it). |
| Test Connection | `TestBookloreConnection` | Runs a connection test and shows the result as a notification. Equivalent to tapping **Test Connection** in the Settings menu. |

---

## Assigning an action

To assign an action to a gesture or button in KOReader:

1. Go to **Tools → More tools → Gestures** (or the equivalent for your device).
2. Select the gesture or button you want to configure.
3. Choose **Other actions** from the action list.
4. Find the BookLore Sync actions in the list (they appear under their action names).
5. Confirm.

The exact navigation path varies by device and KOReader version. Consult the KOReader documentation for your specific device if needed.

---

## Use cases

**Sync Pending Sessions** (`SyncBooklorePending`) is the most commonly assigned action. Assigning it to a swipe gesture lets you sync your reading data with a single gesture without navigating any menus.

**Toggle BookLore Sync** (`ToggleBookloreSync`) is useful if you read some books that are not in your BookLore library (e.g., work documents, temporary files) and you want to quickly disable tracking without going into the Settings menu.

**Toggle Manual Sync Only** (`ToggleBookloreManualSyncOnly`) is useful on metered or unreliable connections — you can switch to manual mode when on mobile data and back to auto mode when on Wi-Fi.
