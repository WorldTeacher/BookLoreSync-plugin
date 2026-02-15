# Auto-Updater Testing Checklist

This document provides a comprehensive testing checklist for the BookloreSync auto-updater feature.

## Pre-Testing Verification

- ✅ All Lua syntax checks passed
- ✅ Version comparison logic tested (9/9 tests passed)
- ✅ GitHub API accessible and returns valid data
- ✅ Download URL works (36KB ZIP file)
- ✅ ZIP structure contains required files (main.lua, _meta.lua)

---

## Test Environment Setup

### 1. Install Plugin on KOReader Device
```bash
# Copy plugin to KOReader
scp -r bookloresync.koplugin user@device:~/.local/share/koreader/

# Or if using system installation
sudo cp -r bookloresync.koplugin /usr/lib/koreader/plugins/
```

### 2. Restart KOReader
- Fully restart KOReader (not just sleep/wake)
- Verify plugin loads without errors
- Check logs: `~/.local/share/koreader/crash.log`

---

## Phase 1: Initialization Tests

### Test 1.1: Plugin Initialization
**Expected**: Plugin loads successfully, updater initializes

**Steps**:
1. Start KOReader
2. Check logs for: `BookloreSync Updater: Initialized`
3. Verify paths logged correctly

**Pass Criteria**:
- ✓ No errors in crash.log
- ✓ Updater module loaded
- ✓ Plugin directory detected correctly

---

### Test 1.2: Database Migration
**Expected**: Migration 8 runs, updater_cache table created

**Steps**:
1. Check database schema version
2. Verify `updater_cache` table exists

**Verification**:
```bash
sqlite3 ~/.local/share/koreader/booklore-sync.sqlite "PRAGMA user_version;"
# Should output: 8

sqlite3 ~/.local/share/koreader/booklore-sync.sqlite ".schema updater_cache"
# Should show table structure
```

**Pass Criteria**:
- ✓ Schema version = 8
- ✓ `updater_cache` table created with correct columns

---

### Test 1.3: Auto-Check Scheduled
**Expected**: Auto-check scheduled for 5 seconds after startup

**Steps**:
1. Start KOReader
2. Wait 5-10 seconds
3. Check for update notification

**Pass Criteria**:
- ✓ Notification appears: "BookloreSync update available! Current: 0.0.0-dev Latest: 1.1.1"
- ✓ Notification shows correct versions
- ✓ Menu badge appears: "About & Updates ⚠"

---

## Phase 2: Menu & UI Tests

### Test 2.1: About & Updates Menu
**Expected**: Menu appears with all options

**Steps**:
1. Go to: Tools → Booklore Sync
2. Find "About & Updates ⚠" menu item
3. Tap to open submenu

**Pass Criteria**:
- ✓ Menu badge shows (⚠) when update available
- ✓ Four submenu items visible:
  - Version Information
  - Check for Updates ⚠ Update Available!
  - Auto-check on Startup (checked)
  - Clear Update Cache

---

### Test 2.2: Version Information
**Expected**: Shows current version details

**Steps**:
1. Tap "Version Information"
2. Read displayed information

**Pass Criteria**:
- ✓ Shows: Current Version, Version Type, Build Date, Git Commit
- ✓ Displays "⚠ Update available!" at bottom
- ✓ Dialog closes after 10 seconds

---

### Test 2.3: Check for Updates (Manual)
**Expected**: Shows update confirmation dialog

**Steps**:
1. Tap "Check for Updates"
2. Wait for GitHub API response (1-2 seconds)

**Pass Criteria**:
- ✓ Shows "Checking for updates..." message
- ✓ Confirmation dialog appears with:
  - Current version: 0.0.0-dev+...
  - Latest version: 1.1.1
  - Download size: 35.6 KB
  - Changelog preview
  - "Install" button
  - "Cancel" button

---

## Phase 3: Update Installation Tests

### Test 3.1: Download Phase
**Expected**: Download progresses, shows completion

**Steps**:
1. From update dialog, tap "Install"
2. Watch progress indicator

**Pass Criteria**:
- ✓ Progress message shows: "Downloading update... 0%"
- ✓ Progress updates to 25%, 50%, 75%, 100%
- ✓ Download completes without errors
- ✓ Transitions to "Installing update..." message

---

### Test 3.2: Installation Phase
**Expected**: Backup created, files replaced atomically

**Steps**:
1. Watch installation progress
2. Check backup directory after installation

**Verification**:
```bash
ls -la ~/.local/share/koreader/booklore-backups/
# Should show: bookloresync-0.0.0-dev+179f0b9-<timestamp>/
```

