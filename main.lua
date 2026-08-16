-- Get plugin root directory absolute path (inspired by zen_ui)
local src = debug.getinfo(1, "S").source or ""
local path = (src:sub(1, 1) == "@") and src:sub(2):match("^(.*)/[^/]+$") or nil

local _plugin_dir  -- Declare local variable

if path then
    -- Handle relative path (some KOReader installations may return relative paths)
    if path:sub(1, 1) ~= "/" then
        local ok, lfs = pcall(require, "libs/libkoreader-lfs")
        local cwd = ok and lfs and lfs.currentdir()
        if cwd then
            path = cwd .. "/" .. path
        end
    end
    _plugin_dir = path .. "/"
else
    _plugin_dir = "./"
end

-- Add plugin directory to package.path to avoid module name conflicts
package.path = _plugin_dir .. "?.lua;" .. package.path

-- i18n must be installed before any other require()
local i18n = dofile(_plugin_dir .. "i18n.lua")
i18n.install()

local WidgetContainer = require("ui/widget/container/widgetcontainer")
local Dispatcher = require("dispatcher")
local UIManager = require("ui/uimanager")
local TextViewer = require("ui/widget/textviewer")
local Device = require("device")
local DataStorage = require("datastorage")
local _ = require("gettext")
local logger = require("logger")
local T = require("ffi/util").template
local lfs = require("libs/libkoreader-lfs")
local Notification = require("ui/widget/notification")
local ConfirmBox = require("ui/widget/confirmbox")
local ButtonDialog = require("ui/widget/buttondialog")
local Screen = Device.screen

local CloudLibraryPlugin = WidgetContainer:extend {
    is_doc_only = false,
}

CloudLibraryPlugin.default_settings = {
    last_sync = "Never",
    metadata_naming_mode = "metadata",
    auto_sync_enabled = false,
    auto_upload_on_annotate = false,
    auto_upload_on_close = false,
    auto_upload_on_suspend = false,
    auto_download_on_open = false,
    auto_download_mode = "merge",
    manual_download_mode = "merge", 
    auto_sync_notify = true,
    upload_json = false,
    use_notemark_format = false,
    sync_log_enabled = false,
    book_naming_mode = "title",
    book_download_dir = nil,
    override_keep_local_settings = true,
    book_cloud_dir = nil,
    book_cloud_type = nil,
    book_cloud_address = nil,
    book_cloud_username = nil,
    book_cloud_password = nil,
    exclude_dirs = {},
}


function CloudLibraryPlugin:init()
    local meta = dofile(_plugin_dir .. "_meta.lua")
    self.VERSION = meta.version or "v1.0.0"
    
    self.ui.menu:registerToMainMenu(self)
    
    local utils = dofile(_plugin_dir .. "utils.lua")
    utils.insert_after_statistics(self.plugin_id)
    self:onDispatcherRegisterActions()
    
    self.settings = G_reader_settings:readSetting(self.plugin_id, self.default_settings)
    
    local AutoSync = dofile(_plugin_dir .. "auto_sync.lua")
    local ManualSync = dofile(_plugin_dir .. "manual_sync.lua")
    local Hooks = dofile(_plugin_dir .. "hooks.lua")
    
    if not CloudLibraryPlugin._auto_sync then
        self.auto_sync = AutoSync:new(self, self.settings)
        CloudLibraryPlugin._auto_sync = self.auto_sync
    else
        self.auto_sync = CloudLibraryPlugin._auto_sync
        self.auto_sync.settings = self.settings
        self.auto_sync.plugin = self
    end
    
    self.manual_sync = ManualSync:new(self, self.auto_sync)
    self.hooks = Hooks:new(self, self.auto_sync)
    
    if self.ui then
        self.ui.CloudLibrary = self
    end
    
    if not CloudLibraryPlugin._global_hooks_registered then
        self.hooks:hookAnnotationModified()
        self.hooks:hookOnReaderReady()
        CloudLibraryPlugin._global_hooks_registered = true
    end
    
    self.hooks:hookOnClose()
    self.hooks:hookOnSuspend()

    G_reader_settings:saveSetting("cloudlibrary_skip_auto_download", false)
    
    logger.info("CloudLibrary: plugin init completed")
end

function CloudLibraryPlugin:addToMainMenu(menu_items)
    menu_items.cloud_library_plugin = {
        text = _("Cloud Library"),
        sorting_hint = "tools",
        sub_item_table = self:buildMenuItems(),
    }
end

function CloudLibraryPlugin:buildMenuItems()
    local utils = dofile(_plugin_dir .. "utils.lua")
    local items = {
        {
            text = _("Settings"),
            sub_item_table = self:buildSettingsMenu(),
            separator = true,
        },
        {
            text = _("Metadata Sync"),
            sub_item_table = self:buildMetadataSyncMenu(),
        },
        {
            text = _("Book Sync"),
            sub_item_table = self:buildBookSyncMenu(),
        },
        {
            text = _("View Sync Log"),
            callback = function()
                self:viewSyncLog()
            end,
        },
        {
            text = _("Plugin Info"),
            callback = function()
                self:showPluginInfo()
            end,
        },
        {
            text = _("Updates") .. "  (" .. _("Current version") .. ": " .. self.VERSION .. ")",
            callback = function()
                local update = dofile(_plugin_dir .. "update.lua")
                update.check_for_updates(false, self)
            end
        },
        {
            enabled = false,
            text_func = function()
                local last_sync = self.settings.last_sync
                if last_sync == "Never" then
                    return T(_("Last sync: %1"), last_sync)
                end
                local time_part = last_sync:match("(.+) %(") or last_sync
                local action_part = last_sync:match("%((.+)%)") or ""
                if action_part ~= "" then
                    return string.format(_("Last sync: %s\n(%s)"), time_part, action_part)
                else
                    return T(_("Last sync: %1"), last_sync)
                end
            end
        },
    }
    return items
end

