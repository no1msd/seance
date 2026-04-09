const std = @import("std");
const c = @import("c.zig").c;
const Window = @import("window.zig");
const Pane = @import("pane.zig").Pane;
const Column = @import("column.zig").Column;

/// All bindable keyboard shortcut actions.
pub const Action = enum(u8) {
    // Workspaces
    prev_workspace,
    next_workspace,
    workspace_1,
    workspace_2,
    workspace_3,
    workspace_4,
    workspace_5,
    workspace_6,
    workspace_7,
    workspace_8,
    workspace_9,

    // Tabs
    new_tab,
    close_tab,
    next_tab,
    prev_tab,
    tab_1,
    tab_2,
    tab_3,
    tab_4,
    tab_5,
    tab_6,
    tab_7,
    tab_8,
    tab_9,

    // Panes
    new_column,
    close_pane,
    focus_left,
    focus_right,
    focus_up,
    focus_down,

    // Terminal
    copy,
    paste,
    clear_scrollback,
    find,
    use_selection_for_find,

    // Find navigation
    find_next,
    find_previous,

    // Font
    zoom_in,
    zoom_out,
    zoom_reset,

    // UI
    toggle_sidebar,
    toggle_notifications,
    jump_to_unread,
    flash_focused,
    rename_workspace,
    toggle_pin,

    // Workspace management
    new_workspace,
    close_workspace,
    workspace_switcher,

    // Window
    new_window,
    quit_app,

    // Command palette
    open_command_palette,

    // Tab management
    close_other_tabs,
    rename_tab,

    // Folder
    open_folder,

    // Config
    reload_config,

    // Settings
    open_settings,

    // Layout
    toggle_layout_mode,

    // Move column
    move_column_left,
    move_column_right,

    // Expel
    expel_left,
    expel_right,

    // Resize
    resize_wider,
    resize_narrower,
    maximize_column,
    switch_preset_column_width,
    resize_taller,
    resize_shorter,

    // History
    last_workspace,
    last_pane,

    // Help
    show_shortcuts,

    // Workspace management (command-palette only)
    move_workspace_up,
    move_workspace_down,
    move_workspace_to_top,
    close_other_workspaces,
    close_workspaces_above,
    close_workspaces_below,
    mark_workspace_read,
    mark_workspace_unread,
    equalize_splits,
    clear_workspace_name,

    // Tab management (command-palette only)
    clear_tab_name,
    close_tabs_to_right,

    pub const count = @typeInfo(Action).@"enum".fields.len;
};

/// A keyboard shortcut: a key plus modifier flags.
pub const Keybind = struct {
    key: u32 = 0,
    ctrl: bool = false,
    shift: bool = false,
    alt: bool = false,
    enabled: bool = true,

    pub fn matches(self: Keybind, keyval: u32, base_keyval: u32, is_ctrl: bool, is_shift: bool, is_alt: bool) bool {
        if (!self.enabled) return false;
        if (self.ctrl != is_ctrl) return false;
        if (self.shift != is_shift) return false;
        if (self.alt != is_alt) return false;
        if (self.key == keyval) return true;
        // When shift is held, GTK reports the shifted keyval (e.g. '<' or '?' for comma,
        // ISO_Left_Tab for Tab) which varies by keyboard layout. Compare against the
        // base (unshifted) keyval derived from the hardware keycode to handle all layouts.
        if (self.key == base_keyval) return true;
        return false;
    }
};

var bindings: [Action.count]Keybind = undefined;
var initialized: bool = false;

/// When true, the main key handler yields so the settings dialog can capture the keypress.
pub var recording_shortcut: bool = false;

pub fn register(app: *c.GtkApplication) void {
    _ = app;
}

/// Install key event controller on the given window widget.
/// The WindowState is passed as user_data so keybinds route to the correct window.
pub fn installController(window_widget: *c.GtkWidget, state: *Window.WindowState) void {
    if (!initialized) initDefaults();

    const controller = c.gtk_event_controller_key_new();
    c.gtk_event_controller_set_propagation_phase(@ptrCast(controller), c.GTK_PHASE_CAPTURE);
    _ = c.g_signal_connect_data(
        @as(c.gpointer, @ptrCast(controller)),
        "key-pressed",
        @as(c.GCallback, @ptrCast(&onKeyPressed)),
        @ptrCast(state),
        null,
        0,
    );
    c.gtk_widget_add_controller(window_widget, @ptrCast(controller));
}

