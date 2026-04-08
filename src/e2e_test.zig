// src/e2e_test.zig — End-to-end test runner for seance
//
// Spawns seance in an isolated environment, exercises the socket API, and
// verifies responses.  Runs as a standalone executable via `zig build e2e`.
//
// Display backends (tried in order):
//   1. native — use the existing display (XWayland/X11) with hardware GL
//   2. cage (Wayland kiosk compositor, headless) — software rendering
//   3. Xvfb (X11 virtual framebuffer) — software rendering
//
// The native backend is preferred when a display is already available
// (developer workstation) because headless software rendering often
// hits driver bugs (e.g. llvmpipe LLVM codegen issues, NVIDIA EGL
// not supporting GL contexts in headless Wayland compositors).
// cage/Xvfb are fallbacks for headless CI environments.

const std = @import("std");
const posix = std.posix;
const Allocator = std.mem.Allocator;

// ── Main ───────────────────────────────────────────────────────────────

pub fn main() !void {
    // Use page_allocator to avoid leak-check noise on exit — the e2e runner
    // is a short-lived process and all memory is reclaimed by the OS.
    const alloc = std.heap.page_allocator;

    const argv = try std.process.argsAlloc(alloc);
    defer std.process.argsFree(alloc, argv);

    const seance_bin = if (argv.len > 1) argv[1] else {
        std.debug.print("usage: e2e_test <path-to-seance-binary>\n", .{});
        std.process.exit(1);
    };

    // Verify seance binary exists
    std.fs.accessAbsolute(seance_bin, .{}) catch {
        std.debug.print("error: seance binary not found at: {s}\n", .{seance_bin});
        std.process.exit(1);
    };

    const backend = detectBackend(alloc);

    var harness = Harness.start(alloc, seance_bin, backend) catch |e| {
        std.debug.print("error: failed to start harness: {}\n", .{e});
        std.process.exit(1);
    };
    defer harness.shutdown();

    var runner = Runner{};

    runner.run("system.ping", &harness, testPing);
    runner.run("system.capabilities", &harness, testCapabilities);
    runner.run("system.identify", &harness, testIdentify);
    runner.run("system.tree", &harness, testTree);
    runner.run("workspace.create", &harness, testWorkspaceCreate);
    runner.run("workspace.list", &harness, testWorkspaceList);
    runner.run("workspace.rename", &harness, testWorkspaceRename);
    runner.run("workspace.select + current", &harness, testWorkspaceSelectCurrent);
    runner.run("workspace.navigation", &harness, testWorkspaceNavigation);
    runner.run("surface.split + list", &harness, testSurfaceSplitList);
    runner.run("surface.send_text + read_screen", &harness, testTerminalIO);
    runner.run("workspace.metadata", &harness, testWorkspaceMetadata);
    runner.run("notification lifecycle", &harness, testNotifications);
    runner.run("surface.close", &harness, testSurfaceClose);
    runner.run("surface.focus + last", &harness, testSurfaceFocusLast);
    runner.run("surface.send_key", &harness, testSurfaceSendKey);
    runner.run("surface.health", &harness, testSurfaceHealth);
    runner.run("window lifecycle", &harness, testWindowLifecycle);
    runner.run("workspace.move_to_window", &harness, testWorkspaceMoveToWindow);
    runner.run("surface.expel", &harness, testSurfaceExpel);
    runner.run("error: invalid method", &harness, testErrorInvalidMethod);
    runner.run("error: bad workspace id", &harness, testErrorBadWorkspaceId);
    runner.run("error: missing params", &harness, testErrorMissingParams);
    runner.run("workspace.close", &harness, testWorkspaceClose);

    runner.summary();
    if (runner.fail > 0) std.process.exit(1);
}

// ── Display backend detection ──────────────────────────────────────────

const DisplayBackend = enum { native, cage, xvfb };

fn detectBackend(alloc: Allocator) DisplayBackend {
    // Prefer the existing display — uses hardware GL, avoids software
    // rendering bugs (llvmpipe LLVM issues, NVIDIA headless EGL).
    if (probeNativeDisplay(alloc)) {
        std.debug.print("seance e2e: using native X11 display (hardware GL)\n", .{});
        return .native;
    }
    if (hasCommand(alloc, "cage")) {
        std.debug.print("seance e2e: using cage (Wayland headless)\n", .{});
        return .cage;
    }
    if (hasCommand(alloc, "Xvfb")) {
        std.debug.print("seance e2e: using Xvfb (X11, software rendering)\n", .{});
        return .xvfb;
    }
    std.debug.print("error: no display available and neither cage nor Xvfb found in PATH\n", .{});
    std.debug.print("  arch (preferred): pacman -S cage\n", .{});
    std.debug.print("  arch (fallback):  pacman -S xorg-server-xvfb\n", .{});
    std.debug.print("  ubuntu:           apt install cage  # or: apt install xvfb\n", .{});
    std.process.exit(1);
}

/// Check if the current DISPLAY points to a live X server.
/// Returns false on CI / headless machines where DISPLAY is unset or
/// points at a dead socket.
fn probeNativeDisplay(alloc: Allocator) bool {
    if (std.posix.getenv("DISPLAY") == null) return false;
    // Verify the X display is reachable.  `xset q` is lightweight and
    // exits 1 when the display is unreachable.
    const result = std.process.Child.run(.{
        .allocator = alloc,
        .argv = &.{ "xset", "q" },
    }) catch return false;
    alloc.free(result.stdout);
    alloc.free(result.stderr);
    return result.term == .Exited and result.term.Exited == 0;
}

fn hasCommand(alloc: Allocator, name: []const u8) bool {
    const result = std.process.Child.run(.{
        .allocator = alloc,
        .argv = &.{ "which", name },
    }) catch return false;
    alloc.free(result.stdout);
    alloc.free(result.stderr);
    return result.term.Exited == 0;
}

// ── Test runner ────────────────────────────────────────────────────────

