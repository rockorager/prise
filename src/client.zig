//! Client-side networking and application state management.

const std = @import("std");
const vaxis = @import("vaxis");
const io = @import("io.zig");
const lua_event = @import("lua_event.zig");
const msgpack = @import("msgpack.zig");
const redraw = @import("redraw.zig");
const rpc = @import("rpc.zig");
const Surface = @import("Surface.zig");
const UI = @import("ui.zig").UI;
const vaxis_helper = @import("vaxis_helper.zig");
const widget = @import("widget.zig");
const posix = std.posix;

const log = std.log.scoped(.client);

pub const MsgId = enum(u16) {
    spawn_pty = 1,
    attach_pty = 2,
};

/// Map redraw MouseShape to vaxis Mouse.Shape
fn mapMouseShapeToVaxis(shape: redraw.UIEvent.MouseShape.Shape) vaxis.Mouse.Shape {
    return switch (shape) {
        .default => .default,
        .text => .text,
        .pointer => .pointer,
        .help => .help,
        .progress => .progress,
        .wait => .wait,
        .cell => .cell,
        .ew_resize, .col_resize => .@"ew-resize",
        .ns_resize, .row_resize => .@"ns-resize",
        // vaxis has limited shapes, map others to closest match
        .crosshair,
        .move,
        .not_allowed,
        .grab,
        .grabbing,
        .nesw_resize,
        .nwse_resize,
        .all_scroll,
        .zoom_in,
        .zoom_out,
        => .default,
    };
}

pub const UnixSocketClient = struct {
    allocator: std.mem.Allocator,
    fd: ?posix.fd_t = null,
    ctx: io.Context,
    addr: posix.sockaddr.un,

    const Msg = enum {
        socket,
        connect,
    };

    fn handleMsg(loop: *io.Loop, completion: io.Completion) anyerror!void {
        const self = completion.userdataCast(UnixSocketClient);

        switch (completion.msgToEnum(Msg)) {
            .socket => {
                switch (completion.result) {
                    .socket => |fd| {
                        self.fd = fd;
                        _ = try loop.connect(
                            fd,
                            @ptrCast(&self.addr),
                            @sizeOf(posix.sockaddr.un),
                            .{
                                .ptr = self,
                                .msg = @intFromEnum(Msg.connect),
                                .cb = UnixSocketClient.handleMsg,
                            },
                        );
                    },
                    .err => |err| {
                        defer self.allocator.destroy(self);
                        try self.ctx.cb(loop, .{
                            .userdata = self.ctx.ptr,
                            .msg = self.ctx.msg,
                            .callback = self.ctx.cb,
                            .result = .{ .err = err },
                        });
                    },
                    else => unreachable,
                }
            },

            .connect => {
                defer self.allocator.destroy(self);

                switch (completion.result) {
                    .connect => {
                        try self.ctx.cb(loop, .{
                            .userdata = self.ctx.ptr,
                            .msg = self.ctx.msg,
                            .callback = self.ctx.cb,
                            .result = .{ .socket = self.fd.? },
                        });
                    },
                    .err => |err| {
                        try self.ctx.cb(loop, .{
                            .userdata = self.ctx.ptr,
                            .msg = self.ctx.msg,
                            .callback = self.ctx.cb,
                            .result = .{ .err = err },
                        });
                        if (self.fd) |fd| {
                            _ = try loop.close(fd, .{
                                .ptr = null,
                                .cb = struct {
                                    fn noop(_: *io.Loop, _: io.Completion) anyerror!void {}
                                }.noop,
                            });
                        }
                    },
                    else => unreachable,
                }
            },
        }
    }
};

pub fn connectUnixSocket(
    loop: *io.Loop,
    socket_path: []const u8,
    ctx: io.Context,
) !*UnixSocketClient {
    const client = try loop.allocator.create(UnixSocketClient);
    errdefer loop.allocator.destroy(client);

    var addr: posix.sockaddr.un = undefined;
    addr.family = posix.AF.UNIX;
    @memcpy(addr.path[0..socket_path.len], socket_path);
    addr.path[socket_path.len] = 0;

    client.* = .{
        .allocator = loop.allocator,
        .ctx = ctx,
        .addr = addr,
        .fd = null,
    };

    _ = try loop.socket(
        posix.AF.UNIX,
        posix.SOCK.STREAM | posix.SOCK.CLOEXEC | posix.SOCK.NONBLOCK,
        0,
        .{
            .ptr = client,
            .msg = @intFromEnum(UnixSocketClient.Msg.socket),
            .cb = UnixSocketClient.handleMsg,
        },
    );

    return client;
}

pub const ClientState = struct {
    pty_id: ?i64 = null,
    response_received: bool = false,
    attached: bool = false,
    should_quit: bool = false,
    connection_refused: bool = false,
    next_msgid: u32 = 1,
    pending_requests: std.AutoHashMap(u32, RequestInfo),
    allocator: std.mem.Allocator,
    prefix_mode: bool = false,

    pub const RequestInfo = union(enum) {
        spawn,
        attach: i64,
        detach,
    };

    pub fn init(allocator: std.mem.Allocator) ClientState {
        return .{
            .allocator = allocator,
            .pending_requests = std.AutoHashMap(u32, RequestInfo).init(allocator),
        };
    }

    pub fn deinit(self: *ClientState) void {
        self.pending_requests.deinit();
    }
};

pub const ServerAction = union(enum) {
    none,
    send_attach: i64,
    redraw: msgpack.Value,
    attached: i64,
    pty_exited: struct { pty_id: u32, status: u32 },
    detached,
};

pub const PipeAction = union(enum) {
    none,
    send_key: msgpack.Value, // key map
    send_resize: struct { rows: u16, cols: u16 },
    quit,
};

pub const ClientLogic = struct {
    pub fn processServerMessage(state: *ClientState, msg: rpc.Message) !ServerAction {
        switch (msg) {
            .response => |resp| {
                state.response_received = true;

                log.info("processServerMessage: response msgid={}", .{resp.msgid});
                const request_info = state.pending_requests.fetchRemove(resp.msgid);

                if (resp.err) |err_val| {
                    _ = err_val;
                    log.err("Error in response", .{});
                    return .none;
                } else {
                    if (request_info) |entry| {
                        log.info("processServerMessage: found pending request: {s}", .{@tagName(entry.value)});
                        switch (entry.value) {
                            .spawn => {
                                const id: i64 = switch (resp.result) {
                                    .integer => |i| i,
                                    .unsigned => |u| @intCast(u),
                                    else => -1,
                                };
                                log.info("processServerMessage: spawn result id={}", .{id});
                                if (id >= 0) {
                                    state.pty_id = id; // Last attached
                                    state.attached = true;
                                    return .{ .attached = id };
                                }
                            },
                            .attach => |id| {
                                state.pty_id = id;
                                state.attached = true;
                                return .{ .attached = id };
                            },
                            .detach => {
                                return ServerAction.detached;
                            },
                        }
                    } else {
                        switch (resp.result) {
                            .integer => |i| {
                                // Legacy fallback or unsolicited?
                                if (state.pty_id == null) {
                                    state.pty_id = i;
                                    return .{ .send_attach = i };
                                } else if (!state.attached) {
                                    state.attached = true;
                                    return .{ .attached = i };
                                }
                            },
                            .unsigned => |u| {
                                if (state.pty_id == null) {
                                    state.pty_id = @intCast(u);
                                    state.attached = true;
                                    return .{ .attached = @intCast(u) };
                                } else if (!state.attached) {
                                    state.attached = true;
                                    return .{ .attached = @intCast(u) };
                                }
                            },
                            .string => |s| {
                                log.info("{s}", .{s});
                                return .none;
                            },
                            else => {
                                log.info("Unknown result type", .{});
                                return .none;
                            },
                        }
                    }
                }
            },
            .request => {
                log.warn("Got unexpected request from server", .{});
                return .none;
            },
            .notification => |notif| {
                if (std.mem.eql(u8, notif.method, "redraw")) {
                    return .{ .redraw = notif.params };
                } else if (std.mem.eql(u8, notif.method, "pty_exited")) {
                    if (notif.params == .array and notif.params.array.len >= 2) {
                        const pty_id = switch (notif.params.array[0]) {
                            .integer => |i| @as(u32, @intCast(i)),
                            .unsigned => |u| @as(u32, @intCast(u)),
                            else => 0,
                        };
                        const status = switch (notif.params.array[1]) {
                            .integer => |i| @as(u32, @intCast(i)),
                            .unsigned => |u| @as(u32, @intCast(u)),
                            else => 0,
                        };
                        return .{ .pty_exited = .{ .pty_id = pty_id, .status = status } };
                    }
                }
            },
        }
        return .none;
    }

    pub fn processPipeMessage(state: *ClientState, value: msgpack.Value) !PipeAction {
        if (value != .array or value.array.len < 1) return .none;

        const msg_type = value.array[0];
        if (msg_type != .string) return .none;

        if (std.mem.eql(u8, msg_type.string, "key")) {
            if (value.array.len < 2 or value.array[1] != .map) return .none;
            const key_map = value.array[1];
            if (state.attached and state.pty_id != null) {
                return .{ .send_key = key_map };
            }
        } else if (std.mem.eql(u8, msg_type.string, "resize")) {
            if (value.array.len < 3) return .none;
            const rows = switch (value.array[1]) {
                .unsigned => |u| @as(u16, @intCast(u)),
                .integer => |i| @as(u16, @intCast(i)),
                else => return .none,
            };
            const cols = switch (value.array[2]) {
                .unsigned => |u| @as(u16, @intCast(u)),
                .integer => |i| @as(u16, @intCast(i)),
                else => return .none,
            };
            return .{ .send_resize = .{ .rows = rows, .cols = cols } };
        } else if (std.mem.eql(u8, msg_type.string, "quit")) {
            state.should_quit = true;
            return .quit;
        }
        return .none;
    }

    pub fn shouldFlush(params: msgpack.Value) bool {
        if (params != .array) return false;
        for (params.array) |event_val| {
            if (event_val != .array or event_val.array.len < 1) continue;
            const event_name = event_val.array[0];
            switch (event_name) {
                .string => |s| {
                    if (std.mem.eql(u8, s, "flush")) return true;
                },
                else => {},
            }
        }
        return false;
    }

    pub fn encodeEvent(allocator: std.mem.Allocator, event: vaxis.Event) !?[]u8 {
        switch (event) {
            .key_press, .key_release => |key| {
                const event_name: []const u8 = if (event == .key_press) "key" else "key_release";

                // Build key map in W3C KeyboardEvent format
                const key_strs = try vaxis_helper.vaxisKeyToStrings(allocator, key);
                defer allocator.free(key_strs.key);
                defer allocator.free(key_strs.code);

                var key_map_kv = try allocator.alloc(msgpack.Value.KeyValue, 6);
                key_map_kv[0] = .{ .key = .{ .string = "key" }, .value = .{ .string = key_strs.key } };
                key_map_kv[1] = .{ .key = .{ .string = "code" }, .value = .{ .string = key_strs.code } };
                key_map_kv[2] = .{ .key = .{ .string = "shiftKey" }, .value = .{ .boolean = key.mods.shift } };
                key_map_kv[3] = .{ .key = .{ .string = "ctrlKey" }, .value = .{ .boolean = key.mods.ctrl } };
                key_map_kv[4] = .{ .key = .{ .string = "altKey" }, .value = .{ .boolean = key.mods.alt } };
                key_map_kv[5] = .{ .key = .{ .string = "metaKey" }, .value = .{ .boolean = key.mods.super } };

                const key_map_val: msgpack.Value = .{ .map = key_map_kv };
                var arr = try allocator.alloc(msgpack.Value, 2);
                arr[0] = .{ .string = event_name };
                arr[1] = key_map_val;

                const result = try msgpack.encodeFromValue(allocator, .{ .array = arr });

                // Clean up temporary allocations
                allocator.free(arr);
                allocator.free(key_map_kv);

                return result;
            },
            .winsize => |ws| {
                return try msgpack.encode(allocator, .{ "resize", ws.rows, ws.cols });
            },
            else => return null,
        }
    }

    pub fn vaxisKeyToString(allocator: std.mem.Allocator, key: vaxis.Key) ![]u8 {
        return vaxis_helper.vaxisKeyToString(allocator, key);
    }
};

