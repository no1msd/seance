const std = @import("std");
const c = @import("c.zig").c;

pub const ResolvedColors = struct {
    window_bg: [7]u8,
    window_fg: [7]u8,
    accent_bg: [7]u8, // palette[4] blue
    accent_fg: [7]u8, // palette[15] bright white
    borders: [7]u8, // palette[8] bright black
    notify_border: [7]u8, // palette[12] bright blue
    tab_active_bg: [7]u8, // subtle bg blend for active tab
    tab_colors: [7][7]u8, // ANSI palette[1..7]: red, green, yellow, blue, magenta, cyan, white
    is_light: bool,
};

/// Resolved colors queried from ghostty after config finalization.
var resolved: ResolvedColors = defaultColors();

/// Query ghostty's resolved colors after config finalization.
/// Must be called after ghostty_config_finalize().
pub fn queryGhosttyColors(config: *anyopaque) void {
    var bg: c.ghostty_config_color_s = .{ .r = 0x0e, .g = 0x14, .b = 0x19 };
    var fg: c.ghostty_config_color_s = .{ .r = 0xe5, .g = 0xe1, .b = 0xcf };
    var palette: c.ghostty_config_palette_s = undefined;

    // Zero-init palette to sensible defaults
    @memset(std.mem.asBytes(&palette), 0);

    _ = c.ghostty_config_get(@ptrCast(config), &bg, "background", "background".len);
    _ = c.ghostty_config_get(@ptrCast(config), &fg, "foreground", "foreground".len);
    _ = c.ghostty_config_get(@ptrCast(config), &palette, "palette", "palette".len);

    const bg_hex = colorToHex(bg);
    const fg_hex = colorToHex(fg);

    // Log any theme diagnostics (e.g. theme not found)
    const diag_count = c.ghostty_config_diagnostics_count(@ptrCast(config));
    var di: u32 = 0;
    while (di < diag_count) : (di += 1) {
        const diag = c.ghostty_config_get_diagnostic(@ptrCast(config), di);
        if (diag.message) |msg| {
            std.log.warn("theme: ghostty config: {s}", .{std.mem.sliceTo(msg, 0)});
        }
    }

    var tab_colors: [7][7]u8 = undefined;
    for (0..7) |i| {
        tab_colors[i] = colorToHex(palette.colors[i + 1]);
    }

    resolved = .{
        .window_bg = bg_hex,
        .window_fg = fg_hex,
        .accent_bg = colorToHex(palette.colors[4]),
        .accent_fg = colorToHex(palette.colors[15]),
        .borders = colorToHex(palette.colors[8]),
        .notify_border = colorToHex(palette.colors[12]),
        .tab_active_bg = blendHexColors(bg_hex, fg_hex, 0.15),
        .tab_colors = tab_colors,
        .is_light = isLightColor(bg),
    };
}

pub const tab_color_names = [7][*:0]const u8{
    "Red", "Green", "Yellow", "Blue", "Purple", "Cyan", "White",
};

/// Get the current resolved colors.
pub fn resolveColors() ResolvedColors {
    return resolved;
}

fn colorToHex(color: c.ghostty_config_color_s) [7]u8 {
    var buf: [7]u8 = undefined;
    buf[0] = '#';
    _ = std.fmt.bufPrint(buf[1..7], "{x:0>2}{x:0>2}{x:0>2}", .{ color.r, color.g, color.b }) catch {
        return "#000000".*;
    };
    return buf;
}

/// Determine if a color is light based on perceived luminance.
fn isLightColor(color: c.ghostty_config_color_s) bool {
    // ITU-R BT.601 luma
    const luma = @as(f32, @floatFromInt(color.r)) * 0.299 +
        @as(f32, @floatFromInt(color.g)) * 0.587 +
        @as(f32, @floatFromInt(color.b)) * 0.114;
    return luma > 128.0;
}

/// Blend two hex colors: result = a * (1 - factor) + b * factor.
fn blendHexColors(a: [7]u8, b: [7]u8, factor: f32) [7]u8 {
    const ar = parseHex2(a[1..3]);
    const ag = parseHex2(a[3..5]);
    const ab = parseHex2(a[5..7]);
    const br = parseHex2(b[1..3]);
    const bg = parseHex2(b[3..5]);
    const bb = parseHex2(b[5..7]);

    const inv = 1.0 - factor;
    const r: u8 = @intFromFloat(@as(f32, @floatFromInt(ar)) * inv + @as(f32, @floatFromInt(br)) * factor);
    const g: u8 = @intFromFloat(@as(f32, @floatFromInt(ag)) * inv + @as(f32, @floatFromInt(bg)) * factor);
    const bl: u8 = @intFromFloat(@as(f32, @floatFromInt(ab)) * inv + @as(f32, @floatFromInt(bb)) * factor);

    var result: [7]u8 = undefined;
    result[0] = '#';
    _ = std.fmt.bufPrint(result[1..7], "{x:0>2}{x:0>2}{x:0>2}", .{ r, g, bl }) catch {
        return a; // fallback
    };
    return result;
}

fn parseHex2(s: *const [2]u8) u8 {
    return std.fmt.parseInt(u8, s, 16) catch 0;
}

fn defaultColors() ResolvedColors {
    return .{
        .window_bg = "#0e1419".*,
        .window_fg = "#e5e1cf".*,
        .accent_bg = "#36a3d9".*,
        .accent_fg = "#ffffff".*,
        .borders = "#323232".*,
        .notify_border = "#68d4ff".*,
        .tab_active_bg = "#2c2f33".*,
        .tab_colors = .{
            "#cc0000".*, // red (palette[1])
            "#4e9a06".*, // green (palette[2])
            "#c4a000".*, // yellow (palette[3])
            "#3465a4".*, // blue (palette[4])
            "#75507b".*, // magenta (palette[5])
            "#06989a".*, // cyan (palette[6])
            "#d3d7cf".*, // white (palette[7])
        },
        .is_light = false,
    };
}
