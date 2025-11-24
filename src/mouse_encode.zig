const std = @import("std");
const ghostty = @import("ghostty-vt");
const key_parse = @import("key_parse.zig");

pub const TerminalState = struct {
    flags: @FieldType(ghostty.Terminal, "flags"),
    modes: ghostty.modes.ModeState,
    cols: u16,
    rows: u16,
    width_px: u32,
    height_px: u32,

    pub fn init(terminal: *const ghostty.Terminal) TerminalState {
        return .{
            .flags = terminal.flags,
            .modes = terminal.modes,
            .cols = terminal.cols,
            .rows = terminal.rows,
            .width_px = terminal.width_px,
            .height_px = terminal.height_px,
        };
    }
};

pub fn encode(
    writer: anytype,
    event: key_parse.MouseEvent,
    state: TerminalState,
) !void {
    const flags = state.flags;
    const modes = state.modes;

    std.log.debug("mouse_encode: event={s} format={s} x10={} normal={} button={} any={} utf8={} sgr={} urxvt={} sgr_pixels={}", .{
        @tagName(flags.mouse_event),
        @tagName(flags.mouse_format),
        modes.get(.mouse_event_x10),
        modes.get(.mouse_event_normal),
        modes.get(.mouse_event_button),
        modes.get(.mouse_event_any),
        modes.get(.mouse_format_utf8),
        modes.get(.mouse_format_sgr),
        modes.get(.mouse_format_urxvt),
        modes.get(.mouse_format_sgr_pixels),
    });

    // Check if mouse reporting is enabled
    if (flags.mouse_event == .none) return;

    // Filter based on event type and enabled mode
    const report = switch (flags.mouse_event) {
        .x10 => event.type == .press, // X10 only reports press
        .normal => event.type == .press or event.type == .release,
        .button => event.type == .press or event.type == .release or event.type == .drag,
        .any => true, // Report everything including motion
        .none => false,
    };

    if (!report) return;

    // Compute cell coordinates from float (floor)
    const col: u16 = @intFromFloat(@max(0, @floor(event.x)));
    const row: u16 = @intFromFloat(@max(0, @floor(event.y)));

    // SGR encoding (1006)
    if (flags.mouse_format == .sgr) {
        try encodeSGR(writer, col, row, event);
        return;
    }

    // SGR pixels (1016) - compute pixel coordinates from float
    if (flags.mouse_format == .sgr_pixels) {
        const cell_width: f64 = if (state.cols > 0 and state.width_px > 0)
            @as(f64, @floatFromInt(state.width_px)) / @as(f64, @floatFromInt(state.cols))
        else
            1.0;
        const cell_height: f64 = if (state.rows > 0 and state.height_px > 0)
            @as(f64, @floatFromInt(state.height_px)) / @as(f64, @floatFromInt(state.rows))
        else
            1.0;

        const px_x: u16 = @intFromFloat(@max(0, @round(event.x * cell_width)));
        const px_y: u16 = @intFromFloat(@max(0, @round(event.y * cell_height)));

        try encodeSGR(writer, px_x, px_y, event);
        return;
    }

    // Fallback to X10/Normal (max 223 coords)
    // If coordinates are too large for X10, we skip reporting
    if (col > 222 or row > 222) return;

    try encodeX10(writer, col, row, event);
}

fn encodeSGR(writer: anytype, col: u16, row: u16, event: key_parse.MouseEvent) !void {
    var cb: u8 = 0;

    // Button mapping
    switch (event.button) {
        .left => cb = 0,
        .middle => cb = 1,
        .right => cb = 2,
        .wheel_up => cb = 64,
        .wheel_down => cb = 65,
        .wheel_left => cb = 66,
        .wheel_right => cb = 67,
        .none => if (event.type == .motion) {
            cb = 35;
        } else {
            cb = 0;
        },
    }

    // Modifiers
    if (event.mods.shift) cb |= 4;
    if (event.mods.alt) cb |= 8;
    if (event.mods.ctrl) cb |= 16;

    // Drag/Motion
    if (event.type == .drag) cb |= 32;
    if (event.type == .motion) cb |= 32;

    // Format: CSI < Cb ; Cx ; Cy M (or m for release)
    const char: u8 = if (event.type == .release) 'm' else 'M';

    std.log.debug("encodeSGR: col={} (sent {})", .{ col, col + 1 });
    try writer.print("\x1b[<{};{};{}{c}", .{ cb, col + 1, row + 1, char });
}

fn encodeX10(writer: anytype, col: u16, row: u16, event: key_parse.MouseEvent) !void {
    var cb: u8 = 0;
    switch (event.button) {
        .left => cb = 0,
        .middle => cb = 1,
        .right => cb = 2,
        .wheel_up => cb = 64,
        .wheel_down => cb = 65,
        .wheel_left => cb = 66,
        .wheel_right => cb = 67,
        .none => cb = 0,
    }

    if (event.type == .release) cb = 3;
    if (event.type == .drag) cb += 32;
    if (event.type == .motion) cb += 32;

    if (event.mods.shift) cb |= 4;
    if (event.mods.alt) cb |= 8;
    if (event.mods.ctrl) cb |= 16;

    try writer.print("\x1b[M{c}{c}{c}", .{ cb + 32, @as(u8, @intCast(col + 1)) + 32, @as(u8, @intCast(row + 1)) + 32 });
}
