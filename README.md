# Booklore Sync - KOReader Plugin

> **⚠️ Important Notice**
>
> This GitHub repository is a **public-facing mirror** of the main development repository.
>
> **If you encounter issues or bugs:**
> - You are welcome to create GitHub issues
> - **You MUST mention `@WorldTeacher` in your issue** - GitHub notifications do not reach me
> - I do not regularly monitor this repository
> - Without the mention, your issue may go unnoticed
>
> **Primary Support:** [Documentation Site](https://docs.worldteacher.dev/worldteacher/booklore-koreader-plugin/)

---

**Automatically track reading sessions in KOReader and sync them to your self-hosted Booklore server.**

> **Docker Image Requirement**
>
> This plugin requires the custom Booklore Docker image to function. The standard Booklore image does **not** include the necessary API endpoints used by this plugin.
>
> You must use: **`worldteacher99/booklore:koreader-plugin`**

## Features

- 📚 **Automatic Session Tracking** - Duration, progress, pages, and location tracking
- ⭐ **Rating Sync** - Sync book ratings to Booklore (KOReader stars or custom 1-10 rating)
- 📝 **Highlights & Notes** - Sync annotations to Booklore (in-book or web-UI notes)
- 🔄 **Offline Support** - Queue sessions when offline, auto-sync when connected
- 🗄️ **Smart Caching** - Local SQLite database with book hash fingerprinting
- 🔄 **Auto-Update** - Self-updating from within KOReader
- ⚙️ **Flexible Configuration** - Customize thresholds, sync triggers, and behavior

## Installation

1. **Copy plugin to KOReader:**
   ```bash
   cp -r bookloresync.koplugin {your_koreader_installation}/plugins/
   ```

2. **Restart KOReader** (complete restart, not sleep mode)

3. **Configure:**
   - Go to **Tools → BookLore Sync → Settings → Authentication**
   - Enter server URL, username, and password
   - Tap **Test Connection** to verify

## Quick Start

1. Open a book → Plugin calculates hash and fetches book ID
2. Read for 30+ seconds → Session tracked automatically  
3. Close the book → Session validated and synced
4. Check your Booklore server → Session appears!

**First time?** See the [Getting Started Guide](https://docs.worldteacher.dev/worldteacher/booklore-koreader-plugin/getting-started/quick-start/)

## Documentation

**📚 Full documentation:** https://docs.worldteacher.dev/worldteacher/booklore-koreader-plugin/

Key sections:
- [Installation](https://docs.worldteacher.dev/worldteacher/booklore-koreader-plugin/getting-started/installation/)
- [Authentication Setup](https://docs.worldteacher.dev/worldteacher/booklore-koreader-plugin/configuration/authentication/)
- [Session Tracking & Sync](https://docs.worldteacher.dev/worldteacher/booklore-koreader-plugin/configuration/session-tracking/)
- [Troubleshooting](https://docs.worldteacher.dev/worldteacher/booklore-koreader-plugin/troubleshooting/common-issues/)
- [API Reference](https://docs.worldteacher.dev/worldteacher/booklore-koreader-plugin/reference/api-endpoints/)

## Updates

The plugin can update itself from within KOReader:

1. Go to **Tools → BookLore Sync → About & Updates**
2. Tap **Check for Updates**
3. Tap **Install** if update available
4. Restart KOReader when prompted

Auto-check on startup is enabled by default (checks once per day).

## Troubleshooting

### Plugin not appearing in menu
- Verify files are in `plugins/bookloresync.koplugin/`
- Restart KOReader completely (not sleep mode)

### Connection test fails
```bash
# Verify server is running
curl http://your-server:6060/api/health
# Should return: {"status":"ok"}
```
Check server URL, username, and password.

### Sessions not syncing
- Check **Tools → BookLore Sync → Manage Sessions** for pending count
- Disable **Manual Sync Only** if you want auto-sync
- Try manual sync: **Manage Sessions → Sync Pending Now**

**More help:** [Troubleshooting Guide](https://docs.worldteacher.dev/worldteacher/booklore-koreader-plugin/troubleshooting/common-issues/)

## Development

### Structure
```
bookloresync.koplugin/
├── main.lua                    # Core plugin logic
├── booklore_settings.lua       # Settings UI
├── booklore_api_client.lua     # API communication
├── booklore_database.lua       # SQLite operations
├── booklore_metadata_extractor.lua  # Metadata & highlights
├── booklore_file_logger.lua    # Debug logging
├── booklore_updater.lua        # Auto-update system
├── plugin_version.lua          # Version info
└── _meta.lua                   # Plugin metadata
```

### Database Inspection
```bash
sqlite3 ~/.config/koreader/settings/booklore-sync.sqlite

# View cached books
SELECT * FROM book_cache;

# View pending sessions
SELECT * FROM pending_sessions;

# View pending annotations
SELECT * FROM pending_annotations;
```

## License

MIT License

## Links

- **Documentation:** https://docs.worldteacher.dev/worldteacher/booklore-koreader-plugin/
- **Booklore Server:** https://gitlab.worldteacher.dev/WorldTeacher/booklore
- **KOReader:** https://github.com/koreader/koreader
