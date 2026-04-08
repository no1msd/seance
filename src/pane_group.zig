const std = @import("std");
const c = @import("c.zig").c;
const Pane = @import("pane.zig").Pane;
const Panel = @import("panel.zig").Panel;

// Module-level state for cross-group tab transfer via AdwTabView.
// When a page is detached during a transfer, we stash the panel here
// so page-attached on the destination can pick it up.
var pending_transfer_panel: ?Panel = null;

/// Cast any libadwaita/GTK pointer to *GtkWidget (handles alignment).
inline fn asWidget(ptr: anytype) *c.GtkWidget {
    return @ptrCast(@alignCast(ptr));
}


pub const PaneGroup = struct {
    pub const FindPanelResult = struct { panel: Panel, index: usize };

    id: u64,
    workspace_id: u64,
    panels: std.ArrayList(Panel),
    active_panel: usize = 0,
    container: *c.GtkWidget, // GtkBox vertical: [AdwTabBar | separator | AdwTabView]
    tab_view: *c.AdwTabView,
    tab_bar: *c.GtkWidget, // AdwTabBar widget, stored for CSS class toggling
    alloc: std.mem.Allocator,
    is_zooming: bool = false,
    /// When true, onPageDetached skips cleanup — the caller handles it.
    programmatic_close: bool = false,
    /// Set after disconnectSignals() so destroy() won't re-disconnect
    /// on a potentially-finalized tab_view.
    signals_disconnected: bool = false,
    menu_target_page: ?*c.AdwTabPage = null,
    /// True when panels live on GtkFixed instead of inside AdwTabView.
    in_stacked_mode: bool = false,
    /// GtkFixed widget where panels are placed in stacked mode.
    fixed: ?*c.GtkWidget = null,

    pub fn create(alloc: std.mem.Allocator, cwd: ?[*:0]const u8, workspace_id: u64) !*PaneGroup {
        const self = try initGroupWidgets(alloc, workspace_id);
        const pane = try Pane.create(alloc, cwd, workspace_id, self.id);
        const panel = Panel{ .terminal = pane };
        try self.addPanel(panel);
        return self;
    }

    /// Create a PaneGroup with no initial panel. Used when moving a
    /// detached panel into a brand-new column.
    pub fn createEmpty(alloc: std.mem.Allocator, workspace_id: u64) !*PaneGroup {
        return initGroupWidgets(alloc, workspace_id);
    }

    /// Shared widget creation, signal wiring, and struct init for
    /// create() and createEmpty().
    fn initGroupWidgets(alloc: std.mem.Allocator, workspace_id: u64) !*PaneGroup {
        const group_id = nextId();

        const min_pane_size: c_int = 100;
        const container = c.gtk_box_new(c.GTK_ORIENTATION_VERTICAL, 0);
        c.gtk_widget_set_hexpand(container, 1);
        c.gtk_widget_set_vexpand(container, 1);
        c.gtk_widget_set_size_request(container, min_pane_size, min_pane_size);
        c.gtk_widget_set_overflow(container, c.GTK_OVERFLOW_HIDDEN);

        const tab_view = c.adw_tab_view_new() orelse return error.OutOfMemory;
        c.adw_tab_view_set_shortcuts(tab_view, c.ADW_TAB_VIEW_SHORTCUT_NONE);
        const tv_widget = asWidget(tab_view);
        c.gtk_widget_set_hexpand(tv_widget, 1);
        c.gtk_widget_set_vexpand(tv_widget, 1);

        const menu = c.g_menu_new();
        c.g_menu_append(menu, "Rename Tab", "tab.rename");
        c.g_menu_append(menu, "Close", "tab.close");
        c.g_menu_append(menu, "Close Other Tabs", "tab.close-others");
        c.g_menu_append(menu, "Close Tabs to the Right", "tab.close-right");
        c.adw_tab_view_set_menu_model(tab_view, @ptrCast(@alignCast(menu)));
        c.g_object_unref(@ptrCast(menu));

        const tab_bar = c.adw_tab_bar_new();
        c.adw_tab_bar_set_view(tab_bar, tab_view);
        c.adw_tab_bar_set_autohide(tab_bar, 0);
        c.adw_tab_bar_set_expand_tabs(tab_bar, 0);

        const add_btn = c.gtk_button_new_from_icon_name("list-add-symbolic");
        c.gtk_widget_add_css_class(@ptrCast(add_btn), "flat");
        c.adw_tab_bar_set_end_action_widget(tab_bar, @ptrCast(add_btn));

        const tb_widget = asWidget(tab_bar);
        c.gtk_box_append(@ptrCast(container), tb_widget);
        const divider = c.gtk_separator_new(c.GTK_ORIENTATION_HORIZONTAL);
        c.gtk_box_append(@ptrCast(container), @ptrCast(divider));
        c.gtk_box_append(@ptrCast(container), tv_widget);

        const self = try alloc.create(PaneGroup);
        self.* = .{
            .id = group_id,
            .workspace_id = workspace_id,
            .panels = .empty,
            .container = container,
            .tab_view = tab_view,
            .tab_bar = tb_widget,
            .alloc = alloc,
        };

        const action_group = c.g_simple_action_group_new();

        const rename_action = c.g_simple_action_new("rename", null);
        _ = c.g_signal_connect_data(@ptrCast(rename_action), "activate", @as(c.GCallback, @ptrCast(&onCtxRename)), @ptrCast(self), null, 0);
        c.g_action_map_add_action(@ptrCast(action_group), @ptrCast(rename_action));

        const close_action = c.g_simple_action_new("close", null);
        _ = c.g_signal_connect_data(@ptrCast(close_action), "activate", @as(c.GCallback, @ptrCast(&onCtxClose)), @ptrCast(self), null, 0);
        c.g_action_map_add_action(@ptrCast(action_group), @ptrCast(close_action));

        const others_action = c.g_simple_action_new("close-others", null);
        _ = c.g_signal_connect_data(@ptrCast(others_action), "activate", @as(c.GCallback, @ptrCast(&onCtxCloseOthers)), @ptrCast(self), null, 0);
        c.g_action_map_add_action(@ptrCast(action_group), @ptrCast(others_action));

        const right_action = c.g_simple_action_new("close-right", null);
        _ = c.g_signal_connect_data(@ptrCast(right_action), "activate", @as(c.GCallback, @ptrCast(&onCtxCloseRight)), @ptrCast(self), null, 0);
        c.g_action_map_add_action(@ptrCast(action_group), @ptrCast(right_action));

        c.gtk_widget_insert_action_group(container, "tab", @ptrCast(action_group));
        c.g_object_unref(@ptrCast(action_group));

        _ = c.g_signal_connect_data(@ptrCast(tab_view), "close-page", @as(c.GCallback, @ptrCast(&onClosePage)), @ptrCast(self), null, 0);
        _ = c.g_signal_connect_data(@ptrCast(tab_view), "page-detached", @as(c.GCallback, @ptrCast(&onPageDetached)), @ptrCast(self), null, 0);
        _ = c.g_signal_connect_data(@ptrCast(tab_view), "page-attached", @as(c.GCallback, @ptrCast(&onPageAttached)), @ptrCast(self), null, 0);
        _ = c.g_signal_connect_data(@ptrCast(tab_view), "notify::selected-page", @as(c.GCallback, @ptrCast(&onSelectedPageChanged)), @ptrCast(self), null, 0);
        _ = c.g_signal_connect_data(@ptrCast(tab_view), "setup-menu", @as(c.GCallback, @ptrCast(&onSetupMenu)), @ptrCast(self), null, 0);
        _ = c.g_signal_connect_data(@ptrCast(tab_view), "create-window", @as(c.GCallback, @ptrCast(&onCreateWindow)), null, null, 0);

        _ = c.g_signal_connect_data(@ptrCast(add_btn), "clicked", @as(c.GCallback, @ptrCast(&onAddClicked)), @ptrCast(self), null, 0);

        return self;
    }

    /// Disconnect all signal handlers (on AdwTabView and on each panel's
    /// widgets) so GTK won't call back into freed memory during widget
    /// teardown. Must be called while widgets are still alive (before
    /// gtk_fixed_remove). Safe to call multiple times.
    pub fn disconnectSignals(self: *PaneGroup) void {
        if (self.signals_disconnected) return;
        self.signals_disconnected = true;
        _ = c.g_signal_handlers_disconnect_matched(
            @as(c.gpointer, @ptrCast(self.tab_view)),
            c.G_SIGNAL_MATCH_DATA,
            0,
            0,
            null,
            null,
            @as(c.gpointer, @ptrCast(self)),
        );
        for (self.panels.items) |panel| {
            panel.disconnectSignals();
        }
    }

    pub fn destroy(self: *PaneGroup) void {
        self.disconnectSignals();
        // Remove stacked panel widgets from GtkFixed before destroying
        if (self.in_stacked_mode) {
            if (self.fixed) |fixed| {
                for (self.panels.items) |panel| {
                    c.gtk_fixed_remove(@ptrCast(fixed), panel.getWidget());
                }
            }
        }
        for (self.panels.items) |panel| {
            panel.destroy(self.alloc);
        }
        self.panels.deinit(self.alloc);
        self.alloc.destroy(self);
    }

    pub fn addPanel(self: *PaneGroup, panel: Panel) !void {
        try self.panels.append(self.alloc, panel);

        if (self.in_stacked_mode) {
            if (self.fixed) |fixed| {
                c.gtk_fixed_put(@ptrCast(fixed), panel.getWidget(), 0, 0);
                // Start with open animation at 0 (will animate in)
                if (panel.asTerminal()) |pane| {
                    pane.stacked_open_anim = 0.0;
                    // Initialize layout fraction at target so new panel doesn't slide
                    const n_f: f64 = @floatFromInt(self.panels.items.len);
                    const i_f: f64 = @floatFromInt(self.panels.items.len - 1);
                    pane.stacked_frac_y = i_f / n_f;
                    pane.stacked_frac_h = 1.0 / n_f;
                }
            }
            // Focus the newly added panel
            if (self.active_panel < self.panels.items.len - 1) {
                self.panels.items[self.active_panel].unfocus();
            }
            self.active_panel = self.panels.items.len - 1;
            panel.focus();
        } else {
            const page = c.adw_tab_view_append(self.tab_view, panel.getWidget());
            const title = panelTitle(panel);
            var buf: [65:0]u8 = [_:0]u8{0} ** 65;
            const len = @min(title.len, 64);
            @memcpy(buf[0..len], title[0..len]);
            c.adw_tab_page_set_title(page, &buf);

            c.adw_tab_view_set_selected_page(self.tab_view, page);
        }
    }

    pub fn newPanel(self: *PaneGroup, cwd: ?[*:0]const u8) !*Pane {
        const pane = try Pane.create(self.alloc, cwd, self.workspace_id, self.id);

        const panel = Panel{ .terminal = pane };
        try self.addPanel(panel);
        return pane;
    }

    /// Remove panel at index. Returns true if the group is now empty.
    /// Caller is responsible for handling the empty-group case.
    pub fn removePanel(self: *PaneGroup, index: usize) bool {
        if (index >= self.panels.items.len) return self.panels.items.len == 0;

        const panel = self.panels.items[index];
        _ = self.panels.orderedRemove(index);

        if (self.in_stacked_mode) {
            if (self.fixed) |fixed| {
                c.gtk_fixed_remove(@ptrCast(fixed), panel.getWidget());
            }
        } else {
            // Close the tab view page; suppress onPageDetached cleanup
            self.programmatic_close = true;
            const page = c.adw_tab_view_get_nth_page(self.tab_view, @intCast(index));
            c.adw_tab_view_close_page(self.tab_view, page);
            self.programmatic_close = false;
        }

        panel.destroy(self.alloc);

        if (self.panels.items.len == 0) return true;

        if (self.active_panel >= self.panels.items.len) {
            self.active_panel = self.panels.items.len - 1;
        }
        if (!self.in_stacked_mode) {
            self.switchToPanel(self.active_panel);
        }
        // Ensure keyboard focus lands on the new active panel.
        // In tabbed mode switchToPanel may be a no-op when the page
        // was already auto-selected by adw_tab_view_close_page.
        self.panels.items[self.active_panel].focus();
        return false;
    }

    /// Remove the active panel. Returns true if the group is now empty.
    pub fn removeActivePanel(self: *PaneGroup) bool {
        return self.removePanel(self.active_panel);
    }

    pub fn switchToPanel(self: *PaneGroup, index: usize) void {
        if (index >= self.panels.items.len) return;
        if (self.in_stacked_mode) {
            // In stacked mode, directly update active_panel and focus
            if (self.active_panel < self.panels.items.len) {
                self.panels.items[self.active_panel].unfocus();
            }
            self.active_panel = index;
            self.panels.items[index].focus();
        } else {
            const page = c.adw_tab_view_get_nth_page(self.tab_view, @intCast(index));
            c.adw_tab_view_set_selected_page(self.tab_view, page);
        }
    }

    pub fn getActivePanel(self: *const PaneGroup) ?Panel {
        if (self.panels.items.len == 0) return null;
        if (self.active_panel >= self.panels.items.len) return null;
        return self.panels.items[self.active_panel];
    }

    pub fn focusedTerminalPane(self: *const PaneGroup) ?*Pane {
        const panel = self.getActivePanel() orelse return null;
        return panel.asTerminal();
    }

    pub fn nextPanel(self: *PaneGroup) void {
        if (self.panels.items.len <= 1) return;
        self.switchToPanel((self.active_panel + 1) % self.panels.items.len);
    }

    pub fn prevPanel(self: *PaneGroup) void {
        if (self.panels.items.len <= 1) return;
        if (self.active_panel == 0) {
            self.switchToPanel(self.panels.items.len - 1);
        } else {
            self.switchToPanel(self.active_panel - 1);
        }
    }

    pub fn focus(self: *PaneGroup) void {
        c.gtk_widget_add_css_class(self.tab_bar, "tab-bar-focused");
        if (self.getActivePanel()) |panel| panel.focus();
    }

    pub fn unfocus(self: *PaneGroup) void {
        c.gtk_widget_remove_css_class(self.tab_bar, "tab-bar-focused");
        if (self.getActivePanel()) |panel| panel.unfocus();
    }

    pub fn getWidget(self: *const PaneGroup) *c.GtkWidget {
        return self.container;
    }

    /// Move all panels from AdwTabView to GtkFixed for stacked display.
    /// The PaneGroup container remains on GtkFixed (for tab bar animation)
    /// but its tab_view content is hidden.
    pub fn enterStackedMode(self: *PaneGroup, fixed: *c.GtkWidget) void {
        if (self.in_stacked_mode) return;
        self.in_stacked_mode = true;
        self.fixed = fixed;

        // Suppress signals during reparenting.
        self.programmatic_close = true;

        // Ref all panel widgets before removing them from AdwTabView.
        for (self.panels.items) |panel| {
            _ = c.g_object_ref(@ptrCast(panel.getWidget()));
        }

        // Directly unparent each panel widget from the AdwTabView's internal
        // container rather than using adw_tab_view_close_page (which can
        // leave the widget parented in an internal container and schedule
        // deferred cleanup on repeated enter/exit cycles).
        // Unparenting directly is safe because we hold an extra ref.
        for (self.panels.items) |panel| {
            const w = panel.getWidget();
            if (c.gtk_widget_get_parent(w) != null) {
                c.gtk_widget_unparent(w);
            }
        }

        // Close the now-stale (childless) pages immediately.  Widgets are
        // parentless at this point, so page dispose's gtk_widget_unparent
        // is a no-op.  Without this, the AdwTabView retains pages whose
        // dispose will later unparent widgets that have since been moved
        // to GtkFixed (e.g. after an expel moves a panel to another group
        // and the source column is destroyed, finalizing this tab_view).
        var stale_n = c.adw_tab_view_get_n_pages(self.tab_view);
        while (stale_n > 0) {
            const page = c.adw_tab_view_get_nth_page(self.tab_view, 0);
            c.adw_tab_view_close_page(self.tab_view, page);
            const new_n = c.adw_tab_view_get_n_pages(self.tab_view);
            if (new_n >= stale_n) break;
            stale_n = new_n;
        }

        // Hide tab_view
        c.gtk_widget_set_visible(asWidget(self.tab_view), 0);

        // Add all panel widgets to GtkFixed and initialize layout fractions.
        const n_f: f64 = @floatFromInt(self.panels.items.len);
        for (self.panels.items, 0..) |panel, i| {
            const w = panel.getWidget();
            c.gtk_fixed_put(@ptrCast(fixed), w, 0, 0);
            _ = c.g_object_unref(@ptrCast(w));
            if (panel.asTerminal()) |pane| {
                const i_f: f64 = @floatFromInt(i);
                pane.stacked_frac_y = i_f / n_f;
                pane.stacked_frac_h = 1.0 / n_f;
            }
        }

        self.programmatic_close = false;
    }

    /// Move all panels from GtkFixed back to AdwTabView for tabbed display.
    pub fn exitStackedMode(self: *PaneGroup) void {
        if (!self.in_stacked_mode) return;
        self.in_stacked_mode = false;

        const fixed = self.fixed orelse return;

        // Ref all panel widgets, restore visibility/opacity (cleared by
        // stacked→tabbed animation), remove divider CSS classes (they're
        // meaningless inside AdwTabView and must be cleared before
        // reparenting to avoid stale style state), then remove from GtkFixed.
        for (self.panels.items) |panel| {
            const w = panel.getWidget();
            c.gtk_widget_set_visible(w, 1);
            c.gtk_widget_set_opacity(w, 1.0);
            // Clear the explicit size request left by stacked layout so the
            // panel doesn't inflate AdwTabView's natural size (which GtkFixed
            // uses for allocation).  Without this, the tabbed container stays
            // at full-viewport width when a second column is added.
            c.gtk_widget_set_size_request(w, -1, -1);
            c.gtk_widget_remove_css_class(w, "column-has-divider");
            c.gtk_widget_remove_css_class(w, "column-has-right-divider");
            c.gtk_widget_remove_css_class(w, "row-has-divider");
            c.gtk_fixed_set_child_transform(@ptrCast(fixed), w, null);
            _ = c.g_object_ref(@ptrCast(w));
            c.gtk_fixed_remove(@ptrCast(fixed), w);
        }

        // Suppress signals while cleaning up stale pages and re-adding panels.
        self.programmatic_close = true;

        // Clean up stale (childless) pages left by enterStackedMode.
        // enterStackedMode unparents widgets directly without close_page,
        // so the tab_view may still have page objects with no children.
        var stale_n = c.adw_tab_view_get_n_pages(self.tab_view);
        while (stale_n > 0) {
            const page = c.adw_tab_view_get_nth_page(self.tab_view, 0);
            c.adw_tab_view_close_page(self.tab_view, page);
            const new_n = c.adw_tab_view_get_n_pages(self.tab_view);
            if (new_n >= stale_n) break;
            stale_n = new_n;
        }

        // Add all panels back to AdwTabView as fresh pages.
        for (self.panels.items) |panel| {
            const w = panel.getWidget();
            const page = c.adw_tab_view_append(self.tab_view, w);
            const title = panelTitle(panel);
            var buf: [65:0]u8 = [_:0]u8{0} ** 65;
            const len = @min(title.len, 64);
            @memcpy(buf[0..len], title[0..len]);
            c.adw_tab_page_set_title(page, &buf);
            _ = c.g_object_unref(@ptrCast(w));
        }

        self.programmatic_close = false;

        // Show tab_view
        c.gtk_widget_set_visible(asWidget(self.tab_view), 1);

        // Select active panel (fires onSelectedPageChanged normally)
        if (self.active_panel < self.panels.items.len) {
            const page = c.adw_tab_view_get_nth_page(self.tab_view, @intCast(self.active_panel));
            c.adw_tab_view_set_selected_page(self.tab_view, page);
        }

        self.fixed = null;
    }

    /// Find a panel by its ID in this group. Returns the panel and its index.
    pub fn findPanelById(self: *const PaneGroup, panel_id: u64) ?FindPanelResult {
        for (self.panels.items, 0..) |panel, i| {
            if (panel.getId() == panel_id) return .{ .panel = panel, .index = i };
        }
        return null;
    }

    /// Find a terminal pane by ID in this group.
    pub fn findPaneById(self: *const PaneGroup, pane_id: u64) ?*Pane {
        for (self.panels.items) |panel| {
            if (panel.getId() == pane_id) {
                return panel.asTerminal();
            }
        }
        return null;
    }

    /// Returns true if any terminal pane in this group has unread notifications.
    pub fn hasUnreadPane(self: *const PaneGroup) bool {
        for (self.panels.items) |panel| {
            const pane = panel.asTerminal() orelse continue;
            if (pane.has_unread) return true;
        }
        return false;
    }

    /// Close all panels except the one at keep_index.
    pub fn closeOtherPanels(self: *PaneGroup, keep_index: usize) void {
        if (keep_index >= self.panels.items.len) return;
        if (self.in_stacked_mode) {
            // Remove panels manually in reverse order
            var i = self.panels.items.len;
            while (i > 0) {
                i -= 1;
                if (i != keep_index) {
                    _ = self.removePanel(i);
                }
            }
            self.active_panel = 0;
        } else {
            const keep_page = c.adw_tab_view_get_nth_page(self.tab_view, @intCast(keep_index));
            c.adw_tab_view_close_other_pages(self.tab_view, keep_page);
        }
    }

    /// Close all panels to the right of from_index.
    pub fn closePanelsToRight(self: *PaneGroup, from_index: usize) void {
        if (from_index >= self.panels.items.len) return;
        if (self.in_stacked_mode) {
            var i = self.panels.items.len;
            while (i > from_index + 1) {
                i -= 1;
                _ = self.removePanel(i);
            }
        } else {
            const page = c.adw_tab_view_get_nth_page(self.tab_view, @intCast(from_index));
            c.adw_tab_view_close_pages_after(self.tab_view, page);
        }
    }

    pub fn reorderPanel(self: *PaneGroup, from: usize, to: usize) void {
        if (from == to) return;
        if (from >= self.panels.items.len or to >= self.panels.items.len) return;

        const panel = self.panels.items[from];
        _ = self.panels.orderedRemove(from);
        self.panels.insert(self.alloc, to, panel) catch return;

        if (!self.in_stacked_mode) {
            const page = c.adw_tab_view_get_nth_page(self.tab_view, @intCast(from));
            _ = c.adw_tab_view_reorder_page(self.tab_view, page, @intCast(to));
        }

        if (self.active_panel == from) {
            self.active_panel = to;
        } else if (from < self.active_panel and to >= self.active_panel) {
            self.active_panel -= 1;
        } else if (from > self.active_panel and to <= self.active_panel) {
            self.active_panel += 1;
        }
    }

    /// Update the tab bar title for a panel by its pane ID.
    pub fn updateTitleForPane(self: *PaneGroup, pane_id: u64, title: []const u8) void {
        if (self.in_stacked_mode) return; // no tab pages in stacked mode
        for (self.panels.items, 0..) |panel, i| {
            if (panel.getId() == pane_id) {
                const page = c.adw_tab_view_get_nth_page(self.tab_view, @intCast(i));
                var buf: [65:0]u8 = [_:0]u8{0} ** 65;
                const tlen = @min(title.len, 64);
                @memcpy(buf[0..tlen], title[0..tlen]);
                c.adw_tab_page_set_title(page, &buf);
                return;
            }
        }
    }

    /// Set tab notification badge for a panel by pane ID.
    pub fn setNotificationForPane(self: *PaneGroup, pane_id: u64, has_notification: bool) void {
        if (self.in_stacked_mode) return; // no tab pages in stacked mode
        for (self.panels.items, 0..) |panel, i| {
            if (panel.getId() == pane_id) {
                const page = c.adw_tab_view_get_nth_page(self.tab_view, @intCast(i));
                c.adw_tab_page_set_needs_attention(page, if (has_notification) 1 else 0);
                return;
            }
        }
    }

    /// Clear tab attention indicators on all panels in this group.
    pub fn clearAllTabNotifications(self: *PaneGroup) void {
        if (self.in_stacked_mode) return;
        const n = c.adw_tab_view_get_n_pages(self.tab_view);
        var i: c_int = 0;
        while (i < n) : (i += 1) {
            const page = c.adw_tab_view_get_nth_page(self.tab_view, i);
            c.adw_tab_page_set_needs_attention(page, 0);
        }
    }

    /// Find panel index by matching the widget inside an AdwTabPage.
    fn findPanelIndexByWidget(self: *PaneGroup, widget: *c.GtkWidget) ?usize {
        for (self.panels.items, 0..) |panel, i| {
            if (panel.getWidget() == widget) return i;
        }
        return null;
    }
};

