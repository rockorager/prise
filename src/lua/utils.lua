local prise = require("prise")

---@class Utils
local M = {}

---Check if a table looks like a keybind (has a 'key' field)
---@param t table
---@return boolean
function M.is_keybind(t)
    return t.key ~= nil
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
---Like deep_merge, but keybind tables are replaced entirely instead of merged
---@param target table
---@param source table
function M.merge_config(target, source)
    for k, v in pairs(source) do
        if type(v) == "table" and type(target[k]) == "table" and not M.is_keybind(v) then
            M.merge_config(target[k], v)
        else
            target[k] = v
        end
    end
end

---Open a URL using the system's default handler
---Uses prise.open_url (Zig implementation) for security - no shell interpolation
---@param url string The URL to open
---@return boolean success Whether the command was started successfully
function M.open_url(url)
    if not url or url == "" then
        return false
    end
    return prise.open_url(url)
end

return M
