+++
title = "Appearance & Diagnostics"
description = "Configure notifications, logging, export, and plugin naming."
weight = 4
+++

# Appearance & Diagnostics

These settings are found at:

**Tools → BookLore Sync → Appearance & Diagnostics**

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

## Plugin Name (Branding)

**Default:** `Booklore`

Lets you rename how the plugin is labeled in KOReader UI text. The setting is available in:

**Tools -> BookLore Sync -> Appearance & Diagnostics -> Plugin Name**

Behavior details:

- The value is trimmed and normalized before saving.
- If the name ends with `Sync`, that suffix is removed automatically to avoid duplicate naming.
- The plugin also computes a shortcut-style label as `<DisplayName>Sync` for places that use the compact form.
- If branding cannot be applied globally, the value is still saved locally and you'll see an error message with details.

Examples:

- `MyLibrary` -> display name `MyLibrary`, shortcut name `MyLibrarySync`
- `MyLibrarySync` -> display name `MyLibrary`, shortcut name `MyLibrarySync`

Branding affects plugin-provided labels and messages; it does not rename unrelated KOReader UI text from other plugins.

---

## Export Settings

Writes the current plugin configuration to a JSON file at:

```
{koreader_settings_dir}/booklore_settings_export.json
```

Sensitive fields are excluded from the export: server URL, username, and password are never written to the file. All other settings - sync mode, thresholds, feature toggles, and logging options - are included.

A confirmation toast shows the full path when the export succeeds.

---

## Dispatcher actions

See [Reference → Dispatcher Actions](@/reference/dispatcher-actions.md) for the full list of actions that can be assigned to KOReader hardware buttons, gestures, or profiles.
