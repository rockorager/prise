const std = @import("std");
const vaxis = @import("vaxis");
const msgpack = @import("msgpack.zig");

const Surface = @This();

front: *vaxis.AllocatingScreen,
back: *vaxis.AllocatingScreen,
allocator: std.mem.Allocator,
rows: u16,
cols: u16,
cursor_shape: redraw.UIEvent.CursorShape.Shape = .block,
dirty: bool = false,
hl_attrs: std.AutoHashMap(u32, vaxis.Style),

const redraw = @import("redraw.zig");

pub fn init(allocator: std.mem.Allocator, rows: u16, cols: u16) !Surface {
    const front = try allocator.create(vaxis.AllocatingScreen);
    errdefer allocator.destroy(front);

    const back = try allocator.create(vaxis.AllocatingScreen);
    errdefer allocator.destroy(back);

    front.* = try vaxis.AllocatingScreen.init(allocator, cols, rows);
    errdefer front.deinit(allocator);

    back.* = try vaxis.AllocatingScreen.init(allocator, cols, rows);

    return .{
        .front = front,
        .back = back,
        .allocator = allocator,
        .rows = rows,
        .cols = cols,
        .hl_attrs = std.AutoHashMap(u32, vaxis.Style).init(allocator),
    };
}

pub fn deinit(self: *Surface) void {
    self.front.deinit(self.allocator);
    self.allocator.destroy(self.front);
    self.back.deinit(self.allocator);
    self.allocator.destroy(self.back);
    self.hl_attrs.deinit();
}

pub fn resize(self: *Surface, rows: u16, cols: u16) !void {
    // Deinit old screens
    self.front.deinit(self.allocator);
    self.back.deinit(self.allocator);

    // Reinit with new size
    self.front.* = try vaxis.AllocatingScreen.init(self.allocator, cols, rows);
    self.back.* = try vaxis.AllocatingScreen.init(self.allocator, cols, rows);

    self.rows = rows;
    self.cols = cols;
    self.dirty = true;
}

