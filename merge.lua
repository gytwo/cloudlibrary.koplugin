local logger = require("logger")
local lfs = require("libs/libkoreader-lfs")
local M = {}

-- 需要从云端覆盖的字段（同步数据）
local SYNC_FIELDS = {
    "annotations",      -- 标注（高亮、划线、笔记）
    "last_xpointer",    -- 阅读进度（EPUB）
    "last_page",        -- 阅读页码（PDF）
    "percent_finished", -- 阅读百分比
    "summary",          -- 阅读状态（已读完/阅读中/未读）
    "stats",            -- 统计信息（高亮数、笔记数）
    "bookmarks",        -- 书签
}

function M.merge(local_path, cloud_path)
    logger.info("CloudLibrary: 开始合并元数据")
    
    local local_data = M.load_metadata(local_path)
    local cloud_data = M.load_metadata(cloud_path)
    
    if not local_data and not cloud_data then
        logger.warn("CloudLibrary: 两个元数据文件都无法读取")
        return nil
    end
    
    if not local_data then
        logger.info("CloudLibrary: 本地元数据不存在，使用云端数据")
        return cloud_data
    end
    
    if not cloud_data then
        logger.info("CloudLibrary: 云端元数据不存在，保留本地数据")
        return nil
    end
    
    local local_anno_count = #(local_data.annotations or {})
    local cloud_anno_count = #(cloud_data.annotations or {})
    logger.info(string.format("CloudLibrary: 合并前 - 本地标注:%d, 云端标注:%d", 
        local_anno_count, cloud_anno_count))
    
    local_data.annotations = M.merge_annotations(
        local_data.annotations or {},
        cloud_data.annotations or {}
    )
    logger.info(string.format("CloudLibrary: 合并后标注总数:%d", #(local_data.annotations or {})))
    
    -- 排序函数
    local function get_sort_key(anno)
        -- EPUB：page 是字符串
        if type(anno.page) == "string" then
            local nums = {}
            for num in anno.page:gmatch("%d+") do
                table.insert(nums, string.format("%08d", tonumber(num)))
            end
            while #nums < 10 do
                table.insert(nums, "00000000")
            end
            return table.concat(nums, "|")
        end
        
        -- PDF：页码 + y坐标 + x坐标
        if type(anno.page) == "number" then
            local page = anno.page
            local y = 0
            local x = 0
            if anno.pos0 and type(anno.pos0) == "table" then
                y = anno.pos0.y or 0
                x = anno.pos0.x or 0
            end
            return string.format("pdf|%08d|%010.2f|%010.2f", page, y, x)
        end
        
        return ""
    end
    
    -- 按位置排序
    if local_data.annotations and #local_data.annotations > 0 then
        table.sort(local_data.annotations, function(a, b)
            return get_sort_key(a) < get_sort_key(b)
        end)
    end
    
    M.merge_progress(local_data, cloud_data)
    M.merge_stats(local_data, cloud_data)
    M.merge_summary(local_data, cloud_data)
    
    local_data.last_merged = os.date("%Y-%m-%d %H:%M:%S")
    
    logger.info("CloudLibrary: 合并完成")
    return local_data
end

-- 覆盖合并：以本地为基础，用云端数据覆盖同步字段
function M.override_merge(local_path, cloud_path)
    logger.info("CloudLibrary: 开始覆盖合并（保留本地设置，替换同步数据）")
    
    local local_data = M.load_metadata(local_path)
    local cloud_data = M.load_metadata(cloud_path)
    
    if not cloud_data then
        logger.warn("CloudLibrary: 云端元数据不存在")
        return nil
    end
    
    if not local_data then
        logger.info("CloudLibrary: 本地元数据不存在，直接使用云端数据")
        return cloud_data
    end
    
    -- 以本地数据为基础
    local result = local_data
    
    -- 用云端数据覆盖同步字段
    local covered_count = 0
    for _, field in ipairs(SYNC_FIELDS) do
        if cloud_data[field] ~= nil then
            result[field] = cloud_data[field]
            covered_count = covered_count + 1
            logger.info("CloudLibrary: 覆盖字段: " .. field)
        end
    end
    
    -- 重新统计（基于新的标注）
    M.merge_stats(result, {})
    
    logger.info(string.format("CloudLibrary: 覆盖合并完成，共覆盖 %d 个字段", covered_count))
    return result
end

function M.load_metadata(path)
    local f = io.open(path, "r")
    if not f then 
        logger.warn("CloudLibrary: 无法打开文件: " .. path)
        return nil 
    end
    
    local content = f:read("*all")
    f:close()
    
    content = content:gsub("^\239\187\191", "")
    
    local func, err = load(content, "metadata")
    if not func then
        logger.err("CloudLibrary: 加载失败: " .. tostring(err))
        return nil
    end
    
    local ok, result = pcall(func)
    if not ok or type(result) ~= "table" then
        logger.err("CloudLibrary: 执行失败: " .. tostring(result))
        return nil
    end
    
    return result
end

function M.save_metadata(path, data, target_path)
    local lines = {}
    local comment_path = target_path or path
    table.insert(lines, string.format("-- %s", comment_path))
    table.insert(lines, "return {")
    
    local dump = require("dump")
    
    if data.annotations and #data.annotations > 0 then
        table.insert(lines, '    ["annotations"] = {')
        for i, anno in ipairs(data.annotations) do
            table.insert(lines, '        [' .. i .. '] = {')
            for ak, av in pairs(anno) do
                local value
                if type(av) == "string" then
                    value = string.format("%q", av)
                elseif type(av) == "number" then
                    value = tostring(av)
                elseif type(av) == "boolean" then
                    value = av and "true" or "false"
                elseif type(av) == "table" then
                    local table_str = dump(av, nil, true)
                    table_str = table_str:gsub("^return ", ""):gsub("\n$", "")
                    table_str = table_str:gsub("\n", "\n            ")
                    value = table_str
                else
                    value = "nil"
                end
                table.insert(lines, string.format('            ["%s"] = %s,', ak, value))
            end
            table.insert(lines, '        },')
        end
        table.insert(lines, '    },')
    end
    
    for k, v in pairs(data) do
        if k ~= "annotations" then
            if type(v) == "string" then
                table.insert(lines, string.format('    ["%s"] = %q,', k, v))
            elseif type(v) == "number" then
                table.insert(lines, string.format('    ["%s"] = %s,', k, tostring(v)))
            elseif type(v) == "boolean" then
                table.insert(lines, string.format('    ["%s"] = %s,', k, v and "true" or "false"))
            elseif type(v) == "table" then
                local table_str = dump(v, nil, true)
                table_str = table_str:gsub("^return ", ""):gsub("\n$", "")
                table_str = table_str:gsub("\n", "\n    ")
                table.insert(lines, string.format('    ["%s"] = %s,', k, table_str))
            end
        end
    end
    
    table.insert(lines, "}")
    
    local tmp_path = path .. ".tmp"
    local f = io.open(tmp_path, "w")
    if not f then
        logger.err("CloudLibrary: 无法创建临时文件")
        return false
    end
    
    f:write(table.concat(lines, "\n"))
    f:close()
    
    local func, err = loadfile(tmp_path)
    if not func then
        logger.err("CloudLibrary: 生成的元数据无效: " .. tostring(err))
        os.remove(tmp_path)
        return false
    end
    
    os.rename(tmp_path, path)
    logger.info("CloudLibrary: 文件已保存: " .. path)
    return true
end

function M.merge_annotations(local_annos, cloud_annos)
    local merged = {}
    local key_map = {}
    
    local function get_time(anno)
        return anno.datetime_updated or anno.datetime or "0"
    end
    
    for _, anno in ipairs(local_annos) do
        local key = M.get_annotation_key(anno)
        if key then
            key_map[key] = {
                anno = anno,
                time = get_time(anno)
            }
        else
            table.insert(merged, anno)
        end
    end
    
    for _, anno in ipairs(cloud_annos) do
        local key = M.get_annotation_key(anno)
        local cloud_time = get_time(anno)
        
        if key then
            if not key_map[key] then
                key_map[key] = {
                    anno = anno,
                    time = cloud_time
                }
            else
                if cloud_time > key_map[key].time then
                    key_map[key].anno = anno
                    key_map[key].time = cloud_time
                end
            end
        else
            table.insert(merged, anno)
        end
    end
    
    for _, item in pairs(key_map) do
        table.insert(merged, item.anno)
    end
    
    return merged
end

function M.get_annotation_key(anno)
    if not anno then
        return nil
    end
    
    -- EPUB：page 是字符串
    if type(anno.page) == "string" then
        return anno.page
    end
    
    -- PDF 高亮：有 pos0，用坐标去重
    if anno.pos0 and type(anno.pos0) == "table" then
        return string.format("pdf|%d|%.2f|%.2f", 
            anno.pos0.page, anno.pos0.x, anno.pos0.y)
    end
    
    -- PDF 书签：没有 pos0，只有页码
    if type(anno.page) == "number" then
        return string.format("pdf|bookmark|%d", anno.page)
    end
    
    return nil
end

function M.merge_progress(local_data, cloud_data)
    local local_xp = local_data.last_xpointer or ""
    local cloud_xp = cloud_data.last_xpointer or ""
    
    if cloud_xp > local_xp then
        local_data.last_xpointer = cloud_data.last_xpointer
        local_data.last_page = cloud_data.last_page
        local_data.percent_finished = cloud_data.percent_finished
        logger.info("CloudLibrary: 进度使用云端（更靠后）")
    else
        logger.info("CloudLibrary: 进度保留本地（更靠后）")
    end
end

function M.merge_stats(local_data, cloud_data)
    local highlights = 0
    local notes = 0
    for _, anno in ipairs(local_data.annotations or {}) do
        if anno.drawer then
            if anno.note and anno.note ~= "" then
                notes = notes + 1
            else
                highlights = highlights + 1
            end
        end
    end
    
    if not local_data.stats then
        local_data.stats = {}
    end
    local_data.stats.highlights = highlights
    local_data.stats.notes = notes
end

function M.merge_summary(local_data, cloud_data)
    local summary = local_data.summary or {}
    local cloud_summary = cloud_data.summary or {}
    
    local priority = {
        ["complete"] = 3,
        ["reading"] = 2,
        ["new"] = 1,
    }
    
    local local_pri = priority[summary.status] or 0
    local cloud_pri = priority[cloud_summary.status] or 0
    
    if cloud_pri > local_pri then
        summary.status = cloud_summary.status
        if cloud_summary.modified then
            summary.modified = cloud_summary.modified
        end
        logger.info("CloudLibrary: 阅读状态使用云端")
    else
        logger.info("CloudLibrary: 阅读状态保留本地")
    end
    
    local_data.summary = summary
end

return M