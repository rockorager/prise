const std = @import("std");
const io = @import("io.zig");
const rpc = @import("rpc.zig");
const msgpack = @import("msgpack.zig");
const pty = @import("pty.zig");
const key_parse = @import("key_parse.zig");
const key_encode = @import("key_encode.zig");
const mouse_encode = @import("mouse_encode.zig");
const posix = std.posix;
const ghostty_vt = @import("ghostty-vt");
const vt_handler = @import("vt_handler.zig");
const redraw = @import("redraw.zig");

var signal_write_fd: posix.fd_t = undefined;

fn signalHandler(sig: c_int) callconv(std.builtin.CallingConvention.c) void {
    // Ignore further signals
    const ignore: posix.Sigaction = .{
        .handler = .{ .handler = posix.SIG.IGN },
        .mask = posix.sigemptyset(),
        .flags = 0,
    };
    posix.sigaction(posix.SIG.INT, &ignore, null);
    posix.sigaction(posix.SIG.TERM, &ignore, null);

    _ = sig;
    _ = posix.write(signal_write_fd, "s") catch {};
}

const Pty = struct {
    id: usize,
    process: pty.Process,
    clients: std.ArrayList(*Client),
    read_thread: ?std.Thread = null,
    running: std.atomic.Value(bool),
    keep_alive: bool = false,
    terminal: ghostty_vt.Terminal,
    allocator: std.mem.Allocator,

    // Title of the terminal window
    title: std.ArrayList(u8),
    title_dirty: bool = false,

    // Exit state
    exited: std.atomic.Value(bool) = std.atomic.Value(bool).init(false),
    exit_status: std.atomic.Value(u32) = std.atomic.Value(u32).init(0),

    // Synchronization for terminal access
    terminal_mutex: std.Thread.Mutex = .{},
    // Dirty signaling
    pipe_fds: [2]posix.fd_t,
    exit_pipe_fds: [2]posix.fd_t,
    dirty_signal_buf: [1]u8 = undefined,
    last_render_time: i64 = 0,
    render_timer: ?io.Task = null,
    render_state: ghostty_vt.RenderState,

    // Selection state: stores click position for drag selection
    selection_start: ?struct { col: u16, row: u16 } = null,
    // Click counting for double/triple click
    left_click_count: u8 = 0,
    left_click_time: i64 = 0, // milliseconds timestamp

    // Pointer to server for callbacks (opaque to avoid circular type dependency)
    server_ptr: *anyopaque = undefined,

    fn init(allocator: std.mem.Allocator, id: usize, process_instance: pty.Process, size: pty.winsize) !*Pty {
        const instance = try allocator.create(Pty);
        const pipe_fds = try posix.pipe2(.{ .NONBLOCK = true, .CLOEXEC = true });
        const exit_pipe_fds = try posix.pipe2(.{ .NONBLOCK = true, .CLOEXEC = true });

        instance.* = .{
            .id = id,
            .process = process_instance,
            .clients = std.ArrayList(*Client).empty,
            .running = std.atomic.Value(bool).init(true),
            .terminal = try ghostty_vt.Terminal.init(allocator, .{
                .cols = size.ws_col,
                .rows = size.ws_row,
            }),
            .allocator = allocator,
            .title = std.ArrayList(u8).empty,
            .title_dirty = false,
            .pipe_fds = pipe_fds,
            .exit_pipe_fds = exit_pipe_fds,
            .render_state = .empty,
        };
        return instance;
    }

    /// Signal the PTY to stop and cancel pending I/O (non-blocking)
    fn stopAndCancelIO(self: *Pty, loop: *io.Loop) void {
        self.running.store(false, .seq_cst);
        // Signal read thread to exit
        _ = posix.write(self.exit_pipe_fds[1], "q") catch {};

        // Kill the PTY process
        _ = posix.kill(self.process.pid, posix.SIG.HUP) catch {};

        // Cancel any pending render timer
        if (self.render_timer) |*task| {
            task.cancel(loop) catch {};
            self.render_timer = null;
        }

        // Cancel pending read on dirty signal pipe
        loop.cancelByFd(self.pipe_fds[0]);
    }

    /// Join read thread and free resources (call after event loop exits)
    fn joinAndFree(self: *Pty, allocator: std.mem.Allocator) void {
        if (self.read_thread) |thread| {
            thread.join();
        }
        self.process.close();

        posix.close(self.pipe_fds[0]);
        posix.close(self.pipe_fds[1]);
        posix.close(self.exit_pipe_fds[0]);
        posix.close(self.exit_pipe_fds[1]);
        self.terminal.deinit(allocator);
        self.render_state.deinit(allocator);
        self.clients.deinit(allocator);
        self.title.deinit(allocator);
        allocator.destroy(self);
    }

    fn deinit(self: *Pty, allocator: std.mem.Allocator, loop: *io.Loop) void {
        self.stopAndCancelIO(loop);
        self.joinAndFree(allocator);
    }

    fn addClient(self: *Pty, allocator: std.mem.Allocator, client: *Client) !void {
        try self.clients.append(allocator, client);
    }

    fn removeClient(self: *Pty, client: *Client) void {
        for (self.clients.items, 0..) |c, i| {
            if (c == client) {
                _ = self.clients.swapRemove(i);
                return;
            }
        }
    }

    fn setTitle(self: *Pty, title: []const u8) !void {
        // Mutex is already held by readThread when this is called via callback

        // Update internal title
        self.title.clearRetainingCapacity();
        try self.title.appendSlice(self.allocator, title);
        self.title_dirty = true;
    }

    // Removed broadcast - we'll send msgpack-RPC redraw notifications instead

    fn readThread(self: *Pty, server: *Server) void {
        _ = server;
        var buffer: [4096]u8 = undefined;

        var handler = vt_handler.Handler.init(&self.terminal);
        defer handler.deinit();

        // Set up the write callback so the handler can respond to queries
        handler.setWriteCallback(self, struct {
            fn writeToPty(ctx: ?*anyopaque, data: []const u8) !void {
                const pty_inst: *Pty = @ptrCast(@alignCast(ctx));
                _ = posix.write(pty_inst.process.master, data) catch |err| {
                    std.log.err("Failed to write to PTY: {}", .{err});
                    return err;
                };
            }
        }.writeToPty);

        // Set up title callback
        handler.setTitleCallback(self, struct {
            fn onTitle(ctx: ?*anyopaque, title: []const u8) !void {
                const pty_inst: *Pty = @ptrCast(@alignCast(ctx));
                pty_inst.setTitle(title) catch |err| {
                    std.log.err("Failed to set title: {}", .{err});
                };
            }
        }.onTitle);

        var stream = vt_handler.Stream.initAlloc(self.allocator, handler);
        defer stream.deinit();

        var poll_fds = [_]posix.pollfd{
            .{ .fd = self.process.master, .events = posix.POLL.IN, .revents = 0 },
            .{ .fd = self.exit_pipe_fds[0], .events = posix.POLL.IN, .revents = 0 },
        };

        while (self.running.load(.seq_cst)) {
            // Tight loop: drain PTY buffer
            while (true) {
                const n = posix.read(self.process.master, &buffer) catch |err| {
                    if (err == error.WouldBlock) break; // Buffer empty, time to poll
                    std.log.err("PTY read error: {}", .{err});
                    self.running.store(false, .seq_cst);
                    break;
                };
                if (n == 0) {
                    self.running.store(false, .seq_cst);
                    break;
                }

                // Lock mutex and update terminal state
                self.terminal_mutex.lock();
                // Parse the data through ghostty-vt to update terminal state
                stream.nextSlice(buffer[0..n]) catch |err| {
                    std.log.err("Failed to parse VT sequences: {}", .{err});
                };
                self.terminal_mutex.unlock();

                // Notify main thread by writing to pipe
                // Ignore EAGAIN (pipe full means already dirty)
                if (!self.terminal.modes.get(.synchronized_output)) {
                    _ = posix.write(self.pipe_fds[1], "x") catch |err| {
                        if (err != error.WouldBlock) {
                            std.log.err("Failed to signal dirty: {}", .{err});
                        }
                    };
                }
            }

            if (!self.running.load(.seq_cst)) break;

            // Poll for more data or exit signal
            _ = posix.poll(&poll_fds, -1) catch |err| {
                std.log.err("Poll error: {}", .{err});
                break;
            };

            if (poll_fds[1].revents & posix.POLL.IN != 0) break; // Exit signal received
        }
        std.log.info("PTY read thread exiting for session {}", .{self.id});

        // Reap the child process
        const result = posix.waitpid(self.process.pid, 0);
        std.log.info("Session {} PTY process {} exited with status {}", .{ self.id, self.process.pid, result.status });

        self.exit_status.store(result.status, .seq_cst);
        self.exited.store(true, .seq_cst);

        // Signal main thread about exit
        while (true) {
            _ = posix.write(self.pipe_fds[1], "e") catch |err| {
                if (err == error.WouldBlock) {
                    std.Thread.sleep(1 * std.time.ns_per_ms);
                    continue;
                }
            };
            break;
        }
    }
};

/// Map ghostty MouseShape to redraw MouseShape
fn mapMouseShape(shape: ghostty_vt.MouseShape) redraw.UIEvent.MouseShape.Shape {
    return switch (shape) {
        .default => .default,
        .text => .text,
        .pointer => .pointer,
        .help => .help,
        .progress => .progress,
        .wait => .wait,
        .cell => .cell,
        .crosshair => .crosshair,
        .move => .move,
        .not_allowed => .not_allowed,
        .no_drop => .not_allowed,
        .grab => .grab,
        .grabbing => .grabbing,
        .ew_resize, .e_resize, .w_resize => .ew_resize,
        .ns_resize, .n_resize, .s_resize => .ns_resize,
        .nesw_resize, .ne_resize, .sw_resize => .nesw_resize,
        .nwse_resize, .nw_resize, .se_resize => .nwse_resize,
        .col_resize => .col_resize,
        .row_resize => .row_resize,
        .all_scroll => .all_scroll,
        .zoom_in => .zoom_in,
        .zoom_out => .zoom_out,
        .context_menu, .alias, .copy, .vertical_text => .default,
    };
}

