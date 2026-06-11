-- Post-update "What's New" bullet lists, keyed by version string.
-- Add an entry for each release with noteworthy changes.
-- Omit a version to show no changelog on that update.
--
-- Example:
-- ["0.1.0"] = {
--     "New feature added",
--     "Bug fix for ...",
-- },

return {
["1.0"] = {
    "Added book sync functionality, allowing batch upload, download, or deletion of cloud books",
    "Added gesture shortcuts, allowing quick actions and quick settings via gestures",
    "Fixed potential state confusion in file browser selection mode when using gesture shortcuts",
    "Fixed crash issue with PDF documents during merge update",
    "Fixed issue where some annotations might lose rendering during merge update",
    "Optimized note update issues during merge update",
    "Added function to clear cloud sync logs",
    "Fixed potential format confusion issue when enabling Record Cloud Sync for sync logs",
    "Removed mutual exclusion restriction for auto upload and auto download, allowing both to be enabled simultaneously",
    "Added online update feature",
    "Changed overwrite update from complete overwrite to optional overwrite, allowing choice to keep local document settings",
},

["1.1"] = {
    "Fixed online update crash issue on Android",
},

["1.2"] = {
    "Fixed the issue where synchronization failed when opening a book for the first time",
    "Added support for setting an independent cloud directory for books (separate from metadata cloud directory)",
},

["1.3"] = {
    "Added pre-flight checks for network and configuration",
    "Added Worry-Free Sync Mode quick toggle for metadata",
    "Fixed path concatenation issues for sync logs, metadata and temporary folders",
    "Removed debug logs",
},

["1.4"] = {
    "Added English support: Menu changed to English with Chinese translation",
    "Progress bar for upload/download: Upload progress by book count, download progress by bytes",
    "Manual and auto sync download modes are no longer shared: Prevents temporary switching of download mode in manual sync from affecting automated sync tasks",
    "Optimized update channel: Added three update sources options - GitHub (Latest), GitHub (Pre-release), Gitee (Latest)",
},

["1.4.1"] = {
    "Added changelog.lua to track version history",
    "Optimize plugin module loading path and fix naming conflict with other plugins",
},
}