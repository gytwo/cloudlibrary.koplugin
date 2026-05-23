local logger = require("logger")
local UIManager = require("ui/uimanager")
local Notification = require("ui/widget/notification")
local ConfirmBox = require("ui/widget/confirmbox")
local lfs = require("libs/libkoreader-lfs")
local DataStorage = require("datastorage")
local _ = require("gettext")
local Event = require("ui/event")
local utils = require("utils")  
local ProgressbarDialog = require("ui/widget/progressbardialog")
local blitbuffer = require("ffi/blitbuffer") 

local ManualSync = {}

function ManualSync:new(plugin, auto_sync)
    local obj = {}
    setmetatable(obj, self)
    self.__index = self
    
    obj.plugin = plugin
    obj.auto_sync = auto_sync
    obj.settings = plugin.settings
    
    return obj
end

function ManualSync:syncCurrentBook(is_upload)
    local doc = self.plugin.ui.document
    if not doc then
        self:showMsg(_("Please open a book first"))
        return
    end
    
    local file = doc.file
    local DocSettings = require("docsettings")
    local metadata_file = DocSettings:findSidecarFile(file)
    
    if not metadata_file then
        self:showMsg(_("Local metadata file not found"))
        return
    end
    
    local NetworkMgr = require("ui/network/manager")
    if not NetworkMgr:isOnline() then
        self:showMsg(_("No network connection, cannot sync"))
        return
    end

    local remote = require("remote")
    local server = remote.get_server()
    if not server then
        self:showMsg(_("Cloud storage service not configured, please configure in settings first"))
        return
    end

    if not server.url or server.url == "" then
        self:showMsg(_("Cloud directory not set, please configure in cloud directory settings"))
        return
    end

    local api = remote.get_api(server)
    if not api then
        self:showMsg(_("Unsupported cloud storage type, please use WebDAV or Dropbox"))
        return
    end

    if is_upload then
        self:doSyncCurrentBook(is_upload, file, metadata_file)
    else

        local confirm_dialog = ConfirmBox:new{
            title = _("Confirm download"),
            text = _("This operation requires reopening the current book to override update metadata. Continue?"),
            ok_text = _("Continue"),
            cancel_text = _("Cancel"),
            ok_callback = function()
                 UIManager:show(Notification:new{
                     text = _("Downloading and applying metadata - Overwrite..."),
                     timeout = 0
                 })
                UIManager:nextTick(function()
                    self:doSyncCurrentBook(is_upload, file, metadata_file)
                end)
            end
        }
        UIManager:show(confirm_dialog)
    end
end

function ManualSync:syncCurrentBookMerge()
    local doc = self.plugin.ui.document
    if not doc then
        self:showMsg(_("Please open a book first"))
        return
    end
    
    local file = doc.file
    local DocSettings = require("docsettings")
    local metadata_file = DocSettings:findSidecarFile(file)
    
    if not metadata_file then
        self:showMsg(_("Local metadata file not found"))
        return
    end
    
    local NetworkMgr = require("ui/network/manager")
    if not NetworkMgr:isOnline() then
        self:showMsg(_("No network connection, cannot sync"))
        return
    end

    local remote = require("remote")
    local server = remote.get_server()
    if not server then
        self:showMsg(_("Cloud storage service not configured, please configure in settings first"))
        return
    end

    if not server.url or server.url == "" then
        self:showMsg(_("Cloud directory not set, please configure in cloud directory settings"))
        return
    end

    local api = remote.get_api(server)
    if not api then
        self:showMsg(_("Unsupported cloud storage type, please use WebDAV or Dropbox"))
        return
    end

    self.plugin.ui:saveSettings()
    
    local confirm_dialog = ConfirmBox:new{
        title = _("Confirm merge download"),
        text = _("This operation requires reopening the current book to merge update metadata. Continue?"),
        ok_text = _("Continue"),
        cancel_text = _("Cancel"),
        ok_callback = function()
            UIManager:show(Notification:new{
                text = _("Downloading and applying metadata - Merge..."),
                timeout = 0
            })
            UIManager:nextTick(function()
                self:doSyncCurrentBookMerge(file, metadata_file)
            end)
        end
    }
    UIManager:show(confirm_dialog)
end

