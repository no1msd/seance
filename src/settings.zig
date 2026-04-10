const std = @import("std");
const c = @import("c.zig").c;
const config_mod = @import("config.zig");
const ghostty_bridge = @import("ghostty_bridge.zig");
const keybinds = @import("keybinds.zig");
const WindowManager = @import("window_manager.zig").WindowManager;

// ---------------------------------------------------------------------------
// Module state (singleton)
// ---------------------------------------------------------------------------

var win: ?*c.GtkWidget = null;
var wm_ref: ?*WindowManager = null;
var updating: bool = false; // guard against recursive signal firing

// Keyboard shortcut recording state
var recording_action: ?keybinds.Action = null;
var recording_button: ?*c.GtkWidget = null;
var key_ctrl_ref: ?*c.GtkEventController = null;
var dialog_widget_ref: ?*c.GtkWidget = null;
var shortcut_buttons: [keybinds.Action.count]?*c.GtkWidget = [_]?*c.GtkWidget{null} ** keybinds.Action.count;

// Widget references for change callbacks
var w: Widgets = .{};

const Widgets = struct {
    // Switches
    desktop_notifications: ?*c.GtkWidget = null,
    bell_notification: ?*c.GtkWidget = null,
    confirm_close_window: ?*c.GtkWidget = null,
    focus_follows_mouse: ?*c.GtkWidget = null,
    show_notification_text: ?*c.GtkWidget = null,
    show_status: ?*c.GtkWidget = null,
    show_logs: ?*c.GtkWidget = null,
    show_progress: ?*c.GtkWidget = null,
    show_branch: ?*c.GtkWidget = null,
    show_ports: ?*c.GtkWidget = null,
    cursor_blink: ?*c.GtkWidget = null,
    dim_unfocused_panes: ?*c.GtkWidget = null,
    claude_code_hooks: ?*c.GtkWidget = null,
    codex_hooks: ?*c.GtkWidget = null,
    pi_hooks: ?*c.GtkWidget = null,

    // Combos
    notification_sound: ?*c.GtkWidget = null,
    sidebar_position: ?*c.GtkWidget = null,
    cursor_shape: ?*c.GtkWidget = null,
    theme: ?*c.GtkWidget = null,
    decoration_mode: ?*c.GtkWidget = null,

    // Entries
    socket_path: ?*c.GtkWidget = null,

    // Spins
    font_size: ?*c.GtkWidget = null,
    scrollback_lines: ?*c.GtkWidget = null,
    port_base: ?*c.GtkWidget = null,
    port_range: ?*c.GtkWidget = null,

    // Custom sound file entry (shown only when "Custom File" selected)
    custom_sound_path: ?*c.GtkWidget = null,
    // Sound preview button
    sound_preview_btn: ?*c.GtkWidget = null,

    // Scale
    background_opacity: ?*c.GtkWidget = null,
    background_opacity_label: ?*c.GtkWidget = null,

};

// ---------------------------------------------------------------------------
// Public API
// ---------------------------------------------------------------------------

pub fn show(wm: *WindowManager) void {
    wm_ref = wm;
    if (win != null) return; // already open (modal)
    createWindow();
}

// ---------------------------------------------------------------------------
// Window creation
// ---------------------------------------------------------------------------

fn createWindow() void {
    const parent = if (wm_ref) |wm| (if (wm.active_window) |active| active.gtk_window else null) else null;
    if (parent == null) return;

    const cfg = config_mod.get();

    const window = c.adw_dialog_new();
    c.adw_dialog_set_title(@as(*c.AdwDialog, @ptrCast(window)), "Settings");
    c.adw_dialog_set_content_width(@as(*c.AdwDialog, @ptrCast(window)), 800);
    c.adw_dialog_set_content_height(@as(*c.AdwDialog, @ptrCast(window)), 680);

    // Header bar
    const header = c.adw_header_bar_new();

    // Toolbar view (flat top bar — gains separator on scroll)
    const toolbar_view = c.adw_toolbar_view_new();
    c.adw_toolbar_view_add_top_bar(@as(*c.AdwToolbarView, @ptrCast(toolbar_view)), @ptrCast(header));
    c.adw_toolbar_view_set_top_bar_style(@as(*c.AdwToolbarView, @ptrCast(toolbar_view)), c.ADW_TOOLBAR_FLAT);

    // Preferences page (handles scrolling and group spacing)
    const page = c.adw_preferences_page_new();

    // Build all sections
    updating = true;
    buildAppearanceSection(page, cfg);
    buildWindowSection(page, cfg);
    buildTerminalSection(page, cfg);
    buildNotificationsSection(page, cfg);
    buildIntegrationsSection(page, cfg);
    buildKeyboardSection(page, cfg);
    buildResetSection(page);
    updating = false;

    c.adw_toolbar_view_set_content(@as(*c.AdwToolbarView, @ptrCast(toolbar_view)), page);
    c.adw_dialog_set_child(@as(*c.AdwDialog, @ptrCast(window)), @ptrCast(toolbar_view));

    // Key controller for shortcut recording — attached to the dialog itself
    // with CAPTURE phase so we intercept keypresses before internal AdwDialog widgets.
    const key_ctrl = c.gtk_event_controller_key_new();
    c.gtk_event_controller_set_propagation_phase(@as(*c.GtkEventController, @ptrCast(key_ctrl)), c.GTK_PHASE_CAPTURE);
    _ = c.g_signal_connect_data(
        @as(c.gpointer, @ptrCast(key_ctrl)),
        "key-pressed",
        @as(c.GCallback, @ptrCast(&onSettingsKeyPress)),
        null,
        null,
        0,
    );
    c.gtk_widget_add_controller(@as(*c.GtkWidget, @ptrCast(window)), @as(*c.GtkEventController, @ptrCast(key_ctrl)));
    key_ctrl_ref = @as(*c.GtkEventController, @ptrCast(key_ctrl));
    dialog_widget_ref = @as(*c.GtkWidget, @ptrCast(window));

    // Closed signal
    _ = c.g_signal_connect_data(
        @as(c.gpointer, @ptrCast(window)),
        "closed",
        @as(c.GCallback, @ptrCast(&onDialogClosed)),
        null,
        null,
        0,
    );

    win = @as(*c.GtkWidget, @ptrCast(window));
    c.adw_dialog_present(@as(*c.AdwDialog, @ptrCast(window)), parent.?);
}

// ---------------------------------------------------------------------------
// Section: Appearance
// ---------------------------------------------------------------------------

