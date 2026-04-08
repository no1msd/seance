const std = @import("std");
const c = @import("c.zig").c;
const workspace_mod = @import("workspace.zig");
const Workspace = workspace_mod.Workspace;
const notification = @import("notification.zig");
const config_mod = @import("config.zig");
const vtab_mod = @import("vertical_tab_bar.zig");

pub const ContextAction = enum { pin_toggle, rename, color_0, color_1, color_2, color_3, color_4, color_5, color_6, color_none, move_up, move_down, move_to_top, close, mark_read };

pub const Sidebar = struct {
    widget: *c.GtkWidget,
    tab_bar: vtab_mod.VerticalTabBar,
    workspaces: *std.ArrayList(*Workspace),
    alloc: std.mem.Allocator,
    notif_store: ?*const notification.NotificationStore = null,
    on_select: ?*const fn (usize) void = null,
    on_new: ?*const fn () void = null,
    on_reorder: ?*const fn (usize, usize) void = null,
    on_close: ?*const fn (usize) void = null,
    on_toggle_notifications: ?*const fn () void = null,
    on_context_action: ?*const fn (usize, ContextAction) void = null,
    on_move_to_window: ?*const fn (usize, usize) void = null,
    on_toggle_sidebar: ?*const fn () void = null,
    on_settings: ?*const fn () void = null,

    // Ordered indices for display (pinned first, then unpinned)
    display_order: [128]usize = undefined,
    display_order_len: usize = 0,

    // Debounce: coalesce multiple refresh() calls into a single idle callback
    refresh_pending: bool = false,
    refresh_idle_id: c.guint = 0,
    pending_set_active: ?usize = null,

    // Notification bell badge (overlay label showing unread count)
    // Either lives in the footer (SSD) or the window's header bar (CSD).
    notif_badge: ?*c.GtkWidget = null,
    notif_overlay: ?*c.GtkWidget = null,

    // Footer row (add / notif / hide / settings).  Only present when the
    // window is in SSD mode and we can't stash those buttons in an
    // adw_header_bar.  Null in CSD mode.
    footer: ?*c.GtkWidget = null,

    // Suppress refresh while interacting (context menu or hover)
    popover_open: bool = false,
    hover_active: bool = false,

    // Track workspace IDs with expanded status pills
    status_expanded_ids: [128]u64 = [_]u64{0} ** 128,
    status_expanded_count: usize = 0,

    pub fn isStatusExpanded(self: *const Sidebar, ws_id: u64) bool {
        for (self.status_expanded_ids[0..self.status_expanded_count]) |id| {
            if (id == ws_id) return true;
        }
        return false;
    }

    pub fn toggleStatusExpanded(self: *Sidebar, ws_id: u64) void {
        for (0..self.status_expanded_count) |i| {
            if (self.status_expanded_ids[i] == ws_id) {
                var j = i;
                while (j + 1 < self.status_expanded_count) : (j += 1) {
                    self.status_expanded_ids[j] = self.status_expanded_ids[j + 1];
                }
                self.status_expanded_count -= 1;
                return;
            }
        }
        if (self.status_expanded_count < self.status_expanded_ids.len) {
            self.status_expanded_ids[self.status_expanded_count] = ws_id;
            self.status_expanded_count += 1;
        }
    }

    pub fn create(
        alloc: std.mem.Allocator,
        workspaces: *std.ArrayList(*Workspace),
        on_select: *const fn (usize) void,
        on_new: *const fn () void,
    ) Sidebar {
        const vbox = c.gtk_box_new(c.GTK_ORIENTATION_VERTICAL, 0);
        c.gtk_widget_add_css_class(vbox, "sidebar");
        c.gtk_widget_set_size_request(vbox, 180, -1);

        // Vertical tab bar (replaces scrolled + list_box)
        const tab_bar = vtab_mod.VerticalTabBar.create(alloc);
        c.gtk_widget_set_vexpand(tab_bar.widget, 1);
        c.gtk_box_append(@ptrCast(vbox), tab_bar.widget);

        // The footer row (add / notif / hide / settings) is built lazily by
        // buildFooter() once the Sidebar has its final stable address in
        // WindowState.  In CSD mode the window's adw_header_bar hosts these
        // buttons instead and the footer stays null.
        return Sidebar{
            .widget = vbox,
            .tab_bar = tab_bar,
            .workspaces = workspaces,
            .alloc = alloc,
            .on_select = on_select,
            .on_new = on_new,
        };
    }

    pub fn connectSignals(self: *Sidebar) void {
        // Connect tab bar signals now that self (and tab_bar within it) has a stable address
        self.tab_bar.connectSignals();
        self.tab_bar.on_select = &onVtabSelect;
        self.tab_bar.on_close = &onVtabClose;
        self.tab_bar.on_reorder = &onVtabReorder;
        self.tab_bar.on_context_menu = &onVtabContext;
        self.tab_bar.on_middle_click = &onVtabClose;
    }

    /// Build the footer row with the add / notif / hide / settings buttons
    /// and append it to the sidebar vbox.  Wires click handlers directly,
    /// so this must be called after the Sidebar has a stable address.
    /// Idempotent: calling twice while a footer already exists is a no-op.
    pub fn buildFooter(self: *Sidebar) void {
        if (self.footer != null) return;

        const footer = c.gtk_box_new(c.GTK_ORIENTATION_HORIZONTAL, 4);
        c.gtk_widget_add_css_class(footer, "sidebar-footer");

        // Left group: primary action
        const add_btn = c.gtk_button_new_from_icon_name("list-add-symbolic");
        c.gtk_widget_set_tooltip_text(@ptrCast(add_btn), "New Workspace");
        c.gtk_box_append(@ptrCast(footer), @ptrCast(add_btn));
        _ = c.g_signal_connect_data(@ptrCast(add_btn), "clicked", @ptrCast(&onAddClicked), @ptrCast(self), null, 0);

        // Spacer
        const spacer = c.gtk_label_new("");
        c.gtk_widget_set_hexpand(spacer, 1);
        c.gtk_box_append(@ptrCast(footer), spacer);

        // Right group: utility controls
        const notif_btn = c.gtk_button_new_from_icon_name("bell-outline-symbolic");
        c.gtk_widget_set_tooltip_text(@ptrCast(notif_btn), "Notifications");
        _ = c.g_signal_connect_data(@ptrCast(notif_btn), "clicked", @ptrCast(&onNotifToggleClicked), @ptrCast(self), null, 0);

        // Wrap bell button in overlay for unread badge
        const overlay = c.gtk_overlay_new();
        c.gtk_overlay_set_child(@ptrCast(overlay), @ptrCast(notif_btn));
        const badge = c.gtk_label_new("");
        c.gtk_widget_add_css_class(badge, "notif-bell-badge");
        c.gtk_label_set_xalign(@ptrCast(badge), 0.5);
        c.gtk_widget_set_halign(badge, c.GTK_ALIGN_END);
        c.gtk_widget_set_valign(badge, c.GTK_ALIGN_START);
        c.gtk_widget_set_visible(badge, 0);
        c.gtk_overlay_add_overlay(@ptrCast(overlay), badge);
        c.gtk_box_append(@ptrCast(footer), @ptrCast(overlay));
        self.notif_badge = badge;
        self.notif_overlay = @ptrCast(overlay);

        const cfg = config_mod.get();
        const hide_icon: [*:0]const u8 = if (cfg.sidebar_position == .right) "sidebar-show-right-symbolic" else "sidebar-show-symbolic";
        const hide_btn = c.gtk_button_new_from_icon_name(hide_icon);
        c.gtk_widget_set_tooltip_text(@ptrCast(hide_btn), "Hide Sidebar");
        c.gtk_box_append(@ptrCast(footer), @ptrCast(hide_btn));
        _ = c.g_signal_connect_data(@ptrCast(hide_btn), "clicked", @ptrCast(&onSidebarHideClicked), @ptrCast(self), null, 0);

        const settings_btn = c.gtk_button_new_from_icon_name("emblem-system-symbolic");
        c.gtk_widget_set_tooltip_text(@ptrCast(settings_btn), "Settings");
        c.gtk_box_append(@ptrCast(footer), @ptrCast(settings_btn));
        _ = c.g_signal_connect_data(@ptrCast(settings_btn), "clicked", @ptrCast(&onSettingsClicked), @ptrCast(self), null, 0);

        c.gtk_box_append(@ptrCast(self.widget), footer);
        self.footer = footer;

        // Push the current unread count into the freshly created badge.
        self.refresh();
    }

    /// Remove the footer row if present.  Also clears notif_badge and
    /// notif_overlay since they belong to the footer; the caller (window.zig)
    /// is responsible for repointing them at header-bar widgets in CSD mode.
    pub fn destroyFooter(self: *Sidebar) void {
        const footer = self.footer orelse return;
        c.gtk_box_remove(@ptrCast(self.widget), footer);
        self.footer = null;
        self.notif_badge = null;
        self.notif_overlay = null;
    }

    /// Build display order: pinned workspaces first, then unpinned, preserving
    /// relative order within each group.
    fn buildDisplayOrder(self: *Sidebar) void {
        self.display_order_len = 0;
        for (self.workspaces.items, 0..) |ws, i| {
            if (ws.is_pinned) {
                if (self.display_order_len < self.display_order.len) {
                    self.display_order[self.display_order_len] = i;
                    self.display_order_len += 1;
                }
            }
        }
        for (self.workspaces.items, 0..) |ws, i| {
            if (!ws.is_pinned) {
                if (self.display_order_len < self.display_order.len) {
                    self.display_order[self.display_order_len] = i;
                    self.display_order_len += 1;
                }
            }
        }
    }

    /// Rebuild display order synchronously (for callers that need it up-to-date immediately).
    pub fn ensureDisplayOrder(self: *Sidebar) void {
        self.buildDisplayOrder();
    }

    /// Map a workspace list index to its display row index.
    pub fn displayIndexOf(self: *Sidebar, ws_index: usize) ?usize {
        for (self.display_order[0..self.display_order_len], 0..) |idx, di| {
            if (idx == ws_index) return di;
        }
        return null;
    }

    /// Find workspace index from workspace ID.
    fn wsIndexFromId(self: *const Sidebar, ws_id: u64) ?usize {
        for (self.workspaces.items, 0..) |ws, i| {
            if (ws.id == ws_id) return i;
        }
        return null;
    }

    pub fn refresh(self: *Sidebar) void {
        self.refresh_pending = true;
        if (self.refresh_idle_id == 0) {
            self.refresh_idle_id = c.g_timeout_add_full(
                c.G_PRIORITY_HIGH_IDLE,
                32,
                @ptrCast(&sidebarIdleRefresh),
                @ptrCast(self),
                null,
            );
        }
    }

    fn sidebarIdleRefresh(data: c.gpointer) callconv(.c) c.gboolean {
        const self: *Sidebar = @ptrCast(@alignCast(data));
        self.refresh_idle_id = 0;
        if (self.refresh_pending) {
            if (self.popover_open or self.hover_active) return c.G_SOURCE_REMOVE;
            self.refresh_pending = false;
            self.refreshImpl();
            if (self.pending_set_active) |idx| {
                self.pending_set_active = null;
                self.setActiveImpl(idx);
            }
        }
        return c.G_SOURCE_REMOVE;
    }

    pub fn cancelPendingRefresh(self: *Sidebar) void {
        if (self.refresh_idle_id != 0) {
            _ = c.g_source_remove(self.refresh_idle_id);
            self.refresh_idle_id = 0;
        }
        self.refresh_pending = false;
        self.pending_set_active = null;
        // Cancel tab bar timers and pending idle callbacks
        self.tab_bar.deinit();
    }

    fn refreshImpl(self: *Sidebar) void {
        self.buildDisplayOrder();

        var ids: [128]u64 = undefined;
        var pinned: [128]bool = undefined;
        for (self.display_order[0..self.display_order_len], 0..) |ws_idx, i| {
            ids[i] = self.workspaces.items[ws_idx].id;
            pinned[i] = self.workspaces.items[ws_idx].is_pinned;
        }

        self.tab_bar.reconcile(
            ids[0..self.display_order_len],
            pinned[0..self.display_order_len],
            &contentBuilderCallback,
        );

        // Update color bars for each workspace
        for (self.display_order[0..self.display_order_len]) |ws_idx| {
            const ws = self.workspaces.items[ws_idx];
            self.tab_bar.setTabColor(ws.id, ws.getCustomColor());
        }

        // Update notification bell badge
        if (self.notif_badge) |badge| {
            if (self.notif_store) |store| {
                const total_unread = store.unreadCount();
                if (total_unread > 0) {
                    var buf: [8]u8 = undefined;
                    const text = std.fmt.bufPrintZ(&buf, "{d}", .{total_unread}) catch "!";
                    c.gtk_label_set_text(@ptrCast(badge), text.ptr);
                    c.gtk_widget_set_visible(badge, 1);
                } else {
                    c.gtk_widget_set_visible(badge, 0);
                }
            } else {
                c.gtk_widget_set_visible(badge, 0);
            }
        }
    }

    /// Content builder callback passed to VerticalTabBar.reconcile.
    /// Builds the rich content widget for a given workspace ID.
    fn contentBuilderCallback(vtab: *vtab_mod.VerticalTabBar, ws_id: u64) ?*c.GtkWidget {
        // Recover the Sidebar pointer from the vtab pointer.
        // The tab_bar is a field within Sidebar, so we can use @fieldParentPtr.
        const self: *Sidebar = @fieldParentPtr("tab_bar", vtab);
        return self.buildTabContent(ws_id);
    }

    fn buildTabContent(self: *Sidebar, ws_id: u64) ?*c.GtkWidget {
        const cfg = config_mod.get();
        const ws_idx = self.wsIndexFromId(ws_id) orelse return null;
        const ws = self.workspaces.items[ws_idx];

        const show_notification_text = cfg.sidebar_show_notification_text;
        const show_status = cfg.sidebar_show_status;
        const show_logs = cfg.sidebar_show_logs;
        const show_progress = cfg.sidebar_show_progress;
        const show_branch = cfg.sidebar_show_branch;
        const show_ports = cfg.sidebar_show_ports;

        // Container: VStack, leading-aligned, spacing 4
        const row_box = c.gtk_box_new(c.GTK_ORIENTATION_VERTICAL, 4);
        c.gtk_widget_add_css_class(row_box, "sidebar-row");

        // ═══ Section 1: Header Row (HStack, spacing 8) ═══
        const title_hbox = c.gtk_box_new(c.GTK_ORIENTATION_HORIZONTAL, 8);

        // Unread badge
        if (self.notif_store) |store| {
            const unread = store.unreadForWorkspace(ws.id);
            if (unread > 0) {
                var badge_buf: [8]u8 = undefined;
                const badge_text = std.fmt.bufPrintZ(&badge_buf, "{d}", .{unread}) catch "!";
                const badge = c.gtk_label_new(badge_text.ptr);
                c.gtk_widget_add_css_class(badge, "sidebar-badge");
                c.gtk_widget_set_valign(badge, c.GTK_ALIGN_CENTER);
                c.gtk_box_append(@ptrCast(title_hbox), badge);
            }
        }

        // Pin icon
        if (ws.is_pinned) {
            const pin_icon = makeIcon("pin-symbolic", 10);
            c.gtk_widget_add_css_class(pin_icon, "sidebar-pin-icon");
            c.gtk_box_append(@ptrCast(title_hbox), pin_icon);
        }

        // Workspace title
        var title_z: [129]u8 = undefined;
        const ws_title = ws.getTitle();
        const tlen = @min(ws_title.len, title_z.len - 1);
        @memcpy(title_z[0..tlen], ws_title[0..tlen]);
        title_z[tlen] = 0;
        const title_label = c.gtk_label_new(&title_z);
        c.gtk_label_set_xalign(@ptrCast(title_label), 0);
        c.gtk_widget_add_css_class(title_label, "sidebar-ws-title");
        c.gtk_label_set_ellipsize(@ptrCast(title_label), c.PANGO_ELLIPSIZE_END);
        c.gtk_widget_set_hexpand(title_label, 1);

        c.gtk_box_append(@ptrCast(title_hbox), title_label);
        c.gtk_box_append(@ptrCast(row_box), title_hbox);

        // ═══ Section 2: Latest Notification Subtitle ═══
        if (show_notification_text) {
            if (self.notif_store) |store| {
                if (store.latestForWorkspace(ws.id)) |notif| {
                    const raw_body = notif.getBody();
                    const raw_subtitle = notif.getSubtitle();
                    const raw_text = if (raw_body.len > 0) raw_body else if (raw_subtitle.len > 0) raw_subtitle else notif.getTitle();
                    const text = std.mem.trim(u8, raw_text, " \t\r\n");
                    if (text.len > 0) {
                        var preview_buf: [256]u8 = undefined;
                        const plen = @min(text.len, preview_buf.len - 1);
                        @memcpy(preview_buf[0..plen], text[0..plen]);
                        preview_buf[plen] = 0;
                        const preview_label = c.gtk_label_new(&preview_buf);
                        c.gtk_label_set_xalign(@ptrCast(preview_label), 0);
                        c.gtk_widget_add_css_class(preview_label, "sidebar-notif-preview");
                        c.gtk_label_set_ellipsize(@ptrCast(preview_label), c.PANGO_ELLIPSIZE_END);
                        c.gtk_label_set_lines(@ptrCast(preview_label), 2);
                        c.gtk_label_set_wrap(@ptrCast(preview_label), 1);
                        c.gtk_label_set_wrap_mode(@ptrCast(preview_label), c.PANGO_WRAP_WORD_CHAR);
                        c.gtk_box_append(@ptrCast(row_box), preview_label);
                    }
                }
            }
        }

        // ═══ Section 3: Status Metadata Pills ═══
        if (show_status and ws.metadata.status_count > 0) {
            const pills_box = c.gtk_box_new(c.GTK_ORIENTATION_VERTICAL, 2);
            c.gtk_widget_set_halign(pills_box, c.GTK_ALIGN_FILL);

            var sort_indices: [16]usize = undefined;
            const sorted_count = ws.metadata.getSortedStatusIndices(&sort_indices);
            const is_expanded = self.isStatusExpanded(ws.id);

            const visible_count: usize = if (is_expanded or sorted_count <= 3) sorted_count else 3;

            for (0..visible_count) |si| {
                const entry = &ws.metadata.status_entries[sort_indices[si]];
                const status_label = makeStatusLabel(entry);
                c.gtk_box_append(@ptrCast(pills_box), status_label);
            }

            // Show more/less toggle when > 3 entries
            if (sorted_count > 3) {
                const toggle_text: [*:0]const u8 = if (is_expanded) "Show less" else "Show more";
                const toggle_btn = c.gtk_button_new_with_label(toggle_text);
                c.gtk_widget_add_css_class(@ptrCast(toggle_btn), "sidebar-show-more-btn");
                c.gtk_widget_set_halign(@ptrCast(toggle_btn), c.GTK_ALIGN_START);
                c.gtk_button_set_has_frame(@ptrCast(toggle_btn), 0);
                const toggle_data = self.alloc.create(StatusToggleData) catch null;
                if (toggle_data) |td| {
                    td.* = .{ .sidebar = self, .ws_id = ws.id };
                    _ = c.g_signal_connect_data(
                        @as(c.gpointer, @ptrCast(toggle_btn)),
                        "clicked",
                        @as(c.GCallback, @ptrCast(&onStatusToggleClicked)),
                        @ptrCast(td),
                        @ptrCast(&onStatusToggleDataDestroy),
                        0,
                    );
                }
                c.gtk_box_append(@ptrCast(pills_box), @ptrCast(toggle_btn));
            }

            c.gtk_box_append(@ptrCast(row_box), pills_box);
        }

        // ═══ Section 4: Latest Log Entry ═══
        if (show_logs and ws.metadata.log_count > 0) {
            var log_buf: [1]workspace_mod.LogEntry = undefined;
            const log_count = ws.metadata.getRecentLogs(&log_buf);
            if (log_count > 0) {
                const log_widget = makeLogLabel(&log_buf[0]);
                c.gtk_box_append(@ptrCast(row_box), log_widget);
            }
        }

        // ═══ Section 5: Progress Bar ═══
        if (show_progress and ws.metadata.progress.active) {
            const progress_widget = makeProgressWidget(&ws.metadata.progress);
            c.gtk_box_append(@ptrCast(row_box), progress_widget);
        }

        // ═══ Section 6: Git Branch + Directory ═══
        if (show_branch) {
            const cwd = ws.getActivePaneCwd();
            const branch = ws.getGitBranch();
            if (cwd != null or branch != null) {
                const section = makeBranchDirectorySection(
                    branch,
                    ws.git_dirty,
                    cwd,
                    false,
                );
                c.gtk_box_append(@ptrCast(row_box), section);
            }
        }

        // ═══ Section 7: Listening Ports ═══
        if (show_ports and ws.ports_len > 0) {
            const ports_label = makePortsLabel(ws.getActivePorts());
            c.gtk_box_append(@ptrCast(row_box), ports_label);
        }

        // ═══ Section 8: Column Indicator Dots ═══
        if (makeColumnDots(ws)) |dots_widget| {
            c.gtk_box_append(@ptrCast(row_box), dots_widget);
        }

        return row_box;
    }

    pub fn setActive(self: *Sidebar, index: usize) void {
        if (self.refresh_pending or self.refresh_idle_id != 0) {
            self.pending_set_active = index;
            return;
        }
        self.setActiveImpl(index);
    }

    fn setActiveImpl(self: *Sidebar, index: usize) void {
        if (index >= self.workspaces.items.len) return;
        const ws_id = self.workspaces.items[index].id;
        self.tab_bar.setSelected(ws_id);
    }
};

