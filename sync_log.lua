local logger = require("logger")
local lfs = require("libs/libkoreader-lfs")
local DataStorage = require("datastorage")
local NetworkMgr = require("ui/network/manager")
local UIManager = require("ui/uimanager")
local Notification = require("ui/widget/notification")
local _ = require("gettext")
local utils = require("utils")

local M = {}

local CLOUD_LOG_FILENAME = "cloudlibrary_global_log.txt"
local LOCAL_LOG_PATH = DataStorage:getDataDir() .. "同步记录.txt"

-- 延迟执行相关
local pending_sync = false
local sync_timer = nil

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

local function get_cloud_path(server)
    local api = get_api(server)
    if not api then
        return nil
    end
    if server.type == "dropbox" then
        local url_base = server.url:sub(-1) == "/" and server.url or server.url.."/"
        return url_base .. CLOUD_LOG_FILENAME
    else
        local path = api:getJoinedPath(server.address, server.url)
        return api:getJoinedPath(path, CLOUD_LOG_FILENAME)
    end
end

local function download_cloud_log()
    local server = get_server()
    if not server then
        return nil
    end
    local api = get_api(server)
    if not api then
        return nil
    end
    local cloud_path = get_cloud_path(server)
    if not cloud_path then
        return nil
    end
    
    local temp_file = DataStorage:getDataDir() .. "cloud_log.tmp"
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
    
    if type(code) == "number" and code == 200 then
        local f = io.open(temp_file, "r")
        if f then
            local content = f:read("*all")
            f:close()
            os.remove(temp_file)
            return content
        end
    end
    
    if lfs.attributes(temp_file, "mode") then
        os.remove(temp_file)
    end
    return nil
end

local function upload_cloud_log(content)
    if not content then
        return false
    end
    
    local server = get_server()
    if not server then
        return false
    end
    
    local api = get_api(server)
    if not api then
        return false
    end
    
    local cloud_path = get_cloud_path(server)
    if not cloud_path then
        return false
    end
    
    local temp_file = DataStorage:getDataDir() .. "cloud_log.tmp"
    local f = io.open(temp_file, "w")
    if not f then
        return false
    end
    f:write(content)
    f:close()
    
    local code
    if server.type == "dropbox" then
        local token = server.password
        if server.address and server.address ~= "" then
            token = api:getAccessToken(server.password, server.address)
        end
        code = api:uploadFile(cloud_path, token, temp_file, nil, true)
    else
        code = api:uploadFile(cloud_path, server.username, server.password, temp_file)
    end
    
    os.remove(temp_file)
    
    return type(code) == "number" and code >= 200 and code < 300
end

local function split_records(content)
    if not content or content == "" then
        return {}
    end
    
    local records = {}
    local pattern = utils.SEPARATOR_LINE .. "\n同步时间:"
    local pos = 1
    local last_pos = 1
    
    while true do
        local start_pos = content:find(pattern, pos)
        if not start_pos then
            break
        end
        
        if start_pos > last_pos then
            local record = content:sub(last_pos, start_pos - 1)
            if record:match("同步时间:") then
                table.insert(records, record)
            end
        end
        
        pos = start_pos + 1
        last_pos = start_pos
    end
    
    if last_pos <= #content then
        local record = content:sub(last_pos)
        if record:match("同步时间:") then
            table.insert(records, record)
        end
    end
    
    return records
end

local function get_record_key(record)
    local timestamp = record:match("同步时间: ([^\n]+)")
    local device_id = record:match("设备ID: ([^\n]+)")
    if timestamp and device_id then
        return timestamp .. "|" .. device_id
    end
    return record:sub(1, 100)
end

-- 实际的同步逻辑
function M.doSync(silent)
    if not NetworkMgr:isOnline() then
        if not silent then
            UIManager:show(Notification:new{
                text = _("无网络连接，无法同步"),
                timeout = 2
            })
        end
        return false
    end
    
    if not silent then
        UIManager:show(Notification:new{
            text = _("正在同步记录..."),
            timeout = 1
        })
    end
    
    UIManager:scheduleIn(0.5, function()
        local cloud_content = download_cloud_log()
        local local_content = ""
        
        if lfs.attributes(LOCAL_LOG_PATH, "mode") == "file" then
            local f = io.open(LOCAL_LOG_PATH, "r")
            if f then
                local_content = f:read("*all")
                f:close()
            end
        end
        
        local local_records = (local_content and local_content ~= "") and split_records(local_content) or {}
        local cloud_records = (cloud_content and cloud_content ~= "") and split_records(cloud_content) or {}
        
        local all_records = {}
        local keys = {}
        
        for _, record in ipairs(local_records) do
            local key = get_record_key(record)
            if not keys[key] then
                keys[key] = true
                table.insert(all_records, record)
            end
        end
        
        local new_count = 0
        for _, record in ipairs(cloud_records) do
            local key = get_record_key(record)
            if not keys[key] then
                keys[key] = true
                table.insert(all_records, record)
                new_count = new_count + 1
            end
        end
        
        table.sort(all_records, function(a, b)
            local ta = a:match("同步时间: ([^\n]+)") or ""
            local tb = b:match("同步时间: ([^\n]+)") or ""
            return ta > tb
        end)
        
        local final_content = table.concat(all_records, "")
        
        local out_f = io.open(LOCAL_LOG_PATH, "w")
        if out_f then
            out_f:write(final_content)
            out_f:close()
        end
        
        local success = upload_cloud_log(final_content)
        
        local result_msg = ""
        if success then
            result_msg = string.format(_("同步成功！新增 %d 条记录，共 %d 条"), new_count, #all_records)
        else
            result_msg = _("同步失败，请检查云存储配置")
        end
        
        if not silent then
            UIManager:show(Notification:new{
                text = result_msg,
                timeout = 2
            })
        else
            logger.info("CloudLibrary: " .. result_msg)
        end
    end)
    
    return true
end

-- 入口函数：延迟执行，不阻塞主流程
function M.sync_log(silent)
    pending_sync = true
    
    if sync_timer then
        return true
    end
    
    sync_timer = UIManager:scheduleIn(2, function()
        sync_timer = nil
        
        if not pending_sync then
            return
        end
        pending_sync = false
        
        M.doSync(silent)
    end)
    
    return true
end

-- 在 sync_log.lua 末尾添加

-- 清空云端同步记录
function M.clear_cloud_log()
    local server = get_server()
    if not server then
        return false, "未配置云存储服务"
    end
    
    local api = get_api(server)
    if not api then
        return false, "不支持的云服务类型"
    end
    
    local cloud_path = get_cloud_path(server)
    if not cloud_path then
        return false, "无法获取云端路径"
    end
    
    -- 上传一个空文件覆盖云端记录
    local temp_file = DataStorage:getDataDir() .. "cloud_log_empty.tmp"
    local f = io.open(temp_file, "w")
    if not f then
        return false, "无法创建临时文件"
    end
    f:write("")  -- 空内容
    f:close()
    
    local code
    if server.type == "dropbox" then
        local token = server.password
        if server.address and server.address ~= "" then
            token = api:getAccessToken(server.password, server.address)
        end
        code = api:uploadFile(cloud_path, token, temp_file, nil, true)
    else
        code = api:uploadFile(cloud_path, server.username, server.password, temp_file)
    end
    
    os.remove(temp_file)
    
    if type(code) == "number" and code >= 200 and code < 300 then
        return true, "云端同步记录已清空"
    else
        return false, "清空失败，HTTP状态码: " .. tostring(code)
    end
end

return M