/// Convert ghostty style to Prise Style Attributes
fn getStyleAttributes(style: ghostty_vt.Style) redraw.UIEvent.Style.Attributes {
    var attrs: redraw.UIEvent.Style.Attributes = .{};

    // Convert foreground color
    switch (style.fg_color) {
        .none => {},
        .palette => |idx| {
            attrs.fg_idx = @intCast(idx);
        },
        .rgb => |rgb| {
            // Convert RGB struct to u32: 0xRRGGBB
            attrs.fg = (@as(u32, rgb.r) << 16) | (@as(u32, rgb.g) << 8) | @as(u32, rgb.b);
        },
    }

    // Convert background color
    switch (style.bg_color) {
        .none => {},
        .palette => |idx| {
            attrs.bg_idx = @intCast(idx);
        },
        .rgb => |rgb| {
            // Convert RGB struct to u32: 0xRRGGBB
            attrs.bg = (@as(u32, rgb.r) << 16) | (@as(u32, rgb.g) << 8) | @as(u32, rgb.b);
        },
    }

    // Convert underline color
    switch (style.underline_color) {
        .none => {},
        .palette => |idx| {
            _ = idx;
        },
        .rgb => |rgb| {
            attrs.ul_color = (@as(u32, rgb.r) << 16) | (@as(u32, rgb.g) << 8) | @as(u32, rgb.b);
        },
    }

    // Convert flags
    attrs.bold = style.flags.bold;
    attrs.dim = style.flags.faint;
    attrs.italic = style.flags.italic;
    attrs.reverse = style.flags.inverse;
    attrs.blink = style.flags.blink;
    attrs.strikethrough = style.flags.strikethrough;

    // Handle underline variants
    attrs.ul_style = switch (style.flags.underline) {
        .none => .none,
        .single => .single,
        .double => .double,
        .curly => .curly,
        .dotted => .dotted,
        .dashed => .dashed,
    };

    return attrs;
}

/// Captured screen state for building redraw notifications
pub const RenderMode = enum { full, incremental };

/// Build redraw message directly from PTY render state
fn buildRedrawMessageFromPty(
    allocator: std.mem.Allocator,
    pty_instance: *Pty,
    mode: RenderMode,
) ![]u8 {
    var builder = redraw.RedrawBuilder.init(allocator);
    defer builder.deinit();

    // Temporary arena for this build operation (text buffers, style map, etc)
    var temp_arena = std.heap.ArenaAllocator.init(allocator);
    defer temp_arena.deinit();
    const temp_alloc = temp_arena.allocator();

    pty_instance.terminal_mutex.lock();
    try pty_instance.render_state.update(pty_instance.allocator, &pty_instance.terminal);
    const mouse_shape = mapMouseShape(pty_instance.terminal.mouse_shape);
    pty_instance.terminal_mutex.unlock();

    const rs = &pty_instance.render_state;

    // Handle title
    if (mode == .full or pty_instance.title_dirty) {
        try builder.title(@intCast(pty_instance.id), pty_instance.title.items);
        pty_instance.title_dirty = false;
    }

    var effective_mode = mode;
    if (rs.dirty == .full) effective_mode = .full;
    rs.dirty = .false;

    const rows = rs.rows;
    const cols = rs.cols;

    if (effective_mode == .full) {
        try builder.resize(@intCast(pty_instance.id), @intCast(rows), @intCast(cols));
    }

    // Style deduplication
    var styles_map = std.AutoHashMap(u64, u32).init(temp_alloc);
    var next_style_id: u32 = 1;

    const default_style: ghostty_vt.Style = .{
        .fg_color = .none,
        .bg_color = .none,
        .underline_color = .none,
        .flags = .{},
    };
    const default_hash = std.hash.Wyhash.hash(0, std.mem.asBytes(&default_style));
    try styles_map.put(default_hash, 0);
    try builder.style(0, .{}); // Ensure default style is known

    // Iteration buffers
    const row_data_slice = rs.row_data.slice();
    const row_cells = row_data_slice.items(.cells);
    const row_dirties = row_data_slice.items(.dirty);

    var last_style: ?ghostty_vt.Style = null;
    var last_style_id: u32 = 0;

    // Reused buffers for text encoding
    var utf8_buf: [4]u8 = undefined;
    var one_grapheme_buf: [1]u21 = undefined;

    for (0..rows) |y| {
        if (effective_mode == .incremental and !row_dirties[y]) continue;
        row_dirties[y] = false;

        var cells_buf = std.ArrayList(redraw.UIEvent.Write.Cell).empty;

        const rs_cells = row_cells[y];
        const rs_cells_slice = rs_cells.slice();
        const rs_cells_raw = rs_cells_slice.items(.raw);
        const rs_cells_style = rs_cells_slice.items(.style);
        const rs_cells_grapheme = rs_cells_slice.items(.grapheme);

        var last_hl_id: u32 = 0;

        var x: usize = 0;
        while (x < cols) {
            const raw_cell = rs_cells_raw[x];

            if (raw_cell.wide == .spacer_tail) {
                x += 1;
                continue;
            }

            // Resolve style
            var vt_style = if (raw_cell.style_id > 0) rs_cells_style[x] else default_style;
            var is_direct_color = false;

            if (raw_cell.content_tag == .bg_color_rgb) {
                const cell_rgb = raw_cell.content.color_rgb;
                vt_style.bg_color = .{ .rgb = .{ .r = cell_rgb.r, .g = cell_rgb.g, .b = cell_rgb.b } };
                is_direct_color = true;
            } else if (raw_cell.content_tag == .bg_color_palette) {
                vt_style.bg_color = .{ .palette = raw_cell.content.color_palette };
                is_direct_color = true;
            }

            var style_id: u32 = 0;
            var found_match = false;

            if (last_style) |last| {
                if (std.meta.eql(last, vt_style)) {
                    style_id = last_style_id;
                    found_match = true;
                }
            }

            if (!found_match) {
                const style_hash = std.hash.Wyhash.hash(0, std.mem.asBytes(&vt_style));
                if (styles_map.get(style_hash)) |id| {
                    style_id = id;
                } else {
                    style_id = next_style_id;
                    next_style_id += 1;
                    try styles_map.put(style_hash, style_id);
                    const attrs = getStyleAttributes(vt_style);
                    try builder.style(style_id, attrs);
                }
                last_style = vt_style;
                last_style_id = style_id;
            }

            // Resolve text
            var text: []const u8 = "";
            if (is_direct_color) {
                text = " ";
            } else {
                var cluster: []const u21 = &[_]u21{};
                switch (raw_cell.content_tag) {
                    .codepoint => {
                        if (raw_cell.content.codepoint != 0) {
                            one_grapheme_buf[0] = raw_cell.content.codepoint;
                            cluster = &one_grapheme_buf;
                        }
                    },
                    .codepoint_grapheme => {
                        cluster = rs_cells_grapheme[x];
                    },
                    else => {
                        cluster = &[_]u21{' '};
                    },
                }

                if (cluster.len > 0) {
                    // Encode to utf8
                    var stack_buf: [64]u8 = undefined;
                    var stack_len: usize = 0;
                    for (cluster) |cp| {
                        if (stack_len + 4 > stack_buf.len) break;
                        const len = std.unicode.utf8Encode(cp, &utf8_buf) catch continue;
                        @memcpy(stack_buf[stack_len..][0..len], utf8_buf[0..len]);
                        stack_len += len;
                    }
                    text = try temp_alloc.dupe(u8, stack_buf[0..stack_len]);
                } else {
                    text = try temp_alloc.dupe(u8, " ");
                }
            }

            // Repeat detection
            var repeat: usize = 1;
            var next_x = x + 1;
            if (raw_cell.wide == .wide) next_x += 1;

            while (next_x < cols) {
                if (next_x >= cols) break;
                const next_raw = rs_cells_raw[next_x];

                // Width mismatch
                if (raw_cell.wide != next_raw.wide) break;

                var next_text_match = false;

                // For direct color, ensure tag matches and color matches
                if (is_direct_color) {
                    if (next_raw.content_tag == raw_cell.content_tag and next_raw.style_id == raw_cell.style_id) {
                        if (raw_cell.content_tag == .bg_color_rgb) {
                            if (std.meta.eql(raw_cell.content.color_rgb, next_raw.content.color_rgb)) next_text_match = true;
                        } else if (raw_cell.content_tag == .bg_color_palette) {
                            if (raw_cell.content.color_palette == next_raw.content.color_palette) next_text_match = true;
                        }
                    }
                } else {
                    // Normal text
                    if (next_raw.content_tag == raw_cell.content_tag and next_raw.style_id == raw_cell.style_id) {
                        if (raw_cell.content_tag == .codepoint) {
                            if (next_raw.content.codepoint == raw_cell.content.codepoint) next_text_match = true;
                        } else if (raw_cell.content_tag == .codepoint_grapheme) {
                            if (std.mem.eql(u21, rs_cells_grapheme[x], rs_cells_grapheme[next_x])) next_text_match = true;
                        } else {
                            next_text_match = true;
                        }
                    }
                }

                if (!next_text_match) break;

                repeat += 1;
                next_x += 1;
                if (next_raw.wide == .wide) next_x += 1;
            }

            const hl_id_to_send: ?u32 = if (style_id != last_hl_id) style_id else null;
            if (hl_id_to_send) |id| last_hl_id = id;

            try cells_buf.append(temp_alloc, .{
                .grapheme = text,
                .style_id = hl_id_to_send,
                .repeat = if (repeat > 1) @intCast(repeat) else null,
            });

            x = next_x;
        }

        if (cells_buf.items.len > 0) {
            try builder.write(@intCast(pty_instance.id), @intCast(y), 0, cells_buf.items);
        }
    }

    const cursor_visible = rs.cursor.visible and rs.cursor.viewport != null;
    if (rs.cursor.viewport) |vp| {
        try builder.cursorPos(@intCast(pty_instance.id), @intCast(vp.y), @intCast(vp.x), cursor_visible);
    } else {
        try builder.cursorPos(@intCast(pty_instance.id), @intCast(rs.cursor.active.y), @intCast(rs.cursor.active.x), cursor_visible);
    }
    const shape: redraw.UIEvent.CursorShape.Shape = switch (rs.cursor.visual_style) {
        .block, .block_hollow => .block,
        .bar => .beam,
        .underline => .underline,
    };
    try builder.cursorShape(@intCast(pty_instance.id), shape);

    // Send mouse shape
    try builder.mouseShape(@intCast(pty_instance.id), mouse_shape);

    // Send selection bounds from row_data
    const row_selections = row_data_slice.items(.selection);
    var sel_start_row: ?u16 = null;
    var sel_start_col: ?u16 = null;
    var sel_end_row: ?u16 = null;
    var sel_end_col: ?u16 = null;

    for (row_selections, 0..) |sel_range, y| {
        if (sel_range) |range| {
            if (sel_start_row == null) {
                sel_start_row = @intCast(y);
                sel_start_col = @intCast(range[0]);
            }
            sel_end_row = @intCast(y);
            sel_end_col = @intCast(range[1]);
        }
    }

    try builder.selection(@intCast(pty_instance.id), sel_start_row, sel_start_col, sel_end_row, sel_end_col);

    try builder.flush();
    return builder.build();
}