// ── VerticalTabBar callback adapters ──
// These fire with workspace IDs; we map back to workspace indices.

fn onVtabSelect(ws_id: u64) void {
    // We need to find the Sidebar from the callback context.
    // Since VerticalTabBar stores function pointers (not closures), we use the
    // window_manager to find the active sidebar.
    const Window = @import("window.zig");
    if (Window.window_manager) |wm| {
        if (wm.active_window) |state| {
            for (state.workspaces.items, 0..) |ws, i| {
                if (ws.id == ws_id) {
                    if (state.sidebar.on_select) |cb| cb(i);
                    return;
                }
            }
        }
    }
}

fn onVtabClose(ws_id: u64) void {
    const Window = @import("window.zig");
    if (Window.window_manager) |wm| {
        if (wm.active_window) |state| {
            for (state.workspaces.items, 0..) |ws, i| {
                if (ws.id == ws_id) {
                    if (state.sidebar.on_close) |cb| cb(i);
                    return;
                }
            }
        }
    }
}

fn onVtabReorder(ws_id: u64, target_display_pos: usize) void {
    const Window = @import("window.zig");
    if (Window.window_manager) |wm| {
        if (wm.active_window) |state| {
            // Find source workspace index
            var src_ws_idx: ?usize = null;
            for (state.workspaces.items, 0..) |ws, i| {
                if (ws.id == ws_id) {
                    src_ws_idx = i;
                    break;
                }
            }
            const src = src_ws_idx orelse return;

            // Map target display position to workspace index
            if (target_display_pos < state.sidebar.display_order_len) {
                const dst = state.sidebar.display_order[target_display_pos];
                if (state.sidebar.on_reorder) |cb| cb(src, dst);
            }
        }
    }
}