pub const DragState = struct {
    handle: widget.SplitHandle,
    start_x: f64,
    start_y: f64,
};

pub const App = struct {
    connected: bool = false,
    fd: posix.fd_t = undefined,
    allocator: std.mem.Allocator,
    recv_buffer: [4096]u8 = undefined,
    msg_buffer: std.ArrayList(u8),
    msg_arena: std.heap.ArenaAllocator,
    send_buffer: ?[]u8 = null,
    send_task: ?io.Task = null,
    recv_task: ?io.Task = null,
    pipe_read_task: ?io.Task = null,
    vx: vaxis.Vaxis = undefined,
    tty: vaxis.Tty = undefined,
    tty_thread: ?std.Thread = null,
    io_loop: ?*io.Loop = null,
    tty_buffer: [4096]u8 = undefined,
    surfaces: std.AutoHashMap(u32, *Surface),
    state: ClientState,
    ui: UI = undefined,
    first_resize_done: bool = false,
    socket_path: []const u8 = undefined,
    attach_session: ?[]const u8 = null,
    last_render_time: i64 = 0,
    render_timer: ?io.Task = null,

    // Terminal metrics
    cell_width_px: u16 = 0,
    cell_height_px: u16 = 0,

    // Hit regions for mouse event targeting
    hit_regions: []widget.HitRegion = &.{},
    split_handles: []widget.SplitHandle = &.{},

    // Drag state for split resizing
    drag_state: ?DragState = null,

    pipe_read_fd: posix.fd_t = undefined,
    pipe_write_fd: posix.fd_t = undefined,
    parser: vaxis.Parser = undefined,
    pipe_buf: std.ArrayList(u8),
    pipe_recv_buffer: [4096]u8 = undefined,
    colors: TerminalColors = .{},

    pending_attach_ids: ?[]u32 = null,
    pending_attach_count: usize = 0,
    session_json: ?[]const u8 = null,

    pub const TerminalColors = struct {
        fg: ?vaxis.Cell.Color = null,
        bg: ?vaxis.Cell.Color = null,
        palette: [16]?vaxis.Cell.Color = .{null} ** 16,

        pub fn isDark(rgb: [3]u8) bool {
            const r: u32 = rgb[0];
            const g: u32 = rgb[1];
            const b: u32 = rgb[2];
            // Perceived luminance (Rec. 601)
            // Y = 0.299R + 0.587G + 0.114B
            // Using integer arithmetic with 1000 scale
            const y = 299 * r + 587 * g + 114 * b;
            return y < 128000;
        }

        pub fn reduceContrast(rgb: [3]u8, factor: f32) [3]u8 {
            std.debug.assert(factor >= 0.0 and factor <= 1.0);
            if (isDark(rgb)) {
                // Dark background -> Lighten (mix with white)
                return .{
                    @intFromFloat(@as(f32, @floatFromInt(rgb[0])) * (1.0 - factor) + 255.0 * factor),
                    @intFromFloat(@as(f32, @floatFromInt(rgb[1])) * (1.0 - factor) + 255.0 * factor),
                    @intFromFloat(@as(f32, @floatFromInt(rgb[2])) * (1.0 - factor) + 255.0 * factor),
                };
            } else {
                // Light background -> Darken (mix with black)
                return .{
                    @intFromFloat(@as(f32, @floatFromInt(rgb[0])) * (1.0 - factor)),
                    @intFromFloat(@as(f32, @floatFromInt(rgb[1])) * (1.0 - factor)),
                    @intFromFloat(@as(f32, @floatFromInt(rgb[2])) * (1.0 - factor)),
                };
            }
        }
    };

    pub fn init(allocator: std.mem.Allocator) !App {
        var app: App = .{
            .allocator = allocator,
            .vx = try vaxis.init(allocator, .{
                .kitty_keyboard_flags = .{
                    .report_events = true,
                },
            }),
            .tty = undefined,
            .tty_buffer = undefined,
            .msg_buffer = .empty,
            .msg_arena = std.heap.ArenaAllocator.init(allocator),
            .pipe_buf = .empty,
            .surfaces = std.AutoHashMap(u32, *Surface).init(allocator),
            .state = ClientState.init(allocator),
        };
        app.tty = try vaxis.Tty.init(&app.tty_buffer);
        // parser doesn't need init? assuming default init is fine or init(&allocator)
        app.parser = .{};

        log.info("Vaxis initialized", .{});

        // Initialize Lua UI
        app.ui = try UI.init(allocator);
        log.info("Lua UI initialized", .{});

        // Create pipe for TTY thread -> Main thread communication
        const fds = try posix.pipe2(.{ .CLOEXEC = true, .NONBLOCK = true });
        app.pipe_read_fd = fds[0];
        app.pipe_write_fd = fds[1];
        log.info("Pipe created: read_fd={} write_fd={}", .{ app.pipe_read_fd, app.pipe_write_fd });

        return app;
    }

    pub fn deinit(self: *App) void {
        self.ui.deinit();
        self.state.should_quit = true;

        // Wake up TTY thread by sending a Device Status Report request.
        // This causes the terminal to send a response, unblocking the read.
        self.vx.deviceStatusReport(self.tty.writer()) catch {};

        // Cancel pending recv task
        if (self.recv_task) |*task| {
            if (self.io_loop) |loop| {
                task.cancel(loop) catch |err| {
                    log.warn("Failed to cancel recv task: {}", .{err});
                };
            } else {
                log.warn("deinit: io_loop is null, cannot cancel recv task", .{});
            }
            self.recv_task = null;
        }

        if (self.render_timer) |*task| {
            if (self.io_loop) |loop| {
                task.cancel(loop) catch |err| {
                    log.warn("Failed to cancel render timer: {}", .{err});
                };
            }
            self.render_timer = null;
        }

        // Close the socket
        if (self.connected) {
            posix.close(self.fd);
        }

        // Wait for TTY thread to exit naturally (it checks should_quit)
        if (self.tty_thread) |thread| {
            thread.join();
        }
        var surface_it = self.surfaces.valueIterator();
        while (surface_it.next()) |surface| {
            surface.*.deinit();
            self.allocator.destroy(surface.*);
        }
        self.surfaces.deinit();

        self.pipe_buf.deinit(self.allocator);
        self.msg_buffer.deinit(self.allocator);
        self.msg_arena.deinit();
        self.state.deinit();
        if (self.hit_regions.len > 0) self.allocator.free(self.hit_regions);
        if (self.split_handles.len > 0) self.allocator.free(self.split_handles);
        self.vx.deinit(self.allocator, self.tty.writer());
        self.tty.deinit();

        posix.close(self.pipe_read_fd);
        posix.close(self.pipe_write_fd);
    }

    pub fn setup(self: *App, loop: *io.Loop) !void {
        self.io_loop = loop;
        self.ui.setLoop(loop);
        self.ui.setQuitCallback(self, struct {
            fn quit(ctx: *anyopaque) void {
                const app: *App = @ptrCast(@alignCast(ctx));
                app.state.should_quit = true;
                if (app.connected) {
                    posix.close(app.fd);
                    app.connected = false;
                }
                if (app.recv_task) |*task| {
                    if (app.io_loop) |l| task.cancel(l) catch {};
                    app.recv_task = null;
                }
                if (app.render_timer) |*task| {
                    if (app.io_loop) |l| task.cancel(l) catch {};
                    app.render_timer = null;
                }
            }
        }.quit);

        try self.vx.enterAltScreen(self.tty.writer());

        // Don't initialize surface yet - wait for first winsize event from TTY thread
        // The surface will be created when we get the window size

        // Register pipe read end with io.Loop
        self.pipe_read_task = try loop.read(self.pipe_read_fd, &self.pipe_recv_buffer, .{
            .ptr = self,
            .cb = onPipeRead,
        });

        // Spawn TTY thread to handle vaxis events and forward via pipe
        log.info("Spawning TTY thread...", .{});
        self.tty_thread = try std.Thread.spawn(.{}, ttyThreadFn, .{self});
        log.info("TTY thread spawned", .{});

        // Send terminal queries to detect capabilities
        try self.vx.queryTerminalSend(self.tty.writer());

        // Query colors
        try self.vx.queryColor(self.tty.writer(), .fg);
        try self.vx.queryColor(self.tty.writer(), .bg);
        for (0..16) |i| {
            try self.vx.queryColor(self.tty.writer(), .{ .index = @intCast(i) });
        }

        // Register spawn callback
        self.ui.setSpawnCallback(self, struct {
            fn spawnCb(ctx: *anyopaque, opts: UI.SpawnOptions) !void {
                const app_ptr: *App = @ptrCast(@alignCast(ctx));
                try app_ptr.spawnPty(opts);
            }
        }.spawnCb);

        // Register redraw callback
        self.ui.setRedrawCallback(self, struct {
            fn redrawCb(ctx: *anyopaque) void {
                const app_ptr: *App = @ptrCast(@alignCast(ctx));
                app_ptr.scheduleRender() catch |err| {
                    log.err("Failed to schedule render: {}", .{err});
                };
            }
        }.redrawCb);

        // Register detach callback
        self.ui.setDetachCallback(self, struct {
            fn detachCb(ctx: *anyopaque, session_name: []const u8) anyerror!void {
                const app_ptr: *App = @ptrCast(@alignCast(ctx));
                try app_ptr.saveSession(session_name);

                // Build array of PTY IDs to detach
                var pty_ids = try app_ptr.allocator.alloc(msgpack.Value, app_ptr.surfaces.count());
                defer app_ptr.allocator.free(pty_ids);
                var i: usize = 0;
                var key_iter = app_ptr.surfaces.keyIterator();
                while (key_iter.next()) |pty_id| {
                    pty_ids[i] = .{ .unsigned = pty_id.* };
                    i += 1;
                }

                // Send single detach_session request with all PTY IDs
                const msgid = app_ptr.state.next_msgid;
                app_ptr.state.next_msgid +%= 1;

                var params = try app_ptr.allocator.alloc(msgpack.Value, 2);
                params[0] = .{ .array = pty_ids };
                params[1] = .{ .unsigned = @intCast(app_ptr.fd) };

                var arr = try app_ptr.allocator.alloc(msgpack.Value, 4);
                arr[0] = .{ .unsigned = 0 }; // request
                arr[1] = .{ .unsigned = msgid };
                arr[2] = .{ .string = "detach_ptys" };
                arr[3] = .{ .array = params };

                const encoded = msgpack.encodeFromValue(app_ptr.allocator, msgpack.Value{ .array = arr }) catch {
                    app_ptr.allocator.free(arr);
                    app_ptr.allocator.free(params);
                    return;
                };
                defer app_ptr.allocator.free(encoded);
                app_ptr.allocator.free(arr);
                app_ptr.allocator.free(params);

                // Track that we're waiting for detach response
                try app_ptr.state.pending_requests.put(msgid, .detach);

                app_ptr.sendDirect(encoded) catch {};
            }
        }.detachCb);

        // Manually trigger initial resize to connect
        const ws = try vaxis.Tty.getWinsize(self.tty.fd);
        try self.handleVaxisEvent(.{ .winsize = ws });
    }

    fn ttyThreadFn(self: *App) void {
        log.info("TTY thread started", .{});

        var buf: [1024]u8 = undefined;
        while (!self.state.should_quit) {
            const n = posix.read(self.tty.fd, &buf) catch |err| {
                log.err("TTY read failed: {}", .{err});
                break;
            };
            if (n == 0) break; // EOF

            // Forward to pipe
            self.writePipeBytes(buf[0..n]) catch |err| {
                log.err("Failed to write to pipe: {}", .{err});
                break;
            };
        }
        log.info("TTY thread exiting", .{});
    }

    fn writePipeBytes(self: *App, data: []const u8) !void {
        var index: usize = 0;
        while (index < data.len) {
            const n = posix.write(self.pipe_write_fd, data[index..]) catch |err| {
                if (err == error.WouldBlock) {
                    std.Thread.sleep(1 * std.time.ns_per_ms);
                    continue;
                }
                return err;
            };
            index += n;
        }
    }

    fn onPipeRead(l: *io.Loop, completion: io.Completion) anyerror!void {
        const app = completion.userdataCast(@This());

        switch (completion.result) {
            .read => |bytes_read| {
                if (bytes_read == 0) {
                    log.warn("Pipe closed", .{});
                    return;
                }

                // Append to pipe buffer
                try app.pipe_buf.appendSlice(app.allocator, app.pipe_recv_buffer[0..bytes_read]);

                // Parse events using vaxis parser
                var i: usize = 0;
                while (i < app.pipe_buf.items.len) {
                    // Guessing parser API: parse(bytes, allocator) -> Result { n, event }
                    const result = try app.parser.parse(app.pipe_buf.items[i..], app.allocator);
                    if (result.n == 0) {
                        // Incomplete sequence, wait for more data
                        break;
                    }
                    i += result.n;

                    if (result.event) |event| {
                        try app.handleVaxisEvent(event);
                    }
                }

                // Remove processed bytes
                if (i > 0) {
                    try app.pipe_buf.replaceRange(app.allocator, 0, i, &.{});
                }

                // Keep reading unless we're quitting
                if (!app.state.should_quit) {
                    app.pipe_read_task = try l.read(app.pipe_read_fd, &app.pipe_recv_buffer, .{
                        .ptr = app,
                        .cb = onPipeRead,
                    });
                }
            },
            .err => |err| {
                log.err("Pipe recv failed: {}", .{err});
            },
            else => unreachable,
        }
    }

    fn handleVaxisEvent(self: *App, event: vaxis.Event) !void {
        log.debug("handleVaxisEvent: {s}", .{@tagName(event)});

        // Handle mouse events specially - do hit testing and convert to MouseEvent
        if (event == .mouse) {
            const mouse = event.mouse;

            // Convert pixel coordinates to cell coordinates as floats
            const cell_w: f64 = if (self.cell_width_px > 0) @floatFromInt(self.cell_width_px) else 1.0;
            const cell_h: f64 = if (self.cell_height_px > 0) @floatFromInt(self.cell_height_px) else 1.0;
            const x: f64 = @as(f64, @floatFromInt(mouse.col)) / cell_w;
            const y: f64 = @as(f64, @floatFromInt(mouse.row)) / cell_h;

            // Handle ongoing drag
            if (self.drag_state) |*drag| {
                if (mouse.type == .release) {
                    // End drag - calculate final ratio and send to Lua
                    const mouse_pos = switch (drag.handle.axis) {
                        .horizontal => x,
                        .vertical => y,
                    };
                    const new_ratio = drag.handle.calculateNewRatio(mouse_pos);

                    self.ui.update(.{ .split_resize = .{
                        .parent_id = drag.handle.parent_id,
                        .child_index = drag.handle.child_index,
                        .ratio = new_ratio,
                    } }) catch |err| {
                        if (err != error.NoUpdateFunction) {
                            log.err("Lua UI update failed: {}", .{err});
                        }
                    };

                    self.drag_state = null;
                    self.vx.setMouseShape(.default);
                } else if (mouse.type == .drag) {
                    // Continue drag - update ratio
                    const mouse_pos = switch (drag.handle.axis) {
                        .horizontal => x,
                        .vertical => y,
                    };
                    const new_ratio = drag.handle.calculateNewRatio(mouse_pos);

                    self.ui.update(.{ .split_resize = .{
                        .parent_id = drag.handle.parent_id,
                        .child_index = drag.handle.child_index,
                        .ratio = new_ratio,
                    } }) catch |err| {
                        if (err != error.NoUpdateFunction) {
                            log.err("Lua UI update failed: {}", .{err});
                        }
                    };
                }
                return;
            }

            // Check if hovering over a split handle
            if (widget.hitTestSplitHandle(self.split_handles, x, y)) |handle| {
                // Start drag on press
                if (mouse.type == .press and mouse.button == .left) {
                    self.drag_state = .{
                        .handle = handle.*,
                        .start_x = x,
                        .start_y = y,
                    };
                }

                // Set cursor shape based on axis
                switch (handle.axis) {
                    .horizontal => self.vx.setMouseShape(.@"ew-resize"),
                    .vertical => self.vx.setMouseShape(.@"ns-resize"),
                }
                try self.scheduleRender();
                return;
            } else {
                // Not on a split handle
                const target = widget.hitTest(self.hit_regions, x, y);
                var target_x: ?f64 = null;
                var target_y: ?f64 = null;

                if (target) |pty_id| {
                    if (widget.findRegion(self.hit_regions, pty_id)) |region| {
                        target_x = x - @as(f64, @floatFromInt(region.x));
                        target_y = y - @as(f64, @floatFromInt(region.y));
                    }
                    // Update mouse cursor shape based on target PTY's mouse_shape
                    if (self.surfaces.get(pty_id)) |surface| {
                        const vaxis_shape = mapMouseShapeToVaxis(surface.mouse_shape);
                        self.vx.setMouseShape(vaxis_shape);
                        try self.scheduleRender();
                    }
                } else {
                    // No target - reset to default
                    self.vx.setMouseShape(.default);
                    try self.scheduleRender();
                }

                const mouse_event = lua_event.MouseEvent{
                    .x = x,
                    .y = y,
                    .button = mouse.button,
                    .action = mouse.type,
                    .mods = mouse.mods,
                    .target = target,
                    .target_x = target_x,
                    .target_y = target_y,
                };

                self.ui.update(.{ .mouse = mouse_event }) catch |err| {
                    if (err != error.NoUpdateFunction) {
                        log.err("Lua UI update failed: {}", .{err});
                    }
                };
            }
            return;
        }

        // Forward other events to Lua UI
        self.ui.update(.{ .vaxis = event }) catch |err| {
            // Ignore NoUpdateFunction, log others
            if (err != error.NoUpdateFunction) {
                log.err("Lua UI update failed: {}", .{err});
            }
        };

        switch (event) {
            .key_press => |key| {
                // Check for a cursor position response for our explicit width query. This will
                // always be an F3 key with shift = true, and we must be looking for queries
                if (key.codepoint == vaxis.Key.f3 and
                    key.mods.shift and
                    !self.vx.queries_done.load(.unordered))
                {
                    log.info("explicit width capability detected", .{});
                    self.vx.caps.explicit_width = true;
                    self.vx.caps.unicode = .unicode;
                    self.vx.screen.width_method = .unicode;
                    return;
                }
                // Check for a cursor position response for our scaled text query. This will
                // always be an F3 key with alt = true, and we must be looking for queries
                if (key.codepoint == vaxis.Key.f3 and
                    key.mods.alt and
                    !self.vx.queries_done.load(.unordered))
                {
                    log.info("scaled text capability detected", .{});
                    self.vx.caps.scaled_text = true;
                    return;
                }
            },
            .winsize => |ws| {
                // Calculate and store cell metrics
                if (ws.cols > 0 and ws.rows > 0) {
                    self.cell_width_px = if (ws.x_pixel > 0) ws.x_pixel / ws.cols else 0;
                    self.cell_height_px = if (ws.y_pixel > 0) ws.y_pixel / ws.rows else 0;
                }

                if (ws.cols != self.vx.screen.width or ws.rows != self.vx.screen.height) {
                    self.vx.state.in_band_resize = true;
                    try self.vx.resize(self.allocator, self.tty.writer(), ws);

                    // Schedule a render after resize to ensure UI matches new size
                    try self.scheduleRender();
                }
            },
            .cap_kitty_keyboard => {
                log.info("kitty keyboard capability detected", .{});
                self.vx.caps.kitty_keyboard = true;
            },
            .cap_kitty_graphics => {
                if (!self.vx.caps.kitty_graphics) {
                    log.info("kitty graphics capability detected", .{});
                    self.vx.caps.kitty_graphics = true;
                }
            },
            .cap_rgb => {
                log.info("rgb capability detected", .{});
                self.vx.caps.rgb = true;
            },
            .cap_unicode => {
                log.info("unicode capability detected", .{});
                self.vx.caps.unicode = .unicode;
                self.vx.screen.width_method = .unicode;
            },
            .cap_sgr_pixels => {
                log.info("pixel mouse capability detected", .{});
                self.vx.caps.sgr_pixels = true;
            },
            .cap_color_scheme_updates => {
                log.info("color_scheme_updates capability detected", .{});
                self.vx.caps.color_scheme_updates = true;
            },
            .cap_multi_cursor => {
                log.info("multi cursor capability detected", .{});
                self.vx.caps.multi_cursor = true;
            },
            .cap_da1 => {
                self.vx.queries_done.store(true, .unordered);
                try self.vx.enableDetectedFeatures(self.tty.writer());
                // Enable mouse mode (uses pixel coordinates if supported)
                try self.vx.setMouseMode(self.tty.writer(), true);
                // Send init event
                self.ui.update(.init) catch |err| {
                    log.err("Failed to update UI with init: {}", .{err});
                };

                if (!self.connected) {
                    if (self.io_loop) |loop| {
                        log.info("Initiating connection to {s} (da1 received)", .{self.socket_path});
                        _ = try connectUnixSocket(loop, self.socket_path, .{
                            .ptr = self,
                            .cb = App.onConnected,
                        });
                    }
                }
            },
            .color_report => |report| {
                const color: vaxis.Cell.Color = .{ .rgb = report.value };
                log.debug("Received color report: kind={any} color={any}", .{ report.kind, color });
                switch (report.kind) {
                    .fg => self.colors.fg = color,
                    .bg => self.colors.bg = color,
                    .index => |idx| if (idx < 16) {
                        self.colors.palette[idx] = color;
                    },
                    else => {},
                }
            },
            else => {},
        }
    }

    fn updateSurfaceSize(self: *App, pty_id: u32, rows: u16, cols: u16) void {
        log.info("Updating surface size to {}x{}", .{ cols, rows });

        // Create or resize surface
        if (self.surfaces.get(pty_id)) |surface| {
            surface.resize(rows, cols) catch |err| {
                log.err("Failed to resize surface: {}", .{err});
            };
        } else {
            const surface = self.allocator.create(Surface) catch |err| {
                log.err("Failed to allocate surface: {}", .{err});
                return;
            };
            surface.* = Surface.init(self.allocator, pty_id, rows, cols) catch |err| {
                log.err("Failed to create surface: {}", .{err});
                self.allocator.destroy(surface);
                return;
            };
            self.surfaces.put(pty_id, surface) catch |err| {
                log.err("Failed to store surface: {}", .{err});
                surface.deinit();
                self.allocator.destroy(surface);
                return;
            };
            log.info("Surface initialized: {}x{}", .{ cols, rows });
        }
    }

    pub fn sendResize(self: *App, pty_id: u32, rows: u16, cols: u16) !void {
        // Check if surface is already at correct size
        if (self.surfaces.get(pty_id)) |surface| {
            // Only check if this is the active surface
            if (surface.rows == rows and surface.cols == cols) return;

            // Update surface immediately
            try surface.resize(rows, cols);
        }

        const msgid = self.state.next_msgid;
        self.state.next_msgid += 1;

        const width_px = @as(u16, cols) * self.cell_width_px;
        const height_px = @as(u16, rows) * self.cell_height_px;

        const msg = try msgpack.encode(self.allocator, .{ 0, msgid, "resize_pty", .{ pty_id, rows, cols, width_px, height_px } });
        defer self.allocator.free(msg);

        try self.sendDirect(msg);
        log.info("Sent resize request id={} for pty={} to {}x{} ({}x{}px)", .{ msgid, pty_id, cols, rows, width_px, height_px });
    }

    pub fn handleRedraw(self: *App, params: msgpack.Value) !void {
        log.debug("handleRedraw: received redraw params", .{});
        if (params != .array) return;

        // Find PTY ID from events
        var pty_id: ?u32 = null;
        for (params.array) |event| {
            if (event != .array or event.array.len < 2) continue;
            const name = event.array[0];
            if (name != .string) continue;
            if (std.mem.eql(u8, name.string, "style")) continue;
            if (std.mem.eql(u8, name.string, "flush")) continue;

            const args = event.array[1];
            if (args != .array or args.array.len < 1) continue;

            switch (args.array[0]) {
                .integer => |i| pty_id = @intCast(i),
                .unsigned => |u| pty_id = @intCast(u),
                else => {},
            }
            if (pty_id) |_| break;
        }

        if (pty_id) |pid| {
            if (self.surfaces.get(pid)) |surface| {
                try surface.applyRedraw(params);

                // Check if we got a flush event - if so, swap and render
                const should_flush = ClientLogic.shouldFlush(params);
                if (should_flush) {
                    log.debug("handleRedraw: flush event received for pty {}, rendering", .{pid});
                    try self.scheduleRender();
                }
            } else {
                log.warn("handleRedraw: no surface for pty {}, ignoring redraw", .{pid});
            }
        } else {
            log.debug("handleRedraw: could not determine pty_id from events", .{});
        }
    }

    fn renderWidget(self: *App, w: widget.Widget, win: vaxis.Window) !void {
        switch (w.kind) {
            .surface => |surf| {
                if (self.surfaces.get(surf.pty_id)) |surface| {
                    // Check if we need to resize the PTY
                    log.debug("renderWidget surface: pty={} widget={}x{} surface={}x{}", .{
                        surf.pty_id,
                        w.width,
                        w.height,
                        surface.cols,
                        surface.rows,
                    });
                    if (w.width != surface.cols or w.height != surface.rows) {
                        log.info("renderWidget: size mismatch for pty={}, sending resize", .{surf.pty_id});
                        self.sendResize(surf.pty_id, w.height, w.width) catch |err| {
                            log.err("Failed to send resize: {}", .{err});
                        };
                    }
                    // Calculate dim factor based on focus
                    const dim_factor: f32 = if (w.focus) 0.0 else 0.05; // Dim inactive windows by 5%
                    surface.render(win, w.focus, &self.colors, dim_factor);
                }
            },
            .text => |text| {
                // Use a temporary arena for rendering this frame
                var arena = std.heap.ArenaAllocator.init(self.allocator);
                defer arena.deinit();
                const alloc = arena.allocator();

                var iter = widget.Text.Iterator{
                    .text = text,
                    .max_width = w.width,
                    .allocator = alloc,
                };

                var row: usize = 0;
                while (iter.next() catch null) |line| {
                    var col: usize = 0;

                    // Handle alignment
                    const free_space = if (w.width > line.width) w.width - line.width else 0;
                    const start_col: u16 = switch (text.@"align") {
                        widget.Text.Align.left => 0,
                        widget.Text.Align.center => free_space / 2,
                        widget.Text.Align.right => free_space,
                    };

                    col = start_col;

                    for (line.segments) |seg| {
                        _ = win.printSegment(seg, .{ .row_offset = @intCast(row), .col_offset = @intCast(col) });
                        col += vaxis.gwidth.gwidth(seg.text, .unicode);
                    }

                    // Fill remaining space with background from last segment
                    if (line.segments.len > 0 and col < w.width) {
                        const last_style = line.segments[line.segments.len - 1].style;
                        const spacer = vaxis.Segment{
                            .text = " ",
                            .style = last_style,
                        };
                        while (col < w.width) {
                            _ = win.printSegment(spacer, .{ .row_offset = @intCast(row), .col_offset = @intCast(col) });
                            col += 1;
                        }
                    }

                    row += 1;
                }
            },
            .text_input => |ti| {
                if (self.ui.text_inputs.get(ti.input_id)) |input| {
                    input.updateScrollOffset(@intCast(win.width));
                    input.render(win, ti.style);
                }
            },
            .list => |list| {
                const visible_rows = w.height;
                const start = list.scroll_offset;
                const end = @min(start + visible_rows, list.items.len);

                log.debug("render list: items={} height={} start={} end={}", .{ list.items.len, w.height, start, end });

                for (start..end) |i| {
                    const row: u16 = @intCast(i - start);
                    const item = list.items[i];
                    const is_selected = list.selected != null and list.selected.? == i;

                    const item_style = if (is_selected)
                        list.selected_style
                    else
                        item.style orelse list.style;

                    for (0..win.width) |col| {
                        var grapheme: []const u8 = " ";
                        if (col < item.text.len) {
                            grapheme = item.text[col .. col + 1];
                        }
                        win.writeCell(@intCast(col), row, .{
                            .char = .{ .grapheme = grapheme, .width = 1 },
                            .style = item_style,
                        });
                    }
                }
            },
            .box => |b| {
                const chars = b.borderChars();
                const style = b.style;

                log.debug("render box: w={} h={}", .{ win.width, win.height });

                // Fill the entire box with background color
                for (0..win.height) |row| {
                    for (0..win.width) |col| {
                        win.writeCell(@intCast(col), @intCast(row), .{
                            .char = .{ .grapheme = " ", .width = 1 },
                            .style = style,
                        });
                    }
                }

                if (b.border != .none and win.width >= 2 and win.height >= 2) {
                    win.writeCell(0, 0, .{ .char = .{ .grapheme = chars.tl, .width = 1 }, .style = style });
                    win.writeCell(win.width - 1, 0, .{ .char = .{ .grapheme = chars.tr, .width = 1 }, .style = style });
                    win.writeCell(0, win.height - 1, .{ .char = .{ .grapheme = chars.bl, .width = 1 }, .style = style });
                    win.writeCell(win.width - 1, win.height - 1, .{ .char = .{ .grapheme = chars.br, .width = 1 }, .style = style });

                    if (win.width > 2) {
                        for (1..win.width - 1) |col| {
                            win.writeCell(@intCast(col), 0, .{ .char = .{ .grapheme = chars.h, .width = 1 }, .style = style });
                            win.writeCell(@intCast(col), win.height - 1, .{ .char = .{ .grapheme = chars.h, .width = 1 }, .style = style });
                        }
                    }

                    if (win.height > 2) {
                        for (1..win.height - 1) |row| {
                            win.writeCell(0, @intCast(row), .{ .char = .{ .grapheme = chars.v, .width = 1 }, .style = style });
                            win.writeCell(win.width - 1, @intCast(row), .{ .char = .{ .grapheme = chars.v, .width = 1 }, .style = style });
                        }
                    }
                }

                const child_win = win.child(.{
                    .x_off = b.child.x,
                    .y_off = b.child.y,
                    .width = b.child.width,
                    .height = b.child.height,
                });
                try self.renderWidget(b.child.*, child_win);
            },
            .padding => |p| {
                const child_win = win.child(.{
                    .x_off = p.child.x,
                    .y_off = p.child.y,
                    .width = p.child.width,
                    .height = p.child.height,
                });
                try self.renderWidget(p.child.*, child_win);
            },
            .column => |col| {
                for (col.children) |child| {
                    const child_win = win.child(.{
                        .x_off = child.x,
                        .y_off = child.y,
                        .width = child.width,
                        .height = child.height,
                    });
                    try self.renderWidget(child, child_win);
                }
            },
            .row => |row| {
                for (row.children) |child| {
                    const child_win = win.child(.{
                        .x_off = child.x,
                        .y_off = child.y,
                        .width = child.width,
                        .height = child.height,
                    });
                    try self.renderWidget(child, child_win);
                }
            },
            .stack => |stack| {
                for (stack.children) |child| {
                    const child_win = win.child(.{
                        .x_off = child.x,
                        .y_off = child.y,
                        .width = child.width,
                        .height = child.height,
                    });
                    try self.renderWidget(child, child_win);
                }
            },
            .positioned => |pos| {
                const child_win = win.child(.{
                    .x_off = pos.child.x,
                    .y_off = pos.child.y,
                    .width = pos.child.width,
                    .height = pos.child.height,
                });
                try self.renderWidget(pos.child.*, child_win);
            },
        }
    }

    pub fn scheduleRender(self: *App) !void {
        if (self.io_loop) |loop| {
            const now = std.time.milliTimestamp();
            const FRAME_TIME = 8;

            if (now - self.last_render_time >= FRAME_TIME) {
                try self.render();
            } else if (self.render_timer == null) {
                const delay = FRAME_TIME - (now - self.last_render_time);
                // Make sure delay is positive
                const safe_delay = if (delay < 0) 0 else delay;
                self.render_timer = try loop.timeout(@as(u64, @intCast(safe_delay)) * std.time.ns_per_ms, .{
                    .ptr = self,
                    .cb = onRenderTimer,
                });
            }
        } else {
            // Fallback if no loop (e.g. during tests or init)
            try self.render();
        }
    }

    fn onRenderTimer(loop: *io.Loop, completion: io.Completion) anyerror!void {
        _ = loop;
        const app = completion.userdataCast(App);
        app.render() catch |err| {
            log.err("Failed to render frame: {}", .{err});
        };
        app.render_timer = null;
    }

    pub fn render(self: *App) !void {
        log.debug("render: starting render", .{});

        const win = self.vx.window();
        win.hideCursor();
        win.clear();

        var root_widget = self.ui.view() catch |err| {
            log.err("Failed to get view from UI: {}", .{err});
            return;
        };
        defer root_widget.deinit(self.allocator);

        const screen = win.screen;

        const constraints = widget.BoxConstraints{
            .min_width = 0,
            .max_width = screen.width,
            .min_height = 0,
            .max_height = screen.height,
        };

        var w = root_widget;
        _ = w.layout(constraints);

        // Collect hit regions for mouse event targeting
        if (self.hit_regions.len > 0) {
            self.allocator.free(self.hit_regions);
        }
        self.hit_regions = w.collectHitRegions(self.allocator, 0, 0) catch &.{};

        // Collect split handles for resize drag detection
        if (self.split_handles.len > 0) {
            self.allocator.free(self.split_handles);
        }
        self.split_handles = w.collectSplitHandles(self.allocator, 0, 0) catch &.{};

        try self.renderWidget(w, win);

        // Log cursor state after render
        log.info("App.render: cursor_vis={}", .{screen.cursor_vis});

        log.debug("render: calling vx.render()", .{});
        if (self.state.pty_id) |pid_i64| {
            const pid = @as(u32, @intCast(pid_i64));
            if (self.surfaces.get(pid)) |surface| {
                self.vx.setTitle(self.tty.writer(), surface.getTitle()) catch {};
            }
        }
        try self.vx.render(self.tty.writer());
        log.debug("render: flushing tty", .{});
        try self.tty.tty_writer.interface.flush();
        log.debug("render: complete", .{});

        self.last_render_time = std.time.milliTimestamp();
    }

    pub fn onConnected(l: *io.Loop, completion: io.Completion) anyerror!void {
        const app = completion.userdataCast(@This());

        switch (completion.result) {
            .socket => |fd| {
                app.fd = fd;
                app.connected = true;
                log.info("Connected! fd={}", .{app.fd});

                if (!app.state.should_quit) {
                    // Start receiving from the server
                    app.recv_task = try l.recv(fd, &app.recv_buffer, .{
                        .ptr = app,
                        .cb = onRecv,
                    });

                    // Vaxis and surface are already initialized from first winsize event
                    const ws = try vaxis.Tty.getWinsize(app.tty.fd);

                    if (app.attach_session) |session_name| {
                        // Attach mode: load session and attach to existing PTYs
                        try app.startSessionAttach(session_name);
                    } else {
                        // Normal mode: spawn new PTY
                        const msgid = app.state.next_msgid;
                        app.state.next_msgid += 1;
                        try app.state.pending_requests.put(msgid, .spawn);

                        var params_kv = try app.allocator.alloc(msgpack.Value.KeyValue, 3);
                        defer app.allocator.free(params_kv);
                        log.info("Sending spawn_pty: rows={} cols={}", .{ ws.rows, ws.cols });
                        params_kv[0] = .{ .key = .{ .string = "rows" }, .value = .{ .unsigned = ws.rows } };
                        params_kv[1] = .{ .key = .{ .string = "cols" }, .value = .{ .unsigned = ws.cols } };
                        params_kv[2] = .{ .key = .{ .string = "attach" }, .value = .{ .boolean = true } };
                        const params_val = msgpack.Value{ .map = params_kv };
                        var arr = try app.allocator.alloc(msgpack.Value, 4);
                        defer app.allocator.free(arr);
                        arr[0] = .{ .unsigned = 0 };
                        arr[1] = .{ .unsigned = msgid };
                        arr[2] = .{ .string = "spawn_pty" };
                        arr[3] = params_val;
                        app.send_buffer = try msgpack.encodeFromValue(app.allocator, msgpack.Value{ .array = arr });

                        app.send_task = try l.send(fd, app.send_buffer.?, .{
                            .ptr = app,
                            .cb = onSendComplete,
                        });
                    }
                } else {
                    log.info("Connected but should_quit=true, not sending spawn_pty", .{});
                }
            },
            .err => |err| {
                if (err == error.ConnectionRefused) {
                    app.state.connection_refused = true;
                } else {
                    log.err("Connection failed: {}", .{err});
                }
            },
            else => unreachable,
        }
    }

    fn startSessionAttach(self: *App, session_name: []const u8) !void {
        const home = std.posix.getenv("HOME") orelse return error.NoHomeDirectory;

        const filename = try std.fmt.allocPrint(self.allocator, "{s}.json", .{session_name});
        defer self.allocator.free(filename);

        const path = try std.fs.path.join(self.allocator, &.{ home, ".local", "state", "prise", "sessions", filename });
        defer self.allocator.free(path);

        const file = std.fs.openFileAbsolute(path, .{}) catch |err| {
            log.err("Failed to open session file {s}: {}", .{ path, err });
            return err;
        };
        defer file.close();

        const json = try file.readToEndAlloc(self.allocator, 1024 * 1024);
        self.session_json = json;

        const pty_ids = try extractPtyIdsFromJson(self.allocator, json);
        if (pty_ids.len == 0) {
            log.err("No PTY IDs found in session", .{});
            self.allocator.free(json);
            self.session_json = null;
            return error.NoSessionsFound;
        }

        log.info("Attaching to {} PTYs from session {s}", .{ pty_ids.len, session_name });
        self.pending_attach_ids = pty_ids;
        self.pending_attach_count = pty_ids.len;

        for (pty_ids) |pty_id| {
            const msgid = self.state.next_msgid;
            self.state.next_msgid += 1;
            try self.state.pending_requests.put(msgid, .{ .attach = @intCast(pty_id) });

            // Server expects params as array: [pty_id]
            var params = try self.allocator.alloc(msgpack.Value, 1);
            params[0] = .{ .unsigned = pty_id };
            const params_val = msgpack.Value{ .array = params };

            var arr = try self.allocator.alloc(msgpack.Value, 4);
            arr[0] = .{ .unsigned = 0 };
            arr[1] = .{ .unsigned = msgid };
            arr[2] = .{ .string = "attach_pty" };
            arr[3] = params_val;

            const encoded = try msgpack.encodeFromValue(self.allocator, msgpack.Value{ .array = arr });
            defer self.allocator.free(encoded);
            self.allocator.free(arr);
            self.allocator.free(params);

            try self.sendDirect(encoded);
        }
    }

    fn onSendComplete(_: *io.Loop, completion: io.Completion) anyerror!void {
        const app = completion.userdataCast(@This());

        if (app.send_buffer) |buf| {
            app.allocator.free(buf);
            app.send_buffer = null;
        }

        switch (completion.result) {
            .send => {},
            .err => |err| {
                log.err("Send failed: {}", .{err});
            },
            else => unreachable,
        }
    }

    fn onRecv(l: *io.Loop, completion: io.Completion) anyerror!void {
        const app = completion.userdataCast(@This());
        defer _ = app.msg_arena.reset(.retain_capacity);
        const arena = app.msg_arena.allocator();

        switch (completion.result) {
            .recv => |initial_bytes_read| {
                if (initial_bytes_read == 0) {
                    log.info("Server closed connection", .{});
                    app.state.should_quit = true;
                    if (app.connected) {
                        posix.close(app.fd);
                        app.connected = false;
                    }
                    app.vx.deviceStatusReport(app.tty.writer()) catch {};
                    return;
                }

                var current_bytes_read = initial_bytes_read;

                while (true) {
                    // Append new data to message buffer
                    try app.msg_buffer.appendSlice(app.allocator, app.recv_buffer[0..current_bytes_read]);

                    // Try to decode as many complete messages as possible
                    while (app.msg_buffer.items.len > 0) {
                        const result = rpc.decodeMessageWithSize(arena, app.msg_buffer.items) catch |err| {
                            if (err == error.UnexpectedEndOfInput) {
                                // Partial message, wait for more data
                                break;
                            }
                            return err;
                        };
                        defer result.message.deinit(arena);

                        const msg = result.message;
                        const bytes_consumed = result.bytes_consumed;

                        // Process message via ClientLogic
                        const action = try ClientLogic.processServerMessage(&app.state, msg);

                        switch (action) {
                            .send_attach => |pty_id| {
                                log.info("Sending attach_pty for session {}", .{pty_id});
                                app.send_buffer = try msgpack.encode(app.allocator, .{ 0, @intFromEnum(MsgId.attach_pty), "attach_pty", .{pty_id} });
                                _ = try l.send(app.fd, app.send_buffer.?, .{
                                    .ptr = app,
                                    .cb = onSendComplete,
                                });
                            },
                            .redraw => |params| {
                                app.handleRedraw(params) catch |err| {
                                    log.err("Failed to handle redraw: {}", .{err});
                                };
                            },
                            .attached => |id_i64| {
                                log.info("Attached to session, checking for resize", .{});
                                const pty_id = @as(u32, @intCast(id_i64));

                                // Ensure surface exists
                                if (!app.surfaces.contains(pty_id)) {
                                    const ws = try vaxis.Tty.getWinsize(app.tty.fd);
                                    log.info("Creating surface for attached session {}: {}x{}", .{ pty_id, ws.rows, ws.cols });
                                    const surface = app.allocator.create(Surface) catch |err| {
                                        log.err("Failed to allocate surface: {}", .{err});
                                        return error.SurfaceInitFailed;
                                    };
                                    surface.* = Surface.init(app.allocator, pty_id, ws.rows, ws.cols) catch |err| {
                                        log.err("Failed to create surface: {}", .{err});
                                        app.allocator.destroy(surface);
                                        return error.SurfaceInitFailed;
                                    };
                                    app.surfaces.put(pty_id, surface) catch |err| {
                                        log.err("Failed to store surface: {}", .{err});
                                        surface.deinit();
                                        app.allocator.destroy(surface);
                                        return error.SurfaceInitFailed;
                                    };
                                }

                                if (app.surfaces.get(pty_id)) |surface| {
                                    // Skip pty_attach events during session restore - set_state will restore the UI tree
                                    const is_session_restore = app.pending_attach_count > 0 or app.session_json != null;
                                    if (!is_session_restore) {
                                        log.info("Updating UI with pty_attach for {}", .{pty_id});
                                        // Send pty_attach event to Lua UI
                                        app.ui.update(.{
                                            .pty_attach = .{
                                                .id = pty_id,
                                                .surface = surface,
                                                .app = app,
                                                .send_key_fn = struct {
                                                    fn appSendDirect(ctx: *anyopaque, id: u32, key: lua_event.KeyData) anyerror!void {
                                                        const self: *App = @ptrCast(@alignCast(ctx));

                                                        var key_map_kv = try self.allocator.alloc(msgpack.Value.KeyValue, 6);
                                                        key_map_kv[0] = .{ .key = .{ .string = "key" }, .value = .{ .string = key.key } };
                                                        key_map_kv[1] = .{ .key = .{ .string = "code" }, .value = .{ .string = key.code } };
                                                        key_map_kv[2] = .{ .key = .{ .string = "shiftKey" }, .value = .{ .boolean = key.shift } };
                                                        key_map_kv[3] = .{ .key = .{ .string = "ctrlKey" }, .value = .{ .boolean = key.ctrl } };
                                                        key_map_kv[4] = .{ .key = .{ .string = "altKey" }, .value = .{ .boolean = key.alt } };
                                                        key_map_kv[5] = .{ .key = .{ .string = "metaKey" }, .value = .{ .boolean = key.super } };

                                                        const key_map_val: msgpack.Value = .{ .map = key_map_kv };

                                                        var params = try self.allocator.alloc(msgpack.Value, 2);
                                                        params[0] = .{ .unsigned = @intCast(id) };
                                                        params[1] = key_map_val;

                                                        const method: []const u8 = if (key.release) "key_release" else "key_input";

                                                        var arr = try self.allocator.alloc(msgpack.Value, 3);
                                                        arr[0] = .{ .unsigned = 2 }; // notification
                                                        arr[1] = .{ .string = method };
                                                        arr[2] = .{ .array = params };

                                                        const encoded_msg = try msgpack.encodeFromValue(self.allocator, .{ .array = arr });
                                                        defer self.allocator.free(encoded_msg);

                                                        // Clean up msgpack structures
                                                        self.allocator.free(arr);
                                                        self.allocator.free(params);
                                                        self.allocator.free(key_map_kv);

                                                        try self.sendDirect(encoded_msg);
                                                    }
                                                }.appSendDirect,
                                                .send_mouse_fn = struct {
                                                    fn appSendMouse(ctx: *anyopaque, id: u32, mouse: lua_event.MouseData) anyerror!void {
                                                        const self: *App = @ptrCast(@alignCast(ctx));

                                                        var mouse_map_kv = try self.allocator.alloc(msgpack.Value.KeyValue, 7);
                                                        mouse_map_kv[0] = .{ .key = .{ .string = "x" }, .value = .{ .float = mouse.x } };
                                                        mouse_map_kv[1] = .{ .key = .{ .string = "y" }, .value = .{ .float = mouse.y } };
                                                        mouse_map_kv[2] = .{ .key = .{ .string = "button" }, .value = .{ .string = mouse.button } };
                                                        mouse_map_kv[3] = .{ .key = .{ .string = "event_type" }, .value = .{ .string = mouse.event_type } };
                                                        mouse_map_kv[4] = .{ .key = .{ .string = "shiftKey" }, .value = .{ .boolean = mouse.shift } };
                                                        mouse_map_kv[5] = .{ .key = .{ .string = "ctrlKey" }, .value = .{ .boolean = mouse.ctrl } };
                                                        mouse_map_kv[6] = .{ .key = .{ .string = "altKey" }, .value = .{ .boolean = mouse.alt } };

                                                        const mouse_map_val: msgpack.Value = .{ .map = mouse_map_kv };

                                                        var params = try self.allocator.alloc(msgpack.Value, 2);
                                                        params[0] = .{ .unsigned = @intCast(id) };
                                                        params[1] = mouse_map_val;

                                                        var arr = try self.allocator.alloc(msgpack.Value, 3);
                                                        arr[0] = .{ .unsigned = 2 }; // notification
                                                        arr[1] = .{ .string = "mouse_input" };
                                                        arr[2] = .{ .array = params };

                                                        const encoded_msg = try msgpack.encodeFromValue(self.allocator, .{ .array = arr });
                                                        defer self.allocator.free(encoded_msg);

                                                        // Clean up msgpack structures
                                                        self.allocator.free(arr);
                                                        self.allocator.free(params);
                                                        self.allocator.free(mouse_map_kv);

                                                        try self.sendDirect(encoded_msg);
                                                    }
                                                }.appSendMouse,
                                                .close_fn = struct {
                                                    fn appClosePty(ctx: *anyopaque, id: u32) anyerror!void {
                                                        const self: *App = @ptrCast(@alignCast(ctx));

                                                        var params = try self.allocator.alloc(msgpack.Value, 1);
                                                        params[0] = .{ .unsigned = @intCast(id) };

                                                        const msgid = self.state.next_msgid;
                                                        self.state.next_msgid +%= 1;

                                                        var arr = try self.allocator.alloc(msgpack.Value, 4);
                                                        arr[0] = .{ .unsigned = 0 }; // request
                                                        arr[1] = .{ .unsigned = msgid };
                                                        arr[2] = .{ .string = "close_pty" };
                                                        arr[3] = .{ .array = params };

                                                        const encoded_msg = try msgpack.encodeFromValue(self.allocator, .{ .array = arr });
                                                        defer self.allocator.free(encoded_msg);

                                                        self.allocator.free(arr);
                                                        self.allocator.free(params);

                                                        try self.sendDirect(encoded_msg);
                                                    }
                                                }.appClosePty,
                                            },
                                        }) catch |err| {
                                            log.err("Failed to update UI with pty_attach: {}", .{err});
                                        };
                                    }

                                    const width_px = @as(u16, surface.cols) * app.cell_width_px;
                                    const height_px = @as(u16, surface.rows) * app.cell_height_px;
                                    log.info("Sending initial resize: {}x{} ({}x{}px, cell={}x{})", .{ surface.rows, surface.cols, width_px, height_px, app.cell_width_px, app.cell_height_px });
                                    const resize_msg = try msgpack.encode(app.allocator, .{
                                        2, // notification
                                        "resize_pty",
                                        .{ pty_id, surface.rows, surface.cols, width_px, height_px },
                                    });
                                    defer app.allocator.free(resize_msg);
                                    try app.sendDirect(resize_msg);

                                    // Check if we're in session attach mode and all PTYs attached
                                    if (app.pending_attach_count > 0) {
                                        app.pending_attach_count -= 1;
                                        if (app.pending_attach_count == 0) {
                                            log.info("All PTYs attached, restoring session state", .{});
                                            if (app.session_json) |json| {
                                                app.ui.setStateFromJson(json, ptyLookup, app) catch |err| {
                                                    log.err("Failed to restore session state: {}", .{err});
                                                };
                                                app.allocator.free(json);
                                                app.session_json = null;
                                            }
                                            if (app.pending_attach_ids) |ids| {
                                                app.allocator.free(ids);
                                                app.pending_attach_ids = null;
                                            }
                                            try app.scheduleRender();
                                        }
                                    }
                                }
                            },
                            .pty_exited => |info| {
                                log.info("PTY {} exited with status {}", .{ info.pty_id, info.status });
                                app.ui.update(.{ .pty_exited = .{ .id = info.pty_id, .status = info.status } }) catch |err| {
                                    log.err("Failed to update UI with pty_exited: {}", .{err});
                                };
                            },
                            .detached => {
                                log.info("Detach complete, closing connection", .{});
                                app.state.should_quit = true;
                                if (app.connected) {
                                    posix.close(app.fd);
                                    app.connected = false;
                                }
                                // Wake up TTY thread so it can exit
                                app.vx.deviceStatusReport(app.tty.writer()) catch {};
                                return;
                            },
                            .none => {},
                        }

                        // Remove consumed bytes from buffer
                        if (bytes_consumed > 0) {
                            try app.msg_buffer.replaceRange(app.allocator, 0, bytes_consumed, &.{});
                        }
                    }

                    // Try to read more
                    const n = posix.recv(app.fd, &app.recv_buffer, 0) catch |err| {
                        if (err == error.WouldBlock) break;
                        return err;
                    };

                    if (n == 0) {
                        log.info("Server closed connection", .{});
                        app.state.should_quit = true;
                        if (app.connected) {
                            posix.close(app.fd);
                            app.connected = false;
                        }
                        app.vx.deviceStatusReport(app.tty.writer()) catch {};
                        return;
                    }
                    current_bytes_read = n;
                }

                // Keep receiving unless we're quitting
                if (!app.state.should_quit) {
                    app.recv_task = try l.recv(app.fd, &app.recv_buffer, .{
                        .ptr = app,
                        .cb = onRecv,
                    });
                }
            },
            .err => |err| {
                log.err("Recv failed: {}", .{err});
                log.info("NOT resubmitting recv after error", .{});
                // Don't resubmit on error - let it drain
            },
            else => unreachable,
        }
    }

    fn sendDirect(self: *App, data: []const u8) !void {
        var index: usize = 0;
        while (index < data.len) {
            const n = try posix.write(self.fd, data[index..]);
            index += n;
        }
    }

    pub fn spawnPty(self: *App, opts: UI.SpawnOptions) !void {
        const msgid = self.state.next_msgid;
        self.state.next_msgid += 1;

        log.info("spawnPty: sending request msgid={}", .{msgid});
        try self.state.pending_requests.put(msgid, .spawn);

        // Manually construct map for spawn params
        var map_items = try self.allocator.alloc(msgpack.Value.KeyValue, 3);
        defer self.allocator.free(map_items);

        map_items[0] = .{ .key = .{ .string = "rows" }, .value = .{ .unsigned = opts.rows } };
        map_items[1] = .{ .key = .{ .string = "cols" }, .value = .{ .unsigned = opts.cols } };
        map_items[2] = .{ .key = .{ .string = "attach" }, .value = .{ .boolean = opts.attach } };

        const params = msgpack.Value{ .map = map_items };
        const msg = try msgpack.encode(self.allocator, .{ 0, msgid, "spawn_pty", params });
        defer self.allocator.free(msg);

        try self.sendDirect(msg);
    }

    pub fn saveSession(self: *App, name: []const u8) !void {
        const json = try self.ui.getStateJson();
        defer self.allocator.free(json);

        const home = std.posix.getenv("HOME") orelse return error.NoHomeDirectory;
        const state_dir = try std.fs.path.join(self.allocator, &.{ home, ".local", "state", "prise", "sessions" });
        defer self.allocator.free(state_dir);

        std.fs.makeDirAbsolute(state_dir) catch |err| {
            if (err != error.PathAlreadyExists) {
                // Try creating parent directories
                const parent = try std.fs.path.join(self.allocator, &.{ home, ".local", "state", "prise" });
                defer self.allocator.free(parent);
                std.fs.makeDirAbsolute(parent) catch |e| {
                    if (e != error.PathAlreadyExists) return e;
                };
                std.fs.makeDirAbsolute(state_dir) catch |e| {
                    if (e != error.PathAlreadyExists) return e;
                };
            }
        };

        const filename = try std.fmt.allocPrint(self.allocator, "{s}.json", .{name});
        defer self.allocator.free(filename);

        const path = try std.fs.path.join(self.allocator, &.{ state_dir, filename });
        defer self.allocator.free(path);

        const file = try std.fs.createFileAbsolute(path, .{});
        defer file.close();

        try file.writeAll(json);
        log.info("Session saved to {s}", .{path});
    }

    pub fn loadSession(self: *App, name: []const u8) !void {
        const home = std.posix.getenv("HOME") orelse return error.NoHomeDirectory;

        const filename = try std.fmt.allocPrint(self.allocator, "{s}.json", .{name});
        defer self.allocator.free(filename);

        const path = try std.fs.path.join(self.allocator, &.{ home, ".local", "state", "prise", "sessions", filename });
        defer self.allocator.free(path);

        const file = std.fs.openFileAbsolute(path, .{}) catch |err| {
            log.err("Failed to open session file {s}: {}", .{ path, err });
            return err;
        };
        defer file.close();

        const json = try file.readToEndAlloc(self.allocator, 1024 * 1024);
        defer self.allocator.free(json);

        try self.ui.setStateFromJson(json, ptyLookup, self);
        log.info("Session loaded from {s}", .{path});
    }

    fn extractPtyIdsFromJson(allocator: std.mem.Allocator, json: []const u8) ![]u32 {
        const parsed = try std.json.parseFromSlice(std.json.Value, allocator, json, .{});
        defer parsed.deinit();

        var ids: std.ArrayList(u32) = .empty;
        errdefer ids.deinit(allocator);

        try collectPtyIds(&ids, allocator, parsed.value);
        return ids.toOwnedSlice(allocator);
    }

    fn collectPtyIds(ids: *std.ArrayList(u32), allocator: std.mem.Allocator, value: std.json.Value) !void {
        switch (value) {
            .object => |obj| {
                if (obj.get("type")) |type_val| {
                    if (type_val == .string and std.mem.eql(u8, type_val.string, "pane")) {
                        if (obj.get("pty_id")) |pty_id_val| {
                            if (pty_id_val == .integer) {
                                try ids.append(allocator, @intCast(pty_id_val.integer));
                            }
                        }
                    }
                }
                var it = obj.iterator();
                while (it.next()) |entry| {
                    try collectPtyIds(ids, allocator, entry.value_ptr.*);
                }
            },
            .array => |arr| {
                for (arr.items) |item| {
                    try collectPtyIds(ids, allocator, item);
                }
            },
            else => {},
        }
    }

    fn ptyLookup(ctx: *anyopaque, id: u32) ?UI.PtyLookupResult {
        const self: *App = @ptrCast(@alignCast(ctx));

        const surface = self.surfaces.get(id) orelse return null;

        return .{
            .surface = surface,
            .app = self,
            .send_key_fn = struct {
                fn sendKey(app_ctx: *anyopaque, pty_id: u32, key: lua_event.KeyData) anyerror!void {
                    const app: *App = @ptrCast(@alignCast(app_ctx));

                    var key_map_kv = try app.allocator.alloc(msgpack.Value.KeyValue, 6);
                    key_map_kv[0] = .{ .key = .{ .string = "key" }, .value = .{ .string = key.key } };
                    key_map_kv[1] = .{ .key = .{ .string = "code" }, .value = .{ .string = key.code } };
                    key_map_kv[2] = .{ .key = .{ .string = "shiftKey" }, .value = .{ .boolean = key.shift } };
                    key_map_kv[3] = .{ .key = .{ .string = "ctrlKey" }, .value = .{ .boolean = key.ctrl } };
                    key_map_kv[4] = .{ .key = .{ .string = "altKey" }, .value = .{ .boolean = key.alt } };
                    key_map_kv[5] = .{ .key = .{ .string = "metaKey" }, .value = .{ .boolean = key.super } };

                    const key_map_val: msgpack.Value = .{ .map = key_map_kv };

                    var params = try app.allocator.alloc(msgpack.Value, 2);
                    params[0] = .{ .unsigned = @intCast(pty_id) };
                    params[1] = key_map_val;

                    const method: []const u8 = if (key.release) "key_release" else "key_input";

                    var arr = try app.allocator.alloc(msgpack.Value, 3);
                    arr[0] = .{ .unsigned = 2 };
                    arr[1] = .{ .string = method };
                    arr[2] = .{ .array = params };

                    const encoded_msg = try msgpack.encodeFromValue(app.allocator, .{ .array = arr });
                    defer app.allocator.free(encoded_msg);

                    app.allocator.free(arr);
                    app.allocator.free(params);
                    app.allocator.free(key_map_kv);

                    try app.sendDirect(encoded_msg);
                }
            }.sendKey,
            .send_mouse_fn = struct {
                fn sendMouse(app_ctx: *anyopaque, pty_id: u32, mouse: lua_event.MouseData) anyerror!void {
                    const app: *App = @ptrCast(@alignCast(app_ctx));

                    var mouse_map_kv = try app.allocator.alloc(msgpack.Value.KeyValue, 7);
                    mouse_map_kv[0] = .{ .key = .{ .string = "x" }, .value = .{ .float = mouse.x } };
                    mouse_map_kv[1] = .{ .key = .{ .string = "y" }, .value = .{ .float = mouse.y } };
                    mouse_map_kv[2] = .{ .key = .{ .string = "button" }, .value = .{ .string = mouse.button } };
                    mouse_map_kv[3] = .{ .key = .{ .string = "event_type" }, .value = .{ .string = mouse.event_type } };
                    mouse_map_kv[4] = .{ .key = .{ .string = "shiftKey" }, .value = .{ .boolean = mouse.shift } };
                    mouse_map_kv[5] = .{ .key = .{ .string = "ctrlKey" }, .value = .{ .boolean = mouse.ctrl } };
                    mouse_map_kv[6] = .{ .key = .{ .string = "altKey" }, .value = .{ .boolean = mouse.alt } };

                    const mouse_map_val: msgpack.Value = .{ .map = mouse_map_kv };

                    var params = try app.allocator.alloc(msgpack.Value, 2);
                    params[0] = .{ .unsigned = @intCast(pty_id) };
                    params[1] = mouse_map_val;

                    var arr = try app.allocator.alloc(msgpack.Value, 3);
                    arr[0] = .{ .unsigned = 2 };
                    arr[1] = .{ .string = "mouse_input" };
                    arr[2] = .{ .array = params };

                    const encoded_msg = try msgpack.encodeFromValue(app.allocator, .{ .array = arr });
                    defer app.allocator.free(encoded_msg);

                    app.allocator.free(arr);
                    app.allocator.free(params);
                    app.allocator.free(mouse_map_kv);

                    try app.sendDirect(encoded_msg);
                }
            }.sendMouse,
            .close_fn = struct {
                fn closePty(app_ctx: *anyopaque, pty_id: u32) anyerror!void {
                    const app: *App = @ptrCast(@alignCast(app_ctx));

                    var params = try app.allocator.alloc(msgpack.Value, 1);
                    params[0] = .{ .unsigned = @intCast(pty_id) };

                    // Use 0 for request type (it's a request, but we don't wait for response here as it's fire-and-forget from Lua perspective)
                    // Actually, let's use request type 0 and a dummy msgid, or just notification type 2?
                    // Server handles "close_pty" as a request (returns msgpack.Value.nil).
                    // So we should send a request.
                    const msgid = app.state.next_msgid;
                    app.state.next_msgid +%= 1;

                    var arr = try app.allocator.alloc(msgpack.Value, 4);
                    arr[0] = .{ .unsigned = 0 }; // request
                    arr[1] = .{ .unsigned = msgid };
                    arr[2] = .{ .string = "close_pty" };
                    arr[3] = .{ .array = params };

                    const encoded_msg = try msgpack.encodeFromValue(app.allocator, .{ .array = arr });
                    defer app.allocator.free(encoded_msg);

                    app.allocator.free(arr);
                    app.allocator.free(params);

                    try app.sendDirect(encoded_msg);
                }
            }.closePty,
        };
    }
};

