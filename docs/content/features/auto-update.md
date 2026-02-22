+++
title = "Auto-Update"
description = "How the plugin keeps itself up to date from within KOReader."
weight = 5
+++

# Auto-Update

The plugin can check for and install its own updates without leaving KOReader. Updates are downloaded from the official GitHub releases page.

---

## Accessing the update menu

Go to:

**Tools → BookLore Sync → About & Updates**



---

## Auto-check on startup

**Default:** Enabled

When auto-check is on, the plugin queries the GitHub API for the latest release once per day during KOReader startup (with a 5-second delay to avoid slowing down the launch).

If a newer version is available, a notification badge (`⚠`) appears on the **About & Updates** menu item.

To disable auto-check, toggle off **Auto-check for updates** in:

**Tools → BookLore Sync → About & Updates → Toggle auto-check**

---

## Manual update check

Tap **Check for Updates** in the About & Updates menu to trigger an immediate check regardless of the daily schedule.

The check queries:

```
GET https://api.github.com/repos/WorldTeacher/BookloreSync-plugin/releases/latest
```

Release information is cached locally for **1 hour** to respect GitHub API rate limits. Tap **Clear update cache** to force a fresh check before the hour is up.

If an update is available, a dialog shows:
- The new version number
- The release notes (changelog)
- The download size
- An **Install** button

---

## Installing an update

Tap **Install** in the update dialog to begin the installation process:

{% mermaid() %}
flowchart TD
    A["Tap Install"]
    B["Network check"]
    C["Download release ZIP"]
    D["Validate ZIP structure"]
    E["Backup current plugin"]
    F["Install new version"]
    G["Restart prompt"]
    ERR["Failure - auto-restore from backup"]

    A --> B --> C --> D --> E --> F --> G
    B -->|No connection| ERR
    D -->|Invalid ZIP| ERR
    F -->|Install error| ERR
{% end %}

The entire process happens on-device. No computer is needed.

---

## Backups and rollback

Before every update, the plugin creates an automatic backup of the current installation:

```
{your_koreader_installation}/booklore-backups/bookloresync-{version}-{hash}-{datetime}
```

Up to **3 backups** are retained. Older backups are deleted automatically.

If an installation fails for any reason, the plugin automatically restores from the most recent backup. You can also trigger a manual rollback from the update menu if needed.

---

## Version numbering

The plugin follows [Semantic Versioning](https://semver.org/):

```
MAJOR.MINOR.PATCH
```

| Component | Changes when |
|-----------|-------------|
| MAJOR | Breaking changes that require database migration or significant reconfiguration |
| MINOR | New features added in a backwards-compatible way |
| PATCH | Bug fixes |

Development builds (built from uncommitted changes) show a version like `0.0.0-dev+<commit>` and are always treated as outdated — installing a release will always replace a dev build.

---

## Current version

The current version, build date, and git commit are shown at:

**Tools → BookLore Sync → About & Updates → Version Info**

You can also see this information in the [Reference → Changelog](/reference/changelog/).
