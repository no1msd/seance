// Minimal hand-written Wayland protocol bindings for the KDE KWin blur
// protocol (org_kde_kwin_blur_manager v1 / org_kde_kwin_blur v1).
//
// These definitions are equivalent to what wayland-scanner would generate
// from the blur.xml protocol file.  We avoid the build-time dependency
// by spelling them out directly — the protocol is small and stable.

#include <wayland-client-core.h>

// External interfaces from libwayland-client
extern const struct wl_interface wl_surface_interface;
extern const struct wl_interface wl_region_interface;

// ── org_kde_kwin_blur ──────────────────────────────────────────────

// Forward declaration (referenced by manager_types below)
const struct wl_interface org_kde_kwin_blur_interface;

static const struct wl_interface *blur_types[] = {
    &wl_region_interface,   // set_region arg
};

static const struct wl_message blur_requests[] = {
    { "commit",     "",   NULL },
    { "release",    "",   NULL },
    { "set_region", "?o", blur_types },
};

const struct wl_interface org_kde_kwin_blur_interface = {
    "org_kde_kwin_blur", 1,
    3, blur_requests,
    0, NULL,
};

// ── org_kde_kwin_blur_manager ──────────────────────────────────────

static const struct wl_interface *manager_create_types[] = {
    &org_kde_kwin_blur_interface,
    &wl_surface_interface,
};

static const struct wl_interface *manager_unset_types[] = {
    &wl_surface_interface,
};

static const struct wl_message manager_requests[] = {
    { "create", "no", manager_create_types },
    { "unset",  "o",  manager_unset_types },
};

const struct wl_interface org_kde_kwin_blur_manager_interface = {
    "org_kde_kwin_blur_manager", 1,
    2, manager_requests,
    0, NULL,
};
