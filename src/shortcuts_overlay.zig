const c = @import("c.zig").c;
const keybinds = @import("keybinds.zig");
const WindowManager = @import("window_manager.zig").WindowManager;

// ---------------------------------------------------------------------------
// Module state (singleton)
// ---------------------------------------------------------------------------

var dialog: ?*c.GtkWidget = null;

// ---------------------------------------------------------------------------
// Shortcut group definitions
// ---------------------------------------------------------------------------

const Entry = struct {
    action: keybinds.Action,
    label: [*:0]const u8,
};

const RangeEntry = struct {
    first_action: keybinds.Action,
    label: [*:0]const u8,
    count: u8,
};

const Row = union(enum) {
    single: Entry,
    range: RangeEntry,
};

const Group = struct {
    title: [*:0]const u8,
    rows: []const Row,
};

const groups = [_]Group{
    .{
        .title = "Workspaces",
        .rows = &.{
            .{ .single = .{ .action = .prev_workspace, .label = "Previous Workspace" } },
            .{ .single = .{ .action = .next_workspace, .label = "Next Workspace" } },
            .{ .single = .{ .action = .last_workspace, .label = "Last Workspace" } },
            .{ .range = .{ .first_action = .workspace_1, .label = "Workspace 1\xe2\x80\x939", .count = 9 } },
            .{ .single = .{ .action = .new_workspace, .label = "New Workspace" } },
            .{ .single = .{ .action = .close_workspace, .label = "Close Workspace" } },
            .{ .single = .{ .action = .workspace_switcher, .label = "Workspace Switcher" } },
        },
    },
    .{
        .title = "Tabs",
        .rows = &.{
            .{ .single = .{ .action = .new_tab, .label = "New Tab" } },
            .{ .single = .{ .action = .close_tab, .label = "Close Tab" } },
            .{ .single = .{ .action = .next_tab, .label = "Next Tab" } },
            .{ .single = .{ .action = .prev_tab, .label = "Previous Tab" } },
            .{ .range = .{ .first_action = .tab_1, .label = "Tab 1\xe2\x80\x939", .count = 9 } },
            .{ .single = .{ .action = .close_other_tabs, .label = "Close Other Tabs" } },
            .{ .single = .{ .action = .rename_tab, .label = "Rename Tab" } },
        },
    },
    .{
        .title = "Panes",
        .rows = &.{
            .{ .single = .{ .action = .new_column, .label = "New Column" } },
            .{ .single = .{ .action = .close_pane, .label = "Close Pane" } },
            .{ .single = .{ .action = .focus_left, .label = "Focus Left" } },
            .{ .single = .{ .action = .focus_right, .label = "Focus Right" } },
            .{ .single = .{ .action = .focus_up, .label = "Focus Up" } },
            .{ .single = .{ .action = .focus_down, .label = "Focus Down" } },
            .{ .single = .{ .action = .last_pane, .label = "Last Pane" } },
        },
    },
    .{
        .title = "Terminal",
        .rows = &.{
            .{ .single = .{ .action = .copy, .label = "Copy" } },
            .{ .single = .{ .action = .paste, .label = "Paste" } },
            .{ .single = .{ .action = .find, .label = "Find" } },
            .{ .single = .{ .action = .use_selection_for_find, .label = "Use Selection for Find" } },
            .{ .single = .{ .action = .find_next, .label = "Find Next" } },
            .{ .single = .{ .action = .find_previous, .label = "Find Previous" } },
            .{ .single = .{ .action = .clear_scrollback, .label = "Clear Scrollback" } },
        },
    },
    .{
        .title = "Font",
        .rows = &.{
            .{ .single = .{ .action = .zoom_in, .label = "Zoom In" } },
            .{ .single = .{ .action = .zoom_out, .label = "Zoom Out" } },
            .{ .single = .{ .action = .zoom_reset, .label = "Reset Zoom" } },
        },
    },
    .{
        .title = "Layout & Resize",
        .rows = &.{
            .{ .single = .{ .action = .toggle_layout_mode, .label = "Toggle Layout Mode" } },
            .{ .single = .{ .action = .move_column_left, .label = "Move Column Left" } },
            .{ .single = .{ .action = .move_column_right, .label = "Move Column Right" } },
            .{ .single = .{ .action = .expel_left, .label = "Expel Left" } },
            .{ .single = .{ .action = .expel_right, .label = "Expel Right" } },
            .{ .single = .{ .action = .resize_wider, .label = "Resize Column Wider" } },
            .{ .single = .{ .action = .resize_narrower, .label = "Resize Column Narrower" } },
            .{ .single = .{ .action = .maximize_column, .label = "Maximize Column" } },
            .{ .single = .{ .action = .switch_preset_column_width, .label = "Cycle Preset Width" } },
            .{ .single = .{ .action = .resize_taller, .label = "Resize Row Taller" } },
            .{ .single = .{ .action = .resize_shorter, .label = "Resize Row Shorter" } },
        },
    },
    .{
        .title = "UI",
        .rows = &.{
            .{ .single = .{ .action = .toggle_sidebar, .label = "Toggle Sidebar" } },
            .{ .single = .{ .action = .toggle_notifications, .label = "Toggle Notifications" } },
            .{ .single = .{ .action = .jump_to_unread, .label = "Jump to Unread" } },
            .{ .single = .{ .action = .flash_focused, .label = "Flash Focused Pane" } },
            .{ .single = .{ .action = .rename_workspace, .label = "Rename Workspace" } },
            .{ .single = .{ .action = .toggle_pin, .label = "Toggle Pin" } },
        },
    },
    .{
        .title = "General",
        .rows = &.{
            .{ .single = .{ .action = .new_window, .label = "New Window" } },
            .{ .single = .{ .action = .open_command_palette, .label = "Command Palette" } },
            .{ .single = .{ .action = .open_folder, .label = "Open Folder" } },
            .{ .single = .{ .action = .open_settings, .label = "Settings" } },
            .{ .single = .{ .action = .reload_config, .label = "Reload Config" } },
            .{ .single = .{ .action = .show_shortcuts, .label = "Keyboard Shortcuts" } },
        },
    },
};