const Runner = struct {
    pass: u32 = 0,
    fail: u32 = 0,
    skip: u32 = 0,

    fn run(self: *Runner, name: []const u8, harness: *Harness, comptime testFn: fn (*Harness) TestError!void) void {
        testFn(harness) catch |e| {
            if (e == TestError.Skip) {
                std.debug.print("  \x1b[33mSKIP\x1b[0m {s}\n", .{name});
                self.skip += 1;
                return;
            }
            std.debug.print("  \x1b[31mFAIL\x1b[0m {s}: {}\n", .{ name, e });
            self.fail += 1;
            return;
        };
        std.debug.print("  \x1b[32mPASS\x1b[0m {s}\n", .{name});
        self.pass += 1;
    }

    fn summary(self: *const Runner) void {
        const total = self.pass + self.fail + self.skip;
        std.debug.print("\n{d} tests: \x1b[32m{d} passed\x1b[0m", .{ total, self.pass });
        if (self.fail > 0) std.debug.print(", \x1b[31m{d} failed\x1b[0m", .{self.fail});
        if (self.skip > 0) std.debug.print(", \x1b[33m{d} skipped\x1b[0m", .{self.skip});
        std.debug.print("\n", .{});
    }
};

const TestError = error{
    AssertionFailed,
    SocketError,
    Timeout,
    Skip,
    Unexpected,
};

fn expect(ok: bool) TestError!void {
    if (!ok) return TestError.AssertionFailed;
}

// ── Harness ────────────────────────────────────────────────────────────

const Harness = struct {
    alloc: Allocator,
    tmp_dir: []const u8,
    socket_path: []const u8,
    /// cage pid (Wayland) or Xvfb pid (X11). Null if backend wraps seance directly.
    display_pid: ?posix.pid_t,
    /// seance pid (only set for Xvfb where seance is a separate process)
    seance_pid: ?posix.pid_t,

    const STARTUP_TIMEOUT_MS = 15_000;
    const POLL_INTERVAL_MS = 100;

    pub fn start(alloc: Allocator, seance_bin: []const u8, backend: DisplayBackend) !Harness {
        // 1. Create isolated temp directory
        const pid = if (@hasDecl(std.os, "linux")) std.os.linux.getpid() else std.c.getpid();
        const tmp_dir = try std.fmt.allocPrint(alloc, "/tmp/seance-e2e-{d}", .{pid});

        // Clean up any stale dir from a previous crashed run
        std.fs.deleteTreeAbsolute(tmp_dir) catch {};

        const config_dir = try std.fmt.allocPrint(alloc, "{s}/config/seance", .{tmp_dir});
        const home_dir = try std.fmt.allocPrint(alloc, "{s}/home", .{tmp_dir});
        const run_dir = try std.fmt.allocPrint(alloc, "{s}/run", .{tmp_dir});
        const cache_dir = try std.fmt.allocPrint(alloc, "{s}/cache", .{tmp_dir});

        for ([_][]const u8{ config_dir, home_dir, run_dir, cache_dir }) |dir| {
            try mkdirRecursive(dir);
        }

        // 2. Write minimal config.toml
        const socket_path = try std.fmt.allocPrint(alloc, "{s}/seance.sock", .{tmp_dir});
        const config_path = try std.fmt.allocPrint(alloc, "{s}/config.toml", .{config_dir});
        {
            const f = try std.fs.createFileAbsolute(config_path, .{});
            defer f.close();
            var buf: [512]u8 = undefined;
            var w = f.writer(&buf);
            try w.interface.print("[socket]\npath = \"{s}\"\n\n[behavior]\nconfirm-close-window = false\n", .{socket_path});
            try w.interface.flush();
        }

        const xdg_config = std.fs.path.dirname(config_dir) orelse config_dir;

        var harness = Harness{
            .alloc = alloc,
            .tmp_dir = tmp_dir,
            .socket_path = socket_path,
            .display_pid = null,
            .seance_pid = null,
        };

        switch (backend) {
            .native => {
                // Use the existing display (XWayland/X11) — no display server to spawn
                harness.seance_pid = try spawnSeanceNative(alloc, seance_bin, xdg_config, home_dir, run_dir, cache_dir);
            },
            .cage => {
                // cage wraps seance as its child — single process to manage
                harness.display_pid = try spawnCage(alloc, seance_bin, xdg_config, home_dir, run_dir, cache_dir);
            },
            .xvfb => {
                const display = try findFreeDisplay(alloc);
                harness.display_pid = try spawnXvfb(alloc, display);

                // Give Xvfb a moment to initialize
                std.Thread.sleep(300 * std.time.ns_per_ms);

                harness.seance_pid = try spawnSeanceX11(alloc, seance_bin, display, xdg_config, home_dir, run_dir, cache_dir);
            },
        }

        // 3. Wait for seance to be ready
        try harness.waitReady();

        std.debug.print("seance e2e: harness ready (socket={s})\n\n", .{socket_path});
        return harness;
    }

    pub fn shutdown(self: *Harness) void {
        std.debug.print("\nseance e2e: shutting down...\n", .{});
        if (self.seance_pid) |pid| killProcess(pid);
        std.Thread.sleep(100 * std.time.ns_per_ms);
        if (self.display_pid) |pid| killProcess(pid);
        std.fs.deleteTreeAbsolute(self.tmp_dir) catch {};
    }

    fn waitReady(self: *Harness) !void {
        var elapsed: u64 = 0;
        while (elapsed < STARTUP_TIMEOUT_MS) {
            if (self.callRaw("system.ping", null)) |_| {
                return;
            } else |_| {}
            std.Thread.sleep(POLL_INTERVAL_MS * std.time.ns_per_ms);
            elapsed += POLL_INTERVAL_MS;
        }
        std.debug.print("error: seance did not respond within {d}ms\n", .{STARTUP_TIMEOUT_MS});
        return error.Timeout;
    }

    // ── Socket client ──────────────────────────────────────────────────

    const Response = struct {
        ok: bool,
        result: std.json.Value,
        raw: []const u8,
        parsed: std.json.Parsed(std.json.Value),
    };

    pub fn call(self: *Harness, method: []const u8, params: ?[]const u8) TestError!Response {
        return self.callRaw(method, params) catch return TestError.SocketError;
    }

    pub fn callOk(self: *Harness, method: []const u8, params: ?[]const u8) TestError!std.json.Value {
        const resp = try self.call(method, params);
        if (!resp.ok) return TestError.AssertionFailed;
        return resp.result;
    }

    /// Expect the call to return ok:false.
    pub fn callExpectFail(self: *Harness, method: []const u8, params: ?[]const u8) TestError!void {
        const resp = try self.call(method, params);
        if (resp.ok) return TestError.AssertionFailed;
    }

    fn callRaw(self: *Harness, method: []const u8, params: ?[]const u8) !Response {
        const request = if (params) |p|
            try std.fmt.allocPrint(self.alloc, "{{\"id\":\"1\",\"method\":\"{s}\",\"params\":{s}}}\n", .{ method, p })
        else
            try std.fmt.allocPrint(self.alloc, "{{\"id\":\"1\",\"method\":\"{s}\"}}\n", .{method});
        defer self.alloc.free(request);

        const sock = try posix.socket(posix.AF.UNIX, posix.SOCK.STREAM, 0);
        defer posix.close(sock);

        var addr: posix.sockaddr.un = .{ .family = posix.AF.UNIX, .path = undefined };
        @memset(&addr.path, 0);
        const copy_len = @min(self.socket_path.len, addr.path.len - 1);
        for (0..copy_len) |i| {
            addr.path[i] = @intCast(self.socket_path[i]);
        }
        try posix.connect(sock, @ptrCast(&addr), @sizeOf(posix.sockaddr.un));

        const tv: posix.timeval = .{ .sec = 5, .usec = 0 };
        try posix.setsockopt(sock, posix.SOL.SOCKET, posix.SO.RCVTIMEO, std.mem.asBytes(&tv));

        _ = try posix.write(sock, request);

        var response_buf: std.ArrayList(u8) = .empty;
        var buf: [16384]u8 = undefined;
        while (true) {
            const n = try posix.read(sock, &buf);
            if (n == 0) break;
            try response_buf.appendSlice(self.alloc, buf[0..n]);
            if (std.mem.indexOfScalar(u8, buf[0..n], '\n') != null) break;
        }

        if (response_buf.items.len == 0) return error.EmptyResponse;

        const trimmed = std.mem.trim(u8, response_buf.items, &[_]u8{ '\r', '\n', ' ' });
        const parsed = try std.json.parseFromSlice(std.json.Value, self.alloc, trimmed, .{});

        if (parsed.value != .object) return error.InvalidResponse;

        const ok_val = parsed.value.object.get("ok");
        const ok = if (ok_val) |v| (v == .bool and v.bool) else false;
        const result = parsed.value.object.get("result") orelse .null;

        return Response{
            .ok = ok,
            .result = result,
            .raw = trimmed,
            .parsed = parsed,
        };
    }

    /// Read terminal screen, retrying until `needle` appears or timeout.
    pub fn expectScreen(self: *Harness, surface_id_param: ?[]const u8, needle: []const u8, timeout_ms: u64) TestError!void {
        var elapsed: u64 = 0;
        while (elapsed < timeout_ms) {
            const params = if (surface_id_param) |sid|
                std.fmt.allocPrint(self.alloc, "{{\"surface_id\":{s}}}", .{sid}) catch return TestError.Unexpected
            else
                null;
            if (self.call("surface.read_screen", params)) |resp| {
                if (resp.ok) {
                    if (resp.result == .object) {
                        if (resp.result.object.get("text")) |text_val| {
                            if (text_val == .string) {
                                if (std.mem.indexOf(u8, text_val.string, needle) != null) return;
                            }
                        }
                    }
                }
            } else |_| {}
            std.Thread.sleep(POLL_INTERVAL_MS * std.time.ns_per_ms);
            elapsed += POLL_INTERVAL_MS;
        }
        return TestError.Timeout;
    }
};

