-- update.lua
-- 插件在线更新模块

-- Get plugin directory (same as other files)
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
local ConfirmBox = require("ui/widget/confirmbox")
local InfoMessage = require("ui/widget/infomessage")
local NetworkMgr = require("ui/network/manager")
local DataStorage = require("datastorage")
local lfs = require("libs/libkoreader-lfs")
local gettext = require("gettext")

local M = {}

local REPO_OWNER = "gytwo"
local REPO_NAME = "cloudlibrary.koplugin"
local MANUAL_ZIP_NAME = "cloudlibrary.koplugin.zip"

local Device = require("device")
local is_android = Device:isAndroid()

-- 定义更新源（三种选项）
local SOURCES = {
    github_latest = {
        name = "GitHub (Latest)",
        api_url = "https://api.github.com/repos/%s/%s/releases/latest",
        list_url = "https://api.github.com/repos/%s/%s/releases",
        type = "github",
        prerelease = false,
    },
    github_prerelease = {
        name = "GitHub (Pre-release)",
        api_url = "https://api.github.com/repos/%s/%s/releases",
        list_url = "https://api.github.com/repos/%s/%s/releases",
        type = "github",
        prerelease = true,
    },
    gitee_latest = {
        name = "Gitee (Latest)",
        api_url = "https://gitee.com/api/v5/repos/%s/%s/releases/latest",
        list_url = "https://gitee.com/api/v5/repos/%s/%s/releases",
        type = "gitee",
        prerelease = false,
    },
}

-- 当前使用的源（临时，用于本次更新操作）
local current_source = nil

-- 保存用户选择的更新源到设置
local function save_selected_source(source_key)
    G_reader_settings:saveSetting("cloudlibrary_update_source", source_key)
end

-- 获取用户保存的更新源key
local function get_saved_source_key()
    local saved = G_reader_settings:readSetting("cloudlibrary_update_source")
    if saved == "github_prerelease" then
        return "github_prerelease"
    elseif saved == "gitee_latest" then
        return "gitee_latest"
    else
        return "github_latest"  -- 默认
    end
end

-- 根据key获取source对象
local function get_source_by_key(key)
    if key == "github_prerelease" then
        return SOURCES.github_prerelease
    elseif key == "gitee_latest" then
        return SOURCES.gitee_latest
    else
        return SOURCES.github_latest
    end
end

local function get_current_version()
    local meta_path = _plugin_dir .. "_meta.lua"
    local f = io.open(meta_path, "r")
    if not f then
        return "v1.0"
    end
    local content = f:read("*all")
    f:close()
    local version = content:match('version%s*=%s*"([^"]+)"')
    if not version then
        version = content:match("version%s*=%s*'([^']+)'")
    end
    return version or "v1.0"
end

-- HTTP 请求（带超时）
local function request_url(url, timeout)
    timeout = timeout or 10
    logger.info("CloudLibrary: 请求 URL: " .. url)
    
    local http = require("socket.http")
    local ltn12 = require("ltn12")
    
    local response = {}
    local ok, err = pcall(function()
        return http.request{
            url = url,
            sink = ltn12.sink.table(response),
            headers = {
                ["User-Agent"] = "KOReader-CloudLibrary",
                ["Accept"] = "application/json",
            },
            timeout = timeout,
        }
    end)
    
    if not ok then
        logger.warn("CloudLibrary: HTTP 请求异常: " .. tostring(err))
        return nil
    end
    if not response or #response == 0 then
        logger.warn("CloudLibrary: 响应为空")
        return nil
    end
    
    local response_str = table.concat(response)
    local json = require("json")
    local success, data = pcall(json.decode, response_str)
    if not success or not data then
        logger.warn("CloudLibrary: JSON 解析失败")
        return nil
    end
    return data
end

