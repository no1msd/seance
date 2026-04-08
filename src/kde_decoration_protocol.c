// Minimal hand-written Wayland protocol bindings for the KDE KWin
// server-decoration protocol (org_kde_kwin_server_decoration_manager v1 /
// org_kde_kwin_server_decoration v1).
//
// These definitions are equivalent to what wayland-scanner would generate
// from server-decoration.xml.  We avoid the build-time dependency on
// wayland-scanner the same way kde_blur_protocol.c does — by spelling
// the interface descriptors out by hand.
//
// We use this older KWin-specific protocol (rather than the newer
// xdg-decoration-unstable-v1) because GTK4 does not expose the underlying
// xdg_toplevel proxy through any public GDK API, so we cannot create an
// xdg-decoration object on it.  The KWin protocol takes a wl_surface
// instead, which we *can* obtain via gdk_wayland_surface_get_wl_surface.
// KWin still ships this protocol for exactly this reason.

#include <wayland-client-core.h>

extern const struct wl_interface wl_surface_interface;

// ── org_kde_kwin_server_decoration ──────────────────────────────────

const struct wl_interface org_kde_kwin_server_decoration_interface;

static const struct wl_message decoration_requests[] = {
    { "release",      "",  NULL },
    { "request_mode", "u", NULL },
};

static const struct wl_message decoration_events[] = {
    { "mode", "u", NULL },
};

const struct wl_interface org_kde_kwin_server_decoration_interface = {
    "org_kde_kwin_server_decoration", 1,
    2, decoration_requests,
    1, decoration_events,
};

// ── org_kde_kwin_server_decoration_manager ──────────────────────────

static const struct wl_interface *manager_create_types[] = {
    &org_kde_kwin_server_decoration_interface,
    &wl_surface_interface,
};

static const struct wl_message manager_requests[] = {
    { "create", "no", manager_create_types },
};

static const struct wl_message manager_events[] = {
    { "default_mode", "u", NULL },
};

const struct wl_interface org_kde_kwin_server_decoration_manager_interface = {
    "org_kde_kwin_server_decoration_manager", 1,
    1, manager_requests,
    1, manager_events,
};
