const std = @import("std");
const c = @import("c.zig").c;
const notification = @import("notification.zig");

/// Callback for navigating to a notification's source pane.
pub const JumpCallback = *const fn (workspace_id: u64, pane_group_id: u64, pane_id: u64) void;

pub const NotificationPanel = struct {
    container: *c.GtkWidget, // outer vertical box
    header_label: *c.GtkWidget,
    clear_btn: *c.GtkWidget,
    list_box: *c.GtkListBox,
    scrolled: *c.GtkWidget,
    empty_box: *c.GtkWidget, // "No notifications" placeholder
    center: *notification.NotificationCenter,
    on_jump: ?JumpCallback = null,
    on_show_sidebar: ?*const fn () void = null,
    popover: ?*c.GtkWidget = null,

    pub fn create(center: *notification.NotificationCenter) NotificationPanel {
        // Header row: title + clear all
        const header_box = c.gtk_box_new(c.GTK_ORIENTATION_HORIZONTAL, 8);
        c.gtk_widget_set_margin_top(header_box, 12);
        c.gtk_widget_set_margin_bottom(header_box, 8);
        c.gtk_widget_set_margin_start(header_box, 12);
        c.gtk_widget_set_margin_end(header_box, 12);

        const header_label = c.gtk_label_new("Notifications");
        c.gtk_widget_add_css_class(header_label, "sidebar-header");
        c.gtk_label_set_xalign(@ptrCast(header_label), 0);
        c.gtk_widget_set_hexpand(header_label, 1);
        c.gtk_box_append(@ptrCast(header_box), header_label);

        const clear_btn = c.gtk_button_new_from_icon_name("user-trash-symbolic");
        c.gtk_widget_add_css_class(@ptrCast(clear_btn), "flat");
        c.gtk_widget_set_tooltip_text(@ptrCast(clear_btn), "Clear All");
        c.gtk_box_append(@ptrCast(header_box), @ptrCast(clear_btn));

        // Content box to hold empty state and scrolled list
        const content_box = c.gtk_box_new(c.GTK_ORIENTATION_VERTICAL, 0);

        // Empty state placeholder
        const empty_box = c.adw_status_page_new();
        c.adw_status_page_set_icon_name(@as(*c.AdwStatusPage, @ptrCast(empty_box)), "notifications-disabled-symbolic");
        c.adw_status_page_set_title(@as(*c.AdwStatusPage, @ptrCast(empty_box)), "No notifications yet");
        c.adw_status_page_set_description(@as(*c.AdwStatusPage, @ptrCast(empty_box)), "Bell notifications will appear here.");
        c.gtk_widget_set_vexpand(empty_box, 1);

        c.gtk_box_append(@ptrCast(content_box), empty_box);

        // Scrolled list
        const scrolled = c.gtk_scrolled_window_new();
        c.gtk_scrolled_window_set_policy(@ptrCast(scrolled), c.GTK_POLICY_NEVER, c.GTK_POLICY_AUTOMATIC);
        c.gtk_widget_set_vexpand(scrolled, 1);

        const list_box = c.gtk_list_box_new();
        c.gtk_list_box_set_selection_mode(@ptrCast(list_box), c.GTK_SELECTION_BROWSE);
        c.gtk_widget_add_css_class(@as(*c.GtkWidget, @ptrCast(@alignCast(list_box))), "notif-list");
        c.gtk_scrolled_window_set_child(@ptrCast(scrolled), @as(*c.GtkWidget, @ptrCast(@alignCast(list_box))));
        c.gtk_box_append(@ptrCast(content_box), scrolled);

        // Main container
        const container = c.gtk_box_new(c.GTK_ORIENTATION_VERTICAL, 0);
        c.gtk_widget_add_css_class(container, "notification-panel");
        c.gtk_box_append(@ptrCast(container), header_box);
        const sep = c.gtk_separator_new(c.GTK_ORIENTATION_HORIZONTAL);
        c.gtk_box_append(@ptrCast(container), sep);
        c.gtk_box_append(@ptrCast(container), content_box);
        c.gtk_widget_set_vexpand(content_box, 1);

        c.gtk_widget_set_size_request(container, 360, 700);

        const self = NotificationPanel{
            .container = container,
            .header_label = header_label,
            .clear_btn = @ptrCast(clear_btn),
            .list_box = @ptrCast(list_box),
            .scrolled = scrolled,
            .empty_box = empty_box,
            .center = center,
        };

        return self;
    }

    pub fn dismissPopover(self: *NotificationPanel) void {
        if (self.popover) |p| c.gtk_popover_popdown(@ptrCast(p));
    }

    pub fn connectSignals(self: *NotificationPanel) void {
        // Connect clear-all button
        _ = c.g_signal_connect_data(
            @as(c.gpointer, @ptrCast(self.clear_btn)),
            "clicked",
            @as(c.GCallback, @ptrCast(&onClearAllClicked)),
            @ptrCast(self),
            null,
            0,
        );

        // Connect list box row-activated
        _ = c.g_signal_connect_data(
            @as(c.gpointer, @ptrCast(self.list_box)),
            "row-activated",
            @as(c.GCallback, @ptrCast(&onRowActivated)),
            @ptrCast(self),
            null,
            0,
        );
    }

    pub fn refresh(self: *NotificationPanel) void {
        // Update header with unread count
        const unread = self.center.store.unreadCount();
        var header_buf: [64]u8 = undefined;
        const header_text = if (unread > 0)
            std.fmt.bufPrintZ(&header_buf, "Notifications ({d})", .{unread}) catch "Notifications"
        else
            "Notifications";
        c.gtk_label_set_text(@ptrCast(self.header_label), header_text.ptr);

        // Clear existing rows
        var child = c.gtk_widget_get_first_child(@as(*c.GtkWidget, @ptrCast(@alignCast(self.list_box))));
        while (child != null) {
            const next = c.gtk_widget_get_next_sibling(child.?);
            c.gtk_list_box_remove(self.list_box, child.?);
            child = next;
        }

        // Show/hide empty state vs list
        if (self.center.store.count == 0) {
            c.gtk_widget_set_visible(self.empty_box, 1);
            c.gtk_widget_set_visible(self.scrolled, 0);
            return;
        }

        c.gtk_widget_set_visible(self.empty_box, 0);
        c.gtk_widget_set_visible(self.scrolled, 1);

        // Add rows newest-first
        const now = std.time.timestamp();
        for (0..self.center.store.count) |i| {
            const notif = self.center.store.getByIndex(i) orelse continue;
            const row_widget = buildNotificationRow(notif, now, self);
            c.gtk_list_box_append(self.list_box, row_widget);
        }

        // Auto-select first row (Feature 4.2)
        const first_row = c.gtk_list_box_get_row_at_index(self.list_box, 0);
        if (first_row) |row| {
            c.gtk_list_box_select_row(self.list_box, row);
        }
    }
};