**Pass Criteria**:
- ✓ Backup directory created with timestamp
- ✓ Old version backed up successfully
- ✓ New files installed in plugin directory
- ✓ Success dialog appears

---

### Test 3.3: Restart Prompt
**Expected**: Restart dialog shows

**Steps**:
1. After successful installation, read dialog
2. Tap "Restart" button

**Pass Criteria**:
- ✓ Dialog shows: "Update installed successfully! Version 1.1.1 is ready. Restart KOReader now?"
- ✓ "Restart" button present
- ✓ "Later" button present
- ✓ Tapping "Restart" triggers KOReader restart

---

### Test 3.4: Post-Restart Verification
**Expected**: New version loaded, plugin works

**Steps**:
1. KOReader restarts
2. Check plugin version
3. Test basic functionality

**Verification**:
```bash
# Check version in _meta.lua
cat ~/.local/share/koreader/bookloresync.koplugin/_meta.lua | grep version
# Should show: version = "1.1.1"

# Check plugin_version.lua
cat ~/.local/share/koreader/bookloresync.koplugin/plugin_version.lua | grep version
# Should show: version = "1.1.1"
```

**Pass Criteria**:
- ✓ Version updated to 1.1.1
- ✓ Plugin loads without errors
- ✓ All menus accessible
- ✓ Basic sync functionality works

---

## Phase 4: Edge Case Tests

### Test 4.1: No Network Connection
**Expected**: Graceful handling when offline

**Steps**:
1. Disable WiFi on device
2. Go to "Check for Updates"
3. Tap to check

**Pass Criteria**:
- ✓ Shows: "No network connection. Please connect to check for updates."
- ✓ No crash or error
- ✓ Can retry after enabling WiFi

---

### Test 4.2: Already Up to Date
**Expected**: Shows "up to date" message

**Steps**:
1. After updating to 1.1.1
2. Go to "Check for Updates" again
3. Tap to check

**Pass Criteria**:
- ✓ Shows: "You're up to date! Current version: 1.1.1"
- ✓ No update offered
- ✓ Menu badge removed (no ⚠)

---

### Test 4.3: Cache Behavior
**Expected**: Second check within 1 hour uses cache

**Steps**:
1. Check for updates (fetches from API)
2. Immediately check again
3. Check logs

**Pass Criteria**:
- ✓ First check logs: "Fetching latest release from GitHub"
- ✓ Second check logs: "Using cached release info"
- ✓ Both checks return same result
- ✓ No duplicate API calls within 1 hour

---

### Test 4.4: Clear Cache
**Expected**: Cache cleared, next check fetches fresh data

**Steps**:
1. Tap "Clear Update Cache"
2. Check for updates again
3. Check logs

**Pass Criteria**:
- ✓ Shows: "Update cache cleared. Next check will fetch fresh data."
- ✓ Next check fetches from API (not cache)
- ✓ Logs show: "Fetching latest release from GitHub"

---

### Test 4.5: Auto-Check Frequency
**Expected**: Runs once per day, not more

**Steps**:
1. Restart KOReader
2. Wait 5 seconds for auto-check
3. Restart again within 24 hours
4. Check if auto-check runs

**Pass Criteria**:
- ✓ First restart: Auto-check runs after 5 seconds
- ✓ Second restart (same day): Auto-check skipped
- ✓ Logs show: "Auto-check skipped (last check was less than 24 hours ago)"

---

### Test 4.6: Toggle Auto-Check
**Expected**: Can disable/enable auto-check

**Steps**:
1. Go to "Auto-check on Startup" menu item
2. Tap to toggle
3. Restart KOReader

**Pass Criteria**:
- ✓ Checkbox toggles correctly
- ✓ Shows: "Auto-update check disabled" when unchecked
- ✓ Shows: "Auto-update check enabled" when checked
- ✓ No auto-check after restart when disabled

---

## Phase 5: Error Handling Tests

### Test 5.1: Installation Failure
**Expected**: Rollback option offered

**Steps**:
1. Simulate installation failure (not realistic to test)
2. Or check code path handles errors

**Pass Criteria**:
- ✓ Error dialog shows with clear message
- ✓ "Rollback" button appears
- ✓ "Cancel" button appears
- ✓ Backup preserved (not deleted)

---

### Test 5.2: Rollback Mechanism
**Expected**: Restores previous version

**Steps**:
1. Trigger rollback (from failed installation)
2. Verify files restored

**Pass Criteria**:
- ✓ Shows: "Rolling back to previous version..."
- ✓ Files restored from backup
- ✓ Version reverts to previous
- ✓ Restart prompt appears

---

