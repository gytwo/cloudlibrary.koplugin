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
local _ = require("gettext")
local utils = dofile(_plugin_dir .. "utils.lua") 

local Hooks = {}

function Hooks:new(plugin, auto_sync)
    local obj = {}
    setmetatable(obj, self)
    self.__index = self
    
    obj.plugin = plugin
    obj.auto_sync = auto_sync
    obj.settings = plugin.settings
    
    return obj
end

function Hooks:hookAnnotationModified()
    local ReaderAnnotation = require("apps/reader/modules/readerannotation")
    if not ReaderAnnotation or ReaderAnnotation._cloudlibrary_hooked then
        return
    end
    
    local original = ReaderAnnotation.onAnnotationsModified
    if not original then
        return
    end
    
    ReaderAnnotation._cloudlibrary_hooked = true
    
    local self_auto_sync = self.auto_sync
    local last_delete_time = 0
    
    ReaderAnnotation.onAnnotationsModified = function(self_annot, items)
        local result = original(self_annot, items)
        
        local ReaderUI = require("apps/reader/readerui")
        local ui = ReaderUI.instance
        
        if not (ui and ui.document) or not self_auto_sync:shouldUpload("annotate") then
            return result
        end
        
        local is_deletion = items.index_modified and items.index_modified < 0
        if is_deletion then
            local now = os.time()
            if now - last_delete_time < 1 then
                last_delete_time = now
                return result
            end
            last_delete_time = now
        end
        
        self_auto_sync:sync(ui.document, true, "annotate")
        
        return result
    end
end

function Hooks:patchNoteEdit()
    local ReaderBookmark = require("apps/reader/modules/readerbookmark")
    
    local original_setBookmarkNote = ReaderBookmark.setBookmarkNote
    
    ReaderBookmark.setBookmarkNote = function(self, index, is_new_note, text, callback)
        original_setBookmarkNote(self, index, is_new_note, text, callback)
        
        local annotation = self.ui.annotation.annotations[index]
        if annotation then
            annotation.datetime_updated = os.date("%Y-%m-%d %H:%M:%S")
        end
    end
end

