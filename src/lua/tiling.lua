local prise = require("prise")
local utils = require("utils")

---@class Pane
---@field type "pane"
---@field id number
---@field pty Pty
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
---@field input? TextInput
---@field selected number
---@field scroll_offset number
---@field regions PaletteRegion[]
---@field palette_y number

---@class RenameState
---@field visible boolean
---@field input? TextInput

---@class SessionPickerState
---@field visible boolean
---@field input? TextInput
---@field selected number
---@field scroll_offset number
---@field sessions string[]
---@field regions PaletteRegion[]

---@class State
---@field tabs Tab[]
---@field active_tab integer
---@field next_tab_id integer
---@field focused_id? number
---@field zoomed_pane_id? number
---@field pending_command boolean
---@field timer? Timer
---@field clock_timer? Timer
---@field pending_split? { direction: "row"|"col" }
---@field pending_new_tab? boolean
---@field next_split_id number
---@field palette PaletteState
---@field rename RenameState
---@field rename_tab RenameState
---@field session_picker SessionPickerState
---@field screen_cols number
---@field screen_rows number
---@field keybind_matcher? KeybindMatcher

---@class Command
---@field name string
---@field action fun()
---@field shortcut? string
---@field visible? fun(): boolean

---@class PtyAttachEvent
---@field type "pty_attach"
---@field data { pty: Pty }

---@class PtyExitedEvent
---@field type "pty_exited"
---@field data { id: number }

---@class KeyPressEvent
---@field type "key_press"
---@field data PtyKeyData

---@class KeyReleaseEvent
---@field type "key_release"
---@field data PtyKeyData

---@class PasteEvent
---@field type "paste"
---@field data { text: string }

---@class MouseEvent
---@field type "mouse"
---@field data { action: string, button?: string, x: number, y: number, target?: number, target_x?: number, target_y?: number, mods?: table }

---@class WinsizeEvent
---@field type "winsize"
---@field data { cols: number, rows: number }

---@class FocusInEvent
---@field type "focus_in"
---@field data table

---@class FocusOutEvent
---@field type "focus_out"
---@field data table

---@class SplitResizeEvent
---@field type "split_resize"
---@field data { parent_id: number, child_index: integer, ratio: number }

---@class CwdChangedEvent
---@field type "cwd_changed"
---@field data table

---@alias Event PtyAttachEvent|PtyExitedEvent|KeyPressEvent|KeyReleaseEvent|PasteEvent|MouseEvent|WinsizeEvent|FocusInEvent|FocusOutEvent|SplitResizeEvent|CwdChangedEvent

-- Powerline symbols
local POWERLINE_SYMBOLS = {
    right_solid = "",
    right_thin = "",
    left_solid = "",
    left_thin = "",
    left_round = "\u{E0B6}",
    right_round = "\u{E0B4}",
}

---@class PriseThemeOptions
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

---@class PriseTheme
---@field mode_normal string
---@field mode_command string
---@field bg1 string
---@field bg2 string
---@field bg3 string
---@field bg4 string
---@field fg_bright string
---@field fg_dim string
---@field fg_dark string
---@field accent string
---@field green string
---@field yellow string

---@class PriseStatusBarConfig
---@field enabled? boolean Show the status bar (default: true)

---@class PriseTabBarConfig
---@field show_single_tab? boolean Show tab bar even with one tab (default: false)

---Keybinds are a map from key_string to action name
---Example: ["<leader>v"] = "split_horizontal"
---@alias PriseKeybinds table<string, string|function>

---@class PriseBordersConfig
---@field enabled? boolean Show pane borders (default: false)
---@field show_single_pane? boolean Show border when only one pane exists (default: false)
---@field mode? "box"|"separator" Border mode: "box" for full borders, "separator" for tmux-style (default: "box")
---@field style? "none"|"single"|"double"|"rounded" Border line style (default: "single")
---@field focused_color? string Hex color for focused pane border (default: "#89b4fa")
---@field unfocused_color? string Hex color for unfocused borders (default: "#585b70")

---@class PriseConfigOptions
---@field theme? PriseThemeOptions Color theme options
---@field borders? PriseBordersConfig Pane border options
---@field status_bar? PriseStatusBarConfig Status bar options
---@field tab_bar? PriseTabBarConfig Tab bar options
---@field leader? string Leader key sequence (default: "<D-k>")
---@field keybinds? PriseKeybinds Keybind definitions
---@field macos_option_as_alt? "false"|"left"|"right"|"true" macOS Option key behavior (default: "false")

---@class PriseConfig
---@field theme PriseTheme
---@field borders PriseBordersConfig
---@field status_bar PriseStatusBarConfig
---@field tab_bar PriseTabBarConfig
---@field leader string
---@field keybinds PriseKeybinds

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
    borders = {
        enabled = false,
        show_single_pane = false,
        mode = "box", -- "box" for full borders, "separator" for tmux-style
        style = "single",
        focused_color = "#89b4fa", -- Blue (matches default theme.accent)
        unfocused_color = "#585b70", -- Gray (matches default theme.bg4)
    },
    status_bar = {
        enabled = true,
    },
    tab_bar = {
        show_single_tab = false,
    },
    leader = "<D-k>",
    keybinds = {
        ["<D-p>"] = "command_palette",
        ["<leader>v"] = "split_horizontal",
        ["<leader>s"] = "split_vertical",
        ["<leader><Enter>"] = "split_auto",
        ["<leader>h"] = "focus_left",
        ["<leader>l"] = "focus_right",
        ["<leader>j"] = "focus_down",
        ["<leader>k"] = "focus_up",
        ["<leader>w"] = "close_pane",
        ["<leader>z"] = "toggle_zoom",
        ["<leader>t"] = "new_tab",
        ["<leader>c"] = "close_tab",
        ["<leader>r"] = "rename_tab",
        ["<leader>n"] = "next_tab",
        ["<leader>p"] = "previous_tab",
        ["<leader>d"] = "detach_session",
        ["<leader>q"] = "quit",
        ["<leader>H"] = "resize_left",
        ["<leader>L"] = "resize_right",
        ["<leader>J"] = "resize_down",
        ["<leader>K"] = "resize_up",
        ["<leader>1"] = "tab_1",
        ["<leader>2"] = "tab_2",
        ["<leader>3"] = "tab_3",
        ["<leader>4"] = "tab_4",
        ["<leader>5"] = "tab_5",
        ["<leader>6"] = "tab_6",
        ["<leader>7"] = "tab_7",
        ["<leader>8"] = "tab_8",
        ["<leader>9"] = "tab_9",
        ["<leader>0"] = "tab_10",
    },
    macos_option_as_alt = "false",
}