fn buildAppearanceSection(page: *c.GtkWidget, cfg: *const config_mod.Config) void {
    const g1 = newGroup("Appearance");
    {
        const row = c.adw_combo_row_new();
        c.adw_preferences_row_set_title(@as(*c.AdwPreferencesRow, @ptrCast(row)), "Theme");
        c.adw_combo_row_set_enable_search(@as(*c.AdwComboRow, @ptrCast(row)), 1);
        const expression = c.gtk_property_expression_new(c.gtk_string_object_get_type(), null, "string");
        c.adw_combo_row_set_expression(@as(*c.AdwComboRow, @ptrCast(row)), expression);

        const result = populateThemeModel(cfg);
        c.adw_combo_row_set_model(@as(*c.AdwComboRow, @ptrCast(row)), @as(*c.GListModel, @ptrCast(result.model)));
        c.adw_combo_row_set_selected(@as(*c.AdwComboRow, @ptrCast(row)), result.selected);
        c.adw_preferences_group_add(@as(*c.AdwPreferencesGroup, @ptrCast(g1)), @as(*c.GtkWidget, @ptrCast(row)));
        _ = c.g_signal_connect_data(@as(c.gpointer, @ptrCast(row)), "notify::selected", @as(c.GCallback, @ptrCast(&onComboChanged)), null, null, 0);
        w.theme = @as(*c.GtkWidget, @ptrCast(row));
    }
    {
        const row = c.adw_action_row_new();
        c.adw_preferences_row_set_title(@as(*c.AdwPreferencesRow, @ptrCast(row)), "Font Family");
        c.adw_action_row_set_subtitle(@as(*c.AdwActionRow, @ptrCast(row)), "Terminal font face. Must be a monospace font.");
        const btn = c.gtk_font_dialog_button_new(c.gtk_font_dialog_new());
        if (cfg.font_family_len > 0) {
            var desc_buf: [192]u8 = undefined;
            const desc_str = std.fmt.bufPrintZ(&desc_buf, "{s} {d}", .{ cfg.font_family[0..cfg.font_family_len], @as(u32, @intFromFloat(cfg.font_size orelse 11.0)) }) catch null;
            if (desc_str) |ds| {
                const desc = c.pango_font_description_from_string(ds.ptr);
                if (desc != null) {
                    c.gtk_font_dialog_button_set_font_desc(@as(*c.GtkFontDialogButton, @ptrCast(btn)), desc);
                    c.pango_font_description_free(desc);
                }
            }
        }
        c.gtk_widget_set_valign(@as(*c.GtkWidget, @ptrCast(btn)), c.GTK_ALIGN_CENTER);
        c.adw_action_row_add_suffix(@as(*c.AdwActionRow, @ptrCast(row)), @as(*c.GtkWidget, @ptrCast(btn)));
        c.adw_preferences_group_add(@as(*c.AdwPreferencesGroup, @ptrCast(g1)), @as(*c.GtkWidget, @ptrCast(row)));
        _ = c.g_signal_connect_data(@as(c.gpointer, @ptrCast(btn)), "notify::font-desc", @as(c.GCallback, @ptrCast(&onFontChanged)), null, null, 0);
    }
    w.font_size = addSpinRow(g1, "Font Size", "Font size in points.", 6.0, 72.0, 0.5, cfg.font_size orelse 11.0);
    {
        const row = c.adw_action_row_new();
        c.adw_preferences_row_set_title(@as(*c.AdwPreferencesRow, @ptrCast(row)), "Background Opacity");
        c.adw_action_row_set_subtitle(@as(*c.AdwActionRow, @ptrCast(row)), "Terminal background transparency. Requires a compositor.");
        const scale = c.gtk_scale_new_with_range(c.GTK_ORIENTATION_HORIZONTAL, 0.0, 1.0, 0.05);
        c.gtk_range_set_value(@as(*c.GtkRange, @ptrCast(scale)), cfg.background_opacity);
        c.gtk_widget_set_size_request(@as(*c.GtkWidget, @ptrCast(scale)), 200, -1);
        c.gtk_widget_set_valign(@as(*c.GtkWidget, @ptrCast(scale)), c.GTK_ALIGN_CENTER);
        c.adw_action_row_add_suffix(@as(*c.AdwActionRow, @ptrCast(row)), @as(*c.GtkWidget, @ptrCast(scale)));
        const opacity_label = c.gtk_label_new(null);
        var buf: [8]u8 = undefined;
        const label_text = std.fmt.bufPrintZ(&buf, "{d:.0}%", .{cfg.background_opacity * 100.0}) catch "?";
        c.gtk_label_set_text(@as(*c.GtkLabel, @ptrCast(opacity_label)), label_text.ptr);
        c.gtk_widget_set_size_request(@as(*c.GtkWidget, @ptrCast(opacity_label)), 40, -1);
        c.gtk_widget_set_valign(@as(*c.GtkWidget, @ptrCast(opacity_label)), c.GTK_ALIGN_CENTER);
        c.adw_action_row_add_suffix(@as(*c.AdwActionRow, @ptrCast(row)), @as(*c.GtkWidget, @ptrCast(opacity_label)));
        w.background_opacity_label = @as(*c.GtkWidget, @ptrCast(opacity_label));
        c.adw_preferences_group_add(@as(*c.AdwPreferencesGroup, @ptrCast(g1)), @as(*c.GtkWidget, @ptrCast(row)));
        w.background_opacity = @as(*c.GtkWidget, @ptrCast(scale));
        _ = c.g_signal_connect_data(@as(c.gpointer, @ptrCast(scale)), "value-changed", @as(c.GCallback, @ptrCast(&onScaleChanged)), null, null, 0);
    }
    w.cursor_shape = addComboRow(g1, "Cursor Shape", &.{ "Block", "I-Beam", "Underline" }, switch (cfg.cursor_shape) {
        .block => 0,
        .ibeam => 1,
        .underline => 2,
    });
    w.cursor_blink = addSwitchRow(g1, "Cursor Blink", "Animate the terminal cursor.", cfg.cursor_blink);
    w.dim_unfocused_panes = addSwitchRow(g1, "Dim Unfocused Panes", "Reduce opacity of unfocused terminal panes.", cfg.dim_unfocused_panes);
    addToPage(page, g1);
}

// ---------------------------------------------------------------------------
// Section: Window
// ---------------------------------------------------------------------------

fn buildWindowSection(page: *c.GtkWidget, cfg: *const config_mod.Config) void {
    const g1 = newGroup("Window");

    w.decoration_mode = addComboRow(g1, "Window Decorations", &.{ "Automatic", "Client-Side", "Server-Side" }, switch (cfg.decoration_mode) {
        .auto => 0,
        .csd => 1,
        .ssd => 2,
    });

    w.confirm_close_window = addSwitchRow(g1, "Confirm Closing Window", "Ask before closing a window with multiple workspaces.", cfg.confirm_close_window);
    w.sidebar_position = addComboRow(g1, "Sidebar Position", &.{ "Left", "Right" }, if (cfg.sidebar_position == .right) @as(u32, 1) else @as(u32, 0));
    addToPage(page, g1);

    // Sidebar detail visibility
    const g2 = newGroup(null);
    c.adw_preferences_group_set_description(@as(*c.AdwPreferencesGroup, @ptrCast(g2)), "Choose which details to display in the sidebar for each workspace.");
    w.show_notification_text = addSwitchRow(g2, "Notification Text", "Latest notification message.", cfg.sidebar_show_notification_text);
    w.show_status = addSwitchRow(g2, "Status Metadata", "Custom status entries from report_meta/set_status.", cfg.sidebar_show_status);
    w.show_logs = addSwitchRow(g2, "Log Entries", "Most recent log message.", cfg.sidebar_show_logs);
    w.show_progress = addSwitchRow(g2, "Progress Bar", "Active progress indicator.", cfg.sidebar_show_progress);
    w.show_branch = addSwitchRow(g2, "Git Branch + Directory", "Git branch and working-directory path.", cfg.sidebar_show_branch);
    w.show_ports = addSwitchRow(g2, "Listening Ports", "Detected listening ports for the workspace.", cfg.sidebar_show_ports);
    addToPage(page, g2);
}

// ---------------------------------------------------------------------------
// Section: Terminal
// ---------------------------------------------------------------------------