const Client = struct {
    fd: posix.fd_t,
    server: *Server,
    recv_buffer: [4096]u8 = undefined,
    send_buffer: ?[]u8 = null,
    send_queue: std.ArrayList([]u8),
    attached_sessions: std.ArrayList(usize),
    // Map style ID to its last known definition hash/attributes to detect changes
    // We store the Attributes struct directly.
    // style_cache: std.AutoHashMap(u16, redraw.UIEvent.Style.Attributes),

    fn sendData(self: *Client, loop: *io.Loop, data: []const u8) !void {
        const buf = try self.server.allocator.dupe(u8, data);

        // If there's a pending send, queue this one
        if (self.send_buffer != null) {
            try self.send_queue.append(self.server.allocator, buf);
            return;
        }

        // Otherwise send immediately
        self.send_buffer = buf;
        _ = try loop.send(self.fd, buf, .{
            .ptr = self,
            .cb = onSendComplete,
        });
    }

    fn onSendComplete(loop: *io.Loop, completion: io.Completion) anyerror!void {
        const client = completion.userdataCast(Client);

        // Free send buffer
        if (client.send_buffer) |buf| {
            client.server.allocator.free(buf);
            client.send_buffer = null;
        }

        switch (completion.result) {
            .send => {
                // Send next queued message if any
                if (client.send_queue.items.len > 0) {
                    const next_buf = client.send_queue.orderedRemove(0);
                    client.send_buffer = next_buf;
                    _ = try loop.send(client.fd, next_buf, .{
                        .ptr = client,
                        .cb = onSendComplete,
                    });
                }
            },
            .err => |err| {
                std.log.err("Send failed: {}", .{err});
                // Clear queue on error
                for (client.send_queue.items) |buf| {
                    client.server.allocator.free(buf);
                }
                client.send_queue.clearRetainingCapacity();
            },
            else => unreachable,
        }
    }

    fn handleMessage(self: *Client, loop: *io.Loop, data: []const u8) !void {
        const msg = try rpc.decodeMessage(self.server.allocator, data);
        defer msg.deinit(self.server.allocator);

        switch (msg) {
            .request => |req| {
                // std.log.info("Got request: msgid={} method={s}", .{ req.msgid, req.method });

                // Dispatch to handler
                const result = try self.server.handleRequest(self, req.method, req.params);
                defer result.deinit(self.server.allocator);

                // Send response: [1, msgid, error, result]
                // Build response array manually since we have a Value
                const response_arr = try self.server.allocator.alloc(msgpack.Value, 4);
                defer self.server.allocator.free(response_arr);
                response_arr[0] = msgpack.Value{ .unsigned = 1 }; // type
                response_arr[1] = msgpack.Value{ .unsigned = req.msgid }; // msgid
                response_arr[2] = msgpack.Value.nil; // no error
                response_arr[3] = result; // result

                const response_value = msgpack.Value{ .array = response_arr };
                const response_bytes = try msgpack.encodeFromValue(self.server.allocator, response_value);
                defer self.server.allocator.free(response_bytes);

                try self.sendData(loop, response_bytes);
            },
            .notification => |notif| {
                // Handle notifications (no response needed)
                if (std.mem.eql(u8, notif.method, "write_pty")) {
                    if (notif.params == .array and notif.params.array.len >= 2) {
                        const session_id: usize = switch (notif.params.array[0]) {
                            .unsigned => |u| @intCast(u),
                            .integer => |i| @intCast(i),
                            else => {
                                std.log.warn("write_pty notification: invalid session_id type", .{});
                                return;
                            },
                        };
                        const input_data = if (notif.params.array[1] == .binary)
                            notif.params.array[1].binary
                        else if (notif.params.array[1] == .string)
                            notif.params.array[1].string
                        else {
                            std.log.warn("write_pty notification: invalid data type", .{});
                            return;
                        };

                        if (self.server.ptys.get(session_id)) |pty_instance| {
                            _ = posix.write(pty_instance.process.master, input_data) catch |err| {
                                std.log.err("Write to PTY failed: {}", .{err});
                            };
                        } else {
                            std.log.warn("write_pty notification: session {} not found", .{session_id});
                        }
                    } else {
                        std.log.warn("write_pty notification: invalid params", .{});
                    }
                } else if (std.mem.eql(u8, notif.method, "key_input")) {
                    if (notif.params == .array and notif.params.array.len >= 2) {
                        const session_id: usize = switch (notif.params.array[0]) {
                            .unsigned => |u| @intCast(u),
                            .integer => |i| @intCast(i),
                            else => {
                                std.log.warn("key_input notification: invalid session_id type", .{});
                                return;
                            },
                        };
                        const key_map = notif.params.array[1];

                        if (self.server.ptys.get(session_id)) |pty_instance| {
                            const key = key_parse.parseKeyMap(key_map) catch |err| {
                                std.log.err("Failed to parse key map: {}", .{err});
                                return;
                            };

                            var encode_buf: [32]u8 = undefined;
                            var writer = std.Io.Writer.fixed(&encode_buf);

                            pty_instance.terminal_mutex.lock();
                            key_encode.encode(&writer, key, &pty_instance.terminal) catch |err| {
                                std.log.err("Failed to encode key: {}", .{err});
                                pty_instance.terminal_mutex.unlock();
                                return;
                            };
                            pty_instance.terminal_mutex.unlock();

                            const encoded = writer.buffered();
                            if (encoded.len > 0) {
                                _ = posix.write(pty_instance.process.master, encoded) catch |err| {
                                    std.log.err("Write to PTY failed: {}", .{err});
                                };
                            }
                        } else {
                            std.log.warn("key_input notification: session {} not found", .{session_id});
                        }
                    } else {
                        std.log.warn("key_input notification: invalid params", .{});
                    }
                } else if (std.mem.eql(u8, notif.method, "mouse_input")) {
                    if (notif.params == .array and notif.params.array.len >= 2) {
                        const session_id: usize = switch (notif.params.array[0]) {
                            .unsigned => |u| @intCast(u),
                            .integer => |i| @intCast(i),
                            else => {
                                std.log.warn("mouse_input notification: invalid session_id type", .{});
                                return;
                            },
                        };
                        const mouse_map = notif.params.array[1];

                        if (self.server.ptys.get(session_id)) |pty_instance| {
                            const mouse = key_parse.parseMouseMap(mouse_map) catch |err| {
                                std.log.err("Failed to parse mouse map: {}", .{err});
                                return;
                            };

                            const is_wheel = switch (mouse.button) {
                                .wheel_up, .wheel_down, .wheel_left, .wheel_right => true,
                                else => false,
                            };

                            const State = struct {
                                terminal: mouse_encode.TerminalState,
                                active_screen: ghostty_vt.ScreenSet.Key,
                            };
                            const state: State = state: {
                                pty_instance.terminal_mutex.lock();
                                defer pty_instance.terminal_mutex.unlock();
                                break :state .{
                                    .terminal = mouse_encode.TerminalState.init(&pty_instance.terminal),
                                    .active_screen = pty_instance.terminal.screens.active_key,
                                };
                            };

                            if (is_wheel and state.terminal.flags.mouse_event == .none) {
                                if (state.active_screen == .alternate and
                                    state.terminal.modes.get(.mouse_alternate_scroll))
                                {
                                    const seq: []const u8 = if (state.terminal.modes.get(.cursor_keys))
                                        (if (mouse.button == .wheel_up) "\x1bOA" else "\x1bOB")
                                    else
                                        (if (mouse.button == .wheel_up) "\x1b[A" else "\x1b[B");
                                    _ = posix.write(pty_instance.process.master, seq) catch |err| {
                                        std.log.err("Write to PTY failed: {}", .{err});
                                    };
                                } else {
                                    const delta: isize = switch (mouse.button) {
                                        .wheel_up => -1,
                                        .wheel_down => 1,
                                        else => 0,
                                    };
                                    if (delta != 0) {
                                        pty_instance.terminal_mutex.lock();
                                        pty_instance.terminal.scrollViewport(.{ .delta = delta }) catch |err| {
                                            std.log.err("Failed to scroll viewport: {}", .{err});
                                        };
                                        pty_instance.terminal_mutex.unlock();
                                        _ = posix.write(pty_instance.pipe_fds[1], "x") catch {};
                                    }
                                }
                            } else if (mouse.button == .left and state.terminal.flags.mouse_event == .none) {
                                const col: u16 = @intFromFloat(@max(0, @floor(mouse.x)));
                                const row: u16 = @intFromFloat(@max(0, @floor(mouse.y)));
                                const CLICK_INTERVAL_MS: i64 = 500;

                                switch (mouse.type) {
                                    .press => {
                                        // Update click count based on timing
                                        const now = std.time.milliTimestamp();
                                        if (pty_instance.left_click_count > 0 and
                                            (now - pty_instance.left_click_time) < CLICK_INTERVAL_MS)
                                        {
                                            pty_instance.left_click_count += 1;
                                            if (pty_instance.left_click_count > 3) {
                                                pty_instance.left_click_count = 1;
                                            }
                                        } else {
                                            pty_instance.left_click_count = 1;
                                        }
                                        pty_instance.left_click_time = now;
                                        pty_instance.selection_start = .{ .col = col, .row = row };

                                        pty_instance.terminal_mutex.lock();
                                        defer pty_instance.terminal_mutex.unlock();

                                        const screen = pty_instance.terminal.screens.active;
                                        const pin = screen.pages.pin(.{ .viewport = .{
                                            .x = col,
                                            .y = row,
                                        } }) orelse return;

                                        switch (pty_instance.left_click_count) {
                                            1 => {
                                                // Single click: clear selection
                                                screen.select(null) catch {};
                                            },
                                            2 => {
                                                // Double click: select word
                                                if (screen.selectWord(pin)) |sel| {
                                                    screen.select(sel) catch {};
                                                }
                                            },
                                            3 => {
                                                // Triple click: select line
                                                if (screen.selectLine(.{ .pin = pin })) |sel| {
                                                    screen.select(sel) catch {};
                                                }
                                            },
                                            else => {},
                                        }
                                        _ = posix.write(pty_instance.pipe_fds[1], "x") catch {};
                                    },
                                    .drag => {
                                        if (pty_instance.selection_start) |start| {
                                            pty_instance.terminal_mutex.lock();
                                            defer pty_instance.terminal_mutex.unlock();

                                            const screen = pty_instance.terminal.screens.active;
                                            const start_pin = screen.pages.pin(.{ .viewport = .{
                                                .x = start.col,
                                                .y = start.row,
                                            } }) orelse return;
                                            const end_pin = screen.pages.pin(.{ .viewport = .{
                                                .x = col,
                                                .y = row,
                                            } }) orelse return;

                                            switch (pty_instance.left_click_count) {
                                                1 => {
                                                    // Single-click drag: character selection
                                                    const sel = ghostty_vt.Selection.init(start_pin, end_pin, false);
                                                    screen.select(sel) catch {};
                                                },
                                                2 => {
                                                    // Double-click drag: word-by-word selection
                                                    const word_start = screen.selectWord(start_pin);
                                                    const word_end = screen.selectWord(end_pin);
                                                    if (word_start != null and word_end != null) {
                                                        const sel = if (end_pin.before(start_pin))
                                                            ghostty_vt.Selection.init(word_end.?.start(), word_start.?.end(), false)
                                                        else
                                                            ghostty_vt.Selection.init(word_start.?.start(), word_end.?.end(), false);
                                                        screen.select(sel) catch {};
                                                    }
                                                },
                                                3 => {
                                                    // Triple-click drag: line-by-line selection
                                                    const line_start = screen.selectLine(.{ .pin = start_pin });
                                                    const line_end = screen.selectLine(.{ .pin = end_pin });
                                                    if (line_start != null and line_end != null) {
                                                        const sel = if (end_pin.before(start_pin))
                                                            ghostty_vt.Selection.init(line_end.?.start(), line_start.?.end(), false)
                                                        else
                                                            ghostty_vt.Selection.init(line_start.?.start(), line_end.?.end(), false);
                                                        screen.select(sel) catch {};
                                                    }
                                                },
                                                else => {},
                                            }
                                            _ = posix.write(pty_instance.pipe_fds[1], "x") catch {};
                                        }
                                    },
                                    .release => {
                                        pty_instance.selection_start = null;
                                    },
                                    .motion => {},
                                }
                            } else {
                                var encode_buf: [32]u8 = undefined;
                                var writer = std.Io.Writer.fixed(&encode_buf);

                                mouse_encode.encode(&writer, mouse, state.terminal) catch |err| {
                                    std.log.err("Failed to encode mouse: {}", .{err});
                                    return;
                                };

                                const encoded = writer.buffered();
                                if (encoded.len > 0) {
                                    _ = posix.write(pty_instance.process.master, encoded) catch |err| {
                                        std.log.err("Write to PTY failed: {}", .{err});
                                    };
                                }
                            }
                        } else {
                            std.log.warn("mouse_input notification: session {} not found", .{session_id});
                        }
                    } else {
                        std.log.warn("mouse_input notification: invalid params", .{});
                    }
                } else if (std.mem.eql(u8, notif.method, "resize_pty")) {
                    if (notif.params == .array and notif.params.array.len >= 3) {
                        const session_id: usize = switch (notif.params.array[0]) {
                            .unsigned => |u| @intCast(u),
                            .integer => |i| @intCast(i),
                            else => {
                                std.log.warn("resize_pty notification: invalid session_id type", .{});
                                return;
                            },
                        };
                        const rows: u16 = switch (notif.params.array[1]) {
                            .unsigned => |u| @intCast(u),
                            .integer => |i| @intCast(i),
                            else => {
                                std.log.warn("resize_pty notification: invalid rows type", .{});
                                return;
                            },
                        };
                        const cols: u16 = switch (notif.params.array[2]) {
                            .unsigned => |u| @intCast(u),
                            .integer => |i| @intCast(i),
                            else => {
                                std.log.warn("resize_pty notification: invalid cols type", .{});
                                return;
                            },
                        };

                        var x_pixel: u16 = 0;
                        var y_pixel: u16 = 0;

                        if (notif.params.array.len >= 5) {
                            x_pixel = switch (notif.params.array[3]) {
                                .unsigned => |u| @intCast(u),
                                .integer => |i| @intCast(i),
                                else => 0,
                            };
                            y_pixel = switch (notif.params.array[4]) {
                                .unsigned => |u| @intCast(u),
                                .integer => |i| @intCast(i),
                                else => 0,
                            };
                        }

                        if (self.server.ptys.get(session_id)) |pty_instance| {
                            // Always resize if we get an event, as pixel dimensions might have changed even if rows/cols didn't?
                            // But usually we check rows/cols match.
                            // Let's keep the optimization but check pixels too if they are non-zero?
                            // Ghostty internal terminal doesn't store pixel size directly in public fields easily?
                            // It stores cols/rows.
                            // But we should update PTY size with pixels.

                            const size: pty.winsize = .{
                                .ws_row = rows,
                                .ws_col = cols,
                                .ws_xpixel = x_pixel,
                                .ws_ypixel = y_pixel,
                            };
                            var pty_mut = pty_instance.process;
                            pty_mut.setSize(size) catch |err| {
                                std.log.err("Resize PTY failed: {}", .{err});
                            };

                            // Also resize the terminal state
                            pty_instance.terminal_mutex.lock();
                            if (pty_instance.terminal.rows != rows or pty_instance.terminal.cols != cols) {
                                pty_instance.terminal.resize(
                                    pty_instance.allocator,
                                    cols,
                                    rows,
                                ) catch |err| {
                                    std.log.err("Resize terminal failed: {}", .{err});
                                };
                            }
                            // Update pixel dimensions for mouse encoding
                            pty_instance.terminal.width_px = x_pixel;
                            pty_instance.terminal.height_px = y_pixel;

                            // Send in-band size report if mode 2048 is enabled
                            if (pty_instance.terminal.modes.get(.in_band_size_reports)) {
                                var report_buf: [64]u8 = undefined;
                                const report = std.fmt.bufPrint(&report_buf, "\x1b[48;{};{};{};{}t", .{
                                    rows,
                                    cols,
                                    y_pixel,
                                    x_pixel,
                                }) catch unreachable;
                                _ = posix.write(pty_instance.process.master, report) catch |err| {
                                    std.log.err("Failed to send in-band size report: {}", .{err});
                                };
                            }
                            pty_instance.terminal_mutex.unlock();
                        } else {
                            std.log.warn("resize_pty notification: session {} not found", .{session_id});
                        }
                    } else {
                        std.log.warn("resize_pty notification: invalid params", .{});
                    }
                }
            },
            .response => {
                // std.log.warn("Client sent response, ignoring", .{});
            },
        }
    }

    fn onRecv(loop: *io.Loop, completion: io.Completion) anyerror!void {
        const client = completion.userdataCast(Client);

        switch (completion.result) {
            .recv => |bytes_read| {
                if (bytes_read == 0) {
                    // EOF - client disconnected
                    std.log.debug("Client fd={} disconnected (EOF)", .{client.fd});
                    client.server.removeClient(client);
                } else {
                    std.log.debug("Received {} bytes from client fd={}", .{ bytes_read, client.fd });
                    // Got data, try to parse as RPC message
                    const data = client.recv_buffer[0..bytes_read];
                    client.handleMessage(loop, data) catch |err| {
                        std.log.err("Failed to handle message: {}", .{err});
                    };

                    // Keep receiving
                    _ = try loop.recv(client.fd, &client.recv_buffer, .{
                        .ptr = client,
                        .cb = onRecv,
                    });
                }
            },
            .err => {
                std.log.debug("Client fd={} disconnected (error)", .{client.fd});
                client.server.removeClient(client);
            },
            else => unreachable,
        }
    }
};

