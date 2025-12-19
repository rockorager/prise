//! YAML-driven startup layouts for new sessions.
//!
//! mvp scope:
//! - layout selection priority: --layout > local .prise.yml > global layout.yml > built-in default
//! - sequential pane splits per window (tab)

const std = @import("std");
const yaml = @import("yaml");

pub const Split = enum {
    horizontal,
    vertical,
};

pub const Pane = struct {
    title: ?[]const u8 = null,
    cmd: ?[]const u8 = null,
    split: ?Split = null,
};

pub const Window = struct {
    name: ?[]const u8 = null,
    panes: []const Pane,
};

pub const Plan = struct {
    windows: []const Window,
};

pub const Options = struct {
    cwd: []const u8,
    layout_name: ?[]const u8 = null,
};

pub fn selectPlan(allocator: std.mem.Allocator, opts: Options) !Plan {
    if (opts.layout_name) |name| {
        if (try findByNameInFiles(allocator, opts.cwd, name)) |plan| return plan;
        if (builtinPlan(name)) |plan| return plan;
        return error.UnknownLayout;
    }

    if (try findDefaultInFiles(allocator, opts.cwd)) |plan| return plan;
    return builtinPlan("default") orelse unreachable;
}

fn builtinPlan(name: []const u8) ?Plan {
    if (std.mem.eql(u8, name, "default")) {
        return .{ .windows = &.{.{ .name = null, .panes = &.{.{}} }} };
    }
    if (std.mem.eql(u8, name, "horizontal-split")) {
        return .{ .windows = &.{.{ .name = "horizontal-split", .panes = &.{ .{}, .{ .split = .horizontal } } }} };
    }
    if (std.mem.eql(u8, name, "vertical-split")) {
        return .{ .windows = &.{.{ .name = "vertical-split", .panes = &.{ .{}, .{ .split = .vertical } } }} };
    }
    if (std.mem.eql(u8, name, "dev")) {
        return .{ .windows = &.{.{ .name = "dev", .panes = &.{ .{}, .{ .split = .horizontal }, .{ .split = .vertical } } }} };
    }
    return null;
}

fn findByNameInFiles(allocator: std.mem.Allocator, cwd: []const u8, name: []const u8) !?Plan {
    if (try loadLocalYaml(allocator, cwd)) |yml_val| {
        var yml = yml_val;
        defer yml.deinit(allocator);
        if (try planFromYamlByName(allocator, cwd, &yml, name)) |plan| return plan;
    }
    if (try loadGlobalYaml(allocator)) |yml_val| {
        var yml = yml_val;
        defer yml.deinit(allocator);
        if (try planFromYamlByName(allocator, cwd, &yml, name)) |plan| return plan;
    }
    return null;
}

fn findDefaultInFiles(allocator: std.mem.Allocator, cwd: []const u8) !?Plan {
    if (try loadLocalYaml(allocator, cwd)) |yml_val| {
        var yml = yml_val;
        defer yml.deinit(allocator);
        if (try planFromYamlDefault(allocator, cwd, &yml)) |plan| return plan;
    }
    if (try loadGlobalYaml(allocator)) |yml_val| {
        var yml = yml_val;
        defer yml.deinit(allocator);
        if (try planFromYamlDefault(allocator, cwd, &yml)) |plan| return plan;
    }
    return null;
}

fn loadGlobalYaml(allocator: std.mem.Allocator) !?yaml.Yaml {
    const home = std.posix.getenv("HOME") orelse return null;
    const path = try std.fs.path.join(allocator, &.{ home, ".config", "prise", "layout.yml" });
    if (!fileExistsAbsolute(path)) return null;
    return try loadYamlAtPath(allocator, path);
}

fn loadLocalYaml(allocator: std.mem.Allocator, cwd: []const u8) !?yaml.Yaml {
    const path = (try findLocalConfigPath(allocator, cwd)) orelse return null;
    return try loadYamlAtPath(allocator, path);
}

fn loadYamlAtPath(allocator: std.mem.Allocator, path: []const u8) !yaml.Yaml {
    const file = try std.fs.openFileAbsolute(path, .{});
    defer file.close();

    const source = try file.readToEndAlloc(allocator, 1024 * 1024);

    var yml: yaml.Yaml = .{ .source = source };
    errdefer yml.deinit(allocator);

    yml.load(allocator) catch |err| switch (err) {
        error.ParseFailure => {
            if (yml.parse_errors.errorMessageCount() > 0) {
                yml.parse_errors.renderToStdErr(.{ .ttyconf = std.io.tty.detectConfig(std.fs.File.stderr()) });
            }
            return err;
        },
        else => return err,
    };

    return yml;
}

