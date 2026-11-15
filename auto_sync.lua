-- Get plugin directory
local src = debug.getinfo(1, "S").source or ""
local path = (src:sub(1, 1) == "@") and src:sub(2):match("^(.*)/[^/]+$") or nil
local _plugin_dir

if path then
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

local logger = require("logger")
local UIManager = require("ui/uimanager")
local Notification = require("ui/widget/notification")
local lfs = require("libs/libkoreader-lfs")
local DataStorage = require("datastorage")
local _ = require("gettext")
local utils = dofile(_plugin_dir .. "utils.lua")
local Event = require("ui/event")

local AutoSync = {
    is_syncing = false,
    skip_auto_upload = false,
    skip_auto_download = false,
    settings = nil,
    plugin = nil,
}

function AutoSync:new(plugin, settings)
    local obj = {}
    setmetatable(obj, self)
    self.__index = self
    
    obj.plugin = plugin
    obj.settings = settings
    obj.is_syncing = false
    obj.skip_auto_upload = false
    obj.skip_auto_download = false
    obj._incomplete = {}
    
    return obj
end

function AutoSync:shouldUpload(source)
    if source == "annotate" then
        return self.settings.auto_upload_on_annotate
    elseif source == "close" then
        return self.settings.auto_upload_on_close
    elseif source == "suspend" then
        return self.settings.auto_upload_on_suspend
    end
    return false
end

function AutoSync:shouldDownload(source)
    if source == "open" then
        return self.settings.auto_download_on_open
    end
    return false
end