-- 获取最新版本信息（从 GitHub，支持 prerelease）
local function get_latest_from_github(source)
    local url = string.format(source.api_url, REPO_OWNER, REPO_NAME)
    
    if source.prerelease then
        -- Pre-release 模式：获取所有 releases，然后筛选
        local data = request_url(url, 15)
        if not data or #data == 0 then
            return nil, nil, nil, gettext("Failed to get version information")
        end
        
        -- 查找最新的 prerelease（按创建时间排序）
        local latest_prerelease = nil
        for _, release in ipairs(data) do
            if release.prerelease == true then
                if not latest_prerelease then
                    latest_prerelease = release
                else
                    -- 比较创建时间
                    local current_time = os.time()
                    local release_time = os.time({
                        year = tonumber(release.created_at:sub(1,4)),
                        month = tonumber(release.created_at:sub(6,7)),
                        day = tonumber(release.created_at:sub(9,10)),
                        hour = tonumber(release.created_at:sub(12,13)) or 0,
                        min = tonumber(release.created_at:sub(15,16)) or 0,
                        sec = tonumber(release.created_at:sub(18,19)) or 0,
                    })
                    local latest_time = os.time({
                        year = tonumber(latest_prerelease.created_at:sub(1,4)),
                        month = tonumber(latest_prerelease.created_at:sub(6,7)),
                        day = tonumber(latest_prerelease.created_at:sub(9,10)),
                        hour = tonumber(latest_prerelease.created_at:sub(12,13)) or 0,
                        min = tonumber(latest_prerelease.created_at:sub(15,16)) or 0,
                        sec = tonumber(latest_prerelease.created_at:sub(18,19)) or 0,
                    })
                    if release_time > latest_time then
                        latest_prerelease = release
                    end
                end
            end
        end
        
        if not latest_prerelease then
            return nil, nil, nil, gettext("No pre-release found")
        end
        
        return M._parse_release_data(latest_prerelease, source)
    else
        -- Latest 模式：直接获取 latest release
        local data = request_url(url, 15)
        if not data or not data.tag_name then
            return nil, nil, nil, gettext("Failed to get version information")
        end
        return M._parse_release_data(data, source)
    end
end

-- 获取最新版本信息（从 Gitee）
local function get_latest_from_gitee(source)
    local url = string.format(source.api_url, REPO_OWNER, REPO_NAME)
    local data = request_url(url, 15)
    
    if not data or not data.tag_name then
        return nil, nil, nil, gettext("Failed to get version information")
    end
    
    return M._parse_release_data(data, source)
end

-- 解析 release 数据，提取下载地址
function M._parse_release_data(data, source)
    local tag_name = data.tag_name or data.name
    logger.info("CloudLibrary: 最新版本: " .. tag_name .. " (来源: " .. source.name .. ")")
    
    -- 获取下载地址
    local zip_url = nil
    if data.assets then
        for _, asset in ipairs(data.assets) do
            if asset.name == MANUAL_ZIP_NAME then
                zip_url = asset.browser_download_url
                logger.info("CloudLibrary: 使用手动上传的 ZIP 包")
                break
            end
        end
    end
    if not zip_url and data.zipball_url then
        zip_url = data.zipball_url
        logger.info("CloudLibrary: 使用自动生成的源码包")
    end
    
    return tag_name, zip_url, source.name, data.body
end

-- 获取最新版本信息（根据源类型）
local function get_latest_version_from_source(source)
    if source.type == "github" then
        return get_latest_from_github(source)
    else
        return get_latest_from_gitee(source)
    end
end