fn panelTitle(panel: Panel) []const u8 {
    if (panel.asTerminal()) |pane| {
        if (pane.getDisplayTitle()) |title| return title;
    }
    return "Terminal";
}

// ── AdwTabView signal handlers ─────────────────────────────────────

fn onClosePage(_: *c.AdwTabView, page: *c.AdwTabPage, user_data: c.gpointer) callconv(.c) c.gboolean {
    const self: *PaneGroup = @ptrCast(@alignCast(user_data));
    c.adw_tab_view_close_page_finish(self.tab_view, page, 1);
    return 1; // handled
}

fn onPageDetached(tab_view: *c.AdwTabView, page: *c.AdwTabPage, _: c.gint, user_data: c.gpointer) callconv(.c) void {
    const self: *PaneGroup = @ptrCast(@alignCast(user_data));
    const child = c.adw_tab_page_get_child(page);

    // If transferring to another tab view, stash the panel instead of destroying
    if (c.adw_tab_view_get_is_transferring_page(tab_view) != 0) {
        if (self.findPanelIndexByWidget(child)) |idx| {
            pending_transfer_panel = self.panels.items[idx];
            _ = self.panels.orderedRemove(idx);
            if (self.active_panel >= self.panels.items.len and self.panels.items.len > 0) {
                self.active_panel = self.panels.items.len - 1;
            }
        }
        if (self.panels.items.len == 0) {
            _ = c.g_idle_add(@ptrCast(&idleCloseEmptyGroup), @ptrFromInt(self.id));
        }
        return;
    }

    // Programmatic close (removePanel) — caller handles cleanup.
    // Also ignore in stacked mode: panels live on GtkFixed, not in the
    // tab view, so any deferred page-detached signals are stale.
    if (self.is_zooming or self.programmatic_close or self.in_stacked_mode) return;

    // User-initiated close (clicked tab close button): clean up the panel
    if (self.findPanelIndexByWidget(child)) |idx| {
        const panel = self.panels.items[idx];
        _ = self.panels.orderedRemove(idx);
        panel.destroy(self.alloc);
        if (self.active_panel >= self.panels.items.len and self.panels.items.len > 0) {
            self.active_panel = self.panels.items.len - 1;
        }
    }

    if (self.panels.items.len == 0) {
        _ = c.g_idle_add(@ptrCast(&idleCloseEmptyGroup), @ptrFromInt(self.id));
    }
}

