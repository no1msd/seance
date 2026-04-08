const std = @import("std");
const ErrorBuf = @import("error_buf.zig").ErrorBuf;

pub const SidebarPosition = enum { left, right };
pub const CursorShape = enum { block, ibeam, underline };
pub const DecorationMode = enum { auto, csd, ssd };
pub const NotificationSound = union(enum) {
    default,
    none,
    bell,
    dialog_warning,
    complete,
    custom: struct {
        path: [256]u8 = [_]u8{0} ** 256,
        path_len: usize = 0,
    },
};

pub const Config = struct {
    // Font
    font_family: [128]u8 = [_]u8{0} ** 128,
    font_family_len: usize = 0,
    font_size: ?f64 = null,

    // Theme
    theme: [64]u8 = [_]u8{0} ** 64,
    theme_len: usize = 0,
    background_opacity: f64 = 1.0,

    // Window
    window_padding_x: ?u32 = null,
    window_padding_y: ?u32 = null,
    decoration_mode: DecorationMode = .auto,

    // Sidebar
    sidebar_position: SidebarPosition = .left,
    sidebar_width: u32 = 240,
    sidebar_visible: bool = true,
    sidebar_show_notification_text: bool = true,
    sidebar_show_status: bool = true,
    sidebar_show_logs: bool = true,
    sidebar_show_progress: bool = true,
    sidebar_show_branch: bool = true,
    sidebar_show_ports: bool = true,

    // Terminal
    scrollback_lines: u32 = 10000,
    cursor_shape: CursorShape = .block,
    cursor_blink: bool = true,

    // Behavior
    bell_notification: bool = true,
    desktop_notifications: bool = true,
    focus_follows_mouse: bool = false,
    confirm_close_window: bool = true,
    // Claude Code integration
    claude_code_hooks: bool = true,

    // Codex CLI integration
    codex_hooks: bool = true,

    // Notifications
    notification_sound: NotificationSound = .default,

    // Workspace

    // Socket
    socket_path: [256]u8 = [_]u8{0} ** 256,
    socket_path_len: usize = 0,

    // Ports
    port_base: u32 = 9100,
    port_range: u32 = 10,
};

var global: Config = .{};

var load_error: ErrorBuf("Config error (details too long)") = .{};

pub fn getLoadError() ?[*:0]const u8 {
    return load_error.get();
}

pub fn clearLoadError() void {
    load_error.clear();
}

/// Return the seance config directory, respecting XDG_CONFIG_HOME.
fn configDir(buf: []u8) ?[]const u8 {
    if (std.posix.getenv("XDG_CONFIG_HOME")) |xdg| {
        return std.fmt.bufPrint(buf, "{s}/seance", .{xdg}) catch null;
    }
    const home = std.posix.getenv("HOME") orelse return null;
    return std.fmt.bufPrint(buf, "{s}/.config/seance", .{home}) catch null;
}

/// Return the runtime directory for ephemeral files (sockets, scrollback replay, temp configs).
/// Prefers XDG_RUNTIME_DIR, falls back to /tmp.
pub fn runtimeDir() []const u8 {
    return std.posix.getenv("XDG_RUNTIME_DIR") orelse "/tmp";
}

