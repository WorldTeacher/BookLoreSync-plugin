local M = {}

function M.new(deps)
    local _ = deps._
    local FileManager = deps.FileManager
    local UIManager = deps.UIManager

    local module = {}

    local function closeFileDialog()
        local fc = FileManager.instance and FileManager.instance.file_chooser
        if fc and fc.file_dialog then
            UIManager:close(fc.file_dialog)
        end
    end

    function module.register(plugin)
        -- Row 1: primary actions
        FileManager.addFileDialogButtons(FileManager, "booklore_sync_actions_row1", function(file, is_file, _book_props)
            if not is_file then return nil end
            return {
                {
                    text = _("Booklore Sync"),
                    callback = function()
                        closeFileDialog()
                        plugin:_fileDialogBookloreSync(file)
                    end,
                },
                {
                    text = _("Match Book"),
                    callback = function()
                        closeFileDialog()
                        plugin:fileDialogMatchBook(file)
                    end,
                },
            }
        end)

        -- Row 2: data actions
        FileManager.addFileDialogButtons(FileManager, "booklore_sync_actions_row2", function(file, is_file, _book_props)
            if not is_file then return nil end
            return {
                {
                    text = _("Show Stored Data"),
                    callback = function()
                        closeFileDialog()
                        plugin:fileDialogShowStoredData(file)
                    end,
                },
                {
                    text = _("Extract from Sidecar"),
                    callback = function()
                        closeFileDialog()
                        plugin:fileDialogExtractFromSidecar(file)
                    end,
                },
            }
        end)

        -- Row 4: recommendations
        FileManager.addFileDialogButtons(FileManager, "booklore_sync_actions_row4", function(file, is_file, _book_props)
            if not is_file then return nil end
            return {
                {
                    text = _("Get recommendations"),
                    callback = function()
                        closeFileDialog()
                        plugin:fileDialogGetRecommendations(file)
                    end,
                },
            }
        end)

        -- Row 3: tracking + status actions
        FileManager.addFileDialogButtons(FileManager, "booklore_sync_actions_row3", function(file, is_file, _book_props)
            if not is_file then return nil end
            return {
                {
                    text_func = function()
                        if plugin.db and not plugin.db:isBookTrackingEnabled(file) then
                            return _("Enable tracking")
                        end
                        return _("Disable tracking")
                    end,
                    callback = function()
                        closeFileDialog()
                        plugin:fileDialogToggleTracking(file)
                    end,
                },
                {
                    text = _("Set Reading Status"),
                    callback = function()
                        closeFileDialog()
                        plugin:fileDialogSetReadingStatus(file)
                    end,
                },
            }
        end)
    end

    function module.unregister()
        FileManager.removeFileDialogButtons(FileManager, "booklore_sync_actions_row1")
        FileManager.removeFileDialogButtons(FileManager, "booklore_sync_actions_row2")
        FileManager.removeFileDialogButtons(FileManager, "booklore_sync_actions_row3")
        FileManager.removeFileDialogButtons(FileManager, "booklore_sync_actions_row4")
    end

    return module
end

return M
