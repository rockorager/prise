//! UI layout and widget tree management.

const std = @import("std");

const vaxis = @import("vaxis");
const ziglua = @import("zlua");

const io = @import("io.zig");
const lua_event = @import("lua_event.zig");
const msgpack = @import("msgpack.zig");
const Surface = @import("Surface.zig");
const TextInput = @import("TextInput.zig");
const widget = @import("widget.zig");

const log = std.log.scoped(.ui);
const logger = std.log.scoped(.lua);

const prise_module = @embedFile("lua/prise.lua");
const tiling_ui_module = @embedFile("lua/tiling.lua");
const fallback_init = "return require('prise').tiling()";

const TimerContext = struct {
    ui: *UI,
    timer_ref: i32,
};

const Timer = struct {
    ui: *UI,
    callback_ref: i32,
    task_id: usize,
    timer_ctx: ?*TimerContext,
    fired: bool,
};

fn timerCancel(lua: *ziglua.Lua) i32 {
    const timer = lua.checkUserdata(Timer, 1, "PriseTimer");
    if (timer.fired) return 0;

    if (timer.timer_ctx) |ctx| {
        if (timer.ui.loop) |loop| {
            loop.cancel(timer.task_id) catch {};
        }

        // Unref callback and timer
        timer.ui.lua.unref(ziglua.registry_index, timer.callback_ref);
        timer.ui.lua.unref(ziglua.registry_index, ctx.timer_ref);

        timer.ui.allocator.destroy(ctx);
        timer.timer_ctx = null;
    }

    timer.fired = true;
    return 0;
}

fn registerTimerMetatable(lua: *ziglua.Lua) void {
    lua.newMetatable("PriseTimer") catch return;
    _ = lua.pushString("__index");
    lua.createTable(0, 1);
    _ = lua.pushString("cancel");
    lua.pushFunction(ziglua.wrap(timerCancel));
    lua.setTable(-3);
    lua.setTable(-3);
    lua.pop(1);
}

