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
["1.4.2"] = {
    "Fix: support all KOReader formats in book validation (including .fb2.zip)",
    "Non-touch navigation for the cloud book dialog",
},
["1.4.3"] = {
    "Added Auto Sync Exclude Directories feature",
    "Optimized gesture registration: merged reader/filemanager paired gestures into unified general gestures",
},
["1.4.4"] = {
    "Added quick folder navigation to cloud book dialog for switching cloud directories",
    "Optimized upload/download/delete progress dialogs with book name and progress counter display",
    "Add auto WiFi prompt and retry for network-dependent operations",
    "Optimize cloud book dialog refresh logic for better K3/e-ink experience",
    "Wrap page navigation for K3/e-ink devices",
    "Display release notes when new version is found"
    "Improved Chinese translations",
},
["1.4.5"] = {
    "Integrate with Bookshelf: batch operations now auto-enter Bookshelf selection mode and retrieve selected books",
    "Fix garbled text when truncating Chinese folder paths in cloud book dialog navigation",
    "Optimization: Repaint the progress bar once a second on non-touch Kindles to improve download progress feedback"
    "Improved Chinese translations",
},
["1.4.6"] = {
    "Fix Nutstore WebDAV 750-file limit causing incomplete cloud book list",
    "Add upload/download metadata(CL) and upload book(CL) actions to the long-press menu",
    "Add batch upload/download metadatas(CL) and batch upload books(CL) to the selection-mode Plus menu",
},
["1.4.7"] = {
    "Long-press menu actions (upload/download metadata, upload book) and selection-mode Plus menu actions now reuse the existing batch pipelines instead of duplicating logic",
    "Fix book upload from the long-press menu dropping the author field, which broke the title_author naming mode",
    "Flush the currently open book's metadata to disk before checking for its sidecar",
    "Suppress automatic upload for a book after its automatic download failed (no network, not configured, download errors), to avoid overwriting the cloud with incomplete local metadata; a successful download,or a 404 (book not in cloud) clears the suppression, and manual upload asks for confirmation while suppressed",
    "When enabling automatic upload while automatic download is off, prompt to optionally enable automatic download (merge), to avoid overwriting cloud data on first upload",
    "When enabling Worry-Free Sync Mode with a book currently open, prompt to merge-update the current book first, to avoid overwriting the cloud with data that has not been aligned",
},
["1.4.8"] = {
    "Excluded_dir: Fix the issue where auto-sync excluded directories were not persisted",
    "Progress merge: fix incorrect farthest progress selection due to cross-length xpointer comparison",
    "Book_sync: Postpone is_supported_book check, allow all files for upload/download with different upload‑naming branches",
},
}
