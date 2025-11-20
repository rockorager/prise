const std = @import("std");
const io = @import("io.zig");
const rpc = @import("rpc.zig");
const msgpack = @import("msgpack.zig");
const pty = @import("pty.zig");
const key_parse = @import("key_parse.zig");
const key_encode = @import("key_encode.zig");
const posix = std.posix;
const ghostty_vt = @import("ghostty-vt");
const vt_handler = @import("vt_handler.zig");
const redraw = @import("redraw.zig");

const Pty = struct {
    id: usize,
    process: pty.Process,
    clients: std.ArrayList(*Client),
    read_thread: ?std.Thread = null,
    running: std.atomic.Value(bool),
    keep_alive: bool = false,
    terminal: ghostty_vt.Terminal,
    allocator: std.mem.Allocator,

    // Synchronization for terminal access
    terminal_mutex: std.Thread.Mutex = .{},
    // Dirty signaling
    pipe_fds: [2]posix.fd_t,
    dirty_signal_buf: [1]u8 = undefined,
    last_render_time: i64 = 0,
    render_timer: ?io.Task = null,
    last_viewport: ?ghostty_vt.Pin = null,

    // Pointer to server for callbacks (opaque to avoid circular type dependency)
    server_ptr: *anyopaque = undefined,

    fn init(allocator: std.mem.Allocator, id: usize, process_instance: pty.Process, size: pty.winsize) !*Pty {
        const instance = try allocator.create(Pty);
        const pipe_fds = try posix.pipe2(.{ .NONBLOCK = true, .CLOEXEC = true });

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
            .pipe_fds = pipe_fds,
        };
        return instance;
    }

    fn deinit(self: *Pty, allocator: std.mem.Allocator, loop: *io.Loop) void {
        self.running.store(false, .seq_cst);

        // Kill the PTY process
        _ = posix.kill(self.process.pid, posix.SIG.HUP) catch {};

        if (self.read_thread) |thread| {
            thread.join();
        }
        self.process.close();

        // Cancel any pending render timer
        if (self.render_timer) |*task| {
            task.cancel(loop) catch {};
            self.render_timer = null;
        }

        // Cancel pending read on dirty signal pipe
        loop.cancelByFd(self.pipe_fds[0]);

        posix.close(self.pipe_fds[0]);
        posix.close(self.pipe_fds[1]);
        self.terminal.deinit(allocator);
        self.clients.deinit(allocator);
        allocator.destroy(self);
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

        var stream = vt_handler.Stream.initAlloc(self.allocator, handler);
        defer stream.deinit();

        while (self.running.load(.seq_cst)) {
            const n = posix.read(self.process.master, &buffer) catch |err| {
                if (err == error.WouldBlock) {
                    std.Thread.sleep(10 * std.time.ns_per_ms);
                    continue;
                }
                std.log.err("PTY read error: {}", .{err});
                break;
            };
            if (n == 0) break;

            // Lock mutex and update terminal state
            self.terminal_mutex.lock();
            defer self.terminal_mutex.unlock();

            // Parse the data through ghostty-vt to update terminal state
            stream.nextSlice(buffer[0..n]) catch |err| {
                std.log.err("Failed to parse VT sequences: {}", .{err});
                continue;
            };

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
        std.log.info("PTY read thread exiting for session {}", .{self.id});

        // Reap the child process
        const result = posix.waitpid(self.process.pid, 0);
        std.log.info("Session {} PTY process {} exited with status {}", .{ self.id, self.process.pid, result.status });
    }
};

