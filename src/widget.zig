const std = @import("std");
const ziglua = @import("zlua");
const vaxis = @import("vaxis");

pub const BoxConstraints = struct {
    min_width: u16,
    max_width: ?u16,
    min_height: u16,
    max_height: ?u16,
};

pub const Size = struct {
    width: u16,
    height: u16,
};

pub const Widget = struct {
    x: u16 = 0,
    y: u16 = 0,
    width: u16 = 0,
    height: u16 = 0,
    flex: u8 = 0,
    kind: WidgetKind,

    pub fn deinit(self: *Widget, allocator: std.mem.Allocator) void {
        switch (self.kind) {
            .surface => {},
            .text => |*t| {
                for (t.spans) |span| {
                    allocator.free(span.text);
                }
                allocator.free(t.spans);
            },
            .column => |*c| {
                for (c.children) |*child| {
                    child.deinit(allocator);
                }
                allocator.free(c.children);
            },
        }
    }

    pub fn layout(self: *Widget, constraints: BoxConstraints) Size {
        const size = switch (self.kind) {
            .surface => Size{
                .width = constraints.max_width.?,
                .height = constraints.max_height.?,
            },
            .column => |*col| blk: {
                var width: u16 = 0;
                var height: u16 = 0;
                var total_flex: u32 = 0;

                // Pass 1: Measure non-flex children and count total flex
                for (col.children) |*child| {
                    if (child.flex == 0) {
                        const remaining_height = if (constraints.max_height) |max|
                            if (max > height) max - height else 0
                        else
                            null;

                        const child_constraints = BoxConstraints{
                            .min_width = 0,
                            .max_width = constraints.max_width,
                            .min_height = 0,
                            .max_height = remaining_height,
                        };

                        const child_size = child.layout(child_constraints);
                        child.height = child_size.height;
                        child.width = child_size.width;
                        height += child_size.height;
                        if (child_size.width > width) width = child_size.width;
                    } else {
                        total_flex += child.flex;
                    }
                }

                // Pass 2: Measure flex children
                if (total_flex > 0) {
                    const available_height = if (constraints.max_height) |max|
                        if (max > height) max - height else 0
                    else
                        0;

                    if (available_height > 0) {
                        // We need to distribute available_height among flex children
                        // We'll do a second pass to layout them
                        var remaining_flex_height = available_height;
                        var remaining_flex = total_flex;

                        for (col.children) |*child| {
                            if (child.flex > 0) {
                                // Calculate share
                                const share: u16 = @intCast((@as(u32, remaining_flex_height) * @as(u32, child.flex)) / remaining_flex);
                                remaining_flex_height -= share;
                                remaining_flex -= child.flex;

                                const child_constraints = BoxConstraints{
                                    .min_width = 0,
                                    .max_width = constraints.max_width,
                                    .min_height = share, // Force height? Or at least offer it?
                                    .max_height = share,
                                };

                                const child_size = child.layout(child_constraints);
                                child.height = child_size.height;
                                child.width = child_size.width;
                                height += child_size.height;
                                if (child_size.width > width) width = child_size.width;
                            }
                        }
                    } else {
                        // No space left for flex children, set them to 0 height
                        for (col.children) |*child| {
                            if (child.flex > 0) {
                                child.height = 0;
                                child.width = 0;
                            }
                        }
                    }
                }

                // Final pass: Position children
                var current_y: u16 = 0;
                for (col.children) |*child| {
                    child.y = current_y;

                    switch (col.cross_axis_align) {
                        .start => {
                            child.x = 0;
                            // Keep intrinsic width
                        },
                        .center => {
                            if (width > child.width) {
                                child.x = (width - child.width) / 2;
                            } else {
                                child.x = 0;
                            }
                        },
                        .end => {
                            if (width > child.width) {
                                child.x = width - child.width;
                            } else {
                                child.x = 0;
                            }
                        },
                        .stretch => {
                            child.x = 0;
                            child.width = width;
                        },
                    }

                    current_y += child.height;
                }

                break :blk Size{
                    .width = width,
                    .height = height,
                };
            },
            .text => |*text| blk: {
                // For layout, we need to iterate to calculate height.
                // But iterator allocates. Since layout is called often, we should probably
                // try to minimize allocation. However, strict correctness for wrapping requires
                // the full iteration logic.
                //
                // We can use a GPA for layout which is acceptable as layout is usually
                // per-frame or per-resize.
                var gpa = std.heap.GeneralPurposeAllocator(.{}){};
                const alloc = gpa.allocator();
                defer _ = gpa.deinit();

                var iter = Text.Iterator{
                    .text = text.*,
                    .max_width = constraints.max_width orelse 65535,
                    .allocator = alloc,
                };

                var max_w: u16 = 0;
                var height: u16 = 0;

                while (iter.next() catch null) |line| {
                    defer alloc.free(line.segments);
                    if (line.width > max_w) max_w = line.width;
                    height += 1;
                }

                break :blk Size{
                    .width = max_w,
                    .height = height,
                };
            },
        };
        self.width = size.width;
        self.height = size.height;
        return size;
    }

    pub fn paint(self: *const Widget) !void {
        switch (self.kind) {
            .surface => |surface| {
                _ = surface;
                // TODO: paint surface at self.x, self.y, self.width, self.height
            },
            .text => {},
            .column => |*col| {
                for (col.children) |*child| {
                    try child.paint();
                }
            },
        }
    }
};