test "ClientLogic - encodeEvent" {
    const testing = std.testing;
    const allocator = testing.allocator;

    // Test Key Press
    {
        const event = vaxis.Event{
            .key_press = .{
                .codepoint = 'a',
                .mods = .{},
            },
        };
        const msg = (try ClientLogic.encodeEvent(allocator, event)).?;
        defer allocator.free(msg);

        const val = try msgpack.decode(allocator, msg);
        defer val.deinit(allocator);

        try testing.expectEqual(std.meta.Tag(msgpack.Value).array, std.meta.activeTag(val));
        try testing.expectEqual(2, val.array.len);
        try testing.expectEqualStrings("key", val.array[0].string);
        try testing.expectEqual(std.meta.Tag(msgpack.Value).map, std.meta.activeTag(val.array[1]));
    }

    // Test Resize
    {
        const event = vaxis.Event{
            .winsize = .{
                .rows = 24,
                .cols = 80,
                .x_pixel = 0,
                .y_pixel = 0,
            },
        };
        const msg = (try ClientLogic.encodeEvent(allocator, event)).?;
        defer allocator.free(msg);

        const val = try msgpack.decode(allocator, msg);
        defer val.deinit(allocator);

        try testing.expectEqual(std.meta.Tag(msgpack.Value).array, std.meta.activeTag(val));
        try testing.expectEqual(3, val.array.len);
        try testing.expectEqualStrings("resize", val.array[0].string);
        try testing.expectEqual(24, val.array[1].unsigned);
        try testing.expectEqual(80, val.array[2].unsigned);
    }
}