function AutoSync:sync(document, is_upload, source)
    if not document then 
        return 
    end
    
    -- ===== 先获取文件路径 =====
    local file = document.file
    if not file or not lfs.attributes(file, "mode") then
        return
    end

    -- ===== 新增：检查是否在排除目录中 =====
    local exclude_dirs = self.settings.exclude_dirs or {}
    if utils.is_path_excluded(file, exclude_dirs) then
        if self.settings.auto_sync_notify then
            local book_title = document.title or (document.file and document.file:match("([^/]+)$"):gsub("%.[^%.]+$", "")) or "book"
            self:showNotification(book_title, _("Auto sync skipped (directory excluded)"), nil, false)
        end
        return
    end
    
    local NetworkMgr = require("ui/network/manager")
    if not NetworkMgr:isOnline() then
        if self.settings.auto_sync_notify then
            local book_title = document.title or (document.file and document.file:match("([^/]+)$"):gsub("%.[^%.]+$", "")) or "book"
            self:showNotification(book_title, _("Auto sync failed (Network disconnected)"), nil, false)
        end
        return
    end
    
    local remote = dofile(_plugin_dir .. "remote.lua")
    local server = remote.get_server()
    if not server then
        if self.settings.auto_sync_notify then
            local book_title = document.title or (document.file and document.file:match("([^/]+)$"):gsub("%.[^%.]+$", "")) or "book"
            self:showNotification(book_title, _("Auto sync failed (Cloud storage not configured)"), nil, false)
        end
        return
    end
    
    if not server.url or server.url == "" then
        if self.settings.auto_sync_notify then
            local book_title = document.title or (document.file and document.file:match("([^/]+)$"):gsub("%.[^%.]+$", "")) or "book"
            self:showNotification(book_title, _("Auto sync failed (Cloud directory not set)"), nil, false)
        end
        return
    end
    
    local api = remote.get_api(server)
    if not api then
        if self.settings.auto_sync_notify then
            local book_title = document.title or (document.file and document.file:match("([^/]+)$"):gsub("%.[^%.]+$", "")) or "book"
            self:showNotification(book_title, _("Auto sync failed (Unsupported cloud service)"), nil, false)
        end
        return
    end

    if is_upload and self.skip_auto_upload then
        return
    end
    
    if not is_upload and self.skip_auto_download then
        return
    end
    
    if self.is_syncing then
        return
    end
    
    if is_upload then
        if not self:shouldUpload(source) then
            return
        end
    else
        if not self:shouldDownload(source) then
            return
        end
    end
    
    local source_desc = ""
    if source == "annotate" then
        source_desc = _("Edit annotation")
    elseif source == "close" then
        source_desc = _("Close book")
    elseif source == "suspend" then
        source_desc = _("Device suspend")
    elseif source == "open" then
        source_desc = _("Open book")
    end
    
    -- 先落盘当前打开书的 settings，确保 sidecar 已生成
    local ReaderUI = require("apps/reader/readerui")
    local current_ui = ReaderUI.instance
    if current_ui and current_ui.document and current_ui.document.file == file then
        current_ui:saveSettings()
        UIManager:broadcastEvent(Event:new("FlushSettings"))
    end

    local DocSettings = require("docsettings")
    local metadata_file = DocSettings:findSidecarFile(file)
    local props = {}
    if self.plugin.ui and self.plugin.ui.bookinfo then
        props = self.plugin.ui.bookinfo:getDocProps(file, nil, true) or {}
    end
    local title = props.title or props.display_title or file:match("([^/]+)$"):gsub("%.[^%.]+$", "")
    local author = props.authors
    if type(author) == "table" then
        author = author[1]
    end
    
    local book = {
        file = file,
        metadata = metadata_file,
        title = title,
        book_basename = file:match("([^/]+)$"):gsub("%.[^%.]+$", ""),
        author = author,
    }
    
    if not metadata_file or not lfs.attributes(metadata_file, "mode") then
        local error_info = {
            reason = _("Local metadata file not found"),
            solution = _("Please open the book first to generate metadata file")
        }
        self:writeLog(book, source_desc, is_upload, false, error_info.reason, nil, error_info.solution)
        self:updateLastSync(_("Auto sync") .. "(" .. source_desc .. ")-" .. _("Failed"))
        self:showNotification(book.title, _("Sync failed"), nil, false)
        return
    end

    if is_upload and self._incomplete[file] then
        self:writeLog(book, source_desc, true, false,
            _("Skipped: previous auto download failed, cloud may contain data not present locally"))
        self:showNotification(book.title, _("Auto upload skipped (previous download failed)"), nil, false)
        return
    end

    self.is_syncing = true
    
    UIManager:scheduleIn(0, function()
        local remote = dofile(_plugin_dir .. "remote.lua")
        local success, error_type
        local naming_mode = self.settings.metadata_naming_mode or "metadata"
        
        if is_upload then
            success, error_type = remote.upload_book(book, naming_mode)
            
            if success then
                self:writeLog(book, source_desc, true, true)
                self:updateLastSync(_("Metadata sync") .. "-" .. _("Auto sync") .. "(" .. source_desc .. ")-" .. _("Upload successful"))
                self:showNotification(book.title, _("Auto backup successful"), nil, true)
            else
                local error_info = remote.get_error_message(error_type, true, naming_mode)
                self:writeLog(book, source_desc, true, false, error_info.reason, nil, error_info.solution)
                self:updateLastSync(_("Metadata sync") .. "-" .. _("Auto sync") .. "(" .. source_desc .. ")-" .. _("Upload failed"))
                local fail_msg = string.format(_("Auto backup failed (%s)"), error_info.reason)
                self:showNotification(book.title, fail_msg, nil, false)
            end
        else
            local mode_desc = (self.settings.auto_download_mode == "merge") and _("Merge") or _("Overwrite")
            
            if self.settings.auto_download_mode == "merge" then
                success, error_type = remote.download_book_merge(book, naming_mode)
            else
                success, error_type = remote.download_book(book, naming_mode)
            end
            
            if success then
                self:writeLog(book, source_desc, false, true, nil, mode_desc)
                self:updateLastSync(_("Metadata sync") .. "-" .. _("Auto sync") .. "(" .. source_desc .. ")-" .. _("Download successful") .. "(" .. mode_desc .. ")")
                self:showNotification(book.title, _("Auto update successful"), mode_desc, true)
            else
                local error_info = remote.get_error_message(error_type, false, naming_mode)
                self:writeLog(book, source_desc, false, false, error_info.reason, nil, error_info.solution)
                self:updateLastSync(_("Metadata sync") .. "-" .. _("Auto sync") .. "(" .. source_desc .. ")-" .. _("Download failed"))
                local fail_msg = string.format(_("Auto update failed (%s)"), error_info.reason)
                self:showNotification(book.title, fail_msg, mode_desc, false)
            end
        end
        
        self.is_syncing = false
    end)