fn buildTerminalSection(page: *c.GtkWidget, cfg: *const config_mod.Config) void {
    const g1 = newGroup("Terminal");
    w.scrollback_lines = addSpinRow(g1, "Scrollback Lines", "Maximum number of lines kept in scrollback buffer per pane.", 0, 100000, 1000, @floatFromInt(cfg.scrollback_lines));
    w.focus_follows_mouse = addSwitchRow(g1, "Focus Follows Mouse", "Automatically focus the pane under the mouse cursor.", cfg.focus_follows_mouse);
    addToPage(page, g1);
}

// ---------------------------------------------------------------------------
// Theme model population
// ---------------------------------------------------------------------------

const ThemeModelResult = struct {
    model: *c.GtkStringList,
    selected: u32,
};

fn populateThemeModel(cfg: *const config_mod.Config) ThemeModelResult {
    const model = c.gtk_string_list_new(null);
    const string_list: *c.GtkStringList = @ptrCast(model);
    c.gtk_string_list_append(string_list, "(Default)");

    const current_theme = if (cfg.theme_len > 0) cfg.theme[0..cfg.theme_len] else "";
    var selected: u32 = 0;

    // Collect theme names from all sources, deduplicated.
    // Precedence (first seen wins): seance bundled > ghostty resources > user themes.
    const alloc = std.heap.c_allocator;
    var names: std.ArrayList([]const u8) = .empty;
    defer {
        for (names.items) |n| alloc.free(n);
        names.deinit(alloc);
    }
    var seen = std.StringHashMap(void).init(alloc);
    defer seen.deinit();

    // 1. Seance bundled themes
    collectThemesFromDir(ghostty_bridge.getSeanceThemesDir(), &names, &seen);

    // 2. Ghostty original themes (if at a different path)
    if (ghostty_bridge.getGhosttyOrigResourcesDir()) |orig| {
        var buf: [std.fs.max_path_bytes]u8 = undefined;
        if (std.fmt.bufPrint(&buf, "{s}/themes", .{orig})) |path| {
            collectThemesFromDir(path, &names, &seen);
        } else |_| {}
    }

    // 3. User themes (~/.config/ghostty/themes/)
    if (std.posix.getenv("HOME")) |home| {
        var buf: [std.fs.max_path_bytes]u8 = undefined;
        if (std.fmt.bufPrint(&buf, "{s}/.config/ghostty/themes", .{home})) |path| {
            collectThemesFromDir(path, &names, &seen);
        } else |_| {}
    }

    // Sort case-insensitively and populate the model
    std.mem.sortUnstable([]const u8, names.items, {}, struct {
        fn lt(_: void, a: []const u8, b: []const u8) bool {
            return std.ascii.orderIgnoreCase(a, b) == .lt;
        }
    }.lt);

    var index: u32 = 1; // 0 is "(Default)"
    for (names.items) |name| {
        var name_buf: [256]u8 = undefined;
        if (name.len >= name_buf.len) continue;
        @memcpy(name_buf[0..name.len], name);
        name_buf[name.len] = 0;
        c.gtk_string_list_append(string_list, @ptrCast(&name_buf));

        if (current_theme.len > 0 and std.mem.eql(u8, name, current_theme)) {
            selected = index;
        }
        index += 1;
    }

    return .{ .model = string_list, .selected = selected };
}

fn collectThemesFromDir(
    dir_path: ?[]const u8,
    names: *std.ArrayList([]const u8),
    seen: *std.StringHashMap(void),
) void {
    const path = dir_path orelse return;
    var dir = std.fs.openDirAbsolute(path, .{ .iterate = true }) catch return;
    defer dir.close();
    var it = dir.iterate();
    while (it.next() catch null) |entry| {
        if (entry.kind == .directory) continue;
        if (entry.name.len == 0 or entry.name[0] == '.') continue;
        if (seen.contains(entry.name)) continue;
        const alloc = std.heap.c_allocator;
        const duped = alloc.dupe(u8, entry.name) catch continue;
        seen.put(duped, {}) catch {
            alloc.free(duped);
            continue;
        };
        names.append(alloc, duped) catch continue;
    }
}

// ---------------------------------------------------------------------------
// Section: Notifications
// ---------------------------------------------------------------------------

fn buildNotificationsSection(page: *c.GtkWidget, cfg: *const config_mod.Config) void {
    const g1 = newGroup("Notifications");
    w.desktop_notifications = addSwitchRow(g1, "Desktop Notifications", "Send desktop notifications via libnotify when terminal bells or OSC notifications arrive.", cfg.desktop_notifications);
    w.bell_notification = addSwitchRow(g1, "Bell Notification", "Treat terminal bell (BEL) as a notification.", cfg.bell_notification);

    w.notification_sound = addComboRow(g1, "Notification Sound", &.{ "Default", "None", "Bell", "Dialog Warning", "Complete", "Custom File" }, switch (cfg.notification_sound) {
        .default => 0,
        .none => 1,
        .bell => 2,
        .dialog_warning => 3,
        .complete => 4,
        .custom => 5,
    });

    w.custom_sound_path = addEntryRow(g1, "Custom Sound File", "/path/to/sound.ogg", switch (cfg.notification_sound) {
        .custom => |cs| cs.path[0..cs.path_len],
        else => "",
    });
    c.gtk_widget_set_visible(w.custom_sound_path.?, if (cfg.notification_sound == .custom) 1 else 0);

    // Browse button suffix on the custom sound entry row
    {
        const browse_btn = c.gtk_button_new_from_icon_name("document-open-symbolic");
        c.gtk_widget_set_tooltip_text(@ptrCast(browse_btn), "Choose a sound file");
        c.gtk_widget_set_valign(@ptrCast(browse_btn), c.GTK_ALIGN_CENTER);
        c.gtk_widget_add_css_class(@ptrCast(browse_btn), "flat");
        c.adw_entry_row_add_suffix(@as(*c.AdwEntryRow, @ptrCast(w.custom_sound_path.?)), @ptrCast(browse_btn));
        _ = c.g_signal_connect_data(@as(c.gpointer, @ptrCast(browse_btn)), "clicked", @as(c.GCallback, @ptrCast(&onCustomSoundBrowseClicked)), null, null, 0);
    }

    // Sound preview button
    {
        const preview_row = c.adw_action_row_new();
        c.adw_preferences_row_set_title(@as(*c.AdwPreferencesRow, @ptrCast(preview_row)), "Preview Sound");
        const preview_btn = c.gtk_button_new_from_icon_name("audio-speakers-symbolic");
        c.gtk_widget_set_tooltip_text(@ptrCast(preview_btn), "Play selected sound");
        c.gtk_widget_set_valign(@ptrCast(preview_btn), c.GTK_ALIGN_CENTER);
        c.adw_action_row_add_suffix(@as(*c.AdwActionRow, @ptrCast(preview_row)), @ptrCast(preview_btn));
        c.adw_action_row_set_activatable_widget(@as(*c.AdwActionRow, @ptrCast(preview_row)), @ptrCast(preview_btn));
        c.adw_preferences_group_add(@as(*c.AdwPreferencesGroup, @ptrCast(g1)), @as(*c.GtkWidget, @ptrCast(preview_row)));
        w.sound_preview_btn = @ptrCast(preview_btn);
        _ = c.g_signal_connect_data(@as(c.gpointer, @ptrCast(preview_btn)), "clicked", @as(c.GCallback, @ptrCast(&onSoundPreviewClicked)), null, null, 0);
    }

    // Send Test Notification button
    {
        const test_row = c.adw_action_row_new();
        c.adw_preferences_row_set_title(@as(*c.AdwPreferencesRow, @ptrCast(test_row)), "Send Test Notification");
        c.adw_action_row_set_subtitle(@as(*c.AdwActionRow, @ptrCast(test_row)), "Exercises the full notification pipeline.");
        const test_btn = c.gtk_button_new_from_icon_name("notifications-symbolic");
        c.gtk_widget_set_tooltip_text(@ptrCast(test_btn), "Send a test notification");
        c.gtk_widget_set_valign(@ptrCast(test_btn), c.GTK_ALIGN_CENTER);
        c.adw_action_row_add_suffix(@as(*c.AdwActionRow, @ptrCast(test_row)), @ptrCast(test_btn));
        c.adw_action_row_set_activatable_widget(@as(*c.AdwActionRow, @ptrCast(test_row)), @ptrCast(test_btn));
        c.adw_preferences_group_add(@as(*c.AdwPreferencesGroup, @ptrCast(g1)), @as(*c.GtkWidget, @ptrCast(test_row)));
        _ = c.g_signal_connect_data(@as(c.gpointer, @ptrCast(test_btn)), "clicked", @as(c.GCallback, @ptrCast(&onTestNotificationClicked)), null, null, 0);
    }

    addToPage(page, g1);
}