fn onPageAttached(_: *c.AdwTabView, page: *c.AdwTabPage, position: c.gint, user_data: c.gpointer) callconv(.c) void {
    const self: *PaneGroup = @ptrCast(@alignCast(user_data));

    if (pending_transfer_panel) |panel| {
        pending_transfer_panel = null;
        const pos: usize = @intCast(position);

        if (panel.asTerminal()) |pane| {
            pane.pane_group_id = self.id;
            pane.workspace_id = self.workspace_id;
        }

        self.panels.insert(self.alloc, pos, panel) catch return;

        const title = panelTitle(panel);
        var buf: [65:0]u8 = [_:0]u8{0} ** 65;
        const len = @min(title.len, 64);
        @memcpy(buf[0..len], title[0..len]);
        c.adw_tab_page_set_title(page, &buf);
    }
}

fn onSelectedPageChanged(_: *c.GObject, _: *c.GParamSpec, user_data: c.gpointer) callconv(.c) void {
    const self: *PaneGroup = @ptrCast(@alignCast(user_data));
    // Suppress during enterStackedMode/exitStackedMode reparenting
    if (self.programmatic_close) return;
    const page = c.adw_tab_view_get_selected_page(self.tab_view) orelse return;
    const child = c.adw_tab_page_get_child(page);

    if (self.active_panel < self.panels.items.len) {
        self.panels.items[self.active_panel].unfocus();
    }

    if (self.findPanelIndexByWidget(child)) |idx| {
        self.active_panel = idx;
        self.panels.items[idx].focus();
    }
}

