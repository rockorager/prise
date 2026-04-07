//! Text input widget backed by vaxis gap-buffer TextInput.
//!
//! Delegates editing to `vaxis.widgets.TextInput` for grapheme-aware
//! cursor movement and readline primitives. Keeps prise's own render
//! logic (reverse-video block cursor, background fill, no ellipsis).

const std = @import("std");

const vaxis = @import("vaxis");
const unicode = vaxis.unicode;

const TextInput = @This();

allocator: std.mem.Allocator,
vaxis_input: vaxis.widgets.TextInput,
scroll_offset: u16 = 0,

pub fn init(allocator: std.mem.Allocator) TextInput {
    return .{
        .allocator = allocator,
        .vaxis_input = vaxis.widgets.TextInput.init(allocator),
    };
}

pub fn deinit(self: *TextInput) void {
    self.vaxis_input.deinit();
}

// -----------------------------------------------------------------------
// Editing — delegate to vaxis
// -----------------------------------------------------------------------

pub fn insertSlice(self: *TextInput, str: []const u8) !void {
    try self.vaxis_input.insertSliceAtCursor(str);
}

pub fn deleteBackward(self: *TextInput) void {
    self.vaxis_input.deleteBeforeCursor();
}

pub fn deleteForward(self: *TextInput) void {
    self.vaxis_input.deleteAfterCursor();
}

pub fn deleteWordBackward(self: *TextInput) void {
    self.vaxis_input.deleteWordBefore();
}

pub fn killLine(self: *TextInput) void {
    self.vaxis_input.deleteToEnd();
}

pub fn moveLeft(self: *TextInput) void {
    self.vaxis_input.cursorLeft();
}

pub fn moveRight(self: *TextInput) void {
    self.vaxis_input.cursorRight();
}

pub fn moveToStart(self: *TextInput) void {
    self.vaxis_input.buf.moveGapLeft(self.vaxis_input.buf.firstHalf().len);
}

pub fn moveToEnd(self: *TextInput) void {
    self.vaxis_input.buf.moveGapRight(self.vaxis_input.buf.secondHalf().len);
}

pub fn clear(self: *TextInput) void {
    self.vaxis_input.clearRetainingCapacity();
    self.scroll_offset = 0;
}

// -----------------------------------------------------------------------
// New editing methods — expose additional vaxis capabilities
// -----------------------------------------------------------------------

pub fn deleteToStart(self: *TextInput) void {
    self.vaxis_input.deleteToStart();
}

pub fn deleteWordAfter(self: *TextInput) void {
    self.vaxis_input.deleteWordAfter();
}

pub fn moveWordBackward(self: *TextInput) void {
    self.vaxis_input.moveBackwardWordwise();
}

pub fn moveWordForward(self: *TextInput) void {
    self.vaxis_input.moveForwardWordwise();
}

// -----------------------------------------------------------------------
// Text access
// -----------------------------------------------------------------------

/// Return the full text as a contiguous slice. Caller must free with
/// the same allocator that was passed to `init`.
pub fn text(self: *const TextInput) ![]const u8 {
    const first = self.vaxis_input.buf.firstHalf();
    const second = self.vaxis_input.buf.secondHalf();
    const buf = try self.allocator.alloc(u8, first.len + second.len);
    @memcpy(buf[0..first.len], first);
    @memcpy(buf[first.len..], second);
    return buf;
}

// -----------------------------------------------------------------------
// Rendering — prise's own style (reverse-video block cursor, bg fill)
// -----------------------------------------------------------------------