fn initDefaults() void {
    for (&bindings) |*b| {
        b.* = .{ .enabled = false };
    }

    // Workspaces
    set(.prev_workspace, .{ .key = c.GDK_KEY_Page_Up, .ctrl = true });
    set(.next_workspace, .{ .key = c.GDK_KEY_Page_Down, .ctrl = true });
    set(.last_workspace, .{ .key = c.GDK_KEY_BackSpace, .ctrl = true, .shift = true });
    set(.last_pane, .{ .key = c.GDK_KEY_BackSpace, .ctrl = true, .alt = true });
    set(.workspace_1, .{ .key = c.GDK_KEY_1, .alt = true });
    set(.workspace_2, .{ .key = c.GDK_KEY_2, .alt = true });
    set(.workspace_3, .{ .key = c.GDK_KEY_3, .alt = true });
    set(.workspace_4, .{ .key = c.GDK_KEY_4, .alt = true });
    set(.workspace_5, .{ .key = c.GDK_KEY_5, .alt = true });
    set(.workspace_6, .{ .key = c.GDK_KEY_6, .alt = true });
    set(.workspace_7, .{ .key = c.GDK_KEY_7, .alt = true });
    set(.workspace_8, .{ .key = c.GDK_KEY_8, .alt = true });
    set(.workspace_9, .{ .key = c.GDK_KEY_9, .alt = true });

    // Tabs
    set(.new_tab, .{ .key = c.GDK_KEY_T, .ctrl = true, .shift = true });
    set(.close_tab, .{ .key = c.GDK_KEY_W, .ctrl = true, .shift = true });
    set(.next_tab, .{ .key = c.GDK_KEY_Tab, .ctrl = true });
    set(.prev_tab, .{ .key = c.GDK_KEY_Tab, .ctrl = true, .shift = true });
    set(.tab_1, .{ .key = c.GDK_KEY_1, .ctrl = true });
    set(.tab_2, .{ .key = c.GDK_KEY_2, .ctrl = true });
    set(.tab_3, .{ .key = c.GDK_KEY_3, .ctrl = true });
    set(.tab_4, .{ .key = c.GDK_KEY_4, .ctrl = true });
    set(.tab_5, .{ .key = c.GDK_KEY_5, .ctrl = true });
    set(.tab_6, .{ .key = c.GDK_KEY_6, .ctrl = true });
    set(.tab_7, .{ .key = c.GDK_KEY_7, .ctrl = true });
    set(.tab_8, .{ .key = c.GDK_KEY_8, .ctrl = true });
    set(.tab_9, .{ .key = c.GDK_KEY_9, .ctrl = true });

    // Panes
    set(.new_column, .{ .key = c.GDK_KEY_Return, .ctrl = true, .shift = true });
    set(.close_pane, .{ .key = c.GDK_KEY_X, .ctrl = true, .shift = true });
    set(.focus_left, .{ .key = c.GDK_KEY_Left, .ctrl = true, .shift = true });
    set(.focus_right, .{ .key = c.GDK_KEY_Right, .ctrl = true, .shift = true });
    set(.focus_up, .{ .key = c.GDK_KEY_Up, .ctrl = true, .shift = true });
    set(.focus_down, .{ .key = c.GDK_KEY_Down, .ctrl = true, .shift = true });

    // Tab management
    set(.close_other_tabs, .{ .key = c.GDK_KEY_T, .ctrl = true, .alt = true });
    set(.rename_tab, .{ .key = c.GDK_KEY_R, .ctrl = true, .alt = true });

    // Terminal
    set(.copy, .{ .key = c.GDK_KEY_C, .ctrl = true, .shift = true });
    set(.paste, .{ .key = c.GDK_KEY_V, .ctrl = true, .shift = true });
    set(.clear_scrollback, .{ .key = c.GDK_KEY_K, .ctrl = true, .shift = true });
    set(.find, .{ .key = c.GDK_KEY_F, .ctrl = true, .shift = true });
    set(.use_selection_for_find, .{ .key = c.GDK_KEY_E, .ctrl = true, .shift = true });
    set(.find_next, .{ .key = c.GDK_KEY_F3 });
    set(.find_previous, .{ .key = c.GDK_KEY_F3, .shift = true });

    // Font
    set(.zoom_in, .{ .key = c.GDK_KEY_equal, .ctrl = true });
    set(.zoom_out, .{ .key = c.GDK_KEY_minus, .ctrl = true });
    set(.zoom_reset, .{ .key = c.GDK_KEY_0, .ctrl = true });

    // UI
    set(.toggle_sidebar, .{ .key = c.GDK_KEY_B, .ctrl = true, .shift = true });
    set(.toggle_notifications, .{ .key = c.GDK_KEY_I, .ctrl = true, .shift = true });
    set(.jump_to_unread, .{ .key = c.GDK_KEY_U, .ctrl = true, .shift = true });
    set(.flash_focused, .{ .key = c.GDK_KEY_H, .ctrl = true, .shift = true });
    set(.rename_workspace, .{ .key = c.GDK_KEY_R, .ctrl = true, .shift = true });
    set(.toggle_pin, .{ .key = c.GDK_KEY_J, .ctrl = true, .shift = true });
    set(.new_workspace, .{ .key = c.GDK_KEY_N, .ctrl = true, .alt = true });
    set(.close_workspace, .{ .key = c.GDK_KEY_W, .ctrl = true, .alt = true });
    set(.workspace_switcher, .{ .key = c.GDK_KEY_G, .ctrl = true, .shift = true });

    // Window
    set(.new_window, .{ .key = c.GDK_KEY_N, .ctrl = true, .shift = true });
    set(.quit_app, .{ .key = c.GDK_KEY_Q, .ctrl = true, .shift = true });

    // Command palette
    set(.open_command_palette, .{ .key = c.GDK_KEY_P, .ctrl = true, .shift = true });

    // Folder
    set(.open_folder, .{ .key = c.GDK_KEY_O, .ctrl = true, .shift = true });

    // Config
    set(.reload_config, .{ .key = c.GDK_KEY_comma, .ctrl = true, .shift = true });

    // Settings
    set(.open_settings, .{ .key = c.GDK_KEY_comma, .ctrl = true });

    // Layout
    set(.toggle_layout_mode, .{ .key = c.GDK_KEY_L, .ctrl = true, .shift = true });

    // Move column
    set(.move_column_left, .{ .key = c.GDK_KEY_A, .ctrl = true, .shift = true });
    set(.move_column_right, .{ .key = c.GDK_KEY_D, .ctrl = true, .shift = true });

    // Expel
    set(.expel_left, .{ .key = c.GDK_KEY_Left, .ctrl = true, .alt = true });
    set(.expel_right, .{ .key = c.GDK_KEY_Right, .ctrl = true, .alt = true });

    // Resize
    set(.resize_wider, .{ .key = c.GDK_KEY_equal, .ctrl = true, .shift = true });
    set(.resize_narrower, .{ .key = c.GDK_KEY_minus, .ctrl = true, .shift = true });
    set(.maximize_column, .{ .key = c.GDK_KEY_M, .ctrl = true, .shift = true });
    set(.switch_preset_column_width, .{ .key = c.GDK_KEY_S, .ctrl = true, .shift = true });
    set(.resize_taller, .{ .key = c.GDK_KEY_equal, .ctrl = true, .alt = true });
    set(.resize_shorter, .{ .key = c.GDK_KEY_minus, .ctrl = true, .alt = true });

    // Help
    set(.show_shortcuts, .{ .key = c.GDK_KEY_F1 });

    initialized = true;
}