fn onSetupMenu(_: *c.AdwTabView, page: ?*c.AdwTabPage, user_data: c.gpointer) callconv(.c) void {
    const self: *PaneGroup = @ptrCast(@alignCast(user_data));
    self.menu_target_page = page;
}

fn onCreateWindow(_: *c.AdwTabView, _: c.gpointer) callconv(.c) ?*c.AdwTabView {
    return null;
}

fn onAddClicked(_: *c.GtkButton, data: c.gpointer) callconv(.c) void {
    const self: *PaneGroup = @ptrCast(@alignCast(data));
    _ = self.newPanel(null) catch {};
}

// ── Context menu action handlers ───────────────────────────────────

fn onCtxRename(_: *c.GSimpleAction, _: ?*c.GVariant, data: c.gpointer) callconv(.c) void {
    const self: *PaneGroup = @ptrCast(@alignCast(data));
    const page = self.menu_target_page orelse return;
    const child = c.adw_tab_page_get_child(page);
    const pane = blk: {
        for (self.panels.items) |panel| {
            if (panel.getWidget() == child) break :blk panel.asTerminal() orelse return;
        }
        return;
    };

    const root = c.gtk_widget_get_root(asWidget(self.tab_view)) orelse return;

    const dialog = c.adw_alert_dialog_new("Rename Tab", null);
    c.adw_alert_dialog_add_response(@as(*c.AdwAlertDialog, @ptrCast(dialog)), "cancel", "Cancel");
    c.adw_alert_dialog_add_response(@as(*c.AdwAlertDialog, @ptrCast(dialog)), "clear", "Clear");
    c.adw_alert_dialog_add_response(@as(*c.AdwAlertDialog, @ptrCast(dialog)), "rename", "Rename");
    c.adw_alert_dialog_set_response_appearance(@as(*c.AdwAlertDialog, @ptrCast(dialog)), "rename", c.ADW_RESPONSE_SUGGESTED);
    c.adw_alert_dialog_set_default_response(@as(*c.AdwAlertDialog, @ptrCast(dialog)), "rename");
    c.adw_alert_dialog_set_close_response(@as(*c.AdwAlertDialog, @ptrCast(dialog)), "cancel");

    const entry = c.gtk_entry_new();
    c.gtk_entry_set_activates_default(@ptrCast(entry), 1);
    var title_z: [257]u8 = undefined;
    const display_title = pane.getDisplayTitle() orelse "Terminal";
    const tlen = @min(display_title.len, title_z.len - 1);
    @memcpy(title_z[0..tlen], display_title[0..tlen]);
    title_z[tlen] = 0;
    c.gtk_editable_set_text(@ptrCast(entry), &title_z);
    c.adw_alert_dialog_set_extra_child(@as(*c.AdwAlertDialog, @ptrCast(dialog)), entry);

    const ctx = self.alloc.create(RenameCtx) catch return;
    ctx.* = .{ .group = self, .pane_id = pane.id, .entry = @ptrCast(entry) };

    _ = c.g_signal_connect_data(@as(c.gpointer, @ptrCast(dialog)), "response", @as(c.GCallback, @ptrCast(&onCtxRenameResponse)), @ptrCast(ctx), null, 0);
    c.adw_dialog_present(@as(*c.AdwDialog, @ptrCast(dialog)), @ptrCast(@alignCast(root)));

    _ = c.gtk_widget_grab_focus(entry);
    c.gtk_editable_select_region(@ptrCast(entry), 0, -1);
}