fn onVtabContext(ws_id: u64, x: f64, y: f64, widget: *c.GtkWidget) void {
    const Window = @import("window.zig");
    if (Window.window_manager) |wm| {
        if (wm.active_window) |state| {
            for (state.workspaces.items, 0..) |ws, i| {
                if (ws.id == ws_id) {
                    showContextMenu(&state.sidebar, i, ws.is_pinned, x, y, widget);
                    return;
                }
            }
        }
    }
}

fn showContextMenu(self: *Sidebar, ws_idx: usize, is_pinned: bool, x: f64, y: f64, widget: *c.GtkWidget) void {
    const menu = c.g_menu_new();
    const action_group = c.g_simple_action_group_new();

    const pin_label: [*:0]const u8 = if (is_pinned) "Unpin" else "Pin";

    const ActionItem = struct { name: [*:0]const u8, label: [*:0]const u8, action: ContextAction };
    const items = [_]ActionItem{
        .{ .name = "pin-toggle", .label = pin_label, .action = .pin_toggle },
        .{ .name = "rename", .label = "Rename", .action = .rename },
        .{ .name = "move-up", .label = "Move Up", .action = .move_up },
        .{ .name = "move-down", .label = "Move Down", .action = .move_down },
        .{ .name = "move-to-top", .label = "Move to Top", .action = .move_to_top },
        .{ .name = "mark-read", .label = "Mark as Read", .action = .mark_read },
        .{ .name = "close", .label = "Close", .action = .close },
    };

    // Determine if move-up/down/top should be enabled based on display position
    const display_pos = self.displayIndexOf(ws_idx);
    const is_first = if (display_pos) |dp| dp == 0 else true;
    const is_last = if (display_pos) |dp| dp + 1 >= self.display_order_len else true;

    for (items) |item| {
        var ref_buf: [64]u8 = undefined;
        const action_ref = std.fmt.bufPrintZ(&ref_buf, "wsctx.{s}", .{std.mem.span(item.name)}) catch continue;
        c.g_menu_append(@as(*c.GMenu, @ptrCast(menu)), item.label, action_ref.ptr);

        const simple_action = c.g_simple_action_new(item.name, null);

        // Disable move actions at boundaries
        if (item.action == .move_up or item.action == .move_to_top) {
            if (is_first) c.g_simple_action_set_enabled(@ptrCast(simple_action), 0);
        } else if (item.action == .move_down) {
            if (is_last) c.g_simple_action_set_enabled(@ptrCast(simple_action), 0);
        }

        const ctx = self.alloc.create(ContextActionData) catch continue;
        ctx.* = .{ .sidebar = self, .ws_idx = ws_idx, .action = item.action };
        _ = c.g_signal_connect_data(@ptrCast(simple_action), "activate", @as(c.GCallback, @ptrCast(&onCtxAction)), @ptrCast(ctx), @ptrCast(&onContextActionDataDestroy), 0);
        c.g_action_map_add_action(@ptrCast(action_group), @ptrCast(simple_action));
    }

    // "Tab Color" submenu
    {
        const theme_mod = @import("theme.zig");
        const submenu = c.g_menu_new();
        const color_actions = [7]ContextAction{ .color_0, .color_1, .color_2, .color_3, .color_4, .color_5, .color_6 };

        for (0..7) |ci| {
            var cref_buf: [64]u8 = undefined;
            const caction_ref = std.fmt.bufPrintZ(&cref_buf, "wsctx.color-{d}", .{ci}) catch continue;
            c.g_menu_append(@as(*c.GMenu, @ptrCast(submenu)), theme_mod.tab_color_names[ci], caction_ref.ptr);

            var cname_buf: [32]u8 = undefined;
            const caction_name = std.fmt.bufPrintZ(&cname_buf, "color-{d}", .{ci}) catch continue;
            const csimple = c.g_simple_action_new(caction_name.ptr, null);
            const cctx = self.alloc.create(ContextActionData) catch continue;
            cctx.* = .{ .sidebar = self, .ws_idx = ws_idx, .action = color_actions[ci] };
            _ = c.g_signal_connect_data(@ptrCast(csimple), "activate", @as(c.GCallback, @ptrCast(&onCtxAction)), @ptrCast(cctx), @ptrCast(&onContextActionDataDestroy), 0);
            c.g_action_map_add_action(@ptrCast(action_group), @ptrCast(csimple));
        }

        // "None" option
        c.g_menu_append(@as(*c.GMenu, @ptrCast(submenu)), "None", "wsctx.color-none");
        const none_action = c.g_simple_action_new("color-none", null);
        const none_ctx = self.alloc.create(ContextActionData) catch null;
        if (none_ctx) |nctx| {
            nctx.* = .{ .sidebar = self, .ws_idx = ws_idx, .action = .color_none };
            _ = c.g_signal_connect_data(@ptrCast(none_action), "activate", @as(c.GCallback, @ptrCast(&onCtxAction)), @ptrCast(nctx), @ptrCast(&onContextActionDataDestroy), 0);
        }
        c.g_action_map_add_action(@ptrCast(action_group), @ptrCast(none_action));

        c.g_menu_insert_submenu(@as(*c.GMenu, @ptrCast(menu)), 2, "Tab Color", @ptrCast(@alignCast(submenu)));
        c.g_object_unref(@ptrCast(submenu));
    }

    // "Move to Window" items
    {
        const Window = @import("window.zig");
        if (Window.window_manager) |wm| {
            if (wm.windows.items.len >= 2) {
                for (wm.windows.items, 0..) |win, win_idx| {
                    if (&win.workspaces == self.workspaces) continue;

                    var label_buf: [128]u8 = undefined;
                    const win_title = if (win.activeWorkspace()) |aws| aws.getTitle() else "Window";
                    const lbl = std.fmt.bufPrintZ(&label_buf, "Move to: {s}", .{win_title}) catch continue;

                    var ref_buf: [64]u8 = undefined;
                    const action_ref = std.fmt.bufPrintZ(&ref_buf, "wsctx.move-to-win-{d}", .{win_idx}) catch continue;
                    c.g_menu_append(@as(*c.GMenu, @ptrCast(menu)), lbl.ptr, action_ref.ptr);

                    var name_buf: [32]u8 = undefined;
                    const action_name = std.fmt.bufPrintZ(&name_buf, "move-to-win-{d}", .{win_idx}) catch continue;
                    const simple_action = c.g_simple_action_new(action_name.ptr, null);
                    const mw_ctx = self.alloc.create(MoveToWindowData) catch continue;
                    mw_ctx.* = .{ .sidebar = self, .ws_idx = ws_idx, .target_window_idx = win_idx };
                    _ = c.g_signal_connect_data(@ptrCast(simple_action), "activate", @as(c.GCallback, @ptrCast(&onCtxMoveToWindow)), @ptrCast(mw_ctx), @ptrCast(&onMoveToWindowDataDestroy), 0);
                    c.g_action_map_add_action(@ptrCast(action_group), @ptrCast(simple_action));
                }
            }
        }
    }

    c.gtk_widget_insert_action_group(widget, "wsctx", @ptrCast(action_group));

    const popover = c.gtk_popover_menu_new_from_model(@ptrCast(@alignCast(menu)));
    c.gtk_widget_set_parent(@as(*c.GtkWidget, @ptrCast(popover)), widget);
    c.gtk_popover_set_has_arrow(@ptrCast(popover), 0);
    const rect = c.GdkRectangle{
        .x = @intFromFloat(x),
        .y = @intFromFloat(y),
        .width = 1,
        .height = 1,
    };
    c.gtk_popover_set_pointing_to(@ptrCast(popover), &rect);

    self.popover_open = true;
    _ = c.g_signal_connect_data(
        @as(c.gpointer, @ptrCast(popover)),
        "closed",
        @as(c.GCallback, @ptrCast(&onPopoverClosed)),
        @ptrCast(self),
        null,
        0,
    );

    c.gtk_popover_popup(@ptrCast(popover));

    c.g_object_unref(@ptrCast(menu));
    c.g_object_unref(@ptrCast(action_group));
}

