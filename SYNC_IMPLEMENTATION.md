# Sync Pending Sessions Implementation

## Overview
Implemented the `syncPendingSessions` function to upload queued reading sessions to the Booklore server with automatic book ID resolution and formatted duration display.

## Features Implemented

### 1. Format Duration Function (`formatDuration`)
**Location**: `main.lua:533-557`

Converts duration in seconds to a human-readable format with only present values shown:
- `309` seconds → `"5m 9s"`
- `3661` seconds → `"1h 1m 1s"`
- `45` seconds → `"45s"`
- `3600` seconds → `"1h"`
- `0` seconds → `"0s"`

**Function signature**:
```lua
function BookloreSync:formatDuration(duration_seconds)
```

### 2. Sync Pending Sessions Function (`syncPendingSessions`)
**Location**: `main.lua:591-736`

Synchronizes all pending sessions from the local database to the Booklore server.

**Key Features**:

#### Automatic Book ID Resolution
- Checks cache first for book ID by hash
- If not in cache, queries the server
- Updates cache with resolved book IDs
- Skips sessions that can't be resolved (with retry tracking)

#### Session Data Enhancement
- Adds `durationFormatted` field to each session
- Removes internal database fields (id, retryCount, etc.)
- Validates that book ID exists before submitting

#### Error Handling & Retry Logic
- Increments retry count for failed sessions
- Keeps failed sessions in the queue for next sync
- Deletes successfully synced sessions from database
- Logs all operations for debugging

#### User Feedback
- Silent mode support for background syncs
- Progress messages showing sync status
- Summary messages with counts (synced/failed)
- Respects `silent_messages` setting

**Function signature**:
```lua
function BookloreSync:syncPendingSessions(silent)
```

**Parameters**:
- `silent` (optional): If true, suppresses UI messages (default: false)

**Returns**:
- `synced_count`: Number of sessions successfully synced
- `failed_count`: Number of sessions that failed to sync

## Usage Examples

### Manual Sync
```lua
-- User clicks "Sync Pending Sessions" in menu
self:syncPendingSessions()
-- Shows messages and returns counts
```

### Background Sync (Silent)
```lua
-- Auto-sync on resume without UI messages
self:syncPendingSessions(true)
-- No messages shown, only logging
```

## Session Data Structure

### Before Submission (from database)
```lua
{
    id = 1,                          -- Internal DB ID
    bookId = 123,                    -- Booklore book ID (may be nil)
    bookHash = "abc123...",          -- MD5 hash of book file
    bookType = "EPUB",
    startTime = "2026-02-11T08:00:00Z",
    endTime = "2026-02-11T08:05:09Z",
    durationSeconds = 309,
    startProgress = 10.5,
    endProgress = 15.2,
    progressDelta = 4.7,
    startLocation = "100",
    endLocation = "150",
    retryCount = 0,                  -- Internal retry tracking
}
```

### After Enhancement (sent to API)
```lua
{
    bookId = 123,
    bookType = "EPUB",
    startTime = "2026-02-11T08:00:00Z",
    endTime = "2026-02-11T08:05:09Z",
    durationSeconds = 309,
    durationFormatted = "5m 9s",     -- Added by formatDuration
    startProgress = 10.5,
    endProgress = 15.2,
    progressDelta = 4.7,
    startLocation = "100",
    endLocation = "150",
}
```

## Workflow