// ---------------------------------------------------------------------------
// Section: Integrations
// ---------------------------------------------------------------------------

fn buildIntegrationsSection(page: *c.GtkWidget, cfg: *const config_mod.Config) void {
    // Card 1: Socket Configuration
    const g1 = newGroup("Integrations");
    c.adw_preferences_group_set_description(@as(*c.AdwPreferencesGroup, @ptrCast(g1)), "The socket allows external tools (e.g. seance notify) to send commands to seance. Created on startup if the path is set.");
    w.socket_path = addEntryRow(g1, "Socket Path", "~/.seance/seance.sock", cfg.socket_path[0..cfg.socket_path_len]);
    addToPage(page, g1);

    // Card 2: Claude Code Integration
    const g2 = newGroup(null);
    c.adw_preferences_group_set_description(@as(*c.AdwPreferencesGroup, @ptrCast(g2)), "When enabled, seance wraps the claude command to inject session tracking and notification hooks.");
    w.claude_code_hooks = addSwitchRow(g2, "Claude Code Integration", if (cfg.claude_code_hooks) "Sidebar shows Claude session status and notifications." else "Claude Code runs without seance integration.", cfg.claude_code_hooks);
    w.codex_hooks = addSwitchRow(g2, "Codex Integration", if (cfg.codex_hooks) "Sidebar shows Codex session status and notifications." else "Codex runs without seance integration.", cfg.codex_hooks);
    w.pi_hooks = addSwitchRow(g2, "Pi Agent Integration", if (cfg.pi_hooks) "Sidebar shows Pi session status and notifications." else "Pi runs without seance integration.", cfg.pi_hooks);
    addToPage(page, g2);

    // Card 3: Port Configuration
    const g3 = newGroup(null);
    c.adw_preferences_group_set_description(@as(*c.AdwPreferencesGroup, @ptrCast(g3)), "Each workspace gets SEANCE_PORT and SEANCE_PORT_END env vars with a dedicated port range.");
    w.port_base = addSpinRow(g3, "Port Base", "Starting port for SEANCE_PORT env var.", 1024, 65535, 1, @floatFromInt(cfg.port_base));
    w.port_range = addSpinRow(g3, "Port Range Size", "Number of ports per workspace.", 1, 100, 1, @floatFromInt(cfg.port_range));
    addToPage(page, g3);
}

// ---------------------------------------------------------------------------
// Section: Keyboard Shortcuts
// ---------------------------------------------------------------------------

const ShortcutDef = struct {
    action: keybinds.Action,
    label: [*:0]const u8,
};

const shortcut_defs = [_]ShortcutDef{
    .{ .action = .prev_workspace, .label = "Previous Workspace" },
    .{ .action = .next_workspace, .label = "Next Workspace" },
    .{ .action = .last_workspace, .label = "Last Workspace" },
    .{ .action = .new_workspace, .label = "New Workspace" },
    .{ .action = .close_workspace, .label = "Close Workspace" },
    .{ .action = .workspace_switcher, .label = "Workspace Switcher" },
    .{ .action = .workspace_1, .label = "Workspace 1" },
    .{ .action = .workspace_2, .label = "Workspace 2" },
    .{ .action = .workspace_3, .label = "Workspace 3" },
    .{ .action = .workspace_4, .label = "Workspace 4" },
    .{ .action = .workspace_5, .label = "Workspace 5" },
    .{ .action = .workspace_6, .label = "Workspace 6" },
    .{ .action = .workspace_7, .label = "Workspace 7" },
    .{ .action = .workspace_8, .label = "Workspace 8" },
    .{ .action = .workspace_9, .label = "Workspace 9" },
    .{ .action = .new_tab, .label = "New Tab" },
    .{ .action = .close_tab, .label = "Close Tab" },
    .{ .action = .next_tab, .label = "Next Tab" },
    .{ .action = .prev_tab, .label = "Previous Tab" },
    .{ .action = .tab_1, .label = "Tab 1" },
    .{ .action = .tab_2, .label = "Tab 2" },
    .{ .action = .tab_3, .label = "Tab 3" },
    .{ .action = .tab_4, .label = "Tab 4" },
    .{ .action = .tab_5, .label = "Tab 5" },
    .{ .action = .tab_6, .label = "Tab 6" },
    .{ .action = .tab_7, .label = "Tab 7" },
    .{ .action = .tab_8, .label = "Tab 8" },
    .{ .action = .tab_9, .label = "Tab 9" },
    .{ .action = .new_column, .label = "New Column" },
    .{ .action = .close_pane, .label = "Close Pane" },
    .{ .action = .focus_left, .label = "Focus Left" },
    .{ .action = .focus_right, .label = "Focus Right" },
    .{ .action = .focus_up, .label = "Focus Up" },
    .{ .action = .focus_down, .label = "Focus Down" },
    .{ .action = .last_pane, .label = "Last Pane" },
    .{ .action = .copy, .label = "Copy" },
    .{ .action = .paste, .label = "Paste" },
    .{ .action = .clear_scrollback, .label = "Clear Scrollback" },
    .{ .action = .find, .label = "Find" },
    .{ .action = .use_selection_for_find, .label = "Use Selection for Find" },
    .{ .action = .zoom_in, .label = "Zoom In" },
    .{ .action = .zoom_out, .label = "Zoom Out" },
    .{ .action = .zoom_reset, .label = "Reset Zoom" },
    .{ .action = .toggle_sidebar, .label = "Toggle Sidebar" },
    .{ .action = .toggle_notifications, .label = "Toggle Notifications" },
    .{ .action = .jump_to_unread, .label = "Jump to Unread" },
    .{ .action = .flash_focused, .label = "Flash Focused Pane" },
    .{ .action = .rename_workspace, .label = "Rename Workspace" },
    .{ .action = .toggle_pin, .label = "Toggle Pin" },
    .{ .action = .new_window, .label = "New Window" },
    .{ .action = .open_command_palette, .label = "Command Palette" },
    .{ .action = .open_folder, .label = "Open Folder" },
    .{ .action = .reload_config, .label = "Reload Config" },
    .{ .action = .open_settings, .label = "Open Settings" },
    .{ .action = .resize_wider, .label = "Resize Column Wider" },
    .{ .action = .resize_narrower, .label = "Resize Column Narrower" },
    .{ .action = .maximize_column, .label = "Maximize Column" },
    .{ .action = .switch_preset_column_width, .label = "Cycle Preset Column Width" },
    .{ .action = .resize_taller, .label = "Resize Row Taller" },
    .{ .action = .resize_shorter, .label = "Resize Row Shorter" },
    .{ .action = .show_shortcuts, .label = "Keyboard Shortcuts" },
};

