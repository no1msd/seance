const std = @import("std");
const c = @import("c.zig").c;
const PaneGroup = @import("pane_group.zig").PaneGroup;
const Pane = @import("pane.zig").Pane;
const Panel = @import("panel.zig").Panel;
const Column = @import("column.zig").Column;

pub const StatusEntry = struct {
    key: [64]u8 = undefined,
    key_len: usize = 0,
    value: [256]u8 = undefined,
    value_len: usize = 0,
    priority: i32 = 0,
    is_agent: bool = false,
    display_name: [32]u8 = undefined,
    display_name_len: usize = 0,

    pub fn getKey(self: *const StatusEntry) []const u8 {
        return self.key[0..self.key_len];
    }

    pub fn getValue(self: *const StatusEntry) []const u8 {
        return self.value[0..self.value_len];
    }

    pub fn getDisplayName(self: *const StatusEntry) ?[]const u8 {
        if (self.display_name_len == 0) return null;
        return self.display_name[0..self.display_name_len];
    }
};

pub const LogLevel = enum { info, progress, success, warning, @"error" };

pub const LogEntry = struct {
    message: [256]u8 = undefined,
    message_len: usize = 0,
    level: LogLevel = .info,
    timestamp: i64 = 0,

    pub fn getMessage(self: *const LogEntry) []const u8 {
        return self.message[0..self.message_len];
    }
};

pub const ProgressState = struct {
    value: f64 = 0.0, // 0.0 to 1.0
    label: [128]u8 = undefined,
    label_len: usize = 0,
    active: bool = false,

    pub fn getLabel(self: *const ProgressState) ?[]const u8 {
        if (self.label_len == 0) return null;
        return self.label[0..self.label_len];
    }
};

pub const WorkspaceMetadata = struct {
    status_entries: [16]StatusEntry = [_]StatusEntry{.{}} ** 16,
    status_count: usize = 0,
    log_entries: [50]LogEntry = [_]LogEntry{.{}} ** 50,
    log_head: usize = 0, // ring buffer write position
    log_count: usize = 0,
    progress: ProgressState = .{},

    pub fn setStatus(self: *WorkspaceMetadata, key: []const u8, value: []const u8, priority: i32, is_agent: bool, display_name: ?[]const u8) void {
        // Update existing entry with same key
        for (self.status_entries[0..self.status_count]) |*entry| {
            if (std.mem.eql(u8, entry.getKey(), key)) {
                const vlen = @min(value.len, entry.value.len);
                @memcpy(entry.value[0..vlen], value[0..vlen]);
                entry.value_len = vlen;
                entry.priority = priority;
                entry.is_agent = is_agent;
                if (display_name) |dn| {
                    const dnlen = @min(dn.len, entry.display_name.len);
                    @memcpy(entry.display_name[0..dnlen], dn[0..dnlen]);
                    entry.display_name_len = dnlen;
                }
                return;
            }
        }
        // Add new entry if space available
        if (self.status_count >= self.status_entries.len) return;
        var entry = &self.status_entries[self.status_count];
        entry.* = .{};
        const klen = @min(key.len, entry.key.len);
        @memcpy(entry.key[0..klen], key[0..klen]);
        entry.key_len = klen;
        const vlen = @min(value.len, entry.value.len);
        @memcpy(entry.value[0..vlen], value[0..vlen]);
        entry.value_len = vlen;
        entry.priority = priority;
        entry.is_agent = is_agent;
        if (display_name) |dn| {
            const dnlen = @min(dn.len, entry.display_name.len);
            @memcpy(entry.display_name[0..dnlen], dn[0..dnlen]);
            entry.display_name_len = dnlen;
        }
        self.status_count += 1;
    }

    pub fn clearStatus(self: *WorkspaceMetadata, key: []const u8) bool {
        for (0..self.status_count) |i| {
            if (std.mem.eql(u8, self.status_entries[i].getKey(), key)) {
                var j = i;
                while (j + 1 < self.status_count) : (j += 1) {
                    self.status_entries[j] = self.status_entries[j + 1];
                }
                self.status_count -= 1;
                return true;
            }
        }
        return false;
    }

    pub fn appendLog(self: *WorkspaceMetadata, message: []const u8, level: LogLevel, timestamp: i64) void {
        var entry = &self.log_entries[self.log_head];
        entry.* = .{};
        const mlen = @min(message.len, entry.message.len);
        @memcpy(entry.message[0..mlen], message[0..mlen]);
        entry.message_len = mlen;
        entry.level = level;
        entry.timestamp = timestamp;
        self.log_head = (self.log_head + 1) % self.log_entries.len;
        if (self.log_count < self.log_entries.len) {
            self.log_count += 1;
        }
    }

    pub fn clearLog(self: *WorkspaceMetadata) void {
        self.log_head = 0;
        self.log_count = 0;
    }

    pub fn getRecentLogs(self: *const WorkspaceMetadata, out: []LogEntry) usize {
        const count = @min(self.log_count, out.len);
        for (0..count) |i| {
            const idx = if (self.log_head >= i + 1)
                self.log_head - i - 1
            else
                self.log_entries.len - (i + 1 - self.log_head);
            out[i] = self.log_entries[idx];
        }
        return count;
    }

    pub fn setProgress(self: *WorkspaceMetadata, value: f64, label: ?[]const u8) void {
        self.progress.value = std.math.clamp(value, 0.0, 1.0);
        self.progress.active = true;
        if (label) |lbl| {
            const llen = @min(lbl.len, self.progress.label.len);
            @memcpy(self.progress.label[0..llen], lbl[0..llen]);
            self.progress.label_len = llen;
        } else {
            self.progress.label_len = 0;
        }
    }

    pub fn clearProgress(self: *WorkspaceMetadata) void {
        self.progress.active = false;
        self.progress.value = 0.0;
        self.progress.label_len = 0;
    }

    pub fn getSortedStatusIndices(self: *const WorkspaceMetadata, out: []usize) usize {
        const count = @min(self.status_count, out.len);
        for (0..count) |i| {
            out[i] = i;
        }
        var i: usize = 1;
        while (i < count) : (i += 1) {
            const tmp = out[i];
            var j: usize = i;
            while (j > 0 and self.statusLessThan(tmp, out[j - 1])) : (j -= 1) {
                out[j] = out[j - 1];
            }
            out[j] = tmp;
        }
        return count;
    }

    fn statusLessThan(self: *const WorkspaceMetadata, a_idx: usize, b_idx: usize) bool {
        const a = &self.status_entries[a_idx];
        const b = &self.status_entries[b_idx];
        if (a.priority != b.priority) return a.priority < b.priority;
        return std.mem.lessThan(u8, a.getKey(), b.getKey());
    }
};

pub const FocusDirection = enum { left, right, up, down };

