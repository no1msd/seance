const std = @import("std");
const c = @import("c.zig").c;

// Animation constants
const SPACING: f64 = 2.0;
/// Exponential decay rate — 99% in ~150ms (snappy tab reorder feel).
const ANIM_DECAY_RATE: f64 = 30.7; // -ln(0.01) / 0.15
const ANIM_SNAP_THRESHOLD: f64 = 0.01;
const SNAP_BACK_THRESHOLD: f64 = 1.0;
const AUTOSCROLL_ZONE: f64 = 40.0;
const ANIM_INTERVAL: u32 = 16;

pub const TabInfo = struct {
    id: u64,
    outer_revealer: *c.GtkWidget, // GtkRevealer wrapping whole tab
    tab_frame: *c.GtkWidget, // GtkBox with "vtab" CSS class
    overlay: *c.GtkWidget, // GtkOverlay
    content: *c.GtkWidget, // user-provided content widget
    close_revealer: *c.GtkWidget, // GtkRevealer around close button
    close_btn: *c.GtkWidget, // close GtkButton
    color_bar: *c.GtkWidget, // colored bar on the left side
    separator: ?*c.GtkWidget = null, // separator line widget below this tab
    is_pinned: bool,
    needs_attention: bool = false,
    color_bar_provider: ?*c.GtkCssProvider = null,
    reveal_source_id: c.guint = 0, // pending g_idle reveal callback (0 = none)
    // Layout fields for smooth drag animation
    base_y: f64 = 0,
    height: f64 = 0,
    reorder_offset: f64 = 0, // target: -1, 0, or +1 slots to shift
    anim_offset: f64 = 0, // current animated offset (lerps toward reorder_offset)
};

