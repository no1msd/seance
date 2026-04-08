const builtin = @import("builtin");
const is_linux = builtin.os.tag == .linux;

pub const c = @cImport({
    @cInclude("adwaita.h");
    @cInclude("glib-unix.h");

    if (is_linux) {
        // GDK backend headers for blur / transparency
        @cInclude("gdk/x11/gdkx.h");
        @cInclude("gdk/wayland/gdkwayland.h");
        @cInclude("X11/Xlib.h");
        @cInclude("X11/Xatom.h");

        @cInclude("libnotify/notify.h");
        @cInclude("canberra.h");
    }

    @cInclude("ghostty.h");
});
