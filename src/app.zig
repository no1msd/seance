const std = @import("std");
const builtin = @import("builtin");
const c = @import("c.zig").c;
const Window = @import("window.zig");
const keybinds = @import("keybinds.zig");
const session = @import("session.zig");
const WindowManager = @import("window_manager.zig").WindowManager;
const socket_server = @import("socket_server.zig");
const ghostty_bridge = @import("ghostty_bridge.zig");
const config_mod = @import("config.zig");
const blur_mod = @import("blur.zig");
const kde_decoration = @import("kde_decoration.zig");

const is_linux = builtin.os.tag == .linux;

var wm: ?*WindowManager = null;
var server: socket_server.SocketServer = .{};
pub var shutting_down: bool = false;

pub fn create() *c.AdwApplication {
    if (is_linux) {
        _ = c.notify_init("seance");
    }

    const app = c.adw_application_new("com.seance.app", c.G_APPLICATION_DEFAULT_FLAGS);
    _ = c.g_signal_connect_data(
        @as(c.gpointer, @ptrCast(app)),
        "activate",
        @as(c.GCallback, @ptrCast(&onActivate)),
        null,
        null,
        0,
    );
    _ = c.g_signal_connect_data(
        @as(c.gpointer, @ptrCast(app)),
        "shutdown",
        @as(c.GCallback, @ptrCast(&onShutdown)),
        null,
        null,
        0,
    );
    return app;
}

pub fn destroy(app: *c.AdwApplication) void {
    c.g_object_unref(@ptrCast(app));
}

pub fn run(app: *c.AdwApplication) c_int {
    return c.g_application_run(gapp(app), 0, null);
}

fn onActivate(app: *c.AdwApplication) callconv(.c) void {
    keybinds.register(gtkApp(app));

    if (wm == null) {
        // Register bundled icons so GTK can find them by name.
        // Icons are installed to <prefix>/share/icons; the exe is at <prefix>/bin/.
        registerBundledIcons();

        // Load config before initializing ghostty so theme/font settings are available
        _ = config_mod.load();

        // Set libadwaita to follow system dark/light, preferring dark when
        // the system has no opinion (or on non-Linux platforms).
        const style_manager = c.adw_style_manager_get_default();
        c.adw_style_manager_set_color_scheme(style_manager, c.ADW_COLOR_SCHEME_DEFAULT);

        // Initialize ghostty terminal engine
        if (!ghostty_bridge.init()) {
            std.log.err("Failed to initialize ghostty bridge", .{});
        }

        // Track system dark/light changes for default theme mode
        Window.initThemeTracking();

        // Initialize blur/transparency protocol support (X11/Wayland)
        blur_mod.init();

        // Initialize KDE server-side decoration support — no-op when not on KDE.
        kde_decoration.init();

        // First activation: create window manager and restore session
        const manager = WindowManager.init(gtkApp(app));
        wm = manager;
        Window.window_manager = manager;

        // Start socket server for CLI notifications (e.g., seance notify)
        server.start();

        session.cleanupStaleReplayDirs();
        if (!session.loadAndRestoreAll(manager)) {
            _ = manager.newWindow();
        }
        // Register UNIX signal handlers for graceful shutdown
        _ = c.g_unix_signal_add(std.posix.SIG.TERM, &onUnixSignal, @ptrCast(@alignCast(app)));
        _ = c.g_unix_signal_add(std.posix.SIG.INT, &onUnixSignal, @ptrCast(@alignCast(app)));
        _ = c.g_unix_signal_add(std.posix.SIG.HUP, &onUnixSignal, @ptrCast(@alignCast(app)));
    } else {
        // Subsequent activation (e.g., second instance): new window
        _ = wm.?.newWindow();
    }
}

fn onShutdown(_: *c.AdwApplication) callconv(.c) void {
    shutting_down = true;

    if (wm) |manager| {
        // Remove autosave timer first to prevent it firing during cleanup
        if (manager.autosave_timer != 0) {
            _ = c.g_source_remove(manager.autosave_timer);
            manager.autosave_timer = 0;
        }

        if (manager.windows.items.len > 0) {
            session.saveAll(manager, true);
        }
    }

    // Clean up scrollback replay temp files
    session.cleanupReplayDir();

    // Clean up wrapper resources dir (symlinks + wrapper scripts)
    ghostty_bridge.cleanupResourcesWrapper();

    // Clean up external resources before force-exit so we don't leave
    // stale socket files behind.
    server.stop();

    // Force-exit — ghostty's thread joins deadlock on Linux because the
    // renderer thread requires the main thread (must_draw_from_app_thread).
    std.posix.exit(0);
}

fn onUnixSignal(data: c.gpointer) callconv(.c) c.gboolean {
    c.g_application_quit(@as(*c.GApplication, @ptrCast(@alignCast(data))));
    return 0; // G_SOURCE_REMOVE
}

fn registerBundledIcons() void {
    // Resolve exe path via /proc/self/exe, then derive <prefix>/share/icons.
    var buf: [std.fs.max_path_bytes]u8 = undefined;
    const exe_path = std.fs.selfExePath(&buf) catch return;
    // exe_path is e.g. "/path/to/zig-out/bin/seance"
    // We need "/path/to/zig-out/share/icons"
    const bin_dir = std.fs.path.dirname(exe_path) orelse return;
    const prefix = std.fs.path.dirname(bin_dir) orelse return;

    var icon_buf: [std.fs.max_path_bytes]u8 = undefined;
    const icons_path = std.fmt.bufPrintZ(&icon_buf, "{s}/share/icons", .{prefix}) catch return;

    const theme = c.gtk_icon_theme_get_for_display(c.gdk_display_get_default());
    c.gtk_icon_theme_add_search_path(theme, icons_path.ptr);
}

// Cast helpers
pub fn gapp(app: *c.AdwApplication) *c.GApplication {
    return @ptrCast(app);
}

pub fn gtkApp(app: *c.AdwApplication) *c.GtkApplication {
    return @ptrCast(app);
}