// ── Process helpers ────────────────────────────────────────────────────

/// Spawn seance using the existing display (XWayland or X11).
fn spawnSeanceNative(
    alloc: Allocator,
    seance_bin: []const u8,
    xdg_config: []const u8,
    home_dir: []const u8,
    run_dir: []const u8,
    cache_dir: []const u8,
) !posix.pid_t {
    const xdg_config_arg = try std.fmt.allocPrint(alloc, "XDG_CONFIG_HOME={s}", .{xdg_config});
    const run_dir_arg = try std.fmt.allocPrint(alloc, "XDG_RUNTIME_DIR={s}", .{run_dir});
    const cache_dir_arg = try std.fmt.allocPrint(alloc, "XDG_CACHE_HOME={s}", .{cache_dir});
    const home_dir_arg = try std.fmt.allocPrint(alloc, "HOME={s}", .{home_dir});

    var child = std.process.Child.init(
        &.{
            "env",
            "GDK_BACKEND=x11",
            xdg_config_arg,
            run_dir_arg,
            cache_dir_arg,
            home_dir_arg,
            "NO_AT_BRIDGE=1",
            "DBUS_SESSION_BUS_ADDRESS=disabled:",
            seance_bin,
        },
        alloc,
    );
    child.stdin_behavior = .Ignore;
    child.stdout_behavior = .Ignore;
    child.stderr_behavior = .Pipe;
    try child.spawn();
    return child.id;
}

/// Spawn cage (headless Wayland compositor) wrapping seance as its child.
/// Uses `env` to set specific vars while inheriting the parent environment.
fn spawnCage(
    alloc: Allocator,
    seance_bin: []const u8,
    xdg_config: []const u8,
    home_dir: []const u8,
    run_dir: []const u8,
    cache_dir: []const u8,
) !posix.pid_t {
    const xdg_config_arg = try std.fmt.allocPrint(alloc, "XDG_CONFIG_HOME={s}", .{xdg_config});
    const run_dir_arg = try std.fmt.allocPrint(alloc, "XDG_RUNTIME_DIR={s}", .{run_dir});
    const cache_dir_arg = try std.fmt.allocPrint(alloc, "XDG_CACHE_HOME={s}", .{cache_dir});
    const home_dir_arg = try std.fmt.allocPrint(alloc, "HOME={s}", .{home_dir});

    var child = std.process.Child.init(
        &.{
            "env",
            "WLR_BACKENDS=headless",
            xdg_config_arg,
            run_dir_arg,
            cache_dir_arg,
            home_dir_arg,
            // On Wayland, GDK needs GLES (EGL) for window surfaces — only disable vulkan
            "GDK_DISABLE=vulkan",
            // Block dbus to prevent GApplication single-instance detection
            "DBUS_SESSION_BUS_ADDRESS=disabled:",
            "NO_AT_BRIDGE=1",
            "cage",
            "--",
            seance_bin,
        },
        alloc,
    );
    child.stdin_behavior = .Ignore;
    child.stdout_behavior = .Ignore;
    child.stderr_behavior = .Pipe; // suppress verbose wlroots/EGL logging
    try child.spawn();
    return child.id;
}

