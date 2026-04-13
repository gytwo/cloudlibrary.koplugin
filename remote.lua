local json = require("json")
local InfoMessage = require("ui/widget/infomessage")
local Notification = require("ui/widget/notification")
local ConfirmBox = require("ui/widget/confirmbox")
local UIManager = require("ui/uimanager")
local util = require("util")
local lfs = require("libs/libkoreader-lfs")
local docsettings = require("frontend/docsettings")
local DataStorage = require("datastorage")
local _ = require("gettext")
local logger = require("logger")
local Event = require("ui/event")
local M = {}

local DOWNLOAD_DIR = DataStorage:getDataDir() .. "metadatasync/"

local ERROR_TYPES = {
    NO_NETWORK = "no_network",
    NO_SERVER_CONFIG = "no_server_config",
    UNSUPPORTED_SERVER = "unsupported_server",
    AUTH_FAILED = "auth_failed",
    LOCAL_METADATA_NOT_EXISTS = "local_metadata_not_exists",
    CLOUD_FILE_NOT_FOUND = "cloud_file_not_found",
    FILENAME_TOO_LONG = "filename_too_long",
    UNKNOWN_ERROR = "unknown_error"
}

function M.get_error_message(error_type, is_upload, naming_mode)
    local messages = {
        [ERROR_TYPES.NO_NETWORK] = { 
            reason = "设备未连接到网络", 
            solution = "请打开 Wi-Fi 后重试" 
        },
        [ERROR_TYPES.NO_SERVER_CONFIG] = { 
            reason = "未配置云存储服务", 
            solution = "请在设置中配置云存储" 
        },
        [ERROR_TYPES.UNSUPPORTED_SERVER] = { 
            reason = "不支持的云服务类型", 
            solution = "请使用 WebDAV 或 Dropbox" 
        },
        [ERROR_TYPES.AUTH_FAILED] = { 
            reason = "云存储认证失败", 
            solution = "请检查用户名/密码" 
        },
        [ERROR_TYPES.LOCAL_METADATA_NOT_EXISTS] = { 
            reason = "未找到本地元数据文件", 
            solution = "请先打开该书生成元数据文件" 
        },
        [ERROR_TYPES.CLOUD_FILE_NOT_FOUND] = { 
            reason = "云端未找到元数据文件", 
            solution = "请先上传该书" 
        },
        [ERROR_TYPES.FILENAME_TOO_LONG] = { 
            reason = "云端文件名过长导致上传失败", 
            solution = string.format("请尝试：\n1. 缩短书籍文件名\n2. 切换云端命名方式为「使用书籍标题」（标题一般不会太长）\n当前命名方式：%s", 
                naming_mode == "metadata" and "使用书籍标题" or "使用文件名") 
        },
        [ERROR_TYPES.UNKNOWN_ERROR] = { 
            reason = "未知错误", 
            solution = "请查看日志文件" 
        }
    }
    return messages[error_type] or { reason = "未知错误", solution = "请联系开发者" }
end

function M.ensure_download_dir()
    if lfs.attributes(DOWNLOAD_DIR, "mode") then
        return true
    end
    local success = pcall(function()
        os.execute("mkdir -p " .. DOWNLOAD_DIR)
    end)
    if not success or not lfs.attributes(DOWNLOAD_DIR, "mode") then
        logger.info("CloudLibrary: 无法创建下载目录")
        return false
    end
    return true
end

-- 确保 sdr 目录存在
function M.ensure_sdr_directory(book_file)
    local DocSettings = require("docsettings")
    
    logger.info("CloudLibrary: ensure_sdr_directory 开始, book_file = " .. tostring(book_file))
    
    local sdr_dir = DocSettings:getSidecarDir(book_file)
    if not sdr_dir then
        logger.warn("CloudLibrary: DocSettings:getSidecarDir 返回 nil")
        return nil
    end
    logger.info("CloudLibrary: sdr_dir = " .. sdr_dir)
    
    if lfs.attributes(sdr_dir, "mode") == "directory" then
        logger.info("CloudLibrary: sdr 目录已存在")
        return sdr_dir
    end
    
    logger.info("CloudLibrary: sdr 目录不存在，开始创建...")
    pcall(function()
        os.execute("mkdir -p " .. sdr_dir)
    end)
    
    if lfs.attributes(sdr_dir, "mode") == "directory" then
        logger.info("CloudLibrary: sdr 目录创建成功: " .. sdr_dir)
        return sdr_dir
    else
        logger.error("CloudLibrary: sdr 目录创建失败: " .. sdr_dir)
        return nil
    end
