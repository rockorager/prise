//! Entry point for the prise terminal multiplexer client.

const std = @import("std");
const builtin = @import("builtin");
const io = @import("io.zig");
const server = @import("server.zig");
const client = @import("client.zig");
const posix = std.posix;

const log = std.log.scoped(.main);

var log_file: ?std.fs.File = null;

pub const std_options: std.Options = .{
    .logFn = fileLogFn,
    .log_scope_levels = &.{
        .{ .scope = .page_list, .level = .warn },
    },
};

var log_buffer: [4096]u8 = undefined;

fn fileLogFn(
    comptime level: std.log.Level,
    comptime scope: @TypeOf(.enum_literal),
    comptime format: []const u8,
    args: anytype,
) void {
    const file = log_file orelse return;
    const scope_prefix = if (scope == .default) "" else "(" ++ @tagName(scope) ++ ") ";
    const prefix = "[" ++ comptime level.asText() ++ "] " ++ scope_prefix;
    const msg = std.fmt.bufPrint(&log_buffer, prefix ++ format ++ "\n", args) catch return;
    _ = file.write(msg) catch {};
}

const MAX_LOG_SIZE = 64 * 1024 * 1024; // 64 MiB

fn initLogFile(filename: []const u8) void {
    const home = posix.getenv("HOME") orelse return;
    var path_buf: [std.fs.max_path_bytes]u8 = undefined;
    const log_dir = std.fmt.bufPrint(&path_buf, "{s}/.cache/prise", .{home}) catch return;

    std.fs.makeDirAbsolute(log_dir) catch |err| switch (err) {
        error.PathAlreadyExists => {},
        else => return,
    };

    var file_path_buf: [std.fs.max_path_bytes]u8 = undefined;
    const log_path = std.fmt.bufPrint(&file_path_buf, "{s}/{s}", .{ log_dir, filename }) catch return;

    if (std.fs.openFileAbsolute(log_path, .{ .mode = .read_write })) |file| {
        const stat = file.stat() catch {
            file.close();
            return;
        };
        if (stat.size > MAX_LOG_SIZE) {
            file.setEndPos(0) catch {};
            file.seekTo(0) catch {};
        } else {
            file.seekFromEnd(0) catch {};
        }
        log_file = file;
    } else |_| {
        log_file = std.fs.createFileAbsolute(log_path, .{}) catch return;
    }
}

pub fn main() !void {
    var debug_allocator: std.heap.DebugAllocator(.{}) = .init;
    const allocator, const is_debug = gpa: {
        break :gpa switch (builtin.mode) {
            .Debug, .ReleaseSafe => .{ debug_allocator.allocator(), true },
            .ReleaseFast, .ReleaseSmall => .{ std.heap.smp_allocator, false },
        };
    };
    defer if (is_debug) {
        _ = debug_allocator.deinit();
    };

    const uid = posix.getuid();
    var socket_buffer: [256]u8 = undefined;
    const socket_path = try std.fmt.bufPrint(&socket_buffer, "/tmp/prise-{d}.sock", .{uid});

    const attach_session = try parseArgs(allocator, socket_path) orelse return;
    try runClient(allocator, socket_path, attach_session);
}

fn parseArgs(allocator: std.mem.Allocator, socket_path: []const u8) !?(?[]const u8) {
    var args = try std.process.argsWithAllocator(allocator);
    defer args.deinit();
    _ = args.skip();

    const cmd = args.next() orelse return @as(?[]const u8, null);

    if (std.mem.eql(u8, cmd, "serve")) {
        initLogFile("server.log");
        try server.startServer(allocator, socket_path);
        return null;
    } else if (std.mem.eql(u8, cmd, "session")) {
        return try handleSessionCommand(allocator, &args);
    } else if (std.mem.eql(u8, cmd, "pty")) {
        return try handlePtyCommand(&args);
    } else {
        log.err("Unknown command: {s}", .{cmd});
        log.err("Available commands: serve, session, pty", .{});
        return error.UnknownCommand;
    }
}

fn handleSessionCommand(allocator: std.mem.Allocator, args: *std.process.ArgIterator) !?(?[]const u8) {
    const subcmd = args.next() orelse {
        log.err("Missing session command. Available commands: attach, list", .{});
        return error.MissingCommand;
    };

    if (std.mem.eql(u8, subcmd, "attach")) {
        const session = args.next() orelse try findMostRecentSession(allocator);
        return @as(?[]const u8, session);
    } else if (std.mem.eql(u8, subcmd, "list")) {
        try listSessions(allocator);
        return null;
    } else {
        log.err("Unknown session command: {s}", .{subcmd});
        log.err("Available commands: attach, list", .{});
        return error.UnknownCommand;
    }
}