// ── Content helper functions ──

fn makeIcon(name: [*:0]const u8, size: c.gint) *c.GtkWidget {
    const img = c.gtk_image_new_from_icon_name(name);
    c.gtk_image_set_pixel_size(@ptrCast(@alignCast(img)), size);
    c.gtk_widget_set_valign(img, c.GTK_ALIGN_CENTER);
    return img;
}

fn makeBranchDirectorySection(branch: ?[]const u8, dirty: bool, cwd: ?[]const u8, horizontal: bool) *c.GtkWidget {
    if (horizontal) {
        const hbox = c.gtk_box_new(c.GTK_ORIENTATION_HORIZONTAL, 4);

        if (branch != null) {
            const icon = makeIcon("branch-arrow-symbolic", 11);
            c.gtk_widget_add_css_class(icon, "sidebar-branch-icon");
            c.gtk_box_append(@ptrCast(hbox), icon);
        }

        var buf: [384]u8 = undefined;
        var pos: usize = 0;

        if (branch) |br| {
            const blen = @min(br.len, buf.len - pos - 4);
            @memcpy(buf[pos..][0..blen], br[0..blen]);
            pos += blen;
            if (dirty) {
                buf[pos] = '*';
                pos += 1;
            }
        }

        if (branch != null and cwd != null) {
            if (pos + 3 < buf.len) {
                @memcpy(buf[pos..][0..3], " | ");
                pos += 3;
            }
        }

        if (cwd) |cwd_path| {
            var short_buf: [256]u8 = undefined;
            const display = shortenPath(cwd_path, &short_buf);
            const dlen = @min(display.len, buf.len - pos - 1);
            @memcpy(buf[pos..][0..dlen], display[0..dlen]);
            pos += dlen;
        }

        buf[pos] = 0;
        const text_label = c.gtk_label_new(&buf);
        c.gtk_label_set_xalign(@ptrCast(text_label), 0);
        c.gtk_widget_add_css_class(text_label, "sidebar-branch-text");
        c.gtk_label_set_ellipsize(@ptrCast(text_label), c.PANGO_ELLIPSIZE_END);
        c.gtk_widget_set_valign(text_label, c.GTK_ALIGN_CENTER);
        c.gtk_box_append(@ptrCast(hbox), text_label);

        return hbox;
    } else {
        const hbox = c.gtk_box_new(c.GTK_ORIENTATION_HORIZONTAL, 4);
        c.gtk_widget_set_valign(hbox, c.GTK_ALIGN_START);

        if (branch != null) {
            const icon = makeIcon("branch-arrow-symbolic", 11);
            c.gtk_widget_add_css_class(icon, "sidebar-branch-icon");
            c.gtk_box_append(@ptrCast(hbox), icon);
        }

        const line_hbox = c.gtk_box_new(c.GTK_ORIENTATION_HORIZONTAL, 3);
        c.gtk_widget_set_valign(line_hbox, c.GTK_ALIGN_CENTER);

        if (branch) |br| {
            var br_buf: [140]u8 = undefined;
            const blen = @min(br.len, br_buf.len - 2);
            @memcpy(br_buf[0..blen], br[0..blen]);
            var br_pos = blen;
            if (dirty) {
                br_buf[br_pos] = '*';
                br_pos += 1;
            }
            br_buf[br_pos] = 0;
            const branch_label = c.gtk_label_new(&br_buf);
            c.gtk_label_set_xalign(@ptrCast(branch_label), 0);
            c.gtk_widget_add_css_class(branch_label, "sidebar-branch-text");
            c.gtk_label_set_ellipsize(@ptrCast(branch_label), c.PANGO_ELLIPSIZE_END);
            c.gtk_box_append(@ptrCast(line_hbox), branch_label);
        }

        if (branch != null and cwd != null) {
            const dot = c.gtk_label_new("\xe2\x80\xa2");
            c.gtk_widget_add_css_class(dot, "sidebar-branch-sep");
            c.gtk_widget_set_valign(dot, c.GTK_ALIGN_CENTER);
            c.gtk_box_append(@ptrCast(line_hbox), dot);
        }

        if (cwd) |cwd_path| {
            var short_buf: [256]u8 = undefined;
            const display = shortenPath(cwd_path, &short_buf);
            var cwd_z: [257]u8 = undefined;
            const clen = @min(display.len, cwd_z.len - 1);
            @memcpy(cwd_z[0..clen], display[0..clen]);
            cwd_z[clen] = 0;
            const dir_label = c.gtk_label_new(&cwd_z);
            c.gtk_label_set_xalign(@ptrCast(dir_label), 0);
            c.gtk_widget_add_css_class(dir_label, "sidebar-branch-text");
            c.gtk_label_set_ellipsize(@ptrCast(dir_label), c.PANGO_ELLIPSIZE_END);
            c.gtk_box_append(@ptrCast(line_hbox), dir_label);
        }

        c.gtk_box_append(@ptrCast(hbox), line_hbox);
        return hbox;
    }
}