function CloudLibraryPlugin:buildSettingsMenu()
    local utils = dofile(_plugin_dir .. "utils.lua")
    return {
        {
            text = _("Cloud Directory"),
            sub_item_table = self:buildCloudDirMenu(),
            separator = true,
        },
        {
            text = _("Cloud Naming Rules"),
            sub_item_table = self:buildNamingModeMenu(),
            separator = true,
        },
        {
            text_func = function()
                local dir = self.settings.book_download_dir
                if dir and dir ~= "" then
                    return _("Book Download Directory: ") .. dir
                else
                    return _("Set Book Download Directory")
                end
            end,
            callback = function()
                self:chooseBookLocalDir()
            end,
        },
        {
            text = _("Metadata Download Mode (Manual)"),
            sub_item_table = {
                {
                    text = _("Overwrite"),
                    checked_func = function()
                        return self.settings.manual_download_mode == "override"
                    end,
                    callback = function()
                        self.settings.manual_download_mode = "override"
                        G_reader_settings:saveSetting(self.plugin_id, self.settings)
                        utils.show_msg(_("Metadata download mode (manual): Overwrite"))
                    end
                },
                {
                    text = _("Merge"),
                    checked_func = function()
                        return self.settings.manual_download_mode == "merge"
                    end,
                    callback = function()
                        self.settings.manual_download_mode = "merge"
                        G_reader_settings:saveSetting(self.plugin_id, self.settings)
                        utils.show_msg(_("Metadata download mode (manual): Merge"))
                    end
                },
            },
        },
        {
            text = _("Auto Sync Settings (Metadata Only)"),
            sub_item_table = self:buildAutoSyncMenu(),
            separator = true,
        },
        {
            text = _("Additional JSON Backup"),
            sub_item_table = {
                {
                    text = _("Original format (default)"),
                    checked_func = function()
                        return self.settings.upload_json == true and self.settings.use_notemark_format == false
                    end,
                    callback = function()
                        if self.settings.upload_json and not self.settings.use_notemark_format then
                            self.settings.upload_json = false
                            self.settings.use_notemark_format = false
                        else
                            self.settings.upload_json = true
                            self.settings.use_notemark_format = false
                        end
                        G_reader_settings:saveSetting(self.plugin_id, self.settings)
                        utils.show_msg(self.settings.upload_json and _("Enabled: Original format") or _("Disabled: Additional JSON backup"))
                    end
                },
                {
                    text = _("NoteMarkData format"),
                    checked_func = function()
                        return self.settings.upload_json == true and self.settings.use_notemark_format == true
                    end,
                    help_text = _("When enabled: Convert annotations to NoteMarkData format"),
                    callback = function()
                        if self.settings.upload_json and self.settings.use_notemark_format then
                            self.settings.upload_json = false
                            self.settings.use_notemark_format = false
                        else
                            self.settings.upload_json = true
                            self.settings.use_notemark_format = true
                        end
                        G_reader_settings:saveSetting(self.plugin_id, self.settings)
                        utils.show_msg(self.settings.upload_json and _("Enabled: NoteMarkData format") or _("Disabled: Additional JSON backup"))
                    end
                },
            },
        },
        {
            text = _("Keep local document settings when overwriting"),
            checked_func = function()
                return self.settings.override_keep_local_settings == true
            end,
            help_text = _("When enabled: Keep local font, margin settings when overwriting, only sync annotations and progress"),
            callback = function()
                self.settings.override_keep_local_settings = not self.settings.override_keep_local_settings
                G_reader_settings:saveSetting(self.plugin_id, self.settings)
                utils.show_msg(self.settings.override_keep_local_settings and 
                    _("Enabled: Keep local document settings when overwriting") or 
                    _("Disabled: Fully use cloud file when overwriting"))
            end
        },
        {
            text = _("Enable Cloud Sync Log"),
            checked_func = function()
                return self.settings.sync_log_enabled == true
            end,
            help_text = _("When enabled: Automatically upload local sync logs to cloud or merge cloud logs locally"),
            callback = function()
                self.settings.sync_log_enabled = not self.settings.sync_log_enabled
                G_reader_settings:saveSetting(self.plugin_id, self.settings)
                
                if self.settings.sync_log_enabled then
                    local sync_log = dofile(_plugin_dir .. "sync_log.lua")
                    sync_log.sync_log()
                    utils.show_msg(_("Cloud sync log enabled"))
                else
                    utils.show_msg(_("Cloud sync log disabled"))
                end
            end
        },
        {
            text = _("Clear Cloud Sync Log"),
            help_text = _("Clear all sync logs stored in the cloud, local logs will not be affected"),
            callback = function()
                self:confirmClearCloudLog()
            end,
            separator = true,
        },
    }
end

function CloudLibraryPlugin:buildCloudDirMenu()
    return {
        {
            text_func = function()
                local remote = dofile(_plugin_dir .. "remote.lua")
                local server = remote.get_server()
                if server and server.url then
                    return _("Metadata Cloud Directory: ") .. server.url
                else
                    return _("Set Metadata Cloud Directory")
                end
            end,
            callback = function()
                local SyncService = require("apps/cloudstorage/syncservice")
                local remote = dofile(_plugin_dir .. "remote.lua")
                local sync_service = SyncService:new{}
                sync_service.onConfirm = function(server)
                    remote.save_server_settings(server)
                end
                UIManager:show(sync_service)
            end
        },
        {
            text_func = function()
                local book_dir = self.settings.book_cloud_dir
                if book_dir and book_dir ~= "" then
                    return _("Book Cloud Directory: ") .. book_dir
                else
                    return _("Set Book Cloud Directory (defaults to metadata directory)")
                end
            end,
            callback = function()
                self:chooseBookCloudDir()
            end,
        },
    }
end

function CloudLibraryPlugin:chooseBookCloudDir()
    local SyncService = require("apps/cloudstorage/syncservice")
    local remote = dofile(_plugin_dir .. "remote.lua")
    
    local current_server = remote.get_server()
    
    local sync_service = SyncService:new{
        server_type = current_server and current_server.type or nil,
        server_address = current_server and current_server.address or nil,
        server_username = current_server and current_server.username or nil,
        server_password = current_server and current_server.password or nil,
        server_url = self.settings.book_cloud_dir or (current_server and current_server.url or nil),
    }
    
    sync_service.onConfirm = function(server)
        self.settings.book_cloud_dir = server.url
        self.settings.book_cloud_type = server.type
        self.settings.book_cloud_address = server.address
        self.settings.book_cloud_username = server.username
        self.settings.book_cloud_password = server.password
        G_reader_settings:saveSetting(self.plugin_id, self.settings)
    end
    
    UIManager:show(sync_service)
end

function CloudLibraryPlugin:addExcludeDir()
    local utils = dofile(_plugin_dir .. "utils.lua")
    local DownloadMgr = require("ui/downloadmgr")
    local self_ref = self
    local current_dir = nil
    
    DownloadMgr:new{
        title = _("Select Directory to Exclude from Auto Sync"),
        onConfirm = function(path)
            if path and path ~= "" then
                local exclude_dirs = self_ref.settings.exclude_dirs or {}
                for idx, existing in ipairs(exclude_dirs) do
                    if existing == path then
                        utils.show_msg(_("This directory is already in the exclude list"))
                        return
                    end
                end
                table.insert(exclude_dirs, path)
                self_ref.settings.exclude_dirs = exclude_dirs
                G_reader_settings:saveSetting(self_ref.plugin_id, self_ref.settings)
                utils.show_msg(string.format(_("Excluded directory added: %s"), path))
            end
        end,
    }:chooseDir(current_dir)
end

function CloudLibraryPlugin:removeExcludeDir(index)
    local utils = dofile(_plugin_dir .. "utils.lua")
    local exclude_dirs = self.settings.exclude_dirs or {}
    if index < 1 or index > #exclude_dirs then
        return
    end
    
    local removed_dir = exclude_dirs[index]
    local self_ref = self
    
    if self_ref._exclude_dir_dialog then
        UIManager:close(self_ref._exclude_dir_dialog)
        self_ref._exclude_dir_dialog = nil
    end
    
    UIManager:show(ConfirmBox:new{
        text = string.format(_("Remove \"%s\" from exclude list?"), removed_dir),
        ok_text = _("Remove"),
        cancel_text = _("Cancel"),
        ok_callback = function()
            table.remove(exclude_dirs, index)
            self_ref.settings.exclude_dirs = exclude_dirs
            G_reader_settings:saveSetting(self_ref.plugin_id, self_ref.settings)
        end,
    })
end

function CloudLibraryPlugin:confirmClearCloudLog()
    UIManager:show(ConfirmBox:new{
        text = _("Are you sure you want to clear all sync logs from the cloud?\n\nThis will not affect local logs, but other devices will not be able to sync cleared records."),
        ok_text = _("Clear"),
        cancel_text = _("Cancel"),
        ok_callback = function()
            self:doClearCloudLog()
        end
    })
end

function CloudLibraryPlugin:doClearCloudLog()
    local utils = dofile(_plugin_dir .. "utils.lua")
    local NetworkMgr = require("ui/network/manager")
    
    if not NetworkMgr:isOnline() then
        utils.show_msg(_("No network connection, cannot clear"))
        return
    end
    
    utils.show_msg(_("Clearing cloud sync logs..."))
    
    UIManager:scheduleIn(0, function()
        local sync_log = dofile(_plugin_dir .. "sync_log.lua")
        local success, msg = sync_log.clear_cloud_log()
        
        if success then
            utils.show_msg(_("Cloud sync logs cleared"))
        else
            utils.show_msg(_("Clear failed: ") .. msg)
        end
    end)
