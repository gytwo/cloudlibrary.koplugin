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
    auto_sync_notify = true,
    upload_json = false,
    sync_log_enabled = false,
    book_naming_mode = "title",
    book_download_dir = nil,
    override_keep_local_settings = true,
}

CloudLibraryPlugin.VERSION = "v1.0"
CloudLibraryPlugin.UPDATE_DATE = "2026/04/09"

function CloudLibraryPlugin:init()
    logger.info("CloudLibrary: init 开始, 版本 " .. self.VERSION)
    
    self.ui.menu:registerToMainMenu(self)
    
    local utils = require("utils")
    utils.insert_after_statistics(self.plugin_id)
    self:onDispatcherRegisterActions()
    
    self.settings = G_reader_settings:readSetting(self.plugin_id, self.default_settings)
    
    local AutoSync = require("auto_sync")
    local ManualSync = require("manual_sync")
    local Hooks = require("hooks")
    
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
    
    logger.info("CloudLibrary: 插件初始化完成")
end

function CloudLibraryPlugin:addToMainMenu(menu_items)
    menu_items.cloud_library_plugin = {
        text = _("云端书库"),
        sorting_hint = "tools",
        sub_item_table = self:buildMenuItems(),
    }
end

function CloudLibraryPlugin:buildMenuItems()
    local utils = require("utils")
    local items = {
        {
            text = _("设置"),
            sub_item_table = self:buildSettingsMenu(),
            separator = true,
        },
        {
            text = _("元数据同步"),
            sub_item_table = self:buildMetadataSyncMenu(),
        },
        {
            text = _("书籍同步"),
            sub_item_table = self:buildBookSyncMenu(),
        },
        {
            text = _("查看同步记录"),
            callback = function()
                self:viewSyncLog()
            end,
        },
        {
            text = _("插件说明"),
            callback = function()
                self:showPluginInfo()
            end,
        },
        {
            text = _("检查更新"),
            callback = function()
                local update = require("update")
                update.check_for_updates(false, self)
            end
        },
        {
            enabled = false,
            text_func = function()
                local last_sync = self.settings.last_sync
                if last_sync == "Never" then
                    return T(_("最后同步：%1"), last_sync)
                end
                local time_part = last_sync:match("(.+) %(") or last_sync
                local action_part = last_sync:match("%((.+)%)") or ""
                if action_part ~= "" then
                    return string.format("最后同步：%s\n(%s)", time_part, action_part)
                else
                    return T(_("最后同步：%1"), last_sync)
                end
            end
        },
    }
    return items
end

function CloudLibraryPlugin:buildSettingsMenu()
    local utils = require("utils")
    logger.info("CloudLibrary: buildSettingsMenu 被调用")
    return {
        {
            text = _("云端目录"),
            callback = function()
                logger.info("CloudLibrary: 元数据云端目录 被点击")
                local SyncService = require("apps/cloudstorage/syncservice")
                local remote = require("remote")
                local sync_service = SyncService:new{}
                sync_service.onConfirm = function(server)
                    logger.info("CloudLibrary: 元数据云端目录 设置完成, url=" .. tostring(server.url))
                    remote.save_server_settings(server)
                end
                UIManager:show(sync_service)
            end
        },
        {
            text = _("云端命名方式"),
            sub_item_table = self:buildNamingModeMenu(),
            separator = true,
        },
        {
            text_func = function()
                local dir = self.settings.book_download_dir
                if dir and dir ~= "" then
                    return _("书籍下载目录: ") .. dir
                else
                    return _("设置书籍下载目录")
                end
            end,
            callback = function()
                logger.info("CloudLibrary: 设置书籍下载目录 被点击")
                self:chooseBookLocalDir()
            end,
        },
        {
            text = _("元数据下载模式（手动）"),
            sub_item_table = {
                {
                    text = _("覆盖更新"),
                    checked_func = function()
                        return self.settings.auto_download_mode == "override"
                    end,
                    callback = function()
                        self.settings.auto_download_mode = "override"
                        G_reader_settings:saveSetting(self.plugin_id, self.settings)
                        utils.show_msg(_("元数据下载模式（手动）：覆盖更新"))
                    end
                },
                {
                    text = _("合并更新"),
                    checked_func = function()
                        return self.settings.auto_download_mode == "merge"
                    end,
                    callback = function()
                        self.settings.auto_download_mode = "merge"
                        G_reader_settings:saveSetting(self.plugin_id, self.settings)
                        utils.show_msg(_("元数据下载模式（手动）：合并更新"))
                    end
                },
            },
        },
        {
            text = _("自动同步设置（仅元数据）"),
            sub_item_table = self:buildAutoSyncMenu(),
            separator = true,
        },
        {
            text = _("元数据额外备份JSON"),
            checked_func = function()
                return self.settings.upload_json == true
            end,
            callback = function()
                self.settings.upload_json = not self.settings.upload_json
                G_reader_settings:saveSetting(self.plugin_id, self.settings)
                utils.show_msg(self.settings.upload_json and 
                    "已开启：上传时将额外生成JSON文件" or 
                    "已关闭：仅上传原始LUA文件")
            end
        },
        {
            text = _("覆盖更新时保留本地文档设置"),
            checked_func = function()
                return self.settings.override_keep_local_settings == true
            end,
            help_text = _("开启后：覆盖更新时保留本地的字体、边距等设置，仅同步标注和进度"),
            callback = function()
                self.settings.override_keep_local_settings = not self.settings.override_keep_local_settings
                G_reader_settings:saveSetting(self.plugin_id, self.settings)
                utils.show_msg(self.settings.override_keep_local_settings and 
                    "已开启：覆盖更新时保留本地文档设置" or 
                    "已关闭：覆盖更新时完全使用云端文件")
            end
        },
        {
            text = _("开启记录云同步"),
            checked_func = function()
                return self.settings.sync_log_enabled == true
            end,
            help_text = _("开启后：自动上传本地记录至云端或从云端合并同步记录至本地"),
            callback = function()
                self.settings.sync_log_enabled = not self.settings.sync_log_enabled
                G_reader_settings:saveSetting(self.plugin_id, self.settings)
                
                if self.settings.sync_log_enabled then
                    local sync_log = require("sync_log")
                    sync_log.sync_log()
                    utils.show_msg(_("已开启记录云同步"))
                else
                    utils.show_msg(_("已关闭记录云同步"))
                end
            end
        },
        {
            text = _("清空云端同步记录"),
            help_text = _("清空云端存储的所有同步记录，不会影响本地记录"),
            callback = function()
                self:confirmClearCloudLog()
            end,
            separator = true,
        },
    }
