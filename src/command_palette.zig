const std = @import("std");
const c = @import("c.zig").c;
const Window = @import("window.zig");
const keybinds = @import("keybinds.zig");

const Action = keybinds.Action;
const WindowState = Window.WindowState;

/// Palette operating mode.
const Mode = enum {
    commands,
    switcher,
    rename_workspace,
    rename_tab,
};

/// Context condition for command visibility / enablement.
const Condition = enum {
    always,
    workspace_exists,
    has_custom_workspace_name,
    has_splits,
    has_peers,
    has_workspace_above,
    has_workspace_below,
    has_tab_focus,
    has_custom_tab_name,
    has_multiple_tabs,
    has_unread_notifications,
    has_no_unread_notifications,
    has_tabs_to_right,
};

/// Evaluated context state (computed once per updateResults call).
const ContextState = struct {
    workspace_exists: bool = false,
    has_custom_workspace_name: bool = false,
    has_splits: bool = false,
    has_peers: bool = false,
    has_workspace_above: bool = false,
    has_workspace_below: bool = false,
    has_tab_focus: bool = false,
    has_custom_tab_name: bool = false,
    has_multiple_tabs: bool = false,
    has_unread_notifications: bool = false,
    has_no_unread_notifications: bool = false,
    has_tabs_to_right: bool = false,

    fn check(self: ContextState, cond: Condition) bool {
        return switch (cond) {
            .always => true,
            .workspace_exists => self.workspace_exists,
            .has_custom_workspace_name => self.has_custom_workspace_name,
            .has_splits => self.has_splits,
            .has_peers => self.has_peers,
            .has_workspace_above => self.has_workspace_above,
            .has_workspace_below => self.has_workspace_below,
            .has_tab_focus => self.has_tab_focus,
            .has_custom_tab_name => self.has_custom_tab_name,
            .has_multiple_tabs => self.has_multiple_tabs,
            .has_unread_notifications => self.has_unread_notifications,
            .has_no_unread_notifications => self.has_no_unread_notifications,
            .has_tabs_to_right => self.has_tabs_to_right,
        };
    }

    fn evaluate(state: *WindowState) ContextState {
        var ctx = ContextState{};
        const ws = state.activeWorkspace() orelse return ctx;
        ctx.workspace_exists = true;
        ctx.has_custom_workspace_name = ws.title_is_custom;
        ctx.has_splits = ws.liveColumnCount() > 1;
        ctx.has_peers = state.workspaces.items.len > 1;
        ctx.has_workspace_above = state.active_workspace > 0;
        ctx.has_workspace_below = state.active_workspace + 1 < state.workspaces.items.len;
        ctx.has_unread_notifications = ws.hasUnreadPane();
        ctx.has_no_unread_notifications = !ctx.has_unread_notifications;

        if (ws.focusedGroup()) |group| {
            if (group.focusedTerminalPane()) |pane| {
                ctx.has_tab_focus = true;
                ctx.has_custom_tab_name = pane.custom_title_len > 0;
            }
            ctx.has_multiple_tabs = group.panels.items.len > 1;
            ctx.has_tabs_to_right = group.active_panel + 1 < group.panels.items.len;
        }

        return ctx;
    }
};

/// A command entry in the palette.
const Command = struct {
    label: []const u8,
    action: Action,
    keywords: []const u8,
    /// If true, selecting this command does not dismiss but enters rename mode.
    enters_rename: bool = false,
    /// Condition that must be true for the command to appear.
    visible: Condition = .always,
    /// Condition that must be true for the command to be selectable (dimmed if false).
    enabled: Condition = .always,
};

