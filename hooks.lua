local logger = require("logger")
local UIManager = require("ui/uimanager")
local Notification = require("ui/widget/notification")
local lfs = require("libs/libkoreader-lfs")

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
        
        -- 直接检查自动上传是否开启，不再依赖 auto_sync_mode
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
        -- 调用原方法保存笔记
        original_setBookmarkNote(self, index, is_new_note, text, callback)
        
        -- 只更新时间戳，不触发事件
        local annotation = self.ui.annotation.annotations[index]
        if annotation then
            annotation.datetime_updated = os.date("%Y-%m-%d %H:%M:%S")
            logger.info("CloudLibrary: 笔记保存，更新时间戳: " .. annotation.datetime_updated)
        end
    end
    
    logger.info("CloudLibrary: 已 patch ReaderBookmark.setBookmarkNote")
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
    logger.info("CloudLibrary: hookOnReaderReady - 已hook ReaderUI.showReader")
    
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
            logger.info("CloudLibrary: 跳过自动下载（下载后重开标志已清除）")
        else
            -- 直接检查自动下载是否开启，不再依赖 auto_sync_mode
            local should = self_auto_sync:shouldDownload("open")
            
            if file and type(file) == "string" and should then
                local DocSettings = require("docsettings")
                local metadata_file = DocSettings:findSidecarFile(file)
                
                local props = {}
                if self_plugin.ui and self_plugin.ui.bookinfo then
                    props = self_plugin.ui.bookinfo:getDocProps(file, nil, true) or {}
                end
                local title = props.title or props.display_title or 
                              file:match("([^/]+)$"):gsub("%.[^%.]+$", "")
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
                
                local remote = require("remote")
                local success, error_type
                local download_mode = self_auto_sync.settings.auto_download_mode
                local mode_desc = (download_mode == "merge") and "合并更新" or "覆盖更新"
                local naming_mode = self_auto_sync.settings.metadata_naming_mode or "metadata"
                
                if download_mode == "merge" then
                    success, error_type = remote.download_book_merge_before_open(book, naming_mode)
                else
                    success, error_type = remote.download_book_before_open(book, naming_mode)
                end
                
                if success then
                    self_auto_sync:updateLastSync(string.format("元数据同步-自动同步(打开书籍)-下载成功(%s)", mode_desc))
                    self_auto_sync:writeLog(book, "打开书籍", false, true, nil, mode_desc)
                    self_auto_sync:showNotification(title, "自动更新成功", mode_desc, true)
                else
                    local error_info = remote.get_error_message(error_type, false, naming_mode)
                    self_auto_sync:writeLog(book, "打开书籍", false, false, error_info.reason, nil, error_info.solution)
                    self_auto_sync:showNotification(title, "自动更新失败", mode_desc, false)
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
        
        -- 直接检查自动上传是否开启，不再依赖 auto_sync_mode
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
        
        -- 直接检查自动上传是否开启，不再依赖 auto_sync_mode
        if self_auto_sync:shouldUpload("suspend") and ui_instance and ui_instance.document then
            self_auto_sync:sync(ui_instance.document, true, "suspend")
        end
        
        return result
    end
end

return Hooks