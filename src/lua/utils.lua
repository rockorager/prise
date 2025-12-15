---@class Utils
local M = {}

---Check if a table looks like a keybind (has a 'key' field)
---@param t table
---@return boolean
function M.is_keybind(t)
    return t.key ~= nil
end

---Check if a table is a list/array (has numeric keys 1, 2, 3, ...)
---@param t table
---@return boolean
function M.is_array(t)
    local i = 0
    for _ in pairs(t) do
        i = i + 1
        if t[i] == nil then
            return false
        end
    end
    return i > 0
end

---Deep merge tables (source into target)
---@param target table
---@param source table
function M.deep_merge(target, source)
    for k, v in pairs(source) do
        if type(v) == "table" and type(target[k]) == "table" then
            M.deep_merge(target[k], v)
        else
            target[k] = v
        end
    end
end

---Merge config tables (source into target)
---Like deep_merge, but keybind tables and arrays are replaced entirely instead of merged
---@param target table
---@param source table
function M.merge_config(target, source)
    for k, v in pairs(source) do
        if type(v) == "table" and type(target[k]) == "table" and not M.is_keybind(v) and not M.is_array(v) then
            M.merge_config(target[k], v)
        else
            target[k] = v
        end
    end
end

return M