pub fn render(self: *TextInput, win: vaxis.Window, style: vaxis.Style) void {
    if (win.width == 0) return;

    const first_half = self.vaxis_input.buf.firstHalf();
    const second_half = self.vaxis_input.buf.secondHalf();

    // Calculate cursor display column for scroll adjustment
    var cursor_display_col: u16 = 0;
    {
        var iter = unicode.graphemeIterator(first_half);
        while (iter.next()) |grapheme| {
            cursor_display_col += win.gwidth(grapheme.bytes(first_half));
        }
    }

    // Adjust scroll offset to keep cursor visible
    if (cursor_display_col < self.scroll_offset) {
        self.scroll_offset = cursor_display_col;
    } else if (cursor_display_col >= self.scroll_offset + win.width) {
        self.scroll_offset = cursor_display_col - win.width + 1;
    }

    var col: u16 = 0;
    var abs_col: u16 = 0;

    // Render first half (before cursor)
    {
        var iter = unicode.graphemeIterator(first_half);
        while (iter.next()) |grapheme| {
            const g = grapheme.bytes(first_half);
            const w = win.gwidth(g);
            if (abs_col + w <= self.scroll_offset) {
                abs_col += w;
                continue;
            }
            if (col + w > win.width) break;
            win.writeCell(col, 0, .{
                .char = .{ .grapheme = g, .width = @intCast(w) },
                .style = style,
            });
            col += w;
            abs_col += w;
        }
    }

    // Render cursor cell: first grapheme of second half with reverse,
    // or a reversed space if the cursor is at the end of input.
    var cursor_style = style;
    cursor_style.reverse = true;
    {
        var iter = unicode.graphemeIterator(second_half);
        if (iter.next()) |grapheme| {
            const g = grapheme.bytes(second_half);
            const w = win.gwidth(g);
            if (col + w <= win.width) {
                win.writeCell(col, 0, .{
                    .char = .{ .grapheme = g, .width = @intCast(w) },
                    .style = cursor_style,
                });
                col += w;
            }

            // Render rest of second half (normal style)
            while (iter.next()) |g2| {
                const g2_bytes = g2.bytes(second_half);
                const w2 = win.gwidth(g2_bytes);
                if (col + w2 > win.width) break;
                win.writeCell(col, 0, .{
                    .char = .{ .grapheme = g2_bytes, .width = @intCast(w2) },
                    .style = style,
                });
                col += w2;
            }
        } else {
            // Cursor at end of input — show reversed space
            if (col < win.width) {
                win.writeCell(col, 0, .{
                    .char = .{ .grapheme = " ", .width = 1 },
                    .style = cursor_style,
                });
                col += 1;
            }
        }
    }

    // Fill remaining width with background
    while (col < win.width) : (col += 1) {
        win.writeCell(col, 0, .{
            .char = .{ .grapheme = " ", .width = 1 },
            .style = style,
        });
    }
}

// ===========================================================================
// Tests
// ===========================================================================

const tui_test = @import("tui_test.zig");

test "basic insert and cursor movement" {
    const allocator = std.testing.allocator;

    var input = TextInput.init(allocator);
    defer input.deinit();

    try input.insertSlice("abc");

    const t1 = try input.text();
    defer allocator.free(t1);
    try std.testing.expectEqualStrings("abc", t1);

    input.moveLeft();

    try input.insertSlice("X");
    const t2 = try input.text();
    defer allocator.free(t2);
    try std.testing.expectEqualStrings("abXc", t2);
}

test "delete backward and forward" {
    const allocator = std.testing.allocator;

    var input = TextInput.init(allocator);
    defer input.deinit();

    try input.insertSlice("hello");

    {
        const t = try input.text();
        defer allocator.free(t);
        try std.testing.expectEqualStrings("hello", t);
    }

    input.deleteBackward();
    {
        const t = try input.text();
        defer allocator.free(t);
        try std.testing.expectEqualStrings("hell", t);
    }

    input.moveToStart();
    input.deleteForward();
    {
        const t = try input.text();
        defer allocator.free(t);
        try std.testing.expectEqualStrings("ell", t);
    }
}

test "delete word backward" {
    const allocator = std.testing.allocator;

    var input = TextInput.init(allocator);
    defer input.deinit();

    try input.insertSlice("hello world");

    input.deleteWordBackward();
    {
        const t = try input.text();
        defer allocator.free(t);
        try std.testing.expectEqualStrings("hello ", t);
    }
}

test "scroll offset via render" {
    const allocator = std.testing.allocator;

    var input = TextInput.init(allocator);
    defer input.deinit();

    try input.insertSlice("abcdefghijklmnop");

    // Rendering into a narrow window triggers scroll adjustment
    var screen = try tui_test.createScreen(allocator, 5, 1);
    defer screen.deinit(allocator);

    const win = tui_test.windowFromScreen(&screen);
    input.render(win, .{});

    try std.testing.expect(input.scroll_offset > 0);
}

// -----------------------------------------------------------------------
// New editing method tests
// -----------------------------------------------------------------------

test "killLine deletes from cursor to end" {
    const allocator = std.testing.allocator;

    var input = TextInput.init(allocator);
    defer input.deinit();

    try input.insertSlice("hello world");
    // Move cursor to after "hello" (back over " world" = 6 graphemes)
    for (0..6) |_| input.moveLeft();

    input.killLine();
    {
        const t = try input.text();
        defer allocator.free(t);
        try std.testing.expectEqualStrings("hello", t);
    }
}

test "killLine at end of input is a no-op" {
    const allocator = std.testing.allocator;

    var input = TextInput.init(allocator);
    defer input.deinit();

    try input.insertSlice("hello world");
    // Cursor already at end — killLine should leave text unchanged
    input.killLine();
    {
        const t = try input.text();
        defer allocator.free(t);
        try std.testing.expectEqualStrings("hello world", t);
    }
}

test "delete to start" {
    const allocator = std.testing.allocator;

    var input = TextInput.init(allocator);
    defer input.deinit();

    try input.insertSlice("hello world");
    // Move cursor to middle (after "hello")
    for (0..6) |_| input.moveLeft();

    input.deleteToStart();
    {
        const t = try input.text();
        defer allocator.free(t);
        try std.testing.expectEqualStrings(" world", t);
    }
}