```
┌─────────────────────────┐
│  syncPendingSessions()  │
└───────────┬─────────────┘
            │
            ▼
┌─────────────────────────┐
│  Check database exists  │
└───────────┬─────────────┘
            │
            ▼
┌─────────────────────────┐
│ Get pending session     │
│ count from database     │
└───────────┬─────────────┘
            │
            ▼
┌─────────────────────────┐
│ Fetch up to 100         │
│ pending sessions        │
└───────────┬─────────────┘
            │
            ▼
    ┌───────────────┐
    │ For each      │
    │ session:      │
    └───────┬───────┘
            │
            ├──► Has book ID? ──NO──┐
            │        │               │
            │       YES              ▼
            │        │      ┌────────────────┐
            │        │      │ Check cache for│
            │        │      │ book by hash   │
            │        │      └────────┬───────┘
            │        │               │
            │        │          Found in cache?
            │        │          │         │
            │        │         YES       NO
            │        │          │         │
            │        │          │         ▼
            │        │          │   ┌─────────────┐
            │        │          │   │ Query server│
            │        │          │   │ for book ID │
            │        │          │   └──────┬──────┘
            │        │          │          │
            │        │          │     Found on server?
            │        │          │      │         │
            │        │          │     YES       NO
            │        │          │      │         │
            │        │          └──────┤         ▼
            │        │                 │    ┌─────────────┐
            │        │                 │    │ Increment   │
            │        │                 │    │ retry count │
            │        │                 │    │ & skip      │
            │        │                 │    └─────────────┘
            │        ▼                 │
            │  ┌─────────────────────┐│
            │  │ Format duration     ││
            │  │ (Xh Ym Zs)          ││
            │  └──────────┬──────────┘│
            │             │            │
            │             ▼            │
            │  ┌─────────────────────┐│
            │  │ Prepare session     ││
            │  │ data for API        ││
            │  └──────────┬──────────┘│
            │             │            │
            │             ▼            │
            │  ┌─────────────────────┐│
            │  │ Submit to server    ││
            │  │ via API             ││
            │  └──────────┬──────────┘│
            │             │            │
            │        Success?          │
            │        │      │          │
            │       YES    NO          │
            │        │      │          │
            │        ▼      ▼          │
            │  ┌─────┐  ┌───────────┐ │
            │  │Delete│  │ Increment │ │
            │  │from  │  │   retry   │ │
            │  │ DB   │  │   count   │ │
            │  └─────┘  └───────────┘ │
            │        │      │          │
            └────────┴──────┴──────────┘
                     │
                     ▼
            ┌─────────────────┐
            │ Show summary    │
            │ message         │
            └─────────────────┘
```

## Integration Points

### Menu Item
The function is triggered from:
- **Booklore Sync → Session Management → Sync Pending Sessions**
- Menu location: `main.lua:299-306`

### Dispatcher Action
Can be triggered via gesture:
- Action: `booklore_sync_pending`
- Handler: `onSyncBooklorePending` (`main.lua:171-184`)

### Automatic Triggers (Future)
Will be called automatically from:
- `onResume` - After device wakes from sleep (not yet implemented)
- `onReaderReady` - When reader starts (not yet implemented)
- After successful session submission (cascade sync)

## Dependencies

### Database Methods Used
- `db:getPendingSessionCount()` - Count pending sessions
- `db:getPendingSessions(limit)` - Fetch pending sessions
- `db:getBookByHash(hash)` - Check cache for book ID
- `db:updateBookId(hash, id)` - Cache resolved book ID
- `db:incrementSessionRetryCount(id)` - Track retry attempts
- `db:deletePendingSession(id)` - Remove synced session

### API Methods Used
- `api:getBookByHash(hash)` - Resolve book ID from server
- `api:submitSession(data)` - Upload session to server

## Testing

### Manual Testing Checklist
- [ ] Sync sessions with known book IDs
- [ ] Sync sessions requiring book ID resolution
- [ ] Sync with no pending sessions
- [ ] Sync with network offline (should fail gracefully)
- [ ] Sync with invalid credentials
- [ ] Verify retry count increments on failure
- [ ] Verify successful sessions are deleted from database
- [ ] Check formatted duration display in logs
- [ ] Test silent mode (no UI messages)
- [ ] Test normal mode (shows messages)

### Test Cases for formatDuration
| Input (seconds) | Expected Output |
|-----------------|-----------------|
| 0               | "0s"            |
| 9               | "9s"            |
| 59              | "59s"           |
| 60              | "1m"            |
| 309             | "5m 9s"         |
| 3600            | "1h"            |
| 3661            | "1h 1m 1s"      |
| 7384            | "2h 3m 4s"      |
| nil             | "0s"            |
| -5              | "0s"            |

## Notes

### Performance
- Processes up to 100 sessions per call to avoid blocking UI
- Each session requires 1-2 API calls (book lookup + session submit)
- Book lookups are cached to reduce server requests

### Error Recovery
- Failed sessions remain in database
- Retry count prevents infinite retry loops
- Book ID resolution failures are logged for debugging

### Future Improvements
- Add batch submission API endpoint (reduce API calls)
- Add progress bar for large sync operations
- Add configurable retry limit (currently unlimited)
- Add option to manually remove stuck sessions
- Add network check before attempting sync
