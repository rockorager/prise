const std = @import("std");
const builtin = @import("builtin");
const posix = std.posix;

const backend = switch (builtin.os.tag) {
    .linux => @import("loop/io_uring.zig"),
    .macos => @import("loop/kqueue.zig"),
    else => @compileError("unsupported platform"),
};

pub const Loop = backend.Loop;

pub const Context = struct {
    ptr: ?*anyopaque = null,
    msg: u16 = 0,
    cb: *const fn (*Loop, Completion) anyerror!void,
};

pub const Completion = struct {
    userdata: ?*anyopaque,
    msg: u16,
    callback: *const fn (*Loop, Completion) anyerror!void,
    result: Result,

    pub fn userdataCast(self: Completion, comptime T: type) *T {
        return @ptrCast(@alignCast(self.userdata.?));
    }

    pub fn msgToEnum(self: Completion, comptime T: type) T {
        return @enumFromInt(self.msg);
    }
};

pub const Result = union(enum) {
    socket: posix.socket_t,
    connect: void,
    accept: posix.socket_t,
    recv: usize,
    send: usize,
    close: void,
    err: anyerror,
};

pub const Task = struct {
    id: usize,
    ctx: Context,

    pub fn cancel(self: *Task, loop: *Loop) !void {
        try loop.cancel(self.id);
    }
};