fn makeStatusLabel(entry: *const workspace_mod.StatusEntry) *c.GtkWidget {
    const hbox = c.gtk_box_new(c.GTK_ORIENTATION_HORIZONTAL, 4);

    const icon_name: [*:0]const u8 = if (entry.is_agent)
        agentStatusIcon(entry.getValue())
    else
        "right-symbolic";
    const icon = makeIcon(icon_name, 10);
    c.gtk_widget_add_css_class(icon, "sidebar-status-icon");
    c.gtk_box_append(@ptrCast(hbox), icon);

    const name = if (entry.is_agent)
        (entry.getDisplayName() orelse entry.getKey())
    else
        entry.getKey();

    var buf: [384]u8 = undefined;
    var pos: usize = 0;
    const klen = @min(name.len, buf.len - pos - 3);
    @memcpy(buf[pos..][0..klen], name[0..klen]);
    pos += klen;
    if (pos + 2 < buf.len) {
        buf[pos] = ':';
        buf[pos + 1] = ' ';
        pos += 2;
    }
    const val = entry.getValue();
    const vlen = @min(val.len, buf.len - pos - 1);
    @memcpy(buf[pos..][0..vlen], val[0..vlen]);
    pos += vlen;
    buf[pos] = 0;

    const label = c.gtk_label_new(&buf);
    c.gtk_label_set_xalign(@ptrCast(label), 0);
    c.gtk_widget_add_css_class(label, "sidebar-ws-meta");
    c.gtk_widget_add_css_class(label, "sidebar-status-entry");
    c.gtk_label_set_ellipsize(@ptrCast(label), c.PANGO_ELLIPSIZE_END);
    c.gtk_widget_set_valign(label, c.GTK_ALIGN_CENTER);
    c.gtk_box_append(@ptrCast(hbox), label);

    return hbox;
}