/// Convert ghostty style to Prise Style Attributes
fn getStyleAttributes(style: ghostty_vt.Style, selected: bool) redraw.UIEvent.Style.Attributes {
    var attrs: redraw.UIEvent.Style.Attributes = .{
        .selected = selected,
    };

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
const ScreenState = struct {
    rows: usize,
    cols: usize,
    cursor_x: usize,
    cursor_y: usize,
    cursor_visible: bool,
    cursor_shape: redraw.UIEvent.CursorShape.Shape,
    rows_data: []DirtyRow,
    styles: []const redraw.UIEvent.Style,
    allocator: std.mem.Allocator,
    viewport: ghostty_vt.Pin,
    text_arena: std.heap.ArenaAllocator,

    pub const RenderMode = enum { full, incremental };

    pub const DirtyRow = struct {
        y: usize,
        cells: []CellData,
    };

    const CellData = struct {
        text: []const u8, // UTF-8 encoded
        style_id: u32,
        wide: bool, // true if this cell is wide (occupies 2 columns)
    };

    fn init(
        allocator: std.mem.Allocator,
        terminal: *ghostty_vt.Terminal,
        mutex: *std.Thread.Mutex,
        mode: RenderMode,
        last_viewport: ?ghostty_vt.Pin,
    ) !ScreenState {
        const t0 = std.time.nanoTimestamp();

        mutex.lock();
        errdefer mutex.unlock();

        // Snapshot the screen state so we can iterate without holding the lock
        var screen = try terminal.screens.active.clone(allocator, .{ .viewport = .{} }, null);

        const t1 = std.time.nanoTimestamp();

        // Get current viewport pin from live terminal
        // We expect this to always return a valid pin
        const current_viewport = terminal.screens.active.pages.pin(.{ .viewport = .{} }).?;

        // Determine effective mode based on dirty flags and viewport changes
        var effective_mode = mode;

        // Check terminal flags (palette, clear, etc)
        if (!std.meta.eql(terminal.flags.dirty, .{})) effective_mode = .full;

        // Check screen flags (selection, etc)
        if (!std.meta.eql(terminal.screens.active.dirty, .{})) effective_mode = .full;

        // Check if we scrolled (viewport changed)
        if (last_viewport) |prev| {
            if (!prev.eql(current_viewport)) effective_mode = .full;
        } else {
            effective_mode = .full;
        }

        // Clear all dirty flags
        terminal.flags.dirty = .{};
        terminal.screens.active.dirty = .{};
        var it = terminal.screens.active.pages.pageIterator(.right_down, .{ .screen = .{} }, null);
        while (it.next()) |chunk| {
            var ds = chunk.node.data.dirtyBitSet();
            ds.unsetAll();
        }

        mutex.unlock();

        const t2 = std.time.nanoTimestamp();
        defer screen.deinit();

        const rows = screen.pages.rows;
        const cols = screen.pages.cols;

        var text_arena = std.heap.ArenaAllocator.init(allocator);
        errdefer text_arena.deinit();
        const arena_allocator = text_arena.allocator();

        var styles_list = std.ArrayList(redraw.UIEvent.Style).empty;
        errdefer styles_list.deinit(allocator);

        // Map from style hash to our style ID for deduplication within this frame
        var styles_map = std.AutoHashMap(u64, u32).init(allocator);
        defer styles_map.deinit();

        // Ensure default style is ID 0
        const StyleKey = struct { style: ghostty_vt.Style, selected: bool };
        const default_style = ghostty_vt.Style{
            .fg_color = .none,
            .bg_color = .none,
            .underline_color = .none,
            .flags = .{},
        };
        const default_key = StyleKey{ .style = default_style, .selected = false };
        const default_hash = std.hash.Wyhash.hash(0, std.mem.asBytes(&default_key));
        try styles_map.put(default_hash, 0);
        try styles_list.append(allocator, .{ .id = 0, .attrs = .{} });
        var next_style_id: u32 = 1;

        var rows_data = std.ArrayList(DirtyRow).empty;
        errdefer {
            for (rows_data.items) |row| {
                allocator.free(row.cells);
            }
            rows_data.deinit(allocator);
        }

        var utf8_buf: [4]u8 = undefined;
        var grapheme_buf: [32]u21 = undefined;

        var time_style_ops: i128 = 0;
        var time_text_ops: i128 = 0;

        // Iterate over the viewport
        var row_it = screen.pages.rowIterator(.right_down, .{ .viewport = .{} }, null);
        var y: usize = 0;
        var dirty_row_count: usize = 0;

        while (row_it.next()) |row| : (y += 1) {
            // If our viewport is smaller than the pages rows (can happen?), stop.
            if (y >= rows) break;

            // If incremental, skip non-dirty rows
            if (effective_mode == .incremental and !row.isDirty()) continue;
            dirty_row_count += 1;

            var cells = try allocator.alloc(CellData, cols);
            errdefer allocator.free(cells);

            const row_cells = row.cells(.all);
            // If row_cells is smaller than cols, we pad with empty cells?
            // Ghostty's row.cells(.all) should return the full width generally,
            // but let's be safe and iterate up to cols.

            for (0..cols) |x| {
                // Default cell if out of bounds
                const cell = if (x < row_cells.len) &row_cells[x] else &ghostty_vt.Cell.init(0);

                // Skip spacer tails
                if (cell.wide == .spacer_tail) {
                    cells[x] = .{
                        .text = try arena_allocator.dupe(u8, ""),
                        .style_id = 0,
                        .wide = false,
                    };
                    continue;
                }

                // Check selection
                const selected = if (screen.selection) |sel|
                    sel.contains(&screen, .{ .node = row.node, .y = row.y, .x = @intCast(x) })
                else
                    false;

                const ts0 = std.time.nanoTimestamp();

                // Get ghostty style for this cell
                var vt_style = row.style(cell);

                // Handle direct color cells (bg_color_rgb / bg_color_palette)
                var text: []const u8 = "";
                var is_direct_color = false;

                if (cell.content_tag == .bg_color_rgb) {
                    const cell_rgb = cell.content.color_rgb;
                    vt_style.bg_color = .{ .rgb = .{ .r = cell_rgb.r, .g = cell_rgb.g, .b = cell_rgb.b } };
                    is_direct_color = true;
                } else if (cell.content_tag == .bg_color_palette) {
                    vt_style.bg_color = .{ .palette = cell.content.color_palette };
                    is_direct_color = true;
                }

                // Hash the style + selected flag together
                const style_key = StyleKey{ .style = vt_style, .selected = selected };
                const style_hash = std.hash.Wyhash.hash(0, std.mem.asBytes(&style_key));

                // Get or create style ID using style hash as key
                const style_id = if (styles_map.get(style_hash)) |id|
                    id
                else id: {
                    const id = next_style_id;
                    next_style_id += 1;
                    const attrs = getStyleAttributes(vt_style, selected);
                    try styles_map.put(style_hash, id);
                    try styles_list.append(allocator, .{ .id = id, .attrs = attrs });
                    break :id id;
                };

                const ts1 = std.time.nanoTimestamp();
                time_style_ops += ts1 - ts0;

                const tt0 = std.time.nanoTimestamp();

                if (is_direct_color) {
                    text = try arena_allocator.dupe(u8, " ");
                } else {
                    var cluster: []const u21 = &[_]u21{};

                    switch (cell.content_tag) {
                        .codepoint => {
                            if (cell.content.codepoint != 0) {
                                cluster = grapheme_buf[0..1];
                                grapheme_buf[0] = cell.content.codepoint;
                            }
                        },
                        .codepoint_grapheme => {
                            grapheme_buf[0] = cell.content.codepoint;
                            var len: usize = 1;
                            if (row.node.data.lookupGrapheme(cell)) |extra| {
                                for (extra) |cp| {
                                    if (len >= grapheme_buf.len) break;
                                    grapheme_buf[len] = cp;
                                    len += 1;
                                }
                            }
                            cluster = grapheme_buf[0..len];
                        },
                        else => {
                            cluster = &[_]u21{' '};
                        },
                    }

                    if (cluster.len > 0) {
                        var utf8_list = std.ArrayList(u8).empty;
                        defer utf8_list.deinit(arena_allocator);
                        for (cluster) |cp| {
                            const len = std.unicode.utf8Encode(cp, &utf8_buf) catch continue;
                            try utf8_list.appendSlice(arena_allocator, utf8_buf[0..len]);
                        }
                        text = try utf8_list.toOwnedSlice(arena_allocator);
                    } else {
                        text = try arena_allocator.dupe(u8, " ");
                    }
                }

                const tt1 = std.time.nanoTimestamp();
                time_text_ops += tt1 - tt0;

                cells[x] = .{
                    .text = text,
                    .style_id = style_id,
                    .wide = cell.wide == .wide,
                };
            }

            try rows_data.append(allocator, .{ .y = y, .cells = cells });
        }

        const t3 = std.time.nanoTimestamp();

        const cursor_shape: redraw.UIEvent.CursorShape.Shape = switch (screen.cursor.cursor_style) {
            .block, .block_hollow => .block,
            .bar => .beam,
            .underline => .underline,
        };

        const clone_us = @divTrunc(t1 - t0, std.time.ns_per_us);
        const clear_us = @divTrunc(t2 - t1, std.time.ns_per_us);
        const iterate_us = @divTrunc(t3 - t2, std.time.ns_per_us);
        const style_us = @divTrunc(time_style_ops, std.time.ns_per_us);
        const text_us = @divTrunc(time_text_ops, std.time.ns_per_us);

        std.log.info("ScreenState.init: mode={s} dirty_rows={}/{} clone={}us clear={}us iterate={}us (style={}us text={}us)", .{ if (effective_mode == .full) "full" else "incremental", dirty_row_count, rows, clone_us, clear_us, iterate_us, style_us, text_us });

        return .{
            .rows = rows,
            .cols = cols,
            .cursor_x = screen.cursor.x,
            .cursor_y = screen.cursor.y,
            .cursor_visible = terminal.modes.get(.cursor_visible),
            .cursor_shape = cursor_shape,
            .rows_data = try rows_data.toOwnedSlice(allocator),
            .styles = try styles_list.toOwnedSlice(allocator),
            .allocator = allocator,
            .viewport = current_viewport,
            .text_arena = text_arena,
        };
    }

    fn deinit(self: *ScreenState) void {
        self.allocator.free(self.styles);
        for (self.rows_data) |row| {
            self.allocator.free(row.cells);
        }
        self.allocator.free(self.rows_data);
        self.text_arena.deinit();
    }
};

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

                        std.log.debug("Received key_input: session={}", .{session_id});

                        if (self.server.ptys.get(session_id)) |pty_instance| {
                            // Parse key map to ghostty key
                            const key = key_parse.parseKeyMap(key_map) catch |err| {
                                std.log.err("Failed to parse key map: {}", .{err});
                                return;
                            };

                            std.log.debug("Parsed key: key={} utf8='{s}' mods=(shift={} ctrl={} alt={})", .{
                                key.key,
                                key.utf8,
                                key.mods.shift,
                                key.mods.ctrl,
                                key.mods.alt,
                            });

                            // Encode key using terminal state
                            var encode_buf: [32]u8 = undefined;
                            var stream = std.io.fixedBufferStream(&encode_buf);
                            const writer = stream.writer();

                            pty_instance.terminal_mutex.lock();
                            key_encode.encode(writer, key, &pty_instance.terminal) catch |err| {
                                std.log.err("Failed to encode key: {}", .{err});
                                pty_instance.terminal_mutex.unlock();
                                return;
                            };
                            pty_instance.terminal_mutex.unlock();

                            const encoded = stream.getWritten();
                            std.log.debug("Encoded key to {} bytes: {any}", .{ encoded.len, encoded });

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

                        if (self.server.ptys.get(session_id)) |pty_instance| {
                            if (pty_instance.terminal.rows == rows and pty_instance.terminal.cols == cols) {
                                std.log.info("Skipping resize for session {}, already at {}x{}", .{ session_id, rows, cols });
                                return;
                            }

                            const size: pty.winsize = .{
                                .ws_row = rows,
                                .ws_col = cols,
                                .ws_xpixel = 0,
                                .ws_ypixel = 0,
                            };
                            var pty_mut = pty_instance.process;
                            pty_mut.setSize(size) catch |err| {
                                std.log.err("Resize PTY failed: {}", .{err});
                            };

                            // Also resize the terminal state
                            pty_instance.terminal_mutex.lock();
                            pty_instance.terminal.resize(
                                pty_instance.allocator,
                                cols,
                                rows,
                            ) catch |err| {
                                std.log.err("Resize terminal failed: {}", .{err});
                            };
                            pty_instance.terminal_mutex.unlock();

                            std.log.info("Resized session {} to {}x{}", .{ session_id, rows, cols });
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

    fn parseResizePtyParams(params: msgpack.Value) !struct { id: usize, rows: u16, cols: u16 } {
        if (params != .array or params.array.len < 3 or params.array[0] != .unsigned or params.array[1] != .unsigned or params.array[2] != .unsigned) {
            return error.InvalidParams;
        }
        return .{
            .id = @intCast(params.array[0].unsigned),
            .rows = @intCast(params.array[1].unsigned),
            .cols = @intCast(params.array[2].unsigned),
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
                var state = try ScreenState.init(self.allocator, &pty_instance.terminal, &pty_instance.terminal_mutex, .full, pty_instance.last_viewport);
                defer state.deinit();
                std.log.info("ScreenState: rows={} cols={}", .{ state.rows, state.cols });
                try self.sendRedraw(self.loop, pty_instance, &state, client, .full);
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
            var state = try ScreenState.init(
                self.allocator,
                &pty_instance.terminal,
                &pty_instance.terminal_mutex,
                .full,
                null,
            );
            defer state.deinit();

            try self.sendRedraw(self.loop, pty_instance, &state, client, .full);

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

            const pty_instance = self.ptys.get(session_id) orelse {
                return msgpack.Value{ .string = try self.allocator.dupe(u8, "session not found") };
            };

            if (pty_instance.terminal.rows == rows and pty_instance.terminal.cols == cols) {
                std.log.info("Skipping resize for session {}, already at {}x{}", .{ session_id, rows, cols });
                return msgpack.Value.nil;
            }

            const size: pty.winsize = .{
                .ws_row = rows,
                .ws_col = cols,
                .ws_xpixel = 0,
                .ws_ypixel = 0,
            };

            var pty_mut = pty_instance.process;
            pty_mut.setSize(size) catch |err| {
                std.log.err("Resize PTY failed: {}", .{err});
                return msgpack.Value{ .string = try self.allocator.dupe(u8, "resize failed") };
            };

            // Also resize the terminal state
            pty_instance.terminal_mutex.lock();
            pty_instance.terminal.resize(
                pty_instance.allocator,
                cols,
                rows,
            ) catch |err| {
                std.log.err("Resize terminal failed: {}", .{err});
            };
            pty_instance.terminal_mutex.unlock();

            std.log.info("Resized session {} to {}x{}", .{ session_id, rows, cols });
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
            if (self.ptys.fetchRemove(session_id)) |kv| {
                std.log.info("Killing session {} (no clients, not keep_alive)", .{session_id});
                kv.value.deinit(self.allocator, self.loop);
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

    /// Build and send redraw notification for a session to attached clients
    fn buildRedrawMessage(allocator: std.mem.Allocator, pty_id: usize, state: *ScreenState, mode: ScreenState.RenderMode) ![]u8 {
        var builder = redraw.RedrawBuilder.init(allocator);
        defer builder.deinit();

        if (mode == .full) {
            try builder.resize(@intCast(pty_id), @intCast(state.rows), @intCast(state.cols));
        }

        // Define all styles used in this frame
        for (state.styles) |style| {
            try builder.style(style.id, style.attrs);
        }

        // Build write events for each dirty row
        for (state.rows_data) |row| {
            var cells_buf = std.ArrayList(redraw.UIEvent.Write.Cell).empty;
            defer cells_buf.deinit(allocator);

            // Track the last style ID sent to optimize output
            var last_hl_id: u32 = 0;

            var x: usize = 0;
            while (x < state.cols) {
                if (x >= row.cells.len) break;
                const cell = &row.cells[x];

                // Count consecutive cells with same style
                var repeat: usize = 1;
                var next_x = x + 1;
                if (cell.wide) next_x += 1; // Skip spacer for wide char

                while (next_x < state.cols and next_x < row.cells.len) {
                    const next_cell = &row.cells[next_x];
                    if (next_cell.style_id != cell.style_id) break;
                    if (!std.mem.eql(u8, next_cell.text, cell.text)) break;

                    repeat += 1;
                    next_x += 1;
                    if (next_cell.wide) next_x += 1;
                }

                // Determine if we need to send the style ID
                const hl_id_to_send: ?u32 = if (cell.style_id != last_hl_id) cell.style_id else null;
                if (hl_id_to_send) |id| {
                    last_hl_id = id;
                }

                try cells_buf.append(allocator, .{
                    .grapheme = cell.text,
                    .style_id = hl_id_to_send,
                    .repeat = if (repeat > 1) @intCast(repeat) else null,
                });

                x = next_x;
            }

            if (cells_buf.items.len > 0) {
                try builder.write(@intCast(pty_id), @intCast(row.y), 0, cells_buf.items);
            }
        }

        // Send cursor position
        if (state.cursor_visible) {
            try builder.cursorPos(@intCast(pty_id), @intCast(state.cursor_y), @intCast(state.cursor_x));
        }

        // Send cursor shape
        try builder.cursorShape(@intCast(pty_id), state.cursor_shape);

        try builder.flush();
        return builder.build();
    }

    /// Build and send redraw notification for a session to attached clients
    fn sendRedraw(self: *Server, loop: *io.Loop, pty_instance: *Pty, state: *ScreenState, target_client: ?*Client, mode: ScreenState.RenderMode) !void {
        std.log.debug("sendRedraw: session={} rows={} cols={} mode={} target_client={} total_clients={}", .{ pty_instance.id, state.rows, state.cols, mode, target_client != null, self.clients.items.len });

        const msg = try buildRedrawMessage(self.allocator, pty_instance.id, state, mode);
        defer self.allocator.free(msg);

        // Send to each client attached to this session
        for (self.clients.items) |client| {
            std.log.debug("sendRedraw: checking client fd={}", .{client.fd});
            // If we have a target client, skip others
            if (target_client) |target| {
                if (client != target) {
                    std.log.debug("sendRedraw: skipping client fd={} (not target)", .{client.fd});
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
            std.log.debug("sendRedraw: client fd={} attached={} attached_sessions={}", .{ client.fd, attached, client.attached_sessions.items.len });
            if (!attached) {
                continue;
            }

            std.log.debug("sendRedraw: sending {} bytes to client fd={}", .{ msg.len, client.fd });
            try client.sendData(loop, msg);
        }
    }

    fn renderFrame(self: *Server, pty_instance: *Pty) void {
        const start_time = std.time.nanoTimestamp();

        // Copy screen state under mutex
        var state = ScreenState.init(
            self.allocator,
            &pty_instance.terminal,
            &pty_instance.terminal_mutex,
            .incremental,
            pty_instance.last_viewport,
        ) catch |err| {
            std.log.err("Failed to copy screen state for session {}: {}", .{ pty_instance.id, err });
            return;
        };
        defer state.deinit();

        const capture_time = std.time.nanoTimestamp();

        // Determine mode from state (ScreenState.init can change mode from incremental to full)
        const mode_str = if (state.rows_data.len == state.rows) "full" else "incremental";

        // Update total rows
        pty_instance.last_viewport = state.viewport;

        // Build and send redraw notifications
        self.sendRedraw(self.loop, pty_instance, &state, null, .incremental) catch |err| {
            std.log.err("Failed to send redraw for session {}: {}", .{ pty_instance.id, err });
        };

        const end_time = std.time.nanoTimestamp();
        const capture_us = @divTrunc(capture_time - start_time, std.time.ns_per_us);
        const serialize_us = @divTrunc(end_time - capture_time, std.time.ns_per_us);
        const total_us = @divTrunc(end_time - start_time, std.time.ns_per_us);

        std.log.info("renderFrame: mode={s} capture={}us serialize={}us total={}us", .{ mode_str, capture_us, serialize_us, total_us });

        // Update timestamp
        pty_instance.last_render_time = std.time.milliTimestamp();
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

                const now = std.time.milliTimestamp();
                const FRAME_TIME = 16;

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

    var server: Server = .{
        .allocator = allocator,
        .loop = &loop,
        .listen_fd = listen_fd,
        .socket_path = socket_path,
        .clients = std.ArrayList(*Client).empty,
        .ptys = std.AutoHashMap(usize, *Pty).init(allocator),
    };
    defer {
        for (server.clients.items) |client| {
            posix.close(client.fd);
            client.attached_sessions.deinit(allocator);
            // client.style_cache.deinit();
            allocator.destroy(client);
        }
        server.clients.deinit(allocator);
        var it = server.ptys.valueIterator();
        while (it.next()) |pty_instance| {
            pty_instance.*.deinit(allocator, &loop);
        }
        server.ptys.deinit();
    }

    // Start accepting connections
    server.accept_task = try loop.accept(listen_fd, .{
        .ptr = &server,
        .cb = Server.onAccept,
    });

    // Run until server decides to exit
    try loop.run(.until_done);

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

test "buildRedrawMessage" {
    const testing = std.testing;
    var rows_data = std.ArrayList(ScreenState.DirtyRow).empty;
    defer {
        for (rows_data.items) |row| {
            for (row.cells) |cell| testing.allocator.free(cell.text);
            testing.allocator.free(row.cells);
        }
        rows_data.deinit(testing.allocator);
    }

    // Create a row with one cell
    var cells = try testing.allocator.alloc(ScreenState.CellData, 1);
    cells[0] = .{
        .text = try testing.allocator.dupe(u8, "A"),
        .style_id = 1,
        .wide = false,
    };
    try rows_data.append(testing.allocator, .{ .y = 0, .cells = cells });

    var styles_list = std.ArrayList(redraw.UIEvent.Style).empty;
    defer styles_list.deinit(testing.allocator);
    try styles_list.append(testing.allocator, .{ .id = 1, .attrs = .{ .fg = 0xFF0000 } });

    var state = ScreenState{
        .rows = 24,
        .cols = 80,
        .cursor_x = 5,
        .cursor_y = 10,
        .cursor_visible = true,
        .cursor_shape = .block,
        .rows_data = rows_data.items,
        .styles = styles_list.items,
        .allocator = testing.allocator,
        .viewport = undefined,
    };

    const msg = try Server.buildRedrawMessage(testing.allocator, 1, &state, .full);
    defer testing.allocator.free(msg);

    try testing.expect(msg.len > 0);
}