test "ClientLogic - processServerMessage" {
    const testing = std.testing;
    // const allocator = testing.allocator; // Unused in this test

    // Test PTY spawn response (integer)
    {
        var state = ClientState.init(testing.allocator);
        defer state.deinit();
        // Manually add a pending spawn request
        try state.pending_requests.put(1, .spawn);

        const msg = rpc.Message{
            .response = .{
                .msgid = 1,
                .err = null,
                .result = .{ .integer = 123 },
            },
        };

        const action = try ClientLogic.processServerMessage(&state, msg);
        try testing.expect(state.response_received);
        try testing.expectEqual(123, state.pty_id.?);
        try testing.expectEqual(std.meta.Tag(ServerAction).attached, std.meta.activeTag(action));
        try testing.expectEqual(123, action.attached);
    }

    // Test Attach response (already have pty_id)
    {
        var state = ClientState.init(testing.allocator);
        defer state.deinit();
        try state.pending_requests.put(2, .{ .attach = 123 });

        const msg = rpc.Message{
            .response = .{
                .msgid = 2,
                .err = null,
                .result = .{ .integer = 0 }, // Result of attach is typically success/pty_id
            },
        };

        const action = try ClientLogic.processServerMessage(&state, msg);
        try testing.expect(state.attached);
        try testing.expectEqual(std.meta.Tag(ServerAction).attached, std.meta.activeTag(action));
        try testing.expectEqual(123, action.attached);
    }

    // Test Redraw Notification
    {
        var state = ClientState.init(testing.allocator);
        defer state.deinit();
        // Params: [events...]
        const params = msgpack.Value{ .array = &[_]msgpack.Value{} };
        const msg = rpc.Message{
            .notification = .{
                .method = "redraw",
                .params = params,
            },
        };

        const action = try ClientLogic.processServerMessage(&state, msg);
        try testing.expectEqual(std.meta.Tag(ServerAction).redraw, std.meta.activeTag(action));
    }
}

