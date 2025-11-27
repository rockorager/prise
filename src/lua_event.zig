const std = @import("std");
const ziglua = @import("zlua");
const vaxis = @import("vaxis");
const Surface = @import("Surface.zig");
const msgpack = @import("msgpack.zig");
const vaxis_helper = @import("vaxis_helper.zig");

pub const Event = union(enum) {
    vaxis: vaxis.Event,
    mouse: MouseEvent,
    split_resize: SplitResizeEvent,
    pty_attach: struct {
        id: u32,
        surface: *Surface,
        app: *anyopaque,
        send_key_fn: *const fn (app: *anyopaque, id: u32, key: KeyData) anyerror!void,
        send_mouse_fn: *const fn (app: *anyopaque, id: u32, mouse: MouseData) anyerror!void,
        close_fn: *const fn (app: *anyopaque, id: u32) anyerror!void,
    },
    pty_exited: struct {
        id: u32,
        status: u32,
    },
    init: void,
};

pub const SplitResizeEvent = struct {
    parent_id: ?u32,
    child_index: u16,
    ratio: f32,
};

pub const MouseEvent = struct {
    x: f64,
    y: f64,
    button: vaxis.Mouse.Button,
    action: vaxis.Mouse.Type,
    mods: vaxis.Mouse.Modifiers,
    target: ?u32, // PTY ID if hit, null otherwise
    target_x: ?f64, // x relative to target widget
    target_y: ?f64, // y relative to target widget
};

pub const KeyData = struct {
    key: []const u8, // W3C "key" - the produced character/text
    code: []const u8, // W3C "code" - the physical key name
    ctrl: bool,
    alt: bool,
    shift: bool,
    super: bool,
    release: bool = false,
};

pub const MouseData = struct {
    x: f64,
    y: f64,
    button: []const u8,
    event_type: []const u8,
    ctrl: bool,
    alt: bool,
    shift: bool,
};

pub fn registerMetatable(lua: *ziglua.Lua) !void {
    _ = try lua.newMetatable("PrisePty");
    // Metatable is at -1
    _ = lua.pushString("__index");
    lua.pushFunction(ziglua.wrap(ptyIndex));
    lua.setTable(-3);
    lua.pop(1);
}