local merge_config = utils.merge_config

-- Convenience alias for theme access
local THEME = config.theme

---@type State
local state = {
    tabs = {},
    active_tab = 1,
    next_tab_id = 1,
    focused_id = nil,
    zoomed_pane_id = nil,
    app_focused = true,
    pending_command = false,
    timer = nil,
    clock_timer = nil,
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
    -- Rename tab prompt
    rename_tab = {
        visible = false,
        input = nil, -- TextInput handle
    },
    -- Session switcher
    session_picker = {
        visible = false,
        input = nil, -- TextInput handle
        selected = 1,
        scroll_offset = 0,
        sessions = {}, -- List of session names
        regions = {}, -- Click regions for items
    },
    -- Tab bar hit regions: array of {start_x, end_x, tab_index}
    tab_regions = {},
    -- Tab close button regions: array of {start_x, end_x, tab_index}
    tab_close_regions = {},
    -- Currently hovered tab index (nil if none)
    hovered_tab = nil,
    -- Currently hovered close button tab index (nil if none)
    hovered_close_tab = nil,
    -- Screen dimensions
    screen_cols = 80,
    screen_rows = 24,
    -- Cached git branch (updated on cwd_changed)
    cached_git_branch = nil,
    -- True when detaching (prevents new timers from being scheduled)
    detaching = false,
    -- Keybind matcher (initialized by init_keybinds)
    keybind_matcher = nil,
}

local M = {}

---Forward declaration for action_handlers (defined after helper functions)
---@type table<string, fun()>
local action_handlers

---Initialize keybinds by compiling the trie
local function init_keybinds()
    if state.keybind_matcher then
        return
    end
    state.keybind_matcher = prise.keybind.compile(config.keybinds, config.leader)
end

---Configure the default UI
---@param opts? PriseConfigOptions Configuration options to merge
function M.setup(opts)
    if opts then
        merge_config(config, opts)
    end
    -- Mark keybinds for re-initialization on next key event
    -- (lazy init because UI pointer may not be available during config loading)
    state.keybind_matcher = nil
end

---Get the macos_option_as_alt setting
---@return string
function M.get_macos_option_as_alt()
    return config.macos_option_as_alt or "false"
end

local RESIZE_STEP = 0.05 -- 5% step for keyboard resize
local PALETTE_WIDTH = 60 -- Total width of command palette
local PALETTE_INNER_WIDTH = 56 -- Inner width (PALETTE_WIDTH - 4 for padding)

-- --- Helpers ---

---Handle common text input key events
---@param input TextInput
---@param key_data PtyKeyData
---@return boolean handled
local function handle_text_input_key(input, key_data)
    local k = key_data.key
    local ctrl = key_data.ctrl

    if k == "Backspace" then
        input:delete_backward()
        prise.request_frame()
        return true
    elseif k == "Delete" then
        input:delete_forward()
        prise.request_frame()
        return true
    elseif k == "w" and ctrl then
        input:delete_word_backward()
        prise.request_frame()
        return true
    elseif k == "k" and ctrl then
        input:kill_line()
        prise.request_frame()
        return true
    elseif k == "ArrowLeft" then
        input:move_left()
        prise.request_frame()
        return true
    elseif k == "ArrowRight" then
        input:move_right()
        prise.request_frame()
        return true
    elseif k == "Home" or (k == "a" and ctrl) then
        input:move_to_start()
        prise.request_frame()
        return true
    elseif k == "End" or (k == "e" and ctrl) then
        input:move_to_end()
        prise.request_frame()
        return true
    elseif #k == 1 and not ctrl and not key_data.alt and not key_data.super then
        input:insert(k)
        prise.request_frame()
        return true
    end

    return false
end

---@param node? table
---@return boolean
local function is_pane(node)
    return node ~= nil and node.type == "pane"
end

---@param node? table
---@return boolean
local function is_split(node)
    return node ~= nil and node.type == "split"
end