end

-- 确保本地元数据文件存在（只创建目录，不创建空文件）
function M.ensure_local_metadata(book)
    logger.info("CloudLibrary: ===== ensure_local_metadata 开始 =====")
    logger.info("CloudLibrary: book.file = " .. tostring(book.file))
    logger.info("CloudLibrary: book.metadata = " .. tostring(book.metadata))
    logger.info("CloudLibrary: book.title = " .. tostring(book.title))
    
    local metadata_exists = book.metadata and lfs.attributes(book.metadata, "mode") == "file"
    logger.info("CloudLibrary: metadata_exists = " .. tostring(metadata_exists))
    
    if metadata_exists then
        logger.info("CloudLibrary: 元数据文件已存在，无需创建")
        return true
    end
    
    -- 创建 sdr 目录
    logger.info("CloudLibrary: 开始创建 sdr 目录...")
    local sdr_dir = M.ensure_sdr_directory(book.file)
    if not sdr_dir then
        logger.warn("CloudLibrary: ensure_sdr_directory 返回 nil")
        return false
    end
    logger.info("CloudLibrary: sdr_dir = " .. tostring(sdr_dir))
    
    -- 设置 metadata 路径：metadata.扩展名.lua
    local ext = book.file:match("%.([^%.]+)$") or "epub"
    book.metadata = sdr_dir .. "/metadata." .. ext .. ".lua"
    logger.info("CloudLibrary: 设置 book.metadata = " .. book.metadata)
    
    -- 不创建空文件，让后续的 save_metadata_native 创建
    return true
end

-- 使用 KOReader 原生方式保存元数据
function M.save_metadata_native(metadata, book_file)
    local DocSettings = require("docsettings")
    
    local doc_settings = DocSettings:open(book_file)
    doc_settings.data = metadata
    doc_settings:flush()
    logger.info("CloudLibrary: 使用原生方式保存元数据，书籍文件: " .. book_file)
    return true
end

function M.get_api(server)
    if server.type == "dropbox" then
        return require("apps/cloudstorage/dropboxapi")
    elseif server.type == "webdav" then
        return require("apps/cloudstorage/webdavapi")
    end
    return nil
end

function M.sanitize_filename(name)
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

function M.get_cloud_filename(book, naming_mode)
    if naming_mode == "metadata" or naming_mode == "title" then
        return M.sanitize_filename(book.title) .. ".lua"
    elseif naming_mode == "title_author" then
        local filename = book.title
        if book.author and book.author ~= "" then
            filename = book.title .. "_" .. book.author
        end
        return M.sanitize_filename(filename) .. ".lua"
    else
        return M.sanitize_filename(book.book_basename) .. ".lua"
    end
end

function M.get_server()
    local server_json = G_reader_settings:readSetting("cloud_server_object")
    if not server_json then
        return nil
    end
    return json.decode(server_json)
end

function M.save_server_settings(server)
    G_reader_settings:saveSetting("cloud_server_object", json.encode(server))
    G_reader_settings:saveSetting("cloud_download_dir", server.url)
    G_reader_settings:saveSetting("cloud_provider_type", server.type)
    UIManager:show(InfoMessage:new{
        text = string.format(_("云服务已设置:\n%s"), server.url),
        timeout = 3
    })
end

function M.get_book_cloud_dir()
    return G_reader_settings:readSetting("cloud_book_dir")
end

function M.set_book_cloud_dir(dir)
    G_reader_settings:saveSetting("cloud_book_dir", dir)
    logger.info("CloudLibrary: 书籍云端目录已设置为 " .. tostring(dir))
end