pub fn pushEvent(lua: *ziglua.Lua, event: Event) !void {
    lua.createTable(0, 2);

    switch (event) {
        .init => {
            _ = lua.pushString("init");
            lua.setField(-2, "type");
        },
        .pty_attach => |info| {
            std.log.info("pushEvent: pty_attach id={}", .{info.id});
            _ = lua.pushString("pty_attach");
            lua.setField(-2, "type");

            lua.createTable(0, 1);

            const pty = lua.newUserdata(PtyHandle, @sizeOf(PtyHandle));
            pty.* = .{
                .id = info.id,
                .surface = info.surface,
                .app = info.app,
                .send_key_fn = info.send_key_fn,
                .send_mouse_fn = info.send_mouse_fn,
                .close_fn = info.close_fn,
            };

            _ = lua.getMetatableRegistry("PrisePty");
            lua.setMetatable(-2);

            lua.setField(-2, "pty");

            lua.setField(-2, "data");
            std.log.info("pushEvent: pty_attach done", .{});
        },

        .pty_exited => |info| {
            _ = lua.pushString("pty_exited");
            lua.setField(-2, "type");

            lua.createTable(0, 2);
            lua.pushInteger(@intCast(info.id));
            lua.setField(-2, "id");
            lua.pushInteger(@intCast(info.status));
            lua.setField(-2, "status");
            lua.setField(-2, "data");
        },

        .split_resize => |sr| {
            _ = lua.pushString("split_resize");
            lua.setField(-2, "type");

            lua.createTable(0, 3);

            if (sr.parent_id) |pid| {
                lua.pushInteger(@intCast(pid));
                lua.setField(-2, "parent_id");
            }

            lua.pushInteger(@intCast(sr.child_index));
            lua.setField(-2, "child_index");

            lua.pushNumber(@floatCast(sr.ratio));
            lua.setField(-2, "ratio");

            lua.setField(-2, "data");
        },

        .mouse => |m| {
            _ = lua.pushString("mouse");
            lua.setField(-2, "type");

            lua.createTable(0, 8);

            lua.pushNumber(m.x);
            lua.setField(-2, "x");

            lua.pushNumber(m.y);
            lua.setField(-2, "y");

            switch (m.button) {
                .left => _ = lua.pushString("left"),
                .middle => _ = lua.pushString("middle"),
                .right => _ = lua.pushString("right"),
                .wheel_up => _ = lua.pushString("wheel_up"),
                .wheel_down => _ = lua.pushString("wheel_down"),
                .wheel_left => _ = lua.pushString("wheel_left"),
                .wheel_right => _ = lua.pushString("wheel_right"),
                else => _ = lua.pushString("none"),
            }
            lua.setField(-2, "button");

            switch (m.action) {
                .press => _ = lua.pushString("press"),
                .release => _ = lua.pushString("release"),
                .motion => _ = lua.pushString("motion"),
                .drag => _ = lua.pushString("drag"),
            }
            lua.setField(-2, "action");

            lua.createTable(0, 3);
            lua.pushBoolean(m.mods.ctrl);
            lua.setField(-2, "ctrl");
            lua.pushBoolean(m.mods.alt);
            lua.setField(-2, "alt");
            lua.pushBoolean(m.mods.shift);
            lua.setField(-2, "shift");
            lua.setField(-2, "mods");

            if (m.target) |target| {
                lua.pushInteger(@intCast(target));
                lua.setField(-2, "target");

                if (m.target_x) |tx| {
                    lua.pushNumber(tx);
                    lua.setField(-2, "target_x");
                }
                if (m.target_y) |ty| {
                    lua.pushNumber(ty);
                    lua.setField(-2, "target_y");
                }
            }

            lua.setField(-2, "data");
        },

        .vaxis => |vaxis_event| switch (vaxis_event) {
            .key_press, .key_release => |key| {
                if (vaxis_event == .key_press) {
                    _ = lua.pushString("key_press");
                } else {
                    _ = lua.pushString("key_release");
                }
                lua.setField(-2, "type");

                lua.createTable(0, 6);

                var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
                defer arena.deinit();
                const key_strs = vaxis_helper.vaxisKeyToStrings(arena.allocator(), key) catch vaxis_helper.KeyStrings{ .key = "Unidentified", .code = "Unidentified" };

                _ = lua.pushString(key_strs.key);
                lua.setField(-2, "key");

                _ = lua.pushString(key_strs.code);
                lua.setField(-2, "code");

                lua.pushBoolean(key.mods.ctrl);
                lua.setField(-2, "ctrl");

                lua.pushBoolean(key.mods.alt);
                lua.setField(-2, "alt");

                lua.pushBoolean(key.mods.shift);
                lua.setField(-2, "shift");

                lua.pushBoolean(key.mods.super);
                lua.setField(-2, "super");

                lua.setField(-2, "data");
            },

            .winsize => |ws| {
                _ = lua.pushString("winsize");
                lua.setField(-2, "type");

                lua.createTable(0, 4);
                lua.pushInteger(@intCast(ws.rows));
                lua.setField(-2, "rows");
                lua.pushInteger(@intCast(ws.cols));
                lua.setField(-2, "cols");
                lua.pushInteger(@intCast(ws.x_pixel));
                lua.setField(-2, "width");
                lua.pushInteger(@intCast(ws.y_pixel));
                lua.setField(-2, "height");

                lua.setField(-2, "data");
            },

            .mouse => |mouse| {
                _ = lua.pushString("mouse");
                lua.setField(-2, "type");

                lua.createTable(0, 5);

                lua.pushInteger(@intCast(mouse.col));
                lua.setField(-2, "col");

                lua.pushInteger(@intCast(mouse.row));
                lua.setField(-2, "row");

                switch (mouse.button) {
                    .left => _ = lua.pushString("left"),
                    .middle => _ = lua.pushString("middle"),
                    .right => _ = lua.pushString("right"),
                    .wheel_up => _ = lua.pushString("wheel_up"),
                    .wheel_down => _ = lua.pushString("wheel_down"),
                    .wheel_left => _ = lua.pushString("wheel_left"),
                    .wheel_right => _ = lua.pushString("wheel_right"),
                    else => _ = lua.pushString("none"),
                }
                lua.setField(-2, "button");

                switch (mouse.type) {
                    .press => _ = lua.pushString("press"),
                    .release => _ = lua.pushString("release"),
                    .motion => _ = lua.pushString("motion"),
                    .drag => _ = lua.pushString("drag"),
                }
                lua.setField(-2, "event_type");

                lua.createTable(0, 3);
                lua.pushBoolean(mouse.mods.ctrl);
                lua.setField(-2, "ctrl");
                lua.pushBoolean(mouse.mods.alt);
                lua.setField(-2, "alt");
                lua.pushBoolean(mouse.mods.shift);
                lua.setField(-2, "shift");
                lua.setField(-2, "mods");

                lua.setField(-2, "data");
            },

            else => {
                _ = lua.pushString("unknown");
                lua.setField(-2, "type");
            },
        },
    }
}