/// Reset keybinds to defaults (used before config reload to clear stale overrides).
pub fn resetToDefaults() void {
    initialized = false;
    initDefaults();
}

fn set(action: Action, kb: Keybind) void {
    bindings[@intFromEnum(action)] = kb;
}

/// Apply a keybind override from the config file.
/// action_name: e.g. "new_column" or "new-column"
/// raw_value: e.g. "ctrl+shift+v" or "unset"
pub fn applyConfigOverride(action_name: []const u8, raw_value: []const u8) bool {
    if (!initialized) initDefaults();

    const value = stripQuotes(raw_value);
    const action = parseActionName(action_name) orelse return false;

    if (eql(value, "unset") or eql(value, "none") or eql(value, "disabled")) {
        bindings[@intFromEnum(action)].enabled = false;
        return true;
    }

    if (parseKeybindString(value)) |kb| {
        bindings[@intFromEnum(action)] = kb;
        return true;
    }
    return false;
}

/// Get the display string for a keybind action (e.g., "Ctrl+Shift+V").
/// Returns the number of bytes written, or 0 if not bound.
pub fn displayString(action: Action, buf: []u8) usize {
    const kb = bindings[@intFromEnum(action)];
    if (!kb.enabled) return 0;

    var pos: usize = 0;
    if (kb.ctrl) {
        const s = "Ctrl+";
        if (pos + s.len > buf.len) return 0;
        @memcpy(buf[pos..][0..s.len], s);
        pos += s.len;
    }
    if (kb.shift) {
        const s = "Shift+";
        if (pos + s.len > buf.len) return 0;
        @memcpy(buf[pos..][0..s.len], s);
        pos += s.len;
    }
    if (kb.alt) {
        const s = "Alt+";
        if (pos + s.len > buf.len) return 0;
        @memcpy(buf[pos..][0..s.len], s);
        pos += s.len;
    }

    const key_name = c.gdk_keyval_name(kb.key);
    if (key_name != null) {
        const name = std.mem.span(key_name);
        if (pos + name.len > buf.len) return 0;
        @memcpy(buf[pos..][0..name.len], name);
        pos += name.len;
    }

    return pos;
}

// --- Key event handler ---

fn onKeyPressed(
    _: *c.GtkEventControllerKey,
    keyval: c.guint,
    keycode: c.guint,
    gdk_state: c.GdkModifierType,
    user_data: c.gpointer,
) callconv(.c) c.gboolean {
    // Settings dialog is recording a shortcut — let it handle the event.
    if (recording_shortcut) return 0;

    const state: *Window.WindowState = @ptrCast(@alignCast(user_data));

    const is_ctrl = (gdk_state & c.GDK_CONTROL_MASK) != 0;
    const is_shift = (gdk_state & c.GDK_SHIFT_MASK) != 0;
    const is_alt = (gdk_state & c.GDK_ALT_MASK) != 0;

    // Get the base (unmodified) keyval from the hardware keycode to handle
    // keyboard layouts where shifted punctuation differs (e.g. Shift+comma
    // producing '?' instead of '<').
    var base_keyval: c.guint = keyval;
    if (c.gdk_display_get_default()) |display| {
        var unshifted: c.guint = undefined;
        if (c.gdk_display_translate_key(display, keycode, 0, 0, &unshifted, null, null, null) != 0) {
            base_keyval = unshifted;
        }
    }

    // When the command palette is visible, only allow the palette/switcher toggle keybind
    // and let all other keys pass through to the palette's entry widget.
    if (state.command_palette.visible) {
        const cp_kb = bindings[@intFromEnum(Action.open_command_palette)];
        if (cp_kb.matches(keyval, base_keyval, is_ctrl, is_shift, is_alt)) {
            state.command_palette.toggle();
            return 1;
        }
        const ws_kb = bindings[@intFromEnum(Action.workspace_switcher)];
        if (ws_kb.matches(keyval, base_keyval, is_ctrl, is_shift, is_alt)) {
            state.command_palette.toggleSwitcher();
            return 1;
        }
        return 0; // let palette handle it
    }

    for (bindings, 0..) |kb, i| {
        if (kb.matches(keyval, base_keyval, is_ctrl, is_shift, is_alt)) {
            return executeAction(@enumFromInt(i), state);
        }
    }

    return 0; // not handled — pass to terminal
}