local function get_plugin()
    local ReaderUI = require("apps/reader/readerui")
    if ReaderUI and ReaderUI.instance and ReaderUI.instance.CloudLibrary then
        return ReaderUI.instance.CloudLibrary
    end
    return nil
end

function M.is_json_upload_enabled()
    local settings = G_reader_settings:readSetting("cloud_library_plugin", {})
    return settings.upload_json == true
end

function M.clean_for_json(data)
    if type(data) ~= "table" then
        return data
    end
    
    local clean = {}
    for k, v in pairs(data) do
        local t = type(v)
        if t == "table" then
            clean[k] = M.clean_for_json(v)
        elseif t == "string" or t == "number" or t == "boolean" then
            clean[k] = v
        end
    end
    return clean
end

function M.convert_metadata_to_json(lua_path)
    if not lua_path or not lfs.attributes(lua_path, "mode") then
        logger.warn("CloudLibrary: 元数据文件不存在，无法生成JSON: " .. tostring(lua_path))
        return nil
    end
    
    local merge = require("merge")
    local metadata = merge.load_metadata(lua_path)
    if not metadata then
        logger.warn("CloudLibrary: 无法加载元数据，无法生成JSON: " .. lua_path)
        return nil
    end
    
    local clean_data = M.clean_for_json(metadata)
    
    local ok, json_str = pcall(json.encode, clean_data)
    if not ok or not json_str then
        logger.warn("CloudLibrary: JSON编码失败: " .. tostring(ok))
        return nil
    end
    
    local json_tmp_path = lua_path .. ".json.tmp"
    local f = io.open(json_tmp_path, "w")
    if not f then
        logger.warn("CloudLibrary: 无法创建JSON临时文件: " .. json_tmp_path)
        return nil
    end
    f:write(json_str)
    f:close()
    
    return json_tmp_path
end

function M.upload_json_to_cloud(server, json_path, lua_filename)
    if not json_path or not lfs.attributes(json_path, "mode") then
        logger.warn("CloudLibrary: JSON文件不存在，无法上传: " .. tostring(json_path))
        return false
    end
    
    local api = M.get_api(server)
    if not api then
        logger.warn("CloudLibrary: 无法获取API，JSON上传失败")
        return false
    end
    
    local json_filename = lua_filename:gsub("%.lua$", ".json")
    
    local cloud_path
    if server.type == "dropbox" then
        local url_base = server.url:sub(-1) == "/" and server.url or server.url.."/"
        cloud_path = url_base .. json_filename
    else
        cloud_path = api:getJoinedPath(server.address, server.url)
        cloud_path = api:getJoinedPath(cloud_path, json_filename)
    end
    
    local code
    if server.type == "dropbox" then
        local token = server.password
        if server.address and server.address ~= "" then
            token = api:getAccessToken(server.password, server.address)
        end
        code = api:uploadFile(cloud_path, token, json_path, nil, true)
    else
        code = api:uploadFile(cloud_path, server.username, server.password, json_path)
    end
    
    if type(code) == "number" and code >= 200 and code < 300 then
        logger.info("CloudLibrary: JSON文件上传成功: " .. json_filename)
        return true
    else
        logger.warn("CloudLibrary: JSON文件上传失败, HTTP状态码: " .. tostring(code))
        return false
    end
end

function M.upload_dual_format(server, lua_path, lua_filename, book)
    local json_tmp_path = M.convert_metadata_to_json(lua_path)
    if not json_tmp_path then
        logger.warn("CloudLibrary: 生成JSON失败，仅上传LUA文件")
        return
    end
    
    local json_success = M.upload_json_to_cloud(server, json_tmp_path, lua_filename)
    
    if json_success and book and book.title then
        local log_path = DataStorage:getDataDir() .. "同步记录.txt"
        local f = io.open(log_path, "a")
        if f then
            local timestamp = os.date("%Y-%m-%d %H:%M:%S")
            f:write(string.format("[%s] JSON格式已上传: %s\n", timestamp, book.title))
            f:close()
        end
    end
    
    os.remove(json_tmp_path)
end

