local M = {}

function M.new(deps)
    local Device = deps.Device

    local module = {}

    function module.roundKoreaderSyncPercentage(_self, value)
        local n = tonumber(value) or 0
        if n < 0 then n = 0 end
        if n > 1 then n = 1 end
        return math.floor(n * 10000 + 0.5) / 10000
    end

    function module.roundToInt(_self, value)
        local n = tonumber(value)
        if not n then
            return nil
        end
        return math.floor(n + 0.5)
    end

    local function getReflowableXPointer(self)
        local document = self.ui and self.ui.document or nil
        if document and document.getXPointer then
            local ok_xp, xpointer = pcall(document.getXPointer, document)
            if ok_xp and xpointer and tostring(xpointer):sub(1, 1) == "/" then
                return tostring(xpointer)
            end
        end

        local doc_settings = self.ui and self.ui.doc_settings or nil
        if doc_settings and doc_settings.readSetting then
            local ok_ds, sidecar_xp = pcall(doc_settings.readSetting, doc_settings, "last_xpointer")
            if ok_ds and sidecar_xp and tostring(sidecar_xp):sub(1, 1) == "/" then
                return tostring(sidecar_xp)
            end
        end

        return nil
    end

    function module.getCurrentKoreaderSyncProgress(self)
        local fallback_pct, fallback_loc = self:getCurrentProgress()
        local percentage_ratio = (tonumber(fallback_pct) or 0) / 100
        local progress_value = tostring(fallback_loc or "0")
        local is_paged_document = self.ui and self.ui.document and self.ui.document.info and self.ui.document.info.has_pages

        if is_paged_document then
            if self.ui.paging then
                if self.ui.paging.getLastPercent then
                    percentage_ratio = tonumber(self.ui.paging:getLastPercent()) or percentage_ratio
                end
                if self.ui.paging.getLastProgress then
                    progress_value = tostring(self.ui.paging:getLastProgress() or progress_value)
                end
            end
        elseif self.ui and self.ui.rolling then
            if self.ui.rolling.getLastPercent then
                percentage_ratio = tonumber(self.ui.rolling:getLastPercent()) or percentage_ratio
            end
            if self.ui.rolling.getLastProgress then
                progress_value = tostring(self.ui.rolling:getLastProgress() or progress_value)
            end

            local xpointer = getReflowableXPointer(self)

            if xpointer then
                progress_value = tostring(xpointer)
            end
        end

        percentage_ratio = self:roundKoreaderSyncPercentage(percentage_ratio)
        return percentage_ratio, progress_value, progress_value
    end

    function module.getCurrentDocumentHashForProgress(self)
        local file_path = self.ui and self.ui.document and self.ui.document.file or nil
        if not file_path then
            return nil
        end

        if self.current_session and self.current_session.file_hash and self.current_session.file_hash ~= "" then
            return self.current_session.file_hash
        end

        local cached = self.db and self.db:getBookByFilePath(file_path) or nil
        if cached and cached.file_hash and cached.file_hash ~= "" then
            return cached.file_hash
        end

        local computed = self:calculateBookHash(file_path)
        if computed and computed ~= "" then
            if self.db then
                local title = cached and cached.title or nil
                local author = cached and cached.author or nil
                self.db:saveBookCache(file_path, computed, cached and cached.book_id or nil, title, author, nil, nil)
            end
            return computed
        end

        return nil
    end

    function module.buildCurrentKoreaderProgressPayload(self, timestamp)
        if not self.progress_sync_enabled then
            return nil, "Progress sync is disabled"
        end

        local file_path = self.ui and self.ui.document and self.ui.document.file or nil
        if not file_path or file_path == "" then
            return nil, "No open document"
        end

        local book_hash = self:getCurrentDocumentHashForProgress()
        if not book_hash or book_hash == "" then
            return nil, "Missing book hash"
        end

        local percentage_ratio, progress_value, location_value = self:getCurrentKoreaderSyncProgress()
        local ts = tonumber(timestamp) or os.time()
        local device_id = tostring(self.progress_sync_device_id or "unknown")
        local device_name = tostring((Device and Device.model) or "KOReader")
        local book_cache_id = self.db and self.db:getBookCacheIdByFilePath(file_path) or nil

        return {
            timestamp = ts,
            document = tostring(book_hash),
            percentage = self:roundKoreaderSyncPercentage(tonumber(percentage_ratio) or 0),
            progress = tostring(progress_value or location_value or "0"),
            device = device_name,
            device_id = device_id,
            book_hash = tostring(book_hash),
            book_cache_id = book_cache_id,
            location = tostring(location_value or progress_value or "0"),
        }, nil
    end

    function module.pushCurrentKoreaderProgressDirect(self, payload)
        if type(payload) ~= "table" then
            return false, "Invalid payload"
        end
        if not self.api then
            return false, "API client not initialized"
        end
        if not self:isNetworkConnected() then
            return false, "WiFi is not connected"
        end

        local ok, body_or_err = self.api:updateKoReaderProgress(payload)
        if not ok then
            return false, body_or_err
        end

        if self.db then
            self.db:markKoreaderProgressSynced({
                book_cache_id = payload.book_cache_id,
                book_hash = payload.book_hash or payload.document,
                progress = tostring(payload.progress or payload.location or "0"),
                percentage = tonumber(payload.percentage) or 0,
                location = tostring(payload.location or payload.progress or "0"),
                remote_device = payload.device,
                remote_device_id = payload.device_id,
                remote_timestamp = tonumber(payload.timestamp) or nil,
            })
        end

        return true, body_or_err
    end

    return module
end

return M