pub fn load() Config {
    load_error.clear(); // Clear previous error
    var config = Config{};

    var dir_buf: [std.fs.max_path_bytes]u8 = undefined;
    const dir = configDir(&dir_buf) orelse {
        const home = std.posix.getenv("HOME") orelse {
            std.log.warn("config: HOME not set, using defaults", .{});
            global = config;
            return config;
        };
        loadGhosttyConfig(&config, home);
        global = config;
        return config;
    };

    var path_buf: [std.fs.max_path_bytes]u8 = undefined;
    const path = std.fmt.bufPrint(&path_buf, "{s}/config.toml", .{dir}) catch {
        std.log.err("config: config path exceeds max path length", .{});
        load_error.set("Config path too long — using defaults", .{});
        global = config;
        return config;
    };

    const file = std.fs.openFileAbsolute(path, .{}) catch |e| {
        if (e != error.FileNotFound) {
            std.log.err("config: failed to open {s}: {s}", .{ path, @errorName(e) });
            load_error.set("Could not open config.toml: {s}", .{@errorName(e)});
        }
        // Fallback to Ghostty config
        if (std.posix.getenv("HOME")) |home| loadGhosttyConfig(&config, home);
        global = config;
        return config;
    };
    defer file.close();

    const stat = file.stat() catch |e| {
        std.log.err("config: stat failed on config.toml: {s}", .{@errorName(e)});
        load_error.set("Could not read config.toml: {s}", .{@errorName(e)});
        global = config;
        return config;
    };
    const file_size = @min(stat.size, 1024 * 1024); // cap at 1 MB
    var alloc_buf = std.heap.page_allocator.alloc(u8, file_size) catch {
        // Fallback to fixed buffer for small configs
        std.log.warn("config: allocation failed for {d} bytes, using fixed buffer", .{file_size});
        var buf: [8192]u8 = undefined;
        const n = file.readAll(&buf) catch |e| {
            std.log.err("config: readAll failed: {s}", .{@errorName(e)});
            load_error.set("Could not read config.toml: {s}", .{@errorName(e)});
            global = config;
            return config;
        };
        parseToml(&config, buf[0..n]);
        global = config;
        return config;
    };
    defer std.heap.page_allocator.free(alloc_buf);
    const n = file.readAll(alloc_buf) catch |e| {
        std.log.err("config: readAll failed: {s}", .{@errorName(e)});
        load_error.set("Could not read config.toml: {s}", .{@errorName(e)});
        global = config;
        return config;
    };
    parseToml(&config, alloc_buf[0..n]);

    global = config;
    return config;
}

pub fn reloadConfig() Config {
    return load();
}

pub fn get() *const Config {
    return &global;
}

pub fn getMut() *Config {
    return &global;
}