/// Static commands derived from the Action enum.
const static_commands = [_]Command{
    // Global commands
    .{ .label = "New Workspace", .action = .new_workspace, .keywords = "create new workspace" },
    .{ .label = "New Window", .action = .new_window, .keywords = "create new window" },
    .{ .label = "Open Folder...", .action = .open_folder, .keywords = "open folder repository project directory" },
    .{ .label = "New Tab", .action = .new_tab, .keywords = "new terminal tab create add" },
    .{ .label = "Close Tab", .action = .close_tab, .keywords = "close tab remove delete", .visible = .has_tab_focus },
    .{ .label = "Close Workspace", .action = .close_workspace, .keywords = "close workspace remove delete", .visible = .workspace_exists },
    .{ .label = "Toggle Sidebar", .action = .toggle_sidebar, .keywords = "toggle sidebar show hide layout" },
    .{ .label = "Flash Focused Pane", .action = .flash_focused, .keywords = "flash highlight focus pane" },
    .{ .label = "Toggle Notifications", .action = .toggle_notifications, .keywords = "notifications show hide alerts inbox" },
    .{ .label = "Jump to Unread", .action = .jump_to_unread, .keywords = "jump unread notification" },
    .{ .label = "Open Settings", .action = .open_settings, .keywords = "settings preferences config options" },
    .{ .label = "Reload Configuration", .action = .reload_config, .keywords = "config reload refresh settings" },
    .{ .label = "Quit Seance", .action = .quit_app, .keywords = "quit exit close application app shutdown" },

    // Workspace commands
    .{ .label = "Rename Workspace...", .action = .rename_workspace, .keywords = "rename workspace title name", .enters_rename = true, .visible = .workspace_exists },
    .{ .label = "Toggle Pin", .action = .toggle_pin, .keywords = "pin unpin workspace", .visible = .workspace_exists },
    .{ .label = "Previous Workspace", .action = .prev_workspace, .keywords = "previous workspace navigate switch back" },
    .{ .label = "Next Workspace", .action = .next_workspace, .keywords = "next workspace navigate switch forward" },
    .{ .label = "Workspace Switcher", .action = .workspace_switcher, .keywords = "go switch workspace" },
    .{ .label = "Last Workspace", .action = .last_workspace, .keywords = "last previous recent workspace switch back" },
    .{ .label = "Move Workspace Up", .action = .move_workspace_up, .keywords = "move workspace up reorder", .visible = .workspace_exists, .enabled = .has_workspace_above },
    .{ .label = "Move Workspace Down", .action = .move_workspace_down, .keywords = "move workspace down reorder", .visible = .workspace_exists, .enabled = .has_workspace_below },
    .{ .label = "Move Workspace to Top", .action = .move_workspace_to_top, .keywords = "move workspace top reorder", .visible = .workspace_exists, .enabled = .has_workspace_above },
    .{ .label = "Close Other Workspaces", .action = .close_other_workspaces, .keywords = "close other workspaces remove", .visible = .workspace_exists, .enabled = .has_peers },
    .{ .label = "Close Workspaces Above", .action = .close_workspaces_above, .keywords = "close workspaces above remove", .visible = .workspace_exists, .enabled = .has_workspace_above },
    .{ .label = "Close Workspaces Below", .action = .close_workspaces_below, .keywords = "close workspaces below remove", .visible = .workspace_exists, .enabled = .has_workspace_below },
    .{ .label = "Mark Workspace as Read", .action = .mark_workspace_read, .keywords = "mark read notification workspace", .visible = .workspace_exists, .enabled = .has_unread_notifications },
    .{ .label = "Mark Workspace as Unread", .action = .mark_workspace_unread, .keywords = "mark unread notification workspace", .visible = .workspace_exists, .enabled = .has_no_unread_notifications },
    .{ .label = "Clear Workspace Name", .action = .clear_workspace_name, .keywords = "clear reset workspace name title", .visible = .workspace_exists, .enabled = .has_custom_workspace_name },

    // Pane commands
    .{ .label = "New Column", .action = .new_column, .keywords = "split vertical divide pane column", .visible = .has_tab_focus },
    .{ .label = "Close Pane", .action = .close_pane, .keywords = "close pane remove delete", .visible = .has_tab_focus },
    .{ .label = "Toggle Zoom", .action = .maximize_column, .keywords = "zoom toggle maximize pane fullscreen", .visible = .has_splits },
    .{ .label = "Focus Left", .action = .focus_left, .keywords = "focus left navigate pane", .visible = .has_splits },
    .{ .label = "Focus Right", .action = .focus_right, .keywords = "focus right navigate pane", .visible = .has_splits },
    .{ .label = "Focus Up", .action = .focus_up, .keywords = "focus up navigate pane", .visible = .has_splits },
    .{ .label = "Focus Down", .action = .focus_down, .keywords = "focus down navigate pane", .visible = .has_splits },
    .{ .label = "Equalize Splits", .action = .equalize_splits, .keywords = "equalize even distribute splits columns", .visible = .workspace_exists, .enabled = .has_splits },
    .{ .label = "Last Pane", .action = .last_pane, .keywords = "last previous recent pane switch back" },

    // Layout
    .{ .label = "Toggle Layout Mode", .action = .toggle_layout_mode, .keywords = "layout mode toggle scrolling tiling" },
    .{ .label = "Move Column Left", .action = .move_column_left, .keywords = "move column left reorder", .visible = .has_splits },
    .{ .label = "Move Column Right", .action = .move_column_right, .keywords = "move column right reorder", .visible = .has_splits },
    .{ .label = "Expel Left", .action = .expel_left, .keywords = "expel pane left new column split", .visible = .has_splits },
    .{ .label = "Expel Right", .action = .expel_right, .keywords = "expel pane right new column split", .visible = .has_splits },

    // Resize
    .{ .label = "Resize Column Wider", .action = .resize_wider, .keywords = "grow expand column width" },
    .{ .label = "Resize Column Narrower", .action = .resize_narrower, .keywords = "shrink column width" },
    .{ .label = "Resize Row Taller", .action = .resize_taller, .keywords = "grow expand row height pane" },
    .{ .label = "Resize Row Shorter", .action = .resize_shorter, .keywords = "shrink row height pane" },

    // Terminal commands
    .{ .label = "Find...", .action = .find, .keywords = "terminal find search", .visible = .has_tab_focus },
    .{ .label = "Find Next", .action = .find_next, .keywords = "terminal find next search", .visible = .has_tab_focus },
    .{ .label = "Find Previous", .action = .find_previous, .keywords = "terminal find previous search", .visible = .has_tab_focus },
    .{ .label = "Use Selection for Find", .action = .use_selection_for_find, .keywords = "terminal selection find search", .visible = .has_tab_focus },
    .{ .label = "Copy", .action = .copy, .keywords = "clipboard copy selection", .visible = .has_tab_focus },
    .{ .label = "Clear Scrollback", .action = .clear_scrollback, .keywords = "clear scrollback reset history", .visible = .has_tab_focus },

    // Font
    .{ .label = "Zoom In", .action = .zoom_in, .keywords = "font bigger larger zoom in" },
    .{ .label = "Zoom Out", .action = .zoom_out, .keywords = "font smaller zoom out" },
    .{ .label = "Zoom Reset", .action = .zoom_reset, .keywords = "font default zoom reset actual size" },

    // Tab management
    .{ .label = "Rename Tab...", .action = .rename_tab, .keywords = "rename tab title name", .enters_rename = true, .visible = .has_tab_focus },
    .{ .label = "Close Other Tabs", .action = .close_other_tabs, .keywords = "close other tabs remove", .visible = .has_multiple_tabs },
    .{ .label = "Close Tabs to Right", .action = .close_tabs_to_right, .keywords = "close tabs right remove", .visible = .has_tab_focus, .enabled = .has_tabs_to_right },
    .{ .label = "Clear Tab Name", .action = .clear_tab_name, .keywords = "clear reset tab name title", .visible = .has_tab_focus, .enabled = .has_custom_tab_name },

    // Help
    .{ .label = "Keyboard Shortcuts", .action = .show_shortcuts, .keywords = "help keys bindings cheat sheet F1" },

    // Workspace navigation
    .{ .label = "Workspace 1", .action = .workspace_1, .keywords = "switch select workspace" },
    .{ .label = "Workspace 2", .action = .workspace_2, .keywords = "switch select workspace" },
    .{ .label = "Workspace 3", .action = .workspace_3, .keywords = "switch select workspace" },
    .{ .label = "Workspace 4", .action = .workspace_4, .keywords = "switch select workspace" },
    .{ .label = "Workspace 5", .action = .workspace_5, .keywords = "switch select workspace" },
    .{ .label = "Workspace 6", .action = .workspace_6, .keywords = "switch select workspace" },
    .{ .label = "Workspace 7", .action = .workspace_7, .keywords = "switch select workspace" },
    .{ .label = "Workspace 8", .action = .workspace_8, .keywords = "switch select workspace" },
    .{ .label = "Workspace 9", .action = .workspace_9, .keywords = "switch select workspace" },

    // Tab navigation
    .{ .label = "Next Tab", .action = .next_tab, .keywords = "next tab switch forward" },
    .{ .label = "Previous Tab", .action = .prev_tab, .keywords = "previous tab switch back" },
    .{ .label = "Tab 1", .action = .tab_1, .keywords = "switch select tab" },
    .{ .label = "Tab 2", .action = .tab_2, .keywords = "switch select tab" },
    .{ .label = "Tab 3", .action = .tab_3, .keywords = "switch select tab" },
    .{ .label = "Tab 4", .action = .tab_4, .keywords = "switch select tab" },
    .{ .label = "Tab 5", .action = .tab_5, .keywords = "switch select tab" },
    .{ .label = "Tab 6", .action = .tab_6, .keywords = "switch select tab" },
    .{ .label = "Tab 7", .action = .tab_7, .keywords = "switch select tab" },
    .{ .label = "Tab 8", .action = .tab_8, .keywords = "switch select tab" },
    .{ .label = "Tab 9", .action = .tab_9, .keywords = "switch select tab" },
};

/// Maximum number of visible results in the palette list.
const max_visible_results = 20;

/// Distinguishes the type of a result entry.
const EntryKind = enum {
    static_command,
    workspace,
    tab,
    open_directory,
};

/// Scored result for sorting.
const ScoredResult = struct {
    index: usize, // into static_commands (for static) or app index (open_directory)
    score: u32,
    kind: EntryKind,
    enabled: bool, // false = visible but dimmed / not selectable
    dyn_label: [128]u8,
    dyn_label_len: usize,
    dyn_ws_index: usize, // workspace index for dynamic entries
    kind_label: []const u8, // comptime string literal ("Workspace", "Terminal", etc.)
    // Subtitle (e.g. parent workspace name for tab entries)
    dyn_subtitle: [128]u8,
    dyn_subtitle_len: usize,
    // Tab-entry specifics
    dyn_pane_id: u64,
    dyn_group_id: u64,
    // Fuzzy match positions for highlighting (up to 32 highlighted chars)
    match_positions: [32]usize,
    match_count: usize,
};

/// External application for "Open Directory In..." commands.
const ExternalApp = struct {
    name: []const u8,
    binary: [:0]const u8,
    /// Argument template. "{dir}" is replaced with the directory path.
    arg: []const u8,
    keywords: []const u8,
    detected: bool,
};