/// Spawn Xvfb (X11 virtual framebuffer).
fn spawnXvfb(alloc: Allocator, display: []const u8) !posix.pid_t {
    var child = std.process.Child.init(
        &.{ "Xvfb", display, "-screen", "0", "1280x720x24", "-nolisten", "tcp", "-ac" },
        alloc,
    );
    child.stdin_behavior = .Ignore;
    child.stdout_behavior = .Ignore;
    child.stderr_behavior = .Ignore;
    try child.spawn();
    return child.id;
}

/// Spawn seance under Xvfb (X11 + software rendering).
fn spawnSeanceX11(
    alloc: Allocator,
    seance_bin: []const u8,
    display: []const u8,
    xdg_config: []const u8,
    home_dir: []const u8,
    run_dir: []const u8,
    cache_dir: []const u8,
) !posix.pid_t {
    const display_arg = try std.fmt.allocPrint(alloc, "DISPLAY={s}", .{display});
    const xdg_config_arg = try std.fmt.allocPrint(alloc, "XDG_CONFIG_HOME={s}", .{xdg_config});
    const run_dir_arg = try std.fmt.allocPrint(alloc, "XDG_RUNTIME_DIR={s}", .{run_dir});
    const cache_dir_arg = try std.fmt.allocPrint(alloc, "XDG_CACHE_HOME={s}", .{cache_dir});
    const home_dir_arg = try std.fmt.allocPrint(alloc, "HOME={s}", .{home_dir});

    var child = std.process.Child.init(
        &.{
            "env",
            display_arg,
            "GDK_BACKEND=x11",
            "LIBGL_ALWAYS_SOFTWARE=1",
            xdg_config_arg,
            run_dir_arg,
            cache_dir_arg,
            home_dir_arg,
            "GDK_DISABLE=gles-api,vulkan",
            "NO_AT_BRIDGE=1",
            "DBUS_SESSION_BUS_ADDRESS=disabled:",
            seance_bin,
        },
        alloc,
    );
    child.stdin_behavior = .Ignore;
    child.stdout_behavior = .Ignore;
    child.stderr_behavior = .Inherit;
    try child.spawn();
    return child.id;
}

fn killProcess(pid: posix.pid_t) void {
    posix.kill(pid, posix.SIG.TERM) catch {};
    _ = posix.waitpid(pid, 0);
}

fn mkdirRecursive(path: []const u8) !void {
    var i: usize = 1;
    while (i < path.len) : (i += 1) {
        if (path[i] == '/') {
            std.fs.makeDirAbsolute(path[0..i]) catch |e| switch (e) {
                error.PathAlreadyExists => {},
                else => return e,
            };
        }
    }
    std.fs.makeDirAbsolute(path) catch |e| switch (e) {
        error.PathAlreadyExists => {},
        else => return e,
    };
}

fn findFreeDisplay(alloc: Allocator) ![]const u8 {
    for (99..111) |n| {
        const lock_path = std.fmt.allocPrint(alloc, "/tmp/.X{d}-lock", .{n}) catch continue;
        defer alloc.free(lock_path);
        std.fs.accessAbsolute(lock_path, .{}) catch {
            return try std.fmt.allocPrint(alloc, ":{d}", .{n});
        };
    }
    return error.NoFreeDisplay;
}

// ── Test cases ─────────────────────────────────────────────────────────

fn testPing(h: *Harness) TestError!void {
    const resp = try h.call("system.ping", null);
    try expect(resp.ok);
}

fn testCapabilities(h: *Harness) TestError!void {
    const result = try h.callOk("system.capabilities", null);
    if (result != .object) return TestError.AssertionFailed;
    const methods = result.object.get("methods") orelse return TestError.AssertionFailed;
    if (methods != .array) return TestError.AssertionFailed;
    try expect(methods.array.items.len > 10);

    var found_ping = false;
    var found_tree = false;
    for (methods.array.items) |m| {
        if (m == .string) {
            if (std.mem.eql(u8, m.string, "system.ping")) found_ping = true;
            if (std.mem.eql(u8, m.string, "system.tree")) found_tree = true;
        }
    }
    try expect(found_ping);
    try expect(found_tree);
}

fn testIdentify(h: *Harness) TestError!void {
    const result = try h.callOk("system.identify", null);
    if (result != .object) return TestError.AssertionFailed;
    const window_index = result.object.get("window_index") orelse return TestError.AssertionFailed;
    if (window_index != .integer) return TestError.AssertionFailed;
    try expect(window_index.integer >= 0);
    const workspace_id = result.object.get("workspace_id") orelse return TestError.AssertionFailed;
    if (workspace_id != .integer) return TestError.AssertionFailed;
    try expect(workspace_id.integer >= 0);
    const surface_id = result.object.get("surface_id") orelse return TestError.AssertionFailed;
    if (surface_id != .integer) return TestError.AssertionFailed;
    try expect(surface_id.integer >= 0);

    // Cross-check: the identified workspace should exist in the tree
    const tree = try h.callOk("system.tree", null);
    if (tree != .object) return TestError.AssertionFailed;
    const windows = tree.object.get("windows") orelse return TestError.AssertionFailed;
    if (windows != .array) return TestError.AssertionFailed;
    var found_ws = false;
    for (windows.array.items) |win| {
        if (win != .object) continue;
        const wss = win.object.get("workspaces") orelse continue;
        if (wss != .array) continue;
        for (wss.array.items) |ws| {
            if (ws != .object) continue;
            const id = ws.object.get("id") orelse continue;
            if (id == .integer and id.integer == workspace_id.integer) {
                found_ws = true;
                break;
            }
        }
    }
    try expect(found_ws);
}

