---@class TerminalOpts
---@field pty userdata
---@field ratio? number
---@field id? string
---@field focus? boolean
---@field show_cursor? boolean

---@class TextSegment
---@field text string
---@field style? table

---@class TextOpts
---@field text? string
---@field content? TextSegment[]
---@field show_cursor? boolean

---@class LayoutOpts
---@field children? table[]
---@field ratio? number
---@field id? string|number
---@field cross_axis_align? string
---@field resizable? boolean
---@field show_cursor? boolean

---@class PositionedOpts
---@field child? table
---@field x? number
---@field y? number
---@field anchor? string
---@field ratio? number
---@field id? string|number

---@class TextInputOpts
---@field input userdata
---@field style? table
---@field focus? boolean

---@class ListOpts
---@field items? string[]
---@field selected? number
---@field scroll_offset? number
---@field style? table
---@field selected_style? table

---@class BoxOpts
---@field child? table
---@field border? string
---@field style? table
---@field max_width? number
---@field max_height? number
---@field ratio? number For layout sizing
---@field id? string|number For widget identification

---@class PaddingOpts
---@field child? table
---@field all? number
---@field top? number
---@field bottom? number
---@field left? number
---@field right? number

---@class DividerOpts
---@field direction? "horizontal"|"vertical"
---@field style? table
---@field focus? boolean

---@class DividerSegment
---@field start number Starting position (row or col)
---@field end number Ending position (exclusive)
---@field style table Style for this segment

---@class SegmentedDividerOpts
---@field direction? "horizontal"|"vertical"
---@field segments? DividerSegment[]
---@field default_style? table

---@class PriseUI
---@field update fun(event: table) Handle an input event
---@field view fun(): table Return the widget tree to render
---@field get_state? fun(cwd_lookup: fun(id: number): string?): table Serialize UI state for persistence
---@field set_state? fun(saved: table?, pty_lookup: fun(id: number): userdata?) Restore UI state
---@field setup? fun(opts: table?) Configure the UI (optional)

local M = {}

---Load the tiling UI module
---@return PriseUI
function M.tiling()
    local ok, result = pcall(require, "prise_tiling_ui")
    if not ok then
        error("Failed to load tiling UI: " .. tostring(result))
    end
    return result
end

---Create a terminal widget that displays a PTY
---@param opts TerminalOpts
---@return table Terminal widget
function M.Terminal(opts)
    return {
        type = "terminal",
        pty = opts.pty,
        ratio = opts.ratio,
        id = opts.id,
        focus = opts.focus,
        show_cursor = opts.show_cursor,
    }
end

---Create a text widget with optional styling and segments
---@param opts string|TextSegment[]|TextOpts
---@return table Text widget
function M.Text(opts)
    if type(opts) == "string" then
        return {
            type = "text",
            content = { { text = opts } },
        }
    end

    if type(opts) == "table" and opts[1] ~= nil then
        return {
            type = "text",
            content = opts,
        }
    end

    -- If it has a 'text' key but not 'content', treat it as a single segment
    if opts.text and not opts.content then
        return {
            type = "text",
            content = { opts },
        }
    end

    return {
        type = "text",
        content = opts.content or {},
        show_cursor = opts.show_cursor,
    }
end

---Create a column layout that arranges children vertically
---@param opts table[]|LayoutOpts
---@return table Column widget
function M.Column(opts)
    -- If opts is an array (has numeric keys), it's just the children
    if opts[1] then
        ---@cast opts table[]
        return {
            type = "column",
            children = opts,
        }
    end

    ---@cast opts LayoutOpts
    return {
        type = "column",
        children = opts.children or {},
        ratio = opts.ratio,
        id = opts.id,
        cross_axis_align = opts.cross_axis_align,
        resizable = opts.resizable,
        show_cursor = opts.show_cursor,
    }
end

---Create a row layout that arranges children horizontally
---@param opts table[]|LayoutOpts
---@return table Row widget
function M.Row(opts)
    -- If opts is an array (has numeric keys), it's just the children
    if opts[1] then
        ---@cast opts table[]
        return {
            type = "row",
            children = opts,
        }
    end

    ---@cast opts LayoutOpts
    return {
        type = "row",
        children = opts.children or {},
        ratio = opts.ratio,
        id = opts.id,
        cross_axis_align = opts.cross_axis_align,
        resizable = opts.resizable,
        show_cursor = opts.show_cursor,
    }
end

---Create a stacked layout that overlays children on top of each other
---@param opts table[]|LayoutOpts
---@return table Stack widget
function M.Stack(opts)
    -- If opts is an array (has numeric keys), it's just the children
    if opts[1] then
        return {
            type = "stack",
            children = opts,
        }
    end

    return {
        type = "stack",
        children = opts.children or {},
        ratio = opts.ratio,
        id = opts.id,
    }
end

---Create a positioned widget that places a child at absolute coordinates
---@param opts PositionedOpts
---@return table Positioned widget
function M.Positioned(opts)
    return {
        type = "positioned",
        child = opts.child or opts[1],
        x = opts.x,
        y = opts.y,
        anchor = opts.anchor,
        ratio = opts.ratio,
        id = opts.id,
    }
end

---Create a text input widget for capturing user input
---@param opts TextInputOpts
---@return table TextInput widget
function M.TextInput(opts)
    return {
        type = "text_input",
        input = opts.input,
        style = opts.style,
        focus = opts.focus,
    }
end

---Create a list widget with items and optional selection
---@param opts ListOpts|string[]
---@return table List widget
function M.List(opts)
    return {
        type = "list",
        items = opts.items or opts,
        selected = opts.selected,
        scroll_offset = opts.scroll_offset,
        style = opts.style,
        selected_style = opts.selected_style,
    }
end

---Create a box widget with border and styling options
---@param opts BoxOpts
---@return table Box widget
function M.Box(opts)
    return {
        type = "box",
        child = opts.child or opts[1],
        border = opts.border,
        style = opts.style,
        max_width = opts.max_width,
        max_height = opts.max_height,
        ratio = opts.ratio, -- Propagate ratio for layout system
        id = opts.id, -- Propagate id for widget identification
    }
end

---Create a padding widget that adds spacing around a child
---@param opts PaddingOpts
---@return table Padding widget
function M.Padding(opts)
    return {
        type = "padding",
        child = opts.child or opts[1],
        all = opts.all,
        top = opts.top,
        bottom = opts.bottom,
        left = opts.left,
        right = opts.right,
    }
end

---Create a divider widget that draws a line (for tmux-style borders)
---@param opts DividerOpts
---@return table Divider widget
function M.Divider(opts)
    return {
        type = "divider",
        direction = opts.direction or "horizontal",
        style = opts.style,
        focus = opts.focus,
    }
end

---Create a segmented divider widget that can render different segments with different colors
---@param opts SegmentedDividerOpts
---@return table SegmentedDivider widget
function M.SegmentedDivider(opts)
    return {
        type = "segmented_divider",
        direction = opts.direction or "horizontal",
        segments = opts.segments or {},
        default_style = opts.default_style,
    }
end

return M