-- 获取版本列表（用于回退）
local function get_all_versions_from_source(source)
    local all_versions = {}
    local page = 1
    
    local url_template = source.list_url
    local url = string.format(url_template, REPO_OWNER, REPO_NAME)
    
    if source.type == "github" and source.prerelease then
        -- GitHub Pre-release 模式：获取所有 releases，只显示 prerelease
        local data = request_url(url .. "?per_page=100", 15)
        if not data or #data == 0 then
            return {}
        end
        
        for _, release in ipairs(data) do
            if release.prerelease == true then
                local tag_name = release.tag_name or release.name
                if tag_name then
                    local zip_url = nil
                    if release.assets then
                        for _, asset in ipairs(release.assets) do
                            if asset.name == MANUAL_ZIP_NAME then
                                zip_url = asset.browser_download_url
                                break
                            end
                        end
                    end
                    table.insert(all_versions, {
                        tag = tag_name,
                        url = zip_url,
                        body = release.body,
                        source = source.name,
                    })
                end
            end
        end
    elseif source.type == "github" then
        -- GitHub Latest 模式：获取所有 releases（不包含 prerelease？GitHub API 默认返回所有）
        local data = request_url(url .. "?per_page=100", 15)
        if not data or #data == 0 then
            return {}
        end
        
        for _, release in ipairs(data) do
            -- 可以选择是否排除 prerelease，这里排除让列表更干净
            if release.prerelease ~= true then
                local tag_name = release.tag_name or release.name
                if tag_name then
                    local zip_url = nil
                    if release.assets then
                        for _, asset in ipairs(release.assets) do
                            if asset.name == MANUAL_ZIP_NAME then
                                zip_url = asset.browser_download_url
                                break
                            end
                        end
                    end
                    table.insert(all_versions, {
                        tag = tag_name,
                        url = zip_url,
                        body = release.body,
                        source = source.name,
                    })
                end
            end
        end
    else
        -- Gitee：分页获取
        while true do
            local paged_url = url .. "?page=" .. tostring(page) .. "&per_page=100"
            local data = request_url(paged_url, 15)
            
            if not data or #data == 0 then
                break
            end
            
            for _, release in ipairs(data) do
                local tag_name = release.tag_name or release.name
                if tag_name then
                    local zip_url = nil
                    if release.assets then
                        for _, asset in ipairs(release.assets) do
                            if asset.name == MANUAL_ZIP_NAME then
                                zip_url = asset.browser_download_url
                                break
                            end
                        end
                    end
                    table.insert(all_versions, {
                        tag = tag_name,
                        url = zip_url,
                        body = release.body,
                        source = source.name,
                    })
                end
            end
            
            if #data < 100 then
                break
            end
            page = page + 1
        end
    end
    
    return all_versions
end