end

function CloudLibraryPlugin:confirmClearCloudLog()
    UIManager:show(ConfirmBox:new{
        text = _("确定要清空云端的同步记录吗？\n\n此操作不会影响本地的同步记录，但其他设备将无法同步到已清空的记录。"),
        ok_text = _("清空"),
        cancel_text = _("取消"),
        ok_callback = function()
            self:doClearCloudLog()
        end
    })
end

function CloudLibraryPlugin:doClearCloudLog()
    local utils = require("utils")
    local NetworkMgr = require("ui/network/manager")
    
    if not NetworkMgr:isOnline() then
        utils.show_msg(_("无网络连接，无法清空"))
        return
    end
    
    utils.show_msg(_("正在清空云端同步记录..."))
    
    UIManager:scheduleIn(0, function()
        local sync_log = require("sync_log")
        local success, msg = sync_log.clear_cloud_log()
        
        if success then
            utils.show_msg(_("云端同步记录已清空"))
            logger.info("CloudLibrary: 云端同步记录已清空")
        else
            utils.show_msg(_("清空失败: ") .. msg)
        end
    end)
end

function CloudLibraryPlugin:buildNamingModeMenu()
    local utils = require("utils")
    return {
        {
            text = _("元数据命名方式"),
            sub_item_table = {
                {
                    text = _("使用文件名"),
                    checked_func = function()
                        return self.settings.metadata_naming_mode == "filename"
                    end,
                    callback = function()
                        self.settings.metadata_naming_mode = "filename"
                        utils.show_msg(_("元数据使用文件名命名"))
                        G_reader_settings:saveSetting(self.plugin_id, self.settings)
                    end
                },
                {
                    text = _("使用书籍标题（默认）"),
                    checked_func = function()
                        return self.settings.metadata_naming_mode == "metadata"
                    end,
                    callback = function()
                        self.settings.metadata_naming_mode = "metadata"
                        utils.show_msg(_("元数据使用书籍标题命名"))
                        G_reader_settings:saveSetting(self.plugin_id, self.settings)
                    end
                },
                {
                    text = _("使用标题_作者"),
                    checked_func = function()
                        return self.settings.metadata_naming_mode == "title_author"
                    end,
                    callback = function()
                        self.settings.metadata_naming_mode = "title_author"
                        utils.show_msg(_("元数据使用「标题_作者」格式命名"))
                        G_reader_settings:saveSetting(self.plugin_id, self.settings)
                    end
                },
            },
        },
        {
            text = _("书籍命名方式"),
            sub_item_table = {
                {
                    text = _("使用文件名"),
                    checked_func = function()
                        return self.settings.book_naming_mode == "filename"
                    end,
                    callback = function()
                        self.settings.book_naming_mode = "filename"
                        utils.show_msg(_("书籍使用文件名命名"))
                        G_reader_settings:saveSetting(self.plugin_id, self.settings)
                    end
                },
                {
                    text = _("使用书籍标题（默认）"),
                    checked_func = function()
                        return self.settings.book_naming_mode == "title"
                    end,
                    callback = function()
                        self.settings.book_naming_mode = "title"
                        utils.show_msg(_("书籍使用书籍标题命名"))
                        G_reader_settings:saveSetting(self.plugin_id, self.settings)
                    end
                },
                {
                    text = _("使用标题_作者"),
                    checked_func = function()
                        return self.settings.book_naming_mode == "title_author"
                    end,
                    callback = function()
                        self.settings.book_naming_mode = "title_author"
                        utils.show_msg(_("书籍使用「标题_作者」格式命名"))
                        G_reader_settings:saveSetting(self.plugin_id, self.settings)
                    end
                },
            },
        },
    }
end

function CloudLibraryPlugin:chooseBookLocalDir()
    logger.info("CloudLibrary: chooseBookLocalDir 被调用")
    local DownloadMgr = require("ui/downloadmgr")
    local current_dir = self.settings.book_download_dir
    
    DownloadMgr:new{
        title = _("选择书籍下载目录"),
        onConfirm = function(path)
            logger.info("CloudLibrary: 本地下载目录选择完成, path=" .. tostring(path))
            if path and path ~= "" then
                self.settings.book_download_dir = path
                G_reader_settings:saveSetting(self.plugin_id, self.settings)
                UIManager:show(Notification:new{
                    text = string.format(_("本地下载目录已设置: %s"), path),
                    timeout = 2
                })
            end
        end,
    }:chooseDir(current_dir)
