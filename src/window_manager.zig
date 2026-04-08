const std = @import("std");
const c = @import("c.zig").c;
const app_mod = @import("app.zig");
const Window = @import("window.zig");
const session = @import("session.zig");

var gpa = std.heap.GeneralPurposeAllocator(.{}){};

pub const WindowManager = struct {
    allocator: std.mem.Allocator,
    windows: std.ArrayList(*Window.WindowState),
    active_window: ?*Window.WindowState = null,
    app: *c.GtkApplication,
    autosave_timer: c.guint = 0,

    pub fn init(app: *c.GtkApplication) *WindowManager {
        const alloc = gpa.allocator();
        const self = alloc.create(WindowManager) catch @panic("OOM");
        self.* = .{
            .allocator = alloc,
            .windows = .empty,
            .app = app,
        };
        self.autosave_timer = c.g_timeout_add_seconds(
            session.AUTOSAVE_INTERVAL_SECS,
            @ptrCast(&onAutoSave),
            @ptrCast(self),
        );
        return self;
    }

    /// Create a new window with a default workspace.
    pub fn newWindow(self: *WindowManager) ?*Window.WindowState {
        const state = Window.create(self) catch return null;
        self.windows.append(self.allocator, state) catch return null;
        self.active_window = state;
        state.newWorkspace() catch {};
        c.gtk_window_present(@as(*c.GtkWindow, @ptrCast(state.gtk_window)));
        return state;
    }

    pub fn closeWindow(self: *WindowManager, win: *Window.WindowState) void {
        const is_shutdown = app_mod.shutting_down;
        const is_last_window = self.windows.items.len <= 1;

        // Save session with scrollback when this is the last window or
        // shutting down — must happen BEFORE removing from the list so the
        // closing window's state is captured for next-launch restore.
        if (is_last_window or is_shutdown) {
            session.saveAll(self, true);
        }

        // Mark as destroyed so in-flight background work won't touch state
        win.destroyed = true;

        // Cancel any pending sidebar idle refresh
        win.sidebar.cancelPendingRefresh();

        // Stop all pane timers to prevent dangling callbacks
        win.stopAllPaneTimers();

        // Stop metadata refresh timer
        if (win.metadata_timer != 0) {
            _ = c.g_source_remove(win.metadata_timer);
            win.metadata_timer = 0;
        }

        // Stop vim check timer
        if (win.vim_check_timer != 0) {
            _ = c.g_source_remove(win.vim_check_timer);
            win.vim_check_timer = 0;
        }

        // Stop port scan timer
        if (win.port_scan_timer != 0) {
            _ = c.g_source_remove(win.port_scan_timer);
            win.port_scan_timer = 0;
        }

        // Remove from window list
        for (self.windows.items, 0..) |w, i| {
            if (w == win) {
                _ = self.windows.orderedRemove(i);
                break;
            }
        }

        // Update active window
        if (self.active_window == win) {
            self.active_window = if (self.windows.items.len > 0) self.windows.items[0] else null;
        }

        // If no windows remain, trigger application quit which runs
        // onShutdown → cleanup → exit(0).  We go through the GTK path
        // so socket files, etc. are cleaned up properly.
        if (self.windows.items.len == 0 or is_shutdown) {
            c.g_application_quit(@ptrCast(self.app));
            return;
        }

        // Other windows still open — safe to clean up ghostty surfaces
        // since the main loop is still running for the remaining windows.
        for (win.workspaces.items) |ws| {
            ws.destroy();
        }
        win.workspaces.clearRetainingCapacity();

        // Save session with remaining windows (no scrollback for speed)
        session.saveAll(self, false);
    }

    pub fn setActiveWindow(self: *WindowManager, win: *Window.WindowState) void {
        self.active_window = win;
    }

    pub fn findByWorkspaceId(self: *WindowManager, workspace_id: u64) ?*Window.WindowState {
        for (self.windows.items) |state| {
            for (state.workspaces.items) |ws| {
                if (ws.id == workspace_id) return state;
            }
        }
        return null;
    }

    pub fn findByPaneId(self: *WindowManager, pane_id: u64) ?*Window.WindowState {
        for (self.windows.items) |state| {
            for (state.workspaces.items) |ws| {
                if (ws.findPaneById(pane_id) != null) return state;
            }
        }
        return null;
    }

    /// Move a workspace from one window to another by workspace ID.
    /// Returns true if the move succeeded.
    pub fn moveWorkspaceToWindow(self: *WindowManager, workspace_id: u64, target_window: *Window.WindowState) bool {
        // Find the source window and workspace index
        var source_window: ?*Window.WindowState = null;
        var ws_idx: ?usize = null;
        for (self.windows.items) |state| {
            for (state.workspaces.items, 0..) |ws, i| {
                if (ws.id == workspace_id) {
                    source_window = state;
                    ws_idx = i;
                    break;
                }
            }
            if (source_window != null) break;
        }

        const src = source_window orelse return false;
        const idx = ws_idx orelse return false;

        // Don't move to the same window
        if (src == target_window) return false;

        // Detach from source
        const ws = src.detachWorkspace(idx) orelse return false;

        // Attach to target
        target_window.attachWorkspace(ws);

        // Present the target window
        c.gtk_window_present(@as(*c.GtkWindow, @ptrCast(target_window.gtk_window)));

        return true;
    }

    pub fn reloadAllConfigs(self: *WindowManager, silent: bool) void {
        for (self.windows.items) |state| {
            state.reloadConfig(silent);
        }
    }

    fn onAutoSave(data: c.gpointer) callconv(.c) c.gboolean {
        const self: *WindowManager = @ptrCast(@alignCast(data));
        session.saveAll(self, false);
        return 1; // G_SOURCE_CONTINUE
    }
};