pub fn saveConfig(cfg: *const Config) void {
    var dir_buf2: [std.fs.max_path_bytes]u8 = undefined;
    const dir_path = configDir(&dir_buf2) orelse {
        std.log.warn("config: cannot save — config dir unavailable", .{});
        return;
    };
    std.fs.cwd().makePath(dir_path) catch |e| {
        std.log.warn("config: failed to create config dir: {s}", .{@errorName(e)});
        return;
    };

    var path_buf: [std.fs.max_path_bytes]u8 = undefined;
    const file_path = std.fmt.bufPrint(&path_buf, "{s}/config.toml", .{dir_path}) catch {
        std.log.warn("config: cannot save — path too long", .{});
        return;
    };

    // Write to a temp file first, then rename for atomic save
    var tmp_buf: [std.fs.max_path_bytes]u8 = undefined;
    const tmp_path = std.fmt.bufPrint(&tmp_buf, "{s}/config.toml.tmp", .{dir_path}) catch {
        std.log.warn("config: cannot save — tmp path too long", .{});
        return;
    };

    const file = std.fs.createFileAbsolute(tmp_path, .{}) catch |e| {
        std.log.warn("config: cannot create temp file for save: {s}", .{@errorName(e)});
        return;
    };
    defer file.close();

    var buf: [16384]u8 = undefined;
    var fbs = std.io.fixedBufferStream(&buf);
    const w = fbs.writer();

    // [font]
    w.print("[font]\n", .{}) catch return;
    if (cfg.font_family_len > 0) w.print("family = \"{s}\"\n", .{cfg.font_family[0..cfg.font_family_len]}) catch return;
    if (cfg.font_size) |fs| {
        w.print("size = ", .{}) catch return;
        writeFloat(w, fs) catch return;
        w.print("\n", .{}) catch return;
    }

    // [colors]
    w.print("\n[colors]\n", .{}) catch return;
    if (cfg.theme_len > 0) w.print("theme = \"{s}\"\n", .{cfg.theme[0..cfg.theme_len]}) catch return;
    w.print("background-opacity = ", .{}) catch return;
    writeFloat(w, cfg.background_opacity) catch return;
    w.print("\n", .{}) catch return;

    // [window]
    w.print("\n[window]\n", .{}) catch return;
    if (cfg.window_padding_x) |px| w.print("padding-x = {d}\n", .{px}) catch return;
    if (cfg.window_padding_y) |py| w.print("padding-y = {d}\n", .{py}) catch return;
    w.print("decoration-mode = \"{s}\"\n", .{@tagName(cfg.decoration_mode)}) catch return;

    // [sidebar]
    w.print("\n[sidebar]\n", .{}) catch return;
    w.print("position = \"{s}\"\n", .{if (cfg.sidebar_position == .right) @as([]const u8, "right") else @as([]const u8, "left")}) catch return;
    w.print("width = {d}\n", .{cfg.sidebar_width}) catch return;
    writeBool(w, "visible", cfg.sidebar_visible) catch return;
    writeBool(w, "show-notification-text", cfg.sidebar_show_notification_text) catch return;
    writeBool(w, "show-status", cfg.sidebar_show_status) catch return;
    writeBool(w, "show-logs", cfg.sidebar_show_logs) catch return;
    writeBool(w, "show-progress", cfg.sidebar_show_progress) catch return;
    writeBool(w, "show-branch", cfg.sidebar_show_branch) catch return;
    writeBool(w, "show-ports", cfg.sidebar_show_ports) catch return;

    // [terminal]
    w.print("\n[terminal]\nscrollback-lines = {d}\n", .{cfg.scrollback_lines}) catch return;
    w.print("cursor-shape = \"{s}\"\n", .{@tagName(cfg.cursor_shape)}) catch return;
    writeBool(w, "cursor-blink", cfg.cursor_blink) catch return;

    // [behavior]
    w.print("\n[behavior]\n", .{}) catch return;
    writeBool(w, "bell-notification", cfg.bell_notification) catch return;
    writeBool(w, "desktop-notifications", cfg.desktop_notifications) catch return;
    writeBool(w, "focus-follows-mouse", cfg.focus_follows_mouse) catch return;
    writeBool(w, "confirm-close-window", cfg.confirm_close_window) catch return;
    writeBool(w, "claude-code-hooks", cfg.claude_code_hooks) catch return;
    writeBool(w, "codex-hooks", cfg.codex_hooks) catch return;

    // [notifications]
    w.print("\n[notifications]\n", .{}) catch return;
    switch (cfg.notification_sound) {
        .default => w.print("sound = \"default\"\n", .{}) catch return,
        .none => w.print("sound = \"none\"\n", .{}) catch return,
        .bell => w.print("sound = \"bell\"\n", .{}) catch return,
        .dialog_warning => w.print("sound = \"dialog-warning\"\n", .{}) catch return,
        .complete => w.print("sound = \"complete\"\n", .{}) catch return,
        .custom => |cs| w.print("sound = \"{s}\"\n", .{cs.path[0..cs.path_len]}) catch return,
    }

    // [socket]
    w.print("\n[socket]\n", .{}) catch return;
    if (cfg.socket_path_len > 0) w.print("path = \"{s}\"\n", .{cfg.socket_path[0..cfg.socket_path_len]}) catch return;
    w.print("port-base = {d}\nport-range = {d}\n", .{ cfg.port_base, cfg.port_range }) catch return;

    // [keybinds]
    w.print("\n", .{}) catch return;
    const keybinds_mod = @import("keybinds.zig");
    keybinds_mod.writeKeybinds(w) catch return;

    file.writeAll(fbs.getWritten()) catch |e| {
        std.log.warn("config: failed to write config file: {s}", .{@errorName(e)});
        return;
    };

    // Atomic rename: tmp → final. If we crash before this, the old config is intact.
    std.fs.renameAbsolute(tmp_path, file_path) catch |e| {
        std.log.warn("config: atomic rename failed: {s}", .{@errorName(e)});
    };
}

