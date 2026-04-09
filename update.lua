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
local ffiUtil = require("ffi/util")
local _ = require("gettext")

local M = {}

-- Gitee 仓库信息（请替换为你的信息）
local REPO_OWNER = "gytwo"
local REPO_NAME = "cloudlibrary"

local function get_current_version()
    local plugin_path = DataStorage:getDataDir() .. "plugins/cloudlibrary.koplugin/_meta.lua"
    local f = io.open(plugin_path, "r")
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
    
    if not ok or not response or #response == 0 then
        logger.warn("CloudLibrary: 获取最新版本失败 - " .. tostring(err))
        return nil, "网络请求失败"
    end
    
    local json = require("json")
    local data = json.decode(table.concat(response))
    
    if not data or not data.tag_name then
        logger.warn("CloudLibrary: 解析版本信息失败")
        return nil, "解析版本信息失败"
    end
    
    local zip_url = nil
    if data.assets then
        for _, asset in ipairs(data.assets) do
            if asset.name and asset.name:match("%.zip$") then
                zip_url = asset.browser_download_url
                break
            end
        end
    end
    
    if not zip_url and data.body then
        local download_url = data.body:match("https://gitee.com/[^%s]+%.zip")
        if download_url then
            zip_url = download_url
        end
    end
    
    return data.tag_name, zip_url, data.body
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

function M.download_update(download_url)
    local http = require("socket.http")
    local ltn12 = require("ltn12")
    
    local temp_file = DataStorage:getDataDir() .. "temp_update.zip"
    
    local out_file = io.open(temp_file, "w")
    if not out_file then
        return nil, "无法创建临时文件"
    end
    
    local ok, err = pcall(function()
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
        logger.warn("CloudLibrary: 下载更新失败 - " .. tostring(err))
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

function M.install_update(zip_path)
    local plugin_path = DataStorage:getDataDir() .. "plugins/cloudlibrary.koplugin"
    local plugin_dir = plugin_path:match("(.*)/")
    
    local unzip_cmd = string.format("unzip -o %s -d %s", zip_path, plugin_dir)
    local result = os.execute(unzip_cmd)
    
    if result ~= 0 then
        unzip_cmd = string.format("/usr/bin/unzip -o %s -d %s", zip_path, plugin_dir)
        result = os.execute(unzip_cmd)
    end
    
    os.remove(zip_path)
    return result == 0
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
                UIManager:show(ConfirmBox:new{
                    text = _("更新安装完成，需要重启 KOReader 才能生效。是否立即重启？"),
                    ok_text = _("重启"),
                    cancel_text = _("稍后"),
                    ok_callback = function()
                        UIManager:restartKOReader()
                    end
                })
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