pub const WidgetKind = union(enum) {
    surface: Surface,
    text: Text,
    column: Column,
};

pub const CrossAxisAlignment = enum {
    start,
    center,
    end,
    stretch,
};

pub const Column = struct {
    children: []Widget,
    cross_axis_align: CrossAxisAlignment = .center,
};

pub const Surface = struct {
    pty_id: u32,
};

pub const Text = struct {
    spans: []Span,
    wrap: Wrap = .none,
    // We must quote align because it is a keyword
    @"align": Align = .left,

    pub const Span = struct {
        text: []const u8,
        style: vaxis.Style,
    };

    pub const Wrap = enum {
        none,
        word,
        char,
    };

    pub const Align = enum {
        left,
        center,
        right,
    };

    pub const Line = struct {
        width: u16,
        segments: []vaxis.Segment,
    };

    pub const Iterator = struct {
        text: Text,
        max_width: u16,
        allocator: std.mem.Allocator,

        // State
        span_idx: usize = 0,
        byte_offset: usize = 0, // offset into current span text
        done: bool = false,

        pub fn next(self: *Iterator) !?Line {
            if (self.done) return null;
            if (self.text.spans.len == 0) {
                self.done = true;
                return null;
            }
            if (self.span_idx >= self.text.spans.len) {
                self.done = true;
                return null;
            }

            var line_segments = std.ArrayList(vaxis.Segment).empty;
            errdefer line_segments.deinit(self.allocator);

            var current_width: u16 = 0;

            while (self.span_idx < self.text.spans.len) {
                const span = self.text.spans[self.span_idx];
                const remaining_text = span.text[self.byte_offset..];

                // If we are at the start of a span and it's empty, skip it (unless it's the only thing?)
                if (remaining_text.len == 0) {
                    self.span_idx += 1;
                    self.byte_offset = 0;
                    continue;
                }

                // If no wrap, take everything
                if (self.text.wrap == .none) {
                    try line_segments.append(self.allocator, .{
                        .text = remaining_text,
                        .style = span.style,
                    });
                    current_width += vaxis.gwidth.gwidth(remaining_text, .unicode);
                    self.span_idx += 1;
                    self.byte_offset = 0;
                    continue;
                }

                // Calculate how much we can fit
                const available = if (self.max_width > current_width) self.max_width - current_width else 0;

                // If no space left on this line and we have content, break line
                if (available == 0 and line_segments.items.len > 0) {
                    break;
                }

                // Find split point
                // This is a simplified logic. For robust wrapping we need proper grapheme/word boundary analysis.
                // Using gwidth on substrings is slow but accurate.

                var fit_len: usize = 0;
                var fit_width: u16 = 0;
                // Iterate graphemes to find fit
                var iter = std.unicode.Utf8View.init(remaining_text) catch unreachable; // Should be valid UTF8
                var iterator = iter.iterator();

                var last_space_idx: ?usize = null;
                var last_space_width: u16 = 0;

                while (iterator.nextCodepointSlice()) |grapheme| {
                    const w = vaxis.gwidth.gwidth(grapheme, .unicode);
                    if (current_width + fit_width + w > self.max_width) {
                        // Overflow
                        break;
                    }
                    fit_width += w;
                    fit_len += grapheme.len;

                    // Track word boundaries (very basic: space)
                    if (std.mem.indexOfScalar(u8, grapheme, ' ') != null) {
                        last_space_idx = fit_len;
                        last_space_width = fit_width;
                    }
                }

                // If we couldn't fit anything
                if (fit_len == 0) {
                    // If line is empty, force take at least one grapheme to avoid infinite loop
                    if (line_segments.items.len == 0) {
                        var it = iter.iterator();
                        if (it.nextCodepointSlice()) |g| {
                            fit_len = g.len;
                            fit_width = vaxis.gwidth.gwidth(g, .unicode);
                        }
                    } else {
                        // Line not empty, push to next line
                        break;
                    }
                } else {
                    // If wrap word, back up to last space if we didn't finish the span
                    // But only if we are actually breaking the line (fit_len < remaining_text.len)
                    // AND we found a space
                    if (self.text.wrap == .word and fit_len < remaining_text.len) {
                        if (last_space_idx) |idx| {
                            fit_len = idx;
                            fit_width = last_space_width;
                        }
                    }
                }

                const segment_text = remaining_text[0..fit_len];
                try line_segments.append(self.allocator, .{
                    .text = segment_text,
                    .style = span.style,
                });
                current_width += fit_width;
                self.byte_offset += fit_len;

                // If we finished this span, move to next
                if (self.byte_offset >= span.text.len) {
                    self.span_idx += 1;
                    self.byte_offset = 0;
                }

                // If we broke early (didn't consume full remaining text), then the line is full
                if (fit_len < remaining_text.len) {
                    break;
                }
            }

            if (line_segments.items.len == 0 and !self.done) {
                // Ensure we don't return empty lines indefinitely if something goes wrong,
                // but valid empty text might result in empty line.
                // If done=false and loop finished with 0 segments, it means we exhausted spans.
                self.done = true;
                // If we were invoked, we should return at least one line if text is empty?
                // Logic at start handles spans.len == 0.
                return null;
            }

            return Line{
                .width = current_width,
                .segments = try line_segments.toOwnedSlice(self.allocator),
            };
        }
    };
};

