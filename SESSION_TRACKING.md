# Session Tracking Implementation

## Overview
Implemented complete session tracking system that automatically records reading sessions from when a book is opened until it's closed, the device suspends, or user returns to menu.

## Architecture

### Session Lifecycle

```
┌──────────────────────────────────────────────────────────────┐
│                    SESSION LIFECYCLE                         │
└──────────────────────────────────────────────────────────────┘

Book Opened (onReaderReady)
        │
        ▼
┌───────────────────┐
│  startSession()   │
│  - Check DB cache │
│  - Get progress   │
│  - Create session │
└─────────┬─────────┘
          │
          │ Reading...
          │
          ▼
┌─────────────────────────────────────────────┐
│  Trigger Event:                             │
│  • Document Close (onCloseDocument)         │
│  • Device Suspend (onSuspend)               │
│  • Return to Menu                           │
└─────────┬───────────────────────────────────┘
          │
          ▼
┌───────────────────┐
│   endSession()    │
│  - Get progress   │
│  - Calculate dur. │
│  - Validate       │
│  - Save to DB     │
│  - Auto-sync?     │
└─────────┬─────────┘
          │
          ▼
┌───────────────────┐
│ Session in        │
│ pending_sessions  │
│ table (SQLite)    │
└───────────────────┘
```

## Components

### 1. Session State (`main.lua:58-59`)

```lua
self.current_session = nil  -- Active session tracking
```

Session object structure:
```lua
{
    file_path = "/path/to/book.epub",
    book_id = 123,                    -- Booklore book ID (may be nil)
    file_hash = "abc123...",          -- Cached hash (may be nil)
    cache_id = 1,                     -- Database cache entry ID
    start_time = 1707648000,          -- Unix timestamp
    start_progress = 10.5,            -- Progress percentage
    start_location = "100",           -- Page number or position
    book_type = "EPUB",               -- EPUB, PDF, DJVU, COMIC
}
```

### 2. Helper Functions

#### `roundProgress(value)` - `main.lua:605-609`
Rounds progress to configured decimal places (0-5).

```lua
function BookloreSync:roundProgress(value)
```

**Example:**
- Input: `10.123456`, decimal_places: `2`
- Output: `10.12`

#### `getCurrentProgress()` - `main.lua:616-651`
Gets current reading progress and location for both PDF and EPUB formats.

```lua
function BookloreSync:getCurrentProgress()
```

**Returns:**
- `progress` (number): 0-100 percentage
- `location` (string): Page number or position

**Supports:**
- PDF/image-based formats (has_pages)
- EPUB/reflowable formats (rolling)

#### `getBookType(file_path)` - `main.lua:653-676`
Determines book type from file extension.

```lua
function BookloreSync:getBookType(file_path)
```

**Supported formats:**
- `.epub` → `"EPUB"`
- `.pdf` → `"PDF"`
- `.djvu` → `"DJVU"`
- `.cbz`, `.cbr` → `"COMIC"`
- Default → `"EPUB"`

### 3. Session Management

#### `startSession()` - `main.lua:678-731`
Starts tracking a new reading session when document opens.

**Process:**
1. Check if sync is enabled
2. Verify document is available
3. Get file path
4. Check database for cached book info
5. Get current progress/location
6. Create session tracking object
7. Log session start

**Database lookup:**
```lua
local cached_book = self.db:getBookByFilePath(file_path)
```

Returns:
```lua
{
    id = 1,              -- Cache entry ID
    file_path = "...",
    file_hash = "...",   -- MD5 hash
    book_id = 123,       -- Booklore ID (may be nil)
    title = "...",       -- May be nil
    author = "...",      -- May be nil
}
```

#### `endSession(options)` - `main.lua:733-843`
Ends current session and saves to database.

**Parameters:**
```lua
options = {
    silent = false,       -- Suppress UI messages
    force_queue = false,  -- Always queue, don't auto-sync
}
```

**Process:**
1. Check if session exists
2. Get current progress/location
3. Calculate duration and pages read
4. Validate session (duration/pages check)
5. Calculate progress delta
6. Format timestamps (ISO 8601)
7. Prepare session data
8. Save to pending_sessions table
9. Optionally auto-sync
10. Clear session state