fn buildKeyboardSection(page: *c.GtkWidget, _: *const config_mod.Config) void {
    // Shortcuts list
    const g1 = newGroup("Keyboard Shortcuts");
    c.adw_preferences_group_set_description(@as(*c.AdwPreferencesGroup, @ptrCast(g1)), "Click a shortcut value to record a new binding. Set to \xe2\x80\x98unset\xe2\x80\x99 in config to disable.");

    for (shortcut_defs) |def| {
        const row = c.adw_action_row_new();
        c.adw_preferences_row_set_title(@as(*c.AdwPreferencesRow, @ptrCast(row)), def.label);

        const hbox = c.gtk_box_new(c.GTK_ORIENTATION_HORIZONTAL, 4);
        c.gtk_widget_set_valign(hbox, c.GTK_ALIGN_CENTER);

        // Shortcut button
        var display_buf: [64]u8 = undefined;
        const dlen = keybinds.displayString(def.action, &display_buf);
        const label_text: [*:0]const u8 = if (dlen > 0) blk: {
            display_buf[dlen] = 0;
            break :blk @ptrCast(&display_buf);
        } else "unset";

        const btn = c.gtk_button_new_with_label(label_text);
        c.gtk_widget_add_css_class(@as(*c.GtkWidget, @ptrCast(btn)), "flat");
        c.gtk_widget_set_size_request(@as(*c.GtkWidget, @ptrCast(btn)), 160, -1);
        _ = c.g_signal_connect_data(@as(c.gpointer, @ptrCast(btn)), "clicked", @as(c.GCallback, @ptrCast(&onShortcutButtonClicked)), null, null, 0);
        shortcut_buttons[@intFromEnum(def.action)] = @as(*c.GtkWidget, @ptrCast(btn));

        // Clear button
        const clear_btn = c.gtk_button_new_from_icon_name("edit-clear-symbolic");
        c.gtk_widget_add_css_class(@as(*c.GtkWidget, @ptrCast(clear_btn)), "flat");
        c.gtk_widget_set_tooltip_text(@as(*c.GtkWidget, @ptrCast(clear_btn)), "Unbind");
        _ = c.g_signal_connect_data(@as(c.gpointer, @ptrCast(clear_btn)), "clicked", @as(c.GCallback, @ptrCast(&onClearShortcutClicked)), null, null, 0);

        c.gtk_box_append(@as(*c.GtkBox, @ptrCast(hbox)), @as(*c.GtkWidget, @ptrCast(btn)));
        c.gtk_box_append(@as(*c.GtkBox, @ptrCast(hbox)), @as(*c.GtkWidget, @ptrCast(clear_btn)));

        c.adw_action_row_add_suffix(@as(*c.AdwActionRow, @ptrCast(row)), hbox);
        c.adw_preferences_group_add(@as(*c.AdwPreferencesGroup, @ptrCast(g1)), @as(*c.GtkWidget, @ptrCast(row)));
    }

    addToPage(page, g1);
}

// ---------------------------------------------------------------------------
// Section: Reset
// ---------------------------------------------------------------------------

fn buildResetSection(page: *c.GtkWidget) void {
    const g1 = newGroup(null);
    {
        const row = c.adw_action_row_new();
        const btn = c.gtk_button_new_with_label("Reset All Settings");
        c.gtk_widget_add_css_class(@as(*c.GtkWidget, @ptrCast(btn)), "destructive-action");
        c.gtk_widget_set_halign(@as(*c.GtkWidget, @ptrCast(btn)), c.GTK_ALIGN_CENTER);
        c.gtk_widget_set_valign(@as(*c.GtkWidget, @ptrCast(btn)), c.GTK_ALIGN_CENTER);
        c.adw_action_row_add_suffix(@as(*c.AdwActionRow, @ptrCast(row)), @as(*c.GtkWidget, @ptrCast(btn)));
        c.adw_preferences_group_add(@as(*c.AdwPreferencesGroup, @ptrCast(g1)), @as(*c.GtkWidget, @ptrCast(row)));
        _ = c.g_signal_connect_data(@as(c.gpointer, @ptrCast(btn)), "clicked", @as(c.GCallback, @ptrCast(&onResetClicked)), null, null, 0);
    }

    addToPage(page, g1);
}

// ---------------------------------------------------------------------------
// Widget helpers
// ---------------------------------------------------------------------------

fn newGroup(title: ?[*:0]const u8) *c.GtkWidget {
    const g = c.adw_preferences_group_new();
    if (title) |t| c.adw_preferences_group_set_title(@as(*c.AdwPreferencesGroup, @ptrCast(g)), t);
    return @as(*c.GtkWidget, @ptrCast(g));
}

fn addSwitchRow(group: *c.GtkWidget, title: [*:0]const u8, subtitle: [*:0]const u8, active: bool) *c.GtkWidget {
    const row = c.adw_switch_row_new();
    c.adw_preferences_row_set_title(@as(*c.AdwPreferencesRow, @ptrCast(row)), title);
    c.adw_action_row_set_subtitle(@as(*c.AdwActionRow, @ptrCast(row)), subtitle);
    c.adw_switch_row_set_active(@as(*c.AdwSwitchRow, @ptrCast(row)), if (active) 1 else 0);
    c.adw_preferences_group_add(@as(*c.AdwPreferencesGroup, @ptrCast(group)), @as(*c.GtkWidget, @ptrCast(row)));
    _ = c.g_signal_connect_data(@as(c.gpointer, @ptrCast(row)), "notify::active", @as(c.GCallback, @ptrCast(&onSwitchChanged)), null, null, 0);
    return @as(*c.GtkWidget, @ptrCast(row));
}

fn addComboRow(group: *c.GtkWidget, title: [*:0]const u8, items: []const [*:0]const u8, selected: u32) *c.GtkWidget {
    const row = c.adw_combo_row_new();
    c.adw_preferences_row_set_title(@as(*c.AdwPreferencesRow, @ptrCast(row)), title);
    const model = c.gtk_string_list_new(null);
    for (items) |item| {
        c.gtk_string_list_append(@as(*c.GtkStringList, @ptrCast(model)), item);
    }
    c.adw_combo_row_set_model(@as(*c.AdwComboRow, @ptrCast(row)), @as(*c.GListModel, @ptrCast(model)));
    c.adw_combo_row_set_selected(@as(*c.AdwComboRow, @ptrCast(row)), selected);
    c.adw_preferences_group_add(@as(*c.AdwPreferencesGroup, @ptrCast(group)), @as(*c.GtkWidget, @ptrCast(row)));
    _ = c.g_signal_connect_data(@as(c.gpointer, @ptrCast(row)), "notify::selected", @as(c.GCallback, @ptrCast(&onComboChanged)), null, null, 0);
    return @as(*c.GtkWidget, @ptrCast(row));
}