end

function AutoSync:showNotification(title, operation, mode, is_success)
    if not self.settings.auto_sync_notify then
        return
    end

    local max_bytes = 30
    local display_title = title
    if title and #title > max_bytes then
        local truncated = title:sub(1, max_bytes)
        local util = require("util")
        display_title = util.fixUtf8(truncated, "") .. "..."
    end

    local icon = is_success and "✓" or "✗"
    local text
    if mode then
        text = string.format("%s %s - %s - %s", icon, display_title, operation, mode)
    else
        text = string.format("%s %s - %s", icon, display_title, operation)
    end
    
    UIManager:show(Notification:new{
        text = text,
        timeout = 2,
    })
end

function AutoSync:updateLastSync(descriptor)
    self.settings.last_sync = os.date("%Y-%m-%d %H:%M:%S") .. " (" .. descriptor .. ")"
    G_reader_settings:saveSetting(self.plugin.plugin_id, self.settings)
end

function AutoSync:writeLog(book, source_desc, is_upload, success, error_reason, download_mode, solution)
    local timestamp = os.date("%Y-%m-%d %H:%M:%S")
    local log_path = utils.get_log_path()
    
    local device_name = utils.get_device_name()
    local device_id = utils.get_device_id()
    
    local operation_type = ""
    if is_upload then
        operation_type = string.format(_("Metadata sync") .. "-" .. _("Auto sync") .. "-%s-" .. _("Upload"), source_desc)
    else
        local mode_desc = (download_mode == "merge") and _("Merge") or _("Overwrite")
        operation_type = string.format(_("Metadata sync") .. "-" .. _("Auto sync") .. "-%s-" .. _("Download") .. "(%s)", source_desc, mode_desc)
    end
    
    local new_record = {}
    table.insert(new_record, utils.SEPARATOR_LINE)
    table.insert(new_record, string.format(_("Sync time: %s"), timestamp))
    table.insert(new_record, string.format(_("Device: %s"), device_name))
    table.insert(new_record, string.format(_("Device ID: %s"), device_id))
    table.insert(new_record, string.format(_("Operation type: %s"), operation_type))
    table.insert(new_record, utils.SEPARATOR_LINE)
    
    if success then
        table.insert(new_record, string.format(_("[Success] ✓ %s"), book.title or book.book_basename))
    else
        table.insert(new_record, string.format(_("[Failed] ✗ %s"), book.title or book.book_basename))
        table.insert(new_record, string.format(_("Reason: %s"), error_reason or _("Unknown error")))
        if solution then
            table.insert(new_record, string.format(_("Solution: %s"), solution))
        end
    end
    table.insert(new_record, "")
    table.insert(new_record, "")
    
    local content = table.concat(new_record, "\n") .. "\n"
    
    utils.write_log(log_path, content)
    
    local settings = G_reader_settings:readSetting("cloud_library_plugin", {})
    if settings.sync_log_enabled then
        pcall(function()
            local sync_log = dofile(_plugin_dir .. "sync_log.lua")
            sync_log.sync_log(true)
        end)
    end
end

function AutoSync:setSkipUpload(skip)
    self.skip_auto_upload = skip
end

function AutoSync:setSkipDownload(skip)
    self.skip_auto_download = skip
end

return AutoSync
