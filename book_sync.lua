-- book_sync.lua
-- 书籍文件云端同步模块

local logger = require("logger")
local lfs = require("libs/libkoreader-lfs")
local DataStorage = require("datastorage")
local NetworkMgr = require("ui/network/manager")
local UIManager = require("ui/uimanager")
local Notification = require("ui/widget/notification")
local ConfirmBox = require("ui/widget/confirmbox")
local ButtonDialog = require("ui/widget/buttondialog")
local Device = require("device")
local Screen = Device.screen
local _ = require("gettext")
local utils = require("utils")

local M = {}

local BOOK_EXTENSIONS = {
    ".pdf", ".epub", ".mobi", ".azw", ".azw3", ".kfx",
    ".cbz", ".cbr", ".fb2", ".djvu", ".docx", ".txt"
}

local function get_server()
    local json = require("json")
    local server_json = G_reader_settings:readSetting("cloud_server_object")
    if not server_json then
        return nil
    end
    return json.decode(server_json)
end

local function get_api(server)
    if server.type == "dropbox" then
        return require("apps/cloudstorage/dropboxapi")
    elseif server.type == "webdav" then
        return require("apps/cloudstorage/webdavapi")
    end
    return nil
end

local function sanitize_filename(name)
    if not name or name == "" then
        return "unknown_book"
    end
    local illegal_chars = '[\\/:*?\"<>|%s]'
    local sanitized = name:gsub(illegal_chars, "_")
    if #sanitized > 200 then
        sanitized = sanitized:sub(1, 200)
    end
    return sanitized
end

local function get_file_extension(file_path)
    local ext = file_path:match("%.([^%.]+)$")
    return ext and ("." .. ext) or ""
end

local function get_cloud_path(server, cloud_filename)
    local api = get_api(server)
    if not api then
        return nil
    end
    
    local base_dir = server.book_url or server.url
    
    if server.type == "dropbox" then
        local url_base = base_dir:sub(-1) == "/" and base_dir or base_dir .. "/"
        return url_base .. cloud_filename
    else
        local path = api:getJoinedPath(server.address, base_dir)
        return api:getJoinedPath(path, cloud_filename)
    end
end

function M.get_cloud_filename_for_path(book, naming_mode)
    local original_filename = book.file_path:match("([^/]+)$") or "unknown_book"
    local ext = get_file_extension(original_filename)
    
    if naming_mode == "filename" then
        return sanitize_filename(original_filename)
    end
    
    if naming_mode == "title_author" then
        local filename = book.title
        if book.author and book.author ~= "" then
            filename = book.title .. "_" .. book.author
        end
        return sanitize_filename(filename) .. ext
    end
    
    local title = book.title
    if not title or title == "" then
        title = original_filename:gsub("%.[^%.]+$", "")
    end
    return sanitize_filename(title) .. ext
end

function M.check_cloud_file_exists(cloud_filename)
    logger.info("BookSync: check_cloud_file_exists, cloud_filename=" .. tostring(cloud_filename))
    local server = get_server()
    if not server then
        logger.warn("BookSync: check_cloud_file_exists, server is nil")
        return false
    end
    
    local api = get_api(server)
    if not api then
        logger.warn("BookSync: check_cloud_file_exists, api is nil")
        return false
    end
    
    local cloud_path = get_cloud_path(server, cloud_filename)
    if not cloud_path then
        logger.warn("BookSync: check_cloud_file_exists, cloud_path is nil")
        return false
    end
    
    logger.info("BookSync: check_cloud_file_exists, cloud_path=" .. tostring(cloud_path))
    
    local temp_file = DataStorage:getDataDir() .. "check_temp.tmp"
    local code
    
    if server.type == "dropbox" then
        local token = server.password
        if server.address and server.address ~= "" then
            token = api:getAccessToken(server.password, server.address)
        end
        code = api:downloadFile(cloud_path, token, temp_file)
    else
        code = api:downloadFile(cloud_path, server.username, server.password, temp_file)
    end
    
    if lfs.attributes(temp_file, "mode") then
        os.remove(temp_file)
    end
    
    logger.info("BookSync: check_cloud_file_exists, code=" .. tostring(code))
    return type(code) == "number" and code == 200
end