pub fn executeAction(action: Action, state: *Window.WindowState) c.gboolean {
    switch (action) {
        // Workspaces
        .prev_workspace => state.prevWorkspace(),
        .next_workspace => state.nextWorkspace(),
        .last_workspace => _ = state.lastWorkspace(),
        .last_pane => {
            if (state.activeWorkspace()) |ws| _ = ws.lastPane();
        },
        .workspace_1 => state.selectWorkspace(0),
        .workspace_2 => state.selectWorkspace(1),
        .workspace_3 => state.selectWorkspace(2),
        .workspace_4 => state.selectWorkspace(3),
        .workspace_5 => state.selectWorkspace(4),
        .workspace_6 => state.selectWorkspace(5),
        .workspace_7 => state.selectWorkspace(6),
        .workspace_8 => state.selectWorkspace(7),
        .workspace_9 => state.selectWorkspace(8),

        // Tabs (per focused pane group)
        .new_tab => {
            if (state.activeWorkspace()) |ws| ws.newTabInFocusedGroup() catch {};
        },
        .close_tab => {
            if (state.activeWorkspace()) |ws| {
                const ws_empty = ws.closeTabInFocusedGroup();
                if (ws_empty) state.closeWorkspace(state.active_workspace);
            }
        },
        .next_tab => {
            if (state.activeWorkspace()) |ws| ws.nextTabInFocusedGroup();
        },
        .prev_tab => {
            if (state.activeWorkspace()) |ws| ws.prevTabInFocusedGroup();
        },
        .tab_1 => switchTab(state, 0),
        .tab_2 => switchTab(state, 1),
        .tab_3 => switchTab(state, 2),
        .tab_4 => switchTab(state, 3),
        .tab_5 => switchTab(state, 4),
        .tab_6 => switchTab(state, 5),
        .tab_7 => switchTab(state, 6),
        .tab_8 => switchTab(state, 7),
        .tab_9 => switchTab(state, 8),

        // Panes
        .new_column => state.splitFocused(),
        .close_pane => state.closeFocusedPane(),
        .focus_left => state.focusPaneDirection(.left),
        .focus_right => state.focusPaneDirection(.right),
        .focus_up => state.focusPaneDirection(.up),
        .focus_down => state.focusPaneDirection(.down),

        // Terminal
        .copy => {
            const pane = getFocusedPane(state) orelse return 0;
            if (pane.surface) |s| {
                _ = c.ghostty_surface_binding_action(s, "copy_to_clipboard", 17);
            }
        },
        .paste => {
            const pane = getFocusedPane(state) orelse return 0;
            const pane_mod = @import("pane.zig");
            pane_mod.handlePaste(pane);
        },
        .clear_scrollback => {
            const pane = getFocusedPane(state) orelse return 0;
            pane.clearScrollback();
        },
        .find => {
            const pane = getFocusedPane(state) orelse return 0;
            pane.search_overlay.toggle();
        },
        .use_selection_for_find => {
            const pane = getFocusedPane(state) orelse return 0;
            pane.search_overlay.setSearchFromSelection();
        },
        .find_next => {
            const pane = getFocusedPane(state) orelse return 0;
            pane.search_overlay.findNext();
        },
        .find_previous => {
            const pane = getFocusedPane(state) orelse return 0;
            pane.search_overlay.findPrev();
        },

        // Font
        .zoom_in => {
            const pane = getFocusedPane(state) orelse return 0;
            if (pane.surface) |s| {
                _ = c.ghostty_surface_binding_action(s, "increase_font_size:1", 20);
            }
        },
        .zoom_out => {
            const pane = getFocusedPane(state) orelse return 0;
            if (pane.surface) |s| {
                _ = c.ghostty_surface_binding_action(s, "decrease_font_size:1", 20);
            }
        },
        .zoom_reset => {
            const pane = getFocusedPane(state) orelse return 0;
            if (pane.surface) |s| {
                _ = c.ghostty_surface_binding_action(s, "reset_font_size", 15);
            }
        },

        // UI
        .toggle_sidebar => state.toggleSidebar(),
        .toggle_notifications => state.toggleNotificationPopover(),
        .jump_to_unread => state.jumpToUnread(),
        .flash_focused => {
            const pane = getFocusedPane(state) orelse return 0;
            pane.triggerFlash();
        },
        .rename_workspace => state.renameWorkspace(),
        .toggle_pin => state.togglePinWorkspace(),
        .new_workspace => {
            state.newWorkspace() catch {};
        },
        .close_workspace => state.closeActiveWorkspace(),
        .workspace_switcher => state.command_palette.toggleSwitcher(),

        // Window
        .new_window => {
            _ = state.window_manager.newWindow();
        },
        .quit_app => state.quitApp(),

        // Command palette
        .open_command_palette => state.toggleCommandPalette(),

        // Tab management
        .close_other_tabs => {
            if (state.activeWorkspace()) |ws| {
                if (ws.focusedGroup()) |group| {
                    if (group.panels.items.len > 1) {
                        group.closeOtherPanels(group.active_panel);
                    }
                }
            }
        },
        .rename_tab => state.renameTab(),

        // Folder
        .open_folder => state.showOpenFolderDialog(),

        // Config
        .reload_config => {
            state.reloadConfig(false);
        },

        // Settings
        .open_settings => {
            state.showSettings();
        },

        // Layout
        .toggle_layout_mode => {
            if (state.activeWorkspace()) |ws| ws.toggleFocusedColumnLayout();
        },

        // Move column
        .move_column_left => {
            if (state.activeWorkspace()) |ws| {
                ws.moveColumn(.left);
                state.sidebar.refresh();
            }
        },
        .move_column_right => {
            if (state.activeWorkspace()) |ws| {
                ws.moveColumn(.right);
                state.sidebar.refresh();
            }
        },

        // Expel
        .expel_left => {
            if (state.activeWorkspace()) |ws| ws.expelPane(.left);
        },
        .expel_right => {
            if (state.activeWorkspace()) |ws| ws.expelPane(.right);
        },

        // Resize
        .resize_wider => {
            if (state.activeWorkspace()) |ws| ws.resizeColumnWidth(Column.resize_step);
        },
        .resize_narrower => {
            if (state.activeWorkspace()) |ws| ws.resizeColumnWidth(-Column.resize_step);
        },
        .maximize_column => {
            if (state.activeWorkspace()) |ws| ws.maximizeColumn();
        },
        .switch_preset_column_width => {
            if (state.activeWorkspace()) |ws| ws.switchPresetColumnWidth();
        },
        .resize_taller => {
            if (state.activeWorkspace()) |ws| ws.resizeRowHeight(0.2);
        },
        .resize_shorter => {
            if (state.activeWorkspace()) |ws| ws.resizeRowHeight(-0.2);
        },

        // Help
        .show_shortcuts => {
            const shortcuts_overlay = @import("shortcuts_overlay.zig");
            shortcuts_overlay.show(state.window_manager);
        },

        // Workspace management (command-palette)
        .move_workspace_up => {
            const idx = state.active_workspace;
            if (idx > 0) state.reorderWorkspace(idx, idx - 1);
        },
        .move_workspace_down => {
            const idx = state.active_workspace;
            if (idx + 1 < state.workspaces.items.len) state.reorderWorkspace(idx, idx + 1);
        },
        .move_workspace_to_top => {
            const idx = state.active_workspace;
            if (idx > 0) {
                // Find first unpinned position (respect pinned boundary)
                var target: usize = 0;
                for (state.workspaces.items) |w| {
                    if (w.is_pinned) target += 1 else break;
                }
                if (idx > target) state.reorderWorkspace(idx, target);
            }
        },
        .close_other_workspaces => {
            if (state.workspaces.items.len > 1) {
                // Iterate backwards: closeWorkspace adjusts active_workspace when
                // removing below it, so the live index stays correct each iteration.
                var i: usize = state.workspaces.items.len;
                while (i > 0) {
                    i -= 1;
                    if (i != state.active_workspace) state.closeWorkspace(i);
                }
            }
        },
        .close_workspaces_above => {
            var i = state.active_workspace;
            while (i > 0) {
                i -= 1;
                state.closeWorkspace(i);
            }
        },
        .close_workspaces_below => {
            while (state.workspaces.items.len > state.active_workspace + 1) {
                state.closeWorkspace(state.workspaces.items.len - 1);
            }
        },
        .mark_workspace_read => {
            if (state.activeWorkspace()) |ws| {
                state.notif_center.markWorkspaceRead(ws.id, @ptrCast(ws));
            }
        },
        .mark_workspace_unread => {
            if (state.activeWorkspace()) |ws| {
                // Set the first pane as unread so the workspace shows as unread
                for (ws.columns.items) |col| {
                    for (col.groups.items) |grp| {
                        for (grp.panels.items) |panel| {
                            if (panel.asTerminal()) |pane| {
                                pane.has_unread = true;
                                state.sidebar.refresh();
                                state.sidebar.setActive(state.active_workspace);
                                return 1;
                            }
                        }
                    }
                }
            }
        },
        .equalize_splits => {
            if (state.activeWorkspace()) |ws| {
                const live = ws.liveColumnCount();
                if (live > 1) {
                    const equal_w = 1.0 / @as(f64, @floatFromInt(live));
                    for (ws.columns.items) |*col| {
                        if (!col.closing) col.target_width = equal_w;
                    }
                }
            }
        },
        .clear_workspace_name => {
            if (state.activeWorkspace()) |ws| {
                ws.clearCustomTitle();
                state.sidebar.refresh();
                state.sidebar.setActive(state.active_workspace);
            }
        },

        // Tab management (command-palette)
        .clear_tab_name => {
            const pane = getFocusedPane(state) orelse return 0;
            pane.clearCustomTitle();
            if (state.activeWorkspace()) |ws| {
                if (ws.focusedGroup()) |group| {
                    const title = pane.getCachedTitle() orelse "Terminal";
                    group.updateTitleForPane(pane.id, title);
                }
            }
        },
        .close_tabs_to_right => {
            if (state.activeWorkspace()) |ws| {
                if (ws.focusedGroup()) |group| {
                    group.closePanelsToRight(group.active_panel);
                }
            }
        },
    }
    return 1;
}