function ManualSync:doSyncCurrentBook(is_upload, file, metadata_file)
    if is_upload then
        self.auto_sync:setSkipUpload(true)
    else
        self.auto_sync:setSkipDownload(true)
    end

    local props = {}
    if self.plugin.ui and self.plugin.ui.bookinfo then
        props = self.plugin.ui.bookinfo:getDocProps(file, nil, true) or {}
    end
    local title = props.title or props.display_title or file:match("([^/]+)$"):gsub("%.[^%.]+$", "")
    local author = props.authors
    if type(author) == "table" then
        author = author[1]
    end

    local book = {
        file = file,
        metadata = metadata_file,
        title = title,
        book_basename = file:match("([^/]+)$"):gsub("%.[^%.]+$", ""),
        author = author,
    }

    local remote = require("remote")
    local naming_mode = self.settings.metadata_naming_mode or "metadata"

    if is_upload then
        local success, error_type = remote.upload_book(book, naming_mode)

        if success then
             UIManager:show(Notification:new{
                 text = _("✓ Upload successful"),
                 timeout = 2
             })
            self:writeSingleLog(book, true, false, true)
            self:updateLastSync(_("Metadata sync") .. "-" .. _("Single upload") .. "-" .. _("Overwrite cloud"))
        else
            local error_info = remote.get_error_message(error_type, true, naming_mode)
            UIManager:show(Notification:new{
                text = string.format(_("✗ Upload failed: %s"), error_info.reason),
                timeout = 2
            })
            self:writeSingleLog(book, true, false, false, error_info.reason)
        end
        self.auto_sync:setSkipUpload(false)
        return
    end

    -- Download
    local ReaderUI = require("apps/reader/readerui")
    local current_ui = ReaderUI.instance
    local is_currently_open = current_ui and current_ui.document and current_ui.document.file == file

    -- Download to temp file
    local downloaded_file, cloud_filename, err_type = remote.download_to_temp(book, naming_mode)

    if not downloaded_file then
        local error_info = remote.get_error_message(err_type, false, naming_mode)
        UIManager:show(Notification:new{
            text = string.format(_("✗ Download failed: %s"), error_info.reason),
            timeout = 2
        })
        self:writeSingleLog(book, false, false, false, error_info.reason)
        self.auto_sync:setSkipDownload(false)
        return
    end

    -- Close current book if open
    if is_currently_open then
        self.auto_sync:setSkipUpload(true)
        G_reader_settings:saveSetting("cloudlibrary_skip_auto_download", true)
        current_ui:saveSettings()
        current_ui.tearing_down = true
        current_ui:onClose()
    end

    -- Merge or override metadata
    local Merger = require("merge")
    local merged_data
    local settings = G_reader_settings:readSetting("cloud_library_plugin", {})
    local keep_local_settings = settings.override_keep_local_settings == true

    if keep_local_settings then
        merged_data = Merger.override_merge(book.metadata, downloaded_file)
    else
        merged_data = Merger.load_metadata(downloaded_file)
    end

    os.remove(downloaded_file)

    if not merged_data then
        UIManager:show(Notification:new{
            text = _("✗ Merge failed"),
            timeout = 2
        })
        self:writeSingleLog(book, false, false, false, "merge_failed")
        self.auto_sync:setSkipDownload(false)
        return
    end

    remote.save_metadata_native(merged_data, book.file)

    -- Reopen the book
    if is_currently_open then
        UIManager:scheduleIn(0.1, function()
            ReaderUI:showReader(book.file)
        end)
    end

    -- Show success notification
    UIManager:show(Notification:new{
        text = _("✓ Applying successful (Overwrite)"),
        timeout = 2
    })

    self:writeSingleLog(book, false, false, true)
    self:updateLastSync(_("Metadata sync") .. "-" .. _("Single download") .. "-" .. _("Overwrite"))
    self.auto_sync:setSkipDownload(false)
end