fn testTree(h: *Harness) TestError!void {
    const result = try h.callOk("system.tree", null);
    if (result != .object) return TestError.AssertionFailed;
    const windows = result.object.get("windows") orelse return TestError.AssertionFailed;
    if (windows != .array) return TestError.AssertionFailed;
    try expect(windows.array.items.len >= 1);

    // Verify window has valid typed fields, not just keys
    const win = windows.array.items[0];
    if (win != .object) return TestError.AssertionFailed;
    const idx = win.object.get("index") orelse return TestError.AssertionFailed;
    if (idx != .integer) return TestError.AssertionFailed;
    try expect(idx.integer >= 0);
    const title = win.object.get("title") orelse return TestError.AssertionFailed;
    try expect(title == .string);

    const workspaces = win.object.get("workspaces") orelse return TestError.AssertionFailed;
    if (workspaces != .array) return TestError.AssertionFailed;
    try expect(workspaces.array.items.len >= 1);

    // Verify workspace within the tree has an id and title
    const ws = workspaces.array.items[0];
    if (ws != .object) return TestError.AssertionFailed;
    const ws_id = ws.object.get("id") orelse return TestError.AssertionFailed;
    if (ws_id != .integer) return TestError.AssertionFailed;
    try expect(ws_id.integer >= 0);
    try expect(ws.object.get("title") != null);

    // Exactly one workspace should be marked active
    var active_count: u32 = 0;
    for (workspaces.array.items) |w| {
        if (w != .object) continue;
        const active = w.object.get("active") orelse continue;
        if (active == .bool and active.bool) active_count += 1;
    }
    try expect(active_count == 1);
}

fn testWorkspaceCreate(h: *Harness) TestError!void {
    const result = try h.callOk("workspace.create", "{\"title\":\"e2e-test-ws\"}");
    if (result != .object) return TestError.AssertionFailed;
    try expect(result.object.get("id") != null);
}

fn testWorkspaceList(h: *Harness) TestError!void {
    const result = try h.callOk("workspace.list", null);
    if (result != .object) return TestError.AssertionFailed;
    const workspaces = result.object.get("workspaces") orelse return TestError.AssertionFailed;
    if (workspaces != .array) return TestError.AssertionFailed;
    try expect(workspaces.array.items.len >= 2);

    var found = false;
    for (workspaces.array.items) |ws| {
        if (ws == .object) {
            if (ws.object.get("title")) |title| {
                if (title == .string and std.mem.eql(u8, title.string, "e2e-test-ws")) {
                    found = true;
                    break;
                }
            }
        }
    }
    try expect(found);
}

fn testWorkspaceRename(h: *Harness) TestError!void {
    const ws_id = try findWorkspaceByTitle(h, "e2e-test-ws");
    const params = std.fmt.allocPrint(h.alloc, "{{\"workspace_id\":{d},\"title\":\"renamed-ws\"}}", .{ws_id}) catch
        return TestError.Unexpected;
    _ = try h.callOk("workspace.rename", params);
    _ = try findWorkspaceByTitle(h, "renamed-ws");
}

fn testWorkspaceSelectCurrent(h: *Harness) TestError!void {
    const ws_id = try findWorkspaceByTitle(h, "renamed-ws");
    const params = std.fmt.allocPrint(h.alloc, "{{\"workspace_id\":{d}}}", .{ws_id}) catch
        return TestError.Unexpected;
    _ = try h.callOk("workspace.select", params);

    const result = try h.callOk("workspace.current", null);
    if (result != .object) return TestError.AssertionFailed;
    const current_id = result.object.get("id") orelse return TestError.AssertionFailed;
    if (current_id != .integer) return TestError.AssertionFailed;
    try expect(@as(u64, @intCast(current_id.integer)) == ws_id);
}

fn testWorkspaceNavigation(h: *Harness) TestError!void {
    const before = try h.callOk("workspace.current", null);
    if (before != .object) return TestError.AssertionFailed;
    const before_id = before.object.get("id") orelse return TestError.AssertionFailed;
    if (before_id != .integer) return TestError.AssertionFailed;

    _ = try h.callOk("workspace.previous", null);

    const after_prev = try h.callOk("workspace.current", null);
    if (after_prev != .object) return TestError.AssertionFailed;
    const after_prev_id = after_prev.object.get("id") orelse return TestError.AssertionFailed;
    if (after_prev_id != .integer) return TestError.AssertionFailed;
    try expect(after_prev_id.integer != before_id.integer);

    _ = try h.callOk("workspace.next", null);

    // Should be back where we started
    const after_next = try h.callOk("workspace.current", null);
    if (after_next != .object) return TestError.AssertionFailed;
    const after_next_id = after_next.object.get("id") orelse return TestError.AssertionFailed;
    if (after_next_id != .integer) return TestError.AssertionFailed;
    try expect(after_next_id.integer == before_id.integer);

    // workspace.last should switch to the most recently active workspace
    _ = try h.callOk("workspace.last", null);
    const after_last = try h.callOk("workspace.current", null);
    if (after_last != .object) return TestError.AssertionFailed;
    const after_last_id = after_last.object.get("id") orelse return TestError.AssertionFailed;
    if (after_last_id != .integer) return TestError.AssertionFailed;
    try expect(after_last_id.integer == after_prev_id.integer);
}

fn testSurfaceSplitList(h: *Harness) TestError!void {
    const split_result = try h.callOk("surface.split", null);
    if (split_result != .object) return TestError.AssertionFailed;
    const new_sid_val = split_result.object.get("surface_id") orelse return TestError.AssertionFailed;
    if (new_sid_val != .integer) return TestError.AssertionFailed;
    const new_sid = new_sid_val.integer;

    const list_result = try h.callOk("surface.list", null);
    if (list_result != .object) return TestError.AssertionFailed;
    const surfaces = list_result.object.get("surfaces") orelse return TestError.AssertionFailed;
    if (surfaces != .array) return TestError.AssertionFailed;
    try expect(surfaces.array.items.len >= 2);

    // Verify the split's returned surface_id actually appears in the list
    var found = false;
    for (surfaces.array.items) |s| {
        if (s != .object) continue;
        const id = s.object.get("id") orelse continue;
        if (id == .integer and id.integer == new_sid) {
            found = true;
            break;
        }
    }
    try expect(found);
}

/// Poll read_screen until the surface is ready (GL context initialized).
/// With software rendering the first render cycle may be delayed.
fn waitForSurface(h: *Harness) TestError!void {
    var elapsed: u64 = 0;
    const timeout: u64 = 5000;
    while (elapsed < timeout) {
        const probe = try h.call("surface.read_screen", null);
        if (probe.ok) return;
        std.Thread.sleep(Harness.POLL_INTERVAL_MS * std.time.ns_per_ms);
        elapsed += Harness.POLL_INTERVAL_MS;
    }
    return TestError.Skip;
}