const RenameCtx = struct {
    group: *PaneGroup,
    pane_id: u64,
    entry: *c.GtkEditable,
};

fn onCtxRenameResponse(_: *c.AdwAlertDialog, response: [*:0]const u8, data: c.gpointer) callconv(.c) void {
    const ctx: *RenameCtx = @ptrCast(@alignCast(data));
    const resp = std.mem.sliceTo(response, 0);

    if (std.mem.eql(u8, resp, "rename")) {
        const text: [*c]const u8 = c.gtk_editable_get_text(ctx.entry);
        if (text != null) {
            const slice = std.mem.span(text);
            const trimmed = std.mem.trim(u8, slice, " \t\r\n");
            if (trimmed.len > 0) {
                if (ctx.group.findPaneById(ctx.pane_id)) |pane| {
                    pane.setCustomTitle(trimmed);
                    ctx.group.updateTitleForPane(ctx.pane_id, trimmed);
                }
            }
        }
    } else if (std.mem.eql(u8, resp, "clear")) {
        if (ctx.group.findPaneById(ctx.pane_id)) |pane| {
            pane.clearCustomTitle();
            const title = pane.getCachedTitle() orelse "Terminal";
            ctx.group.updateTitleForPane(ctx.pane_id, title);
        }
    }

    ctx.group.alloc.destroy(ctx);
}