fn writeFloat(writer: anytype, val: f64) !void {
    const cents: u64 = @intFromFloat(@round(@abs(val) * 100.0));
    if (val < 0) try writer.writeByte('-');
    try writer.print("{d}.{:0>2}", .{ cents / 100, cents % 100 });
}

fn writeBool(writer: anytype, key: []const u8, val: bool) !void {
    try writer.print("{s} = {s}\n", .{ key, if (val) @as([]const u8, "true") else @as([]const u8, "false") });
}

fn parseToml(config: *Config, content: []const u8) void {
    var current_section: []const u8 = "";
    var line_num: usize = 0;
    var lines = std.mem.splitScalar(u8, content, '\n');
    while (lines.next()) |line| {
        line_num += 1;
        const trimmed = std.mem.trim(u8, line, " \t\r");
        if (trimmed.len == 0 or trimmed[0] == '#') continue;
        if (trimmed[0] == '[') {
            if (std.mem.indexOfScalar(u8, trimmed, ']')) |end| {
                const section = trimmed[1..end];
                if (!isKnownSection(section)) {
                    load_error.set("config.toml line {d}: unknown section [{s}]", .{ line_num, section });
                    std.log.warn("config: line {d}: unknown section [{s}]", .{ line_num, section });
                    return;
                }
                current_section = section;
            } else {
                load_error.set("config.toml line {d}: malformed section header", .{line_num});
                std.log.warn("config: line {d}: malformed section header", .{line_num});
                return;
            }
            continue;
        }
        if (std.mem.indexOfScalar(u8, trimmed, '=')) |eq| {
            const key = std.mem.trim(u8, trimmed[0..eq], " \t");
            const val = std.mem.trim(u8, trimmed[eq + 1 ..], " \t");
            // Detect unterminated quotes
            if (val.len >= 1 and val[0] == '"' and (val.len < 2 or val[val.len - 1] != '"')) {
                load_error.set("config.toml line {d}: unterminated quote for \"{s}\"", .{ line_num, key });
                std.log.warn("config: line {d}: unterminated quote for \"{s}\"", .{ line_num, key });
                return;
            }
            if (!applyValue(config, current_section, key, val)) {
                if (current_section.len == 0) {
                    load_error.set("config.toml line {d}: unexpected key \"{s}\" (missing section header?)", .{ line_num, key });
                    std.log.warn("config: line {d}: unexpected key \"{s}\" outside any section", .{ line_num, key });
                } else {
                    load_error.set("config.toml line {d}: unknown key \"{s}\" in [{s}]", .{ line_num, key, current_section });
                    std.log.warn("config: line {d}: unknown key \"{s}\" in [{s}]", .{ line_num, key, current_section });
                }
                return;
            }
        } else {
            load_error.set("config.toml line {d}: syntax error", .{line_num});
            std.log.warn("config: line {d}: syntax error (no '=' found)", .{line_num});
            return;
        }
    }
}

fn isKnownSection(section: []const u8) bool {
    const known = [_][]const u8{ "font", "colors", "window", "sidebar", "terminal", "behavior", "notifications", "socket", "keybinds" };
    for (known) |s| {
        if (eql(section, s)) return true;
    }
    return false;
}

