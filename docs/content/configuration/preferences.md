+++
title = "Preferences"
description = "Configure notifications, logging, and WiFi behaviour."
weight = 4
+++

# Preferences

The preferences settings are found at:

**Tools → BookLore Sync → Preferences**

---

## Silent Mode

**Default:** Off

When enabled, the plugin suppresses all popup notifications related to session caching, sync results, and upload confirmations. The plugin continues to work normally in the background - you just won't see any toast messages.

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

## Ask Before Enabling WiFi

**Default:** Off

When enabled, the plugin prompts for confirmation before turning on WiFi for any sync operation. The prompt shows the action that requires WiFi (for example, "sync sessions" or "upload annotation"). Two options are presented:

- **Enable** — turns on WiFi and proceeds with the action.
- **Skip** — leaves WiFi off; the action is deferred and data remains in the pending queue for the next sync opportunity.

When disabled, the plugin enables WiFi automatically without prompting whenever a sync requires it.

---

## Export Settings

Writes the current plugin configuration to a JSON file at:

```
{koreader_settings_dir}/booklore_settings_export.json
```

Sensitive fields are excluded from the export: server URL, username, and password are never written to the file. All other settings — sync mode, thresholds, feature toggles, and logging options — are included.

A confirmation toast shows the full path when the export succeeds.

---

## Dispatcher actions

See [Reference → Dispatcher Actions](@/reference/dispatcher-actions.md) for the full list of actions that can be assigned to KOReader hardware buttons, gestures, or profiles.