fn rootMap(yml: *const yaml.Yaml) !yaml.Yaml.Map {
    if (yml.docs.items.len != 1) return error.InvalidLayout;
    return yml.docs.items[0].asMap() orelse return error.InvalidLayout;
}

fn planFromYamlDefault(allocator: std.mem.Allocator, cwd: []const u8, yml: *const yaml.Yaml) !?Plan {
    const map = try rootMap(yml);

    if (map.get("layout")) |layout_val| {
        const layout_map = layout_val.asMap() orelse return error.InvalidLayout;
        return try planFromLayoutMap(allocator, cwd, layout_map);
    }

    const layouts_val = map.get("layouts") orelse return null;
    const layouts_list = layouts_val.asList() orelse return error.InvalidLayout;
    if (layouts_list.len == 0) return null;

    const default_name_val = map.get("default_layout") orelse map.get("default-layout");

    if (default_name_val) |v| {
        const name = v.asScalar() orelse return error.InvalidLayout;
        return (try findLayoutInList(allocator, cwd, layouts_list, name)) orelse return error.UnknownLayout;
    }

    if (layouts_list.len == 1) {
        const one_map = layouts_list[0].asMap() orelse return error.InvalidLayout;
        return try planFromLayoutMap(allocator, cwd, one_map);
    }

    for (layouts_list) |item| {
        const lm = item.asMap() orelse return error.InvalidLayout;
        const nm = lm.get("name") orelse continue;
        const n = nm.asScalar() orelse continue;
        if (std.mem.eql(u8, n, "default")) {
            return try planFromLayoutMap(allocator, cwd, lm);
        }
    }

    return error.AmbiguousLayoutSelection;
}

fn planFromYamlByName(allocator: std.mem.Allocator, cwd: []const u8, yml: *const yaml.Yaml, name: []const u8) !?Plan {
    const map = try rootMap(yml);

    if (map.get("layout")) |layout_val| {
        const layout_map = layout_val.asMap() orelse return error.InvalidLayout;
        if (layout_map.get("name")) |nm| {
            const n = nm.asScalar() orelse return error.InvalidLayout;
            if (std.mem.eql(u8, n, name)) {
                return try planFromLayoutMap(allocator, cwd, layout_map);
            }
        }
    }

    if (map.get("layouts")) |layouts_val| {
        const layouts_list = layouts_val.asList() orelse return error.InvalidLayout;
        return try findLayoutInList(allocator, cwd, layouts_list, name);
    }

    return null;
}

fn findLayoutInList(allocator: std.mem.Allocator, cwd: []const u8, list: yaml.Yaml.List, name: []const u8) !?Plan {
    for (list) |item| {
        const lm = item.asMap() orelse return error.InvalidLayout;
        const nm = lm.get("name") orelse continue;
        const n = nm.asScalar() orelse continue;
        if (std.mem.eql(u8, n, name)) {
            return try planFromLayoutMap(allocator, cwd, lm);
        }
    }
    return null;
}