pub const UI = struct {
    allocator: std.mem.Allocator,
    lua: *ziglua.Lua,
    loop: ?*io.Loop = null,
    exit_callback: ?*const fn (ctx: *anyopaque) void = null,
    exit_ctx: *anyopaque = undefined,
    spawn_callback: ?*const fn (ctx: *anyopaque, opts: SpawnOptions) anyerror!void = null,
    spawn_ctx: *anyopaque = undefined,
    redraw_callback: ?*const fn (ctx: *anyopaque) void = null,
    redraw_ctx: *anyopaque = undefined,
    detach_callback: ?*const fn (ctx: *anyopaque, session_name: []const u8) anyerror!void = null,
    detach_ctx: *anyopaque = undefined,
    save_callback: ?*const fn (ctx: *anyopaque) void = null,
    save_ctx: *anyopaque = undefined,
    get_session_name_callback: ?*const fn (ctx: *anyopaque) ?[]const u8 = null,
    get_session_name_ctx: *anyopaque = undefined,
    rename_session_callback: ?*const fn (ctx: *anyopaque, new_name: []const u8) anyerror!void = null,
    rename_session_ctx: *anyopaque = undefined,
    text_inputs: std.AutoHashMap(u32, *TextInput),
    next_text_input_id: u32 = 1,

    pub const SpawnOptions = struct {
        rows: u16,
        cols: u16,
        attach: bool,
        cwd: ?[]const u8 = null,
    };

    pub fn init(allocator: std.mem.Allocator) !UI {
        const lua = try ziglua.Lua.init(allocator);
        errdefer lua.deinit();

        lua.openLibs();

        // Add prise lua paths to package.path for runtime loading
        const home = std.posix.getenv("HOME") orelse return error.NoHomeDirectory;
        _ = try lua.getGlobal("package");
        _ = lua.getField(-1, "path");
        const current_path = lua.toString(-1) catch "";
        lua.pop(1);

        const extra_paths = try std.fmt.allocPrint(
            allocator,
            "{s}/.local/share/prise/lua/?.lua;/usr/local/share/prise/lua/?.lua;/usr/share/prise/lua/?.lua;{s}",
            .{ home, current_path },
        );
        defer allocator.free(extra_paths);
        _ = lua.pushString(extra_paths);
        lua.setField(-2, "path");
        lua.pop(1);

        // Register prise module loader (always use embedded for API stability)
        _ = try lua.getGlobal("package");
        _ = lua.getField(-1, "preload");
        lua.pushFunction(ziglua.wrap(loadPriseModule));
        lua.setField(-2, "prise");

        // Only register embedded tiling UI if not found on disk
        // (preload takes precedence over path, so we check explicitly)
        const tiling_on_disk = blk: {
            const user_path = try std.fs.path.join(allocator, &.{ home, ".local", "share", "prise", "lua", "prise_tiling_ui.lua" });
            defer allocator.free(user_path);
            const paths = [_][]const u8{
                user_path,
                "/usr/local/share/prise/lua/prise_tiling_ui.lua",
                "/usr/share/prise/lua/prise_tiling_ui.lua",
            };
            for (paths) |p| {
                std.fs.accessAbsolute(p, .{}) catch continue;
                break :blk true;
            }
            break :blk false;
        };
        if (!tiling_on_disk) {
            lua.pushFunction(ziglua.wrap(loadTilingUiModule));
            lua.setField(-2, "prise_tiling_ui");
        }
        lua.pop(2);

        // Try to load ~/.config/prise/init.lua
        const config_path = try std.fs.path.joinZ(allocator, &.{ home, ".config", "prise", "init.lua" });
        defer allocator.free(config_path);

        // If init.lua doesn't exist, use default UI
        const use_default = blk: {
            std.fs.accessAbsolute(config_path, .{}) catch {
                break :blk true;
            };
            break :blk false;
        };

        if (use_default) {
            lua.doString(fallback_init) catch {
                const msg = lua.toString(-1) catch "unknown error";
                log.err("Failed to load default UI: {s}", .{msg});
                return error.DefaultUIFailed;
            };
        } else {
            lua.doFile(config_path) catch {
                const msg = lua.toString(-1) catch "unknown error";
                log.err("Failed to load init.lua: {s}", .{msg});
                return error.InitLuaFailed;
            };
        }

        // init.lua should return a table with update and view functions
        if (lua.typeOf(-1) != .table) {
            return error.InitLuaMustReturnTable;
        }

        // Store the UI table in registry
        lua.setField(ziglua.registry_index, "prise_ui");

        // Initialize PrisePty metatable
        lua_event.registerMetatable(lua) catch |err| {
            log.err("Failed to register metatable: {}", .{err});
            return err;
        };

        // Initialize TextInput metatable
        registerTextInputMetatable(lua);

        return .{
            .allocator = allocator,
            .lua = lua,
            .text_inputs = std.AutoHashMap(u32, *TextInput).init(allocator),
        };
    }

    pub fn setLoop(self: *UI, loop: *io.Loop) void {
        self.loop = loop;
        // Store pointer to self in registry for static functions to use
        self.lua.pushLightUserdata(self);
        self.lua.setField(ziglua.registry_index, "prise_ui_ptr");
    }

    pub fn setExitCallback(self: *UI, ctx: *anyopaque, cb: *const fn (ctx: *anyopaque) void) void {
        self.exit_ctx = ctx;
        self.exit_callback = cb;
    }

    pub fn setSpawnCallback(self: *UI, ctx: *anyopaque, cb: *const fn (ctx: *anyopaque, opts: SpawnOptions) anyerror!void) void {
        self.spawn_ctx = ctx;
        self.spawn_callback = cb;
    }

    pub fn setRedrawCallback(self: *UI, ctx: *anyopaque, cb: *const fn (ctx: *anyopaque) void) void {
        self.redraw_ctx = ctx;
        self.redraw_callback = cb;
    }

    pub fn setDetachCallback(self: *UI, ctx: *anyopaque, cb: *const fn (ctx: *anyopaque, session_name: []const u8) anyerror!void) void {
        self.detach_ctx = ctx;
        self.detach_callback = cb;
    }

    pub fn setSaveCallback(self: *UI, ctx: *anyopaque, cb: *const fn (ctx: *anyopaque) void) void {
        self.save_ctx = ctx;
        self.save_callback = cb;
    }

    pub fn setGetSessionNameCallback(self: *UI, ctx: *anyopaque, cb: *const fn (ctx: *anyopaque) ?[]const u8) void {
        self.get_session_name_ctx = ctx;
        self.get_session_name_callback = cb;
    }

    pub fn setRenameSessionCallback(self: *UI, ctx: *anyopaque, cb: *const fn (ctx: *anyopaque, new_name: []const u8) anyerror!void) void {
        self.rename_session_ctx = ctx;
        self.rename_session_callback = cb;
    }

    pub fn getNextSessionName(self: *UI) ![]const u8 {
        const home = std.posix.getenv("HOME") orelse return self.allocator.dupe(u8, AMORY_NAMES[0]);

        const sessions_dir = try std.fs.path.join(self.allocator, &.{ home, ".local", "state", "prise", "sessions" });
        defer self.allocator.free(sessions_dir);

        var dir = std.fs.openDirAbsolute(sessions_dir, .{ .iterate = true }) catch {
            return self.allocator.dupe(u8, AMORY_NAMES[0]);
        };
        defer dir.close();

        var used = std.StringHashMap(void).init(self.allocator);
        defer {
            var key_iter = used.keyIterator();
            while (key_iter.next()) |key| {
                self.allocator.free(key.*);
            }
            used.deinit();
        }

        var iter = dir.iterate();
        while (try iter.next()) |entry| {
            if (entry.kind != .file) continue;
            const name = entry.name;
            if (!std.mem.endsWith(u8, name, ".json")) continue;
            const base = try self.allocator.dupe(u8, name[0 .. name.len - 5]);
            try used.put(base, {});
        }

        // Collect unused names and pick one randomly
        var unused_names: [AMORY_NAMES.len][]const u8 = undefined;
        var unused_count: usize = 0;
        for (AMORY_NAMES) |name| {
            if (!used.contains(name)) {
                unused_names[unused_count] = name;
                unused_count += 1;
            }
        }
        if (unused_count > 0) {
            var prng = std.Random.DefaultPrng.init(@bitCast(std.time.timestamp()));
            const idx = prng.random().uintLessThan(usize, unused_count);
            return self.allocator.dupe(u8, unused_names[idx]);
        }

        // All names used - try all names with suffix -2, then -3, etc.
        var prng = std.Random.DefaultPrng.init(@bitCast(std.time.timestamp()));
        var suffix: u32 = 2;
        var buf: [32]u8 = undefined;
        while (suffix < 1000) : (suffix += 1) {
            var unused_suffixed: [AMORY_NAMES.len][]const u8 = undefined;
            var suffixed_count: usize = 0;
            for (AMORY_NAMES) |name| {
                const suffixed = std.fmt.bufPrint(&buf, "{s}-{d}", .{ name, suffix }) catch continue;
                if (!used.contains(suffixed)) {
                    unused_suffixed[suffixed_count] = name;
                    suffixed_count += 1;
                }
            }
            if (suffixed_count > 0) {
                const idx = prng.random().uintLessThan(usize, suffixed_count);
                const chosen = std.fmt.bufPrint(&buf, "{s}-{d}", .{ unused_suffixed[idx], suffix }) catch break;
                return self.allocator.dupe(u8, chosen);
            }
        }

        return self.allocator.dupe(u8, AMORY_NAMES[0]);
    }

    fn loadTilingUiModule(lua: *ziglua.Lua) i32 {
        lua.doString(tiling_ui_module) catch {
            lua.pushNil();
            return 1;
        };
        return 1;
    }

    fn loadPriseModule(lua: *ziglua.Lua) i32 {
        lua.doString(prise_module) catch {
            lua.pushNil();
            return 1;
        };

        // Register set_timeout
        lua.pushFunction(ziglua.wrap(setTimeout));
        lua.setField(-2, "set_timeout");

        // Register exit (deletes session - for when last PTY exits)
        lua.pushFunction(ziglua.wrap(exit));
        lua.setField(-2, "exit");

        // Register spawn
        lua.pushFunction(ziglua.wrap(spawn));
        lua.setField(-2, "spawn");

        // Register request_frame
        lua.pushFunction(ziglua.wrap(requestFrame));
        lua.setField(-2, "request_frame");

        // Register detach
        lua.pushFunction(ziglua.wrap(detach));
        lua.setField(-2, "detach");

        // Register next_session_name
        lua.pushFunction(ziglua.wrap(nextSessionName));
        lua.setField(-2, "next_session_name");

        // Register save (triggers auto-save)
        lua.pushFunction(ziglua.wrap(save));
        lua.setField(-2, "save");

        // Register get_session_name
        lua.pushFunction(ziglua.wrap(getSessionName));
        lua.setField(-2, "get_session_name");

        // Register rename_session
        lua.pushFunction(ziglua.wrap(renameSession));
        lua.setField(-2, "rename_session");

        // Register create_text_input
        lua.pushFunction(ziglua.wrap(createTextInput));
        lua.setField(-2, "create_text_input");

        // Register log
        lua.createTable(0, 4);

        lua.pushFunction(ziglua.wrap(logDebug));
        lua.setField(-2, "debug");

        lua.pushFunction(ziglua.wrap(logInfo));
        lua.setField(-2, "info");

        lua.pushFunction(ziglua.wrap(logWarn));
        lua.setField(-2, "warn");

        lua.pushFunction(ziglua.wrap(logErr));
        lua.setField(-2, "err");
        lua.pushFunction(ziglua.wrap(logErr));
        lua.setField(-2, "error");

        lua.setField(-2, "log");

        // Register platform
        const platform = switch (@import("builtin").os.tag) {
            .macos => "macos",
            .linux => "linux",
            .windows => "windows",
            else => "unknown",
        };
        _ = lua.pushString(platform);
        lua.setField(-2, "platform");

        // Register gwidth
        lua.pushFunction(ziglua.wrap(gwidth));
        lua.setField(-2, "gwidth");

        registerTimerMetatable(lua);

        return 1;
    }

    fn spawn(lua: *ziglua.Lua) i32 {
        _ = lua.getField(ziglua.registry_index, "prise_ui_ptr");
        const ui = lua.toUserdata(UI, -1) catch {
            lua.pushNil();
            return 1;
        };
        lua.pop(1); // pop ui ptr

        if (ui.spawn_callback) |cb| {
            lua.checkType(1, .table);

            var opts: SpawnOptions = .{
                .rows = 24,
                .cols = 80,
                .attach = true,
            };

            _ = lua.getField(1, "rows");
            if (lua.isInteger(-1)) opts.rows = @intCast(lua.toInteger(-1) catch 24);
            lua.pop(1);

            _ = lua.getField(1, "cols");
            if (lua.isInteger(-1)) opts.cols = @intCast(lua.toInteger(-1) catch 80);
            lua.pop(1);

            _ = lua.getField(1, "attach");
            if (lua.isBoolean(-1)) opts.attach = lua.toBoolean(-1);
            lua.pop(1);

            _ = lua.getField(1, "cwd");
            if (lua.isString(-1)) opts.cwd = lua.toString(-1) catch null;
            lua.pop(1);

            cb(ui.spawn_ctx, opts) catch |err| {
                lua.raiseErrorStr("Failed to spawn: %s", .{@errorName(err).ptr});
            };
        } else {
            lua.raiseErrorStr("Spawn callback not configured", .{});
        }
        return 0;
    }

    fn requestFrame(lua: *ziglua.Lua) i32 {
        _ = lua.getField(ziglua.registry_index, "prise_ui_ptr");
        const ui = lua.toUserdata(UI, -1) catch {
            lua.pushNil();
            return 1;
        };
        lua.pop(1); // pop ui ptr

        if (ui.redraw_callback) |cb| {
            cb(ui.redraw_ctx);
        }
        return 0;
    }

    fn save(lua: *ziglua.Lua) i32 {
        _ = lua.getField(ziglua.registry_index, "prise_ui_ptr");
        const ui = lua.toUserdata(UI, -1) catch return 0;
        lua.pop(1);

        if (ui.save_callback) |cb| {
            cb(ui.save_ctx);
        }
        return 0;
    }

    fn getSessionName(lua: *ziglua.Lua) i32 {
        _ = lua.getField(ziglua.registry_index, "prise_ui_ptr");
        const ui = lua.toUserdata(UI, -1) catch {
            lua.pushNil();
            return 1;
        };
        lua.pop(1);

        if (ui.get_session_name_callback) |cb| {
            if (cb(ui.get_session_name_ctx)) |name| {
                _ = lua.pushString(name);
                return 1;
            }
        }
        lua.pushNil();
        return 1;
    }

    fn renameSession(lua: *ziglua.Lua) i32 {
        _ = lua.getField(ziglua.registry_index, "prise_ui_ptr");
        const ui = lua.toUserdata(UI, -1) catch {
            lua.pushBoolean(false);
            return 1;
        };
        lua.pop(1);

        const new_name = lua.toString(1) catch {
            lua.pushBoolean(false);
            return 1;
        };

        if (ui.rename_session_callback) |cb| {
            cb(ui.rename_session_ctx, new_name) catch |err| {
                lua.raiseErrorStr("Failed to rename session: %s", .{@errorName(err).ptr});
            };
            lua.pushBoolean(true);
        } else {
            lua.pushBoolean(false);
        }
        return 1;
    }

    fn detach(lua: *ziglua.Lua) i32 {
        _ = lua.getField(ziglua.registry_index, "prise_ui_ptr");
        const ui = lua.toUserdata(UI, -1) catch {
            lua.pushNil();
            return 1;
        };
        lua.pop(1);

        const session_name = lua.toString(1) catch "default";

        if (ui.detach_callback) |cb| {
            cb(ui.detach_ctx, session_name) catch |err| {
                lua.raiseErrorStr("Failed to detach: %s", .{@errorName(err).ptr});
            };
        } else {
            lua.raiseErrorStr("Detach callback not configured", .{});
        }
        return 0;
    }

    /// Amory Wars universe names for session generation
    const AMORY_NAMES = [_][]const u8{
        // Characters
        "ambellina",
        "inferno",
        "sirius",
        "cambria",
        "josephine",
        "newo",
        "ikkin",
        "apollo",
        "wilhelm",
        "jesse",
        "mayo",
        "meri",
        "chase",
        "mariah",
        "sizer",
        "ryder",
        "creature",
        "spider",
        "nostrand",
        "colten",
        "paranoia",
        "tenspeed",
        // Places
        "keywork",
        "saratoga",
        "kalline",
        "hetricus",
        "apity",
        "sentencer",
        "fence",
        "fiction",
        // Songs and concepts
        "velorium",
        "camper",
        "gravemakers",
        "crowing",
        "domino",
        "delirium",
        "willing",
        "feathers",
        "evagria",
        "afterman",
        "descension",
        "ascension",
        "neverender",
        "turbine",
        "monstar",
        "suffering",
        "bloodred",
        "gravity",
        "shoulders",
        "comatose",
        "liars",
        "embers",
        "ladders",
        "naianasha",
        "saudade",
        // Vaxis series
        "sonny",
        "candelaria",
        "yuko",
        "melvin",
        "shiloh",
        "continuum",
        "sunshine",
        "tethered",
        "allmother",
        "gutter",
        "pavilion",
        "walkers",
    };

    fn nextSessionName(lua: *ziglua.Lua) i32 {
        _ = lua.getField(ziglua.registry_index, "prise_ui_ptr");
        const ui = lua.toUserdata(UI, -1) catch {
            _ = lua.pushString(AMORY_NAMES[0]);
            return 1;
        };
        lua.pop(1);

        const name = ui.getNextSessionName() catch {
            _ = lua.pushString(AMORY_NAMES[0]);
            return 1;
        };
        defer ui.allocator.free(name);

        _ = lua.pushString(name);
        return 1;
    }

    fn logDebug(lua: *ziglua.Lua) i32 {
        const msg = lua.toString(1) catch "";
        logger.debug("{s}", .{msg});
        return 0;
    }

    fn logInfo(lua: *ziglua.Lua) i32 {
        const msg = lua.toString(1) catch "";
        logger.info("{s}", .{msg});
        return 0;
    }

    fn logWarn(lua: *ziglua.Lua) i32 {
        const msg = lua.toString(1) catch "";
        logger.warn("{s}", .{msg});
        return 0;
    }

    fn logErr(lua: *ziglua.Lua) i32 {
        const msg = lua.toString(1) catch "";
        logger.err("{s}", .{msg});
        return 0;
    }

    fn gwidth(lua: *ziglua.Lua) i32 {
        const str = lua.toString(1) catch "";
        const width = vaxis.gwidth.gwidth(str, .unicode);
        lua.pushInteger(@intCast(width));
        return 1;
    }

    fn setTimeout(lua: *ziglua.Lua) i32 {
        // Get UI ptr
        _ = lua.getField(ziglua.registry_index, "prise_ui_ptr");
        const ui = lua.toUserdata(UI, -1) catch {
            lua.pushNil();
            return 1;
        };
        lua.pop(1); // pop ui ptr

        if (ui.loop == null) {
            lua.raiseErrorStr("Event loop not configured in UI", .{});
        }

        const ms = lua.checkInteger(1);
        lua.checkType(2, .function);

        // Create reference to callback
        lua.pushValue(2);
        const callback_ref = lua.ref(ziglua.registry_index) catch {
            lua.raiseErrorStr("Failed to create reference", .{});
        };

        // Create Timer userdata
        const timer = lua.newUserdata(Timer, @sizeOf(Timer));
        timer.* = .{
            .ui = ui,
            .callback_ref = callback_ref,
            .task_id = 0, // set later
            .timer_ctx = null, // set later
            .fired = false,
        };

        // Set metatable
        _ = lua.getMetatableRegistry("PriseTimer");
        lua.setMetatable(-2);

        // Create reference to Timer userdata (it is at -1)
        lua.pushValue(-1);
        const timer_ref = lua.ref(ziglua.registry_index) catch {
            // Cleanup
            lua.unref(ziglua.registry_index, callback_ref);
            lua.raiseErrorStr("Failed to create timer ref", .{});
        };

        const ctx = ui.allocator.create(TimerContext) catch {
            lua.unref(ziglua.registry_index, callback_ref);
            lua.unref(ziglua.registry_index, timer_ref);
            lua.raiseErrorStr("Out of memory", .{});
        };
        ctx.* = .{ .ui = ui, .timer_ref = timer_ref };
        timer.timer_ctx = ctx;

        const ns = @as(u64, @intCast(ms)) * std.time.ns_per_ms;
        const task = ui.loop.?.timeout(ns, .{
            .ptr = ctx,
            .cb = onTimeout,
        }) catch {
            ui.allocator.destroy(ctx);
            lua.unref(ziglua.registry_index, callback_ref);
            lua.unref(ziglua.registry_index, timer_ref);
            lua.raiseErrorStr("Failed to schedule timeout", .{});
        };

        timer.task_id = task.id;

        return 1;
    }

    fn exit(lua: *ziglua.Lua) i32 {
        _ = lua.getField(ziglua.registry_index, "prise_ui_ptr");
        const ui = lua.toUserdata(UI, -1) catch {
            lua.pushNil();
            return 1;
        };
        lua.pop(1);

        if (ui.exit_callback) |cb| {
            cb(ui.exit_ctx);
        }
        return 0;
    }

    fn onTimeout(loop: *io.Loop, completion: io.Completion) !void {
        _ = loop;
        const ctx = completion.userdataCast(TimerContext);

        // Get Timer userdata
        _ = ctx.ui.lua.rawGetIndex(ziglua.registry_index, ctx.timer_ref);
        const timer = ctx.ui.lua.toUserdata(Timer, -1) catch unreachable;
        ctx.ui.lua.pop(1);

        timer.fired = true;
        timer.timer_ctx = null;

        // Get callback
        _ = ctx.ui.lua.rawGetIndex(ziglua.registry_index, timer.callback_ref);
        ctx.ui.lua.protectedCall(.{ .args = 0, .results = 0, .msg_handler = 0 }) catch {
            const err = ctx.ui.lua.toString(-1) catch "Unknown error";
            log.err("Lua timeout callback error: {s}", .{err});
            ctx.ui.lua.pop(1);
        };

        // Cleanup
        ctx.ui.lua.unref(ziglua.registry_index, timer.callback_ref);
        ctx.ui.lua.unref(ziglua.registry_index, ctx.timer_ref);
        ctx.ui.allocator.destroy(ctx);
    }

    pub fn deinit(self: *UI) void {
        var it = self.text_inputs.iterator();
        while (it.next()) |entry| {
            entry.value_ptr.*.deinit();
            self.allocator.destroy(entry.value_ptr.*);
        }
        self.text_inputs.deinit();
        self.lua.deinit();
    }

    pub fn update(self: *UI, event: lua_event.Event) !void {
        _ = self.lua.getField(ziglua.registry_index, "prise_ui");
        defer self.lua.pop(1);

        _ = self.lua.getField(-1, "update");
        if (self.lua.typeOf(-1) != .function) {
            return error.NoUpdateFunction;
        }

        try lua_event.pushEvent(self.lua, event);

        self.lua.protectedCall(.{ .args = 1, .results = 0, .msg_handler = 0 }) catch |err| {
            const msg = self.lua.toString(-1) catch "Unknown Lua error";
            log.err("Lua update error: {s}", .{msg});
            self.lua.pop(1); // pop error message
            return err;
        };
    }

    pub fn view(self: *UI) !widget.Widget {
        _ = self.lua.getField(ziglua.registry_index, "prise_ui");
        defer self.lua.pop(1);

        _ = self.lua.getField(-1, "view");
        if (self.lua.typeOf(-1) != .function) {
            return error.NoViewFunction;
        }

        self.lua.call(.{ .args = 0, .results = 1 });
        defer self.lua.pop(1);

        return widget.parseWidget(self.lua, self.allocator, -1);
    }

    pub const CwdLookupFn = *const fn (ctx: *anyopaque, id: i64) ?[]const u8;

    pub fn getStateJson(self: *UI, cwd_lookup_fn: ?CwdLookupFn, cwd_lookup_ctx: *anyopaque) ![]u8 {
        _ = self.lua.getField(ziglua.registry_index, "prise_ui");
        defer self.lua.pop(1);

        _ = self.lua.getField(-1, "get_state");
        if (self.lua.typeOf(-1) != .function) {
            return error.NoGetStateFunction;
        }

        const LookupCtx = struct {
            ctx: *anyopaque,
            lookup_fn: CwdLookupFn,
        };

        // Create cwd_lookup closure if provided
        var lookup_ctx: ?*LookupCtx = null;
        if (cwd_lookup_fn != null) {
            lookup_ctx = try self.allocator.create(LookupCtx);
            lookup_ctx.?.* = .{ .ctx = cwd_lookup_ctx, .lookup_fn = cwd_lookup_fn.? };

            self.lua.pushLightUserdata(lookup_ctx.?);
            self.lua.pushClosure(ziglua.wrap(cwdLookupWrapper), 1);
        } else {
            self.lua.pushNil();
        }
        defer if (lookup_ctx) |ctx| self.allocator.destroy(ctx);

        self.lua.protectedCall(.{ .args = 1, .results = 1, .msg_handler = 0 }) catch |err| {
            const msg = self.lua.toString(-1) catch "Unknown Lua error";
            log.err("Lua get_state error: {s}", .{msg});
            self.lua.pop(1);
            return err;
        };
        defer self.lua.pop(1);

        return luaTableToJson(self.lua, self.allocator, -1);
    }

    pub const PtyLookupResult = struct {
        surface: *Surface,
        app: *anyopaque,
        send_key_fn: *const fn (app: *anyopaque, id: u32, key: lua_event.KeyData) anyerror!void,
        send_mouse_fn: *const fn (app: *anyopaque, id: u32, mouse: lua_event.MouseData) anyerror!void,
        send_paste_fn: *const fn (app: *anyopaque, id: u32, data: []const u8) anyerror!void,
        set_focus_fn: *const fn (app: *anyopaque, id: u32, focused: bool) anyerror!void,
        close_fn: *const fn (app: *anyopaque, id: u32) anyerror!void,
        cwd_fn: *const fn (app: *anyopaque, id: u32) ?[]const u8,
        copy_selection_fn: *const fn (app: *anyopaque, id: u32) anyerror!void,
    };

    pub const PtyLookupFn = *const fn (ctx: *anyopaque, id: u32) ?PtyLookupResult;

    pub fn setStateFromJson(self: *UI, json: []const u8, pty_lookup_fn: PtyLookupFn, pty_lookup_ctx: *anyopaque) !void {
        _ = self.lua.getField(ziglua.registry_index, "prise_ui");
        defer self.lua.pop(1);

        _ = self.lua.getField(-1, "set_state");
        if (self.lua.typeOf(-1) != .function) {
            return error.NoSetStateFunction;
        }

        try jsonToLuaTable(self.lua, self.allocator, json);

        // Create pty_lookup closure with context
        const LookupCtx = struct {
            ctx: *anyopaque,
            lookup_fn: PtyLookupFn,
        };
        const lookup_ctx = try self.allocator.create(LookupCtx);
        lookup_ctx.* = .{ .ctx = pty_lookup_ctx, .lookup_fn = pty_lookup_fn };

        self.lua.pushLightUserdata(lookup_ctx);
        self.lua.pushClosure(ziglua.wrap(ptyLookupWrapper), 1);

        self.lua.protectedCall(.{ .args = 2, .results = 0, .msg_handler = 0 }) catch |err| {
            const msg = self.lua.toString(-1) catch "Unknown Lua error";
            log.err("Lua set_state error: {s}", .{msg});
            self.lua.pop(1);
            self.allocator.destroy(lookup_ctx);
            return err;
        };

        self.allocator.destroy(lookup_ctx);
    }

    fn ptyLookupWrapper(lua: *ziglua.Lua) i32 {
        const LookupCtx = struct {
            ctx: *anyopaque,
            lookup_fn: PtyLookupFn,
        };
        const lookup_ctx = lua.toUserdata(LookupCtx, ziglua.Lua.upvalueIndex(1)) catch return 0;

        const id: u32 = @intCast(lua.checkInteger(1));
        const result = lookup_ctx.lookup_fn(lookup_ctx.ctx, id);

        if (result) |r| {
            lua_event.pushPtyUserdata(lua, id, r.surface, r.app, r.send_key_fn, r.send_mouse_fn, r.send_paste_fn, r.set_focus_fn, r.close_fn, r.cwd_fn, r.copy_selection_fn) catch {
                lua.pushNil();
            };
        } else {
            lua.pushNil();
        }
        return 1;
    }

    fn cwdLookupWrapper(lua: *ziglua.Lua) i32 {
        const LookupCtx = struct {
            ctx: *anyopaque,
            lookup_fn: CwdLookupFn,
        };
        const lookup_ctx = lua.toUserdata(LookupCtx, ziglua.Lua.upvalueIndex(1)) catch return 0;

        const id: i64 = lua.checkInteger(1);
        const cwd = lookup_ctx.lookup_fn(lookup_ctx.ctx, id);

        if (cwd) |c| {
            _ = lua.pushString(c);
        } else {
            lua.pushNil();
        }
        return 1;
    }
};