---Cancel all timers and detach from session
local function detach_session()
    state.detaching = true
    if state.clock_timer then
        state.clock_timer:cancel()
        state.clock_timer = nil
    end
    if state.timer then
        state.timer:cancel()
        state.timer = nil
    end
    prise.detach(prise.get_session_name())
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
---@type fun(current: Node?, target_id: number, path: Node[]?): Node[]?
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
    if node.type == "pane" then
        ---@cast node Pane
        return node
    end
    if node.type == "split" then
        ---@cast node Split
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
    if node.type == "pane" then
        ---@cast node Pane
        return node
    end
    if node.type == "split" then
        ---@cast node Split
        return get_last_leaf(node.children[#node.children])
    end
    return nil
end

---Update the cached git branch for the focused pane
local function update_cached_git_branch()
    local root = get_active_root()
    if state.focused_id and root then
        local path = find_node_path(root, state.focused_id)
        if path then
            local pane = path[#path]
            local cwd = pane.pty:cwd()
            if cwd then
                state.cached_git_branch = prise.get_git_branch(cwd)
                return
            end
        end
    end
    state.cached_git_branch = nil
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
            ---@type Node
            local survivor = new_children[1]
            survivor.ratio = node.ratio -- Inherit ratio from parent
            return survivor, closest_id
        end

        node.children = new_children
        return node, closest_id
    end
    return nil, nil
end

---@return Pty?
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

local function get_auto_split_direction()
    local pty = get_focused_pty()
    if pty then
        local size = pty:size()
        ---@type boolean
        local wider
        if size.width_px > 0 and size.height_px > 0 then
            wider = size.width_px > size.height_px
        else
            wider = size.cols > size.rows
        end
        if wider then
            return "row"
        else
            return "col"
        end
    end
    return "row"
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
    update_cached_git_branch()
    prise.request_frame()
end

---Close the current tab
---Close tab at given index
---@param idx integer
local function close_tab(idx)
    if #state.tabs == 0 then
        return
    end

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
        -- Cancel clock timer before exit
        if state.clock_timer then
            state.clock_timer:cancel()
            state.clock_timer = nil
        end
        prise.exit()
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
        update_cached_git_branch()
    else
        -- No tabs left
        state.focused_id = nil
        state.cached_git_branch = nil
    end

    prise.request_frame()
    prise.save()
end

---Close the current tab
local function close_current_tab()
    close_tab(state.active_tab)
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
            -- Cancel clock timer before exit
            if state.clock_timer then
                state.clock_timer:cancel()
                state.clock_timer = nil
            end
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
                update_cached_git_branch()
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
            update_cached_git_branch()
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

---Determine if borders should be shown for the active tab
---@return boolean
local function should_show_borders()
    if not config.borders.enabled then
        return false
    end
    if config.borders.show_single_pane then
        return true
    end
    local root = get_active_root()
    return count_panes(root) > 1
end

---Check if a node subtree contains the focused pane
---@param node Node
---@return boolean
local function contains_focused(node)
    if not node or not state.focused_id then
        return false
    end
    if is_pane(node) then
        return node.id == state.focused_id
    elseif is_split(node) then
        for _, child in ipairs(node.children) do
            if contains_focused(child) then
                return true
            end
        end
    end
    return false
end

---Compute a child's share as used by the layout engine
---@param split Split
---@param idx number
---@return number
local function layout_share(split, idx)
    local ratio_sum = 0
    local nil_count = 0

    for _, child in ipairs(split.children) do
        if child.ratio then
            ratio_sum = ratio_sum + child.ratio
        else
            nil_count = nil_count + 1
        end
    end

    local remaining = 1.0 - ratio_sum
    if remaining < 0 then
        remaining = 0
    end

    local nil_share = (nil_count > 0) and (remaining / nil_count) or 0
    return split.children[idx].ratio or nil_share
end

---Collect leaf ranges along a target split direction, in 0.0-1.0 space
---@param node Node
---@param target_direction "row"|"col"
---@param range_start number
---@param range_end number
---@param out? table[]
---@param depth? number
---@return table[]
local function collect_leaf_ranges(node, target_direction, range_start, range_end, out, depth)
    out = out or {}
    depth = depth or 0

    local MAX_DEPTH = 20
    if depth > MAX_DEPTH then
        table.insert(out, { node = node, ratio_start = range_start, ratio_end = range_end })
        return out
    end

    if is_pane(node) then
        table.insert(out, { node = node, ratio_start = range_start, ratio_end = range_end })
        return out
    end

    if is_split(node) and node.direction == target_direction and node.children and #node.children > 0 then
        ---@cast node Split
        local span = range_end - range_start
        local pos = range_start

        for i, child in ipairs(node.children) do
            local share = layout_share(node, i)
            local child_start = pos
            local child_end = (i == #node.children) and range_end or (pos + span * share)
            collect_leaf_ranges(child, target_direction, child_start, child_end, out, depth + 1)
            pos = child_end
        end

        return out
    end

    table.insert(out, { node = node, ratio_start = range_start, ratio_end = range_end })
    return out
end

---Find the focused range within a set of leaf ranges
---@param ranges table[]
---@return number?, number?
local function get_focused_range(ranges)
    for _, r in ipairs(ranges) do
        if contains_focused(r.node) then
            return r.ratio_start, r.ratio_end
        end
    end
    return nil, nil
end

---Build per-section styles for a separator adjacent to the focused pane
---@param left_child Node
---@param right_child Node
---@param sep_axis "horizontal"|"vertical"
---@return table[]? segments
local function build_separator_segments(left_child, right_child, sep_axis)
    local target_direction = (sep_axis == "vertical") and "col" or "row"

    local left_ranges = collect_leaf_ranges(left_child, target_direction, 0.0, 1.0)
    local right_ranges = collect_leaf_ranges(right_child, target_direction, 0.0, 1.0)

    local edges = { 0.0, 1.0 }
    for _, r in ipairs(left_ranges) do
        table.insert(edges, r.ratio_start)
        table.insert(edges, r.ratio_end)
    end
    for _, r in ipairs(right_ranges) do
        table.insert(edges, r.ratio_start)
        table.insert(edges, r.ratio_end)
    end

    table.sort(edges)

    local unique = {}
    local last = nil
    for _, e in ipairs(edges) do
        if last == nil or math.abs(e - last) > 1e-6 then
            table.insert(unique, e)
            last = e
        end
    end

    if #unique <= 2 then
        return nil
    end

    local left_focus_start, left_focus_end = get_focused_range(left_ranges)
    local right_focus_start, right_focus_end = get_focused_range(right_ranges)

    local segments = {}

    local function push_segment(seg_start, seg_end, color)
        if seg_end <= seg_start then
            return
        end

        local last_seg = segments[#segments]
        if
            last_seg
            and last_seg.style
            and last_seg.style.fg == color
            and math.abs(last_seg.ratio_end - seg_start) < 1e-6
        then
            last_seg.ratio_end = seg_end
            return
        end

        table.insert(segments, {
            ratio_start = seg_start,
            ratio_end = seg_end,
            style = { fg = color },
        })
    end

    for i = 1, #unique - 1 do
        local a = unique[i]
        local b = unique[i + 1]

        local focused = false
        if left_focus_start ~= nil then
            focused = focused or (a < left_focus_end and b > left_focus_start)
        end
        if right_focus_start ~= nil then
            focused = focused or (a < right_focus_end and b > right_focus_start)
        end

        local color = focused and config.borders.focused_color or config.borders.unfocused_color
        push_segment(a, b, color)
    end

    return segments
end

---Serialize a node tree to a table with pty_ids instead of userdata
---@param node? Node
---@param cwd_lookup? fun(pty_id: number): string?
---@return table?
local function serialize_node(node, cwd_lookup)
    if not node then
        return nil
    end
    if is_pane(node) then
        local pty_id = node.pty:id()
        ---@type string?
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
---@param pty_lookup fun(id: number): Pty?
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
        ---@type Node[]
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
            ---@type Node
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

local MIN_PANE_SHARE = 0.05

---Get the effective ratio for a child in a split
---@param split Split
---@param idx number
---@return number
local function effective_ratio(split, idx)
    local n = #split.children
    return split.children[idx].ratio or (1.0 / n)
end

---Adjust the ratios of two adjacent siblings, keeping their combined share constant
---@param split Split
---@param left_idx number
---@param right_idx number
---@param delta number Amount to add to left child (negative grows right child)
local function adjust_pair(split, left_idx, right_idx, delta)
    local left_r = effective_ratio(split, left_idx)
    local right_r = effective_ratio(split, right_idx)
    local total = left_r + right_r

    if total < 2 * MIN_PANE_SHARE then
        return
    end

    local new_left = left_r + delta

    -- Clamp so each keeps at least MIN_PANE_SHARE
    if new_left < MIN_PANE_SHARE then
        new_left = MIN_PANE_SHARE
    end
    if new_left > total - MIN_PANE_SHARE then
        new_left = total - MIN_PANE_SHARE
    end

    local new_right = total - new_left

    split.children[left_idx].ratio = new_left
    split.children[right_idx].ratio = new_right
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

    for i = #path - 1, 1, -1 do
        if path[i].type == "split" and path[i].direction == target_split_dir then
            parent_split = path[i]
            local node = path[i + 1]

            -- Find index of current node in parent's children
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

    local num_children = #parent_split.children

    -- Use pairwise adjustment to move the divider between two adjacent siblings.
    -- This keeps other siblings unaffected and matches user expectation of
    -- "move the nearest divider in that direction".
    if delta_ratio < 0 then
        -- Resize left/up: grow current pane by taking from left neighbor
        if child_idx > 1 then
            -- Move divider between (child_idx-1, child_idx) to the left
            adjust_pair(parent_split, child_idx - 1, child_idx, delta_ratio)
        else
            return
        end
    else
        -- Resize right/down: grow current pane by taking from right neighbor
        if child_idx < num_children then
            -- Move divider between (child_idx, child_idx+1) to the right
            adjust_pair(parent_split, child_idx, child_idx + 1, delta_ratio)
        else
            return
        end
    end

    prise.request_frame()
    prise.save()
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
        ---@type Pane?
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
            update_cached_git_branch()
            prise.request_frame()
        end
    end
end

local function open_rename_tab()
    if not state.rename_tab.input then
        state.rename_tab.input = prise.create_text_input()
    end
    local tab = get_active_tab()
    local current_title = (tab and tab.title) or ""
    state.rename_tab.input:clear()
    state.rename_tab.input:insert(current_title)
    state.rename_tab.visible = true
    prise.request_frame()
end

local function close_rename_tab()
    state.rename_tab.visible = false
    prise.request_frame()
end

local function execute_rename_tab()
    if not state.rename_tab.input then
        return
    end
    local new_title = state.rename_tab.input:text()
    local tab = get_active_tab()
    if tab then
        -- If empty, clear title to show index number
        if new_title == "" then
            tab.title = nil
        else
            tab.title = new_title
        end
        prise.save() -- Auto-save on tab renamed
    end
    close_rename_tab()
end

-- Platform-dependent key prefix for shortcuts
local key_prefix = prise.platform == "macos" and "󰘳 +k" or "Super+k"

---Forward declaration for open_rename
---@type fun()
local open_rename

---Forward declaration for open_session_picker
---@type fun()
local open_session_picker

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
            state.pending_split = { direction = get_auto_split_direction() }
            prise.spawn({ cwd = pty and pty:cwd() })
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
        name = "Rename Tab",
        shortcut = key_prefix .. " r",
        action = function()
            open_rename_tab()
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
            detach_session()
        end,
    },
    {
        name = "Rename Session",
        action = function()
            open_rename()
        end,
    },
    {
        name = "Switch Session",
        shortcut = key_prefix .. " S",
        action = function()
            open_session_picker()
        end,
    },
    {
        name = "Quit",
        shortcut = key_prefix .. " q",
        action = function()
            detach_session()
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

-- Action handlers for keybind system
-- Maps action names (from Action enum) to handler functions
action_handlers = {
    split_horizontal = function()
        local pty = get_focused_pty()
        state.pending_split = { direction = "row" }
        prise.spawn({ cwd = pty and pty:cwd() })
    end,
    split_vertical = function()
        local pty = get_focused_pty()
        state.pending_split = { direction = "col" }
        prise.spawn({ cwd = pty and pty:cwd() })
    end,
    split_auto = function()
        local pty = get_focused_pty()
        state.pending_split = { direction = get_auto_split_direction() }
        prise.spawn({ cwd = pty and pty:cwd() })
    end,
    focus_left = function()
        move_focus("left")
    end,
    focus_right = function()
        move_focus("right")
    end,
    focus_up = function()
        move_focus("up")
    end,
    focus_down = function()
        move_focus("down")
    end,
    close_pane = function()
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
    toggle_zoom = function()
        if state.zoomed_pane_id then
            state.zoomed_pane_id = nil
        elseif state.focused_id then
            state.zoomed_pane_id = state.focused_id
        end
        prise.request_frame()
    end,
    new_tab = function()
        local pty = get_focused_pty()
        state.pending_new_tab = true
        prise.spawn({ cwd = pty and pty:cwd() })
    end,
    close_tab = function()
        close_current_tab()
    end,
    rename_tab = function()
        open_rename_tab()
    end,
    next_tab = function()
        if #state.tabs > 1 then
            local next_idx = state.active_tab % #state.tabs + 1
            set_active_tab_index(next_idx)
        end
    end,
    previous_tab = function()
        if #state.tabs > 1 then
            local prev_idx = (state.active_tab - 2 + #state.tabs) % #state.tabs + 1
            set_active_tab_index(prev_idx)
        end
    end,
    tab_1 = function()
        set_active_tab_index(1)
    end,
    tab_2 = function()
        set_active_tab_index(2)
    end,
    tab_3 = function()
        set_active_tab_index(3)
    end,
    tab_4 = function()
        set_active_tab_index(4)
    end,
    tab_5 = function()
        set_active_tab_index(5)
    end,
    tab_6 = function()
        set_active_tab_index(6)
    end,
    tab_7 = function()
        set_active_tab_index(7)
    end,
    tab_8 = function()
        set_active_tab_index(8)
    end,
    tab_9 = function()
        set_active_tab_index(9)
    end,
    tab_10 = function()
        set_active_tab_index(10)
    end,
    resize_left = function()
        resize_pane("width", -RESIZE_STEP)
    end,
    resize_right = function()
        resize_pane("width", RESIZE_STEP)
    end,
    resize_up = function()
        resize_pane("height", -RESIZE_STEP)
    end,
    resize_down = function()
        resize_pane("height", RESIZE_STEP)
    end,
    detach_session = function()
        detach_session()
    end,
    rename_session = function()
        open_rename()
    end,
    quit = function()
        detach_session()
    end,
    -- command_palette is added after open_palette is defined
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

-- Add command_palette handler now that open_palette is defined
action_handlers.command_palette = function()
    open_palette()
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

open_rename = function()
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

open_session_picker = function()
    if not state.session_picker.input then
        state.session_picker.input = prise.create_text_input()
    end
    state.session_picker.input:clear()
    state.session_picker.sessions = prise.list_sessions() or {}
    state.session_picker.selected = 1
    state.session_picker.scroll_offset = 0
    state.session_picker.visible = true
    prise.request_frame()
end

local function close_session_picker()
    state.session_picker.visible = false
    prise.request_frame()
end

---Filter sessions by fuzzy matching the input text
---@param query string
---@return string[]
local function filter_sessions(query)
    if not query or query == "" then
        return state.session_picker.sessions
    end
    local lower_query = query:lower()
    local matches = {}
    for _, session in ipairs(state.session_picker.sessions) do
        if session:lower():find(lower_query, 1, true) then
            table.insert(matches, session)
        end
    end
    return matches
end

local function execute_session_switch()
    local query = state.session_picker.input:text()
    local filtered = filter_sessions(query)
    if #filtered == 0 then
        close_session_picker()
        return
    end
    local idx = state.session_picker.selected
    if idx >= 1 and idx <= #filtered then
        local target = filtered[idx]
        close_session_picker()
        prise.switch_session(target)
    end
end

-- --- Main Functions ---

---@param event Event
function M.update(event)
    if event.type == "pty_attach" then
        prise.log.info("Lua: pty_attach received")
        ---@type Pty
        local pty = event.data.pty
        ---@type Pane
        local new_pane = { type = "pane", pty = pty, id = pty:id() }
        local old_focused_id = state.focused_id

        if state.pending_new_tab then
            -- Create a new tab with this pane
            state.pending_new_tab = false
            local tab_id = state.next_tab_id
            state.next_tab_id = tab_id + 1
            ---@type Tab
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
            ---@type Tab
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
            ---@type string
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
            elseif k == "ArrowUp" or (k == "p" and event.data.ctrl) then
                if state.palette.selected > 1 then
                    state.palette.selected = state.palette.selected - 1
                    prise.request_frame()
                end
                return
            elseif k == "ArrowDown" or (k == "n" and event.data.ctrl) then
                if state.palette.selected < #filtered then
                    state.palette.selected = state.palette.selected + 1
                    prise.request_frame()
                end
                return
            end

            local old_text = state.palette.input:text()
            if handle_text_input_key(state.palette.input, event.data) then
                if state.palette.input:text() ~= old_text then
                    state.palette.selected = 1
                end
                return
            end
            return
        end

        -- Handle session picker
        if state.session_picker.visible then
            local k = event.data.key
            local filtered = filter_sessions(state.session_picker.input:text())

            if k == "Escape" then
                close_session_picker()
                return
            elseif k == "Enter" then
                execute_session_switch()
                return
            elseif k == "ArrowUp" or (k == "p" and event.data.ctrl) then
                if state.session_picker.selected > 1 then
                    state.session_picker.selected = state.session_picker.selected - 1
                    -- Adjust scroll if needed
                    if state.session_picker.selected <= state.session_picker.scroll_offset then
                        state.session_picker.scroll_offset = state.session_picker.selected - 1
                    end
                end
                prise.request_frame()
                return
            elseif k == "ArrowDown" or (k == "n" and event.data.ctrl) then
                if state.session_picker.selected < #filtered then
                    state.session_picker.selected = state.session_picker.selected + 1
                    -- Adjust scroll if needed (visible height approx screen_rows - 15)
                    local visible_height = math.max(1, state.screen_rows - 15)
                    if state.session_picker.selected > state.session_picker.scroll_offset + visible_height then
                        state.session_picker.scroll_offset = state.session_picker.selected - visible_height
                    end
                end
                prise.request_frame()
                return
            elseif k == "Backspace" then
                state.session_picker.input:delete_backward()
                local new_filtered = filter_sessions(state.session_picker.input:text())
                state.session_picker.selected = math.min(state.session_picker.selected, math.max(1, #new_filtered))
                state.session_picker.scroll_offset = 0
                prise.request_frame()
                return
            elseif #k == 1 and not event.data.ctrl and not event.data.alt and not event.data.super then
                state.session_picker.input:insert(k)
                local new_filtered = filter_sessions(state.session_picker.input:text())
                state.session_picker.selected = math.min(state.session_picker.selected, math.max(1, #new_filtered))
                state.session_picker.scroll_offset = 0
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
            end
            handle_text_input_key(state.rename.input, event.data)
            return
        end

        -- Handle rename tab prompt
        if state.rename_tab.visible then
            local k = event.data.key

            if k == "Escape" then
                close_rename_tab()
                return
            elseif k == "Enter" then
                execute_rename_tab()
                return
            end
            handle_text_input_key(state.rename_tab.input, event.data)
            return
        end

        -- Handle keybinds via matcher
        init_keybinds()
        local result = state.keybind_matcher:handle_key(event.data)

        if result.action or result.func then
            -- Cancel any pending timeout
            if state.timer then
                state.timer:cancel()
                state.timer = nil
            end
            state.pending_command = false

            -- Dispatch action
            if result.func then
                result.func()
            elseif result.action then
                local handler = action_handlers[result.action]
                if handler then
                    handler()
                end
            end
            prise.request_frame()
            return
        elseif result.pending then
            -- Key sequence in progress
            state.pending_command = true
            prise.request_frame()

            -- Cancel existing timeout and start new one
            if state.timer then
                state.timer:cancel()
            end
            state.timer = prise.set_timeout(1000, function()
                if state.pending_command then
                    state.pending_command = false
                    state.timer = nil
                    state.keybind_matcher:reset()
                    prise.request_frame()
                end
            end)
            return
        end

        -- No match - reset pending state if we were in one
        if state.pending_command then
            if state.timer then
                state.timer:cancel()
                state.timer = nil
            end
            state.pending_command = false
            prise.request_frame()
            return
        end

        -- Copy selection: Cmd+c (macOS) or Ctrl+Shift+c (Linux)
        if event.data.key == "c" then
            local is_copy = false
            if prise.platform == "macos" then
                is_copy = (event.data.super == true) and not event.data.ctrl and not event.data.alt
            else
                is_copy = (event.data.ctrl == true) and (event.data.shift == true) and not event.data.super
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

        -- Track tab and close button hover state on motion
        if d.action == "motion" and #state.tab_regions > 0 then
            local new_hover = nil
            local new_close_hover = nil
            if d.y < 1 then
                -- Check close button regions first (they're more specific)
                for _, region in ipairs(state.tab_close_regions) do
                    if d.x >= region.start_x and d.x < region.end_x then
                        new_close_hover = region.tab_index
                        new_hover = region.tab_index
                        break
                    end
                end
                -- If not on close button, check tab regions
                if not new_close_hover then
                    for _, region in ipairs(state.tab_regions) do
                        if d.x >= region.start_x and d.x < region.end_x then
                            new_hover = region.tab_index
                            break
                        end
                    end
                end
            end
            if new_hover ~= state.hovered_tab or new_close_hover ~= state.hovered_close_tab then
                state.hovered_tab = new_hover
                state.hovered_close_tab = new_close_hover
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
                -- Check close button regions first
                for _, region in ipairs(state.tab_close_regions) do
                    if d.x >= region.start_x and d.x < region.end_x then
                        close_tab(region.tab_index)
                        return
                    end
                end
                -- Then check tab regions for switching
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

        -- In separator mode, widget children include separators interleaved with panes.
        -- Widget structure: [Pane0, Sep, Pane1, Sep, Pane2, ...]
        -- Lua state structure: [Pane0, Pane1, Pane2, ...]
        -- Map widget child_index to lua pane_index:
        -- - Even widget indices (0, 2, 4, ...) are panes
        -- - Odd widget indices (1, 3, 5, ...) are separators
        -- For a handle at the boundary after widget child N:
        -- - If N is even (a pane), pane_index = N / 2
        -- - If N is odd (a separator), pane_index = (N - 1) / 2 (the pane before the separator)
        local pane_index = child_index
        if config.borders.mode == "separator" and should_show_borders() then
            if child_index % 2 == 0 then
                pane_index = child_index // 2
            else
                pane_index = (child_index - 1) // 2
            end
        end

        -- Find the split by id and update the child's ratio
        local function update_split_ratio(node)
            if not node then
                return false
            end
            if is_split(node) then
                if node.split_id == split_id then
                    -- Found it - update the pane's ratio
                    if node.children[pane_index + 1] then
                        node.children[pane_index + 1].ratio = new_ratio
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
        -- CWD changed for a PTY - update cached git branch
        update_cached_git_branch()
        prise.request_frame()
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
        local terminal = prise.Terminal({
            pty = node.pty,
            ratio = node.ratio,
            focus = is_focused,
        })

        -- Wrap in Box if borders should be shown (only in box mode)
        if should_show_borders() and config.borders.mode == "box" then
            local border_color = is_focused and config.borders.focused_color or config.borders.unfocused_color

            return prise.Box({
                border = config.borders.style,
                style = { fg = border_color },
                child = terminal,
                ratio = node.ratio, -- Propagate ratio for layout system
            })
        else
            return terminal
        end
    elseif is_split(node) then
        local children_widgets = {}

        -- In separator mode, insert separators between children
        if should_show_borders() and config.borders.mode == "separator" then
            for i, child in ipairs(node.children) do
                -- Add separator before this child (except for first)
                if i > 1 then
                    local prev_child = node.children[i - 1]
                    local prev_focused = contains_focused(prev_child)
                    local curr_focused = contains_focused(child)

                    local sep_axis = node.direction == "row" and "vertical" or "horizontal"

                    local segments = nil
                    if prev_focused or curr_focused then
                        segments = build_separator_segments(prev_child, child, sep_axis)
                    end

                    if segments then
                        table.insert(
                            children_widgets,
                            prise.Separator({
                                axis = sep_axis,
                                style = { fg = config.borders.unfocused_color },
                                segments = segments,
                                border = config.borders.style,
                            })
                        )
                    else
                        -- Default behavior: highlight whole separator if adjacent to focus
                        local sep_color = (prev_focused or curr_focused) and config.borders.focused_color
                            or config.borders.unfocused_color

                        table.insert(
                            children_widgets,
                            prise.Separator({
                                axis = sep_axis,
                                style = { fg = sep_color },
                                border = config.borders.style,
                            })
                        )
                    end
                end
                table.insert(children_widgets, render_node(child, force_unfocused))
            end
        else
            -- Box mode or no borders: just render children directly
            for _, child in ipairs(node.children) do
                table.insert(children_widgets, render_node(child, force_unfocused))
            end
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
    else
        error("render_node: unknown node type: " .. tostring(node.type))
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
                        prise.Text({
                            text = string.rep("─", PALETTE_WIDTH),
                            style = { fg = THEME.bg3, bg = THEME.bg1 },
                        }),
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
                        prise.Text({ text = "Rename Session", style = { fg = THEME.fg_dim, bg = THEME.bg1 } }),
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

---Build the rename tab modal
---@return table?
local function build_rename_tab()
    if not state.rename_tab.visible or not state.rename_tab.input then
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
                        prise.Text({ text = "Rename Tab", style = { fg = THEME.fg_dim, bg = THEME.bg1 } }),
                        prise.TextInput({
                            input = state.rename_tab.input,
                            style = input_style,
                        }),
                    },
                }),
            }),
        }),
    })
end

---Build the session picker modal
---@return table?
local function build_session_picker()
    if not state.session_picker.visible or not state.session_picker.input then
        state.session_picker.regions = {}
        return nil
    end

    local text = state.session_picker.input:text()
    local filtered = filter_sessions(text)
    local has_sessions = #filtered > 0

    local items = {}
    local current_session = prise.get_session_name()
    for _, session in ipairs(filtered) do
        local display = session
        if session == current_session then
            display = session .. " (current)"
        end
        table.insert(items, display)
    end

    if not has_sessions then
        table.insert(items, "No sessions found")
    end

    local palette_style = { bg = THEME.bg1, fg = THEME.fg_bright }
    local selected_style = { bg = THEME.accent, fg = THEME.fg_dark }
    local input_style = { bg = THEME.bg1, fg = THEME.fg_bright }

    -- Calculate click regions for visible items
    local items_start_y = 5 + 1 + 1 + 1 -- palette_y + padding + input + separator
    state.session_picker.regions = {}
    if has_sessions then
        local available_height = state.screen_rows - items_start_y - 1
        local visible_count = math.min(#items - state.session_picker.scroll_offset, available_height)
        for display_row = 1, visible_count do
            local item_index = state.session_picker.scroll_offset + display_row
            table.insert(state.session_picker.regions, {
                start_y = items_start_y + (display_row - 1),
                end_y = items_start_y + display_row,
                index = item_index,
            })
        end
    end

    return prise.Positioned({
        anchor = "top_center",
        y = 5,
        focus = true,
        child = prise.Box({
            border = "none",
            max_width = PALETTE_WIDTH,
            style = palette_style,
            focus = true,
            child = prise.Padding({
                top = 1,
                bottom = 1,
                left = 2,
                right = 2,
                child = prise.Column({
                    cross_axis_align = "stretch",
                    children = {
                        prise.Text({ text = "Switch Session", style = { fg = THEME.fg_dim, bg = THEME.bg1 } }),
                        prise.TextInput({
                            input = state.session_picker.input,
                            style = input_style,
                            focus = true,
                        }),
                        prise.Text({
                            text = string.rep("─", PALETTE_WIDTH),
                            style = { fg = THEME.bg3, bg = THEME.bg1 },
                        }),
                        prise.List({
                            items = items,
                            selected = state.session_picker.selected,
                            scroll_offset = state.session_picker.scroll_offset,
                            style = palette_style,
                            selected_style = selected_style,
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
        state.tab_close_regions = {}
        return nil
    end

    local num_tabs = #state.tabs
    local total_width = state.screen_cols
    local endcap_width = 2 -- left_round and right_round are 1 cell each

    -- Calculate tab widths: divide available space evenly
    local base_tab_width = math.floor(total_width / num_tabs)
    local extra_pixels = total_width % num_tabs

    local segments = {}
    local x_pos = 0
    state.tab_regions = {}
    state.tab_close_regions = {}

    for i, tab in ipairs(state.tabs) do
        local is_active = (i == state.active_tab)
        local is_hovered = (i == state.hovered_tab)
        local is_close_hovered = (i == state.hovered_close_tab)

        -- Distribute extra width to last tabs so they fill the line
        local tab_width = base_tab_width
        if i > (num_tabs - extra_pixels) then
            tab_width = tab_width + 1
        end

        -- Close widget: always reserve 2 cells, only show icon when hovered
        local close_widget_width = 2
        local close_text = "  " -- 2 spaces when not hovered
        if is_close_hovered then
            close_text = "\u{F530}" -- md-close_circle (filled)
        elseif is_hovered then
            close_text = "\u{F467}" -- md-close_circle_outline
        end
        -- Pad close_text to exactly close_widget_width cells
        local close_text_width = prise.gwidth(close_text)
        if close_text_width < close_widget_width then
            close_text = close_text .. string.rep(" ", close_widget_width - close_text_width)
        end

        -- Get title: manual title, or focused pty title, or focused pty cwd
        local title = "Terminal"
        if tab.title then
            title = tab.title
        else
            local focused_id = is_active and state.focused_id or tab.last_focused_id
            if focused_id and tab.root then
                local path = find_node_path(tab.root, focused_id)
                if path then
                    local pane = path[#path]
                    local pty_title = pane.pty:title()
                    if pty_title and #pty_title > 0 then
                        title = pty_title
                    else
                        local cwd = pane.pty:cwd()
                        if cwd then
                            title = cwd:match("([^/]+)/?$") or cwd
                        end
                    end
                end
            end
        end

        -- Tab index shown on the right
        local index_str = tostring(i)
        local index_width = #index_str + 2 -- space + index + space

        -- Always reserve space for endcaps, close widget, and index
        local inner_width = tab_width - endcap_width - close_widget_width - index_width
        local title_width = prise.gwidth(title)

        -- Truncate title if needed
        if title_width > inner_width then
            title = string.sub(title, 1, inner_width - 1) .. "…"
            title_width = prise.gwidth(title)
        end

        -- Center the title
        local padding_total = inner_width - title_width
        local pad_left = math.floor(padding_total / 2)
        local pad_right = padding_total - pad_left
        if pad_left < 0 then
            pad_left = 0
        end
        if pad_right < 0 then
            pad_right = 0
        end

        local label = string.rep(" ", pad_left) .. title .. string.rep(" ", pad_right)
        local index_label = " " .. index_str .. " "

        -- Record close button hit region (after left endcap)
        local close_start = x_pos + 1 -- after left endcap
        table.insert(state.tab_close_regions, {
            start_x = close_start,
            end_x = close_start + close_widget_width,
            tab_index = i,
        })

        -- Record hit region for this tab
        table.insert(state.tab_regions, {
            start_x = x_pos,
            end_x = x_pos + tab_width,
            tab_index = i,
        })
        x_pos = x_pos + tab_width

        local tab_bg, tab_fg
        if is_active then
            tab_bg = THEME.bg4
            tab_fg = THEME.fg_bright
        elseif is_hovered then
            tab_bg = THEME.bg3
            tab_fg = THEME.fg_bright
        else
            tab_bg = THEME.bg2
            tab_fg = THEME.fg_dim
        end

        -- Left endcap
        table.insert(segments, { text = POWERLINE_SYMBOLS.left_round, style = { fg = tab_bg, bg = THEME.bg1 } })
        -- Close widget
        table.insert(segments, { text = close_text, style = { bg = tab_bg, fg = tab_fg } })
        -- Tab content (title)
        table.insert(segments, { text = label, style = { bg = tab_bg, fg = tab_fg, bold = is_active } })
        -- Tab index (right side, dimmed)
        table.insert(segments, { text = index_label, style = { bg = tab_bg, fg = THEME.fg_dim } })
        -- Right endcap
        table.insert(segments, { text = POWERLINE_SYMBOLS.right_round, style = { fg = tab_bg, bg = THEME.bg1 } })
    end

    return prise.Text(segments)
end

---Build the powerline-style status bar
---@return table
local function build_status_bar()
    local mode_color = state.pending_command and THEME.mode_command or THEME.mode_normal
    local session_name = (prise.get_session_name() or "prise"):upper()
    local mode_text = state.pending_command and " CMD " or (" " .. session_name .. " ")

    -- Use cached git branch (updated on cwd_changed and focus change)
    local git_branch = state.cached_git_branch

    -- Get current time
    local time_str = prise.get_time()

    -- Build segments and track width
    local segments = {}
    local left_width = 0

    -- Mode indicator
    table.insert(segments, { text = mode_text, style = { bg = mode_color, fg = THEME.fg_dark, bold = true } })
    left_width = left_width + prise.gwidth(mode_text)

    -- Track the last background color for proper powerline transitions
    local last_bg = mode_color

    -- Git branch
    if git_branch then
        local branch_text = " \u{F062C} " .. git_branch .. " "
        table.insert(segments, { text = POWERLINE_SYMBOLS.right_solid, style = { fg = last_bg, bg = THEME.bg2 } })
        table.insert(segments, { text = branch_text, style = { bg = THEME.bg2, fg = THEME.fg_bright } })
        left_width = left_width + 1 + prise.gwidth(branch_text)
        last_bg = THEME.bg2
    end

    -- Zoom indicator
    if state.zoomed_pane_id then
        table.insert(segments, { text = POWERLINE_SYMBOLS.right_solid, style = { fg = last_bg, bg = THEME.yellow } })
        table.insert(segments, { text = " ZOOM ", style = { bg = THEME.yellow, fg = THEME.fg_dark, bold = true } })
        left_width = left_width + 1 + 6
        last_bg = THEME.yellow
    end

    -- End left side
    table.insert(segments, { text = POWERLINE_SYMBOLS.right_solid, style = { fg = last_bg, bg = THEME.bg1 } })
    left_width = left_width + 1

    -- Right side content
    local right_text = " " .. time_str .. " "
    local right_width = 1 + prise.gwidth(right_text) -- powerline symbol + time

    -- Calculate padding to fill the middle
    local padding = state.screen_cols - left_width - right_width
    if padding < 0 then
        padding = 0
    end

    -- Add padding
    table.insert(segments, { text = string.rep(" ", padding), style = { bg = THEME.bg1 } })

    -- Add right side
    table.insert(segments, { text = POWERLINE_SYMBOLS.left_solid, style = { fg = THEME.bg3, bg = THEME.bg1 } })
    table.insert(segments, { text = right_text, style = { bg = THEME.bg3, fg = THEME.fg_dim } })

    return prise.Text(segments)
end

---Schedule a clock timer to refresh the display every minute
local function schedule_clock_timer()
    if state.clock_timer or state.detaching then
        return
    end
    state.clock_timer = prise.set_timeout(60000, function()
        state.clock_timer = nil
        if not state.detaching then
            prise.request_frame()
            schedule_clock_timer()
        end
    end)
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

    -- Start clock timer for status bar updates
    if config.status_bar.enabled then
        schedule_clock_timer()
    end

    local palette = build_palette()
    local rename = build_rename()
    local rename_tab = build_rename_tab()
    local session_picker = build_session_picker()
    local tab_bar = build_tab_bar()
    prise.log.debug("view: palette.visible=" .. tostring(state.palette.visible))

    -- When zoomed, render only the zoomed pane
    local overlay_visible = state.palette.visible
        or state.rename.visible
        or state.rename_tab.visible
        or state.session_picker.visible
    local content
    if state.zoomed_pane_id then
        local path = find_node_path(root, state.zoomed_pane_id)
        if path then
            local pane = path[#path]
            local terminal = prise.Terminal({
                pty = pane.pty,
                focus = not overlay_visible,
            })

            -- Apply borders to zoomed pane if enabled and show_single_pane is true
            -- (zoomed pane is a temporary single-pane view)
            if config.borders.enabled and config.borders.show_single_pane then
                content = prise.Box({
                    border = config.borders.style,
                    style = { fg = config.borders.focused_color }, -- Zoomed pane is always focused
                    child = terminal,
                })
            else
                content = terminal
            end
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

    local overlay = palette or rename or rename_tab or session_picker
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

---@param cwd_lookup? fun(pty_id: number): string?
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
---@param pty_lookup fun(id: number): Pty?
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

-- Export internal functions for testing
M._test = {
    is_pane = is_pane,
    is_split = is_split,
    collect_panes = collect_panes,
    find_node_path = find_node_path,
    get_first_leaf = get_first_leaf,
    get_last_leaf = get_last_leaf,
    format_palette_item = format_palette_item,
}

return M
