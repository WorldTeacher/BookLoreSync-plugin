+++
title = "Preferences"
description = "Configure notifications and logging behaviour."
weight = 4
+++

# Preferences

The preferences settings are found at:

**Tools → BookLore Sync → Settings → Preferences**

---

## Silent Mode

**Default:** Off

When enabled, the plugin suppresses all popup notifications related to session caching, sync results, and upload confirmations. The plugin continues to work normally in the background — you just won't see any toast messages.

This is useful on devices where popups are disruptive, or if you prefer a completely silent reading experience.

Errors and warnings that require your attention (e.g., connection failures when you explicitly tap Test Connection) are still shown regardless of this setting.

---

## Debug Logging

**Default:** Off

When enabled, the plugin writes detailed log entries to a rotating daily log file:

```
{your_koreader_installation}/plugins/bookloresync.koplugin/logs/booklore-YYYY-MM-DD.log
```

The last **3 log files** are kept automatically. Older files are deleted during rotation.

Log entries cover:
- Session start and end events
- Database read/write operations
- API request details and responses
- Error conditions with stack information
- Auto-update check activity

Enable this setting when investigating an issue and share the log file when reporting a bug. See [Troubleshooting → Logs and Debugging](@/troubleshooting/logs-and-debugging.md) for guidance on reading the logs.

---

## Secure Logs

**Default:** Off

When enabled, all URLs are redacted from log output and replaced with `[URL REDACTED]`.

This is useful when you want to share a log file for debugging purposes but do not want to expose your server address or any path information.

Enable **Debug Logging** and **Secure Logs** together before capturing a log to share publicly.

---

## Dispatcher actions

The following actions can be assigned to KOReader hardware buttons, gestures, or profiles via the dispatcher:

| Action | Dispatcher key | What it does |
|--------|---------------|-------------|
| Toggle sync | `ToggleBookloreSync` | Enable or disable the plugin |
| Sync pending | `SyncBooklorePending` | Upload all pending sessions now |
| Toggle manual sync | `ToggleBookloreManualSyncOnly` | Switch between auto and manual sync mode |
| Test connection | `TestBookloreConnection` | Run a connection test |

To assign an action, go to **Tools → More tools → Gestures** (or the equivalent for your device's button customisation).
