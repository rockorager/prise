const std = @import("std");
const io = @import("io.zig");
const server = @import("server.zig");
const client = @import("client.zig");
const posix = std.posix;

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    const uid = posix.getuid();
    var socket_buffer: [256]u8 = undefined;
    const socket_path = try std.fmt.bufPrint(&socket_buffer, "/tmp/prise-{d}.sock", .{uid});

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

    var app: client.App = .{ .allocator = allocator };

    _ = try client.connectUnixSocket(
        &loop,
        socket_path,
        .{ .ptr = &app, .cb = client.App.onConnected },
    );

    try loop.run(.until_done);

    if (app.connection_refused) {
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

            // Retry connection
            loop = try io.Loop.init(allocator);
            app = .{ .allocator = allocator };
            _ = try client.connectUnixSocket(
                &loop,
                socket_path,
                .{ .ptr = &app, .cb = client.App.onConnected },
            );
            try loop.run(.until_done);
        }
    }

    if (app.connected) {
        defer posix.close(app.fd);
        std.log.info("Connection successful!", .{});
        if (app.response_received) {
            if (app.pty_id) |pty_id| {
                std.log.info("Ready with PTY ID: {}", .{pty_id});
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
}
