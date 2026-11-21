local logger = require("logger")
local lfs = require("libs/libkoreader-lfs")
local M = {}

local SYNC_FIELDS = {
    "annotations",
    "last_xpointer",
    "last_page",
    "percent_finished",
    "summary",
    "stats",
    "bookmarks",
}

function M.merge(local_path, cloud_path)
    local local_data = M.load_metadata(local_path)
    local cloud_data = M.load_metadata(cloud_path)
    
    if not local_data and not cloud_data then
        return nil
    end
    
    if not local_data then
        return cloud_data
    end
    
    if not cloud_data then
        return nil
    end
    
    local_data.annotations = M.merge_annotations(
        local_data.annotations or {},
        cloud_data.annotations or {}
    )
    
    local function get_sort_key(anno)
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
    
    if local_data.annotations and #local_data.annotations > 0 then
        table.sort(local_data.annotations, function(a, b)
            return get_sort_key(a) < get_sort_key(b)
        end)
    end
    
    M.merge_progress(local_data, cloud_data)
    M.merge_stats(local_data, cloud_data)
    M.merge_summary(local_data, cloud_data)
    
    local_data.last_merged = os.date("%Y-%m-%d %H:%M:%S")
    
    return local_data
end

function M.override_merge(local_path, cloud_path)
    local local_data = M.load_metadata(local_path)
    local cloud_data = M.load_metadata(cloud_path)
    
    if not cloud_data then
        return nil
    end
    
    if not local_data then
        return cloud_data
    end
    
    local result = local_data
    
    for _, field in ipairs(SYNC_FIELDS) do
        if cloud_data[field] ~= nil then
            result[field] = cloud_data[field]
        end
    end
    
    M.merge_stats(result, {})
    
    return result
end

function M.load_metadata(path)
    local f = io.open(path, "r")
    if not f then 
        return nil 
    end
    
    local content = f:read("*all")
    f:close()
    
    content = content:gsub("^\239\187\191", "")
    
    local func, err = load(content, "metadata")
    if not func then
        return nil
    end
    
    local ok, result = pcall(func)
    if not ok or type(result) ~= "table" then
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
        return false
    end
    
    f:write(table.concat(lines, "\n"))
    f:close()
    
    local func, err = loadfile(tmp_path)
    if not func then
        os.remove(tmp_path)
        return false
    end
    
    os.rename(tmp_path, path)
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
    
    if type(anno.page) == "string" then
        return anno.page
    end
    
    if anno.pos0 and type(anno.pos0) == "table" then
        return string.format("pdf|%d|%.2f|%.2f", 
            anno.pos0.page, anno.pos0.x, anno.pos0.y)
    end
    
    if type(anno.page) == "number" then
        return string.format("pdf|bookmark|%d", anno.page)
    end
    
    return nil
end

local function normalize_xpointer(xp)
    if not xp or xp == "" then
        return ""
    end
    -- 把路径里每一段数字（[13]、[9]、text().0 里的 0 等）都填成固定宽度
    return (xp:gsub("%d+", function(num)
        return string.format("%08d", tonumber(num))
    end))
end

function M.merge_progress(local_data, cloud_data)
    local local_xp = normalize_xpointer(local_data.last_xpointer)
    local cloud_xp = normalize_xpointer(cloud_data.last_xpointer)

    if cloud_xp > local_xp then
        local_data.last_xpointer = cloud_data.last_xpointer
        local_data.last_page = cloud_data.last_page
        local_data.percent_finished = cloud_data.percent_finished
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
    end
    
    local_data.summary = summary
end

return M