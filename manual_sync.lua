local logger = require("logger")
local UIManager = require("ui/uimanager")
local Notification = require("ui/widget/notification")
local ConfirmBox = require("ui/widget/confirmbox")
local lfs = require("libs/libkoreader-lfs")
local DataStorage = require("datastorage")
local _ = require("gettext")
local Event = require("ui/event")
local utils = require("utils")  

local ManualSync = {}

function ManualSync:new(plugin, auto_sync)
    local obj = {}
    setmetatable(obj, self)
    self.__index = self
    
    obj.plugin = plugin
    obj.auto_sync = auto_sync
    obj.settings = plugin.settings
    
    return obj
end

function ManualSync:syncCurrentBook(is_upload)
    local doc = self.plugin.ui.document
    if not doc then
        self:showMsg(_("请先打开一本书"))
        return
    end
    
    local file = doc.file
    local DocSettings = require("docsettings")
    local metadata_file = DocSettings:findSidecarFile(file)
    
    if not metadata_file then
        self:showMsg(_("找不到当前书籍的元数据文件"))
        return
    end
    
    if is_upload then
        self:doSyncCurrentBook(is_upload, file, metadata_file)
    else
        UIManager:show(ConfirmBox:new{
            title = _("确认下载"),
            text = _("此操作需要重新打开当前书籍以覆盖更新元数据，是否继续？"),
            ok_text = _("继续"),
            cancel_text = _("取消"),
            ok_callback = function()
                self:doSyncCurrentBook(is_upload, file, metadata_file)
            end
        })
    end
end

function ManualSync:syncCurrentBookMerge()
    local doc = self.plugin.ui.document
    if not doc then
        self:showMsg(_("请先打开一本书"))
        return
    end
    
    local file = doc.file
    local DocSettings = require("docsettings")
    local metadata_file = DocSettings:findSidecarFile(file)
    
    if not metadata_file then
        self:showMsg(_("找不到当前书籍的元数据文件"))
        return
    end
    
    self.plugin.ui:saveSettings()
    
    UIManager:show(ConfirmBox:new{
        title = _("确认合并下载"),
        text = _("此操作需要重新打开当前书籍以合并更新元数据。是否继续？"),
        ok_text = _("继续"),
        cancel_text = _("取消"),
        ok_callback = function()
            self:doSyncCurrentBookMerge(file, metadata_file)
        end
    })
end

function ManualSync:doSyncCurrentBook(is_upload, file, metadata_file)
    if is_upload then
        self.auto_sync:setSkipUpload(true)
    else
        self.auto_sync:setSkipDownload(true)
    end
    
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
    
    local remote = require("remote")
    local success, error_type = false, nil
    local naming_mode = self.settings.metadata_naming_mode or "metadata"
    
    if is_upload then
        success, error_type = remote.upload_book(book, naming_mode)
    else
        success, error_type = remote.download_book(book, naming_mode)
    end
    
    if success then
        local success_text = is_upload and "✓ 上传成功" or "✓ 下载成功(覆盖更新)"
        UIManager:show(Notification:new{
            text = success_text,
            timeout = 2
        })
        
        self:writeSingleLog(book, is_upload, false, true)
        self:updateLastSync(is_upload and "元数据同步-单本上传-覆盖云端" or "元数据同步-单本下载-覆盖更新")
    else
        local error_info = remote.get_error_message(error_type, is_upload, naming_mode)
        UIManager:show(Notification:new{
            text = string.format(is_upload and "✗ 上传失败: %s" or "✗ 下载失败: %s", error_info.reason),
            timeout = 3
        })
        
        self:writeSingleLog(book, is_upload, false, false, error_info.reason)
    end
    
    if is_upload then
        self.auto_sync:setSkipUpload(false)
    else
        self.auto_sync:setSkipDownload(false)
    end
end