fn planFromLayoutMap(allocator: std.mem.Allocator, cwd: []const u8, layout_map: yaml.Yaml.Map) !Plan {
    const windows_val = layout_map.get("windows") orelse return error.InvalidLayout;
    const windows_list = windows_val.asList() orelse return error.InvalidLayout;
    if (windows_list.len == 0) return error.InvalidLayout;

    var vars = std.StringHashMap([]const u8).init(allocator);
    try putBaseVars(allocator, &vars, cwd);

    if (layout_map.get("vars")) |vars_val| {
        const vars_map = vars_val.asMap() orelse return error.InvalidLayout;
        var it = vars_map.iterator();
        while (it.next()) |entry| {
            const key = entry.key_ptr.*;
            const raw = entry.value_ptr.*.asScalar() orelse return error.InvalidLayout;
            const expanded = try expandString(allocator, &vars, raw);
            try vars.put(key, expanded);
        }
    }

    var out_windows = try allocator.alloc(Window, windows_list.len);

    for (windows_list, 0..) |w_val, wi| {
        const w_map = w_val.asMap() orelse return error.InvalidLayout;
        const panes_val = w_map.get("panes") orelse return error.InvalidLayout;
        const panes_list = panes_val.asList() orelse return error.InvalidLayout;
        if (panes_list.len == 0) return error.InvalidLayout;

        var panes = try allocator.alloc(Pane, panes_list.len);

        for (panes_list, 0..) |p_val, pi| {
            const p_map = p_val.asMap() orelse return error.InvalidLayout;

            var split: ?Split = null;
            if (p_map.get("split")) |split_val| {
                const s = split_val.asScalar() orelse return error.InvalidLayout;
                split = std.meta.stringToEnum(Split, s) orelse return error.InvalidLayout;
            }
            if (pi == 0) {
                if (split != null) return error.InvalidLayout;
            } else if (split == null) {
                return error.InvalidLayout;
            }

            var title: ?[]const u8 = null;
            if (p_map.get("title")) |t_val| {
                title = t_val.asScalar() orelse return error.InvalidLayout;
            }

            var cmd: ?[]const u8 = null;
            if (p_map.get("cmd")) |c_val| {
                const raw_cmd = c_val.asScalar() orelse return error.InvalidLayout;
                if (raw_cmd.len > 0) {
                    cmd = try expandString(allocator, &vars, raw_cmd);
                }
            }

            panes[pi] = .{ .title = title, .cmd = cmd, .split = split };
        }

        var w_name: ?[]const u8 = null;
        if (w_map.get("name")) |n_val| {
            w_name = n_val.asScalar() orelse return error.InvalidLayout;
        }

        out_windows[wi] = .{ .name = w_name, .panes = panes };
    }

    return .{ .windows = out_windows };
}

fn putBaseVars(allocator: std.mem.Allocator, vars: *std.StringHashMap([]const u8), cwd: []const u8) !void {
    const home = std.posix.getenv("HOME") orelse "";
    try vars.put("HOME", try allocator.dupe(u8, home));

    if (std.posix.getenv("EDITOR")) |editor| {
        try vars.put("EDITOR", try allocator.dupe(u8, editor));
    }

    if (std.posix.getenv("SHELL")) |shell| {
        try vars.put("SHELL", try allocator.dupe(u8, shell));
    }

    try vars.put("PROJECT_DIR", try allocator.dupe(u8, cwd));
    try vars.put("PROJECT_NAME", try allocator.dupe(u8, std.fs.path.basename(cwd)));
}

fn expandString(allocator: std.mem.Allocator, vars: *const std.StringHashMap([]const u8), input: []const u8) ![]const u8 {
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(allocator);

    var i: usize = 0;
    while (i < input.len) : (i += 1) {
        if (input[i] != '$' or i + 1 >= input.len or input[i + 1] != '{') {
            try out.append(allocator, input[i]);
            continue;
        }

        const start = i + 2;
        const end_rel = std.mem.indexOfScalarPos(u8, input, start, '}') orelse return error.InvalidLayout;
        const key = input[start..end_rel];
        const val = vars.get(key) orelse return error.UnknownVariable;
        try out.appendSlice(allocator, val);
        i = end_rel;
    }

    return out.toOwnedSlice(allocator);
}

fn findLocalConfigPath(allocator: std.mem.Allocator, start_dir: []const u8) !?[]const u8 {
    var dir = start_dir;
    while (true) {
        const candidate = try std.fs.path.join(allocator, &.{ dir, ".prise.yml" });
        if (fileExistsAbsolute(candidate)) return candidate;

        const parent = std.fs.path.dirname(dir) orelse break;
        if (std.mem.eql(u8, parent, dir)) break;
        dir = parent;
    }
    return null;
}

fn fileExistsAbsolute(path: []const u8) bool {
    std.fs.accessAbsolute(path, .{}) catch return false;
    return true;
}

test "expandString - project vars" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    var vars = std.StringHashMap([]const u8).init(arena.allocator());
    try vars.put("PROJECT_DIR", "/tmp/demo");
    try vars.put("PROJECT_NAME", "demo");

    const out = try expandString(arena.allocator(), &vars, "${PROJECT_DIR}/${PROJECT_NAME}");
    try std.testing.expectEqualStrings("/tmp/demo/demo", out);
}
