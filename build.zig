const std = @import("std");

// Force pkg-config for every system library so a missing module fails
// loudly with the module name instead of falling back to a literal
// `lib<name>.so` filename search (which double-prefixes "libnotify"
// to "liblibnotify.so" and lowercases "X11"/"GL"/"EGL").
const sys_lib: std.Build.Module.LinkSystemLibraryOptions = .{ .use_pkg_config = .force };

/// Verify pkg-config is on PATH and that every system library seance
/// links against has a discoverable .pc file, before kicking off a
/// 60-step build that would otherwise fail with either a wall of
/// linker search paths or a Zig build-runner panic stack trace.
/// All missing modules are reported in a single message.
fn requirePkgConfig(b: *std.Build, modules: []const []const u8) void {
    _ = std.process.Child.run(.{
        .allocator = b.allocator,
        .argv = &.{ "pkg-config", "--version" },
    }) catch {
        std.log.err("pkg-config not found on PATH. Install pkg-config and the GTK4 development libraries.", .{});
        std.process.exit(1);
    };

    var missing: std.ArrayList([]const u8) = .empty;
    for (modules) |m| {
        const result = std.process.Child.run(.{
            .allocator = b.allocator,
            .argv = &.{ "pkg-config", "--exists", m },
        }) catch {
            missing.append(b.allocator, m) catch @panic("OOM");
            continue;
        };
        switch (result.term) {
            .Exited => |code| if (code != 0) missing.append(b.allocator, m) catch @panic("OOM"),
            else => missing.append(b.allocator, m) catch @panic("OOM"),
        }
    }

    if (missing.items.len > 0) {
        std.log.err("pkg-config could not find {d} required librar{s}:", .{
            missing.items.len,
            if (missing.items.len == 1) "y" else "ies",
        });
        for (missing.items) |m| std.log.err("  - {s}", .{m});
        std.log.err("Install the corresponding development packages and try again.", .{});
        std.process.exit(1);
    }
}

