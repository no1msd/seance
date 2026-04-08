const std = @import("std");
const builtin = @import("builtin");
const c = @import("c.zig").c;
const config_mod = @import("config.zig");

const is_linux = builtin.os.tag == .linux;

// ── Wayland protocol interfaces (defined in kde_blur_protocol.c) ───

extern const org_kde_kwin_blur_manager_interface: if (is_linux) c.struct_wl_interface else void;
extern const org_kde_kwin_blur_interface: if (is_linux) c.struct_wl_interface else void;

// ── Module state ───────────────────────────────────────────────────

const Backend = enum { wayland, x11, unknown };

var detected_backend: Backend = .unknown;

// Wayland state
var wl_blur_manager: if (is_linux) ?*c.struct_wl_proxy else void = if (is_linux) null else {};

// X11 state
var x11_blur_atom: if (is_linux) c.Atom else void = if (is_linux) 0 else {};

// ── Initialisation ─────────────────────────────────────────────────

pub fn init() void {
    if (!is_linux) return; // Blur protocol support is Linux-only (X11/Wayland)

    const display: *c.GdkDisplay = c.gdk_display_get_default() orelse return;

    // Use GLib type checking to detect display backend.
    const inst: *c.GTypeInstance = @ptrCast(@alignCast(display));
    if (c.g_type_check_instance_is_a(inst, c.gdk_wayland_display_get_type()) != 0) {
        detected_backend = .wayland;
        initWayland(display);
    } else if (c.g_type_check_instance_is_a(inst, c.gdk_x11_display_get_type()) != 0) {
        detected_backend = .x11;
        initX11(display);
    }
}

fn initWayland(display: *c.GdkDisplay) void {
    const wl_display: *c.struct_wl_display = c.gdk_wayland_display_get_wl_display(display) orelse return;
    const registry: *c.struct_wl_proxy = @ptrCast(c.wl_display_get_registry(wl_display) orelse return);

    const listener = c.struct_wl_registry_listener{
        .global = &onRegistryGlobal,
        .global_remove = &onRegistryGlobalRemove,
    };
    _ = c.wl_proxy_add_listener(registry, @constCast(@ptrCast(&listener)), null);
    _ = c.wl_display_roundtrip(wl_display);
}

fn onRegistryGlobal(
    _: ?*anyopaque,
    registry: ?*c.struct_wl_registry,
    name: u32,
    interface: [*c]const u8,
    _: u32,
) callconv(.c) void {
    const iface = std.mem.span(@as([*:0]const u8, @ptrCast(interface)));
    if (std.mem.eql(u8, iface, "org_kde_kwin_blur_manager")) {
        wl_blur_manager = c.wl_proxy_marshal_constructor_versioned(
            @ptrCast(registry),
            0, // wl_registry::bind opcode
            &org_kde_kwin_blur_manager_interface,
            1, // version
            name,
            org_kde_kwin_blur_manager_interface.name,
            @as(u32, 1),
            @as(?*c.struct_wl_proxy, null),
        );
    }
}

fn onRegistryGlobalRemove(_: ?*anyopaque, _: ?*c.struct_wl_registry, _: u32) callconv(.c) void {}

fn initX11(display: *c.GdkDisplay) void {
    const xdisplay: *c.Display = c.gdk_x11_display_get_xdisplay(display) orelse return;
    x11_blur_atom = c.XInternAtom(xdisplay, "_KDE_NET_WM_BLUR_BEHIND_REGION", 0);
}

// ── Public API ─────────────────────────────────────────────────────

/// Stored per-window blur tokens so we can release them on transition.
const max_windows = 16;
var blur_tokens: [max_windows]?BlurProxy = [_]?BlurProxy{null} ** max_windows;
var blur_windows: [max_windows]?*c.GtkWindow = [_]?*c.GtkWindow{null} ** max_windows;

const BlurProxy = if (is_linux) *c.struct_wl_proxy else void;

/// Enable or disable blur for a given window based on the current config.
pub fn syncBlur(gtk_window: *c.GtkWindow) void {
    if (!is_linux) return; // Blur protocol support is Linux-only (X11/Wayland)

    const cfg = config_mod.get();
    const want_blur = cfg.background_opacity < 1.0;

    switch (detected_backend) {
        .wayland => syncBlurWayland(gtk_window, want_blur),
        .x11 => syncBlurX11(gtk_window, want_blur),
        .unknown => {},
    }
}

