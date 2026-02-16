# Booklore Sync - KOReader Plugin

**Version:** 1.0.0-beta  
**Status:** Ready for Testing  
**Last Updated:** February 11, 2026

Automatically track your reading sessions in KOReader and sync them to your Booklore server.

---

## Features

### 📚 Automatic Session Tracking
- **Smart Detection** - Automatically starts tracking when you open a book
- **Progress Tracking** - Records reading progress (0-100%) with configurable precision
- **Duration Tracking** - Measures time spent reading in seconds
- **Location Tracking** - Tracks page numbers and positions
- **Format Support** - Works with EPUB, PDF, DJVU, CBZ, CBR files
- **Suspend/Resume** - Handles device sleep and wake events

### 📊 Session Validation
- **Minimum Duration** - Only save sessions longer than X seconds (default: 30)
- **Minimum Pages** - Only save sessions with Y+ pages read (default: 5)
- **Detection Mode** - Choose duration-based OR pages-based validation
- **Skip Zero Progress** - Automatically reject sessions with no progress

### 🔄 Offline Support
- **Queue When Offline** - Sessions saved locally when server unavailable
- **Auto-Sync** - Syncs queued sessions when connection restored
- **Retry Logic** - Failed syncs automatically retried with counter
- **Book ID Resolution** - Offline sessions resolved by hash during sync

### 🗄️ Smart Caching
- **Book Hash Calculation** - Fast MD5 fingerprinting using sample-based algorithm
- **Book ID Mapping** - Maps file hashes to Booklore book IDs
- **SQLite Database** - Robust local caching with migrations
- **File Path Caching** - Remembers books by file location

### ⚙️ Flexible Configuration
- **Server URL** - Connect to any Booklore server
- **Authentication** - Username/password with MD5 hashing
- **Session Thresholds** - Customize min duration and pages
- **Progress Decimals** - 0-5 decimal places for progress tracking
- **Manual/Auto Sync** - Choose when sessions are synced
- **Silent Mode** - Disable popup notifications

### 🔄 Auto-Update System
- **Self-Updating** - Update plugin from within KOReader
- **GitHub Integration** - Automatically fetches latest releases
- **One-Click Install** - Download and install updates with single tap
- **Auto-Check** - Optional daily check for new versions on startup
- **Safe Updates** - Automatic backup before installation
- **Rollback Support** - Restore previous version if update fails
- **Version Management** - Semantic versioning with clear changelog

---

## Quick Start

### Installation

1. **Copy plugin to KOReader:**
   ```bash
   cp -r bookloresync.koplugin ~/.config/koreader/plugins/
   ```

2. **Restart KOReader completely** (not just sleep mode)

3. **Configure the plugin:**
   - Open KOReader
   - Go to **Tools → Booklore Sync → Settings**
   - Enter your server URL, username, and password
   - Tap **Test Connection** to verify

### First Session

1. **Open any book** - Hash calculated, book ID fetched
2. **Read for 30+ seconds** - Session tracked automatically
3. **Close the book** - Session validated and synced
4. **Check your Booklore server** - Session appears!

For detailed testing instructions, see [QUICK_START.md](QUICK_START.md).

### Keeping Up to Date

**The plugin can update itself from within KOReader!**

1. **Auto-Check (Recommended)**
   - Enabled by default
   - Checks once per day on startup
   - Shows notification when update available
   - Go to **Tools → Booklore Sync → About & Updates**

2. **Manual Check**
   - Open KOReader
   - Go to **Tools → Booklore Sync → About & Updates**
   - Tap **Check for Updates**
   - Tap **Install** if update available
   - Restart KOReader when prompted

3. **Version Information**
   - Check current version
   - View build date and git commit
   - See update status

**Update Process**:
- Downloads latest version from GitHub
- Creates backup of current version automatically
- Installs new version atomically
- Prompts for restart to complete
- Rollback available if installation fails

---

## How It Works

### Session Lifecycle

```
┌─────────────┐
│ Open Book   │ → Calculate hash → Fetch book_id → Cache
└─────────────┘
       ↓
┌─────────────┐
│ Start       │ → Record: start time, progress, location
│ Session     │
└─────────────┘
       ↓
┌─────────────┐
│ Read Book   │ → User reads...
└─────────────┘
       ↓
┌─────────────┐
│ Close Book  │ → Calculate: duration, pages, progress delta
└─────────────┘
       ↓
┌─────────────┐
│ Validate    │ → Check: min duration, min pages
└─────────────┘
       ↓
    [Valid?]
       ↓ Yes
┌─────────────┐
│ Save to     │ → Queue in local database
│ Queue       │
└─────────────┘
       ↓
┌─────────────┐
│ Sync to     │ → Upload to Booklore server
│ Server      │
└─────────────┘
```

### Offline Mode

When offline, sessions are saved with `book_id = NULL`:

```
Offline Open → Hash calculated → book_id = NULL → Cache
             ↓
Read & Close → Session saved to queue
             ↓
[Network available]
             ↓
Sync → Resolve book_id by hash → Upload session → Delete from queue
```

