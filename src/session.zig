//! Session management utilities.
//!
//! Provides shared helpers for session file operations used by both
//! the CLI (main.zig) and the client application (client.zig).

const std = @import("std");

pub const SessionsDir = struct {
    dir: std.fs.Dir,
    path: []const u8,

    pub fn deinit(self: *SessionsDir, allocator: std.mem.Allocator) void {
        self.dir.close();
        allocator.free(self.path);
    }
};

pub fn getSessionsDir(allocator: std.mem.Allocator) !SessionsDir {
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

pub fn getSessionNames(allocator: std.mem.Allocator) ![][]const u8 {
    var result = getSessionsDir(allocator) catch |err| {
        if (err == error.NoSessionsFound) {
            return allocator.alloc([]const u8, 0);
        }
        return err;
    };
    defer result.deinit(allocator);

    var sessions: std.ArrayListUnmanaged([]const u8) = .empty;
    errdefer {
        for (sessions.items) |s| {
            allocator.free(s);
        }
        sessions.deinit(allocator);
    }

    var iter = result.dir.iterate();
    while (try iter.next()) |entry| {
        if (entry.kind != .file) continue;
        if (!std.mem.endsWith(u8, entry.name, ".json")) continue;

        const name_without_ext = entry.name[0 .. entry.name.len - 5];
        try sessions.append(allocator, try allocator.dupe(u8, name_without_ext));
    }

    return sessions.toOwnedSlice(allocator);
}

pub fn freeSessionNames(allocator: std.mem.Allocator, names: [][]const u8) void {
    for (names) |name| {
        allocator.free(name);
    }
    allocator.free(names);
}