fn switchTab(state: *Window.WindowState, index: usize) void {
    if (state.activeWorkspace()) |ws| ws.switchTabInFocusedGroup(index);
}

fn getFocusedPane(state: *Window.WindowState) ?*Pane {
    const ws = state.activeWorkspace() orelse return null;
    const group = ws.focusedGroup() orelse return null;
    return group.focusedTerminalPane();
}

// --- Keybind string parsing ---

fn parseActionName(name: []const u8) ?Action {
    // Normalize hyphens to underscores
    var buf: [64]u8 = undefined;
    if (name.len > buf.len) return null;
    for (name, 0..) |ch, i| {
        buf[i] = if (ch == '-') '_' else ch;
    }
    const normalized = buf[0..name.len];

    const fields = @typeInfo(Action).@"enum".fields;
    inline for (fields) |field| {
        if (std.mem.eql(u8, normalized, field.name)) {
            return @enumFromInt(field.value);
        }
    }
    return null;
}

fn parseKeybindString(s: []const u8) ?Keybind {
    var kb = Keybind{ .key = 0, .enabled = true };
    var has_key = false;
    var iter = std.mem.splitScalar(u8, s, '+');

    while (iter.next()) |raw_part| {
        const part = std.mem.trim(u8, raw_part, " \t");
        if (part.len == 0) continue;

        if (asciiEqlIgnoreCase(part, "ctrl") or asciiEqlIgnoreCase(part, "control")) {
            kb.ctrl = true;
        } else if (asciiEqlIgnoreCase(part, "shift")) {
            kb.shift = true;
        } else if (asciiEqlIgnoreCase(part, "alt")) {
            kb.alt = true;
        } else if (asciiEqlIgnoreCase(part, "super")) {
            // Ignored — super/meta not supported as modifier
        } else {
            kb.key = resolveKeyName(part) orelse return null;
            has_key = true;
        }
    }

    if (!has_key) return null;

    // When shift is held, GTK reports uppercase keyval for letters.
    // Convert stored key to uppercase to match runtime behavior.
    if (kb.shift and kb.key >= c.GDK_KEY_a and kb.key <= c.GDK_KEY_z) {
        kb.key = kb.key - @as(u32, c.GDK_KEY_a) + @as(u32, c.GDK_KEY_A);
    }

    return kb;
}