pub const VerticalTabBar = struct {
    widget: *c.GtkWidget, // root: GtkScrolledWindow
    scrolled: *c.GtkScrolledWindow,
    fixed: *c.GtkWidget, // GtkFixed (replaces inner_box)

    tabs: [128]TabInfo = undefined,
    tab_count: usize = 0,
    selected_index: ?usize = null,

    // Smooth drag state
    dragging: bool = false,
    drag_claimed: bool = false, // true once drag threshold exceeded
    drag_gesture: ?*c.GtkGesture = null,
    drag_tab_index: ?usize = null,
    drag_start_y: f64 = 0,
    drag_offset_y: f64 = 0, // cursor offset within the tab (grab point)
    drag_y: f64 = 0, // current y position for the dragged tab
    reorder_index: usize = 0, // current logical position during drag
    anim_timer: c.guint = 0,
    last_anim_time: i64 = 0, // microseconds, from g_get_monotonic_time()
    snap_back_active: bool = false, // true during snap-back animation after release
    snap_back_target: f64 = 0, // y position to animate toward after release

    // Autoscroll
    autoscroll_timer: c.guint = 0,
    autoscroll_speed: f64 = 0,


    // Interaction
    hover_tab_index: ?usize = null,
    alloc: std.mem.Allocator,

    // Callbacks
    on_select: ?*const fn (u64) void = null,
    on_close: ?*const fn (u64) void = null,
    on_reorder: ?*const fn (u64, usize) void = null,
    on_context_menu: ?*const fn (u64, f64, f64, *c.GtkWidget) void = null,
    on_middle_click: ?*const fn (u64) void = null,

    pub fn create(alloc: std.mem.Allocator) VerticalTabBar {
        const scrolled = c.gtk_scrolled_window_new();
        c.gtk_scrolled_window_set_policy(@ptrCast(scrolled), c.GTK_POLICY_NEVER, c.GTK_POLICY_AUTOMATIC);
        c.gtk_widget_add_css_class(scrolled, "vtab-scroll");

        const fixed = c.gtk_fixed_new();
        c.gtk_widget_add_css_class(fixed, "vtab-bar");
        c.gtk_scrolled_window_set_child(@ptrCast(scrolled), fixed);
        c.gtk_widget_set_focusable(fixed, 1);

        return VerticalTabBar{
            .widget = scrolled,
            .scrolled = @ptrCast(scrolled),
            .fixed = fixed,
            .alloc = alloc,
        };
    }

    /// Cancel all pending timers and idle callbacks. Must be called before
    /// the VerticalTabBar (or its owning Sidebar/WindowState) is freed.
    pub fn deinit(self: *VerticalTabBar) void {
        self.stopAnimTimer();
        self.stopAutoscroll();
        for (self.tabs[0..self.tab_count]) |*tab| {
            if (tab.reveal_source_id != 0) {
                _ = c.g_source_remove(tab.reveal_source_id);
                tab.reveal_source_id = 0;
            }
        }
    }

    /// Must be called after the VerticalTabBar has its final stable address.
    /// Connects the gesture drag and keyboard controller.
    pub fn connectSignals(self: *VerticalTabBar) void {
        // GtkGestureDrag on the fixed container for reordering
        const drag = c.gtk_gesture_drag_new();
        c.gtk_gesture_single_set_button(@ptrCast(drag), 1);
        c.gtk_event_controller_set_propagation_phase(@ptrCast(drag), c.GTK_PHASE_CAPTURE);
        _ = c.g_signal_connect_data(
            @as(c.gpointer, @ptrCast(drag)),
            "drag-begin",
            @as(c.GCallback, @ptrCast(&onGestureDragBegin)),
            @as(c.gpointer, @ptrCast(self)),
            null,
            0,
        );
        _ = c.g_signal_connect_data(
            @as(c.gpointer, @ptrCast(drag)),
            "drag-update",
            @as(c.GCallback, @ptrCast(&onGestureDragUpdate)),
            @as(c.gpointer, @ptrCast(self)),
            null,
            0,
        );
        _ = c.g_signal_connect_data(
            @as(c.gpointer, @ptrCast(drag)),
            "drag-end",
            @as(c.GCallback, @ptrCast(&onGestureDragEnd)),
            @as(c.gpointer, @ptrCast(self)),
            null,
            0,
        );
        c.gtk_widget_add_controller(self.fixed, @ptrCast(drag));
        self.drag_gesture = @ptrCast(drag);

        // Keyboard navigation
        const key_ctrl = c.gtk_event_controller_key_new();
        _ = c.g_signal_connect_data(@ptrCast(key_ctrl), "key-pressed", @as(c.GCallback, @ptrCast(&onKeyPressed)), @ptrCast(self), null, 0);
        c.gtk_widget_add_controller(self.fixed, @ptrCast(key_ctrl));
    }

    pub fn addTab(self: *VerticalTabBar, id: u64, content: *c.GtkWidget, pinned: bool, position: usize) void {
        if (self.tab_count >= self.tabs.len) return;

        // Outer revealer for add/remove animation
        const outer_revealer = c.gtk_revealer_new();
        c.gtk_revealer_set_transition_type(@ptrCast(outer_revealer), c.GTK_REVEALER_TRANSITION_TYPE_CROSSFADE);
        c.gtk_revealer_set_transition_duration(@ptrCast(outer_revealer), 200);

        // Tab frame (holds padding, background, border-radius)
        const tab_frame = c.gtk_box_new(c.GTK_ORIENTATION_HORIZONTAL, 0);
        c.gtk_widget_add_css_class(tab_frame, "vtab");

        // Overlay: content + close button
        const overlay = c.gtk_overlay_new();
        c.gtk_overlay_set_child(@ptrCast(overlay), content);
        c.gtk_widget_set_hexpand(overlay, 1);

        // Close button in a crossfade revealer
        const close_revealer = c.gtk_revealer_new();
        c.gtk_revealer_set_transition_type(@ptrCast(close_revealer), c.GTK_REVEALER_TRANSITION_TYPE_CROSSFADE);
        c.gtk_revealer_set_transition_duration(@ptrCast(close_revealer), 150);
        c.gtk_revealer_set_reveal_child(@ptrCast(close_revealer), 0);

        const close_btn = c.gtk_button_new_from_icon_name("window-close-symbolic");
        c.gtk_widget_add_css_class(close_btn, "vtab-close");
        c.gtk_widget_set_halign(close_btn, c.GTK_ALIGN_END);
        c.gtk_widget_set_valign(close_btn, c.GTK_ALIGN_START);
        c.gtk_revealer_set_child(@ptrCast(close_revealer), close_btn);

        c.gtk_widget_set_halign(close_revealer, c.GTK_ALIGN_END);
        c.gtk_widget_set_valign(close_revealer, c.GTK_ALIGN_START);
        c.gtk_overlay_add_overlay(@ptrCast(overlay), close_revealer);

        c.gtk_box_append(@ptrCast(tab_frame), overlay);

        // Wrapper overlay: positions color bar outside flow layout
        const tab_wrapper = c.gtk_overlay_new();
        c.gtk_widget_add_css_class(tab_wrapper, "vtab-wrapper");
        c.gtk_overlay_set_child(@ptrCast(tab_wrapper), tab_frame);

        // Color bar (hidden by default, overlay child for non-flow positioning)
        const color_bar = c.gtk_box_new(c.GTK_ORIENTATION_VERTICAL, 0);
        c.gtk_widget_add_css_class(color_bar, "vtab-color-bar");
        c.gtk_widget_set_visible(color_bar, 0);
        c.gtk_widget_set_halign(color_bar, c.GTK_ALIGN_START);
        c.gtk_widget_set_valign(color_bar, c.GTK_ALIGN_FILL);
        c.gtk_overlay_add_overlay(@ptrCast(tab_wrapper), color_bar);

        c.gtk_revealer_set_child(@ptrCast(outer_revealer), tab_wrapper);

        // Add to GtkFixed at (0,0) — relayout will position it
        c.gtk_fixed_put(@ptrCast(self.fixed), outer_revealer, 0, 0);

        // Create separator line widget (positioned between this tab and the next)
        const sep_line = c.gtk_box_new(c.GTK_ORIENTATION_HORIZONTAL, 0);
        c.gtk_widget_add_css_class(sep_line, "vtab-sep-line");
        c.gtk_widget_set_visible(sep_line, 0);
        c.gtk_widget_set_can_target(sep_line, 0);
        c.gtk_fixed_put(@ptrCast(self.fixed), sep_line, 0, 0);

        // Shift tabs array
        const pos = @min(position, self.tab_count);
        var i = self.tab_count;
        while (i > pos) : (i -= 1) {
            self.tabs[i] = self.tabs[i - 1];
        }
        self.tabs[pos] = .{
            .id = id,
            .outer_revealer = outer_revealer,
            .tab_frame = tab_frame,
            .overlay = overlay,
            .content = content,
            .close_revealer = close_revealer,
            .close_btn = close_btn,
            .color_bar = color_bar,
            .separator = sep_line,
            .is_pinned = pinned,
        };
        self.tab_count += 1;

        // Adjust selected_index
        if (self.selected_index) |sel| {
            if (pos <= sel) self.selected_index = sel + 1;
        }

        // Attach event controllers to tab_frame
        self.attachTabControllers(pos);

        // Animate in: start unrevealed, then reveal on next idle
        c.gtk_revealer_set_reveal_child(@ptrCast(outer_revealer), 0);
        const reveal_data = self.alloc.create(RevealData) catch {
            c.gtk_revealer_set_reveal_child(@ptrCast(outer_revealer), 1);
            self.relayout();
            return;
        };
        reveal_data.* = .{ .revealer = @ptrCast(outer_revealer), .vtab = self, .tab_id = id };
        const source_id = c.g_idle_add_full(
            c.G_PRIORITY_DEFAULT_IDLE,
            @ptrCast(&revealIdleCallback),
            @ptrCast(reveal_data),
            @ptrCast(&revealDataDestroy),
        );
        self.tabs[pos].reveal_source_id = source_id;

        self.relayout();
        self.updateSeparators();
    }

    fn removeTabImmediate(self: *VerticalTabBar, idx: usize) void {
        if (idx >= self.tab_count) return;
        const tab = &self.tabs[idx];
        // Cancel pending reveal callback before destroying the widget
        if (tab.reveal_source_id != 0) {
            _ = c.g_source_remove(tab.reveal_source_id);
            tab.reveal_source_id = 0;
        }
        if (tab.separator) |sep| c.gtk_fixed_remove(@ptrCast(self.fixed), sep);
        c.gtk_fixed_remove(@ptrCast(self.fixed), tab.outer_revealer);

        // Compact array
        var i = idx;
        while (i + 1 < self.tab_count) : (i += 1) {
            self.tabs[i] = self.tabs[i + 1];
        }
        self.tab_count -= 1;

        // Adjust selected_index
        if (self.selected_index) |sel| {
            if (idx == sel) {
                self.selected_index = if (self.tab_count > 0) @min(sel, self.tab_count - 1) else null;
            } else if (idx < sel) {
                self.selected_index = sel - 1;
            }
        }

        self.relayout();
        self.updateSeparators();
    }

    pub fn updateContent(self: *VerticalTabBar, id: u64, new_content: *c.GtkWidget) void {
        const idx = self.findTabById(id) orelse return;
        const tab = &self.tabs[idx];
        c.gtk_overlay_set_child(@ptrCast(tab.overlay), new_content);
        tab.content = new_content;
    }

    pub fn setSelected(self: *VerticalTabBar, id: u64) void {
        // Remove old selection
        if (self.selected_index) |old| {
            if (old < self.tab_count) {
                c.gtk_widget_remove_css_class(self.tabs[old].tab_frame, "vtab-selected");
                c.gtk_widget_remove_css_class(self.tabs[old].tab_frame, "vtab-active-rail");
            }
        }

        const idx = self.findTabById(id) orelse return;
        self.selected_index = idx;
        c.gtk_widget_add_css_class(self.tabs[idx].tab_frame, "vtab-selected");

        c.gtk_widget_add_css_class(self.tabs[idx].tab_frame, "vtab-active-rail");

        self.scrollToTab(idx);
        self.updateSeparators();
    }

    pub fn setNeedsAttention(self: *VerticalTabBar, id: u64, attention: bool) void {
        const idx = self.findTabById(id) orelse return;
        self.tabs[idx].needs_attention = attention;
        if (attention) {
            c.gtk_widget_add_css_class(self.tabs[idx].tab_frame, "vtab-attention");
        } else {
            c.gtk_widget_remove_css_class(self.tabs[idx].tab_frame, "vtab-attention");
        }
    }

    pub fn setTabColor(self: *VerticalTabBar, id: u64, color: ?[]const u8) void {
        const idx = self.findTabById(id) orelse return;
        var tab = &self.tabs[idx];

        if (color) |hex| {
            // Show the color bar with the given color
            c.gtk_widget_set_visible(tab.color_bar, 1);

            // Apply background color via CSS provider
            var css_buf: [128]u8 = undefined;
            const css = std.fmt.bufPrintZ(&css_buf, ".vtab-color-bar {{ background-color: {s}; }}", .{hex}) catch return;

            if (tab.color_bar_provider) |provider| {
                c.gtk_css_provider_load_from_string(provider, css.ptr);
            } else {
                const provider = c.gtk_css_provider_new();
                c.gtk_css_provider_load_from_string(provider, css.ptr);
                const ctx = c.gtk_widget_get_style_context(tab.color_bar);
                c.gtk_style_context_add_provider(ctx, @ptrCast(provider), c.GTK_STYLE_PROVIDER_PRIORITY_APPLICATION);
                tab.color_bar_provider = provider;
            }
        } else {
            // Hide the color bar
            c.gtk_widget_set_visible(tab.color_bar, 0);
        }
    }

    /// Show/hide separator line widgets between adjacent unselected tabs,
    /// matching the divider behaviour of libadwaita's horizontal tab bar.
    pub fn updateSeparators(self: *VerticalTabBar) void {
        for (0..self.tab_count) |i| {
            var show = i + 1 < self.tab_count and
                self.selected_index != i and
                self.selected_index != i + 1;

            // During drag/snap-back, suppress separators around the dragged
            // tab's current visual insertion point (reorder_index).
            if (show and (self.dragging or self.snap_back_active)) {
                if (self.drag_tab_index) |di| {
                    const ri = self.reorder_index;
                    if (i == di) {
                        show = false;
                    } else if ((i < di and i + 1 == ri) or (i > di and i == ri)) {
                        show = false;
                    }
                }
            }

            // Hover: hide the separator on the hovered tab and on the tab
            // whose bottom separator leads into the hovered tab.
            if (show) {
                if (self.hover_tab_index) |hi| {
                    if (i == hi or i + 1 == hi) {
                        show = false;
                    }
                }
            }

            if (self.tabs[i].separator) |sep| {
                c.gtk_widget_set_visible(sep, if (show) 1 else 0);
            }
        }
    }

    pub fn reconcile(
        self: *VerticalTabBar,
        ids: []const u64,
        pinned: []const bool,
        builder: *const fn (*VerticalTabBar, u64) ?*c.GtkWidget,
    ) void {
        // 1. Remove tabs not in new list
        {
            var i: usize = 0;
            while (i < self.tab_count) {
                const tab_id = self.tabs[i].id;
                var found = false;
                for (ids) |new_id| {
                    if (new_id == tab_id) {
                        found = true;
                        break;
                    }
                }
                if (!found) {
                    self.removeTabImmediate(i);
                } else {
                    i += 1;
                }
            }
        }

        // 2. Add or update tabs
        for (ids, 0..) |new_id, pos| {
            if (self.findTabById(new_id)) |existing_idx| {
                self.tabs[existing_idx].is_pinned = pinned[pos];
                if (builder(self, new_id)) |new_content| {
                    self.updateContent(new_id, new_content);
                }
                if (existing_idx != pos) {
                    self.moveTabToPosition(existing_idx, pos);
                }
            } else {
                if (builder(self, new_id)) |content| {
                    self.addTab(new_id, content, pinned[pos], pos);
                }
            }
        }

        self.relayout();
        self.updateSeparators();
    }

    fn moveTabToPosition(self: *VerticalTabBar, from: usize, to: usize) void {
        if (from == to or from >= self.tab_count or to >= self.tab_count) return;

        const tab = self.tabs[from];

        // Shift the array
        if (from < to) {
            var i = from;
            while (i < to) : (i += 1) {
                self.tabs[i] = self.tabs[i + 1];
            }
        } else {
            var i = from;
            while (i > to) : (i -= 1) {
                self.tabs[i] = self.tabs[i - 1];
            }
        }
        self.tabs[to] = tab;

        // GtkFixed doesn't care about child order for layout — relayout handles positioning
        self.relayout();
    }

    pub fn findTabById(self: *const VerticalTabBar, id: u64) ?usize {
        for (self.tabs[0..self.tab_count], 0..) |t, i| {
            if (t.id == id) return i;
        }
        return null;
    }

    pub fn pinnedCount(self: *const VerticalTabBar) usize {
        var count: usize = 0;
        for (self.tabs[0..self.tab_count]) |t| {
            if (t.is_pinned) count += 1;
        }
        return count;
    }

    // ── Layout ──

    pub fn relayout(self: *VerticalTabBar) void {
        const container_width = c.gtk_widget_get_width(self.fixed);
        // Use a minimum width if widget hasn't been allocated yet
        const w: c_int = if (container_width > 0) container_width else 200;

        var dragged_height: f64 = 0;
        if (self.drag_tab_index) |di| {
            if (di < self.tab_count) {
                dragged_height = self.tabs[di].height;
                if (dragged_height <= 0) dragged_height = 40;
            }
        }

        var y: f64 = 0;
        var render_y: [128]f64 = undefined;
        var render_h: [128]f64 = undefined;
        for (self.tabs[0..self.tab_count], 0..) |*tab, i| {
            // Measure tab height
            var minimum: c_int = 0;
            var natural: c_int = 0;
            c.gtk_widget_measure(tab.outer_revealer, c.GTK_ORIENTATION_VERTICAL, w, &minimum, &natural, null, null);
            const h: f64 = @floatFromInt(if (natural > 0) natural else minimum);

            tab.base_y = y;
            tab.height = h;
            render_h[i] = h;

            // Set width
            c.gtk_widget_set_size_request(tab.outer_revealer, w, -1);

            if (self.dragging or self.snap_back_active) {
                if (self.drag_tab_index) |di| {
                    if (i == di) {
                        // Dragged tab follows cursor (or snap-back position)
                        c.gtk_fixed_move(@ptrCast(self.fixed), tab.outer_revealer, 0, self.drag_y);
                        // Ensure dragged tab always renders on top
                        c.gtk_widget_insert_before(tab.outer_revealer, self.fixed, null);
                        render_y[i] = self.drag_y;
                        y += h + SPACING;
                        continue;
                    }
                }
            }

            // Normal tab with animated offset
            const step = if (dragged_height > 0) dragged_height + SPACING else h + SPACING;
            const offset_px = tab.anim_offset * step;
            c.gtk_fixed_move(@ptrCast(self.fixed), tab.outer_revealer, 0, y + offset_px);
            render_y[i] = y + offset_px;

            y += h + SPACING;
        }

        // Position separator line widgets at the midpoint between adjacent tabs
        const sep_w = if (w > 12) w - 12 else w;
        for (0..self.tab_count) |i| {
            if (self.tabs[i].separator) |sep| {
                if (i + 1 < self.tab_count) {
                    const bottom_i = render_y[i] + render_h[i];
                    const top_next = render_y[i + 1];
                    const sep_y = (bottom_i + top_next) / 2.0;
                    c.gtk_widget_set_size_request(sep, sep_w, 1);
                    c.gtk_fixed_move(@ptrCast(self.fixed), sep, 6, sep_y);
                }
            }
        }

        // Tell scrolled window about content size
        c.gtk_widget_set_size_request(self.fixed, w, @intFromFloat(y));
    }

    fn startAnimTimer(self: *VerticalTabBar) void {
        if (self.anim_timer != 0) return;
        self.anim_timer = c.g_timeout_add(ANIM_INTERVAL, @ptrCast(&animTick), @ptrCast(self));
    }

    fn stopAnimTimer(self: *VerticalTabBar) void {
        if (self.anim_timer != 0) {
            _ = c.g_source_remove(self.anim_timer);
            self.anim_timer = 0;
        }
    }

    fn animTick(data: c.gpointer) callconv(.c) c.gboolean {
        const self: *VerticalTabBar = @ptrCast(@alignCast(data));
        var all_done = true;

        // Compute time-based lerp factor
        const now = c.g_get_monotonic_time();
        const dt: f64 = if (self.last_anim_time > 0)
            @as(f64, @floatFromInt(now - self.last_anim_time)) / 1_000_000.0
        else
            1.0 / 60.0;
        self.last_anim_time = now;
        const lerp_factor = 1.0 - @exp(-ANIM_DECAY_RATE * dt);

        // Animate tab offsets
        for (self.tabs[0..self.tab_count]) |*tab| {
            if (@abs(tab.anim_offset - tab.reorder_offset) > ANIM_SNAP_THRESHOLD) {
                tab.anim_offset += (tab.reorder_offset - tab.anim_offset) * lerp_factor;
                if (@abs(tab.anim_offset - tab.reorder_offset) <= ANIM_SNAP_THRESHOLD) {
                    tab.anim_offset = tab.reorder_offset;
                } else {
                    all_done = false;
                }
            }
        }

        // Snap-back animation after drag release
        if (self.snap_back_active) {
            if (self.drag_tab_index) |di| {
                if (di < self.tab_count) {
                    const target = self.snap_back_target;
                    self.drag_y += (target - self.drag_y) * lerp_factor;
                    if (@abs(self.drag_y - target) < SNAP_BACK_THRESHOLD) {
                        self.drag_y = target;
                        self.finalizeDrag();
                    } else {
                        all_done = false;
                    }
                } else {
                    self.finalizeDrag();
                }
            } else {
                self.snap_back_active = false;
            }
        }

        self.relayout();

        if (all_done) {
            self.anim_timer = 0;
            self.last_anim_time = 0;
            return c.G_SOURCE_REMOVE;
        }
        return 1; // G_SOURCE_CONTINUE
    }

    fn finalizeDrag(self: *VerticalTabBar) void {
        const di = self.drag_tab_index orelse return;

        // Remove dragging CSS
        if (di < self.tab_count) {
            c.gtk_widget_remove_css_class(self.tabs[di].tab_frame, "vtab-dragging");
        }

        // Check if position actually changed
        const original_index = di;
        const new_index = self.reorder_index;

        // Reset all animation offsets
        for (self.tabs[0..self.tab_count]) |*tab| {
            tab.reorder_offset = 0;
            tab.anim_offset = 0;
        }

        self.snap_back_active = false;
        self.drag_tab_index = null;
        self.dragging = false;
        self.updateSeparators();

        // If position changed, do the actual reorder
        if (original_index != new_index and original_index < self.tab_count) {
            const tab_id = self.tabs[original_index].id;
            // Rearrange the array
            self.moveTabToPosition(original_index, new_index);
            // Adjust selected_index
            if (self.selected_index) |sel| {
                if (sel == original_index) {
                    self.selected_index = new_index;
                } else if (original_index < new_index) {
                    if (sel > original_index and sel <= new_index) {
                        self.selected_index = sel - 1;
                    }
                } else {
                    if (sel >= new_index and sel < original_index) {
                        self.selected_index = sel + 1;
                    }
                }
            }
            // Fire callback
            if (self.on_reorder) |cb| cb(tab_id, new_index);
        }

        self.relayout();
    }

    // ── Gesture drag callbacks ──

    fn onGestureDragBegin(
        gesture: *c.GtkGestureDrag,
        _: f64,
        start_y: f64,
        user_data: c.gpointer,
    ) callconv(.c) void {
        const self: *VerticalTabBar = @ptrCast(@alignCast(user_data));
        if (self.tab_count <= 1) {
            _ = c.gtk_gesture_set_state(@ptrCast(gesture), c.GTK_EVENT_SEQUENCE_DENIED);
            return;
        }

        // Account for scroll offset
        const vadj = c.gtk_scrolled_window_get_vadjustment(self.scrolled);
        const scroll_offset = if (vadj != null) c.gtk_adjustment_get_value(vadj) else 0.0;
        const abs_y = start_y + scroll_offset;

        // Find which tab was clicked
        var found_idx: ?usize = null;
        for (self.tabs[0..self.tab_count], 0..) |tab, i| {
            if (abs_y >= tab.base_y and abs_y < tab.base_y + tab.height) {
                found_idx = i;
                break;
            }
        }

        if (found_idx == null) {
            _ = c.gtk_gesture_set_state(@ptrCast(gesture), c.GTK_EVENT_SEQUENCE_DENIED);
            return;
        }

        const idx = found_idx.?;

        // Don't claim yet — wait for sufficient drag movement in drag-update
        // so that simple clicks can propagate to tab click handlers.
        self.drag_tab_index = idx;
        self.drag_start_y = start_y;
        self.drag_offset_y = abs_y - self.tabs[idx].base_y;
        self.drag_y = self.tabs[idx].base_y;
        self.reorder_index = idx;
        self.drag_claimed = false;
        self.snap_back_active = false;
    }

    fn onGestureDragUpdate(
        _: *c.GtkGestureDrag,
        _: f64,
        offset_y: f64,
        user_data: c.gpointer,
    ) callconv(.c) void {
        const self: *VerticalTabBar = @ptrCast(@alignCast(user_data));
        const di = self.drag_tab_index orelse return;

        // Only claim the gesture once drag exceeds threshold
        if (!self.drag_claimed) {
            if (@abs(offset_y) < 8.0) return;
            self.drag_claimed = true;
            if (self.drag_gesture) |g| {
                _ = c.gtk_gesture_set_state(g, c.GTK_EVENT_SEQUENCE_CLAIMED);
            }
            self.dragging = true;

            // Raise dragged tab z-order (render on top)
            if (di < self.tab_count) {
                c.gtk_widget_insert_before(self.tabs[di].outer_revealer, self.fixed, null);
                c.gtk_widget_add_css_class(self.tabs[di].tab_frame, "vtab-dragging");
            }
            self.updateSeparators();
            self.startAnimTimer();
        }

        if (!self.dragging) return;
        if (di >= self.tab_count) return;

        // Account for scroll offset
        const vadj = c.gtk_scrolled_window_get_vadjustment(self.scrolled);
        const scroll_offset = if (vadj != null) c.gtk_adjustment_get_value(vadj) else 0.0;

        // Calculate the absolute start position in content coordinates
        const abs_start_y = self.drag_start_y + scroll_offset;
        // Current absolute cursor y in content coordinates
        const abs_cursor_y = abs_start_y + offset_y;
        // Position of the dragged tab: cursor y minus grab offset within the tab
        self.drag_y = abs_cursor_y - self.drag_offset_y;

        // Compute total height for clamping
        var total_height: f64 = 0;
        for (self.tabs[0..self.tab_count]) |tab| {
            total_height += tab.height + SPACING;
        }
        if (total_height > SPACING) total_height -= SPACING;

        const tab_height = self.tabs[di].height;
        // Clamp
        if (self.drag_y < 0) self.drag_y = 0;
        if (self.drag_y > total_height - tab_height) self.drag_y = total_height - tab_height;

        // Compute dragged tab center
        const drag_center = self.drag_y + tab_height / 2.0;

        // Find new position: use tab boundaries (edges) instead of midpoints
        // so actuation triggers at the gap between tabs, not at the neighbor's center.
        // Tabs above the dragged one use their bottom edge; tabs below use their top edge.
        var count_above: usize = 0;
        for (self.tabs[0..self.tab_count], 0..) |tab, i| {
            if (i == di) continue;
            const boundary = if (i < di) tab.base_y + tab.height else tab.base_y;
            if (drag_center > boundary) {
                count_above += 1;
            }
        }
        var new_pos: usize = count_above;

        // Enforce pinned/unpinned boundary
        const src_pinned = self.tabs[di].is_pinned;
        const pc = self.pinnedCount();
        if (src_pinned and new_pos >= pc) new_pos = if (pc > 0) pc - 1 else 0;
        if (!src_pinned and new_pos < pc) new_pos = pc;

        if (new_pos != self.reorder_index) {
            self.reorder_index = new_pos;
            self.updateReorderOffsets();
            self.updateSeparators();
            self.startAnimTimer();
        }

        // Autoscroll near edges of the scrolled window
        const scroll_widget = self.widget;
        var scroll_alloc: c.GtkAllocation = undefined;
        c.gtk_widget_get_allocation(scroll_widget, &scroll_alloc);
        const scroll_height: f64 = @floatFromInt(scroll_alloc.height);
        // Convert to viewport-relative y
        const viewport_y = self.drag_start_y + offset_y;
        if (viewport_y < AUTOSCROLL_ZONE) {
            self.autoscroll_speed = -(1.0 - viewport_y / AUTOSCROLL_ZONE) * 5.0;
            self.startAutoscroll();
        } else if (viewport_y > scroll_height - AUTOSCROLL_ZONE) {
            self.autoscroll_speed = (1.0 - (scroll_height - viewport_y) / AUTOSCROLL_ZONE) * 5.0;
            self.startAutoscroll();
        } else {
            self.stopAutoscroll();
        }

        self.relayout();
    }

    fn onGestureDragEnd(
        _: *c.GtkGestureDrag,
        _: f64,
        _: f64,
        user_data: c.gpointer,
    ) callconv(.c) void {
        const self: *VerticalTabBar = @ptrCast(@alignCast(user_data));
        if (!self.drag_claimed) {
            // Drag threshold was never exceeded — this was a click.
            // Reset state and let the click gesture handle it.
            self.drag_tab_index = null;
            return;
        }
        if (!self.dragging) return;

        self.dragging = false;
        self.stopAutoscroll();

        // Compute snap-back target: the y position the tab will occupy at
        // reorder_index, based on the heights of the non-dragged tabs before it.
        if (self.drag_tab_index) |di| {
            var target: f64 = 0;
            var count: usize = 0;
            for (self.tabs[0..self.tab_count], 0..) |tab, i| {
                if (i == di) continue;
                if (count >= self.reorder_index) break;
                target += tab.height + SPACING;
                count += 1;
            }
            self.snap_back_target = target;
        }

        // Start snap-back animation
        self.snap_back_active = true;
        self.startAnimTimer();
    }

    fn updateReorderOffsets(self: *VerticalTabBar) void {
        const di = self.drag_tab_index orelse return;
        const new_pos = self.reorder_index;

        for (self.tabs[0..self.tab_count], 0..) |*tab, i| {
            if (i == di) {
                tab.reorder_offset = 0;
                continue;
            }

            if (di < new_pos) {
                // Dragged tab moved down: tabs between (di, new_pos] shift up by 1
                if (i > di and i <= new_pos) {
                    tab.reorder_offset = -1;
                } else {
                    tab.reorder_offset = 0;
                }
            } else if (di > new_pos) {
                // Dragged tab moved up: tabs between [new_pos, di) shift down by 1
                if (i >= new_pos and i < di) {
                    tab.reorder_offset = 1;
                } else {
                    tab.reorder_offset = 0;
                }
            } else {
                tab.reorder_offset = 0;
            }
        }
    }

    fn scrollToTab(self: *VerticalTabBar, idx: usize) void {
        if (idx >= self.tab_count) return;
        const tab = &self.tabs[idx];
        const vadj = c.gtk_scrolled_window_get_vadjustment(self.scrolled);
        if (vadj != null) {
            const y = tab.base_y;
            const h = tab.height;
            const page = c.gtk_adjustment_get_page_size(vadj);
            const current = c.gtk_adjustment_get_value(vadj);
            if (y < current) {
                c.gtk_adjustment_set_value(vadj, y);
            } else if (y + h > current + page) {
                c.gtk_adjustment_set_value(vadj, y + h - page);
            }
        }
    }

    fn attachTabControllers(self: *VerticalTabBar, idx: usize) void {
        const tab = &self.tabs[idx];
        const tab_frame = tab.tab_frame;

        const data = self.alloc.create(TabEventData) catch return;
        data.* = .{ .vtab = self, .tab_id = tab.id };

        // Left click → select (use "released" so that clicks on the close button,
        // which claim the gesture on press, deny this gesture before "released" fires)
        const click1 = c.gtk_gesture_click_new();
        c.gtk_gesture_single_set_button(@ptrCast(click1), 1);
        _ = c.g_signal_connect_data(@ptrCast(click1), "released", @as(c.GCallback, @ptrCast(&onTabClick)), @ptrCast(data), null, 0);
        c.gtk_widget_add_controller(tab_frame, @ptrCast(click1));

        // Middle click → close
        const click2 = c.gtk_gesture_click_new();
        c.gtk_gesture_single_set_button(@ptrCast(click2), 2);
        _ = c.g_signal_connect_data(@ptrCast(click2), "pressed", @as(c.GCallback, @ptrCast(&onTabMiddleClick)), @ptrCast(data), null, 0);
        c.gtk_widget_add_controller(tab_frame, @ptrCast(click2));

        // Right click → context menu
        const click3 = c.gtk_gesture_click_new();
        c.gtk_gesture_single_set_button(@ptrCast(click3), 3);
        _ = c.g_signal_connect_data(@ptrCast(click3), "pressed", @as(c.GCallback, @ptrCast(&onTabContextMenu)), @ptrCast(data), null, 0);
        c.gtk_widget_add_controller(tab_frame, @ptrCast(click3));

        // Hover → show/hide close button
        const motion = c.gtk_event_controller_motion_new();
        _ = c.g_signal_connect_data(@ptrCast(motion), "enter", @as(c.GCallback, @ptrCast(&onTabHoverEnter)), @ptrCast(data), null, 0);
        _ = c.g_signal_connect_data(@ptrCast(motion), "leave", @as(c.GCallback, @ptrCast(&onTabHoverLeave)), @ptrCast(data), @ptrCast(&onTabEventDataDestroy), 0);
        c.gtk_widget_add_controller(tab_frame, @ptrCast(motion));

        // Close button click
        const close_data = self.alloc.create(TabEventData) catch return;
        close_data.* = .{ .vtab = self, .tab_id = tab.id };
        _ = c.g_signal_connect_data(@ptrCast(tab.close_btn), "clicked", @as(c.GCallback, @ptrCast(&onCloseClicked)), @ptrCast(close_data), @ptrCast(&onTabEventDataDestroy), 0);
    }

    // ── Helper structs ──

    const TabEventData = struct {
        vtab: *VerticalTabBar,
        tab_id: u64,
    };

    const RevealData = struct {
        revealer: *c.GtkRevealer,
        vtab: *VerticalTabBar,
        tab_id: u64,
    };

    // ── Callbacks ──

    fn revealIdleCallback(data: c.gpointer) callconv(.c) c.gboolean {
        const rd: *RevealData = @ptrCast(@alignCast(data));
        // Clear tracking on the tab (if it still exists)
        if (rd.vtab.findTabById(rd.tab_id)) |idx| {
            rd.vtab.tabs[idx].reveal_source_id = 0;
        }
        c.gtk_revealer_set_reveal_child(rd.revealer, 1);
        rd.vtab.relayout();
        return c.G_SOURCE_REMOVE;
    }

    fn revealDataDestroy(data: c.gpointer) callconv(.c) void {
        const rd: *RevealData = @ptrCast(@alignCast(data));
        rd.vtab.alloc.destroy(rd);
    }

    fn onTabEventDataDestroy(data: c.gpointer, _: *c.GClosure) callconv(.c) void {
        const d: *TabEventData = @ptrCast(@alignCast(data));
        d.vtab.alloc.destroy(d);
    }

    fn onTabClick(_: *c.GtkGestureClick, _: c_int, _: f64, _: f64, data: c.gpointer) callconv(.c) void {
        const d: *TabEventData = @ptrCast(@alignCast(data));
        if (d.vtab.on_select) |cb| cb(d.tab_id);
    }

    fn onTabMiddleClick(_: *c.GtkGestureClick, _: c_int, _: f64, _: f64, data: c.gpointer) callconv(.c) void {
        const d: *TabEventData = @ptrCast(@alignCast(data));
        if (d.vtab.on_middle_click) |cb| cb(d.tab_id);
    }

    fn onTabContextMenu(_: *c.GtkGestureClick, _: c_int, x: f64, y: f64, data: c.gpointer) callconv(.c) void {
        const d: *TabEventData = @ptrCast(@alignCast(data));
        const idx = d.vtab.findTabById(d.tab_id) orelse return;
        if (d.vtab.on_context_menu) |cb| cb(d.tab_id, x, y, d.vtab.tabs[idx].tab_frame);
    }

    fn onTabHoverEnter(_: *c.GtkEventControllerMotion, _: f64, _: f64, data: c.gpointer) callconv(.c) void {
        const d: *TabEventData = @ptrCast(@alignCast(data));
        const idx = d.vtab.findTabById(d.tab_id) orelse return;
        d.vtab.hover_tab_index = idx;
        c.gtk_revealer_set_reveal_child(@ptrCast(d.vtab.tabs[idx].close_revealer), 1);
        d.vtab.updateSeparators();
    }

    fn onTabHoverLeave(_: *c.GtkEventControllerMotion, data: c.gpointer) callconv(.c) void {
        const d: *TabEventData = @ptrCast(@alignCast(data));
        const idx = d.vtab.findTabById(d.tab_id) orelse return;
        d.vtab.hover_tab_index = null;
        c.gtk_revealer_set_reveal_child(@ptrCast(d.vtab.tabs[idx].close_revealer), 0);
        d.vtab.updateSeparators();
    }

    fn onCloseClicked(_: *c.GtkButton, data: c.gpointer) callconv(.c) void {
        const d: *TabEventData = @ptrCast(@alignCast(data));
        if (d.vtab.on_close) |cb| cb(d.tab_id);
    }

    // ── Autoscroll ──

    fn startAutoscroll(self: *VerticalTabBar) void {
        if (self.autoscroll_timer != 0) return;
        self.autoscroll_timer = c.g_timeout_add(50, @ptrCast(&autoscrollTick), @ptrCast(self));
    }

    fn stopAutoscroll(self: *VerticalTabBar) void {
        if (self.autoscroll_timer != 0) {
            _ = c.g_source_remove(self.autoscroll_timer);
            self.autoscroll_timer = 0;
        }
        self.autoscroll_speed = 0;
    }

    fn autoscrollTick(data: c.gpointer) callconv(.c) c.gboolean {
        const self: *VerticalTabBar = @ptrCast(@alignCast(data));
        if (!self.dragging) {
            self.autoscroll_timer = 0;
            return c.G_SOURCE_REMOVE;
        }
        const vadj = c.gtk_scrolled_window_get_vadjustment(self.scrolled);
        if (vadj != null) {
            const current = c.gtk_adjustment_get_value(vadj);
            c.gtk_adjustment_set_value(vadj, current + self.autoscroll_speed);
        }
        return 1; // G_SOURCE_CONTINUE
    }

    // ── Keyboard navigation ──

    fn onKeyPressed(_: *c.GtkEventControllerKey, keyval: c.guint, _: c.guint, _: c.GdkModifierType, data: c.gpointer) callconv(.c) c.gboolean {
        const self: *VerticalTabBar = @ptrCast(@alignCast(data));
        if (self.tab_count == 0) return 0;

        const current = self.selected_index orelse 0;

        switch (keyval) {
            c.GDK_KEY_Up => {
                if (current > 0) {
                    const new_id = self.tabs[current - 1].id;
                    if (self.on_select) |cb| cb(new_id);
                }
                return 1;
            },
            c.GDK_KEY_Down => {
                if (current + 1 < self.tab_count) {
                    const new_id = self.tabs[current + 1].id;
                    if (self.on_select) |cb| cb(new_id);
                }
                return 1;
            },
            c.GDK_KEY_Home => {
                const new_id = self.tabs[0].id;
                if (self.on_select) |cb| cb(new_id);
                return 1;
            },
            c.GDK_KEY_End => {
                const new_id = self.tabs[self.tab_count - 1].id;
                if (self.on_select) |cb| cb(new_id);
                return 1;
            },
            c.GDK_KEY_Delete => {
                const del_id = self.tabs[current].id;
                if (self.on_close) |cb| cb(del_id);
                return 1;
            },
            else => return 0,
        }
    }

};