fn addEntryRow(group: *c.GtkWidget, title: [*:0]const u8, placeholder: [*:0]const u8, value: []const u8) *c.GtkWidget {
    const row = c.adw_entry_row_new();
    c.adw_preferences_row_set_title(@as(*c.AdwPreferencesRow, @ptrCast(row)), title);
    // AdwEntryRow uses the title as the floating label. Set placeholder via subtitle hint.
    _ = c.g_object_set_data(@as(*c.GObject, @ptrCast(row)), "placeholder", @as(c.gpointer, @ptrCast(@constCast(placeholder))));
    // Set actual value
    if (value.len > 0) {
        var zbuf: [512]u8 = undefined;
        const n = @min(value.len, zbuf.len - 1);
        @memcpy(zbuf[0..n], value[0..n]);
        zbuf[n] = 0;
        c.gtk_editable_set_text(@as(*c.GtkEditable, @ptrCast(row)), @ptrCast(&zbuf));
    }
    c.adw_preferences_group_add(@as(*c.AdwPreferencesGroup, @ptrCast(group)), @as(*c.GtkWidget, @ptrCast(row)));
    _ = c.g_signal_connect_data(@as(c.gpointer, @ptrCast(row)), "changed", @as(c.GCallback, @ptrCast(&onEntryChanged)), null, null, 0);
    return @as(*c.GtkWidget, @ptrCast(row));
}

fn addSpinRow(group: *c.GtkWidget, title: [*:0]const u8, subtitle: [*:0]const u8, min: f64, max: f64, step: f64, value: f64) *c.GtkWidget {
    const row = c.adw_spin_row_new_with_range(min, max, step);
    c.adw_preferences_row_set_title(@as(*c.AdwPreferencesRow, @ptrCast(row)), title);
    c.adw_action_row_set_subtitle(@as(*c.AdwActionRow, @ptrCast(row)), subtitle);
    c.adw_spin_row_set_value(@as(*c.AdwSpinRow, @ptrCast(row)), value);
    c.adw_preferences_group_add(@as(*c.AdwPreferencesGroup, @ptrCast(group)), @as(*c.GtkWidget, @ptrCast(row)));
    _ = c.g_signal_connect_data(@as(c.gpointer, @ptrCast(row)), "notify::value", @as(c.GCallback, @ptrCast(&onSpinChanged)), null, null, 0);
    return @as(*c.GtkWidget, @ptrCast(row));
}

fn addToPage(page: *c.GtkWidget, group: *c.GtkWidget) void {
    c.adw_preferences_page_add(@as(*c.AdwPreferencesPage, @ptrCast(page)), @as(*c.AdwPreferencesGroup, @ptrCast(group)));
}

// ---------------------------------------------------------------------------
// Signal callbacks
// ---------------------------------------------------------------------------

fn onSwitchChanged(obj: *c.GObject, _: *c.GParamSpec, _: c.gpointer) callconv(.c) void {
    if (updating) return;
    const widget: *c.GtkWidget = @ptrCast(obj);
    const active = c.adw_switch_row_get_active(@as(*c.AdwSwitchRow, @ptrCast(widget))) != 0;
    const cfg = config_mod.getMut();

    if (widget == w.desktop_notifications) {
        cfg.desktop_notifications = active;
    } else if (widget == w.bell_notification) {
        cfg.bell_notification = active;
    } else if (widget == w.confirm_close_window) {
        cfg.confirm_close_window = active;
    } else if (widget == w.focus_follows_mouse) {
        cfg.focus_follows_mouse = active;
    } else if (widget == w.show_notification_text) {
        cfg.sidebar_show_notification_text = active;
    } else if (widget == w.show_status) {
        cfg.sidebar_show_status = active;
    } else if (widget == w.show_logs) {
        cfg.sidebar_show_logs = active;
    } else if (widget == w.show_progress) {
        cfg.sidebar_show_progress = active;
    } else if (widget == w.show_branch) {
        cfg.sidebar_show_branch = active;
    } else if (widget == w.show_ports) {
        cfg.sidebar_show_ports = active;
    } else if (widget == w.cursor_blink) {
        cfg.cursor_blink = active;
    } else if (widget == w.dim_unfocused_panes) {
        cfg.dim_unfocused_panes = active;
    } else if (widget == w.claude_code_hooks) {
        cfg.claude_code_hooks = active;
    } else if (widget == w.codex_hooks) {
        cfg.codex_hooks = active;
    } else if (widget == w.pi_hooks) {
        cfg.pi_hooks = active;
    } else return;

    saveAndReload();
}

fn onComboChanged(obj: *c.GObject, _: *c.GParamSpec, _: c.gpointer) callconv(.c) void {
    if (updating) return;
    const widget: *c.GtkWidget = @ptrCast(obj);
    const selected = c.adw_combo_row_get_selected(@as(*c.AdwComboRow, @ptrCast(widget)));
    const cfg = config_mod.getMut();

    if (widget == w.notification_sound) {
        cfg.notification_sound = switch (selected) {
            0 => .default,
            1 => .none,
            2 => .bell,
            3 => .dialog_warning,
            4 => .complete,
            5 => blk: {
                // Preserve existing custom path if switching back
                var cust: config_mod.NotificationSound = .{ .custom = .{} };
                if (w.custom_sound_path) |entry| {
                    const text_ptr: ?[*:0]const u8 = c.gtk_editable_get_text(@as(*c.GtkEditable, @ptrCast(entry)));
                    const text = if (text_ptr) |p| std.mem.sliceTo(p, 0) else "";
                    const n = @min(text.len, 256);
                    @memcpy(cust.custom.path[0..n], text[0..n]);
                    cust.custom.path_len = n;
                }
                break :blk cust;
            },
            else => .default,
        };
        // Show/hide custom sound path entry
        if (w.custom_sound_path) |entry| {
            c.gtk_widget_set_visible(entry, if (selected == 5) 1 else 0);
        }
    } else if (widget == w.sidebar_position) {
        cfg.sidebar_position = if (selected == 1) .right else .left;
    } else if (widget == w.cursor_shape) {
        cfg.cursor_shape = switch (selected) {
            0 => .block,
            1 => .ibeam,
            2 => .underline,
            else => .block,
        };
    } else if (widget == w.theme) {
        if (selected == 0) {
            cfg.theme_len = 0;
        } else {
            const item: ?*c.GObject = @ptrCast(@alignCast(c.adw_combo_row_get_selected_item(@as(*c.AdwComboRow, @ptrCast(widget)))));
            if (item) |obj_item| {
                const str: ?[*:0]const u8 = c.gtk_string_object_get_string(@as(*c.GtkStringObject, @ptrCast(@alignCast(obj_item))));
                if (str) |s| {
                    const name = std.mem.sliceTo(s, 0);
                    setStr(&cfg.theme, &cfg.theme_len, name);
                }
            }
        }
    } else if (widget == w.decoration_mode) {
        cfg.decoration_mode = switch (selected) {
            0 => .auto,
            1 => .csd,
            2 => .ssd,
            else => .auto,
        };
    } else return;

    saveAndReload();
}

fn onSpinChanged(obj: *c.GObject, _: *c.GParamSpec, _: c.gpointer) callconv(.c) void {
    if (updating) return;
    const widget: *c.GtkWidget = @ptrCast(obj);
    const cfg = config_mod.getMut();

    // AdwSpinRow
    const val = c.adw_spin_row_get_value(@as(*c.AdwSpinRow, @ptrCast(widget)));

    if (widget == w.font_size) {
        cfg.font_size = val;
    } else if (widget == w.scrollback_lines) {
        cfg.scrollback_lines = @intFromFloat(val);
    } else if (widget == w.port_base) {
        cfg.port_base = @intFromFloat(val);
    } else if (widget == w.port_range) {
        cfg.port_range = @intFromFloat(val);
    } else return;

    saveAndReload();
}

