# Book Hash Calculation

## Overview

The Booklore plugin uses MD5 hashing to uniquely identify book files. The hash is calculated using a **sample-based fingerprinting algorithm** that matches the Booklore server's `FileFingerprint` implementation.

## Algorithm

Instead of hashing the entire file (which would be slow for large books), the algorithm samples chunks from specific positions:

```
Positions: base << (2*i) for i = -1 to 10
where base = 1024 bytes

Positions calculated:
- i=-1: 1024 >> 2 = 512 bytes
- i=0:  1024 << 0 = 1024 bytes  
- i=1:  1024 << 2 = 4096 bytes
- i=2:  1024 << 4 = 16384 bytes
- i=3:  1024 << 6 = 65536 bytes
- ... and so on up to i=10
```

### Steps:
1. Open file in binary read mode
2. Get total file size
3. Sample 1024-byte chunks starting at each calculated position
4. Stop when position exceeds file size
5. Concatenate all sampled chunks
6. Calculate MD5 hash of concatenated data
7. Return hash as hex string

## Implementation

### Function: `calculateBookHash(file_path)`
**Location:** `main.lua:668-723`

```lua
function BookloreSync:calculateBookHash(file_path)
    local file = io.open(file_path, "rb")
    if not file then return nil end
    
    local md5 = require("ffi/sha2").md5
    local base = 1024
    local block_size = 1024
    local buffer = {}
    
    -- Get file size
    local file_size = file:seek("end")
    file:seek("set", 0)
    
    -- Sample at specific positions
    for i = -1, 10 do
        local position = bit.lshift(base, 2 * i)
        if position >= file_size then break end
        
        file:seek("set", position)
        local chunk = file:read(block_size)
        if chunk then
            table.insert(buffer, chunk)
        end
    end
    
    file:close()
    
    -- Calculate MD5
    local combined_data = table.concat(buffer)
    return md5(combined_data)
end
```

## Book ID Resolution Flow

When a session starts, the plugin follows this flow to identify the book:

```
1. Check database cache by file_path
   ├─ Found → Use cached hash and book_id
   └─ Not Found → Calculate hash
       ├─ Hash calculation failed → Continue without hash
       └─ Hash calculated → Look up book_id
           ├─ Check database cache by hash
           │   └─ Found → Use cached book_id
           └─ Not in cache → Query server
               ├─ GET /api/koreader/books/by-hash/{hash}
               ├─ Found → Cache book_id in database
               └─ Not Found → Continue with hash only
```

### Function: `getBookIdByHash(book_hash)`
**Location:** `main.lua:725-777`

```lua
function BookloreSync:getBookIdByHash(book_hash)
    -- Check database cache first
    local cached_book = self.db:getBookByHash(book_hash)
    if cached_book and cached_book.book_id then
        return cached_book.book_id
    end
    
    -- Query server via API
    local success, book_data = self.api:getBookByHash(book_hash)
    if success and book_data and book_data.id then
        -- Update cache
        if cached_book then
            self.db:updateBookId(book_hash, book_data.id)
        end
        return book_data.id
    end
    
    return nil
end
```

## Caching Strategy

### Database Schema
**Table:** `book_cache`

```sql
CREATE TABLE book_cache (
    id INTEGER PRIMARY KEY AUTOINCREMENT,
    file_path TEXT UNIQUE NOT NULL,
    file_hash TEXT NOT NULL,
    book_id INTEGER,
    title TEXT,
    author TEXT,
    last_accessed INTEGER,
    created_at INTEGER,
    updated_at INTEGER
)
```

**Indexes:**
- `file_path` - Fast lookup when opening a book
- `file_hash` - Fast lookup during session sync
- `book_id` - Optional lookup by server ID

### Cache Workflow

#### First Time Opening a Book
```
1. User opens /path/to/book.epub
2. Database query: SELECT * FROM book_cache WHERE file_path = '/path/to/book.epub'
3. No result → Calculate hash
4. Hash: "abc123..."
5. Query server: GET /api/koreader/books/by-hash/abc123
6. Server returns: {id: 42, title: "Example Book"}
7. Insert into database:
   - file_path: /path/to/book.epub
   - file_hash: abc123...
   - book_id: 42
8. Start tracking session with book_id=42
```