fn handlePtyCommand(args: *std.process.ArgIterator) !?(?[]const u8) {
    if (args.next()) |subcmd| {
        _ = subcmd;
        log.err("pty commands not yet implemented", .{});
        return error.NotImplemented;
    } else {
        log.err("Missing pty command. Available commands: spawn, capture, kill", .{});
        return error.MissingCommand;
    }
}

fn runClient(allocator: std.mem.Allocator, socket_path: []const u8, attach_session: ?[]const u8) !void {
    std.fs.accessAbsolute(socket_path, .{}) catch |err| {
        if (err == error.FileNotFound) {
            log.err("Server not running. Start it with: prise serve", .{});
            return error.ServerNotRunning;
        }
        return err;
    };

    initLogFile("client.log");
    log.info("Connecting to server at {s}", .{socket_path});

    var loop = try io.Loop.init(allocator);
    defer loop.deinit();

    var app = try client.App.init(allocator);
    defer app.deinit();

    app.socket_path = socket_path;
    app.attach_session = attach_session;

    var cwd_buf: [std.fs.max_path_bytes]u8 = undefined;
    app.initial_cwd = posix.getcwd(&cwd_buf) catch null;

    try app.setup(&loop);
    try loop.run(.until_done);

    if (app.state.connection_refused) {
        log.err("Connection refused. Server may have crashed. Start it with: prise serve", .{});
        posix.unlink(socket_path) catch {};
        return error.ConnectionRefused;
    }
}

fn getSessionsDir(allocator: std.mem.Allocator) !struct { dir: std.fs.Dir, path: []const u8 } {
    const home = std.posix.getenv("HOME") orelse return error.NoHomeDirectory;
    const sessions_dir = try std.fs.path.join(allocator, &.{ home, ".local", "state", "prise", "sessions" });

    const dir = std.fs.openDirAbsolute(sessions_dir, .{ .iterate = true }) catch |err| {
        allocator.free(sessions_dir);
        if (err == error.FileNotFound) {
            return error.NoSessionsFound;
        }
        return err;
    };

    return .{ .dir = dir, .path = sessions_dir };
}

fn listSessions(allocator: std.mem.Allocator) !void {
    var buf: [4096]u8 = undefined;
    var stdout = std.fs.File.stdout().writer(&buf);
    defer stdout.interface.flush() catch {};

    const result = getSessionsDir(allocator) catch |err| {
        if (err == error.NoSessionsFound) {
            try stdout.interface.print("No sessions found.\n", .{});
            return;
        }
        return err;
    };
    defer allocator.free(result.path);
    var dir = result.dir;
    defer dir.close();

    var count: usize = 0;

    var iter = dir.iterate();
    while (try iter.next()) |entry| {
        if (entry.kind != .file) continue;
        if (!std.mem.endsWith(u8, entry.name, ".json")) continue;

        const name_without_ext = entry.name[0 .. entry.name.len - 5];
        try stdout.interface.print("{s}\n", .{name_without_ext});
        count += 1;
    }

    if (count == 0) {
        try stdout.interface.print("No sessions found.\n", .{});
    }
}

fn findMostRecentSession(allocator: std.mem.Allocator) ![]const u8 {
    const result = getSessionsDir(allocator) catch |err| {
        if (err == error.NoSessionsFound) {
            log.err("No sessions directory found", .{});
        }
        return err;
    };
    defer allocator.free(result.path);
    var dir = result.dir;
    defer dir.close();

    var most_recent: ?[]const u8 = null;
    var most_recent_time: i128 = 0;

    var iter = dir.iterate();
    while (try iter.next()) |entry| {
        if (entry.kind != .file) continue;
        if (!std.mem.endsWith(u8, entry.name, ".json")) continue;

        const stat = dir.statFile(entry.name) catch continue;
        const mtime = stat.mtime;

        if (mtime > most_recent_time) {
            if (most_recent) |old| {
                allocator.free(old);
            }
            most_recent_time = mtime;
            const name_without_ext = entry.name[0 .. entry.name.len - 5];
            most_recent = try allocator.dupe(u8, name_without_ext);
        }
    }

    if (most_recent) |name| {
        log.info("Attaching to most recent session: {s}", .{name});
        return name;
    }

    log.err("No session files found", .{});
    return error.NoSessionsFound;
}

test {
    _ = @import("io/mock.zig");
    _ = @import("server.zig");
    _ = @import("msgpack.zig");
    _ = @import("rpc.zig");
    _ = @import("pty.zig");
    _ = @import("client.zig");
    _ = @import("redraw.zig");
    _ = @import("Surface.zig");
    _ = @import("widget.zig");
    _ = @import("TextInput.zig");
    _ = @import("key_encode.zig");
    _ = @import("mouse_encode.zig");
    _ = @import("vaxis_helper.zig");

    if (builtin.os.tag.isDarwin() or builtin.os.tag.isBSD()) {
        _ = @import("io/kqueue.zig");
    } else if (builtin.os.tag == .linux) {
        _ = @import("io/io_uring.zig");
    }
}
