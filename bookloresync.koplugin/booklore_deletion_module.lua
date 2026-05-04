local M = {}

function M.new(deps)
    local json = deps.json
    local UIManager = deps.UIManager

    local module = {}

    function module.preDeleteHook(self, filepath)
    if not filepath then return nil, nil, nil end

    -- Support common ebook formats
    local stem = filepath:match("([^/\\]+)%.[Ee][Pp][Uu][Bb]$")
              or filepath:match("([^/\\]+)%.[Pp][Dd][Ff]$")
              or filepath:match("([^/\\]+)%.[Cc][Bb][Zz]$")
              or filepath:match("([^/\\]+)%.[Cc][Bb][Rr]$")
    if not stem then return nil, nil, nil end

    self:logInfo("BookloreSync: preDeleteHook for:", filepath)

    local book_id = nil
    if self.db then
        local cached = self.db:getBookByFilePath(filepath)
        if cached then
            if cached.book_id then
                book_id = tonumber(cached.book_id)
                self:logInfo("BookloreSync: preDeleteHook - cached book_id:", book_id)
            else
                self:logInfo("BookloreSync: preDeleteHook - cached book has no book_id (never synced)")
            end
        else
            self:logInfo("BookloreSync: preDeleteHook - book not in cache")
        end
    end

    -- Fallback: parse book ID from the "_id" tag embedded in the filename.
    -- This works even after a DB reset or a naming-scheme switch.
    if not book_id then
        local fname = filepath:match("([^/\\]+)$") or filepath
        book_id = tonumber(fname:match("_(%d+)%.[^.]+$"))
        if book_id then
            self:logInfo("BookloreSync: preDeleteHook - book_id from filename:", book_id)
        end
    end

    local hash = self:calculateBookHash(filepath)
    if not hash then
        self:logWarn("BookloreSync: preDeleteHook - could not compute hash for:", filepath)
        return nil, nil, nil
    end

    return hash, stem, book_id
    end

    function module.notifyBookloreOnDeletion(self, hash, stem, cached_book_id, from_queue)
    from_queue = from_queue or false

    if not self.is_enabled then return end
    if self.booklore_username == "" or self.booklore_password == "" then return end

    -- If offline, queue immediately rather than attempting the async call
    if not from_queue and not self:isNetworkConnected() then
        self:logWarn("BookloreSync: notifyBookloreOnDeletion - offline, queuing deletion")
        if self.db then self.db:savePendingDeletion(hash, stem, cached_book_id) end
        return
    end

    local booklore_self = self

    UIManager:scheduleIn(0, function()
        local ok, err = pcall(function()
            self:logInfo("BookloreSync: notifyBookloreOnDeletion - hash:", hash, "stem:", stem, "cached_book_id:", tostring(cached_book_id))

            local book_id = cached_book_id

            -- Fallback: search by title if we don't have a cached book_id
            if not book_id then
                self:logInfo("BookloreSync: notifyBookloreOnDeletion - no cached book_id, searching by title")
                local ok1, resp1 = self.api:searchBooksWithAuth(stem, self.booklore_username, self.booklore_password)
                if ok1 and type(resp1) == "table" and resp1[1] and resp1[1].id then
                    book_id = tonumber(resp1[1].id)
                else
                    -- Try the part after "Author - " prefix if present
                    local title_part = stem:match("^.+ %- (.+)$")
                    if title_part then
                        local ok2, resp2 = self.api:searchBooksWithAuth(title_part, self.booklore_username, self.booklore_password)
                        if ok2 and type(resp2) == "table" and resp2[1] and resp2[1].id then
                            book_id = tonumber(resp2[1].id)
                        end
                    end
                end
            end

            if not book_id then
                self:logWarn("BookloreSync: notifyBookloreOnDeletion - book not found on server, skipping shelf removal")
                return
            end

            -- Get bearer token and unassign book from shelf
            local token_ok, token = self.api:getOrRefreshBearerToken(self.booklore_username, self.booklore_password, false)
            if not token_ok then error(token or "Failed to obtain auth token") end

            local shelf_id = self.shelf_id
            if not shelf_id then error("No shelf_id configured - cannot unassign book from shelf") end

            local headers = {
                ["Authorization"] = "Bearer " .. token,
                ["Content-Type"]  = "application/json",
            }
            local body = {
                bookIds           = json.util.InitArray({ book_id }),
                shelvesToAssign   = json.util.InitArray({}),
                shelvesToUnassign = json.util.InitArray({ shelf_id }),
            }
            local req_ok, code, resp = self.api:request("POST", "/api/v1/books/shelves", body, headers)

            if req_ok or code == 200 then
                self:logInfo("BookloreSync: notifyBookloreOnDeletion - book unassigned from shelf, id:", book_id)
            else
                error(tostring(code) .. ": " .. tostring(resp))
            end
        end)
        if not ok then
            self:logWarn("BookloreSync: notifyBookloreOnDeletion failed:", tostring(err))
            if not from_queue and booklore_self.db then
                self:logInfo("BookloreSync: notifyBookloreOnDeletion - queuing for retry")
                booklore_self.db:savePendingDeletion(hash, stem, cached_book_id)
            end
        end
    end)
    end

    return module
end

return M