function M.upload_book(book, naming_mode)
    local ReaderUI = require("apps/reader/readerui")
    local current_ui = ReaderUI.instance
    local is_currently_open = (current_ui and current_ui.document and current_ui.document.file == book.file)
    
    if is_currently_open then
        logger.info("CloudLibrary: 保存当前书籍设置: " .. book.file)
        current_ui:saveSettings()
        UIManager:broadcastEvent(Event:new("FlushSettings"))
    end
    
    if not book.metadata or not lfs.attributes(book.metadata, "mode") then
        return false, ERROR_TYPES.LOCAL_METADATA_NOT_EXISTS
    end
    
    local server = M.get_server()
    if not server then
        return false, ERROR_TYPES.NO_SERVER_CONFIG
    end
    
    local NetworkMgr = require("ui/network/manager")
    if not NetworkMgr:isOnline() then
        return false, ERROR_TYPES.NO_NETWORK
    end
    
    local api = M.get_api(server)
    if not api then
        return false, ERROR_TYPES.UNSUPPORTED_SERVER
    end
    
    local cloud_filename = M.get_cloud_filename(book, naming_mode)
    
    if #cloud_filename > 255 then
        logger.warn("CloudLibrary: 云端文件名过长: " .. cloud_filename)
        return false, ERROR_TYPES.FILENAME_TOO_LONG
    end
    
    local cloud_path
    if server.type == "dropbox" then
        local url_base = server.url:sub(-1) == "/" and server.url or server.url.."/"
        cloud_path = url_base .. cloud_filename
    else
        cloud_path = api:getJoinedPath(server.address, server.url)
        cloud_path = api:getJoinedPath(cloud_path, cloud_filename)
    end
    
    local code
    if server.type == "dropbox" then
        local token = server.password
        if server.address and server.address ~= "" then
            token = api:getAccessToken(server.password, server.address)
        end
        code = api:uploadFile(cloud_path, token, book.metadata, nil, true)
    else
        code = api:uploadFile(cloud_path, server.username, server.password, book.metadata)
    end
    
    if type(code) == "number" and code >= 200 and code < 300 then
        if M.is_json_upload_enabled() then
            logger.info("CloudLibrary: 开始生成并上传JSON文件")
            M.upload_dual_format(server, book.metadata, cloud_filename, book)
        end
        return true
    end
    
    if type(code) == "number" and code == 401 then
        return false, ERROR_TYPES.AUTH_FAILED
    end
    
    return false, ERROR_TYPES.UNKNOWN_ERROR
end

