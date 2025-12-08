const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const version = getVersion(b);

    const exe_mod = b.createModule(.{
        .root_source_file = b.path("src/main.zig"),
        .target = target,
        .optimize = optimize,
    });

    const options = b.addOptions();
    options.addOption([]const u8, "version", version);
    exe_mod.addOptions("build_options", options);

    const ghostty = b.dependency("ghostty", .{
        .target = target,
        .optimize = optimize,
    });
    exe_mod.addImport("ghostty-vt", ghostty.module("ghostty-vt"));

    const vaxis = b.dependency("vaxis", .{
        .target = target,
        .optimize = optimize,
    });
    exe_mod.addImport("vaxis", vaxis.module("vaxis"));

    const zlua = b.dependency("zlua", .{
        .target = target,
        .optimize = optimize,
        .lang = .lua54,
    });
    exe_mod.addImport("zlua", zlua.module("zlua"));

    const exe = b.addExecutable(.{
        .name = "prise",
        .root_module = exe_mod,
    });

    b.installArtifact(exe);

    b.installFile("completions/prise.fish", "share/fish/vendor_completions.d/prise.fish");
    b.installFile("completions/prise.bash", "share/bash-completion/completions/prise");
    b.installFile("completions/prise.zsh", "share/zsh/site-functions/_prise");

    b.installFile("src/lua/prise.lua", "share/prise/lua/prise.lua");
    b.installFile("src/lua/tiling.lua", "share/prise/lua/prise_tiling_ui.lua");
    b.installFile("src/lua/utils.lua", "share/prise/lua/utils.lua");

    const os = @import("builtin").os.tag;
    if (os.isDarwin()) {
        const plist = b.addWriteFiles();
        const plist_content = std.fmt.allocPrint(b.allocator,
            \\<?xml version="1.0" encoding="UTF-8"?>
            \\<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
            \\<plist version="1.0">
            \\<dict>
            \\    <key>Label</key>
            \\    <string>sh.prise.server</string>
            \\    <key>ProgramArguments</key>
            \\    <array>
            \\        <string>{s}/bin/prise</string>
            \\        <string>serve</string>
            \\    </array>
            \\    <key>RunAtLoad</key>
            \\    <true/>
            \\    <key>KeepAlive</key>
            \\    <true/>
            \\    <key>StandardOutPath</key>
            \\    <string>/dev/null</string>
            \\    <key>StandardErrorPath</key>
            \\    <string>/dev/null</string>
            \\</dict>
            \\</plist>
            \\
        , .{b.install_prefix}) catch @panic("OOM");
        _ = plist.add("sh.prise.server.plist", plist_content);
        b.getInstallStep().dependOn(&b.addInstallDirectory(.{
            .source_dir = plist.getDirectory(),
            .install_dir = .{ .custom = "share/prise" },
            .install_subdir = "",
        }).step);
    } else if (os == .linux) {
        const service = b.addWriteFiles();
        const service_content = std.fmt.allocPrint(b.allocator,
            \\[Unit]
            \\Description=Prise terminal multiplexer server
            \\Documentation=https://prise.sh
            \\
            \\[Service]
            \\Type=simple
            \\ExecStart={s}/bin/prise serve
            \\Restart=on-failure
            \\RestartSec=5
            \\
            \\[Install]
            \\WantedBy=default.target
            \\
        , .{b.install_prefix}) catch @panic("OOM");
        _ = service.add("prise.service", service_content);
        b.getInstallStep().dependOn(&b.addInstallDirectory(.{
            .source_dir = service.getDirectory(),
            .install_dir = .{ .custom = "lib/systemd/user" },
            .install_subdir = "",
        }).step);
    }

    const run_cmd = b.addRunArtifact(exe);
    run_cmd.step.dependOn(b.getInstallStep());

    if (b.args) |args| {
        run_cmd.addArgs(args);
    }

    const run_step = b.step("run", "Run the app");
    run_step.dependOn(&run_cmd.step);

    const tests = b.addTest(.{
        .root_module = exe_mod,
    });

    const test_cmd = b.addRunArtifact(tests);
    const test_step = b.step("test", "Run tests");
    test_step.dependOn(&test_cmd.step);

    const check_fmt = b.addSystemCommand(&.{
        "sh", "-c",
        \\zig fmt --check src --exclude src/lua && zig fmt --check tools build.zig && stylua --check src/lua || {
        \\  echo ""; echo "Format check failed. Run 'zig build fmt' to fix."; exit 1;
        \\}
        ,
    });
    test_step.dependOn(&check_fmt.step);

    const fmt_step = b.step("fmt", "Format Zig and Lua files");

    const fmt_zig = b.addFmt(.{
        .paths = &.{ "src", "build.zig", "tools" },
        .exclude_paths = &.{"src/lua"},
        .check = false,
    });
    fmt_step.dependOn(&fmt_zig.step);

    const stylua = b.addSystemCommand(&.{ "stylua", "src/lua" });
    fmt_step.dependOn(&stylua.step);

    // mdman - markdown to man page converter
    const mdman_mod = b.createModule(.{
        .root_source_file = b.path("tools/mdman/main.zig"),
        .target = target,
        .optimize = optimize,
    });

    const mdman = b.addExecutable(.{
        .name = "mdman",
        .root_module = mdman_mod,
    });

    const mdman_step = b.step("mdman", "Build the mdman tool");
    mdman_step.dependOn(&b.addInstallArtifact(mdman, .{}).step);

    const mdman_tests = b.addTest(.{
        .root_module = mdman_mod,
    });
    test_step.dependOn(&b.addRunArtifact(mdman_tests).step);

    // Generate man pages from docs/*.md
    const man_step = b.step("man", "Generate man pages");
    const man_sources = .{
        .{ "prise.1.md", "prise.1", "1" },
        .{ "prise.5.md", "prise.5", "5" },
        .{ "prise.7.md", "prise.7", "7" },
    };
    inline for (man_sources) |entry| {
        const md_file, const man_file, const section = entry;
        const run_mdman = b.addRunArtifact(mdman);
        run_mdman.addArgs(&.{ "-n", "prise", "-s", section });
        run_mdman.addFileArg(b.path("docs/" ++ md_file));
        const output = run_mdman.captureStdOut();
        man_step.dependOn(&b.addInstallFile(output, "share/man/man" ++ section ++ "/" ++ man_file).step);
    }
    b.getInstallStep().dependOn(man_step);

    // Generate HTML documentation (not installed, for website builds)
    const web_step = b.step("web", "Generate HTML documentation");
    const web_wf = b.addWriteFiles();
    _ = web_wf.addCopyFile(b.path("docs/web/index.html"), "index.html");
    inline for (man_sources) |entry| {
        const md_file, _, _ = entry;
        const html_file = md_file[0 .. md_file.len - 3] ++ ".html";

        const run_html = b.addRunArtifact(mdman);
        run_html.addArgs(&.{ "-n", "prise", "--html-fragment" });
        run_html.addFileArg(b.path("docs/" ++ md_file));
        const fragment = run_html.captureStdOut();

        const cat = b.addSystemCommand(&.{ "cat", "--" });
        cat.addFileArg(b.path("docs/web/header.html"));
        cat.addFileArg(fragment);
        cat.addFileArg(b.path("docs/web/footer.html"));
        _ = web_wf.addCopyFile(cat.captureStdOut(), html_file);
    }
    web_step.dependOn(&b.addInstallDirectory(.{
        .source_dir = web_wf.getDirectory(),
        .install_dir = .prefix,
        .install_subdir = "web",
    }).step);

    const setup_step = b.step("setup", "Setup development environment (install pre-commit hook)");

    const pre_commit_hook =
        \\#!/bin/sh
        \\set -e
        \\zig build fmt
        \\zig build test
    ;

    const setup_hook = b.addSystemCommand(&.{
        "sh",
        "-c",
        b.fmt("mkdir -p .git/hooks && cat > .git/hooks/pre-commit << 'EOF'\n{s}\nEOF\nchmod +x .git/hooks/pre-commit && echo '✓ Pre-commit hook installed'", .{pre_commit_hook}),
    });
    setup_step.dependOn(&setup_hook.step);

    const check_stylua = b.addSystemCommand(&.{
        "sh",
        "-c",
        "command -v stylua > /dev/null || { echo '⚠ Warning: stylua not found. Run: brew install stylua'; }",
    });
    setup_step.dependOn(&check_stylua.step);

    const enable_service_step = b.step("enable-service", "Enable and start the prise server service");
    if (os.isDarwin()) {
        const enable_macos = b.addSystemCommand(&.{
            "sh",
            "-c",
            \\set -e
            \\PLIST_SRC="$1/share/prise/sh.prise.server.plist"
            \\PLIST_DST="$HOME/Library/LaunchAgents/sh.prise.server.plist"
            \\mkdir -p "$HOME/Library/LaunchAgents"
            \\ln -sf "$PLIST_SRC" "$PLIST_DST"
            \\launchctl unload "$PLIST_DST" 2>/dev/null || true
            \\launchctl load "$PLIST_DST"
            \\echo "✓ prise server enabled and started"
            ,
            "--",
        });
        enable_macos.addDirectoryArg(.{ .cwd_relative = b.install_prefix });
        enable_service_step.dependOn(&enable_macos.step);
    } else if (os == .linux) {
        const enable_linux = b.addSystemCommand(&.{
            "sh",
            "-c",
            \\set -e
            \\SERVICE_SRC="$1/lib/systemd/user/prise.service"
            \\SERVICE_DST="$HOME/.config/systemd/user/prise.service"
            \\mkdir -p "$HOME/.config/systemd/user"
            \\ln -sf "$SERVICE_SRC" "$SERVICE_DST"
            \\systemctl --user daemon-reload
            \\systemctl --user enable --now prise.service
            \\echo "✓ prise server enabled and started"
            ,
            "--",
        });
        enable_linux.addDirectoryArg(.{ .cwd_relative = b.install_prefix });
        enable_service_step.dependOn(&enable_linux.step);
    }
    enable_service_step.dependOn(b.getInstallStep());
}

const version_base = "0.1.0";

fn getVersion(b: *std.Build) []const u8 {
    var code: u8 = undefined;
    const git_describe = b.runAllowFail(&.{ "git", "describe", "--match", "*.*.*", "--tags" }, &code, .Ignore) catch {
        return getDevVersion(b);
    };
    const trimmed = std.mem.trim(u8, git_describe, " \n\r");
    if (std.mem.eql(u8, trimmed, version_base)) {
        return version_base;
    }
    return getDevVersion(b);
}

fn getDevVersion(b: *std.Build) []const u8 {
    var code: u8 = undefined;
    const commit_count = b.runAllowFail(&.{ "git", "rev-list", "--count", "HEAD" }, &code, .Ignore) catch "0";
    const commit_hash = b.runAllowFail(&.{ "git", "rev-parse", "--short=7", "HEAD" }, &code, .Ignore) catch "unknown";
    return b.fmt("{s}-dev.{s}+{s}", .{
        version_base,
        std.mem.trim(u8, commit_count, " \n\r"),
        std.mem.trim(u8, commit_hash, " \n\r"),
    });
}