pub fn applyRedraw(self: *Surface, params: msgpack.Value) !void {
    const start_time = std.time.nanoTimestamp();

    if (params != .array) return error.InvalidRedrawParams;

    std.log.debug("applyRedraw: received params with {} events", .{params.array.len});

    var rows_updated = std.ArrayList(usize).empty;
    defer rows_updated.deinit(self.allocator);

    // Don't reset the arena or copy - back buffer already has the full state from last render
    // write events will update only changed rows
    // The arena keeps growing but only with new/changed cell text

    for (params.array) |event_val| {
        if (event_val != .array or event_val.array.len < 2) continue;

        const event_name = event_val.array[0];
        if (event_name != .string) continue;

        const event_params = event_val.array[1];
        if (event_params != .array) continue;

        if (std.mem.eql(u8, event_name.string, "resize")) {
            if (event_params.array.len < 3) continue;

            // args: [pty, rows, cols]
            const rows = switch (event_params.array[1]) {
                .unsigned => |u| @as(u16, @intCast(u)),
                .integer => |i| @as(u16, @intCast(i)),
                else => continue,
            };
            const cols = switch (event_params.array[2]) {
                .unsigned => |u| @as(u16, @intCast(u)),
                .integer => |i| @as(u16, @intCast(i)),
                else => continue,
            };

            // Only resize if dimensions actually changed
            if (rows != self.rows or cols != self.cols) {
                std.log.debug("resize: resizing from {}x{} to {}x{}", .{ self.cols, self.rows, cols, rows });
                try self.resize(rows, cols);
            }
        } else if (std.mem.eql(u8, event_name.string, "cursor_pos")) {
            if (event_params.array.len < 3) continue;

            // args: [pty, row, col]
            const row = switch (event_params.array[1]) {
                .unsigned => |u| @as(u16, @intCast(u)),
                .integer => |i| @as(u16, @intCast(i)),
                else => continue,
            };
            const col = switch (event_params.array[2]) {
                .unsigned => |u| @as(u16, @intCast(u)),
                .integer => |i| @as(u16, @intCast(i)),
                else => continue,
            };

            self.back.cursor_row = row;
            self.back.cursor_col = col;
            self.back.cursor_vis = true;
            self.dirty = true;
        } else if (std.mem.eql(u8, event_name.string, "cursor_shape")) {
            if (event_params.array.len < 2) continue;

            // args: [pty, shape]
            const shape_int = switch (event_params.array[1]) {
                .unsigned => |u| @as(u8, @intCast(u)),
                .integer => |i| @as(u8, @intCast(i)),
                else => continue,
            };

            self.cursor_shape = @enumFromInt(shape_int);
            self.dirty = true;
        } else if (std.mem.eql(u8, event_name.string, "write")) {
            if (event_params.array.len < 4) continue;

            // args: [pty, row, col, cells]
            const row = switch (event_params.array[1]) {
                .unsigned => |u| @as(usize, @intCast(u)),
                .integer => |i| @as(usize, @intCast(i)),
                else => continue,
            };
            var col = switch (event_params.array[2]) {
                .unsigned => |u| @as(usize, @intCast(u)),
                .integer => |i| @as(usize, @intCast(i)),
                else => continue,
            };

            const cells = event_params.array[3];
            if (cells != .array) continue;

            try rows_updated.append(self.allocator, row);

            // style_id semantics:
            // - Absent or nil => reuse previous cell style within this write batch
            // - 0 => default style
            // current_hl resets to 0 at the start of each write event
            var current_hl: u32 = 0;
            for (cells.array) |cell| {
                if (cell != .array or cell.array.len == 0) continue;

                // cell: [grapheme, style_id?, repeat?]
                const text = if (cell.array[0] == .string) cell.array[0].string else " ";

                if (cell.array.len > 1 and cell.array[1] != .nil) {
                    // Only update when present and not nil; nil means “no change”
                    current_hl = switch (cell.array[1]) {
                        .unsigned => |u| @as(u32, @intCast(u)),
                        .integer => |i| @as(u32, @intCast(i)),
                        else => current_hl,
                    };
                }

                const repeat: usize = if (cell.array.len > 2 and cell.array[2] != .nil)
                    switch (cell.array[2]) {
                        .unsigned => |u| @intCast(u),
                        .integer => |i| @intCast(i),
                        else => 1,
                    }
                else
                    1;

                const style = self.hl_attrs.get(current_hl) orelse vaxis.Style{};

                var i: usize = 0;
                while (i < repeat) : (i += 1) {
                    if (col < self.cols and row < self.rows) {
                        self.back.writeCell(@intCast(col), @intCast(row), .{
                            .char = .{ .grapheme = text },
                            .style = style,
                        });
                    }
                    col += 1;
                }
            }
            self.dirty = true;
        } else if (std.mem.eql(u8, event_name.string, "style")) {
            if (event_params.array.len < 2) continue;

            // args: [id, map]
            const id = switch (event_params.array[0]) {
                .unsigned => |u| @as(u32, @intCast(u)),
                .integer => |i| @as(u32, @intCast(i)),
                else => continue,
            };

            const attrs = event_params.array[1];
            if (attrs != .map) continue;

            var style = vaxis.Style{};

            for (attrs.map) |kv| {
                if (kv.key != .string) continue;
                const key = kv.key.string;

                if (std.mem.eql(u8, key, "fg")) {
                    const val: ?u32 = switch (kv.value) {
                        .unsigned => |u| @intCast(u),
                        .integer => |i| @intCast(i),
                        else => null,
                    };
                    if (val) |v| {
                        style.fg = .{ .rgb = .{
                            @intCast((v >> 16) & 0xFF),
                            @intCast((v >> 8) & 0xFF),
                            @intCast(v & 0xFF),
                        } };
                    }
                } else if (std.mem.eql(u8, key, "fg_idx")) {
                    const val: ?u8 = switch (kv.value) {
                        .unsigned => |u| @intCast(u),
                        .integer => |i| @intCast(i),
                        else => null,
                    };
                    if (val) |v| {
                        style.fg = .{ .index = v };
                    }
                } else if (std.mem.eql(u8, key, "bg")) {
                    const val: ?u32 = switch (kv.value) {
                        .unsigned => |u| @intCast(u),
                        .integer => |i| @intCast(i),
                        else => null,
                    };
                    if (val) |v| {
                        style.bg = .{ .rgb = .{
                            @intCast((v >> 16) & 0xFF),
                            @intCast((v >> 8) & 0xFF),
                            @intCast(v & 0xFF),
                        } };
                    }
                } else if (std.mem.eql(u8, key, "bg_idx")) {
                    const val: ?u8 = switch (kv.value) {
                        .unsigned => |u| @intCast(u),
                        .integer => |i| @intCast(i),
                        else => null,
                    };
                    if (val) |v| {
                        style.bg = .{ .index = v };
                    }
                } else if (std.mem.eql(u8, key, "bold")) {
                    if (kv.value == .boolean) style.bold = kv.value.boolean;
                } else if (std.mem.eql(u8, key, "dim")) {
                    if (kv.value == .boolean) style.dim = kv.value.boolean;
                } else if (std.mem.eql(u8, key, "italic")) {
                    if (kv.value == .boolean) style.italic = kv.value.boolean;
                } else if (std.mem.eql(u8, key, "underline")) {
                    if (kv.value == .boolean and kv.value.boolean) {
                        // Only set if not already set by ul_style
                        if (style.ul_style == .off) {
                            style.ul_style = .single;
                        }
                    }
                } else if (std.mem.eql(u8, key, "ul_style")) {
                    const val: ?u8 = switch (kv.value) {
                        .unsigned => |u| @intCast(u),
                        .integer => |i| @intCast(i),
                        else => null,
                    };
                    if (val) |v| {
                        style.ul_style = switch (v) {
                            1 => .single,
                            2 => .double,
                            3 => .curly,
                            4 => .dotted,
                            5 => .dashed,
                            else => .off,
                        };
                    }
                } else if (std.mem.eql(u8, key, "ul_color")) {
                    const val: ?u32 = switch (kv.value) {
                        .unsigned => |u| @intCast(u),
                        .integer => |i| @intCast(i),
                        else => null,
                    };
                    if (val) |v| {
                        style.ul = .{ .rgb = .{
                            @intCast((v >> 16) & 0xFF),
                            @intCast((v >> 8) & 0xFF),
                            @intCast(v & 0xFF),
                        } };
                    }
                } else if (std.mem.eql(u8, key, "strikethrough")) {
                    if (kv.value == .boolean) style.strikethrough = kv.value.boolean;
                } else if (std.mem.eql(u8, key, "reverse")) {
                    if (kv.value == .boolean) style.reverse = kv.value.boolean;
                } else if (std.mem.eql(u8, key, "blink")) {
                    if (kv.value == .boolean) style.blink = kv.value.boolean;
                }
            }

            try self.hl_attrs.put(id, style);
        } else if (std.mem.eql(u8, event_name.string, "flush")) {
            // Flush marks the end of a frame - copy back to front now

            std.log.debug("flush: copying back→front", .{});
            for (0..self.rows) |row| {
                for (0..self.cols) |col| {
                    if (self.back.readCell(@intCast(col), @intCast(row))) |cell| {
                        self.front.writeCell(@intCast(col), @intCast(row), cell);
                    }
                }
            }
            self.front.cursor_row = self.back.cursor_row;
            self.front.cursor_col = self.back.cursor_col;
            self.front.cursor_vis = self.back.cursor_vis;

            // Reset cursor visibility for the next frame. If we don't receive a cursor_pos
            // event in the next frame, we assume the cursor is hidden.
            self.back.cursor_vis = false;

            // Debug: check what got copied to front at (0,0)
            if (self.front.readCell(0, 0)) |cell| {
                std.log.debug("flush: front(0,0) after copy = '{s}'", .{cell.char.grapheme});
            }
        }
    }

    const end_time = std.time.nanoTimestamp();
    const deserialize_us = @divTrunc(end_time - start_time, std.time.ns_per_us);

    std.log.info("applyRedraw: updated {} rows deserialize={}us", .{ rows_updated.items.len, deserialize_us });
}

