---@class PrisePluginsManager
---Plugin manager for prise
local M = {}

---@type table<string, table> Normalized specs indexed by name
M.specs = {}

---@type table<string, table|boolean> Loaded plugins indexed by name
M.loaded = {}

---@type table<string, function[]> Hook handlers indexed by hook name
M.hooks = {}

---@type table<string, string[]> Plugin names indexed by trigger key
M.key_triggers = {}

---@type table<string, string[]> Plugin names indexed by trigger event
M.event_triggers = {}

---@type table? Reference to user's tiling config
M.user_config = nil

---@type table<string, boolean> Plugins currently being loaded (to prevent duplicate loads)
M.loading = {}

---@type table<string, function[]> Pending callbacks for plugins currently being loaded
M.pending_callbacks = {}

---@type string[] Names of remote plugins queued for loading when event loop is ready
M.deferred_loads = {}

---Check if a table contains a value
---@param tbl table
---@param val any
---@return boolean
local function tbl_contains(tbl, val)
    for _, v in ipairs(tbl) do
        if v == val then
            return true
        end
    end
    return false
end

---Check if a path is a local filesystem path
---@param path string
---@return boolean
local function is_local_path(path)
    return path:match("^/") ~= nil
        or path:match("^%./") ~= nil
        or path:match("^%.%./") ~= nil
        or path:match("^~") ~= nil
end

---Expand ~ to home directory
---@param path string
---@return string
local function expand_path(path)
    if path:match("^~") then
        local home = os.getenv("HOME")
        if home then
            return home .. path:sub(2)
        end
    end
    return path
end

---Get the base name from a path
---@param path string
---@return string
local function basename(path)
    return path:match("([^/]+)/?$") or path
end

---Normalize a plugin spec into a consistent format
---@param spec PrisePluginSpec
---@return table
local function normalize_spec(spec)
    local source = spec[1]
    assert(type(source) == "string", "plugin[1] must be 'user/repo' or path string")

    local events = spec.event
    if type(events) == "string" then
        events = { events }
    end
    events = events or {}

    local keys = spec.keys
    if type(keys) == "string" then
        keys = { keys }
    end
    keys = keys or {}

    if is_local_path(source) then
        local expanded = expand_path(source)
        local name = spec.name or basename(expanded)
        return {
            source = source,
            dir = expanded,
            is_local = true,
            name = name,
            enabled = spec.enabled,
            lazy = spec.lazy ~= false,
            event = events,
            keys = keys,
            opts = spec.opts or {},
            config = spec.config,
        }
    end

    local user, repo_name = source:match("^([^/]+)/([^/]+)$")
    if not user or not repo_name then
        error("Invalid plugin spec: '" .. source .. "' must be 'user/repo' or a local path")
    end

    local name = spec.name or repo_name

    return {
        source = source,
        repo = source,
        user = user,
        repo_name = repo_name,
        is_local = false,
        name = name,
        branch = spec.branch or "HEAD",
        enabled = spec.enabled,
        lazy = spec.lazy ~= false,
        event = events,
        keys = keys,
        opts = spec.opts or {},
        config = spec.config,
    }
end

---Check if a plugin is enabled
---@param spec table Normalized spec
---@return boolean
local function is_enabled(spec)
    if spec.enabled == nil then
        return true
    end
    if type(spec.enabled) == "boolean" then
        return spec.enabled
    end
    return spec.enabled()
end

---Initialize plugin manager with specs
---@param raw_specs PrisePluginSpec[]?
---@param user_cfg table? Reference to user's config for plugins that need it
function M.setup(raw_specs, user_cfg)
    M.user_config = user_cfg

    if not raw_specs then
        return
    end

    for _, raw in ipairs(raw_specs) do
        local ok, spec_or_err = pcall(normalize_spec, raw)
        if not ok then
            print("[prise.plugins] invalid spec: " .. tostring(spec_or_err))
        else
            local spec = spec_or_err
            M.specs[spec.name] = spec

            for _, key in ipairs(spec.keys) do
                M.key_triggers[key] = M.key_triggers[key] or {}
                if not tbl_contains(M.key_triggers[key], spec.name) then
                    table.insert(M.key_triggers[key], spec.name)
                end
            end

            for _, event in ipairs(spec.event) do
                M.event_triggers[event] = M.event_triggers[event] or {}
                if not tbl_contains(M.event_triggers[event], spec.name) then
                    table.insert(M.event_triggers[event], spec.name)
                end
            end

            if not spec.lazy then
                if spec.is_local then
                    M.load(spec.name)
                else
                    table.insert(M.deferred_loads, spec.name)
                end
            end
        end
    end
