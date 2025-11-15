const std = @import("std");
const posix = std.posix;
const c = std.c;
const root = @import("../loop.zig");

pub const Loop = struct {
    allocator: std.mem.Allocator,
    kq: i32,
    next_id: usize = 1,
    pending: std.AutoHashMap(usize, PendingOp),

    const PendingOp = struct {
        ctx: root.Context,
        kind: OpKind,
        fd: posix.fd_t = undefined,
        buf: []u8 = &.{},
        addr: *const posix.sockaddr = undefined,
        addr_len: posix.socklen_t = 0,
    };

    const OpKind = enum {
        socket,
        connect,
        accept,
        recv,
        send,
        close,
    };

    pub fn init(allocator: std.mem.Allocator) !Loop {
        const kq = try posix.kqueue();
        return .{
            .allocator = allocator,
            .kq = kq,
            .pending = std.AutoHashMap(usize, PendingOp).init(allocator),
        };
    }

    pub fn deinit(self: *Loop) void {
        self.pending.deinit();
        posix.close(self.kq);
    }

    pub fn socket(
        self: *Loop,
        domain: u32,
        socket_type: u32,
        protocol: u32,
        ctx: root.Context,
    ) !root.Task {
        const id = self.next_id;
        self.next_id += 1;

        // Socket creation is synchronous, complete immediately
        const fd = posix.socket(domain, socket_type, protocol) catch |err| {
            try ctx.cb(self, .{
                .userdata = ctx.ptr,
                .msg = ctx.msg,
                .callback = ctx.cb,
                .result = .{ .err = err },
            });
            return root.Task{ .id = id, .ctx = ctx };
        };

        try ctx.cb(self, .{
            .userdata = ctx.ptr,
            .msg = ctx.msg,
            .callback = ctx.cb,
            .result = .{ .socket = fd },
        });

        return root.Task{ .id = id, .ctx = ctx };
    }

    pub fn connect(
        self: *Loop,
        fd: posix.socket_t,
        addr: *const posix.sockaddr,
        addr_len: posix.socklen_t,
        ctx: root.Context,
    ) !root.Task {
        const id = self.next_id;
        self.next_id += 1;

        // Try non-blocking connect
        const rc = posix.system.connect(fd, addr, addr_len);

        if (rc == 0) {
            // Connected immediately
            try ctx.cb(self, .{
                .userdata = ctx.ptr,
                .msg = ctx.msg,
                .callback = ctx.cb,
                .result = .{ .connect = {} },
            });
        } else {
            const err = posix.errno(rc);
            if (err == .INPROGRESS) {
                // Connection in progress, wait for writability
                try self.pending.put(id, .{
                    .ctx = ctx,
                    .kind = .connect,
                    .fd = fd,
                });

                var changes = [_]posix.Kevent{.{
                    .ident = @intCast(fd),
                    .filter = c.EVFILT.WRITE,
                    .flags = c.EV.ADD | c.EV.ENABLE | c.EV.ONESHOT,
                    .fflags = 0,
                    .data = 0,
                    .udata = id,
                }};
                _ = try posix.kevent(self.kq, &changes, &[_]posix.Kevent{}, null);
            } else {
                // Immediate error
                try ctx.cb(self, .{
                    .userdata = ctx.ptr,
                    .msg = ctx.msg,
                    .callback = ctx.cb,
                    .result = .{ .err = posix.unexpectedErrno(err) },
                });
            }
        }

        return root.Task{ .id = id, .ctx = ctx };
    }

    pub fn accept(
        self: *Loop,
        fd: posix.socket_t,
        ctx: root.Context,
    ) !root.Task {
        const id = self.next_id;
        self.next_id += 1;

        try self.pending.put(id, .{
            .ctx = ctx,
            .kind = .accept,
            .fd = fd,
        });

        var changes = [_]posix.Kevent{.{
            .ident = @intCast(fd),
            .filter = c.EVFILT.READ,
            .flags = c.EV.ADD | c.EV.ENABLE | c.EV.ONESHOT,
            .fflags = 0,
            .data = 0,
            .udata = id,
        }};
        _ = try posix.kevent(self.kq, &changes, &[_]posix.Kevent{}, null);

        return root.Task{ .id = id, .ctx = ctx };
    }

    pub fn recv(
        self: *Loop,
        fd: posix.socket_t,
        buf: []u8,
        ctx: root.Context,
    ) !root.Task {
        const id = self.next_id;
        self.next_id += 1;

        try self.pending.put(id, .{
            .ctx = ctx,
            .kind = .recv,
            .fd = fd,
            .buf = buf,
        });

        var changes = [_]posix.Kevent{.{
            .ident = @intCast(fd),
            .filter = c.EVFILT.READ,
            .flags = c.EV.ADD | c.EV.ENABLE | c.EV.ONESHOT,
            .fflags = 0,
            .data = 0,
            .udata = id,
        }};
        _ = try posix.kevent(self.kq, &changes, &[_]posix.Kevent{}, null);

        return root.Task{ .id = id, .ctx = ctx };
    }

    pub fn send(
        self: *Loop,
        fd: posix.socket_t,
        buf: []const u8,
        ctx: root.Context,
    ) !root.Task {
        const id = self.next_id;
        self.next_id += 1;

        try self.pending.put(id, .{
            .ctx = ctx,
            .kind = .send,
            .fd = fd,
            .buf = @constCast(buf),
        });

        var changes = [_]posix.Kevent{.{
            .ident = @intCast(fd),
            .filter = c.EVFILT.WRITE,
            .flags = c.EV.ADD | c.EV.ENABLE | c.EV.ONESHOT,
            .fflags = 0,
            .data = 0,
            .udata = id,
        }};
        _ = try posix.kevent(self.kq, &changes, &[_]posix.Kevent{}, null);

        return root.Task{ .id = id, .ctx = ctx };
    }

    pub fn close(
        self: *Loop,
        fd: posix.socket_t,
        ctx: root.Context,
    ) !root.Task {
        const id = self.next_id;
        self.next_id += 1;

        posix.close(fd);

        try ctx.cb(self, .{
            .userdata = ctx.ptr,
            .msg = ctx.msg,
            .callback = ctx.cb,
            .result = .{ .close = {} },
        });

        return root.Task{ .id = id, .ctx = ctx };
    }

    pub fn cancel(self: *Loop, id: usize) !void {
        _ = self.pending.remove(id);
    }

    pub fn run(self: *Loop, mode: RunMode) !void {
        var events: [32]posix.Kevent = undefined;

        while (true) {
            if (mode == .until_done and self.pending.count() == 0) break;

            const timeout: ?*const posix.timespec = if (mode == .once) &.{ .sec = 0, .nsec = 0 } else null;
            const n = posix.kevent(self.kq, &[_]posix.Kevent{}, events[0..], timeout) catch |err| {
                if (err == error.Unexpected) continue;
                return err;
            };

            if (n == 0 and mode == .once) break;

            for (events[0..n]) |ev| {
                const id: usize = @intCast(ev.udata);
                const op = self.pending.get(id) orelse continue;
                _ = self.pending.remove(id);

                try self.handleCompletion(op, ev);
            }

            if (mode == .once) break;
        }
    }

    fn handleCompletion(self: *Loop, op: PendingOp, ev: posix.Kevent) !void {
        const ctx = op.ctx;

        if (ev.flags & c.EV.ERROR != 0) {
            try ctx.cb(self, .{
                .userdata = ctx.ptr,
                .msg = ctx.msg,
                .callback = ctx.cb,
                .result = .{ .err = error.IOError },
            });
            return;
        }

        switch (op.kind) {
            .connect => {
                var err_code: i32 = undefined;
                var len: posix.socklen_t = @sizeOf(i32);
                _ = posix.system.getsockopt(op.fd, posix.SOL.SOCKET, posix.SO.ERROR, @ptrCast(&err_code), &len);

                if (err_code == 0) {
                    try ctx.cb(self, .{
                        .userdata = ctx.ptr,
                        .msg = ctx.msg,
                        .callback = ctx.cb,
                        .result = .{ .connect = {} },
                    });
                } else {
                    try ctx.cb(self, .{
                        .userdata = ctx.ptr,
                        .msg = ctx.msg,
                        .callback = ctx.cb,
                        .result = .{ .err = error.ConnectionFailed },
                    });
                }
            },

            .accept => {
                const client_fd = posix.accept(op.fd, null, null, posix.SOCK.CLOEXEC) catch |err| {
                    try ctx.cb(self, .{
                        .userdata = ctx.ptr,
                        .msg = ctx.msg,
                        .callback = ctx.cb,
                        .result = .{ .err = err },
                    });
                    return;
                };

                try ctx.cb(self, .{
                    .userdata = ctx.ptr,
                    .msg = ctx.msg,
                    .callback = ctx.cb,
                    .result = .{ .accept = client_fd },
                });
            },

            .recv => {
                const bytes_read = posix.recv(op.fd, op.buf, 0) catch |err| {
                    try ctx.cb(self, .{
                        .userdata = ctx.ptr,
                        .msg = ctx.msg,
                        .callback = ctx.cb,
                        .result = .{ .err = err },
                    });
                    return;
                };

                try ctx.cb(self, .{
                    .userdata = ctx.ptr,
                    .msg = ctx.msg,
                    .callback = ctx.cb,
                    .result = .{ .recv = bytes_read },
                });
            },

            .send => {
                const bytes_sent = posix.send(op.fd, op.buf, 0) catch |err| {
                    try ctx.cb(self, .{
                        .userdata = ctx.ptr,
                        .msg = ctx.msg,
                        .callback = ctx.cb,
                        .result = .{ .err = err },
                    });
                    return;
                };

                try ctx.cb(self, .{
                    .userdata = ctx.ptr,
                    .msg = ctx.msg,
                    .callback = ctx.cb,
                    .result = .{ .recv = bytes_sent },
                });
            },

            .socket, .close => unreachable,
        }
    }

    pub const RunMode = enum {
        until_done,
        once,
        forever,
    };
};
