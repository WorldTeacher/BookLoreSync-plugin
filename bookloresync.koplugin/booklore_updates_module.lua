local M = {}

function M.new(deps)
    local _ = deps._
    local T = deps.T
    local logger = deps.logger
    local NetworkMgr = deps.NetworkMgr
    local UIManager = deps.UIManager
    local InfoMessage = deps.InfoMessage
    local ButtonDialog = deps.ButtonDialog
    local ConfirmBox = deps.ConfirmBox

    local module = {}

    function module.showVersionInfo(self)
        local version_info = self.updater:getCurrentVersion()

        local text = T(_([[Version Information

Current Version: %1
Version Type: %2
Build Date: %3
Git Commit: %4]]),
            version_info.version,
            version_info.version_type,
            version_info.build_date,
            version_info.git_commit
        )

        if self.update_available then
            text = text .. _("\n\n⚠ Update available!")
        end

        UIManager:show(InfoMessage:new{
            text = text,
            timeout = 10,
        })
    end

    function module.autoCheckForUpdates(self)
        if self.use_dev_builds then
            logger.info("BookloreSync Updater: Auto-check skipped (Use Dev Builds is enabled)")
            return
        end

        local now = os.time()
        if now - self.last_update_check < 86400 then
            logger.info("BookloreSync Updater: Auto-check skipped (last check was less than 24 hours ago)")
            return
        end

        self.last_update_check = now
        self.settings:saveSetting("last_update_check", now)
        self.settings:flush()

        if not NetworkMgr:isConnected() then
            logger.info("BookloreSync Updater: No network, skipping auto-check")
            return
        end

        logger.info("BookloreSync Updater: Running auto-check for updates")
        local result = self.updater:checkForUpdates(true)

        if not result then
            logger.warn("BookloreSync Updater: Auto-check failed")
            return
        end

        if result.available then
            self.update_available = true
            logger.info("BookloreSync Updater: Update available:", result.latest_version)

            UIManager:show(InfoMessage:new{
                text = T(_([[BookloreSync update available!

Current: %1
Latest: %2

Go to Tools → Booklore Sync → About & Updates to install.]]),
                    result.current_version, result.latest_version),
                timeout = 8,
            })
        else
            logger.info("BookloreSync Updater: Already up to date")
        end
    end

    function module.checkForUpdates(self, silent)
        if not NetworkMgr:isConnected() then
            if not silent then
                UIManager:show(InfoMessage:new{
                    text = _("No network connection.\n\nPlease connect to check for updates."),
                    timeout = 3,
                })
            end
            return
        end

        if not silent then
            UIManager:show(InfoMessage:new{
                text = _("Checking for updates..."),
                timeout = 1,
            })
        end

        local result = nil
        if self.use_dev_builds then
            local dev_url, dev_err = self:getDevBuildDownloadURL()
            if not dev_url then
                if not silent then
                    UIManager:show(InfoMessage:new{
                        text = T(_("Dev builds are enabled, but no valid download URL is configured.\n\n%1"), dev_err or _("Unknown error")),
                        timeout = 4,
                    })
                end
                return
            end

            result = self.updater:checkForDirectDownload(dev_url)
        else
            result = self.updater:checkForUpdates(silent)
        end

        if not result then
            if not silent then
                UIManager:show(InfoMessage:new{
                    text = _("Failed to check for updates.\n\nPlease try again later."),
                    timeout = 3,
                })
            end
            return
        end

        if result.available then
            self.update_available = not self.use_dev_builds
            local size_text = self.updater:formatBytes(result.release_info.size)
            local buttons = {
                {
                    {
                        text = _("Install"),
                        callback = function()
                            UIManager:close(self.update_dialog)
                            self:installUpdate(result.release_info.download_url, result.latest_version)
                        end,
                    },
                },
            }

            if result.release_info.changelog_url then
                table.insert(buttons, {
                    {
                        text = _("View Changelog"),
                        callback = function()
                            UIManager:close(self.update_dialog)
                            self:showChangelog(result.release_info.changelog_url, result.latest_version, result.release_info)
                        end,
                    },
                })
            end

            table.insert(buttons, {
                {
                    text = _("Cancel"),
                    callback = function()
                        UIManager:close(self.update_dialog)
                    end,
                },
            })

            self.update_dialog = ButtonDialog:new{
                title = T(_([[Update available!

Current version: %1
Latest version: %2

Download size: %3]]),
                    result.current_version,
                    result.latest_version,
                    size_text),
                buttons = buttons,
            }

            UIManager:show(self.update_dialog)
        else
            self.update_available = false

            if not silent then
                UIManager:show(InfoMessage:new{
                    text = T(_("You're up to date!\n\nCurrent version: %1"), result.current_version),
                    timeout = 3,
                })
            end
        end
    end

    function module.showChangelog(self, changelog_url, version, release_info)
        local loading_msg = InfoMessage:new{
            text = _("Loading changelog..."),
        }
        UIManager:show(loading_msg)

        local full_changelog_content, error_msg = self.updater:fetchChangelog(changelog_url)

        UIManager:close(loading_msg)

        if not full_changelog_content then
            UIManager:show(InfoMessage:new{
                text = T(_("Failed to load changelog:\n%1"), error_msg or "Unknown error"),
                timeout = 3,
            })
            self:checkForUpdates(true)
            return
        end

        local changelog_text = self.updater:parseChangelogForVersion(full_changelog_content, version)

        if not changelog_text or changelog_text == "" then
            logger.warn("BookloreSync: Could not parse version-specific changelog, showing full file")
            changelog_text = full_changelog_content
        end

        changelog_text = self.updater:cleanChangelog(changelog_text)

        local Screen = require("device").screen
        local TextViewer = require("ui/widget/textviewer")

        local changelog_viewer
        changelog_viewer = TextViewer:new{
            title = T(_("Changelog - Version %1"), version),
            text = changelog_text,
            width = math.floor(Screen:getWidth() * 0.8),
            height = math.floor(Screen:getHeight() * 0.7),
            buttons_table = {
                {
                    {
                        text = _("Install Update"),
                        callback = function()
                            UIManager:close(changelog_viewer)
                            self:installUpdate(release_info.download_url, version)
                        end,
                    },
                },
                {
                    {
                        text = _("Close"),
                        callback = function()
                            UIManager:close(changelog_viewer)
                        end,
                    },
                },
            },
        }

        UIManager:show(changelog_viewer)
    end

    function module.installUpdate(self, download_url, version)
        local progress_msg = InfoMessage:new{
            text = _("Downloading update...\n0%"),
        }
        UIManager:show(progress_msg)

        local success, zip_path_or_error = self.updater:downloadUpdate(
            download_url,
            function(bytes_downloaded, total_bytes)
                if total_bytes > 0 then
                    local progress = math.floor((bytes_downloaded / total_bytes) * 100)
                    progress_msg:setText(T(_("Downloading update...\n%1%%"), progress))
                    UIManager:setDirty(progress_msg, "ui")
                end
            end
        )

        UIManager:close(progress_msg)

        if not success then
            UIManager:show(InfoMessage:new{
                text = T(_("Download failed:\n%1"), zip_path_or_error),
                timeout = 5,
            })
            return
        end

        UIManager:show(InfoMessage:new{
            text = _("Installing update..."),
            timeout = 2,
        })

        success, error_msg = self.updater:installUpdate(zip_path_or_error)

        if success then
            UIManager:askForRestart(T(_([[Update installed successfully!

Version %1 is ready.

Restart KOReader now?]]), version))
        else
            UIManager:show(ConfirmBox:new{
                text = T(_([[Installation failed:
%1

Rollback to previous version?]]), error_msg),
                ok_text = _("Rollback"),
                ok_callback = function()
                    self:rollbackUpdate()
                end,
                cancel_text = _("Cancel"),
            })
        end
    end

    function module.rollbackUpdate(self)
        UIManager:show(InfoMessage:new{
            text = _("Rolling back to previous version..."),
            timeout = 2,
        })

        local success, error_msg = self.updater:rollback()

        if success then
            UIManager:askForRestart(_("Rollback successful!\n\nRestart KOReader now?"))
        else
            UIManager:show(InfoMessage:new{
                text = T(_("Rollback failed:\n%1"), error_msg),
                timeout = 5,
            })
        end
    end

    function module.toggleAutoUpdateCheck(self)
        self.auto_update_check = not self.auto_update_check
        self.settings:saveSetting("auto_update_check", self.auto_update_check)
        self.settings:flush()

        UIManager:show(InfoMessage:new{
            text = self.auto_update_check
                and _("Auto-update check enabled.\n\nWill check once per day on startup.")
                or _("Auto-update check disabled."),
            timeout = 2,
        })
    end

    function module.toggleUseDevBuilds(self)
        if not self.use_dev_builds then
            local dev_url, dev_err = self:getDevBuildDownloadURL()
            if not dev_url then
                UIManager:show(InfoMessage:new{
                    text = T(_("Cannot enable dev builds.\n\n%1"), dev_err or _("Unknown error")),
                    timeout = 4,
                })
                return
            end
        end

        self.use_dev_builds = not self.use_dev_builds
        self.settings:saveSetting("use_dev_builds", self.use_dev_builds)
        self.settings:flush()

        self.updater:clearCache()
        self.update_available = false

        UIManager:show(InfoMessage:new{
            text = self.use_dev_builds
                and _("Dev builds enabled.\n\nCheck for Updates will use dev-build.location.")
                or _("Dev builds disabled.\n\nCheck for Updates will use stable releases."),
            timeout = 3,
        })
    end

    function module.clearUpdateCache(self)
        self.updater:clearCache()
        self.update_available = false

        UIManager:show(InfoMessage:new{
            text = _("Update cache cleared.\n\nNext check will fetch fresh data."),
            timeout = 2,
        })
    end

    return module
end

return M
