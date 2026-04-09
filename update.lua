-- update.lua
-- 插件在线更新模块（支持 Gitee）

local logger = require("logger")
local UIManager = require("ui/uimanager")
local Notification = require("ui/widget/notification")
local ConfirmBox = require("ui/widget/confirmbox")
local InfoMessage = require("ui/widget/infomessage")
local NetworkMgr = require("ui/network/manager")
local DataStorage = require("datastorage")
local lfs = require("libs/libkoreader-lfs")
local _ = require("gettext")

local M = {}

-- Gitee 仓库信息
local REPO_OWNER = "gytwo"
local REPO_NAME = "cloudlibrary"

local Device = require("device")
local is_android = Device:isAndroid()

-- 根据设备类型获取插件目录
local plugin_dir
local current_file_path = (...)

if is_android then
    -- Android: 使用 DataStorage 方式
    local data_dir = DataStorage:getDataDir()
    if data_dir:sub(1, 2) == "./" then
        data_dir = data_dir:sub(3)
    elseif data_dir:sub(1, 1) == "." then
        data_dir = data_dir:sub(2)
    end
    if data_dir:sub(-1) ~= "/" then
        data_dir = data_dir .. "/"
    end
    plugin_dir = data_dir .. "plugins/cloudlibrary.koplugin/"
else
    -- Kindle: 使用 ... 获取绝对路径
    plugin_dir = current_file_path:match("(.*/)cloudlibrary.koplugin/")
    if not plugin_dir then
        local data_dir = DataStorage:getDataDir()
        if data_dir:sub(1, 2) == "./" then
            data_dir = data_dir:sub(3)
        elseif data_dir:sub(1, 1) == "." then
            data_dir = data_dir:sub(2)
        end
        plugin_dir = data_dir .. "plugins/cloudlibrary.koplugin/"
    end
end

if plugin_dir:sub(-1) == "/" then
    plugin_dir = plugin_dir:sub(1, -2)
end

logger.info("CloudLibrary: 插件目录: " .. plugin_dir)

local function get_data_dir()
    local data_dir = DataStorage:getDataDir()
    if data_dir:sub(1, 2) == "./" then
        data_dir = data_dir:sub(3)
    elseif data_dir:sub(1, 1) == "." then
        data_dir = data_dir:sub(2)
    end
    if data_dir:sub(-1) ~= "/" then
        data_dir = data_dir .. "/"
    end
    return data_dir
end

local function get_current_version()
    local meta_path = plugin_dir .. "/_meta.lua"
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

function M.get_latest_version()
    local url = string.format("https://gitee.com/api/v5/repos/%s/%s/releases/latest", REPO_OWNER, REPO_NAME)
    
    logger.info("CloudLibrary: 请求最新版本 URL: " .. url)
    
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
            }
        }
    end)
    
    if not ok then
        logger.warn("CloudLibrary: HTTP 请求异常: " .. tostring(err))
        return nil, "网络请求异常"
    end
    
    if not response or #response == 0 then
        logger.warn("CloudLibrary: 响应为空")
        return nil, "服务器无响应"
    end
    
    local response_str = table.concat(response)
    
    local json = require("json")
    local success, data = pcall(json.decode, response_str)
    
    if not success or not data then
        logger.warn("CloudLibrary: JSON 解析失败")
        return nil, "解析版本信息失败"
    end
    
    local tag_name = data.tag_name or data.name
    if not tag_name then
        logger.warn("CloudLibrary: 未找到版本号")
        return nil, "未找到版本号"
    end
    
    logger.info("CloudLibrary: 最新版本: " .. tag_name)
    
    local zip_url = nil
    if data.assets then
        for _, asset in ipairs(data.assets) do
            if asset.name and asset.name:match("%.zip$") then
                zip_url = asset.browser_download_url
                break
            end
        end
    end
    
    return tag_name, zip_url, data.body
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