const Server = struct {
    allocator: std.mem.Allocator,
    loop: *io.Loop,
    listen_fd: posix.fd_t,
    socket_path: []const u8,
    clients: std.ArrayList(*Client),
    ptys: std.AutoHashMap(usize, *Pty),
    next_session_id: usize = 0,
    accepting: bool = true,
    accept_task: ?io.Task = null,
    exit_on_idle: bool = false,
    signal_pipe_fds: [2]posix.fd_t,
    signal_buf: [1]u8 = undefined,

    fn parseSpawnPtyParams(params: msgpack.Value) struct { size: pty.winsize, attach: bool } {
        var rows: u16 = 24;
        var cols: u16 = 80;
        var attach: bool = false;

        if (params == .map) {
            for (params.map) |kv| {
                if (kv.key != .string) continue;
                if (std.mem.eql(u8, kv.key.string, "rows") and kv.value == .unsigned) {
                    rows = @intCast(kv.value.unsigned);
                } else if (std.mem.eql(u8, kv.key.string, "cols") and kv.value == .unsigned) {
                    cols = @intCast(kv.value.unsigned);
                } else if (std.mem.eql(u8, kv.key.string, "attach") and kv.value == .boolean) {
                    attach = kv.value.boolean;
                }
            }
        }

        return .{
            .size = .{
                .ws_row = rows,
                .ws_col = cols,
                .ws_xpixel = 0,
                .ws_ypixel = 0,
            },
            .attach = attach,
        };
    }

    fn prepareSpawnEnv(allocator: std.mem.Allocator, env_map: *std.process.EnvMap) !std.ArrayList([]const u8) {
        try env_map.put("TERM", "xterm-256color");
        try env_map.put("COLORTERM", "truecolor");

        var env_list = std.ArrayList([]const u8).empty;
        var it = env_map.iterator();
        while (it.next()) |entry| {
            const key_eq_val = try std.fmt.allocPrint(allocator, "{s}={s}", .{ entry.key_ptr.*, entry.value_ptr.* });
            try env_list.append(allocator, key_eq_val);
        }
        return env_list;
    }

    fn parseAttachPtyParams(params: msgpack.Value) !usize {
        return parseSessionId(params);
    }

    fn parseSessionId(params: msgpack.Value) !usize {
        if (params != .array or params.array.len < 1) {
            return error.InvalidParams;
        }
        return switch (params.array[0]) {
            .unsigned => |u| @intCast(u),
            .integer => |i| @intCast(i),
            else => error.InvalidParams,
        };
    }

    fn parseWritePtyParams(params: msgpack.Value) !struct { id: usize, data: []const u8 } {
        if (params != .array or params.array.len < 2 or params.array[0] != .unsigned or params.array[1] != .binary) {
            return error.InvalidParams;
        }
        return .{
            .id = @intCast(params.array[0].unsigned),
            .data = params.array[1].binary,
        };
    }

    fn parseResizePtyParams(params: msgpack.Value) !struct { id: usize, rows: u16, cols: u16, x_pixel: u16, y_pixel: u16 } {
        if (params != .array or params.array.len < 3 or params.array[0] != .unsigned or params.array[1] != .unsigned or params.array[2] != .unsigned) {
            return error.InvalidParams;
        }

        var x_pixel: u16 = 0;
        var y_pixel: u16 = 0;

        if (params.array.len >= 5) {
            x_pixel = switch (params.array[3]) {
                .unsigned => |u| @intCast(u),
                .integer => |i| @intCast(i),
                else => 0,
            };
            y_pixel = switch (params.array[4]) {
                .unsigned => |u| @intCast(u),
                .integer => |i| @intCast(i),
                else => 0,
            };
        }

        return .{
            .id = @intCast(params.array[0].unsigned),
            .rows = @intCast(params.array[1].unsigned),
            .cols = @intCast(params.array[2].unsigned),
            .x_pixel = x_pixel,
            .y_pixel = y_pixel,
        };
    }

    fn parseDetachPtyParams(params: msgpack.Value) !struct { id: usize, client_fd: posix.fd_t } {
        if (params != .array or params.array.len < 2 or params.array[0] != .unsigned or params.array[1] != .unsigned) {
            return error.InvalidParams;
        }
        return .{
            .id = @intCast(params.array[0].unsigned),
            .client_fd = @intCast(params.array[1].unsigned),
        };
    }

    fn handleRequest(self: *Server, client: *Client, method: []const u8, params: msgpack.Value) !msgpack.Value {
        if (std.mem.eql(u8, method, "ping")) {
            return msgpack.Value{ .string = try self.allocator.dupe(u8, "pong") };
        } else if (std.mem.eql(u8, method, "spawn_pty")) {
            const parsed = parseSpawnPtyParams(params);
            std.log.info("spawn_pty: rows={} cols={} attach={}", .{ parsed.size.ws_row, parsed.size.ws_col, parsed.attach });

            const shell = std.posix.getenv("SHELL") orelse "/bin/sh";

            // Prepare environment
            var env_map = try std.process.getEnvMap(self.allocator);
            defer env_map.deinit();

            var env_list = try prepareSpawnEnv(self.allocator, &env_map);
            // Manage lifetime of strings in env_list
            defer {
                for (env_list.items) |item| {
                    self.allocator.free(item);
                }
                env_list.deinit(self.allocator);
            }

            const process = try pty.Process.spawn(self.allocator, parsed.size, &.{shell}, @ptrCast(env_list.items));

            const session_id = self.next_session_id;
            self.next_session_id += 1;

            const pty_instance = try Pty.init(self.allocator, session_id, process, parsed.size);
            pty_instance.server_ptr = self;

            try self.ptys.put(session_id, pty_instance);

            pty_instance.read_thread = try std.Thread.spawn(.{}, Pty.readThread, .{ pty_instance, self });

            // Register dirty signal pipe
            _ = try self.loop.read(pty_instance.pipe_fds[0], &pty_instance.dirty_signal_buf, .{
                .ptr = pty_instance,
                .cb = onPtyDirty,
            });

            if (parsed.attach) {
                try client.attached_sessions.append(self.allocator, session_id);

                // Send initial redraw
                std.log.info("Sending initial redraw for session {}", .{session_id});
                const msg = try buildRedrawMessageFromPty(self.allocator, pty_instance, .full);
                defer self.allocator.free(msg);
                try self.sendRedraw(self.loop, pty_instance, msg, client);
            }

            std.log.info("Created session {} with PID {}", .{ session_id, process.pid });

            return msgpack.Value{ .unsigned = session_id };
        } else if (std.mem.eql(u8, method, "attach_pty")) {
            std.log.info("attach_pty called with params: {}", .{params});
            const session_id = parseAttachPtyParams(params) catch |err| {
                std.log.warn("attach_pty: invalid params: {}", .{err});
                return msgpack.Value{ .string = try self.allocator.dupe(u8, "invalid params") };
            };

            std.log.info("attach_pty: session_id={} client_fd={}", .{ session_id, client.fd });

            const pty_instance = self.ptys.get(session_id) orelse {
                std.log.warn("attach_pty: session {} not found", .{session_id});
                return msgpack.Value{ .string = try self.allocator.dupe(u8, "session not found") };
            };

            try pty_instance.addClient(self.allocator, client);
            try client.attached_sessions.append(self.allocator, session_id);
            std.log.info("Client {} attached to session {}", .{ client.fd, session_id });

            // Send full redraw to the newly attached client
            const msg = try buildRedrawMessageFromPty(
                self.allocator,
                pty_instance,
                .full,
            );
            defer self.allocator.free(msg);

            try self.sendRedraw(self.loop, pty_instance, msg, client);

            return msgpack.Value{ .unsigned = session_id };
        } else if (std.mem.eql(u8, method, "write_pty")) {
            const args = parseWritePtyParams(params) catch {
                return msgpack.Value{ .string = try self.allocator.dupe(u8, "invalid params") };
            };
            const session_id = args.id;
            const data = args.data;

            const pty_instance = self.ptys.get(session_id) orelse {
                return msgpack.Value{ .string = try self.allocator.dupe(u8, "session not found") };
            };

            _ = posix.write(pty_instance.process.master, data) catch |err| {
                std.log.err("Write to PTY failed: {}", .{err});
                return msgpack.Value{ .string = try self.allocator.dupe(u8, "write failed") };
            };

            return msgpack.Value.nil;
        } else if (std.mem.eql(u8, method, "resize_pty")) {
            const args = parseResizePtyParams(params) catch {
                return msgpack.Value{ .string = try self.allocator.dupe(u8, "invalid params") };
            };
            const session_id = args.id;
            const rows = args.rows;
            const cols = args.cols;
            const x_pixel = args.x_pixel;
            const y_pixel = args.y_pixel;

            const pty_instance = self.ptys.get(session_id) orelse {
                return msgpack.Value{ .string = try self.allocator.dupe(u8, "session not found") };
            };

            // Update PTY size including pixels
            const size: pty.winsize = .{
                .ws_row = rows,
                .ws_col = cols,
                .ws_xpixel = x_pixel,
                .ws_ypixel = y_pixel,
            };

            var pty_mut = pty_instance.process;
            pty_mut.setSize(size) catch |err| {
                std.log.err("Resize PTY failed: {}", .{err});
                return msgpack.Value{ .string = try self.allocator.dupe(u8, "resize failed") };
            };

            // Also resize the terminal state if grid dimensions changed
            if (pty_instance.terminal.rows != rows or pty_instance.terminal.cols != cols) {
                pty_instance.terminal_mutex.lock();
                pty_instance.terminal.resize(
                    pty_instance.allocator,
                    cols,
                    rows,
                ) catch |err| {
                    std.log.err("Resize terminal failed: {}", .{err});
                };
                pty_instance.terminal_mutex.unlock();
            }

            std.log.info("Resized session {} to {}x{} ({}x{}px)", .{ session_id, rows, cols, x_pixel, y_pixel });
            return msgpack.Value.nil;
        } else if (std.mem.eql(u8, method, "detach_pty")) {
            const args = parseDetachPtyParams(params) catch {
                return msgpack.Value{ .string = try self.allocator.dupe(u8, "invalid params") };
            };
            const session_id = args.id;
            const client_fd = args.client_fd;

            const pty_instance = self.ptys.get(session_id) orelse {
                return msgpack.Value{ .string = try self.allocator.dupe(u8, "session not found") };
            };

            // Mark session as keep_alive since client explicitly detached
            pty_instance.keep_alive = true;

            // Find client by fd and detach
            for (self.clients.items) |c| {
                if (c.fd == client_fd) {
                    pty_instance.removeClient(c);
                    for (c.attached_sessions.items, 0..) |sid, i| {
                        if (sid == session_id) {
                            _ = c.attached_sessions.swapRemove(i);
                            break;
                        }
                    }
                    std.log.info("Client {} detached from session {} (marked keep_alive)", .{ c.fd, session_id });
                    break;
                }
            }

            return msgpack.Value.nil;
        } else if (std.mem.eql(u8, method, "get_selection")) {
            const session_id = parseSessionId(params) catch {
                return msgpack.Value{ .string = try self.allocator.dupe(u8, "invalid params") };
            };

            const pty_instance = self.ptys.get(session_id) orelse {
                return msgpack.Value{ .string = try self.allocator.dupe(u8, "session not found") };
            };

            pty_instance.terminal_mutex.lock();
            defer pty_instance.terminal_mutex.unlock();

            const screen = pty_instance.terminal.screens.active;
            const sel = screen.selection orelse {
                return msgpack.Value.nil;
            };

            const result = screen.selectionString(self.allocator, .{
                .sel = sel,
                .trim = true,
            }) catch |err| {
                std.log.err("Failed to get selection string: {}", .{err});
                return msgpack.Value.nil;
            };

            return msgpack.Value{ .string = result };
        } else if (std.mem.eql(u8, method, "clear_selection")) {
            const session_id = parseSessionId(params) catch {
                return msgpack.Value{ .string = try self.allocator.dupe(u8, "invalid params") };
            };

            const pty_instance = self.ptys.get(session_id) orelse {
                return msgpack.Value{ .string = try self.allocator.dupe(u8, "session not found") };
            };

            pty_instance.terminal_mutex.lock();
            const screen = pty_instance.terminal.screens.active;
            screen.select(null) catch {};
            pty_instance.terminal_mutex.unlock();

            _ = posix.write(pty_instance.pipe_fds[1], "x") catch {};

            return msgpack.Value.nil;
        } else {
            return msgpack.Value{ .string = try self.allocator.dupe(u8, "unknown method") };
        }
    }

    fn shouldExit(self: *Server) bool {
        return self.exit_on_idle and self.clients.items.len == 0;
    }

    fn cleanupSessionsForClient(self: *Server, client: *Client) void {
        var to_remove = std.ArrayList(usize).empty;
        defer to_remove.deinit(self.allocator);

        for (client.attached_sessions.items) |session_id| {
            if (self.ptys.get(session_id)) |pty_instance| {
                pty_instance.removeClient(client);
                std.log.info("Auto-removed client {} from session {}", .{ client.fd, session_id });

                // If no more clients attached and not marked keep_alive, kill the session
                if (pty_instance.clients.items.len == 0 and !pty_instance.keep_alive) {
                    to_remove.append(self.allocator, session_id) catch {};
                }
            }
        }

        // Also cleanup any orphaned sessions with no clients and not keep_alive
        var it = self.ptys.iterator();
        while (it.next()) |entry| {
            const pty_instance = entry.value_ptr.*;
            if (pty_instance.clients.items.len == 0 and !pty_instance.keep_alive) {
                to_remove.append(self.allocator, pty_instance.id) catch {};
            }
        }

        for (to_remove.items) |session_id| {
            if (self.ptys.getPtr(session_id)) |pty_ptr| {
                std.log.info("Killing session {} (no clients, not keep_alive)", .{session_id});
                // Signal PTY to stop and cancel I/O, but don't join thread yet
                // Thread join happens in startServer defer block after event loop exits
                pty_ptr.*.stopAndCancelIO(self.loop);
            }
        }
    }

    fn checkExit(self: *Server) !void {
        if (self.shouldExit() and self.accepting) {
            self.accepting = false;
            if (self.accept_task) |*task| {
                try task.cancel(self.loop);
                self.accept_task = null;
            }
        }
    }

    fn onAccept(loop: *io.Loop, completion: io.Completion) anyerror!void {
        const self = completion.userdataCast(Server);

        switch (completion.result) {
            .accept => |client_fd| {
                std.log.debug("Accepted client connection fd={}", .{client_fd});
                const client = try self.allocator.create(Client);
                client.* = .{
                    .fd = client_fd,
                    .server = self,
                    .send_queue = std.ArrayList([]u8).empty,
                    .attached_sessions = std.ArrayList(usize).empty,
                    // .style_cache = std.AutoHashMap(u16, redraw.UIEvent.Style.Attributes).init(self.allocator),
                };
                try self.clients.append(self.allocator, client);
                std.log.debug("Total clients: {}", .{self.clients.items.len});

                // Start recv to detect disconnect
                _ = try loop.recv(client_fd, &client.recv_buffer, .{
                    .ptr = client,
                    .cb = Client.onRecv,
                });

                // Queue next accept if still accepting
                if (self.accepting) {
                    self.accept_task = try loop.accept(self.listen_fd, .{
                        .ptr = self,
                        .cb = onAccept,
                    });
                }
            },
            .err => |err| {
                std.log.err("Accept error: {}", .{err});
            },
            else => unreachable,
        }
    }

    fn removeClient(self: *Server, client: *Client) void {
        std.log.debug("Removing client fd={}", .{client.fd});
        // Cleanup sessions (kill if no clients remain and not keep_alive)
        self.cleanupSessionsForClient(client);

        // Free any queued sends
        for (client.send_queue.items) |buf| {
            self.allocator.free(buf);
        }
        client.send_queue.deinit(self.allocator);

        // Free in-flight send buffer
        if (client.send_buffer) |buf| {
            self.allocator.free(buf);
            client.send_buffer = null;
        }

        client.attached_sessions.deinit(self.allocator);
        // client.style_cache.deinit();

        for (self.clients.items, 0..) |c, i| {
            if (c == client) {
                _ = self.clients.swapRemove(i);
                break;
            }
        }

        // Cancel any pending tasks for this client's FD before closing it
        self.loop.cancelByFd(client.fd);

        _ = self.loop.close(client.fd, .{
            .ptr = null,
            .cb = struct {
                fn noop(_: *io.Loop, _: io.Completion) anyerror!void {}
            }.noop,
        }) catch {};
        self.allocator.destroy(client);
        std.log.debug("Total clients: {}", .{self.clients.items.len});
        self.checkExit() catch {};
    }

    /// Send redraw notification (bytes) to attached clients
    fn sendRedraw(self: *Server, loop: *io.Loop, pty_instance: *Pty, msg: []const u8, target_client: ?*Client) !void {
        std.log.debug("sendRedraw: session={} bytes={} target_client={} total_clients={}", .{ pty_instance.id, msg.len, target_client != null, self.clients.items.len });

        // Send to each client attached to this session
        for (self.clients.items) |client| {
            // If we have a target client, skip others
            if (target_client) |target| {
                if (client != target) {
                    continue;
                }
            }

            // Check if client is attached to this session
            var attached = false;
            for (client.attached_sessions.items) |sid| {
                if (sid == pty_instance.id) {
                    attached = true;
                    break;
                }
            }
            if (!attached) {
                continue;
            }

            try client.sendData(loop, msg);
        }
    }

    fn renderFrame(self: *Server, pty_instance: *Pty) void {
        const start_time = std.time.nanoTimestamp();

        const msg = buildRedrawMessageFromPty(
            self.allocator,
            pty_instance,
            .incremental,
        ) catch |err| {
            std.log.err("Failed to build redraw message for session {}: {}", .{ pty_instance.id, err });
            return;
        };
        defer self.allocator.free(msg);

        const build_time = std.time.nanoTimestamp();

        // Build and send redraw notifications
        self.sendRedraw(self.loop, pty_instance, msg, null) catch |err| {
            std.log.err("Failed to send redraw for session {}: {}", .{ pty_instance.id, err });
        };

        const send_time = std.time.nanoTimestamp();
        const build_us = @divTrunc(build_time - start_time, std.time.ns_per_us);
        const send_us = @divTrunc(send_time - build_time, std.time.ns_per_us);

        std.log.info("renderFrame: build={}us send={}us", .{ build_us, send_us });

        // Update timestamp
        pty_instance.last_render_time = std.time.milliTimestamp();
    }

    /// Build and send pty_exited notification to all clients
    fn sendPtyExited(self: *Server, pty_id: usize, exit_status: u32) !void {
        const params = .{ pty_id, exit_status };
        const msg_bytes = try msgpack.encode(self.allocator, .{ 2, "pty_exited", params });
        defer self.allocator.free(msg_bytes);

        std.log.info("Sending pty_exited for session {} status {}", .{ pty_id, exit_status });

        // Send to all clients
        for (self.clients.items) |client| {
            try client.sendData(self.loop, msg_bytes);
        }
    }

    fn shutdown(self: *Server) void {
        std.log.info("Shutting down server...", .{});

        // Stop accepting
        self.accepting = false;
        if (self.accept_task) |*task| {
            task.cancel(self.loop) catch {};
            self.accept_task = null;
        }

        // Close all clients
        while (self.clients.items.len > 0) {
            const client = self.clients.items[0];
            self.removeClient(client);
        }

        // Cancel signal watcher
        self.loop.cancelByFd(self.signal_pipe_fds[0]);

        // Signal all PTYs to stop and cancel their pending I/O
        // (thread joins happen after event loop exits in startServer defer)
        var it = self.ptys.valueIterator();
        while (it.next()) |pty_instance| {
            pty_instance.*.stopAndCancelIO(self.loop);
        }
    }

    fn onSignal(loop: *io.Loop, completion: io.Completion) anyerror!void {
        const self = completion.userdataCast(Server);

        switch (completion.result) {
            .read => |n| {
                if (n == 0) return;
                // Drain
                var buf: [128]u8 = undefined;
                while (true) {
                    _ = posix.read(self.signal_pipe_fds[0], &buf) catch |err| {
                        if (err == error.WouldBlock) break;
                        break;
                    };
                }

                self.shutdown();
            },
            .err => |err| {
                std.log.err("Signal pipe error: {}", .{err});
            },
            else => {},
        }
        _ = loop;
    }

    fn onRenderTimer(loop: *io.Loop, completion: io.Completion) anyerror!void {
        _ = loop;
        const pty_instance = completion.userdataCast(Pty);
        const server: *Server = @ptrCast(@alignCast(pty_instance.server_ptr));
        server.renderFrame(pty_instance);
        pty_instance.render_timer = null;
    }

    fn onPtyDirty(loop: *io.Loop, completion: io.Completion) anyerror!void {
        const pty_instance = completion.userdataCast(Pty);
        const server: *Server = @ptrCast(@alignCast(pty_instance.server_ptr));

        switch (completion.result) {
            .read => |n| {
                if (n == 0) return;

                // Drain pipe
                var buf: [128]u8 = undefined;
                while (true) {
                    _ = posix.read(pty_instance.pipe_fds[0], &buf) catch |err| {
                        if (err == error.WouldBlock) break;
                        break;
                    };
                }

                // Check if exited
                if (pty_instance.exited.load(.acquire)) {
                    const status = pty_instance.exit_status.load(.acquire);
                    server.sendPtyExited(pty_instance.id, status) catch |err| {
                        std.log.err("Failed to send pty_exited: {}", .{err});
                    };
                    // Render final frame
                    server.renderFrame(pty_instance);
                    return;
                }

                const now = std.time.milliTimestamp();
                const FRAME_TIME = 8;

                if (now - pty_instance.last_render_time >= FRAME_TIME) {
                    server.renderFrame(pty_instance);
                } else if (pty_instance.render_timer == null) {
                    const delay = FRAME_TIME - (now - pty_instance.last_render_time);
                    // Make sure delay is positive
                    const safe_delay = if (delay < 0) 0 else delay;
                    pty_instance.render_timer = try loop.timeout(@as(u64, @intCast(safe_delay)) * std.time.ns_per_ms, .{
                        .ptr = pty_instance,
                        .cb = onRenderTimer,
                    });
                }

                // Re-arm
                _ = try loop.read(pty_instance.pipe_fds[0], &pty_instance.dirty_signal_buf, .{
                    .ptr = pty_instance,
                    .cb = onPtyDirty,
                });
            },
            .err => |err| {
                std.log.err("Pty dirty pipe error: {}", .{err});
            },
            else => {},
        }
    }
};