function M.write_batch_book_log(results, action)
    local timestamp = os.date("%Y-%m-%d %H:%M:%S")
    local log_path = utils.get_log_path()
    
    local device_name = utils.get_device_name()
    local device_id = utils.get_device_id()
    
    local action_text = (action == "upload") and "书籍同步-批量上传" or (action == "download") and "书籍同步-批量下载" or "书籍同步-批量删除"
    
    local new_record = {}
    table.insert(new_record, utils.SEPARATOR_LINE)
    table.insert(new_record, string.format("同步时间: %s", timestamp))
    table.insert(new_record, string.format("操作设备: %s", device_name))
    table.insert(new_record, string.format("设备ID: %s", device_id))
    table.insert(new_record, string.format("操作类型: %s", action_text))
    table.insert(new_record, utils.SEPARATOR_LINE)
    
    table.insert(new_record, string.format("【成功】(%d 本)", #(results.success or {})))
    table.insert(new_record, string.rep("-", 40))
    if #(results.success or {}) > 0 then
        for _, book in ipairs(results.success) do
            table.insert(new_record, string.format("  ✓ %s", book.name))
        end
    else
        table.insert(new_record, "  无")
    end
    table.insert(new_record, "")
    
    if results.skipped and #results.skipped > 0 then
        table.insert(new_record, string.format("【跳过】(%d 本)", #results.skipped))
        table.insert(new_record, string.rep("-", 40))
        for _, book in ipairs(results.skipped) do
            table.insert(new_record, string.format("  ○ %s (%s)", book.name, book.reason))
        end
        table.insert(new_record, "")
    end
    
    table.insert(new_record, string.format("【失败】(%d 本)", #(results.failed or {})))
    table.insert(new_record, string.rep("-", 40))
    if #(results.failed or {}) > 0 then
        local failed_by_reason = {}
        for _, book in ipairs(results.failed) do
            local key = book.reason or "未知错误"
            if not failed_by_reason[key] then
                failed_by_reason[key] = { books = {} }
            end
            table.insert(failed_by_reason[key].books, { name = book.name })
        end
        local reason_index = 0
        for reason, info in pairs(failed_by_reason) do
            reason_index = reason_index + 1
            table.insert(new_record, string.format("\n【失败原因 %d】%s", reason_index, reason))
            table.insert(new_record, string.rep("~", 40))
            for i, book in ipairs(info.books) do
                table.insert(new_record, string.format("  (%d) %s", i, book.name))
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

local function show_notification(msg, timeout)
    UIManager:show(Notification:new{
        text = msg,
        timeout = timeout or 2
    })
end

function M.upload_book(book_path, show_msg, naming_mode, book_info)
    logger.info("BookSync: upload_book 被调用, book_path=" .. tostring(book_path))
    show_msg = (show_msg == nil) or show_msg
    
    if lfs.attributes(book_path, "mode") ~= "file" then
        logger.warn("BookSync: upload_book, 文件不存在")
        if show_msg then show_notification(_("书籍文件不存在"), 2) end
        return false, "file_not_found"
    end
    
    local ext = get_file_extension(book_path):lower()
    local is_book = false
    for _, book_ext in ipairs(BOOK_EXTENSIONS) do
        if ext == book_ext then
            is_book = true
            break
        end
    end
    if not is_book then
        logger.warn("BookSync: upload_book, 不支持的文件格式")
        if show_msg then show_notification(_("不支持的文件格式"), 2) end
        return false, "unsupported_format"
    end
    
    local server = get_server()
    if not server then
        logger.warn("BookSync: upload_book, server is nil")
        if show_msg then show_notification(_("未配置云存储服务"), 2) end
        return false, "no_server_config"
    end
    
    if not NetworkMgr:isOnline() then
        logger.warn("BookSync: upload_book, 网络未连接")
        if show_msg then show_notification(_("设备未连接到网络"), 2) end
        return false, "no_network"
    end
    
    local api = get_api(server)
    if not api then
        logger.warn("BookSync: upload_book, api is nil")
        if show_msg then show_notification(_("不支持的云服务类型"), 2) end
        return false, "unsupported_server"
    end
    
    local cloud_filename = M.get_cloud_filename_for_path({
        file_path = book_path,
        title = book_info.title,
        author = book_info.author,
    }, naming_mode)
    local cloud_path = get_cloud_path(server, cloud_filename)
    
    logger.info("BookSync: upload_book, cloud_filename=" .. tostring(cloud_filename))
    logger.info("BookSync: upload_book, cloud_path=" .. tostring(cloud_path))
    
    if not cloud_path then
        logger.warn("BookSync: upload_book, cloud_path is nil")
        if show_msg then show_notification(_("无法构建云端路径"), 2) end
        return false, "path_error"
    end
    
    local code
    if server.type == "dropbox" then
        local token = server.password
        if server.address and server.address ~= "" then
            token = api:getAccessToken(server.password, server.address)
        end
        code = api:uploadFile(cloud_path, token, book_path, nil, true)
    else
        code = api:uploadFile(cloud_path, server.username, server.password, book_path)
    end
    
    logger.info("BookSync: upload_book, code=" .. tostring(code))
    
    if type(code) == "number" and code >= 200 and code < 300 then
        return true, "success"
    elseif type(code) == "number" and code == 401 then
        if show_msg then show_notification(_("云存储认证失败，请重新配置"), 3) end
        return false, "auth_failed"
    else
        if show_msg then
            show_notification(string.format(_("上传失败 (HTTP %s)"), tostring(code)), 3)
        end
        return false, "upload_failed"
    end
end

function M.download_book(cloud_filename, target_dir, show_msg)
    logger.info("BookSync: download_book 被调用, cloud_filename=" .. tostring(cloud_filename))
    show_msg = (show_msg == nil) or show_msg
    
    local settings = G_reader_settings:readSetting("cloud_library_plugin", {})
    local download_dir = target_dir or settings.book_download_dir
    if not download_dir or download_dir == "" then
        logger.warn("BookSync: download_book, 下载目录未设置")
        if show_msg then show_notification(_("请先在设置中指定书籍本地下载目录"), 3) end
        return false, "no_download_dir"
    end
    
    if lfs.attributes(download_dir, "mode") ~= "directory" then
        pcall(function()
            os.execute("mkdir -p " .. download_dir)
        end)
        if lfs.attributes(download_dir, "mode") ~= "directory" then
            logger.warn("BookSync: download_book, 无法创建下载目录")
            if show_msg then show_notification(_("无法创建下载目录"), 2) end
            return false, "cannot_create_dir"
        end
    end
    
    local local_path = download_dir .. "/" .. cloud_filename
    
    if lfs.attributes(local_path, "mode") == "file" then
        logger.info("BookSync: 文件已存在，跳过: " .. cloud_filename)
        return false, "file_exists"
    end
    
    local server = get_server()
    if not server then
        logger.warn("BookSync: download_book, server is nil")
        if show_msg then show_notification(_("未配置云存储服务"), 2) end
        return false, "no_server_config"
    end
    
    if not NetworkMgr:isOnline() then
        logger.warn("BookSync: download_book, 网络未连接")
        if show_msg then show_notification(_("设备未连接到网络"), 2) end
        return false, "no_network"
    end
    
    local api = get_api(server)
    if not api then
        logger.warn("BookSync: download_book, api is nil")
        if show_msg then show_notification(_("不支持的云服务类型"), 2) end
        return false, "unsupported_server"
    end
    
    local cloud_path = get_cloud_path(server, cloud_filename)
    logger.info("BookSync: download_book, cloud_path=" .. tostring(cloud_path))
    
    if not cloud_path then
        logger.warn("BookSync: download_book, cloud_path is nil")
        if show_msg then show_notification(_("无法构建云端路径"), 2) end
        return false, "path_error"
    end
    
    if show_msg then
        show_notification(string.format(_("正在下载: %s"), cloud_filename), 2)
    end
    
    local code
    if server.type == "dropbox" then
        local token = server.password
        if server.address and server.address ~= "" then
            token = api:getAccessToken(server.password, server.address)
        end
        code = api:downloadFile(cloud_path, token, local_path)
    else
        code = api:downloadFile(cloud_path, server.username, server.password, local_path)
    end
    
    logger.info("BookSync: download_book, code=" .. tostring(code))
    
    if type(code) == "number" and code == 200 then
        if show_msg then
            show_notification(string.format(_("✓ 下载成功: %s"), cloud_filename), 2)
        end
        return true, "success", local_path
    elseif type(code) == "number" and code == 404 then
        logger.warn("BookSync: download_book, 文件不存在")
        if show_msg then show_notification(_("云端文件不存在"), 2) end
        return false, "file_not_found"
    elseif type(code) == "number" and code == 401 then
        logger.warn("BookSync: download_book, 认证失败")
        if show_msg then show_notification(_("云存储认证失败"), 2) end
        return false, "auth_failed"
    else
        logger.warn("BookSync: download_book, 下载失败, code=" .. tostring(code))
        if show_msg then
            show_notification(string.format(_("下载失败 (HTTP %s)"), tostring(code)), 3)
        end
        return false, "download_failed"
    end
end

function M.delete_cloud_book(cloud_filename, show_msg)
    logger.info("BookSync: delete_cloud_book 被调用, cloud_filename=" .. tostring(cloud_filename))
    show_msg = (show_msg == nil) or show_msg
    
    local server = get_server()
    if not server then
        logger.warn("BookSync: delete_cloud_book, server is nil")
        if show_msg then show_notification(_("未配置云存储服务"), 2) end
        return false, "no_server_config"
    end
    
    if not NetworkMgr:isOnline() then
        logger.warn("BookSync: delete_cloud_book, 网络未连接")
        if show_msg then show_notification(_("设备未连接到网络"), 2) end
        return false, "no_network"
    end
    
    local api = get_api(server)
    if not api then
        logger.warn("BookSync: delete_cloud_book, api is nil")
        if show_msg then show_notification(_("不支持的云服务类型"), 2) end
        return false, "unsupported_server"
    end
    
    local cloud_path = get_cloud_path(server, cloud_filename)
    logger.info("BookSync: delete_cloud_book, cloud_path=" .. tostring(cloud_path))
    
    if not cloud_path then
        logger.warn("BookSync: delete_cloud_book, cloud_path is nil")
        if show_msg then show_notification(_("无法构建云端路径"), 2) end
        return false, "path_error"
    end
    
    local code
    if server.type == "dropbox" then
        local token = server.password
        if server.address and server.address ~= "" then
            token = api:getAccessToken(server.password, server.address)
        end
        code = api:deleteFile(cloud_path, token)
    else
        code = api:deleteFile(cloud_path, server.username, server.password)
    end
    
    logger.info("BookSync: delete_cloud_book, code=" .. tostring(code))
    
    if type(code) == "number" and code >= 200 and code < 300 then
        if show_msg then
            show_notification(string.format(_("✓ 删除成功: %s"), cloud_filename), 2)
        end
        return true, "success"
    elseif type(code) == "number" and code == 404 then
        logger.warn("BookSync: delete_cloud_book, 文件不存在")
        if show_msg then show_notification(_("云端文件不存在"), 2) end
        return false, "file_not_found"
    elseif type(code) == "number" and code == 401 then
        logger.warn("BookSync: delete_cloud_book, 认证失败")
        if show_msg then show_notification(_("云存储认证失败"), 2) end
        return false, "auth_failed"
    else
        logger.warn("BookSync: delete_cloud_book, 删除失败, code=" .. tostring(code))
        if show_msg then
            show_notification(string.format(_("删除失败 (HTTP %s)"), tostring(code)), 3)
        end
        return false, "delete_failed"
    end
end

function M.batch_delete_books(book_names, settings, plugin)
    logger.info("BookSync: batch_delete_books 被调用, 共 " .. #book_names .. " 本")
    
    local results = {
        success = {},
        failed = {}
    }
    
    for _, filename in ipairs(book_names) do
        local success, error_msg = M.delete_cloud_book(filename, false)
        
        if success then
            table.insert(results.success, {
                name = filename,
            })
        else
            table.insert(results.failed, {
                name = filename,
                reason = error_msg
            })
        end
        
        UIManager:scheduleIn(0.01, function() end)
    end
    
    M.write_batch_book_log(results, "delete")
    
    if settings then
        settings.last_sync = os.date("%Y-%m-%d %H:%M:%S") .. " (书籍同步-批量删除)"
        G_reader_settings:saveSetting(plugin and plugin.plugin_id or "cloud_library_plugin", settings)
    end
    
    local msg = string.format("删除完成: %d 成功, %d 失败", #results.success, #results.failed)
    show_notification(msg, 3)
    
    if #results.failed > 0 then
        UIManager:scheduleIn(0.5, function()
            local fail_msg = M.formatFailureDetails(results.failed)
            local TextViewer = require("ui/widget/textviewer")
            UIManager:show(TextViewer:new{
                title = _("删除失败详情"),
                text = fail_msg,
            })
        end)
    end
end

function M.get_cloud_book_list()
    logger.info("BookSync: get_cloud_book_list 被调用")
    local server = get_server()
    if not server then
        logger.warn("BookSync: get_cloud_book_list, server is nil")
        return nil, "未配置云存储服务"
    end
    
    local book_dir = server.book_url or server.url
    if not book_dir or book_dir == "" then
        logger.warn("BookSync: get_cloud_book_list, 云端目录未设置")
        return nil, "云端目录未设置"
    end
    
    local api = get_api(server)
    if not api then
        logger.warn("BookSync: get_cloud_book_list, api is nil")
        return nil, "不支持的云服务类型"
    end
    
    local items
    if server.type == "dropbox" then
        if api.listFolder then
            local token = server.password
            if server.address and server.address ~= "" then
                token = api:getAccessToken(server.password, server.address)
            end
            items = api:listFolder(book_dir, token, false)
        else
            return nil, "Dropbox API 不支持获取目录列表"
        end
    elseif server.type == "webdav" then
        if api.listFolder then
            items = api:listFolder(server.address, server.username, server.password, book_dir, false)
        else
            return nil, "WebDAV API 不支持获取目录列表"
        end
    else
        return nil, "不支持的云服务类型"
    end
    
    if not items or type(items) ~= "table" then
        logger.warn("BookSync: get_cloud_book_list, items is nil or not table")
        return nil, "无法获取云端文件列表"
    end
    
    local books = {}
    for _, item in ipairs(items) do
        if item.type == "file" then
            local filename = item.text
            if filename then
                local ext = filename:match("%.([^%.]+)$")
                if ext then
                    ext = "." .. ext:lower()
                    for _, book_ext in ipairs(BOOK_EXTENSIONS) do
                        if ext == book_ext then
                            table.insert(books, {
                                name = filename,
                                path = item.url,
                                size = item.filesize or 0,
                            })
                            break
                        end
                    end
                end
            end
        end
    end
    
    logger.info("BookSync: get_cloud_book_list, 找到 " .. #books .. " 本书")
    return books, nil
end

function M.show_cloud_book_dialog(callback, plugin)
    logger.info("BookSync: show_cloud_book_dialog 被调用")
    
    local books, err = M.get_cloud_book_list()
    if not books or #books == 0 then
        show_notification(err or _("云端没有找到书籍文件"), 3)
        return
    end
    
    local original_books = {}
    for i, book in ipairs(books) do
        table.insert(original_books, book)
    end
    
    local search_keyword = ""
    local items_per_page = 10
    local current_page = 1
    
    local selected = {}
    for _, book in ipairs(original_books) do
        selected[book.name] = false
    end
    
    local dialog
    local refresh_book_list
    local update_buttons
    local show_search_dialog
    local clear_search
    
    refresh_book_list = function()
        if search_keyword == "" then
            books = {}
            for i, book in ipairs(original_books) do
                table.insert(books, book)
            end
        else
            books = {}
            local keyword_lower = string.lower(search_keyword)
            for _, book in ipairs(original_books) do
                if string.find(string.lower(book.name), keyword_lower, 1, true) then
                    table.insert(books, book)
                end
            end
        end
        current_page = 1
    end
    
    update_buttons = function()
        local total_pages = math.ceil(#books / items_per_page)
        if total_pages == 0 then total_pages = 1 end
        if current_page > total_pages then current_page = total_pages end
        
        local start_idx = (current_page - 1) * items_per_page + 1
        local end_idx = math.min(start_idx + items_per_page - 1, #books)
        
        local buttons = {}
        
        if search_keyword ~= "" then
            table.insert(buttons, {
                {
                    text = string.format("搜索: \"%s\" (找到 %d 本)", search_keyword, #books),
                    enabled = false,
                }
            })
            table.insert(buttons, {})
        end
        
        for i = start_idx, end_idx do
            local book = books[i]
            local size_mb = string.format("%.2f MB", (book.size or 0) / (1024 * 1024))
            local check = selected[book.name] and "✓ " or "  "
            table.insert(buttons, {
                {
                    text = check .. book.name .. " (" .. size_mb .. ")",
                    callback = function()
                        selected[book.name] = not selected[book.name]
                        if dialog then
                            UIManager:close(dialog)
                            update_buttons()
                        end
                    end,
                }
            })
        end
        
        if #books == 0 then
            table.insert(buttons, {
                {
                    text = _("没有找到匹配的书籍"),
                    enabled = false,
                    alignment = "center",
                }
            })
        end
        
        table.insert(buttons, {})
        
        local nav_buttons = {}
        if current_page > 1 then
            table.insert(nav_buttons, {
                text = "◀ 上一页",
                callback = function()
                    current_page = current_page - 1
                    if dialog then
                        UIManager:close(dialog)
                    end
                    update_buttons()
                end
            })
        end
        table.insert(nav_buttons, {
            text = string.format("第 %d/%d 页 (%d本)", current_page, total_pages, #books),
            enabled = false,
        })
        if current_page < total_pages then
            table.insert(nav_buttons, {
                text = "下一页 ▶",
                callback = function()
                    current_page = current_page + 1
                    if dialog then
                        UIManager:close(dialog)
                    end
                    update_buttons()
                end
            })
        end
        table.insert(buttons, nav_buttons)
        
        table.insert(buttons, {})
        
        local selected_count = 0
        for _, book in ipairs(original_books) do
            if selected[book.name] then
                selected_count = selected_count + 1
            end
        end
        
        table.insert(buttons, {
            {
                text = _("全选"),
                callback = function()
                    for _, book in ipairs(original_books) do
                        selected[book.name] = true
                    end
                    if dialog then
                        UIManager:close(dialog)
                    end
                    update_buttons()
                end
            },
            {
                text = _("取消全选"),
                callback = function()
                    for _, book in ipairs(original_books) do
                        selected[book.name] = false
                    end
                    if dialog then
                        UIManager:close(dialog)
                    end
                    update_buttons()
                end
            },
            {
                text = _("搜索"),
                callback = function()
                    show_search_dialog()
                end
            },
        })
        
        table.insert(buttons, {
            {
                text = search_keyword ~= "" and _("清除搜索") or "",
                enabled = search_keyword ~= "",
                callback = function()
                    clear_search()
                end
            },
            {
                text = string.format(_("下载 (%d)"), selected_count),
                callback = function()
                    local selected_names = {}
                    for _, book in ipairs(original_books) do
                        if selected[book.name] then
                            table.insert(selected_names, book.name)
                        end
                    end
                    if dialog then
                        UIManager:close(dialog)
                    end
                    if #selected_names > 0 then
                        callback(selected_names)
                    else
                        show_notification(_("未选中任何书籍"), 2)
                    end
                end
            },
            {
                text = string.format(_("删除 (%d)"), selected_count),
                callback = function()
                    local selected_names = {}
                    for _, book in ipairs(original_books) do
                        if selected[book.name] then
                            table.insert(selected_names, book.name)
                        end
                    end
                    if dialog then
                        UIManager:close(dialog)
                    end
                    if #selected_names > 0 then
                        UIManager:show(ConfirmBox:new{
                            text = string.format(_("确定要删除 %d 本书籍吗？\n\n此操作不可恢复！"), #selected_names),
                            ok_text = _("删除"),
                            cancel_text = _("取消"),
                            ok_callback = function()
                                local settings = G_reader_settings:readSetting("cloud_library_plugin", {})
                                M.batch_delete_books(selected_names, settings, plugin)
                            end
                        })
                    else
                        show_notification(_("未选中任何书籍"), 2)
                    end
                end
            },
            {
                text = _("取消"),
                callback = function()
                    if dialog then
                        UIManager:close(dialog)
                    end
                end
            },
        })
        
        dialog = ButtonDialog:new{
            title = string.format(_("请选择要下载/删除的书籍 (已选 %d 本)"), selected_count),
            title_align = "center",
            buttons = buttons,
            width = math.floor(Screen:getWidth() * 0.85),
        }
        UIManager:show(dialog)
    end
    
    show_search_dialog = function()
        local InputDialog = require("ui/widget/inputdialog")
        local search_dialog = nil
        search_dialog = InputDialog:new{
            title = _("搜索书籍"),
            input = search_keyword,
            input_hint = _("输入书名关键字"),
            buttons = {
                {
                    {
                        text = _("取消"),
                        id = "close",
                        callback = function()
                            UIManager:close(search_dialog)
                        end,
                    },
                    {
                        text = _("搜索"),
                        is_enter_default = true,
                        callback = function()
                            search_keyword = search_dialog:getInputText()
                            UIManager:close(search_dialog)
                            refresh_book_list()
                            if dialog then
                                UIManager:close(dialog)
                            end
                            update_buttons()
                        end,
                    },
                },
            },
        }
        UIManager:show(search_dialog)
        search_dialog:onShowKeyboard()
    end
    
    clear_search = function()
        if search_keyword ~= "" then
            search_keyword = ""
            refresh_book_list()
            if dialog then
                UIManager:close(dialog)
            end
            update_buttons()
        end
    end
    
    refresh_book_list()
    update_buttons()
end

function M.batchUploadBooks(selected_books, naming_mode, settings, plugin)
    logger.info("BookSync: batchUploadBooks 被调用, 共 " .. #selected_books .. " 本书")
    logger.info("BookSync: naming_mode = " .. tostring(naming_mode))
    
    local results = {
        success = {},
        failed = {}
    }
    
    for _, book_info in ipairs(selected_books) do
        local path = book_info.path or book_info.file_path
        local local_name = path:match("([^/]+)$") or "未知"
        
        local cloud_name = M.get_cloud_filename_for_path({
            file_path = path,
            title = book_info.title,
            author = book_info.author,
        }, naming_mode)
        
        local success, error_msg = M.upload_book(path, false, naming_mode, {
            title = book_info.title,
            author = book_info.author,
        })
        
        if success then
            table.insert(results.success, {
                name = local_name,
                cloud_name = cloud_name,
                path = path
            })
        else
            table.insert(results.failed, {
                name = local_name,
                cloud_name = cloud_name,
                path = path,
                reason = error_msg
            })
        end
        
        UIManager:scheduleIn(0.01, function() end)
    end
    
    M.write_batch_book_log(results, "upload")
    
    settings.last_sync = os.date("%Y-%m-%d %H:%M:%S") .. " (书籍同步-批量上传)"
    G_reader_settings:saveSetting(plugin.plugin_id, settings)
    
    local msg = string.format("书籍上传完成: %d 成功, %d 失败", #results.success, #results.failed)
    UIManager:show(Notification:new{
        text = msg,
        timeout = 2
    })
    
    if #results.failed > 0 then
        UIManager:scheduleIn(0.5, function()
            local fail_msg = M.formatFailureDetails(results.failed)
            local TextViewer = require("ui/widget/textviewer")
            UIManager:show(TextViewer:new{
                title = _("上传失败详情"),
                text = fail_msg,
            })
        end)
    end
    
    M.cleanupFileManagerSelection()
    
    logger.info("BookSync: 批量上传完成, 成功:" .. #results.success .. ", 失败:" .. #results.failed)
end

function M.batchDownloadBooks(book_names, settings, plugin)
    logger.info("BookSync: batchDownloadBooks 被调用, 共 " .. #book_names .. " 本")
    
    local download_dir = settings.book_download_dir
    local results = {
        success = {},
        failed = {},
        skipped = {}
    }
    
    if not download_dir or download_dir == "" then
        table.insert(results.failed, {
            name = "所有书籍",
            reason = "下载目录未设置"
        })
    else
        for _, filename in ipairs(book_names) do
            local success, error_msg, _ = M.download_book(filename, nil, false)
            
            if success then
                table.insert(results.success, {
                    name = filename,
                    path = download_dir .. "/" .. filename
                })
            elseif error_msg == "file_exists" then
                table.insert(results.skipped, {
                    name = filename,
                    reason = "本地已存在同名文件"
                })
            else
                table.insert(results.failed, {
                    name = filename,
                    reason = error_msg
                })
            end
            
            UIManager:scheduleIn(0.01, function() end)
        end
    end
    
    M.write_batch_book_log(results, "download")
    
    settings.last_sync = os.date("%Y-%m-%d %H:%M:%S") .. " (书籍同步-批量下载)"
    G_reader_settings:saveSetting(plugin.plugin_id, settings)
    
    local msg = string.format("下载完成: %d 成功, %d 失败, %d 跳过", 
        #results.success, #results.failed, #results.skipped)
    UIManager:show(Notification:new{
        text = msg,
        timeout = 2
    })
    
    if #results.failed > 0 then
        UIManager:scheduleIn(0.5, function()
            local fail_msg = M.formatFailureDetails(results.failed)
            local TextViewer = require("ui/widget/textviewer")
            UIManager:show(TextViewer:new{
                title = _("下载失败详情"),
                text = fail_msg,
            })
        end)
    end
    
    M.refreshFileManager()
    
    logger.info("BookSync: 批量下载完成, 成功:" .. #results.success .. ", 失败:" .. #results.failed .. ", 跳过:" .. #results.skipped)
end

function M.refreshFileManager()
    local FileManager = require("apps/filemanager/filemanager")
    local fm = FileManager.instance
    if fm and fm.file_chooser then
        fm.file_chooser:refreshPath()
    end
end

function M.formatFailureDetails(failed_list)
    local fail_msg = "失败详情:\n\n"
    
    local failed_by_reason = {}
    for _, fail in ipairs(failed_list) do
        local reason = fail.reason or "未知错误"
        if not failed_by_reason[reason] then
            failed_by_reason[reason] = {}
        end
        table.insert(failed_by_reason[reason], fail)
    end
    
    local reason_index = 0
    for reason, books in pairs(failed_by_reason) do
        reason_index = reason_index + 1
        fail_msg = fail_msg .. string.format("【失败原因 %d】%s\n", reason_index, reason)
        fail_msg = fail_msg .. string.rep("~", 40) .. "\n"
        for i, book in ipairs(books) do
            fail_msg = fail_msg .. string.format("  %d. %s", i, book.name)
            if book.cloud_name then
                fail_msg = fail_msg .. string.format(" -> %s", book.cloud_name)
            end
            fail_msg = fail_msg .. "\n"
        end
        fail_msg = fail_msg .. "\n"
    end
    
    return fail_msg
end

function M.formatSkippedDetails(skipped_list)
    local skip_msg = "跳过详情:\n\n"
    skip_msg = skip_msg .. string.format("共 %d 本书籍因本地已存在同名文件而被跳过:\n\n", #skipped_list)
    
    for i, book in ipairs(skipped_list) do
        skip_msg = skip_msg .. string.format("  %d. %s\n", i, book.name)
    end
    
    skip_msg = skip_msg .. "\n提示: 如需重新下载，请先删除或重命名本地同名文件"
    
    return skip_msg
end

function M.cleanupFileManagerSelection()
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

function M.batchUploadWithFMSelection(plugin)
    logger.info("BookSync: batchUploadWithFMSelection 被调用")
    
    local ui = plugin.ui
    local action_text = "上传"
    local button_text = "批量上传选中书籍"
    
    if not ui or not ui.file_chooser then
        local FileManager = require("apps/filemanager/filemanager")
        
        if plugin.ui and plugin.ui.document then
            if plugin.auto_sync then
                plugin.auto_sync:setSkipUpload(true)
            end
            plugin.ui.tearing_down = true
            plugin.ui:onClose()
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
    
    local FileManager = require("apps/filemanager/filemanager")
    local fm = FileManager.instance
    
    if not fm then
        UIManager:show(Notification:new{
            text = _("无法获取文件管理器实例"),
            timeout = 3
        })
        return
    end
    
    if fm.selected_files == nil then
        fm:onToggleSelectMode(true)
        UIManager:show(Notification:new{
            text = string.format(_("请勾选要%s的书籍，再点击「%s」"), action_text, button_text),
            timeout = 5
        })
        return
    end
    
    local selected_files = fm.selected_files
    if not selected_files or next(selected_files) == nil then
        UIManager:show(Notification:new{
            text = string.format(_("请勾选要%s的书籍，再点击「%s」"), action_text, button_text),
            timeout = 5
        })
        return
    end
    
    local books = {}
    for file, selected in pairs(selected_files) do
        if selected and lfs.attributes(file, "mode") == "file" then
            local ext = get_file_extension(file):lower()
            local is_book = false
            for _, book_ext in ipairs(BOOK_EXTENSIONS) do
                if ext == book_ext then
                    is_book = true
                    break
                end
            end
            
            if is_book then
                local filename = file:match("([^/]+)$") or "未知"
                local basename = filename:gsub("%.[^%.]+$", "")
                
                local props = {}
                if ui and ui.bookinfo then
                    props = ui.bookinfo:getDocProps(file, nil, true) or {}
                end
                local title = props.title or props.display_title or basename
                local author = props.authors
                if type(author) == "table" then
                    author = author[1]
                end
                
                table.insert(books, {
                    file_path = file,
                    path = file,
                    name = filename,
                    title = title,
                    author = author,
                    book_basename = basename,
                })
            end
        end
    end
    
    if #books == 0 then
        UIManager:show(Notification:new{
            text = _("没有选中任何有效的书籍文件"),
            timeout = 3
        })
        return
    end
    
    local naming_mode = plugin.settings.book_naming_mode or "title"
    
    UIManager:show(ConfirmBox:new{
        text = string.format("将上传 %d 本书籍到云端", #books),
        ok_text = _("继续"),
        cancel_text = _("取消"),
        ok_callback = function()
            M.batchUploadBooks(books, naming_mode, plugin.settings, plugin)
        end
    })
end

return M