pub fn parseWidget(lua: *ziglua.Lua, allocator: std.mem.Allocator, index: i32) !Widget {
    if (lua.typeOf(index) != .table) {
        return error.InvalidWidget;
    }

    _ = lua.getField(index, "type");
    if (lua.typeOf(-1) != .string) {
        lua.pop(1);
        return error.MissingWidgetType;
    }
    const widget_type = try lua.toString(-1);
    lua.pop(1);

    var flex: u8 = 0;
    _ = lua.getField(index, "flex");
    if (lua.typeOf(-1) == .number) {
        flex = @intCast(try lua.toInteger(-1));
    }
    lua.pop(1);

    if (std.mem.eql(u8, widget_type, "surface")) {
        // Surface default flex is 1 if not specified?
        // User said: "a surface should probably be flex = 1 by default"
        // But we already parsed flex=0 if not present.
        // So if flex field was missing (or 0), we should set it to 1?
        // Or maybe only if it was missing.
        // But standard practice is usually explicit.
        // However, the requirement is "surface should probably be flex = 1 by default".
        // Let's check if "flex" field existed.
        // Actually, simpler: if we didn't find flex (so flex==0), and it's a surface, make it 1.
        // But what if user wants fixed surface? They can set flex=0.
        // To distinguish "not set" from "set to 0", we'd need to check field existence.
        // For now, let's assume surface implies flex=1 unless overridden?
        // The simplest way to support "default flex=1" without complex logic is:
        // if type is surface and we didn't see a flex > 0, default to 1?
        // But then user can't set flex=0.
        // Let's check properly.

        var actual_flex = flex;
        _ = lua.getField(index, "flex");
        if (lua.typeOf(-1) == .nil) {
            actual_flex = 1;
        }
        lua.pop(1);

        _ = lua.getField(index, "pty");

        if (lua.typeOf(-1) != .number) {
            lua.pop(1);
            return error.MissingPtyId;
        }

        const pty_id = try lua.toInteger(-1);
        lua.pop(1);

        return .{ .flex = actual_flex, .kind = .{ .surface = .{ .pty_id = @intCast(pty_id) } } };
    } else if (std.mem.eql(u8, widget_type, "column")) {
        _ = lua.getField(index, "children");
        if (lua.typeOf(-1) != .table) {
            lua.pop(1);
            return error.MissingColumnChildren;
        }

        var children = std.ArrayList(Widget).empty;
        errdefer {
            for (children.items) |*c| c.deinit(allocator);
            children.deinit(allocator);
        }

        const len = lua.rawLen(-1);
        for (1..len + 1) |i| {
            _ = lua.getIndex(-1, @intCast(i));
            // recursive call
            const child = try parseWidget(lua, allocator, -1);
            try children.append(allocator, child);
            lua.pop(1);
        }
        lua.pop(1); // children

        var cross_align: CrossAxisAlignment = .center;
        _ = lua.getField(index, "cross_axis_align");
        if (lua.typeOf(-1) == .string) {
            const s = try lua.toString(-1);
            if (std.mem.eql(u8, s, "start")) cross_align = .start;
            if (std.mem.eql(u8, s, "center")) cross_align = .center;
            if (std.mem.eql(u8, s, "end")) cross_align = .end;
            if (std.mem.eql(u8, s, "stretch")) cross_align = .stretch;
        }
        lua.pop(1);

        return .{ .flex = flex, .kind = .{ .column = .{
            .children = try children.toOwnedSlice(allocator),
            .cross_axis_align = cross_align,
        } } };
    } else if (std.mem.eql(u8, widget_type, "text")) {
        _ = lua.getField(index, "content");
        if (lua.typeOf(-1) != .table) {
            lua.pop(1);
            return error.MissingTextContent;
        }

        var spans = std.ArrayList(Text.Span).empty;
        errdefer {
            for (spans.items) |span| allocator.free(span.text);
            spans.deinit(allocator);
        }

        const len = lua.rawLen(-1);
        for (1..len + 1) |i| {
            _ = lua.getIndex(-1, @intCast(i));
            defer lua.pop(1);

            if (lua.typeOf(-1) == .string) {
                const text = try lua.toString(-1);
                try spans.append(allocator, .{
                    .text = try allocator.dupe(u8, text),
                    .style = .{},
                });
            } else if (lua.typeOf(-1) == .table) {
                _ = lua.getField(-1, "text");
                if (lua.typeOf(-1) != .string) {
                    lua.pop(1);
                    continue;
                }
                const text = try lua.toString(-1);
                lua.pop(1);

                var style = vaxis.Style{};

                _ = lua.getField(-1, "style");
                if (lua.typeOf(-1) == .table) {
                    style = try parseStyle(lua, -1);
                }
                lua.pop(1);

                try spans.append(allocator, .{
                    .text = try allocator.dupe(u8, text),
                    .style = style,
                });
            }
        }
        lua.pop(1); // content

        var wrap: Text.Wrap = .none;
        _ = lua.getField(index, "wrap");
        if (lua.typeOf(-1) == .string) {
            const s = try lua.toString(-1);
            if (std.mem.eql(u8, s, "word")) wrap = .word;
            if (std.mem.eql(u8, s, "char")) wrap = .char;
        }
        lua.pop(1);

        var @"align": Text.Align = .left;
        _ = lua.getField(index, "align");
        if (lua.typeOf(-1) == .string) {
            const s = try lua.toString(-1);
            if (std.mem.eql(u8, s, "center")) @"align" = .center;
            if (std.mem.eql(u8, s, "right")) @"align" = .right;
        }
        lua.pop(1);

        return .{ .flex = flex, .kind = .{ .text = .{
            .spans = try spans.toOwnedSlice(allocator),
            .wrap = wrap,
            .@"align" = @"align",
        } } };
    }

    return error.UnknownWidgetType;
}