test "ClientLogic - processPipeMessage" {
    const testing = std.testing;
    const allocator = testing.allocator;

    // Test Quit
    {
        var state = ClientState.init(testing.allocator);
        defer state.deinit();
        const encoded = try msgpack.encode(allocator, .{"quit"});
        defer allocator.free(encoded);

        const quit_val = try msgpack.decode(allocator, encoded);
        defer quit_val.deinit(allocator);

        const action = try ClientLogic.processPipeMessage(&state, quit_val);
        try testing.expect(state.should_quit);
        try testing.expectEqual(std.meta.Tag(PipeAction).quit, std.meta.activeTag(action));
    }

    // Test Key Input
    {
        var state = ClientState.init(testing.allocator);
        defer state.deinit();
        state.attached = true;
        state.pty_id = 123;

        // Create a proper msgpack map value
        var key_map_kv = try allocator.alloc(msgpack.Value.KeyValue, 5);
        key_map_kv[0] = .{ .key = .{ .string = "key" }, .value = .{ .string = "a" } };
        key_map_kv[1] = .{ .key = .{ .string = "shiftKey" }, .value = .{ .boolean = false } };
        key_map_kv[2] = .{ .key = .{ .string = "ctrlKey" }, .value = .{ .boolean = false } };
        key_map_kv[3] = .{ .key = .{ .string = "altKey" }, .value = .{ .boolean = false } };
        key_map_kv[4] = .{ .key = .{ .string = "metaKey" }, .value = .{ .boolean = false } };

        const key_map_val: msgpack.Value = .{ .map = key_map_kv };
        var arr = try allocator.alloc(msgpack.Value, 2);
        arr[0] = .{ .string = "key" };
        arr[1] = key_map_val;
        const encoded = try msgpack.encodeFromValue(allocator, .{ .array = arr });
        defer allocator.free(encoded);

        const key_val = try msgpack.decode(allocator, encoded);
        defer key_val.deinit(allocator);
        defer allocator.free(arr);
        defer allocator.free(key_map_kv);

        const action = try ClientLogic.processPipeMessage(&state, key_val);
        try testing.expectEqual(std.meta.Tag(PipeAction).send_key, std.meta.activeTag(action));
        try testing.expect(action.send_key == .map);
    }

    // Test Resize
    {
        var state = ClientState.init(testing.allocator);
        defer state.deinit();

        const encoded = try msgpack.encode(allocator, .{ "resize", 24, 80 });
        defer allocator.free(encoded);

        const resize_val = try msgpack.decode(allocator, encoded);
        defer resize_val.deinit(allocator);

        const action = try ClientLogic.processPipeMessage(&state, resize_val);
        try testing.expectEqual(std.meta.Tag(PipeAction).send_resize, std.meta.activeTag(action));
        try testing.expectEqual(24, action.send_resize.rows);
        try testing.expectEqual(80, action.send_resize.cols);
    }
}