const external_apps_template = [_]ExternalApp{
    .{ .name = "File Manager", .binary = "xdg-open", .arg = "{dir}", .keywords = "open directory folder external file manager", .detected = false },
    .{ .name = "VS Code", .binary = "code", .arg = "{dir}", .keywords = "open directory folder external vscode code editor", .detected = false },
    .{ .name = "Zed", .binary = "zed", .arg = "{dir}", .keywords = "open directory folder external zed editor", .detected = false },
    .{ .name = "Cursor", .binary = "cursor", .arg = "{dir}", .keywords = "open directory folder external cursor editor", .detected = false },
    .{ .name = "Windsurf", .binary = "windsurf", .arg = "{dir}", .keywords = "open directory folder external windsurf editor", .detected = false },
    .{ .name = "Ghostty", .binary = "ghostty", .arg = "--working-directory={dir}", .keywords = "open directory folder external ghostty terminal", .detected = false },
};

pub const CommandPalette = struct {
    overlay: *c.GtkWidget, // full-window overlay background
    palette_box: *c.GtkWidget, // the palette container
    entry: *c.GtkWidget, // GtkSearchEntry (commands/switcher mode)
    rename_entry: *c.GtkWidget, // GtkEntry (rename mode)
    rename_hint: *c.GtkWidget, // hint label below rename entry
    rename_sep: *c.GtkWidget, // separator above rename hint
    results_box: *c.GtkWidget, // GtkListBox
    scroll: *c.GtkWidget, // GtkScrolledWindow
    visible: bool = false,
    mode: Mode = .commands,
    selected_index: usize = 0,
    result_count: usize = 0,
    state: *WindowState,

    // For rename mode: which workspace/pane we're renaming
    rename_ws_id: u64 = 0,
    rename_pane_id: u64 = 0,

    // Detected external apps (cached at startup)
    external_apps: [external_apps_template.len]ExternalApp = external_apps_template,

    // Stored scored results for the current filter
    results: [max_visible_results + 80]ScoredResult = undefined, // extra space for dynamic entries

    pub fn create(state: *WindowState) CommandPalette {
        // Use a GtkOverlay so the dim backdrop and the palette are siblings,
        // preventing the semi-transparent backdrop from tinting the palette.
        const overlay = c.gtk_overlay_new();
        c.gtk_widget_set_hexpand(overlay, 1);
        c.gtk_widget_set_vexpand(overlay, 1);

        // Dim backdrop (covers the full window area, click-to-dismiss target)
        const backdrop = c.gtk_box_new(c.GTK_ORIENTATION_VERTICAL, 0);
        c.gtk_widget_add_css_class(backdrop, "command-palette-overlay");
        c.gtk_widget_set_hexpand(backdrop, 1);
        c.gtk_widget_set_vexpand(backdrop, 1);
        c.gtk_overlay_set_child(@ptrCast(overlay), backdrop);

        // Centering wrapper (added as overlay so it floats above the backdrop)
        const center_box = c.gtk_box_new(c.GTK_ORIENTATION_HORIZONTAL, 0);
        c.gtk_widget_set_halign(center_box, c.GTK_ALIGN_CENTER);
        c.gtk_widget_set_valign(center_box, c.GTK_ALIGN_START);
        c.gtk_widget_set_margin_top(center_box, 40);
        c.gtk_overlay_add_overlay(@ptrCast(overlay), center_box);

        // Palette container
        const palette_box = c.gtk_box_new(c.GTK_ORIENTATION_VERTICAL, 0);
        c.gtk_widget_add_css_class(palette_box, "command-palette");
        c.gtk_widget_set_size_request(palette_box, 340, -1);
        c.gtk_box_append(@ptrCast(center_box), palette_box);

        // Search entry (commands/switcher mode)
        const entry = c.gtk_search_entry_new();
        c.gtk_widget_add_css_class(entry, "command-palette-entry");
        c.gtk_search_entry_set_placeholder_text(@ptrCast(entry), "Type a command");
        c.gtk_box_append(@ptrCast(palette_box), entry);

        // Rename entry (hidden by default)
        const rename_entry = c.gtk_entry_new();
        c.gtk_widget_add_css_class(rename_entry, "command-palette-entry");
        c.gtk_widget_set_visible(rename_entry, 0);
        c.gtk_box_append(@ptrCast(palette_box), rename_entry);

        // Separator
        const sep = c.gtk_separator_new(c.GTK_ORIENTATION_HORIZONTAL);
        c.gtk_box_append(@ptrCast(palette_box), sep);

        // Scrolled window for results
        const scroll = c.gtk_scrolled_window_new();
        c.gtk_scrolled_window_set_policy(@ptrCast(scroll), c.GTK_POLICY_NEVER, c.GTK_POLICY_AUTOMATIC);
        c.gtk_widget_set_vexpand(scroll, 1);
        c.gtk_scrolled_window_set_max_content_height(@ptrCast(scroll), 450);
        c.gtk_scrolled_window_set_propagate_natural_height(@ptrCast(scroll), 1);
        c.gtk_box_append(@ptrCast(palette_box), scroll);

        // Results list
        const results_box = c.gtk_list_box_new();
        c.gtk_widget_add_css_class(results_box, "command-palette-results");
        c.gtk_list_box_set_selection_mode(@ptrCast(results_box), c.GTK_SELECTION_SINGLE);
        c.gtk_scrolled_window_set_child(@ptrCast(scroll), results_box);

        // Rename hint (below results area, hidden by default)
        const rename_sep = c.gtk_separator_new(c.GTK_ORIENTATION_HORIZONTAL);
        c.gtk_widget_set_visible(rename_sep, 0);
        c.gtk_box_append(@ptrCast(palette_box), rename_sep);

        const rename_hint = c.gtk_label_new("Press Enter to rename, Escape to cancel.");
        c.gtk_widget_add_css_class(rename_hint, "command-palette-hint");
        c.gtk_label_set_xalign(@ptrCast(rename_hint), 0);
        c.gtk_widget_set_visible(rename_hint, 0);
        c.gtk_box_append(@ptrCast(palette_box), rename_hint);

        // Hide by default
        c.gtk_widget_set_visible(overlay, 0);

        // Connect search-changed signal
        _ = c.g_signal_connect_data(
            @as(c.gpointer, @ptrCast(entry)),
            "search-changed",
            @as(c.GCallback, @ptrCast(&onSearchChanged)),
            @ptrCast(state),
            null,
            0,
        );

        // Connect activate signal (Enter key) on search entry — GtkSearchEntry's
        // internal GtkText consumes Enter before it reaches the key controller.
        _ = c.g_signal_connect_data(
            @as(c.gpointer, @ptrCast(entry)),
            "activate",
            @as(c.GCallback, @ptrCast(&onEntryActivate)),
            @ptrCast(state),
            null,
            0,
        );

        // Connect row-activated signal on listbox
        _ = c.g_signal_connect_data(
            @as(c.gpointer, @ptrCast(results_box)),
            "row-activated",
            @as(c.GCallback, @ptrCast(&onRowActivated)),
            @ptrCast(state),
            null,
            0,
        );

        // Key controller on the search entry for Escape, Up, Down
        const key_ctrl = c.gtk_event_controller_key_new();
        _ = c.g_signal_connect_data(
            @as(c.gpointer, @ptrCast(key_ctrl)),
            "key-pressed",
            @as(c.GCallback, @ptrCast(&onKeyPress)),
            @ptrCast(state),
            null,
            0,
        );
        c.gtk_widget_add_controller(entry, @ptrCast(key_ctrl));

        // Key controller on the rename entry
        const rename_key_ctrl = c.gtk_event_controller_key_new();
        _ = c.g_signal_connect_data(
            @as(c.gpointer, @ptrCast(rename_key_ctrl)),
            "key-pressed",
            @as(c.GCallback, @ptrCast(&onRenameKeyPress)),
            @ptrCast(state),
            null,
            0,
        );
        c.gtk_widget_add_controller(rename_entry, @ptrCast(rename_key_ctrl));

        // Click controller on backdrop to close (clicking the dim area dismisses)
        const click_ctrl = c.gtk_gesture_click_new();
        _ = c.g_signal_connect_data(
            @as(c.gpointer, @ptrCast(click_ctrl)),
            "pressed",
            @as(c.GCallback, @ptrCast(&onOverlayClick)),
            @ptrCast(state),
            null,
            0,
        );
        c.gtk_widget_add_controller(backdrop, @ptrCast(click_ctrl));

        // Clicks on the palette are consumed by its own widgets (entry, listbox)
        // and won't propagate to the backdrop, so no blanket gesture needed here.

        var palette = CommandPalette{
            .overlay = overlay,
            .palette_box = palette_box,
            .entry = entry,
            .rename_entry = rename_entry,
            .rename_hint = rename_hint,
            .rename_sep = rename_sep,
            .results_box = results_box,
            .scroll = scroll,
            .state = state,
        };
        palette.detectExternalApps();
        return palette;
    }

    /// Detect which external apps are available on $PATH (cached at startup).
    pub fn detectExternalApps(self: *CommandPalette) void {
        for (&self.external_apps) |*app| {
            app.detected = detectBinary(app.binary);
        }
    }

    /// Open in commands mode (> prefix pre-filled).
    pub fn show(self: *CommandPalette) void {
        self.visible = true;
        self.mode = .commands;
        self.showSearchUI();
        c.gtk_widget_set_visible(self.overlay, 1);
        c.gtk_editable_set_text(@ptrCast(self.entry), "> ");
        // Position cursor after "> "
        c.gtk_editable_set_position(@ptrCast(self.entry), 2);
        self.updateResults("");
        _ = c.gtk_widget_grab_focus(self.entry);
    }

    /// Open in switcher mode (no prefix).
    pub fn showWorkspaceSwitcher(self: *CommandPalette) void {
        self.visible = true;
        self.mode = .switcher;
        self.showSearchUI();
        c.gtk_widget_set_visible(self.overlay, 1);
        c.gtk_editable_set_text(@ptrCast(self.entry), "");
        c.gtk_search_entry_set_placeholder_text(@ptrCast(self.entry), "Search workspaces...");
        self.updateResults("");
        _ = c.gtk_widget_grab_focus(self.entry);
    }

    pub fn hide(self: *CommandPalette) void {
        self.visible = false;
        self.mode = .commands;
        c.gtk_widget_set_visible(self.overlay, 0);
        self.showSearchUI(); // reset UI state
        self.focusTerminal();
    }

    pub fn toggle(self: *CommandPalette) void {
        if (self.visible) {
            // If already in commands mode, dismiss. If in different mode, switch.
            if (self.mode == .commands) {
                self.hide();
            } else {
                self.mode = .commands;
                self.showSearchUI();
                c.gtk_editable_set_text(@ptrCast(self.entry), "> ");
                c.gtk_editable_set_position(@ptrCast(self.entry), 2);
                self.updateResults("");
                _ = c.gtk_widget_grab_focus(self.entry);
            }
        } else {
            self.show();
        }
    }

    pub fn toggleSwitcher(self: *CommandPalette) void {
        if (self.visible) {
            if (self.mode == .switcher) {
                self.hide();
            } else {
                self.mode = .switcher;
                self.showSearchUI();
                c.gtk_editable_set_text(@ptrCast(self.entry), "");
                c.gtk_search_entry_set_placeholder_text(@ptrCast(self.entry), "Search workspaces...");
                self.updateResults("");
                _ = c.gtk_widget_grab_focus(self.entry);
            }
        } else {
            self.showWorkspaceSwitcher();
        }
    }

    /// Show search entry, hide rename entry.
    fn showSearchUI(self: *CommandPalette) void {
        c.gtk_widget_set_visible(self.entry, 1);
        c.gtk_widget_set_visible(self.rename_entry, 0);
        c.gtk_widget_set_visible(self.rename_hint, 0);
        c.gtk_widget_set_visible(self.rename_sep, 0);
        c.gtk_widget_set_visible(self.scroll, 1);
    }

    /// Show rename entry, hide search entry and results.
    fn showRenameUI(self: *CommandPalette) void {
        c.gtk_widget_set_visible(self.entry, 0);
        c.gtk_widget_set_visible(self.rename_entry, 1);
        c.gtk_widget_set_visible(self.rename_hint, 1);
        c.gtk_widget_set_visible(self.rename_sep, 1);
        c.gtk_widget_set_visible(self.scroll, 0);
    }

    /// Enter rename mode for a workspace.
    fn enterRenameWorkspace(self: *CommandPalette) void {
        const ws = self.state.activeWorkspace() orelse return;
        self.mode = .rename_workspace;
        self.rename_ws_id = ws.id;
        self.showRenameUI();

        // Set placeholder and hint
        c.gtk_entry_set_placeholder_text(@ptrCast(self.rename_entry), "Workspace name");
        c.gtk_label_set_text(@ptrCast(self.rename_hint), "Enter a workspace name. Press Enter to rename, Escape to cancel.");

        // Pre-fill with current name
        var title_z: [129]u8 = undefined;
        const ws_title = ws.getTitle();
        const tlen = @min(ws_title.len, title_z.len - 1);
        @memcpy(title_z[0..tlen], ws_title[0..tlen]);
        title_z[tlen] = 0;
        c.gtk_editable_set_text(@ptrCast(self.rename_entry), @ptrCast(&title_z));

        _ = c.gtk_widget_grab_focus(self.rename_entry);
        c.gtk_editable_select_region(@ptrCast(self.rename_entry), 0, -1);
    }

    /// Enter rename mode for a tab.
    fn enterRenameTab(self: *CommandPalette) void {
        const ws = self.state.activeWorkspace() orelse return;
        const group = ws.focusedGroup() orelse return;
        const pane = group.focusedTerminalPane() orelse return;
        self.mode = .rename_tab;
        self.rename_pane_id = pane.id;
        self.showRenameUI();

        c.gtk_entry_set_placeholder_text(@ptrCast(self.rename_entry), "Tab name");
        c.gtk_label_set_text(@ptrCast(self.rename_hint), "Enter a tab name. Press Enter to rename, Escape to cancel.");

        // Pre-fill with current name
        var title_z: [257]u8 = undefined;
        const display_title = pane.getDisplayTitle() orelse "Terminal";
        const tlen = @min(display_title.len, title_z.len - 1);
        @memcpy(title_z[0..tlen], display_title[0..tlen]);
        title_z[tlen] = 0;
        c.gtk_editable_set_text(@ptrCast(self.rename_entry), @ptrCast(&title_z));

        _ = c.gtk_widget_grab_focus(self.rename_entry);
        c.gtk_editable_select_region(@ptrCast(self.rename_entry), 0, -1);
    }

    /// Apply the rename from the rename entry.
    fn applyRename(self: *CommandPalette) void {
        const text_ptr: [*c]const u8 = c.gtk_editable_get_text(@ptrCast(self.rename_entry));
        const text = if (text_ptr != null) std.mem.span(text_ptr) else "";
        const trimmed = std.mem.trim(u8, text, " \t\r\n");

        switch (self.mode) {
            .rename_workspace => {
                for (self.state.workspaces.items) |ws| {
                    if (ws.id == self.rename_ws_id) {
                        if (trimmed.len > 0) {
                            ws.setCustomTitle(trimmed);
                        } else {
                            ws.clearCustomTitle();
                        }
                        break;
                    }
                }
                self.state.sidebar.refresh();
                self.state.sidebar.setActive(self.state.active_workspace);
            },
            .rename_tab => {
                for (self.state.workspaces.items) |ws| {
                    if (ws.findGroupContainingPane(self.rename_pane_id)) |group| {
                        if (group.findPaneById(self.rename_pane_id)) |pane| {
                            if (trimmed.len > 0) {
                                pane.setCustomTitle(trimmed);
                                group.updateTitleForPane(self.rename_pane_id, trimmed);
                            } else {
                                pane.clearCustomTitle();
                                const title = pane.getCachedTitle() orelse "Terminal";
                                group.updateTitleForPane(self.rename_pane_id, title);
                            }
                        }
                        break;
                    }
                }
            },
            else => {},
        }

        self.hide();
    }

    fn focusTerminal(self: *CommandPalette) void {
        const ws = self.state.activeWorkspace() orelse return;
        const group = ws.focusedGroup() orelse return;
        if (group.focusedTerminalPane()) |pane| {
            if (pane.gl_area) |gl| {
                _ = c.gtk_widget_grab_focus(@as(*c.GtkWidget, @ptrCast(gl)));
            }
        }
    }

    fn executeSelected(self: *CommandPalette) void {
        if (self.result_count == 0) return;
        const idx = @min(self.selected_index, self.result_count - 1);
        const result = self.results[idx];

        // Don't execute disabled entries
        if (!result.enabled) return;

        switch (result.kind) {
            .workspace => {
                self.hide();
                self.state.selectWorkspace(result.dyn_ws_index);
            },
            .tab => {
                // Switch to workspace, then focus the specific pane/group
                self.hide();
                self.state.selectWorkspace(result.dyn_ws_index);
                if (self.state.activeWorkspace()) |ws| {
                    // Find the column containing this group and focus it
                    for (ws.columns.items, 0..) |col, col_idx| {
                        if (col.closing) continue;
                        for (col.groups.items) |grp| {
                            if (grp.id == result.dyn_group_id) {
                                ws.focused_column = col_idx;
                                // Find the panel index for this pane
                                for (grp.panels.items, 0..) |panel, pi| {
                                    if (panel.getId() == result.dyn_pane_id) {
                                        grp.switchToPanel(pi);
                                        break;
                                    }
                                }
                                grp.focus();
                                return;
                            }
                        }
                    }
                }
            },
            .open_directory => {
                self.hide();
                self.launchOpenDirectory(result.index);
            },
            .static_command => {
                const cmd = static_commands[result.index];
                if (cmd.enters_rename) {
                    if (cmd.action == .rename_workspace) {
                        self.enterRenameWorkspace();
                    } else if (cmd.action == .rename_tab) {
                        self.enterRenameTab();
                    }
                } else {
                    self.hide();
                    _ = keybinds.executeAction(cmd.action, self.state);
                }
            },
        }
    }

    /// Launch an external app to open the focused pane's working directory.
    fn launchOpenDirectory(self: *CommandPalette, app_index: usize) void {
        if (app_index >= self.external_apps.len) return;
        const app = self.external_apps[app_index];
        if (!app.detected) return;

        const cwd = blk: {
            const ws = self.state.activeWorkspace() orelse return;
            const group = ws.focusedGroup() orelse return;
            const pane = group.focusedTerminalPane() orelse return;
            break :blk pane.getCwd() orelse return;
        };

        // Build the argument by replacing {dir} in the arg template
        var arg_buf: [1024]u8 = undefined;
        var pos: usize = 0;
        var tmpl = app.arg;
        while (tmpl.len > 0) {
            if (std.mem.indexOf(u8, tmpl, "{dir}")) |di| {
                if (pos + di + cwd.len > arg_buf.len) return;
                @memcpy(arg_buf[pos..][0..di], tmpl[0..di]);
                pos += di;
                @memcpy(arg_buf[pos..][0..cwd.len], cwd);
                pos += cwd.len;
                tmpl = tmpl[di + 5 ..];
            } else {
                if (pos + tmpl.len > arg_buf.len) return;
                @memcpy(arg_buf[pos..][0..tmpl.len], tmpl);
                pos += tmpl.len;
                break;
            }
        }
        if (pos >= arg_buf.len) return;
        arg_buf[pos] = 0;

        // Use argv to avoid shell interpretation of directory paths
        const arg_slice: [:0]const u8 = arg_buf[0..pos :0];
        var argv = [_:null]?[*:0]const u8{ app.binary.ptr, arg_slice.ptr, null };
        _ = c.g_spawn_async(null, @ptrCast(&argv), null, c.G_SPAWN_SEARCH_PATH, null, null, null, null);
    }

    /// Derive the current mode from the search field text.
    fn deriveMode(text: []const u8) Mode {
        if (text.len > 0 and text[0] == '>') return .commands;
        return .switcher;
    }

    /// Extract the actual query from the text (strip > prefix and leading space).
    fn extractQuery(text: []const u8) []const u8 {
        if (text.len > 0 and text[0] == '>') {
            var rest = text[1..];
            // Strip leading whitespace after >
            while (rest.len > 0 and (rest[0] == ' ' or rest[0] == '\t')) {
                rest = rest[1..];
            }
            return rest;
        }
        return std.mem.trim(u8, text, " \t");
    }

    fn updateResults(self: *CommandPalette, query: []const u8) void {
        // Remove all existing rows
        var child = c.gtk_widget_get_first_child(self.results_box);
        while (child != null) {
            const next = c.gtk_widget_get_next_sibling(child);
            c.gtk_list_box_remove(@ptrCast(self.results_box), child);
            child = next;
        }

        var count: usize = 0;
        const ctx = ContextState.evaluate(self.state);

        if (self.mode == .commands) {
            // Commands mode: show static commands filtered by context
            for (static_commands, 0..) |cmd, i| {
                if (cmd.action == .open_command_palette) continue;
                if (cmd.action == .workspace_switcher) continue;

                // Visibility check: skip if condition not met
                if (!ctx.check(cmd.visible)) continue;

                var match_pos: [32]usize = undefined;
                var match_cnt: usize = 0;
                const score = if (query.len == 0)
                    @as(u32, 1)
                else blk: {
                    if (fuzzyScoreWithPositions(query, cmd.label, &match_pos, &match_cnt)) |s| {
                        break :blk s;
                    }
                    if (fuzzyScore(query, cmd.keywords)) |s| {
                        match_cnt = 0;
                        break :blk s;
                    }
                    continue;
                };

                if (count < self.results.len) {
                    self.results[count] = .{
                        .index = i,
                        .score = score,
                        .kind = .static_command,
                        .enabled = ctx.check(cmd.enabled),
                        .dyn_label = undefined,
                        .dyn_label_len = 0,
                        .dyn_ws_index = 0,
                        .kind_label = "",
                        .dyn_subtitle = undefined,
                        .dyn_subtitle_len = 0,
                        .dyn_pane_id = 0,
                        .dyn_group_id = 0,
                        .match_positions = match_pos,
                        .match_count = match_cnt,
                    };
                    count += 1;
                }
            }

            // Open Directory commands (only when a terminal has a known cwd)
            if (ctx.has_tab_focus) {
                const cwd = blk: {
                    const ws = self.state.activeWorkspace() orelse break :blk @as(?[]const u8, null);
                    const group = ws.focusedGroup() orelse break :blk @as(?[]const u8, null);
                    const pane = group.focusedTerminalPane() orelse break :blk @as(?[]const u8, null);
                    break :blk pane.getCwd();
                };
                if (cwd != null) {
                    for (self.external_apps, 0..) |app, app_idx| {
                        if (!app.detected) continue;

                        // Build label: "Open Directory in <App>"
                        var label_buf: [128]u8 = undefined;
                        const prefix = "Open Directory in ";
                        if (prefix.len + app.name.len > label_buf.len) continue;
                        @memcpy(label_buf[0..prefix.len], prefix);
                        @memcpy(label_buf[prefix.len..][0..app.name.len], app.name);
                        const label_len = prefix.len + app.name.len;

                        var match_pos: [32]usize = undefined;
                        var match_cnt: usize = 0;
                        const score = if (query.len == 0)
                            @as(u32, 1)
                        else blk2: {
                            if (fuzzyScoreWithPositions(query, label_buf[0..label_len], &match_pos, &match_cnt)) |s| {
                                break :blk2 s;
                            }
                            if (fuzzyScore(query, app.keywords)) |s| {
                                match_cnt = 0;
                                break :blk2 s;
                            }
                            continue;
                        };

                        if (count < self.results.len) {
                            self.results[count] = .{
                                .index = app_idx,
                                .score = score,
                                .kind = .open_directory,
                                .enabled = true,
                                .dyn_label = undefined,
                                .dyn_label_len = label_len,
                                .dyn_ws_index = 0,
                                .kind_label = "",
                                .dyn_subtitle = undefined,
                                .dyn_subtitle_len = 0,
                                .dyn_pane_id = 0,
                                .dyn_group_id = 0,
                                .match_positions = match_pos,
                                .match_count = match_cnt,
                            };
                            @memcpy(self.results[count].dyn_label[0..label_len], label_buf[0..label_len]);
                            count += 1;
                        }
                    }
                }
            }
        } else {
            // Switcher mode: always show workspaces
            for (self.state.workspaces.items, 0..) |ws, ws_idx| {
                const ws_title = ws.getTitle();
                if (ws_title.len > 128) continue;

                var match_pos: [32]usize = undefined;
                var match_cnt: usize = 0;
                const score = if (query.len == 0)
                    @as(u32, 1)
                else blk: {
                    if (fuzzyScoreWithPositions(query, ws_title, &match_pos, &match_cnt)) |s| {
                        break :blk s;
                    }
                    if (ws.getGitBranch()) |branch| {
                        if (fuzzyScore(query, branch)) |s| {
                            match_cnt = 0;
                            break :blk s;
                        }
                    }
                    if (ws.getActivePaneCwd()) |cwd_str| {
                        if (fuzzyScore(query, cwd_str)) |s| {
                            match_cnt = 0;
                            break :blk s;
                        }
                    }
                    continue;
                };

                if (count < self.results.len) {
                    self.results[count] = .{
                        .index = 0,
                        .score = score,
                        .kind = .workspace,
                        .enabled = true,
                        .dyn_label = undefined,
                        .dyn_label_len = ws_title.len,
                        .dyn_ws_index = ws_idx,
                        .kind_label = "Workspace",
                        .dyn_subtitle = undefined,
                        .dyn_subtitle_len = 0,
                        .dyn_pane_id = 0,
                        .dyn_group_id = 0,
                        .match_positions = match_pos,
                        .match_count = match_cnt,
                    };
                    @memcpy(self.results[count].dyn_label[0..ws_title.len], ws_title);
                    count += 1;
                }
            }

            // Tab entries: only when query is non-empty
            if (query.len > 0) {
                for (self.state.workspaces.items, 0..) |ws, ws_idx| {
                    const ws_title = ws.getTitle();
                    for (ws.columns.items) |col| {
                        if (col.closing) continue;
                        for (col.groups.items) |grp| {
                            for (grp.panels.items) |panel| {
                                const pane = panel.asTerminal() orelse continue;
                                const tab_title = pane.getDisplayTitle() orelse "Terminal";
                                if (tab_title.len > 128) continue;

                                var match_pos: [32]usize = undefined;
                                var match_cnt: usize = 0;
                                const score = blk: {
                                    // Match on tab title
                                    if (fuzzyScoreWithPositions(query, tab_title, &match_pos, &match_cnt)) |s| {
                                        break :blk s;
                                    }
                                    // Match on cwd
                                    if (pane.getCwd()) |cwd_str| {
                                        if (fuzzyScore(query, cwd_str)) |s| {
                                            match_cnt = 0;
                                            break :blk s;
                                        }
                                    }
                                    // Match on pane's git branch
                                    if (pane.shell_git_branch_len > 0) {
                                        if (fuzzyScore(query, pane.shell_git_branch[0..pane.shell_git_branch_len])) |s| {
                                            match_cnt = 0;
                                            break :blk s;
                                        }
                                    }
                                    // Match on workspace ports
                                    if (ws.ports_len > 0) {
                                        var port_buf: [128]u8 = undefined;
                                        var plen: usize = 0;
                                        for (ws.ports[0..ws.ports_len]) |port| {
                                            const digits = std.fmt.bufPrint(port_buf[plen..], "{d} ", .{port}) catch break;
                                            plen += digits.len;
                                        }
                                        if (plen > 0) {
                                            if (fuzzyScore(query, port_buf[0..plen])) |s| {
                                                match_cnt = 0;
                                                break :blk s;
                                            }
                                        }
                                    }
                                    continue;
                                };

                                if (count < self.results.len) {
                                    self.results[count] = .{
                                        .index = 0,
                                        .score = score,
                                        .kind = .tab,
                                        .enabled = true,
                                        .dyn_label = undefined,
                                        .dyn_label_len = tab_title.len,
                                        .dyn_ws_index = ws_idx,
                                        .kind_label = "Terminal",
                                        .dyn_subtitle = undefined,
                                        .dyn_subtitle_len = @min(ws_title.len, 128),
                                        .dyn_pane_id = pane.id,
                                        .dyn_group_id = grp.id,
                                        .match_positions = match_pos,
                                        .match_count = match_cnt,
                                    };
                                    @memcpy(self.results[count].dyn_label[0..tab_title.len], tab_title);
                                    @memcpy(self.results[count].dyn_subtitle[0..self.results[count].dyn_subtitle_len], ws_title[0..self.results[count].dyn_subtitle_len]);
                                    count += 1;
                                }
                            }
                        }
                    }
                }
            }
        }

        // Sort by score descending (only if query is non-empty)
        if (query.len > 0 and count > 1) {
            const items = self.results[0..count];
            std.sort.insertion(ScoredResult, items, {}, struct {
                fn cmp(_: void, a: ScoredResult, b_item: ScoredResult) bool {
                    return a.score > b_item.score;
                }
            }.cmp);
        }

        // Limit visible results
        const visible_count = @min(count, max_visible_results);
        self.result_count = visible_count;
        self.selected_index = 0;

        // Select first enabled result
        for (self.results[0..visible_count], 0..) |result, ri| {
            if (result.enabled) {
                self.selected_index = ri;
                break;
            }
        }

        // Create rows
        for (self.results[0..visible_count], 0..) |result, ri| {
            const row_widget = self.buildResultRow(result);
            c.gtk_list_box_append(@ptrCast(self.results_box), row_widget);

            if (ri == self.selected_index) {
                const row = c.gtk_list_box_get_row_at_index(@ptrCast(self.results_box), @intCast(ri));
                if (row != null) {
                    c.gtk_list_box_select_row(@ptrCast(self.results_box), row);
                }
            }
        }

        // Show empty state if no results
        if (visible_count == 0 and query.len > 0) {
            const empty_msg = if (self.mode == .commands)
                "No commands match your search."
            else
                "No workspaces match your search.";
            const empty_label = c.gtk_label_new(empty_msg.ptr);
            c.gtk_widget_add_css_class(empty_label, "command-palette-empty");
            c.gtk_label_set_xalign(@ptrCast(empty_label), 0);
            c.gtk_list_box_append(@ptrCast(self.results_box), empty_label);
        }
    }

    fn buildResultRow(self: *const CommandPalette, result: ScoredResult) *c.GtkWidget {
        const hbox = c.gtk_box_new(c.GTK_ORIENTATION_HORIZONTAL, 8);
        c.gtk_widget_add_css_class(hbox, "command-palette-result");

        // Dim the entire row if disabled
        if (!result.enabled) {
            c.gtk_widget_add_css_class(hbox, "command-palette-disabled");
        }

        // Get label text
        const label_text = switch (result.kind) {
            .static_command => static_commands[result.index].label,
            .workspace, .tab, .open_directory => result.dyn_label[0..result.dyn_label_len],
        };

        // Build Pango markup with fuzzy match highlighting
        var markup_buf: [1024]u8 = undefined;
        const markup = buildHighlightedMarkup(label_text, result.match_positions[0..result.match_count], &markup_buf);

        // For tab entries, use a vertical box with title + subtitle
        if (result.kind == .tab and result.dyn_subtitle_len > 0) {
            const vbox = c.gtk_box_new(c.GTK_ORIENTATION_VERTICAL, 0);
            c.gtk_widget_set_hexpand(vbox, 1);

            const title_label = c.gtk_label_new(null);
            c.gtk_label_set_markup(@ptrCast(title_label), markup.ptr);
            c.gtk_label_set_xalign(@ptrCast(title_label), 0);
            c.gtk_box_append(@ptrCast(vbox), title_label);

            var sub_z: [129]u8 = undefined;
            const slen = @min(result.dyn_subtitle_len, sub_z.len - 1);
            @memcpy(sub_z[0..slen], result.dyn_subtitle[0..slen]);
            sub_z[slen] = 0;
            const subtitle = c.gtk_label_new(@ptrCast(&sub_z));
            c.gtk_widget_add_css_class(subtitle, "command-palette-subtitle");
            c.gtk_label_set_xalign(@ptrCast(subtitle), 0);
            c.gtk_box_append(@ptrCast(vbox), subtitle);

            c.gtk_box_append(@ptrCast(hbox), vbox);
        } else {
            const label = c.gtk_label_new(null);
            c.gtk_label_set_markup(@ptrCast(label), markup.ptr);
            c.gtk_label_set_xalign(@ptrCast(label), 0);
            c.gtk_widget_set_hexpand(label, 1);
            c.gtk_box_append(@ptrCast(hbox), label);
        }

        // Right-aligned trailing info
        if (result.kind == .static_command) {
            // Show keyboard shortcut badge for commands
            var shortcut_buf: [64]u8 = undefined;
            const slen = keybinds.displayString(static_commands[result.index].action, &shortcut_buf);
            if (slen > 0) {
                shortcut_buf[slen] = 0;
                const shortcut_label = c.gtk_label_new(@ptrCast(&shortcut_buf));
                c.gtk_widget_add_css_class(shortcut_label, "command-palette-shortcut");
                c.gtk_box_append(@ptrCast(hbox), shortcut_label);
            }
        } else if (self.mode == .switcher and result.kind_label.len > 0) {
            // Show kind label ("Workspace" or "Terminal")
            var kind_z: [32]u8 = undefined;
            const klen = @min(result.kind_label.len, kind_z.len - 1);
            @memcpy(kind_z[0..klen], result.kind_label[0..klen]);
            kind_z[klen] = 0;
            const kind_label = c.gtk_label_new(@ptrCast(&kind_z));
            c.gtk_widget_add_css_class(kind_label, "command-palette-kind");
            c.gtk_box_append(@ptrCast(hbox), kind_label);
        }

        return hbox;
    }

    fn moveSelection(self: *CommandPalette, delta: i32) void {
        if (self.result_count == 0) return;

        const count = @as(i32, @intCast(self.result_count));
        var new_idx = @as(i32, @intCast(self.selected_index)) + delta;
        // Clamp to boundaries (no wrap-around)
        if (new_idx < 0) new_idx = 0;
        if (new_idx >= count) new_idx = count - 1;

        // Skip disabled entries in the direction of movement
        const step: i32 = if (delta > 0) 1 else -1;
        while (new_idx >= 0 and new_idx < count) {
            if (self.results[@intCast(new_idx)].enabled) break;
            new_idx += step;
        }
        // If we couldn't find an enabled entry, stay put
        if (new_idx < 0 or new_idx >= count or !self.results[@intCast(new_idx)].enabled) return;

        self.selected_index = @intCast(new_idx);

        const row = c.gtk_list_box_get_row_at_index(@ptrCast(self.results_box), @intCast(self.selected_index));
        if (row != null) {
            c.gtk_list_box_select_row(@ptrCast(self.results_box), row);
            // Scroll to row
            const widget: *c.GtkWidget = @ptrCast(@alignCast(row));
            const adj = c.gtk_scrolled_window_get_vadjustment(@ptrCast(self.scroll));
            if (adj != null) {
                var alloc_rect: c.GtkAllocation = undefined;
                c.gtk_widget_get_allocation(widget, &alloc_rect);
                const row_y: f64 = @floatFromInt(alloc_rect.y);
                const row_h: f64 = @floatFromInt(alloc_rect.height);
                const page = c.gtk_adjustment_get_page_size(adj);
                const val = c.gtk_adjustment_get_value(adj);
                if (row_y < val) {
                    c.gtk_adjustment_set_value(adj, row_y);
                } else if (row_y + row_h > val + page) {
                    c.gtk_adjustment_set_value(adj, row_y + row_h - page);
                }
            }
        }
    }
};