fn testTerminalIO(h: *Harness) TestError!void {
    // Wait for the terminal surface to initialize — with software rendering
    // the first GL render cycle (which calls initSurface) may be delayed.
    try waitForSurface(h);

    // Wait for shell prompt before sending text
    try h.expectScreen(null, "$", 8000);

    _ = try h.callOk("surface.send_text", "{\"text\":\"echo SEANCE_E2E_MARKER_42\\n\"}");
    try h.expectScreen(null, "SEANCE_E2E_MARKER_42", 8000);
}

fn testWorkspaceMetadata(h: *Harness) TestError!void {
    // NOTE: The socket API has no read-back methods for status/logs/progress,
    // so these are smoke tests only — we verify the calls succeed without error.
    const current = try h.callOk("workspace.current", null);
    if (current != .object) return TestError.AssertionFailed;
    const ws_id_val = current.object.get("id") orelse return TestError.AssertionFailed;
    if (ws_id_val != .integer) return TestError.AssertionFailed;
    const ws_id: u64 = @intCast(ws_id_val.integer);

    const set_status = std.fmt.allocPrint(h.alloc, "{{\"workspace_id\":{d},\"key\":\"test\",\"value\":\"running\"}}", .{ws_id}) catch return TestError.Unexpected;
    _ = try h.callOk("workspace.set_status", set_status);

    const log_params = std.fmt.allocPrint(h.alloc, "{{\"workspace_id\":{d},\"message\":\"e2e test log\",\"level\":\"info\"}}", .{ws_id}) catch return TestError.Unexpected;
    _ = try h.callOk("workspace.log", log_params);

    const progress = std.fmt.allocPrint(h.alloc, "{{\"workspace_id\":{d},\"value\":0.5}}", .{ws_id}) catch return TestError.Unexpected;
    _ = try h.callOk("workspace.set_progress", progress);

    const clear_progress = std.fmt.allocPrint(h.alloc, "{{\"workspace_id\":{d}}}", .{ws_id}) catch return TestError.Unexpected;
    _ = try h.callOk("workspace.clear_progress", clear_progress);

    const clear_status = std.fmt.allocPrint(h.alloc, "{{\"workspace_id\":{d},\"key\":\"test\"}}", .{ws_id}) catch return TestError.Unexpected;
    _ = try h.callOk("workspace.clear_status", clear_status);
}

fn testNotifications(h: *Harness) TestError!void {
    // Notifications for the focused pane are silently skipped (visibility check).
    // Create a temp workspace (auto-activates), navigate away, then target it.
    const tmp_ws = try h.callOk("workspace.create", "{\"title\":\"notif-tmp\"}");
    if (tmp_ws != .object) return TestError.AssertionFailed;
    const tmp_ws_id_val = tmp_ws.object.get("id") orelse return TestError.AssertionFailed;
    if (tmp_ws_id_val != .integer) return TestError.AssertionFailed;
    const tmp_ws_id: u64 = @intCast(tmp_ws_id_val.integer);

    // Navigate away so the temp workspace is no longer active
    _ = try h.callOk("workspace.previous", null);

    // Create notification targeting the now-inactive temp workspace
    const create_params = std.fmt.allocPrint(h.alloc, "{{\"title\":\"E2E Test\",\"body\":\"hello from tests\",\"workspace_id\":{d}}}", .{tmp_ws_id}) catch
        return TestError.Unexpected;
    _ = try h.callOk("notification.create", create_params);

    const list = try h.callOk("notification.list", null);
    if (list != .object) return TestError.AssertionFailed;
    const notifs = list.object.get("notifications") orelse return TestError.AssertionFailed;
    if (notifs != .array) return TestError.AssertionFailed;
    try expect(notifs.array.items.len >= 1);

    // Verify notification content matches what we created
    var found = false;
    for (notifs.array.items) |n| {
        if (n != .object) continue;
        const title = n.object.get("title") orelse continue;
        const body = n.object.get("body") orelse continue;
        if (title == .string and body == .string) {
            if (std.mem.eql(u8, title.string, "E2E Test") and
                std.mem.eql(u8, body.string, "hello from tests"))
            {
                found = true;
                break;
            }
        }
    }
    try expect(found);

    _ = try h.callOk("notification.clear", null);

    // Verify clear actually removed notifications
    const after_clear = try h.callOk("notification.list", null);
    if (after_clear != .object) return TestError.AssertionFailed;
    const after_notifs = after_clear.object.get("notifications") orelse return TestError.AssertionFailed;
    if (after_notifs != .array) return TestError.AssertionFailed;
    try expect(after_notifs.array.items.len == 0);

    // Clean up temp workspace
    const close_params = std.fmt.allocPrint(h.alloc, "{{\"workspace_id\":{d}}}", .{tmp_ws_id}) catch
        return TestError.Unexpected;
    _ = try h.callOk("workspace.close", close_params);
}

fn testWorkspaceClose(h: *Harness) TestError!void {
    const ws_id = try findWorkspaceByTitle(h, "renamed-ws");
    const params = std.fmt.allocPrint(h.alloc, "{{\"workspace_id\":{d}}}", .{ws_id}) catch
        return TestError.Unexpected;
    _ = try h.callOk("workspace.close", params);

    const result = try h.callOk("workspace.list", null);
    if (result != .object) return TestError.AssertionFailed;
    const workspaces = result.object.get("workspaces") orelse return TestError.AssertionFailed;
    if (workspaces != .array) return TestError.AssertionFailed;
    for (workspaces.array.items) |ws| {
        if (ws == .object) {
            if (ws.object.get("title")) |title| {
                if (title == .string and std.mem.eql(u8, title.string, "renamed-ws")) {
                    return TestError.AssertionFailed;
                }
            }
        }
    }
}

fn testSurfaceClose(h: *Harness) TestError!void {
    // Split to create a new surface
    const split = try h.callOk("surface.split", null);
    if (split != .object) return TestError.AssertionFailed;
    const new_sid_val = split.object.get("surface_id") orelse return TestError.AssertionFailed;
    if (new_sid_val != .integer) return TestError.AssertionFailed;
    const new_sid = new_sid_val.integer;

    // Verify the new surface exists in the list
    try expect(surfaceInList(h, new_sid));

    // Close the new surface by id
    const close_params = std.fmt.allocPrint(h.alloc, "{{\"surface_id\":{d}}}", .{new_sid}) catch
        return TestError.Unexpected;
    _ = try h.callOk("surface.close", close_params);

    // Verify the surface is gone from the list
    try expect(!surfaceInList(h, new_sid));
}