function ManualSync:doSyncCurrentBookMerge(file, metadata_file)
    self.auto_sync:setSkipDownload(true)
    
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
    
    local remote = require("remote")
    local naming_mode = self.settings.metadata_naming_mode or "metadata"
    local success, error_type = remote.download_book_merge(book, naming_mode)
    
    if success then
        UIManager:show(Notification:new{
            text = "✓ 下载成功(合并更新)",
            timeout = 2
        })
        
        self:writeSingleLog(book, false, true, true)
        self:updateLastSync("元数据同步-单本下载-合并更新")
        
        UIManager:scheduleIn(0.5, function()
            if self.plugin.ui and self.plugin.ui.document then
                self.plugin.ui:handleEvent(Event:new("RedrawCurrentView"))
            end
        end)
    else
        local error_info = remote.get_error_message(error_type, false, naming_mode)
        UIManager:show(Notification:new{
            text = string.format("✗ 下载失败(合并更新): %s", error_info.reason),
            timeout = 3
        })
        
        self:writeSingleLog(book, false, true, false, error_info.reason)
    end
    
    self.auto_sync:setSkipDownload(false)
end

function ManualSync:batchSyncWithFMSelection(is_upload, is_merge)
    local ui = self.plugin.ui
    
    -- 根据操作类型生成提示文字
    local action_text = ""
    local button_text = ""
    if is_upload then
        action_text = "上传"
        button_text = "批量上传元数据"
    else
        action_text = "下载"
        if is_merge then
            button_text = "批量下载元数据-合并更新"
        else
            button_text = "批量下载元数据-覆盖更新"
        end
    end
    
    -- 如果没有文件管理器界面，先进入
    if not ui or not ui.file_chooser then
        local FileManager = require("apps/filemanager/filemanager")
        
        if self.plugin.ui and self.plugin.ui.document then
            self.auto_sync:setSkipUpload(true)
            self.plugin.ui.tearing_down = true
            self.plugin.ui:onClose()
        end
        
        FileManager:showFiles()
        local fm = FileManager.instance
        if fm then
            fm:onToggleSelectMode(true)
            if fm.title_bar then
                fm.title_bar:setRightIcon("check")
            end
        end
        
        UIManager:show(Notification:new{
            text = string.format(_("请勾选要%s的书籍，再点击「%s」"), action_text, button_text),
            timeout = 5
        })
        return
    end
    
    -- 已经在文件管理器界面
    local FileManager = require("apps/filemanager/filemanager")
    local fm = FileManager.instance
    
    if not fm then
        self:showMsg(_("无法获取文件管理器实例"))
        return
    end
    
    -- 检查是否在选择模式：selected_files 不为 nil 表示已在选择模式
    if fm.selected_files == nil then
        -- 不在选择模式，进入选择模式
        fm:onToggleSelectMode(true)
        UIManager:show(Notification:new{
            text = string.format(_("请勾选要%s的书籍，再点击「%s」"), action_text, button_text),
            timeout = 5
        })
        return
    end
    
    -- 已在选择模式，获取选中的文件
    local selected_files = fm.selected_files
    if not selected_files or next(selected_files) == nil then
        -- 在选择模式但没有选中任何文件
        UIManager:show(Notification:new{
            text = string.format(_("请勾选要%s的书籍，再点击「%s」"), action_text, button_text),
            timeout = 5
        })
        return
    end
    
    -- 有选中文件，直接执行同步
    self:processSelectedFiles(is_upload, is_merge, selected_files)
end

