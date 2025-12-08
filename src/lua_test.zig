//! Lua unit tests
//!
//! Runs Lua test files through ziglua to verify Lua utility functions.

const std = @import("std");
const ziglua = @import("zlua");

fn runLuaTest(lua: *ziglua.Lua, file: [:0]const u8) !void {
    lua.doFile(file) catch {
        const err_msg = lua.toString(-1) catch "(no error message)";
        std.debug.print("\nLua error: {s}\n", .{err_msg});
        return error.LuaTestFailed;
    };
}

test "lua utils" {
    const allocator = std.testing.allocator;

    var lua = try ziglua.Lua.init(allocator);
    defer lua.deinit();

    lua.openLibs();

    // Set up package.path to find our Lua modules
    _ = try lua.getGlobal("package");
    _ = lua.pushString("src/lua/?.lua");
    lua.setField(-2, "path");
    lua.pop(1);

    // Run the test file
    try runLuaTest(lua, "src/lua/test_utils.lua");
}