pub fn startServer(allocator: std.mem.Allocator, socket_path: []const u8) !void {
    std.log.info("Starting server on {s}", .{socket_path});

    var loop = try io.Loop.init(allocator);
    defer loop.deinit();

    // Check if socket exists and if a server is already running
    if (std.fs.accessAbsolute(socket_path, .{})) {
        // Socket exists - test if server is alive
        const test_fd = posix.socket(posix.AF.UNIX, posix.SOCK.STREAM | posix.SOCK.CLOEXEC, 0) catch |err| {
            std.log.err("Failed to create test socket: {}", .{err});
            return err;
        };
        defer posix.close(test_fd);

        var addr: posix.sockaddr.un = undefined;
        addr.family = posix.AF.UNIX;
        @memcpy(addr.path[0..socket_path.len], socket_path);
        addr.path[socket_path.len] = 0;

        if (posix.connect(test_fd, @ptrCast(&addr), @sizeOf(posix.sockaddr.un))) {
            // Connection succeeded - server is already running
            std.log.err("Server is already running on {s}", .{socket_path});
            return error.AddressInUse;
        } else |err| {
            if (err == error.ConnectionRefused or err == error.FileNotFound) {
                // Stale socket
                std.log.info("Removing stale socket", .{});
                posix.unlink(socket_path) catch {};
            } else {
                std.log.err("Failed to test socket: {}", .{err});
                return err;
            }
        }
    } else |err| {
        if (err != error.FileNotFound) return err;
        // Socket doesn't exist, continue
    }

    // Create socket
    const listen_fd = try posix.socket(posix.AF.UNIX, posix.SOCK.STREAM | posix.SOCK.CLOEXEC, 0);
    errdefer posix.close(listen_fd);

    // Bind to socket path
    var addr: posix.sockaddr.un = undefined;
    addr.family = posix.AF.UNIX;
    @memcpy(addr.path[0..socket_path.len], socket_path);
    addr.path[socket_path.len] = 0;

    try posix.bind(listen_fd, @ptrCast(&addr), @sizeOf(posix.sockaddr.un));

    // Listen
    try posix.listen(listen_fd, 128);

    // Create signal pipe
    const signal_pipe_fds = try posix.pipe2(.{ .NONBLOCK = true, .CLOEXEC = true });
    signal_write_fd = signal_pipe_fds[1];

    var sa: posix.Sigaction = .{
        .handler = .{ .handler = signalHandler },
        .mask = posix.sigemptyset(),
        .flags = 0,
    };
    posix.sigaction(posix.SIG.INT, &sa, null);
    posix.sigaction(posix.SIG.TERM, &sa, null);

    var server: Server = .{
        .allocator = allocator,
        .loop = &loop,
        .listen_fd = listen_fd,
        .socket_path = socket_path,
        .clients = std.ArrayList(*Client).empty,
        .ptys = std.AutoHashMap(usize, *Pty).init(allocator),
        .signal_pipe_fds = signal_pipe_fds,
    };
    defer {
        posix.close(signal_pipe_fds[0]);
        posix.close(signal_pipe_fds[1]);
        for (server.clients.items) |client| {
            posix.close(client.fd);
            client.attached_sessions.deinit(allocator);
            // client.style_cache.deinit();
            allocator.destroy(client);
        }
        server.clients.deinit(allocator);
        server.ptys.deinit();
    }

    // Start accepting connections
    server.accept_task = try loop.accept(listen_fd, .{
        .ptr = &server,
        .cb = Server.onAccept,
    });

    // Register signal watcher
    _ = try loop.read(signal_pipe_fds[0], &server.signal_buf, .{
        .ptr = &server,
        .cb = Server.onSignal,
    });

    // Run until server decides to exit
    try loop.run(.until_done);

    // Block signals during thread cleanup to prevent EINTR interrupting joins
    var block_mask = posix.sigemptyset();
    posix.sigaddset(&block_mask, posix.SIG.INT);
    posix.sigaddset(&block_mask, posix.SIG.TERM);
    posix.sigprocmask(posix.SIG.BLOCK, &block_mask, null);

    // Join all PTY threads before exiting
    var it = server.ptys.valueIterator();
    while (it.next()) |pty_instance| {
        pty_instance.*.joinAndFree(allocator);
    }
    server.ptys.clearRetainingCapacity();

    // Cleanup
    posix.close(listen_fd);
    posix.unlink(socket_path) catch {};
}