-- ========== download_book 函数（手动同步-覆盖模式） ==========
function M.download_book(book, naming_mode)
    logger.info("CloudLibrary: ========== download_book 开始 ==========")
    logger.info("CloudLibrary: book.file = " .. tostring(book.file))
    logger.info("CloudLibrary: book.metadata = " .. tostring(book.metadata))
    
    local Merger = require("merge")
    local ReaderUI = require("apps/reader/readerui")
    local current_ui = ReaderUI.instance
    local is_currently_open = (current_ui and current_ui.document and current_ui.document.file == book.file)
    
    -- 直接调用 ensure_local_metadata，它会处理目录创建和 metadata 路径设置
    if not M.ensure_local_metadata(book) then
        logger.error("CloudLibrary: ensure_local_metadata 失败")
        return false, ERROR_TYPES.LOCAL_METADATA_NOT_EXISTS
    end
    logger.info("CloudLibrary: ensure_local_metadata 成功, book.metadata = " .. book.metadata)
    
    -- 如果当前打开，先关闭
    if is_currently_open then
        logger.info("CloudLibrary: 关闭当前书籍: " .. book.file)
        local plugin = get_plugin()
        if plugin and plugin.auto_sync then
            plugin.auto_sync:setSkipUpload(true)
        end
        G_reader_settings:saveSetting("cloudlibrary_skip_auto_download", true)
        current_ui:saveSettings()
        current_ui.tearing_down = true
        current_ui:onClose()
    end
    
    local server = M.get_server()
    if not server then
        return false, ERROR_TYPES.NO_SERVER_CONFIG
    end
    
    local NetworkMgr = require("ui/network/manager")
    if not NetworkMgr:isOnline() then
        return false, ERROR_TYPES.NO_NETWORK
    end
    
    local api = M.get_api(server)
    if not api then
        return false, ERROR_TYPES.UNSUPPORTED_SERVER
    end
    
    if not M.ensure_download_dir() then
        return false, "download_dir_create_failed"
    end
    
    local cloud_filename = M.get_cloud_filename(book, naming_mode)
    logger.info("CloudLibrary: download_book - cloud_filename = " .. cloud_filename)
    
    local cloud_path
    if server.type == "dropbox" then
        local url_base = server.url:sub(-1) == "/" and server.url or server.url.."/"
        cloud_path = url_base .. cloud_filename
    else
        cloud_path = api:getJoinedPath(server.address, server.url)
        cloud_path = api:getJoinedPath(cloud_path, cloud_filename)
    end
    logger.info("CloudLibrary: download_book - cloud_path = " .. tostring(cloud_path))
    
    local downloaded_file = DOWNLOAD_DIR .. cloud_filename
    local code
    
    if server.type == "dropbox" then
        local token = server.password
        if server.address and server.address ~= "" then
            token = api:getAccessToken(server.password, server.address)
        end
        code = api:downloadFile(cloud_path, token, downloaded_file)
    else
        code = api:downloadFile(cloud_path, server.username, server.password, downloaded_file)
    end
    
    logger.info("CloudLibrary: download_book - download code = " .. tostring(code))
    
    if type(code) ~= "number" or code ~= 200 then
        if lfs.attributes(downloaded_file, "mode") then
            os.remove(downloaded_file)
        end
        if type(code) == "number" and code == 404 then
            return false, ERROR_TYPES.CLOUD_FILE_NOT_FOUND
        end
        if type(code) == "number" and code == 401 then
            return false, ERROR_TYPES.AUTH_FAILED
        end
        return false, ERROR_TYPES.UNKNOWN_ERROR
    end
    
    if not lfs.attributes(downloaded_file, "mode") then
        return false, ERROR_TYPES.UNKNOWN_ERROR
    end
    logger.info("CloudLibrary: download_book - 下载成功")
    
    -- 获取设置，判断是否保留本地文档设置
    local settings = G_reader_settings:readSetting("cloud_library_plugin", {})
    local keep_local_settings = settings.override_keep_local_settings == true
    
    local merged_data
    if keep_local_settings then
        logger.info("CloudLibrary: 覆盖更新模式 - 保留本地文档设置")
        merged_data = Merger.override_merge(book.metadata, downloaded_file)
    else
        logger.info("CloudLibrary: 覆盖更新模式 - 完全使用云端文件")
        merged_data = Merger.load_metadata(downloaded_file)
    end
    os.remove(downloaded_file)
    
    if not merged_data then
        logger.error("CloudLibrary: 获取合并数据失败")
        return false, "merge_failed"
    end
    
    -- 使用原生方式保存
    M.save_metadata_native(merged_data, book.file)
    logger.info("CloudLibrary: 覆盖后的元数据已保存")
    
    -- 如果之前是打开的，重新打开
    if is_currently_open then
        logger.info("CloudLibrary: 重新打开书籍: " .. book.file)
        local plugin = get_plugin()
        if plugin and plugin.auto_sync then
            plugin.auto_sync:setSkipUpload(false)
        end
        if plugin then
            plugin._skip_auto_download = true
        end
        ReaderUI:showReader(book.file)
    end
    
    logger.info("CloudLibrary: ========== download_book 结束 ==========")
    return true
end

