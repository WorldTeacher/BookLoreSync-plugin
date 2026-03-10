+++
title = "API Endpoints"
description = "All BookLore API endpoints used by the plugin, with authentication details."
weight = 2
+++

# API Endpoints

This page documents every API endpoint the plugin communicates with, along with the authentication mechanism and request format used for each.

---

## Authentication mechanisms

The plugin uses two authentication methods depending on the endpoint:

### MD5 credentials (legacy KOReader API)

Used for the original KOReader sync endpoints. Credentials are sent as HTTP headers:

```
x-auth-user: <username>
x-auth-key: <md5(password)>
```

### Bearer token (JWT)

Used for the v1 REST API endpoints. The token is obtained once and cached:

```
Authorization: Bearer <jwt_token>
```

The token is fetched from `POST /api/v1/auth/login` and automatically refreshed when it is within 24 hours of expiry.

---

## Authentication endpoints

### `GET /api/koreader/users/auth`

Validates the KOReader (MD5) credentials.

**Authentication:** MD5 credentials (headers)

**Successful response:** HTTP 200 with user information.

Used by **Test Connection**.

---

### `POST /api/v1/auth/login`

Obtains a Bearer token (JWT) for the BookLore account.

**Authentication:** None (credentials in request body)

**Request body:**
```json
{
  "username": "your_username",
  "password": "your_password"
}
```

**Successful response:**
```json
{
  "accessToken": "<jwt_string>",
  "refreshToken": "<refresh_token_string>"
}
```

The `accessToken` is cached in the `bearer_tokens` table with a 28-day local TTL. The plugin proactively refreshes the token when it is within 24 hours of that expiry.

---

## Book endpoints

### `GET /api/koreader/books/by-hash/:hash`

Looks up a book by its MD5 file fingerprint.

**Authentication:** MD5 credentials (headers)

**Path parameter:** `:hash` - the MD5 fingerprint of the book file.

**Successful response:**
```json
{
  "id": 42,
  "title": "Book Title",
  "authors": "Author Name"
}
```

Used when opening a book to resolve the BookLore book ID. Result is cached in `book_cache`.

---

### `GET /api/v1/books/by-hash/:hash`

Alternative book lookup using Bearer token authentication.

**Authentication:** Bearer token

**Path parameter:** `:hash` - the MD5 fingerprint of the book file.

Used for extended sync features.

---

### `GET /api/v1/books/search?title=<title>`

Searches for a book by title.

**Authentication:** Bearer token

Used as a fallback for book lookup when hash lookup fails, and during manual/import-history matching flows.

---

### `GET /api/v1/books/search?isbn=<isbn>`

Searches for a book by ISBN.

**Authentication:** Bearer token

**Query parameter:** `isbn` - an ISBN-10 or ISBN-13 value. If both are embedded in the file, ISBN-13 is preferred.

**When it is called:** Automatically at book-open time, as a fallback when `GET /api/koreader/books/by-hash/:hash` returns no match and the device has a network connection.

**Match requirement:** The plugin inspects each result for a `matchScore` field and only accepts a result where `matchScore == 1` (exact match). If no result meets this threshold, the lookup is treated as failed and the user is shown a notification. This prevents a low-confidence ISBN hit from being silently associated with the wrong book.

**On success:** The resolved book ID is written to the local `book_cache` table and used for all subsequent sessions with that file.

**On failure:** No book ID is cached from this call. The session is still saved locally and the book ID will need to be resolved through another means (hash lookup on a future open, or manual matching).

---

### `GET /api/v1/books/<id>`

Fetches full metadata for a single book by its BookLore ID.

**Authentication:** Bearer token

**Path parameter:** `<id>` - the BookLore book ID (integer).

**Successful response:**
```json
{
  "id": 42,
  "title": "Book Title",
  "isbn10": "0123456789",
  "isbn13": "9780123456789",
  "hardcover_id": 12345
}
```

Used when resolving a book by numeric ID during manual matching, and when fetching Hardcover IDs for matched books.

---