// --- Fuzzy matching ---

fn toLower(ch: u8) u8 {
    if (ch >= 'A' and ch <= 'Z') return ch + 32;
    return ch;
}

/// Simple fuzzy score without position tracking.
fn fuzzyScore(query: []const u8, target: []const u8) ?u32 {
    if (query.len == 0) return 1;
    if (target.len == 0) return null;

    var qi: usize = 0;
    var score: u32 = 0;
    var prev_match: ?usize = null;

    for (target, 0..) |ch, ti| {
        if (qi < query.len and toLower(ch) == toLower(query[qi])) {
            score += 1;
            if (prev_match) |pm| {
                if (ti == pm + 1) score += 5; // consecutive bonus
            }
            if (ti == 0) score += 10; // start bonus
            if (ti > 0 and (target[ti - 1] == ' ' or target[ti - 1] == '_' or target[ti - 1] == '/')) score += 5; // word boundary
            prev_match = ti;
            qi += 1;
        }
    }

    return if (qi == query.len) score else null;
}

/// Fuzzy score with match position tracking for highlighting.
fn fuzzyScoreWithPositions(query: []const u8, target: []const u8, positions: *[32]usize, pos_count: *usize) ?u32 {
    if (query.len == 0) {
        pos_count.* = 0;
        return 1;
    }
    if (target.len == 0) return null;

    var qi: usize = 0;
    var score: u32 = 0;
    var prev_match: ?usize = null;
    var pcount: usize = 0;

    for (target, 0..) |ch, ti| {
        if (qi < query.len and toLower(ch) == toLower(query[qi])) {
            score += 1;
            if (prev_match) |pm| {
                if (ti == pm + 1) score += 5;
            }
            if (ti == 0) score += 10;
            if (ti > 0 and (target[ti - 1] == ' ' or target[ti - 1] == '_' or target[ti - 1] == '/')) score += 5;
            if (pcount < positions.len) {
                positions[pcount] = ti;
                pcount += 1;
            }
            prev_match = ti;
            qi += 1;
        }
    }

    if (qi == query.len) {
        pos_count.* = pcount;
        return score;
    }
    return null;
}

