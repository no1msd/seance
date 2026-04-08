//! Server-side window decorations for non-GNOME desktops.
//!
//! The AdwApplicationWindow that seance uses gives us no titlebar by
//! default, and most compositors won't draw decorations on top of it
//! because libadwaita installs an internal titlebar slot, which trips
//! GTK4's "this window has a custom titlebar, request CSD" path. The
//! result is a chromeless window on desktops that would otherwise be
//! happy to decorate it.
//!
//! This module overrides that decision: it tells GTK to stop drawing
//! its own decorations (gtk_window_set_decorated(false)) and then asks
//! the windowing system directly for server-side decorations.
//!
//!   * On Wayland the only path is the kwin server-decoration protocol
//!     (KDE Plasma's KWin is the only major compositor that still
//!     advertises it). xdg-decoration-unstable-v1 would be the standard
//!     answer, but GTK4 does not expose the underlying xdg_toplevel
//!     proxy through any public GDK API, so we cannot use it from
//!     outside GTK.
//!   * On X11 we set _MOTIF_WM_HINTS, which works on basically every
//!     non-GNOME WM (KDE/KWin, XFCE/xfwm4, MATE/marco, Cinnamon/muffin,
//!     LXQt/openbox, i3, etc.).
//!
//! The caller is responsible for not invoking this on GNOME. Under
//! GNOME Shell, seance uses its own header bar and we don't want SSD.
//!
//! attachToWindow() bails out early if the running compositor doesn't
//! advertise a way to deliver SSD, so calling it on e.g. Sway or
//! Hyprland is a harmless no-op (we leave GTK's CSD untouched rather
//! than stripping it and ending up with a chromeless window).
//!
//! The Wayland path mirrors the recipe used by upstream Ghostty (see
//! ghostty/src/apprt/gtk/winproto/wayland.zig and x11.zig); we replicate
//! it because seance has its own GTK window code rather than going
//! through Ghostty's GTK apprt.

const std = @import("std");
const builtin = @import("builtin");
const c = @import("c.zig").c;

const is_linux = builtin.os.tag == .linux;

// ── Wayland protocol interfaces (defined in kde_decoration_protocol.c) ──

extern const org_kde_kwin_server_decoration_manager_interface: if (is_linux) c.struct_wl_interface else void;
extern const org_kde_kwin_server_decoration_interface: if (is_linux) c.struct_wl_interface else void;

// org_kde_kwin_server_decoration::Mode
const CLIENT_MODE: c_uint = 1;
const SERVER_MODE: c_uint = 2;

// GObject data key used to stash the per-window wl_proxy* for the
// org_kde_kwin_server_decoration object so we can reverse the mode later.
const SSD_PROXY_KEY: [*:0]const u8 = "seance-ssd-proxy";

// _MOTIF_WM_HINTS bits.  See Xm/MwmUtil.h.
const MWM_HINTS_DECORATIONS: c_ulong = 1 << 1;
const MWM_DECOR_ALL: c_ulong = 1;

const MotifWmHints = extern struct {
    flags: c_ulong = 0,
    functions: c_ulong = 0,
    decorations: c_ulong = 0,
    input_mode: c_long = 0,
    status: c_ulong = 0,
};

const Backend = enum { none, wayland, x11 };

var backend: Backend = .none;
var wl_decoration_manager: if (is_linux) ?*c.struct_wl_proxy else void = if (is_linux) null else {};
var x11_motif_atom: if (is_linux) c.Atom else void = if (is_linux) 0 else {};

// ── Initialisation ─────────────────────────────────────────────────