fn onCtxClose(_: *c.GSimpleAction, _: ?*c.GVariant, data: c.gpointer) callconv(.c) void {
    const self: *PaneGroup = @ptrCast(@alignCast(data));
    const page = self.menu_target_page orelse return;
    c.adw_tab_view_close_page(self.tab_view, page);
}

fn onCtxCloseOthers(_: *c.GSimpleAction, _: ?*c.GVariant, data: c.gpointer) callconv(.c) void {
    const self: *PaneGroup = @ptrCast(@alignCast(data));
    const page = self.menu_target_page orelse return;

    const n = c.adw_tab_view_get_n_pages(self.tab_view);
    if (n <= 1) return;

    if (n > 2) {
        showCloseConfirmDialog(self, page, false);
        return;
    }
    c.adw_tab_view_close_other_pages(self.tab_view, page);
}

fn onCtxCloseRight(_: *c.GSimpleAction, _: ?*c.GVariant, data: c.gpointer) callconv(.c) void {
    const self: *PaneGroup = @ptrCast(@alignCast(data));
    const page = self.menu_target_page orelse return;

    const page_pos = c.adw_tab_view_get_page_position(self.tab_view, page);
    const n = c.adw_tab_view_get_n_pages(self.tab_view);
    const count_right = n - page_pos - 1;
    if (count_right <= 0) return;

    if (count_right > 1) {
        showCloseConfirmDialog(self, page, true);
        return;
    }
    c.adw_tab_view_close_pages_after(self.tab_view, page);
}