test "ClientLogic - shouldFlush" {
    const testing = std.testing;
    const allocator = testing.allocator;

    // Test with flush event
    {
        const flush_event = try msgpack.encode(allocator, .{"flush"});
        defer allocator.free(flush_event);

        const flush_val = try msgpack.decode(allocator, flush_event);
        defer flush_val.deinit(allocator);

        const events = try allocator.alloc(msgpack.Value, 1);
        events[0] = flush_val;

        const params: msgpack.Value = .{ .array = events };
        defer allocator.free(events);

        try testing.expect(ClientLogic.shouldFlush(params));
    }

    // Test without flush event
    {
        const other_event = try msgpack.encode(allocator, .{"other"});
        defer allocator.free(other_event);

        const other_val = try msgpack.decode(allocator, other_event);
        defer other_val.deinit(allocator);

        const events = try allocator.alloc(msgpack.Value, 1);
        events[0] = other_val;

        const params: msgpack.Value = .{ .array = events };
        defer allocator.free(events);

        try testing.expect(!ClientLogic.shouldFlush(params));
    }

    // Test empty events
    {
        const events = try allocator.alloc(msgpack.Value, 0);
        const params: msgpack.Value = .{ .array = events };
        defer allocator.free(events);

        try testing.expect(!ClientLogic.shouldFlush(params));
    }
}