fn luaTableToJson(lua: *ziglua.Lua, allocator: std.mem.Allocator, index: i32) ![]u8 {
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();

    const value = try luaToJsonValue(lua, arena.allocator(), index);

    var list: std.ArrayList(u8) = .empty;
    errdefer list.deinit(allocator);

    try list.writer(allocator).print("{f}", .{std.json.fmt(value, .{ .whitespace = .indent_2 })});
    return list.toOwnedSlice(allocator);
}

fn luaToJsonValue(lua: *ziglua.Lua, allocator: std.mem.Allocator, index: i32) !std.json.Value {
    const abs_index = if (index < 0) @as(i32, @intCast(lua.getTop())) + index + 1 else index;

    return switch (lua.typeOf(abs_index)) {
        .nil => .null,
        .boolean => .{ .bool = lua.toBoolean(abs_index) },
        .number => blk: {
            if (lua.isInteger(abs_index)) {
                break :blk .{ .integer = lua.toInteger(abs_index) catch 0 };
            } else {
                break :blk .{ .float = lua.toNumber(abs_index) catch 0 };
            }
        },
        .string => .{ .string = try allocator.dupe(u8, lua.toString(abs_index) catch "") },
        .table => blk: {
            // Check if array or object by looking for integer keys starting at 1
            var is_array = true;
            var max_index: i64 = 0;

            lua.pushNil();
            while (lua.next(abs_index)) {
                lua.pop(1); // pop value, keep key
                if (lua.typeOf(-1) == .number and lua.isInteger(-1)) {
                    const key = lua.toInteger(-1) catch 0;
                    if (key > 0) {
                        if (key > max_index) max_index = key;
                    } else {
                        is_array = false;
                        lua.pop(1);
                        break;
                    }
                } else {
                    is_array = false;
                    lua.pop(1);
                    break;
                }
            }

            if (is_array and max_index > 0) {
                var arr = std.json.Array.init(allocator);
                errdefer arr.deinit();

                for (1..@intCast(max_index + 1)) |i| {
                    _ = lua.rawGetIndex(abs_index, @intCast(i));
                    const val = try luaToJsonValue(lua, allocator, -1);
                    lua.pop(1);
                    try arr.append(val);
                }
                break :blk .{ .array = arr };
            } else {
                var obj = std.json.ObjectMap.init(allocator);
                errdefer obj.deinit();

                lua.pushNil();
                while (lua.next(abs_index)) {
                    const val = try luaToJsonValue(lua, allocator, -1);
                    lua.pop(1);

                    const key = lua.toString(-1) catch {
                        continue;
                    };
                    const key_owned = try allocator.dupe(u8, key);
                    try obj.put(key_owned, val);
                }
                break :blk .{ .object = obj };
            }
        },
        else => .null,
    };
}