See [SESSION_TRACKING.md](SESSION_TRACKING.md) for detailed architecture.

---

## Architecture

### Module Structure

```
bookloresync.koplugin/
├── main.lua                    - Main plugin, session logic, event handlers
├── booklore_settings.lua       - Settings UI and configuration
├── booklore_api_client.lua     - HTTP client for Booklore API
├── booklore_database.lua       - SQLite database operations
├── plugin_version.lua          - Auto-generated version info
└── _meta.lua                   - Plugin metadata
```

### Database Schema

**book_cache** - Caches book information
- `file_path` (unique) - Full path to book file
- `file_hash` (indexed) - MD5 hash of book content
- `book_id` - Booklore server book ID (nullable)
- `title`, `author`, `book_type` - Book metadata
- `created_at`, `updated_at` - Timestamps

**pending_sessions** - Queued sessions waiting to sync
- `book_id` - Booklore book ID (nullable if offline)
- `book_hash` - MD5 hash for resolution
- `start_time`, `end_time` - ISO 8601 timestamps
- `duration_seconds` - Reading time in seconds
- `start_progress`, `end_progress`, `progress_delta` - Progress tracking
- `start_location`, `end_location` - Page/position
- `retry_count` - Failed sync attempts
- `created_at` - Queue timestamp

See [SYNC_IMPLEMENTATION.md](SYNC_IMPLEMENTATION.md) for sync workflow details.

---

## API Endpoints

The plugin communicates with these Booklore API endpoints:

- `GET /api/koreader/users/auth` - Authenticate user
- `GET /api/koreader/books/by-hash/:hash` - Get book by file hash
- `POST /api/v1/reading-sessions` - Submit reading session
- `GET /api/health` - Check server health

Authentication uses MD5-hashed password for compatibility with Booklore server.

---

## Configuration Options

### Connection
- **Server URL** - Booklore server address (e.g., `http://localhost:6060`)
- **Username** - Your Booklore username
- **Password** - Your Booklore password (stored as MD5 hash)

### Session Tracking
- **Enable/Disable** - Turn sync on/off
- **Min Duration** - Minimum seconds to save session (default: 30)
- **Min Pages** - Minimum pages to save session (default: 5)
- **Detection Mode** - Validate by "duration" or "pages"
- **Progress Decimals** - 0-5 decimal places (default: 2)

### Sync Options
- **Manual Sync Only** - Disable auto-sync, sync manually
- **Silent Messages** - Hide popup notifications
- **Force Push on Suspend** - (UI only, not implemented)
- **Connect Network on Suspend** - (UI only, not implemented)

### Advanced
- **Clear Cache** - Remove all cached book data
- **Clear Pending Sessions** - Delete queued sessions
- **View Statistics** - See cache size and pending count

---

## Feature Completion

| Category | Status |
|----------|--------|
| **Session Tracking** | ✅ 100% (12/12 features) |
| **Session Validation** | ✅ 100% (4/4 features) |
| **Offline Support** | ✅ 100% (10/10 features) |
| **Cache Management** | ✅ 100% (6/6 features) |
| **Settings & UI** | ✅ 89% (8/9 features) |
| **API Communication** | ✅ 100% (9/9 features) |
| **Database (SQLite)** | ✅ 100% (20/20 features) |
| **Dispatcher Integration** | ✅ 100% (4/4 features) |
| **Network Management** | ⏳ 33% (1/3 features) |
| **Historical Data Sync** | ⏳ 43% (3/7 features) |

**Overall: 85.9% Complete** (85/99 core features)

See [features.md](features.md) for detailed feature tracking.

---

## Known Limitations

### Deferred for Post-Launch
These features are not critical and intentionally deferred:

1. **Historical Data Sync** - Import sessions from `statistics.sqlite3`
   - Can be added later based on user demand
   - Reference implementation: `old/main.lua:1059-1356`

2. **Network Management** - Auto-enable WiFi on suspend
   - Device-specific, requires testing on various hardware
   - Reference implementation: `old/main.lua:404-441`

3. **Custom File Logging** - Write to dedicated log file
   - KOReader's logger works fine for now
   - Can add if users request it

### By Design
- **Auto-sync on reader ready** - Not implemented to avoid startup delays
- **Force push on suspend** - UI exists but behavior not implemented

---

## Troubleshooting

### Plugin Not Appearing in Menu
- Ensure files are in `~/.config/koreader/plugins/bookloresync.koplugin/`
- Restart KOReader completely (not just sleep mode)
- Check KOReader log for Lua errors

### Connection Test Fails
```bash
# Verify server is running
curl http://localhost:6060/api/health

# Should return: {"status":"ok"}
```
- Check server URL is correct
- Verify server is running and accessible
- Check username/password are correct

### Sessions Not Syncing
- Check **Tools → Booklore Sync → View Statistics** for pending count
- Verify **Manual Sync Only** is disabled (if you want auto-sync)
- Check KOReader log: `tail -f /tmp/koreader.log | grep BookloreSync`
- Try manual sync: **Tools → Booklore Sync → Sync Now**

### "bad argument #1 to 'floor'" Error
- **Cause:** KOReader didn't reload updated plugin code
- **Fix:** Restart KOReader completely

