+++
title = "Gestures and Buttons"
description = "How to assign BookLore Sync actions to gestures, tap zones, and hardware buttons in KOReader."
weight = 6
+++

# Gestures and Buttons

The plugin does not define any gestures of its own. Instead, it registers four **dispatcher actions** with KOReader's built-in dispatcher system. You can then assign any of those actions to whatever input you prefer — a swipe, a tap zone, a hardware button, or a KOReader profile.

---

## Available actions

| Action title | What it does |
|---|---|
| Toggle BookLore Sync | Enables or disables the plugin. No sessions are tracked while it is disabled. |
| Sync Pending Sessions | Immediately uploads all queued sessions, ratings, and annotations. |
| Toggle Manual Sync Only | Switches between automatic sync (after every session) and manual sync (only when triggered). |
| Test Connection | Runs a connection test and shows the result as a notification. |

---

## How to assign an action

The exact menu path varies slightly by device type and KOReader version.

**From inside an open book:**

1. Tap the centre of the screen to open the top bar, then open the menu.
2. Go to **Tools → More tools → Gestures**.
3. Tap the gesture or button you want to configure (e.g. "Swipe down from top").
4. Tap **General**.
5. Scroll to find the BookLore Sync actions and select one.
6. Confirm.

**From the file browser:**

1. Open the menu (tap the top of the screen or use the hardware menu button).
2. Go to **Tools → More tools → Gestures**.
3. Follow steps 3–6 above.




---

## Notes

- Assigning a dispatcher action to a gesture requires going through KOReader's standard gesture UI. The plugin has no separate gesture configuration screen.
- If an action appears greyed out or missing, ensure the plugin is installed and has been loaded at least once (open a book, then close it).
- For full details on each action's behaviour, see [Dispatcher Actions](/reference/dispatcher-actions/).
