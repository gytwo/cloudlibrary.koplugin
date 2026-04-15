local reader_order = require("ui/elements/reader_menu_order")
local UIManager = require("ui/uimanager")
local InfoMessage = require("ui/widget/infomessage")
local json = require("json")
local Device = require("device")
local lfs = require("libs/libkoreader-lfs")
local DataStorage = require("datastorage")
local logger = require("logger")

local M = {}

function M.read_json(path)
    local f = io.open(path, "r")
    if not f then return {} end
    local content = f:read("*a")
    f:close()
    if not content or content == "" then return {} end
    if not M.isPossiblyJson(content) then return nil end
    local ok, data = pcall(json.decode, content)
    if ok and type(data) == "table" then
        if data.error_summary or (data.error and type(data.error) == "table") then
            return nil
        end
        return data
    end
    return nil
end

function M.insert_after_statistics(key)
    local pos = 1
    if reader_order and reader_order.tools then
        for index, value in ipairs(reader_order.tools) do
            if value == "statistics" then
                pos = index + 1
                break
            end
        end
        table.insert(reader_order.tools, pos, key)
    end
end

function M.isPossiblyJson(content)
    return content:sub(1, #"{") == "{"
end

function M.show_msg(msg)
    UIManager:show(InfoMessage:new{
        text = msg,
        timeout = 3,
    })
end

function M.get_device_name()
    local model = Device.model or "Unknown"
    
    local friendly_names = {
        KindleVoyage = "Kindle Voyage",
        KindlePaperWhite = "Kindle PaperWhite",
        KindlePaperWhite2 = "Kindle PaperWhite 2",
        KindlePaperWhite3 = "Kindle PaperWhite 3",
        KindlePaperWhite4 = "Kindle PaperWhite 4",
        KindlePaperWhite5 = "Kindle PaperWhite 5",
        KindleBasic = "Kindle Basic",
        KindleBasic2 = "Kindle Basic 2",
        KindleBasic3 = "Kindle Basic 3",
        KindleOasis = "Kindle Oasis",
        KindleOasis2 = "Kindle Oasis 2",
        KindleOasis3 = "Kindle Oasis 3",
        Kindle = "Kindle",
        KoboAuraH2O = "Kobo Aura H2O",
        KoboAura = "Kobo Aura",
        KoboAuraOne = "Kobo Aura One",
        KoboGlo = "Kobo Glo",
        KoboGloHD = "Kobo Glo HD",
        KoboClara = "Kobo Clara",
        KoboClaraHD = "Kobo Clara HD",
        KoboForma = "Kobo Forma",
        KoboLibra = "Kobo Libra",
        KoboLibra2 = "Kobo Libra 2",
        KoboSage = "Kobo Sage",
        KoboElipsa = "Kobo Elipsa",
        PocketBook = "PocketBook",
        PocketBookBasic = "PocketBook Basic",
        PocketBookTouch = "PocketBook Touch",
        PocketBookHD = "PocketBook HD",
        Android = "Android Device",
        Remarkable = "reMarkable",
        Likebook = "Likebook",
        Boox = "Boox",
    }
    
    return friendly_names[model] or model
end

function M.get_device_id()
    local id = G_reader_settings:readSetting("cloudlibrary_device_id")
    if not id then
        math.randomseed(os.time())
        id = string.format("%08x", math.random(0xffffffff))
        G_reader_settings:saveSetting("cloudlibrary_device_id", id)
    end
    return id
end

function M.write_log(log_path, content)
    if not log_path or not content then
        return false
    end
    
    local dir = log_path:match("(.*)/")
    if dir and dir ~= "" then
        pcall(function()
            os.execute("mkdir -p " .. dir)
        end)
    end
    
    -- 读取原有内容
    local old_content = ""
    local f = io.open(log_path, "r")
    if f then
        old_content = f:read("*all") or ""
        f:close()
    end
    
    -- 新内容直接拼接在前面（不需要额外加空行，因为新内容末尾已有空行）
    local new_content = content
    if old_content ~= "" then
        new_content = content .. old_content
    end
    
    local out_f = io.open(log_path, "w")
    if out_f then
        out_f:write(new_content)
        out_f:close()
        return true
    end
    return false
end

function M.get_log_path()
    local data_dir = DataStorage:getDataDir()
    if not data_dir then
        data_dir = os.getenv("HOME") or "/mnt/us"
        if data_dir then
            data_dir = data_dir .. "/.koreader/"
        end
    end
    return data_dir .. "同步记录.txt"
end


M.SEPARATOR_LINE = string.rep("=", 30)  -- 统一使用30个等号

return M
