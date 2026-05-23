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

local DOWNLOAD_DIR = DataStorage:getDataDir() .. "/metadatasync/"

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
            reason = _("Device not connected to network"), 
            solution = _("Please turn on Wi-Fi and try again") 
        },
        [ERROR_TYPES.NO_SERVER_CONFIG] = { 
            reason = _("Cloud storage service not configured"), 
            solution = _("Please configure cloud storage in settings") 
        },
        [ERROR_TYPES.UNSUPPORTED_SERVER] = { 
            reason = _("Unsupported cloud storage type"), 
            solution = _("Please use WebDAV or Dropbox") 
        },
        [ERROR_TYPES.AUTH_FAILED] = { 
            reason = _("Cloud storage authentication failed"), 
            solution = _("Please check username/password") 
        },
        [ERROR_TYPES.LOCAL_METADATA_NOT_EXISTS] = { 
            reason = _("Local metadata file not found"), 
            solution = _("Please open the book first to generate metadata file") 
        },
        [ERROR_TYPES.CLOUD_FILE_NOT_FOUND] = { 
            reason = _("Metadata file not found in cloud"), 
            solution = _("Please upload the book first") 
        },
        [ERROR_TYPES.FILENAME_TOO_LONG] = { 
            reason = _("Cloud filename too long, upload failed"), 
            solution = string.format(_("Please try:\n1. Shorten the book filename\n2. Switch cloud naming to \"Use Book Title\"\nCurrent naming mode: %s"), 
                naming_mode == "metadata" and _("Use Book Title") or _("Use Filename")) 
        },
        [ERROR_TYPES.UNKNOWN_ERROR] = { 
            reason = _("Unknown error"), 
            solution = _("Please check the log file") 
        }
    }
    return messages[error_type] or { reason = _("Unknown error"), solution = _("Contact developer") }
end

function M.ensure_download_dir()
    if lfs.attributes(DOWNLOAD_DIR, "mode") then
        return true
    end
    local success = pcall(function()
        os.execute("mkdir -p " .. DOWNLOAD_DIR)
    end)
    if not success or not lfs.attributes(DOWNLOAD_DIR, "mode") then
        return false
    end
    return true
end

function M.ensure_sdr_directory(book_file)
    local DocSettings = require("docsettings")
    
    local sdr_dir = DocSettings:getSidecarDir(book_file)
    if not sdr_dir then
        return nil
    end
    
    if lfs.attributes(sdr_dir, "mode") == "directory" then
        return sdr_dir
    end
    
    local escaped_dir = sdr_dir:gsub("([() ])", "\\%1")
    os.execute("mkdir -p " .. escaped_dir)
    
    if lfs.attributes(sdr_dir, "mode") == "directory" then
        return sdr_dir
    else
        return nil
    end
end

function M.ensure_local_metadata(book)
    local metadata_exists = book.metadata and lfs.attributes(book.metadata, "mode") == "file"
    
    if metadata_exists then
        return true
    end
    
    local sdr_dir = M.ensure_sdr_directory(book.file)
    if not sdr_dir then
        return false
    end
    
    local ext = book.file:match("%.([^%.]+)$") or "epub"
    book.metadata = sdr_dir .. "/metadata." .. ext .. ".lua"
    
    return true
end

function M.save_metadata_native(metadata, book_file)
    local DocSettings = require("docsettings")
    
    local doc_settings = DocSettings:open(book_file)
    doc_settings.data = metadata
    doc_settings:flush()
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
        text = string.format(_("Cloud storage configured:\n%s"), server.url),
        timeout = 3
    })
end

function M.get_book_cloud_dir()
    return G_reader_settings:readSetting("cloud_book_dir")
end

function M.set_book_cloud_dir(dir)
    G_reader_settings:saveSetting("cloud_book_dir", dir)
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