pub fn render(self: *Surface, win: vaxis.Window) void {
    if (!self.dirty) return;

    std.log.debug("render: copying front→vaxis window (win={}x{}, surface={}x{})", .{ win.width, win.height, self.cols, self.rows });

    var cells_written: usize = 0;
    // Copy front buffer to vaxis window
    for (0..self.rows) |row| {
        for (0..self.cols) |col| {
            if (col < win.width and row < win.height) {
                const cell = self.front.readCell(@intCast(col), @intCast(row)) orelse continue;

                // Debug: log what we write to (0,0)
                if (row == 0 and col == 0) {
                    std.log.debug("render: writing to (0,0): '{s}'", .{cell.char.grapheme});
                }

                win.writeCell(@intCast(col), @intCast(row), cell);
                cells_written += 1;
            }
        }
    }
    std.log.debug("render: wrote {} cells to vaxis window", .{cells_written});

    // Copy cursor state to window
    if (self.front.cursor_vis and
        self.front.cursor_col < win.width and
        self.front.cursor_row < win.height)
    {
        win.showCursor(self.front.cursor_col, self.front.cursor_row);
        const shape: vaxis.Cell.CursorShape = switch (self.cursor_shape) {
            .block => .block,
            .beam => .beam,
            .underline => .underline,
        };
        win.setCursorShape(shape);
    } else {
        win.hideCursor();
    }

    self.dirty = false;
}