-- ========== download_book_merge 函数（手动同步-合并模式） ==========
function M.download_book_merge(book, naming_mode)
    logger.info("CloudLibrary: ========== download_book_merge 开始 ==========")
    logger.info("CloudLibrary: book.file = " .. tostring(book.file))
    logger.info("CloudLibrary: book.metadata = " .. tostring(book.metadata))
    logger.info("CloudLibrary: book.title = " .. tostring(book.title))
    
    local Merger = require("merge")
    local ReaderUI = require("apps/reader/readerui")
    local current_ui = ReaderUI.instance
    local is_currently_open = (current_ui and current_ui.document and current_ui.document.file == book.file)
    
    -- 直接调用 ensure_local_metadata，它会处理目录创建和 metadata 路径设置
    if not M.ensure_local_metadata(book) then
        logger.error("CloudLibrary: ensure_local_metadata 失败")
        return false, ERROR_TYPES.LOCAL_METADATA_NOT_EXISTS
    end
    logger.info("CloudLibrary: ensure_local_metadata 成功, book.metadata = " .. book.metadata)
    
    -- 如果当前打开，先关闭
    if is_currently_open then
        logger.info("CloudLibrary: 关闭当前书籍: " .. book.file)
        local plugin = get_plugin()
        if plugin and plugin.auto_sync then
            plugin.auto_sync:setSkipUpload(true)
        end
        G_reader_settings:saveSetting("cloudlibrary_skip_auto_download", true)
        current_ui:saveSettings()
        current_ui.tearing_down = true
        current_ui:onClose()
    end
    
    local server = M.get_server()
    if not server then
        return false, ERROR_TYPES.NO_SERVER_CONFIG
    end
    
    local NetworkMgr = require("ui/network/manager")
    if not NetworkMgr:isOnline() then
        return false, ERROR_TYPES.NO_NETWORK
    end
    
    local api = M.get_api(server)
    if not api then
        return false, ERROR_TYPES.UNSUPPORTED_SERVER
    end
    
    if not M.ensure_download_dir() then
        return false, "download_dir_create_failed"
    end
    
    local cloud_filename = M.get_cloud_filename(book, naming_mode)
    logger.info("CloudLibrary: download_book_merge - cloud_filename = " .. cloud_filename)
    
    local cloud_path
    if server.type == "dropbox" then
        local url_base = server.url:sub(-1) == "/" and server.url or server.url.."/"
        cloud_path = url_base .. cloud_filename
    else
        cloud_path = api:getJoinedPath(server.address, server.url)
        cloud_path = api:getJoinedPath(cloud_path, cloud_filename)
    end
    logger.info("CloudLibrary: download_book_merge - cloud_path = " .. tostring(cloud_path))
    
    local downloaded_file = DOWNLOAD_DIR .. cloud_filename
    local code
    
    if server.type == "dropbox" then
        local token = server.password
        if server.address and server.address ~= "" then
            token = api:getAccessToken(server.password, server.address)
        end
        code = api:downloadFile(cloud_path, token, downloaded_file)
    else
        code = api:downloadFile(cloud_path, server.username, server.password, downloaded_file)
    end
    
    logger.info("CloudLibrary: download_book_merge - download code = " .. tostring(code))
    
    if type(code) ~= "number" or code ~= 200 then
        if lfs.attributes(downloaded_file, "mode") then
            os.remove(downloaded_file)
        end
        if type(code) == "number" and code == 404 then
            return false, ERROR_TYPES.CLOUD_FILE_NOT_FOUND
        end
        if type(code) == "number" and code == 401 then
            return false, ERROR_TYPES.AUTH_FAILED
        end
        return false, ERROR_TYPES.UNKNOWN_ERROR
    end
    
    if not lfs.attributes(downloaded_file, "mode") then
        return false, ERROR_TYPES.UNKNOWN_ERROR
    end
    logger.info("CloudLibrary: download_book_merge - 下载成功")
    
    logger.info("CloudLibrary: 开始合并元数据")
    local merged_data = Merger.merge(book.metadata, downloaded_file)
    os.remove(downloaded_file)
    
    if not merged_data then
        logger.error("CloudLibrary: 合并元数据失败")
        return false, "merge_failed"
    end
    
    -- 使用原生方式保存
    M.save_metadata_native(merged_data, book.file)
    logger.info("CloudLibrary: 合并后的元数据已保存")
    
    -- 如果之前是打开的，重新打开
    if is_currently_open then
        logger.info("CloudLibrary: 重新打开书籍: " .. book.file)
        local plugin = get_plugin()
        if plugin and plugin.auto_sync then
            plugin.auto_sync:setSkipUpload(false)
        end
        if plugin then
            plugin._skip_auto_download = true
        end
        ReaderUI:showReader(book.file)
    end
    
    logger.info("CloudLibrary: ========== download_book_merge 结束 ==========")
    return true