local function generate_random_string(length)
    length = length or 8
    local chars = "abcdefghijklmnopqrstuvwxyz0123456789"
    local result = ""
    for i = 1, length do
        local rand = math.random(1, #chars)
        result = result .. chars:sub(rand, rand)
    end
    return result
end

local function datetime_to_timestamp(datetime_str)
    if not datetime_str then
        return nil
    end
    local year, month, day, hour, min, sec = datetime_str:match("(%d+)-(%d+)-(%d+) (%d+):(%d+):(%d+)")
    if not year then
        return nil
    end
    local dt = os.time({
        year = tonumber(year),
        month = tonumber(month),
        day = tonumber(day),
        hour = tonumber(hour),
        min = tonumber(min),
        sec = tonumber(sec)
    })
    return (dt - 8 * 3600) * 1000
end

local function datetime_to_iso(datetime_str)
    if not datetime_str then
        return nil
    end
    local timestamp_ms = datetime_to_timestamp(datetime_str)
    if not timestamp_ms then
        return nil
    end
    local seconds = math.floor(timestamp_ms / 1000)
    local millis = timestamp_ms % 1000
    local utc_time = os.date("!%Y-%m-%dT%H:%M:%S", seconds)
    return string.format("%s.%03dZ", utc_time, millis)
end

local function generate_id(annotation_type, datetime_str)
    local timestamp_ms = datetime_to_timestamp(datetime_str) or (os.time() * 1000)
    local random_str = generate_random_string(8)
    return string.format("%s_%d_%s", annotation_type, timestamp_ms, random_str)
end

local function convert_annotation_to_notemark(ann)
    local text = ann.text or ""
    local datetime_str = ann.datetime or ""
    local datetime_updated = ann.datetime_updated or ann.datetime or ""
    local note_content = ann.note or ""
    local drawer = ann.drawer
    
    local notemark = {
        order = 1,
        total = 1,
        timestamp = datetime_to_iso(datetime_str) or os.date("!%Y-%m-%dT%H:%M:%S.000Z")
    }
    
    if note_content and note_content ~= "" then
        notemark.id = generate_id("note", datetime_str)
        notemark.type = "note"
        notemark.text = text
        notemark.note = note_content
        notemark.noteType = "richtext"
        notemark.updated = datetime_to_iso(datetime_updated) or notemark.timestamp
        return notemark
    end
    
    if drawer == "lighten" then
        notemark.id = generate_id("highlight", datetime_str)
        notemark.type = "highlight"
        notemark.text = text
    elseif drawer == "underscore" then
        notemark.id = generate_id("htmltag", datetime_str)
        notemark.type = "html-tag"
        notemark.text = text
        notemark.htmlTag = "u"
    elseif drawer == "strikeout" then
        notemark.id = generate_id("question", datetime_str)
        notemark.type = "question"
        notemark.text = text
    elseif drawer == "invert" then
        notemark.id = generate_id("bold", datetime_str)
        notemark.type = "bold"
        notemark.text = text
    else
        return nil
    end
    
    return notemark
end

function M.convert_annotations_to_notemarkdata(annotations)
    if not annotations or type(annotations) ~= "table" or #annotations == 0 then
        return nil
    end
    
    local notemarks = {}
    for _, ann in ipairs(annotations) do
        local notemark = convert_annotation_to_notemark(ann)
        if notemark then
            table.insert(notemarks, notemark)
        end
    end
    
    if #notemarks == 0 then
        return nil
    end
    
    return {
        NoteMarkData = {
            notemarks = notemarks
        }
    }
end

function M.convert_metadata_to_json(lua_path)
    if not lua_path or not lfs.attributes(lua_path, "mode") then
        return nil
    end
    
    local merge = require("merge")
    local metadata = merge.load_metadata(lua_path)
    if not metadata then
        return nil
    end
    
    local clean_data = M.clean_for_json(metadata)
    
    local ok, json_str = pcall(json.encode, clean_data)
    if not ok or not json_str then
        return nil
    end
    
    local json_tmp_path = lua_path .. ".json.tmp"
    local f = io.open(json_tmp_path, "w")
    if not f then
        return nil
    end
    f:write(json_str)
    f:close()
    
    return json_tmp_path
end

function M.convert_metadata_to_json_with_notemark(lua_path)
    if not lua_path or not lfs.attributes(lua_path, "mode") then
        return nil
    end
    
    local merge = require("merge")
    local metadata = merge.load_metadata(lua_path)
    if not metadata then
        return nil
    end
    
    local annotations = metadata.annotations
    local notemark_data = M.convert_annotations_to_notemarkdata(annotations)
    
    if not notemark_data then
        return nil
    end
    
    local output_data = notemark_data
    
    local ok, json_str = pcall(json.encode, output_data)
    if not ok or not json_str then
        return nil
    end
    
    local json_tmp_path = lua_path .. ".json.tmp"
    local f = io.open(json_tmp_path, "w")
    if not f then
        return nil
    end
    f:write(json_str)
    f:close()
    
    return json_tmp_path
end

function M.upload_dual_format(server, lua_path, lua_filename, book)
    local settings = G_reader_settings:readSetting("cloud_library_plugin", {})
    local use_notemark = settings.use_notemark_format == true
    
    local json_tmp_path
    if use_notemark then
        json_tmp_path = M.convert_metadata_to_json_with_notemark(lua_path)
    else
        json_tmp_path = M.convert_metadata_to_json(lua_path)
    end
    
    if not json_tmp_path then
        return
    end
    
    local json_success = M.upload_json_to_cloud(server, json_tmp_path, lua_filename)
    
    if json_success and book and book.title then
        local log_path = DataStorage:getDataDir() .. "/cloudlibrary_sync_log.txt"
        local f = io.open(log_path, "a")
        if f then
            local timestamp = os.date("%Y-%m-%d %H:%M:%S")
            if use_notemark then
                f:write(string.format("[%s] JSON format uploaded (NoteMarkData): %s\n", timestamp, book.title))
            else
                f:write(string.format("[%s] JSON format uploaded: %s\n", timestamp, book.title))
            end
            f:close()
        end
    end
    
    os.remove(json_tmp_path)
end

function M.upload_json_to_cloud(server, json_path, lua_filename)
    if not json_path or not lfs.attributes(json_path, "mode") then
        return false
    end
    
    local api = M.get_api(server)
    if not api then
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
        return true
    else
        return false
    end
end

function M.upload_book(book, naming_mode)
    local ReaderUI = require("apps/reader/readerui")
    local current_ui = ReaderUI.instance
    local is_currently_open = (current_ui and current_ui.document and current_ui.document.file == book.file)
    
    if is_currently_open then
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
            M.upload_dual_format(server, book.metadata, cloud_filename, book)
        end
        return true
    end
    
    if type(code) == "number" and code == 401 then
        return false, ERROR_TYPES.AUTH_FAILED
    end
    
    return false, ERROR_TYPES.UNKNOWN_ERROR
end

function M.download_book(book, naming_mode, progress_callback)
    local Merger = require("merge")
    local ReaderUI = require("apps/reader/readerui")
    local current_ui = ReaderUI.instance
    local is_currently_open = (current_ui and current_ui.document and current_ui.document.file == book.file)
    
    if not M.ensure_local_metadata(book) then
        return false, ERROR_TYPES.LOCAL_METADATA_NOT_EXISTS
    end
    
    if is_currently_open then
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
    
    local cloud_path
    if server.type == "dropbox" then
        local url_base = server.url:sub(-1) == "/" and server.url or server.url.."/"
        cloud_path = url_base .. cloud_filename
    else
        cloud_path = api:getJoinedPath(server.address, server.url)
        cloud_path = api:getJoinedPath(cloud_path, cloud_filename)
    end
    
    local downloaded_file = DOWNLOAD_DIR .. cloud_filename
    local code
    
    if server.type == "dropbox" then
        local token = server.password
        if server.address and server.address ~= "" then
            token = api:getAccessToken(server.password, server.address)
        end
        code = api:downloadFile(cloud_path, token, downloaded_file, progress_callback)
    else
        code = api:downloadFile(cloud_path, server.username, server.password, downloaded_file, progress_callback)
    end
    
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
    
    local settings = G_reader_settings:readSetting("cloud_library_plugin", {})
    local keep_local_settings = settings.override_keep_local_settings == true
    
    local merged_data
    if keep_local_settings then
        merged_data = Merger.override_merge(book.metadata, downloaded_file)
    else
        merged_data = Merger.load_metadata(downloaded_file)
    end
    os.remove(downloaded_file)
    
    if not merged_data then
        return false, "merge_failed"
    end
    
    M.save_metadata_native(merged_data, book.file)
    
    if is_currently_open then
        local plugin = get_plugin()
        if plugin and plugin.auto_sync then
            plugin.auto_sync:setSkipUpload(false)
        end
        if plugin then
            plugin._skip_auto_download = true
        end
        ReaderUI:showReader(book.file)
    end
    
    return true
end

function M.download_book_merge(book, naming_mode, progress_callback)
    local Merger = require("merge")
    local ReaderUI = require("apps/reader/readerui")
    local current_ui = ReaderUI.instance
    local is_currently_open = (current_ui and current_ui.document and current_ui.document.file == book.file)
    
    if not M.ensure_local_metadata(book) then
        return false, ERROR_TYPES.LOCAL_METADATA_NOT_EXISTS
    end
    
    if is_currently_open then
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
    
    local cloud_path
    if server.type == "dropbox" then
        local url_base = server.url:sub(-1) == "/" and server.url or server.url.."/"
        cloud_path = url_base .. cloud_filename
    else
        cloud_path = api:getJoinedPath(server.address, server.url)
        cloud_path = api:getJoinedPath(cloud_path, cloud_filename)
    end
    
    local downloaded_file = DOWNLOAD_DIR .. cloud_filename
    local code
    
    if server.type == "dropbox" then
        local token = server.password
        if server.address and server.address ~= "" then
            token = api:getAccessToken(server.password, server.address)
        end
        code = api:downloadFile(cloud_path, token, downloaded_file, progress_callback)
    else
        code = api:downloadFile(cloud_path, server.username, server.password, downloaded_file, progress_callback)
    end
    
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
    
    local merged_data = Merger.merge(book.metadata, downloaded_file)
    os.remove(downloaded_file)
    
    if not merged_data then
        return false, "merge_failed"
    end
    
    M.save_metadata_native(merged_data, book.file)
    
    if is_currently_open then
        local plugin = get_plugin()
        if plugin and plugin.auto_sync then
            plugin.auto_sync:setSkipUpload(false)
        end
        if plugin then
            plugin._skip_auto_download = true
        end
        ReaderUI:showReader(book.file)
    end
    
    return true
end

function M.download_book_before_open(book, naming_mode)
    local Merger = require("merge")
    
    if not M.ensure_local_metadata(book) then
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
    
    if not M.ensure_download_dir() then
        return false, "download_dir_create_failed"
    end
    
    local cloud_filename = M.get_cloud_filename(book, naming_mode)
    
    local cloud_path
    if server.type == "dropbox" then
        local url_base = server.url:sub(-1) == "/" and server.url or server.url.."/"
        cloud_path = url_base .. cloud_filename
    else
        cloud_path = api:getJoinedPath(server.address, server.url)
        cloud_path = api:getJoinedPath(cloud_path, cloud_filename)
    end
    
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
    
    if type(code) == "number" and code == 200 then
        if lfs.attributes(downloaded_file, "mode") then
            local settings = G_reader_settings:readSetting("cloud_library_plugin", {})
            local keep_local_settings = settings.override_keep_local_settings == true
            
            local merged_data
            if keep_local_settings then
                merged_data = Merger.override_merge(book.metadata, downloaded_file)
            else
                merged_data = Merger.load_metadata(downloaded_file)
            end
            os.remove(downloaded_file)
            
            if merged_data then
                M.save_metadata_native(merged_data, book.file)
            end
            
            return true
        end
    end
    
    if type(code) == "number" and code == 404 then
        return false, ERROR_TYPES.CLOUD_FILE_NOT_FOUND
    end
    
    if type(code) == "number" and code == 401 then
        return false, ERROR_TYPES.AUTH_FAILED
    end
    
    return false, ERROR_TYPES.UNKNOWN_ERROR
end

function M.download_book_merge_before_open(book, naming_mode)
    local Merger = require("merge")
    
    if not M.ensure_local_metadata(book) then
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
    
    if not M.ensure_download_dir() then
        return false, "download_dir_create_failed"
    end
    
    local cloud_filename = M.get_cloud_filename(book, naming_mode)
    
    local cloud_path
    if server.type == "dropbox" then
        local url_base = server.url:sub(-1) == "/" and server.url or server.url.."/"
        cloud_path = url_base .. cloud_filename
    else
        cloud_path = api:getJoinedPath(server.address, server.url)
        cloud_path = api:getJoinedPath(cloud_path, cloud_filename)
    end
    
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
    
    if type(code) == "number" and code == 200 then
        if lfs.attributes(downloaded_file, "mode") then
            local merged_data = Merger.merge(book.metadata, downloaded_file)
            os.remove(downloaded_file)
            
            if merged_data then
                M.save_metadata_native(merged_data, book.file)
            else
                return false, "merge_failed"
            end
            
            return true
        end
    end
    
    if type(code) == "number" and code == 404 then
        return false, ERROR_TYPES.CLOUD_FILE_NOT_FOUND
    end
    
    if type(code) == "number" and code == 401 then
        return false, ERROR_TYPES.AUTH_FAILED
    end
    
    return false, ERROR_TYPES.UNKNOWN_ERROR
end

-- Download metadata to temp directory without closing current book
function M.download_to_temp(book, naming_mode, progress_callback)
    local server = M.get_server()
    if not server then
        return nil, nil, ERROR_TYPES.NO_SERVER_CONFIG
    end

    local NetworkMgr = require("ui/network/manager")
    if not NetworkMgr:isOnline() then
        return nil, nil, ERROR_TYPES.NO_NETWORK
    end

    local api = M.get_api(server)
    if not api then
        return nil, nil, ERROR_TYPES.UNSUPPORTED_SERVER
    end

    if not M.ensure_download_dir() then
        return nil, nil, "download_dir_create_failed"
    end

    local cloud_filename = M.get_cloud_filename(book, naming_mode)

    local cloud_path
    if server.type == "dropbox" then
        local url_base = server.url:sub(-1) == "/" and server.url or server.url.."/"
        cloud_path = url_base .. cloud_filename
    else
        cloud_path = api:getJoinedPath(server.address, server.url)
        cloud_path = api:getJoinedPath(cloud_path, cloud_filename)
    end

    local downloaded_file = DOWNLOAD_DIR .. cloud_filename
    local code

    if server.type == "dropbox" then
        local token = server.password
        if server.address and server.address ~= "" then
            token = api:getAccessToken(server.password, server.address)
        end
        code = api:downloadFile(cloud_path, token, downloaded_file, progress_callback)
    else
        code = api:downloadFile(cloud_path, server.username, server.password, downloaded_file, progress_callback)
    end

    if type(code) ~= "number" or code ~= 200 then
        if lfs.attributes(downloaded_file, "mode") then
            os.remove(downloaded_file)
        end
        if type(code) == "number" and code == 404 then
            return nil, nil, ERROR_TYPES.CLOUD_FILE_NOT_FOUND
        end
        if type(code) == "number" and code == 401 then
            return nil, nil, ERROR_TYPES.AUTH_FAILED
        end
        return nil, nil, ERROR_TYPES.UNKNOWN_ERROR
    end

    if not lfs.attributes(downloaded_file, "mode") then
        return nil, nil, ERROR_TYPES.UNKNOWN_ERROR
    end

    return downloaded_file, cloud_filename, nil
end

return M
