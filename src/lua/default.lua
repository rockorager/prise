local prise = require("prise")

-- Powerline symbols
local PL = {
    right_solid = "",
    right_thin = "",
    left_solid = "",
    left_thin = "",
}

-- Color theme (Catppuccin Mocha inspired)
local theme = {
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
}

local state = {
    root = nil,
    focused_id = nil,
    pending_command = false,
    timer = nil,
    pending_split = nil,
    next_split_id = 1,
    -- Command palette
    palette = {
        visible = false,
        input = nil, -- TextInput handle
        selected = 1,
        scroll_offset = 0,
    },
}

local M = {}

local RESIZE_STEP = 0.05 -- 5% step for keyboard resize

-- --- Helpers ---

local function is_pane(node)
    return node and node.type == "pane"
end
local function is_split(node)
    return node and node.type == "split"
end

-- Returns a list of nodes from root to the target node [root, ..., target]
local function find_node_path(current, target_id, path)
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

-- Recursively insert a new pane relative to target_id
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

-- Recursively remove a pane and return: new_node, closest_sibling_id
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

local function get_focused_pty()
    if not state.focused_id or not state.root then
        return nil
    end
    local path = find_node_path(state.root, state.focused_id)
    if path then
        return path[#path].pty
    end
    return nil
end

local function remove_pane_by_id(id)
    local new_root, next_focus = remove_pane_recursive(state.root, id)
    state.root = new_root

    if not state.root then
        prise.quit()
    else
        if state.focused_id == id then
            if next_focus then
                state.focused_id = next_focus
            else
                local first = get_first_leaf(state.root)
                if first then
                    state.focused_id = first.id
                end
            end
        end
    end
    prise.request_frame()
end

-- Count all panes in the tree
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

-- Get index of focused pane (1-based) and total count
local function get_pane_position()
    if not state.root or not state.focused_id then
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

    walk(state.root)
    return found_index, index
end

-- Serialize a node tree to a table with pty_ids instead of userdata
local function serialize_node(node)
    if not node then
        return nil
    end
    if is_pane(node) then
        return {
            type = "pane",
            id = node.id,
            pty_id = node.pty:id(),
            ratio = node.ratio,
        }
    elseif is_split(node) then
        local children = {}
        for _, child in ipairs(node.children) do
            table.insert(children, serialize_node(child))
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

-- Deserialize a node tree, looking up PTYs by id
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

local function resize_pane(dimension, delta_ratio)
    if not state.focused_id or not state.root then
        return
    end

    local path = find_node_path(state.root, state.focused_id)
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

    if not parent_split or not child_idx or child_idx ~= 1 then
        -- Only resize first child (sets the split ratio)
        return
    end

    -- Get current ratio (nil means 0.5)
    local current_ratio = node.ratio or 0.5
    local new_ratio = current_ratio + delta_ratio

    -- Clamp to valid range
    if new_ratio < 0.1 then
        new_ratio = 0.1
    end
    if new_ratio > 0.9 then
        new_ratio = 0.9
    end

    node.ratio = new_ratio

    prise.request_frame()
end

local function move_focus(direction)
    if not state.focused_id or not state.root then
        return
    end

    local path = find_node_path(state.root, state.focused_id)
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

        if target_leaf then
            state.focused_id = target_leaf.id
            prise.request_frame()
        end
    end
end

-- Command palette commands
local commands = {
    {
        name = "Split Horizontal",
        action = function()
            state.pending_split = { direction = "row" }
            prise.spawn({})
        end,
    },
    {
        name = "Split Vertical",
        action = function()
            state.pending_split = { direction = "col" }
            prise.spawn({})
        end,
    },
    {
        name = "Split Auto",
        action = function()
            local pty = get_focused_pty()
            if pty then
                local size = pty:size()
                if size.cols > (size.rows * 2.2) then
                    state.pending_split = { direction = "row" }
                else
                    state.pending_split = { direction = "col" }
                end
                prise.spawn({})
            end
        end,
    },
    {
        name = "Focus Left",
        action = function()
            move_focus("left")
        end,
    },
    {
        name = "Focus Right",
        action = function()
            move_focus("right")
        end,
    },
    {
        name = "Focus Up",
        action = function()
            move_focus("up")
        end,
    },
    {
        name = "Focus Down",
        action = function()
            move_focus("down")
        end,
    },
    {
        name = "Detach Session",
        action = function()
            prise.detach("default")
        end,
    },
    {
        name = "Quit",
        action = function()
            prise.quit()
        end,
    },
}

local function filter_commands(query)
    if not query or query == "" then
        return commands
    end
    local q = query:lower()
    local results = {}
    for _, cmd in ipairs(commands) do
        if cmd.name:lower():find(q, 1, true) then
            table.insert(results, cmd)
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

-- --- Main Functions ---

function M.update(event)
    if event.type == "pty_attach" then
        prise.log.info("Lua: pty_attach received")
        local pty = event.data.pty
        local new_pane = { type = "pane", pty = pty, id = pty:id() }

        if not state.root then
            -- First terminal
            state.root = new_pane
            state.focused_id = new_pane.id
        else
            -- Insert into tree
            local direction = (state.pending_split and state.pending_split.direction) or "row"

            if state.focused_id then
                state.root = insert_split_recursive(state.root, state.focused_id, new_pane, direction)
            else
                -- Fallback
                if is_split(state.root) then
                    table.insert(state.root.children, new_pane)
                else
                    local split_id = state.next_split_id
                    state.next_split_id = state.next_split_id + 1
                    state.root = {
                        type = "split",
                        split_id = split_id,
                        direction = direction,
                        children = { state.root, new_pane },
                    }
                end
            end

            state.focused_id = new_pane.id
            state.pending_split = nil
        end
        prise.request_frame()
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

        -- Super+p to open command palette
        if event.data.key == "p" and event.data.super then
            open_palette()
            return
        end

        -- Handle pending command mode (after Ctrl+b)
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
                prise.spawn({})
                state.pending_split = { direction = "row" }
                handled = true
            elseif k == '"' or k == "'" or k == "s" then
                -- Split vertical (top-bottom)
                prise.spawn({})
                state.pending_split = { direction = "col" }
                handled = true
            elseif k == "d" then
                -- Detach from session
                prise.detach("default")
                handled = true
            elseif k == "w" then
                -- Close current pane
                local path = state.focused_id and find_node_path(state.root, state.focused_id)
                if path then
                    local pane = path[#path]
                    pane.pty:close()
                    remove_pane_by_id(pane.id)
                    handled = true
                end
            elseif k == "q" then
                -- Quit
                prise.quit()
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
                    prise.spawn({})
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

        -- Super+; to enter command mode
        if event.data.key == ";" and event.data.super then
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

        -- Pass key to focused PTY
        if state.root and state.focused_id then
            local path = find_node_path(state.root, state.focused_id)
            if path then
                local pane = path[#path]
                pane.pty:send_key(event.data)
            end
        end
    elseif event.type == "key_release" then
        -- Forward all key releases to focused PTY
        if state.root and state.focused_id then
            local path = find_node_path(state.root, state.focused_id)
            if path then
                local pane = path[#path]
                local data = event.data
                data.release = true
                pane.pty:send_key(data)
            end
        end
    elseif event.type == "pty_exited" then
        local id = event.data.id
        prise.log.info("Lua: pty_exited " .. id)
        remove_pane_by_id(id)
    elseif event.type == "mouse" then
        local d = event.data
        if d.action == "press" and d.button == "left" then
            -- Focus the clicked pane
            if d.target then
                state.focused_id = d.target
                prise.request_frame()
            end
        end
        -- Forward mouse events to the target PTY if there is one
        if d.target and state.root then
            local path = find_node_path(state.root, d.target)
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
        prise.request_frame()
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

        if update_split_ratio(state.root) then
            prise.request_frame()
        end
    end
end

-- Recursive rendering function
local function render_node(node)
    if is_pane(node) then
        local is_focused = (node.id == state.focused_id)
        return prise.Terminal({
            pty = node.pty,
            ratio = node.ratio,
            show_cursor = is_focused,
        })
    elseif is_split(node) then
        local children_widgets = {}
        for _, child in ipairs(node.children) do
            table.insert(children_widgets, render_node(child))
        end

        local props = {
            children = children_widgets,
            ratio = node.ratio,
            id = node.split_id,
            cross_axis_align = "stretch",
        }

        if node.direction == "row" then
            return prise.Row(props)
        else
            return prise.Column(props)
        end
    end
end

-- Build the command palette overlay
local function build_palette()
    if not state.palette.visible or not state.palette.input then
        return nil
    end

    local text = state.palette.input:text()
    prise.log.debug("build_palette: text='" .. text .. "'")
    local filtered = filter_commands(text)
    if #filtered == 0 then
        table.insert(filtered, { name = "No matches" })
    end
    prise.log.debug("build_palette: filtered count=" .. #filtered)
    local items = {}
    for _, cmd in ipairs(filtered) do
        table.insert(items, cmd.name)
    end

    local palette_style = { bg = theme.bg2, fg = theme.fg_bright }
    local selected_style = { bg = theme.accent, fg = theme.fg_dark }
    local input_style = { bg = theme.bg3, fg = theme.fg_bright }

    return prise.Positioned({
        anchor = "top_center",
        y = 2,
        child = prise.Box({
            border = "rounded",
            style = palette_style,
            child = prise.Column({
                cross_axis_align = "stretch",
                children = {
                    prise.TextInput({
                        input = state.palette.input,
                        style = input_style,
                    }),
                    prise.List({
                        items = items,
                        selected = state.palette.selected,
                        style = palette_style,
                        selected_style = selected_style,
                    }),
                },
            }),
        }),
    })
end

-- Build the powerline-style status bar
local function build_status_bar()
    local mode_color = state.pending_command and theme.mode_command or theme.mode_normal
    local mode_text = state.pending_command and " CMD " or " PRISE "

    -- Get pane title
    local title = "Terminal"
    if state.focused_id then
        local path = find_node_path(state.root, state.focused_id)
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

    -- Build the segments
    return prise.Text({
        -- Left side: mode indicator
        { text = mode_text, style = { bg = mode_color, fg = theme.fg_dark, bold = true } },
        { text = PL.right_solid, style = { fg = mode_color, bg = theme.bg2 } },

        -- Title section
        { text = " " .. title .. " ", style = { bg = theme.bg2, fg = theme.fg_bright } },
        { text = PL.right_solid, style = { fg = theme.bg2, bg = theme.bg3 } },

        -- Pane info
        { text = pane_info, style = { bg = theme.bg3, fg = theme.fg_dim } },
        { text = PL.right_solid, style = { fg = theme.bg3, bg = theme.bg1 } },
    })
end

function M.view()
    if not state.root then
        return prise.Column({
            cross_axis_align = "stretch",
            children = { prise.Text("Waiting for terminal...") },
        })
    end

    local content = render_node(state.root)
    local status_bar = build_status_bar()

    local main_ui = prise.Column({
        cross_axis_align = "stretch",
        children = {
            content,
            status_bar,
        },
    })

    local palette = build_palette()
    if palette then
        return prise.Stack({
            children = {
                main_ui,
                palette,
            },
        })
    end

    return main_ui
end

function M.get_state()
    return {
        root = serialize_node(state.root),
        focused_id = state.focused_id,
        next_split_id = state.next_split_id,
    }
end

function M.set_state(saved, pty_lookup)
    if not saved then
        return
    end
    state.root = deserialize_node(saved.root, pty_lookup)
    state.focused_id = saved.focused_id
    state.next_split_id = saved.next_split_id or 1

    if state.root and not state.focused_id then
        local first = get_first_leaf(state.root)
        if first then
            state.focused_id = first.id
        end
    end

    prise.request_frame()
end

return M