end

-- ========== download_book_before_open 函数（自动下载-覆盖模式） ==========
function M.download_book_before_open(book, naming_mode)
    logger.info("CloudLibrary: ========== download_book_before_open 开始 ==========")
    logger.info("CloudLibrary: book.file = " .. tostring(book.file))
    logger.info("CloudLibrary: book.metadata = " .. tostring(book.metadata))
    
    local Merger = require("merge")
    
    if not M.ensure_local_metadata(book) then
        logger.error("CloudLibrary: ensure_local_metadata 失败")
        return false, ERROR_TYPES.LOCAL_METADATA_NOT_EXISTS
    end
    logger.info("CloudLibrary: ensure_local_metadata 成功, book.metadata = " .. book.metadata)
    
    local server = M.get_server()
    if not server then
        return false, ERROR_TYPES.NO_SERVER_CONFIG
    end
    
    local NetworkMgr = require("ui/network/manager")
    if not NetworkMgr:isOnline() then
        return false, ERROR_TYPES.NO_NETWORK
    end
    
    local api = M.get_api(server)
    if not api then
        return false, ERROR_TYPES.UNSUPPORTED_SERVER
    end
    
    if not M.ensure_download_dir() then
        return false, "download_dir_create_failed"
    end
    
    local cloud_filename = M.get_cloud_filename(book, naming_mode)
    logger.info("CloudLibrary: download_book_before_open - cloud_filename = " .. cloud_filename)
    
    local cloud_path
    if server.type == "dropbox" then
        local url_base = server.url:sub(-1) == "/" and server.url or server.url.."/"
        cloud_path = url_base .. cloud_filename
    else
        cloud_path = api:getJoinedPath(server.address, server.url)
        cloud_path = api:getJoinedPath(cloud_path, cloud_filename)
    end
    logger.info("CloudLibrary: download_book_before_open - cloud_path = " .. tostring(cloud_path))
    
    local downloaded_file = DOWNLOAD_DIR .. cloud_filename
    local code
    
    if server.type == "dropbox" then
        local token = server.password
        if server.address and server.address ~= "" then
            token = api:getAccessToken(server.password, server.address)
        end
        code = api:downloadFile(cloud_path, token, downloaded_file)
    else
        code = api:downloadFile(cloud_path, server.username, server.password, downloaded_file)
    end
    
    logger.info("CloudLibrary: download_book_before_open - download code = " .. tostring(code))
    
    if type(code) == "number" and code == 200 then
        if lfs.attributes(downloaded_file, "mode") then
            logger.info("CloudLibrary: download_book_before_open - 下载成功")
            
            -- 获取设置，判断是否保留本地文档设置
            local settings = G_reader_settings:readSetting("cloud_library_plugin", {})
            local keep_local_settings = settings.override_keep_local_settings == true
            
            local merged_data
            if keep_local_settings then
                logger.info("CloudLibrary: 自动下载覆盖模式 - 保留本地文档设置")
                merged_data = Merger.override_merge(book.metadata, downloaded_file)
            else
                logger.info("CloudLibrary: 自动下载覆盖模式 - 完全使用云端文件")
                merged_data = Merger.load_metadata(downloaded_file)
            end
            os.remove(downloaded_file)
            
            if merged_data then
                M.save_metadata_native(merged_data, book.file)
                logger.info("CloudLibrary: 覆盖后的元数据已保存")
            end
            
            logger.info("CloudLibrary: ========== download_book_before_open 成功 ==========")
            return true
        end
    end
    
    if type(code) == "number" and code == 404 then
        logger.warn("CloudLibrary: download_book_before_open - 云端文件不存在")
        return false, ERROR_TYPES.CLOUD_FILE_NOT_FOUND
    end
    
    if type(code) == "number" and code == 401 then
        logger.warn("CloudLibrary: download_book_before_open - 认证失败")
        return false, ERROR_TYPES.AUTH_FAILED
    end
    
    logger.error("CloudLibrary: download_book_before_open - 下载失败, code = " .. tostring(code))
    return false, ERROR_TYPES.UNKNOWN_ERROR