test "server lifecycle - shutdown when no clients" {
    const testing = std.testing;

    var loop = try io.Loop.init(testing.allocator);
    defer loop.deinit();

    var server: Server = .{
        .allocator = testing.allocator,
        .loop = &loop,
        .listen_fd = 100,
        .socket_path = "/tmp/test.sock",
        .clients = std.ArrayList(*Client).empty,
        .ptys = std.AutoHashMap(usize, *Pty).init(testing.allocator),
        .exit_on_idle = true,
        .signal_pipe_fds = undefined,
    };
    defer server.clients.deinit(testing.allocator);
    defer server.ptys.deinit();

    server.accept_task = try loop.accept(100, .{
        .ptr = &server,
        .cb = Server.onAccept,
    });

    try testing.expect(server.accepting);
    try testing.expect(server.shouldExit());

    try server.checkExit();

    try testing.expect(!server.accepting);
    try testing.expect(server.accept_task == null);
}

test "server lifecycle - accept client connection" {
    const testing = std.testing;

    var loop = try io.Loop.init(testing.allocator);
    defer loop.deinit();

    var server: Server = .{
        .allocator = testing.allocator,
        .loop = &loop,
        .listen_fd = 100,
        .socket_path = "/tmp/test.sock",
        .clients = std.ArrayList(*Client).empty,
        .ptys = std.AutoHashMap(usize, *Pty).init(testing.allocator),
        .signal_pipe_fds = undefined,
    };
    defer {
        for (server.clients.items) |client| {
            testing.allocator.destroy(client);
        }
        server.clients.deinit(testing.allocator);
        server.ptys.deinit();
    }

    server.accept_task = try loop.accept(100, .{
        .ptr = &server,
        .cb = Server.onAccept,
    });

    try loop.completeAccept(100);
    try loop.run(.once);

    try testing.expectEqual(@as(usize, 1), server.clients.items.len);
    try testing.expect(server.accepting);
}