-- 下载函数：根据设备选择不同方式
function M.download_update(download_url)
    if is_android then
        -- Android: 使用 socket.http 下载到 plugins 目录
        local data_dir = get_data_dir()
        local zip_path = data_dir .. "plugins/cloudlibrary.koplugin.zip"
        
        local http = require("socket.http")
        local ltn12 = require("ltn12")
        
        local out_file = io.open(zip_path, "w")
        if not out_file then
            return nil, "无法创建文件"
        end
        
        logger.info("CloudLibrary: 开始下载到: " .. zip_path)
        
        local ok, response = pcall(function()
            return http.request{
                url = download_url,
                sink = ltn12.sink.file(out_file),
                headers = {
                    ["User-Agent"] = "KOReader-CloudLibrary",
                }
            }
        end)
        
        out_file:close()
        
        if not ok then
            os.remove(zip_path)
            return nil, "下载失败"
        end
        
        if type(response) == "number" and (response < 200 or response >= 300) then
            os.remove(zip_path)
            return nil, string.format("HTTP 错误: %d", response)
        end
        
        local size = lfs.attributes(zip_path, "size") or 0
        if size < 1000 then
            os.remove(zip_path)
            return nil, "下载的文件无效"
        end
        
        return zip_path
    else
        -- Kindle: 使用 wget/curl 下载到 /tmp
        local temp_file = "/tmp/cloudlibrary.koplugin.zip"
        
        local cmd = string.format("wget -O %s %s", temp_file, download_url)
        local result = os.execute(cmd)
        
        if result ~= 0 then
            cmd = string.format("curl -o %s %s", temp_file, download_url)
            result = os.execute(cmd)
        end
        
        if result ~= 0 then
            os.remove(temp_file)
            return nil, "下载失败"
        end
        
        local size = lfs.attributes(temp_file, "size") or 0
        if size < 1000 then
            os.remove(temp_file)
            return nil, "下载的文件无效"
        end
        
        return temp_file
    end
end

-- 安装函数：根据设备选择不同方式
function M.install_update(zip_path)
    if is_android then
        -- Android: 只提示手动解压
        local data_dir = get_data_dir()
        UIManager:show(ConfirmBox:new{
            text = string.format(_("更新包已下载完成\n\n文件位置: %splugins/cloudlibrary.koplugin.zip\n\n请手动解压到 plugins 目录后重启 KOReader"), data_dir),
            ok_text = _("确定"),
        })
        return true
    else
        -- Kindle: 自动解压到插件目录
        logger.info("CloudLibrary: 解压到插件目录: " .. plugin_dir)
        
        local result = os.execute(string.format("unzip -o %s -d %s", zip_path, plugin_dir))
        
        if result ~= 0 then
            result = os.execute(string.format("/usr/bin/unzip -o %s -d %s", zip_path, plugin_dir))
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

function M.check_for_updates(silent, plugin)
    if not NetworkMgr:isOnline() then
        if not silent then
            UIManager:show(Notification:new{
                text = _("无网络连接，无法检查更新"),
                timeout = 2
            })
        end
        return
    end
    
    if not silent then
        UIManager:show(Notification:new{
            text = _("正在检查更新..."),
            timeout = 1
        })
    end
    
    UIManager:scheduleIn(1, function()
        local latest_version, download_url, release_notes = M.get_latest_version()
        
        if not latest_version then
            if not silent then
                UIManager:show(Notification:new{
                    text = _("检查更新失败，请稍后重试"),
                    timeout = 2
                })
            end
            return
        end
        
        local current_version = get_current_version()
        
        if M.is_newer_version(current_version, latest_version) then
            local message = string.format(_("发现新版本: %s\n当前版本: %s\n\n是否下载并安装更新？"), latest_version, current_version)
            
            if release_notes and release_notes ~= "" then
                local notes = release_notes:sub(1, 200)
                message = message .. "\n\n更新内容:\n" .. notes
                if #release_notes > 200 then
                    message = message .. "..."
                end
            end
            
            UIManager:show(ConfirmBox:new{
                text = message,
                ok_text = _("更新"),
                cancel_text = _("稍后"),
                ok_callback = function()
                    M.perform_update(download_url, plugin)
                end
            })
        else
            if not silent then
                UIManager:show(Notification:new{
                    text = string.format(_("已是最新版本 (%s)"), current_version),
                    timeout = 2
                })
            end
        end
    end)
end

function M.perform_update(download_url, plugin)
    if not download_url then
        UIManager:show(Notification:new{
            text = _("未找到更新包下载地址"),
            timeout = 2
        })
        return
    end
    
    UIManager:show(InfoMessage:new{
        text = _("正在下载更新..."),
        timeout = 1
    })
    
    UIManager:scheduleIn(0.5, function()
        local zip_path, err = M.download_update(download_url)
        
        if not zip_path then
            UIManager:show(Notification:new{
                text = err or _("下载失败，请稍后重试"),
                timeout = 3
            })
            return
        end
        
        UIManager:show(InfoMessage:new{
            text = _("正在安装更新..."),
            timeout = 1
        })
        
        UIManager:scheduleIn(0.5, function()
            local success = M.install_update(zip_path)
            
            if success then
                if not is_android then
                    UIManager:show(ConfirmBox:new{
                        text = _("更新安装完成，需要重启 KOReader 才能生效。是否立即重启？"),
                        ok_text = _("重启"),
                        cancel_text = _("稍后"),
                        ok_callback = function()
                            UIManager:restartKOReader()
                        end
                    })
                end
            else
                UIManager:show(Notification:new{
                    text = _("安装失败，请手动更新"),
                    timeout = 3
                })
            end
        end)
    end)
end

return M