fn applyValue(config: *Config, section: []const u8, key: []const u8, raw_val: []const u8) bool {
    const val = stripQuotes(raw_val);

    if (eql(section, "font")) {
        if (eql(key, "family")) {
            setStr(&config.font_family, &config.font_family_len, val); return true;
        } else if (eql(key, "size")) {
            if (parseFloat(val)) |f| config.font_size = f;
            return true;
        }
    } else if (eql(section, "colors")) {
        if (eql(key, "theme")) {
            setStr(&config.theme, &config.theme_len, val); return true;
        } else if (eql(key, "background-opacity")) {
            config.background_opacity = parseFloat(val) orelse config.background_opacity; return true;
        }
    } else if (eql(section, "window")) {
        if (eql(key, "padding-x")) {
            config.window_padding_x = parseU32(val) orelse config.window_padding_x; return true;
        } else if (eql(key, "padding-y")) {
            config.window_padding_y = parseU32(val) orelse config.window_padding_y; return true;
        } else if (eql(key, "decoration-mode")) {
            config.decoration_mode = if (eql(val, "csd"))
                .csd
            else if (eql(val, "ssd"))
                .ssd
            else
                .auto;
            return true;
        }
    } else if (eql(section, "sidebar")) {
        if (eql(key, "position")) {
            config.sidebar_position = if (eql(val, "right")) .right else .left; return true;
        } else if (eql(key, "width")) {
            config.sidebar_width = parseU32(val) orelse config.sidebar_width; return true;
        } else if (eql(key, "visible")) {
            config.sidebar_visible = parseBool(val) orelse config.sidebar_visible; return true;
        } else if (eql(key, "show-notification-text")) {
            config.sidebar_show_notification_text = parseBool(val) orelse config.sidebar_show_notification_text; return true;
        } else if (eql(key, "show-status")) {
            config.sidebar_show_status = parseBool(val) orelse config.sidebar_show_status; return true;
        } else if (eql(key, "show-logs")) {
            config.sidebar_show_logs = parseBool(val) orelse config.sidebar_show_logs; return true;
        } else if (eql(key, "show-progress")) {
            config.sidebar_show_progress = parseBool(val) orelse config.sidebar_show_progress; return true;
        } else if (eql(key, "show-branch")) {
            config.sidebar_show_branch = parseBool(val) orelse config.sidebar_show_branch; return true;
        } else if (eql(key, "show-ports")) {
            config.sidebar_show_ports = parseBool(val) orelse config.sidebar_show_ports; return true;
        }
    } else if (eql(section, "terminal")) {
        if (eql(key, "scrollback-lines")) {
            config.scrollback_lines = parseU32(val) orelse config.scrollback_lines; return true;
        } else if (eql(key, "cursor-shape")) {
            config.cursor_shape = if (eql(val, "ibeam"))
                .ibeam
            else if (eql(val, "underline"))
                .underline
            else
                .block;
            return true;
        } else if (eql(key, "cursor-blink")) {
            config.cursor_blink = parseBool(val) orelse config.cursor_blink; return true;
        }
    } else if (eql(section, "behavior")) {
        if (eql(key, "bell-notification")) {
            config.bell_notification = parseBool(val) orelse config.bell_notification; return true;
        } else if (eql(key, "desktop-notifications")) {
            config.desktop_notifications = parseBool(val) orelse config.desktop_notifications; return true;
        } else if (eql(key, "focus-follows-mouse")) {
            config.focus_follows_mouse = parseBool(val) orelse config.focus_follows_mouse; return true;
        } else if (eql(key, "confirm-close-window")) {
            config.confirm_close_window = parseBool(val) orelse config.confirm_close_window; return true;
        } else if (eql(key, "claude-code-hooks")) {
            config.claude_code_hooks = parseBool(val) orelse config.claude_code_hooks; return true;
        } else if (eql(key, "codex-hooks")) {
            config.codex_hooks = parseBool(val) orelse config.codex_hooks; return true;
        }
    } else if (eql(section, "notifications")) {
        if (eql(key, "sound")) {
            config.notification_sound = parseNotificationSound(val); return true;
        }
    } else if (eql(section, "socket")) {
        if (eql(key, "path")) {
            setStr(&config.socket_path, &config.socket_path_len, val); return true;
        } else if (eql(key, "port-base")) {
            config.port_base = parseU32(val) orelse config.port_base; return true;
        } else if (eql(key, "port-range")) {
            config.port_range = parseU32(val) orelse config.port_range; return true;
        }
    } else if (eql(section, "keybinds")) {
        const keybinds = @import("keybinds.zig");
        return keybinds.applyConfigOverride(key, val);
    }
    // Key in a known section but not recognized, or key in root (empty section)
    return false;
}

