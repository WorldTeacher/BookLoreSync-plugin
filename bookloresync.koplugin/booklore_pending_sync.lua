local M = {}

function M.new(deps)
    local _ = deps._
    local T = deps.T
    local json = deps.json
    local UIManager = deps.UIManager
    local InfoMessage = deps.InfoMessage
    local Device = deps.Device

    local module = {}

    function module.syncPendingBookmarks(self, silent, book_cache_id)
    silent = silent or false
    local pending = self.db:getPendingBookmarks()
    if not pending or #pending == 0 then return 0, 0 end
    if book_cache_id then
        local filtered = {}
        for _, row in ipairs(pending) do
            if row.book_cache_id == book_cache_id then
                filtered[#filtered + 1] = row
            end
        end
        pending = filtered
    end
    if #pending == 0 then return 0, 0 end

    local synced_count = 0
    local failed_count = 0

    for _, row in ipairs(pending) do
        local ok_dec, payload = pcall(function() return json.decode(row.payload) end)
        if not ok_dec or not payload then
            self:logWarn("BookloreSync: Cannot decode pending bookmark payload, skipping id:", row.id)
            self.db:incrementBookmarkRetry(row.id)
            failed_count = failed_count + 1
            goto pb_continue
        end

        local cfi = payload.cfi
        if not cfi then
            self:logInfo("BookloreSync: Pending bookmark has no CFI, skipping id:", row.id)
            self.db:incrementBookmarkRetry(row.id)
            failed_count = failed_count + 1
            goto pb_continue
        end

        local book_id = row.book_id
        if not book_id then
            -- Try to resolve book_id from cache
            local cached_id = self.db:getBookIdByBookCacheId(row.book_cache_id)
            if cached_id then
                book_id = cached_id
            else
                self:logInfo("BookloreSync: No book_id for pending bookmark id:", row.id, "- deferring")
                goto pb_continue
            end
        end

        local ok, server_id = self.api:submitBookmark(
            book_id, cfi,
            { title = payload.chapter },
            self.booklore_username, self.booklore_password
        )

        if ok then
            self.db:markBookmarkSynced(row.book_cache_id, row.datetime, server_id)
            self.db:deletePendingBookmark(row.id)
            synced_count = synced_count + 1
        elseif type(server_id) == "string" and server_id:lower():find("already exists") then
            -- Server reports a duplicate - treat as success so the item is
            -- not retried indefinitely.
            self.db:markBookmarkSynced(row.book_cache_id, row.datetime, nil)
            self.db:deletePendingBookmark(row.id)
            synced_count = synced_count + 1
            self:logInfo("BookloreSync: Pending bookmark already on server, marking synced (id:", row.id, ")")
        else
            self.db:incrementBookmarkRetry(row.id)
            failed_count = failed_count + 1
        end

        ::pb_continue::
    end

    self:logInfo(string.format(
        "BookloreSync: Pending bookmark retry complete - synced=%d failed=%d",
        synced_count, failed_count
    ))
    return synced_count, failed_count
    end

function module.syncPendingDeletions(self, silent)
    silent = silent or false

    if not self.db then return 0, 0 end

    if self.booklore_sync_source_type == "magic" then
        local deletions = self.db:getPendingDeletions()
        if deletions and #deletions > 0 then
            self:logInfo("BookloreSync: syncPendingDeletions - clearing", #deletions, "queued deletion(s) for magic shelf source")
            for _, deletion in ipairs(deletions) do
                self.db:removePendingDeletion(deletion.id)
            end
            return #deletions, 0
        end
        return 0, 0
    end

    local deletions = self.db:getPendingDeletions()
    if not deletions or #deletions == 0 then return 0, 0 end

    self:logInfo("BookloreSync: syncPendingDeletions - retrying", #deletions, "queued deletion(s)")

    local synced_count = 0
    local failed_count = 0

    -- Cache token once for the whole batch
    local token_ok, token = self.api:getOrRefreshBearerToken(self.booklore_username, self.booklore_password, false)

    for _, deletion in ipairs(deletions) do
        -- Drop stale entries that have exceeded the retry limit
        if deletion.retry_count > 10 then
            self:logWarn("BookloreSync: syncPendingDeletions - dropping stale deletion (>10 retries), hash:", deletion.file_hash)
            self.db:removePendingDeletion(deletion.id)
            goto del_continue
        end

        local book_id = deletion.book_id
        if not book_id and deletion.file_hash then
            local ok_bh, book_data = self.api:getBookByHash(deletion.file_hash)
            if ok_bh and book_data and book_data.id then
                book_id = tonumber(book_data.id)
            end
        end

        if not book_id then
            -- Can't find the book - nothing to remove; silently discard
            self:logInfo("BookloreSync: syncPendingDeletions - book_id unknown, discarding deletion id:", deletion.id)
            self.db:removePendingDeletion(deletion.id)
            synced_count = synced_count + 1
            goto del_continue
        end

        if not token_ok then
            self:logWarn("BookloreSync: syncPendingDeletions - no auth token, skipping")
            self.db:incrementDeletionRetry(deletion.id)
            failed_count = failed_count + 1
            goto del_continue
        end

        local shelf_id = tonumber(self.booklore_source_shelf_id) or self.shelf_id
        if not shelf_id then
            self:logWarn("BookloreSync: syncPendingDeletions - no shelf_id configured, cannot unassign book, skipping")
            self.db:incrementDeletionRetry(deletion.id)
            failed_count = failed_count + 1
            goto del_continue
        end

        local headers = {
            ["Authorization"] = "Bearer " .. token,
            ["Content-Type"]  = "application/json",
        }
        local body = {
            bookIds           = json.util.InitArray({ book_id }),
            shelvesToAssign   = json.util.InitArray({}),
            shelvesToUnassign = json.util.InitArray({ shelf_id }),
        }
        local ok, code, _ = self.api:request("POST", "/api/v1/books/shelves", body, headers)
        if ok or code == 200 then
            self.db:removePendingDeletion(deletion.id)
            synced_count = synced_count + 1
        else
            self.db:incrementDeletionRetry(deletion.id)
            failed_count = failed_count + 1
        end

        ::del_continue::
    end

    self:logInfo(string.format(
        "BookloreSync: syncPendingDeletions complete - synced=%d failed=%d",
        synced_count, failed_count
    ))
    return synced_count, failed_count
    end

    function module.syncPendingRatings(self, silent)
    silent = silent or false

    if not self.db then
        self:logErr("BookloreSync: syncPendingRatings - database not initialised")
        return 0, 0
    end

    -- Respect the user's rating-sync toggle: if they disabled rating sync
    -- after queueing ratings, do not submit anything.
    if not self.rating_sync_enabled then
        self:logInfo("BookloreSync: Rating sync disabled - skipping pending ratings")
        return 0, 0
    end

    -- ── Phase 1: deferred rating prompts ─────────────────────────────────
    -- These are books that were completed while the book_id was unknown.
    -- Now that the cache may have been updated, check if a book_id exists.
    local deferred = self.db:getBooksPendingRatingPrompt()
    if #deferred > 0 then
        self:logInfo("BookloreSync: Processing", #deferred, "deferred rating prompt(s)")
        local mode = self.rating_sync_mode or "koreader_scaled"
        for _, row in ipairs(deferred) do
            self:logInfo("BookloreSync: Deferred rating prompt - book_id:", row.book_id,
                         "file:", row.file_path)
            if mode == "koreader_scaled" then
                -- Push the KOReader star rating silently now that we have a book_id.
                -- syncKOReaderRating will either sync successfully, queue the rating
                -- in pending_ratings on failure, or return early (no rating set /
                -- already synced / no credentials).  Only clear the deferred flag
                -- if we actually had credentials to attempt the call - otherwise
                -- leave the flag so the next sync retries.
                if self.booklore_username ~= "" and self.booklore_password ~= "" then
                    self:syncKOReaderRating(row.file_path, row.book_id)
                    -- Flag cleared below: rating was either sent or queued for retry
                    -- in pending_ratings, so the deferred-prompt entry is no longer needed.
                    self.db:setPendingRatingPrompt(row.book_cache_id, false)
                else
                    self:logWarn("BookloreSync: Deferred rating skipped - Booklore credentials not configured")
                    -- Leave flag set; will retry on the next sync once credentials are added.
                end
            elseif mode == "select_at_complete" then
                -- If the user already submitted a rating via the immediate dialog
                -- (shown at book-close time), it is now sitting in pending_ratings
                -- with a nil book_id.  Now that we have the real book_id, update
                -- the pending row so Phase 2 can upload it without re-prompting.
                local meta = self.db:getBookMetadata(row.book_cache_id)
                if meta and meta.rating then
                    -- Rating already captured - just stamp the resolved book_id
                    -- onto the pending_ratings row and clear the deferred flag.
                    self.db:addPendingRating(row.book_cache_id, row.book_id, meta.rating)
                    self.db:setPendingRatingPrompt(row.book_cache_id, false)
                    self:logInfo("BookloreSync: Stamped book_id", row.book_id,
                                 "onto pending rating for book_cache_id:", row.book_cache_id)
                else
                    -- No rating stored yet - show the dialog now that we have a book_id.
                    -- Clear the flag before scheduling so the dialog is not re-shown
                    -- on subsequent syncs.
                    local file_path = row.file_path
                    local book_id   = row.book_id
                    self.db:setPendingRatingPrompt(row.book_cache_id, false)
                    UIManager:scheduleIn(2, function()
                        self:showRatingDialog(file_path, book_id)
                    end)
                end
            end
        end
    end

    -- ── Phase 2: retry previously-failed rating submissions ──────────────
    local pending = self.db:getPendingRatings()
    if #pending == 0 then
        self:logInfo("BookloreSync: No pending ratings to sync")
        return 0, 0
    end

    self:logInfo("BookloreSync: Retrying", #pending, "pending rating(s)")

    self:refreshEffectiveServerUrl()
    self.api:init(self.server_url, self.username, self.password, self.db)

    local synced_count = 0
    local failed_count = 0

    for _, row in ipairs(pending) do
        self:logInfo("BookloreSync: Submitting pending rating - book_id:", row.book_id,
                     "rating:", row.rating, "(retry #" .. (row.retry_count + 1) .. ")")

        -- Per-book tracking check: skip this rating if the user has disabled
        -- tracking for the book.  We look up the cache row to get the file_path
        -- (same lookup used below to resolve a missing book_id, so the extra
        -- cost is only incurred for the books that still lack a book_id).
        do
            local bc = self.db:getBookCacheById(row.book_cache_id)
            local fp = bc and bc.file_path or nil
            if fp and not self.db:isBookTrackingEnabled(fp) then
                self:logInfo("BookloreSync: Tracking disabled for book, skipping pending rating id:", row.id)
                goto continue_rating
            end
        end

        -- Resolve book_id if it was nil when the rating was first queued.
        local book_id = row.book_id
        if not book_id then
            local bc = self.db:getBookCacheById(row.book_cache_id)
            book_id = bc and bc.book_id or nil
            if not book_id then
                self:logInfo("BookloreSync: book_id still unknown for pending rating id:", row.id, "- will retry later")
                goto continue_rating
            end
            self:logInfo("BookloreSync: Resolved book_id", book_id, "for pending rating id:", row.id)
        end

        local ok, err = self.api:submitRating(
            book_id, row.rating,
            self.booklore_username, self.booklore_password
        )

        if ok then
            synced_count = synced_count + 1
            -- Mark rating as synced in book_metadata and record the outcome
            self.db:upsertBookMetadata(row.book_cache_id, { rating = row.rating, rating_synced = true })
            self.db:recordRatingSyncHistory(row.book_cache_id, row.rating, "success")
            -- Remove from the pending queue
            self.db:deletePendingRating(row.id)
            self:logInfo("BookloreSync: Pending rating synced successfully (id:", row.id, ")")
        else
            failed_count = failed_count + 1
            self:logWarn("BookloreSync: Pending rating sync failed (id:", row.id, "):", err)
            self.db:recordRatingSyncHistory(row.book_cache_id, row.rating, "error", err)
            self.db:incrementPendingRatingRetryCount(row.id)
        end

        ::continue_rating::
    end

    self:logInfo("BookloreSync: Pending ratings sync complete - synced:", synced_count, "failed:", failed_count)
    return synced_count, failed_count
    end

    function module.syncPendingAnnotations(self, silent, book_cache_id)
    silent = silent or false

    if not self.db then
        self:logErr("BookloreSync: syncPendingAnnotations - database not initialised")
        return 0, 0
    end

    if not self.highlights_notes_sync_enabled then
        self:logInfo("BookloreSync: Annotation sync disabled - skipping pending annotations")
        return 0, 0
    end

    if self.booklore_username == "" or self.booklore_password == "" then
        self:logInfo("BookloreSync: Pending annotations skipped - Booklore credentials not configured")
        return 0, 0
    end

    local pending = self.db:getPendingAnnotations()
    if book_cache_id then
        local filtered = {}
        for _, row in ipairs(pending) do
            if row.book_cache_id == book_cache_id then
                filtered[#filtered + 1] = row
            end
        end
        pending = filtered
    end
    if #pending == 0 then
        self:logInfo("BookloreSync: No pending annotations to sync")
        return 0, 0
    end

    self:logInfo("BookloreSync: Retrying", #pending, "pending annotation(s)")

    self:refreshEffectiveServerUrl()
    self.api:init(self.server_url, self.username, self.password, self.db)

    local synced_count = 0
    local failed_count = 0
    local skipped_count = 0

    for _, row in ipairs(pending) do
        self:logInfo("BookloreSync: Retrying pending annotation - id:", row.id,
                     "type:", row.ann_type, "datetime:", row.datetime,
                     "(retry #" .. (row.retry_count + 1) .. ")")

        -- Per-book tracking check: skip this annotation if the user has
        -- disabled tracking for the book (same pattern as sessions/ratings).
        do
            local bc = self.db:getBookCacheById(row.book_cache_id)
            local fp = bc and bc.file_path or nil
            if fp and not self.db:isBookTrackingEnabled(fp) then
                self:logInfo("BookloreSync: Tracking disabled for book, skipping pending annotation id:", row.id)
                skipped_count = skipped_count + 1
                goto continue_ann
            end
        end

        local ok_dec, payload = pcall(json.decode, row.payload)
        if not ok_dec or type(payload) ~= "table" then
            self:logErr("BookloreSync: Failed to decode pending annotation payload (id:", row.id, ") - removing")
            self.db:deletePendingAnnotation(row.id)
            goto continue_ann
        end

        local book_id = row.book_id
        if not book_id then
            local bc = self.db:getBookCacheById(row.book_cache_id)
            book_id = bc and bc.book_id or nil
            if not book_id then
                self:logInfo("BookloreSync: book_id still unknown for pending annotation id:", row.id, "- will retry later")
                skipped_count = skipped_count + 1
                goto continue_ann
            end
            self:logInfo("BookloreSync: Resolved book_id", book_id, "for pending annotation id:", row.id)
        end

        local ok, server_id

        if row.ann_type == "highlight" then
            -- Highlights require a CFI.  Without an open document we cannot
            -- recompute it from pos0/pos1, so skip if the payload has no cfi.
            -- (When the book is opened next time syncHighlightsAndNotes will
            -- pick it up fresh and the pending row will be superseded.)
            local cfi = payload.cfi
            if not cfi or cfi == "" then
                self:logInfo("BookloreSync: Skipping pending highlight (no CFI available) - id:", row.id)
                skipped_count = skipped_count + 1
                goto continue_ann
            end
            ok, server_id = self.api:submitHighlight(
                book_id, cfi, payload.text,
                {
                    color         = payload.color,
                    style         = payload.style,
                    chapter_title = payload.chapter,
                },
                self.booklore_username, self.booklore_password
            )

        elseif row.ann_type == "in_book_note" then
            local cfi = payload.cfi
            if not cfi or cfi == "" then
                self:logInfo("BookloreSync: Skipping pending in-book note (no CFI available) - id:", row.id)
                skipped_count = skipped_count + 1
                goto continue_ann
            end
            ok, server_id = self.api:submitInBookNote(
                book_id, cfi, payload.note,
                {
                    selected_text = payload.text,
                    color         = payload.color,
                    chapter_title = payload.chapter,
                },
                self.booklore_username, self.booklore_password
            )

        elseif row.ann_type == "booklore_note" then
            ok, server_id = self.api:submitBookloreNote(
                book_id, payload.note, payload.chapter,
                self.booklore_username, self.booklore_password
            )

        elseif row.ann_type == "both_note" then
            -- Submit as both an in-book note (CFI required) and a Booklore
            -- web-UI note.  Treat as success only when all required
            -- destinations succeed.
            local in_book_ok, in_book_id
            local bl_ok,      bl_id
            local cfi = payload.cfi
            local requires_in_book = cfi and cfi ~= ""
            if requires_in_book then
                in_book_ok, in_book_id = self.api:submitInBookNote(
                    book_id, cfi, payload.note,
                    {
                        selected_text = payload.text,
                        color         = payload.color,
                        chapter_title = payload.chapter,
                    },
                    self.booklore_username, self.booklore_password
                )
                if not in_book_ok then
                    self:logWarn("BookloreSync: 'Both' retry - in-book note failed:", in_book_id)
                end
            else
                self:logInfo("BookloreSync: 'Both' retry - no CFI, skipping in-book note (id:", row.id, ")")
            end
            bl_ok, bl_id = self.api:submitBookloreNote(
                book_id, payload.note, payload.chapter,
                self.booklore_username, self.booklore_password
            )
            if not bl_ok then
                self:logWarn("BookloreSync: 'Both' retry - Booklore note failed:", bl_id)
            end
            ok        = (requires_in_book and in_book_ok and bl_ok) or ((not requires_in_book) and bl_ok) or false
            server_id = in_book_id or bl_id

        else
            self:logWarn("BookloreSync: Unknown ann_type in pending_annotations (id:", row.id, "):", row.ann_type, "- removing")
            self.db:deletePendingAnnotation(row.id)
            goto continue_ann
        end

        if ok then
            synced_count = synced_count + 1
            -- Record as synced so syncHighlightsAndNotes skips it in future
            self.db:markAnnotationSynced(row.book_cache_id, row.datetime, row.ann_type, server_id)
            self.db:deletePendingAnnotation(row.id)
            self:logInfo("BookloreSync: Pending annotation synced (id:", row.id, ")")
        elseif type(server_id) == "string" and server_id:lower():find("already exists") then
            -- Server reports a duplicate - treat as success so the item is
            -- not retried indefinitely.
            synced_count = synced_count + 1
            self.db:markAnnotationSynced(row.book_cache_id, row.datetime, row.ann_type, nil)
            self.db:deletePendingAnnotation(row.id)
            self:logInfo("BookloreSync: Pending annotation already on server, marking synced (id:", row.id, ")")
        else
            failed_count = failed_count + 1
            self:logWarn("BookloreSync: Pending annotation retry failed (id:", row.id, "):", server_id)
            self.db:incrementPendingAnnotationRetryCount(row.id)
        end

        ::continue_ann::
    end

    self:logInfo("BookloreSync: Pending annotations sync complete - synced:", synced_count, "failed:", failed_count, "skipped:", skipped_count)
    return synced_count, failed_count, skipped_count
    end

    function module.syncPendingKoreaderProgress(self, silent, max_rows)
    silent = silent or false
    max_rows = tonumber(max_rows) or 0

    if not self.db then
        return 0, 0
    end

    local rows = self.db:getPendingKoreaderProgress()
    if not rows or #rows == 0 then
        return 0, 0
    end

    local synced_count = 0
    local failed_count = 0

    local processed = 0
    for _, row in ipairs(rows) do
        if max_rows > 0 and processed >= max_rows then
            break
        end
        processed = processed + 1
        local payload = {
            timestamp = tonumber(row.timestamp) or os.time(),
            document = tostring(row.book_hash),
            percentage = self:roundKoreaderSyncPercentage(tonumber(row.percentage) or 0),
            progress = tostring(row.progress or row.location or "0"),
            device = tostring(row.device or (Device and Device.model) or "KOReader"),
            device_id = tostring(row.device_id or self.progress_sync_device_id or "unknown"),
        }

        local ok, body_or_err = self.api:updateKoReaderProgress(payload)
        if ok then
            synced_count = synced_count + 1
            self.db:markKoreaderProgressSynced({
                book_cache_id = row.book_cache_id,
                book_hash = row.book_hash,
                progress = payload.progress,
                percentage = payload.percentage,
                location = tostring(row.location or row.progress or payload.progress),
                remote_device = payload.device,
                remote_device_id = payload.device_id,
                remote_timestamp = payload.timestamp,
            })
            self.db:deletePendingKoreaderProgress(row.id)
        else
            failed_count = failed_count + 1
            self.db:incrementPendingKoreaderProgressRetry(row.id)
            self:logWarn("BookloreSync: Failed to sync pending progress for hash:", tostring(row.book_hash), tostring(body_or_err))
        end
    end

    if not silent and (synced_count > 0 or failed_count > 0) then
        if failed_count > 0 then
            UIManager:show(InfoMessage:new{
                text = T(_("Progress: %1 synced, %2 failed"), synced_count, failed_count),
                timeout = 2,
            })
        else
            UIManager:show(InfoMessage:new{
                text = T(_("Progress: %1 synced"), synced_count),
                timeout = 2,
            })
        end
    end

    return synced_count, failed_count
    end

    function module.syncPendingSessions(self, silent)
    silent = silent or false

    if not self.db then
        self:logErr("BookloreSync: Database not initialized")
        if not silent then
            UIManager:show(InfoMessage:new{
                text = _("Database not initialized"),
                timeout = 2,
            })
        end
        return
    end

    local network_ok = self:isNetworkConnected()
    self:refreshEffectiveServerUrl()
    self.api:init(self.server_url, self.username, self.password, self.db)

    -- ── Phase 0: Resolve all book_ids ─────────────────────────────────────
    -- Iterate every pending session that is missing a book_id and attempt to
    -- resolve it via the cache then the server.  We do this BEFORE running
    -- syncPendingRatings / syncPendingAnnotations so that those two passes
    -- see a warm cache and can resolve their own book_cache lookups on the
    -- first try, rather than needing a separate sync cycle.
    --
    -- When a book_id is resolved, it is written back to the pending_sessions
    -- row so subsequent sync cycles do not re-resolve the same hash.
    --
    -- Sessions that still cannot be resolved after this phase are skipped in
    -- Phase 3 (retry count incremented).  Ratings and annotations for those
    -- books are also skipped by their respective functions (they do the same
    -- getBookCacheById lookup and bail when book_id is still nil).
    local sessions = self.db:getPendingSessions(100)
    local resolved_count = 0

    for _, session in ipairs(sessions) do
        if session.bookHash and not session.bookId then
            self:logInfo("BookloreSync: Phase 0 - resolving book_id for hash:", session.bookHash)
            -- 1. Check DB cache (may have been populated by onCloseDocument)
            local cached = self.db:getBookByHash(session.bookHash)
            if cached and cached.book_id then
                session.bookId = tonumber(cached.book_id)
                -- Write back so future sync cycles skip re-resolution.
                self.db:updatePendingSessionBookId(session.id, session.bookId)
                self:logInfo("BookloreSync: Phase 0 - resolved from cache:", session.bookId)
                resolved_count = resolved_count + 1
            elseif network_ok then
                -- 2. Ask the server (only when online)
                local ok_bh, book_data = self.api:getBookByHash(session.bookHash)
                if ok_bh and book_data and book_data.id then
                    local book_id = tonumber(book_data.id)
                    if book_id then
                        session.bookId = book_id
                        -- Warm the book-cache and fix the pending_sessions row.
                        self.db:updateBookId(session.bookHash, book_id)
                        self.db:updatePendingSessionBookId(session.id, book_id)
                        self:logInfo("BookloreSync: Phase 0 - resolved from server:", book_id)
                        resolved_count = resolved_count + 1
                    else
                        self:logWarn("BookloreSync: Phase 0 - server returned invalid book_id for hash:", session.bookHash)
                    end
                else
                    self:logWarn("BookloreSync: Phase 0 - book not found on server for hash:", session.bookHash, "- will retry later")
                end
            else
                self:logInfo("BookloreSync: Phase 0 - offline, skipping server lookup for hash:", session.bookHash)
            end
        end
    end

    if resolved_count > 0 then
        self:logInfo("BookloreSync: Phase 0 complete - resolved", resolved_count, "book_id(s)")
    end

    -- ── Phase 1: Ratings ──────────────────────────────────────────────────
    -- Cache is now warm from Phase 0; pending_ratings rows that had nil
    -- book_ids will find their values via getBookCacheById.
    local pending_ratings_count = tonumber(self.db:getPendingRatingCount()) or 0
    local ratings_synced, ratings_failed = 0, 0
    if pending_ratings_count > 0 then
        ratings_synced, ratings_failed = self:syncPendingRatings(true)
        ratings_synced = tonumber(ratings_synced) or 0
        ratings_failed = tonumber(ratings_failed) or 0
    else
        self:logInfo("BookloreSync: No-op skipped", "component=syncPendingRatings", "reason=no_pending_ratings")
    end

    -- ── Phase 2: Annotations ──────────────────────────────────────────────
    -- Same warm-cache benefit as Phase 1.
    local pending_annotations_count = tonumber(self.db:getPendingAnnotationCount()) or 0
    local ann_synced, ann_failed, ann_skipped = 0, 0, 0
    if pending_annotations_count > 0 then
        ann_synced, ann_failed, ann_skipped = self:syncPendingAnnotations(true)
        ann_synced  = tonumber(ann_synced)  or 0
        ann_failed  = tonumber(ann_failed)  or 0
        ann_skipped = tonumber(ann_skipped) or 0
    else
        self:logInfo("BookloreSync: No-op skipped", "component=syncPendingAnnotations", "reason=no_pending_annotations")
    end

    -- ── Phase 2b: Bookmarks ───────────────────────────────────────────────
    local pending_bookmarks_count = tonumber(self.db:getPendingBookmarkCount()) or 0
    local bm_synced, bm_failed = 0, 0
    if pending_bookmarks_count > 0 then
        bm_synced, bm_failed = self:syncPendingBookmarks(true)
        bm_synced = tonumber(bm_synced) or 0
        bm_failed = tonumber(bm_failed) or 0
    else
        self:logInfo("BookloreSync: No-op skipped", "component=syncPendingBookmarks", "reason=no_pending_bookmarks")
    end

    -- ── Phase 2c: KOReader Progress ───────────────────────────────────────
    local pending_progress_count = tonumber(self.db:getPendingKoreaderProgressCount()) or 0
    local prog_synced, prog_failed = 0, 0
    if pending_progress_count > 0 then
        prog_synced, prog_failed = self:syncPendingKoreaderProgress(true)
        prog_synced = tonumber(prog_synced) or 0
        prog_failed = tonumber(prog_failed) or 0
    else
        self:logInfo("BookloreSync: No-op skipped", "component=syncPendingKoreaderProgress", "reason=no_pending_progress")
    end

    -- ── Phase 2d: Deletions ───────────────────────────────────────────────
    local pending_deletions_count = 0
    if type(self.db.getPendingDeletionCount) == "function" then
        pending_deletions_count = tonumber(self.db:getPendingDeletionCount()) or 0
    elseif type(self.db.getPendingDeletions) == "function" then
        local ok_del, del_rows = pcall(self.db.getPendingDeletions, self.db)
        if ok_del and type(del_rows) == "table" then
            pending_deletions_count = #del_rows
        end
    end
    local del_synced, del_failed = 0, 0
    if pending_deletions_count > 0 then
        del_synced, del_failed = self:syncPendingDeletions(true)
        del_synced = tonumber(del_synced) or 0
        del_failed = tonumber(del_failed) or 0
    else
        self:logInfo("BookloreSync: No-op skipped", "component=syncPendingDeletions", "reason=no_pending_deletions")
    end

    -- ── Phase 3: Sessions ─────────────────────────────────────────────────
    local pending_count = self.db:getPendingSessionCount()
    pending_count = tonumber(pending_count) or 0

    if pending_count == 0 then
        self:logInfo("BookloreSync: No pending sessions to sync")
        if not silent then
            local parts = {}
            parts[#parts + 1] = _("S: none pending")
            if ratings_synced + ratings_failed > 0 then
                if ratings_failed > 0 then
                    parts[#parts + 1] = T(_("R: %1 synced, %2 failed"), ratings_synced, ratings_failed)
                else
                    parts[#parts + 1] = T(_("R: %1 synced"), ratings_synced)
                end
            end
            if ann_synced + ann_failed + ann_skipped > 0 then
                if ann_failed > 0 and ann_skipped > 0 then
                    parts[#parts + 1] = T(_("A: %1 synced, %2 failed, %3 skipped"), ann_synced, ann_failed, ann_skipped)
                elseif ann_failed > 0 then
                    parts[#parts + 1] = T(_("A: %1 synced, %2 failed"), ann_synced, ann_failed)
                elseif ann_skipped > 0 then
                    parts[#parts + 1] = T(_("A: %1 synced, %2 skipped"), ann_synced, ann_skipped)
                else
                    parts[#parts + 1] = T(_("A: %1 synced"), ann_synced)
                end
            end
            if bm_synced + bm_failed > 0 then
                if bm_failed > 0 then
                    parts[#parts + 1] = T(_("B: %1 synced, %2 failed"), bm_synced, bm_failed)
                else
                    parts[#parts + 1] = T(_("B: %1 synced"), bm_synced)
                end
            end
            if prog_synced + prog_failed > 0 then
                if prog_failed > 0 then
                    parts[#parts + 1] = T(_("P: %1 synced, %2 failed"), prog_synced, prog_failed)
                else
                    parts[#parts + 1] = T(_("P: %1 synced"), prog_synced)
                end
            end
            local msg = #parts > 0 and table.concat(parts, "\n") or _("No pending items to sync")
            UIManager:show(InfoMessage:new{
                text = msg,
                timeout = 2,
            })
        end
        return
    end

    self:logInfo("BookloreSync: Phase 3 - submitting", pending_count, "pending session(s)")

    local synced_count = 0
    local failed_count = 0

    for i, session in ipairs(sessions) do
        self:logInfo("BookloreSync: Processing pending session", i, "of", #sessions)

        if not session.bookId then
            self:logWarn("BookloreSync: Session", i, "has no book_id after Phase 0 - skipping")
            self.db:incrementSessionRetryCount(session.id)
            failed_count = failed_count + 1
        else
            local duration_formatted = self:formatDuration(session.durationSeconds)
            local normalized_start_location = session.startLocation
            local normalized_end_location = session.endLocation
            if self.progress_sync_normalize_session_locations then
                local server_pagecount = self:getServerPagecountForSession(session)
                normalized_start_location = self:normalizeSessionLocationWithFallback(
                    session.startLocation,
                    session.koreaderPagecount,
                    server_pagecount,
                    session.startProgress
                )
                normalized_end_location = self:normalizeSessionLocationWithFallback(
                    session.endLocation,
                    session.koreaderPagecount,
                    server_pagecount,
                    session.endProgress
                )
            end

            local session_data = {
                bookId            = session.bookId,
                bookType          = session.bookType,
                startTime         = session.startTime,
                endTime           = session.endTime,
                durationSeconds   = session.durationSeconds,
                durationFormatted = duration_formatted,
                startProgress     = self:roundProgress(session.startProgress),
                endProgress       = self:roundProgress(session.endProgress),
                progressDelta     = self:roundProgress(session.progressDelta),
                startLocation     = normalized_start_location,
                endLocation       = normalized_end_location,
            }

            self:logInfo("BookloreSync: Submitting session", i, "- book_id:", session.bookId,
                         "duration:", duration_formatted)

            local success, message = self.api:submitSession(session_data)

            if success then
                synced_count = synced_count + 1
                local archived = self.db:archivePendingSession(session.id)
                if not archived then
                    self:logWarn("BookloreSync: Failed to archive session", i, "to historical_sessions")
                end
                self.db:deletePendingSession(session.id)
                self:logInfo("BookloreSync: Session", i, "synced successfully")
            else
                failed_count = failed_count + 1
                self:logWarn("BookloreSync: Session", i, "failed to sync:", message)
                self.db:incrementSessionRetryCount(session.id)
            end
        end
    end

    self:logInfo("BookloreSync: Sync complete - sessions synced:", synced_count,
                 "failed:", failed_count, "resolved:", resolved_count)

    if not silent then
        local parts = {}
        if synced_count > 0 and failed_count > 0 then
            parts[#parts + 1] = T(_("S: %1 synced, %2 failed"), synced_count, failed_count)
        elseif synced_count > 0 then
            parts[#parts + 1] = T(_("S: %1 synced"), synced_count)
        elseif failed_count > 0 then
            parts[#parts + 1] = _("S: all failed - check connection")
        end
        if ratings_synced + ratings_failed > 0 then
            if ratings_failed > 0 then
                parts[#parts + 1] = T(_("R: %1 synced, %2 failed"), ratings_synced, ratings_failed)
            else
                parts[#parts + 1] = T(_("R: %1 synced"), ratings_synced)
            end
        end
        if ann_synced + ann_failed + ann_skipped > 0 then
            if ann_failed > 0 and ann_skipped > 0 then
                parts[#parts + 1] = T(_("A: %1 synced, %2 failed, %3 skipped"), ann_synced, ann_failed, ann_skipped)
            elseif ann_failed > 0 then
                parts[#parts + 1] = T(_("A: %1 synced, %2 failed"), ann_synced, ann_failed)
            elseif ann_skipped > 0 then
                parts[#parts + 1] = T(_("A: %1 synced, %2 skipped"), ann_synced, ann_skipped)
            else
                parts[#parts + 1] = T(_("A: %1 synced"), ann_synced)
            end
        end
        if bm_synced + bm_failed > 0 then
            if bm_failed > 0 then
                parts[#parts + 1] = T(_("B: %1 synced, %2 failed"), bm_synced, bm_failed)
            else
                parts[#parts + 1] = T(_("B: %1 synced"), bm_synced)
            end
        end
        if prog_synced + prog_failed > 0 then
            if prog_failed > 0 then
                parts[#parts + 1] = T(_("P: %1 synced, %2 failed"), prog_synced, prog_failed)
            else
                parts[#parts + 1] = T(_("P: %1 synced"), prog_synced)
            end
        end
        if #parts > 0 then
            UIManager:show(InfoMessage:new{
                text = table.concat(parts, "\n"),
                timeout = 3,
            })
        end
    end

    return synced_count, failed_count
    end

    return module
end

return M
