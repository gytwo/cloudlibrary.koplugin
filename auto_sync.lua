local logger = require("logger")
local UIManager = require("ui/uimanager")
local Notification = require("ui/widget/notification")
local lfs = require("libs/libkoreader-lfs")
local DataStorage = require("datastorage")
local _ = require("gettext")
local utils = require("utils")

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
    
    if is_upload and self.skip_auto_upload then
        logger.info("CloudLibrary: 跳过自动上传（手动操作中）")
        return
    end
    
    if not is_upload and self.skip_auto_download then
        logger.info("CloudLibrary: 跳过自动下载（手动操作中）")
        return
    end
    
    if self.is_syncing then
        logger.info("CloudLibrary: 正在同步中，跳过")
        return
    end
    
    -- 检查是否开启对应的自动同步
    if is_upload then
        if not self:shouldUpload(source) then
            return
        end
    else
        if not self:shouldDownload(source) then
            return
        end
    end
    
    local file = document.file
    if not file or not lfs.attributes(file, "mode") then
        return
    end
    
    local source_desc = ""
    if source == "annotate" then
        source_desc = "编辑标注"
    elseif source == "close" then
        source_desc = "关闭书籍"
    elseif source == "suspend" then
        source_desc = "设备休眠"
    elseif source == "open" then
        source_desc = "打开书籍"
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
        logger.warn("CloudLibrary: 找不到元数据文件: " .. file)
        local error_info = {
            reason = "未找到本地元数据文件",
            solution = "请先打开该书生成元数据文件"
        }
        self:writeLog(book, source_desc, is_upload, false, error_info.reason, nil, error_info.solution)
        self:updateLastSync("自动同步(" .. source_desc .. ")-失败")
        self:showNotification(book.title, "同步失败", nil, false)
        return
    end
    
    self.is_syncing = true
    
    UIManager:scheduleIn(0, function()
        local remote = require("remote")
        local success, error_type
        local naming_mode = self.settings.metadata_naming_mode or "metadata"
        
        if is_upload then
            success, error_type = remote.upload_book(book, naming_mode)
            
            if success then
                self:writeLog(book, source_desc, true, true)
                self:updateLastSync("元数据同步-自动同步(" .. source_desc .. ")-上传成功")
                self:showNotification(book.title, "自动备份成功", nil, true)
            else
                local error_info = remote.get_error_message(error_type, true, naming_mode)
                self:writeLog(book, source_desc, true, false, error_info.reason, nil, error_info.solution)
                self:updateLastSync("元数据同步-自动同步(" .. source_desc .. ")-上传失败")
                logger.warn("CloudLibrary: 自动上传失败: " .. error_info.reason)
                self:showNotification(book.title, "自动备份失败", nil, false)
            end
        else
            local mode_desc = (self.settings.auto_download_mode == "merge") and "合并更新" or "覆盖更新"
            
            if self.settings.auto_download_mode == "merge" then
                success, error_type = remote.download_book_merge(book, naming_mode)
            else
                success, error_type = remote.download_book(book, naming_mode)
            end
            
            if success then
                self:writeLog(book, source_desc, false, true, nil, mode_desc)
                self:updateLastSync("元数据同步-自动同步(" .. source_desc .. ")-下载成功(" .. mode_desc .. ")")
                self:showNotification(book.title, "自动更新成功", mode_desc, true)
            else
                local error_info = remote.get_error_message(error_type, false, naming_mode)
                self:writeLog(book, source_desc, false, false, error_info.reason, nil, error_info.solution)
                self:updateLastSync("元数据同步-自动同步(" .. source_desc .. ")-下载失败")
                logger.warn("CloudLibrary: 自动下载失败: " .. error_info.reason)
                self:showNotification(book.title, "自动更新失败", mode_desc, false)
            end
        end
        
        self.is_syncing = false
    end)
end

function AutoSync:showNotification(title, operation, mode, is_success)
    if not self.settings.auto_sync_notify then
        return
    end
    
    local icon = is_success and "✓" or "✗"
    local text
    if mode then
        text = string.format("%s %s - %s - %s", icon, title, operation, mode)
    else
        text = string.format("%s %s - %s", icon, title, operation)
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
        operation_type = string.format("元数据同步-自动同步-%s-上传", source_desc)
    else
        local mode_desc = (download_mode == "merge") and "合并更新" or "覆盖更新"
        operation_type = string.format("元数据同步-自动同步-%s-下载(%s)", source_desc, mode_desc)
    end
    
    local new_record = {}
    table.insert(new_record, utils.SEPARATOR_LINE)
    table.insert(new_record, string.format("同步时间: %s", timestamp))
    table.insert(new_record, string.format("操作设备: %s", device_name))
    table.insert(new_record, string.format("设备ID: %s", device_id))
    table.insert(new_record, string.format("操作类型: %s", operation_type))
    table.insert(new_record, utils.SEPARATOR_LINE)
    
    if success then
        table.insert(new_record, string.format("【成功】✓ %s", book.title or book.book_basename))
    else
        table.insert(new_record, string.format("【失败】✗ %s", book.title or book.book_basename))
        table.insert(new_record, string.format("原因: %s", error_reason or "未知错误"))
        if solution then
            table.insert(new_record, string.format("解决方案: %s", solution))
        end
    end
    table.insert(new_record, "")
    table.insert(new_record, "")
    
    local content = table.concat(new_record, "\n") .. "\n"
    
    utils.write_log(log_path, content)
    
    local settings = G_reader_settings:readSetting("cloud_library_plugin", {})
    if settings.sync_log_enabled then
        pcall(function()
            local sync_log = require("sync_log")
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