fn agentStatusIcon(value: []const u8) [*:0]const u8 {
    if (std.mem.eql(u8, value, "Idle")) return "pause-symbolic";
    if (std.mem.eql(u8, value, "Needs input")) return "bell-outline-symbolic";
    return "camera-flash-symbolic";
}

fn makeProgressWidget(progress: *const workspace_mod.ProgressState) *c.GtkWidget {
    const vbox = c.gtk_box_new(c.GTK_ORIENTATION_VERTICAL, 2);

    const bar = c.gtk_progress_bar_new();
    c.gtk_progress_bar_set_fraction(@ptrCast(bar), progress.value);
    c.gtk_progress_bar_set_show_text(@ptrCast(bar), 0);
    c.gtk_widget_add_css_class(bar, "sidebar-progress");
    c.gtk_box_append(@ptrCast(vbox), bar);

    if (progress.getLabel()) |lbl| {
        var buf: [129]u8 = undefined;
        const llen = @min(lbl.len, buf.len - 1);
        @memcpy(buf[0..llen], lbl[0..llen]);
        buf[llen] = 0;
        const label = c.gtk_label_new(&buf);
        c.gtk_label_set_xalign(@ptrCast(label), 0);
        c.gtk_widget_add_css_class(label, "sidebar-progress-label");
        c.gtk_label_set_ellipsize(@ptrCast(label), c.PANGO_ELLIPSIZE_END);
        c.gtk_box_append(@ptrCast(vbox), label);
    }

    return vbox;
}