fn onScaleChanged(obj: *c.GtkRange, _: c.gpointer) callconv(.c) void {
    if (updating) return;
    const widget: *c.GtkWidget = @ptrCast(obj);
    const cfg = config_mod.getMut();

    if (widget == w.background_opacity) {
        cfg.background_opacity = c.gtk_range_get_value(obj);
        if (w.background_opacity_label) |label| {
            var buf: [8]u8 = undefined;
            const text = std.fmt.bufPrintZ(&buf, "{d:.0}%", .{cfg.background_opacity * 100.0}) catch "?";
            c.gtk_label_set_text(@as(*c.GtkLabel, @ptrCast(label)), text.ptr);
        }
        saveAndReload();
    }
}

fn onEntryChanged(obj: *c.GtkEditable, _: c.gpointer) callconv(.c) void {
    if (updating) return;
    const widget: *c.GtkWidget = @ptrCast(@alignCast(obj));
    const text_ptr: ?[*:0]const u8 = c.gtk_editable_get_text(obj);
    const text = if (text_ptr) |p| std.mem.sliceTo(p, 0) else "";
    const cfg = config_mod.getMut();

    if (widget == w.custom_sound_path) {
        // Update custom sound path in config
        var cust = config_mod.NotificationSound{ .custom = .{} };
        const n = @min(text.len, 256);
        @memcpy(cust.custom.path[0..n], text[0..n]);
        cust.custom.path_len = n;
        cfg.notification_sound = cust;
    } else if (widget == w.socket_path) {
        setStr(&cfg.socket_path, &cfg.socket_path_len, text);
    } else return;

    saveAndReload();
}

fn onFontChanged(obj: *c.GObject, _: *c.GParamSpec, _: c.gpointer) callconv(.c) void {
    if (updating) return;
    const btn: *c.GtkFontDialogButton = @ptrCast(@alignCast(obj));
    const desc: ?*const c.PangoFontDescription = c.gtk_font_dialog_button_get_font_desc(btn);
    if (desc) |d| {
        const family: ?[*:0]const u8 = c.pango_font_description_get_family(d);
        if (family) |f| {
            const cfg = config_mod.getMut();
            const name = std.mem.sliceTo(f, 0);
            setStr(&cfg.font_family, &cfg.font_family_len, name);

            const size_pango = c.pango_font_description_get_size(d);
            if (size_pango > 0) {
                const pt: f64 = @as(f64, @floatFromInt(size_pango)) / @as(f64, @floatFromInt(c.PANGO_SCALE));
                cfg.font_size = pt;
                // Update font size spin if present
                if (w.font_size) |spin| {
                    updating = true;
                    c.adw_spin_row_set_value(@as(*c.AdwSpinRow, @ptrCast(spin)), pt);
                    updating = false;
                }
            }

            saveAndReload();
        }
    }
}

// ---------------------------------------------------------------------------
// Keyboard shortcut recording
// ---------------------------------------------------------------------------

fn onShortcutButtonClicked(button: *c.GtkButton, _: c.gpointer) callconv(.c) void {
    const btn_widget: *c.GtkWidget = @ptrCast(button);

    // Find which action this button belongs to
    for (shortcut_defs) |def| {
        if (shortcut_buttons[@intFromEnum(def.action)] == btn_widget) {
            // Start recording
            recording_action = def.action;
            recording_button = btn_widget;
            keybinds.recording_shortcut = true;
            c.gtk_button_set_label(button, "Press shortcut...");
            return;
        }
    }
}

fn onClearShortcutClicked(button: *c.GtkButton, _: c.gpointer) callconv(.c) void {
    // Find the action by looking at the adjacent shortcut button
    // The clear button is the sibling of the shortcut button in the hbox
    const clear_widget: *c.GtkWidget = @ptrCast(button);
    const parent = c.gtk_widget_get_parent(clear_widget) orelse return;
    const first_child = c.gtk_widget_get_first_child(parent) orelse return;

    for (shortcut_defs) |def| {
        if (shortcut_buttons[@intFromEnum(def.action)] == first_child) {
            keybinds.setBinding(def.action, .{ .enabled = false });
            updateShortcutButtonLabel(def.action);
            saveAndReload();
            return;
        }
    }
}

fn onSettingsKeyPress(
    _: *c.GtkEventControllerKey,
    keyval: c.guint,
    _: c.guint,
    gdk_state: c.GdkModifierType,
    _: c.gpointer,
) callconv(.c) c.gboolean {
    if (recording_action == null) return 0;

    // Cancel on Escape
    if (keyval == c.GDK_KEY_Escape) {
        cancelRecording();
        return 1;
    }

    // Ignore pure modifier keypresses
    if (keyval == c.GDK_KEY_Control_L or keyval == c.GDK_KEY_Control_R or
        keyval == c.GDK_KEY_Shift_L or keyval == c.GDK_KEY_Shift_R or
        keyval == c.GDK_KEY_Alt_L or keyval == c.GDK_KEY_Alt_R or
        keyval == c.GDK_KEY_Super_L or keyval == c.GDK_KEY_Super_R)
        return 1;

    const is_ctrl = (gdk_state & c.GDK_CONTROL_MASK) != 0;
    const is_shift = (gdk_state & c.GDK_SHIFT_MASK) != 0;
    const is_alt = (gdk_state & c.GDK_ALT_MASK) != 0;

    // Allow function keys (F1-F12) without modifiers; require a modifier for everything else.
    const is_function_key = (keyval >= c.GDK_KEY_F1 and keyval <= c.GDK_KEY_F12);
    if (!is_ctrl and !is_shift and !is_alt and !is_function_key) {
        // Flash the button label so the user sees why it was rejected
        if (recording_button) |btn| {
            c.gtk_button_set_label(@as(*c.GtkButton, @ptrCast(btn)), "Need Ctrl/Shift/Alt...");
        }
        return 1;
    }

    const action = recording_action.?;
    const kb = keybinds.Keybind{
        .key = keyval,
        .ctrl = is_ctrl,
        .shift = is_shift,
        .alt = is_alt,
        .enabled = true,
    };
    keybinds.setBinding(action, kb);
    updateShortcutButtonLabel(action);

    recording_action = null;
    recording_button = null;
    keybinds.recording_shortcut = false;
    saveAndReload();
    return 1;
}

fn cancelRecording() void {
    if (recording_action) |action| {
        updateShortcutButtonLabel(action);
    }
    recording_action = null;
    recording_button = null;
    keybinds.recording_shortcut = false;
}

fn updateShortcutButtonLabel(action: keybinds.Action) void {
    const btn = shortcut_buttons[@intFromEnum(action)] orelse return;
    var display_buf: [64]u8 = undefined;
    const dlen = keybinds.displayString(action, &display_buf);
    if (dlen > 0) {
        display_buf[dlen] = 0;
        c.gtk_button_set_label(@as(*c.GtkButton, @ptrCast(btn)), @ptrCast(&display_buf));
    } else {
        c.gtk_button_set_label(@as(*c.GtkButton, @ptrCast(btn)), "unset");
    }
}

// ---------------------------------------------------------------------------
// Reset
// ---------------------------------------------------------------------------

