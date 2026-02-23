+++
title = "Logs and Debugging"
description = "How to capture and read debug logs from the BookLore Sync plugin."
weight = 2
+++

# Logs and Debugging

---

## KOReader system log

KOReader writes all plugin log output to its main log file:

```
/tmp/koreader.log
```

To filter for BookLore Sync entries only:

```bash
grep BookloreSync /tmp/koreader.log
```

To follow the log in real time while reproducing an issue:

```bash
tail -f /tmp/koreader.log | grep BookloreSync
```

This log is not persistent — it is cleared each time KOReader starts.

---

## File logging (plugin log)

For more detailed diagnostics, the plugin can write its own log file with daily rotation.

### Enabling file logging

Go to:

**Tools → BookLore Sync → Settings → Preferences → Debug logging**

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
- API request URLs, response codes, and response bodies
- Error conditions with context
- Auto-update check activity and results
- Token acquisition and refresh events

### Disabling file logging

Toggle **Debug logging** off in the same menu. The current log file is closed cleanly.

---

## Secure logs

If you need to share a log file publicly (e.g., when reporting a bug), enable **Secure logs** before capturing:

**Tools → BookLore Sync → Settings → Preferences → Secure logs**

With this setting on, all URLs in log output are replaced with `[URL REDACTED]`, so your server address and path information are not exposed.

**Recommended capture procedure:**

{% mermaid() %}
flowchart TD
    A["1. Enable Debug logging"]
    B["2. Enable Secure logs"]
    C["3. Restart KOReader"]
    D["4. Reproduce the issue"]
    E["5. Copy log file from logs directory"]
    F["6. Attach to bug report"]

    A --> B --> C --> D --> E --> F
{% end %}

---

## Log levels

The plugin uses four log levels:

| Level | Prefix | When it appears |
|-------|--------|----------------|
| Debug | `[D]` | Detailed internal state, only with debug logging on |
| Info  | `[I]` | Normal operation milestones (session saved, sync started) |
| Warning | `[W]` | Recoverable issues (retry needed, book not found) |
| Error | `[E]` | Failures that need attention (auth failure, database error) |

---

## Useful grep patterns

```bash
# All errors
grep "BookloreSync.*\[E\]" /tmp/koreader.log

# Session events only
grep "BookloreSync.*session" /tmp/koreader.log

# API calls
grep "BookloreSync.*POST\|GET\|PUT" /tmp/koreader.log

# Sync attempts
grep "BookloreSync.*sync\|pending" /tmp/koreader.log

# Update checks
grep "BookloreSync.*update\|version" /tmp/koreader.log
```

---

## Reporting a bug

When opening a bug report on the [GitLab issue tracker](https://gitlab.worldteacher.dev/WorldTeacher/booklore-koreader-plugin/-/issues), please include:

1. **Plugin version** (from **About & Updates → Version Info**)
2. **KOReader version** (from KOReader's own About screen)
3. **Device and OS** (Kindle, Kobo, Android, Linux, etc.)
4. **Steps to reproduce** the issue
5. **A log file** captured with Debug logging and Secure logs enabled
6. **Database state** if relevant (see [Database](@/troubleshooting/database.md))