### Test 5.3: Download Timeout
**Expected**: Graceful timeout handling

**Steps**:
1. Test with very slow/interrupted network (hard to simulate)
2. Check code has timeout logic

**Pass Criteria**:
- ✓ Code has 60-second timeout for downloads
- ✓ Timeout shows error message
- ✓ Temp files cleaned up
- ✓ Can retry download

---

## Phase 6: Backup & Cleanup Tests

### Test 6.1: Backup Creation
**Expected**: Backup created before installation

**Steps**:
1. Before updating, note current version
2. Install update
3. Check backup directory

**Verification**:
```bash
ls -la ~/.local/share/koreader/booklore-backups/
# Should show timestamped backup directory

# Verify backup contains all files
ls ~/.local/share/koreader/booklore-backups/bookloresync-*/
```

**Pass Criteria**:
- ✓ Backup directory created with timestamp
- ✓ All plugin files backed up
- ✓ Backup readable and complete

---

### Test 6.2: Backup Retention
**Expected**: Only keeps 3 most recent backups

**Steps**:
1. Perform 4 updates (simulated)
2. Check backup directory count

**Pass Criteria**:
- ✓ Only 3 backup directories exist
- ✓ Oldest backup automatically deleted
- ✓ Most recent 3 backups retained

---

### Test 6.3: Temp File Cleanup
**Expected**: Temp files removed after installation

**Steps**:
1. Install update
2. Check for temp files

**Verification**:
```bash
ls /tmp/booklore-update-* 2>/dev/null || echo "No temp files found"
```

**Pass Criteria**:
- ✓ No temp directories in /tmp
- ✓ Downloaded ZIP removed
- ✓ Extracted files cleaned up

---

## Performance Tests

### Test P.1: Startup Impact
**Expected**: < 1 second delay from auto-check

**Steps**:
1. Measure KOReader startup time before implementation
2. Measure after implementation
3. Compare

**Pass Criteria**:
- ✓ Auto-check scheduled, not blocking
- ✓ No noticeable startup delay
- ✓ Plugin loads immediately

---

### Test P.2: Update Check Speed
**Expected**: < 3 seconds for API call

**Steps**:
1. Manual check for updates
2. Time from tap to dialog

**Pass Criteria**:
- ✓ GitHub API responds < 2 seconds
- ✓ Total time < 3 seconds
- ✓ UI responsive during check

---

### Test P.3: Download Speed
**Expected**: Depends on connection, ~1-10 seconds for 36KB

**Steps**:
1. Install update
2. Measure download time

**Pass Criteria**:
- ✓ Progress indicator updates smoothly
- ✓ Download completes in reasonable time
- ✓ No UI freezing

---

## Regression Tests

### Test R.1: Existing Functionality
**Expected**: No regression in existing features

**Steps**:
1. Test basic sync functionality
2. Test all existing menus
3. Test session tracking

**Pass Criteria**:
- ✓ Session sync still works
- ✓ Book hashing works
- ✓ Historical data functions work
- ✓ All settings accessible

---

## Final Checklist

Before marking as complete:

- [ ] All Phase 1 tests passed
- [ ] All Phase 2 tests passed
- [ ] All Phase 3 tests passed
- [ ] All Phase 4 tests passed
- [ ] At least 3 edge cases from Phase 5 tested
- [ ] Backup mechanism verified (Phase 6)
- [ ] No performance regression (Phase P)
- [ ] No functional regression (Phase R)
- [ ] Documentation updated
- [ ] README updated with auto-update section

---

## Test Results Template

```
Date: YYYY-MM-DD
Tester: [Name]
Device: [Device Model]
KOReader Version: [Version]
Plugin Version Before: 0.0.0-dev+179f0b9
Plugin Version After: 1.1.1

| Test ID | Description | Result | Notes |
|---------|-------------|--------|-------|
| 1.1 | Plugin Init | PASS/FAIL | |
| 1.2 | DB Migration | PASS/FAIL | |
| 1.3 | Auto-Check | PASS/FAIL | |
| ... | ... | ... | |

Overall Status: PASS / FAIL
Issues Found: [List any issues]
```

---

## Known Limitations

1. **Full end-to-end test**: Requires actual KOReader device/emulator
2. **Network simulation**: Hard to test all network error scenarios
3. **Installation failure**: Difficult to reliably trigger for testing
4. **Multi-device**: Need to test on different devices (Kindle, Kobo, etc.)

---

## Next Steps After Testing

1. If all tests pass: Mark as production-ready
2. If issues found: Document and fix
3. Update CHANGELOG.md with new feature
4. Create release notes
5. Notify users of new auto-update capability