/// Bind the kwin server-decoration manager (Wayland) or look up the
/// _MOTIF_WM_HINTS atom (X11).  Must be called after GTK is initialised
/// and a default GdkDisplay exists.  Cheap no-op on non-Linux.
///
/// Runs unconditionally on Linux: we can't tell from here whether the
/// caller is on a desktop that wants SSD (it might be GNOME-on-X11,
/// where the X11 path would still bind successfully but shouldn't be
/// used).  attachToWindow() is the gate that decides whether to
/// actually mutate a window, and the caller in window.zig is
/// responsible for not invoking it on GNOME.
pub fn init() void {
    if (!is_linux) return;

    const display: *c.GdkDisplay = c.gdk_display_get_default() orelse return;
    const inst: *c.GTypeInstance = @ptrCast(@alignCast(display));

    if (c.g_type_check_instance_is_a(inst, c.gdk_wayland_display_get_type()) != 0) {
        backend = .wayland;
        initWayland(display);
    } else if (c.g_type_check_instance_is_a(inst, c.gdk_x11_display_get_type()) != 0) {
        backend = .x11;
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

fn initX11(display: *c.GdkDisplay) void {
    const xdisplay: *c.Display = c.gdk_x11_display_get_xdisplay(display) orelse return;
    x11_motif_atom = c.XInternAtom(xdisplay, "_MOTIF_WM_HINTS", 0);
}

fn onRegistryGlobal(
    _: ?*anyopaque,
    registry: ?*c.struct_wl_registry,
    name: u32,
    interface: [*c]const u8,
    _: u32,
) callconv(.c) void {
    const iface = std.mem.span(@as([*:0]const u8, @ptrCast(interface)));
    if (std.mem.eql(u8, iface, "org_kde_kwin_server_decoration_manager")) {
        wl_decoration_manager = c.wl_proxy_marshal_constructor_versioned(
            @ptrCast(registry),
            0, // wl_registry::bind opcode
            &org_kde_kwin_server_decoration_manager_interface,
            1, // version
            name,
            org_kde_kwin_server_decoration_manager_interface.name,
            @as(u32, 1),
            @as(?*c.struct_wl_proxy, null),
        );
    }
}

fn onRegistryGlobalRemove(_: ?*anyopaque, _: ?*c.struct_wl_registry, _: u32) callconv(.c) void {}

// ── Per-window setup ───────────────────────────────────────────────

/// Returns true when the current display backend can deliver server-side
/// decorations.  Wayland requires the kwin manager, X11 requires the Motif
/// hints atom, everything else is a no-op.  Use this to decide whether a
/// requested SSD mode is honorable before promising it to the user.
pub fn isSsdAvailable() bool {
    if (!is_linux) return false;
    return switch (backend) {
        .wayland => wl_decoration_manager != null,
        .x11 => x11_motif_atom != 0,
        .none => false,
    };
}

/// Configure a window so the windowing system draws server-side
/// decorations on it.  Should be called during window construction,
/// before the window is presented.
///
/// Bails out early when SSD can't be delivered (e.g. on Sway,
/// Hyprland, or any other Wayland compositor that doesn't advertise
/// the kwin server-decoration manager).  In that case GTK's existing
/// CSD is left untouched, since stripping it without anything to take
/// its place would leave a chromeless window.
pub fn attachToWindow(gtk_window: *c.GtkWindow) void {
    if (!isSsdAvailable()) return;

    const widget: *c.GtkWidget = @ptrCast(gtk_window);

    // Tell GTK to stop drawing client-side decorations.  This is the key
    // step that lets the WM take over for an AdwApplicationWindow on
    // Wayland.  On X11 it's harmless because we override _MOTIF_WM_HINTS
    // below regardless.
    c.gtk_window_set_decorated(gtk_window, 0);
    c.gtk_widget_add_css_class(widget, "ssd");
    c.gtk_widget_add_css_class(widget, "no-border-radius");

    // The wl_surface / X11 window doesn't exist until the GTK widget is
    // realized, so defer the per-surface request until then.  If we're
    // somehow already realized, apply immediately.
    if (c.gtk_widget_get_realized(widget) != 0) {
        applyToWindow(gtk_window);
    } else {
        _ = c.g_signal_connect_data(
            @as(c.gpointer, @ptrCast(widget)),
            "realize",
            @as(c.GCallback, @ptrCast(&onWindowRealize)),
            null,
            null,
            0,
        );
    }
}

fn onWindowRealize(widget: *c.GtkWidget, _: c.gpointer) callconv(.c) void {
    applyToWindow(@ptrCast(widget));
}

fn applyToWindow(gtk_window: *c.GtkWindow) void {
    switch (backend) {
        .wayland => applyWayland(gtk_window),
        .x11 => applyX11(gtk_window),
        .none => {},
    }
}

fn applyWayland(gtk_window: *c.GtkWindow) void {
    const manager = wl_decoration_manager orelse return;
    const widget: *c.GtkWidget = @ptrCast(gtk_window);
    const gobject: *c.GObject = @ptrCast(widget);

    // If we already stashed a proxy for this window (e.g. we're toggling
    // from CSD back to SSD at runtime) reuse it.  Asking the manager for
    // a second decoration object on the same surface is a protocol error.
    if (c.g_object_get_data(gobject, SSD_PROXY_KEY)) |existing| {
        const d: *c.struct_wl_proxy = @ptrCast(@alignCast(existing));
        _ = c.wl_proxy_marshal_flags(
            d,
            1,
            null,
            c.wl_proxy_get_version(d),
            0,
            SERVER_MODE,
        );
        return;
    }

    const gdk_surface: *c.GdkSurface = c.gtk_native_get_surface(
        @as(*c.GtkNative, @ptrCast(gtk_window)),
    ) orelse return;
    const wl_surface: *c.struct_wl_surface =
        c.gdk_wayland_surface_get_wl_surface(gdk_surface) orelse return;

    // org_kde_kwin_server_decoration_manager::create — opcode 0,
    // signature "no" (new_id, surface).
    const deco: ?*c.struct_wl_proxy = c.wl_proxy_marshal_constructor_versioned(
        manager,
        0,
        &org_kde_kwin_server_decoration_interface,
        c.wl_proxy_get_version(manager),
        @as(?*c.struct_wl_proxy, null),
        @as(*c.struct_wl_proxy, @ptrCast(wl_surface)),
    );
    const d = deco orelse return;

    // org_kde_kwin_server_decoration::request_mode — opcode 1,
    // signature "u".  Mode 2 = Server.
    _ = c.wl_proxy_marshal_flags(
        d,
        1,
        null,
        c.wl_proxy_get_version(d),
        0,
        SERVER_MODE,
    );

    // Stash the proxy on the widget so detachFromWindow / future toggles
    // can find it again.  The proxy itself lives as long as the window.
    c.g_object_set_data(gobject, SSD_PROXY_KEY, @ptrCast(d));
}

/// Reverse attachToWindow: re-enable GTK's client-side decorations on a
/// window that was previously configured for SSD.  Safe to call on
/// windows that were never attached (no-op).  Intended for runtime
/// toggles via the settings dialog.
pub fn detachFromWindow(gtk_window: *c.GtkWindow) void {
    if (!is_linux) return;

    const widget: *c.GtkWidget = @ptrCast(gtk_window);
    const gobject: *c.GObject = @ptrCast(widget);

    // Ask the WM to give up its decorations first, so we don't briefly
    // have both SSD and CSD drawn together.
    switch (backend) {
        .wayland => {
            if (c.g_object_get_data(gobject, SSD_PROXY_KEY)) |existing| {
                const d: *c.struct_wl_proxy = @ptrCast(@alignCast(existing));
                _ = c.wl_proxy_marshal_flags(
                    d,
                    1,
                    null,
                    c.wl_proxy_get_version(d),
                    0,
                    CLIENT_MODE,
                );
            }
        },
        .x11 => {
            if (x11_motif_atom == 0) return;
            const gdk_surface: *c.GdkSurface = c.gtk_native_get_surface(
                @as(*c.GtkNative, @ptrCast(gtk_window)),
            ) orelse return;
            const display: *c.GdkDisplay = c.gdk_display_get_default() orelse return;
            const xdisplay: *c.Display = c.gdk_x11_display_get_xdisplay(display) orelse return;
            const xid: c.Window = c.gdk_x11_surface_get_xid(gdk_surface);
            if (xid == 0) return;
            // Clear the hint so the WM falls back to its default (decorated).
            _ = c.XDeleteProperty(xdisplay, xid, x11_motif_atom);
        },
        .none => {},
    }

    // Hand decoration back to GTK and strip SSD-specific styling.
    c.gtk_window_set_decorated(gtk_window, 1);
    c.gtk_widget_remove_css_class(widget, "ssd");
    c.gtk_widget_remove_css_class(widget, "no-border-radius");
}

fn applyX11(gtk_window: *c.GtkWindow) void {
    if (x11_motif_atom == 0) return;

    const gdk_surface: *c.GdkSurface = c.gtk_native_get_surface(
        @as(*c.GtkNative, @ptrCast(gtk_window)),
    ) orelse return;
    const display: *c.GdkDisplay = c.gdk_display_get_default() orelse return;
    const xdisplay: *c.Display = c.gdk_x11_display_get_xdisplay(display) orelse return;
    const xid: c.Window = c.gdk_x11_surface_get_xid(gdk_surface);
    if (xid == 0) return;

    const hints = MotifWmHints{
        .flags = MWM_HINTS_DECORATIONS,
        .decorations = MWM_DECOR_ALL,
    };

    _ = c.XChangeProperty(
        xdisplay,
        xid,
        x11_motif_atom,
        x11_motif_atom, // type is _MOTIF_WM_HINTS itself
        32,
        c.PropModeReplace,
        @ptrCast(&hints),
        @sizeOf(MotifWmHints) / @sizeOf(c_long),
    );
}