const CloseDialogCtx = struct {
    group: *PaneGroup,
    page: *c.AdwTabPage,
    right_only: bool,
    alloc: std.mem.Allocator,
};

fn showCloseConfirmDialog(group: *PaneGroup, page: *c.AdwTabPage, right_only: bool) void {
    const root = c.gtk_widget_get_root(asWidget(group.tab_view)) orelse return;

    const page_pos = c.adw_tab_view_get_page_position(group.tab_view, page);
    const n = c.adw_tab_view_get_n_pages(group.tab_view);
    const count: usize = if (right_only)
        @intCast(n - page_pos - 1)
    else
        @intCast(n - 1);

    const title: [*:0]const u8 = if (right_only) "Close Tabs to the Right?" else "Close Other Tabs?";
    var msg_buf: [128:0]u8 = [_:0]u8{0} ** 128;
    _ = std.fmt.bufPrint(&msg_buf, "This will close {d} tab{s} and their terminal sessions.", .{ count, if (count != 1) "s" else "" }) catch {};

    const dialog = c.adw_alert_dialog_new(title, &msg_buf);
    c.adw_alert_dialog_add_response(@as(*c.AdwAlertDialog, @ptrCast(dialog)), "cancel", "Cancel");
    c.adw_alert_dialog_add_response(@as(*c.AdwAlertDialog, @ptrCast(dialog)), "close", "Close");
    c.adw_alert_dialog_set_response_appearance(@as(*c.AdwAlertDialog, @ptrCast(dialog)), "close", c.ADW_RESPONSE_DESTRUCTIVE);
    c.adw_alert_dialog_set_default_response(@as(*c.AdwAlertDialog, @ptrCast(dialog)), "cancel");
    c.adw_alert_dialog_set_close_response(@as(*c.AdwAlertDialog, @ptrCast(dialog)), "cancel");

    const ctx = group.alloc.create(CloseDialogCtx) catch return;
    ctx.* = .{
        .group = group,
        .page = page,
        .right_only = right_only,
        .alloc = group.alloc,
    };

    _ = c.g_signal_connect_data(@as(c.gpointer, @ptrCast(dialog)), "response", @as(c.GCallback, @ptrCast(&onCloseDialogResponse)), @ptrCast(ctx), null, 0);
    c.adw_dialog_present(@as(*c.AdwDialog, @ptrCast(dialog)), @ptrCast(@alignCast(root)));
}