fn jsonToLuaTable(lua: *ziglua.Lua, allocator: std.mem.Allocator, json: []const u8) !void {
    const parsed = try std.json.parseFromSlice(std.json.Value, allocator, json, .{});
    defer parsed.deinit();

    try pushJsonValue(lua, parsed.value);
}

fn pushJsonValue(lua: *ziglua.Lua, value: std.json.Value) !void {
    switch (value) {
        .null => lua.pushNil(),
        .bool => |b| lua.pushBoolean(b),
        .integer => |i| lua.pushInteger(i),
        .float => |f| lua.pushNumber(f),
        .string => |s| _ = lua.pushString(s),
        .array => |arr| {
            lua.createTable(@intCast(arr.items.len), 0);
            for (arr.items, 1..) |item, i| {
                try pushJsonValue(lua, item);
                lua.rawSetIndex(-2, @intCast(i));
            }
        },
        .object => |obj| {
            lua.createTable(0, @intCast(obj.count()));
            var it = obj.iterator();
            while (it.next()) |entry| {
                _ = lua.pushString(entry.key_ptr.*);
                try pushJsonValue(lua, entry.value_ptr.*);
                lua.setTable(-3);
            }
        },
        .number_string => |s| _ = lua.pushString(s),
    }
}

const TextInputHandle = struct {
    id: u32,
};