function ManualSync:processSelectedFiles(is_upload, is_merge, selected_files)
    logger.info("========== processSelectedFiles 开始 ==========")
    logger.info("is_upload = " .. tostring(is_upload))
    logger.info("is_merge = " .. tostring(is_merge))
    
    local DocSettings = require("docsettings")
    local ui = self.plugin.ui
    local books = {}
    
    local file_count = 0
    for file, selected in pairs(selected_files) do
        file_count = file_count + 1
        logger.info("process: 处理文件 " .. file_count .. ": " .. tostring(file) .. ", selected = " .. tostring(selected))
        
        if selected and lfs.attributes(file, "mode") == "file" then
            logger.info("process: 文件有效，查找元数据")
            local metadata_file = DocSettings:findSidecarFile(file)
            logger.info("process: metadata_file = " .. tostring(metadata_file))
            
            local props = {}
            if ui and ui.bookinfo then
                props = ui.bookinfo:getDocProps(file, nil, true) or {}
            end
            local title = props.title or props.display_title
            local basename = file:match("([^/]+)$"):gsub("%.[^%.]+$", "")
            local author = props.authors
            if type(author) == "table" then
                author = author[1]
            end
            
            logger.info("process: title = " .. tostring(title))
            logger.info("process: basename = " .. tostring(basename))
            
            table.insert(books, {
                file = file,
                metadata = metadata_file,
                title = title or basename,
                book_basename = basename,
                author = author,
            })
        else
            logger.info("process: 文件无效或未选中，跳过")
        end
    end
    
    logger.info("process: 共处理 " .. file_count .. " 个文件，有效书籍 " .. #books .. " 本")
    
    if #books == 0 then
        logger.info("process: 没有有效书籍，显示提示")
        self:showMsg(_("没有选中任何文件"))
        return
    end
    
    local action_text = ""
    if is_upload then
        action_text = "上传"
    else
        action_text = is_merge and "下载-合并更新" or "下载-覆盖更新"
    end
    
    logger.info("process: 显示确认框，将" .. action_text .. " " .. #books .. " 本书籍")
    UIManager:show(ConfirmBox:new{
        text = string.format("将%s %d 本书籍的元数据", action_text, #books),
        ok_text = _("继续"),
        cancel_text = _("取消"),
        ok_callback = function()
            logger.info("process: 用户确认，调用 doBatchSync")
            self:doBatchSync(is_upload, is_merge, books)
        end
    })
    logger.info("========== processSelectedFiles 结束 ==========")
end


function ManualSync:doBatchSync(is_upload, is_merge, selected_books)
    local remote = require("remote")
    local naming_mode = self.settings.metadata_naming_mode or "metadata"
    local sync_results = {
        type = "batch",
        success = {},
        failed = {}
    }
    
    for _, book in ipairs(selected_books) do
        if not book.metadata or not lfs.attributes(book.metadata, "mode") then
            table.insert(sync_results.failed, {
                title = book.title,
                file = book.file,
                reason = "未找到本地元数据文件",
                solution = "请先打开该书籍生成元数据文件"
            })
        else
            local success, error_type = false, nil
            if is_upload then
                success, error_type = remote.upload_book(book, naming_mode)
            else
                if is_merge then
                    success, error_type = remote.download_book_merge(book, naming_mode)
                else
                    success, error_type = remote.download_book(book, naming_mode)
                end
            end
            
            if success then
                table.insert(sync_results.success, {
                    title = book.title,
                    file = book.file
                })
            else
                local error_info = remote.get_error_message(error_type, is_upload, naming_mode)
                table.insert(sync_results.failed, {
                    title = book.title,
                    file = book.file,
                    reason = error_info.reason,
                    solution = error_info.solution
                })
            end
        end
    end
    
    self:writeBatchLog(sync_results, is_upload, is_merge)
    
    local msg = ""
    if is_upload then
        msg = string.format("元数据上传完成: %d 成功, %d 失败", #sync_results.success, #sync_results.failed)
    else
        local mode_text = is_merge and "合并更新" or "覆盖更新"
        msg = string.format("元数据下载完成-%s: %d 成功, %d 失败", mode_text, #sync_results.success, #sync_results.failed)
    end
    
    UIManager:show(Notification:new{
        text = msg,
        timeout = 2
    })
    
    local sync_type = ""
    if is_upload then
        sync_type = "元数据同步-批量上传-覆盖云端"
    else
        sync_type = is_merge and "元数据同步-批量下载-合并更新" or "元数据同步-批量下载-覆盖更新"
    end
    self:updateLastSync(sync_type)
    
    local FileManager = require("apps/filemanager/filemanager")
    local fm = FileManager.instance
    if fm then
        if fm.file_chooser and fm.file_chooser.item_table then
            for _, item in ipairs(fm.file_chooser.item_table) do
                if item.is_file then
                    item.dim = nil
                end
            end
            fm.file_chooser:updateItems(1, true)
        end
        fm:onToggleSelectMode(true)
    end
end

function ManualSync:writeSingleLog(book, is_upload, is_merge, success, error_reason)
    local timestamp = os.date("%Y-%m-%d %H:%M:%S")
    local log_path = utils.get_log_path()
    
    local device_name = utils.get_device_name()
    local device_id = utils.get_device_id()
    
    local operation_type = ""
    if is_upload then
        operation_type = "元数据同步-单本上传-覆盖云端"
    else
        operation_type = is_merge and "元数据同步-单本下载-合并更新" or "元数据同步-单本下载-覆盖更新"
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

function ManualSync:writeBatchLog(results, is_upload, is_merge)
    local timestamp = os.date("%Y-%m-%d %H:%M:%S")
    local log_path = utils.get_log_path()
    
    local device_name = utils.get_device_name()
    local device_id = utils.get_device_id()
    
    local operation_type = ""
    if is_upload then
        operation_type = "元数据同步-批量上传-覆盖云端"
    else
        operation_type = is_merge and "元数据同步-批量下载-合并更新" or "元数据同步-批量下载-覆盖更新"
    end
    
    local failed_by_reason = {}
    for _, book in ipairs(results.failed) do
        local key = book.reason
        if not failed_by_reason[key] then
            failed_by_reason[key] = {
                solution = book.solution,
                books = {}
            }
        end
        table.insert(failed_by_reason[key].books, {
            title = book.title,
            file = book.file
        })
    end
    
    local new_record = {}
    table.insert(new_record, utils.SEPARATOR_LINE)
    table.insert(new_record, string.format("同步时间: %s", timestamp))
    table.insert(new_record, string.format("操作设备: %s", device_name))
    table.insert(new_record, string.format("设备ID: %s", device_id))
    table.insert(new_record, string.format("操作类型: %s", operation_type))
    table.insert(new_record, utils.SEPARATOR_LINE)
    
    table.insert(new_record, string.format("【成功】(%d 本)", #results.success))
    table.insert(new_record, string.rep("-", 40))
    if #results.success > 0 then
        for _, book in ipairs(results.success) do
            table.insert(new_record, string.format("  ✓ %s", book.title))
        end
    else
        table.insert(new_record, "  无")
    end
    table.insert(new_record, "")
    
    table.insert(new_record, string.format("【失败】(%d 本)", #results.failed))
    table.insert(new_record, string.rep("-", 40))
    if #results.failed > 0 then
        local reason_index = 0
        for reason, info in pairs(failed_by_reason) do
            reason_index = reason_index + 1
            table.insert(new_record, string.format("\n【失败原因 %d】%s", reason_index, reason))
            table.insert(new_record, string.rep("~", 40))
            table.insert(new_record, string.format("✓解决方案: %s", info.solution or "请检查网络和配置"))
            table.insert(new_record, "")
            table.insert(new_record, "✗失败书籍:")
            for i, book in ipairs(info.books) do
                table.insert(new_record, string.format("  (%d) %s", i, book.title))
            end
        end
    else
        table.insert(new_record, "  无")
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

function ManualSync:showMsg(msg)
    local InfoMessage = require("ui/widget/infomessage")
    UIManager:show(InfoMessage:new{
        text = msg,
        timeout = 3,
    })
end

function ManualSync:updateLastSync(descriptor)
    self.settings.last_sync = os.date("%Y-%m-%d %H:%M:%S") .. " (" .. descriptor .. ")"
    G_reader_settings:saveSetting(self.plugin.plugin_id, self.settings)
end

return ManualSync