test "Surface - applyRedraw style handling" {
    const testing = std.testing;

    const allocator = testing.allocator;

    var surface = try Surface.init(allocator, 5, 10);
    defer surface.deinit();

    // Define style 1 (red)
    var style_builder = redraw.RedrawBuilder.init(allocator);
    defer style_builder.deinit();

    try style_builder.style(1, .{ .fg = 0xFF0000 });
    const style_msg = try style_builder.build();
    defer allocator.free(style_msg);

    const style_val = try msgpack.decode(allocator, style_msg);
    defer style_val.deinit(allocator);

    // Extract events array from notification [2, "redraw", [events]]
    const style_params = style_val.array[2];
    try surface.applyRedraw(style_params);

    // Create a write event with mixed styles
    // 1. "A" with style 1
    // 2. "B" with null style (should be 1)
    // 3. "C" with style 0 (should be default)
    // 4. "D" with null style (should be 0)
    // 5. "E" with style 1, repeat 2

    var write_builder = redraw.RedrawBuilder.init(allocator);
    defer write_builder.deinit();

    const cells = [_]redraw.UIEvent.Write.Cell{
        .{ .grapheme = "A", .style_id = 1 },
        .{ .grapheme = "B", .style_id = null }, // should reuse 1
        .{ .grapheme = "C", .style_id = 0 }, // reset to default
        .{ .grapheme = "D", .style_id = null }, // reuse 0
        .{ .grapheme = "E", .style_id = 1, .repeat = 2 },
    };

    try write_builder.write(0, 0, 0, &cells);
    const write_msg = try write_builder.build();
    defer allocator.free(write_msg);

    const write_val = try msgpack.decode(allocator, write_msg);
    defer write_val.deinit(allocator);

    // Extract events array
    const write_params = write_val.array[2];
    try surface.applyRedraw(write_params);

    // Verify content of back buffer
    // We can't access .back directly if it's private, but we can access it if we are in the same file.
    // Since we are appending this test to Surface.zig, we have access to private fields.

    // A: Style 1
    const cell_a = surface.back.readCell(0, 0).?;
    try testing.expectEqualStrings("A", cell_a.char.grapheme);
    try testing.expectEqual(vaxis.Color{ .rgb = .{ 255, 0, 0 } }, cell_a.style.fg);

    // B: Style 1 (inherited)
    const cell_b = surface.back.readCell(1, 0).?;
    try testing.expectEqualStrings("B", cell_b.char.grapheme);
    try testing.expectEqual(vaxis.Color{ .rgb = .{ 255, 0, 0 } }, cell_b.style.fg);

    // C: Style 0 (default)
    const cell_c = surface.back.readCell(2, 0).?;
    try testing.expectEqualStrings("C", cell_c.char.grapheme);
    try testing.expectEqual(vaxis.Color.default, cell_c.style.fg);

    // D: Style 0 (inherited default)
    const cell_d = surface.back.readCell(3, 0).?;
    try testing.expectEqualStrings("D", cell_d.char.grapheme);
    try testing.expectEqual(vaxis.Color.default, cell_d.style.fg);

    // E1: Style 1
    const cell_e1 = surface.back.readCell(4, 0).?;
    try testing.expectEqualStrings("E", cell_e1.char.grapheme);
    try testing.expectEqual(vaxis.Color{ .rgb = .{ 255, 0, 0 } }, cell_e1.style.fg);

    // E2: Style 1 (repeated)
    const cell_e2 = surface.back.readCell(5, 0).?;
    try testing.expectEqualStrings("E", cell_e2.char.grapheme);
    try testing.expectEqual(vaxis.Color{ .rgb = .{ 255, 0, 0 } }, cell_e2.style.fg);
}