test "UnixSocketClient - successful connection" {
    const testing = std.testing;

    var loop = try io.Loop.init(testing.allocator);
    defer loop.deinit();

    var connected = false;
    var fd: posix.socket_t = undefined;

    const State = struct {
        connected: *bool,
        fd: *posix.socket_t,
    };

    var state = State{
        .connected = &connected,
        .fd = &fd,
    };

    const callback = struct {
        fn cb(l: *io.Loop, completion: io.Completion) anyerror!void {
            _ = l;
            const s = completion.userdataCast(State);
            switch (completion.result) {
                .socket => |socket_fd| {
                    s.fd.* = socket_fd;
                    s.connected.* = true;
                },
                .err => |err| return err,
                else => unreachable,
            }
        }
    }.cb;

    _ = try connectUnixSocket(&loop, "/tmp/test.sock", .{
        .ptr = &state,
        .cb = callback,
    });

    try loop.run(.once);
    try testing.expect(!connected);

    const socket_fd = blk: {
        var it = loop.pending.iterator();
        while (it.next()) |entry| {
            if (entry.value_ptr.kind == .connect) {
                break :blk entry.value_ptr.fd;
            }
        }
        unreachable;
    };

    try loop.completeConnect(socket_fd);
    try loop.run(.once);
    try testing.expect(connected);
    try testing.expectEqual(socket_fd, fd);
}