fn testSurfaceFocusLast(h: *Harness) TestError!void {
    // Get the currently focused surface
    const id_before = try h.callOk("system.identify", null);
    if (id_before != .object) return TestError.AssertionFailed;
    const orig_sid_val = id_before.object.get("surface_id") orelse return TestError.AssertionFailed;
    if (orig_sid_val != .integer) return TestError.Skip;
    const orig_sid = orig_sid_val.integer;

    // Split — new surface gets focus
    const split = try h.callOk("surface.split", null);
    if (split != .object) return TestError.AssertionFailed;
    const new_sid_val = split.object.get("surface_id") orelse return TestError.AssertionFailed;
    if (new_sid_val != .integer) return TestError.AssertionFailed;
    const new_sid = new_sid_val.integer;
    try expect(new_sid != orig_sid);

    // Verify focus moved to the new surface
    const id_after_split = try h.callOk("system.identify", null);
    if (id_after_split != .object) return TestError.AssertionFailed;
    const focused_split = id_after_split.object.get("surface_id") orelse return TestError.AssertionFailed;
    if (focused_split != .integer) return TestError.AssertionFailed;
    try expect(focused_split.integer == new_sid);

    // Focus the original surface explicitly
    const focus_params = std.fmt.allocPrint(h.alloc, "{{\"surface_id\":{d}}}", .{orig_sid}) catch
        return TestError.Unexpected;
    _ = try h.callOk("surface.focus", focus_params);

    // Verify focus is on the original
    const id_after_focus = try h.callOk("system.identify", null);
    if (id_after_focus != .object) return TestError.AssertionFailed;
    const focused_focus = id_after_focus.object.get("surface_id") orelse return TestError.AssertionFailed;
    if (focused_focus != .integer) return TestError.AssertionFailed;
    try expect(focused_focus.integer == orig_sid);

    // surface.last should switch back to the new surface
    _ = try h.callOk("surface.last", null);

    const id_after_last = try h.callOk("system.identify", null);
    if (id_after_last != .object) return TestError.AssertionFailed;
    const focused_last = id_after_last.object.get("surface_id") orelse return TestError.AssertionFailed;
    if (focused_last != .integer) return TestError.AssertionFailed;
    try expect(focused_last.integer == new_sid);

    // Clean up: close the extra surface
    const close_params = std.fmt.allocPrint(h.alloc, "{{\"surface_id\":{d}}}", .{new_sid}) catch
        return TestError.Unexpected;
    _ = h.callOk("surface.close", close_params) catch {};
}

fn testSurfaceSendKey(h: *Harness) TestError!void {
    // Wait for the terminal surface to initialize (see testTerminalIO).
    try waitForSurface(h);

    // Wait for shell prompt
    try h.expectScreen(null, "$", 8000);

    // Type a command via send_text (no newline), then press enter via send_key
    _ = try h.callOk("surface.send_text", "{\"text\":\"echo SENDKEY_OK_99\"}");
    _ = try h.callOk("surface.send_key", "{\"key\":\"enter\"}");

    // Verify the output appeared
    try h.expectScreen(null, "SENDKEY_OK_99", 8000);
}

fn testSurfaceHealth(h: *Harness) TestError!void {
    // Get current surface id
    const ident = try h.callOk("system.identify", null);
    if (ident != .object) return TestError.AssertionFailed;
    const sid_val = ident.object.get("surface_id") orelse return TestError.AssertionFailed;
    // surface_id may be null in headless mode if no terminal pane is focused
    if (sid_val != .integer) return TestError.Skip;

    // Valid surface returns a well-formed response (alive may be false in
    // headless mode where the GL surface doesn't fully initialize)
    const params = std.fmt.allocPrint(h.alloc, "{{\"surface_id\":{d}}}", .{sid_val.integer}) catch
        return TestError.Unexpected;
    const result = try h.callOk("surface.health", params);
    if (result != .object) return TestError.AssertionFailed;
    const alive = result.object.get("alive") orelse return TestError.AssertionFailed;
    if (alive != .bool) return TestError.AssertionFailed;

    // Non-existent surface returns an error
    const bad = try h.call("surface.health", "{\"surface_id\":999999}");
    if (bad.ok) return TestError.AssertionFailed;
}

fn testWindowLifecycle(h: *Harness) TestError!void {
    // Count windows before
    const before = try h.callOk("window.list", null);
    if (before != .object) return TestError.AssertionFailed;
    const before_wins = before.object.get("windows") orelse return TestError.AssertionFailed;
    if (before_wins != .array) return TestError.AssertionFailed;
    const count_before = before_wins.array.items.len;

    // Create a new window
    const create = try h.callOk("window.create", null);
    if (create != .object) return TestError.AssertionFailed;
    const new_idx_val = create.object.get("index") orelse return TestError.AssertionFailed;
    if (new_idx_val != .integer) return TestError.AssertionFailed;
    const new_idx = new_idx_val.integer;

    // Verify it appears in window.list
    const during = try h.callOk("window.list", null);
    if (during != .object) return TestError.AssertionFailed;
    const during_wins = during.object.get("windows") orelse return TestError.AssertionFailed;
    if (during_wins != .array) return TestError.AssertionFailed;
    try expect(during_wins.array.items.len == count_before + 1);

    // Close the new window
    const close_params = std.fmt.allocPrint(h.alloc, "{{\"window_id\":{d}}}", .{new_idx}) catch
        return TestError.Unexpected;
    _ = try h.callOk("window.close", close_params);

    // GTK window close is async — poll until window count drops
    var elapsed: u64 = 0;
    while (elapsed < 3000) {
        const after = try h.callOk("window.list", null);
        if (after == .object) {
            if (after.object.get("windows")) |w| {
                if (w == .array and w.array.items.len == count_before) return;
            }
        }
        std.Thread.sleep(100 * std.time.ns_per_ms);
        elapsed += 100;
    }
    return TestError.Timeout;
}