test "Surface - applyRedraw style handling with integer attributes" {
    const testing = std.testing;

    const allocator = testing.allocator;

    var surface = try Surface.init(allocator, 5, 10);
    defer surface.deinit();

    // Define style 2 with integer fg (using msgpack integer type explicitly)
    // We construct the msgpack value manually to ensure .integer type
    var items = std.ArrayList(msgpack.Value.KeyValue).empty;
    defer items.deinit(allocator);

    try items.append(allocator, .{
        .key = msgpack.Value{ .string = try allocator.dupe(u8, "fg") },
        .value = msgpack.Value{ .integer = 0x00FF00 }, // Green
    });

    const args = try allocator.alloc(msgpack.Value, 2);
    args[0] = msgpack.Value{ .unsigned = 2 };
    args[1] = msgpack.Value{ .map = try items.toOwnedSlice(allocator) };

    const event_arr = try allocator.alloc(msgpack.Value, 2);
    event_arr[0] = msgpack.Value{ .string = try allocator.dupe(u8, "style") };
    event_arr[1] = msgpack.Value{ .array = args };

    const notification = try allocator.alloc(msgpack.Value, 3);
    notification[0] = msgpack.Value{ .unsigned = 2 };
    notification[1] = msgpack.Value{ .string = try allocator.dupe(u8, "redraw") };

    const events = try allocator.alloc(msgpack.Value, 1);
    events[0] = msgpack.Value{ .array = event_arr };
    notification[2] = msgpack.Value{ .array = events };

    const value = msgpack.Value{ .array = notification };
    defer value.deinit(allocator);

    try surface.applyRedraw(notification[2]);

    // Verify style 2 is green
    const style = surface.hl_attrs.get(2).?;
    try testing.expectEqual(vaxis.Color{ .rgb = .{ 0, 255, 0 } }, style.fg);
}

test "Surface - applyRedraw extended attributes" {
    const testing = std.testing;
    const allocator = testing.allocator;

    var surface = try Surface.init(allocator, 5, 10);
    defer surface.deinit();

    var items = std.ArrayList(msgpack.Value.KeyValue).empty;
    defer items.deinit(allocator);

    // Test strikethrough, ul_style=double (2), ul_color=Blue
    try items.append(allocator, .{
        .key = msgpack.Value{ .string = try allocator.dupe(u8, "strikethrough") },
        .value = msgpack.Value{ .boolean = true },
    });
    try items.append(allocator, .{
        .key = msgpack.Value{ .string = try allocator.dupe(u8, "ul_style") },
        .value = msgpack.Value{ .unsigned = 2 }, // double
    });
    try items.append(allocator, .{
        .key = msgpack.Value{ .string = try allocator.dupe(u8, "ul_color") },
        .value = msgpack.Value{ .unsigned = 0x0000FF }, // Blue
    });

    const args = try allocator.alloc(msgpack.Value, 2);
    args[0] = msgpack.Value{ .unsigned = 10 };
    args[1] = msgpack.Value{ .map = try items.toOwnedSlice(allocator) };

    const event_arr = try allocator.alloc(msgpack.Value, 2);
    event_arr[0] = msgpack.Value{ .string = try allocator.dupe(u8, "style") };
    event_arr[1] = msgpack.Value{ .array = args };

    const notification = try allocator.alloc(msgpack.Value, 3);
    notification[0] = msgpack.Value{ .unsigned = 2 };
    notification[1] = msgpack.Value{ .string = try allocator.dupe(u8, "redraw") };

    const events = try allocator.alloc(msgpack.Value, 1);
    events[0] = msgpack.Value{ .array = event_arr };
    notification[2] = msgpack.Value{ .array = events };

    const value = msgpack.Value{ .array = notification };
    defer value.deinit(allocator);

    try surface.applyRedraw(notification[2]);

    const style = surface.hl_attrs.get(10).?;
    try testing.expect(style.strikethrough);
    try testing.expectEqual(vaxis.Style.Underline.double, style.ul_style);
    try testing.expectEqual(vaxis.Color{ .rgb = .{ 0, 0, 255 } }, style.ul);
}
