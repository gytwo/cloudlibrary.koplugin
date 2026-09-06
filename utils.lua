local reader_order = require("ui/elements/reader_menu_order")
local UIManager = require("ui/uimanager")
local InfoMessage = require("ui/widget/infomessage")
local json = require("json")
local Device = require("device")
local lfs = require("libs/libkoreader-lfs")
local DataStorage = require("datastorage")
local logger = require("logger")
local _ = require("gettext")
local Blitbuffer = require("ffi/blitbuffer")
local ButtonTable = require("ui/widget/buttontable")
local CenterContainer = require("ui/widget/container/centercontainer")
local Font = require("ui/font")
local FrameContainer = require("ui/widget/container/framecontainer")
local Geom = require("ui/geometry")
local InputContainer = require("ui/widget/container/inputcontainer")
local ProgressWidget = require("ui/widget/progresswidget")
local Size = require("ui/size")
local TextWidget = require("ui/widget/textwidget")
local VerticalGroup = require("ui/widget/verticalgroup")
local VerticalSpan = require("ui/widget/verticalspan")
local time = require("ui/time")
local Screen = Device.screen

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
    
    local old_content = ""
    local f = io.open(log_path, "r")
    if f then
        old_content = f:read("*all") or ""
        f:close()
    end
    
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
    local DataStorage = require("datastorage")
    return DataStorage:getDataDir() .. "/cloudlibrary_sync_log.txt"
end

M.SEPARATOR_LINE = string.rep("=", 30)

-- ============================================================
-- DownloadDialog - Progress dialog with cancel button
-- ============================================================

local DownloadDialog = InputContainer:extend{
    title = "",
    description = nil,
    progress_max = 100,
    buttons = nil,
    refresh_time_seconds = 0.1,
}

function DownloadDialog:init()
    self.dimen = Screen:getSize()
    self.last_redraw_time_ms = 0

    local width = Screen:getWidth() - Screen:scaleBySize(80)

    local vertical_group = VerticalGroup:new{}

    self.title_widget = TextWidget:new{
        text = self.title or "",
        face = Font:getFace("ffont"),
        bold = true,
        max_width = width,
    }
    self.title_container = CenterContainer:new{
        dimen = Geom:new{
            w = width,
            h = self.title_widget:getSize().h,
        },
        self.title_widget,
    }
    table.insert(vertical_group, self.title_container)

    if self.description and self.description ~= "" then
        self.description_widget = TextWidget:new{
            text = self.description,
            face = Font:getFace("xx_smallinfofont"),
            max_width = width,
        }
        self.description_container = CenterContainer:new{
            dimen = Geom:new{
                w = width,
                h = self.description_widget:getSize().h,
            },
            self.description_widget,
        }
        table.insert(vertical_group, VerticalSpan:new{ width = Size.padding.small })
        table.insert(vertical_group, self.description_container)
    end

    if self.progress_max and self.progress_max > 0 then
        self.progress_bar = ProgressWidget:new{
            fillcolor = Blitbuffer.COLOR_BLACK,
            width = width,
            height = Screen:scaleBySize(18),
            padding = Size.padding.large,
            margin = Size.margin.tiny,
            percentage = 0,
        }
        table.insert(vertical_group, self.progress_bar)
    end

    if self.buttons then
        local button_table = ButtonTable:new{
            width = width,
            buttons = self.buttons,
            zero_sep = true,
            show_parent = self,
        }
        table.insert(vertical_group, VerticalSpan:new{ width = Size.padding.large })
        table.insert(vertical_group, button_table)
    end

    self[1] = CenterContainer:new{
        dimen = Screen:getSize(),
        FrameContainer:new{
            radius = Size.radius.window,
            bordersize = Size.border.window,
            padding = Size.padding.large,
            padding_bottom = self.buttons and 0 or nil,
            background = Blitbuffer.COLOR_WHITE,
            vertical_group,
        },
    }
end

function DownloadDialog:reportProgress(progress)
    if not self.progress_bar then return end
    self.progress_bar:setPercentage(progress / self.progress_max)
    local now = time.now()
    local elapsed = now - self.last_redraw_time_ms
    if self.progress_bar.percentage >= 1 or elapsed >= self.refresh_time_seconds * 1000 * 1000 then
        self.last_redraw_time_ms = now
        UIManager:setDirty(self, function() return "fast", self.dimen end)
        UIManager:forceRePaint()
    end
end

function DownloadDialog:setTitle(title)
    self.title = title or ""
    if self.title_widget and self.title_widget.setText then
        self.title_widget:setText(self.title)
        UIManager:setDirty(self, function() return "fast", self.dimen end)
        UIManager:forceRePaint()
    end
end

function DownloadDialog:setDescription(desc)
    self.description = desc or ""
    if self.description_widget and self.description_widget.setText then
        self.description_widget:setText(self.description)
        UIManager:setDirty(self, function() return "fast", self.dimen end)
        UIManager:forceRePaint()
    end
end

function DownloadDialog:show()
    UIManager:show(self, "ui")
end

function DownloadDialog:close()
    UIManager:close(self, "ui")
end

M.DownloadDialog = DownloadDialog

-- ============================================================
-- 检查文件路径是否在排除目录中
-- ============================================================
function M.is_path_excluded(file_path, exclude_dirs)
    if not file_path or not exclude_dirs or #exclude_dirs == 0 then
        return false
    end
    
    local function normalize_path(path)
        path = path:gsub("\\", "/")  
        path = path:gsub("/+$", "")   
        return path
    end
    
    local normalized_file = normalize_path(file_path)
    
    for _, exclude_dir in ipairs(exclude_dirs) do
        local normalized_exclude = normalize_path(exclude_dir)
        if normalized_file:find(normalized_exclude, 1, true) == 1 then
            local next_char = normalized_file:sub(#normalized_exclude + 1, #normalized_exclude + 1)
            if next_char == "/" or next_char == "" then
                return true
            end
        end
    end
    
    return false
end

-- ============================================================
-- Bookshelf integration: automatically enter selection mode and retrieve selected file list for batch operations
-- ============================================================

function M.findBookshelfWidget()
    local stack = UIManager._window_stack
    if not stack then
        return nil
    end
    
    for i, entry in ipairs(stack) do
        local widget = entry.widget
        if widget and widget.name == "bookshelf" then
            return widget
        end
    end
    
    return nil
end

function M.isBookshelfShowing()
    local widget = M.findBookshelfWidget()
    if not widget then
        return false
    end
    return UIManager:isWidgetShown(widget)
end

function M.bookshelfEnterSelection()
    local widget = M.findBookshelfWidget()
    if not widget then
        return false
    end
    
    if not widget._selection:isActive() then
        widget._selection:enterMode()
        widget:_rebuild()
        UIManager:setDirty(widget, "ui")
    end
    return true
end

function M.bookshelfExitSelection()
    local widget = M.findBookshelfWidget()
    if not widget then
        return false
    end
    
    if widget._selection:isActive() then
        widget._selection:exitMode()
        widget:_rebuild()
        UIManager:setDirty(widget, "ui")
    end
    return true
end

function M.bookshelfGetSelectedFiles()
    local widget = M.findBookshelfWidget()
    if not widget then
        return {}
    end
    
    -- Get selected file paths via Selection:paths()
    return widget._selection:paths() or {}
end

function M.bookshelfIsInSelectionMode()
    local widget = M.findBookshelfWidget()
    if not widget then
        return false
    end
    return widget._selection:isActive()
end

return M