fn makePortsLabel(ports: []const u16) *c.GtkWidget {
    var buf: [256]u8 = undefined;
    var pos: usize = 0;
    for (ports, 0..) |port, i| {
        if (i > 0) {
            if (pos + 2 < buf.len) {
                buf[pos] = ',';
                buf[pos + 1] = ' ';
                pos += 2;
            }
        }
        const written = std.fmt.bufPrint(buf[pos..], ":{d}", .{port}) catch break;
        pos += written.len;
    }
    if (pos >= buf.len) pos = buf.len - 1;
    buf[pos] = 0;
    const label = c.gtk_label_new(&buf);
    c.gtk_label_set_xalign(@ptrCast(label), 0);
    c.gtk_widget_add_css_class(label, "sidebar-ws-ports");
    c.gtk_label_set_ellipsize(@ptrCast(label), c.PANGO_ELLIPSIZE_END);
    return label;
}

fn makeColumnDots(ws: *const Workspace) ?*c.GtkWidget {
    // Count live (non-closing) columns and find focused column's live index
    var live_count: usize = 0;
    var focused_live: usize = 0;
    for (ws.columns.items, 0..) |col, i| {
        if (col.closing) continue;
        if (i == ws.focused_column) focused_live = live_count;
        live_count += 1;
    }
    if (live_count < 2) return null;

    const filled = "\xE2\x97\x8F"; // ●
    const empty = "\xE2\x97\x8B"; // ○
    const ellipsis = "\xE2\x80\xA6"; // …

    var buf: [128]u8 = undefined;
    var pos: usize = 0;

    const max_display: usize = 15;

    if (live_count <= max_display) {
        // Show all dots
        for (0..live_count) |i| {
            if (i > 0) {
                buf[pos] = ' ';
                pos += 1;
            }
            const dot: *const [3]u8 = if (i == focused_live) filled else empty;
            @memcpy(buf[pos..][0..3], dot);
            pos += 3;
        }
    } else {
        // Truncated: show window of (max_display - 2) dots centered on focused, with … on truncated sides
        const window_size = max_display - 2;
        const half = window_size / 2;

        var start: usize = if (focused_live >= half) focused_live - half else 0;
        var end: usize = start + window_size;
        if (end > live_count) {
            end = live_count;
            start = end - window_size;
        }

        const show_left = start > 0;
        const show_right = end < live_count;
        var first = true;

        if (show_left) {
            @memcpy(buf[pos..][0..3], ellipsis);
            pos += 3;
            first = false;
        }

        for (start..end) |i| {
            if (!first) {
                buf[pos] = ' ';
                pos += 1;
            }
            const dot: *const [3]u8 = if (i == focused_live) filled else empty;
            @memcpy(buf[pos..][0..3], dot);
            pos += 3;
            first = false;
        }

        if (show_right) {
            buf[pos] = ' ';
            pos += 1;
            @memcpy(buf[pos..][0..3], ellipsis);
            pos += 3;
        }
    }

    buf[pos] = 0;
    const label = c.gtk_label_new(&buf);
    c.gtk_label_set_xalign(@ptrCast(label), 0);
    c.gtk_widget_add_css_class(label, "sidebar-col-dots");
    return label;
}