end

function CloudLibraryPlugin:buildMetadataSyncMenu()
    return {
        {
            text = _("上传当前书籍元数据"),
            enabled = self.ui and self.ui.document,
            callback = function()
                self.manual_sync:syncCurrentBook(true)
            end
        },
        {
            text = _("下载当前书籍元数据"),
            sub_item_table = {
                {
                    text = _("覆盖更新"),
                    callback = function()
                        self.manual_sync:syncCurrentBook(false)
                    end
                },
                {
                    text = _("合并更新"),
                    callback = function()
                        self.manual_sync:syncCurrentBookMerge()
                    end
                },
            },
        },
        {
            text = _("批量上传选中书籍元数据"),
            callback = function()
                self.manual_sync:batchSyncWithFMSelection(true, false)
            end,
        },
        {
            text = _("批量下载选中书籍元数据"),
            sub_item_table = {
                {
                    text = _("覆盖更新"),
                    callback = function()
                        self.manual_sync:batchSyncWithFMSelection(false, false)
                    end
                },
                {
                    text = _("合并更新"),
                    callback = function()
                        self.manual_sync:batchSyncWithFMSelection(false, true)
                    end
                },
            },
        },
    }
end

function CloudLibraryPlugin:buildBookSyncMenu()
    logger.info("CloudLibrary: buildBookSyncMenu 被调用")
    local BookSync = require("book_sync")
    return {
        {
            text = _("批量上传选中书籍"),
            callback = function()
                logger.info("CloudLibrary: 批量上传选中书籍 被点击")
                BookSync.batchUploadWithFMSelection(self)
            end
        },
        {
            text = _("批量下载云端书籍"),
            callback = function()
                logger.info("CloudLibrary: 批量下载云端书籍 被点击")
                self:batchDownloadBooks()
            end
        },
    }
end

function CloudLibraryPlugin:buildAutoSyncMenu()
    local utils = require("utils")
    return {
        {
            text = _("自动上传备份"),
            enabled = true,
            sub_item_table = {
                {
                    text = _("编辑标注时自动上传"),
                    checked_func = function()
                        return self.settings.auto_upload_on_annotate == true
                    end,
                    callback = function()
                        self.settings.auto_upload_on_annotate = not self.settings.auto_upload_on_annotate
                        self:updateAutoSyncSettings()
                        utils.show_msg(self.settings.auto_upload_on_annotate and "已开启：编辑标注时自动上传" or "已关闭：编辑标注时自动上传")
                    end,
                },
                {
                    text = _("关闭书籍时自动上传"),
                    checked_func = function()
                        return self.settings.auto_upload_on_close == true
                    end,
                    callback = function()
                        self.settings.auto_upload_on_close = not self.settings.auto_upload_on_close
                        self:updateAutoSyncSettings()
                        utils.show_msg(self.settings.auto_upload_on_close and "已开启：关闭书籍时自动上传" or "已关闭：关闭书籍时自动上传")
                    end,
                },
                {
                    text = _("设备休眠时自动上传"),
                    checked_func = function()
                        return self.settings.auto_upload_on_suspend == true
                    end,
                    callback = function()
                        self.settings.auto_upload_on_suspend = not self.settings.auto_upload_on_suspend
                        self:updateAutoSyncSettings()
                        utils.show_msg(self.settings.auto_upload_on_suspend and "已开启：休眠时自动上传" or "已关闭：休眠时自动上传")
                    end,
                },
            },
        },
{
    text = _("自动下载更新"),
    enabled = true,
    sub_item_table = {
        {
            text = _("打开书籍时自动下载（覆盖更新）"),
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
                local utils = require("utils")
                utils.show_msg(self.settings.auto_download_on_open and self.settings.auto_download_mode == "override" and 
                    "已开启：打开书籍时自动下载（覆盖更新）" or "已关闭：打开书籍时自动下载（覆盖更新）")
            end,
        },
        {
            text = _("打开书籍时自动下载（合并更新）"),
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
                local utils = require("utils")
                utils.show_msg(self.settings.auto_download_on_open and self.settings.auto_download_mode == "merge" and 
                    "已开启：打开书籍时自动下载元数据" or "已关闭：打开书籍时自动下载元数据")
            end,
        },
    },
},
        {
            text = _("自动同步时显示通知"),
            checked_func = function()
                return self.settings.auto_sync_notify == true
            end,
            callback = function()
                self.settings.auto_sync_notify = not self.settings.auto_sync_notify
                G_reader_settings:saveSetting(self.plugin_id, self.settings)
                utils.show_msg(self.settings.auto_sync_notify and "已开启：自动同步通知" or "已关闭：自动同步通知")
            end,
        },
    }
end