**Validation:**
- Duration-based: `duration >= min_duration` AND `pages_read > 0`
- Pages-based: `pages_read >= min_pages`

**Session data saved:**
```lua
{
    bookId = 123,                       -- May be nil
    bookHash = "abc123...",             -- May be nil
    bookType = "EPUB",
    startTime = "2026-02-11T08:00:00Z",
    endTime = "2026-02-11T08:05:09Z",
    durationSeconds = 309,
    startProgress = 10.5,
    endProgress = 15.2,
    progressDelta = 4.7,
    startLocation = "100",
    endLocation = "150",
}
```

### 4. Event Handlers

#### `onReaderReady()` - `main.lua:877-880`
Triggered when document is opened and ready.

```lua
function BookloreSync:onReaderReady()
```

**Action:** Calls `startSession()`

#### `onCloseDocument()` - `main.lua:885-891`
Triggered when document is closed.

```lua
function BookloreSync:onCloseDocument()
```

**Action:** Calls `endSession({ silent = false, force_queue = false })`
- Shows UI message
- Allows auto-sync if enabled

#### `onSuspend()` - `main.lua:896-900`
Triggered when device is about to sleep.

```lua
function BookloreSync:onSuspend()
```

**Action:** Calls `endSession({ silent = true, force_queue = true })`
- Silent (no UI messages)
- Always queues (doesn't try to sync on suspend)

#### `onResume()` - `main.lua:905-924`
Triggered when device wakes from sleep.

```lua
function BookloreSync:onResume()
```

**Actions:**
1. Try to sync pending sessions (if not in manual-only mode)
2. If book is still open, start new session

## Session Validation

### Duration-based Mode (default)
```lua
session_detection_mode = "duration"
min_duration = 30  -- seconds
```

**Rules:**
- Session duration must be ≥ `min_duration`
- Must have read at least 1 page (progress must change)

**Example:**
- Duration: 45s, Pages: 5 → ✅ Valid
- Duration: 45s, Pages: 0 → ❌ Invalid (no progress)
- Duration: 15s, Pages: 10 → ❌ Invalid (too short)

### Pages-based Mode
```lua
session_detection_mode = "pages"
min_pages = 5
```

**Rules:**
- Pages read must be ≥ `min_pages`
- Duration is ignored

**Example:**
- Pages: 10, Duration: 10s → ✅ Valid
- Pages: 3, Duration: 300s → ❌ Invalid (too few pages)

## Database Integration

### Cache Lookup
```lua
-- Check if book is in cache
local cached_book = self.db:getBookByFilePath(file_path)

if cached_book then
    -- Use cached book_id and file_hash
    session.book_id = cached_book.book_id
    session.file_hash = cached_book.file_hash
end
```

### Session Storage
```lua
-- Save session to pending queue
local success = self.db:addPendingSession(session_data)
```

Stored in `pending_sessions` table:
- Will be synced later by `syncPendingSessions()`
- Persists across app restarts
- Supports retry logic

## Auto-Sync Behavior

### After Session End (Close Document)
```lua
if not force_queue and not self.manual_sync_only then
    self:syncPendingSessions(true)  -- Silent background sync
end
```

**When:**
- Document is closed normally
- Not in manual-sync-only mode
- Not forced to queue

### On Resume from Suspend
```lua
if not self.manual_sync_only then
    self:syncPendingSessions(true)  -- Silent background sync
end
```

**When:**
- Device wakes from sleep
- Not in manual-sync-only mode

### Manual-Sync-Only Mode
```lua
self.manual_sync_only = true
```

**Behavior:**
- All sessions are queued
- No automatic syncing
- User must manually trigger sync via menu or gesture

## Examples

### Example 1: Normal Reading Session
```
1. User opens book.epub
   → onReaderReady() called
   → startSession() creates tracking object
   → Cache checked: book found with ID 123
   → Session starts at 10.5% (page 100)

2. User reads for 5 minutes
   → Session tracked in memory

3. User closes book
   → onCloseDocument() called
   → endSession() called
   → Current progress: 15.2% (page 150)
   → Duration: 300s, Pages: 50
   → Validation: ✅ Valid (duration ≥ 30s, pages > 0)
   → Session saved to pending_sessions
   → Auto-sync triggered (silent)
```

### Example 2: Short Session (Invalid)
```
1. User opens book.epub
   → Session starts at 50.0%

2. User accidentally closes after 5 seconds
   → Duration: 5s, Pages: 0
   → Validation: ❌ Invalid (duration < 30s)
   → Session discarded
```

### Example 3: Suspend During Reading
```
1. User opens book.epub
   → Session starts at 20.0%

2. User reads for 10 minutes

3. Device goes to sleep
   → onSuspend() called
   → endSession({ silent = true, force_queue = true })
   → Session saved to pending_sessions
   → No auto-sync attempt

4. Device wakes up
   → onResume() called
   → Auto-sync attempted (background)
   → New session started if book still open
```

### Example 4: Manual-Sync-Only Mode
```
Settings: manual_sync_only = true

1. User reads 3 different books
   → Each session saved to pending_sessions
   → No auto-sync attempted

2. Pending sessions: 3

3. User manually triggers "Sync Pending Sessions"
   → All 3 sessions synced to server
   → Pending sessions: 0
```

## Configuration

### Settings
```lua
-- Enable/disable tracking
is_enabled = true

-- Session validation
session_detection_mode = "duration"  -- or "pages"
min_duration = 30                    -- seconds
min_pages = 5                        -- pages

-- Progress precision
progress_decimal_places = 2          -- 0-5

-- Sync behavior
manual_sync_only = false
force_push_session_on_suspend = false
silent_messages = false
```

### Defaults
- `min_duration`: 30 seconds
- `min_pages`: 5 pages
- `session_detection_mode`: "duration"
- `progress_decimal_places`: 2

## Logging

All session events are logged with appropriate levels:

```
INFO:  Session lifecycle events
INFO:  Progress tracking
INFO:  Validation results
WARN:  Missing document/file path
ERR:   Database save failures
```

**Example log output:**
```
INFO: BookloreSync: ========== Starting session ==========
INFO: BookloreSync: File: /mnt/storage/books/example.epub
INFO: BookloreSync: Found book in cache - ID: 123 Hash: abc123...
INFO: BookloreSync: Session started at 10.5 % (location: 100 )
...
INFO: BookloreSync: ========== Ending session ==========
INFO: BookloreSync: Duration: 309 s, Pages read: 50
INFO: BookloreSync: Progress: 10.5 % -> 15.2 %
INFO: BookloreSync: Session valid - Duration: 309 s, Progress delta: 4.7 %
INFO: BookloreSync: Session saved to pending queue
```

## Future Enhancements

### Planned Features
1. **Book hash calculation** - Calculate MD5 hash for new books
2. **Network check before sync** - Verify connectivity before attempting
3. **Progress notifications** - Optional reading progress milestones
4. **Session statistics** - Daily/weekly reading stats
5. **Book title extraction** - Get metadata from files

### Potential Improvements
1. **Batch session start** - Handle multiple documents
2. **Session pause/resume** - Track breaks in reading
3. **Location tracking** - More precise position tracking
4. **Reading speed** - Calculate pages/minute
5. **Chapter tracking** - Track chapter progress

## Testing Checklist

- [ ] Session starts when opening a book
- [ ] Session ends when closing a book
- [ ] Session ends on device suspend
- [ ] Session resumes after wake-up
- [ ] Valid sessions are saved to database
- [ ] Invalid sessions (too short) are discarded
- [ ] Invalid sessions (no progress) are discarded
- [ ] Progress is tracked correctly (PDF)
- [ ] Progress is tracked correctly (EPUB)
- [ ] Duration is calculated correctly
- [ ] Pages read calculation is correct
- [ ] Book type detection works (PDF, EPUB, etc.)
- [ ] Auto-sync works after session end
- [ ] Auto-sync works after resume
- [ ] Manual-sync-only mode prevents auto-sync
- [ ] Silent mode suppresses messages
- [ ] Settings are respected (min_duration, min_pages)
- [ ] Session detection mode switches correctly
- [ ] Database cache is used correctly
- [ ] Sessions persist across app restarts