fn parseStyle(lua: *ziglua.Lua, index: i32) !vaxis.Style {
    var style = vaxis.Style{};

    if (lua.typeOf(index) != .table) return style;

    // Colors
    _ = lua.getField(index, "fg");
    if (lua.typeOf(-1) == .string) {
        style.fg = try parseColor(try lua.toString(-1));
    }
    lua.pop(1);

    _ = lua.getField(index, "bg");
    if (lua.typeOf(-1) == .string) {
        style.bg = try parseColor(try lua.toString(-1));
    }
    lua.pop(1);

    // Attributes
    _ = lua.getField(index, "bold");
    if (lua.typeOf(-1) == .boolean) style.bold = lua.toBoolean(-1);
    lua.pop(1);

    _ = lua.getField(index, "dim");
    if (lua.typeOf(-1) == .boolean) style.dim = lua.toBoolean(-1);
    lua.pop(1);

    _ = lua.getField(index, "italic");
    if (lua.typeOf(-1) == .boolean) style.italic = lua.toBoolean(-1);
    lua.pop(1);

    _ = lua.getField(index, "underline");
    if (lua.typeOf(-1) == .boolean and lua.toBoolean(-1)) style.ul_style = .single;
    lua.pop(1);

    _ = lua.getField(index, "blink");
    if (lua.typeOf(-1) == .boolean) style.blink = lua.toBoolean(-1);
    lua.pop(1);

    _ = lua.getField(index, "reverse");
    if (lua.typeOf(-1) == .boolean) style.reverse = lua.toBoolean(-1);
    lua.pop(1);

    _ = lua.getField(index, "strikethrough");
    if (lua.typeOf(-1) == .boolean) style.strikethrough = lua.toBoolean(-1);
    lua.pop(1);

    return style;
}