/// Build Pango markup with matched characters at full brightness and
/// consecutive non-matched characters grouped into a single dimmed span.
/// Falls back to plain escaped text if the buffer is too small for markup.
fn buildHighlightedMarkup(text: []const u8, match_positions: []const usize, buf: *[1024]u8) [:0]const u8 {
    const margin = 32; // reserve space for closing tags + null
    var pos: usize = 0;
    var in_dim = false;

    const dim_open = "<span alpha=\"60%\">";
    const dim_close = "</span>";

    if (match_positions.len == 0) {
        // No matches — wrap entire text in one dim span
        pos = appendTag(buf, pos, dim_open);
        for (text) |ch| {
            pos = appendEscaped(buf, pos, ch);
        }
        pos = appendTag(buf, pos, dim_close);
        buf[pos] = 0;
        return buf[0..pos :0];
    }

    var mi: usize = 0;
    for (text, 0..) |ch, ti| {
        // Bail out to plain text if running low on buffer
        if (pos + margin >= buf.len) {
            if (in_dim) {
                pos = appendTag(buf, pos, dim_close);
            }
            break;
        }

        const is_match = mi < match_positions.len and match_positions[mi] == ti;
        if (is_match) {
            if (in_dim) {
                pos = appendTag(buf, pos, dim_close);
                in_dim = false;
            }
            pos = appendEscaped(buf, pos, ch);
            mi += 1;
        } else {
            if (!in_dim) {
                pos = appendTag(buf, pos, dim_open);
                in_dim = true;
            }
            pos = appendEscaped(buf, pos, ch);
        }
    }

    if (in_dim) {
        pos = appendTag(buf, pos, dim_close);
    }

    buf[pos] = 0;
    return buf[0..pos :0];
}

