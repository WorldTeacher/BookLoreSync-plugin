local M = {}

function M.new(deps)
    local _ = deps._
    local T = deps.T
    local UIManager = deps.UIManager
    local InfoMessage = deps.InfoMessage
    local ConfirmBox = deps.ConfirmBox
    local ButtonDialog = deps.ButtonDialog

    local module = {}

    function module._startBookCacheMatching(self)
    if not self.db then return end

    if not self:isNetworkConnected() then
        self:_requestWifi(_("manual matching for unmatched books"), function()
            self:_startBookCacheMatching()
        end, function()
            self:showWifiUnavailableInfo(
                _("WiFi not enabled - manual matching skipped"),
                _("Airplane mode is enabled - manual matching skipped")
            )
        end)
        return
    end

    local unmatched = self.db:getAllUnmatchedBooks()
    if not unmatched or #unmatched == 0 then
        UIManager:show(InfoMessage:new{
            text = _("All books are already matched"),
            timeout = 2,
        })
        return
    end
    self:logInfo("BookloreSync: Starting manual book-cache matching for", #unmatched, "books")
    self.bk_matching_index = 1
    self.bk_unmatched_books = unmatched
    self:_showNextBookCacheMatch()
    end

    function module._showNextBookCacheMatch(self)
    if not self.bk_unmatched_books or
       self.bk_matching_index > #self.bk_unmatched_books then
        UIManager:show(InfoMessage:new{
            text = _("Matching complete!"),
            timeout = 2,
        })
        self.bk_unmatched_books = nil
        self.bk_matching_index  = nil
        return
    end

    local book        = self.bk_unmatched_books[self.bk_matching_index]
    local progress    = T(_("Book %1 of %2"),
                          self.bk_matching_index, #self.bk_unmatched_books)
    local search_term = book.title and book.title ~= "" and book.title
                        or book.file_path:match("([^/]+)$") or ""

    UIManager:show(InfoMessage:new{
        text = T(_("Searching for: %1\n\n%2"), search_term, progress),
        timeout = 1,
    })

    local success, results = self.api:searchBooksWithAuth(
        search_term, self.booklore_username, self.booklore_password
    )

    if not success then
        local err = type(results) == "string" and results or _("Unknown error")
        UIManager:show(ConfirmBox:new{
            text = T(_("Search failed for:\n%1\n\nError: %2\n\nSkip this book?"),
                     search_term, err),
            ok_text     = _("Skip"),
            cancel_text = _("Retry"),
            ok_callback = function()
                self.bk_matching_index = self.bk_matching_index + 1
                self:_showNextBookCacheMatch()
            end,
            cancel_callback = function()
                self:_showNextBookCacheMatch()
            end,
        })
        return
    end

    if not results or #results == 0 then
        UIManager:show(ConfirmBox:new{
            text = T(_("No matches found for:\n%1\n\n%2\n\nSkip this book?"),
                     search_term, progress),
            ok_text = _("Skip"),
            ok_callback = function()
                self.bk_matching_index = self.bk_matching_index + 1
                self:_showNextBookCacheMatch()
            end,
            cancel_callback = function()
                self:_showNextBookCacheMatch()
            end,
        })
        return
    end

    -- Show selection dialog
    local top_results = {}
    for i = 1, math.min(5, #results) do
        top_results[i] = results[i]
    end

    local buttons = {}
    for i, result in ipairs(top_results) do
        local score = result.matchScore
            and string.format(" (%.0f%%)", result.matchScore * 100)
            or ""
        local label = result.title .. score
        if result.author and result.author ~= "" then
            label = label .. "\n" .. result.author
        end
        table.insert(buttons, {{
            text = label,
            callback = function()
                UIManager:close(self.bk_match_dialog)
                self:_saveBookCacheMatch(book, result)
            end,
        }})
    end
    table.insert(buttons, {{
        text = _("Skip this book"),
        callback = function()
            UIManager:close(self.bk_match_dialog)
            self.bk_matching_index = self.bk_matching_index + 1
            self:_showNextBookCacheMatch()
        end,
    }})
    table.insert(buttons, {{
        text = _("Cancel matching"),
        callback = function()
            UIManager:close(self.bk_match_dialog)
            self.bk_unmatched_books = nil
            self.bk_matching_index  = nil
        end,
    }})

    self.bk_match_dialog = ButtonDialog:new{
        title = T(_("Select match for:\n%1\n\n%2"), search_term, progress),
        buttons = buttons,
    }
    UIManager:show(self.bk_match_dialog)
    end

    function module._saveBookCacheMatch(self, book, selected_result)
    local book_id    = type(selected_result) == "table"
                       and tonumber(selected_result.id) or tonumber(selected_result)
    local book_title = type(selected_result) == "table" and selected_result.title or nil
    local isbn10     = type(selected_result) == "table" and selected_result.isbn10 or nil
    local isbn13     = type(selected_result) == "table" and selected_result.isbn13 or nil
    local server_pagecount = nil
    if type(selected_result) == "table" then
        local raw_pagecount = selected_result.pagecount
        if raw_pagecount == nil then
            raw_pagecount = selected_result.server_pagecount
        end
        local parsed_pagecount = tonumber(raw_pagecount)
        if parsed_pagecount and parsed_pagecount > 0 then
            -- Keep parsing lightweight and defensive here; saveBookCache()
            -- performs final normalization/rounding/validation.
            server_pagecount = parsed_pagecount
        end
    end

    if not book_id then
        UIManager:show(InfoMessage:new{
            text = _("Invalid book ID - match not saved"),
            timeout = 2,
        })
        return
    end

    -- Stamp book_id (and optional ISBNs) into book_cache
    local ok = self.db:saveBookCache(
        book.file_path, book.file_hash or "",
        book_id, book_title or book.title, book.author,
        isbn10, isbn13, server_pagecount
    )

    if not ok then
        UIManager:show(InfoMessage:new{
            text = _("Failed to save match to database"),
            timeout = 2,
        })
        return
    end

    self:logInfo("BookloreSync: Saved manual match - file:", book.file_path,
                 "book_id:", book_id)

    -- Kick off a sync so pending annotations/ratings/sessions for this book
    -- are uploaded right away.  Run silently so the UI just shows the next
    -- book-match dialog without interruption.
    self:syncPendingSessions(true)

    -- Continue batch matching flow only when that state is active.
    if self.bk_unmatched_books and self.bk_matching_index then
        self.bk_matching_index = self.bk_matching_index + 1
        self:_showNextBookCacheMatch()
    end
    end

    return module
end

return M