// ── Wayland blur ───────────────────────────────────────────────────

fn syncBlurWayland(gtk_window: *c.GtkWindow, want_blur: bool) void {
    const manager = wl_blur_manager orelse return;
    const gdk_surface: *c.GdkSurface = c.gtk_native_get_surface(
        @as(*c.GtkNative, @ptrCast(gtk_window)),
    ) orelse return;
    const wl_surface: *c.struct_wl_surface = c.gdk_wayland_surface_get_wl_surface(gdk_surface) orelse return;

    const slot = windowSlot(gtk_window);

    if (want_blur) {
        if (blur_tokens[slot] != null) return; // already active
        const tok: ?*c.struct_wl_proxy = c.wl_proxy_marshal_constructor_versioned(
            manager,
            0, // org_kde_kwin_blur_manager::create opcode
            &org_kde_kwin_blur_interface,
            c.wl_proxy_get_version(manager),
            @as(?*c.struct_wl_proxy, null),
            @as(*c.struct_wl_proxy, @ptrCast(wl_surface)),
        );
        if (tok) |t| {
            // commit (opcode 0)
            _ = c.wl_proxy_marshal_flags(t, 0, null, c.wl_proxy_get_version(t), 0);
            blur_tokens[slot] = t;
            blur_windows[slot] = gtk_window;
        }
    } else {
        if (blur_tokens[slot]) |tok| {
            // manager::unset (opcode 1)
            _ = c.wl_proxy_marshal_flags(
                manager,
                1,
                null,
                c.wl_proxy_get_version(manager),
                0,
                @as(*c.struct_wl_proxy, @ptrCast(wl_surface)),
            );
            // blur::release (opcode 1, destructor)
            _ = c.wl_proxy_marshal_flags(tok, 1, null, c.wl_proxy_get_version(tok), c.WL_MARSHAL_FLAG_DESTROY);
            blur_tokens[slot] = null;
            blur_windows[slot] = null;
        }
    }
}

fn windowSlot(gtk_window: *c.GtkWindow) usize {
    for (blur_windows, 0..) |w, i| {
        if (w == gtk_window) return i;
    }
    for (blur_windows, 0..) |w, i| {
        if (w == null) return i;
    }
    return 0;
}

// ── X11 blur ───────────────────────────────────────────────────────

const BlurRegion = extern struct {
    x: c_long = 0,
    y: c_long = 0,
    width: c_long = 0,
    height: c_long = 0,
};

fn syncBlurX11(gtk_window: *c.GtkWindow, want_blur: bool) void {
    if (x11_blur_atom == 0) return;

    const gdk_surface: *c.GdkSurface = c.gtk_native_get_surface(
        @as(*c.GtkNative, @ptrCast(gtk_window)),
    ) orelse return;
    const display: *c.GdkDisplay = c.gdk_display_get_default() orelse return;
    const xdisplay: *c.Display = c.gdk_x11_display_get_xdisplay(display) orelse return;
    const xid: c.Window = c.gdk_x11_surface_get_xid(gdk_surface);
    if (xid == 0) return;

    if (want_blur) {
        const widget: *c.GtkWidget = @ptrCast(gtk_window);
        const scale: c_int = c.gtk_widget_get_scale_factor(widget);
        var region = BlurRegion{
            .width = @as(c_long, c.gtk_widget_get_width(widget)) * @as(c_long, scale),
            .height = @as(c_long, c.gtk_widget_get_height(widget)) * @as(c_long, scale),
        };
        var x: f64 = 0;
        var y: f64 = 0;
        c.gtk_native_get_surface_transform(@as(*c.GtkNative, @ptrCast(gtk_window)), &x, &y);
        region.x = @intFromFloat(x * @as(f64, @floatFromInt(scale)));
        region.y = @intFromFloat(y * @as(f64, @floatFromInt(scale)));

        _ = c.XChangeProperty(
            xdisplay,
            xid,
            x11_blur_atom,
            c.XA_CARDINAL,
            32,
            c.PropModeReplace,
            @ptrCast(&region),
            @sizeOf(BlurRegion) / @sizeOf(c_long),
        );
    } else {
        _ = c.XDeleteProperty(xdisplay, xid, x11_blur_atom);
    }
}