fn parseColor(str: []const u8) !vaxis.Color {
    if (std.mem.startsWith(u8, str, "#")) {
        if (str.len != 7) return .default;
        const r = std.fmt.parseInt(u8, str[1..3], 16) catch return .default;
        const g = std.fmt.parseInt(u8, str[3..5], 16) catch return .default;
        const b = std.fmt.parseInt(u8, str[5..7], 16) catch return .default;
        return .{ .rgb = .{ r, g, b } };
    }
    if (std.mem.eql(u8, str, "red")) return .{ .rgb = .{ 255, 0, 0 } };
    if (std.mem.eql(u8, str, "green")) return .{ .rgb = .{ 0, 255, 0 } };
    if (std.mem.eql(u8, str, "blue")) return .{ .rgb = .{ 0, 0, 255 } };
    if (std.mem.eql(u8, str, "black")) return .{ .rgb = .{ 0, 0, 0 } };
    if (std.mem.eql(u8, str, "white")) return .{ .rgb = .{ 255, 255, 255 } };
    if (std.mem.eql(u8, str, "yellow")) return .{ .rgb = .{ 255, 255, 0 } };
    if (std.mem.eql(u8, str, "magenta")) return .{ .rgb = .{ 255, 0, 255 } };
    if (std.mem.eql(u8, str, "cyan")) return .{ .rgb = .{ 0, 255, 255 } };
    return .default;
}

test "parseWidget - surface default flex" {
    const testing = std.testing;
    const allocator = testing.allocator;

    var lua = try ziglua.Lua.init(allocator);
    defer lua.deinit();

    lua.createTable(0, 2);
    _ = lua.pushString("surface");
    lua.setField(-2, "type");
    _ = lua.pushInteger(1);
    lua.setField(-2, "pty");

    var w = try parseWidget(lua, allocator, -1);
    defer w.deinit(allocator);

    try testing.expectEqual(@as(u8, 1), w.flex);
}

test "parseWidget - explicit flex" {
    const testing = std.testing;
    const allocator = testing.allocator;

    var lua = try ziglua.Lua.init(allocator);
    defer lua.deinit();

    // Text with flex=1
    lua.createTable(0, 3);
    _ = lua.pushString("text");
    lua.setField(-2, "type");
    lua.createTable(0, 0);
    lua.setField(-2, "content");
    _ = lua.pushInteger(1);
    lua.setField(-2, "flex");

    var w = try parseWidget(lua, allocator, -1);
    defer w.deinit(allocator);

    try testing.expectEqual(@as(u8, 1), w.flex);

    // Surface with flex=2
    lua.createTable(0, 3);
    _ = lua.pushString("surface");
    lua.setField(-2, "type");
    _ = lua.pushInteger(1);
    lua.setField(-2, "pty");
    _ = lua.pushInteger(2);
    lua.setField(-2, "flex");

    var w2 = try parseWidget(lua, allocator, -1);
    defer w2.deinit(allocator);

    try testing.expectEqual(@as(u8, 2), w2.flex);
}