test "server lifecycle - client disconnect triggers shutdown" {
    const testing = std.testing;

    var loop = try io.Loop.init(testing.allocator);
    defer loop.deinit();

    var server: Server = .{
        .allocator = testing.allocator,
        .loop = &loop,
        .listen_fd = 100,
        .socket_path = "/tmp/test.sock",
        .clients = std.ArrayList(*Client).empty,
        .ptys = std.AutoHashMap(usize, *Pty).init(testing.allocator),
        .exit_on_idle = true,
        .signal_pipe_fds = undefined,
    };
    defer {
        for (server.clients.items) |client| {
            testing.allocator.destroy(client);
        }
        server.clients.deinit(testing.allocator);
        server.ptys.deinit();
    }

    server.accept_task = try loop.accept(100, .{
        .ptr = &server,
        .cb = Server.onAccept,
    });

    try loop.completeAccept(100);
    try loop.run(.once);

    try testing.expectEqual(@as(usize, 1), server.clients.items.len);
    const client_fd = server.clients.items[0].fd;

    try loop.completeRecv(client_fd, "");
    try loop.run(.once);

    try testing.expectEqual(@as(usize, 0), server.clients.items.len);
    try testing.expect(!server.accepting);
}

test "server lifecycle - multiple clients" {
    const testing = std.testing;

    var loop = try io.Loop.init(testing.allocator);
    defer loop.deinit();

    var server: Server = .{
        .allocator = testing.allocator,
        .loop = &loop,
        .listen_fd = 100,
        .socket_path = "/tmp/test.sock",
        .clients = std.ArrayList(*Client).empty,
        .ptys = std.AutoHashMap(usize, *Pty).init(testing.allocator),
        .exit_on_idle = true,
        .signal_pipe_fds = undefined,
    };
    defer {
        for (server.clients.items) |client| {
            testing.allocator.destroy(client);
        }
        server.clients.deinit(testing.allocator);
        server.ptys.deinit();
    }

    server.accept_task = try loop.accept(100, .{
        .ptr = &server,
        .cb = Server.onAccept,
    });

    try loop.completeAccept(100);
    try loop.run(.once);
    try testing.expectEqual(@as(usize, 1), server.clients.items.len);

    try loop.completeAccept(100);
    try loop.run(.once);
    try testing.expectEqual(@as(usize, 2), server.clients.items.len);

    try loop.completeAccept(100);
    try loop.run(.once);
    try testing.expectEqual(@as(usize, 3), server.clients.items.len);

    const client1_fd = server.clients.items[0].fd;
    const client2_fd = server.clients.items[1].fd;
    const client3_fd = server.clients.items[2].fd;

    try loop.completeRecv(client2_fd, "");
    try loop.run(.until_done);
    try testing.expectEqual(@as(usize, 2), server.clients.items.len);

    try loop.completeRecv(client1_fd, "");
    try loop.run(.until_done);
    try testing.expectEqual(@as(usize, 1), server.clients.items.len);

    try loop.completeRecv(client3_fd, "");
    try loop.run(.until_done);
    try testing.expectEqual(@as(usize, 0), server.clients.items.len);
    try testing.expect(!server.accepting);
}

test "server lifecycle - recv error triggers disconnect" {
    const testing = std.testing;

    var loop = try io.Loop.init(testing.allocator);
    defer loop.deinit();

    var server: Server = .{
        .allocator = testing.allocator,
        .loop = &loop,
        .listen_fd = 100,
        .socket_path = "/tmp/test.sock",
        .clients = std.ArrayList(*Client).empty,
        .ptys = std.AutoHashMap(usize, *Pty).init(testing.allocator),
        .exit_on_idle = true,
        .signal_pipe_fds = undefined,
    };
    defer {
        for (server.clients.items) |client| {
            testing.allocator.destroy(client);
        }
        server.clients.deinit(testing.allocator);
        server.ptys.deinit();
    }

    server.accept_task = try loop.accept(100, .{
        .ptr = &server,
        .cb = Server.onAccept,
    });

    try loop.completeAccept(100);
    try loop.run(.once);
    try testing.expectEqual(@as(usize, 1), server.clients.items.len);
    const client_fd = server.clients.items[0].fd;

    try loop.completeWithError(client_fd, error.ConnectionReset);
    try loop.run(.once);
    try testing.expectEqual(@as(usize, 0), server.clients.items.len);
    try testing.expect(!server.accepting);
}

test "parseSpawnPtyParams" {
    const testing = std.testing;

    // Empty params - defaults
    const p1 = Server.parseSpawnPtyParams(.{ .map = &.{} });
    try testing.expectEqual(@as(u16, 24), p1.size.ws_row);
    try testing.expectEqual(@as(u16, 80), p1.size.ws_col);
    try testing.expectEqual(false, p1.attach);

    // Full params
    var params = [_]msgpack.Value.KeyValue{
        .{ .key = .{ .string = "rows" }, .value = .{ .unsigned = 40 } },
        .{ .key = .{ .string = "cols" }, .value = .{ .unsigned = 100 } },
        .{ .key = .{ .string = "attach" }, .value = .{ .boolean = true } },
    };
    const p2 = Server.parseSpawnPtyParams(.{ .map = &params });
    try testing.expectEqual(@as(u16, 40), p2.size.ws_row);
    try testing.expectEqual(@as(u16, 100), p2.size.ws_col);
    try testing.expectEqual(true, p2.attach);
}

test "prepareSpawnEnv" {
    const testing = std.testing;
    var env_map = std.process.EnvMap.init(testing.allocator);
    defer env_map.deinit();

    try env_map.put("EXISTING", "value");

    var list = try Server.prepareSpawnEnv(testing.allocator, &env_map);
    defer {
        for (list.items) |item| testing.allocator.free(item);
        list.deinit(testing.allocator);
    }

    var found_term = false;
    var found_colorterm = false;
    var found_existing = false;

    for (list.items) |item| {
        if (std.mem.startsWith(u8, item, "TERM=")) found_term = true;
        if (std.mem.startsWith(u8, item, "COLORTERM=")) found_colorterm = true;
        if (std.mem.startsWith(u8, item, "EXISTING=")) found_existing = true;
    }

    try testing.expect(found_term);
    try testing.expect(found_colorterm);
    try testing.expect(found_existing);
}

test "parseAttachPtyParams" {
    const testing = std.testing;

    var valid_args = [_]msgpack.Value{.{ .unsigned = 42 }};
    const id = try Server.parseAttachPtyParams(.{ .array = &valid_args });
    try testing.expectEqual(@as(usize, 42), id);

    var invalid_args = [_]msgpack.Value{};
    try testing.expectError(error.InvalidParams, Server.parseAttachPtyParams(.{ .array = &invalid_args }));
}

test "parseWritePtyParams" {
    const testing = std.testing;

    var valid_args = [_]msgpack.Value{
        .{ .unsigned = 42 },
        .{ .binary = "hello" },
    };
    const args = try Server.parseWritePtyParams(.{ .array = &valid_args });
    try testing.expectEqual(@as(usize, 42), args.id);
    try testing.expectEqualStrings("hello", args.data);
}

