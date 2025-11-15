const std = @import("std");
const posix = std.posix;
const linux = std.os.linux;
const root = @import("../loop.zig");

pub const Loop = struct {
    allocator: std.mem.Allocator,
    ring: linux.IoUring,
    next_id: usize = 1,
    pending: std.AutoHashMap(usize, PendingOp),

    const PendingOp = struct {
        ctx: root.Context,
        kind: OpKind,
        buf: []u8 = &.{},
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
        const ring = try linux.IoUring.init(256, 0);
        return .{
            .allocator = allocator,
            .ring = ring,
            .pending = std.AutoHashMap(usize, PendingOp).init(allocator),
        };
    }

    pub fn deinit(self: *Loop) void {
        self.pending.deinit();
        self.ring.deinit();
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

        try self.pending.put(id, .{
            .ctx = ctx,
            .kind = .socket,
        });

        const sqe = try self.ring.socket(@intCast(domain), socket_type, protocol, 0);
        sqe.user_data = id;

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

        try self.pending.put(id, .{
            .ctx = ctx,
            .kind = .connect,
        });

        const sqe = try self.ring.connect(@intCast(fd), addr, addr_len);
        sqe.user_data = id;

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
        });

        const sqe = try self.ring.accept(@intCast(fd), null, null, 0);
        sqe.user_data = id;

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
            .buf = buf,
        });

        const sqe = try self.ring.recv(@intCast(fd), .{ .buffer = buf }, 0);
        sqe.user_data = id;

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
            .buf = @constCast(buf),
        });

        const sqe = try self.ring.send(@intCast(fd), buf, 0);
        sqe.user_data = id;

        return root.Task{ .id = id, .ctx = ctx };
    }

    pub fn close(
        self: *Loop,
        fd: posix.socket_t,
        ctx: root.Context,
    ) !root.Task {
        const id = self.next_id;
        self.next_id += 1;

        try self.pending.put(id, .{
            .ctx = ctx,
            .kind = .close,
        });

        const sqe = try self.ring.close(@intCast(fd));
        sqe.user_data = id;

        return root.Task{ .id = id, .ctx = ctx };
    }

    pub fn cancel(self: *Loop, id: usize) !void {
        _ = self.pending.remove(id);
        // Submit cancel operation
        const sqe = try self.ring.get_sqe();
        sqe.prep_cancel(@intCast(id), 0);
    }

    pub fn run(self: *Loop, mode: RunMode) !void {
        var cqes: [32]linux.io_uring_cqe = undefined;

        while (true) {
            if (mode == .until_done and self.pending.count() == 0) break;

            _ = try self.ring.submit();

            const wait_nr: u32 = if (mode == .once) 0 else 1;
            const n = try self.ring.copy_cqes(&cqes, wait_nr);

            if (n == 0 and mode == .once) break;

            for (cqes[0..n]) |cqe| {
                const id: usize = @intCast(cqe.user_data);
                const op = self.pending.get(id) orelse continue;
                _ = self.pending.remove(id);

                try self.handleCompletion(op, cqe);
            }

            if (mode == .once) break;
        }
    }

    fn handleCompletion(self: *Loop, op: PendingOp, cqe: linux.io_uring_cqe) !void {
        const ctx = op.ctx;

        if (cqe.err() != .SUCCESS) {
            const err = switch (cqe.err()) {
                .CONNREFUSED => error.ConnectionRefused,
                .INPROGRESS => error.WouldBlock,
                .AGAIN => error.WouldBlock,
                else => error.IOError,
            };

            try ctx.cb(self, .{
                .userdata = ctx.ptr,
                .msg = ctx.msg,
                .callback = ctx.cb,
                .result = .{ .err = err },
            });
            return;
        }

        switch (op.kind) {
            .socket => {
                try ctx.cb(self, .{
                    .userdata = ctx.ptr,
                    .msg = ctx.msg,
                    .callback = ctx.cb,
                    .result = .{ .socket = @intCast(cqe.res) },
                });
            },

            .connect => {
                try ctx.cb(self, .{
                    .userdata = ctx.ptr,
                    .msg = ctx.msg,
                    .callback = ctx.cb,
                    .result = .{ .connect = {} },
                });
            },

            .accept => {
                try ctx.cb(self, .{
                    .userdata = ctx.ptr,
                    .msg = ctx.msg,
                    .callback = ctx.cb,
                    .result = .{ .accept = @intCast(cqe.res) },
                });
            },

            .recv => {
                try ctx.cb(self, .{
                    .userdata = ctx.ptr,
                    .msg = ctx.msg,
                    .callback = ctx.cb,
                    .result = .{ .recv = @intCast(cqe.res) },
                });
            },

            .send => {
                try ctx.cb(self, .{
                    .userdata = ctx.ptr,
                    .msg = ctx.msg,
                    .callback = ctx.cb,
                    .result = .{ .send = @intCast(cqe.res) },
                });
            },

            .close => {
                try ctx.cb(self, .{
                    .userdata = ctx.ptr,
                    .msg = ctx.msg,
                    .callback = ctx.cb,
                    .result = .{ .close = {} },
                });
            },
        }
    }

    pub const RunMode = enum {
        until_done,
        once,
        forever,
    };
};