function ManualSync:doSyncCurrentBookMerge(file, metadata_file)
    self.auto_sync:setSkipDownload(true)

    local props = {}
    if self.plugin.ui and self.plugin.ui.bookinfo then
        props = self.plugin.ui.bookinfo:getDocProps(file, nil, true) or {}
    end
    local title = props.title or props.display_title or file:match("([^/]+)$"):gsub("%.[^%.]+$", "")
    local author = props.authors
    if type(author) == "table" then
        author = author[1]
    end

    local book = {
        file = file,
        metadata = metadata_file,
        title = title,
        book_basename = file:match("([^/]+)$"):gsub("%.[^%.]+$", ""),
        author = author,
    }

    local remote = require("remote")
    local naming_mode = self.settings.metadata_naming_mode or "metadata"

    local ReaderUI = require("apps/reader/readerui")
    local current_ui = ReaderUI.instance
    local is_currently_open = current_ui and current_ui.document and current_ui.document.file == file

    -- Download to temp file
    local downloaded_file, cloud_filename, err_type = remote.download_to_temp(book, naming_mode)

    if not downloaded_file then
        local error_info = remote.get_error_message(err_type, false, naming_mode)
        UIManager:show(Notification:new{
            text = string.format(_("✗ Download failed: %s"), error_info.reason),
            timeout = 3
        })
        self:writeSingleLog(book, false, true, false, error_info.reason)
        self.auto_sync:setSkipDownload(false)
        return
    end

    -- Close current book if open
    if is_currently_open then
        self.auto_sync:setSkipUpload(true)
        G_reader_settings:saveSetting("cloudlibrary_skip_auto_download", true)
        current_ui:saveSettings()
        current_ui.tearing_down = true
        current_ui:onClose()
    end

    -- Merge metadata
    local Merger = require("merge")
    local merged_data = Merger.merge(book.metadata, downloaded_file)
    os.remove(downloaded_file)

    if not merged_data then
        UIManager:show(Notification:new{
            text = _("✗ Merge failed"),
            timeout = 3
        })
        self:writeSingleLog(book, false, true, false, "merge_failed")
        self.auto_sync:setSkipDownload(false)
        return
    end

    remote.save_metadata_native(merged_data, book.file)

    -- Reopen the book
    if is_currently_open then
        UIManager:scheduleIn(0.1, function()
            ReaderUI:showReader(book.file)
        end)
    end

    -- Show success notification
    UIManager:show(Notification:new{
        text = _("✓ Applying successful (Overwrite)"),
        timeout = 2
    })

    self:writeSingleLog(book, false, true, true)
    self:updateLastSync(_("Metadata sync") .. "-" .. _("Single download") .. "-" .. _("Merge"))

    UIManager:scheduleIn(0.5, function()
        if self.plugin.ui and self.plugin.ui.document then
            self.plugin.ui:handleEvent(Event:new("RedrawCurrentView"))
        end
    end)

    self.auto_sync:setSkipDownload(false)
end

function ManualSync:batchSyncWithFMSelection(is_upload, is_merge)
    local NetworkMgr = require("ui/network/manager")
    if not NetworkMgr:isOnline() then
        self:showMsg(_("No network connection, cannot sync"))
        return
    end

    local remote = require("remote")
    local server = remote.get_server()
    if not server then
        self:showMsg(_("Cloud storage service not configured, please configure in settings first"))
        return
    end

    if not server.url or server.url == "" then
        self:showMsg(_("Cloud directory not set, please configure in cloud directory settings"))
        return
    end

    local api = remote.get_api(server)
    if not api then
        self:showMsg(_("Unsupported cloud storage type, please use WebDAV or Dropbox"))
        return
    end

    local ui = self.plugin.ui
    
    local action_text = ""
    local button_text = ""
    if is_upload then
        action_text = _("upload")
        button_text = _("Batch upload metadata")
    else
        action_text = _("download")
        if is_merge then
            button_text = _("Batch download metadata - Merge")
        else
            button_text = _("Batch download metadata - Overwrite")
        end
    end
    
    if not ui or not ui.file_chooser then
        local FileManager = require("apps/filemanager/filemanager")
        
        if self.plugin.ui and self.plugin.ui.document then
            self.auto_sync:setSkipUpload(true)
            self.plugin.ui.tearing_down = true
            self.plugin.ui:onClose()
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
        self:showMsg(_("Unable to get file manager instance"))
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
    
    self:processSelectedFiles(is_upload, is_merge, selected_files)
end