test "parseResizePtyParams" {
    const testing = std.testing;

    var valid_args = [_]msgpack.Value{
        .{ .unsigned = 42 },
        .{ .unsigned = 50 },
        .{ .unsigned = 80 },
    };
    const args = try Server.parseResizePtyParams(.{ .array = &valid_args });
    try testing.expectEqual(@as(usize, 42), args.id);
    try testing.expectEqual(@as(u16, 50), args.rows);
    try testing.expectEqual(@as(u16, 80), args.cols);
    try testing.expectEqual(@as(u16, 0), args.x_pixel);
    try testing.expectEqual(@as(u16, 0), args.y_pixel);

    var pixel_args = [_]msgpack.Value{
        .{ .unsigned = 42 },
        .{ .unsigned = 50 },
        .{ .unsigned = 80 },
        .{ .unsigned = 800 },
        .{ .unsigned = 600 },
    };
    const p_args = try Server.parseResizePtyParams(.{ .array = &pixel_args });
    try testing.expectEqual(@as(usize, 42), p_args.id);
    try testing.expectEqual(@as(u16, 50), p_args.rows);
    try testing.expectEqual(@as(u16, 80), p_args.cols);
    try testing.expectEqual(@as(u16, 800), p_args.x_pixel);
    try testing.expectEqual(@as(u16, 600), p_args.y_pixel);
}

test "parseDetachPtyParams" {
    const testing = std.testing;

    var valid_args = [_]msgpack.Value{
        .{ .unsigned = 42 },
        .{ .unsigned = 10 },
    };
    const args = try Server.parseDetachPtyParams(.{ .array = &valid_args });
    try testing.expectEqual(@as(usize, 42), args.id);
    try testing.expectEqual(@as(posix.fd_t, 10), args.client_fd);
}

test "buildRedrawMessageFromPty" {
    const testing = std.testing;
    const allocator = testing.allocator;

    var pty_inst: Pty = .{
        .id = 1,
        .process = .{ .master = -1, .slave = -1, .pid = 0 },
        .clients = std.ArrayList(*Client).empty,
        .running = std.atomic.Value(bool).init(true),
        .terminal = try ghostty_vt.Terminal.init(allocator, .{ .cols = 80, .rows = 24 }),
        .allocator = allocator,
        .title = std.ArrayList(u8).empty,
        .title_dirty = false,
        .pipe_fds = undefined,
        .exit_pipe_fds = undefined,
        .render_state = .empty,
        .server_ptr = undefined,
    };
    defer {
        pty_inst.terminal.deinit(allocator);
        pty_inst.render_state.deinit(allocator);
        pty_inst.clients.deinit(allocator);
        pty_inst.title.deinit(allocator);
    }

    const msg = try buildRedrawMessageFromPty(allocator, &pty_inst, .full);
    defer allocator.free(msg);

    try testing.expect(msg.len > 0);

    const value = try msgpack.decode(allocator, msg);
    defer value.deinit(allocator);
    try testing.expect(value == .array);
}

test "style optimization" {
    const testing = std.testing;
    const allocator = testing.allocator;

    var pty_inst: Pty = .{
        .id = 1,
        .process = .{ .master = -1, .slave = -1, .pid = 0 },
        .clients = std.ArrayList(*Client).empty,
        .running = std.atomic.Value(bool).init(true),
        .terminal = try ghostty_vt.Terminal.init(allocator, .{ .cols = 10, .rows = 5 }),
        .allocator = allocator,
        .title = std.ArrayList(u8).empty,
        .title_dirty = false,
        .pipe_fds = undefined,
        .exit_pipe_fds = undefined,
        .render_state = .empty,
        .server_ptr = undefined,
    };
    defer {
        pty_inst.terminal.deinit(allocator);
        pty_inst.render_state.deinit(allocator);
        pty_inst.clients.deinit(allocator);
        pty_inst.title.deinit(allocator);
    }

    const handler = vt_handler.Handler.init(&pty_inst.terminal);
    var stream = vt_handler.Stream.initAlloc(allocator, handler);
    defer stream.deinit();

    // Row 0: A (Default), B (Red), C (Default)
    try stream.nextSlice(&[_]u8{'A'});
    try stream.nextSlice("\x1b[31m");
    try stream.nextSlice(&[_]u8{'B'});
    try stream.nextSlice("\x1b[0m");
    try stream.nextSlice(&[_]u8{'C'});

    // Newline to start Row 1
    try stream.nextSlice("\r\n");

    // D (Red) - testing switching from Default (C) to Red (D) across rows/cells
    try stream.nextSlice("\x1b[31m");
    try stream.nextSlice(&[_]u8{'D'});

    const msg = try buildRedrawMessageFromPty(allocator, &pty_inst, .full);
    defer allocator.free(msg);

    const value = try msgpack.decode(allocator, msg);
    defer value.deinit(allocator);

    // Verify results by inspecting msgpack events
    const events = value.array[2].array;
    var style_def_red: ?u32 = null;
    var found_row0 = false;
    var found_row1 = false;

    for (events) |evt_val| {
        const name = evt_val.array[0].string;
        const args = evt_val.array[1].array;

        if (std.mem.eql(u8, name, "style")) {
            const id = @as(u32, @intCast(args[0].unsigned));
            const attrs_map = args[1].map;
            for (attrs_map) |kv| {
                if (std.mem.eql(u8, kv.key.string, "fg") and kv.value.unsigned == 0xFF0000) {
                    style_def_red = id;
                }
                if (std.mem.eql(u8, kv.key.string, "fg_idx") and kv.value.unsigned == 1) {
                    style_def_red = id;
                }
            }
        } else if (std.mem.eql(u8, name, "write")) {
            const row = @as(u16, @intCast(args[1].unsigned));
            const cells_arr = args[3].array;

            if (row == 0) {
                found_row0 = true;
                // Cell 1 should be B with red style
                const cell1 = cells_arr[1].array;
                try testing.expectEqualStrings("B", cell1[0].string);
                if (cell1.len > 1 and cell1[1] != .nil) {
                    const sid = @as(u32, @intCast(cell1[1].unsigned));
                    try testing.expectEqual(style_def_red.?, sid);
                }
            }
            if (row == 1) {
                found_row1 = true;
                // Cell 0 should be D with red style
                const cell0 = cells_arr[0].array;
                try testing.expectEqualStrings("D", cell0[0].string);
                if (cell0.len > 1 and cell0[1] != .nil) {
                    const sid = @as(u32, @intCast(cell0[1].unsigned));
                    try testing.expectEqual(style_def_red.?, sid);
                }
            }
        }
    }

    try testing.expect(style_def_red != null);
    try testing.expect(found_row0);
    try testing.expect(found_row1);
}

test "server - pty exit notification" {
    const testing = std.testing;
    const allocator = testing.allocator;

    var loop = try io.Loop.init(allocator);
    defer loop.deinit();

    var server: Server = .{
        .allocator = allocator,
        .loop = &loop,
        .listen_fd = 100,
        .socket_path = "/tmp/test.sock",
        .clients = std.ArrayList(*Client).empty,
        .ptys = std.AutoHashMap(usize, *Pty).init(allocator),
        .signal_pipe_fds = undefined,
    };
    defer {
        // cleanup
        for (server.clients.items) |client| {
            if (client.send_buffer) |buf| allocator.free(buf);
            for (client.send_queue.items) |buf| allocator.free(buf);
            client.send_queue.deinit(allocator);
            client.attached_sessions.deinit(allocator);
            allocator.destroy(client);
        }
        server.clients.deinit(allocator);
        // pty cleanup is manual here since we don't use full server lifecycle
        var it = server.ptys.valueIterator();
        while (it.next()) |p| {
            // Manually cleanup pty resources
            posix.close(p.*.pipe_fds[0]);
            posix.close(p.*.pipe_fds[1]);
            posix.close(p.*.exit_pipe_fds[0]);
            posix.close(p.*.exit_pipe_fds[1]);
            p.*.terminal.deinit(allocator);
            p.*.render_state.deinit(allocator);
            p.*.clients.deinit(allocator);
            p.*.title.deinit(allocator);
            allocator.destroy(p.*);
        }
        server.ptys.deinit();
    }

    // Add a client
    const client = try allocator.create(Client);
    client.* = .{
        .fd = 200,
        .server = &server,
        .send_queue = std.ArrayList([]u8).empty,
        .attached_sessions = std.ArrayList(usize).empty,
    };
    try server.clients.append(allocator, client);

    // Create a dummy Pty
    const pipe_fds = try posix.pipe2(.{ .NONBLOCK = true, .CLOEXEC = true });
    const exit_pipe_fds = try posix.pipe2(.{ .NONBLOCK = true, .CLOEXEC = true });
    const pty_inst = try allocator.create(Pty);
    pty_inst.* = .{
        .id = 1,
        .process = .{ .master = -1, .slave = -1, .pid = 0 },
        .clients = std.ArrayList(*Client).empty,
        .running = std.atomic.Value(bool).init(true),
        .terminal = try ghostty_vt.Terminal.init(allocator, .{ .cols = 80, .rows = 24 }),
        .allocator = allocator,
        .title = std.ArrayList(u8).empty,
        .title_dirty = false,
        .pipe_fds = pipe_fds,
        .exit_pipe_fds = exit_pipe_fds,
        .render_state = .empty,
        .server_ptr = &server,
        .exited = std.atomic.Value(bool).init(false),
        .exit_status = std.atomic.Value(u32).init(0),
    };

    try server.ptys.put(1, pty_inst);

    // Register dirty signal pipe (like in spawn_pty)
    _ = try loop.read(pty_inst.pipe_fds[0], &pty_inst.dirty_signal_buf, .{
        .ptr = pty_inst,
        .cb = Server.onPtyDirty,
    });

    // Simulate exit
    pty_inst.exited.store(true, .seq_cst);
    pty_inst.exit_status.store(123, .seq_cst);

    // Write to pipe so posix.read finds something
    _ = try posix.write(pipe_fds[1], "e");

    // Trigger mock completion
    try loop.completeRead(pipe_fds[0], "e");

    // Run loop to process onPtyDirty
    try loop.run(.once);

    // Check pending sends
    var found_send = false;
    var it = loop.pending.iterator();
    while (it.next()) |entry| {
        if (entry.value_ptr.kind == .send and entry.value_ptr.fd == 200) {
            found_send = true;

            // Verify content
            const msg = try rpc.decodeMessage(allocator, entry.value_ptr.buf);
            defer msg.deinit(allocator);

            try testing.expect(msg == .notification);
            try testing.expectEqualStrings("pty_exited", msg.notification.method);
            try testing.expectEqual(@as(usize, 2), msg.notification.params.array.len);
            try testing.expectEqual(@as(u64, 1), msg.notification.params.array[0].unsigned);
            try testing.expectEqual(@as(u64, 123), msg.notification.params.array[1].unsigned);
        }
    }
    try testing.expect(found_send);
}