end

function CloudLibraryPlugin:buildNamingModeMenu()
    local utils = dofile(_plugin_dir .. "utils.lua")
    return {
        {
            text = _("Metadata Naming Rules"),
            sub_item_table = {
                {
                    text = _("Use Filename"),
                    checked_func = function()
                        return self.settings.metadata_naming_mode == "filename"
                    end,
                    callback = function()
                        self.settings.metadata_naming_mode = "filename"
                        utils.show_msg(_("Metadata naming: Filename"))
                        G_reader_settings:saveSetting(self.plugin_id, self.settings)
                    end
                },
                {
                    text = _("Use Book Title (default)"),
                    checked_func = function()
                        return self.settings.metadata_naming_mode == "metadata"
                    end,
                    callback = function()
                        self.settings.metadata_naming_mode = "metadata"
                        utils.show_msg(_("Metadata naming: Book title"))
                        G_reader_settings:saveSetting(self.plugin_id, self.settings)
                    end
                },
                {
                    text = _("Use Title_Author"),
                    checked_func = function()
                        return self.settings.metadata_naming_mode == "title_author"
                    end,
                    callback = function()
                        self.settings.metadata_naming_mode = "title_author"
                        utils.show_msg(_("Metadata naming: Title_Author"))
                        G_reader_settings:saveSetting(self.plugin_id, self.settings)
                    end
                },
            },
        },
        {
            text = _("Book Naming Rules"),
            sub_item_table = {
                {
                    text = _("Use Filename"),
                    checked_func = function()
                        return self.settings.book_naming_mode == "filename"
                    end,
                    callback = function()
                        self.settings.book_naming_mode = "filename"
                        utils.show_msg(_("Book naming: Filename"))
                        G_reader_settings:saveSetting(self.plugin_id, self.settings)
                    end
                },
                {
                    text = _("Use Book Title (default)"),
                    checked_func = function()
                        return self.settings.book_naming_mode == "title"
                    end,
                    callback = function()
                        self.settings.book_naming_mode = "title"
                        utils.show_msg(_("Book naming: Book title"))
                        G_reader_settings:saveSetting(self.plugin_id, self.settings)
                    end
                },
                {
                    text = _("Use Title_Author"),
                    checked_func = function()
                        return self.settings.book_naming_mode == "title_author"
                    end,
                    callback = function()
                        self.settings.book_naming_mode = "title_author"
                        utils.show_msg(_("Book naming: Title_Author"))
                        G_reader_settings:saveSetting(self.plugin_id, self.settings)
                    end
                },
            },
        },
    }
end

function CloudLibraryPlugin:chooseBookLocalDir()
    local DownloadMgr = require("ui/downloadmgr")
    local current_dir = self.settings.book_download_dir
    
    DownloadMgr:new{
        title = _("Select Book Download Directory"),
        onConfirm = function(path)
            if path and path ~= "" then
                self.settings.book_download_dir = path
                G_reader_settings:saveSetting(self.plugin_id, self.settings)
                UIManager:show(Notification:new{
                    text = string.format(_("Book download directory set: %s"), path),
                    timeout = 2
                })
            end
        end,
    }:chooseDir(current_dir)
end

function CloudLibraryPlugin:buildMetadataSyncMenu()
    return {
        {
            text = _("Upload current book metadata"),
            enabled = self.ui and self.ui.document,
            callback = function()
                self.manual_sync:syncCurrentBook(true)
            end
        },
        {
            text = _("Download current book metadata"),
            sub_item_table = {
                {
                    text = _("Overwrite"),
                    callback = function()
                        self.settings.manual_download_mode = "override"
                        G_reader_settings:saveSetting(self.plugin_id, self.settings)
                        self.manual_sync:syncCurrentBook(false)
                    end
                },
                {
                    text = _("Merge"),
                    callback = function()
                        self.settings.manual_download_mode = "merge"
                        G_reader_settings:saveSetting(self.plugin_id, self.settings)
                        self.manual_sync:syncCurrentBookMerge()
                    end
                },
            },
        },
        {
            text = _("Batch upload selected books metadata"),
            callback = function()
                self.manual_sync:batchSyncWithFMSelection(true, false)
            end,
        },
        {
            text = _("Batch download selected books metadata"),
            sub_item_table = {
                {
                    text = _("Overwrite"),
                    callback = function()
                        self.manual_sync:batchSyncWithFMSelection(false, false)
                    end
                },
                {
                    text = _("Merge"),
                    callback = function()
                        self.manual_sync:batchSyncWithFMSelection(false, true)
                    end
                },
            },
        },
    }
end

function CloudLibraryPlugin:buildBookSyncMenu()
    local BookSync = dofile(_plugin_dir .. "book_sync.lua")
    return {
        {
            text = _("Batch upload selected books"),
            callback = function()
                BookSync.batchUploadWithFMSelection(self)
            end
        },
        {
            text = _("Batch download/delete cloud books"),
            callback = function()
                self:batchDownloadBooks()
            end
        },
    }
end