function ManualSync:processSelectedFiles(is_upload, is_merge, selected_files)
    local DocSettings = require("docsettings")
    local ui = self.plugin.ui
    local books = {}
    
    for file, selected in pairs(selected_files) do
        if selected and lfs.attributes(file, "mode") == "file" then
            local metadata_file = DocSettings:findSidecarFile(file)
            
            local props = {}
            if ui and ui.bookinfo then
                props = ui.bookinfo:getDocProps(file, nil, true) or {}
            end
            local title = props.title or props.display_title
            local basename = file:match("([^/]+)$"):gsub("%.[^%.]+$", "")
            local author = props.authors
            if type(author) == "table" then
                author = author[1]
            end
            
            table.insert(books, {
                file = file,
                metadata = metadata_file,
                title = title or basename,
                book_basename = basename,
                author = author,
            })
        end
    end
    
    if #books == 0 then
        self:showMsg(_("No files selected"))
        return
    end
    
    local action_text = ""
    if is_upload then
        action_text = _("upload")
    else
        action_text = is_merge and _("download-merge") or _("download-overwrite")
    end
    
    UIManager:show(ConfirmBox:new{
        text = string.format(_("%s metadata for %d book(s)"), action_text, #books),
        ok_text = _("Continue"),
        cancel_text = _("Cancel"),
        ok_callback = function()
            self:doBatchSync(is_upload, is_merge, books)
        end
    })
end

function ManualSync:doBatchSync(is_upload, is_merge, selected_books)
    local remote = require("remote")
    local naming_mode = self.settings.metadata_naming_mode or "metadata"
    local sync_results = {
        type = "batch",
        success = {},
        failed = {}
    }
    
    local total = #selected_books
    local completed = 0
    local index = 1
    
    -- 直接创建进度条
    local title = is_upload and _("Uploading metadata...") or _("Downloading metadata...")
    local progress_dialog = ProgressbarDialog:new{
        title = title,
        subtitle = string.format("%d book(s)", total),
        progress = 0,
        progress_max = total,
        refresh_time_seconds = 0.1
    }
    if progress_dialog.progress_bar then
        progress_dialog.progress_bar.fillcolor = blitbuffer.COLOR_BLACK
    end
    progress_dialog:show()
    
    local function process_next()
        if index > total then
            progress_dialog:close()
            
            self:writeBatchLog(sync_results, is_upload, is_merge)
            
            local msg = ""
            if is_upload then
                msg = string.format(_("Metadata upload completed: %d success, %d failed"), #sync_results.success, #sync_results.failed)
            else
                local mode_text = is_merge and _("Merge") or _("Overwrite")
                msg = string.format(_("Metadata download completed (%s): %d success, %d failed"), mode_text, #sync_results.success, #sync_results.failed)
            end
            
            UIManager:show(Notification:new{
                text = msg,
                timeout = 2
            })
            
            local sync_type = ""
            if is_upload then
                sync_type = _("Metadata sync") .. "-" .. _("Batch upload") .. "-" .. _("Overwrite cloud")
            else
                sync_type = is_merge and (_("Metadata sync") .. "-" .. _("Batch download") .. "-" .. _("Merge")) or (_("Metadata sync") .. "-" .. _("Batch download") .. "-" .. _("Overwrite"))
            end
            self:updateLastSync(sync_type)
            
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
            return
        end
        
        local book = selected_books[index]
        index = index + 1
        
        UIManager:scheduleIn(0, function()
            if not book.metadata or not lfs.attributes(book.metadata, "mode") then
                table.insert(sync_results.failed, {
                    title = book.title,
                    file = book.file,
                    reason = _("Local metadata file not found"),
                    solution = _("Please open the book first to generate metadata file")
                })
            else
                local success, error_type = false, nil
                if is_upload then
                    success, error_type = remote.upload_book(book, naming_mode)
                else
                    if is_merge then
                        success, error_type = remote.download_book_merge(book, naming_mode)
                    else
                        success, error_type = remote.download_book(book, naming_mode)
                    end
                end
                
                if success then
                    table.insert(sync_results.success, {
                        title = book.title,
                        file = book.file
                    })
                else
                    local error_info = remote.get_error_message(error_type, is_upload, naming_mode)
                    table.insert(sync_results.failed, {
                        title = book.title,
                        file = book.file,
                        reason = error_info.reason,
                        solution = error_info.solution
                    })
                end
            end
            
            completed = completed + 1
            progress_dialog:reportProgress(completed)
            UIManager:setDirty(progress_dialog, "ui")
            
            process_next()
        end)
    end
    
    process_next()
end

function ManualSync:writeSingleLog(book, is_upload, is_merge, success, error_reason)
    local timestamp = os.date("%Y-%m-%d %H:%M:%S")
    local log_path = utils.get_log_path()
    
    local device_name = utils.get_device_name()
    local device_id = utils.get_device_id()
    
    local operation_type = ""
    if is_upload then
        operation_type = _("Metadata sync") .. "-" .. _("Single upload") .. "-" .. _("Overwrite cloud")
    else
        operation_type = is_merge and (_("Metadata sync") .. "-" .. _("Single download") .. "-" .. _("Merge")) or (_("Metadata sync") .. "-" .. _("Single download") .. "-" .. _("Overwrite"))
    end
    
    local new_record = {}
    table.insert(new_record, utils.SEPARATOR_LINE)
    table.insert(new_record, string.format(_("Sync time: %s"), timestamp))
    table.insert(new_record, string.format(_("Device: %s"), device_name))
    table.insert(new_record, string.format(_("Device ID: %s"), device_id))
    table.insert(new_record, string.format(_("Operation type: %s"), operation_type))
    table.insert(new_record, utils.SEPARATOR_LINE)
    
    if success then
        table.insert(new_record, string.format(_("[Success] ✓ %s"), book.title or book.book_basename))
    else
        table.insert(new_record, string.format(_("[Failed] ✗ %s"), book.title or book.book_basename))
        table.insert(new_record, string.format(_("Reason: %s"), error_reason or _("Unknown error")))
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

function ManualSync:writeBatchLog(results, is_upload, is_merge)
    local timestamp = os.date("%Y-%m-%d %H:%M:%S")
    local log_path = utils.get_log_path()
    
    local device_name = utils.get_device_name()
    local device_id = utils.get_device_id()
    
    local operation_type = ""
    if is_upload then
        operation_type = _("Metadata sync") .. "-" .. _("Batch upload") .. "-" .. _("Overwrite cloud")
    else
        operation_type = is_merge and (_("Metadata sync") .. "-" .. _("Batch download") .. "-" .. _("Merge")) or (_("Metadata sync") .. "-" .. _("Batch download") .. "-" .. _("Overwrite"))
    end
    
    local failed_by_reason = {}
    for _, book in ipairs(results.failed) do
        local key = book.reason
        if not failed_by_reason[key] then
            failed_by_reason[key] = {
                solution = book.solution,
                books = {}
            }
        end
        table.insert(failed_by_reason[key].books, {
            title = book.title,
            file = book.file
        })
    end
    
    local new_record = {}
    table.insert(new_record, utils.SEPARATOR_LINE)
    table.insert(new_record, string.format(_("Sync time: %s"), timestamp))
    table.insert(new_record, string.format(_("Device: %s"), device_name))
    table.insert(new_record, string.format(_("Device ID: %s"), device_id))
    table.insert(new_record, string.format(_("Operation type: %s"), operation_type))
    table.insert(new_record, utils.SEPARATOR_LINE)
    
    table.insert(new_record, string.format(_("[Success] (%d books)"), #results.success))
    table.insert(new_record, string.rep("-", 40))
    if #results.success > 0 then
        for _, book in ipairs(results.success) do
            table.insert(new_record, string.format("  ✓ %s", book.title))
        end
    else
        table.insert(new_record, _("  None"))
    end
    table.insert(new_record, "")
    
    table.insert(new_record, string.format(_("[Failed] (%d books)"), #results.failed))
    table.insert(new_record, string.rep("-", 40))
    if #results.failed > 0 then
        local reason_index = 0
        for reason, info in pairs(failed_by_reason) do
            reason_index = reason_index + 1
            table.insert(new_record, string.format("\n" .. _("[Failure reason %d] %s"), reason_index, reason))
            table.insert(new_record, string.rep("~", 40))
            table.insert(new_record, string.format(_("Solution: %s"), info.solution or _("Please check network and configuration")))
            table.insert(new_record, "")
            table.insert(new_record, _("Failed books:"))
            for i, book in ipairs(info.books) do
                table.insert(new_record, string.format("  (%d) %s", i, book.title))
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
            local sync_log = require("sync_log")
            sync_log.sync_log(true)
        end)
    end
end

function ManualSync:showMsg(msg)
    local InfoMessage = require("ui/widget/infomessage")
    UIManager:show(InfoMessage:new{
        text = msg,
        timeout = 3,
    })
end

function ManualSync:updateLastSync(descriptor)
    self.settings.last_sync = os.date("%Y-%m-%d %H:%M:%S") .. " (" .. descriptor .. ")"
    G_reader_settings:saveSetting(self.plugin.plugin_id, self.settings)
end

return ManualSync
