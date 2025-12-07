local prise = require("prise")

---@class Pane
---@field type "pane"
---@field id number
---@field pty userdata
---@field ratio? number

---@class Split
---@field type "split"
---@field split_id number
---@field direction "row"|"col"
---@field ratio? number
---@field children (Pane|Split)[]

---@alias Node Pane|Split

---@class Tab
---@field id integer
---@field title? string
---@field root? Node
---@field last_focused_id? number

---@class PaletteRegion
---@field start_y number
---@field end_y number
---@field index number

---@class PaletteState
---@field visible boolean
---@field input? userdata
---@field selected number
---@field scroll_offset number
---@field regions PaletteRegion[]
---@field palette_y number

---@class State
---@field tabs Tab[]
---@field active_tab integer
---@field next_tab_id integer
---@field focused_id? number
---@field zoomed_pane_id? number
---@field pending_command boolean
---@field timer? userdata
---@field pending_split? { direction: "row"|"col" }
---@field pending_new_tab? boolean
---@field next_split_id number
---@field palette PaletteState
---@field screen_cols number
---@field screen_rows number

---@class Command
---@field name string
---@field action fun()
---@field shortcut? string
---@field visible? fun(): boolean

-- Powerline symbols
local POWERLINE_SYMBOLS = {
    right_solid = "",
    right_thin = "",
    left_solid = "",
    left_thin = "",
}

---@class PriseTheme
---@field mode_normal? string Color for normal mode indicator
---@field mode_command? string Color for command mode indicator
---@field bg1? string Darkest background
---@field bg2? string Dark background
---@field bg3? string Medium background
---@field bg4? string Lighter background
---@field fg_bright? string Main text color
---@field fg_dim? string Secondary text color
---@field fg_dark? string Dark text (on light backgrounds)
---@field accent? string Accent color
---@field green? string Success/connected color
---@field yellow? string Warning color

---@class PriseStatusBarConfig
---@field enabled? boolean Show the status bar (default: true)

---@class PriseTabBarConfig
---@field show_single_tab? boolean Show tab bar even with one tab (default: false)

---@class PriseKeybind
---@field key string The key (e.g., "k", "p", "Enter")
---@field ctrl? boolean Require ctrl modifier
---@field alt? boolean Require alt modifier
---@field shift? boolean Require shift modifier
---@field super? boolean Require super/cmd modifier

---@class PriseKeybinds
---@field leader? PriseKeybind Key to enter command mode (default: super+k)
---@field palette? PriseKeybind Key to open command palette (default: super+p)

---@class PriseConfig
---@field theme? PriseTheme Color theme options
---@field status_bar? PriseStatusBarConfig Status bar options
---@field tab_bar? PriseTabBarConfig Tab bar options
---@field keybinds? PriseKeybinds Keybind configuration

-- Default configuration
---@type PriseConfig
local config = {
    theme = {
        -- Status bar backgrounds (left to right gradient)
        mode_normal = "#89b4fa", -- Blue - normal mode
        mode_command = "#f38ba8", -- Pink - command mode
        bg1 = "#1e1e2e", -- Darkest (mode section)
        bg2 = "#313244", -- Dark (title section)
        bg3 = "#45475a", -- Medium (info section)
        bg4 = "#585b70", -- Lighter (right sections)

        -- Text colors
        fg_bright = "#cdd6f4", -- Main text
        fg_dim = "#a6adc8", -- Secondary text
        fg_dark = "#1e1e2e", -- Dark text on light bg

        -- Accent colors
        accent = "#89b4fa", -- Blue accent
        green = "#a6e3a1", -- Success/connected
        yellow = "#f9e2af", -- Warning
    },
    status_bar = {
        enabled = true,
    },
    tab_bar = {
        show_single_tab = false,
    },
    keybinds = {
        leader = { key = "k", super = true },
        palette = { key = "p", super = true },
    },
}

---Deep merge tables (source into target)
---@param target table
---@param source table
local function deep_merge(target, source)
    for k, v in pairs(source) do
        if type(v) == "table" and type(target[k]) == "table" then
            deep_merge(target[k], v)
        else
            target[k] = v
        end
    end
end

-- Convenience alias for theme access
local THEME = config.theme

local state = {
    tabs = {},
    active_tab = 1,
    next_tab_id = 1,
    focused_id = nil,
    zoomed_pane_id = nil,
    app_focused = true,
    pending_command = false,
    timer = nil,
    pending_split = nil,
    pending_new_tab = false,
    next_split_id = 1,
    -- Command palette
    palette = {
        visible = false,
        input = nil, -- TextInput handle
        selected = 1,
        scroll_offset = 0,
        regions = {}, -- Click regions for items
        palette_y = 5, -- Y offset of the palette
    },
    -- Rename session prompt
    rename = {
        visible = false,
        input = nil, -- TextInput handle
    },
    -- Tab bar hit regions: array of {start_x, end_x, tab_index}
    tab_regions = {},
    -- Currently hovered tab index (nil if none)
    hovered_tab = nil,
    -- Screen dimensions
    screen_cols = 80,
    screen_rows = 24,
}

local M = {}

---Configure the default UI
---@param opts? PriseConfig Configuration options to merge
function M.setup(opts)
    if opts then
        deep_merge(config, opts)
    end
end

local RESIZE_STEP = 0.05 -- 5% step for keyboard resize
local PALETTE_WIDTH = 60 -- Total width of command palette
local PALETTE_INNER_WIDTH = 56 -- Inner width (PALETTE_WIDTH - 4 for padding)

---Check if a key event matches a keybind
---@param event_data table The event.data from a key_press event
---@param bind PriseKeybind The keybind to match against
---@return boolean
local function matches_keybind(event_data, bind)
    if event_data.key ~= bind.key then
        return false
    end
    if (bind.ctrl or false) ~= (event_data.ctrl or false) then
        return false
    end
    if (bind.alt or false) ~= (event_data.alt or false) then
        return false
    end
    if (bind.shift or false) ~= (event_data.shift or false) then
        return false
    end
    if (bind.super or false) ~= (event_data.super or false) then
        return false
    end
    return true
end

-- --- Helpers ---

---@param node? Node
---@return boolean
local function is_pane(node)
    return node and node.type == "pane"
end

---@param node? Node
---@return boolean
local function is_split(node)
    return node and node.type == "split"
end

---Get the currently active tab
---@return Tab?
local function get_active_tab()
    return state.tabs[state.active_tab]
end

---Get the root node of the active tab
---@return Node?
local function get_active_root()
    local tab = get_active_tab()
    return tab and tab.root or nil
end

---Forward declaration for find_node_path
local find_node_path

---Find which tab contains a pane by id
---@param pane_id number
---@return integer?, Tab?
local function find_tab_for_pane(pane_id)
    for i, tab in ipairs(state.tabs) do
        if find_node_path(tab.root, pane_id) then
            return i, tab
        end
    end
    return nil
end