fn appendTag(buf: *[1024]u8, pos: usize, tag: []const u8) usize {
    if (pos + tag.len <= buf.len) {
        @memcpy(buf[pos..][0..tag.len], tag);
        return pos + tag.len;
    }
    return pos;
}

fn appendEscaped(buf: *[1024]u8, pos: usize, ch: u8) usize {
    const replacement: ?[]const u8 = switch (ch) {
        '&' => "&amp;",
        '<' => "&lt;",
        '>' => "&gt;",
        '"' => "&quot;",
        else => null,
    };
    if (replacement) |s| {
        if (pos + s.len <= buf.len) {
            @memcpy(buf[pos..][0..s.len], s);
            return pos + s.len;
        }
        return pos;
    }
    if (pos < buf.len) {
        buf[pos] = ch;
        return pos + 1;
    }
    return pos;
}

// --- Signal callbacks ---

fn onSearchChanged(_: *c.GtkSearchEntry, user_data: c.gpointer) callconv(.c) void {
    const state: *WindowState = @ptrCast(@alignCast(user_data));
    const palette = &state.command_palette;
    const text_ptr: [*c]const u8 = c.gtk_editable_get_text(@ptrCast(palette.entry));
    const text = if (text_ptr != null) std.mem.span(text_ptr) else "";

    // Derive mode from prefix
    const new_mode = CommandPalette.deriveMode(text);
    if (new_mode != palette.mode) {
        palette.mode = new_mode;
        // Update placeholder
        if (new_mode == .commands) {
            c.gtk_search_entry_set_placeholder_text(@ptrCast(palette.entry), "Type a command");
        } else {
            c.gtk_search_entry_set_placeholder_text(@ptrCast(palette.entry), "Search workspaces...");
        }
    }

    const query = CommandPalette.extractQuery(text);
    palette.updateResults(query);
}