fn makeLogLabel(entry: *const workspace_mod.LogEntry) *c.GtkWidget {
    const hbox = c.gtk_box_new(c.GTK_ORIENTATION_HORIZONTAL, 4);

    const icon_name: [*:0]const u8 = switch (entry.level) {
        .info => "info-outline-symbolic",
        .progress => "execute-to-symbolic",
        .success => "check-round-outline-symbolic",
        .warning => "warning-outline-symbolic",
        .@"error" => "exclamation-mark-symbolic",
    };
    const icon = makeIcon(icon_name, 10);
    c.gtk_widget_add_css_class(icon, "sidebar-log-icon");
    const icon_css: [*:0]const u8 = switch (entry.level) {
        .info => "sidebar-log-info",
        .progress => "sidebar-log-progress",
        .success => "sidebar-log-success",
        .warning => "sidebar-log-warning",
        .@"error" => "sidebar-log-error",
    };
    c.gtk_widget_add_css_class(icon, icon_css);
    c.gtk_box_append(@ptrCast(hbox), icon);

    var buf: [260]u8 = undefined;
    const msg = entry.getMessage();
    const mlen = @min(msg.len, buf.len - 1);
    @memcpy(buf[0..mlen], msg[0..mlen]);
    buf[mlen] = 0;
    const label = c.gtk_label_new(&buf);
    c.gtk_label_set_xalign(@ptrCast(label), 0);
    c.gtk_label_set_ellipsize(@ptrCast(label), c.PANGO_ELLIPSIZE_END);
    c.gtk_widget_add_css_class(label, "sidebar-ws-meta");
    c.gtk_widget_set_valign(label, c.GTK_ALIGN_CENTER);
    c.gtk_box_append(@ptrCast(hbox), label);

    return hbox;
}

fn shortenPath(path: []const u8, buf: []u8) []const u8 {
    const home = std.posix.getenv("HOME") orelse return path;
    if (std.mem.startsWith(u8, path, home)) {
        const rest = path[home.len..];
        if (1 + rest.len <= buf.len) {
            buf[0] = '~';
            @memcpy(buf[1..][0..rest.len], rest);
            return buf[0 .. 1 + rest.len];
        }
    }
    return path;
}

// ── Footer button callbacks ──

pub fn onAddClicked(_: *c.GtkButton, data: c.gpointer) callconv(.c) void {
    const self: *Sidebar = @ptrCast(@alignCast(data));
    if (self.on_new) |cb| cb();
}

pub fn onNotifToggleClicked(_: *c.GtkButton, data: c.gpointer) callconv(.c) void {
    const self: *Sidebar = @ptrCast(@alignCast(data));
    if (self.on_toggle_notifications) |cb| cb();
}

pub fn onSidebarHideClicked(_: *c.GtkButton, data: c.gpointer) callconv(.c) void {
    const self: *Sidebar = @ptrCast(@alignCast(data));
    if (self.on_toggle_sidebar) |cb| cb();
}

pub fn onSettingsClicked(_: *c.GtkButton, data: c.gpointer) callconv(.c) void {
    const self: *Sidebar = @ptrCast(@alignCast(data));
    if (self.on_settings) |cb| cb();
}

// ── Popover closed callback ──

fn onPopoverClosed(_: *c.GtkPopover, data: c.gpointer) callconv(.c) void {
    const self: *Sidebar = @ptrCast(@alignCast(data));
    self.popover_open = false;
    if (self.refresh_pending) {
        self.refresh();
    }
}

// ── Context menu action callbacks ──

const ContextActionData = struct {
    sidebar: *Sidebar,
    ws_idx: usize,
    action: ContextAction,
};

fn onCtxAction(_: *c.GSimpleAction, _: ?*c.GVariant, data: c.gpointer) callconv(.c) void {
    const d: *ContextActionData = @ptrCast(@alignCast(data));
    if (d.sidebar.on_context_action) |cb| cb(d.ws_idx, d.action);
}

fn onContextActionDataDestroy(data: c.gpointer, _: *c.GClosure) callconv(.c) void {
    const d: *ContextActionData = @ptrCast(@alignCast(data));
    d.sidebar.alloc.destroy(d);
}

// ── Move to Window callbacks ──

const MoveToWindowData = struct {
    sidebar: *Sidebar,
    ws_idx: usize,
    target_window_idx: usize,
};

fn onCtxMoveToWindow(_: *c.GSimpleAction, _: ?*c.GVariant, data: c.gpointer) callconv(.c) void {
    const d: *MoveToWindowData = @ptrCast(@alignCast(data));
    if (d.sidebar.on_move_to_window) |cb| cb(d.ws_idx, d.target_window_idx);
}

fn onMoveToWindowDataDestroy(data: c.gpointer, _: *c.GClosure) callconv(.c) void {
    const d: *MoveToWindowData = @ptrCast(@alignCast(data));
    d.sidebar.alloc.destroy(d);
}

// ── Status toggle callbacks ──

const StatusToggleData = struct {
    sidebar: *Sidebar,
    ws_id: u64,
};

fn onStatusToggleClicked(_: *c.GtkButton, data: c.gpointer) callconv(.c) void {
    const d: *StatusToggleData = @ptrCast(@alignCast(data));
    d.sidebar.toggleStatusExpanded(d.ws_id);
    d.sidebar.refresh();
}

fn onStatusToggleDataDestroy(data: c.gpointer, _: *c.GClosure) callconv(.c) void {
    const d: *StatusToggleData = @ptrCast(@alignCast(data));
    d.sidebar.alloc.destroy(d);
}