end

-- ========== download_book_merge_before_open 函数（自动下载-合并模式） ==========
function M.download_book_merge_before_open(book, naming_mode)
    logger.info("CloudLibrary: ========== download_book_merge_before_open 开始 ==========")
    logger.info("CloudLibrary: book.file = " .. tostring(book.file))
    logger.info("CloudLibrary: book.metadata = " .. tostring(book.metadata))
    
    local Merger = require("merge")
    
    if not M.ensure_local_metadata(book) then
        logger.error("CloudLibrary: ensure_local_metadata 失败")
        return false, ERROR_TYPES.LOCAL_METADATA_NOT_EXISTS
    end
    logger.info("CloudLibrary: ensure_local_metadata 成功, book.metadata = " .. book.metadata)
    
    local server = M.get_server()
    if not server then
        return false, ERROR_TYPES.NO_SERVER_CONFIG
    end
    
    local NetworkMgr = require("ui/network/manager")
    if not NetworkMgr:isOnline() then
        return false, ERROR_TYPES.NO_NETWORK
    end
    
    local api = M.get_api(server)
    if not api then
        return false, ERROR_TYPES.UNSUPPORTED_SERVER
    end
    
    if not M.ensure_download_dir() then
        return false, "download_dir_create_failed"
    end
    
    local cloud_filename = M.get_cloud_filename(book, naming_mode)
    logger.info("CloudLibrary: download_book_merge_before_open - cloud_filename = " .. cloud_filename)
    
    local cloud_path
    if server.type == "dropbox" then
        local url_base = server.url:sub(-1) == "/" and server.url or server.url.."/"
        cloud_path = url_base .. cloud_filename
    else
        cloud_path = api:getJoinedPath(server.address, server.url)
        cloud_path = api:getJoinedPath(cloud_path, cloud_filename)
    end
    logger.info("CloudLibrary: download_book_merge_before_open - cloud_path = " .. tostring(cloud_path))
    
    local downloaded_file = DOWNLOAD_DIR .. cloud_filename
    local code
    
    if server.type == "dropbox" then
        local token = server.password
        if server.address and server.address ~= "" then
            token = api:getAccessToken(server.password, server.address)
        end
        code = api:downloadFile(cloud_path, token, downloaded_file)
    else
        code = api:downloadFile(cloud_path, server.username, server.password, downloaded_file)
    end
    
    logger.info("CloudLibrary: download_book_merge_before_open - download code = " .. tostring(code))
    
    if type(code) == "number" and code == 200 then
        if lfs.attributes(downloaded_file, "mode") then
            logger.info("CloudLibrary: download_book_merge_before_open - 下载成功，开始合并")
            local merged_data = Merger.merge(book.metadata, downloaded_file)
            os.remove(downloaded_file)
            
            if merged_data then
                M.save_metadata_native(merged_data, book.file)
                logger.info("CloudLibrary: 合并后的元数据已保存")
            else
                logger.warn("CloudLibrary: 合并失败")
                return false, "merge_failed"
            end
            
            logger.info("CloudLibrary: ========== download_book_merge_before_open 成功 ==========")
            return true
        end
    end
    
    if type(code) == "number" and code == 404 then
        logger.warn("CloudLibrary: download_book_merge_before_open - 云端文件不存在")
        return false, ERROR_TYPES.CLOUD_FILE_NOT_FOUND
    end
    
    if type(code) == "number" and code == 401 then
        logger.warn("CloudLibrary: download_book_merge_before_open - 认证失败")
        return false, ERROR_TYPES.AUTH_FAILED
    end
    
    logger.error("CloudLibrary: download_book_merge_before_open - 下载失败, code = " .. tostring(code))
    return false, ERROR_TYPES.UNKNOWN_ERROR
end

return M