/// Wire all of seance's native dependencies (GTK4/libadwaita, optional
/// Linux desktop libs, libghostty, GLAD) onto a module. Shared between
/// the exe and every test module so they cannot drift.
fn addSeanceDeps(
    mod: *std.Build.Module,
    b: *std.Build,
    is_linux: bool,
    is_darwin: bool,
    ghostty_dep: *std.Build.Dependency,
) void {
    mod.linkSystemLibrary("gtk4", sys_lib);
    mod.linkSystemLibrary("libadwaita-1", sys_lib);

    // Linux-only desktop integration libraries
    if (is_linux) {
        mod.linkSystemLibrary("libnotify", sys_lib);
        mod.linkSystemLibrary("libcanberra", sys_lib);

        // System fontconfig must be linked by seance directly so there's
        // exactly one copy in the process; otherwise ELF symbol
        // interposition routes libfontconfig.so.1's internal calls into
        // a stale bundled copy and crashes in FcCompare on font lookup.
        // See the matching `system_library_options` set in `build()`.
        mod.linkSystemLibrary("fontconfig", sys_lib);

        // X11 + Wayland for blur / transparency protocol support
        mod.linkSystemLibrary("x11", sys_lib);
        mod.linkSystemLibrary("wayland-client", sys_lib);
        // KDE blur protocol interface definitions (hand-written, no scanner needed)
        mod.addCSourceFile(.{
            .file = b.path("src/kde_blur_protocol.c"),
            .flags = &.{},
        });
        // KDE server-decoration protocol interface definitions
        mod.addCSourceFile(.{
            .file = b.path("src/kde_decoration_protocol.c"),
            .flags = &.{},
        });
    }

    mod.link_libc = true;

    // Ghostty (libghostty) — terminal emulation, rendering, fonts.
    mod.linkLibrary(ghostty_dep.artifact("ghostty_static"));
    mod.addIncludePath(ghostty_dep.path("include"));

    // System libraries used internally by libghostty. When ghostty is
    // built as a static library with --system (system integration),
    // these are not embedded in the archive so the consumer must link
    // them explicitly.
    if (is_linux) {
        mod.linkSystemLibrary("freetype2", sys_lib);
        mod.linkSystemLibrary("harfbuzz", sys_lib);
        mod.linkSystemLibrary("oniguruma", sys_lib);
    }

    // GLAD (OpenGL loader) — ghostty only compiles this for exe builds,
    // so we must compile it ourselves when linking libghostty as a library.
    mod.addIncludePath(ghostty_dep.path("vendor/glad/include"));
    mod.addCSourceFile(.{
        .file = ghostty_dep.path("vendor/glad/src/gl.c"),
        .flags = &.{},
    });

    // OpenGL libraries needed by GLAD's runtime loader
    if (is_linux) {
        mod.linkSystemLibrary("gl", sys_lib);
        mod.linkSystemLibrary("egl", sys_lib);
    } else if (is_darwin) {
        mod.linkFramework("OpenGL", .{});
        // Metal framework needed by ghostty's bundled Dear ImGui Metal backend
        mod.linkFramework("Metal", .{});
    }
}

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.option(std.builtin.OptimizeMode, "optimize", "Build optimization") orelse .ReleaseSafe;

    const strip = b.option(bool, "strip", "Strip debug symbols for smaller binary") orelse false;

    const is_linux = target.result.os.tag == .linux;
    const is_darwin = target.result.os.tag.isDarwin();

    if (is_linux) requirePkgConfig(b, &.{
        "gtk4",
        "libadwaita-1",
        "libnotify",
        "libcanberra",
        "x11",
        "wayland-client",
        "gl",
        "egl",
        "fontconfig",
    });

    // Force ghostty to use system fontconfig instead of bundling its own;
    // two fontconfigs in the same process collide via ELF interposition
    // and crash in FcCompare on font lookup. `system_library_options` is
    // shared with the dependency builder, so this must be set before
    // `b.dependency("ghostty", ...)`.
    if (is_linux) {
        b.graph.system_library_options.put(
            b.allocator,
            "fontconfig",
            .user_enabled,
        ) catch @panic("OOM");
    }

    // Ghostty (libghostty) — terminal emulation, rendering, fonts
    const ghostty_dep = b.dependency("ghostty", .{
        .@"app-runtime" = .none,
        .optimize = optimize,
    });

    const exe_mod = b.createModule(.{
        .root_source_file = b.path("src/main.zig"),
        .target = target,
        .optimize = optimize,
        .strip = strip,
        .pic = true,
    });
    addSeanceDeps(exe_mod, b, is_linux, is_darwin, ghostty_dep);

    const exe = b.addExecutable(.{
        .name = "seance",
        .root_module = exe_mod,
    });
    exe.pie = true;

    b.installArtifact(exe);

    // Install seance's own shell integration scripts
    b.installDirectory(.{
        .source_dir = b.path("resources/shell-integration"),
        .install_dir = .prefix,
        .install_subdir = "share/shell-integration",
    });

    // Install wrapper scripts (claude wrapper, etc.)
    b.installDirectory(.{
        .source_dir = b.path("resources/bin"),
        .install_dir = .prefix,
        .install_subdir = "share/bin",
    });

    // Install bundled icons (from GNOME Icon Library) into hicolor theme
    b.installDirectory(.{
        .source_dir = b.path("resources/icons/hicolor"),
        .install_dir = .prefix,
        .install_subdir = "share/icons/hicolor",
    });

    // Install desktop entry and appstream metainfo (Linux desktop integration)
    if (is_linux) {
        b.getInstallStep().dependOn(&b.addInstallFileWithDir(
            b.path("resources/com.seance.app.desktop"),
            .prefix,
            "share/applications/com.seance.app.desktop",
        ).step);
        b.getInstallStep().dependOn(&b.addInstallFileWithDir(
            b.path("resources/com.seance.app.metainfo.xml"),
            .prefix,
            "share/metainfo/com.seance.app.metainfo.xml",
        ).step);
    }

    // Install ghostty's shell integration scripts so ghostty's auto-injection
    // works even when system ghostty isn't installed.  This gives us OSC 7
    // (CWD reporting), OSC 2 (title), prompt marks, etc. for free.
    b.installDirectory(.{
        .source_dir = ghostty_dep.path("src/shell-integration"),
        .install_dir = .prefix,
        .install_subdir = "share/ghostty/shell-integration",
    });

    // Install bundled color themes (iTerm2-Color-Schemes, same set Ghostty uses)
    // so that themes work even when system ghostty is not installed.
    // Then overlay seance's own theme overrides (e.g. corrected Adwaita colors)
    // with an explicit step dependency so they always win.
    {
        const overrides = b.addInstallDirectory(.{
            .source_dir = b.path("resources/themes"),
            .install_dir = .prefix,
            .install_subdir = "share/ghostty/themes",
        });
        if (b.lazyDependency("ghostty_themes", .{})) |themes_dep| {
            const upstream = b.addInstallDirectory(.{
                .source_dir = themes_dep.path(""),
                .install_dir = .prefix,
                .install_subdir = "share/ghostty/themes",
                .exclude_extensions = &.{".md"},
            });
            overrides.step.dependOn(&upstream.step);
        }
        b.getInstallStep().dependOn(&overrides.step);
    }

    // Compile and install the ghostty terminfo database so that child processes
    // can look up the xterm-ghostty terminal type without system ghostty.
    // Ghostty's Exec.zig sets TERMINFO to share/terminfo (sibling of share/ghostty).
    {
        const tic = std.Build.Step.Run.create(b, "compile terminfo");
        tic.addArgs(&.{ "tic", "-x", "-o" });
        const terminfo_db = tic.addOutputDirectoryArg("terminfo");
        tic.addFileArg(b.path("resources/terminfo/ghostty.terminfo"));
        _ = tic.captureStdErr();

        b.installDirectory(.{
            .source_dir = terminfo_db,
            .install_dir = .prefix,
            .install_subdir = "share/terminfo",
        });
    }

    const run_cmd = b.addRunArtifact(exe);
    run_cmd.step.dependOn(b.getInstallStep());
    if (b.args) |args| {
        run_cmd.addArgs(args);
    }

    const run_step = b.step("run", "Run seance");
    run_step.dependOn(&run_cmd.step);

    // --- Unit tests ---
    const test_step = b.step("test", "Run unit tests");

    // Standalone tests (no external dependencies)
    for ([_][]const u8{ "src/osc_parser.zig", "src/port_scan.zig" }) |src| {
        const mod = b.createModule(.{
            .root_source_file = b.path(src),
            .target = target,
            .optimize = optimize,
        });
        const t = b.addTest(.{ .root_module = mod });
        test_step.dependOn(&b.addRunArtifact(t).step);
    }

    // --- E2E tests ---
    {
        const e2e_step = b.step("e2e", "Run end-to-end tests (requires Xvfb)");

        const e2e_mod = b.createModule(.{
            .root_source_file = b.path("src/e2e_test.zig"),
            .target = target,
            .optimize = optimize,
        });
        e2e_mod.link_libc = true;

        const e2e_exe = b.addExecutable(.{
            .name = "seance-e2e",
            .root_module = e2e_mod,
        });

        // Ensure the main seance binary is built first
        e2e_exe.step.dependOn(b.getInstallStep());

        const e2e_run = b.addRunArtifact(e2e_exe);
        // Pass the absolute path to the seance binary
        e2e_run.addArg(b.fmt("{s}/bin/seance", .{b.install_path}));

        e2e_step.dependOn(&e2e_run.step);
    }

    // Tests for files that need GTK/ghostty
    for ([_][]const u8{ "src/config.zig", "src/keybinds.zig", "src/notification.zig", "src/workspace.zig", "src/session.zig" }) |src| {
        const test_mod = b.createModule(.{
            .root_source_file = b.path(src),
            .target = target,
            .optimize = optimize,
        });
        addSeanceDeps(test_mod, b, is_linux, is_darwin, ghostty_dep);

        const t = b.addTest(.{
            .root_module = test_mod,
        });
        test_step.dependOn(&b.addRunArtifact(t).step);
    }
}