test "Column Layout - Flex" {
    const testing = std.testing;
    const allocator = testing.allocator;

    // Create widgets manually
    var child1 = Widget{
        .kind = .{ .text = .{ .spans = try allocator.dupe(Text.Span, &.{.{ .text = "Fixed", .style = .{} }}) } },
        .flex = 0,
    };
    // Manually copy string because deinit will try to free it
    child1.kind.text.spans[0].text = try allocator.dupe(u8, "Fixed");

    const child2 = Widget{
        .kind = .{ .surface = .{ .pty_id = 1 } },
        .flex = 1,
    };

    var children = [_]Widget{ child1, child2 };
    var col = Widget{
        .kind = .{ .column = .{ .children = &children } },
    };

    // Layout in 100x20 box
    const constraints = BoxConstraints{
        .min_width = 0,
        .max_width = 100,
        .min_height = 0,
        .max_height = 20,
    };

    const size = col.layout(constraints);

    try testing.expectEqual(@as(u16, 20), size.height);
    // Child 1 (Fixed) should be 1 high
    try testing.expectEqual(@as(u16, 1), children[0].height);
    try testing.expectEqual(@as(u16, 0), children[0].y);

    // Child 2 (Flex) should be 19 high
    try testing.expectEqual(@as(u16, 19), children[1].height);
    try testing.expectEqual(@as(u16, 1), children[1].y);

    // Clean up manually since we constructed manually
    allocator.free(children[0].kind.text.spans[0].text);
    allocator.free(children[0].kind.text.spans);
}

test "Column Layout - Stretch Width" {
    const testing = std.testing;
    const allocator = testing.allocator;

    // Child 1: Text "Small"
    var child1 = Widget{
        .kind = .{ .text = .{ .spans = try allocator.dupe(Text.Span, &.{.{ .text = "Small", .style = .{} }}) } },
        .flex = 0,
    };
    child1.kind.text.spans[0].text = try allocator.dupe(u8, "Small");

    // Child 2: Surface (Full Width)
    const child2 = Widget{
        .kind = .{ .surface = .{ .pty_id = 1 } },
        .flex = 1,
    };

    var children = [_]Widget{ child1, child2 };
    var col = Widget{
        .kind = .{ .column = .{ .children = &children, .cross_axis_align = .stretch } },
    };

    const constraints = BoxConstraints{
        .min_width = 0,
        .max_width = 100,
        .min_height = 0,
        .max_height = 20,
    };

    const size = col.layout(constraints);

    try testing.expectEqual(@as(u16, 100), size.width);

    // Child 2 should be 100 wide
    try testing.expectEqual(@as(u16, 100), children[1].width);

    // Child 1 should ALSO be 100 wide (stretched)
    try testing.expectEqual(@as(u16, 100), children[0].width);

    allocator.free(children[0].kind.text.spans[0].text);
    allocator.free(children[0].kind.text.spans);
}

test "parseWidget - text" {
    const testing = std.testing;
    const allocator = testing.allocator;

    var lua = try ziglua.Lua.init(allocator);
    defer lua.deinit();

    // Test simple text
    {
        lua.createTable(0, 2);
        _ = lua.pushString("text");
        lua.setField(-2, "type");
        lua.createTable(1, 0);
        _ = lua.pushString("Hello");
        lua.rawSetIndex(-2, 1);
        lua.setField(-2, "content");

        var w = try parseWidget(lua, allocator, -1);
        defer w.deinit(allocator);

        try testing.expectEqual(std.meta.Tag(WidgetKind).text, std.meta.activeTag(w.kind));
        try testing.expectEqualStrings("Hello", w.kind.text.spans[0].text);
    }

    // Test attributes
    {
        lua.createTable(0, 2);
        _ = lua.pushString("text");
        lua.setField(-2, "type");
        lua.createTable(1, 0);
        _ = lua.pushString("Content");
        lua.rawSetIndex(-2, 1);
        lua.setField(-2, "content");
        _ = lua.pushString("word");
        lua.setField(-2, "wrap");
        _ = lua.pushString("center");
        lua.setField(-2, "align");

        var w = try parseWidget(lua, allocator, -1);
        defer w.deinit(allocator);

        try testing.expectEqual(Text.Wrap.word, w.kind.text.wrap);
        try testing.expectEqual(Text.Align.center, w.kind.text.@"align");
    }
}