test "delete word after" {
    const allocator = std.testing.allocator;

    var input = TextInput.init(allocator);
    defer input.deinit();

    try input.insertSlice("hello world");
    input.moveToStart();

    input.deleteWordAfter();
    {
        const t = try input.text();
        defer allocator.free(t);
        try std.testing.expectEqualStrings(" world", t);
    }
}

test "move word backward and forward" {
    const allocator = std.testing.allocator;

    var input = TextInput.init(allocator);
    defer input.deinit();

    try input.insertSlice("one two three");
    // Cursor at end

    input.moveWordBackward();
    // Cursor should be before "three"
    try input.insertSlice("X");
    {
        const t = try input.text();
        defer allocator.free(t);
        try std.testing.expectEqualStrings("one two Xthree", t);
    }

    // Move back to undo the X insertion effect, then test forward
    input.deleteBackward(); // remove X
    input.moveToStart();
    input.moveWordForward();
    // Cursor should be after "one"
    try input.insertSlice("Y");
    {
        const t = try input.text();
        defer allocator.free(t);
        try std.testing.expectEqualStrings("oneY two three", t);
    }
}

test "grapheme-aware cursor movement" {
    const allocator = std.testing.allocator;

    var input = TextInput.init(allocator);
    defer input.deinit();

    // Insert multi-byte characters: "café"
    try input.insertSlice("caf\xc3\xa9");

    {
        const t = try input.text();
        defer allocator.free(t);
        try std.testing.expectEqualStrings("caf\xc3\xa9", t);
    }

    // moveLeft should move over the whole 'é' grapheme, not just one byte
    input.moveLeft();
    try input.insertSlice("X");
    {
        const t = try input.text();
        defer allocator.free(t);
        try std.testing.expectEqualStrings("cafX\xc3\xa9", t);
    }

    // deleteBackward should remove the whole 'X'
    input.deleteBackward();
    // deleteForward should remove the whole 'é'
    input.deleteForward();
    {
        const t = try input.text();
        defer allocator.free(t);
        try std.testing.expectEqualStrings("caf", t);
    }
}

// ===========================================================================
// Rendering Tests
// ===========================================================================

test "render - basic text with cursor at end" {
    const allocator = std.testing.allocator;

    var input = TextInput.init(allocator);
    defer input.deinit();

    try input.insertSlice("abc");

    var screen = try tui_test.createScreen(allocator, 6, 1);
    defer screen.deinit(allocator);

    const win = tui_test.windowFromScreen(&screen);
    input.render(win, .{});

    const ascii = try tui_test.screenToAscii(allocator, &screen, 6, 1);
    defer allocator.free(ascii);

    try tui_test.expectAsciiEqual("abc   ", ascii);

    // Cursor should be at position 3 (after 'c') with reverse style
    const cursor_cell = screen.readCell(3, 0).?;
    try std.testing.expect(cursor_cell.style.reverse);

    // Non-cursor cells should not be reversed
    const normal_cell = screen.readCell(0, 0).?;
    try std.testing.expect(!normal_cell.style.reverse);
}

test "render - cursor in middle" {
    const allocator = std.testing.allocator;

    var input = TextInput.init(allocator);
    defer input.deinit();

    try input.insertSlice("hello");
    input.moveLeft();
    input.moveLeft();

    var screen = try tui_test.createScreen(allocator, 8, 1);
    defer screen.deinit(allocator);

    const win = tui_test.windowFromScreen(&screen);
    input.render(win, .{});

    const ascii = try tui_test.screenToAscii(allocator, &screen, 8, 1);
    defer allocator.free(ascii);

    try tui_test.expectAsciiEqual("hello   ", ascii);

    // Cursor at position 3 ('l')
    const cursor_cell = screen.readCell(3, 0).?;
    try std.testing.expect(cursor_cell.style.reverse);
}

test "render - with scrolling" {
    const allocator = std.testing.allocator;

    var input = TextInput.init(allocator);
    defer input.deinit();

    try input.insertSlice("abcdefghijklmnop");

    var screen = try tui_test.createScreen(allocator, 5, 1);
    defer screen.deinit(allocator);

    const win = tui_test.windowFromScreen(&screen);
    input.render(win, .{});

    // With 16 chars and cursor at end in a 5-wide window, scroll kicks in
    try std.testing.expect(input.scroll_offset > 0);

    // Cursor (reversed space at end) should be at the last visible position
    const cursor_cell = screen.readCell(4, 0).?;
    try std.testing.expect(cursor_cell.style.reverse);
}

test "render - empty input shows cursor" {
    const allocator = std.testing.allocator;

    var input = TextInput.init(allocator);
    defer input.deinit();

    var screen = try tui_test.createScreen(allocator, 5, 1);
    defer screen.deinit(allocator);

    const win = tui_test.windowFromScreen(&screen);
    input.render(win, .{});

    // Cursor at position 0
    const cursor_cell = screen.readCell(0, 0).?;
    try std.testing.expect(cursor_cell.style.reverse);
}