test "UnixSocketClient - connection refused" {
    const testing = std.testing;

    var loop = try io.Loop.init(testing.allocator);
    defer loop.deinit();

    var got_error = false;
    var err_value: ?anyerror = null;

    const State = struct {
        got_error: *bool,
        err_value: *?anyerror,
    };

    var state = State{
        .got_error = &got_error,
        .err_value = &err_value,
    };

    const callback = struct {
        fn cb(l: *io.Loop, completion: io.Completion) anyerror!void {
            _ = l;
            const s = completion.userdataCast(State);
            switch (completion.result) {
                .socket => {},
                .err => |err| {
                    s.got_error.* = true;
                    s.err_value.* = err;
                },
                else => unreachable,
            }
        }
    }.cb;

    _ = try connectUnixSocket(&loop, "/tmp/test.sock", .{
        .ptr = &state,
        .cb = callback,
    });

    try loop.run(.once);

    const socket_fd = blk: {
        var it = loop.pending.iterator();
        while (it.next()) |entry| {
            if (entry.value_ptr.kind == .connect) {
                break :blk entry.value_ptr.fd;
            }
        }
        unreachable;
    };

    try loop.completeWithError(socket_fd, error.ConnectionRefused);
    try loop.run(.until_done);
    try testing.expect(got_error);
    try testing.expectEqual(error.ConnectionRefused, err_value.?);
}