test "parseWidget - column" {
    const testing = std.testing;
    const allocator = testing.allocator;

    var lua = try ziglua.Lua.init(allocator);
    defer lua.deinit();

    // Create column widget table
    lua.createTable(0, 2);
    _ = lua.pushString("column");
    lua.setField(-2, "type");

    // Create children table
    lua.createTable(2, 0);

    // Child 1: text
    lua.createTable(0, 2);
    _ = lua.pushString("text");
    lua.setField(-2, "type");
    lua.createTable(1, 0);
    _ = lua.pushString("Child 1");
    lua.rawSetIndex(-2, 1);
    lua.setField(-2, "content");
    lua.rawSetIndex(-2, 1);

    // Child 2: text
    lua.createTable(0, 2);
    _ = lua.pushString("text");
    lua.setField(-2, "type");
    lua.createTable(1, 0);
    _ = lua.pushString("Child 2");
    lua.rawSetIndex(-2, 1);
    lua.setField(-2, "content");
    lua.rawSetIndex(-2, 2);

    lua.setField(-2, "children");

    var w = try parseWidget(lua, allocator, -1);
    defer w.deinit(allocator);

    try testing.expectEqual(std.meta.Tag(WidgetKind).column, std.meta.activeTag(w.kind));
    try testing.expectEqual(@as(usize, 2), w.kind.column.children.len);
    try testing.expectEqualStrings("Child 1", w.kind.column.children[0].kind.text.spans[0].text);

    // Default alignment
    try testing.expectEqual(CrossAxisAlignment.center, w.kind.column.cross_axis_align);

    // Test explicit alignment
    lua.createTable(0, 2);
    _ = lua.pushString("column");
    lua.setField(-2, "type");
    lua.createTable(0, 0);
    lua.setField(-2, "children");
    _ = lua.pushString("stretch");
    lua.setField(-2, "cross_axis_align");

    var w2 = try parseWidget(lua, allocator, -1);
    defer w2.deinit(allocator);

    try testing.expectEqual(CrossAxisAlignment.stretch, w2.kind.column.cross_axis_align);
}

test "Text Iterator" {
    const testing = std.testing;
    const allocator = testing.allocator;

    // Test simple wrapping
    var spans = [_]Text.Span{
        .{ .text = "Hello World", .style = .{} },
    };
    const text = Text{ .spans = &spans, .wrap = .word };

    var iter = Text.Iterator{
        .text = text,
        .max_width = 5,
        .allocator = allocator,
    };

    const l1 = (try iter.next()).?;
    defer allocator.free(l1.segments);
    try testing.expectEqualStrings("Hello", l1.segments[0].text);

    const l2 = (try iter.next()).?;
    defer allocator.free(l2.segments);
    try testing.expectEqualStrings(" ", l2.segments[0].text);

    const l3 = (try iter.next()).?;
    defer allocator.free(l3.segments);
    try testing.expectEqualStrings("World", l3.segments[0].text);

    try testing.expect((try iter.next()) == null);

    // Test no wrap
    const text_nowrap = Text{ .spans = &spans, .wrap = .none };
    var iter_nowrap = Text.Iterator{
        .text = text_nowrap,
        .max_width = 8,
        .allocator = allocator,
    };

    const l_nowrap = (try iter_nowrap.next()).?;
    defer allocator.free(l_nowrap.segments);
    try testing.expectEqualStrings("Hello World", l_nowrap.segments[0].text);
    try testing.expect((try iter_nowrap.next()) == null);
}
