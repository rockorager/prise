--- Tests for session deserialization with PTY ID remapping
---
--- When a session is restored after a server restart, PTY IDs may be remapped
--- (e.g., saved pane had id=1/pty_id=1, but server assigns pty_id=5 on restore).
--- The deserialized pane.id must use pty:id(), not the stale saved id, otherwise
--- pty_exited lookups fail and the client freezes.

-- Minimal mock setup (self-contained, no test_helpers dependency)
local function mock_pty(id)
    return {
        id = function()
            return id
        end,
        title = function()
            return "mock"
        end,
        cwd = function()
            return nil
        end,
        size = function()
            return { rows = 24, cols = 80, width_px = 0, height_px = 0 }
        end,
        send_key = function() end,
        send_mouse = function() end,
        send_paste = function() end,
        set_focus = function() end,
        close = function() end,
        copy_selection = function() end,
    }
end

package.loaded["prise"] = {
    tiling = function() end,
    Terminal = function(opts)
        return { type = "terminal", pty = opts.pty }
    end,
    Text = function()
        return { type = "text" }
    end,
    Column = function()
        return { type = "column" }
    end,
    Row = function()
        return { type = "row" }
    end,
    Stack = function()
        return { type = "stack" }
    end,
    Positioned = function()
        return { type = "positioned" }
    end,
    TextInput = function()
        return { type = "text_input" }
    end,
    List = function()
        return { type = "list" }
    end,
    Box = function()
        return { type = "box" }
    end,
    Padding = function()
        return { type = "padding" }
    end,
    gwidth = function(s)
        return #s
    end,
    request_frame = function() end,
    save = function() end,
    exit = function() end,
    get_session_name = function()
        return "test"
    end,
    attach = function() end,
    switch_session = function()
        return true
    end,
    rename_session = function() end,
    create_session = function() end,
    create_text_input = function()
        return {
            text = function()
                return ""
            end,
            clear = function() end,
            insert = function() end,
        }
    end,
    log = { debug = function() end, info = function() end },
    set_timeout = function()
        return { cancel = function() end }
    end,
    get_git_branch = function()
        return nil
    end,
    get_time = function()
        return "12:00"
    end,
    list_sessions = function()
        return {}
    end,
}

local tiling = require("tiling")

local get_state = tiling._test.get_state

-- === deserialize_node uses pty:id(), not saved.id ===

-- Simulate ID remapping: saved state has pane id=1/pty_id=1,
-- but pty_lookup returns a PTY with id=5 (server remapped it)
local saved_single = {
    tabs = {
        {
            id = 1,
            root = { type = "pane", id = 1, pty_id = 1 },
            last_focused_id = 1,
        },
    },
    active_tab = 1,
    next_tab_id = 2,
    focused_id = 1,
    next_split_id = 1,
}

local function remapping_lookup(pty_id)
    if pty_id == 1 then
        return mock_pty(5) -- Server assigned new ID 5
    end
    return nil
end

tiling.set_state(saved_single, remapping_lookup)
local st = get_state()

assert(#st.tabs == 1, "remap: tab restored")
assert(st.tabs[1].root.id == 5, "remap: pane.id should be pty:id() (5), not saved id (1)")
assert(st.tabs[1].root.pty:id() == 5, "remap: pty:id() is 5")
assert(st.focused_id == 5, "remap: focused_id updated to actual PTY id")
assert(st.tabs[1].last_focused_id == 5, "remap: last_focused_id updated to actual PTY id")

-- === Split with multiple remapped panes ===
-- Saved focus was on pty_id=20 which the server remaps to id=200.
-- set_state must translate saved.focused_id (=20) through the old->new
-- remap table and land on 200 — not fall back to the first leaf (100).

local saved_split = {
    tabs = {
        {
            id = 1,
            root = {
                type = "split",
                split_id = 1,
                direction = "row",
                children = {
                    { type = "pane", id = 10, pty_id = 10 },
                    { type = "pane", id = 20, pty_id = 20 },
                },
            },
            last_focused_id = 20,
        },
    },
    active_tab = 1,
    next_tab_id = 2,
    focused_id = 20,
    next_split_id = 2,
}

local function split_remap_lookup(pty_id)
    if pty_id == 10 then
        return mock_pty(100)
    elseif pty_id == 20 then
        return mock_pty(200)
    end
    return nil
end

tiling.set_state(saved_split, split_remap_lookup)
st = get_state()

assert(#st.tabs == 1, "split remap: tab restored")
local root = st.tabs[1].root
assert(root.type == "split", "split remap: root is split")
assert(root.children[1].id == 100, "split remap: first pane id is 100")
assert(root.children[2].id == 200, "split remap: second pane id is 200")
assert(st.focused_id == 200, "split remap: focused_id follows remapped pane to 200")
assert(st.tabs[1].last_focused_id == 200, "split remap: last_focused_id follows remapped pane to 200")

-- === Floating pane with remapped ID ===

local saved_floating = {
    tabs = {
        {
            id = 1,
            root = { type = "pane", id = 1, pty_id = 1 },
            last_focused_id = 1,
            floating = {
                pane = { type = "pane", id = 2, pty_id = 2 },
                visible = true,
            },
        },
    },
    active_tab = 1,
    next_tab_id = 2,
    focused_id = 1,
    next_split_id = 1,
}

local function floating_remap_lookup(pty_id)
    if pty_id == 1 then
        return mock_pty(50)
    elseif pty_id == 2 then
        return mock_pty(60)
    end
    return nil
end

tiling.set_state(saved_floating, floating_remap_lookup)
st = get_state()

assert(st.tabs[1].root.id == 50, "floating remap: root pane id is 50")
assert(st.tabs[1].floating.pane.id == 60, "floating remap: floating pane id is 60")
assert(st.tabs[1].floating.visible == true, "floating remap: visibility preserved")

-- === Old format migration with remapped ID ===

local saved_old_format = {
    root = { type = "pane", id = 3, pty_id = 3 },
    focused_id = 3,
    next_split_id = 1,
}

local function old_format_remap(pty_id)
    if pty_id == 3 then
        return mock_pty(30)
    end
    return nil
end

tiling.set_state(saved_old_format, old_format_remap)
st = get_state()

assert(#st.tabs == 1, "old format remap: tab created")
assert(st.tabs[1].root.id == 30, "old format remap: pane id is 30")
assert(st.focused_id == 30, "old format remap: focused_id updated")
assert(st.tabs[1].last_focused_id == 30, "old format remap: last_focused_id updated")

-- === No remapping: IDs unchanged when PTY ID matches saved ID ===

local saved_no_remap = {
    tabs = {
        {
            id = 1,
            root = { type = "pane", id = 7, pty_id = 7 },
            last_focused_id = 7,
        },
    },
    active_tab = 1,
    next_tab_id = 2,
    focused_id = 7,
    next_split_id = 1,
}

local function identity_lookup(pty_id)
    if pty_id == 7 then
        return mock_pty(7) -- Same ID, no remapping
    end
    return nil
end

tiling.set_state(saved_no_remap, identity_lookup)
st = get_state()

assert(st.tabs[1].root.id == 7, "no remap: pane id stays 7")
assert(st.focused_id == 7, "no remap: focused_id stays 7")
assert(st.tabs[1].last_focused_id == 7, "no remap: last_focused_id stays 7")