// ---------------------------------------------------------------------------
// Public API
// ---------------------------------------------------------------------------

pub fn show(wm: *WindowManager) void {
    if (dialog != null) return; // already open

    const parent = if (wm.active_window) |active| active.gtk_window else null;
    if (parent == null) return;

    const win = c.adw_dialog_new();
    c.adw_dialog_set_title(@as(*c.AdwDialog, @ptrCast(win)), "Keyboard Shortcuts");
    c.adw_dialog_set_content_width(@as(*c.AdwDialog, @ptrCast(win)), 900);
    c.adw_dialog_set_content_height(@as(*c.AdwDialog, @ptrCast(win)), 600);

    // Header bar
    const header = c.adw_header_bar_new();

    // Toolbar view (flat top bar)
    const toolbar_view = c.adw_toolbar_view_new();
    c.adw_toolbar_view_add_top_bar(@as(*c.AdwToolbarView, @ptrCast(toolbar_view)), @ptrCast(header));
    c.adw_toolbar_view_set_top_bar_style(@as(*c.AdwToolbarView, @ptrCast(toolbar_view)), c.ADW_TOOLBAR_FLAT);

    // Two-column layout inside a scrolled window
    const scroll = c.gtk_scrolled_window_new();
    c.gtk_scrolled_window_set_policy(@ptrCast(scroll), c.GTK_POLICY_NEVER, c.GTK_POLICY_AUTOMATIC);

    const hbox = c.gtk_box_new(c.GTK_ORIENTATION_HORIZONTAL, 24);
    c.gtk_widget_set_margin_start(hbox, 24);
    c.gtk_widget_set_margin_end(hbox, 24);
    c.gtk_widget_set_margin_top(hbox, 12);
    c.gtk_widget_set_margin_bottom(hbox, 24);

    const left_col = c.gtk_box_new(c.GTK_ORIENTATION_VERTICAL, 18);
    c.gtk_widget_set_hexpand(left_col, 1);
    const right_col = c.gtk_box_new(c.GTK_ORIENTATION_VERTICAL, 18);
    c.gtk_widget_set_hexpand(right_col, 1);

    // Split groups across two columns (first half left, second half right)
    const mid = groups.len / 2;
    for (groups[0..mid]) |*group| {
        buildGroup(left_col, group);
    }
    for (groups[mid..]) |*group| {
        buildGroup(right_col, group);
    }

    c.gtk_box_append(@ptrCast(hbox), left_col);
    c.gtk_box_append(@ptrCast(hbox), right_col);
    c.gtk_scrolled_window_set_child(@ptrCast(scroll), hbox);

    c.adw_toolbar_view_set_content(@as(*c.AdwToolbarView, @ptrCast(toolbar_view)), scroll);
    c.adw_dialog_set_child(@as(*c.AdwDialog, @ptrCast(win)), @ptrCast(toolbar_view));

    // Closed signal — reset singleton
    _ = c.g_signal_connect_data(
        @as(c.gpointer, @ptrCast(win)),
        "closed",
        @as(c.GCallback, @ptrCast(&onDialogClosed)),
        null,
        null,
        0,
    );

    dialog = @as(*c.GtkWidget, @ptrCast(win));
    c.adw_dialog_present(@as(*c.AdwDialog, @ptrCast(win)), parent.?);
}