fn registerTextInputMetatable(lua: *ziglua.Lua) void {
    lua.newMetatable("PriseTextInput") catch return;
    _ = lua.pushString("__index");
    lua.pushFunction(ziglua.wrap(textInputIndex));
    lua.setTable(-3);
    lua.pop(1);
}

fn textInputIndex(lua: *ziglua.Lua) i32 {
    const key = lua.toString(2) catch return 0;

    if (std.mem.eql(u8, key, "id")) {
        lua.pushFunction(ziglua.wrap(textInputId));
        return 1;
    }
    if (std.mem.eql(u8, key, "text")) {
        lua.pushFunction(ziglua.wrap(textInputText));
        return 1;
    }
    if (std.mem.eql(u8, key, "insert")) {
        lua.pushFunction(ziglua.wrap(textInputInsert));
        return 1;
    }
    if (std.mem.eql(u8, key, "delete_backward")) {
        lua.pushFunction(ziglua.wrap(textInputDeleteBackward));
        return 1;
    }
    if (std.mem.eql(u8, key, "delete_forward")) {
        lua.pushFunction(ziglua.wrap(textInputDeleteForward));
        return 1;
    }
    if (std.mem.eql(u8, key, "move_left")) {
        lua.pushFunction(ziglua.wrap(textInputMoveLeft));
        return 1;
    }
    if (std.mem.eql(u8, key, "move_right")) {
        lua.pushFunction(ziglua.wrap(textInputMoveRight));
        return 1;
    }
    if (std.mem.eql(u8, key, "move_to_start")) {
        lua.pushFunction(ziglua.wrap(textInputMoveToStart));
        return 1;
    }
    if (std.mem.eql(u8, key, "move_to_end")) {
        lua.pushFunction(ziglua.wrap(textInputMoveToEnd));
        return 1;
    }
    if (std.mem.eql(u8, key, "clear")) {
        lua.pushFunction(ziglua.wrap(textInputClear));
        return 1;
    }
    if (std.mem.eql(u8, key, "destroy")) {
        lua.pushFunction(ziglua.wrap(textInputDestroy));
        return 1;
    }
    return 0;
}