---Collect all panes in a node tree
---@param node? Node
---@param acc? Pane[]
---@return Pane[]
local function collect_panes(node, acc)
    acc = acc or {}
    if not node then
        return acc
    end
    if is_pane(node) then
        table.insert(acc, node)
    elseif is_split(node) then
        for _, child in ipairs(node.children) do
            collect_panes(child, acc)
        end
    end
    return acc
end

---Returns a list of nodes from root to the target node [root, ..., target]
---@param current? Node
---@param target_id number
---@param path? Node[]
---@return Node[]?
find_node_path = function(current, target_id, path)
    path = path or {}
    if not current then
        return nil
    end

    table.insert(path, current)

    if is_pane(current) then
        if current.id == target_id then
            return path
        end
    elseif is_split(current) then
        for _, child in ipairs(current.children) do
            if find_node_path(child, target_id, path) then
                return path
            end
        end
    end

    -- Not found in this branch
    table.remove(path)
    return nil
end

---@param node? Node
---@return Pane?
local function get_first_leaf(node)
    if not node then
        return nil
    end
    if is_pane(node) then
        return node
    end
    if is_split(node) then
        return get_first_leaf(node.children[1])
    end
    return nil
end

---@param node? Node
---@return Pane?
local function get_last_leaf(node)
    if not node then
        return nil
    end
    if is_pane(node) then
        return node
    end
    if is_split(node) then
        return get_last_leaf(node.children[#node.children])
    end
    return nil
end

---Recursively insert a new pane relative to target_id
---@param node Node
---@param target_id number
---@param new_pane Pane
---@param direction "row"|"col"
---@return Node
local function insert_split_recursive(node, target_id, new_pane, direction)
    if is_pane(node) then
        if node.id == target_id then
            -- Found the target pane. Replace it with a split containing [node, new_pane]
            local split_ratio = node.ratio -- Inherit ratio from the pane being replaced
            node.ratio = nil -- Children start with nil (equal split)
            new_pane.ratio = nil
            local split_id = state.next_split_id
            state.next_split_id = state.next_split_id + 1
            return {
                type = "split",
                split_id = split_id,
                direction = direction,
                ratio = split_ratio,
                children = { node, new_pane },
            }
        else
            return node
        end
    elseif is_split(node) then
        for i, child in ipairs(node.children) do
            node.children[i] = insert_split_recursive(child, target_id, new_pane, direction)
        end
        return node
    end
    return node
end

---Recursively remove a pane and return: new_node, closest_sibling_id
---@param node Node
---@param id number
---@return Node?, number?
local function remove_pane_recursive(node, id)
    if is_pane(node) then
        if node.id == id then
            return nil, nil
        end -- Remove this pane
        return node, nil
    elseif is_split(node) then
        local new_children = {}
        local removed_index = nil
        local closest_id = nil

        for i, child in ipairs(node.children) do
            local res, sibling_from_below = remove_pane_recursive(child, id)

            if res then
                table.insert(new_children, res)
                if sibling_from_below then
                    closest_id = sibling_from_below
                end
            else
                -- This child was removed
                removed_index = i
                if sibling_from_below then
                    closest_id = sibling_from_below
                end
            end
        end

        -- If we found the removed node at this level, pick a sibling
        if removed_index and not closest_id then
            -- Try right sibling first (if exists), then left
            if removed_index < #node.children then
                local neighbor = node.children[removed_index + 1]
                local leaf = get_first_leaf(neighbor)
                if leaf then
                    closest_id = leaf.id
                end
            elseif removed_index > 1 then
                local neighbor = node.children[removed_index - 1]
                local leaf = get_last_leaf(neighbor)
                if leaf then
                    closest_id = leaf.id
                end
            end
        end

        if #new_children == 0 then
            return nil, closest_id
        end

        -- If only one child remains, promote it
        if #new_children == 1 then
            local survivor = new_children[1]
            survivor.ratio = node.ratio -- Inherit ratio from parent
            return survivor, closest_id
        end

        node.children = new_children
        return node, closest_id
    end
    return nil, nil
end

---@return userdata?
local function get_focused_pty()
    local root = get_active_root()
    if not state.focused_id or not root then
        return nil
    end
    local path = find_node_path(root, state.focused_id)
    if path then
        return path[#path].pty
    end
    return nil
end

local function update_pty_focus(old_id, new_id)
    if old_id == new_id then
        return
    end
    if old_id then
        local _, old_tab = find_tab_for_pane(old_id)
        if old_tab then
            local old_path = find_node_path(old_tab.root, old_id)
            if old_path then
                old_path[#old_path].pty:set_focus(false)
            end
        end
    end
    if new_id and state.app_focused then
        local _, new_tab = find_tab_for_pane(new_id)
        if new_tab then
            local new_path = find_node_path(new_tab.root, new_id)
            if new_path then
                new_path[#new_path].pty:set_focus(true)
            end
        end
    end
end

---Switch to a different tab by index
---@param new_index integer
local function set_active_tab_index(new_index)
    if new_index < 1 or new_index > #state.tabs then
        return
    end
    if new_index == state.active_tab then
        return
    end

    -- Clear zoom when switching tabs
    state.zoomed_pane_id = nil

    local old_tab = state.tabs[state.active_tab]
    local old_focused = state.focused_id

    -- Remember focus in old tab
    if old_tab then
        old_tab.last_focused_id = state.focused_id
    end

    state.active_tab = new_index
    local new_tab = state.tabs[new_index]
    if not new_tab then
        return
    end

    -- Pick new focused pane in this tab
    local new_focus_id = new_tab.last_focused_id
    if not new_focus_id or not find_node_path(new_tab.root, new_focus_id) then
        local first_pane = get_first_leaf(new_tab.root)
        new_focus_id = first_pane and first_pane.id or nil
    end

    state.focused_id = new_focus_id
    update_pty_focus(old_focused, new_focus_id)
    prise.request_frame()
end

---Close the current tab
local function close_current_tab()
    if #state.tabs == 0 then
        return
    end

    local idx = state.active_tab
    local tab = state.tabs[idx]
    if not tab then
        return
    end

    -- If this is the last tab, quit the app
    if #state.tabs == 1 then
        local panes = collect_panes(tab.root, {})
        for _, pane in ipairs(panes) do
            if pane.pty and pane.pty.close then
                pane.pty:close()
            end
        end
        prise.detach(prise.get_session_name())
        return
    end

    -- Close all PTYs in this tab
    local panes = collect_panes(tab.root, {})
    for _, pane in ipairs(panes) do
        if pane.pty and pane.pty.close then
            pane.pty:close()
        end
    end

    local old_focused = state.focused_id
    table.remove(state.tabs, idx)

    -- Pick new active tab index
    if idx > #state.tabs then
        idx = #state.tabs
    end
    state.active_tab = idx > 0 and idx or 1

    local new_tab = state.tabs[state.active_tab]
    if new_tab then
        -- Choose focused pane in new tab
        local new_focus_id = new_tab.last_focused_id
        if not new_focus_id or not find_node_path(new_tab.root, new_focus_id) then
            local first_pane = get_first_leaf(new_tab.root)
            new_focus_id = first_pane and first_pane.id or nil
        end
        state.focused_id = new_focus_id
        update_pty_focus(old_focused, new_focus_id)
    else
        -- No tabs left
        state.focused_id = nil
    end

    prise.request_frame()
    prise.save()
end

---Remove a pane by id from the appropriate tab
---@param id number
---@return boolean was_last True if this was the last pane in the last tab (app will quit)
local function remove_pane_by_id(id)
    local tab_idx, tab = find_tab_for_pane(id)
    if not tab then
        return false
    end

    -- Clear zoom if the zoomed pane is being removed
    if state.zoomed_pane_id == id then
        state.zoomed_pane_id = nil
    end

    local new_root, next_focus = remove_pane_recursive(tab.root, id)
    tab.root = new_root

    if not tab.root then
        -- Tab is now empty, remove it
        if #state.tabs == 1 then
            table.remove(state.tabs, tab_idx)
            prise.exit()
            return true
        else
            local old_focused = state.focused_id
            table.remove(state.tabs, tab_idx)

            -- Adjust active_tab if needed
            if state.active_tab > #state.tabs then
                state.active_tab = #state.tabs
            end
            if state.active_tab < 1 then
                state.active_tab = 1
            end

            -- Update focus to new active tab
            local new_tab = state.tabs[state.active_tab]
            if new_tab then
                local new_focus_id = new_tab.last_focused_id
                if not new_focus_id or not find_node_path(new_tab.root, new_focus_id) then
                    local first_pane = get_first_leaf(new_tab.root)
                    new_focus_id = first_pane and first_pane.id or nil
                end
                state.focused_id = new_focus_id
                update_pty_focus(old_focused, new_focus_id)
            end
            prise.request_frame()
            return false
        end
    else
        -- Tab still has panes
        if state.focused_id == id then
            local old_id = state.focused_id
            if next_focus then
                state.focused_id = next_focus
            else
                local first = get_first_leaf(tab.root)
                if first then
                    state.focused_id = first.id
                end
            end
            update_pty_focus(old_id, state.focused_id)
        end
        prise.request_frame()
        return false
    end
end

---Count all panes in the tree
---@param node? Node
---@return number
local function count_panes(node)
    if not node then
        return 0
    end
    if is_pane(node) then
        return 1
    end
    if is_split(node) then
        local count = 0
        for _, child in ipairs(node.children) do
            count = count + count_panes(child)
        end
        return count
    end
    return 0
end

---Get index of focused pane (1-based) and total count in active tab
---@return number index
---@return number total
local function get_pane_position()
    local root = get_active_root()
    if not root or not state.focused_id then
        return 1, 1
    end

    local index = 0
    local found_index = 1

    local function walk(node)
        if is_pane(node) then
            index = index + 1
            if node.id == state.focused_id then
                found_index = index
            end
        elseif is_split(node) then
            for _, child in ipairs(node.children) do
                walk(child)
            end
        end
    end

    walk(root)
    return found_index, index
end

---Serialize a node tree to a table with pty_ids instead of userdata
---@param node? Node
---@return table?
local function serialize_node(node, cwd_lookup)
    if not node then
        return nil
    end
    if is_pane(node) then
        local pty_id = node.pty:id()
        local cwd = nil
        if cwd_lookup then
            cwd = cwd_lookup(pty_id)
        end
        return {
            type = "pane",
            id = node.id,
            pty_id = pty_id,
            cwd = cwd,
            ratio = node.ratio,
        }
    elseif is_split(node) then
        local children = {}
        for _, child in ipairs(node.children) do
            table.insert(children, serialize_node(child, cwd_lookup))
        end
        return {
            type = "split",
            split_id = node.split_id,
            direction = node.direction,
            ratio = node.ratio,
            children = children,
        }
    end
    return nil
end

---Deserialize a node tree, looking up PTYs by id
---@param saved? table
---@param pty_lookup fun(id: number): userdata?
---@return Node?
local function deserialize_node(saved, pty_lookup)
    if not saved then
        return nil
    end
    if saved.type == "pane" then
        local pty = pty_lookup(saved.pty_id)
        if not pty then
            return nil
        end
        return {
            type = "pane",
            id = saved.id,
            pty = pty,
            cwd = saved.cwd, -- Store cwd for spawn fallback
            ratio = saved.ratio,
        }
    elseif saved.type == "split" then
        local children = {}
        for _, child in ipairs(saved.children) do
            local restored = deserialize_node(child, pty_lookup)
            if restored then
                table.insert(children, restored)
            end
        end
        if #children == 0 then
            return nil
        elseif #children == 1 then
            local survivor = children[1]
            survivor.ratio = saved.ratio
            return survivor
        end
        return {
            type = "split",
            split_id = saved.split_id,
            direction = saved.direction,
            ratio = saved.ratio,
            children = children,
        }
    end
    return nil
end

---@param dimension "width"|"height"
---@param delta_ratio number
local function resize_pane(dimension, delta_ratio)
    local root = get_active_root()
    if not state.focused_id or not root then
        return
    end

    local path = find_node_path(root, state.focused_id)
    if not path then
        return
    end

    local target_split_dir = (dimension == "width") and "row" or "col"

    -- Traverse up to find a split of the correct direction
    local parent_split = nil
    local child_idx = nil
    local node = nil

    for i = #path - 1, 1, -1 do
        if path[i].type == "split" and path[i].direction == target_split_dir then
            parent_split = path[i]
            node = path[i + 1]

            -- Find index
            for k, c in ipairs(parent_split.children) do
                if c == node then
                    child_idx = k
                    break
                end
            end
            break
        end
    end

    if not parent_split or not child_idx then
        return
    end

    -- The first child's ratio controls the split position.
    -- "Resize left/right" moves the divider in that direction regardless of which pane is focused.
    local first_child = parent_split.children[1]
    local current_ratio = first_child.ratio or 0.5
    local new_ratio = current_ratio + delta_ratio

    -- Clamp to valid range
    if new_ratio < 0.1 then
        new_ratio = 0.1
    end
    if new_ratio > 0.9 then
        new_ratio = 0.9
    end

    first_child.ratio = new_ratio

    prise.request_frame()
end

---@param direction "left"|"right"|"up"|"down"
local function move_focus(direction)
    local root = get_active_root()
    if not state.focused_id or not root then
        return
    end

    local path = find_node_path(root, state.focused_id)
    if not path then
        return
    end

    -- "left"/"right" implies moving along "row"
    -- "up"/"down" implies moving along "col"
    local target_split_type = (direction == "left" or direction == "right") and "row" or "col"
    local forward = (direction == "right" or direction == "down")

    local sibling_node = nil

    -- Traverse up the path to find a split of the correct type where we can move
    -- path is [root, ..., parent, leaf]
    for i = #path - 1, 1, -1 do
        local node = path[i]
        local child = path[i + 1]

        if node.type == "split" and node.direction == target_split_type then
            -- Find index of child
            local idx = 0
            for k, c in ipairs(node.children) do
                if c == child then
                    idx = k
                    break
                end
            end

            if forward then
                if idx < #node.children then
                    sibling_node = node.children[idx + 1]
                    break
                end
            else
                if idx > 1 then
                    sibling_node = node.children[idx - 1]
                    break
                end
            end
        end
    end

    if sibling_node then
        -- Found a sibling tree/pane. Find the closest leaf.
        local target_leaf
        if forward then
            target_leaf = get_first_leaf(sibling_node)
        else
            target_leaf = get_last_leaf(sibling_node)
        end

        if target_leaf and target_leaf.id ~= state.focused_id then
            local old_id = state.focused_id
            state.focused_id = target_leaf.id
            update_pty_focus(old_id, state.focused_id)
            prise.request_frame()
        end
    end
end

-- Platform-dependent key prefix for shortcuts
local key_prefix = prise.platform == "macos" and "󰘳 +k" or "Super+k"

---Command palette commands
---@type Command[]
local commands = {
    {
        name = "Split Horizontal",
        shortcut = key_prefix .. " v",
        action = function()
            local pty = get_focused_pty()
            state.pending_split = { direction = "row" }
            prise.spawn({ cwd = pty and pty:cwd() })
        end,
    },
    {
        name = "Split Vertical",
        shortcut = key_prefix .. " s",
        action = function()
            local pty = get_focused_pty()
            state.pending_split = { direction = "col" }
            prise.spawn({ cwd = pty and pty:cwd() })
        end,
    },
    {
        name = "Split Auto",
        shortcut = key_prefix .. " Enter",
        action = function()
            local pty = get_focused_pty()
            if pty then
                local size = pty:size()
                if size.cols > (size.rows * 2.2) then
                    state.pending_split = { direction = "row" }
                else
                    state.pending_split = { direction = "col" }
                end
                prise.spawn({ cwd = pty:cwd() })
            end
        end,
    },
    {
        name = "Focus Left",
        shortcut = key_prefix .. " h",
        action = function()
            move_focus("left")
        end,
    },
    {
        name = "Focus Right",
        shortcut = key_prefix .. " l",
        action = function()
            move_focus("right")
        end,
    },
    {
        name = "Focus Up",
        shortcut = key_prefix .. " k",
        action = function()
            move_focus("up")
        end,
    },
    {
        name = "Focus Down",
        shortcut = key_prefix .. " j",
        action = function()
            move_focus("down")
        end,
    },
    {
        name = "Close Pane",
        shortcut = key_prefix .. " w",
        action = function()
            local root = get_active_root()
            local path = state.focused_id and find_node_path(root, state.focused_id)
            if path then
                local pane = path[#path]
                pane.pty:close()
                local was_last = remove_pane_by_id(pane.id)
                if not was_last then
                    prise.save()
                end
            end
        end,
    },
    {
        name = "Toggle Zoom",
        shortcut = key_prefix .. " z",
        action = function()
            if state.zoomed_pane_id then
                state.zoomed_pane_id = nil
            elseif state.focused_id then
                state.zoomed_pane_id = state.focused_id
            end
            prise.request_frame()
        end,
    },
    {
        name = "New Tab",
        shortcut = key_prefix .. " t",
        action = function()
            local pty = get_focused_pty()
            state.pending_new_tab = true
            prise.spawn({ cwd = pty and pty:cwd() })
        end,
    },
    {
        name = "Close Tab",
        shortcut = key_prefix .. " c",
        action = function()
            close_current_tab()
        end,
    },
    {
        name = "Next Tab",
        shortcut = key_prefix .. " n",
        action = function()
            if #state.tabs > 1 then
                local next_idx = state.active_tab % #state.tabs + 1
                set_active_tab_index(next_idx)
            end
        end,
    },
    {
        name = "Previous Tab",
        shortcut = key_prefix .. " p",
        action = function()
            if #state.tabs > 1 then
                local prev_idx = (state.active_tab - 2 + #state.tabs) % #state.tabs + 1
                set_active_tab_index(prev_idx)
            end
        end,
    },
    {
        name = "Detach Session",
        shortcut = key_prefix .. " d",
        action = function()
            prise.detach(prise.get_session_name())
        end,
    },
    {
        name = "Rename Session",
        action = function()
            open_rename()
        end,
    },
    {
        name = "Quit",
        shortcut = key_prefix .. " q",
        action = function()
            prise.detach(prise.get_session_name())
        end,
    },
    {
        name = "Resize Left",
        shortcut = key_prefix .. " H",
        action = function()
            resize_pane("width", -RESIZE_STEP)
        end,
    },
    {
        name = "Resize Right",
        shortcut = key_prefix .. " L",
        action = function()
            resize_pane("width", RESIZE_STEP)
        end,
    },
    {
        name = "Resize Up",
        shortcut = key_prefix .. " K",
        action = function()
            resize_pane("height", -RESIZE_STEP)
        end,
    },
    {
        name = "Resize Down",
        shortcut = key_prefix .. " J",
        action = function()
            resize_pane("height", RESIZE_STEP)
        end,
    },
    {
        name = "Tab 1",
        shortcut = key_prefix .. " 1",
        action = function()
            set_active_tab_index(1)
        end,
        visible = function()
            return #state.tabs >= 1
        end,
    },
    {
        name = "Tab 2",
        shortcut = key_prefix .. " 2",
        action = function()
            set_active_tab_index(2)
        end,
        visible = function()
            return #state.tabs >= 2
        end,
    },
    {
        name = "Tab 3",
        shortcut = key_prefix .. " 3",
        action = function()
            set_active_tab_index(3)
        end,
        visible = function()
            return #state.tabs >= 3
        end,
    },
    {
        name = "Tab 4",
        shortcut = key_prefix .. " 4",
        action = function()
            set_active_tab_index(4)
        end,
        visible = function()
            return #state.tabs >= 4
        end,
    },
    {
        name = "Tab 5",
        shortcut = key_prefix .. " 5",
        action = function()
            set_active_tab_index(5)
        end,
        visible = function()
            return #state.tabs >= 5
        end,
    },
    {
        name = "Tab 6",
        shortcut = key_prefix .. " 6",
        action = function()
            set_active_tab_index(6)
        end,
        visible = function()
            return #state.tabs >= 6
        end,
    },
    {
        name = "Tab 7",
        shortcut = key_prefix .. " 7",
        action = function()
            set_active_tab_index(7)
        end,
        visible = function()
            return #state.tabs >= 7
        end,
    },
    {
        name = "Tab 8",
        shortcut = key_prefix .. " 8",
        action = function()
            set_active_tab_index(8)
        end,
        visible = function()
            return #state.tabs >= 8
        end,
    },
    {
        name = "Tab 9",
        shortcut = key_prefix .. " 9",
        action = function()
            set_active_tab_index(9)
        end,
        visible = function()
            return #state.tabs >= 9
        end,
    },
    {
        name = "Tab 10",
        shortcut = key_prefix .. " 0",
        action = function()
            set_active_tab_index(10)
        end,
        visible = function()
            return #state.tabs >= 10
        end,
    },
}

---@param query string
---@return Command[]
local function filter_commands(query)
    local results = {}
    for _, cmd in ipairs(commands) do
        local is_visible = not cmd.visible or cmd.visible()
        if is_visible then
            if not query or query == "" or cmd.name:lower():find(query:lower(), 1, true) then
                table.insert(results, cmd)
            end
        end
    end
    return results
end

local function open_palette()
    if not state.palette.input then
        state.palette.input = prise.create_text_input()
    end
    state.palette.visible = true
    state.palette.selected = 1
    state.palette.scroll_offset = 0
    state.palette.input:clear()
    prise.request_frame()
end

local function close_palette()
    state.palette.visible = false
    prise.request_frame()
end

local function execute_selected()
    local filtered = filter_commands(state.palette.input:text())
    if filtered[state.palette.selected] then
        close_palette()
        filtered[state.palette.selected].action()
    end
end

local function open_rename()
    if not state.rename.input then
        state.rename.input = prise.create_text_input()
    end
    local current_name = prise.get_session_name() or ""
    state.rename.input:clear()
    state.rename.input:insert(current_name)
    state.rename.visible = true
    prise.request_frame()
end

local function close_rename()
    state.rename.visible = false
    prise.request_frame()
end

local function execute_rename()
    local new_name = state.rename.input:text()
    if new_name and new_name ~= "" then
        prise.rename_session(new_name)
    end
    close_rename()
end

-- --- Main Functions ---

---@param event { type: string, data: table }
function M.update(event)
    if event.type == "pty_attach" then
        prise.log.info("Lua: pty_attach received")
        local pty = event.data.pty
        local new_pane = { type = "pane", pty = pty, id = pty:id() }
        local old_focused_id = state.focused_id

        if state.pending_new_tab then
            -- Create a new tab with this pane
            state.pending_new_tab = false
            local tab_id = state.next_tab_id
            state.next_tab_id = tab_id + 1
            local new_tab = {
                id = tab_id,
                root = new_pane,
                last_focused_id = new_pane.id,
            }
            table.insert(state.tabs, new_tab)
            set_active_tab_index(#state.tabs)
        elseif #state.tabs == 0 then
            -- First terminal - create first tab
            local tab_id = state.next_tab_id
            state.next_tab_id = tab_id + 1
            local new_tab = {
                id = tab_id,
                root = new_pane,
                last_focused_id = new_pane.id,
            }
            table.insert(state.tabs, new_tab)
            state.active_tab = 1
            state.focused_id = new_pane.id
        else
            -- Insert into active tab's tree
            local tab = get_active_tab()
            if not tab then
                return
            end

            local direction = (state.pending_split and state.pending_split.direction) or "row"

            if state.focused_id then
                tab.root = insert_split_recursive(tab.root, state.focused_id, new_pane, direction)
            else
                -- Fallback
                if is_split(tab.root) then
                    table.insert(tab.root.children, new_pane)
                else
                    local split_id = state.next_split_id
                    state.next_split_id = state.next_split_id + 1
                    tab.root = {
                        type = "split",
                        split_id = split_id,
                        direction = direction,
                        children = { tab.root, new_pane },
                    }
                end
            end

            state.focused_id = new_pane.id
            state.pending_split = nil
        end
        update_pty_focus(old_focused_id, state.focused_id)
        prise.request_frame()
        prise.save() -- Auto-save on pane added
    elseif event.type == "key_press" then
        -- Handle command palette
        if state.palette.visible then
            local k = event.data.key
            local filtered = filter_commands(state.palette.input:text())

            prise.log.debug(
                "palette key: "
                    .. tostring(k)
                    .. " len="
                    .. #k
                    .. " ctrl="
                    .. tostring(event.data.ctrl)
                    .. " super="
                    .. tostring(event.data.super)
            )

            if k == "Escape" then
                close_palette()
                return
            elseif k == "Enter" then
                execute_selected()
                return
            elseif k == "ArrowUp" or (k == "k" and event.data.ctrl) then
                if state.palette.selected > 1 then
                    state.palette.selected = state.palette.selected - 1
                    prise.request_frame()
                end
                return
            elseif k == "ArrowDown" or (k == "j" and event.data.ctrl) then
                if state.palette.selected < #filtered then
                    state.palette.selected = state.palette.selected + 1
                    prise.request_frame()
                end
                return
            elseif k == "Backspace" then
                state.palette.input:delete_backward()
                state.palette.selected = 1
                prise.request_frame()
                return
            elseif #k == 1 and not event.data.ctrl and not event.data.alt and not event.data.super then
                state.palette.input:insert(k)
                state.palette.selected = 1
                prise.request_frame()
                return
            end
            return
        end

        -- Handle rename session prompt
        if state.rename.visible then
            local k = event.data.key

            if k == "Escape" then
                close_rename()
                return
            elseif k == "Enter" then
                execute_rename()
                return
            elseif k == "Backspace" then
                state.rename.input:delete_backward()
                prise.request_frame()
                return
            elseif #k == 1 and not event.data.ctrl and not event.data.alt and not event.data.super then
                state.rename.input:insert(k)
                prise.request_frame()
                return
            end
            return
        end

        -- Open command palette
        if matches_keybind(event.data, config.keybinds.palette) then
            open_palette()
            return
        end

        -- Handle pending command mode (after Super/Cmd+k)
        if state.pending_command then
            local handled = false
            local k = event.data.key

            if k == "h" then
                move_focus("left")
                handled = true
            elseif k == "l" then
                move_focus("right")
                handled = true
            elseif k == "j" then
                move_focus("down")
                handled = true
            elseif k == "k" then
                move_focus("up")
                handled = true
            elseif k == "H" then
                resize_pane("width", -RESIZE_STEP)
                handled = true
            elseif k == "L" then
                resize_pane("width", RESIZE_STEP)
                handled = true
            elseif k == "J" then
                resize_pane("height", RESIZE_STEP)
                handled = true
            elseif k == "K" then
                resize_pane("height", -RESIZE_STEP)
                handled = true
            elseif k == "%" or k == "v" then
                -- Split horizontal (side-by-side)
                local pty = get_focused_pty()
                state.pending_split = { direction = "row" }
                prise.spawn({ cwd = pty and pty:cwd() })
                handled = true
            elseif k == '"' or k == "'" or k == "s" then
                -- Split vertical (top-bottom)
                local pty = get_focused_pty()
                state.pending_split = { direction = "col" }
                prise.spawn({ cwd = pty and pty:cwd() })
                handled = true
            elseif k == "d" then
                -- Detach from session
                prise.detach(prise.get_session_name())
                handled = true
            elseif k == "t" then
                -- New tab
                local pty = get_focused_pty()
                state.pending_new_tab = true
                prise.spawn({ cwd = pty and pty:cwd() })
                handled = true
            elseif k == "n" then
                -- Next tab
                if #state.tabs > 1 then
                    local next_idx = state.active_tab % #state.tabs + 1
                    set_active_tab_index(next_idx)
                end
                handled = true
            elseif k == "p" then
                -- Previous tab
                if #state.tabs > 1 then
                    local prev_idx = (state.active_tab - 2 + #state.tabs) % #state.tabs + 1
                    set_active_tab_index(prev_idx)
                end
                handled = true
            elseif k == "c" then
                -- Close current tab
                close_current_tab()
                handled = true
            elseif k >= "1" and k <= "9" then
                -- Switch to tab N
                local idx = tonumber(k)
                if idx and idx <= #state.tabs then
                    set_active_tab_index(idx)
                end
                handled = true
            elseif k == "0" then
                -- Switch to tab 10
                if 10 <= #state.tabs then
                    set_active_tab_index(10)
                end
                handled = true
            elseif k == "w" then
                -- Close current pane
                local root = get_active_root()
                local path = state.focused_id and find_node_path(root, state.focused_id)
                if path then
                    local pane = path[#path]
                    pane.pty:close()
                    local was_last = remove_pane_by_id(pane.id)
                    if not was_last then
                        prise.save()
                    end
                    handled = true
                end
            elseif k == "q" then
                -- Quit
                prise.detach(prise.get_session_name())
                handled = true
            elseif k == "z" then
                -- Toggle zoom
                if state.zoomed_pane_id then
                    state.zoomed_pane_id = nil
                elseif state.focused_id then
                    state.zoomed_pane_id = state.focused_id
                end
                handled = true
            elseif k == "Enter" or k == "\r" or k == "\n" then
                local pty = get_focused_pty()
                if pty then
                    local size = pty:size()
                    -- Account for cell aspect ratio (roughly 1:2)
                    -- Split along the longest visual axis
                    if size.cols > (size.rows * 2.2) then
                        state.pending_split = { direction = "row" }
                    else
                        state.pending_split = { direction = "col" }
                    end
                    prise.spawn({ cwd = pty:cwd() })
                    handled = true
                end
            end

            if handled then
                if state.timer then
                    state.timer:cancel()
                    state.timer = nil
                end
                state.pending_command = false
                prise.request_frame()
                return
            end

            -- Reset timeout
            if state.timer then
                state.timer:cancel()
            end
            state.timer = prise.set_timeout(1000, function()
                if state.pending_command then
                    state.pending_command = false
                    state.timer = nil
                    prise.request_frame()
                end
            end)
            return
        end

        -- Enter command mode (leader key)
        if matches_keybind(event.data, config.keybinds.leader) then
            state.pending_command = true
            prise.request_frame()
            state.timer = prise.set_timeout(1000, function()
                if state.pending_command then
                    state.pending_command = false
                    state.timer = nil
                    prise.request_frame()
                end
            end)
            return
        end

        -- Copy selection: Cmd+c (macOS) or Ctrl+Shift+c (Linux)
        if event.data.key == "c" then
            local is_copy = false
            if prise.platform == "macos" then
                is_copy = event.data.super and not event.data.ctrl and not event.data.alt
            else
                is_copy = event.data.ctrl and event.data.shift and not event.data.super
            end
            if is_copy then
                local pty = get_focused_pty()
                if pty then
                    pty:copy_selection()
                end
                return
            end
        end

        -- Pass key to focused PTY
        local root = get_active_root()
        if root and state.focused_id then
            local path = find_node_path(root, state.focused_id)
            if path then
                local pane = path[#path]
                pane.pty:send_key(event.data)
            end
        end
    elseif event.type == "key_release" then
        -- Forward all key releases to focused PTY
        local root = get_active_root()
        if root and state.focused_id then
            local path = find_node_path(root, state.focused_id)
            if path then
                local pane = path[#path]
                local data = event.data
                data.release = true
                pane.pty:send_key(data)
            end
        end
    elseif event.type == "paste" then
        if state.palette.visible then
            -- Insert into command palette, replacing newlines/tabs with spaces
            local text = event.data.text:gsub("[\r\n\t]", " ")
            state.palette.input:insert(text)
            state.palette.selected = 1
            prise.request_frame()
        else
            local root = get_active_root()
            if root and state.focused_id then
                -- Forward paste to focused PTY
                local path = find_node_path(root, state.focused_id)
                if path then
                    local pane = path[#path]
                    pane.pty:send_paste(event.data.text)
                end
            end
        end
    elseif event.type == "pty_exited" then
        local id = event.data.id
        prise.log.info("Lua: pty_exited " .. id)
        local was_last = remove_pane_by_id(id)
        if not was_last then
            prise.save()
        end
    elseif event.type == "mouse" then
        local d = event.data

        -- Track tab hover state on motion
        if d.action == "motion" and #state.tab_regions > 0 then
            local new_hover = nil
            if d.y < 1 then
                for _, region in ipairs(state.tab_regions) do
                    if d.x >= region.start_x and d.x < region.end_x then
                        new_hover = region.tab_index
                        break
                    end
                end
            end
            if new_hover ~= state.hovered_tab then
                state.hovered_tab = new_hover
                prise.request_frame()
            end
        end

        if d.action == "press" and d.button == "left" then
            -- Check if click is on command palette item
            if state.palette.visible and #state.palette.regions > 0 then
                -- Convert float coords to integer cell positions
                local click_x = math.floor(d.x)
                local click_y = math.floor(d.y)

                local palette_start_x = math.floor((state.screen_cols - PALETTE_WIDTH) / 2)
                local palette_end_x = palette_start_x + PALETTE_WIDTH

                if click_x >= palette_start_x and click_x < palette_end_x then
                    for _, region in ipairs(state.palette.regions) do
                        if click_y >= region.start_y and click_y < region.end_y then
                            if state.palette.selected == region.index then
                                -- Already selected, execute it
                                execute_selected()
                            else
                                -- First click, just highlight it
                                state.palette.selected = region.index
                                prise.request_frame()
                            end
                            return
                        end
                    end
                end
            end

            -- Check if click is on tab bar (y < 1 and we have tab regions)
            if d.y < 1 and #state.tab_regions > 0 then
                for _, region in ipairs(state.tab_regions) do
                    if d.x >= region.start_x and d.x < region.end_x then
                        set_active_tab_index(region.tab_index)
                        return
                    end
                end
            end

            -- Focus the clicked pane
            if d.target and d.target ~= state.focused_id then
                local old_id = state.focused_id
                state.focused_id = d.target
                update_pty_focus(old_id, state.focused_id)
                prise.request_frame()
            end
        end
        -- Forward mouse events to the target PTY if there is one
        local root = get_active_root()
        if d.target and root then
            local path = find_node_path(root, d.target)
            if path then
                local pane = path[#path]
                pane.pty:send_mouse({
                    x = d.target_x or 0,
                    y = d.target_y or 0,
                    button = d.button,
                    event_type = d.action,
                    mods = d.mods,
                })
            end
        end
    elseif event.type == "winsize" then
        state.screen_cols = event.data.cols or state.screen_cols
        state.screen_rows = event.data.rows or state.screen_rows
        prise.request_frame()
    elseif event.type == "focus_in" then
        state.app_focused = true
        local pty = get_focused_pty()
        if pty then
            pty:set_focus(true)
        end
    elseif event.type == "focus_out" then
        state.app_focused = false
        local pty = get_focused_pty()
        if pty then
            pty:set_focus(false)
        end
    elseif event.type == "split_resize" then
        -- Handle mouse drag resize
        local d = event.data
        local split_id = d.parent_id
        local child_index = d.child_index
        local new_ratio = d.ratio

        -- Find the split by id and update the child's ratio
        local function update_split_ratio(node)
            if not node then
                return false
            end
            if is_split(node) then
                if node.split_id == split_id then
                    -- Found it - update the first child's ratio
                    if node.children[child_index + 1] then
                        node.children[child_index + 1].ratio = new_ratio
                    end
                    return true
                end
                for _, child in ipairs(node.children) do
                    if update_split_ratio(child) then
                        return true
                    end
                end
            end
            return false
        end

        local root = get_active_root()
        if update_split_ratio(root) then
            prise.request_frame()
            prise.save() -- Auto-save on layout change
        end
    elseif event.type == "cwd_changed" then
        -- CWD changed for a PTY
        prise.save() -- Auto-save on cwd change
    end
end

---Recursive rendering function
---@param node Node
---@param force_unfocused? boolean
---@return table
local function render_node(node, force_unfocused)
    if is_pane(node) then
        local is_focused = (node.id == state.focused_id) and not (force_unfocused == true)
        prise.log.debug(
            "render_node: force_unfocused=" .. tostring(force_unfocused) .. " is_focused=" .. tostring(is_focused)
        )
        return prise.Terminal({
            pty = node.pty,
            ratio = node.ratio,
            focus = is_focused,
        })
    elseif is_split(node) then
        local children_widgets = {}
        for _, child in ipairs(node.children) do
            table.insert(children_widgets, render_node(child, force_unfocused))
        end

        local props = {
            children = children_widgets,
            ratio = node.ratio,
            id = node.split_id,
            cross_axis_align = "stretch",
            resizable = true,
        }

        if node.direction == "row" then
            return prise.Row(props)
        else
            return prise.Column(props)
        end
    end
end

---Format a command palette item with name and right-aligned shortcut
---@param name string
---@param shortcut? string
---@param width number
---@return string
local function format_palette_item(name, shortcut, width)
    if not shortcut then
        return name
    end
    local padding = width - prise.gwidth(name) - prise.gwidth(shortcut)
    if padding < 2 then
        padding = 2
    end
    return name .. string.rep(" ", padding) .. shortcut
end

---Build the command palette overlay
---@return table?
local function build_palette()
    if not state.palette.visible or not state.palette.input then
        state.palette.regions = {}
        return nil
    end

    local text = state.palette.input:text()
    prise.log.debug("build_palette: text='" .. text .. "'")
    local filtered = filter_commands(text)
    local has_commands = #filtered > 0
    if not has_commands then
        table.insert(filtered, { name = "No matches" })
    end
    prise.log.debug("build_palette: filtered count=" .. #filtered)

    local items = {}
    for _, cmd in ipairs(filtered) do
        table.insert(items, format_palette_item(cmd.name, cmd.shortcut, PALETTE_INNER_WIDTH))
    end

    local palette_style = { bg = THEME.bg1, fg = THEME.fg_bright }
    local selected_style = { bg = THEME.accent, fg = THEME.fg_dark }
    local input_style = { bg = THEME.bg1, fg = THEME.fg_bright }

    -- Calculate click regions for visible items only (skip if no real commands)
    -- Palette layout: y=5, padding top=1, text input=1 line, separator=1 line
    -- Items start at y = 5 + 1 + 1 + 1 = 8
    local items_start_y = state.palette.palette_y + 1 + 1 + 1
    state.palette.regions = {}
    if has_commands then
        -- Calculate visible height: screen height minus palette header and padding
        -- Subtract: palette_y (5) + padding (2) + input (1) + separator (1) + bottom padding (1)
        local available_height = state.screen_rows - items_start_y - 1
        local visible_count = math.min(#items - state.palette.scroll_offset, available_height)
        for display_row = 1, visible_count do
            local item_index = state.palette.scroll_offset + display_row
            table.insert(state.palette.regions, {
                start_y = items_start_y + (display_row - 1),
                end_y = items_start_y + display_row,
                index = item_index,
            })
        end
    end

    return prise.Positioned({
        anchor = "top_center",
        y = state.palette.palette_y,
        child = prise.Box({
            border = "none",
            max_width = PALETTE_WIDTH,
            style = palette_style,
            child = prise.Padding({
                top = 1,
                bottom = 1,
                left = 2,
                right = 2,
                child = prise.Column({
                    cross_axis_align = "stretch",
                    children = {
                        prise.TextInput({
                            input = state.palette.input,
                            style = input_style,
                        }),
                        prise.Text({ text = string.rep("─", PALETTE_WIDTH), style = { fg = THEME.bg3 } }),
                        prise.List({
                            items = items,
                            selected = state.palette.selected,
                            scroll_offset = state.palette.scroll_offset,
                            style = palette_style,
                            selected_style = selected_style,
                        }),
                    },
                }),
            }),
        }),
    })
end

---Build the rename session overlay
---@return table?
local function build_rename()
    if not state.rename.visible or not state.rename.input then
        return nil
    end

    local palette_style = { bg = THEME.bg1, fg = THEME.fg_bright }
    local input_style = { bg = THEME.bg1, fg = THEME.fg_bright }

    return prise.Positioned({
        anchor = "top_center",
        y = 5,
        child = prise.Box({
            border = "none",
            max_width = PALETTE_WIDTH,
            style = palette_style,
            child = prise.Padding({
                top = 1,
                bottom = 1,
                left = 2,
                right = 2,
                child = prise.Column({
                    cross_axis_align = "stretch",
                    children = {
                        prise.Text({ text = "Rename Session", style = { fg = THEME.fg_dim } }),
                        prise.TextInput({
                            input = state.rename.input,
                            style = input_style,
                        }),
                    },
                }),
            }),
        }),
    })
end

---Build the tab bar (only shown if more than 1 tab)
---@return table?
local function build_tab_bar()
    if not config.tab_bar.show_single_tab and #state.tabs <= 1 then
        state.tab_regions = {}
        return nil
    end

    local segments = {}
    local x_pos = 0
    state.tab_regions = {}

    for i, tab in ipairs(state.tabs) do
        local is_active = (i == state.active_tab)
        local is_hovered = (i == state.hovered_tab)
        local label = " " .. (tab.title or tostring(i)) .. " "
        local label_width = #label

        -- Record hit region for this tab
        table.insert(state.tab_regions, {
            start_x = x_pos,
            end_x = x_pos + label_width,
            tab_index = i,
        })
        x_pos = x_pos + label_width

        local style
        if is_active then
            style = { bg = THEME.accent, fg = THEME.fg_dark }
        elseif is_hovered then
            style = { bg = THEME.bg3, fg = THEME.fg_bright }
        else
            style = { bg = THEME.bg2, fg = THEME.fg_dim }
        end

        table.insert(segments, { text = label, style = style })
    end

    -- Cap off with default background so last tab doesn't fill the row
    table.insert(segments, { text = " ", style = { bg = THEME.bg1 } })

    return prise.Text(segments)
end

---Build the powerline-style status bar
---@return table
local function build_status_bar()
    local mode_color = state.pending_command and THEME.mode_command or THEME.mode_normal
    local session_name = (prise.get_session_name() or "prise"):upper()
    local mode_text = state.pending_command and " CMD " or (" " .. session_name .. " ")

    -- Get pane title
    local title = "Terminal"
    local root = get_active_root()
    if state.focused_id and root then
        local path = find_node_path(root, state.focused_id)
        if path then
            local pane = path[#path]
            local t = pane.pty:title()
            if t and #t > 0 then
                title = t
            end
        end
    end

    -- Get pane position
    local pane_idx, pane_total = get_pane_position()
    local pane_info = string.format(" %d/%d ", pane_idx, pane_total)

    -- Tab info (if multiple tabs)
    local tab_info = ""
    if #state.tabs > 1 then
        tab_info = string.format(" Tab %d/%d ", state.active_tab, #state.tabs)
    end

    -- Build the segments
    local segments = {
        -- Left side: mode indicator
        { text = mode_text, style = { bg = mode_color, fg = THEME.fg_dark, bold = true } },
        { text = POWERLINE_SYMBOLS.right_solid, style = { fg = mode_color, bg = THEME.bg2 } },

        -- Title section
        { text = " " .. title .. " ", style = { bg = THEME.bg2, fg = THEME.fg_bright } },
        { text = POWERLINE_SYMBOLS.right_solid, style = { fg = THEME.bg2, bg = THEME.bg3 } },

        -- Pane info
        { text = pane_info, style = { bg = THEME.bg3, fg = THEME.fg_dim } },
    }

    -- Add zoom indicator if zoomed
    if state.zoomed_pane_id then
        table.insert(segments, { text = POWERLINE_SYMBOLS.right_solid, style = { fg = THEME.bg3, bg = THEME.yellow } })
        table.insert(segments, { text = " ZOOM ", style = { bg = THEME.yellow, fg = THEME.fg_dark, bold = true } })
        table.insert(segments, { text = POWERLINE_SYMBOLS.right_solid, style = { fg = THEME.yellow, bg = THEME.bg3 } })
    end

    -- Add tab info if applicable
    if #state.tabs > 1 then
        table.insert(segments, { text = POWERLINE_SYMBOLS.right_solid, style = { fg = THEME.bg3, bg = THEME.bg4 } })
        table.insert(segments, { text = tab_info, style = { bg = THEME.bg4, fg = THEME.fg_dim } })
        table.insert(segments, { text = POWERLINE_SYMBOLS.right_solid, style = { fg = THEME.bg4, bg = THEME.bg1 } })
    else
        table.insert(segments, { text = POWERLINE_SYMBOLS.right_solid, style = { fg = THEME.bg3, bg = THEME.bg1 } })
    end

    return prise.Text(segments)
end

---@return table
function M.view()
    local root = get_active_root()
    if not root then
        return prise.Column({
            cross_axis_align = "stretch",
            children = { prise.Text("Waiting for terminal...") },
        })
    end

    local palette = build_palette()
    local rename = build_rename()
    local tab_bar = build_tab_bar()
    prise.log.debug("view: palette.visible=" .. tostring(state.palette.visible))

    -- When zoomed, render only the zoomed pane
    local overlay_visible = state.palette.visible or state.rename.visible
    local content
    if state.zoomed_pane_id then
        local path = find_node_path(root, state.zoomed_pane_id)
        if path then
            local pane = path[#path]
            content = prise.Terminal({
                pty = pane.pty,
                focus = not overlay_visible,
            })
        else
            state.zoomed_pane_id = nil
            content = render_node(root, overlay_visible)
        end
    else
        content = render_node(root, overlay_visible)
    end

    local status_bar = config.status_bar.enabled and build_status_bar() or nil

    local main_children = {}
    if tab_bar then
        table.insert(main_children, tab_bar)
    end
    table.insert(main_children, content)
    if status_bar then
        table.insert(main_children, status_bar)
    end

    local main_ui = prise.Column({
        cross_axis_align = "stretch",
        children = main_children,
    })

    local overlay = palette or rename
    if overlay then
        return prise.Stack({
            children = {
                main_ui,
                overlay,
            },
        })
    end

    return main_ui
end

---@return table
function M.get_state(cwd_lookup)
    -- Serialize all tabs
    local tabs_data = {}
    for _, tab in ipairs(state.tabs) do
        table.insert(tabs_data, {
            id = tab.id,
            title = tab.title,
            root = serialize_node(tab.root, cwd_lookup),
            last_focused_id = tab.last_focused_id,
        })
    end

    return {
        tabs = tabs_data,
        active_tab = state.active_tab,
        next_tab_id = state.next_tab_id,
        focused_id = state.focused_id,
        next_split_id = state.next_split_id,
    }
end

---@param saved? table
---@param pty_lookup fun(id: number): userdata?
function M.set_state(saved, pty_lookup)
    if not saved then
        return
    end

    -- Handle migration from old format (single root) to new format (tabs)
    if saved.tabs == nil and saved.root ~= nil then
        -- Old format: migrate to tabs
        local restored_root = deserialize_node(saved.root, pty_lookup)
        if restored_root then
            local tab_id = 1
            state.tabs = {
                {
                    id = tab_id,
                    root = restored_root,
                    last_focused_id = saved.focused_id,
                },
            }
            state.active_tab = 1
            state.next_tab_id = tab_id + 1
            state.focused_id = saved.focused_id
            state.next_split_id = saved.next_split_id or 1
        end
    else
        -- New format: restore tabs
        state.tabs = {}
        for _, tab_data in ipairs(saved.tabs or {}) do
            local restored_root = deserialize_node(tab_data.root, pty_lookup)
            if restored_root then
                table.insert(state.tabs, {
                    id = tab_data.id,
                    title = tab_data.title,
                    root = restored_root,
                    last_focused_id = tab_data.last_focused_id,
                })
            end
        end
        state.active_tab = saved.active_tab or 1
        state.next_tab_id = saved.next_tab_id or (#state.tabs + 1)
        state.focused_id = saved.focused_id
        state.next_split_id = saved.next_split_id or 1

        -- Ensure active_tab is valid
        if state.active_tab > #state.tabs then
            state.active_tab = #state.tabs
        end
        if state.active_tab < 1 and #state.tabs > 0 then
            state.active_tab = 1
        end
    end

    -- Ensure focus is valid
    if #state.tabs > 0 and not state.focused_id then
        local tab = state.tabs[state.active_tab]
        if tab then
            local first = get_first_leaf(tab.root)
            if first then
                state.focused_id = first.id
            end
        end
    end

    prise.request_frame()
end

return M