const PtyHandle = struct {
    id: u32,
    surface: *Surface,
    app: *anyopaque,
    send_key_fn: *const fn (app: *anyopaque, id: u32, key: KeyData) anyerror!void,
    send_mouse_fn: *const fn (app: *anyopaque, id: u32, mouse: MouseData) anyerror!void,
    close_fn: *const fn (app: *anyopaque, id: u32) anyerror!void,
};

fn ptyIndex(lua: *ziglua.Lua) i32 {
    const key = lua.toString(2) catch return 0;
    if (std.mem.eql(u8, key, "title")) {
        lua.pushFunction(ziglua.wrap(ptyTitle));
        return 1;
    }
    if (std.mem.eql(u8, key, "id")) {
        lua.pushFunction(ziglua.wrap(ptyId));
        return 1;
    }
    if (std.mem.eql(u8, key, "send_key")) {
        lua.pushFunction(ziglua.wrap(ptySendKey));
        return 1;
    }
    if (std.mem.eql(u8, key, "send_mouse")) {
        lua.pushFunction(ziglua.wrap(ptySendMouse));
        return 1;
    }
    if (std.mem.eql(u8, key, "close")) {
        lua.pushFunction(ziglua.wrap(ptyClose));
        return 1;
    }
    if (std.mem.eql(u8, key, "size")) {
        lua.pushFunction(ziglua.wrap(ptySize));
        return 1;
    }
    return 0;
}

fn ptySize(lua: *ziglua.Lua) i32 {
    const pty = lua.checkUserdata(PtyHandle, 1, "PrisePty");
    lua.createTable(0, 2);
    lua.pushInteger(@intCast(pty.surface.rows));
    lua.setField(-2, "rows");
    lua.pushInteger(@intCast(pty.surface.cols));
    lua.setField(-2, "cols");
    return 1;
}

fn ptyTitle(lua: *ziglua.Lua) i32 {
    const pty = lua.checkUserdata(PtyHandle, 1, "PrisePty");
    const title = pty.surface.getTitle();
    _ = lua.pushString(title);
    return 1;
}

fn ptyId(lua: *ziglua.Lua) i32 {
    const pty = lua.checkUserdata(PtyHandle, 1, "PrisePty");
    lua.pushInteger(@intCast(pty.id));
    return 1;
}

fn ptySendKey(lua: *ziglua.Lua) i32 {
    const pty = lua.checkUserdata(PtyHandle, 1, "PrisePty");
    lua.checkType(2, .table);

    _ = lua.getField(2, "key");
    const key_str = lua.toString(-1) catch "";

    _ = lua.getField(2, "code");
    const code_str = lua.toString(-1) catch "";

    _ = lua.getField(2, "ctrl");
    const ctrl = lua.toBoolean(-1);

    _ = lua.getField(2, "alt");
    const alt = lua.toBoolean(-1);

    _ = lua.getField(2, "shift");
    const shift = lua.toBoolean(-1);

    _ = lua.getField(2, "super");
    const super = lua.toBoolean(-1);

    _ = lua.getField(2, "release");
    const release = lua.toBoolean(-1);

    const key = KeyData{
        .key = key_str,
        .code = code_str,
        .ctrl = ctrl,
        .alt = alt,
        .shift = shift,
        .super = super,
        .release = release,
    };

    pty.send_key_fn(pty.app, pty.id, key) catch |err| {
        // Clean up stack before error
        lua.pop(7);
        lua.raiseErrorStr("Failed to send key: %s", .{@errorName(err).ptr});
    };

    lua.pop(7);
    return 0;
}

fn ptySendMouse(lua: *ziglua.Lua) i32 {
    const pty = lua.checkUserdata(PtyHandle, 1, "PrisePty");
    lua.checkType(2, .table);

    _ = lua.getField(2, "x");
    const x = lua.toNumber(-1) catch 0;
    lua.pop(1);

    _ = lua.getField(2, "y");
    const y = lua.toNumber(-1) catch 0;
    lua.pop(1);

    _ = lua.getField(2, "button");
    const button = lua.toString(-1) catch "none";
    lua.pop(1);

    _ = lua.getField(2, "event_type");
    const event_type = lua.toString(-1) catch "press";
    lua.pop(1);

    _ = lua.getField(2, "mods");
    // Expecting a table or nil
    var ctrl = false;
    var alt = false;
    var shift = false;

    if (lua.typeOf(-1) == .table) {
        _ = lua.getField(-1, "ctrl");
        ctrl = lua.toBoolean(-1);
        lua.pop(1);
        _ = lua.getField(-1, "alt");
        alt = lua.toBoolean(-1);
        lua.pop(1);
        _ = lua.getField(-1, "shift");
        shift = lua.toBoolean(-1);
        lua.pop(1);
    }
    lua.pop(1); // Pop mods table

    const mouse = MouseData{
        .x = x,
        .y = y,
        .button = button,
        .event_type = event_type,
        .ctrl = ctrl,
        .alt = alt,
        .shift = shift,
    };

    pty.send_mouse_fn(pty.app, pty.id, mouse) catch |err| {
        lua.raiseErrorStr("Failed to send mouse: %s", .{@errorName(err).ptr});
    };
    return 0;
}