function M.is_newer_version(current, latest)
    if current == latest then return false end
    
    local cur = current:gsub("^v", "")
    local lat = latest:gsub("^v", "")
    
    local cur_parts = {}
    for part in cur:gmatch("[^.]+") do
        table.insert(cur_parts, tonumber(part) or 0)
    end
    local lat_parts = {}
    for part in lat:gmatch("[^.]+") do
        table.insert(lat_parts, tonumber(part) or 0)
    end
    
    for i = 1, math.max(#cur_parts, #lat_parts) do
        local cur_part = cur_parts[i] or 0
        local lat_part = lat_parts[i] or 0
        if lat_part > cur_part then
            return true
        elseif lat_part < cur_part then
            return false
        end
    end
    return false
end

-- 显示临时提示
local function show_msg(text, timeout)
    UIManager:show(Notification:new{
        text = text,
        timeout = timeout or 2,
    })
end

-- 下载更新
local function download_update(download_url)
    local zip_path
    if is_android then
        zip_path = _plugin_dir .. "cloudlibrary.koplugin.zip"
    else
        zip_path = "/tmp/cloudlibrary.koplugin.zip"
    end
    
    -- 方式1: curl
    local cmd = string.format("curl -L --max-time 15 -o '%s' '%s' 2>/dev/null", zip_path, download_url)
    local result = os.execute(cmd)
    
    -- 方式2: wget
    if result ~= 0 then
        cmd = string.format("wget --timeout=15 -O '%s' '%s' 2>/dev/null", zip_path, download_url)
        result = os.execute(cmd)
    end
    
    -- 方式3: busybox wget
    if result ~= 0 then
        cmd = string.format("busybox wget --timeout=15 -O '%s' '%s' 2>/dev/null", zip_path, download_url)
        result = os.execute(cmd)
    end
    
    if result ~= 0 then
        os.remove(zip_path)
        return nil, gettext("Download failed")
    end
    
    local size = lfs.attributes(zip_path, "size") or 0
    if size < 1000 then
        show_msg(gettext("Downloaded file is invalid"), 3)
        os.remove(zip_path)
        return nil, gettext("Downloaded file is invalid")
    end
    
    return zip_path
end

-- 安装更新
local function install_update(zip_path)
    local install_dir = _plugin_dir:sub(1, -2)
    
    if is_android then
        if lfs.attributes(install_dir, "mode") ~= "directory" then
            os.execute("mkdir -p " .. install_dir)
        end
        
        local result = os.execute(string.format("unzip -o -q '%s' -d '%s' 2>/dev/null", zip_path, install_dir))
        
        if result ~= 0 then
            result = os.execute(string.format("busybox unzip -o -q '%s' -d '%s' 2>/dev/null", zip_path, install_dir))
        end
        
        os.remove(zip_path)
        
        if result == 0 then
            logger.info("CloudLibrary: 自动安装成功")
            return true
        else
            logger.warn("CloudLibrary: 自动安装失败")
            return false
        end
    else
        local result = os.execute(string.format("unzip -o %s -d %s", zip_path, install_dir))
        
        if result ~= 0 then
            result = os.execute(string.format("/usr/bin/unzip -o %s -d %s", zip_path, install_dir))
        end
        
        os.remove(zip_path)
        
        if result == 0 then
            logger.info("CloudLibrary: 更新安装成功")
        else
            logger.warn("CloudLibrary: 更新安装失败")
        end
        
        return result == 0
    end
end

-- 版本选择对话框
local _version_dialog = nil

local function show_version_choice(versions, current_version, source)
    local buttons = {}
    
    for _, v in ipairs(versions) do
        local is_current = (v.tag == current_version)
        local display_text = v.tag
        if v.source then
            display_text = display_text .. " [" .. v.source .. "]"
        end
        local button_text = is_current and string.format(gettext("Current version: %s (re-download)"), display_text) or string.format(gettext("Downgrade to %s"), display_text)
        
        table.insert(buttons, {
            {
                text = button_text,
                callback = function()
                    if _version_dialog then
                        UIManager:close(_version_dialog)
                        _version_dialog = nil
                    end
                    M.perform_update(v.url, v.tag, source)
                end
            }
        })
    end
    
    table.insert(buttons, {})
    table.insert(buttons, {
        {
            text = gettext("Cancel"),
            callback = function()
                if _version_dialog then
                    UIManager:close(_version_dialog)
                    _version_dialog = nil
                end
            end
        }
    })
    
    local ButtonDialog = require("ui/widget/buttondialog")
    local Screen = Device.screen
    _version_dialog = ButtonDialog:new{
        title = gettext("Select version to download"),
        title_align = "center",
        buttons = buttons,
        width = math.floor(Screen:getWidth() * 0.7),
    }
    UIManager:show(_version_dialog)
end

-- 选择更新源的对话框
local function show_source_selection_dialog(on_selected)
    local ButtonDialog = require("ui/widget/buttondialog")
    local Screen = Device.screen
    
    local saved_key = get_saved_source_key()
    
    local dialog
    local buttons = {
        {
            {
                text = (saved_key == "github_latest" and "✓ " or "  ") .. gettext("GitHub (Latest)"),
                callback = function()
                    UIManager:close(dialog)
                    save_selected_source("github_latest")
                    if on_selected then on_selected(get_source_by_key("github_latest")) end
                end
            }
        },
        {
            {
                text = (saved_key == "github_prerelease" and "✓ " or "  ") .. gettext("GitHub (Pre-release)"),
                callback = function()
                    UIManager:close(dialog)
                    save_selected_source("github_prerelease")
                    if on_selected then on_selected(get_source_by_key("github_prerelease")) end
                end
            }
        },
        {
            {
                text = (saved_key == "gitee_latest" and "✓ " or "  ") .. gettext("Gitee (Latest)"),
                callback = function()
                    UIManager:close(dialog)
                    save_selected_source("gitee_latest")
                    if on_selected then on_selected(get_source_by_key("gitee_latest")) end
                end
            }
        },
        {},
        {
            {
                text = gettext("Cancel"),
                callback = function()
                    UIManager:close(dialog)
                end
            }
        },
    }
    
    dialog = ButtonDialog:new{
        title = gettext("Select update source"),
        title_align = "center",
        buttons = buttons,
        width = math.floor(Screen:getWidth() * 0.7),
    }
    UIManager:show(dialog)
end

-- 执行更新检查
local function do_check_updates(source)
    if not NetworkMgr:isOnline() then
        show_msg(gettext("No network connection, cannot check for updates"), 2)
        return
    end
    
    show_msg(gettext("Checking for updates..."), 1)
    
    UIManager:scheduleIn(0.5, function()
        local latest_version, download_url, source_used, err = get_latest_version_from_source(source)
        
        if not latest_version then
            show_msg(err or gettext("Check for updates failed"), 3)
            return
        end
        
        local current_version = get_current_version()
        
        if M.is_newer_version(current_version, latest_version) then
            local source_text = " (" .. source_used .. ")"
            local message = string.format(gettext("New version found: %s%s\nCurrent version: %s\n\nDownload and install update?"), latest_version, source_text, current_version)
            
            UIManager:show(ConfirmBox:new{
                text = message,
                ok_text = gettext("Update"),
                cancel_text = gettext("Later"),
                ok_callback = function()
                    M.perform_update(download_url, latest_version, source)
                end
            })
        else
            UIManager:show(ConfirmBox:new{
                text = string.format(gettext("Current version is up to date (%s)\n\nDowngrade to a previous version?"), current_version),
                ok_text = gettext("Downgrade"),
                cancel_text = gettext("Cancel"),
                ok_callback = function()
                    UIManager:show(InfoMessage:new{
                        text = gettext("Getting version list..."),
                        timeout = 1
                    })
                    
                    UIManager:scheduleIn(0.5, function()
                        local all_versions = get_all_versions_from_source(source)
                        if not all_versions or #all_versions == 0 then
                            show_msg(gettext("Failed to get version list"), 2)
                            return
                        end
                        show_version_choice(all_versions, current_version, source)
                    end)
                end
            })
        end
    end)
end

-- 检查更新（主入口）
function M.check_for_updates(silent, plugin)
    show_source_selection_dialog(function(selected_source)
        do_check_updates(selected_source)
    end)
end

function M.perform_update(download_url, target_version, source)
    if not download_url then
        UIManager:show(Notification:new{
            text = gettext("Update package download URL not found"),
            timeout = 2
        })
        return
    end
    
    local version_text = target_version and (" (" .. target_version .. ")") or ""
    local source_text = source and (" [" .. source.name .. "]") or ""
    
    UIManager:show(Notification:new{
        text = gettext("Downloading update") .. version_text .. source_text .. "...",
        timeout = 1
    })
    
    UIManager:scheduleIn(0.1, function()
        local zip_path, err = download_update(download_url)
        
        if not zip_path then
            UIManager:show(Notification:new{
                text = err or gettext("Download failed, please check network connection and try again"),
                timeout = 4
            })
            return
        end
        
        UIManager:show(Notification:new{
            text = gettext("Installing update") .. version_text .. "...",
            timeout = 1
        })
        
        UIManager:scheduleIn(0.1, function()
            local success = install_update(zip_path)
            
            if success then
                UIManager:show(ConfirmBox:new{
                    text = gettext("Update installed successfully. KOReader needs to restart to apply changes. Restart now?"),
                    ok_text = gettext("Restart"),
                    cancel_text = gettext("Later"),
                    ok_callback = function()
                        UIManager:restartKOReader()
                    end
                })
            else
                if is_android then
                    local data_dir = DataStorage:getDataDir()
                    if data_dir:sub(1, 2) == "./" then
                        data_dir = data_dir:sub(3)
                    elseif data_dir:sub(1, 1) == "." then
                        data_dir = data_dir:sub(2)
                    end
                    UIManager:show(Notification:new{
                        text = string.format(gettext("Automatic installation failed. Please manually extract %splugins/cloudlibrary.koplugin.zip to the plugins directory and restart"), data_dir),
                        timeout = 5
                    })
                else
                    UIManager:show(Notification:new{
                        text = gettext("Installation failed, please update manually"),
                        timeout = 3
                    })
                end
            end
        end)
    end)
end

return M