fn getTextInput(lua: *ziglua.Lua) ?*TextInput {
    const handle = lua.checkUserdata(TextInputHandle, 1, "PriseTextInput");
    _ = lua.getField(ziglua.registry_index, "prise_ui_ptr");
    const ui = lua.toUserdata(UI, -1) catch return null;
    lua.pop(1);
    return ui.text_inputs.get(handle.id);
}

fn textInputId(lua: *ziglua.Lua) i32 {
    const handle = lua.checkUserdata(TextInputHandle, 1, "PriseTextInput");
    lua.pushInteger(@intCast(handle.id));
    return 1;
}

fn textInputText(lua: *ziglua.Lua) i32 {
    const input = getTextInput(lua) orelse {
        lua.pushNil();
        return 1;
    };
    _ = lua.pushString(input.text());
    return 1;
}

fn textInputInsert(lua: *ziglua.Lua) i32 {
    const input = getTextInput(lua) orelse return 0;
    const str = lua.toString(2) catch return 0;
    input.insertSlice(str) catch return 0;
    return 0;
}

fn textInputDeleteBackward(lua: *ziglua.Lua) i32 {
    const input = getTextInput(lua) orelse return 0;
    input.deleteBackward();
    return 0;
}

fn textInputDeleteForward(lua: *ziglua.Lua) i32 {
    const input = getTextInput(lua) orelse return 0;
    input.deleteForward();
    return 0;
}