## Reading session endpoints

### `POST /api/v1/reading-sessions`

Uploads a single reading session.

**Authentication:** MD5 credentials (headers)

**Request body:**
```json
{
  "bookId": 42,
  "bookType": "EPUB",
  "startTime": "2026-02-22T14:00:00Z",
  "endTime": "2026-02-22T15:00:00Z",
  "durationSeconds": 3600,
  "durationFormatted": "1:00:00",
  "startProgress": 25.50,
  "endProgress": 38.75,
  "progressDelta": 13.25,
  "startLocation": 120,
  "endLocation": 185
}
```

Used as the fallback when the batch endpoint is not available or returns an error.

---

### `POST /api/v1/reading-sessions/batch`

Uploads up to 100 reading sessions in a single request.

**Authentication:** MD5 credentials (headers)

**Request body:**
```json
{
  "bookId": 42,
  "bookType": "EPUB",
  "sessions": [
    { "...session object..." },
    { "...session object..." }
  ]
}
```

This is the primary upload endpoint. The plugin falls back to the single-session endpoint if this returns a non-2xx response (including `403 Forbidden` from older server versions).

---

## Rating endpoint

### `PUT /api/v1/books/personal-rating`

Sets the personal rating for one or more books.

**Authentication:** Bearer token

**Request body:**
```json
{
  "ids": [42],
  "rating": 8
}
```

The `rating` value is on a 1–10 scale.

---

## Annotation endpoints

### `POST /api/v1/annotations`

Creates an in-book annotation (highlight with optional note) attached to an EPUB CFI position.

**Authentication:** Bearer token

**Request body:**
```json
{
  "bookId": 42,
  "cfi": "epubcfi(/6/4[chap01]!/4/2/1:0)",
  "text": "The highlighted passage text",
  "note": "My note on this passage",
  "color": "#FFC107",
  "style": "highlight",
  "chapterTitle": "Chapter 1"
}
```

`note`, `color`, `style`, and `chapterTitle` are optional.

Used for the "In book" notes destination mode.

---

### `POST /api/v2/book-notes`

Creates an in-book note with a position reference.

**Authentication:** Bearer token

**Request body:**
```json
{
  "bookId": 42,
  "cfi": "epubcfi(/6/4[chap01]!/4/2/1:0)",
  "noteContent": "Note text",
  "selectedText": "The passage the note is attached to",
  "color": "#FFC107",
  "chapterTitle": "Chapter 1"
}
```

`selectedText`, `color`, and `chapterTitle` are optional.

Used for the "In book" notes destination mode.

---

### `POST /api/v1/book-notes`

Creates a standalone book note visible on the BookLore book detail page.

**Authentication:** Bearer token

**Request body:**
```json
{
  "bookId": 42,
  "title": "Chapter 3: The Beginning",
  "content": "My note content"
}
```

Used for the "In BookLore" notes destination mode.

---

## Bookmark endpoint

### `POST /api/v1/bookmarks`

Creates a bookmark at a specific EPUB CFI position.

**Authentication:** Bearer token

**Request body:**
```json
{
  "bookId": 42,
  "cfi": "epubcfi(/6/4[chap01]!/4/2/1:0)",
  "title": "Optional bookmark label"
}
```

`title` is optional.

---

## Shelf endpoint

### `POST /api/v1/books/shelves`

Assigns or unassigns one or more books to/from shelves.

**Authentication:** Bearer token

**Request body:**
```json
{
  "bookIds": [42],
  "shelvesToAssign": [],
  "shelvesToUnassign": [7]
}
```

Used when a book file is deleted from the device to unassign it from the KOReader shelf. Also used during shelf sync to assign downloaded books to the configured shelf.

---

## HTTP details

- **Timeout:** 10 seconds per request.
- **Redirects:** HTTP redirects (301, 302) are followed manually, as KOReader's HTTP client does not follow them automatically.
- **HTTPS:** Fully supported.
- **JSON:** All request bodies are encoded with `cjson`. All responses are decoded with `cjson`.