fn buildNotificationRow(notif: *notification.Notification, now: i64, panel: *NotificationPanel) *c.GtkWidget {
    const row = c.adw_action_row_new();
    const action_row: *c.AdwActionRow = @ptrCast(row);
    c.gtk_widget_add_css_class(@as(*c.GtkWidget, @ptrCast(row)), "notif-row");
    c.gtk_widget_set_margin_top(@as(*c.GtkWidget, @ptrCast(row)), 4);
    c.gtk_widget_set_margin_bottom(@as(*c.GtkWidget, @ptrCast(row)), 4);

    // Title
    const title = notif.getTitle();
    var title_z: [257]u8 = undefined;
    const tlen = @min(title.len, title_z.len - 1);
    @memcpy(title_z[0..tlen], title[0..tlen]);
    title_z[tlen] = 0;
    c.adw_preferences_row_set_title(@as(*c.AdwPreferencesRow, @ptrCast(row)), &title_z);

    // Subtitle: combine subtitle and body
    const sub = notif.getSubtitle();
    const body = notif.getBody();
    if (sub.len > 0 or body.len > 0) {
        var sub_z: [770]u8 = undefined; // 256 subtitle + \n + 512 body + null
        var spos: usize = 0;
        if (sub.len > 0) {
            const slen = @min(sub.len, 256);
            @memcpy(sub_z[spos..][0..slen], sub[0..slen]);
            spos += slen;
        }
        if (sub.len > 0 and body.len > 0) {
            sub_z[spos] = '\n';
            spos += 1;
        }
        if (body.len > 0) {
            const blen = @min(body.len, 512);
            @memcpy(sub_z[spos..][0..blen], body[0..blen]);
            spos += blen;
        }
        sub_z[spos] = 0;
        c.adw_action_row_set_subtitle(action_row, &sub_z);
    }
    c.adw_action_row_set_subtitle_lines(action_row, 3);

    // Prefix: unread indicator dot
    if (!notif.read) {
        const dot = c.gtk_label_new("\xe2\x97\x8f"); // ●
        c.gtk_widget_add_css_class(dot, "notif-unread-dot");
        c.gtk_widget_set_valign(dot, c.GTK_ALIGN_CENTER);
        c.adw_action_row_add_prefix(action_row, dot);
    }

    // Suffix: timestamp
    var time_buf: [32]u8 = undefined;
    const time_str = formatRelativeTime(now - notif.timestamp, &time_buf);
    const time_label = c.gtk_label_new(time_str.ptr);
    c.gtk_widget_add_css_class(time_label, "notif-time");
    c.gtk_widget_set_valign(time_label, c.GTK_ALIGN_CENTER);
    c.adw_action_row_add_suffix(action_row, time_label);

    // Suffix: dismiss button
    const dismiss_btn = c.gtk_button_new_from_icon_name("window-close-symbolic");
    c.gtk_widget_add_css_class(@ptrCast(dismiss_btn), "flat");
    c.gtk_widget_add_css_class(@ptrCast(dismiss_btn), "notif-dismiss-btn");
    c.gtk_widget_set_valign(@ptrCast(dismiss_btn), c.GTK_ALIGN_CENTER);
    c.gtk_widget_set_focusable(@ptrCast(dismiss_btn), 0);
    c.adw_action_row_add_suffix(action_row, @ptrCast(dismiss_btn));

    // Store the panel pointer on the button for the dismiss handler
    c.g_object_set_data(@as(*c.GObject, @ptrCast(dismiss_btn)), "panel", @ptrCast(panel));
    _ = c.g_signal_connect_data(
        @as(c.gpointer, @ptrCast(dismiss_btn)),
        "clicked",
        @as(c.GCallback, @ptrCast(&onDismissClicked)),
        null,
        null,
        0,
    );

    // Ensure the row is activatable so row-activated fires on the list box
    c.gtk_list_box_row_set_activatable(@as(*c.GtkListBoxRow, @ptrCast(row)), 1);

    return @as(*c.GtkWidget, @ptrCast(row));
}

