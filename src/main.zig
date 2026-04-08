const std = @import("std");
const c = @import("c.zig").c;
const App = @import("app.zig");
const ctl = @import("ctl.zig");

pub const std_options: std.Options = .{
    .log_level = .info,
};

pub fn main() !void {
    // Check if invoked as "seance ctl ..." → enter CLI mode
    var arg_it = std.process.args();
    _ = arg_it.next(); // skip argv0

    if (arg_it.next()) |arg1| {
        if (std.mem.eql(u8, arg1, "ctl")) {
            std.process.exit(ctl.run(2));
        }
        if (std.mem.eql(u8, arg1, "--help") or std.mem.eql(u8, arg1, "-h") or std.mem.eql(u8, arg1, "help")) {
            ctl.printTopLevelUsage();
            return;
        }
    }

    // Normal GUI startup
    // Ghostty requires desktop OpenGL 4.3+, not GLES. Disable GLES
    // and Vulkan before GTK/GDK initialization so that GDK creates a
    // desktop GL context. See ghostty GTK apprt setGtkEnv().
    _ = c.setenv("GDK_DISABLE", "gles-api,vulkan", 0);

    const app = App.create();
    const status = App.run(app);
    App.destroy(app);
    std.process.exit(if (status != 0) @intCast(status) else 0);
}