#### Subsequent Opens (Same File)
```
1. User opens /path/to/book.epub
2. Database query: SELECT * FROM book_cache WHERE file_path = '/path/to/book.epub'
3. Found: {file_hash: "abc123...", book_id: 42}
4. Start tracking session immediately (no hash calculation, no API call)
```

#### Opening Book After Moving/Renaming
```
1. User opens /new/path/book.epub (same file, different path)
2. Database query by file_path: No result
3. Calculate hash: "abc123..."
4. Database query by hash: SELECT * FROM book_cache WHERE file_hash = 'abc123'
5. Found: {book_id: 42, file_path: '/old/path/book.epub'}
6. Insert new entry:
   - file_path: /new/path/book.epub
   - file_hash: abc123...
   - book_id: 42
7. Start tracking session with book_id=42
```

## Performance Considerations

### Hash Calculation Speed
- **Small files (<1MB)**: ~1-2 chunks sampled, very fast
- **Medium files (10MB)**: ~5-7 chunks sampled, fast
- **Large files (100MB+)**: ~10-11 chunks sampled, still fast
- **Total data hashed**: Maximum ~11KB (11 chunks × 1KB each)

### When Hash is Calculated
✅ **Calculated:**
- First time opening a new book
- Opening a book from a new file path
- After clearing cache

❌ **Not Calculated:**
- Re-opening a cached book
- During session sync (uses cached hash)
- When book is already in database

## Error Handling

### File Access Errors
```lua
local file = io.open(file_path, "rb")
if not file then
    logger.warn("BookloreSync: Could not open file for hashing")
    return nil
end
```
- Session continues without hash
- Will be tracked by file path only
- Can be synced later when book is matched

### Network Errors
```lua
local success, book_data = self.api:getBookByHash(book_hash)
if not success then
    -- Offline or server error
    -- Session continues with hash but no book_id
    -- Will be resolved during sync when online
end
```

## Offline Support

The plugin works fully offline:

1. **First open (offline)**: Hash calculated, stored with `book_id = NULL`
2. **Session tracked**: Saved with hash in `pending_sessions`
3. **Later (online)**: During sync, `getBookIdByHash()` resolves the book_id
4. **Session submitted**: With resolved book_id

## Integration Points

### Session Start (`main.lua:779-831`)
```lua
function BookloreSync:startSession()
    local cached_book = self.db:getBookByFilePath(file_path)
    
    if cached_book then
        -- Use cached data
        file_hash = cached_book.file_hash
        book_id = cached_book.book_id
    else
        -- Calculate hash for new book
        file_hash = self:calculateBookHash(file_path)
        if file_hash then
            -- Try to get book_id from server
            book_id = self:getBookIdByHash(file_hash)
            -- Cache for future use
            self.db:cacheBook(file_path, file_hash, book_id)
        end
    end
    
    -- Track session with available data
    self.current_session = {
        file_hash = file_hash,
        book_id = book_id,
        ...
    }
end
```

### Pending Session Sync (`main.lua:1021-1037`)
```lua
-- For sessions without book_id, try to resolve
if not session.bookId and session.bookHash then
    local cached_book = self.db:getBookByHash(session.bookHash)
    if cached_book and cached_book.book_id then
        session.bookId = cached_book.book_id
    else
        -- Try server lookup
        local success, book_data = self.api:getBookByHash(session.bookHash)
        if success and book_data and book_data.id then
            session.bookId = book_data.id
            self.db:updateBookId(session.bookHash, book_data.id)
        end
    end
end
```

## Testing Checklist

- [ ] Hash calculation for EPUB files
- [ ] Hash calculation for PDF files
- [ ] Hash calculation for very small files (<1KB)
- [ ] Hash calculation for very large files (>100MB)
- [ ] Cache hit on second open
- [ ] Server lookup when not in cache
- [ ] Offline behavior (hash calculated, book_id NULL)
- [ ] Session sync with hash resolution
- [ ] File moved/renamed (new path, same hash)
- [ ] Error handling (file not readable)

## Compatibility

This implementation is compatible with:
- **Booklore Server**: Uses same FileFingerprint algorithm
- **Old Plugin**: Migrates existing hash cache from LuaSettings
- **Cross-platform**: Works on Linux, Android, and other KOReader platforms

## References

- Old plugin implementation: `old/main.lua:738-782`
- Server-side algorithm: Booklore FileFingerprint class
- KOReader FFI sha2 module: `require("ffi/sha2").md5`
