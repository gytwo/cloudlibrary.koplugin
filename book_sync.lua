-- book_sync.lua
-- Book file cloud sync module

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
local lfs = require("libs/libkoreader-lfs")
local DataStorage = require("datastorage")
local NetworkMgr = require("ui/network/manager")
local UIManager = require("ui/uimanager")
local Notification = require("ui/widget/notification")
local ConfirmBox = require("ui/widget/confirmbox")
local ButtonDialog = require("ui/widget/buttondialog")
local Device = require("device")
local Screen = Device.screen
local DocumentRegistry = require("document/documentregistry")
local util = require("util")
local _ = require("gettext")
local utils = dofile(_plugin_dir .. "utils.lua")

local M = {}

local function get_book_server()
    local json = require("json")
    local settings = G_reader_settings:readSetting("cloud_library_plugin", {})
    local book_cloud_dir = settings.book_cloud_dir
    
    if book_cloud_dir and book_cloud_dir ~= "" then
        local server = {
            type = settings.book_cloud_type or "webdav",
            url = book_cloud_dir,
            address = settings.book_cloud_address,
            username = settings.book_cloud_username,
            password = settings.book_cloud_password,
        }
        if server.type == "webdav" and (not server.address or not server.username or not server.password) then
            return M.get_metadata_server()
        end
        if server.type == "dropbox" and not server.password then
            return M.get_metadata_server()
        end
        return server
    end
    
    return M.get_metadata_server()
end

function M.get_metadata_server()
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

-- Returns the document extension as KOReader sees it, preserving compound
-- extensions such as ".fb2.zip". getProviders() matches the full registered
-- suffix, so its top provider's extension is "fb2.zip" rather than the bare
-- "zip" (which is only a low-priority generic fallback). This keeps the
-- uploaded cloud filename openable as the right format in the title /
-- title_author naming modes. Falls back to the last dotted component for
-- anything KOReader doesn't recognize.
local function get_file_extension(file_path)
    local providers = DocumentRegistry:getProviders(file_path)
    if providers and providers[1] and providers[1].extension then
        return "." .. providers[1].extension
    end
    local ext = file_path:match("%.([^%.]+)$")
    return ext and ("." .. ext) or ""
end