fn onCloseDialogResponse(_: *c.AdwAlertDialog, response: [*:0]const u8, data: c.gpointer) callconv(.c) void {
    const ctx: *CloseDialogCtx = @ptrCast(@alignCast(data));
    if (std.mem.eql(u8, std.mem.sliceTo(response, 0), "close")) {
        if (ctx.right_only) {
            c.adw_tab_view_close_pages_after(ctx.group.tab_view, ctx.page);
        } else {
            c.adw_tab_view_close_other_pages(ctx.group.tab_view, ctx.page);
        }
    }
    ctx.alloc.destroy(ctx);
}

// ── Idle callback to close empty groups ────────────────────────────

fn idleCloseEmptyGroup(user_data: c.gpointer) callconv(.c) c.gboolean {
    const group_id: u64 = @intFromPtr(user_data);
    const Window = @import("window.zig");
    const wm = Window.window_manager orelse return 0;
    for (wm.windows.items) |state| {
        for (state.workspaces.items, 0..) |ws, ws_idx| {
            if (ws.closeEmptyGroup(group_id)) {
                if (ws.columns.items.len == 0) {
                    state.closeWorkspace(ws_idx);
                } else {
                    state.sidebar.refresh();
                }
                return 0;
            }
        }
    }
    return 0; // G_SOURCE_REMOVE
}

var id_counter: u64 = 0;

fn nextId() u64 {
    id_counter += 1;
    return id_counter;
}