// ---------------------------------------------------------------------------
// Internals
// ---------------------------------------------------------------------------

fn buildGroup(column: *c.GtkWidget, group: *const Group) void {
    const container = c.gtk_box_new(c.GTK_ORIENTATION_VERTICAL, 6);

    // Group title
    const title = c.gtk_label_new(group.title);
    c.gtk_label_set_xalign(@ptrCast(title), 0);
    c.gtk_widget_add_css_class(title, "title-4");
    c.gtk_box_append(@ptrCast(container), title);

    // Shortcut rows in a list box
    const list = c.gtk_list_box_new();
    c.gtk_list_box_set_selection_mode(@ptrCast(list), c.GTK_SELECTION_NONE);
    c.gtk_widget_add_css_class(list, "boxed-list");

    for (group.rows) |*row| {
        switch (row.*) {
            .single => |entry| addRow(list, entry.label, entry.action),
            .range => |range| addRangeRow(list, range),
        }
    }

    c.gtk_box_append(@ptrCast(container), list);
    c.gtk_box_append(@ptrCast(column), container);
}

fn addRow(list: *c.GtkWidget, label: [*:0]const u8, action: keybinds.Action) void {
    var buf: [64]u8 = undefined;
    const len = keybinds.displayString(action, &buf);
    buf[len] = 0;

    const row = c.adw_action_row_new();
    c.adw_preferences_row_set_title(@as(*c.AdwPreferencesRow, @ptrCast(row)), label);

    const text: [*:0]const u8 = if (len > 0) @ptrCast(buf[0..len :0]) else "unset";
    const shortcut_label = c.gtk_label_new(text);
    c.gtk_widget_add_css_class(shortcut_label, "dim-label");
    c.gtk_widget_set_valign(shortcut_label, c.GTK_ALIGN_CENTER);
    c.adw_action_row_add_suffix(@as(*c.AdwActionRow, @ptrCast(row)), shortcut_label);

    c.gtk_list_box_append(@ptrCast(list), row);
}

fn addRangeRow(list: *c.GtkWidget, range: RangeEntry) void {
    var buf: [64]u8 = undefined;
    const len = keybinds.displayString(range.first_action, &buf);

    // Build range display: e.g. "Alt+1" -> "Alt+1\xe2\x80\x939"
    var display_buf: [80]u8 = undefined;
    var display_len: usize = 0;

    if (len > 0) {
        // Copy everything except the last character (the digit), then append "1-9"
        if (len >= 2) {
            @memcpy(display_buf[0 .. len - 1], buf[0 .. len - 1]);
            display_len = len - 1;
        }
        const suffix = "1\xe2\x80\x939"; // "1–9" with en-dash
        @memcpy(display_buf[display_len..][0..suffix.len], suffix);
        display_len += suffix.len;
    }

    const row = c.adw_action_row_new();
    c.adw_preferences_row_set_title(@as(*c.AdwPreferencesRow, @ptrCast(row)), range.label);

    const text: [*:0]const u8 = if (display_len > 0) blk: {
        display_buf[display_len] = 0;
        break :blk @ptrCast(display_buf[0..display_len :0]);
    } else "unset";

    const shortcut_label = c.gtk_label_new(text);
    c.gtk_widget_add_css_class(shortcut_label, "dim-label");
    c.gtk_widget_set_valign(shortcut_label, c.GTK_ALIGN_CENTER);
    c.adw_action_row_add_suffix(@as(*c.AdwActionRow, @ptrCast(row)), shortcut_label);

    c.gtk_list_box_append(@ptrCast(list), row);
}

fn onDialogClosed(_: *c.AdwDialog, _: c.gpointer) callconv(.c) void {
    dialog = null;
}