fn resolveKeyName(name: []const u8) ?u32 {
    // Common aliases (case-insensitive)
    if (asciiEqlIgnoreCase(name, "pageup") or asciiEqlIgnoreCase(name, "page_up")) return c.GDK_KEY_Page_Up;
    if (asciiEqlIgnoreCase(name, "pagedown") or asciiEqlIgnoreCase(name, "page_down")) return c.GDK_KEY_Page_Down;
    if (asciiEqlIgnoreCase(name, "tab")) return c.GDK_KEY_Tab;
    if (asciiEqlIgnoreCase(name, "return") or asciiEqlIgnoreCase(name, "enter")) return c.GDK_KEY_Return;
    if (asciiEqlIgnoreCase(name, "escape") or asciiEqlIgnoreCase(name, "esc")) return c.GDK_KEY_Escape;
    if (asciiEqlIgnoreCase(name, "space")) return c.GDK_KEY_space;
    if (asciiEqlIgnoreCase(name, "left")) return c.GDK_KEY_Left;
    if (asciiEqlIgnoreCase(name, "right")) return c.GDK_KEY_Right;
    if (asciiEqlIgnoreCase(name, "up")) return c.GDK_KEY_Up;
    if (asciiEqlIgnoreCase(name, "down")) return c.GDK_KEY_Down;
    if (asciiEqlIgnoreCase(name, "backspace")) return c.GDK_KEY_BackSpace;
    if (asciiEqlIgnoreCase(name, "delete") or asciiEqlIgnoreCase(name, "del")) return c.GDK_KEY_Delete;
    if (asciiEqlIgnoreCase(name, "home")) return c.GDK_KEY_Home;
    if (asciiEqlIgnoreCase(name, "end")) return c.GDK_KEY_End;
    if (asciiEqlIgnoreCase(name, "insert") or asciiEqlIgnoreCase(name, "ins")) return c.GDK_KEY_Insert;

    // F-keys: F1-F12
    if (name.len >= 2 and name.len <= 3 and (name[0] == 'f' or name[0] == 'F')) {
        if (std.fmt.parseInt(u32, name[1..], 10) catch null) |n| {
            if (n >= 1 and n <= 12) return @as(u32, c.GDK_KEY_F1) + (n - 1);
        }
    }

    // Single character
    if (name.len == 1) {
        const ch = name[0];
        if (ch >= 'A' and ch <= 'Z') return @as(u32, c.GDK_KEY_a) + @as(u32, ch - 'A');
        if (ch >= 'a' and ch <= 'z') return @as(u32, c.GDK_KEY_a) + @as(u32, ch - 'a');
        if (ch >= '0' and ch <= '9') return @as(u32, c.GDK_KEY_0) + @as(u32, ch - '0');
        return switch (ch) {
            '=' => @as(u32, c.GDK_KEY_equal),
            '-' => @as(u32, c.GDK_KEY_minus),
            '[' => @as(u32, c.GDK_KEY_bracketleft),
            ']' => @as(u32, c.GDK_KEY_bracketright),
            '/' => @as(u32, c.GDK_KEY_slash),
            '\\' => @as(u32, c.GDK_KEY_backslash),
            ',' => @as(u32, c.GDK_KEY_comma),
            '.' => @as(u32, c.GDK_KEY_period),
            ';' => @as(u32, c.GDK_KEY_semicolon),
            '\'' => @as(u32, c.GDK_KEY_apostrophe),
            '`' => @as(u32, c.GDK_KEY_grave),
            else => null,
        };
    }

    // Multi-char key names (e.g., "equal", "minus")
    if (eql(name, "equal")) return c.GDK_KEY_equal;
    if (eql(name, "minus")) return c.GDK_KEY_minus;
    if (eql(name, "plus")) return c.GDK_KEY_plus;

    // Fallback: try GDK's own name lookup
    var buf: [64]u8 = undefined;
    if (name.len >= buf.len) return null;
    @memcpy(buf[0..name.len], name);
    buf[name.len] = 0;
    const val = c.gdk_keyval_from_name(@as([*c]const u8, @ptrCast(&buf)));
    if (val == c.GDK_KEY_VoidSymbol or val == 0) return null;
    return val;
}