fn loadGhosttyConfig(config: *Config, home: []const u8) void {
    var path_buf: [std.fs.max_path_bytes]u8 = undefined;
    const path = std.fmt.bufPrint(&path_buf, "{s}/.config/ghostty/config", .{home}) catch return;

    const file = std.fs.openFileAbsolute(path, .{}) catch return;
    defer file.close();

    var buf: [8192]u8 = undefined;
    const n = file.readAll(&buf) catch return;
    const content = buf[0..n];

    var lines = std.mem.splitScalar(u8, content, '\n');
    while (lines.next()) |line| {
        const trimmed = std.mem.trim(u8, line, " \t\r");
        if (trimmed.len == 0 or trimmed[0] == '#') continue;
        if (std.mem.indexOfScalar(u8, trimmed, '=')) |eq| {
            const key = std.mem.trim(u8, trimmed[0..eq], " \t");
            const val = std.mem.trim(u8, trimmed[eq + 1 ..], " \t");
            applyGhosttyValue(config, key, val);
        }
    }
}

fn applyGhosttyValue(config: *Config, key: []const u8, val: []const u8) void {
    if (eql(key, "font-family")) {
        setStr(&config.font_family, &config.font_family_len, val);
    } else if (eql(key, "font-size")) {
        if (parseFloat(val)) |f| config.font_size = f;
    } else if (eql(key, "background-opacity")) {
        config.background_opacity = parseFloat(val) orelse config.background_opacity;
    } else if (eql(key, "cursor-style")) {
        config.cursor_shape = if (eql(val, "bar") or eql(val, "beam"))
            .ibeam
        else if (eql(val, "underline"))
            .underline
        else
            .block;
    } else if (eql(key, "scrollback-limit")) {
        config.scrollback_lines = parseU32(val) orelse config.scrollback_lines;
    } else if (eql(key, "theme")) {
        setStr(&config.theme, &config.theme_len, val);
    } else if (eql(key, "window-padding-x")) {
        config.window_padding_x = parseU32(val) orelse config.window_padding_x;
    } else if (eql(key, "window-padding-y")) {
        config.window_padding_y = parseU32(val) orelse config.window_padding_y;
    }
}

// Helpers

fn eql(a: []const u8, b: []const u8) bool {
    return std.mem.eql(u8, a, b);
}

fn stripQuotes(val: []const u8) []const u8 {
    if (val.len >= 2 and val[0] == '"' and val[val.len - 1] == '"') {
        return val[1 .. val.len - 1];
    }
    return val;
}

fn setStr(buf: []u8, len: *usize, val: []const u8) void {
    const n = @min(val.len, buf.len);
    @memcpy(buf[0..n], val[0..n]);
    len.* = n;
    if (val.len > buf.len) {
        std.log.warn("config: value truncated from {d} to {d} bytes", .{ val.len, buf.len });
    }
}

fn parseU32(val: []const u8) ?u32 {
    return std.fmt.parseInt(u32, val, 10) catch null;
}

fn parseFloat(val: []const u8) ?f64 {
    return std.fmt.parseFloat(f64, val) catch null;
}

fn parseBool(val: []const u8) ?bool {
    if (eql(val, "true")) return true;
    if (eql(val, "false")) return false;
    return null;
}