fn textInputMoveLeft(lua: *ziglua.Lua) i32 {
    const input = getTextInput(lua) orelse return 0;
    input.moveLeft();
    return 0;
}

fn textInputMoveRight(lua: *ziglua.Lua) i32 {
    const input = getTextInput(lua) orelse return 0;
    input.moveRight();
    return 0;
}

fn textInputMoveToStart(lua: *ziglua.Lua) i32 {
    const input = getTextInput(lua) orelse return 0;
    input.moveToStart();
    return 0;
}

fn textInputMoveToEnd(lua: *ziglua.Lua) i32 {
    const input = getTextInput(lua) orelse return 0;
    input.moveToEnd();
    return 0;
}

fn textInputClear(lua: *ziglua.Lua) i32 {
    const input = getTextInput(lua) orelse return 0;
    input.clear();
    return 0;
}

fn textInputDestroy(lua: *ziglua.Lua) i32 {
    const handle = lua.checkUserdata(TextInputHandle, 1, "PriseTextInput");
    _ = lua.getField(ziglua.registry_index, "prise_ui_ptr");
    const ui = lua.toUserdata(UI, -1) catch return 0;
    lua.pop(1);

    if (ui.text_inputs.fetchRemove(handle.id)) |entry| {
        entry.value.deinit();
        ui.allocator.destroy(entry.value);
    }
    return 0;
}

fn createTextInput(lua: *ziglua.Lua) i32 {
    _ = lua.getField(ziglua.registry_index, "prise_ui_ptr");
    const ui = lua.toUserdata(UI, -1) catch {
        lua.pushNil();
        return 1;
    };
    lua.pop(1);

    const input = ui.allocator.create(TextInput) catch {
        lua.pushNil();
        return 1;
    };
    input.* = TextInput.init(ui.allocator);

    const id = ui.next_text_input_id;
    ui.next_text_input_id += 1;

    ui.text_inputs.put(id, input) catch {
        input.deinit();
        ui.allocator.destroy(input);
        lua.pushNil();
        return 1;
    };

    const handle = lua.newUserdata(TextInputHandle, @sizeOf(TextInputHandle));
    handle.* = .{ .id = id };

    _ = lua.getMetatableRegistry("PriseTextInput");
    lua.setMetatable(-2);

    return 1;
}