function CloudLibraryPlugin:batchDownloadBooks()
    logger.info("CloudLibrary: batchDownloadBooks 被调用")
    local utils = require("utils")
    local download_dir = self.settings.book_download_dir
    if not download_dir or download_dir == "" then
        logger.warn("CloudLibrary: 本地下载目录未设置")
        utils.show_msg(_("请先在设置中设置书籍下载目录"))
        return
    end
    
    local BookSync = require("book_sync")
    BookSync.show_cloud_book_dialog(function(book_names)
        logger.info("CloudLibrary: 选择下载书籍, 共 " .. #book_names .. " 本")
        UIManager:show(ConfirmBox:new{
            text = string.format("确定要下载 %d 本书籍吗？", #book_names),
            ok_text = _("下载"),
            cancel_text = _("取消"),
            ok_callback = function()
                BookSync.batchDownloadBooks(book_names, self.settings, self)
            end,
        })
    end)
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
    local utils = require("utils")
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
        utils.show_msg(_("没有同步记录"))
        return
    end
    local content = f:read("*all")
    f:close()
    
    if content == "" or not content then
        utils.show_msg(_("没有同步记录"))
        return
    end
    
    local header = string.format("同步记录文件路径: %s\n\n", absolute_path)
    local full_content = header .. content
    
    local textviewer
    local buttons = {
        {
            {
                text = _("查找"),
                callback = function()
                    if textviewer then
                        textviewer:findDialog()
                    end
                end,
            },
            {
                text = _("复制"),
                callback = function()
                    if Device:hasClipboard() then
                        Device.input.setClipboardText(full_content)
                        utils.show_msg(_("同步记录已复制到剪贴板"))
                    else
                        local temp_file = DataStorage:getDataDir() .. "sync_log_backup.txt"
                        local out_f = io.open(temp_file, "w")
                        if out_f then
                            out_f:write(full_content)
                            out_f:close()
                            utils.show_msg(string.format(_("同步记录已保存到 %s"), temp_file))
                        else
                            utils.show_msg(_("复制失败"))
                        end
                    end
                end,
            },
            {
                text = _("清空"),
                callback = function()
                    UIManager:show(ConfirmBox:new{
                        text = _("确定要清空所有同步记录吗？"),
                        ok_text = _("清空"),
                        cancel_text = _("取消"),
                        ok_callback = function()
                            local out_f = io.open(log_path, "w")
                            if out_f then
                                out_f:write("")
                                out_f:close()
                            end
                            if textviewer then
                                UIManager:close(textviewer)
                            end
                            utils.show_msg(_("同步记录已清空"))
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
        title = _("同步记录"),
        text = full_content,
        justified = false,
        buttons_table = buttons,
    }
    UIManager:show(textviewer)
end

function CloudLibraryPlugin:showPluginInfo()
    local info_text = [[
插件作者：小红书gytwo
更新时间：2026/4/10
版本号：v1.0
项目地址：https://gitee.com/gytwo/cloudlibrary

【插件名称】
云端书库 - 在设备间同步书籍及元数据

【同步原理】
1. 本插件直接操作设备原始元数据文件（.lua格式），通过上传/下载/更新元数据文件，实现书籍标注、阅读进度等书籍信息的一次性同步。
2. 同时支持书籍本身的批量上传/下载，实现完整的书库同步。

【前提设置】
1. 浏览器界面选择「菜单」→「工具」→「云存储」，添加云存储账号
2. 插件操作：「菜单」→「工具」→「云端书库」→「设置」→选择云端目录，用于存放书籍元数据文件、书籍文件、同步记录文件
   -不同设备应设置相同的云端目录，否则无法共享
3. 不同设备的本地文档元数据存放位置应当保持一致（「设置」→「文档」→「书籍元数据文件夹」）。默认通常是一致的，但如果某设备更改了该设置，另一设备也应当进行相应更改，否则可能会提示找不到本地元数据文件

【云端命名规则】
- 元数据：可选文件名 / 使用书籍标题（默认） / 使用标题_作者
- 书籍：可选文件名 / 使用书籍标题（默认） / 使用标题_作者
- 注意：不同设备的云端命名规则应当保持一致

【元数据上传备份】
直接上传本地书籍对应的本地元数据文件（.lua格式）至云端，如云端已有同名文件，会直接覆盖
【元数据下载更新】
- 覆盖模式：云端文件直接覆盖本地文件，通过「菜单」→「工具」→「云端书库」→「设置」可以选择是否需要保留本地文档设置
- 合并模式：以本地为基础，合并云端特有、更新的信息
   - 阅读标注：保留本地和云端的所有标注（含高亮、划线、书签、笔记等）并进行合并、更新、去重、排序
   - 阅读状态：取优先级更高：已读完>阅读中>未读
   - 阅读进度：取更远值
   - 阅读统计：高亮数、笔记数根据合并结果自动统计
   - 文档设置：保留本地设置

【元数据下载模式（手动）】
用于快捷切换覆盖/合并模式（不影响自动下载更新模式）

【书籍同步说明】
- 上传时若云端已存在同名文件，会直接覆盖
- 下载时若本地已存在同名文件，会直接跳过（详情可在同步记录中查看），如确需下载，请先删除/重命名本地文件。

【批量同步方法】
1. 在文件管理器中长按文件进入选择模式
2. 勾选要同步的书籍
3. 选择「菜单」→「工具」→「云端书库」→「元数据同步/书籍同步」

【自动同步设置（仅元数据）】仅针对当前阅读的单本书籍
1. 默认不开启，通过勾选下方具体选项自动开启对应模式。
2. 自动上传备份：编辑标注、关闭书籍、设备休眠时自动上传元数据覆盖云端（可以同时开启，但不建议这么做，推荐选择关闭书籍或设备休眠时自动备份）
3. 自动下载更新：打开书籍时自动从云端下载元数据更新本地（覆盖/合并两种模式）

- 注意事项：
  - 开启自动上传会导致云端元数据文件完全被当前设备元数据文件覆盖，请谨慎设置。
  - 开启自动下载会导致当前设备元数据文件完全被云端元数据文件覆盖或合并，请谨慎设置。
  - 开启自动同步时，为防止不同设备数据被意外覆盖，请尽量选择合并更新模式。

【额外备份JSON文件】
开启时会在上传时额外将原始元数据文件转换为JSON格式并同原始元数据文件一并上传，JSON格式不是用于不同设备上koreader书籍元数据同步的标准文件，而是为了满足用户对koreader上的标注进行进一步整理的需要，按需开启即可。

【同步记录】
1. 每次同步操作都会生成同步记录，可用于排查同步失败问题
2. 开启「记录云同步」后，同步记录会自动与云端同步，可查看不同设备上的同步记录
3.可通过查看同步记录中的清空按钮和「菜单」→「工具」→「云端书库」→「设置」中的清空云端同步记录分别清空本地和云端同步记录
注意：因为本插件是直接操作设备原有的元数据文件，所以如果设备本地没有元数据文件（如还未曾打开过的书籍、或者初次打开的书籍还没来得及生成元数据文件），就会提示同步失败，未找到本地元数据文件，此时只要重新打开书籍后再进行同步操作即可）

【手势快捷操作】
-分别在阅读界面和文件管理器界面进入「设置」→「手势」→「手势管理」，选择手势后勾选阅读器和文件管理器中的云端书库相应菜单
-结合元数据下载模式设置，实现一个手势下载/批量下载（智能模式）

【更新说明】
cloudlibrary（更名后） 在小红书MetedataSync（更名前） v0.22版本的基础上添加了一些新功能，修复了一些bug：

1.  添加书籍同步功能，可批量上传或下载/删除云端书籍（v1.0）
2.  添加手势快捷操作，可通过手势调出快捷操作、快捷设置（v1.0）
3.  修复通过手势快捷操作时文件浏览器选择模式可能状态混乱的问题（v1.0）
4.  修复合并更新时pdf文档崩溃的问题（v1.0）
5.  修复合并更新时部分标注可能丢失渲染的问题（v1.0）
6.  优化合并更新时笔记更新的问题（v1.0）
7.  添加清空云端同步记录的功能（v1.0）
8.  优化同步记录开启记录云同步后可能格式混乱的问题（v1.0）
9.  取消自动同步上传下载互斥限制，可同时开启自动上传和自动下载 （v1.0）
10. 添加在线更新功能（v1.0）
11. 覆盖更新由完全覆盖改为可选覆盖，可以选择是否需要保留本地文档设置（v1.0）

ps：在线更新功能实测安卓端会崩溃，但新文件仍旧会自动下载到koreader\plugins路径，只需要找到该路径下的插件压缩包，解压覆盖旧的插件文件后重新打开koreader即可。

    ]]
    
    local textviewer = TextViewer:new{
        title = _("云端书库 插件说明"),
        text = info_text,
        justified = false,
    }
    UIManager:show(textviewer)
end

function CloudLibraryPlugin:onDispatcherRegisterActions()
    Dispatcher:registerAction("cloudlibrary_reader", {
        category = "none",
        event = "CloudLibraryReader",
        title = _("云端书库-快捷操作"),
        reader = true,
    })
    
    Dispatcher:registerAction("cloudlibrary_filemanager", {
        category = "none",
        event = "CloudLibraryFileManager",
        title = _("云端书库-快捷操作"),
        filemanager = true,
    })

    Dispatcher:registerAction("cloudlibrary_settings_reader", {
        category = "none",
        event = "CloudLibrarySettingsReader",
        title = _("云端书库-快捷设置"),
        reader = true,
    })

    Dispatcher:registerAction("cloudlibrary_settings_filemanager", {
        category = "none",
        event = "CloudLibrarySettingsFileManager",
        title = _("云端书库-快捷设置"),
        filemanager = true,
    })

    Dispatcher:registerAction("cloudlibrary_upload_current", {
        category = "none",
        event = "CloudLibraryUploadCurrent",
        title = _("云端书库-上传当前书籍元数据"),
        reader = true,
    })
    
    Dispatcher:registerAction("cloudlibrary_download_current", {
        category = "none",
        event = "CloudLibraryDownloadCurrent",
        title = _("云端书库-下载当前书籍元数据（智能模式）"),
        reader = true,
    })
    
    Dispatcher:registerAction("cloudlibrary_batch_upload_metadata", {
        category = "none",
        event = "CloudLibraryBatchUploadMetadata",
        title = _("云端书库-批量上传选中书籍元数据"),
        filemanager = true,
    })
    
    Dispatcher:registerAction("cloudlibrary_batch_download_metadata_smart", {
        category = "none",
        event = "CloudLibraryBatchDownloadMetadataSmart",
        title = _("云端书库-批量下载元数据（智能模式）"),
        filemanager = true,
    })
    
    Dispatcher:registerAction("cloudlibrary_batch_upload_books", {
        category = "none",
        event = "CloudLibraryBatchUploadBooks",
        title = _("云端书库-批量上传选中书籍文件"),
        filemanager = true,
    })
    
    Dispatcher:registerAction("cloudlibrary_batch_download_books", {
        category = "none",
        event = "CloudLibraryBatchDownloadBooks",
        title = _("云端书库-批量下载云端书籍文件"),
        filemanager = true,
    })
end

function CloudLibraryPlugin:onCloudLibraryReader()
    self:showSyncDialog("reader")
end

function CloudLibraryPlugin:onCloudLibraryFileManager()
    self:showSyncDialog("filemanager")
end

function CloudLibraryPlugin:showSyncDialog(context)
    local buttons = {}
    local BookSync = require("book_sync")
    local mode_text = (self.settings.auto_download_mode == "merge") and "合并更新" or "覆盖更新"
    
    if context == "reader" then
        buttons = {
            { 
                { text = _("上传当前书籍元数据"), callback = function()
                    if self._current_dialog then
                        UIManager:close(self._current_dialog)
                        self._current_dialog = nil
                    end
                    self.manual_sync:syncCurrentBook(true)
                end } 
            },
            { 
                { text = string.format(_("下载当前书籍元数据（%s）"), mode_text), callback = function()
                    if self._current_dialog then
                        UIManager:close(self._current_dialog)
                        self._current_dialog = nil
                    end
                    if self.settings.auto_download_mode == "merge" then
                        self.manual_sync:syncCurrentBookMerge()
                    else
                        self.manual_sync:syncCurrentBook(false)
                    end
                end } 
            },
            { 
                { text = _("查看同步记录"), callback = function()
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
                { text = _("批量上传选中书籍元数据"), callback = function()
                    if self._current_dialog then
                        UIManager:close(self._current_dialog)
                        self._current_dialog = nil
                    end
                    self.manual_sync:batchSyncWithFMSelection(true, false)
                end } 
            },
            { 
                { text = string.format(_("批量下载选中书籍元数据（%s）"), mode_text), callback = function()
                    if self._current_dialog then
                        UIManager:close(self._current_dialog)
                        self._current_dialog = nil
                    end
                    local is_merge = (self.settings.auto_download_mode == "merge")
                    self.manual_sync:batchSyncWithFMSelection(false, is_merge)
                end } 
            },
            { 
                { text = _("批量上传选中书籍"), callback = function()
                    if self._current_dialog then
                        UIManager:close(self._current_dialog)
                        self._current_dialog = nil
                    end
                    BookSync.batchUploadWithFMSelection(self)
                end } 
            },
            { 
                { text = _("批量下载云端书籍"), callback = function()
                    if self._current_dialog then
                        UIManager:close(self._current_dialog)
                        self._current_dialog = nil
                    end
                    self:batchDownloadBooks()
                end } 
            },
            { 
                { text = _("查看同步记录"), callback = function()
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
        title = _("云端书库-快捷操作"),
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
        if self.settings.auto_download_mode == "merge" then
            self.manual_sync:syncCurrentBookMerge()
        else
            self.manual_sync:syncCurrentBook(false)
        end
    end
end

function CloudLibraryPlugin:onCloudLibrarySettingsReader()
    self:showSettingsDialog("reader")
end

function CloudLibraryPlugin:onCloudLibrarySettingsFileManager()
    self:showSettingsDialog("filemanager")
end

function CloudLibraryPlugin:showSettingsDialog(context)
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
        self_ref:showSettingsDialog(context)
    end
    
    local buttons = {}
    
    -- 云端目录设置
    table.insert(buttons, {
        {
            text = _("设置云端目录"),
            callback = function()
                local SyncService = require("apps/cloudstorage/syncservice")
                local remote = require("remote")
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
    
    -- 元数据命名方式
    local metadata_naming_mode = self.settings.metadata_naming_mode or "metadata"
    local metadata_naming_text = ""
    if metadata_naming_mode == "filename" then
        metadata_naming_text = "使用文件名"
    elseif metadata_naming_mode == "metadata" then
        metadata_naming_text = "使用书籍标题"
    elseif metadata_naming_mode == "title_author" then
        metadata_naming_text = "使用标题_作者"
    end
    
    table.insert(buttons, {
        {
            text = _("元数据命名方式: ") .. metadata_naming_text,
            callback = function()
                self:showMetadataNamingModeDialog()
                if self_ref._current_settings_dialog then
                    UIManager:close(self_ref._current_settings_dialog)
                    self_ref._current_settings_dialog = nil
                end
            end
        }
    })
    
    -- 书籍命名方式
    local book_naming_mode = self.settings.book_naming_mode or "title"
    local book_naming_text = ""
    if book_naming_mode == "filename" then
        book_naming_text = "使用文件名"
    elseif book_naming_mode == "title" then
        book_naming_text = "使用书籍标题"
    elseif book_naming_mode == "title_author" then
        book_naming_text = "使用标题_作者"
    end
    
    table.insert(buttons, {
        {
            text = _("书籍命名方式: ") .. book_naming_text,
            callback = function()
                self:showBookNamingModeDialog()
                if self_ref._current_settings_dialog then
                    UIManager:close(self_ref._current_settings_dialog)
                    self_ref._current_settings_dialog = nil
                end
            end
        }
    })
    
    -- 书籍下载目录
    table.insert(buttons, {
        {
            text_func = function()
                local dir = self.settings.book_download_dir
                if dir and dir ~= "" then
                    return _("书籍下载目录: ") .. dir
                else
                    return _("设置书籍下载目录")
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
    
    -- 元数据下载模式（手动）
    local download_mode_text = (self.settings.auto_download_mode == "merge") and "合并更新" or "覆盖更新"
    table.insert(buttons, {
        {
            text = _("元数据下载模式（手动）: ") .. download_mode_text,
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
    
    -- 自动上传备份
    table.insert(buttons, {
        {
            text_func = function()
                return (self.settings.auto_upload_on_annotate and "✓ " or "  ") .. _("编辑标注时自动上传元数据")
            end,
            callback = function()
                self.settings.auto_upload_on_annotate = not self.settings.auto_upload_on_annotate
                self:updateAutoSyncSettings()
                G_reader_settings:saveSetting(self.plugin_id, self.settings)
                local utils = require("utils")
                utils.show_msg(self.settings.auto_upload_on_annotate and "已开启" or "已关闭")
                rebuildAndShow()
            end
        }
    })
    
    table.insert(buttons, {
        {
            text_func = function()
                return (self.settings.auto_upload_on_close and "✓ " or "  ") .. _("关闭书籍时自动上传元数据")
            end,
            callback = function()
                self.settings.auto_upload_on_close = not self.settings.auto_upload_on_close
                self:updateAutoSyncSettings()
                G_reader_settings:saveSetting(self.plugin_id, self.settings)
                local utils = require("utils")
                utils.show_msg(self.settings.auto_upload_on_close and "已开启" or "已关闭")
                rebuildAndShow()
            end
        }
    })
    
    table.insert(buttons, {
        {
            text_func = function()
                return (self.settings.auto_upload_on_suspend and "✓ " or "  ") .. _("设备休眠时自动上传元数据")
            end,
            callback = function()
                self.settings.auto_upload_on_suspend = not self.settings.auto_upload_on_suspend
                self:updateAutoSyncSettings()
                G_reader_settings:saveSetting(self.plugin_id, self.settings)
                local utils = require("utils")
                utils.show_msg(self.settings.auto_upload_on_suspend and "已开启" or "已关闭")
                rebuildAndShow()
            end
        }
    })
    
    table.insert(buttons, {})
    
    -- 自动下载更新选项
    table.insert(buttons, {
        {
            text_func = function()
                local enabled = self.settings.auto_download_on_open and self.settings.auto_download_mode == "override"
                return (enabled and "✓ " or "  ") .. _("打开书籍时自动下载元数据（覆盖更新）")
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
                local utils = require("utils")
                utils.show_msg(self.settings.auto_download_on_open and self.settings.auto_download_mode == "override" and 
                    "已开启：打开书籍时自动下载元数据（覆盖更新）" or "已关闭")
                rebuildAndShow()
            end
        }
    })
    
    table.insert(buttons, {
        {
            text_func = function()
                local enabled = self.settings.auto_download_on_open and self.settings.auto_download_mode == "merge"
                return (enabled and "✓ " or "  ") .. _("打开书籍时自动下载元数据（合并更新）")
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
                local utils = require("utils")
                utils.show_msg(self.settings.auto_download_on_open and self.settings.auto_download_mode == "merge" and 
                    "已开启：打开书籍时自动下载元数据（合并更新）" or "已关闭")
                rebuildAndShow()
            end
        }
    })
    
    table.insert(buttons, {})
    
    -- 其他设置
    table.insert(buttons, {
        {
            text_func = function()
                return (self.settings.upload_json and "✓ " or "  ") .. _("额外备份JSON文件")
            end,
            callback = function()
                self.settings.upload_json = not self.settings.upload_json
                G_reader_settings:saveSetting(self.plugin_id, self.settings)
                local utils = require("utils")
                utils.show_msg(self.settings.upload_json and "已开启" or "已关闭")
                rebuildAndShow()
            end
        }
    })
    
    table.insert(buttons, {
        {
            text_func = function()
                return (self.settings.override_keep_local_settings and "✓ " or "  ") .. _("覆盖更新时保留本地文档设置")
            end,
            callback = function()
                self.settings.override_keep_local_settings = not self.settings.override_keep_local_settings
                G_reader_settings:saveSetting(self.plugin_id, self.settings)
                local utils = require("utils")
                utils.show_msg(self.settings.override_keep_local_settings and 
                    "已开启：覆盖更新时保留本地文档设置" or 
                    "已关闭：覆盖更新时完全使用云端文件")
                rebuildAndShow()
            end
        }
    })
    
    table.insert(buttons, {
        {
            text_func = function()
                return (self.settings.sync_log_enabled and "✓ " or "  ") .. _("开启记录云同步")
            end,
            callback = function()
                self.settings.sync_log_enabled = not self.settings.sync_log_enabled
                G_reader_settings:saveSetting(self.plugin_id, self.settings)
                if self.settings.sync_log_enabled then
                    local sync_log = require("sync_log")
                    sync_log.sync_log()
                end
                local utils = require("utils")
                utils.show_msg(self.settings.sync_log_enabled and "已开启" or "已关闭")
                rebuildAndShow()
            end
        }
    })
    
    table.insert(buttons, {
        {
            text_func = function()
                return (self.settings.auto_sync_notify and "✓ " or "  ") .. _("自动同步时显示通知")
            end,
            callback = function()
                self.settings.auto_sync_notify = not self.settings.auto_sync_notify
                G_reader_settings:saveSetting(self.plugin_id, self.settings)
                local utils = require("utils")
                utils.show_msg(self.settings.auto_sync_notify and "已开启" or "已关闭")
                rebuildAndShow()
            end
        }
    })
    
    table.insert(buttons, {})
    
    -- 查看同步记录、清空云端同步记录、插件说明、检查更新
    table.insert(buttons, {
        {
            text = _("查看同步记录"),
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
            text = _("清空云端同步记录"),
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
            text = _("插件说明"),
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
            text = _("检查更新"),
            callback = function()
                local update = require("update")
                update.check_for_updates(false, self)
                if self_ref._current_settings_dialog then
                    UIManager:close(self_ref._current_settings_dialog)
                    self_ref._current_settings_dialog = nil
                end
            end
        }
    })
    
    -- 限制菜单高度
    local dialog = ButtonDialog:new{
        title = _("云端书库-快捷设置"),
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
                text = (current_mode == "filename" and "✓ " or "  ") .. _("使用文件名"),
                callback = function()
                    self.settings.metadata_naming_mode = "filename"
                    G_reader_settings:saveSetting(self.plugin_id, self.settings)
                    local utils = require("utils")
                    utils.show_msg(_("元数据使用文件名命名"))
                    if dialog then
                        UIManager:close(dialog)
                    end
                end
            }
        },
        {
            {
                text = (current_mode == "metadata" and "✓ " or "  ") .. _("使用书籍标题（默认）"),
                callback = function()
                    self.settings.metadata_naming_mode = "metadata"
                    G_reader_settings:saveSetting(self.plugin_id, self.settings)
                    local utils = require("utils")
                    utils.show_msg(_("元数据使用书籍标题命名"))
                    if dialog then
                        UIManager:close(dialog)
                    end
                end
            }
        },
        {
            {
                text = (current_mode == "title_author" and "✓ " or "  ") .. _("使用标题_作者"),
                callback = function()
                    self.settings.metadata_naming_mode = "title_author"
                    G_reader_settings:saveSetting(self.plugin_id, self.settings)
                    local utils = require("utils")
                    utils.show_msg(_("元数据使用「标题_作者」格式命名"))
                    if dialog then
                        UIManager:close(dialog)
                    end
                end
            }
        },
        {},
        {
            {
                text = _("返回"),
                callback = function()
                    if dialog then
                        UIManager:close(dialog)
                    end
                end
            }
        }
    }
    
    dialog = ButtonDialog:new{
        title = _("元数据命名方式"),
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
                text = (current_mode == "filename" and "✓ " or "  ") .. _("使用文件名"),
                callback = function()
                    self.settings.book_naming_mode = "filename"
                    G_reader_settings:saveSetting(self.plugin_id, self.settings)
                    local utils = require("utils")
                    utils.show_msg(_("书籍使用文件名命名"))
                    if dialog then
                        UIManager:close(dialog)
                    end
                end
            }
        },
        {
            {
                text = (current_mode == "title" and "✓ " or "  ") .. _("使用书籍标题（默认）"),
                callback = function()
                    self.settings.book_naming_mode = "title"
                    G_reader_settings:saveSetting(self.plugin_id, self.settings)
                    local utils = require("utils")
                    utils.show_msg(_("书籍使用书籍标题命名"))
                    if dialog then
                        UIManager:close(dialog)
                    end
                end
            }
        },
        {
            {
                text = (current_mode == "title_author" and "✓ " or "  ") .. _("使用标题_作者"),
                callback = function()
                    self.settings.book_naming_mode = "title_author"
                    G_reader_settings:saveSetting(self.plugin_id, self.settings)
                    local utils = require("utils")
                    utils.show_msg(_("书籍使用「标题_作者」格式命名"))
                    if dialog then
                        UIManager:close(dialog)
                    end
                end
            }
        },
        {},
        {
            {
                text = _("返回"),
                callback = function()
                    if dialog then
                        UIManager:close(dialog)
                    end
                end
            }
        }
    }
    
    dialog = ButtonDialog:new{
        title = _("书籍命名方式"),
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
    
    local current_mode = self.settings.auto_download_mode or "merge"
    
    local dialog
    local buttons = {
        {
            {
                text = (current_mode == "override" and "✓ " or "  ") .. _("覆盖更新"),
                callback = function()
                    self.settings.auto_download_mode = "override"
                    G_reader_settings:saveSetting(self.plugin_id, self.settings)
                    local utils = require("utils")
                    utils.show_msg(_("元数据下载模式（手动）：覆盖更新"))
                    if dialog then
                        UIManager:close(dialog)
                    end
                end
            }
        },
        {
            {
                text = (current_mode == "merge" and "✓ " or "  ") .. _("合并更新"),
                callback = function()
                    self.settings.auto_download_mode = "merge"
                    G_reader_settings:saveSetting(self.plugin_id, self.settings)
                    local utils = require("utils")
                    utils.show_msg(_("元数据下载模式（手动）：合并更新"))
                    if dialog then
                        UIManager:close(dialog)
                    end
                end
            }
        },
        {},
        {
            {
                text = _("返回"),
                callback = function()
                    if dialog then
                        UIManager:close(dialog)
                    end
                end
            }
        }
    }
    
    dialog = ButtonDialog:new{
        title = _("元数据下载模式（手动）"),
        title_align = "center",
        buttons = buttons,
        width = math.floor(Screen:getWidth() * 0.7),
    }
    UIManager:show(dialog)
end

function CloudLibraryPlugin:onCloudLibraryBatchUploadMetadata()
    self.manual_sync:batchSyncWithFMSelection(true, false)
end

function CloudLibraryPlugin:onCloudLibraryBatchDownloadMetadataSmart()
    local is_merge = (self.settings.auto_download_mode == "merge")
    self.manual_sync:batchSyncWithFMSelection(false, is_merge)
end

function CloudLibraryPlugin:onCloudLibraryBatchUploadBooks()
    local BookSync = require("book_sync")
    BookSync.batchUploadWithFMSelection(self)
end

function CloudLibraryPlugin:onCloudLibraryBatchDownloadBooks()
    self:batchDownloadBooks()
end

return CloudLibraryPlugin