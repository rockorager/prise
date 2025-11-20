const std = @import("std");
const builtin = @import("builtin");
const io = @import("io.zig");
const server = @import("server.zig");
const client = @import("client.zig");
const posix = std.posix;

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

    // Check for "serve" command
    var args = try std.process.argsWithAllocator(allocator);
    defer args.deinit();
    _ = args.skip(); // skip program name
    if (args.next()) |cmd| {
        if (std.mem.eql(u8, cmd, "serve")) {
            try server.startServer(allocator, socket_path);
            return;
        }
    }

    // Check if socket exists
    std.fs.accessAbsolute(socket_path, .{}) catch |err| {
        if (err == error.FileNotFound) {
            const pid = try posix.fork();
            if (pid == 0) {
                // Child process - daemonize
                _ = posix.setsid() catch |e| {
                    std.log.err("setsid failed: {}", .{e});
                    std.posix.exit(1);
                };

                // Fork again to prevent acquiring controlling terminal
                const pid2 = try posix.fork();
                if (pid2 != 0) {
                    // First child exits
                    std.posix.exit(0);
                }

                // Grandchild - actual server daemon
                // Close stdio and redirect stderr to log file
                posix.close(posix.STDIN_FILENO);
                posix.close(posix.STDOUT_FILENO);

                var log_buffer: [256]u8 = undefined;
                const log_path = try std.fmt.bufPrint(&log_buffer, "/tmp/prise-{d}.log", .{uid});
                const log_fd = try posix.open(log_path, .{ .ACCMODE = .WRONLY, .CREAT = true, .APPEND = true }, 0o644);
                try posix.dup2(log_fd, posix.STDERR_FILENO);
                posix.close(log_fd);

                // Start server
                try server.startServer(allocator, socket_path);
                return;
            } else {
                // Parent process - wait for socket to appear
                std.log.info("Forked server with PID {}", .{pid});
                var retries: u8 = 0;
                while (retries < 10) : (retries += 1) {
                    std.Thread.sleep(50 * std.time.ns_per_ms);
                    std.fs.accessAbsolute(socket_path, .{}) catch continue;
                    break;
                }
            }
        } else {
            return err;
        }
    };

    std.log.info("Connecting to server at {s}", .{socket_path});

    var loop = try io.Loop.init(allocator);
    defer loop.deinit();

    var app = try client.App.init(allocator);
    defer app.deinit();

    app.socket_path = socket_path;

    try app.setup(&loop);

    // Connection will be initiated after first winsize event from TTY

    try loop.run(.until_done);

    if (app.state.connection_refused) {
        // Stale socket - remove it and fork server
        std.log.info("Stale socket detected, removing and starting server", .{});
        posix.unlink(socket_path) catch {};

        const pid = try posix.fork();
        if (pid == 0) {
            // Child process - daemonize
            _ = posix.setsid() catch |e| {
                std.log.err("setsid failed: {}", .{e});
                std.posix.exit(1);
            };

            // Fork again to prevent acquiring controlling terminal
            const pid2 = try posix.fork();
            if (pid2 != 0) {
                // First child exits
                std.posix.exit(0);
            }

            // Grandchild - actual server daemon
            // Close stdio and redirect stderr to log file
            posix.close(posix.STDIN_FILENO);
            posix.close(posix.STDOUT_FILENO);

            var log_buffer: [256]u8 = undefined;
            const log_path = try std.fmt.bufPrint(&log_buffer, "/tmp/prise-{d}.log", .{uid});
            const log_fd = try posix.open(log_path, .{ .ACCMODE = .WRONLY, .CREAT = true, .APPEND = true }, 0o644);
            try posix.dup2(log_fd, posix.STDERR_FILENO);
            posix.close(log_fd);

            // Start server
            try server.startServer(allocator, socket_path);
            return;
        } else {
            // Parent process - wait for socket to appear then retry
            std.log.info("Forked server with PID {}", .{pid});
            var retries: u8 = 0;
            while (retries < 10) : (retries += 1) {
                std.Thread.sleep(50 * std.time.ns_per_ms);
                std.fs.accessAbsolute(socket_path, .{}) catch continue;
                break;
            }

            // Retry connection - reuse existing app/loop
            _ = try client.connectUnixSocket(
                &loop,
                socket_path,
                .{ .ptr = &app, .cb = client.App.onConnected },
            );
            try loop.run(.until_done);
        }
    }

    if (app.connected) {
        if (app.state.response_received) {
            if (app.state.pty_id) |pty_id| {
                std.log.info("Ready with PTY ID: {}", .{pty_id});
                // Keep connection alive to see terminal output
                std.log.info("Waiting for terminal output...", .{});
                std.Thread.sleep(4 * std.time.ns_per_s);
            }
        }
    }
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

    if (builtin.os.tag.isDarwin() or builtin.os.tag.isBSD()) {
        _ = @import("io/kqueue.zig");
    } else if (builtin.os.tag.isLinux()) {
        _ = @import("io/io_uring.zig");
    }
}