### Database Errors
```bash
# Reset database (WARNING: deletes all cached data)
rm ~/.config/koreader/settings/booklore-sync.sqlite
# Restart KOReader
```

For more help, see [DEBUG_REFERENCE.md](DEBUG_REFERENCE.md).

---

## Testing

### Quick Test (5 minutes)
See [QUICK_START.md](QUICK_START.md) for a simple 5-step test.

### Comprehensive Test
See [TESTING_GUIDE.md](TESTING_GUIDE.md) for full test plan covering:
- Fresh installation
- Book hash calculation
- Session tracking (valid/invalid)
- Sync (online/offline)
- Edge cases
- Settings persistence
- Performance benchmarks

---

## Development

### Requirements
- Lua 5.1 / LuaJIT
- KOReader 2023.10+ (or compatible version)
- SQLite 3 (via lua-ljsqlite3)
- Booklore server running

### File Structure
```
booklore-koreader-plugin/
├── bookloresync.koplugin/     - Plugin code
│   ├── main.lua
│   ├── booklore_settings.lua
│   ├── booklore_api_client.lua
│   ├── booklore_database.lua
│   ├── plugin_version.lua
│   └── _meta.lua
├── old/                        - Reference old plugin
├── docs/
│   ├── QUICK_START.md         - Quick test guide
│   ├── TESTING_GUIDE.md       - Comprehensive tests
│   ├── DEBUG_REFERENCE.md     - Debug commands
│   ├── STATUS.md              - Project status
│   ├── BOOK_HASH.md           - Hash algorithm
│   ├── SESSION_TRACKING.md    - Session architecture
│   ├── SYNC_IMPLEMENTATION.md - Sync workflow
│   ├── TYPE_SAFETY_FIX.md     - Type conversions
│   └── VERSIONING.md          - Version strategy
├── features.md                 - Feature tracking
└── README.md                   - This file
```

### Syntax Check
```bash
cd bookloresync.koplugin
luac -p *.lua
```

### Database Inspection
```bash
sqlite3 ~/.config/koreader/settings/booklore-sync.sqlite

# View schema
.schema

# View cached books
SELECT * FROM book_cache;

# View pending sessions
SELECT * FROM pending_sessions;
```

---

## Changes from Old Plugin

### Major Improvements
- ✅ **SQLite Database** - Replaced LuaSettings with proper database
- ✅ **Type Safety** - All SQLite cdata properly converted
- ✅ **Offline Book ID Resolution** - Sessions with NULL book_id resolved during sync
- ✅ **Retry Logic** - Track failed sync attempts per session
- ✅ **Module Separation** - Clean separation of concerns
- ✅ **Schema Versioning** - Migration framework for future updates
- ✅ **Atomic Operations** - INSERT OR REPLACE for data consistency
- ✅ **Better Error Handling** - Enhanced API error extraction
- ✅ **No Module Conflicts** - All modules prefixed with "booklore_"

### New Features
- **Session Detection Mode** - Choose duration OR pages validation
- **Minimum Pages Read** - Additional validation option
- **Version Display** - Dedicated button showing version info
- **Formatted Duration** - Human-readable format (e.g., "1h 5m 9s")
- **Auto-Detect Book Type** - Supports EPUB, PDF, DJVU, CBZ, CBR
- **Auto-Sync on Resume** - Background sync on device wake
- **Update Book ID by Hash** - Cache updates when resolved

### Bug Fixes
All SQLite binding errors and cdata type conversion issues resolved. See [TYPE_SAFETY_FIX.md](TYPE_SAFETY_FIX.md) for details.

---

## Version History

### 1.0.0-beta (February 11, 2026) - Current
- Initial rewrite from old plugin
- SQLite database implementation
- Complete session tracking
- Offline support with queue
- Auto-sync and manual sync
- Settings UI
- 85.9% feature complete
- Ready for testing

See [VERSIONING.md](VERSIONING.md) for version strategy.

---

## Contributing

### Bug Reports
When reporting bugs, please include:
- KOReader version
- Plugin version
- Steps to reproduce
- KOReader log output (`grep BookloreSync /tmp/koreader.log`)
- Database state (`SELECT * FROM pending_sessions;`)

### Feature Requests
Feature requests welcome! Check [features.md](features.md) to see what's planned.

---

## License

[Add your license here]

---

## Links

- **Booklore Server**: [Add Booklore repo link]
- **KOReader**: https://github.com/koreader/koreader
- **Documentation**: See `docs/` folder

---

## Support

For help:
1. Check [QUICK_START.md](QUICK_START.md) for testing guide
2. Check [DEBUG_REFERENCE.md](DEBUG_REFERENCE.md) for debug commands
3. Check [TESTING_GUIDE.md](TESTING_GUIDE.md) for comprehensive tests
4. Review KOReader logs for errors
5. Inspect database for pending sessions

---

**Status:** Ready for testing! Follow [QUICK_START.md](QUICK_START.md) to get started.

**Last Updated:** February 11, 2026  
**Next Milestone:** End-to-end testing and user validation