end

---Load all deferred remote plugins (call this when event loop is ready)
function M.load_deferred()
    local to_load = M.deferred_loads
    M.deferred_loads = {}
    for _, name in ipairs(to_load) do
        M.load(name)
    end
end

---Update plugin status in the UI modal
---@param name string Plugin name
---@param status "cloning"|"updating"|"done"|"error"
---@param message? string Optional message
local function set_status(name, status, message)
    local ok, tiling = pcall(require, "prise_tiling_ui")
    if ok and tiling.set_plugin_status then
        tiling.set_plugin_status(name, status, message)
    end
end

---Get plugin directory path (async for remote plugins)
---For local plugins, calls callback immediately with dir
---For remote plugins, calls prise.ensure_plugin which calls back when done
---@param spec table Normalized spec
---@param callback fun(dir: string?, err: string?)
local function get_plugin_dir(spec, callback)
    if spec.is_local then
        callback(spec.dir, nil)
        return
    end

    local prise = require("prise")
    if prise.ensure_plugin then
        set_status(spec.name, "cloning")
        prise.ensure_plugin(spec.repo, spec.branch, function(dir, err, operation)
            if dir then
                if operation == "update" then
                    set_status(spec.name, "updating")
                else
                    set_status(spec.name, "cloning")
                end
                set_status(spec.name, "done")
            else
                set_status(spec.name, "error", tostring(err))
            end
            callback(dir, err)
        end)
    else
        callback(nil, "ensure_plugin not available")
    end
end

---Add plugin lua paths to package.path
---@param dir string Plugin directory
local function add_plugin_paths(dir)
    local lua_path = dir .. "/lua/?.lua;" .. dir .. "/lua/?/init.lua"
    if not package.path:find(lua_path, 1, true) then
        package.path = lua_path .. ";" .. package.path
    end
end

---Finish loading a plugin after its directory is available
---@param name string Plugin name
---@param spec table Normalized spec
---@param dir string Plugin directory
---@return table|nil plugin The loaded plugin module or nil
local function finish_load(name, spec, dir)
    add_plugin_paths(dir)

    local ok, plugin_or_err = pcall(require, spec.name)
    if not ok then
        set_status(name, "error", "load failed")
        M.loaded[name] = false
        M.loading[name] = nil
        return nil
    end

    ---@type table|nil
    local plugin = plugin_or_err
    M.loaded[name] = plugin or true
    M.loading[name] = nil

    if type(spec.config) == "function" then
        local config_ok, config_err = pcall(spec.config, plugin, spec.opts, M.user_config)
        if not config_ok then
            set_status(name, "error", tostring(config_err))
        end
    elseif plugin and type(plugin.setup) == "function" then
        local setup_ok, setup_err = pcall(plugin.setup, spec.opts, M.user_config)
        if not setup_ok then
            set_status(name, "error", tostring(setup_err))
        end
    end

    -- Invalidate keybind matcher in case plugin modified keybinds
    local tiling_ok, tiling = pcall(require, "prise_tiling_ui")
    if tiling_ok and tiling.invalidate_keybinds then
        tiling.invalidate_keybinds()
    end

    M.emit("plugin_loaded", { name = name, plugin = plugin })

    return plugin
end