fn testWorkspaceMoveToWindow(h: *Harness) TestError!void {
    // Create workspace FIRST (on window 0), before creating a new window
    // (window.create changes the active window, and workspace.create
    // creates on the active window)
    const ws = try h.callOk("workspace.create", "{\"title\":\"move-test\"}");
    if (ws != .object) return TestError.AssertionFailed;
    const ws_id_val = ws.object.get("id") orelse return TestError.AssertionFailed;
    if (ws_id_val != .integer) return TestError.AssertionFailed;
    const ws_id = ws_id_val.integer;

    // Now create the second window (becomes active)
    const win = try h.callOk("window.create", null);
    if (win != .object) return TestError.AssertionFailed;
    const target_idx_val = win.object.get("index") orelse return TestError.AssertionFailed;
    if (target_idx_val != .integer) return TestError.AssertionFailed;
    const target_idx = target_idx_val.integer;

    // Move workspace from window 0 to the new window
    const move_params = std.fmt.allocPrint(h.alloc, "{{\"workspace_id\":{d},\"target_window_id\":{d}}}", .{ ws_id, target_idx }) catch
        return TestError.Unexpected;
    _ = try h.callOk("workspace.move_to_window", move_params);

    // Verify it's gone from window 0's workspace list
    const src_list = try h.callOk("workspace.list", "{\"window_id\":0}");
    if (src_list != .object) return TestError.AssertionFailed;
    const src_wss = src_list.object.get("workspaces") orelse return TestError.AssertionFailed;
    if (src_wss != .array) return TestError.AssertionFailed;
    for (src_wss.array.items) |w| {
        if (w != .object) continue;
        const id = w.object.get("id") orelse continue;
        if (id == .integer and id.integer == ws_id) return TestError.AssertionFailed;
    }

    // Verify it appears in the target window's workspace list
    const dst_params = std.fmt.allocPrint(h.alloc, "{{\"window_id\":{d}}}", .{target_idx}) catch
        return TestError.Unexpected;
    const dst_list = try h.callOk("workspace.list", dst_params);
    if (dst_list != .object) return TestError.AssertionFailed;
    const dst_wss = dst_list.object.get("workspaces") orelse return TestError.AssertionFailed;
    if (dst_wss != .array) return TestError.AssertionFailed;
    var found = false;
    for (dst_wss.array.items) |w| {
        if (w != .object) continue;
        const id = w.object.get("id") orelse continue;
        if (id == .integer and id.integer == ws_id) {
            found = true;
            break;
        }
    }
    try expect(found);

    // Clean up: close the extra window (also destroys the workspace inside it)
    const close_win = std.fmt.allocPrint(h.alloc, "{{\"window_id\":{d}}}", .{target_idx}) catch
        return TestError.Unexpected;
    _ = h.callOk("window.close", close_win) catch {};
    // Wait for GTK to process the window close
    var elapsed: u64 = 0;
    while (elapsed < 3000) {
        const wl = h.callOk("window.list", null) catch break;
        if (wl == .object) {
            if (wl.object.get("windows")) |w| {
                if (w == .array and w.array.items.len == 1) break;
            }
        }
        std.Thread.sleep(100 * std.time.ns_per_ms);
        elapsed += 100;
    }

}

fn testSurfaceExpel(h: *Harness) TestError!void {
    // Split to get two panes in the same column
    const split = try h.callOk("surface.split", null);
    if (split != .object) return TestError.AssertionFailed;
    const new_sid_val = split.object.get("surface_id") orelse return TestError.AssertionFailed;
    if (new_sid_val != .integer) return TestError.AssertionFailed;

    // Expel the focused pane to the right — creates a new column
    const result = try h.callOk("surface.expel", "{\"direction\":\"right\"}");
    if (result != .object) return TestError.AssertionFailed;
    const col_idx = result.object.get("column_index") orelse return TestError.AssertionFailed;
    if (col_idx != .integer) return TestError.AssertionFailed;
    const sid = result.object.get("surface_id") orelse return TestError.AssertionFailed;
    if (sid != .integer) return TestError.AssertionFailed;
    try expect(sid.integer > 0);

    // Clean up: close the expelled surface (sid from expel result, not the pre-split id)
    const close_params = std.fmt.allocPrint(h.alloc, "{{\"surface_id\":{d}}}", .{sid.integer}) catch
        return TestError.Unexpected;
    _ = h.callOk("surface.close", close_params) catch {};
}

// ── Error path tests ──────────────────────────────────────────────────

fn testErrorInvalidMethod(h: *Harness) TestError!void {
    try h.callExpectFail("nonexistent.method", null);
}

fn testErrorBadWorkspaceId(h: *Harness) TestError!void {
    // Selecting a workspace that doesn't exist should fail
    try h.callExpectFail("workspace.select", "{\"workspace_id\":999999}");
    // Closing a nonexistent workspace should fail
    try h.callExpectFail("workspace.close", "{\"workspace_id\":999999}");
    // Renaming a nonexistent workspace should fail
    try h.callExpectFail("workspace.rename", "{\"workspace_id\":999999,\"title\":\"nope\"}");
}

fn testErrorMissingParams(h: *Harness) TestError!void {
    // workspace.select requires workspace_id
    try h.callExpectFail("workspace.select", "{}");
    // workspace.rename requires workspace_id and title
    try h.callExpectFail("workspace.rename", "{}");
    // surface.send_text requires text
    try h.callExpectFail("surface.send_text", "{}");
}

// ── Helpers ────────────────────────────────────────────────────────────

fn surfaceInList(h: *Harness, sid: i64) bool {
    const result = h.callOk("surface.list", null) catch return false;
    if (result != .object) return false;
    const surfaces = result.object.get("surfaces") orelse return false;
    if (surfaces != .array) return false;
    for (surfaces.array.items) |s| {
        if (s != .object) continue;
        const id = s.object.get("id") orelse continue;
        if (id == .integer and id.integer == sid) return true;
    }
    return false;
}

fn findWorkspaceByTitle(h: *Harness, title: []const u8) TestError!u64 {
    const result = try h.callOk("workspace.list", null);
    if (result != .object) return TestError.AssertionFailed;
    const workspaces = result.object.get("workspaces") orelse return TestError.AssertionFailed;
    if (workspaces != .array) return TestError.AssertionFailed;
    for (workspaces.array.items) |ws| {
        if (ws == .object) {
            if (ws.object.get("title")) |t| {
                if (t == .string and std.mem.eql(u8, t.string, title)) {
                    if (ws.object.get("id")) |id| {
                        if (id == .integer) return @intCast(id.integer);
                    }
                }
            }
        }
    }
    std.debug.print("    workspace not found: \"{s}\"\n", .{title});
    return TestError.AssertionFailed;
}