fn onResetClicked(_: *c.GtkButton, _: c.gpointer) callconv(.c) void {
    // Show confirmation dialog
    const dialog = c.adw_alert_dialog_new("Reset all settings to defaults?", "This will restore every setting to its default value. Your config file will be overwritten.");
    c.adw_alert_dialog_add_response(@as(*c.AdwAlertDialog, @ptrCast(dialog)), "cancel", "Cancel");
    c.adw_alert_dialog_add_response(@as(*c.AdwAlertDialog, @ptrCast(dialog)), "reset", "Reset All");
    c.adw_alert_dialog_set_response_appearance(@as(*c.AdwAlertDialog, @ptrCast(dialog)), "reset", c.ADW_RESPONSE_DESTRUCTIVE);
    c.adw_alert_dialog_set_default_response(@as(*c.AdwAlertDialog, @ptrCast(dialog)), "cancel");
    c.adw_alert_dialog_set_close_response(@as(*c.AdwAlertDialog, @ptrCast(dialog)), "cancel");

    _ = c.g_signal_connect_data(@as(c.gpointer, @ptrCast(dialog)), "response", @as(c.GCallback, @ptrCast(&onResetResponse)), null, null, 0);

    if (win) |window| {
        c.adw_dialog_present(@as(*c.AdwDialog, @ptrCast(dialog)), window);
    }
}

fn onResetResponse(_: *c.AdwAlertDialog, response: [*:0]const u8, _: c.gpointer) callconv(.c) void {
    if (!std.mem.eql(u8, std.mem.sliceTo(response, 0), "reset")) return;

    // Reset config to defaults
    const cfg = config_mod.getMut();
    cfg.* = config_mod.Config{};

    // Reset keybinds
    keybinds.resetToDefaults();

    // Save and reload
    config_mod.saveConfig(cfg);
    if (wm_ref) |wm| wm.reloadAllConfigs(true);

    // Close settings and reopen to refresh all widgets
    if (win) |window| {
        c.adw_dialog_force_close(@as(*c.AdwDialog, @ptrCast(window)));
    }
}

// ---------------------------------------------------------------------------
// Window lifecycle
// ---------------------------------------------------------------------------

fn onSoundPreviewClicked(_: *c.GtkButton, _: c.gpointer) callconv(.c) void {
    const wm = wm_ref orelse return;
    const state = wm.active_window orelse return;
    const cfg = config_mod.get();
    state.sound_player.playPreview(cfg.notification_sound);
}

fn onCustomSoundBrowseClicked(_: *c.GtkButton, _: c.gpointer) callconv(.c) void {
    const dialog = c.gtk_file_chooser_dialog_new(
        "Choose Sound File",
        if (win) |w_ptr| @as(?*c.GtkWindow, @ptrCast(w_ptr)) else null,
        c.GTK_FILE_CHOOSER_ACTION_OPEN,
        "Cancel",
        @as(c_int, c.GTK_RESPONSE_CANCEL),
        "Open",
        @as(c_int, c.GTK_RESPONSE_ACCEPT),
        @as(?*anyopaque, null),
    );

    // Filter to common audio formats
    const filter = c.gtk_file_filter_new();
    c.gtk_file_filter_set_name(filter, "Audio Files");
    c.gtk_file_filter_add_pattern(filter, "*.wav");
    c.gtk_file_filter_add_pattern(filter, "*.ogg");
    c.gtk_file_filter_add_pattern(filter, "*.oga");
    c.gtk_file_filter_add_pattern(filter, "*.flac");
    c.gtk_file_filter_add_pattern(filter, "*.mp3");
    c.gtk_file_chooser_add_filter(@as(*c.GtkFileChooser, @ptrCast(dialog)), filter);

    // Pre-seed with the current path if any
    const cfg = config_mod.get();
    if (cfg.notification_sound == .custom) {
        const cs = cfg.notification_sound.custom;
        if (cs.path_len > 0) {
            var z: [257]u8 = undefined;
            const n = @min(cs.path_len, z.len - 1);
            @memcpy(z[0..n], cs.path[0..n]);
            z[n] = 0;
            const gfile = c.g_file_new_for_path(@ptrCast(&z));
            if (gfile != null) {
                _ = c.gtk_file_chooser_set_file(@as(*c.GtkFileChooser, @ptrCast(dialog)), gfile, null);
                c.g_object_unref(@ptrCast(gfile));
            }
        }
    }

    _ = c.g_signal_connect_data(
        @as(c.gpointer, @ptrCast(dialog)),
        "response",
        @as(c.GCallback, @ptrCast(&onCustomSoundChosen)),
        null,
        null,
        0,
    );

    c.gtk_widget_set_visible(@as(*c.GtkWidget, @ptrCast(dialog)), 1);
}

fn onCustomSoundChosen(dialog: *c.GtkDialog, response_id: c_int, _: c.gpointer) callconv(.c) void {
    if (response_id == c.GTK_RESPONSE_ACCEPT) {
        const chooser: *c.GtkFileChooser = @ptrCast(@alignCast(dialog));
        const gfile: ?*c.GFile = c.gtk_file_chooser_get_file(chooser);
        if (gfile) |f| {
            const path_z: ?[*:0]const u8 = c.g_file_get_path(f);
            if (path_z) |p| {
                if (w.custom_sound_path) |entry| {
                    c.gtk_editable_set_text(@as(*c.GtkEditable, @ptrCast(entry)), p);
                }
                c.g_free(@ptrCast(@constCast(p)));
            }
            c.g_object_unref(@ptrCast(f));
        }
    }
    c.gtk_window_destroy(@as(*c.GtkWindow, @ptrCast(@alignCast(dialog))));
}

fn onTestNotificationClicked(_: *c.GtkButton, _: c.gpointer) callconv(.c) void {
    const wm = wm_ref orelse return;
    const state = wm.active_window orelse return;

    const ws = state.activeWorkspace();
    const ws_id = if (ws) |w2| w2.id else 0;
    const pane_id: u64 = if (ws) |w2| blk: {
        if (w2.focusedGroup()) |fg| {
            if (fg.focusedTerminalPane()) |fp| break :blk fp.id;
        }
        break :blk 0;
    } else 0;

    // Use emit() but skip visibility check (test should always fire)
    // and skip sound (we play preview sound separately below)
    state.notif_center.emit(.{
        .title = "seance",
        .body = "This is a test notification.",
        .pane_id = pane_id,
        .workspace_id = ws_id,
        .check_visibility = false,
        .play_sound = false,
        .flash = false,
    });

    // Play configured sound preview (bypasses suppression)
    const cfg = config_mod.get();
    state.sound_player.playPreview(cfg.notification_sound);
}

fn onDialogClosed(_: *c.AdwDialog, _: c.gpointer) callconv(.c) void {
    // Remove key controller from dialog widget (it owns the controller, so this frees it)
    if (key_ctrl_ref) |ctrl| {
        if (dialog_widget_ref) |dw| {
            c.gtk_widget_remove_controller(dw, ctrl);
        }
    }
    key_ctrl_ref = null;
    dialog_widget_ref = null;
    win = null;
    recording_action = null;
    recording_button = null;
    keybinds.recording_shortcut = false;
    w = .{};
    shortcut_buttons = [_]?*c.GtkWidget{null} ** keybinds.Action.count;
}

// ---------------------------------------------------------------------------
// Helpers
// ---------------------------------------------------------------------------

fn saveAndReload() void {
    config_mod.saveConfig(config_mod.get());
    if (wm_ref) |wm| wm.reloadAllConfigs(true);
}

fn setStr(buf: []u8, len: *usize, val: []const u8) void {
    const n = @min(val.len, buf.len);
    @memcpy(buf[0..n], val[0..n]);
    len.* = n;
}