fn ptyClose(lua: *ziglua.Lua) i32 {
    const pty = lua.checkUserdata(PtyHandle, 1, "PrisePty");
    pty.close_fn(pty.app, pty.id) catch |err| {
        lua.raiseErrorStr("Failed to close pty: %s", .{@errorName(err).ptr});
    };
    return 0;
}

pub fn luaToMsgpack(lua: *ziglua.Lua, index: i32, allocator: std.mem.Allocator) !msgpack.Value {
    const type_ = lua.typeOf(index);
    switch (type_) {
        .nil => return .nil,
        .boolean => return .{ .boolean = lua.toBoolean(index) },
        .number => {
            if (lua.isInteger(index)) {
                return .{ .integer = try lua.toInteger(index) };
            } else {
                return .{ .float = try lua.toNumber(index) };
            }
        },
        .string => return .{ .string = try allocator.dupe(u8, lua.toString(index) catch "") },
        .table => {
            const len = lua.rawLen(index);
            if (len > 0) {
                var arr = try allocator.alloc(msgpack.Value, len);
                errdefer allocator.free(arr);
                var i: usize = 0;
                while (i < len) : (i += 1) {
                    _ = lua.rawGetIndex(index, @intCast(i + 1));
                    arr[i] = try luaToMsgpack(lua, -1, allocator);
                    lua.pop(1);
                }
                return .{ .array = arr };
            } else {
                var map_items = std.ArrayList(msgpack.Value.KeyValue).empty;
                errdefer map_items.deinit(allocator);

                const table_idx = if (index < 0) index - 1 else index;

                lua.pushNil();
                while (lua.next(table_idx)) {
                    const key = try luaToMsgpack(lua, -2, allocator);
                    const value = try luaToMsgpack(lua, -1, allocator);
                    try map_items.append(allocator, .{ .key = key, .value = value });
                    lua.pop(1);
                }
                return .{ .map = try map_items.toOwnedSlice(allocator) };
            }
        },
        else => return .nil,
    }
}

pub fn getPtyId(lua: *ziglua.Lua, index: i32) !u32 {
    if (lua.typeOf(index) == .number) {
        return @intCast(try lua.toInteger(index));
    }

    if (lua.isUserdata(index)) {
        lua.getMetatable(index) catch return error.InvalidPty;

        _ = lua.getMetatableRegistry("PrisePty");
        const equal = lua.compare(-1, -2, .eq);
        lua.pop(2);

        if (equal) {
            const pty = try lua.toUserdata(PtyHandle, index);
            return pty.id;
        }
    }

    return error.InvalidPty;
}

const TextInputHandle = struct {
    id: u32,
};

pub fn getTextInputId(lua: *ziglua.Lua, index: i32) !u32 {
    if (lua.typeOf(index) == .number) {
        return @intCast(try lua.toInteger(index));
    }

    if (lua.isUserdata(index)) {
        lua.getMetatable(index) catch return error.InvalidTextInput;

        _ = lua.getMetatableRegistry("PriseTextInput");
        const equal = lua.compare(-1, -2, .eq);
        lua.pop(2);

        if (equal) {
            const handle = try lua.toUserdata(TextInputHandle, index);
            return handle.id;
        }
    }

    return error.InvalidTextInput;
}

pub fn pushPtyUserdata(
    lua: *ziglua.Lua,
    id: u32,
    surface: *Surface,
    app: *anyopaque,
    send_key_fn: *const fn (app: *anyopaque, id: u32, key: KeyData) anyerror!void,
    send_mouse_fn: *const fn (app: *anyopaque, id: u32, mouse: MouseData) anyerror!void,
    close_fn: *const fn (app: *anyopaque, id: u32) anyerror!void,
) !void {
    const pty = lua.newUserdata(PtyHandle, @sizeOf(PtyHandle));
    pty.* = .{
        .id = id,
        .surface = surface,
        .app = app,
        .send_key_fn = send_key_fn,
        .send_mouse_fn = send_mouse_fn,
        .close_fn = close_fn,
    };

    _ = lua.getMetatableRegistry("PrisePty");
    lua.setMetatable(-2);
}