pub const Workspace = struct {
    id: u64,
    title: [128]u8 = [_]u8{0} ** 128,
    title_len: usize = 0,
    title_is_custom: bool = false,
    custom_color: [8]u8 = [_]u8{0} ** 8, // hex color e.g. "#C0392B"
    custom_color_len: usize = 0,
    git_branch: [128]u8 = [_]u8{0} ** 128,
    git_branch_len: usize = 0,
    git_dirty: bool = false,
    ports: [16]u16 = [_]u16{0} ** 16,
    ports_len: usize = 0,
    is_pinned: bool = false,
    port_ordinal: u32 = std.math.maxInt(u32),

    // Sidebar metadata (ephemeral, not persisted)
    metadata: WorkspaceMetadata = .{},

    // Layout: columns on a GtkFixed
    container: *c.GtkWidget, // outer GtkBox
    fixed: *c.GtkWidget, // GtkFixed for positioning pane groups
    columns: std.ArrayList(Column),
    focused_column: usize = 0,
    last_focused_pane_id: ?u64 = null,
    camera: f64 = 0.0,
    camera_target: f64 = 0.0,
    cached_width: c_int = 0,
    cached_height: c_int = 0,
    tick_callback_id: c.guint = 0,
    last_frame_time: i64 = 0,

    // Suppress transient onFocusEnter during restructuring
    restructuring: bool = false,

    // Resize handles: transparent overlay widgets at column/row dividers
    col_handles: [max_col_handles]ResizeHandle = undefined,
    row_handles: [max_row_handles]ResizeHandle = undefined,
    resize_drag_kind: DragKind = .none,
    resize_drag_col: usize = 0,
    resize_drag_pane: usize = 0,
    resize_drag_start_a: f64 = 0, // left col or above pane weight at drag start
    resize_drag_start_b: f64 = 0, // right col or below pane weight at drag start

    alloc: std.mem.Allocator,

    const max_col_handles: usize = 16;
    const max_row_handles: usize = 64;
    const handle_thickness: c_int = 11;
    const ResizeHandle = struct {
        widget: *c.GtkWidget,
        col_idx: usize = 0,
        pane_idx: usize = 0,
    };
    const DragKind = enum { none, column, row };

    /// Get the focused PaneGroup (first group in the focused column).
    /// Returns null if the focused column is closing or has no groups.
    pub fn focusedGroup(self: *Workspace) ?*PaneGroup {
        if (self.columns.items.len == 0) return null;
        if (self.focused_column >= self.columns.items.len) return null;
        const col = &self.columns.items[self.focused_column];
        if (col.closing) return null;
        if (col.groups.items.len == 0) return null;
        return col.groups.items[0];
    }

    /// Clear pane history if it references the given pane.
    pub fn clearPaneHistoryFor(self: *Workspace, pane_id: u64) void {
        if (self.last_focused_pane_id) |lid| {
            if (lid == pane_id) self.last_focused_pane_id = null;
        }
    }

    /// Save the currently focused pane ID into history.
    fn savePaneFocusHistory(self: *Workspace) void {
        const grp = self.focusedGroup() orelse return;
        const pane = grp.focusedTerminalPane() orelse return;
        self.last_focused_pane_id = pane.id;
    }

    /// Switch focus to the last-focused pane. Returns true if switched.
    pub fn lastPane(self: *Workspace) bool {
        const target_id = self.last_focused_pane_id orelse return false;
        // Guard against onFocusEnter re-entry: grp.focus() calls
        // gtk_widget_grab_focus, which may fail for unrealized widgets
        // (headless/cage), causing GTK to re-focus the old pane and
        // trigger onFocusEnter, undoing the column switch.
        self.restructuring = true;
        defer self.restructuring = false;
        // Find the column and panel containing this pane
        for (self.columns.items, 0..) |col, col_idx| {
            if (col.closing) continue;
            for (col.groups.items) |grp| {
                for (grp.panels.items, 0..) |panel, pi| {
                    if (panel.getId() == target_id) {
                        // Save current focus before switching
                        self.savePaneFocusHistory();
                        if (self.focusedGroup()) |old| old.unfocus();
                        self.focused_column = col_idx;
                        grp.switchToPanel(pi);
                        grp.focus();
                        self.panToFocusedColumn();
                        return true;
                    }
                }
            }
        }
        return false;
    }

    /// Build the shared container + GtkFixed + GtkScrolledWindow widget
    /// tree used by every workspace. The ScrolledWindow prevents GtkFixed's
    /// children-based minimum size from propagating up the widget tree.
    fn initWidgets() struct { container: *c.GtkWidget, fixed: *c.GtkWidget } {
        const container = c.gtk_box_new(c.GTK_ORIENTATION_VERTICAL, 0);
        c.gtk_widget_set_hexpand(container, 1);
        c.gtk_widget_set_vexpand(container, 1);

        const fixed = c.gtk_fixed_new();
        c.gtk_widget_set_overflow(fixed, c.GTK_OVERFLOW_HIDDEN);

        const scroll = c.gtk_scrolled_window_new();
        c.gtk_scrolled_window_set_policy(@ptrCast(scroll), c.GTK_POLICY_EXTERNAL, c.GTK_POLICY_EXTERNAL);
        c.gtk_widget_set_hexpand(scroll, 1);
        c.gtk_widget_set_vexpand(scroll, 1);
        c.gtk_scrolled_window_set_child(@ptrCast(scroll), fixed);
        c.gtk_box_append(@ptrCast(container), scroll);

        return .{ .container = container, .fixed = fixed };
    }

    pub fn create(alloc: std.mem.Allocator, title: []const u8) !*Workspace {
        const ws = try alloc.create(Workspace);
        const widgets = initWidgets();

        ws.* = .{
            .id = nextId(),
            .container = widgets.container,
            .fixed = widgets.fixed,
            .columns = .empty,
            .alloc = alloc,
        };
        ws.setTitle(title);

        ws.tick_callback_id = c.gtk_widget_add_tick_callback(
            widgets.fixed,
            @ptrCast(&onTick),
            @ptrCast(ws),
            null,
        );
        ws.initResizeHandles();

        _ = try ws.addColumn(null);

        return ws;
    }

    /// Create workspace for session restore — first pane spawns with given CWD.
    pub fn createForRestore(alloc: std.mem.Allocator, cwd: ?[*:0]const u8) !*Workspace {
        const ws = try alloc.create(Workspace);
        const widgets = initWidgets();

        ws.* = .{
            .id = nextId(),
            .container = widgets.container,
            .fixed = widgets.fixed,
            .columns = .empty,
            .alloc = alloc,
        };
        ws.setTitle("Terminal");

        ws.tick_callback_id = c.gtk_widget_add_tick_callback(
            widgets.fixed,
            @ptrCast(&onTick),
            @ptrCast(ws),
            null,
        );
        ws.initResizeHandles();

        _ = try ws.addColumn(cwd);

        return ws;
    }

    /// Add a new column at the end of the strip with one pane group.
    pub fn addColumn(self: *Workspace, cwd: ?[*:0]const u8) !*PaneGroup {
        const grp = try PaneGroup.create(self.alloc, cwd, self.id);
        errdefer grp.destroy();

        // If there's exactly one live column, it's currently displayed at
        // full width (solo-expand rule). Set its animated width to 1.0 so
        // it smoothly contracts to its real target when the new column opens.
        if (self.liveColumnCount() == 1) {
            for (self.columns.items) |*existing| {
                if (!existing.closing) {
                    existing.width = Column.max_width;
                    break;
                }
            }
        }
        var col = try Column.init(self.alloc, Column.default_width, grp);
        errdefer col.deinit(self.alloc);

        // Animate opening if this isn't the first column
        if (self.columns.items.len > 0) {
            col.open_anim = 0.0;
        }

        // Default to stacked mode
        col.layout_mode = .stacked;
        col.stacked_anim = 1.0;

        const insert_idx = @min(self.focused_column + 1, self.columns.items.len);
        try self.columns.insert(self.alloc, insert_idx, col);
        self.focused_column = insert_idx;
        self.panToFocusedColumn();

        // Add PaneGroup container widget to GtkFixed (position set by applyLayout)
        const widget = grp.getWidget();
        c.gtk_fixed_put(@ptrCast(self.fixed), widget, 0, 0);

        // Enter stacked mode: detach panels from AdwTabView, put on GtkFixed
        grp.enterStackedMode(self.fixed);

        // Hide initially to avoid flash before first animation tick
        if (col.open_anim < 1.0) {
            c.gtk_widget_set_opacity(widget, 0);
            // Also hide stacked panels
            for (grp.panels.items) |panel| {
                c.gtk_widget_set_opacity(panel.getWidget(), 0);
            }
        }

        self.applyLayout();
        return grp;
    }

    /// Position all pane group widgets according to column layout and camera.
    pub fn applyLayout(self: *Workspace) void {
        // Use cached viewport size — NOT a live widget query. GtkFixed
        // computes its minimum size from children positions, which inflates
        // all ancestor widgets and creates a feedback loop each frame.
        if (self.cached_width <= 0 or self.cached_height <= 0) return;

        const fw: f64 = @floatFromInt(self.cached_width);
        const fh: f64 = @floatFromInt(self.cached_height);

        // Solo-expand rule: when only one live (non-closing) column exists,
        // it expands to fill the viewport, smoothly growing/shrinking as
        // sibling columns close/open.
        var live_count: usize = 0;
        var total_closing_slots: f64 = 0.0;
        var total_strip_width: f64 = 0.0;
        for (self.columns.items) |col2| {
            if (col2.closing) {
                const slot = col2.width * col2.open_anim;
                total_closing_slots += slot;
                total_strip_width += slot;
            } else {
                live_count += 1;
                total_strip_width += col2.width;
            }
        }
        const solo_expand = live_count == 1;
        if (solo_expand) total_strip_width = @max(total_strip_width, 1.0);

        // Round camera offset once so that panning shifts all columns by
        // the same whole-pixel amount, preventing 1 px jumps on switch.
        const cam_px = @round(self.camera * fw);

        var x: f64 = 0.0; // layout position (closing columns shrink their slot)
        var x_full: f64 = 0.0; // original position (full widths, for closing columns)
        for (self.columns.items, 0..) |col, col_idx| {
            // When this is the sole live column, expand to fill remaining space.
            const effective_w = if (solo_expand and !col.closing)
                @max(col.width, 1.0 - total_closing_slots)
            else
                col.width;

            // Closing columns render at their original position so the
            // scale animation stays centered on the column being closed,
            // not on the column sliding in from the right.
            const pos = if (col.closing) x_full else x;
            // Round column edge and camera independently so camera pans
            // always move columns by integer pixel amounts.
            const pos_px = @round(pos * fw);
            const screen_x = pos_px - cam_px;
            const pixel_w: f64 = @round((pos + effective_w) * fw) - pos_px;

            // Opening animation: scale from 50% to 100%, centered via transform
            const col_scale = 0.5 + 0.5 * col.open_anim;

            // Right-edge divider: last column with empty space to its right
            const is_last_col = col_idx == self.columns.items.len - 1;
            const has_right_empty = is_last_col and total_strip_width < 1.0 - 0.001;

            for (col.groups.items) |grp| {
                const end_x = screen_x + pixel_w;
                const offscreen = end_x <= 0 or screen_x >= fw;

                if (grp.in_stacked_mode or col.isModeTransitioning()) {
                    self.layoutStackedGroup(grp, .{
                        .screen_x = screen_x,
                        .pixel_w = pixel_w,
                        .fh = fh,
                        .col_scale = col_scale,
                        .open_anim = col.open_anim,
                        .stacked_anim = col.stacked_anim,
                        .active_at_switch = col.active_at_switch,
                        .col_idx = col_idx,
                        .has_right_empty = has_right_empty,
                        .offscreen = offscreen,
                        .tab_bar_height = col.measured_tab_bar_height,
                    });
                } else {
                    // -- Tabbed layout --
                    const w = grp.getWidget();
                    if (offscreen) {
                        c.gtk_widget_set_visible(w, 0);
                    } else {
                        c.gtk_widget_set_visible(w, 1);
                        c.gtk_widget_set_opacity(w, col.open_anim);
                        const pw: c_int = @intFromFloat(@max(1.0, @round(pixel_w)));
                        const ph: c_int = @intFromFloat(@max(1.0, @round(fh)));
                        c.gtk_widget_set_size_request(w, pw, ph);
                        setChildTransform(self.fixed, w, @floatCast(col_scale), @floatCast(pixel_w), @floatCast(fh), screen_x, 0);
                        setCssClass(w, "column-has-divider", col_idx > 0);
                        setCssClass(w, "column-has-right-divider", has_right_empty);
                    }
                }
            }

            // Animate layout slot width so subsequent columns slide
            // smoothly instead of teleporting during open/close.
            x += if (col.closing) col.width * col.open_anim else effective_w * col.open_anim;
            x_full += col.width;
        }

        self.positionResizeHandles();
        self.updateMultiPaneClass();
    }

    fn lerp(a: f64, b: f64, t: f64) f64 {
        return a + (b - a) * t;
    }

    fn setCssClass(widget: *c.GtkWidget, class: [*:0]const u8, active: bool) void {
        if (active) {
            c.gtk_widget_add_css_class(widget, class);
        } else {
            c.gtk_widget_remove_css_class(widget, class);
        }
    }

    /// Apply a visual center-point scale transform to a GtkFixed child,
    /// with position baked into the transform. gtk_fixed_set_child_transform
    /// and gtk_fixed_move write to the same internal field, so position must
    /// be included in the transform itself.
    fn setChildTransform(fixed: *c.GtkWidget, widget: *c.GtkWidget, scale: f32, width: f32, height: f32, pos_x: f64, pos_y: f64) void {
        if (scale >= 0.999) {
            // No scale — use normal positioning (also clears any prior transform).
            // Round to pixel boundaries so GTK composites the GL texture
            // without bilinear filtering, which causes blurry terminal text.
            c.gtk_fixed_move(@ptrCast(fixed), widget, @round(pos_x), @round(pos_y));
            return;
        }
        const px: f32 = @floatCast(pos_x);
        const py: f32 = @floatCast(pos_y);
        const cx = width / 2.0;
        const cy = height / 2.0;
        // Combined: translate(pos) * scale_from_center(cx, cy, s)
        // = translate(px+cx, py+cy) * scale(s, s) * translate(-cx, -cy)
        var t: ?*c.GskTransform = c.gsk_transform_new();
        t = c.gsk_transform_translate(t, &c.graphene_point_t{ .x = px + cx, .y = py + cy });
        t = c.gsk_transform_scale(t, scale, scale);
        t = c.gsk_transform_translate(t, &c.graphene_point_t{ .x = -cx, .y = -cy });
        c.gtk_fixed_set_child_transform(@ptrCast(fixed), widget, t);
        c.gsk_transform_unref(t);
    }

    const StackedLayoutContext = struct {
        screen_x: f64,
        pixel_w: f64,
        fh: f64,
        col_scale: f64,
        open_anim: f64,
        stacked_anim: f64,
        active_at_switch: usize,
        col_idx: usize,
        has_right_empty: bool,
        offscreen: bool,
        tab_bar_height: f64,
    };

    /// Position PaneGroup container and individual panels for stacked/transitioning layout.
    fn layoutStackedGroup(self: *Workspace, grp: *PaneGroup, ctx: StackedLayoutContext) void {
        const container_w = grp.getWidget();
        const tab_area_h = ctx.tab_bar_height * (1.0 - ctx.stacked_anim);

        if (ctx.offscreen) {
            c.gtk_widget_set_visible(container_w, 0);
            for (grp.panels.items) |panel| {
                c.gtk_widget_set_visible(panel.getWidget(), 0);
            }
            return;
        }

        // Show/hide the PaneGroup container based on tab bar area
        if (tab_area_h > 1.0) {
            c.gtk_widget_set_visible(container_w, 1);
            c.gtk_widget_set_opacity(container_w, ctx.open_anim);
            const tbw: c_int = @intFromFloat(@max(1.0, @round(ctx.pixel_w)));
            const tbh: c_int = @intFromFloat(@max(1.0, @round(tab_area_h)));
            c.gtk_widget_set_size_request(container_w, tbw, tbh);
            setChildTransform(self.fixed, container_w, @floatCast(ctx.col_scale), @floatCast(ctx.pixel_w), @floatCast(tab_area_h), ctx.screen_x, 0);
        } else {
            c.gtk_widget_set_visible(container_w, 0);
        }

        setCssClass(container_w, "column-has-divider", ctx.col_idx > 0);
        setCssClass(container_w, "column-has-right-divider", ctx.has_right_empty);

        // Position individual panels using unscaled dimensions;
        // col_scale is applied via transform only.
        if (grp.panels.items.len == 0) return;
        const available_h = ctx.fh - tab_area_h;

        for (grp.panels.items, 0..) |panel, i| {
            const pw = panel.getWidget();
            // All panels are terminals (see panel.zig); stacked layout
            // requires per-pane animation state.
            const pane = panel.asTerminal().?;

            // Deferred AdwTabView page disposal after a tabbed-mode
            // expel can unparent the widget from GtkFixed.  Re-attach
            // and release the extra ref that expelPane held.
            const actual_parent = c.gtk_widget_get_parent(pw);
            if (actual_parent != @as(*c.GtkWidget, @ptrCast(self.fixed))) {
                if (actual_parent == null) {
                    c.gtk_fixed_put(@ptrCast(self.fixed), pw, 0, 0);
                    _ = c.g_object_unref(@ptrCast(pw));
                } else {
                    continue;
                }
            }

            const slot_y = pane.stacked_frac_y * available_h;
            const slot_h = pane.stacked_frac_h * available_h;
            // Horizontal offset for cross-column move animation
            const panel_x = ctx.screen_x + pane.stacked_offset_x;

            setCssClass(pw, "column-has-divider", ctx.col_idx > 0);
            setCssClass(pw, "row-has-divider", i > 0);
            setCssClass(pw, "column-has-right-divider", ctx.has_right_empty);

            if (i == ctx.active_at_switch) {
                // Active panel: interpolate from full column to slot
                const panel_y = lerp(tab_area_h, tab_area_h + slot_y, ctx.stacked_anim);
                const panel_h = lerp(available_h, slot_h, ctx.stacked_anim);
                const iw: c_int = @intFromFloat(@max(1.0, @round(ctx.pixel_w)));
                const ih: c_int = @intFromFloat(@max(1.0, @round(panel_h)));
                c.gtk_widget_set_visible(pw, 1);
                c.gtk_widget_set_opacity(pw, ctx.open_anim);
                c.gtk_widget_set_size_request(pw, iw, ih);
                setChildTransform(self.fixed, pw, @floatCast(ctx.col_scale), @floatCast(ctx.pixel_w), @floatCast(panel_h), panel_x, panel_y);
            } else {
                // Inactive panel: fade+scale animation via transform
                const anim = pane.stacked_open_anim;
                const target_y = tab_area_h + slot_y;

                if (anim <= 0.01 and i != grp.active_panel) {
                    c.gtk_widget_set_visible(pw, 0);
                } else {
                    const p_scale = 0.5 + 0.5 * anim;
                    const combined_scale = ctx.col_scale * p_scale;
                    const iw: c_int = @intFromFloat(@max(1.0, @round(ctx.pixel_w)));
                    const ih: c_int = @intFromFloat(@max(1.0, @round(slot_h)));
                    c.gtk_widget_set_visible(pw, 1);
                    c.gtk_widget_set_opacity(pw, anim * ctx.open_anim);
                    c.gtk_widget_set_size_request(pw, iw, ih);
                    setChildTransform(self.fixed, pw, @floatCast(combined_scale), @floatCast(ctx.pixel_w), @floatCast(slot_h), panel_x, target_y);
                }
            }
        }
    }

    /// Remove a column by index. Starts a close animation unless this is the
    /// only remaining column (in which case removal is immediate).
    /// Returns true if the workspace is now empty.
    pub fn removeColumn(self: *Workspace, col_idx: usize) bool {
        if (col_idx >= self.columns.items.len) return self.liveColumnCount() == 0;

        const col = &self.columns.items[col_idx];
        if (col.closing) return self.liveColumnCount() == 0;

        const was_focused = self.focused_column == col_idx;

        // Only column left — remove immediately (workspace will be destroyed).
        if (self.columns.items.len <= 1) {
            return self.finishRemoveColumn(col_idx);
        }

        // Start close animation
        col.closing = true;

        // Move focus away from closing column
        if (was_focused) {
            self.restructuring = true;
            for (col.groups.items) |grp| grp.unfocus();
            self.focusNextLiveColumn(col_idx);
            self.restructuring = false;
        }

        self.applyLayout();
        return false;
    }

    /// Actually remove a column's widgets and data. Called when the close
    /// animation finishes or immediately for the last remaining column.
    fn finishRemoveColumn(self: *Workspace, col_idx: usize) bool {
        // Clear pane history if it points to a pane in this column
        if (self.last_focused_pane_id) |lid| {
            for (self.columns.items[col_idx].groups.items) |grp| {
                if (grp.findPaneById(lid) != null) {
                    self.last_focused_pane_id = null;
                    break;
                }
            }
        }

        // Disconnect signal handlers before removing widgets, because
        // gtk_fixed_remove can finalize child widgets (like tab_view),
        // making later g_signal_handlers_disconnect_matched hit an
        // invalid instance pointer.
        for (self.columns.items[col_idx].groups.items) |grp| {
            grp.disconnectSignals();
        }
        // Remove widgets from GtkFixed and destroy groups
        for (self.columns.items[col_idx].groups.items) |grp| {
            c.gtk_fixed_remove(@ptrCast(self.fixed), grp.getWidget());
            grp.destroy();
        }
        self.columns.items[col_idx].groups.deinit(self.alloc);
        _ = self.columns.orderedRemove(col_idx);

        if (self.columns.items.len == 0) return true;

        // Adjust focused column index after removal.
        // If the removed column was before the focused one, shift the
        // index down so it still points at the same column.
        if (col_idx < self.focused_column) {
            self.focused_column -= 1;
        } else if (self.focused_column >= self.columns.items.len) {
            self.focused_column = self.columns.items.len - 1;
        }

        // Re-clamp the camera so the viewport doesn't point beyond the
        // remaining columns (which would show black space).
        self.clampCamera();

        return false;
    }

    /// Remove the column containing the given group ID. Returns true if workspace is now empty.
    pub fn removeColumnByGroupId(self: *Workspace, group_id: u64) bool {
        for (self.columns.items, 0..) |col, i| {
            for (col.groups.items) |grp| {
                if (grp.id == group_id) {
                    return self.removeColumn(i);
                }
            }
        }
        return false;
    }

    /// Focus the column containing the given pane ID and return the group.
    pub fn focusColumnContainingPane(self: *Workspace, pane_id: u64) ?*PaneGroup {
        for (self.columns.items, 0..) |col, i| {
            for (col.groups.items) |grp| {
                if (grp.findPaneById(pane_id) != null) {
                    self.savePaneFocusHistory();
                    if (self.focusedGroup()) |old| old.unfocus();
                    self.focused_column = i;
                    self.panToFocusedColumn();
                    return grp;
                }
            }
        }
        return null;
    }

    /// Exponential decay rate: 99% of the animation completes in 200ms.
    /// Derived from: k = -ln(0.01) / 0.2 ≈ 23.026
    const anim_decay_rate = 23.026;
    /// Snap threshold — when animation is this close to target, snap to it.
    const anim_snap_threshold = 0.99;

    fn onTick(_: *c.GtkWidget, frame_clock: ?*anyopaque, user_data: c.gpointer) callconv(.c) c.gboolean {
        const self: *Workspace = @ptrCast(@alignCast(user_data));
        var needs_layout = false;

        // Compute delta time from frame clock (microseconds → seconds)
        const now: i64 = c.gdk_frame_clock_get_frame_time(@ptrCast(frame_clock));
        const dt: f64 = if (self.last_frame_time > 0)
            @as(f64, @floatFromInt(now - self.last_frame_time)) / 1_000_000.0
        else
            1.0 / 60.0; // sensible default for first frame
        self.last_frame_time = now;
        const anim_lerp_factor = 1.0 - @exp(-anim_decay_rate * dt);

        // Only update cached viewport size when camera is settled.
        // During camera animation, GtkFixed's children-based minimum
        // size inflates the entire widget tree; re-reading now would
        // feed back into layout and cause exponential growth.
        const camera_settled = @abs(self.camera - self.camera_target) <= 0.0005;
        if (camera_settled or self.cached_width == 0) {
            const w = c.gtk_widget_get_width(self.container);
            const h = c.gtk_widget_get_height(self.container);
            if (w > 0 and h > 0 and (w != self.cached_width or h != self.cached_height)) {
                self.cached_width = w;
                self.cached_height = h;
                needs_layout = true;
            }
        }

        // Advance column animations
        for (self.columns.items) |*col| {
            if (col.closing) {
                col.open_anim *= (1.0 - anim_lerp_factor);
                if (col.open_anim <= 1.0 - anim_snap_threshold) col.open_anim = 0.0;
                needs_layout = true;
            } else if (col.open_anim < 1.0) {
                col.open_anim += (1.0 - col.open_anim) * anim_lerp_factor;
                if (col.open_anim >= anim_snap_threshold) col.open_anim = 1.0;
                needs_layout = true;
            }

            // Animate column width toward target
            {
                const dw = col.target_width - col.width;
                if (@abs(dw) > 0.001) {
                    col.width += dw * anim_lerp_factor;
                    if (@abs(col.target_width - col.width) < 0.002) {
                        col.width = col.target_width;
                    }
                    needs_layout = true;
                }
            }

            // Animate layout mode transition (stacked_anim)
            switch (col.layout_mode) {
                .stacked => {
                    if (col.stacked_anim < 1.0) {
                        col.stacked_anim += (1.0 - col.stacked_anim) * anim_lerp_factor;
                        if (col.stacked_anim >= anim_snap_threshold) col.stacked_anim = 1.0;
                        needs_layout = true;
                    }
                },
                .tabbed => {
                    if (col.stacked_anim > 0.0) {
                        col.stacked_anim *= (1.0 - anim_lerp_factor);
                        if (col.stacked_anim <= 1.0 - anim_snap_threshold) col.stacked_anim = 0.0;
                        needs_layout = true;

                        // When transition completes, reparent panels back to AdwTabView
                        if (col.stacked_anim <= 0.0) {
                            for (col.groups.items) |grp| {
                                grp.exitStackedMode();
                            }
                        }
                    }
                },
            }

            // Animate per-panel stacked_open_anim and layout fractions
            for (col.groups.items) |grp| {
                // Compute total height weight for weight-based distribution
                var total_weight: f64 = 0.0;
                for (grp.panels.items) |p2| {
                    if (p2.asTerminal()) |pp| total_weight += pp.height_weight;
                }
                if (total_weight <= 0.0) total_weight = 1.0;
                var y_accum: f64 = 0.0;

                for (grp.panels.items) |panel| {
                    const pane = panel.asTerminal() orelse continue;
                    if (pane.stacked_closing) {
                        pane.stacked_open_anim *= (1.0 - anim_lerp_factor);
                        if (pane.stacked_open_anim <= 1.0 - anim_snap_threshold) {
                            pane.stacked_open_anim = 0.0;
                        }
                        needs_layout = true;
                    } else if (pane.stacked_open_anim < 1.0) {
                        pane.stacked_open_anim += (1.0 - pane.stacked_open_anim) * anim_lerp_factor;
                        if (pane.stacked_open_anim >= anim_snap_threshold) {
                            pane.stacked_open_anim = 1.0;
                        }
                        needs_layout = true;
                    }

                    // Animate layout position/size fractions toward weight-based target
                    {
                        const target_frac_y = y_accum / total_weight;
                        const target_frac_h = pane.height_weight / total_weight;
                        const dy = target_frac_y - pane.stacked_frac_y;
                        const dh = target_frac_h - pane.stacked_frac_h;
                        if (@abs(dy) > 0.001) {
                            pane.stacked_frac_y += dy * anim_lerp_factor;
                            if (@abs(target_frac_y - pane.stacked_frac_y) < 0.002) {
                                pane.stacked_frac_y = target_frac_y;
                            }
                            needs_layout = true;
                        }
                        if (@abs(dh) > 0.001) {
                            pane.stacked_frac_h += dh * anim_lerp_factor;
                            if (@abs(target_frac_h - pane.stacked_frac_h) < 0.002) {
                                pane.stacked_frac_h = target_frac_h;
                            }
                            needs_layout = true;
                        }
                    }
                    y_accum += pane.height_weight;

                    // Animate horizontal offset toward 0 (cross-column move)
                    if (@abs(pane.stacked_offset_x) > 1.0) {
                        pane.stacked_offset_x *= (1.0 - anim_lerp_factor);
                        if (@abs(pane.stacked_offset_x) < 1.0) {
                            pane.stacked_offset_x = 0.0;
                        }
                        needs_layout = true;
                    }
                }
            }
        }

        // Animate camera panning
        {
            const diff = self.camera_target - self.camera;
            if (@abs(diff) > 0.0005) {
                self.camera += diff * anim_lerp_factor;
                if (@abs(self.camera_target - self.camera) < 0.002) {
                    self.camera = self.camera_target;
                }
                needs_layout = true;
            }
        }

        // Finalize columns whose close animation completed (reverse to keep indices stable)
        {
            var i = self.columns.items.len;
            while (i > 0) {
                i -= 1;
                if (self.columns.items[i].closing and self.columns.items[i].open_anim <= 0.0) {
                    _ = self.finishRemoveColumn(i);
                    needs_layout = true;
                }
            }
            // If all columns were removed, schedule deferred workspace close
            if (self.columns.items.len == 0) {
                _ = c.g_idle_add(@ptrCast(&idleCloseEmptyWorkspace), @ptrFromInt(self.id));
            }
        }

        if (needs_layout) self.applyLayout();
        return 1; // G_SOURCE_CONTINUE
    }

    /// Immediately finalize all closing columns whose open_anim has
    /// reached 0 (or was never > 0).  This prevents "zombie" columns
    /// from accumulating when multiple expels happen between ticks.
    fn flushClosedColumns(self: *Workspace) void {
        var i = self.columns.items.len;
        while (i > 0) {
            i -= 1;
            if (self.columns.items[i].closing and self.columns.items[i].open_anim <= 0.0) {
                _ = self.finishRemoveColumn(i);
            }
        }
    }

    /// Count columns that are not in the process of closing.
    pub fn liveColumnCount(self: *const Workspace) usize {
        var count: usize = 0;
        for (self.columns.items) |col| {
            if (!col.closing) count += 1;
        }
        return count;
    }

    /// Move focus to the nearest live column, preferring right then left.
    fn focusNextLiveColumn(self: *Workspace, from: usize) void {
        // Try right
        var i = from + 1;
        while (i < self.columns.items.len) : (i += 1) {
            if (!self.columns.items[i].closing) {
                self.focused_column = i;
                if (self.focusedGroup()) |grp| grp.focus();
                self.panToFocusedColumn();
                return;
            }
        }
        // Try left
        i = from;
        while (i > 0) {
            i -= 1;
            if (!self.columns.items[i].closing) {
                self.focused_column = i;
                if (self.focusedGroup()) |grp| grp.focus();
                self.panToFocusedColumn();
                return;
            }
        }
    }

    /// Compute the normalized x position of a column's left edge.
    fn columnLeft(self: *const Workspace, col_idx: usize) f64 {
        var x: f64 = 0.0;
        for (self.columns.items[0..col_idx]) |col| {
            x += col.width;
        }
        return x;
    }

    /// Clamp camera_target to the valid range [0, total_width - 1].
    /// camera itself is NOT clamped so it can animate smoothly toward
    /// camera_target (e.g. when the strip shrinks after closing a column).
    fn clampCamera(self: *Workspace) void {
        // Use settled widths (target_width for live columns, skip closing
        // columns) so the camera can pan to the final position immediately
        // while the close animation is still playing.
        var total: f64 = 0.0;
        for (self.columns.items) |col| {
            if (!col.closing) total += col.target_width;
        }
        const max_cam = @max(0.0, total - 1.0);
        self.camera_target = std.math.clamp(self.camera_target, 0.0, max_cam);
    }

    /// Set camera_target so the focused column is fully visible.
    /// Uses settled (target) widths so the camera doesn't overshoot
    /// when animated widths are temporarily inflated (e.g. solo-expand).
    fn panToFocusedColumn(self: *Workspace) void {
        if (self.columns.items.len == 0) return;
        if (self.focused_column >= self.columns.items.len) return;

        const col = &self.columns.items[self.focused_column];
        // Compute where the column will be once animations settle:
        // closing columns vanish, live columns reach target_width.
        var left: f64 = 0.0;
        for (self.columns.items[0..self.focused_column]) |prev| {
            if (!prev.closing) left += prev.target_width;
        }
        const right = left + col.target_width;

        if (right > self.camera_target + 1.0) {
            self.camera_target = right - 1.0;
        }
        if (left < self.camera_target) {
            self.camera_target = left;
        }

        self.clampCamera();
    }

    /// Adjust the focused column's width by `delta` (fraction of viewport).
    pub fn resizeColumnWidth(self: *Workspace, delta: f64) void {
        if (self.columns.items.len == 0) return;
        if (self.focused_column >= self.columns.items.len) return;
        const col = &self.columns.items[self.focused_column];
        if (col.closing) return;
        // If column was maximized, clear the saved width so next maximize re-maximizes
        if (col.pre_maximize_width > 0.0) col.pre_maximize_width = 0.0;
        col.target_width = std.math.clamp(col.target_width + delta, Column.min_width, Column.max_width);
        self.panToFocusedColumn();
    }

    /// Toggle maximize: set focused column to full width, or restore previous width.
    pub fn maximizeColumn(self: *Workspace) void {
        if (self.columns.items.len == 0) return;
        if (self.focused_column >= self.columns.items.len) return;
        const col = &self.columns.items[self.focused_column];
        if (col.closing) return;
        if (col.target_width >= Column.max_width - 0.01 and col.pre_maximize_width > 0.0) {
            // Restore previous width
            col.target_width = col.pre_maximize_width;
            col.pre_maximize_width = 0.0;
        } else {
            // Maximize
            col.pre_maximize_width = col.target_width;
            col.target_width = Column.max_width;
        }
        self.panToFocusedColumn();
    }

    /// Cycle focused column width through preset proportions: 1/3 → 1/2 → 2/3.
    pub fn switchPresetColumnWidth(self: *Workspace) void {
        if (self.columns.items.len == 0) return;
        if (self.focused_column >= self.columns.items.len) return;
        const col = &self.columns.items[self.focused_column];
        if (col.closing) return;

        const presets = [_]f64{ 1.0 / 3.0, 1.0 / 2.0, 2.0 / 3.0 };
        const tolerance = 0.02;

        // Find current preset index (if any)
        var current_idx: ?usize = null;
        for (presets, 0..) |p, i| {
            if (@abs(col.target_width - p) < tolerance) {
                current_idx = i;
                break;
            }
        }

        // Cycle to next preset, or start at first
        const next_idx = if (current_idx) |idx| (idx + 1) % presets.len else 0;
        col.target_width = presets[next_idx];
        if (col.pre_maximize_width > 0.0) col.pre_maximize_width = 0.0;
        self.panToFocusedColumn();
    }

    /// Adjust the focused pane's height weight by `delta`.
    pub fn resizeRowHeight(self: *Workspace, delta: f64) void {
        const grp = self.focusedGroup() orelse return;
        if (grp.active_panel >= grp.panels.items.len) return;
        const pane = grp.panels.items[grp.active_panel].asTerminal() orelse return;
        pane.height_weight = std.math.clamp(pane.height_weight + delta, 0.1, 10.0);
    }

    // ── Resize handles ──────────────────────────────────────────────

    fn initResizeHandles(self: *Workspace) void {
        for (0..max_col_handles) |i| {
            self.col_handles[i] = .{ .widget = createHandle(self, "col-resize") };
        }
        for (0..max_row_handles) |i| {
            self.row_handles[i] = .{ .widget = createHandle(self, "row-resize") };
        }
    }

    fn createHandle(self: *Workspace, cursor_name: [*:0]const u8) *c.GtkWidget {
        const widget = c.gtk_drawing_area_new();
        c.gtk_widget_set_can_focus(widget, 0);
        c.gtk_widget_set_cursor_from_name(widget, cursor_name);
        c.gtk_widget_add_css_class(widget, "resize-handle");
        c.gtk_widget_set_visible(widget, 0);

        const drag = c.gtk_gesture_drag_new();
        c.gtk_gesture_single_set_button(@ptrCast(drag), 1);
        _ = c.g_signal_connect_data(
            @as(c.gpointer, @ptrCast(drag)),
            "drag-begin",
            @as(c.GCallback, @ptrCast(&onResizeDragBegin)),
            @ptrCast(self),
            null,
            0,
        );
        _ = c.g_signal_connect_data(
            @as(c.gpointer, @ptrCast(drag)),
            "drag-update",
            @as(c.GCallback, @ptrCast(&onResizeDragUpdate)),
            @ptrCast(self),
            null,
            0,
        );
        _ = c.g_signal_connect_data(
            @as(c.gpointer, @ptrCast(drag)),
            "drag-end",
            @as(c.GCallback, @ptrCast(&onResizeDragEnd)),
            @ptrCast(self),
            null,
            0,
        );
        c.gtk_widget_add_controller(widget, @ptrCast(drag));
        c.gtk_fixed_put(@ptrCast(self.fixed), widget, 0, 0);
        return widget;
    }

    /// Position resize handles at column/row dividers. Called at the end of applyLayout().
    fn positionResizeHandles(self: *Workspace) void {
        // Skip repositioning during an active drag — moving the handle widget
        // under the cursor shifts GtkGestureDrag's coordinate origin, causing
        // the reported offset to shrink and the handle to lag/flicker.
        if (self.resize_drag_kind != .none) return;
        if (self.cached_width <= 0 or self.cached_height <= 0) return;
        const fw: f64 = @floatFromInt(self.cached_width);
        const fh: f64 = @floatFromInt(self.cached_height);

        var col_h: usize = 0; // next column handle to assign
        var row_h: usize = 0; // next row handle to assign

        // Recompute column positions (mirrors applyLayout main loop)
        var live_count: usize = 0;
        var total_closing_slots: f64 = 0.0;
        for (self.columns.items) |col2| {
            if (col2.closing) {
                total_closing_slots += col2.width * col2.open_anim;
            } else {
                live_count += 1;
            }
        }
        const solo_expand = live_count == 1;

        const cam_px = @round(self.camera * fw);
        var x: f64 = 0.0;
        for (self.columns.items, 0..) |col, col_idx| {
            const effective_w = if (solo_expand and !col.closing)
                @max(col.width, 1.0 - total_closing_slots)
            else
                col.width;

            const pos_px = @round(x * fw);
            const screen_x = pos_px - cam_px;
            const pixel_w = @round((x + effective_w) * fw) - pos_px;

            // Column handle: between col_idx-1 and col_idx
            if (col_idx > 0 and !col.closing and col_h < max_col_handles) {
                const prev_col = &self.columns.items[col_idx - 1];
                const both_settled = col.open_anim >= 0.99 and !prev_col.closing and prev_col.open_anim >= 0.99;
                if (both_settled) {
                    const h = &self.col_handles[col_h];
                    h.col_idx = col_idx;
                    c.gtk_widget_set_size_request(h.widget, handle_thickness, @intFromFloat(@max(1.0, @round(fh))));
                    c.gtk_fixed_move(@ptrCast(self.fixed), h.widget, screen_x - 5.0, 0);
                    c.gtk_widget_set_visible(h.widget, 1);
                    col_h += 1;
                }
            }

            // Row handles: only in fully-stacked mode with multiple panes
            if (!col.closing and col.open_anim >= 0.99 and col.stacked_anim >= 0.99) {
                for (col.groups.items) |grp| {
                    if (!grp.in_stacked_mode) continue;
                    if (grp.panels.items.len <= 1) continue;

                    const tab_area_h = col.measured_tab_bar_height * (1.0 - col.stacked_anim);
                    const available_h = fh - tab_area_h;

                    for (grp.panels.items, 0..) |panel, i| {
                        if (i == 0) continue; // no divider above the first pane
                        const pane = panel.asTerminal() orelse continue;
                        if (pane.stacked_closing or pane.stacked_open_anim < 0.99) continue;
                        // Also check the pane above
                        const above = grp.panels.items[i - 1].asTerminal() orelse continue;
                        if (above.stacked_closing or above.stacked_open_anim < 0.99) continue;
                        if (row_h >= max_row_handles) break;

                        const rh = &self.row_handles[row_h];
                        rh.col_idx = col_idx;
                        rh.pane_idx = i;
                        const handle_y = tab_area_h + pane.stacked_frac_y * available_h - 5.0;
                        c.gtk_widget_set_size_request(rh.widget, @intFromFloat(@max(1.0, @round(pixel_w))), handle_thickness);
                        c.gtk_fixed_move(@ptrCast(self.fixed), rh.widget, screen_x, handle_y);
                        c.gtk_widget_set_visible(rh.widget, 1);
                        row_h += 1;
                    }
                }
            }

            x += if (col.closing) col.width * col.open_anim else effective_w * col.open_anim;
        }

        // Hide unused handles
        for (col_h..max_col_handles) |i| {
            c.gtk_widget_set_visible(self.col_handles[i].widget, 0);
        }
        for (row_h..max_row_handles) |i| {
            c.gtk_widget_set_visible(self.row_handles[i].widget, 0);
        }

        // Raise active handles to top of z-order
        for (0..col_h) |i| {
            c.gtk_widget_insert_before(self.col_handles[i].widget, @ptrCast(self.fixed), null);
        }
        for (0..row_h) |i| {
            c.gtk_widget_insert_before(self.row_handles[i].widget, @ptrCast(self.fixed), null);
        }
    }

    fn onResizeDragBegin(gesture: *c.GtkGestureDrag, _: f64, _: f64, user_data: c.gpointer) callconv(.c) void {
        const self: *Workspace = @ptrCast(@alignCast(user_data));
        const widget = c.gtk_event_controller_get_widget(@ptrCast(gesture));

        // Find which column handle was dragged
        for (self.col_handles[0..max_col_handles]) |h| {
            if (@as(*c.GtkWidget, @ptrCast(h.widget)) == widget) {
                if (h.col_idx == 0 or h.col_idx >= self.columns.items.len) return;
                self.resize_drag_kind = .column;
                self.resize_drag_col = h.col_idx;
                self.resize_drag_start_a = self.columns.items[h.col_idx - 1].target_width;
                self.resize_drag_start_b = self.columns.items[h.col_idx].target_width;
                return;
            }
        }
        // Find which row handle was dragged
        for (self.row_handles[0..max_row_handles]) |h| {
            if (@as(*c.GtkWidget, @ptrCast(h.widget)) == widget) {
                if (h.col_idx >= self.columns.items.len) return;
                const col = &self.columns.items[h.col_idx];
                if (col.groups.items.len == 0) return;
                const grp = col.groups.items[0];
                if (h.pane_idx == 0 or h.pane_idx >= grp.panels.items.len) return;
                const above = grp.panels.items[h.pane_idx - 1].asTerminal() orelse return;
                const below = grp.panels.items[h.pane_idx].asTerminal() orelse return;
                self.resize_drag_kind = .row;
                self.resize_drag_col = h.col_idx;
                self.resize_drag_pane = h.pane_idx;
                self.resize_drag_start_a = above.height_weight;
                self.resize_drag_start_b = below.height_weight;
                return;
            }
        }
    }

    fn onResizeDragUpdate(gesture: *c.GtkGestureDrag, offset_x: f64, offset_y: f64, user_data: c.gpointer) callconv(.c) void {
        _ = gesture;
        const self: *Workspace = @ptrCast(@alignCast(user_data));
        switch (self.resize_drag_kind) {
            .none => return,
            .column => {
                const fw: f64 = @floatFromInt(self.cached_width);
                if (fw <= 0) return;
                if (self.resize_drag_col == 0 or self.resize_drag_col >= self.columns.items.len) return;

                const left = &self.columns.items[self.resize_drag_col - 1];
                const right = &self.columns.items[self.resize_drag_col];
                const delta_frac = offset_x / fw;
                const sum = self.resize_drag_start_a + self.resize_drag_start_b;
                const new_left = std.math.clamp(
                    self.resize_drag_start_a + delta_frac,
                    Column.min_width,
                    sum - Column.min_width,
                );
                const new_right = sum - new_left;

                left.width = new_left;
                left.target_width = new_left;
                left.pre_maximize_width = 0; // manual resize clears maximize state
                right.width = new_right;
                right.target_width = new_right;
                right.pre_maximize_width = 0;
            },
            .row => {
                const fh: f64 = @floatFromInt(self.cached_height);
                if (fh <= 0) return;
                if (self.resize_drag_col >= self.columns.items.len) return;
                const col = &self.columns.items[self.resize_drag_col];
                if (col.groups.items.len == 0) return;
                const grp = col.groups.items[0];
                if (self.resize_drag_pane == 0 or self.resize_drag_pane >= grp.panels.items.len) return;
                const pane_above = grp.panels.items[self.resize_drag_pane - 1].asTerminal() orelse return;
                const pane_below = grp.panels.items[self.resize_drag_pane].asTerminal() orelse return;

                // Compute total weight for pixel-to-weight conversion
                var total_weight: f64 = 0;
                for (grp.panels.items) |p| {
                    if (p.asTerminal()) |pp| total_weight += pp.height_weight;
                }
                if (total_weight <= 0) total_weight = 1.0;

                const tab_area_h = col.measured_tab_bar_height * (1.0 - col.stacked_anim);
                const available_h = fh - tab_area_h;
                if (available_h <= 0) return;
                const delta_weight = (offset_y / available_h) * total_weight;
                const sum = self.resize_drag_start_a + self.resize_drag_start_b;
                const new_above = std.math.clamp(self.resize_drag_start_a + delta_weight, 0.1, sum - 0.1);
                const new_below = sum - new_above;

                pane_above.height_weight = new_above;
                pane_below.height_weight = new_below;

                // Directly update layout fractions for instant feedback
                var y_accum: f64 = 0;
                for (grp.panels.items) |p| {
                    if (p.asTerminal()) |pp| {
                        pp.stacked_frac_y = y_accum / total_weight;
                        pp.stacked_frac_h = pp.height_weight / total_weight;
                        y_accum += pp.height_weight;
                    }
                }
            },
        }
        self.applyLayout();
    }

    fn onResizeDragEnd(_: *c.GtkGestureDrag, _: f64, _: f64, user_data: c.gpointer) callconv(.c) void {
        const self: *Workspace = @ptrCast(@alignCast(user_data));
        self.resize_drag_kind = .none;
        self.positionResizeHandles();
    }

    fn idleCloseEmptyWorkspace(user_data: c.gpointer) callconv(.c) c.gboolean {
        const ws_id: u64 = @intFromPtr(user_data);
        const Window = @import("window.zig");
        const wm = Window.window_manager orelse return 0;
        for (wm.windows.items) |state| {
            for (state.workspaces.items, 0..) |ws, ws_idx| {
                if (ws.id == ws_id and ws.columns.items.len == 0) {
                    state.closeWorkspace(ws_idx);
                    return 0;
                }
            }
        }
        return 0; // G_SOURCE_REMOVE
    }

    // ── Metadata forwarding methods ─────────────────────────────────

    pub fn setStatus(self: *Workspace, key: []const u8, value: []const u8, priority: i32, is_agent: bool, display_name: ?[]const u8) void {
        self.metadata.setStatus(key, value, priority, is_agent, display_name);
    }

    pub fn clearStatus(self: *Workspace, key: []const u8) bool {
        return self.metadata.clearStatus(key);
    }

    pub fn appendLog(self: *Workspace, message: []const u8, level: LogLevel, timestamp: i64) void {
        self.metadata.appendLog(message, level, timestamp);
    }

    pub fn clearLog(self: *Workspace) void {
        self.metadata.clearLog();
    }

    pub fn getRecentLogs(self: *const Workspace, out: []LogEntry) usize {
        return self.metadata.getRecentLogs(out);
    }

    pub fn setProgress(self: *Workspace, value: f64, label: ?[]const u8) void {
        self.metadata.setProgress(value, label);
    }

    pub fn clearProgress(self: *Workspace) void {
        self.metadata.clearProgress();
    }

    pub fn getSortedStatusIndices(self: *const Workspace, out: []usize) usize {
        return self.metadata.getSortedStatusIndices(out);
    }

    /// Disconnect all signal handlers. Must be called while
    /// the widget tree is still alive (before gtk_stack_remove).
    pub fn disconnectSignals(self: *Workspace) void {
        for (self.columns.items) |col| {
            for (col.groups.items) |grp| {
                grp.disconnectSignals();
            }
        }
    }

    pub fn destroy(self: *Workspace) void {
        // Remove tick callback before destroying widgets
        if (self.tick_callback_id != 0) {
            c.gtk_widget_remove_tick_callback(self.fixed, self.tick_callback_id);
            self.tick_callback_id = 0;
        }
        // Detach resize handles so their gesture callbacks can't fire during teardown
        for (self.col_handles[0..max_col_handles]) |h| {
            c.gtk_fixed_remove(@ptrCast(self.fixed), h.widget);
        }
        for (self.row_handles[0..max_row_handles]) |h| {
            c.gtk_fixed_remove(@ptrCast(self.fixed), h.widget);
        }
        for (self.columns.items) |*col| {
            for (col.groups.items) |grp| {
                grp.destroy();
            }
            col.groups.deinit(self.alloc);
        }
        self.columns.deinit(self.alloc);
        self.alloc.destroy(self);
    }

    pub fn setTitle(self: *Workspace, title: []const u8) void {
        const len = @min(title.len, self.title.len);
        @memcpy(self.title[0..len], title[0..len]);
        self.title_len = len;
    }

    pub fn getTitle(self: *const Workspace) []const u8 {
        return self.title[0..self.title_len];
    }

    pub fn setAutoTitle(self: *Workspace, title: []const u8) void {
        if (!self.title_is_custom) self.setTitle(title);
    }

    pub fn setCustomTitle(self: *Workspace, title: []const u8) void {
        self.setTitle(title);
        self.title_is_custom = true;
    }

    pub fn clearCustomTitle(self: *Workspace) void {
        self.title_is_custom = false;
    }

    pub fn setCustomColor(self: *Workspace, hex: []const u8) void {
        const len = @min(hex.len, self.custom_color.len);
        @memcpy(self.custom_color[0..len], hex[0..len]);
        self.custom_color_len = len;
    }

    pub fn getCustomColor(self: *const Workspace) ?[]const u8 {
        if (self.custom_color_len == 0) return null;
        return self.custom_color[0..self.custom_color_len];
    }

    pub fn clearCustomColor(self: *Workspace) void {
        self.custom_color_len = 0;
    }

    pub fn basenameFromPath(path: []const u8) []const u8 {
        const trimmed = std.mem.trimRight(u8, path, "/");
        if (trimmed.len == 0) return "Terminal";
        if (std.mem.lastIndexOfScalar(u8, trimmed, '/')) |pos| {
            return trimmed[pos + 1 ..];
        }
        return trimmed;
    }

    pub fn getActivePaneCwd(self: *Workspace) ?[]const u8 {
        const group = self.focusedGroup() orelse return null;
        const pane = group.focusedTerminalPane() orelse return null;
        return pane.getCwd();
    }

    pub fn getGitBranch(self: *const Workspace) ?[]const u8 {
        if (self.git_branch_len == 0) return null;
        return self.git_branch[0..self.git_branch_len];
    }

    pub fn getActivePorts(self: *const Workspace) []const u16 {
        return self.ports[0..self.ports_len];
    }

    pub fn togglePin(self: *Workspace) void {
        self.is_pinned = !self.is_pinned;
    }

    // ── Layout mode toggle ───────────────────────────────────────────

    /// Toggle the focused column between stacked and tabbed layout modes.
    pub fn toggleFocusedColumnLayout(self: *Workspace) void {
        if (self.columns.items.len == 0) return;
        if (self.focused_column >= self.columns.items.len) return;
        const col = &self.columns.items[self.focused_column];
        if (col.closing) return;
        if (col.groups.items.len == 0) return;
        const grp = col.groups.items[0];

        // Don't toggle while already transitioning
        if (col.isModeTransitioning()) return;

        // Suppress focus events during reparenting
        self.restructuring = true;
        defer self.restructuring = false;

        col.active_at_switch = grp.active_panel;

        switch (col.layout_mode) {
            .tabbed => {
                // Measure tab bar + separator height before removing tabs.
                // Use container height minus tab_view height for exact value.
                const container_h = c.gtk_widget_get_height(grp.getWidget());
                const tv_h = c.gtk_widget_get_height(@as(*c.GtkWidget, @ptrCast(@alignCast(grp.tab_view))));
                if (container_h > 0 and tv_h > 0 and container_h > tv_h) {
                    col.measured_tab_bar_height = @floatFromInt(container_h - tv_h);
                }

                // Tabbed → Stacked
                col.layout_mode = .stacked;
                col.stacked_anim = 0.0; // animate from 0 → 1

                // Move panels from AdwTabView to GtkFixed
                grp.enterStackedMode(self.fixed);

                // Active panel starts fully visible, others animate in
                for (grp.panels.items, 0..) |panel, i| {
                    if (panel.asTerminal()) |pane| {
                        if (i == col.active_at_switch) {
                            pane.stacked_open_anim = 1.0;
                            pane.stacked_closing = false;
                        } else {
                            pane.stacked_open_anim = 0.0;
                            pane.stacked_closing = false;
                        }
                    }
                }
            },
            .stacked => {
                // Stacked → Tabbed
                col.layout_mode = .tabbed;
                col.stacked_anim = 1.0; // animate from 1 → 0

                // Active panel stays visible, others animate out
                for (grp.panels.items, 0..) |panel, i| {
                    if (panel.asTerminal()) |pane| {
                        if (i == grp.active_panel) {
                            col.active_at_switch = i;
                            pane.stacked_open_anim = 1.0;
                            pane.stacked_closing = false;
                        } else {
                            pane.stacked_open_anim = 1.0;
                            pane.stacked_closing = true;
                        }
                    }
                }
                // Note: exitStackedMode is called when stacked_anim reaches 0
                // (handled in onTick)
            },
        }

        self.applyLayout();
    }

    // ── Pane operations ─────────────────────────────────────────────

    /// Add a new terminal pane in a new column.
    pub fn splitFocused(self: *Workspace) !void {
        self.restructuring = true;
        defer self.restructuring = false;

        if (self.focusedGroup()) |old_grp| old_grp.unfocus();
        const grp = try self.addColumn(null);
        grp.focus();
    }

    /// Move the focused column one position left or right by swapping
    /// with its neighbor.  Both columns animate from their old screen
    /// positions to the new ones via stacked_offset_x.
    pub fn moveColumn(self: *Workspace, direction: ExpelDirection) void {
        if (self.columns.items.len < 2) return;
        if (self.focused_column >= self.columns.items.len) return;

        const src = self.focused_column;
        const dst: usize = switch (direction) {
            .left => if (src == 0) return else src - 1,
            .right => if (src + 1 >= self.columns.items.len) return else src + 1,
        };

        // Skip closing columns
        if (self.columns.items[src].closing or self.columns.items[dst].closing) return;

        // Save old screen positions for animation
        const fw: f64 = @floatFromInt(self.cached_width);
        const old_src_screen_x = (self.columnLeft(src) - self.camera) * fw;
        const old_dst_screen_x = (self.columnLeft(dst) - self.camera) * fw;

        // Swap the two columns in the array
        const tmp = self.columns.items[src];
        self.columns.items[src] = self.columns.items[dst];
        self.columns.items[dst] = tmp;

        self.focused_column = dst;
        self.panToFocusedColumn();
        self.applyLayout();

        // Set animation offsets so panes slide from old to new position.
        // After the swap, the old src column is now at index dst and vice versa.
        const new_src_screen_x = (self.columnLeft(src) - self.camera_target) * fw;
        const new_dst_screen_x = (self.columnLeft(dst) - self.camera_target) * fw;

        // Column that was at src is now at dst (the focused/moved column)
        for (self.columns.items[dst].groups.items) |grp| {
            for (grp.panels.items) |p| {
                if (p.asTerminal()) |t| {
                    t.stacked_offset_x = old_src_screen_x - new_dst_screen_x;
                }
            }
        }
        // Column that was at dst is now at src (the neighbor)
        for (self.columns.items[src].groups.items) |grp| {
            for (grp.panels.items) |p| {
                if (p.asTerminal()) |t| {
                    t.stacked_offset_x = old_dst_screen_x - new_src_screen_x;
                }
            }
        }
    }

    pub const ExpelDirection = enum { left, right };

    /// Expel the focused pane from its column into the adjacent column
    /// in the given direction. Creates a new column if none exists and
    /// the source column has multiple panels; no-op if source has a
    /// single panel with nowhere to go.
    pub fn expelPane(self: *Workspace, direction: ExpelDirection) void {
        if (self.columns.items.len == 0) return;
        if (self.restructuring) return;

        // Flush any zombie columns (closing with open_anim ≤ 0) so the
        // column array is clean before we manipulate it.  Without this,
        // rapid expels between ticks accumulate stale columns whose
        // groups have already been destroyed.
        self.flushClosedColumns();

        if (self.focused_column >= self.columns.items.len) return;

        const src_col_idx = self.focused_column;
        const src_col = &self.columns.items[src_col_idx];
        if (src_col.closing) return;
        if (src_col.groups.items.len == 0) return;

        const src_grp = src_col.groups.items[0];
        const panel_count = src_grp.panels.items.len;
        if (panel_count == 0) return;

        // Find target column (first non-closing in the given direction)
        const target_col_idx: ?usize = switch (direction) {
            .left => blk: {
                var i = src_col_idx;
                while (i > 0) {
                    i -= 1;
                    if (!self.columns.items[i].closing) break :blk i;
                }
                break :blk null;
            },
            .right => blk: {
                var i = src_col_idx + 1;
                while (i < self.columns.items.len) : (i += 1) {
                    if (!self.columns.items[i].closing) break :blk i;
                }
                break :blk null;
            },
        };

        // Single panel + no target → no-op
        if (panel_count == 1 and target_col_idx == null) return;

        // --- Fast path: tabbed → tabbed via direct AdwTabView transfer ---
        // Going through a dummy AdwTabView and GtkFixed (the slow path
        // below) reparents the GtkGLArea three+ times, and the deferred
        // page disposal of the dummy can later unparent the widget from
        // its new home in the target tab view.  Result: black terminal
        // and a broken focus chain.  When both ends are tabbed, hand off
        // the page directly so libadwaita keeps a single owning parent.
        if (target_col_idx) |tgt_idx_fast| {
            const tgt_grp_fast = self.columns.items[tgt_idx_fast].groups.items[0];
            if (!src_grp.in_stacked_mode and !tgt_grp_fast.in_stacked_mode) {
                const active_idx_fast = src_grp.active_panel;
                if (active_idx_fast < src_grp.panels.items.len) {
                    const pw_fast = src_grp.panels.items[active_idx_fast].getWidget();
                    const page_fast = c.adw_tab_view_get_page(src_grp.tab_view, pw_fast);
                    if (page_fast != null) {
                        self.restructuring = true;
                        src_grp.panels.items[active_idx_fast].unfocus();

                        const insert_pos_fast = tgt_grp_fast.panels.items.len;

                        // Suppress src's notify::selected-page (would
                        // re-focus a sibling tab) and tgt's (we'll
                        // explicitly select + focus below).  The
                        // transferring branch in onPageDetached and the
                        // pending_transfer_panel branch in onPageAttached
                        // both run regardless of programmatic_close, so
                        // panel-list bookkeeping happens automatically.
                        src_grp.programmatic_close = true;
                        tgt_grp_fast.programmatic_close = true;
                        c.adw_tab_view_transfer_page(
                            src_grp.tab_view,
                            page_fast,
                            tgt_grp_fast.tab_view,
                            @intCast(insert_pos_fast),
                        );
                        src_grp.programmatic_close = false;

                        // Select the freshly inserted page in target.
                        const new_page_fast = c.adw_tab_view_get_nth_page(
                            tgt_grp_fast.tab_view,
                            @intCast(insert_pos_fast),
                        );
                        if (new_page_fast != null) {
                            c.adw_tab_view_set_selected_page(tgt_grp_fast.tab_view, new_page_fast);
                        }
                        tgt_grp_fast.programmatic_close = false;

                        tgt_grp_fast.active_panel = insert_pos_fast;
                        self.focused_column = tgt_idx_fast;

                        // Empty source column → start close animation.
                        // onPageDetached also queues idleCloseEmptyGroup,
                        // but removeColumn is idempotent on already-closing
                        // columns so the duplicate request is a no-op.
                        if (src_grp.panels.items.len == 0) {
                            self.columns.items[src_col_idx].closing = true;
                        }

                        self.panToFocusedColumn();
                        self.applyLayout();
                        self.restructuring = false;
                        if (self.focusedGroup()) |grp| grp.focus();
                        return;
                    }
                }
            }
        }

        // --- Save old position for animation ---
        const fw: f64 = @floatFromInt(self.cached_width);
        const old_col_left = self.columnLeft(src_col_idx);
        const old_screen_x = (old_col_left - self.camera) * fw;
        const active_idx = src_grp.active_panel;
        const pane = src_grp.panels.items[active_idx].asTerminal().?;
        // In tabbed mode the active panel fills the column, so use
        // full-height fractions for animation instead of stale stacked values.
        const old_frac_y: f64 = if (src_grp.in_stacked_mode) pane.stacked_frac_y else 0.0;
        const old_frac_h: f64 = if (src_grp.in_stacked_mode) pane.stacked_frac_h else 1.0;

        // --- Suppress focus events during restructuring ---
        self.restructuring = true;
        defer self.restructuring = false;
        src_grp.unfocus();

        // --- Detach the panel from source group ---
        // In stacked mode, panels are direct children of GtkFixed — move
        // between groups' panel lists without widget tree changes (avoids
        // unrealize → realize cycles that destroy GtkGLArea's GL context).
        // In tabbed mode, detach the active page and reparent onto GtkFixed.
        const src_tabbed = !src_grp.in_stacked_mode;
        src_grp.panels.items[active_idx].unfocus();
        const panel = src_grp.panels.orderedRemove(active_idx);
        if (src_tabbed) {
            const pw = panel.getWidget();
            const page = c.adw_tab_view_get_page(src_grp.tab_view, pw);
            if (page == null) {
                // Widget not in tab view — inconsistent state; put panel back.
                src_grp.panels.insert(src_grp.alloc, active_idx, panel) catch {};
                return;
            }

            // One ref for the transfer/unparent cycle, one extra to
            // survive the deferred page dispose that may later unparent
            // the widget from GtkFixed (released by layoutStackedGroup
            // if the target is stacked, or explicitly below if tabbed).
            _ = c.g_object_ref(@ptrCast(pw));
            _ = c.g_object_ref(@ptrCast(pw));

            const dummy_tv = c.adw_tab_view_new() orelse unreachable;
            _ = c.g_object_ref_sink(@ptrCast(dummy_tv));

            src_grp.programmatic_close = true;
            c.adw_tab_view_transfer_page(src_grp.tab_view, page, dummy_tv, 0);
            src_grp.programmatic_close = false;

            if (c.gtk_widget_get_parent(pw) != null) {
                c.gtk_widget_unparent(pw);
            }
            c.g_object_unref(@ptrCast(dummy_tv));

            c.gtk_fixed_put(@ptrCast(self.fixed), pw, 0, 0);
            _ = c.g_object_unref(@ptrCast(pw));
        }
        if (src_grp.panels.items.len == 0) {
            src_grp.active_panel = 0;
        } else if (src_grp.active_panel >= src_grp.panels.items.len) {
            src_grp.active_panel = src_grp.panels.items.len - 1;
        }

        const src_now_empty = src_grp.panels.items.len == 0;

        if (target_col_idx) |tgt_idx_raw| {
            // --- Target column exists ---

            const tgt_grp = self.columns.items[tgt_idx_raw].groups.items[0];
            const insert_pos = tgt_grp.panels.items.len;

            const tgt_tabbed = !tgt_grp.in_stacked_mode;

            // Insert into target group's list (no widget tree change)
            pane.pane_group_id = tgt_grp.id;
            pane.workspace_id = tgt_grp.workspace_id;
            tgt_grp.panels.insert(tgt_grp.alloc, insert_pos, panel) catch {
                // Failed — put it back in source
                src_grp.panels.insert(src_grp.alloc, active_idx, panel) catch {};
                pane.pane_group_id = src_grp.id;
                pane.workspace_id = src_grp.workspace_id;
                if (src_tabbed) {
                    // Move widget back from GtkFixed into source tab view.
                    const pw = panel.getWidget();
                    _ = c.g_object_ref(@ptrCast(pw));
                    c.gtk_fixed_remove(@ptrCast(self.fixed), pw);
                    _ = c.adw_tab_view_insert(src_grp.tab_view, pw, @intCast(active_idx));
                    // Release both extra refs (no deferred dispose to survive).
                    _ = c.g_object_unref(@ptrCast(pw));
                    _ = c.g_object_unref(@ptrCast(pw));
                }
                return;
            };

            // Reparent into tabbed target (widget is on GtkFixed from
            // either stacked source or the tabbed detach above).
            if (tgt_tabbed) {
                const pw = panel.getWidget();
                _ = c.g_object_ref(@ptrCast(pw));
                c.gtk_fixed_remove(@ptrCast(self.fixed), pw);
                const tab_page = c.adw_tab_view_insert(tgt_grp.tab_view, pw, @intCast(insert_pos));
                const title = if (pane.getDisplayTitle()) |t| t else "Terminal";
                var buf: [65:0]u8 = [_:0]u8{0} ** 65;
                var tlen = @min(title.len, 64);
                // Avoid splitting a multi-byte UTF-8 codepoint.
                while (tlen > 0 and (title[tlen - 1] & 0xC0) == 0x80) tlen -= 1;
                if (tlen > 0 and title[tlen - 1] >= 0xC0) tlen -= 1;
                @memcpy(buf[0..tlen], title[0..tlen]);
                c.adw_tab_page_set_title(tab_page, &buf);
                c.adw_tab_view_set_selected_page(tgt_grp.tab_view, tab_page);
                _ = c.g_object_unref(@ptrCast(pw));
                // Widget is now in AdwTabView, not GtkFixed — release
                // the extra ref meant for layoutStackedGroup recovery.
                if (src_tabbed) {
                    _ = c.g_object_unref(@ptrCast(pw));
                }
            }

            // If the source column is now empty, animate it closed so
            // neighbouring columns slide smoothly instead of teleporting.
            const tgt_idx = tgt_idx_raw;
            if (src_now_empty) {
                self.columns.items[src_col_idx].closing = true;
            }

            // Animation: horizontal slide from old position (stacked
            // layout only — tabbed targets manage their own display).
            if (!tgt_tabbed) {
                const tgt_col_left = self.columnLeft(tgt_idx);
                const new_screen_x = (tgt_col_left - self.camera) * fw;
                pane.stacked_offset_x = old_screen_x - new_screen_x;
                pane.stacked_frac_y = old_frac_y;
                pane.stacked_frac_h = old_frac_h;
                pane.stacked_open_anim = 1.0;
                pane.stacked_closing = false;
            }

            self.focused_column = tgt_idx;
            tgt_grp.active_panel = insert_pos;
        } else {
            // --- No target: create new column with the panel ---
            const insert_at: usize = switch (direction) {
                .left => src_col_idx,
                .right => src_col_idx + 1,
            };

            const new_grp = self.insertColumnWithPanel(panel, insert_at) catch {
                // Failed — re-insert panel back into source
                src_grp.panels.insert(src_grp.alloc, active_idx, panel) catch {};
                pane.pane_group_id = src_grp.id;
                pane.workspace_id = src_grp.workspace_id;
                src_grp.focus();
                return;
            };

            // Skip the column fade/scale-in animation — the expelled pane
            // should slide visibly from its old position, not materialize.
            self.columns.items[insert_at].open_anim = 1.0;

            // Columns after insert_at shifted right by the new column's
            // width.  Give their panes a compensating offset so they
            // animate from their old screen position instead of snapping.
            {
                const shift_px = self.columns.items[insert_at].width * fw;
                var ci = insert_at + 1;
                while (ci < self.columns.items.len) : (ci += 1) {
                    for (self.columns.items[ci].groups.items) |grp2| {
                        for (grp2.panels.items) |p2| {
                            if (p2.asTerminal()) |t| {
                                t.stacked_offset_x -= shift_px;
                            }
                        }
                    }
                }
            }

            // Animation: horizontal slide from old position
            const new_col_left = self.columnLeft(insert_at);
            const new_screen_x = (new_col_left - self.camera) * fw;
            pane.stacked_offset_x = old_screen_x - new_screen_x;
            pane.stacked_frac_y = old_frac_y;
            pane.stacked_frac_h = old_frac_h;
            pane.stacked_open_anim = 1.0;
            pane.stacked_closing = false;

            // Set new column as focused
            self.focused_column = insert_at;
            new_grp.active_panel = 0;
        }

        self.panToFocusedColumn();

        // Layout first so the reparented widget is fully positioned/realized
        self.applyLayout();
        // Clear restructuring before grabbing focus so that onFocusEnter
        // can process normally (the defer will also set it to false, harmlessly).
        self.restructuring = false;
        // Now safe to grab GTK focus on the settled widget
        if (self.focusedGroup()) |grp| {
            // Raise the focused pane to the top of the GtkFixed z-order
            // so it isn't hidden by other panels during the slide animation.
            // Only needed in stacked mode — tabbed panels live inside AdwTabView.
            if (grp.in_stacked_mode and grp.active_panel < grp.panels.items.len) {
                const pw = grp.panels.items[grp.active_panel].getWidget();
                c.gtk_widget_insert_before(pw, @ptrCast(self.fixed), null);
            }
            grp.focus();
        }
    }

    /// Insert a new column at a specific index, pre-populated with an
    /// already-detached panel. The panel widget must already be on the
    /// workspace GtkFixed. Does NOT set focus or call applyLayout.
    fn insertColumnWithPanel(self: *Workspace, panel: Panel, at: usize) !*PaneGroup {
        const grp = try PaneGroup.createEmpty(self.alloc, self.id);
        errdefer grp.destroy();

        var col = try Column.init(self.alloc, Column.default_width, grp);
        errdefer col.deinit(self.alloc);

        col.open_anim = 0.0;
        col.layout_mode = .stacked;
        col.stacked_anim = 1.0;

        const insert_pos = @min(at, self.columns.items.len);
        try self.columns.insert(self.alloc, insert_pos, col);

        // Add group container to GtkFixed
        const widget = grp.getWidget();
        c.gtk_fixed_put(@ptrCast(self.fixed), widget, 0, 0);

        // Enter stacked mode (safe with empty panels). Insert the panel
        // directly into the list — the widget is already on workspace.fixed
        // and re-adding it would trigger unrealize/realize.
        grp.enterStackedMode(self.fixed);
        if (panel.asTerminal()) |p| {
            p.pane_group_id = grp.id;
            p.workspace_id = grp.workspace_id;
        }
        grp.panels.insert(grp.alloc, 0, panel) catch return error.OutOfMemory;

        // Hide initially to avoid flash before first animation tick
        c.gtk_widget_set_opacity(widget, 0);
        for (grp.panels.items) |p| {
            c.gtk_widget_set_opacity(p.getWidget(), 0);
        }

        return grp;
    }

    /// Close the active panel in the focused pane group.
    /// Returns true if the workspace is now empty.
    pub fn closeFocusedPane(self: *Workspace) bool {
        const grp = self.focusedGroup() orelse return true;

        // Clear pane history if it points to the closing pane
        if (grp.focusedTerminalPane()) |pane| self.clearPaneHistoryFor(pane.id);

        // If group has multiple panels, just remove the active one
        if (grp.panels.items.len > 1) {
            _ = grp.removeActivePanel();
            // Trigger layout update for stacked mode
            self.applyLayout();
            return false;
        }

        // Single panel: remove the entire column
        return self.removeColumn(self.focused_column);
    }

    pub fn focusPaneDirection(self: *Workspace, direction: FocusDirection) void {
        self.savePaneFocusHistory();
        switch (direction) {
            .left => {
                if (self.liveColumnCount() <= 1) return;
                var i = self.focused_column;
                while (i > 0) {
                    i -= 1;
                    if (!self.columns.items[i].closing) {
                        if (self.focusedGroup()) |old| old.unfocus();
                        self.focused_column = i;
                        if (self.focusedGroup()) |new_grp| new_grp.focus();
                        self.panToFocusedColumn();
                        return;
                    }
                }
            },
            .right => {
                if (self.liveColumnCount() <= 1) return;
                var i = self.focused_column + 1;
                while (i < self.columns.items.len) : (i += 1) {
                    if (!self.columns.items[i].closing) {
                        if (self.focusedGroup()) |old| old.unfocus();
                        self.focused_column = i;
                        if (self.focusedGroup()) |new_grp| new_grp.focus();
                        self.panToFocusedColumn();
                        return;
                    }
                }
            },
            .up => {
                const group = self.focusedGroup() orelse return;
                group.prevPanel();
            },
            .down => {
                const group = self.focusedGroup() orelse return;
                group.nextPanel();
            },
        }
    }

    // ── Tab operations (per focused group) ──────────────────────────

    pub fn newTabInFocusedGroup(self: *Workspace) !void {
        const group = self.focusedGroup() orelse return error.NoFocusedGroup;
        _ = try group.newPanel(null);
        // Trigger layout update for stacked mode
        self.applyLayout();
        // Re-grab keyboard focus after layout (applyLayout may hide then
        // re-show the widget during stacked animation setup).
        group.focus();
    }

    pub fn closeTabInFocusedGroup(self: *Workspace) bool {
        const grp = self.focusedGroup() orelse return true;
        if (grp.focusedTerminalPane()) |pane| self.clearPaneHistoryFor(pane.id);
        const empty = grp.removeActivePanel();
        if (empty) {
            return self.closeEmptyGroup(grp.id);
        }
        self.applyLayout();
        grp.focus();
        return false;
    }

    pub fn nextTabInFocusedGroup(self: *Workspace) void {
        self.savePaneFocusHistory();
        const group = self.focusedGroup() orelse return;
        group.nextPanel();
    }

    pub fn prevTabInFocusedGroup(self: *Workspace) void {
        self.savePaneFocusHistory();
        const group = self.focusedGroup() orelse return;
        group.prevPanel();
    }

    pub fn switchTabInFocusedGroup(self: *Workspace, index: usize) void {
        self.savePaneFocusHistory();
        const group = self.focusedGroup() orelse return;
        group.switchToPanel(index);
    }

    // ── Lookup helpers ──────────────────────────────────────────────

    pub fn findPaneById(self: *const Workspace, pane_id: u64) ?*Pane {
        for (self.columns.items) |col| {
            for (col.groups.items) |grp| {
                if (grp.findPaneById(pane_id)) |pane| return pane;
            }
        }
        return null;
    }

    pub fn findPanelById(self: *const Workspace, panel_id: u64) ?PaneGroup.FindPanelResult {
        for (self.columns.items) |col| {
            for (col.groups.items) |grp| {
                if (grp.findPanelById(panel_id)) |result| return result;
            }
        }
        return null;
    }

    pub fn findGroupContainingPane(self: *const Workspace, pane_id: u64) ?*PaneGroup {
        for (self.columns.items) |col| {
            for (col.groups.items) |grp| {
                if (grp.findPaneById(pane_id) != null) return grp;
            }
        }
        return null;
    }

    pub fn hasUnreadPane(self: *const Workspace) bool {
        for (self.columns.items) |col| {
            for (col.groups.items) |grp| {
                if (grp.hasUnreadPane()) return true;
            }
        }
        return false;
    }

    /// Close an empty group by ID. Returns true if workspace is now empty.
    pub fn closeEmptyGroup(self: *Workspace, group_id: u64) bool {
        return self.removeColumnByGroupId(group_id);
    }

    /// Toggle "multi-pane" on the workspace container so CSS can show/hide
    /// the focus bar depending on whether there is more than one pane.
    fn updateMultiPaneClass(self: *Workspace) void {
        const multi = if (self.liveColumnCount() > 1)
            true
        else if (self.liveColumnCount() == 1) blk: {
            // Single column in stacked mode with multiple panels counts as multi-pane.
            for (self.columns.items) |col| {
                if (!col.closing and col.layout_mode == .stacked and col.groups.items.len > 0 and col.groups.items[0].panels.items.len > 1)
                    break :blk true;
            }
            break :blk false;
        } else false;

        if (multi) {
            c.gtk_widget_add_css_class(self.container, "multi-pane");
        } else {
            c.gtk_widget_remove_css_class(self.container, "multi-pane");
        }
    }
};