function CloudLibraryPlugin:buildExcludeDirMenu()
    local utils = dofile(_plugin_dir .. "utils.lua")
    local exclude_dirs = self.settings.exclude_dirs or {}
    
    local items = {}
    
    -- 添加新目录按钮
    table.insert(items, {
        text = _("+ Add Directory to Exclude"),
        callback = function()
            self:addExcludeDir()
        end,
        separator = (#exclude_dirs > 0) and true or false,
    })
    
    -- 显示已排除的目录列表
    for i, dir in ipairs(exclude_dirs) do
        local display_dir = dir
        -- 截断长路径以便显示
        if #display_dir > 40 then
            display_dir = "..." .. display_dir:sub(-37)
        end
        table.insert(items, {
            text_func = function()
                return string.format("  %s", display_dir)
            end,
            enabled = false,
        })
        table.insert(items, {
            text = string.format("    ✕ %s", _("Remove")),
            callback = function()
                self:removeExcludeDir(i)
            end,
        })
        if i < #exclude_dirs then
            table.insert(items, { text = "", enabled = false })
        end
    end
    
    if #exclude_dirs == 0 then
        table.insert(items, {
            text = _("  (No directories excluded)"),
            enabled = false,
        })
    end
    
    return items
end

function CloudLibraryPlugin:buildAutoSyncMenu()
    local utils = dofile(_plugin_dir .. "utils.lua")
    return {
        {
            text = _("Auto Upload Backup"),
            enabled = true,
            sub_item_table = {
                {
                    text = _("Auto upload when editing annotations"),
                    checked_func = function()
                        return self.settings.auto_upload_on_annotate == true
                    end,
                    callback = function()
                        self.settings.auto_upload_on_annotate = not self.settings.auto_upload_on_annotate
                        self:updateAutoSyncSettings()
                        utils.show_msg(self.settings.auto_upload_on_annotate and _("Enabled: Auto upload when editing annotations") or _("Disabled: Auto upload when editing annotations"))
                    end,
                },
                {
                    text = _("Auto upload when closing book"),
                    checked_func = function()
                        return self.settings.auto_upload_on_close == true
                    end,
                    callback = function()
                        self.settings.auto_upload_on_close = not self.settings.auto_upload_on_close
                        self:updateAutoSyncSettings()
                        utils.show_msg(self.settings.auto_upload_on_close and _("Enabled: Auto upload when closing book") or _("Disabled: Auto upload when closing book"))
                    end,
                },
                {
                    text = _("Auto upload when device suspends"),
                    checked_func = function()
                        return self.settings.auto_upload_on_suspend == true
                    end,
                    callback = function()
                        self.settings.auto_upload_on_suspend = not self.settings.auto_upload_on_suspend
                        self:updateAutoSyncSettings()
                        utils.show_msg(self.settings.auto_upload_on_suspend and _("Enabled: Auto upload when device suspends") or _("Disabled: Auto upload when device suspends"))
                    end,
                },
            },
        },
        {
            text = _("Auto Download Update"),
            enabled = true,
            sub_item_table = {
                {
                    text = _("Auto download when opening book (Overwrite)"),
                    checked_func = function()
                        return self.settings.auto_download_on_open and self.settings.auto_download_mode == "override"
                    end,
                    callback = function()
                        if self.settings.auto_download_on_open and self.settings.auto_download_mode == "override" then
                            self.settings.auto_download_on_open = false
                        else
                            self.settings.auto_download_on_open = true
                            self.settings.auto_download_mode = "override"
                        end
                        self:updateAutoSyncSettings()
                        G_reader_settings:saveSetting(self.plugin_id, self.settings)
                        local utils = dofile(_plugin_dir .. "utils.lua")
                        utils.show_msg(self.settings.auto_download_on_open and self.settings.auto_download_mode == "override" and 
                            _("Enabled: Auto download when opening book (Overwrite)") or _("Disabled: Auto download when opening book (Overwrite)"))
                    end,
                },
                {
                    text = _("Auto download when opening book (Merge)"),
                    checked_func = function()
                        return self.settings.auto_download_on_open and self.settings.auto_download_mode == "merge"
                    end,
                    callback = function()
                        if self.settings.auto_download_on_open and self.settings.auto_download_mode == "merge" then
                            self.settings.auto_download_on_open = false
                        else
                            self.settings.auto_download_on_open = true
                            self.settings.auto_download_mode = "merge"
                        end
                        self:updateAutoSyncSettings()
                        G_reader_settings:saveSetting(self.plugin_id, self.settings)
                        local utils = dofile(_plugin_dir .. "utils.lua")
                        utils.show_msg(self.settings.auto_download_on_open and self.settings.auto_download_mode == "merge" and 
                            _("Enabled: Auto download when opening book (Merge)") or _("Disabled: Auto download when opening book (Merge)"))
                    end,
                },
            },
        },
        {
            text_func = function()
                local count = #(self.settings.exclude_dirs or {})
                if count > 0 then
                    return string.format(_("Auto Sync Exclude Directories (%d)"), count)
                else
                    return _("Auto Sync Exclude Directories")
                end
            end,
            callback = function()
                self:showExcludeDirDialog()
            end,
            separator = true,
        },
        {
            text = _("Show notification on auto sync"),
            checked_func = function()
                return self.settings.auto_sync_notify == true
            end,
            callback = function()
                self.settings.auto_sync_notify = not self.settings.auto_sync_notify
                G_reader_settings:saveSetting(self.plugin_id, self.settings)
                utils.show_msg(self.settings.auto_sync_notify and _("Enabled: Auto sync notifications") or _("Disabled: Auto sync notifications"))
            end,
        },
    }
end

function CloudLibraryPlugin:batchDownloadBooks()
    local utils = dofile(_plugin_dir .. "utils.lua")
    local download_dir = self.settings.book_download_dir
    if not download_dir or download_dir == "" then
        utils.show_msg(_("Please set book download directory in settings first"))
        return
    end
    
    local BookSync = dofile(_plugin_dir .. "book_sync.lua")
    BookSync.show_cloud_book_dialog(function(selected_books)
        -- selected_books 现在包含 name 和 size 的完整对象
        BookSync.batchDownloadBooks(selected_books, self.settings, self)
    end, self)
end

function CloudLibraryPlugin:updateAutoSyncSettings()
    local has_upload = self.settings.auto_upload_on_annotate or 
                      self.settings.auto_upload_on_close or 
                      self.settings.auto_upload_on_suspend
    local has_download = self.settings.auto_download_on_open
    
    self.settings.auto_sync_enabled = has_upload or has_download
    
    G_reader_settings:saveSetting(self.plugin_id, self.settings)
end

function CloudLibraryPlugin:viewSyncLog()
    local utils = dofile(_plugin_dir .. "utils.lua")
    local log_path = utils.get_log_path()
    
    local realpath = require("ffi/util").realpath
    local absolute_path = log_path
    if realpath then
        local resolved = realpath(log_path)
        if resolved then
            absolute_path = resolved
        end
    end
    
    local f = io.open(log_path, "r")
    if not f then
        utils.show_msg(_("No sync records"))
        return
    end
    local content = f:read("*all")
    f:close()
    
    if content == "" or not content then
        utils.show_msg(_("No sync records"))
        return
    end
    
    local header = string.format(_("Sync log file path: %s\n\n"), absolute_path)
    local full_content = header .. content
    
    local textviewer
    local buttons = {
        {
            {
                text = _("Find"),
                callback = function()
                    if textviewer then
                        textviewer:findDialog()
                    end
                end,
            },
            {
                text = _("Copy"),
                callback = function()
                    if Device:hasClipboard() then
                        Device.input.setClipboardText(full_content)
                        utils.show_msg(_("Sync log copied to clipboard"))
                    else
                        local temp_file = DataStorage:getDataDir() .. "sync_log_backup.txt"
                        local out_f = io.open(temp_file, "w")
                        if out_f then
                            out_f:write(full_content)
                            out_f:close()
                            utils.show_msg(string.format(_("Sync log saved to %s"), temp_file))
                        else
                            utils.show_msg(_("Copy failed"))
                        end
                    end
                end,
            },
            {
                text = _("Clear"),
                callback = function()
                    UIManager:show(ConfirmBox:new{
                        text = _("Are you sure you want to clear all sync records?"),
                        ok_text = _("Clear"),
                        cancel_text = _("Cancel"),
                        ok_callback = function()
                            local out_f = io.open(log_path, "w")
                            if out_f then
                                out_f:write("")
                                out_f:close()
                            end
                            if textviewer then
                                UIManager:close(textviewer)
                            end
                            utils.show_msg(_("Sync records cleared"))
                        end,
                    })
                end,
            },
            {
                text = "⇱",
                callback = function()
                    if textviewer and textviewer.scroll_text_w then
                        textviewer.scroll_text_w:scrollToTop()
                    end
                end,
            },
            {
                text = "⇲",
                callback = function()
                    if textviewer and textviewer.scroll_text_w then
                        textviewer.scroll_text_w:scrollToBottom()
                    end
                end,
            },
        },
    }
    
    textviewer = TextViewer:new{
        title = _("Sync Log"),
        text = full_content,
        justified = false,
        buttons_table = buttons,
    }
    UIManager:show(textviewer)
end

function CloudLibraryPlugin:showPluginInfo()
    local DataStorage = require("datastorage")
    local data_dir = DataStorage:getFullDataDir()
    local plugin_dir = data_dir .. "/plugins/cloudlibrary.koplugin/"
    
    -- Get current language setting
    local current_lang = G_reader_settings:readSetting("language") or "en"
    local is_chinese = current_lang == "zh_CN" or current_lang == "zh-TW" or current_lang:match("^zh")
    
    -- Select README file based on language
    local readme_path
    if is_chinese then
        readme_path = plugin_dir .. "README.zh_CN.md"
        -- Fallback to English if Chinese README doesn't exist
        if not lfs.attributes(readme_path, "mode") then
            readme_path = plugin_dir .. "README.md"
        end
    else
        readme_path = plugin_dir .. "README.md"
        -- Fallback to Chinese if English README doesn't exist
        if not lfs.attributes(readme_path, "mode") then
            readme_path = plugin_dir .. "README.zh_CN.md"
        end
    end
    
    local f = io.open(readme_path, "r")
    local content = nil
    if f then
        content = f:read("*all")
        f:close()
    end
    
    if not content or content == "" then
        content = _("README file not found")
    end
    
    local TextViewer = require("ui/widget/textviewer")
    local textviewer = TextViewer:new{
        title = _("Cloud Library Plugin Info"),
        text = content,
        justified = false,
    }
    UIManager:show(textviewer)
end

function CloudLibraryPlugin:onDispatcherRegisterActions()
    -- ============================================================
    -- 通用手势（阅读器 + 文件管理器）
    -- ============================================================
    Dispatcher:registerAction("cloudlibrary_quick_actions", {
        category = "none",
        event = "CloudLibraryQuickActions",
        title = _("Cloud Library - Quick Actions"),
        general = true,
    })

    Dispatcher:registerAction("cloudlibrary_quick_settings", {
        category = "none",
        event = "CloudLibraryQuickSettings",
        title = _("Cloud Library - Quick Settings"),
        general = true,
    })

    Dispatcher:registerAction("cloudlibrary_autosync", {
        category = "none",
        event = "CloudLibraryAutoSync",
        title = _("Cloud Library - Worry-Free Sync Mode"),
        general = true,
    })

    Dispatcher:registerAction("cloudlibrary_exclude_dirs", {
        category = "none",
        event = "CloudLibraryExcludeDirs",
        title = _("Cloud Library - Exclude Directories"),
        general = true,
    })

    -- ============================================================
    -- 仅阅读器手势（需要打开书籍）
    -- ============================================================
    Dispatcher:registerAction("cloudlibrary_upload_current", {
        category = "none",
        event = "CloudLibraryUploadCurrent",
        title = _("Cloud Library - Upload current book metadata"),
        reader = true,
    })
    
    Dispatcher:registerAction("cloudlibrary_download_current", {
        category = "none",
        event = "CloudLibraryDownloadCurrent",
        title = _("Cloud Library - Download current book metadata (Smart mode)"),
        reader = true,
    })

    -- ============================================================
    -- 仅文件管理器手势（需要选择文件）
    -- ============================================================
    Dispatcher:registerAction("cloudlibrary_batch_upload_metadata", {
        category = "none",
        event = "CloudLibraryBatchUploadMetadata",
        title = _("Cloud Library - Batch upload selected books metadata"),
        filemanager = true,
    })
    
    Dispatcher:registerAction("cloudlibrary_batch_download_metadata_smart", {
        category = "none",
        event = "CloudLibraryBatchDownloadMetadataSmart",
        title = _("Cloud Library - Batch download metadata (Smart mode)"),
        filemanager = true,
    })
    
    Dispatcher:registerAction("cloudlibrary_batch_upload_books", {
        category = "none",
        event = "CloudLibraryBatchUploadBooks",
        title = _("Cloud Library - Batch upload selected books"),
        filemanager = true,
    })
    
    Dispatcher:registerAction("cloudlibrary_batch_download_books", {
        category = "none",
        event = "CloudLibraryBatchDownloadBooks",
        title = _("Cloud Library - Batch download/delete cloud books"),
        filemanager = true,
    })
end

-- ============================================================
-- 通用手势处理函数
-- ============================================================

function CloudLibraryPlugin:onCloudLibraryQuickActions()
    local context
    if self.ui and self.ui.document then
        context = "reader"
    else
        context = "filemanager"
    end
    self:showSyncDialog(context)
end

function CloudLibraryPlugin:onCloudLibraryQuickSettings()
    self:showSettingsDialog()
end

function CloudLibraryPlugin:onCloudLibraryAutoSync()
    self:toggleAutoSyncQuick()
end

function CloudLibraryPlugin:onCloudLibraryExcludeDirs()
    self:showExcludeDirDialog()
end

function CloudLibraryPlugin:showSyncDialog(context)
    local buttons = {}
    local BookSync = dofile(_plugin_dir .. "book_sync.lua")
    local mode_text = (self.settings.manual_download_mode == "merge") and _("Merge") or _("Overwrite")
    
if context == "reader" then
    buttons = {
        { 
            { text = _("Upload current book metadata"), callback = function()
                if self._current_dialog then
                    UIManager:close(self._current_dialog)
                    self._current_dialog = nil
                end
                self.manual_sync:syncCurrentBook(true)
            end } 
        },
        { 
            { text = string.format(_("Download current book metadata (%s)"), mode_text), callback = function()
                if self._current_dialog then
                    UIManager:close(self._current_dialog)
                    self._current_dialog = nil
                end
                -- 改为 manual_download_mode
                if self.settings.manual_download_mode == "merge" then
                    self.manual_sync:syncCurrentBookMerge()
                else
                    self.manual_sync:syncCurrentBook(false)
                end
            end } 
        },
        { 
            { text = _("View Sync Log"), callback = function()
                if self._current_dialog then
                    UIManager:close(self._current_dialog)
                    self._current_dialog = nil
                end
                self:viewSyncLog()
            end } 
        },
    }
else
    buttons = {
        { 
            { text = _("Batch upload selected books metadata"), callback = function()
                if self._current_dialog then
                    UIManager:close(self._current_dialog)
                    self._current_dialog = nil
                end
                self.manual_sync:batchSyncWithFMSelection(true, false)
            end } 
        },
        { 
            {
                text = string.format(_("Batch download selected books metadata (%s)"), 
                    (self.settings.manual_download_mode == "merge") and _("Merge") or _("Overwrite")),
                callback = function()
                    if self._current_dialog then
                        UIManager:close(self._current_dialog)
                        self._current_dialog = nil
                    end
                    local is_merge = (self.settings.manual_download_mode == "merge")
                    self.manual_sync:batchSyncWithFMSelection(false, is_merge)
                end
            } 
        },
        { 
            { text = _("Batch upload selected books"), callback = function()
                if self._current_dialog then
                    UIManager:close(self._current_dialog)
                    self._current_dialog = nil
                end
                BookSync.batchUploadWithFMSelection(self)
            end } 
        },
        { 
            { text = _("Batch download/delete cloud books"), callback = function()
                if self._current_dialog then
                    UIManager:close(self._current_dialog)
                    self._current_dialog = nil
                end
                self:batchDownloadBooks()
            end } 
        },
        { 
            { text = _("View Sync Log"), callback = function()
                if self._current_dialog then
                    UIManager:close(self._current_dialog)
                    self._current_dialog = nil
                end
                self:viewSyncLog()
            end } 
        },
    }
end
    
    local dialog = ButtonDialog:new{
        title = _("Cloud Library - Quick Actions"),
        title_align = "center",
        buttons = buttons,
        width = math.floor(Screen:getWidth() * 0.6),
    }
    self._current_dialog = dialog
    UIManager:show(dialog)
end

function CloudLibraryPlugin:onCloudLibraryUploadCurrent()
    if self.ui and self.ui.document then
        self.manual_sync:syncCurrentBook(true)
    end
end

function CloudLibraryPlugin:onCloudLibraryDownloadCurrent()
    if self.ui and self.ui.document then
        if self.settings.manual_download_mode == "merge" then
            self.manual_sync:syncCurrentBookMerge()
        else
            self.manual_sync:syncCurrentBook(false)
        end
    end
end

function CloudLibraryPlugin:showSettingsDialog()
    local ButtonDialog = require("ui/widget/buttondialog")
    local UIManager = require("ui/uimanager")
    local Screen = Device.screen
    local _ = require("gettext")
    
    local self_ref = self
    
    local function rebuildAndShow()
        if self_ref._current_settings_dialog then
            UIManager:close(self_ref._current_settings_dialog)
            self_ref._current_settings_dialog = nil
        end
        self_ref:showSettingsDialog()
    end
    
    local buttons = {}
    
    table.insert(buttons, {
        {
            text_func = function()
                local remote = dofile(_plugin_dir .. "remote.lua")
                local server = remote.get_server()
                if server and server.url then
                    return _("Metadata Cloud Directory: ") .. server.url
                else
                    return _("Set Metadata Cloud Directory")
                end
            end,
            callback = function()
                local SyncService = require("apps/cloudstorage/syncservice")
                local remote = dofile(_plugin_dir .. "remote.lua")
                local sync_service = SyncService:new{}
                sync_service.onConfirm = function(server)
                    remote.save_server_settings(server)
                end
                UIManager:show(sync_service)
                if self_ref._current_settings_dialog then
                    UIManager:close(self_ref._current_settings_dialog)
                    self_ref._current_settings_dialog = nil
                end
            end
        }
    })
    
    table.insert(buttons, {
        {
            text_func = function()
                local book_dir = self.settings.book_cloud_dir
                if book_dir and book_dir ~= "" then
                    return _("Book Cloud Directory: ") .. book_dir
                else
                    return _("Set Book Cloud Directory (defaults to metadata directory)")
                end
            end,
            callback = function()
                self:chooseBookCloudDir()
                if self_ref._current_settings_dialog then
                    UIManager:close(self_ref._current_settings_dialog)
                    self_ref._current_settings_dialog = nil
                end
            end
        }
    })
    
    table.insert(buttons, {})
    
    local metadata_naming_mode = self.settings.metadata_naming_mode or "metadata"
    local metadata_naming_text = ""
    if metadata_naming_mode == "filename" then
        metadata_naming_text = _("Use Filename")
    elseif metadata_naming_mode == "metadata" then
        metadata_naming_text = _("Use Book Title")
    elseif metadata_naming_mode == "title_author" then
        metadata_naming_text = _("Use Title_Author")
    end
    
    table.insert(buttons, {
        {
            text = _("Metadata Naming Rules: ") .. metadata_naming_text,
            callback = function()
                self:showMetadataNamingModeDialog()
                if self_ref._current_settings_dialog then
                    UIManager:close(self_ref._current_settings_dialog)
                    self_ref._current_settings_dialog = nil
                end
            end
        }
    })
    
    local book_naming_mode = self.settings.book_naming_mode or "title"
    local book_naming_text = ""
    if book_naming_mode == "filename" then
        book_naming_text = _("Use Filename")
    elseif book_naming_mode == "title" then
        book_naming_text = _("Use Book Title")
    elseif book_naming_mode == "title_author" then
        book_naming_text = _("Use Title_Author")
    end
    
    table.insert(buttons, {
        {
            text = _("Book Naming Rules: ") .. book_naming_text,
            callback = function()
                self:showBookNamingModeDialog()
                if self_ref._current_settings_dialog then
                    UIManager:close(self_ref._current_settings_dialog)
                    self_ref._current_settings_dialog = nil
                end
            end
        }
    })
    
    table.insert(buttons, {
        {
            text_func = function()
                local dir = self.settings.book_download_dir
                if dir and dir ~= "" then
                    return _("Book Download Directory: ") .. dir
                else
                    return _("Set Book Download Directory")
                end
            end,
            callback = function()
                self:chooseBookLocalDir()
                if self_ref._current_settings_dialog then
                    UIManager:close(self_ref._current_settings_dialog)
                    self_ref._current_settings_dialog = nil
                end
            end
        }
    })
    
    local download_mode_text = (self.settings.manual_download_mode == "merge") and _("Merge") or _("Overwrite")
    table.insert(buttons, {
        {
            text = _("Metadata Download Mode (Manual): ") .. download_mode_text,
            callback = function()
                self:showManualDownloadModeDialog()
                if self_ref._current_settings_dialog then
                    UIManager:close(self_ref._current_settings_dialog)
                    self_ref._current_settings_dialog = nil
                end
            end
        }
    })
    
    table.insert(buttons, {})
    
    table.insert(buttons, {
        {
            text_func = function()
                return (self.settings.auto_upload_on_annotate and "✓ " or "  ") .. _("Auto upload when editing annotations")
            end,
            callback = function()
                self.settings.auto_upload_on_annotate = not self.settings.auto_upload_on_annotate
                self:updateAutoSyncSettings()
                G_reader_settings:saveSetting(self.plugin_id, self.settings)
                rebuildAndShow()
            end
        }
    })
    
    table.insert(buttons, {
        {
            text_func = function()
                return (self.settings.auto_upload_on_close and "✓ " or "  ") .. _("Auto upload when closing book")
            end,
            callback = function()
                self.settings.auto_upload_on_close = not self.settings.auto_upload_on_close
                self:updateAutoSyncSettings()
                G_reader_settings:saveSetting(self.plugin_id, self.settings)
                rebuildAndShow()
            end
        }
    })
    
    table.insert(buttons, {
        {
            text_func = function()
                return (self.settings.auto_upload_on_suspend and "✓ " or "  ") .. _("Auto upload when device suspends")
            end,
            callback = function()
                self.settings.auto_upload_on_suspend = not self.settings.auto_upload_on_suspend
                self:updateAutoSyncSettings()
                G_reader_settings:saveSetting(self.plugin_id, self.settings)
                rebuildAndShow()
            end
        }
    })
    
    table.insert(buttons, {})
    
    table.insert(buttons, {
        {
            text_func = function()
                local enabled = self.settings.auto_download_on_open and self.settings.auto_download_mode == "override"
                return (enabled and "✓ " or "  ") .. _("Auto download when opening book (Overwrite)")
            end,
            callback = function()
                if self.settings.auto_download_on_open and self.settings.auto_download_mode == "override" then
                    self.settings.auto_download_on_open = false
                else
                    self.settings.auto_download_on_open = true
                    self.settings.auto_download_mode = "override"
                end
                self:updateAutoSyncSettings()
                G_reader_settings:saveSetting(self.plugin_id, self.settings)
                rebuildAndShow()
            end
        }
    })
    
    table.insert(buttons, {
        {
            text_func = function()
                local enabled = self.settings.auto_download_on_open and self.settings.auto_download_mode == "merge"
                return (enabled and "✓ " or "  ") .. _("Auto download when opening book (Merge)")
            end,
            callback = function()
                if self.settings.auto_download_on_open and self.settings.auto_download_mode == "merge" then
                    self.settings.auto_download_on_open = false
                else
                    self.settings.auto_download_on_open = true
                    self.settings.auto_download_mode = "merge"
                end
                self:updateAutoSyncSettings()
                G_reader_settings:saveSetting(self.plugin_id, self.settings)
                rebuildAndShow()
            end
        }
    })
    
    table.insert(buttons, {})
    
    -- 自动同步排除目录
    local exclude_count = #(self.settings.exclude_dirs or {})
    local exclude_text = (exclude_count > 0) and 
        string.format(_("Auto Sync Exclude Directories (%d)"), exclude_count) or
        _("Auto Sync Exclude Directories")
    
    table.insert(buttons, {
        {
            text = exclude_text,
            callback = function()
                if self_ref._current_settings_dialog then
                    UIManager:close(self_ref._current_settings_dialog)
                    self_ref._current_settings_dialog = nil
                end
                self_ref:showExcludeDirDialog()
            end
        }
    })
    
    table.insert(buttons, {}) 

    table.insert(buttons, {
        {
            text_func = function()
                return (self.settings.upload_json and not self.settings.use_notemark_format and "✓ " or "  ") .. _("Additional JSON Backup (Original format)")
            end,
            callback = function()
                if self.settings.upload_json and not self.settings.use_notemark_format then
                    self.settings.upload_json = false
                    self.settings.use_notemark_format = false
                else
                    self.settings.upload_json = true
                    self.settings.use_notemark_format = false
                end
                G_reader_settings:saveSetting(self.plugin_id, self.settings)
                rebuildAndShow()
            end
        }
    })
    
    table.insert(buttons, {
        {
            text_func = function()
                return (self.settings.upload_json and self.settings.use_notemark_format and "✓ " or "  ") .. _("Additional JSON Backup (NoteMarkData format)")
            end,
            callback = function()
                if self.settings.upload_json and self.settings.use_notemark_format then
                    self.settings.upload_json = false
                    self.settings.use_notemark_format = false
                else
                    self.settings.upload_json = true
                    self.settings.use_notemark_format = true
                end
                G_reader_settings:saveSetting(self.plugin_id, self.settings)
                rebuildAndShow()
            end
        }
    })
    
    table.insert(buttons, {})
    
    table.insert(buttons, {
        {
            text_func = function()
                return (self.settings.override_keep_local_settings and "✓ " or "  ") .. _("Keep local document settings when overwriting")
            end,
            callback = function()
                self.settings.override_keep_local_settings = not self.settings.override_keep_local_settings
                G_reader_settings:saveSetting(self.plugin_id, self.settings)
                rebuildAndShow()
            end
        }
    })
    
    table.insert(buttons, {
        {
            text_func = function()
                return (self.settings.sync_log_enabled and "✓ " or "  ") .. _("Enable Cloud Sync Log")
            end,
            callback = function()
                self.settings.sync_log_enabled = not self.settings.sync_log_enabled
                G_reader_settings:saveSetting(self.plugin_id, self.settings)
                if self.settings.sync_log_enabled then
                    local sync_log = dofile(_plugin_dir .. "sync_log.lua")
                    sync_log.sync_log()
                end
                rebuildAndShow()
            end
        }
    })
    
    table.insert(buttons, {
        {
            text_func = function()
                return (self.settings.auto_sync_notify and "✓ " or "  ") .. _("Show notification on auto sync")
            end,
            callback = function()
                self.settings.auto_sync_notify = not self.settings.auto_sync_notify
                G_reader_settings:saveSetting(self.plugin_id, self.settings)
                rebuildAndShow()
            end
        }
    })
    
    table.insert(buttons, {})
    
    table.insert(buttons, {
        {
            text = _("View Sync Log"),
            callback = function()
                self:viewSyncLog()
                if self_ref._current_settings_dialog then
                    UIManager:close(self_ref._current_settings_dialog)
                    self_ref._current_settings_dialog = nil
                end
            end
        }
    })
    
    table.insert(buttons, {
        {
            text = _("Clear Cloud Sync Log"),
            callback = function()
                self:confirmClearCloudLog()
                if self_ref._current_settings_dialog then
                    UIManager:close(self_ref._current_settings_dialog)
                    self_ref._current_settings_dialog = nil
                end
            end
        }
    })
    
    table.insert(buttons, {
        {
            text = _("Plugin Info"),
            callback = function()
                self:showPluginInfo()
                if self_ref._current_settings_dialog then
                    UIManager:close(self_ref._current_settings_dialog)
                    self_ref._current_settings_dialog = nil
                end
            end
        }
    })
    
    table.insert(buttons, {
        {
            text = _("Updates") .. "  (" .. _("Current version") .. ": " .. self.VERSION .. ")",
            callback = function()
                local update = dofile(_plugin_dir .. "update.lua")
                update.check_for_updates(false, self)
                if self_ref._current_settings_dialog then
                    UIManager:close(self_ref._current_settings_dialog)
                    self_ref._current_settings_dialog = nil
                end
            end
        }
    })
    
    local dialog = ButtonDialog:new{
        title = _("Cloud Library - Quick Settings"),
        title_align = "center",
        buttons = buttons,
        width = math.floor(Screen:getWidth() * 0.7),
        max_height = math.floor(Screen:getHeight() * 0.5),
    }
    self._current_settings_dialog = dialog
    UIManager:show(dialog)
end

function CloudLibraryPlugin:showMetadataNamingModeDialog()
    local ButtonDialog = require("ui/widget/buttondialog")
    local UIManager = require("ui/uimanager")
    local Screen = Device.screen
    local _ = require("gettext")
    
    local current_mode = self.settings.metadata_naming_mode or "metadata"
    
    local dialog
    local buttons = {
        {
            {
                text = (current_mode == "filename" and "✓ " or "  ") .. _("Use Filename"),
                callback = function()
                    self.settings.metadata_naming_mode = "filename"
                    G_reader_settings:saveSetting(self.plugin_id, self.settings)
                    local utils = dofile(_plugin_dir .. "utils.lua")
                    utils.show_msg(_("Metadata naming: Filename"))
                    if dialog then
                        UIManager:close(dialog)
                    end
                end
            }
        },
        {
            {
                text = (current_mode == "metadata" and "✓ " or "  ") .. _("Use Book Title (default)"),
                callback = function()
                    self.settings.metadata_naming_mode = "metadata"
                    G_reader_settings:saveSetting(self.plugin_id, self.settings)
                    local utils = dofile(_plugin_dir .. "utils.lua")
                    utils.show_msg(_("Metadata naming: Book title"))
                    if dialog then
                        UIManager:close(dialog)
                    end
                end
            }
        },
        {
            {
                text = (current_mode == "title_author" and "✓ " or "  ") .. _("Use Title_Author"),
                callback = function()
                    self.settings.metadata_naming_mode = "title_author"
                    G_reader_settings:saveSetting(self.plugin_id, self.settings)
                    local utils = dofile(_plugin_dir .. "utils.lua")
                    utils.show_msg(_("Metadata naming: Title_Author"))
                    if dialog then
                        UIManager:close(dialog)
                    end
                end
            }
        },
        {},
        {
            {
                text = _("Back"),
                callback = function()
                    if dialog then
                        UIManager:close(dialog)
                    end
                end
            }
        }
    }
    
    dialog = ButtonDialog:new{
        title = _("Metadata Naming Rules"),
        title_align = "center",
        buttons = buttons,
        width = math.floor(Screen:getWidth() * 0.7),
    }
    UIManager:show(dialog)
end

function CloudLibraryPlugin:showBookNamingModeDialog()
    local ButtonDialog = require("ui/widget/buttondialog")
    local UIManager = require("ui/uimanager")
    local Screen = Device.screen
    local _ = require("gettext")
    
    local current_mode = self.settings.book_naming_mode or "title"
    
    local dialog
    local buttons = {
        {
            {
                text = (current_mode == "filename" and "✓ " or "  ") .. _("Use Filename"),
                callback = function()
                    self.settings.book_naming_mode = "filename"
                    G_reader_settings:saveSetting(self.plugin_id, self.settings)
                    local utils = dofile(_plugin_dir .. "utils.lua")
                    utils.show_msg(_("Book naming: Filename"))
                    if dialog then
                        UIManager:close(dialog)
                    end
                end
            }
        },
        {
            {
                text = (current_mode == "title" and "✓ " or "  ") .. _("Use Book Title (default)"),
                callback = function()
                    self.settings.book_naming_mode = "title"
                    G_reader_settings:saveSetting(self.plugin_id, self.settings)
                    local utils = dofile(_plugin_dir .. "utils.lua")
                    utils.show_msg(_("Book naming: Book title"))
                    if dialog then
                        UIManager:close(dialog)
                    end
                end
            }
        },
        {
            {
                text = (current_mode == "title_author" and "✓ " or "  ") .. _("Use Title_Author"),
                callback = function()
                    self.settings.book_naming_mode = "title_author"
                    G_reader_settings:saveSetting(self.plugin_id, self.settings)
                    local utils = dofile(_plugin_dir .. "utils.lua")
                    utils.show_msg(_("Book naming: Title_Author"))
                    if dialog then
                        UIManager:close(dialog)
                    end
                end
            }
        },
        {},
        {
            {
                text = _("Back"),
                callback = function()
                    if dialog then
                        UIManager:close(dialog)
                    end
                end
            }
        }
    }
    
    dialog = ButtonDialog:new{
        title = _("Book Naming Rules"),
        title_align = "center",
        buttons = buttons,
        width = math.floor(Screen:getWidth() * 0.7),
    }
    UIManager:show(dialog)
end

function CloudLibraryPlugin:showManualDownloadModeDialog()
    local ButtonDialog = require("ui/widget/buttondialog")
    local UIManager = require("ui/uimanager")
    local Screen = Device.screen
    local _ = require("gettext")
    
    -- 改为 manual_download_mode
    local current_mode = self.settings.manual_download_mode or "merge"
    
    local dialog
    local buttons = {
        {
            {
                text = (current_mode == "override" and "✓ " or "  ") .. _("Overwrite"),
                callback = function()
                    self.settings.manual_download_mode = "override"
                    G_reader_settings:saveSetting(self.plugin_id, self.settings)
                    local utils = dofile(_plugin_dir .. "utils.lua")
                    utils.show_msg(_("Metadata download mode (manual): Overwrite"))
                    if dialog then
                        UIManager:close(dialog)
                    end
                end
            }
        },
        {
            {
                text = (current_mode == "merge" and "✓ " or "  ") .. _("Merge"),
                callback = function()
                    self.settings.manual_download_mode = "merge"
                    G_reader_settings:saveSetting(self.plugin_id, self.settings)
                    local utils = dofile(_plugin_dir .. "utils.lua")
                    utils.show_msg(_("Metadata download mode (manual): Merge"))
                    if dialog then
                        UIManager:close(dialog)
                    end
                end
            }
        },
        {},
        {
            {
                text = _("Back"),
                callback = function()
                    if dialog then
                        UIManager:close(dialog)
                    end
                end
            }
        }
    }
    
    dialog = ButtonDialog:new{
        title = _("Metadata Download Mode (Manual)"),
        title_align = "center",
        buttons = buttons,
        width = math.floor(Screen:getWidth() * 0.7),
    }
    UIManager:show(dialog)
end

function CloudLibraryPlugin:showExcludeDirDialog()
    local ButtonDialog = require("ui/widget/buttondialog")
    local UIManager = require("ui/uimanager")
    local Screen = Device.screen
    local _ = require("gettext")
    
    local self_ref = self
    local exclude_dirs = self.settings.exclude_dirs or {}
    
    local function rebuildDialog()
        if self_ref._exclude_dir_dialog then
            UIManager:close(self_ref._exclude_dir_dialog)
            self_ref._exclude_dir_dialog = nil
        end
        self_ref:showExcludeDirDialog()
    end
    
    local buttons = {}
    
    -- 添加新目录按钮
    table.insert(buttons, {
        {
            text = _("+ Add Directory to Exclude"),
            callback = function()
                if self_ref._exclude_dir_dialog then
                    UIManager:close(self_ref._exclude_dir_dialog)
                    self_ref._exclude_dir_dialog = nil
                end
                self_ref:addExcludeDir()
            end
        }
    })
    
    table.insert(buttons, {})
    
    -- 显示已排除的目录列表
    if #exclude_dirs == 0 then
        table.insert(buttons, {
            {
                text = _("  (No directories excluded)"),
                enabled = false,
                alignment = "center",
            }
        })
    else
        for i, dir in ipairs(exclude_dirs) do
            local display_dir = dir
            if #display_dir > 35 then
                display_dir = "..." .. display_dir:sub(-32)
            end
            table.insert(buttons, {
                {
                    text = string.format("  %s", display_dir),
                    enabled = false,
                }
            })
            table.insert(buttons, {
                {
                    text = string.format("    ✕ %s", _("Remove")),
                    callback = function()
                        self_ref:removeExcludeDir(i)
                    end
                }
            })
            if i < #exclude_dirs then
                table.insert(buttons, {})
            end
        end
    end
    
    table.insert(buttons, {})
    
    -- 返回按钮
    table.insert(buttons, {
        {
            text = _("Back"),
            callback = function()
                if self_ref._exclude_dir_dialog then
                    UIManager:close(self_ref._exclude_dir_dialog)
                    self_ref._exclude_dir_dialog = nil
                end
                self_ref:showSettingsDialog()
            end
        },
        {
            text = _("Cancel"),
            id = "close",
            callback = function()
                if self_ref._exclude_dir_dialog then
                    UIManager:close(self_ref._exclude_dir_dialog)
                    self_ref._exclude_dir_dialog = nil
                end
            end
        }
    })
    
    local dialog = ButtonDialog:new{
        title = _("Auto Sync Exclude Directories"),
        title_align = "center",
        buttons = buttons,
        width = math.floor(Screen:getWidth() * 0.75),
        max_height = math.floor(Screen:getHeight() * 0.6),
    }
    
    self_ref._exclude_dir_dialog = dialog
    UIManager:show(dialog)
end

function CloudLibraryPlugin:onCloudLibraryBatchUploadMetadata()
    self.manual_sync:batchSyncWithFMSelection(true, false)
end

function CloudLibraryPlugin:onCloudLibraryBatchDownloadMetadataSmart()
    local is_merge = (self.settings.manual_download_mode == "merge")
    self.manual_sync:batchSyncWithFMSelection(false, is_merge)
end

function CloudLibraryPlugin:onCloudLibraryBatchUploadBooks()
    local BookSync = dofile(_plugin_dir .. "book_sync.lua")
    BookSync.batchUploadWithFMSelection(self)
end

function CloudLibraryPlugin:onCloudLibraryBatchDownloadBooks()
    self:batchDownloadBooks()
end

function CloudLibraryPlugin:toggleAutoSyncQuick()
    local is_auto_mode = self.settings.auto_upload_on_close and 
                         self.settings.auto_upload_on_suspend and 
                         self.settings.auto_download_on_open
    
    if is_auto_mode then
        self.settings.auto_upload_on_annotate = false
        self.settings.auto_upload_on_close = false
        self.settings.auto_upload_on_suspend = false
        self.settings.auto_download_on_open = false
        self.settings.auto_download_mode = "merge"
        
        self:updateAutoSyncSettings()
        G_reader_settings:saveSetting(self.plugin_id, self.settings)
        
        local utils = dofile(_plugin_dir .. "utils.lua")
        utils.show_msg(_("Cloud Library: All auto sync disabled"))
    else
        self.settings.auto_upload_on_annotate = false
        self.settings.auto_upload_on_close = true
        self.settings.auto_upload_on_suspend = true
        self.settings.auto_download_on_open = true
        self.settings.auto_download_mode = "merge"
        
        self:updateAutoSyncSettings()
        G_reader_settings:saveSetting(self.plugin_id, self.settings)
        
        local utils = dofile(_plugin_dir .. "utils.lua")
        utils.show_msg(_("Cloud Library: Worry-Free Sync Mode enabled (auto upload on close/suspend + auto download merge on open)"))
    end
end

return CloudLibraryPlugin