fn onKeyPress(
    _: *c.GtkEventControllerKey,
    keyval: c.guint,
    _: c.guint,
    _: c.GdkModifierType,
    user_data: c.gpointer,
) callconv(.c) c.gboolean {
    const state: *WindowState = @ptrCast(@alignCast(user_data));
    const palette = &state.command_palette;

    if (keyval == c.GDK_KEY_Escape) {
        palette.hide();
        return 1;
    }
    if (keyval == c.GDK_KEY_Up) {
        palette.moveSelection(-1);
        return 1;
    }
    if (keyval == c.GDK_KEY_Down) {
        palette.moveSelection(1);
        return 1;
    }

    return 0;
}

fn onRenameKeyPress(
    _: *c.GtkEventControllerKey,
    keyval: c.guint,
    _: c.guint,
    _: c.GdkModifierType,
    user_data: c.gpointer,
) callconv(.c) c.gboolean {
    const state: *WindowState = @ptrCast(@alignCast(user_data));
    const palette = &state.command_palette;

    if (keyval == c.GDK_KEY_Escape) {
        palette.hide();
        return 1;
    }
    if (keyval == c.GDK_KEY_Return or keyval == c.GDK_KEY_KP_Enter) {
        palette.applyRename();
        return 1;
    }

    return 0;
}