var id_counter: u64 = 0;

pub fn nextId() u64 {
    id_counter += 1;
    return id_counter;
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

const testing = std.testing;

// --- WorkspaceMetadata: setStatus / clearStatus ---

test "WorkspaceMetadata: setStatus inserts new entry" {
    var meta = WorkspaceMetadata{};
    meta.setStatus("agent", "running", 0, true, "Claude");
    try testing.expectEqual(@as(usize, 1), meta.status_count);
    try testing.expectEqualStrings("agent", meta.status_entries[0].getKey());
    try testing.expectEqualStrings("running", meta.status_entries[0].getValue());
    try testing.expect(meta.status_entries[0].is_agent);
    try testing.expectEqualStrings("Claude", meta.status_entries[0].getDisplayName().?);
}

test "WorkspaceMetadata: setStatus updates existing key in place" {
    var meta = WorkspaceMetadata{};
    meta.setStatus("agent", "running", 0, true, null);
    meta.setStatus("agent", "idle", 5, false, "Codex");
    // Should update, not duplicate
    try testing.expectEqual(@as(usize, 1), meta.status_count);
    try testing.expectEqualStrings("idle", meta.status_entries[0].getValue());
    try testing.expectEqual(@as(i32, 5), meta.status_entries[0].priority);
    try testing.expect(!meta.status_entries[0].is_agent);
}

test "WorkspaceMetadata: setStatus at capacity silently drops new entry" {
    var meta = WorkspaceMetadata{};
    for (0..16) |i| {
        var key_buf: [8]u8 = undefined;
        const key = std.fmt.bufPrint(&key_buf, "k{d}", .{i}) catch unreachable;
        meta.setStatus(key, "v", 0, false, null);
    }
    try testing.expectEqual(@as(usize, 16), meta.status_count);
    meta.setStatus("overflow", "v", 0, false, null);
    try testing.expectEqual(@as(usize, 16), meta.status_count);
}

test "WorkspaceMetadata: clearStatus removes and compacts" {
    var meta = WorkspaceMetadata{};
    meta.setStatus("a", "1", 0, false, null);
    meta.setStatus("b", "2", 0, false, null);
    meta.setStatus("c", "3", 0, false, null);

    try testing.expect(meta.clearStatus("b"));
    try testing.expectEqual(@as(usize, 2), meta.status_count);
    try testing.expectEqualStrings("a", meta.status_entries[0].getKey());
    try testing.expectEqualStrings("c", meta.status_entries[1].getKey());
}

test "WorkspaceMetadata: clearStatus nonexistent returns false" {
    var meta = WorkspaceMetadata{};
    meta.setStatus("a", "1", 0, false, null);
    try testing.expect(!meta.clearStatus("nonexistent"));
    try testing.expectEqual(@as(usize, 1), meta.status_count);
}

test "WorkspaceMetadata: clearStatus first and last" {
    var meta = WorkspaceMetadata{};
    meta.setStatus("a", "1", 0, false, null);
    meta.setStatus("b", "2", 0, false, null);
    meta.setStatus("c", "3", 0, false, null);

    try testing.expect(meta.clearStatus("a"));
    try testing.expectEqual(@as(usize, 2), meta.status_count);
    try testing.expectEqualStrings("b", meta.status_entries[0].getKey());

    try testing.expect(meta.clearStatus("c"));
    try testing.expectEqual(@as(usize, 1), meta.status_count);
    try testing.expectEqualStrings("b", meta.status_entries[0].getKey());
}

// --- WorkspaceMetadata: appendLog / getRecentLogs ---

test "WorkspaceMetadata: appendLog and getRecentLogs returns newest first" {
    var meta = WorkspaceMetadata{};
    meta.appendLog("first", .info, 100);
    meta.appendLog("second", .warning, 200);
    meta.appendLog("third", .success, 300);

    var out: [10]LogEntry = undefined;
    const count = meta.getRecentLogs(&out);
    try testing.expectEqual(@as(usize, 3), count);
    try testing.expectEqualStrings("third", out[0].getMessage());
    try testing.expectEqual(LogLevel.success, out[0].level);
    try testing.expectEqualStrings("second", out[1].getMessage());
    try testing.expectEqualStrings("first", out[2].getMessage());
}

test "WorkspaceMetadata: appendLog wraps and evicts oldest" {
    var meta = WorkspaceMetadata{};
    for (0..50) |i| {
        var buf: [32]u8 = undefined;
        const msg = std.fmt.bufPrint(&buf, "msg-{d}", .{i}) catch unreachable;
        meta.appendLog(msg, .info, @intCast(i));
    }
    try testing.expectEqual(@as(usize, 50), meta.log_count);

    // Push one more — evicts msg-0
    meta.appendLog("msg-50", .info, 50);
    try testing.expectEqual(@as(usize, 50), meta.log_count);

    var out: [50]LogEntry = undefined;
    const count = meta.getRecentLogs(&out);
    try testing.expectEqual(@as(usize, 50), count);
    try testing.expectEqualStrings("msg-50", out[0].getMessage());
    try testing.expectEqualStrings("msg-1", out[49].getMessage()); // msg-0 evicted
}

test "WorkspaceMetadata: getRecentLogs with smaller output buffer" {
    var meta = WorkspaceMetadata{};
    for (0..10) |i| {
        var buf: [8]u8 = undefined;
        const msg = std.fmt.bufPrint(&buf, "m{d}", .{i}) catch unreachable;
        meta.appendLog(msg, .info, @intCast(i));
    }
    var out: [3]LogEntry = undefined;
    const count = meta.getRecentLogs(&out);
    try testing.expectEqual(@as(usize, 3), count);
    try testing.expectEqualStrings("m9", out[0].getMessage());
    try testing.expectEqualStrings("m8", out[1].getMessage());
    try testing.expectEqualStrings("m7", out[2].getMessage());
}

test "WorkspaceMetadata: getRecentLogs after multiple wraps" {
    var meta = WorkspaceMetadata{};
    // Push 120 items into 50-slot ring — wraps more than once
    for (0..120) |i| {
        var buf: [8]u8 = undefined;
        const msg = std.fmt.bufPrint(&buf, "m{d}", .{i}) catch unreachable;
        meta.appendLog(msg, .info, @intCast(i));
    }
    var out: [50]LogEntry = undefined;
    const count = meta.getRecentLogs(&out);
    try testing.expectEqual(@as(usize, 50), count);
    try testing.expectEqualStrings("m119", out[0].getMessage());
    try testing.expectEqualStrings("m70", out[49].getMessage());
}

test "WorkspaceMetadata: clearLog resets" {
    var meta = WorkspaceMetadata{};
    meta.appendLog("msg", .info, 0);
    meta.clearLog();
    try testing.expectEqual(@as(usize, 0), meta.log_count);
    var out: [1]LogEntry = undefined;
    try testing.expectEqual(@as(usize, 0), meta.getRecentLogs(&out));
}

// --- WorkspaceMetadata: getSortedStatusIndices ---

test "WorkspaceMetadata: getSortedStatusIndices by priority then key" {
    var meta = WorkspaceMetadata{};
    meta.setStatus("zeta", "v", 3, false, null);
    meta.setStatus("alpha", "v", 1, false, null);
    meta.setStatus("beta", "v", 1, false, null);
    meta.setStatus("gamma", "v", 2, false, null);

    var indices: [16]usize = undefined;
    const count = meta.getSortedStatusIndices(&indices);
    try testing.expectEqual(@as(usize, 4), count);
    // Priority 1: alpha < beta; then priority 2: gamma; then priority 3: zeta
    try testing.expectEqualStrings("alpha", meta.status_entries[indices[0]].getKey());
    try testing.expectEqualStrings("beta", meta.status_entries[indices[1]].getKey());
    try testing.expectEqualStrings("gamma", meta.status_entries[indices[2]].getKey());
    try testing.expectEqualStrings("zeta", meta.status_entries[indices[3]].getKey());
}

test "WorkspaceMetadata: getSortedStatusIndices negative priorities" {
    var meta = WorkspaceMetadata{};
    meta.setStatus("low", "v", 10, false, null);
    meta.setStatus("high", "v", -5, false, null);
    meta.setStatus("mid", "v", 0, false, null);

    var indices: [16]usize = undefined;
    const count = meta.getSortedStatusIndices(&indices);
    try testing.expectEqual(@as(usize, 3), count);
    try testing.expectEqualStrings("high", meta.status_entries[indices[0]].getKey());
    try testing.expectEqualStrings("mid", meta.status_entries[indices[1]].getKey());
    try testing.expectEqualStrings("low", meta.status_entries[indices[2]].getKey());
}

// --- WorkspaceMetadata: progress ---

test "WorkspaceMetadata: setProgress and clearProgress" {
    var meta = WorkspaceMetadata{};
    meta.setProgress(0.75, "Building...");
    try testing.expect(meta.progress.active);
    try testing.expectEqual(@as(f64, 0.75), meta.progress.value);
    try testing.expectEqualStrings("Building...", meta.progress.getLabel().?);

    meta.clearProgress();
    try testing.expect(!meta.progress.active);
    try testing.expectEqual(@as(f64, 0.0), meta.progress.value);
    try testing.expect(meta.progress.getLabel() == null);
}

test "WorkspaceMetadata: setProgress clamps out-of-range values" {
    var meta = WorkspaceMetadata{};
    meta.setProgress(2.5, null);
    try testing.expectEqual(@as(f64, 1.0), meta.progress.value);
    meta.setProgress(-0.5, null);
    try testing.expectEqual(@as(f64, 0.0), meta.progress.value);
}