fn parseNotificationSound(val: []const u8) NotificationSound {
    if (eql(val, "default")) return .default;
    if (eql(val, "none")) return .none;
    if (eql(val, "bell")) return .bell;
    if (eql(val, "dialog-warning")) return .dialog_warning;
    if (eql(val, "complete")) return .complete;
    var custom: NotificationSound = .{ .custom = .{} };
    const n = @min(val.len, 256);
    @memcpy(custom.custom.path[0..n], val[0..n]);
    custom.custom.path_len = n;
    return custom;
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

test "parseToml: basic section and key-value parsing" {
    var cfg = Config{};
    parseToml(&cfg,
        \\[font]
        \\size = 16.5
        \\family = "Iosevka"
        \\
        \\[window]
        \\padding-x = 12
        \\padding-y = 8
    );
    try std.testing.expectEqual(@as(?f64, 16.5), cfg.font_size);
    try std.testing.expectEqualStrings("Iosevka", cfg.font_family[0..cfg.font_family_len]);
    try std.testing.expectEqual(@as(?u32, 12), cfg.window_padding_x);
    try std.testing.expectEqual(@as(?u32, 8), cfg.window_padding_y);
}

test "parseToml: comments and blank lines are skipped" {
    var cfg = Config{};
    parseToml(&cfg,
        \\# This is a comment
        \\
        \\[window]
        \\# padding comment
        \\padding-x = 16
        \\
        \\padding-y = 10
    );
    try std.testing.expectEqual(@as(?u32, 16), cfg.window_padding_x);
    try std.testing.expectEqual(@as(?u32, 10), cfg.window_padding_y);
}

test "parseToml: unknown section and keys are ignored" {
    var cfg = Config{};
    const defaults = Config{};
    parseToml(&cfg,
        \\[unknown_section]
        \\foo = bar
        \\
        \\[window]
        \\nonexistent_key = 999
    );
    // Defaults should be preserved
    try std.testing.expectEqual(defaults.window_padding_x, cfg.window_padding_x);
}

test "parseToml: all sidebar enum values" {
    var cfg = Config{};
    parseToml(&cfg,
        \\[sidebar]
        \\position = right
        \\show-branch = false
    );
    try std.testing.expectEqual(SidebarPosition.right, cfg.sidebar_position);
    try std.testing.expectEqual(false, cfg.sidebar_show_branch);
}

test "parseToml: terminal cursor shapes" {
    var cfg = Config{};

    parseToml(&cfg, "[terminal]\ncursor-shape = ibeam\n");
    try std.testing.expectEqual(CursorShape.ibeam, cfg.cursor_shape);

    parseToml(&cfg, "[terminal]\ncursor-shape = underline\n");
    try std.testing.expectEqual(CursorShape.underline, cfg.cursor_shape);

    parseToml(&cfg, "[terminal]\ncursor-shape = block\n");
    try std.testing.expectEqual(CursorShape.block, cfg.cursor_shape);
}

test "parseToml: boolean values in behavior section" {
    var cfg = Config{};
    parseToml(&cfg,
        \\[behavior]
        \\focus-follows-mouse = true
        \\confirm-close-window = false
    );
    try std.testing.expectEqual(true, cfg.focus_follows_mouse);
    try std.testing.expectEqual(false, cfg.confirm_close_window);
}

test "parseToml: notification sound variants" {
    var cfg = Config{};
    parseToml(&cfg, "[notifications]\nsound = none\n");
    try std.testing.expectEqual(NotificationSound.none, cfg.notification_sound);

    parseToml(&cfg, "[notifications]\nsound = bell\n");
    try std.testing.expectEqual(NotificationSound.bell, cfg.notification_sound);

    parseToml(&cfg, "[notifications]\nsound = dialog-warning\n");
    try std.testing.expectEqual(NotificationSound.dialog_warning, cfg.notification_sound);

    parseToml(&cfg, "[notifications]\nsound = /usr/share/sounds/beep.wav\n");
    switch (cfg.notification_sound) {
        .custom => |cs| try std.testing.expectEqualStrings("/usr/share/sounds/beep.wav", cs.path[0..cs.path_len]),
        else => return error.TestUnexpectedResult,
    }
}

test "stripQuotes: removes surrounding double quotes" {
    try std.testing.expectEqualStrings("hello", stripQuotes("\"hello\""));
}

test "stripQuotes: leaves unquoted values unchanged" {
    try std.testing.expectEqualStrings("hello", stripQuotes("hello"));
}

test "stripQuotes: single character not stripped" {
    try std.testing.expectEqualStrings("x", stripQuotes("x"));
    try std.testing.expectEqualStrings("\"", stripQuotes("\""));
}

test "parseBool: valid values" {
    try std.testing.expectEqual(@as(?bool, true), parseBool("true"));
    try std.testing.expectEqual(@as(?bool, false), parseBool("false"));
}

test "parseBool: invalid values return null" {
    try std.testing.expectEqual(@as(?bool, null), parseBool("yes"));
    try std.testing.expectEqual(@as(?bool, null), parseBool("1"));
    try std.testing.expectEqual(@as(?bool, null), parseBool(""));
}

test "parseU32: valid and invalid" {
    try std.testing.expectEqual(@as(?u32, 42), parseU32("42"));
    try std.testing.expectEqual(@as(?u32, 0), parseU32("0"));
    try std.testing.expectEqual(@as(?u32, null), parseU32("abc"));
    try std.testing.expectEqual(@as(?u32, null), parseU32("-1"));
    try std.testing.expectEqual(@as(?u32, null), parseU32(""));
}

test "parseFloat: valid and invalid" {
    try std.testing.expectEqual(@as(?f64, 13.5), parseFloat("13.5"));
    try std.testing.expectEqual(@as(?f64, 0.0), parseFloat("0"));
    try std.testing.expectEqual(@as(?f64, null), parseFloat("abc"));
    try std.testing.expectEqual(@as(?f64, null), parseFloat(""));
}

test "writeFloat: positive, zero, and negative values" {
    var buf: [64]u8 = undefined;
    var fbs = std.io.fixedBufferStream(&buf);

    writeFloat(fbs.writer(), 13.0) catch unreachable;
    try std.testing.expectEqualStrings("13.00", fbs.getWritten());

    fbs.reset();
    writeFloat(fbs.writer(), 0.85) catch unreachable;
    try std.testing.expectEqualStrings("0.85", fbs.getWritten());

    fbs.reset();
    writeFloat(fbs.writer(), 0.0) catch unreachable;
    try std.testing.expectEqualStrings("0.00", fbs.getWritten());

    fbs.reset();
    writeFloat(fbs.writer(), -1.5) catch unreachable;
    try std.testing.expectEqualStrings("-1.50", fbs.getWritten());
}

test "setStr: normal copy" {
    var buf: [128]u8 = [_]u8{0} ** 128;
    var len: usize = 0;
    setStr(&buf, &len, "hello");
    try std.testing.expectEqualStrings("hello", buf[0..len]);
    try std.testing.expectEqual(@as(usize, 5), len);
}

test "setStr: truncation on overflow" {
    var buf: [4]u8 = undefined;
    var len: usize = 0;
    setStr(&buf, &len, "hello world");
    try std.testing.expectEqual(@as(usize, 4), len);
    try std.testing.expectEqualStrings("hell", buf[0..len]);
}

test "parseToml: sidebar boolean toggles" {
    var cfg = Config{};
    parseToml(&cfg,
        \\[sidebar]
        \\show-notification-text = false
        \\show-status = false
        \\show-logs = false
        \\show-progress = false
        \\show-branch = false
        \\show-ports = false
    );
    try std.testing.expectEqual(false, cfg.sidebar_show_notification_text);
    try std.testing.expectEqual(false, cfg.sidebar_show_status);
    try std.testing.expectEqual(false, cfg.sidebar_show_logs);
    try std.testing.expectEqual(false, cfg.sidebar_show_progress);
    try std.testing.expectEqual(false, cfg.sidebar_show_branch);
    try std.testing.expectEqual(false, cfg.sidebar_show_ports);
}