fn formatRelativeTime(diff_secs: i64, buf: []u8) [:0]const u8 {
    const diff: u64 = if (diff_secs < 0) 0 else @intCast(diff_secs);
    if (diff < 60) {
        return std.fmt.bufPrintZ(buf, "now", .{}) catch "now";
    } else if (diff < 3600) {
        const mins = diff / 60;
        return std.fmt.bufPrintZ(buf, "{d}m ago", .{mins}) catch "?";
    } else if (diff < 86400) {
        const hours = diff / 3600;
        return std.fmt.bufPrintZ(buf, "{d}h ago", .{hours}) catch "?";
    } else {
        const days = diff / 86400;
        return std.fmt.bufPrintZ(buf, "{d}d ago", .{days}) catch "?";
    }
}

fn onClearAllClicked(_: *c.GtkButton, data: c.gpointer) callconv(.c) void {
    const self: *NotificationPanel = @ptrCast(@alignCast(data));
    self.center.store.clearAll();
    self.refresh();
}

fn onDismissClicked(btn: *c.GtkButton, _: c.gpointer) callconv(.c) void {
    // Walk up from the button to find the GtkListBoxRow ancestor.
    // AdwActionRow internal hierarchy varies, so walk until we hit a list-box row.
    var widget: ?*c.GtkWidget = @ptrCast(btn);
    while (widget != null) {
        widget = c.gtk_widget_get_parent(widget.?);
        if (widget != null and c.g_type_check_instance_is_a(
            @ptrCast(widget.?),
            c.gtk_list_box_row_get_type(),
        ) != 0) break;
    }
    const row_widget = widget orelse return;
    const row: *c.GtkListBoxRow = @ptrCast(@alignCast(row_widget));
    const index: usize = @intCast(c.gtk_list_box_row_get_index(row));

    // Get panel from the button's data
    const panel_ptr = c.g_object_get_data(@as(*c.GObject, @ptrCast(btn)), "panel");
    if (panel_ptr == null) return;
    const panel: *NotificationPanel = @ptrCast(@alignCast(panel_ptr));

    panel.center.store.removeAt(index);
    panel.refresh();
}

fn onRowActivated(
    _: *c.GtkListBox,
    row: ?*c.GtkListBoxRow,
    data: c.gpointer,
) callconv(.c) void {
    const self: *NotificationPanel = @ptrCast(@alignCast(data));
    const r = row orelse return;
    const index: usize = @intCast(c.gtk_list_box_row_get_index(r));

    const notif = self.center.store.getByIndex(index) orelse return;

    // Save navigation target before removing the notification
    const ws_id = notif.workspace_id;
    const pg_id = notif.pane_group_id;
    const p_id = notif.pane_id;

    // Remove only the clicked notification
    self.center.store.removeAt(index);

    // Suppress the blanket clearForPane that pane.focus() would trigger,
    // so remaining notifications for this pane are preserved.
    self.center.suppress_focus_clear = true;
    defer self.center.suppress_focus_clear = false;

    // Navigate to source
    if (self.on_jump) |jump| {
        jump(ws_id, pg_id, p_id);
    }

    self.dismissPopover();
    self.refresh();
}