fn onEntryActivate(_: *c.GtkSearchEntry, user_data: c.gpointer) callconv(.c) void {
    const state: *WindowState = @ptrCast(@alignCast(user_data));
    state.command_palette.executeSelected();
}

fn onRowActivated(_: *c.GtkListBox, row: *c.GtkListBoxRow, user_data: c.gpointer) callconv(.c) void {
    const state: *WindowState = @ptrCast(@alignCast(user_data));
    const palette = &state.command_palette;
    const idx = c.gtk_list_box_row_get_index(row);
    if (idx >= 0) {
        palette.selected_index = @intCast(idx);
        palette.executeSelected();
    }
}

fn onOverlayClick(
    _: *c.GtkGestureClick,
    _: c.gint,
    _: c.gdouble,
    _: c.gdouble,
    user_data: c.gpointer,
) callconv(.c) void {
    const state: *WindowState = @ptrCast(@alignCast(user_data));
    // The click controller is on the backdrop, which sits behind the palette.
    // Clicks on the palette are consumed by its own widgets and won't reach here.
    state.command_palette.hide();
}

// --- External app detection ---

/// Check if a binary exists on $PATH using access(2).
fn detectBinary(binary: []const u8) bool {
    const path_env = std.posix.getenv("PATH") orelse return false;
    var iter = std.mem.splitScalar(u8, path_env, ':');
    while (iter.next()) |dir| {
        if (dir.len == 0) continue;
        var buf: [512]u8 = undefined;
        if (dir.len + 1 + binary.len >= buf.len) continue;
        @memcpy(buf[0..dir.len], dir);
        buf[dir.len] = '/';
        @memcpy(buf[dir.len + 1 ..][0..binary.len], binary);
        buf[dir.len + 1 + binary.len] = 0;
        const path_z: [*:0]const u8 = @ptrCast(&buf);
        std.posix.accessZ(path_z, std.posix.X_OK) catch continue;
        return true;
    }
    return false;
}