function Hooks:hookOnReaderReady()
    local ReaderUI = require("apps/reader/readerui")
    if not ReaderUI or ReaderUI._cloudlibrary_hooked then
        return
    end

    self:patchNoteEdit()

    local original = ReaderUI.showReader
    if not original then
        return
    end
    
    ReaderUI._cloudlibrary_hooked = true
    
    local self_plugin = self.plugin
    local self_auto_sync = self.auto_sync
    
    ReaderUI.showReader = function(...)
        local args = {...}
        
        local file = nil
        if #args >= 2 and type(args[2]) == "string" then
            file = args[2]
        end
        
        local skip_download = G_reader_settings:readSetting("cloudlibrary_skip_auto_download", false)
        
        if skip_download then
            G_reader_settings:saveSetting("cloudlibrary_skip_auto_download", false)
        else
            local should = self_auto_sync:shouldDownload("open")
            
            -- ===== 提前获取书籍信息用于通知 =====
            if file and type(file) == "string" and should then
                -- 先获取书名（用于通知）
                local props = {}
                if self_plugin.ui and self_plugin.ui.bookinfo then
                    props = self_plugin.ui.bookinfo:getDocProps(file, nil, true) or {}
                end
                local title = props.title or props.display_title or 
                              file:match("([^/]+)$"):gsub("%.[^%.]+$", "")
                              
                -- ===== 检查是否为书籍 =====               
                -- 非支持书籍直接跳过打开时自动下载元数据
                    if not utils.is_supported_book(file) then
                        local result = original(...)
                        local ui_instance = ReaderUI.instance
                        if ui_instance and not ui_instance.CloudLibrary and self_plugin then
                            ui_instance.CloudLibrary = self_plugin
                        end
                        return result
                    end                
                    
                -- ===== 检查自动同步排除目录 =====
                local exclude_dirs = self_plugin.settings.exclude_dirs or {}
                if utils.is_path_excluded(file, exclude_dirs) then
                    self_auto_sync:showNotification(title, _("Auto update skipped (directory excluded)"), nil, false)
                    local result = original(...)
                    local ui_instance = ReaderUI.instance
                    if ui_instance and not ui_instance.CloudLibrary and self_plugin then
                        ui_instance.CloudLibrary = self_plugin
                    end
                    return result
                end

                -- ===================================
                
                -- 👇 前置检查1：网络连接
                local NetworkMgr = require("ui/network/manager")
                if not NetworkMgr:isOnline() then
                    self_auto_sync:showNotification(title, _("Auto update failed (Network disconnected)"), nil, false)
                    if self_auto_sync._incomplete then
                        self_auto_sync._incomplete[file] = true
                    end
                    local result = original(...)
                    local ui_instance = ReaderUI.instance
                    if ui_instance and not ui_instance.CloudLibrary and self_plugin then
                        ui_instance.CloudLibrary = self_plugin
                    end
                    return result
                end

                -- 👇 前置检查2：服务器配置
                local remote = dofile(_plugin_dir .. "remote.lua")
                local server = remote.get_server()
                if not server then
                    self_auto_sync:showNotification(title, _("Auto update failed (Cloud storage not configured)"), nil, false)
                    if self_auto_sync._incomplete then
                        self_auto_sync._incomplete[file] = true
                    end
                    local result = original(...)
                    local ui_instance = ReaderUI.instance
                    if ui_instance and not ui_instance.CloudLibrary and self_plugin then
                        ui_instance.CloudLibrary = self_plugin
                    end
                    return result
                end

                -- 👇 前置检查3：云端目录
                if not server.url or server.url == "" then
                    self_auto_sync:showNotification(title, _("Auto update failed (Cloud directory not set)"), nil, false)
                    if self_auto_sync._incomplete then
                        self_auto_sync._incomplete[file] = true
                    end
                    local result = original(...)
                    local ui_instance = ReaderUI.instance
                    if ui_instance and not ui_instance.CloudLibrary and self_plugin then
                        ui_instance.CloudLibrary = self_plugin
                    end
                    return result
                end

                -- 👇 前置检查4：云服务类型
                local api = remote.get_api(server)
                if not api then
                    self_auto_sync:showNotification(title, _("Auto update failed (Unsupported cloud service)"), nil, false)
                    if self_auto_sync._incomplete then
                        self_auto_sync._incomplete[file] = true
                    end
                    local result = original(...)
                    local ui_instance = ReaderUI.instance
                    if ui_instance and not ui_instance.CloudLibrary and self_plugin then
                        ui_instance.CloudLibrary = self_plugin
                    end
                    return result
                end
                -- 👆
                
                local DocSettings = require("docsettings")
                local metadata_file = DocSettings:findSidecarFile(file)
                
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
                
                local success, error_type
                local download_mode = self_auto_sync.settings.auto_download_mode
                local mode_desc_for_show = (download_mode == "merge") and _("Merge") or _("Overwrite")
                local naming_mode = self_auto_sync.settings.metadata_naming_mode or "metadata"

                if download_mode == "merge" then
                    success, error_type = remote.download_book_merge_before_open(book, naming_mode)
                else
                    success, error_type = remote.download_book_before_open(book, naming_mode)
                end

                if success then
                    self_auto_sync:updateLastSync(string.format(_("Metadata sync") .. "-" .. _("Auto sync") .. "(" .. _("Open book") .. ")-" .. _("Download successful") .. "(%s)", mode_desc_for_show))
                    self_auto_sync:writeLog(book, _("Open book"), false, true, nil, download_mode) 
                    self_auto_sync:showNotification(title, _("Auto update successful"), mode_desc_for_show, true)
                    if self_auto_sync._incomplete then
                        self_auto_sync._incomplete[file] = nil
                    end
                else
                    local error_info = remote.get_error_message(error_type, false, naming_mode)
                    self_auto_sync:writeLog(book, _("Open book"), false, false, error_info.reason, nil, error_info.solution)
                    local fail_msg = string.format(_("Auto update failed (%s)"), error_info.reason)
                    self_auto_sync:showNotification(title, fail_msg, mode_desc_for_show, false)
                    if self_auto_sync._incomplete then
                        if error_type == "cloud_file_not_found" then
                            self_auto_sync._incomplete[file] = nil
                        else
                            self_auto_sync._incomplete[file] = true
                        end
                    end
                end
            end
        end
        
        local result = original(...)
        
        local ui_instance = ReaderUI.instance
        if ui_instance and not ui_instance.CloudLibrary and self_plugin then
            ui_instance.CloudLibrary = self_plugin
        end
        
        return result
    end
end

function Hooks:hookOnClose()
    local ui_instance = self.plugin.ui
    if not ui_instance then
        return
    end
    
    local original = ui_instance.onClose
    if not original then
        return
    end
    
    local self_plugin = self.plugin
    local self_auto_sync = self.auto_sync
    
    ui_instance.onClose = function(...)
        local skip = self_plugin.auto_sync and self_plugin.auto_sync.skip_auto_upload
        
        if skip then
            if self_plugin.auto_sync then
                self_plugin.auto_sync.skip_auto_upload = false
            end
            return original(...)
        end
        
        if self_auto_sync:shouldUpload("close") and ui_instance and ui_instance.document then
            self_auto_sync:sync(ui_instance.document, true, "close")
        end
        
        return original(...)
    end
end

function Hooks:hookOnSuspend()
    local ReaderDeviceStatus = require("apps/reader/modules/readerdevicestatus")
    if not ReaderDeviceStatus then
        return
    end
    
    local original = ReaderDeviceStatus.onSuspend
    if not original then
        return
    end
    
    local self_auto_sync = self.auto_sync
    local ui_instance = self.plugin.ui
    
    ReaderDeviceStatus.onSuspend = function(self_status)
        local result = original(self_status)
        
        if self_auto_sync:shouldUpload("suspend") and ui_instance and ui_instance.document then
            self_auto_sync:sync(ui_instance.document, true, "suspend")
        end
        
        return result
    end
end

return Hooks