-- Removes the extension (as understood by get_file_extension) from a filename,
-- keeping compound extensions intact so the stem and the extension never
-- overlap. Using a plain `gsub("%.[^%.]+$", "")` here would only drop the last
-- component, turning "book.fb2.zip" into the stem "book.fb2" which, recombined
-- with the compound ext ".fb2.zip", would yield "book.fb2.fb2.zip".
local function strip_extension(filename)
    local ext = get_file_extension(filename)
    if #ext > 0 and filename:sub(-#ext):lower() == ext:lower() then
        return filename:sub(1, #filename - #ext)
    end
    return filename
end

-- A file is a syncable book if KOReader has a document provider for it.
-- We use the same test KOReader's own FileManager uses to decide what to show
-- (hasProvider), instead of a hand-maintained extension allowlist. This
-- automatically covers every format the reader can open and stays in sync with
-- it. We then drop the two provider-backed file kinds that are clearly not
-- books: plain images (covers etc.) and the executable scripts (.sh/.py) that
-- CRE registers only for in-FileManager execution.
local function is_supported_book(file_path)
    return DocumentRegistry:hasProvider(file_path)
        and not DocumentRegistry:isImageFile(file_path)
        and util.getScriptType(file_path) == nil
end

local function get_cloud_path(server, cloud_filename)
    local api = get_api(server)
    if not api then
        return nil
    end
    
    if server.type == "dropbox" then
        local url_base = server.url:sub(-1) == "/" and server.url or server.url .. "/"
        return url_base .. cloud_filename
    else
        local path = api:getJoinedPath(server.address, server.url)
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
        title = strip_extension(original_filename)
    end
    return sanitize_filename(title) .. ext
end

function M.write_batch_book_log(results, action)
    local timestamp = os.date("%Y-%m-%d %H:%M:%S")
    local log_path = utils.get_log_path()
    
    local device_name = utils.get_device_name()
    local device_id = utils.get_device_id()
    
    local action_text = ""
    if action == "upload" then
        action_text = _("Book sync") .. "-" .. _("Batch upload")
    elseif action == "download" then
        action_text = _("Book sync") .. "-" .. _("Batch download")
    else
        action_text = _("Book sync") .. "-" .. _("Batch delete")
    end
    
    local new_record = {}
    table.insert(new_record, utils.SEPARATOR_LINE)
    table.insert(new_record, string.format(_("Sync time: %s"), timestamp))
    table.insert(new_record, string.format(_("Device: %s"), device_name))
    table.insert(new_record, string.format(_("Device ID: %s"), device_id))
    table.insert(new_record, string.format(_("Operation type: %s"), action_text))
    table.insert(new_record, utils.SEPARATOR_LINE)
    
    table.insert(new_record, string.format(_("[Success] (%d books)"), #(results.success or {})))
    table.insert(new_record, string.rep("-", 40))
    if #(results.success or {}) > 0 then
        for _, book in ipairs(results.success) do
            table.insert(new_record, string.format("  ✓ %s", book.name))
        end
    else
        table.insert(new_record, _("  None"))
    end
    table.insert(new_record, "")
    
    if results.skipped and #results.skipped > 0 then
        table.insert(new_record, string.format(_("[Skipped] (%d books)"), #results.skipped))
        table.insert(new_record, string.rep("-", 40))
        for _, book in ipairs(results.skipped) do
            table.insert(new_record, string.format("  ○ %s (%s)", book.name, book.reason))
        end
        table.insert(new_record, "")
    end
    
    table.insert(new_record, string.format(_("[Failed] (%d books)"), #(results.failed or {})))
    table.insert(new_record, string.rep("-", 40))
    if #(results.failed or {}) > 0 then
        local failed_by_reason = {}
        for _, book in ipairs(results.failed) do
            local key = book.reason or _("Unknown error")
            if not failed_by_reason[key] then
                failed_by_reason[key] = { books = {} }
            end
            table.insert(failed_by_reason[key].books, { name = book.name })
        end
        local reason_index = 0
        for reason, info in pairs(failed_by_reason) do
            reason_index = reason_index + 1
            table.insert(new_record, string.format("\n" .. _("[Failure reason %d] %s"), reason_index, reason))
            table.insert(new_record, string.rep("~", 40))
            for i, book in ipairs(info.books) do
                table.insert(new_record, string.format("  (%d) %s", i, book.name))
            end
        end
    else
        table.insert(new_record, _("  None"))
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

local function show_notification(msg, timeout)
    UIManager:show(Notification:new{
        text = msg,
        timeout = timeout or 2
    })
end

function M.upload_book(book_path, show_msg, naming_mode, book_info)
    show_msg = (show_msg == nil) or show_msg
    
    if lfs.attributes(book_path, "mode") ~= "file" then
        if show_msg then show_notification(_("Book file does not exist"), 2) end
        return false, "file_not_found"
    end
    
    if not is_supported_book(book_path) then
        if show_msg then show_notification(_("Unsupported file format"), 2) end
        return false, "unsupported_format"
    end
    
    local server = get_book_server()
    if not server then
        if show_msg then show_notification(_("Cloud storage service not configured"), 2) end
        return false, "no_server_config"
    end
    
    if not NetworkMgr:isOnline() then
        if show_msg then show_notification(_("Device not connected to network"), 2) end
        return false, "no_network"
    end
    
    local api = get_api(server)
    if not api then
        if show_msg then show_notification(_("Unsupported cloud storage type"), 2) end
        return false, "unsupported_server"
    end
    
    local cloud_filename = M.get_cloud_filename_for_path({
        file_path = book_path,
        title = book_info.title,
        author = book_info.author,
    }, naming_mode)
    local cloud_path = get_cloud_path(server, cloud_filename)
    
    if not cloud_path then
        if show_msg then show_notification(_("Cannot build cloud path"), 2) end
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
    
    if type(code) == "number" and code >= 200 and code < 300 then
        return true, "success"
    elseif type(code) == "number" and code == 401 then
        if show_msg then show_notification(_("Cloud storage authentication failed, please reconfigure"), 3) end
        return false, "auth_failed"
    else
        if show_msg then
            show_notification(string.format(_("Upload failed (HTTP %s)"), tostring(code)), 3)
        end
        return false, "upload_failed"
    end
end

function M.download_book(cloud_filename, target_dir, show_msg, progress_callback)
    show_msg = (show_msg == nil) or show_msg
    
    local settings = G_reader_settings:readSetting("cloud_library_plugin", {})
    local download_dir = target_dir or settings.book_download_dir
    if not download_dir or download_dir == "" then
        if show_msg then show_notification(_("Please set book download directory in settings first"), 3) end
        return false, "no_download_dir"
    end
    
    if lfs.attributes(download_dir, "mode") ~= "directory" then
        pcall(function()
            os.execute("mkdir -p " .. download_dir)
        end)
        if lfs.attributes(download_dir, "mode") ~= "directory" then
            if show_msg then show_notification(_("Cannot create download directory"), 2) end
            return false, "cannot_create_dir"
        end
    end
    
    local local_path = download_dir .. "/" .. cloud_filename
    
    if lfs.attributes(local_path, "mode") == "file" then
        return false, "file_exists"
    end
    
    local server = get_book_server()
    if not server then
        if show_msg then show_notification(_("Cloud storage service not configured"), 2) end
        return false, "no_server_config"
    end
    
    if not NetworkMgr:isOnline() then
        if show_msg then show_notification(_("Device not connected to network"), 2) end
        return false, "no_network"
    end
    
    local api = get_api(server)
    if not api then
        if show_msg then show_notification(_("Unsupported cloud storage type"), 2) end
        return false, "unsupported_server"
    end
    
    local cloud_path = get_cloud_path(server, cloud_filename)
    
    if not cloud_path then
        if show_msg then show_notification(_("Cannot build cloud path"), 2) end
        return false, "path_error"
    end
    
    if show_msg then
        show_notification(string.format(_("Downloading: %s"), cloud_filename), 2)
    end
    
    local code
    if server.type == "dropbox" then
        local token = server.password
        if server.address and server.address ~= "" then
            token = api:getAccessToken(server.password, server.address)
        end
        code = api:downloadFile(cloud_path, token, local_path, progress_callback)
    else
        code = api:downloadFile(cloud_path, server.username, server.password, local_path, progress_callback)
    end
    
    if type(code) == "number" and code == 200 then
        if show_msg then
            show_notification(string.format(_("✓ Download successful: %s"), cloud_filename), 2)
        end
        return true, "success", local_path
    elseif type(code) == "number" and code == 404 then
        if show_msg then show_notification(_("Cloud file does not exist"), 2) end
        return false, "file_not_found"
    elseif type(code) == "number" and code == 401 then
        if show_msg then show_notification(_("Cloud storage authentication failed"), 2) end
        return false, "auth_failed"
    else
        if show_msg then
            show_notification(string.format(_("Download failed (HTTP %s)"), tostring(code)), 3)
        end
        return false, "download_failed"
    end
end

function M.delete_cloud_book(cloud_filename, show_msg)
    show_msg = (show_msg == nil) or show_msg
    
    local server = get_book_server()
    if not server then
        if show_msg then show_notification(_("Cloud storage service not configured"), 2) end
        return false, "no_server_config"
    end
    
    if not NetworkMgr:isOnline() then
        if show_msg then show_notification(_("Device not connected to network"), 2) end
        return false, "no_network"
    end
    
    local cloud_path = get_cloud_path(server, cloud_filename)
    
    if not cloud_path then
        if show_msg then show_notification(_("Cannot build cloud path"), 2) end
        return false, "path_error"
    end
    
    local code
    if server.type == "dropbox" then
        local http = require("socket.http")
        local ltn12 = require("ltn12")
        local json = require("json")
        
        local token = server.password
        if server.address and server.address ~= "" then
            local api = get_api(server)
            if api then
                local new_token = api:getAccessToken(server.password, server.address)
                if new_token then
                    token = new_token
                end
            end
        end
        
        local data = json.encode({ path = cloud_path })
        local headers = {
            ["Authorization"] = "Bearer " .. token,
            ["Content-Type"] = "application/json",
            ["Content-Length"] = tostring(#data),
        }
        
        local response, status_code = http.request{
            url = "https://api.dropboxapi.com/2/files/delete_v2",
            method = "POST",
            headers = headers,
            source = ltn12.source.string(data),
        }
        
        code = status_code or 500
        
    elseif server.type == "webdav" then
        local http = require("socket.http")
        local sha2 = require("ffi/sha2")
        local headers = {
            ["User-Agent"] = "KOReader-CloudLibrary",
            ["Authorization"] = "Basic " .. sha2.bin_to_base64(server.username .. ":" .. server.password),
        }
        
        local response, status_code = http.request{
            url = cloud_path,
            method = "DELETE",
            headers = headers,
        }
        
        code = status_code or 500
    else
        if show_msg then show_notification(_("Unsupported cloud storage type"), 2) end
        return false, "unsupported_server"
    end
    
    if type(code) == "number" and code >= 200 and code < 300 then
        if show_msg then
            show_notification(string.format(_("✓ Delete successful: %s"), cloud_filename), 2)
        end
        return true, "success"
    elseif type(code) == "number" and code == 404 then
        if show_msg then show_notification(_("Cloud file does not exist"), 2) end
        return false, "file_not_found"
    elseif type(code) == "number" and code == 401 then
        if show_msg then show_notification(_("Cloud storage authentication failed, please reconfigure"), 3) end
        return false, "auth_failed"
    else
        if show_msg then
            show_notification(string.format(_("Delete failed (HTTP %s)"), tostring(code)), 3)
        end
        return false, "delete_failed"
    end
end

function M.batch_delete_books(book_names, settings)
    local results = {
        success = {},
        failed = {}
    }
    
    local total = #book_names
    local completed = 0
    local index = 1
    
    local ProgressbarDialog = require("ui/widget/progressbardialog")
    local blitbuffer = require("ffi/blitbuffer")
    local progress_dialog = ProgressbarDialog:new{
        title = _("Deleting books..."),
        subtitle = string.format("%d book(s)", total),
        progress = 0,
        progress_max = total,
        refresh_time_seconds = 0.1
    }
    if progress_dialog.progress_bar then
        progress_dialog.progress_bar.fillcolor = blitbuffer.COLOR_BLACK
    end
    progress_dialog:show()
    
    
    local function delete_next()
        if index > total then
            progress_dialog:close()
            M.write_batch_book_log(results, "delete")
            
            if settings then
                settings.last_sync = os.date("%Y-%m-%d %H:%M:%S") .. " (" .. _("Book sync") .. "-" .. _("Batch delete") .. ")"
                G_reader_settings:saveSetting("cloud_library_plugin", settings)
            end
            
            local msg = string.format(_("Delete completed: %d success, %d failed"), #results.success, #results.failed)
            show_notification(msg, 3)
            
            if #results.failed > 0 then
                UIManager:scheduleIn(0.5, function()
                    local fail_msg = M.formatFailureDetails(results.failed)
                    local TextViewer = require("ui/widget/textviewer")
                    UIManager:show(TextViewer:new{
                        title = _("Delete failed details"),
                        text = fail_msg,
                    })
                end)
            end
            return
        end
        
        local filename = book_names[index]
        index = index + 1
        
        UIManager:scheduleIn(0, function()
            local success, error_msg = M.delete_cloud_book(filename, false)
            
            if success then
                table.insert(results.success, { name = filename })
            else
                table.insert(results.failed, { name = filename, reason = error_msg })
            end
            
            completed = completed + 1
            progress_dialog:reportProgress(completed)
            UIManager:setDirty(progress_dialog, "ui")
            delete_next()
        end)
    end
    
    delete_next()
end

function M.get_cloud_book_list()
    local server = get_book_server()
    if not server then
        return nil, _("Cloud storage service not configured")
    end
    
    local book_dir = server.url
    if not book_dir or book_dir == "" then
        return nil, _("Cloud directory not set")
    end
    
    local api = get_api(server)
    if not api then
        return nil, _("Unsupported cloud storage type")
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
            return nil, _("Dropbox API does not support listing folders")
        end
    elseif server.type == "webdav" then
        if api.listFolder then
            items = api:listFolder(server.address, server.username, server.password, book_dir, false)
        else
            return nil, _("WebDAV API does not support listing folders")
        end
    else
        return nil, _("Unsupported cloud storage type")
    end
    
    if not items or type(items) ~= "table" then
        return nil, _("Cannot get cloud file list")
    end
    
    local books = {}
    for _, item in ipairs(items) do
        if item.type == "file" then
            local filename = item.text
            if filename and is_supported_book(filename) then
                table.insert(books, {
                    name = filename,
                    path = item.url,
                    size = item.filesize or 0,
                })
            end
        end
    end
    
    return books, nil
end

function M.show_cloud_book_dialog(callback, plugin)
    local NetworkMgr = require("ui/network/manager")
    if not NetworkMgr:isOnline() then
        show_notification(_("No network connection, cannot get cloud book list"), 3)
        return
    end
    
    local remote = dofile(_plugin_dir .. "remote.lua")
    local server = remote.get_server()
    if not server then
        show_notification(_("Cloud storage service not configured, please configure in settings first"), 3)
        return
    end
    
    if not server.url or server.url == "" then
        show_notification(_("Cloud directory not set, please configure in cloud directory settings"), 3)
        return
    end
    
    local api = remote.get_api(server)
    if not api then
        show_notification(_("Unsupported cloud storage type, please use WebDAV or Dropbox"), 3)
        return
    end

    local books, err = M.get_cloud_book_list()
    if not books or #books == 0 then
        show_notification(err or _("No books found in cloud"), 3)
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
                    text = string.format(_("Search: \"%s\" (%d books found)"), search_keyword, #books),
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
                    text = _("No books found"),
                    enabled = false,
                    alignment = "center",
                }
            })
        end
        
        table.insert(buttons, {})
        
        local nav_buttons = {}
        if current_page > 1 then
            table.insert(nav_buttons, {
                text = _("◀ Previous Page"),
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
            text = string.format(_("Page %d/%d (%d books)"), current_page, total_pages, #books),
            enabled = false,
        })
        if current_page < total_pages then
            table.insert(nav_buttons, {
                text = _("Next Page ▶"),
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
                text = _("Select All"),
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
                text = _("Deselect All"),
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
                text = _("Search"),
                callback = function()
                    show_search_dialog()
                end
            },
        })
        
        table.insert(buttons, {
            {
                text = search_keyword ~= "" and _("Clear Search") or "",
                enabled = search_keyword ~= "",
                callback = function()
                    clear_search()
                end
            },
            {
                text = string.format(_("Delete (%d)"), selected_count),
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
                            text = string.format(_("Are you sure you want to delete %d book(s) from the cloud?\nThis action cannot be undone!"), #selected_names),
                            ok_text = _("Delete"),
                            cancel_text = _("Cancel"),
                            ok_callback = function()
                                local settings = G_reader_settings:readSetting("cloud_library_plugin", {})
                                M.batch_delete_books(selected_names, settings)
                            end
                        })
                    else
                        show_notification(_("No books selected"), 2)
                    end
                end
            },
{
    text = string.format(_("Download (%d)"), selected_count),
    callback = function()
        local picked_books = {}
        for _, book in ipairs(original_books) do
            if selected[book.name] then
                table.insert(picked_books, book)
            end
        end
        if dialog then
            UIManager:close(dialog)
        end
        if #picked_books > 0 then
            callback(picked_books)
        else
            show_notification(_("No books selected"), 2)
        end
    end
},
            {
                text = _("Cancel"),
                callback = function()
                    if dialog then
                        UIManager:close(dialog)
                    end
                end
            },
        })
        
        dialog = ButtonDialog:new{
            title = string.format(_("Select books to download/delete (%d selected)"), selected_count),
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
            title = _("Search books"),
            input = search_keyword,
            input_hint = _("Enter book title keyword"),
            buttons = {
                {
                    {
                        text = _("Cancel"),
                        id = "close",
                        callback = function()
                            UIManager:close(search_dialog)
                        end,
                    },
                    {
                        text = _("Search"),
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
    local results = {
        success = {},
        failed = {}
    }
    
    local total = #selected_books
    local completed = 0
    local index = 1
    
    local ProgressbarDialog = require("ui/widget/progressbardialog")
    local blitbuffer = require("ffi/blitbuffer")
    local progress_dialog = ProgressbarDialog:new{
        title = _("Uploading books..."),
        subtitle = string.format("%d book(s)", total),
        progress = 0,
        progress_max = total,
        refresh_time_seconds = 0.1
    }
    if progress_dialog.progress_bar then
        progress_dialog.progress_bar.fillcolor = blitbuffer.COLOR_BLACK
    end
    progress_dialog:show()
   
    
    local function upload_next()
        if index > total then
            progress_dialog:close()
            M.write_batch_book_log(results, "upload")
            settings.last_sync = os.date("%Y-%m-%d %H:%M:%S") .. " (" .. _("Book sync") .. "-" .. _("Batch upload") .. ")"
            G_reader_settings:saveSetting(plugin.plugin_id, settings)
            
            local msg = string.format(_("Upload completed: %d success, %d failed"), #results.success, #results.failed)
            UIManager:show(Notification:new{ text = msg, timeout = 2 })
            
            if #results.failed > 0 then
                UIManager:scheduleIn(0.5, function()
                    local fail_msg = M.formatFailureDetails(results.failed)
                    local TextViewer = require("ui/widget/textviewer")
                    UIManager:show(TextViewer:new{
                        title = _("Upload failed details"),
                        text = fail_msg,
                    })
                end)
            end
            
            M.cleanupFileManagerSelection()
            return
        end
        
        local book_info = selected_books[index]
        index = index + 1
        
        local path = book_info.path or book_info.file_path
        local local_name = path:match("([^/]+)$") or _("Unknown")
        local cloud_name = M.get_cloud_filename_for_path({
            file_path = path,
            title = book_info.title,
            author = book_info.author,
        }, naming_mode)
        
        UIManager:scheduleIn(0, function()
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
            
            completed = completed + 1
            progress_dialog:reportProgress(completed)
            UIManager:setDirty(progress_dialog, "ui")
            upload_next()
        end)
    end
    
    upload_next()
end

function M.batchDownloadBooks(books, settings, plugin)
    local download_dir = settings.book_download_dir
    local results = {
        success = {},
        failed = {},
        skipped = {}
    }
    
    if not download_dir or download_dir == "" then
        table.insert(results.failed, {
            name = _("All books"),
            reason = _("Download directory not set")
        })
        M.write_batch_book_log(results, "download")
        show_notification(_("Download completed: 0 success, 1 failed, 0 skipped"), 3)
        return
    end
    
    local total_bytes = 0
    for _, book in ipairs(books) do
        total_bytes = total_bytes + (tonumber(book.size) or 0)
    end
    
    local index = 1
    local total_downloaded = 0
    
    local ProgressbarDialog = require("ui/widget/progressbardialog")
    local blitbuffer = require("ffi/blitbuffer")
    local progress_dialog = ProgressbarDialog:new{
        title = _("Downloading books..."),
        subtitle = string.format("%d book(s)", #books),
        progress = 0,
        progress_max = total_bytes,
        refresh_time_seconds = 0.1
    }
    if progress_dialog.progress_bar then
        progress_dialog.progress_bar.fillcolor = blitbuffer.COLOR_BLACK
    end
    progress_dialog:show()
    
    local function download_next()
        if index > #books then
            progress_dialog:close()
            M.write_batch_book_log(results, "download")
            settings.last_sync = os.date("%Y-%m-%d %H:%M:%S") .. " (" .. _("Book sync") .. "-" .. _("Batch download") .. ")"
            G_reader_settings:saveSetting(plugin.plugin_id, settings)
            
            local msg = string.format(_("Download completed: %d success, %d failed, %d skipped"), 
                #results.success, #results.failed, #results.skipped)
            show_notification(msg, 3)
            
            if #results.failed > 0 then
                UIManager:scheduleIn(0.5, function()
                    local fail_msg = M.formatFailureDetails(results.failed)
                    local TextViewer = require("ui/widget/textviewer")
                    UIManager:show(TextViewer:new{
                        title = _("Download failed details"),
                        text = fail_msg,
                    })
                end)
            end
            
            M.refreshFileManager()
            return
        end
        
        local book = books[index]
        local filename = book.name
        local file_size = tonumber(book.size) or 0
        local local_path = download_dir .. "/" .. filename
        
        if lfs.attributes(local_path, "mode") == "file" then
            table.insert(results.skipped, {
                name = filename,
                reason = _("Local file with same name already exists")
            })
            total_downloaded = total_downloaded + file_size
            progress_dialog:reportProgress(total_downloaded)
            UIManager:setDirty(progress_dialog, "ui")
            index = index + 1
            UIManager:scheduleIn(0, download_next)
            return
        end
        
        local this_book_downloaded = 0
        local progress_callback = function(byte_count)
            byte_count = tonumber(byte_count) or 0
            local delta = byte_count - this_book_downloaded
            if delta > 0 then
                this_book_downloaded = byte_count
                total_downloaded = total_downloaded + delta
                progress_dialog:reportProgress(total_downloaded)
                UIManager:setDirty(progress_dialog, "ui")
            end
        end
        
        local success, error_msg, _ = M.download_book(filename, nil, false, progress_callback)
        
        if success then
            table.insert(results.success, {
                name = filename,
                path = local_path
            })
        elseif error_msg == "file_exists" then
            table.insert(results.skipped, {
                name = filename,
                reason = _("Local file with same name already exists")
            })
        else
            table.insert(results.failed, {
                name = filename,
                reason = error_msg
            })
        end
        
        local remaining = file_size - this_book_downloaded
        if remaining > 0 then
            total_downloaded = total_downloaded + remaining
        end
        progress_dialog:reportProgress(total_downloaded)
        UIManager:setDirty(progress_dialog, "ui")
        index = index + 1
        UIManager:scheduleIn(0, download_next)
    end
    
    download_next()
end

function M.refreshFileManager()
    local FileManager = require("apps/filemanager/filemanager")
    local fm = FileManager.instance
    if fm and fm.file_chooser then
        fm.file_chooser:refreshPath()
    end
end

function M.formatFailureDetails(failed_list)
    local fail_msg = _("Failure details:\n\n")
    
    local failed_by_reason = {}
    for _, fail in ipairs(failed_list) do
        local reason = fail.reason or _("Unknown error")
        if not failed_by_reason[reason] then
            failed_by_reason[reason] = {}
        end
        table.insert(failed_by_reason[reason], fail)
    end
    
    local reason_index = 0
    for reason, books in pairs(failed_by_reason) do
        reason_index = reason_index + 1
        fail_msg = fail_msg .. string.format(_("[Failure reason %d] %s\n"), reason_index, reason)
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
    local skip_msg = _("Skipped details:\n\n")
    skip_msg = skip_msg .. string.format(_("%d book(s) were skipped because local files with the same name already exist:\n\n"), #skipped_list)
    
    for i, book in ipairs(skipped_list) do
        skip_msg = skip_msg .. string.format("  %d. %s\n", i, book.name)
    end
    
    skip_msg = skip_msg .. _("\nHint: To re-download, please delete or rename the local files first")
    
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
    local NetworkMgr = require("ui/network/manager")
    if not NetworkMgr:isOnline() then
        UIManager:show(Notification:new{
            text = _("No network connection, cannot upload"),
            timeout = 3
        })
        return
    end
    
    local remote = dofile(_plugin_dir .. "remote.lua")
    local server = remote.get_server()
    if not server then
        UIManager:show(Notification:new{
            text = _("Cloud storage service not configured, please configure in settings first"),
            timeout = 3
        })
        return
    end
    
    if not server.url or server.url == "" then
        UIManager:show(Notification:new{
            text = _("Cloud directory not set, please configure in cloud directory settings"),
            timeout = 3
        })
        return
    end
    
    local api = remote.get_api(server)
    if not api then
        UIManager:show(Notification:new{
            text = _("Unsupported cloud storage type, please use WebDAV or Dropbox"),
            timeout = 3
        })
        return
    end

    local ui = plugin.ui
    local action_text = _("upload")
    local button_text = _("Batch upload selected books")
    
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
            text = string.format(_("Please select books to %s, then tap \"%s\""), action_text, button_text),
            timeout = 5
        })
        return
    end
    
    local FileManager = require("apps/filemanager/filemanager")
    local fm = FileManager.instance
    
    if not fm then
        UIManager:show(Notification:new{
            text = _("Unable to get file manager instance"),
            timeout = 3
        })
        return
    end
    
    if fm.selected_files == nil then
        fm:onToggleSelectMode(true)
        UIManager:show(Notification:new{
            text = string.format(_("Please select books to %s, then tap \"%s\""), action_text, button_text),
            timeout = 5
        })
        return
    end
    
    local selected_files = fm.selected_files
    if not selected_files or next(selected_files) == nil then
        UIManager:show(Notification:new{
            text = string.format(_("Please select books to %s, then tap \"%s\""), action_text, button_text),
            timeout = 5
        })
        return
    end
    
    local books = {}
    for file, selected in pairs(selected_files) do
        if selected and lfs.attributes(file, "mode") == "file" then
            if is_supported_book(file) then
                local filename = file:match("([^/]+)$") or _("Unknown")
                local basename = strip_extension(filename)

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
            text = _("No valid book files selected"),
            timeout = 3
        })
        return
    end
    
    local naming_mode = plugin.settings.book_naming_mode or "title"
    
    UIManager:show(ConfirmBox:new{
        text = string.format(_("Upload %d book(s) to cloud"), #books),
        ok_text = _("Continue"),
        cancel_text = _("Cancel"),
        ok_callback = function()
            M.batchUploadBooks(books, naming_mode, plugin.settings, plugin)
        end
    })
end

return M