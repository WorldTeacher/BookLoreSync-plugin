+++
title = "Installation"
description = "How to install the Booklore Sync plugin on your KOReader device."
weight = 1
+++

# Installation

## Requirements

Before you start, make sure you have:

- **KOReader 2023.10 or later** installed on your e-reader or device.
- A running **Booklore server** reachable from your device (local network or HTTPS).
- Your Booklore **username and password**.
- Enough free storage on your device for the plugin and its SQLite database (a few MB at most).

The plugin has no other dependencies — everything it needs (SQLite, JSON, HTTP) is already bundled with KOReader.

> **Important: Custom Docker Image Required**
>
> This plugin requires the custom Booklore Docker image `worldteacher99/booklore:koreader-plugin`. The standard Booklore image does **not** include the API endpoints needed by this plugin. Make sure your Booklore server is running this image before proceeding.

---

## Step 1 — Download the plugin

Download the latest release ZIP from the [GitLab releases page](https://gitlab.worldteacher.dev/WorldTeacher/booklore-koreader-plugin/-/releases).

The ZIP contains a single folder named `bookloresync.koplugin`.

Alternatively, the plugin can update itself once installed — see [Auto-Update](@/features/auto-update.md).

---

## Step 2 — Copy the plugin to KOReader

Copy the `bookloresync.koplugin` folder into KOReader's plugin directory. The exact path depends on your device and platform.

<details>
<summary><strong>Linux / macOS desktop</strong></summary>

KOReader stores its data in your home directory:

```
{your_koreader_installation}/plugins/
```

Copy with:

```bash
cp -r bookloresync.koplugin {your_koreader_installation}/plugins/
```

</details>

<details>
<summary><strong>Android</strong></summary>

KOReader on Android stores its data on internal storage. Connect via USB (or use a file manager app) and place the folder at:

```
/sdcard/koreader/plugins/
```

Or, if KOReader is installed in a non-standard location, look for a `koreader/` folder on your internal storage and find the `plugins/` subdirectory inside it.

You can also use KOReader's built-in SSH server (if enabled) to transfer files wirelessly.

</details>

<details>
<summary><strong>Kobo</strong></summary>

Connect your Kobo via USB. KOReader's data lives on the device's internal storage:

```
.adds/koreader/plugins/
```

The `.adds/` folder may be hidden on Windows — enable "Show hidden files" in Explorer, or use a file manager that shows hidden directories.

Alternatively, if you have KOReader's SSH server enabled (available on some Kobo models via the developer menu), you can transfer wirelessly.

</details>

<details>
<summary><strong>Kindle</strong></summary>

Connect your Kindle via USB. KOReader's data is stored at:

```
/mnt/us/koreader/plugins/
```

When mounted over USB on a computer, this typically appears as the root of the Kindle drive, so the path you see in your file manager will look like:

```
Kindle:/koreader/plugins/
```

Copy the `bookloresync.koplugin` folder there.

</details>

After copying, the directory structure inside `plugins/` should look like this regardless of platform:

```
plugins/
└── bookloresync.koplugin/
    ├── main.lua
    ├── _meta.lua
    ├── plugin_version.lua
    ├── booklore_api_client.lua
    ├── booklore_database.lua
    ├── booklore_settings.lua
    ├── booklore_updater.lua
    ├── booklore_metadata_extractor.lua
    └── booklore_file_logger.lua
```

---

## Step 3 — Restart KOReader

A restart is required for KOReader to load the newly installed plugin.

Go to **Menu → Exit → Restart**.

---

## Step 4 — Verify the plugin loaded

After restarting, check that the plugin entry appears in the **Tools** menu. This menu is accessible from both the file browser and from within an open book:

**Tools → Booklore Sync**



![KOReader Tools menu showing the BookLore Sync entry](../koreader-menu-main.png)


If the **Booklore Sync** entry appears, the plugin loaded successfully.

If it does not appear, check that:
- The folder is named exactly `bookloresync.koplugin` (no extra characters).
- The folder is in the correct `plugins/` directory for your platform (see Step 2), not inside a subdirectory.
- KOReader was fully restarted, not just resumed from sleep.
- There are no Lua errors in the KOReader log: `grep BookloreSync /tmp/koreader.log` (Linux/Android) or check KOReader's built-in log viewer.

---

## Step 5 — Configure the server connection

![BookLore Sync authentication submenu in KOReader](../koreader-settings-auth.png)

Go to **Tools → Booklore Sync → Settings → Authentication** and enter:

1. **Server URL** — the address of your Booklore server, e.g. `http://192.168.1.100:6060` or `https://booklore.example.com`.
> Enter only the base URL — do not append `/api` or any path. The plugin handles all API routing internally.
2. **KOReader credentials** — tap **Configure KOReader Account** and enter your username and password. These are the credentials you set in the BookLore Settings -> Devices -> KOReader.
3. **Booklore account** — tap **Configure Booklore Account** and enter the same (or a separate) username and password. This second set of credentials is used for extended features like rating and annotation sync. This is the user you use to log in in the webUI.
4. Tap **Test Connection** to verify everything is working.

A confirmation message will appear if the connection succeeds.

![BookLore Sync Login success notification](../koreader-auth-success.png)
---

## Next steps

Once the plugin is installed and connected, follow the [Quick Start](@/getting-started/quick-start.md) guide to confirm your first session syncs correctly.