---Load a plugin by name (async for remote plugins)
---@param name string Plugin name
---@param callback? fun(plugin: table|nil) Optional callback when load completes
---@return table|nil plugin The loaded plugin module or nil (for already-loaded plugins)
function M.load(name, callback)
    if M.loaded[name] then
        ---@type table|nil
        local plugin = nil
        local loaded_val = M.loaded[name]
        if type(loaded_val) == "table" then
            plugin = loaded_val
        end
        if callback then
            callback(plugin)
        end
        return plugin
    end

    if M.loading[name] then
        if callback then
            M.pending_callbacks[name] = M.pending_callbacks[name] or {}
            table.insert(M.pending_callbacks[name], callback)
        end
        return nil
    end

    local spec = M.specs[name]
    if not spec then
        if callback then
            callback(nil)
        end
        return nil
    end

    if not is_enabled(spec) then
        M.loaded[name] = false
        if callback then
            callback(nil)
        end
        return nil
    end

    M.loading[name] = true

    get_plugin_dir(spec, function(dir, dir_err)
        local plugin = nil
        if dir then
            plugin = finish_load(name, spec, dir)
        else
            set_status(name, "error", dir_err)
            M.loaded[name] = false
            M.loading[name] = nil
        end

        if callback then
            callback(plugin)
        end
        local pending = M.pending_callbacks[name]
        if pending then
            M.pending_callbacks[name] = nil
            for _, cb in ipairs(pending) do
                cb(plugin)
            end
        end
    end)

    return nil
end

---Load all plugins triggered by a specific key
---@param key string The key string that was pressed
function M.load_for_key(key)
    local names = M.key_triggers[key]
    if not names then
        return
    end
    for _, name in ipairs(names) do
        M.load(name)
    end
end

---Load all plugins triggered by a specific event
---@param event_name string The event name
function M.load_for_event(event_name)
    local names = M.event_triggers[event_name]
    if names then
        for _, name in ipairs(names) do
            M.load(name)
        end
    end
end

---Register a hook handler
---@param hook_name string Name of the hook
---@param fn function Handler function
function M.on(hook_name, fn)
    assert(type(fn) == "function", "hook callback must be a function")
    M.hooks[hook_name] = M.hooks[hook_name] or {}
    table.insert(M.hooks[hook_name], fn)
end

---Remove a hook handler
---@param hook_name string Name of the hook
---@param fn function Handler function to remove
function M.off(hook_name, fn)
    local handlers = M.hooks[hook_name]
    if not handlers then
        return
    end
    for i, handler in ipairs(handlers) do
        if handler == fn then
            table.remove(handlers, i)
            return
        end
    end
end

---Emit a hook event to all registered handlers
---@param hook_name string Name of the hook
---@param payload table? Data to pass to handlers
function M.emit(hook_name, payload)
    local handlers = M.hooks[hook_name]
    if not handlers then
        return
    end
    for _, fn in ipairs(handlers) do
        local ok, err = pcall(fn, payload or {})
        if not ok then
            print("[prise.plugins] hook '" .. hook_name .. "' error: " .. tostring(err))
        end
    end
end

---Get list of all registered plugin names
---@return string[]
function M.list()
    local names = {}
    for name, _ in pairs(M.specs) do
        table.insert(names, name)
    end
    table.sort(names)
    return names
end

---Get info about a specific plugin
---@param name string Plugin name
---@return table? info Plugin info or nil if not found
function M.info(name)
    local spec = M.specs[name]
    if not spec then
        return nil
    end
    return {
        name = spec.name,
        source = spec.source,
        is_local = spec.is_local,
        dir = spec.dir,
        repo = spec.repo,
        branch = spec.branch,
        lazy = spec.lazy,
        loaded = M.loaded[name] ~= nil and M.loaded[name] ~= false,
        enabled = is_enabled(spec),
    }
end

---Check if a plugin is loaded
---@param name string Plugin name
---@return boolean
function M.is_loaded(name)
    return M.loaded[name] ~= nil and M.loaded[name] ~= false
end

---Get a loaded plugin module safely
---Returns nil if plugin is not loaded yet or failed to load
---@param name string Plugin name
---@return table? plugin The plugin module or nil
function M.get(name)
    local loaded = M.loaded[name]
    if loaded and type(loaded) == "table" then
        return loaded
    end
    return nil
end

return M
