const std = @import("std");
const PaneGroup = @import("pane_group.zig").PaneGroup;

/// A column in the workspace's horizontal strip.
/// Each column has a width (fraction of window width) and contains
/// one or more pane groups stacked vertically.
/// The column itself holds no widgets — it only provides positioning
/// information that the workspace applies to free-floating widgets.
pub const Column = struct {
    /// Width as a fraction of window width (0.1 to 1.0).
    /// This is the animated value — it lerps toward `target_width` each frame.
    width: f64,
    /// Desired width. Resize actions modify this; `width` animates toward it.
    target_width: f64,
    /// Saved width before maximize, for toggle-restore. 0 = not maximized.
    pre_maximize_width: f64 = 0.0,
    /// Pane groups stacked vertically in this column. MVP: always exactly 1.
    groups: std.ArrayList(*PaneGroup),

    /// Animation progress: 0.0 = fully closed, 1.0 = fully open.
    /// Controls fade (opacity) and scale (50% ↔ 100%) from center.
    open_anim: f64 = 1.0,
    /// Column is animating out and will be removed when open_anim reaches 0.
    closing: bool = false,

    /// Layout mode: stacked (all panels visible) or tabbed (one panel with tab bar).
    layout_mode: LayoutMode = .stacked,
    /// Animation progress for layout mode transition.
    /// 0.0 = fully tabbed, 1.0 = fully stacked.
    /// Lerps toward target based on layout_mode.
    stacked_anim: f64 = 1.0,
    /// Which panel was active when the mode switch was initiated.
    /// Used to animate that panel differently during transitions.
    active_at_switch: usize = 0,
    /// Measured height of the tab bar + separator from a previous tabbed state.
    /// Falls back to default_tab_bar_height if never measured.
    measured_tab_bar_height: f64 = default_tab_bar_height,

    pub const LayoutMode = enum { stacked, tabbed };

    pub const default_width: f64 = 0.5;
    pub const min_width: f64 = 0.1;
    pub const max_width: f64 = 1.0;
    /// Width change per resize keypress (fraction of viewport).
    pub const resize_step: f64 = 0.05;

    /// Default height of the tab bar + separator in pixels.
    pub const default_tab_bar_height: f64 = 47.0;

    pub fn init(alloc: std.mem.Allocator, width: f64, group: *PaneGroup) !Column {
        const clamped = std.math.clamp(width, min_width, max_width);
        var col = Column{
            .width = clamped,
            .target_width = clamped,
            .groups = .empty,
        };
        try col.groups.append(alloc, group);
        return col;
    }

    pub fn deinit(self: *Column, alloc: std.mem.Allocator) void {
        self.groups.deinit(alloc);
    }

    /// Returns true if the column is currently in a layout mode transition.
    pub fn isModeTransitioning(self: *const Column) bool {
        return switch (self.layout_mode) {
            .stacked => self.stacked_anim < 1.0,
            .tabbed => self.stacked_anim > 0.0,
        };
    }
};
