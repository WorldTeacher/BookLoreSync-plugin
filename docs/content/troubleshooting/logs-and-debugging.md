+++
title = "Logs and Debugging"
description = "How to capture and read debug logs from the BookLore Sync plugin."
weight = 2
+++

# Logs and Debugging

> **Privacy note:** Logs are secured by default. API request URLs are redacted so server hostnames are not written to log output.

---

## KOReader system log

KOReader system logs are written to:

```text
{your_koreader_installation}/crash.log
```

For this plugin, `crash.log` is mostly useful for early startup events (for example file-logger initialization) and updater check activity.

Most BookLore Sync runtime logs are written to the plugin log file (see **File logging (plugin log)** below).

To filter BookLore-related lines in `crash.log`:

```bash
grep BookloreSync {your_koreader_installation}/crash.log
```

To follow `crash.log` in real time while reproducing an issue:

```bash
tail -f {your_koreader_installation}/crash.log | grep BookloreSync
```

---

## File logging (plugin log)

For more detailed diagnostics, the plugin can write its own log file with daily rotation.

### Enabling file logging

Go to:

**Tools → BookLore Sync → Appearance & Diagnostics → Log to file**

Toggle it on. The plugin will begin writing to:

```
{your_koreader_installation}/plugins/bookloresync.koplugin/logs/booklore-YYYY-MM-DD.log
```

One log file per day is created. The last **3 files** are kept; older files are deleted automatically during rotation.

### What is logged

When file logging is enabled, the log includes:

- Plugin startup and initialisation details
- Session start and end events with timestamps and progress values
- Book hash calculation results
- Database read/write operations
- Redacted API request URLs, response codes, and response bodies
- Error conditions with context
- Auto-update check activity and results
- Token acquisition and refresh events

### Disabling file logging

Toggle **Log to file** off in the same menu. The current log file is closed cleanly.

---

## Log levels

The plugin uses four log levels:

| Level | Prefix | When it appears |
|-------|--------|----------------|
| Debug | `DEBUG` | Detailed internal state, only with debug logging on |
| Info  | `INFO` | Normal operation milestones (session saved, sync started) |
| Warning | `WARN` | Recoverable issues (retry needed, book not found) |
| Error | `ERROR` | Failures that need attention (auth failure, database error) |

---

## Useful grep patterns

```bash
# All errors
grep "BookloreSync.*ERROR" {your_koreader_installation}/plugins/bookloresync.koplugin/logs/booklore-YYYY-MM-DD.log

# Session events only
grep "BookloreSync.*session" {your_koreader_installation}/plugins/bookloresync.koplugin/logs/booklore-YYYY-MM-DD.log

# API calls
grep -E "BookloreSync.*(POST|GET|PUT)" {your_koreader_installation}/plugins/bookloresync.koplugin/logs/booklore-YYYY-MM-DD.log

# Sync attempts
grep -E "BookloreSync.*(sync|pending)" {your_koreader_installation}/plugins/bookloresync.koplugin/logs/booklore-YYYY-MM-DD.log

# Update checks
grep -E "BookloreSync.*(update|version)" {your_koreader_installation}/crash.log
```

---

## Reporting a bug

When opening a bug report on the [GitHub issue tracker](https://github.com/WorldTeacher/BookLoreSync-plugin/issues), please include:

1. **Plugin version** (from **About & Updates → Version Info**)
2. **KOReader version** (from KOReader's own About screen)
3. **Device and OS** (Kindle, Kobo, Android, Linux, etc.)
4. **Steps to reproduce** the issue
5. **A log file** captured with Debug logging enabled
6. **Database state** if relevant (see [Database](@/troubleshooting/database.md))