// --- Helpers ---

fn eql(a: []const u8, b: []const u8) bool {
    return std.mem.eql(u8, a, b);
}

fn asciiEqlIgnoreCase(a: []const u8, b: []const u8) bool {
    return std.ascii.eqlIgnoreCase(a, b);
}

pub fn setBinding(action: Action, kb: Keybind) void {
    if (!initialized) initDefaults();
    bindings[@intFromEnum(action)] = kb;
}

pub fn writeKeybinds(writer: anytype) !void {
    try writer.print("[keybinds]\n", .{});
    const fields = @typeInfo(Action).@"enum".fields;
    inline for (fields) |field| {
        const action: Action = @enumFromInt(field.value);
        const kb = bindings[@intFromEnum(action)];
        if (!kb.enabled) {
            try writer.print("{s} = \"unset\"\n", .{field.name});
        } else {
            var display_buf: [64]u8 = undefined;
            const len = displayString(action, &display_buf);
            if (len > 0) {
                try writer.print("{s} = \"{s}\"\n", .{ field.name, display_buf[0..len] });
            }
        }
    }
}

fn stripQuotes(val: []const u8) []const u8 {
    if (val.len >= 2 and val[0] == '"' and val[val.len - 1] == '"') {
        return val[1 .. val.len - 1];
    }
    return val;
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

test "parseActionName: simple underscore name" {
    try std.testing.expectEqual(@as(?Action, .new_tab), parseActionName("new_tab"));
    try std.testing.expectEqual(@as(?Action, .copy), parseActionName("copy"));
    try std.testing.expectEqual(@as(?Action, .toggle_sidebar), parseActionName("toggle_sidebar"));
}

test "parseActionName: hyphens normalized to underscores" {
    try std.testing.expectEqual(@as(?Action, .new_tab), parseActionName("new-tab"));
    try std.testing.expectEqual(@as(?Action, .close_pane), parseActionName("close-pane"));
    try std.testing.expectEqual(@as(?Action, .close_pane), parseActionName("close-pane"));
}

test "parseActionName: invalid name returns null" {
    try std.testing.expect(parseActionName("nonexistent_action") == null);
    try std.testing.expect(parseActionName("") == null);
}

test "parseKeybindString: simple modifier + key" {
    const kb = parseKeybindString("ctrl+v") orelse unreachable;
    try std.testing.expect(kb.ctrl);
    try std.testing.expect(!kb.shift);
    try std.testing.expect(!kb.alt);
    try std.testing.expect(kb.enabled);
    try std.testing.expectEqual(@as(u32, c.GDK_KEY_v), kb.key);
}

test "parseKeybindString: multiple modifiers" {
    const kb = parseKeybindString("ctrl+shift+alt+a") orelse unreachable;
    try std.testing.expect(kb.ctrl);
    try std.testing.expect(kb.shift);
    try std.testing.expect(kb.alt);
    // shift + letter → uppercase
    try std.testing.expectEqual(@as(u32, c.GDK_KEY_A), kb.key);
}

test "parseKeybindString: case insensitive modifiers" {
    const kb = parseKeybindString("CTRL+SHIFT+v") orelse unreachable;
    try std.testing.expect(kb.ctrl);
    try std.testing.expect(kb.shift);

    const kb2 = parseKeybindString("Ctrl+Shift+v") orelse unreachable;
    try std.testing.expect(kb2.ctrl);
    try std.testing.expect(kb2.shift);
}

test "parseKeybindString: control alias" {
    const kb = parseKeybindString("control+c") orelse unreachable;
    try std.testing.expect(kb.ctrl);
    try std.testing.expectEqual(@as(u32, c.GDK_KEY_c), kb.key);
}

test "parseKeybindString: super modifier is ignored" {
    const kb = parseKeybindString("super+ctrl+a") orelse unreachable;
    try std.testing.expect(kb.ctrl);
    try std.testing.expect(!kb.shift);
    try std.testing.expect(!kb.alt);
    try std.testing.expectEqual(@as(u32, c.GDK_KEY_a), kb.key);
}

test "parseKeybindString: no key returns null" {
    try std.testing.expect(parseKeybindString("ctrl+shift") == null);
    try std.testing.expect(parseKeybindString("") == null);
}

test "parseKeybindString: shift converts letter to uppercase" {
    const kb = parseKeybindString("shift+z") orelse unreachable;
    try std.testing.expectEqual(@as(u32, c.GDK_KEY_Z), kb.key);
}

test "parseKeybindString: digit key" {
    const kb = parseKeybindString("alt+1") orelse unreachable;
    try std.testing.expect(kb.alt);
    try std.testing.expectEqual(@as(u32, c.GDK_KEY_1), kb.key);
}

test "resolveKeyName: single character keys" {
    try std.testing.expectEqual(@as(?u32, c.GDK_KEY_a), resolveKeyName("a"));
    try std.testing.expectEqual(@as(?u32, c.GDK_KEY_a), resolveKeyName("A")); // uppercase → lowercase keyval
    try std.testing.expectEqual(@as(?u32, c.GDK_KEY_0), resolveKeyName("0"));
    try std.testing.expectEqual(@as(?u32, c.GDK_KEY_equal), resolveKeyName("="));
    try std.testing.expectEqual(@as(?u32, c.GDK_KEY_minus), resolveKeyName("-"));
    try std.testing.expectEqual(@as(?u32, c.GDK_KEY_comma), resolveKeyName(","));
    try std.testing.expectEqual(@as(?u32, c.GDK_KEY_slash), resolveKeyName("/"));
}

test "resolveKeyName: F-keys" {
    try std.testing.expectEqual(@as(?u32, c.GDK_KEY_F1), resolveKeyName("F1"));
    try std.testing.expectEqual(@as(?u32, c.GDK_KEY_F1), resolveKeyName("f1"));
    try std.testing.expectEqual(@as(?u32, c.GDK_KEY_F12), resolveKeyName("F12"));
}

test "resolveKeyName: aliases" {
    try std.testing.expectEqual(@as(?u32, c.GDK_KEY_Page_Up), resolveKeyName("pageup"));
    try std.testing.expectEqual(@as(?u32, c.GDK_KEY_Page_Up), resolveKeyName("PageUp"));
    try std.testing.expectEqual(@as(?u32, c.GDK_KEY_Page_Up), resolveKeyName("page_up"));
    try std.testing.expectEqual(@as(?u32, c.GDK_KEY_Tab), resolveKeyName("tab"));
    try std.testing.expectEqual(@as(?u32, c.GDK_KEY_Return), resolveKeyName("return"));
    try std.testing.expectEqual(@as(?u32, c.GDK_KEY_Return), resolveKeyName("enter"));
    try std.testing.expectEqual(@as(?u32, c.GDK_KEY_Escape), resolveKeyName("escape"));
    try std.testing.expectEqual(@as(?u32, c.GDK_KEY_Escape), resolveKeyName("esc"));
    try std.testing.expectEqual(@as(?u32, c.GDK_KEY_BackSpace), resolveKeyName("backspace"));
    try std.testing.expectEqual(@as(?u32, c.GDK_KEY_Delete), resolveKeyName("delete"));
    try std.testing.expectEqual(@as(?u32, c.GDK_KEY_Delete), resolveKeyName("del"));
}

test "resolveKeyName: multi-char names" {
    try std.testing.expectEqual(@as(?u32, c.GDK_KEY_equal), resolveKeyName("equal"));
    try std.testing.expectEqual(@as(?u32, c.GDK_KEY_minus), resolveKeyName("minus"));
    try std.testing.expectEqual(@as(?u32, c.GDK_KEY_plus), resolveKeyName("plus"));
}

test "Keybind.matches: exact keyval match" {
    const kb = Keybind{ .key = c.GDK_KEY_v, .ctrl = true, .enabled = true };
    try std.testing.expect(kb.matches(c.GDK_KEY_v, c.GDK_KEY_v, true, false, false));
}

test "Keybind.matches: modifier mismatch" {
    const kb = Keybind{ .key = c.GDK_KEY_v, .ctrl = true, .enabled = true };
    // No ctrl held
    try std.testing.expect(!kb.matches(c.GDK_KEY_v, c.GDK_KEY_v, false, false, false));
    // Extra shift
    try std.testing.expect(!kb.matches(c.GDK_KEY_v, c.GDK_KEY_v, true, true, false));
}

test "Keybind.matches: base_keyval fallback" {
    const kb = Keybind{ .key = c.GDK_KEY_comma, .ctrl = true, .shift = true, .enabled = true };
    // When shift+comma is pressed, GTK may report '<' as keyval but comma as base_keyval
    try std.testing.expect(kb.matches(c.GDK_KEY_less, c.GDK_KEY_comma, true, true, false));
}

test "Keybind.matches: disabled binding never matches" {
    const kb = Keybind{ .key = c.GDK_KEY_v, .ctrl = true, .enabled = false };
    try std.testing.expect(!kb.matches(c.GDK_KEY_v, c.GDK_KEY_v, true, false, false));
}
