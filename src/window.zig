const std = @import("std");
const builtin = @import("builtin");
const c = @import("c.zig").c;
const config_mod = @import("config.zig");
const Workspace = @import("workspace.zig").Workspace;
const sidebar_mod = @import("sidebar.zig");
const Sidebar = sidebar_mod.Sidebar;
const vtab_mod = @import("vertical_tab_bar.zig");
const ContextAction = sidebar_mod.ContextAction;
const Panel = @import("panel.zig").Panel;
const git_info = @import("git_info.zig");
const notification = @import("notification.zig");
const notification_panel = @import("notification_panel.zig");
const sound = @import("sound.zig");
const WindowManager = @import("window_manager.zig").WindowManager;
const command_palette_mod = @import("command_palette.zig");
const settings_mod = @import("settings.zig");
const blur = @import("blur.zig");
const kde_decoration = @import("kde_decoration.zig");
const port_scan = @import("port_scan.zig");
const session_mod = @import("session.zig");

/// Window decoration currently in effect for a single window.  Derived from
/// config.decoration_mode plus environment (is_gnome) plus platform
/// capability (kde_decoration.isSsdAvailable).  Only two concrete states
/// exist at runtime; "auto" in the config resolves to one of them.
const EffectiveDecoration = enum { csd, ssd };

/// Resolve the effective decoration from the user's config choice, the
/// current desktop, and the compositor's SSD capability.  Pure function.
fn resolveEffectiveDecoration(mode: config_mod.DecorationMode, is_gnome: bool) EffectiveDecoration {
    return switch (mode) {
        .auto => if (is_gnome) .csd else (if (kde_decoration.isSsdAvailable()) .ssd else .csd),
        .csd => .csd,
        .ssd => if (kde_decoration.isSsdAvailable()) .ssd else .csd,
    };
}

const MetadataResult = struct {
    workspace_id: u64,
    cwd: [512]u8 = .{0} ** 512,
    cwd_len: usize = 0,
    git_branch: [128]u8 = .{0} ** 128,
    git_branch_len: usize = 0,
    git_dirty: bool = false,
    shell_has_git: bool = false,
};

const MetadataWork = struct {
    state: *WindowState,
    results: [64]MetadataResult = undefined,
    result_count: usize = 0,
};

const PortScanWorkspaceEntry = struct {
    workspace_id: u64,
    panel_ids: [64]u64 = [_]u64{0} ** 64,
    panel_count: usize = 0,
};

const PortScanResult = struct {
    workspace_id: u64,
    ports: [16]u16 = [_]u16{0} ** 16,
    ports_len: usize = 0,
};

const PortScanWork = struct {
    state: *WindowState,
    entries: [64]PortScanWorkspaceEntry = undefined,
    entry_count: usize = 0,
    results: [64]PortScanResult = undefined,
    result_count: usize = 0,
};

pub const WindowState = struct {
    workspaces: std.ArrayList(*Workspace),
    active_workspace: usize = 0,
    last_workspace_id: ?u64 = null,
    sidebar: Sidebar,
    notif_panel: notification_panel.NotificationPanel = undefined,
    notif_popover: ?*c.GtkWidget = null,
    sidebar_revealer: *c.GtkRevealer = undefined,
    content_stack: *c.GtkStack,
    hbox: *c.GtkWidget = undefined,
    sidebar_visible: bool = true,
    notif_center: notification.NotificationCenter = .{},
    sound_player: sound.SoundPlayer = .{},
    config: config_mod.Config = .{},
    alloc: std.mem.Allocator,
    window_manager: *WindowManager,
    gtk_window: *c.GtkWidget,
    metadata_timer: c.guint = 0,
    vim_check_timer: c.guint = 0,
    port_scan_timer: c.guint = 0,
    command_palette: command_palette_mod.CommandPalette = undefined,
    toast_overlay: *c.GtkWidget = undefined,
    banner: ?*c.GtkWidget = null,
    banner_is_config_error: bool = false,
    metadata_in_flight: bool = false,
    port_scan_in_flight: bool = false,
    destroyed: bool = false,
    next_port_ordinal: u32 = 0,

    // Chrome state, tracked so applyDecorationMode can rebuild at runtime.
    // banner_box is the stable content subtree (banner + toast + overlay + hbox)
    // that gets reparented between CSD (inside toolbar_view) and SSD (direct
    // window content).
    banner_box: *c.GtkWidget = undefined,
    toolbar_view: ?*c.GtkWidget = null,
    effective_decoration: EffectiveDecoration = .csd,
    // Cached XDG_CURRENT_DESKTOP contains "GNOME".  The env var doesn't change
    // during a process lifetime, so resolve once at create() and reuse.
    is_gnome: bool = false,
    // Set to true once the user has been warned in this session that their
    // chosen ssd mode isn't honorable on this compositor.  Prevents a toast
    // on every reloadConfig tick.
    ssd_unavailable_warned: bool = false,

    pub fn activeWorkspace(self: *WindowState) ?*Workspace {
        if (self.workspaces.items.len == 0) return null;
        return self.workspaces.items[self.active_workspace];
    }

    /// Update the GTK window title from the focused pane's terminal title.
    pub fn updateWindowTitle(self: *WindowState) void {
        const ws = self.activeWorkspace() orelse return;
        const title = blk: {
            const fg = ws.focusedGroup() orelse break :blk null;
            const fp = fg.focusedTerminalPane() orelse break :blk null;
            break :blk fp.getDisplayTitle();
        };
        if (title) |t| {
            // We need a null-terminated copy for GTK
            var buf: [257]u8 = undefined;
            const len = @min(t.len, buf.len - 1);
            @memcpy(buf[0..len], t[0..len]);
            buf[len] = 0;
            c.gtk_window_set_title(@as(*c.GtkWindow, @ptrCast(self.gtk_window)), &buf);
        } else {
            c.gtk_window_set_title(@as(*c.GtkWindow, @ptrCast(self.gtk_window)), "seance");
        }
    }

    pub fn selectWorkspace(self: *WindowState, index: usize) void {
        if (index >= self.workspaces.items.len) return;

        // Save workspace history before switching
        const old_index = self.active_workspace;
        if (old_index != index and old_index < self.workspaces.items.len) {
            self.last_workspace_id = self.workspaces.items[old_index].id;
        }

        // Compute slide direction based on sidebar display order
        self.sidebar.ensureDisplayOrder();
        const old_display = self.sidebar.displayIndexOf(old_index);
        const new_display = self.sidebar.displayIndexOf(index);

        const transition: c_uint = if (old_display != null and new_display != null) blk: {
            const od = old_display.?;
            const nd = new_display.?;
            if (nd > od) break :blk c.GTK_STACK_TRANSITION_TYPE_SLIDE_UP;
            if (nd < od) break :blk c.GTK_STACK_TRANSITION_TYPE_SLIDE_DOWN;
            break :blk c.GTK_STACK_TRANSITION_TYPE_CROSSFADE;
        } else c.GTK_STACK_TRANSITION_TYPE_CROSSFADE;

        c.gtk_stack_set_transition_type(self.content_stack, transition);

        // Unfocus pane in current workspace before switching
        if (self.active_workspace < self.workspaces.items.len) {
            const old_ws = self.workspaces.items[self.active_workspace];
            if (old_ws.focusedGroup()) |fg| fg.unfocus();
        }
        self.active_workspace = index;
        const ws = self.workspaces.items[index];

        var name_buf: [32]u8 = undefined;
        const name = std.fmt.bufPrintZ(&name_buf, "ws-{d}", .{ws.id}) catch "ws";
        c.gtk_stack_set_visible_child_name(self.content_stack, name.ptr);

        // Invalidate cached viewport dimensions so the next onTick()
        // re-reads them and forces applyLayout(). While hidden in the
        // GtkStack the tick callback doesn't fire, so stale cache +
        // no active animations can leave columns unpositioned.
        ws.cached_width = 0;
        ws.cached_height = 0;

        self.sidebar.setActive(index);

        // Force resize on all panes so they redraw after being hidden in the stack
        // Also ensure all groups start unfocused so only the intended one gets focus styling.
        for (ws.columns.items) |col| {
            for (col.groups.items) |grp| {
                grp.unfocus();
                c.gtk_widget_queue_resize(grp.getWidget());
            }
        }

        if (ws.focusedGroup()) |fg| {
            // Capture before fg.focus() clears it
            const pane_had_unread = if (fg.focusedTerminalPane()) |fp| fp.has_unread else false;

            // focus() → pane.focus() marks only this pane's notifications
            // as read and refreshes the sidebar/badge.
            fg.focus();

            // Restore workspace title from the focused pane's cached terminal title
            if (fg.focusedTerminalPane()) |fp| {
                if (fp.getCachedTitle()) |title| {
                    ws.setAutoTitle(title);
                }
                if (pane_had_unread) {
                    fp.triggerFlash();
                }
            }
        }
        self.updateWindowTitle();
    }

    pub fn newWorkspace(self: *WindowState) !void {
        const ws = try Workspace.create(self.alloc, "Terminal");
        ws.port_ordinal = self.next_port_ordinal;
        self.next_port_ordinal += 1;

        var name_buf: [32]u8 = undefined;
        const name = std.fmt.bufPrintZ(&name_buf, "ws-{d}", .{ws.id}) catch "ws";
        _ = c.gtk_stack_add_named(self.content_stack, ws.container, name.ptr);

        // Insert workspace after the currently focused one
        const target_idx: usize = blk: {
            const idx = if (self.workspaces.items.len == 0) 0 else self.active_workspace + 1;
            try self.workspaces.insert(self.alloc, idx, ws);
            break :blk idx;
        };

        self.sidebar.refresh();
        self.selectWorkspace(target_idx);
    }

    pub fn closeWorkspace(self: *WindowState, index: usize) void {
        if (index >= self.workspaces.items.len) return;
        const ws = self.workspaces.items[index];

        // Clear workspace history if it points to the closing workspace
        if (self.last_workspace_id) |lid| {
            if (lid == ws.id) self.last_workspace_id = null;
        }

        // Purge notifications for the closing workspace
        _ = self.notif_center.store.removeForWorkspace(ws.id);

        ws.disconnectSignals();
        // Hold a ref so the widget tree survives past gtk_stack_remove.
        // ws.destroy() needs living widgets to disconnect pane signal handlers
        // (gl_area, etc.) before they are finalized.
        const container = ws.container;
        _ = c.g_object_ref(@ptrCast(container));
        c.gtk_stack_remove(self.content_stack, container);
        _ = self.workspaces.orderedRemove(index);
        ws.destroy(); // frees the Workspace struct — ws is now dangling
        c.g_object_unref(@ptrCast(container));

        self.sidebar.refresh();
        if (self.workspaces.items.len == 0) {
            // Create a new workspace if all are closed
            self.newWorkspace() catch {};
        } else if (index == self.active_workspace) {
            // Closed the active workspace: select a neighbor
            if (self.active_workspace >= self.workspaces.items.len) {
                self.active_workspace = self.workspaces.items.len - 1;
            }
            self.selectWorkspace(self.active_workspace);
        } else {
            // Closed a non-active workspace: adjust index for array shift
            if (index < self.active_workspace) {
                self.active_workspace -= 1;
            }
            self.sidebar.setActive(self.active_workspace);
        }
    }

    /// Detach a workspace from this window without destroying it.
    /// The workspace's container widget is ref'd and removed from the content stack.
    /// Returns the detached workspace, or null on invalid index.
    pub fn detachWorkspace(self: *WindowState, index: usize) ?*Workspace {
        if (index >= self.workspaces.items.len) return null;
        const ws = self.workspaces.items[index];

        // Unfocus pane if this is the active workspace
        if (self.active_workspace == index) {
            if (ws.focusedGroup()) |fg| fg.unfocus();
        }

        // Hold a ref so the widget tree survives removal from the stack
        _ = c.g_object_ref(@ptrCast(ws.container));
        c.gtk_stack_remove(self.content_stack, ws.container);
        _ = self.workspaces.orderedRemove(index);

        self.sidebar.refresh();
        if (self.workspaces.items.len == 0) {
            self.active_workspace = 0;
            self.newWorkspace() catch {};
        } else if (index == self.active_workspace) {
            // Detached the active workspace: select a neighbor
            if (self.active_workspace >= self.workspaces.items.len) {
                self.active_workspace = self.workspaces.items.len - 1;
            }
            self.selectWorkspace(self.active_workspace);
        } else {
            // Detached a non-active workspace: adjust index for array shift
            if (index < self.active_workspace) {
                self.active_workspace -= 1;
            }
            self.sidebar.setActive(self.active_workspace);
        }

        return ws;
    }

    /// Attach a workspace (from another window) to this window.
    /// The workspace's container widget is added to the content stack and the ref is released.
    pub fn attachWorkspace(self: *WindowState, ws: *Workspace) void {
        var name_buf: [32]u8 = undefined;
        const name = std.fmt.bufPrintZ(&name_buf, "ws-{d}", .{ws.id}) catch "ws";
        _ = c.gtk_stack_add_named(self.content_stack, ws.container, name.ptr);

        // Release the extra ref taken during detach (stack now owns the widget)
        c.g_object_unref(@ptrCast(ws.container));

        self.workspaces.append(self.alloc, ws) catch return;
        self.sidebar.refresh();
        self.selectWorkspace(self.workspaces.items.len - 1);
    }

    pub fn nextWorkspace(self: *WindowState) void {
        if (self.workspaces.items.len <= 1) return;
        if (self.active_workspace + 1 >= self.workspaces.items.len) return;
        self.selectWorkspace(self.active_workspace + 1);
    }

    pub fn prevWorkspace(self: *WindowState) void {
        if (self.workspaces.items.len <= 1) return;
        if (self.active_workspace == 0) return;
        self.selectWorkspace(self.active_workspace - 1);
    }

    /// Switch to the last-active workspace. Returns the workspace if switched, null if no history.
    pub fn lastWorkspace(self: *WindowState) ?*Workspace {
        const target_id = self.last_workspace_id orelse return null;
        for (self.workspaces.items, 0..) |ws, i| {
            if (ws.id == target_id) {
                self.selectWorkspace(i);
                return ws;
            }
        }
        return null;
    }

    // Split pane operations
    pub fn splitFocused(self: *WindowState) void {
        const ws = self.activeWorkspace() orelse return;
        ws.splitFocused() catch return;
    }

    pub fn closeFocusedPane(self: *WindowState) void {
        const ws = self.activeWorkspace() orelse return;
        // Capture the focused pane's ID before it is destroyed
        const pane_id: ?u64 = if (ws.focusedGroup()) |fg|
            if (fg.getActivePanel()) |p| p.getId() else null
        else
            null;
        const ws_empty = ws.closeFocusedPane();
        // Purge notifications for the closed pane
        if (pane_id) |pid| {
            _ = self.notif_center.store.removeForPane(pid);
        }
        if (ws_empty) {
            self.closeWorkspace(self.active_workspace);
        } else {
            self.sidebar.refresh();
        }
    }

    pub fn focusPaneDirection(self: *WindowState, direction: @import("workspace.zig").FocusDirection) void {
        const ws = self.activeWorkspace() orelse return;
        const old_col = ws.focused_column;
        ws.focusPaneDirection(direction);
        if (ws.focused_column != old_col) self.sidebar.refresh();
        self.updateWindowTitle();
    }

    pub fn closePaneById(self: *WindowState, pane_id: u64) void {
        // Purge notifications for the closing pane
        _ = self.notif_center.store.removeForPane(pane_id);

        // Clean up codex session dir (deterministic path based on surface id).
        // This handles SIGKILL/OOM where the codex SessionEnd hook never fires.
        if (std.posix.getenv("HOME")) |home| {
            var path_buf: [std.fs.max_path_bytes]u8 = undefined;
            const path = std.fmt.bufPrint(&path_buf, "{s}/.cache/seance-codex/{d}", .{ home, pane_id }) catch "";
            if (path.len > 0) {
                std.fs.deleteTreeAbsolute(path) catch {};
            }
        }

        for (self.workspaces.items, 0..) |ws, ws_idx| {
            const grp = ws.findGroupContainingPane(pane_id) orelse continue;

            ws.clearPaneHistoryFor(pane_id);

            // Group has multiple panels — remove just this one
            if (grp.panels.items.len > 1) {
                for (grp.panels.items, 0..) |panel, i| {
                    if (panel.getId() == pane_id) {
                        _ = grp.removePanel(i);
                        break;
                    }
                }
                ws.applyLayout();
                return;
            }

            // Single panel: remove the entire column
            const ws_empty = ws.removeColumnByGroupId(grp.id);
            if (ws_empty) {
                self.closeWorkspace(ws_idx);
            } else {
                self.sidebar.refresh();
            }
            return;
        }
    }

    pub fn refreshMetadata(self: *WindowState) void {
        // Phase 1 (main thread, fast): read .git/HEAD, update titles
        var changed = false;
        for (self.workspaces.items) |ws| {
            // Shell integration already reports the git branch via the socket
            // protocol — skip redundant file I/O on the main thread when available.
            const shell_has_branch = if (ws.focusedGroup()) |fg|
                if (fg.focusedTerminalPane()) |fp| fp.shell_git_branch_len > 0 else false
            else
                false;

            if (!shell_has_branch) {
                // Fallback: read .git/HEAD (file I/O only, fast)
                if (ws.getActivePaneCwd()) |cwd_path| {
                    if (git_info.getBranch(&ws.git_branch, cwd_path)) |branch| {
                        if (branch.len != ws.git_branch_len) changed = true;
                        ws.git_branch_len = branch.len;
                    } else {
                        if (ws.git_branch_len != 0) changed = true;
                        ws.git_branch_len = 0;
                    }
                } else {
                    if (ws.git_branch_len != 0) changed = true;
                    ws.git_branch_len = 0;
                }
            }

            // Update workspace title from focused pane's cached terminal title
            if (ws.focusedGroup()) |fg| {
                if (fg.focusedTerminalPane()) |fp| {
                    if (fp.getCachedTitle()) |title| {
                        const old_len = ws.title_len;
                        ws.setAutoTitle(title);
                        if (ws.title_len != old_len) changed = true;
                    }
                }
            }
        }

        // Only refresh the sidebar if something actually changed
        if (changed) {
            self.sidebar.refresh();
            self.sidebar.setActive(self.active_workspace);
        }

        // Phase 2 (background thread): dirty checks and PR info
        if (self.metadata_in_flight) return;

        const work = self.alloc.create(MetadataWork) catch return;
        work.* = .{ .state = self };

        for (self.workspaces.items) |ws| {
            if (work.result_count >= work.results.len) break;

            var r = MetadataResult{
                .workspace_id = ws.id,
            };

            if (ws.getActivePaneCwd()) |cwd_path| {
                const len = @min(cwd_path.len, r.cwd.len);
                @memcpy(r.cwd[0..len], cwd_path[0..len]);
                r.cwd_len = len;

                // Check if shell integration is reporting git info
                r.shell_has_git = if (ws.focusedGroup()) |fg|
                    if (fg.focusedTerminalPane()) |fp| fp.shell_git_branch_len > 0 else false
                else
                    false;

                if (ws.git_branch_len > 0) {
                    @memcpy(r.git_branch[0..ws.git_branch_len], ws.git_branch[0..ws.git_branch_len]);
                    r.git_branch_len = ws.git_branch_len;
                }
            }

            work.results[work.result_count] = r;
            work.result_count += 1;
        }

        // Nothing to do in background if no workspaces have cwds
        var has_work = false;
        for (work.results[0..work.result_count]) |r| {
            if (r.cwd_len > 0 and r.git_branch_len > 0) {
                has_work = true;
                break;
            }
        }
        if (!has_work) {
            self.alloc.destroy(work);
            return;
        }

        self.metadata_in_flight = true;
        const thread = std.Thread.spawn(.{}, metadataWorker, .{work}) catch {
            self.metadata_in_flight = false;
            self.alloc.destroy(work);
            return;
        };
        thread.detach();
    }

    fn metadataWorker(work: *MetadataWork) void {
        const alloc = work.state.alloc;

        for (work.results[0..work.result_count]) |*r| {
            if (r.cwd_len == 0 or r.git_branch_len == 0) continue;

            const cwd = r.cwd[0..r.cwd_len];

            // Dirty check (subprocess)
            if (!r.shell_has_git) {
                r.git_dirty = git_info.isDirty(alloc, cwd);
            }

        }

        // Post results back to GTK main thread
        _ = c.g_idle_add(@ptrCast(&applyMetadataResults), @ptrCast(work));
    }

    fn applyMetadataResults(data: c.gpointer) callconv(.c) c.gboolean {
        const work: *MetadataWork = @ptrCast(@alignCast(data));
        const self = work.state;

        // Check if window was destroyed while we were working
        if (self.destroyed) {
            self.alloc.destroy(work);
            return c.G_SOURCE_REMOVE;
        }

        self.metadata_in_flight = false;

        // Apply results to workspaces
        for (work.results[0..work.result_count]) |r| {
            // Find workspace by ID (it may have been closed)
            for (self.workspaces.items) |ws| {
                if (ws.id == r.workspace_id) {
                    if (r.cwd_len > 0 and r.git_branch_len > 0) {
                        if (!r.shell_has_git) {
                            ws.git_dirty = r.git_dirty;
                        }
                    } else {
                        ws.git_dirty = false;
                    }
                    break;
                }
            }
        }

        self.sidebar.refresh();
        self.sidebar.setActive(self.active_workspace);

        self.alloc.destroy(work);
        return c.G_SOURCE_REMOVE;
    }

    pub fn refreshPorts(self: *WindowState) void {
        if (self.port_scan_in_flight) return;

        const work = self.alloc.create(PortScanWork) catch return;
        work.* = .{ .state = self };

        for (self.workspaces.items) |ws| {
            if (work.entry_count >= work.entries.len) break;

            var entry = PortScanWorkspaceEntry{ .workspace_id = ws.id };

            for (ws.columns.items) |col| {
                for (col.groups.items) |grp| {
                    for (grp.panels.items) |panel| {
                        const pane = panel.asTerminal() orelse continue;
                        if (entry.panel_count < entry.panel_ids.len) {
                            entry.panel_ids[entry.panel_count] = pane.id;
                            entry.panel_count += 1;
                        }
                    }
                }
            }

            if (entry.panel_count > 0) {
                work.entries[work.entry_count] = entry;
                work.entry_count += 1;
            }
        }

        if (work.entry_count == 0) {
            self.alloc.destroy(work);
            return;
        }

        self.port_scan_in_flight = true;
        const thread = std.Thread.spawn(.{}, portScanWorker, .{work}) catch {
            self.port_scan_in_flight = false;
            self.alloc.destroy(work);
            return;
        };
        thread.detach();
    }

    fn portScanWorker(work: *PortScanWork) void {
        // Flatten all panel IDs across all workspaces for a single scan call
        var all_panel_ids: [256]u64 = undefined;
        var all_count: usize = 0;
        for (work.entries[0..work.entry_count]) |entry| {
            for (entry.panel_ids[0..entry.panel_count]) |pid| {
                if (all_count < all_panel_ids.len) {
                    all_panel_ids[all_count] = pid;
                    all_count += 1;
                }
            }
        }

        // Run the scan once for all panels
        var pane_results: [256]port_scan.PanePorts = undefined;
        const results = port_scan.scanPorts(all_panel_ids[0..all_count], &pane_results);

        // Aggregate per-pane results into per-workspace results
        for (work.entries[0..work.entry_count]) |entry| {
            if (work.result_count >= work.results.len) break;

            var ws_result = PortScanResult{ .workspace_id = entry.workspace_id };

            // Collect ports from all panes in this workspace
            for (entry.panel_ids[0..entry.panel_count]) |panel_id| {
                for (results) |pr| {
                    if (pr.panel_id == panel_id) {
                        for (pr.ports[0..pr.ports_len]) |port| {
                            if (ws_result.ports_len >= ws_result.ports.len) break;
                            // Dedup across panes in same workspace
                            var dup = false;
                            for (ws_result.ports[0..ws_result.ports_len]) |existing| {
                                if (existing == port) {
                                    dup = true;
                                    break;
                                }
                            }
                            if (!dup) {
                                ws_result.ports[ws_result.ports_len] = port;
                                ws_result.ports_len += 1;
                            }
                        }
                        break;
                    }
                }
            }

            port_scan.sortPorts(ws_result.ports[0..ws_result.ports_len]);
            work.results[work.result_count] = ws_result;
            work.result_count += 1;
        }

        _ = c.g_idle_add(@ptrCast(&applyPortScanResults), @ptrCast(work));
    }

    fn applyPortScanResults(data: c.gpointer) callconv(.c) c.gboolean {
        const work: *PortScanWork = @ptrCast(@alignCast(data));
        const self = work.state;

        if (self.destroyed) {
            self.alloc.destroy(work);
            return c.G_SOURCE_REMOVE;
        }

        self.port_scan_in_flight = false;

        var changed = false;
        // First, build a set of workspace IDs that got results
        for (self.workspaces.items) |ws| {
            // Find result for this workspace
            var found_result: ?PortScanResult = null;
            for (work.results[0..work.result_count]) |r| {
                if (r.workspace_id == ws.id) {
                    found_result = r;
                    break;
                }
            }

            const new_len = if (found_result) |r| r.ports_len else 0;

            // Check if anything changed
            if (new_len != ws.ports_len) {
                changed = true;
            } else if (found_result) |r| {
                for (r.ports[0..r.ports_len], ws.ports[0..ws.ports_len]) |a, b| {
                    if (a != b) {
                        changed = true;
                        break;
                    }
                }
            }

            // Apply
            if (found_result) |r| {
                @memcpy(ws.ports[0..r.ports_len], r.ports[0..r.ports_len]);
                ws.ports_len = r.ports_len;
            } else {
                ws.ports_len = 0;
            }
        }

        if (changed) {
            self.sidebar.refresh();
            self.sidebar.setActive(self.active_workspace);
        }

        self.alloc.destroy(work);
        return c.G_SOURCE_REMOVE;
    }

    pub fn jumpToUnread(self: *WindowState) void {
        const notif = self.notif_center.store.mostRecentUnread() orelse return;

        // Find and switch to the workspace
        for (self.workspaces.items, 0..) |ws, ws_idx| {
            if (ws.id == notif.workspace_id) {
                self.selectWorkspace(ws_idx);

                if (ws.focusColumnContainingPane(notif.pane_id)) |grp| {
                    if (grp.findPanelById(notif.pane_id)) |result| {
                        grp.switchToPanel(result.index);
                        result.panel.triggerFlash();
                    }
                    grp.focus();
                }
                return;
            }
        }
    }

    pub fn renameWorkspace(self: *WindowState) void {
        const ws = self.activeWorkspace() orelse return;

        const dialog = c.adw_alert_dialog_new("Rename Workspace", null);
        c.adw_alert_dialog_add_response(@as(*c.AdwAlertDialog, @ptrCast(dialog)), "cancel", "Cancel");
        c.adw_alert_dialog_add_response(@as(*c.AdwAlertDialog, @ptrCast(dialog)), "clear", "Clear");
        c.adw_alert_dialog_add_response(@as(*c.AdwAlertDialog, @ptrCast(dialog)), "rename", "Rename");
        c.adw_alert_dialog_set_response_appearance(@as(*c.AdwAlertDialog, @ptrCast(dialog)), "rename", c.ADW_RESPONSE_SUGGESTED);
        c.adw_alert_dialog_set_default_response(@as(*c.AdwAlertDialog, @ptrCast(dialog)), "rename");
        c.adw_alert_dialog_set_close_response(@as(*c.AdwAlertDialog, @ptrCast(dialog)), "cancel");

        const entry = c.gtk_entry_new();
        c.gtk_entry_set_activates_default(@ptrCast(entry), 1);
        var title_z: [129]u8 = undefined;
        const ws_title = ws.getTitle();
        const tlen = @min(ws_title.len, title_z.len - 1);
        @memcpy(title_z[0..tlen], ws_title[0..tlen]);
        title_z[tlen] = 0;
        c.gtk_editable_set_text(@ptrCast(entry), &title_z);
        c.adw_alert_dialog_set_extra_child(@as(*c.AdwAlertDialog, @ptrCast(dialog)), entry);

        const ctx = self.alloc.create(RenameDialogCtx) catch return;
        ctx.* = .{
            .state = self,
            .ws_id = ws.id,
            .entry = @ptrCast(entry),
        };

        _ = c.g_signal_connect_data(@as(c.gpointer, @ptrCast(dialog)), "response", @as(c.GCallback, @ptrCast(&onRenameResponse)), @ptrCast(ctx), null, 0);
        c.adw_dialog_present(@as(*c.AdwDialog, @ptrCast(dialog)), self.gtk_window);

        _ = c.gtk_widget_grab_focus(entry);
        c.gtk_editable_select_region(@ptrCast(entry), 0, -1);
    }

    pub fn togglePinWorkspace(self: *WindowState) void {
        const ws = self.activeWorkspace() orelse return;
        ws.togglePin();
        self.sidebar.refresh();
        self.sidebar.setActive(self.active_workspace);
    }

    pub fn closeActiveWorkspace(self: *WindowState) void {
        self.closeWorkspace(self.active_workspace);
    }

    /// Quit the entire application. Routes through g_application_quit so
    /// onShutdown saves all currently-open windows (with scrollback). If
    /// `confirm_close_window` is enabled and there's interesting state to
    /// warn about (multiple windows or multiple workspaces), shows a single
    /// quit confirmation dialog instead of doing it per-window.
    pub fn quitApp(self: *WindowState) void {
        const cfg = config_mod.get();
        if (!cfg.confirm_close_window or !hasInterestingState(self.window_manager)) {
            triggerQuit(self.window_manager);
            return;
        }
        showQuitConfirmation(self);
    }

    pub fn renameTab(self: *WindowState) void {
        const ws = self.activeWorkspace() orelse return;
        const group = ws.focusedGroup() orelse return;
        const pane = group.focusedTerminalPane() orelse return;

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

        const ctx = self.alloc.create(RenameTabDialogCtx) catch return;
        ctx.* = .{
            .state = self,
            .pane_id = pane.id,
            .entry = @ptrCast(entry),
        };

        _ = c.g_signal_connect_data(@as(c.gpointer, @ptrCast(dialog)), "response", @as(c.GCallback, @ptrCast(&onRenameTabResponse)), @ptrCast(ctx), null, 0);
        c.adw_dialog_present(@as(*c.AdwDialog, @ptrCast(dialog)), self.gtk_window);

        _ = c.gtk_widget_grab_focus(entry);
        c.gtk_editable_select_region(@ptrCast(entry), 0, -1);
    }

    pub fn toggleCommandPalette(self: *WindowState) void {
        self.command_palette.toggle();
    }

    pub fn toggleSidebar(self: *WindowState) void {
        self.sidebar_visible = !self.sidebar_visible;
        c.gtk_revealer_set_reveal_child(self.sidebar_revealer, if (self.sidebar_visible) 1 else 0);
    }

    pub fn toggleNotificationPopover(self: *WindowState) void {
        const popover = self.notif_popover orelse return;
        if (c.gtk_widget_get_visible(popover) != 0) {
            c.gtk_popover_popdown(@ptrCast(popover));
        } else {
            // In SSD mode the bell anchor lives in the sidebar footer, so we
            // need the sidebar revealed for the popover to have a parent on
            // screen. In CSD mode the anchor is in the header bar, so leave
            // the sidebar alone.
            if (self.effective_decoration == .ssd and !self.sidebar_visible) {
                self.sidebar_visible = true;
                c.gtk_revealer_set_reveal_child(self.sidebar_revealer, 1);
            }
            self.notif_panel.refresh();
            c.gtk_popover_popup(@ptrCast(popover));
        }
    }

    pub fn reorderWorkspace(self: *WindowState, from: usize, to: usize) void {
        if (from == to) return;
        if (from >= self.workspaces.items.len or to >= self.workspaces.items.len) return;

        // Prevent reordering across pinned/unpinned boundary
        const src_pinned = self.workspaces.items[from].is_pinned;
        const dst_pinned = self.workspaces.items[to].is_pinned;
        if (src_pinned != dst_pinned) return;

        const ws = self.workspaces.items[from];
        _ = self.workspaces.orderedRemove(from);
        self.workspaces.insert(self.alloc, to, ws) catch return;

        // Update active_workspace index
        if (self.active_workspace == from) {
            self.active_workspace = to;
        } else if (from < self.active_workspace and to >= self.active_workspace) {
            self.active_workspace -= 1;
        } else if (from > self.active_workspace and to <= self.active_workspace) {
            self.active_workspace += 1;
        }

        self.sidebar.refresh();
        self.sidebar.setActive(self.active_workspace);
    }

    pub fn reorderWorkspaceToTop(self: *WindowState, workspace_id: u64) void {
        // Find workspace index
        var ws_idx: ?usize = null;
        for (self.workspaces.items, 0..) |ws, i| {
            if (ws.id == workspace_id) {
                ws_idx = i;
                break;
            }
        }
        const idx = ws_idx orelse return;
        const ws = self.workspaces.items[idx];

        // Don't reorder pinned workspaces
        if (ws.is_pinned) return;

        // Don't reorder the currently active workspace
        if (idx == self.active_workspace) return;

        // Count pinned workspaces to find insertion point
        var pinned_count: usize = 0;
        for (self.workspaces.items) |w| {
            if (w.is_pinned) pinned_count += 1;
        }

        // Already at the insertion point
        if (idx == pinned_count) return;

        // Remove from current position and insert after pinned workspaces
        _ = self.workspaces.orderedRemove(idx);
        self.workspaces.insert(self.alloc, pinned_count, ws) catch return;

        // Update active_workspace index if it shifted
        if (self.active_workspace >= pinned_count and self.active_workspace < idx) {
            self.active_workspace += 1;
        }

        self.sidebar.refresh();
        self.sidebar.setActive(self.active_workspace);
    }

    pub fn jumpToNotification(self: *WindowState, workspace_id: u64, pane_group_id: u64, pane_id: u64) void {
        _ = pane_group_id; // group id hint; we search by pane_id directly
        for (self.workspaces.items, 0..) |ws, ws_idx| {
            if (ws.id == workspace_id) {
                self.selectWorkspace(ws_idx);

                if (ws.focusColumnContainingPane(pane_id)) |grp| {
                    if (grp.findPanelById(pane_id)) |result| {
                        grp.switchToPanel(result.index);
                        result.panel.triggerFlash();
                    }
                    grp.focus();
                }
                return;
            }
        }
    }

    /// Stop all pane timers in this window to prevent dangling callbacks.
    pub fn stopAllPaneTimers(self: *WindowState) void {
        for (self.workspaces.items) |ws| {
            for (ws.columns.items) |col| {
                for (col.groups.items) |grp| {
                    for (grp.panels.items) |panel| {
                        stopPanelTimers(panel);
                    }
                }
            }
        }
    }

    /// Reload config and apply changes to this window and all its panes.
    /// When `silent` is true, the "Configuration reloaded" toast is suppressed
    /// (used by the settings dialog to avoid flooding toasts on every slider tick).
    pub fn reloadConfig(self: *WindowState, silent: bool) void {
        // Reset keybinds to defaults before reload (clears stale overrides)
        const keybinds_mod = @import("keybinds.zig");
        keybinds_mod.resetToDefaults();

        // Reload config from disk (also re-applies keybind overrides)
        const cfg = config_mod.reloadConfig();
        self.config = cfg;

        // Apply sidebar position if it changed
        self.applySidebarPosition(&cfg);

        // Apply decoration mode change (rebuilds header bar / sidebar footer
        // in place if the effective mode differs from what's currently
        // displayed).  No-op on windows where the mode hasn't changed.
        self.applyDecorationMode();

        // Refresh sidebar to pick up any sidebar-related config changes
        self.sidebar.refresh();
        self.sidebar.setActive(self.active_workspace);

        // Re-resolve theme, update all terminal surfaces, and reload CSS.
        reloadTheme();

        // Check for config errors after reload
        if (config_mod.getLoadError()) |err_msg| {
            self.showBanner(err_msg, true);
            config_mod.clearLoadError();
        } else {
            self.hideBanner();
            if (!silent) self.showToast("Configuration reloaded");
        }
    }

    fn applySidebarPosition(self: *WindowState, cfg: *const config_mod.Config) void {
        const revealer_widget: *c.GtkWidget = @ptrCast(@alignCast(self.sidebar_revealer));
        const content_widget: *c.GtkWidget = @ptrCast(@alignCast(self.content_stack));

        // Check if sidebar is already on the correct side by seeing what
        // the first child of hbox is.
        const first_child = c.gtk_widget_get_first_child(self.hbox);
        const want_right = cfg.sidebar_position == .right;
        const sidebar_is_first = (first_child == revealer_widget);

        // If sidebar is first and we want right, or sidebar is not first and we want left — nothing to do
        if (sidebar_is_first and !want_right) return;
        if (!sidebar_is_first and want_right) return;

        // Ref both so they survive removal
        _ = c.g_object_ref(@ptrCast(revealer_widget));
        _ = c.g_object_ref(@ptrCast(content_widget));

        // Remove both from the hbox
        c.gtk_box_remove(@ptrCast(self.hbox), revealer_widget);
        c.gtk_box_remove(@ptrCast(self.hbox), content_widget);

        // Re-append in the correct order
        if (want_right) {
            c.gtk_box_append(@ptrCast(self.hbox), content_widget);
            c.gtk_box_append(@ptrCast(self.hbox), revealer_widget);
        } else {
            c.gtk_box_append(@ptrCast(self.hbox), revealer_widget);
            c.gtk_box_append(@ptrCast(self.hbox), content_widget);
        }

        // Release extra refs
        c.g_object_unref(@ptrCast(revealer_widget));
        c.g_object_unref(@ptrCast(content_widget));

        // Update revealer slide direction
        const direction: c_uint = if (want_right)
            c.GTK_REVEALER_TRANSITION_TYPE_SLIDE_LEFT
        else
            c.GTK_REVEALER_TRANSITION_TYPE_SLIDE_RIGHT;
        c.gtk_revealer_set_transition_type(self.sidebar_revealer, direction);
    }

    pub fn showSettings(self: *WindowState) void {
        settings_mod.show(self.window_manager);
    }

    pub fn showToast(self: *WindowState, message: [*:0]const u8) void {
        const toast = c.adw_toast_new(message);
        c.adw_toast_set_timeout(@ptrCast(toast), 2);
        c.adw_toast_overlay_add_toast(@ptrCast(self.toast_overlay), @ptrCast(toast));
    }

    pub fn showBanner(self: *WindowState, message: [*:0]const u8, is_config_error: bool) void {
        const banner = self.banner orelse return;
        c.adw_banner_set_title(@ptrCast(banner), message);
        if (is_config_error) {
            c.adw_banner_set_button_label(@ptrCast(banner), "Open Settings");
        } else {
            c.adw_banner_set_button_label(@ptrCast(banner), null);
        }
        self.banner_is_config_error = is_config_error;
        c.adw_banner_set_revealed(@ptrCast(banner), 1);
    }

    pub fn hideBanner(self: *WindowState) void {
        const banner = self.banner orelse return;
        c.adw_banner_set_revealed(@ptrCast(banner), 0);
    }

    pub fn showOpenFolderDialog(self: *WindowState) void {
        const dialog = c.gtk_file_chooser_dialog_new(
            "Open Folder",
            @as(*c.GtkWindow, @ptrCast(self.gtk_window)),
            c.GTK_FILE_CHOOSER_ACTION_SELECT_FOLDER,
            "Cancel",
            @as(c_int, c.GTK_RESPONSE_CANCEL),
            "Open",
            @as(c_int, c.GTK_RESPONSE_ACCEPT),
            @as(?*anyopaque, null),
        );

        _ = c.g_signal_connect_data(
            @as(c.gpointer, @ptrCast(dialog)),
            "response",
            @as(c.GCallback, @ptrCast(&onFolderChosen)),
            @ptrCast(self),
            null,
            0,
        );

        c.gtk_widget_set_visible(@as(*c.GtkWidget, @ptrCast(dialog)), 1);
    }

    pub fn newWorkspaceWithCwd(self: *WindowState, cwd: [*:0]const u8, title: []const u8) void {
        const ws = Workspace.createForRestore(self.alloc, cwd) catch return;
        ws.port_ordinal = self.next_port_ordinal;
        self.next_port_ordinal += 1;
        ws.setTitle(title);

        var name_buf: [32]u8 = undefined;
        const name = std.fmt.bufPrintZ(&name_buf, "ws-{d}", .{ws.id}) catch "ws";
        _ = c.gtk_stack_add_named(self.content_stack, ws.container, name.ptr);

        const target_idx: usize = blk: {
            const idx = if (self.workspaces.items.len == 0) 0 else self.active_workspace + 1;
            self.workspaces.insert(self.alloc, idx, ws) catch return;
            break :blk idx;
        };

        self.sidebar.refresh();
        self.selectWorkspace(target_idx);
    }

    /// Build the CSD chrome: adw header bar with add/notif/hide/settings
    /// buttons, wrapped in an adw toolbar view with banner_box as content.
    /// Assumes self.banner_box is already populated.  Stores the created
    /// toolbar_view on self and repoints the sidebar's notification
    /// badge/overlay at the header-bar widgets.
    fn buildCsdChrome(self: *WindowState) void {
        const window = self.gtk_window;
        const header = c.adw_header_bar_new();

        const add_btn = c.gtk_button_new_from_icon_name("list-add-symbolic");
        c.gtk_widget_set_tooltip_text(@ptrCast(add_btn), "New Workspace");
        c.adw_header_bar_pack_start(@ptrCast(header), @ptrCast(add_btn));

        const settings_btn = c.gtk_button_new_from_icon_name("emblem-system-symbolic");
        c.gtk_widget_set_tooltip_text(@ptrCast(settings_btn), "Settings");
        c.adw_header_bar_pack_end(@ptrCast(header), @ptrCast(settings_btn));

        const hide_icon: [*:0]const u8 = if (self.config.sidebar_position == .right) "sidebar-show-right-symbolic" else "sidebar-show-symbolic";
        const hide_btn = c.gtk_button_new_from_icon_name(hide_icon);
        c.gtk_widget_set_tooltip_text(@ptrCast(hide_btn), "Hide Sidebar");
        c.adw_header_bar_pack_end(@ptrCast(header), @ptrCast(hide_btn));

        // Bell button with unread badge overlay
        const notif_btn = c.gtk_button_new_from_icon_name("bell-outline-symbolic");
        c.gtk_widget_set_tooltip_text(@ptrCast(notif_btn), "Notifications");
        const notif_overlay = c.gtk_overlay_new();
        c.gtk_overlay_set_child(@ptrCast(notif_overlay), @ptrCast(notif_btn));
        const notif_badge = c.gtk_label_new("");
        c.gtk_widget_add_css_class(notif_badge, "notif-bell-badge");
        c.gtk_label_set_xalign(@ptrCast(notif_badge), 0.5);
        c.gtk_widget_set_halign(notif_badge, c.GTK_ALIGN_END);
        c.gtk_widget_set_valign(notif_badge, c.GTK_ALIGN_START);
        c.gtk_widget_set_visible(notif_badge, 0);
        c.gtk_overlay_add_overlay(@ptrCast(notif_overlay), notif_badge);
        c.adw_header_bar_pack_end(@ptrCast(header), @ptrCast(notif_overlay));

        // Point the sidebar at the header-bar-hosted badge/overlay so refresh()
        // keeps updating the unread count after a runtime chrome rebuild.
        self.sidebar.notif_badge = notif_badge;
        self.sidebar.notif_overlay = @ptrCast(notif_overlay);

        const sidebar_ptr: *Sidebar = &self.sidebar;
        _ = c.g_signal_connect_data(@ptrCast(add_btn), "clicked", @ptrCast(&sidebar_mod.onAddClicked), @ptrCast(sidebar_ptr), null, 0);
        _ = c.g_signal_connect_data(@ptrCast(notif_btn), "clicked", @ptrCast(&sidebar_mod.onNotifToggleClicked), @ptrCast(sidebar_ptr), null, 0);
        _ = c.g_signal_connect_data(@ptrCast(hide_btn), "clicked", @ptrCast(&sidebar_mod.onSidebarHideClicked), @ptrCast(sidebar_ptr), null, 0);
        _ = c.g_signal_connect_data(@ptrCast(settings_btn), "clicked", @ptrCast(&sidebar_mod.onSettingsClicked), @ptrCast(sidebar_ptr), null, 0);

        const toolbar_view = c.adw_toolbar_view_new();
        c.adw_toolbar_view_add_top_bar(@as(*c.AdwToolbarView, @ptrCast(toolbar_view)), @ptrCast(header));
        c.adw_toolbar_view_set_top_bar_style(@as(*c.AdwToolbarView, @ptrCast(toolbar_view)), c.ADW_TOOLBAR_FLAT);
        c.adw_toolbar_view_set_content(@as(*c.AdwToolbarView, @ptrCast(toolbar_view)), self.banner_box);
        c.adw_application_window_set_content(@ptrCast(window), toolbar_view);

        self.toolbar_view = @ptrCast(toolbar_view);

        // Push any existing unread count into the fresh badge.
        self.sidebar.refresh();
    }

    /// Build the SSD chrome: the banner_box becomes the window's direct
    /// content, the sidebar grows a footer with the action buttons, and we
    /// ask the windowing system to draw decorations.
    fn buildSsdChrome(self: *WindowState) void {
        const window = self.gtk_window;

        self.sidebar.buildFooter();

        c.adw_application_window_set_content(@ptrCast(window), self.banner_box);
        self.toolbar_view = null;

        // Ask the WM to draw SSD.  No-op if SSD isn't available; caller
        // guarantees we only pick ssd when isSsdAvailable() returns true.
        kde_decoration.attachToWindow(@ptrCast(window));
    }

    /// Toast exactly once per explicit-ssd request when the compositor can't
    /// honor it, and reset the latch when the user moves off ssd (or ssd
    /// becomes available).  Called from both the initial chrome build and
    /// every config reload, so the user sees the warning on launch too.
    fn warnIfSsdUnhonorable(self: *WindowState) void {
        if (self.config.decoration_mode == .ssd and !kde_decoration.isSsdAvailable()) {
            if (!self.ssd_unavailable_warned) {
                self.showToast("Server-side decorations not available on this compositor, using client-side");
                self.ssd_unavailable_warned = true;
            }
        } else {
            self.ssd_unavailable_warned = false;
        }
    }

    /// Recompute the effective decoration from `self.config.decoration_mode`
    /// and rebuild the chrome if it has changed.  Safe to call every
    /// reload; no-op when the mode hasn't changed.
    pub fn applyDecorationMode(self: *WindowState) void {
        self.warnIfSsdUnhonorable();
        const new_mode = resolveEffectiveDecoration(self.config.decoration_mode, self.is_gnome);
        if (new_mode == self.effective_decoration) return;

        // Ref the banner_box so it survives being unparented from the old
        // chrome.  The whole terminal/sidebar subtree lives inside it.
        const banner_box_obj: *c.GObject = @ptrCast(self.banner_box);
        _ = c.g_object_ref(banner_box_obj);
        defer c.g_object_unref(banner_box_obj);

        // Ref the notification popover the same way; it's currently anchored
        // to the old notif_overlay which is about to be destroyed.
        var popover_ref: ?*c.GtkWidget = null;
        if (self.notif_popover) |pop| {
            _ = c.g_object_ref(@ptrCast(pop));
            c.gtk_widget_unparent(pop);
            popover_ref = pop;
        }

        // Tear down the old chrome.  We null out the sidebar's badge/overlay
        // pointers BEFORE destroying their host widgets so a stray refresh()
        // doesn't chase a dangling pointer.
        self.sidebar.notif_badge = null;
        self.sidebar.notif_overlay = null;
        switch (self.effective_decoration) {
            .csd => {
                if (self.toolbar_view) |tv| {
                    // Detach banner_box from the toolbar_view first so it
                    // isn't destroyed along with it.
                    c.adw_toolbar_view_set_content(@as(*c.AdwToolbarView, @ptrCast(tv)), null);
                }
                c.adw_application_window_set_content(@ptrCast(self.gtk_window), null);
                self.toolbar_view = null;
            },
            .ssd => {
                // banner_box is currently the direct window content; detach it.
                c.adw_application_window_set_content(@ptrCast(self.gtk_window), null);
                self.sidebar.destroyFooter();
            },
        }

        // Build the new chrome.
        switch (new_mode) {
            .csd => {
                // ssd → csd: hand decoration back to GTK.
                if (self.effective_decoration == .ssd) {
                    kde_decoration.detachFromWindow(@ptrCast(self.gtk_window));
                }
                self.buildCsdChrome();
            },
            .ssd => {
                self.buildSsdChrome();
            },
        }

        // Reanchor the notification popover to the new bell overlay.
        if (popover_ref) |pop| {
            if (self.sidebar.notif_overlay) |anchor| {
                c.gtk_widget_set_parent(pop, anchor);
            }
            c.g_object_unref(@ptrCast(pop));
        }

        self.effective_decoration = new_mode;
    }
};

fn stopPanelTimers(panel: Panel) void {
    switch (panel) {
        .terminal => |pane| {
            if (pane.flash_timeout != 0) {
                _ = c.g_source_remove(pane.flash_timeout);
                pane.flash_timeout = 0;
            }
        },
    }
}

fn applyConfigToPane(pane: *@import("pane.zig").Pane, config: *anyopaque) void {
    const surface = pane.surface orelse return;
    c.ghostty_surface_update_config(surface, config);
    pane.queueRedraw();
}

fn onFolderChosen(dialog: *c.GtkDialog, response_id: c_int, data: c.gpointer) callconv(.c) void {
    const state: *WindowState = @ptrCast(@alignCast(data));

    if (response_id == c.GTK_RESPONSE_ACCEPT) {
        const chooser: *c.GtkFileChooser = @ptrCast(@alignCast(dialog));
        const gfile: ?*c.GFile = c.gtk_file_chooser_get_file(chooser);
        if (gfile) |f| {
            const path_z: ?[*:0]const u8 = c.g_file_get_path(f);
            if (path_z) |p| {
                const path = std.mem.sliceTo(p, 0);
                const folder_name = Workspace.basenameFromPath(path);
                state.newWorkspaceWithCwd(p, folder_name);
                c.g_free(@ptrCast(@constCast(p)));
            }
            c.g_object_unref(@ptrCast(f));
        }
    }

    c.gtk_window_destroy(@as(*c.GtkWindow, @ptrCast(@alignCast(dialog))));
}

// Global window manager pointer (replaces old window_state)
pub var window_manager: ?*WindowManager = null;

pub fn create(wm: *WindowManager) !*WindowState {
    const alloc = wm.allocator;
    const config = config_mod.load();

    const window = c.adw_application_window_new(wm.app);
    c.gtk_window_set_title(@as(*c.GtkWindow, @ptrCast(window)), "seance");
    c.gtk_window_set_default_size(@as(*c.GtkWindow, @ptrCast(window)), 1200, 800);

    // Main layout: sidebar | content
    const hbox = c.gtk_box_new(c.GTK_ORIENTATION_HORIZONTAL, 0);

    const content_stack = c.gtk_stack_new();
    c.gtk_stack_set_transition_type(@ptrCast(content_stack), c.GTK_STACK_TRANSITION_TYPE_SLIDE_UP);
    c.gtk_widget_set_hexpand(content_stack, 1);
    c.gtk_widget_set_vexpand(content_stack, 1);

    // Initialize state
    const state = try alloc.create(WindowState);
    state.* = .{
        .workspaces = .empty,
        .content_stack = @ptrCast(content_stack),
        .sound_player = sound.SoundPlayer.init(),
        .config = config,
        .alloc = alloc,
        .sidebar = undefined,
        .window_manager = wm,
        .gtk_window = @ptrCast(window),
    };

    // Detect GNOME once and cache on state; the env var is stable for the
    // process lifetime and applyDecorationMode reads it on every reload.
    const desktop = std.posix.getenv("XDG_CURRENT_DESKTOP") orelse "";
    state.is_gnome = std.mem.indexOf(u8, desktop, "GNOME") != null;
    state.effective_decoration = resolveEffectiveDecoration(config.decoration_mode, state.is_gnome);

    state.sidebar = Sidebar.create(alloc, &state.workspaces, &onWorkspaceSelect, &onWorkspaceNew);
    state.sidebar.notif_store = &state.notif_center.store;
    state.sidebar.on_reorder = &onWorkspaceReorder;
    state.sidebar.on_close = &onWorkspaceClose;
    state.sidebar.on_toggle_notifications = &onToggleNotifications;
    state.sidebar.on_context_action = &onWorkspaceContextAction;
    state.sidebar.on_move_to_window = &onMoveToWindow;
    state.sidebar.on_toggle_sidebar = &onToggleSidebar;
    state.sidebar.on_settings = &onSettings;
    state.sidebar.connectSignals();

    // Wire notification center callbacks
    initNotificationCenter(state);

    // Create notification panel
    state.notif_panel = notification_panel.NotificationPanel.create(&state.notif_center);

    // Notification popover is created after the chrome, since the bell
    // overlay it anchors to may live in either the CSD header bar or the
    // SSD sidebar footer depending on the effective decoration.

    // Wrap sidebar in a revealer for animated show/hide
    const sidebar_revealer = c.gtk_revealer_new();
    const reveal_direction: c_uint = if (config.sidebar_position == .right)
        c.GTK_REVEALER_TRANSITION_TYPE_SLIDE_LEFT
    else
        c.GTK_REVEALER_TRANSITION_TYPE_SLIDE_RIGHT;
    c.gtk_revealer_set_transition_type(@ptrCast(sidebar_revealer), reveal_direction);
    c.gtk_revealer_set_transition_duration(@ptrCast(sidebar_revealer), 150);
    c.gtk_revealer_set_child(@ptrCast(sidebar_revealer), state.sidebar.widget);
    c.gtk_revealer_set_reveal_child(@ptrCast(sidebar_revealer), 1);
    state.sidebar_revealer = @ptrCast(sidebar_revealer);

    // Re-layout sidebar tab bar when the revealer finishes revealing,
    // so workspace buttons get the correct width after sidebar was hidden.
    _ = c.g_signal_connect_data(
        @as(c.gpointer, @ptrCast(sidebar_revealer)),
        "notify::child-revealed",
        @as(c.GCallback, @ptrCast(&onSidebarRevealed)),
        @as(c.gpointer, @ptrCast(&state.sidebar.tab_bar)),
        null,
        0,
    );

    // Apply sidebar config
    c.gtk_widget_set_size_request(state.sidebar.widget, @intCast(config.sidebar_width), -1);
    c.gtk_widget_set_hexpand(state.sidebar.widget, 0);
    if (!config.sidebar_visible) {
        state.sidebar_visible = false;
    }

    // Store hbox for runtime sidebar repositioning
    state.hbox = hbox;

    // Sidebar position: left (default) or right
    if (config.sidebar_position == .right) {
        c.gtk_box_append(@ptrCast(hbox), content_stack);
        c.gtk_box_append(@ptrCast(hbox), sidebar_revealer);
    } else {
        c.gtk_box_append(@ptrCast(hbox), sidebar_revealer);
        c.gtk_box_append(@ptrCast(hbox), content_stack);
    }

    // Wrap hbox in a GtkOverlay so the command palette can float on top
    const window_overlay = c.gtk_overlay_new();
    c.gtk_overlay_set_child(@ptrCast(window_overlay), hbox);

    // Wrap in AdwToastOverlay for toast notifications
    const toast_overlay = c.adw_toast_overlay_new();
    c.adw_toast_overlay_set_child(@ptrCast(toast_overlay), window_overlay);
    state.toast_overlay = toast_overlay;

    // Error banner (hidden by default, revealed on config/session errors)
    const banner = c.adw_banner_new("");
    c.adw_banner_set_revealed(@ptrCast(banner), 0);
    state.banner = @ptrCast(banner);

    _ = c.g_signal_connect_data(
        @as(c.gpointer, @ptrCast(banner)),
        "button-clicked",
        @as(c.GCallback, @ptrCast(&onBannerButtonClicked)),
        @as(c.gpointer, @ptrCast(state)),
        null,
        0,
    );

    // Vertical box: banner on top, content below
    const banner_box = c.gtk_box_new(c.GTK_ORIENTATION_VERTICAL, 0);
    c.gtk_box_append(@ptrCast(banner_box), @ptrCast(banner));
    c.gtk_box_append(@ptrCast(banner_box), toast_overlay);
    c.gtk_widget_set_vexpand(toast_overlay, 1);
    state.banner_box = banner_box;

    // Build the initial chrome directly based on the resolved effective
    // decoration.  Subsequent runtime changes flow through
    // applyDecorationMode() which diffs and rebuilds incrementally.
    switch (state.effective_decoration) {
        .csd => state.buildCsdChrome(),
        .ssd => state.buildSsdChrome(),
    }

    // If the user asked for ssd but the compositor can't deliver it, queue
    // the same toast the runtime path would show.  The toast overlay is
    // already set on state, so the queued toast appears once the window is
    // presented.
    state.warnIfSsdUnhonorable();

    // Create notification popover attached to the bell overlay.  The
    // overlay lives in the CSD header bar or the SSD sidebar footer; the
    // chrome build above has already set sidebar.notif_overlay accordingly.
    const notif_popover: *c.GtkWidget = @ptrCast(c.gtk_popover_new());
    c.gtk_widget_set_parent(notif_popover, state.sidebar.notif_overlay.?);
    c.gtk_widget_add_css_class(notif_popover, "notification-popover");
    c.gtk_popover_set_has_arrow(@ptrCast(notif_popover), 1);
    c.gtk_popover_set_child(@ptrCast(notif_popover), state.notif_panel.container);
    state.notif_popover = notif_popover;
    state.notif_panel.popover = notif_popover;

    // When the popover closes (e.g. clicking outside), GTK restores focus to its
    // parent (the bell icon). Re-focus the active terminal pane instead.
    _ = c.g_signal_connect_data(
        @as(c.gpointer, @ptrCast(notif_popover)),
        "closed",
        @as(c.GCallback, @ptrCast(&onNotifPopoverClosed)),
        @as(c.gpointer, @ptrCast(state)),
        null,
        0,
    );

    // Create command palette and add as overlay
    state.command_palette = command_palette_mod.CommandPalette.create(state);
    c.gtk_overlay_add_overlay(@ptrCast(window_overlay), state.command_palette.overlay);

    // Apply initial sidebar visibility from config
    if (!config.sidebar_visible) {
        c.gtk_revealer_set_reveal_child(@ptrCast(sidebar_revealer), 0);
    }

    // Connect notification panel signals
    state.notif_panel.connectSignals();
    state.notif_panel.on_jump = &onNotifJump;
    state.notif_panel.on_show_sidebar = &onNotifShowSidebar;

    // Install key event controller (pass state as user_data)
    const keybinds_mod = @import("keybinds.zig");
    keybinds_mod.installController(@as(*c.GtkWidget, @ptrCast(window)), state);

    // Start periodic metadata refresh — shell integration already reports
    // git branch and CWD in real time, so this is a fallback/catch-up.
    state.metadata_timer = c.g_timeout_add_seconds(15, @ptrCast(&onMetadataRefresh), @ptrCast(state));

    // Start periodic vim detection (every 3 seconds)
    state.vim_check_timer = c.g_timeout_add_seconds(3, @ptrCast(&onVimCheckRefresh), @ptrCast(state));

    // Start periodic port scanning (every 10 seconds)
    state.port_scan_timer = c.g_timeout_add_seconds(10, @ptrCast(&onPortScanRefresh), @ptrCast(state));

    // Connect close-request signal for window close handling
    _ = c.g_signal_connect_data(
        @as(c.gpointer, @ptrCast(window)),
        "close-request",
        @as(c.GCallback, @ptrCast(&onCloseRequest)),
        @ptrCast(state),
        null,
        0,
    );

    // Connect window focus tracking
    _ = c.g_signal_connect_data(
        @as(c.gpointer, @ptrCast(window)),
        "notify::is-active",
        @as(c.GCallback, @ptrCast(&onWindowFocusChanged)),
        @ptrCast(state),
        null,
        0,
    );

    // Load theme-aware CSS
    loadThemeCss();

    // This window isn't in wm.windows yet, so loadThemeCss() didn't touch it.
    // Remove the "background" class directly if transparency is active.
    if (config.background_opacity < 1.0) {
        c.gtk_widget_remove_css_class(@as(*c.GtkWidget, @ptrCast(window)), "background");
    }
    blur.syncBlur(@as(*c.GtkWindow, @ptrCast(window)));

    // Check for deferred config/session errors and show banner
    if (config_mod.getLoadError()) |err_msg| {
        state.showBanner(err_msg, true);
        config_mod.clearLoadError();
        session_mod.clearLoadError();
    } else if (session_mod.getLoadError()) |err_msg| {
        state.showBanner(err_msg, false);
        session_mod.clearLoadError();
    }

    return state;
}

fn onBannerButtonClicked(_: *c.GtkWidget, data: c.gpointer) callconv(.c) void {
    const state: *WindowState = @ptrCast(@alignCast(data));
    if (state.banner_is_config_error) {
        settings_mod.show(state.window_manager);
    }
    state.hideBanner();
}

fn onCloseRequest(_: *c.GtkWindow, data: c.gpointer) callconv(.c) c.gboolean {
    const state: *WindowState = @ptrCast(@alignCast(data));
    if (state.destroyed) return 0;
    const cfg = config_mod.get();

    if (!cfg.confirm_close_window) {
        state.window_manager.closeWindow(state);
        return 0;
    }

    const ws_count = state.workspaces.items.len;
    if (ws_count <= 1) {
        state.window_manager.closeWindow(state);
        return 0;
    }

    // Multiple workspaces — show confirmation dialog
    showCloseConfirmation(state);
    return 1; // block close; dialog will handle it
}

fn showCloseConfirmation(state: *WindowState) void {
    const ws_count = state.workspaces.items.len;
    const is_last = state.window_manager.windows.items.len <= 1;

    var msg_buf: [320:0]u8 = [_:0]u8{0} ** 320;
    if (is_last) {
        _ = std.fmt.bufPrint(&msg_buf, "Quit Seance? {d} workspaces will be saved and restored next launch.", .{ws_count}) catch {};
    } else {
        _ = std.fmt.bufPrint(&msg_buf, "{d} workspaces in this window will be discarded.", .{ws_count}) catch {};
    }

    const title: [*:0]const u8 = if (is_last) "Quit Seance?" else "Close window?";
    const confirm_label: [*:0]const u8 = if (is_last) "Quit" else "Close Window";

    const dialog = c.adw_alert_dialog_new(title, &msg_buf);
    c.adw_alert_dialog_add_response(@as(*c.AdwAlertDialog, @ptrCast(dialog)), "cancel", "Cancel");
    c.adw_alert_dialog_add_response(@as(*c.AdwAlertDialog, @ptrCast(dialog)), "close", confirm_label);
    c.adw_alert_dialog_set_response_appearance(@as(*c.AdwAlertDialog, @ptrCast(dialog)), "close", c.ADW_RESPONSE_DESTRUCTIVE);
    c.adw_alert_dialog_set_default_response(@as(*c.AdwAlertDialog, @ptrCast(dialog)), "cancel");
    c.adw_alert_dialog_set_close_response(@as(*c.AdwAlertDialog, @ptrCast(dialog)), "cancel");

    _ = c.g_signal_connect_data(@as(c.gpointer, @ptrCast(dialog)), "response", @as(c.GCallback, @ptrCast(&onCloseWindowResponse)), @ptrCast(state), null, 0);
    c.adw_dialog_present(@as(*c.AdwDialog, @ptrCast(dialog)), state.gtk_window);
}

fn onCloseWindowResponse(_: *c.AdwAlertDialog, response: [*:0]const u8, data: c.gpointer) callconv(.c) void {
    if (!std.mem.eql(u8, std.mem.sliceTo(response, 0), "close")) return;
    const state: *WindowState = @ptrCast(@alignCast(data));
    state.window_manager.closeWindow(state);
    c.gtk_window_destroy(@ptrCast(state.gtk_window));
}

/// Returns true if quitting would close more than one window or more than
/// one workspace total (enough state to warrant a confirmation).
fn hasInterestingState(wm: *WindowManager) bool {
    if (wm.windows.items.len > 1) return true;
    var total: usize = 0;
    for (wm.windows.items) |w| total += w.workspaces.items.len;
    return total > 1;
}

fn triggerQuit(wm: *WindowManager) void {
    c.g_application_quit(@as(*c.GApplication, @ptrCast(wm.app)));
}

fn showQuitConfirmation(state: *WindowState) void {
    const wm = state.window_manager;
    const win_count = wm.windows.items.len;
    var ws_total: usize = 0;
    for (wm.windows.items) |w| ws_total += w.workspaces.items.len;

    var msg_buf: [320:0]u8 = [_:0]u8{0} ** 320;
    if (win_count > 1) {
        _ = std.fmt.bufPrint(&msg_buf, "{d} windows and {d} workspaces will be saved and restored next launch.", .{ win_count, ws_total }) catch {};
    } else {
        _ = std.fmt.bufPrint(&msg_buf, "{d} workspaces will be saved and restored next launch.", .{ws_total}) catch {};
    }

    const dialog = c.adw_alert_dialog_new("Quit Seance?", &msg_buf);
    c.adw_alert_dialog_add_response(@as(*c.AdwAlertDialog, @ptrCast(dialog)), "cancel", "Cancel");
    c.adw_alert_dialog_add_response(@as(*c.AdwAlertDialog, @ptrCast(dialog)), "quit", "Quit");
    c.adw_alert_dialog_set_response_appearance(@as(*c.AdwAlertDialog, @ptrCast(dialog)), "quit", c.ADW_RESPONSE_DESTRUCTIVE);
    c.adw_alert_dialog_set_default_response(@as(*c.AdwAlertDialog, @ptrCast(dialog)), "cancel");
    c.adw_alert_dialog_set_close_response(@as(*c.AdwAlertDialog, @ptrCast(dialog)), "cancel");

    _ = c.g_signal_connect_data(@as(c.gpointer, @ptrCast(dialog)), "response", @as(c.GCallback, @ptrCast(&onQuitResponse)), @ptrCast(state), null, 0);
    c.adw_dialog_present(@as(*c.AdwDialog, @ptrCast(dialog)), state.gtk_window);
}

fn onQuitResponse(_: *c.AdwAlertDialog, response: [*:0]const u8, data: c.gpointer) callconv(.c) void {
    if (!std.mem.eql(u8, std.mem.sliceTo(response, 0), "quit")) return;
    const state: *WindowState = @ptrCast(@alignCast(data));
    triggerQuit(state.window_manager);
}

fn onWindowFocusChanged(_: *c.GObject, _: ?*anyopaque, data: c.gpointer) callconv(.c) void {
    const state: *WindowState = @ptrCast(@alignCast(data));
    if (c.gtk_window_is_active(@as(*c.GtkWindow, @ptrCast(state.gtk_window))) != 0) {
        state.window_manager.setActiveWindow(state);

        // Auto-dismiss notifications for the focused pane when window gains focus
        const ws = state.activeWorkspace() orelse return;
        const fg = ws.focusedGroup() orelse return;
        const fp = fg.focusedTerminalPane() orelse return;
        if (fp.has_unread) {
            fp.focus();
            fp.triggerFlash();
        }
    }
}

fn onWorkspaceSelect(index: usize) void {
    if (window_manager) |wm| if (wm.active_window) |state| state.selectWorkspace(index);
}

fn onWorkspaceNew() void {
    if (window_manager) |wm| if (wm.active_window) |state| state.newWorkspace() catch {};
}

fn onWorkspaceReorder(from: usize, to: usize) void {
    if (window_manager) |wm| if (wm.active_window) |state| state.reorderWorkspace(from, to);
}

fn onWorkspaceClose(index: usize) void {
    if (window_manager) |wm| if (wm.active_window) |state| state.closeWorkspace(index);
}

fn onToggleNotifications() void {
    if (window_manager) |wm| if (wm.active_window) |state| state.toggleNotificationPopover();
}

fn onToggleSidebar() void {
    if (window_manager) |wm| if (wm.active_window) |state| state.toggleSidebar();
}

fn onSidebarRevealed(revealer: *c.GtkRevealer, _: ?*anyopaque, user_data: c.gpointer) callconv(.c) void {
    if (c.gtk_revealer_get_child_revealed(revealer) != 0) {
        const tab_bar: *vtab_mod.VerticalTabBar = @ptrCast(@alignCast(user_data));
        tab_bar.relayout();
    }
}

fn onSettings() void {
    if (window_manager) |wm| if (wm.active_window) |state| state.showSettings();
}

fn onMoveToWindow(ws_idx: usize, target_window_idx: usize) void {
    if (window_manager) |wm| {
        if (wm.active_window) |state| {
            if (ws_idx >= state.workspaces.items.len) return;
            if (target_window_idx >= wm.windows.items.len) return;
            const ws = state.workspaces.items[ws_idx];
            const target = wm.windows.items[target_window_idx];
            _ = wm.moveWorkspaceToWindow(ws.id, target);
        }
    }
}

fn onWorkspaceContextAction(index: usize, action: ContextAction) void {
    if (window_manager) |wm| {
        if (wm.active_window) |state| {
            switch (action) {
                .pin_toggle => {
                    const saved = state.active_workspace;
                    state.active_workspace = index;
                    state.togglePinWorkspace();
                    state.active_workspace = saved;
                },
                .rename => {
                    const saved = state.active_workspace;
                    state.active_workspace = index;
                    state.renameWorkspace();
                    state.active_workspace = saved;
                },
                .color_0, .color_1, .color_2, .color_3, .color_4, .color_5, .color_6 => {
                    if (index < state.workspaces.items.len) {
                        const theme_mod = @import("theme.zig");
                        const colors = theme_mod.resolveColors();
                        const ci: usize = @intFromEnum(action) - @intFromEnum(ContextAction.color_0);
                        const ws = state.workspaces.items[index];
                        ws.setCustomColor(&colors.tab_colors[ci]);
                        state.sidebar.refresh();
                        state.sidebar.setActive(state.active_workspace);
                    }
                },
                .color_none => {
                    if (index < state.workspaces.items.len) {
                        const ws = state.workspaces.items[index];
                        ws.clearCustomColor();
                        state.sidebar.refresh();
                        state.sidebar.setActive(state.active_workspace);
                    }
                },
                .move_up => {
                    if (index > 0) state.reorderWorkspace(index, index - 1);
                },
                .move_down => {
                    if (index + 1 < state.workspaces.items.len) state.reorderWorkspace(index, index + 1);
                },
                .move_to_top => {
                    if (index < state.workspaces.items.len) {
                        const ws = state.workspaces.items[index];
                        state.reorderWorkspaceToTop(ws.id);
                    }
                },
                .close => state.closeWorkspace(index),
                .mark_read => {
                    if (index < state.workspaces.items.len) {
                        const ws = state.workspaces.items[index];
                        state.notif_center.markWorkspaceRead(ws.id, @ptrCast(ws));
                    }
                },
            }
        }
    }
}

fn onNotifJump(workspace_id: u64, pane_group_id: u64, pane_id: u64) void {
    if (window_manager) |wm| {
        // Route to the window that owns this workspace
        if (wm.findByWorkspaceId(workspace_id)) |state| {
            state.jumpToNotification(workspace_id, pane_group_id, pane_id);
            c.gtk_window_present(@as(*c.GtkWindow, @ptrCast(state.gtk_window)));
        }
    }
}

fn onNotifPopoverClosed(_: *c.GtkPopover, data: c.gpointer) callconv(.c) void {
    const state: *WindowState = @ptrCast(@alignCast(data));

    // Find the widget under the pointer — the click that dismissed the popover
    // was consumed by autohide, so we need to manually focus the right pane.
    const display = c.gdk_display_get_default() orelse return;
    const seat = c.gdk_display_get_default_seat(display) orelse return;
    const pointer = c.gdk_seat_get_pointer(seat) orelse return;
    const surface = c.gtk_native_get_surface(@as(*c.GtkNative, @ptrCast(state.gtk_window))) orelse return;
    var x: f64 = 0;
    var y: f64 = 0;
    _ = c.gdk_surface_get_device_position(surface, pointer, &x, &y, null);

    const picked = c.gtk_widget_pick(state.gtk_window, x, y, c.GTK_PICK_DEFAULT) orelse {
        // Pointer not over any widget — fall back to refocusing current pane
        if (state.activeWorkspace()) |ws| {
            if (ws.focusedGroup()) |fg| fg.focus();
        }
        return;
    };

    // Walk up from the picked widget looking for a GL area tagged with "seance-pane"
    var widget: ?*c.GtkWidget = picked;
    while (widget) |w| {
        const pane_ptr = c.g_object_get_data(@as(*c.GObject, @ptrCast(w)), "seance-pane");
        if (pane_ptr != null) {
            // Found a pane's GL area — grab_focus triggers onFocusEnter which
            // updates focused_column and applies all focus styling.
            _ = c.gtk_widget_grab_focus(w);
            return;
        }
        widget = c.gtk_widget_get_parent(w);
    }

    // Clicked somewhere that isn't a pane — refocus current pane
    if (state.activeWorkspace()) |ws| {
        if (ws.focusedGroup()) |fg| fg.focus();
    }
}

fn onNotifShowSidebar() void {
    if (window_manager) |wm| if (wm.active_window) |state| {
        if (state.notif_popover) |popover| {
            c.gtk_popover_popdown(@ptrCast(popover));
        }
    };
}

// ── NotificationCenter callback adapters ────────────────────────────

fn initNotificationCenter(state: *WindowState) void {
    state.notif_center.ctx = @ptrCast(state);
    state.notif_center.on_sidebar_refresh = &ncSidebarRefresh;
    state.notif_center.on_play_sound = &ncPlaySound;
    state.notif_center.on_pane_notify = &ncPaneNotify;
    state.notif_center.on_pane_trigger_flash = &ncPaneTriggerFlash;
    state.notif_center.on_tab_badge_update = &ncTabBadgeUpdate;
    state.notif_center.on_desktop_notify = &ncDesktopNotify;
    state.notif_center.on_find_pane = &ncFindPane;
    state.notif_center.on_check_visible = &ncCheckVisible;
    state.notif_center.on_clear_ws_visuals = &ncClearWsVisuals;
}

fn ncSidebarRefresh(ctx: *anyopaque) void {
    const state: *WindowState = @ptrCast(@alignCast(ctx));
    state.sidebar.refresh();
    state.sidebar.setActive(state.active_workspace);
}

fn ncPlaySound(ctx: *anyopaque) void {
    const state: *WindowState = @ptrCast(@alignCast(ctx));
    state.sound_player.play();
}

fn ncPaneNotify(pane_ptr: *anyopaque, unread: bool) void {
    const Pane = @import("pane.zig").Pane;
    const pane: *Pane = @ptrCast(@alignCast(pane_ptr));
    if (unread) {
        pane.notify();
    } else {
        pane.has_unread = false;
        if (pane.notif_border_timeout != 0) {
            _ = c.g_source_remove(pane.notif_border_timeout);
        }
        pane.notif_border_timeout = c.g_timeout_add(1500, @ptrCast(&ncClearNotifBorder), pane_ptr);
    }
}

fn ncClearNotifBorder(data: c.gpointer) callconv(.c) c.gboolean {
    const Pane = @import("pane.zig").Pane;
    const pane: *Pane = @ptrCast(@alignCast(data));
    pane.notif_border_timeout = 0;
    c.gtk_widget_remove_css_class(pane.widget, "pane-notification");
    return 0;
}

fn ncPaneTriggerFlash(pane_ptr: *anyopaque) void {
    const Pane = @import("pane.zig").Pane;
    const pane: *Pane = @ptrCast(@alignCast(pane_ptr));
    pane.triggerFlash();
}

fn ncTabBadgeUpdate(ctx: *anyopaque, pane_id: u64, has_notif: bool) void {
    const state: *WindowState = @ptrCast(@alignCast(ctx));
    for (state.workspaces.items) |ws| {
        if (ws.findGroupContainingPane(pane_id)) |grp| {
            grp.setNotificationForPane(pane_id, has_notif);
            return;
        }
    }
}

fn ncDesktopNotify(title: [*:0]const u8, body: [*:0]const u8) void {
    if (comptime builtin.os.tag == .linux) {
        const notif = c.notify_notification_new(title, body, "dialog-information");
        if (notif != null) {
            _ = c.notify_notification_show(notif, null);
            c.g_object_unref(@ptrCast(notif));
        }
    }
    // TODO: macOS notification support (e.g. NSUserNotification / UNUserNotificationCenter)
}

fn ncFindPane(ctx: *anyopaque, pane_id: u64) ?*anyopaque {
    const state: *WindowState = @ptrCast(@alignCast(ctx));
    for (state.workspaces.items) |ws| {
        if (ws.findPaneById(pane_id)) |pane| return @ptrCast(pane);
    }
    return null;
}

fn ncCheckVisible(ctx: *anyopaque, pane_id: u64, ws_id: u64) notification.NotificationCenter.Visibility {
    const state: *WindowState = @ptrCast(@alignCast(ctx));
    if (state.workspaces.items.len == 0) return .{ .visible = false, .in_active_group = false };
    const is_active_ws = state.workspaces.items[state.active_workspace].id == ws_id;
    if (!is_active_ws) return .{ .visible = false, .in_active_group = false };
    const ws = state.activeWorkspace() orelse return .{ .visible = false, .in_active_group = false };
    const grp = ws.findGroupContainingPane(pane_id) orelse return .{ .visible = false, .in_active_group = false };
    const is_active_in_group = if (grp.focusedTerminalPane()) |fp| fp.id == pane_id else false;
    const is_focused = if (ws.focusedGroup()) |fg| fg == grp and is_active_in_group else false;
    return .{ .visible = is_focused, .in_active_group = is_active_in_group };
}

fn ncClearWsVisuals(ws_ptr: *anyopaque) void {
    const ws: *Workspace = @ptrCast(@alignCast(ws_ptr));
    for (ws.columns.items) |col| {
        for (col.groups.items) |grp| {
            for (grp.panels.items) |panel| {
                if (panel.asTerminal()) |pane| {
                    pane.has_unread = false;
                    c.gtk_widget_remove_css_class(pane.widget, "pane-notification");
                }
            }
            grp.clearAllTabNotifications();
        }
    }
}

fn onMetadataRefresh(data: c.gpointer) callconv(.c) c.gboolean {
    const state: *WindowState = @ptrCast(@alignCast(data));
    state.refreshMetadata();
    return 1; // G_SOURCE_CONTINUE
}

fn onVimCheckRefresh(data: c.gpointer) callconv(.c) c.gboolean {
    const state: *WindowState = @ptrCast(@alignCast(data));
    var changed = false;
    for (state.workspaces.items) |ws| {
        for (ws.columns.items) |col| {
            for (col.groups.items) |grp| {
                for (grp.panels.items) |panel| {
                    if (panel.asTerminal()) |pane| {
                        if (pane.checkVimStatus()) changed = true;
                    }
                }
            }
        }
    }
    if (changed) {
        state.sidebar.refresh();
        state.sidebar.setActive(state.active_workspace);
    }
    return 1; // G_SOURCE_CONTINUE
}

fn onPortScanRefresh(data: c.gpointer) callconv(.c) c.gboolean {
    const state: *WindowState = @ptrCast(@alignCast(data));
    if (state.config.sidebar_show_ports) state.refreshPorts();
    return 1; // G_SOURCE_CONTINUE
}

const RenameDialogCtx = struct {
    state: *WindowState,
    ws_id: u64,
    entry: *c.GtkEditable,
};

fn onRenameResponse(_: *c.AdwAlertDialog, response: [*:0]const u8, data: c.gpointer) callconv(.c) void {
    const ctx: *RenameDialogCtx = @ptrCast(@alignCast(data));
    const resp = std.mem.sliceTo(response, 0);

    if (std.mem.eql(u8, resp, "rename")) {
        const text: [*c]const u8 = c.gtk_editable_get_text(ctx.entry);
        if (text != null) {
            const slice = std.mem.span(text);
            const trimmed = std.mem.trim(u8, slice, " \t\r\n");
            if (trimmed.len > 0) {
                for (ctx.state.workspaces.items) |ws| {
                    if (ws.id == ctx.ws_id) {
                        ws.setCustomTitle(trimmed);
                        break;
                    }
                }
            }
        }
        ctx.state.sidebar.refresh();
        ctx.state.sidebar.setActive(ctx.state.active_workspace);
    } else if (std.mem.eql(u8, resp, "clear")) {
        for (ctx.state.workspaces.items) |ws| {
            if (ws.id == ctx.ws_id) {
                ws.clearCustomTitle();
                break;
            }
        }
        ctx.state.sidebar.refresh();
        ctx.state.sidebar.setActive(ctx.state.active_workspace);
    }

    ctx.state.alloc.destroy(ctx);
}

const RenameTabDialogCtx = struct {
    state: *WindowState,
    pane_id: u64,
    entry: *c.GtkEditable,
};

fn onRenameTabResponse(_: *c.AdwAlertDialog, response: [*:0]const u8, data: c.gpointer) callconv(.c) void {
    const ctx: *RenameTabDialogCtx = @ptrCast(@alignCast(data));
    const resp = std.mem.sliceTo(response, 0);

    if (std.mem.eql(u8, resp, "rename")) {
        const text: [*c]const u8 = c.gtk_editable_get_text(ctx.entry);
        if (text != null) {
            const slice = std.mem.span(text);
            const trimmed = std.mem.trim(u8, slice, " \t\r\n");
            if (trimmed.len > 0) {
                for (ctx.state.workspaces.items) |ws| {
                    if (ws.findGroupContainingPane(ctx.pane_id)) |grp| {
                        if (ws.findPaneById(ctx.pane_id)) |pane| {
                            pane.setCustomTitle(trimmed);
                            grp.updateTitleForPane(ctx.pane_id, trimmed);
                        }
                        break;
                    }
                }
            }
        }
    } else if (std.mem.eql(u8, resp, "clear")) {
        for (ctx.state.workspaces.items) |ws| {
            if (ws.findGroupContainingPane(ctx.pane_id)) |grp| {
                if (ws.findPaneById(ctx.pane_id)) |pane| {
                    pane.clearCustomTitle();
                    const title = pane.getCachedTitle() orelse "Terminal";
                    grp.updateTitleForPane(ctx.pane_id, title);
                }
                break;
            }
        }
    }

    ctx.state.alloc.destroy(ctx);
}

var css_provider_global: ?*c.GtkCssProvider = null;

fn loadThemeCss() void {
    const theme_mod = @import("theme.zig");
    const colors = theme_mod.resolveColors();

    // Set libadwaita dark/light mode. In default mode (no explicit theme),
    // let libadwaita track the system preference. With an explicit theme,
    // force based on the terminal background luminance.
    const style_manager = c.adw_style_manager_get_default();
    if (config_mod.get().theme_len == 0) {
        c.adw_style_manager_set_color_scheme(style_manager, c.ADW_COLOR_SCHEME_PREFER_DARK);
    } else {
        if (colors.is_light)
            c.adw_style_manager_set_color_scheme(style_manager, c.ADW_COLOR_SCHEME_FORCE_LIGHT)
        else
            c.adw_style_manager_set_color_scheme(style_manager, c.ADW_COLOR_SCHEME_FORCE_DARK);
    }

    const bg: []const u8 = &colors.window_bg;
    const fg: []const u8 = &colors.window_fg;
    const accent: []const u8 = &colors.accent_bg;

    // When background-opacity < 1, pane wrappers must be transparent so the
    // GL renderer's alpha shows through (mirrors ghostty's syncAppearance).
    const cfg = config_mod.get();
    const pane_bg: []const u8 = if (cfg.background_opacity < 1.0) "transparent" else bg;
    const accent_fg: []const u8 = &colors.accent_fg;
    const notify: []const u8 = &colors.notify_border;
    var css_buf: [10240]u8 = undefined;
    var stream = std.io.fixedBufferStream(&css_buf);
    const w = stream.writer();

    // Override libadwaita's named colors with the terminal theme colors
    // so that all UI chrome (@window_bg_color, @window_fg_color refs) matches the terminal.
    // Includes sidebar_* colors added in libadwaita 1.4+ which are separate from window_*.
    w.print(
        \\@define-color window_bg_color {s};
        \\@define-color window_fg_color {s};
        \\@define-color view_bg_color {s};
        \\@define-color view_fg_color {s};
        \\@define-color card_bg_color {s};
        \\@define-color card_fg_color {s};
        \\@define-color headerbar_bg_color {s};
        \\@define-color headerbar_fg_color {s};
        \\@define-color popover_bg_color {s};
        \\@define-color popover_fg_color {s};
        \\@define-color dialog_bg_color {s};
        \\@define-color dialog_fg_color {s};
        \\@define-color sidebar_bg_color {s};
        \\@define-color sidebar_fg_color {s};
        \\@define-color sidebar_backdrop_color {s};
        \\@define-color secondary_sidebar_bg_color {s};
        \\@define-color secondary_sidebar_fg_color {s};
        \\@define-color secondary_sidebar_backdrop_color {s};
        \\@define-color accent_bg_color {s};
        \\@define-color accent_fg_color {s};
        \\@define-color accent_color {s};
        \\@define-color borders alpha({s}, 0.15);
        \\
    , .{ bg, fg, bg, fg, bg, fg, bg, fg, bg, fg, bg, fg, bg, fg, bg, bg, fg, bg, accent, accent_fg, accent, fg }) catch return;

    // libadwaita forces `background: none` on any headerbar living inside
    // an AdwToolbarView's top/bottom bar, so @headerbar_bg_color never gets
    // applied to our CSD chrome on its own. Paint it ourselves at the
    // configured opacity so it tracks the terminal transparency and
    // actually picks up the theme color. PRIORITY_APPLICATION beats the
    // libadwaita rule regardless of specificity.
    w.print(
        \\toolbarview > .top-bar headerbar {{ background-color: alpha(@headerbar_bg_color, {d:.3}); }}
        \\
    , .{cfg.background_opacity}) catch return;

    // UI chrome uses libadwaita CSS variables (@window_bg_color, @window_fg_color)
    // which are overridden above from the terminal's resolved theme colors.
    // The sidebar bg keeps its tinted mix but gets the same alpha as the
    // terminals/headerbar so transparency tracks background-opacity.
    w.print(
        \\.sidebar {{ background-color: alpha(mix(@window_bg_color, @window_fg_color, 0.10), {d:.3}); color: @window_fg_color; border: none; }}
        \\.sidebar-header {{ font-weight: bold; font-size: 14px; }}
        \\tabbar {{ border-bottom: none; box-shadow: none; }}
        \\tabbar .box {{ background-color: mix(@window_bg_color, @window_fg_color, 0.05); border-bottom: none; box-shadow: none; }}
        \\tabbar tab:selected {{ background-color: mix(@window_bg_color, @window_fg_color, 0.15); }}
        \\tabbar.tab-bar-focused tab:selected {{ background-color: mix(@window_bg_color, @accent_bg_color, 0.35); }}
        \\window.ssd.no-border-radius {{ border-radius: 0; }}
        \\.sidebar row {{ padding: 0; margin: 0; outline: none; outline-width: 0; outline-offset: 0; }}
        \\.sidebar row:focus {{ outline: none; outline-width: 0; }}
        \\.sidebar row:focus-visible {{ outline: none; outline-width: 0; }}
        \\.sidebar row:hover {{ background-color: alpha(@window_fg_color, 0.04); }}
        \\.sidebar row:selected {{ background-color: mix(@window_bg_color, @accent_bg_color, 0.35); }}
        \\.sidebar row:selected:hover {{ background-color: mix(@window_bg_color, @accent_bg_color, 0.45); }}
        \\.sidebar-row {{ padding: 10px 12px 10px 15px; }}
        \\.sidebar-ws-title {{ font-weight: 600; font-size: 12.5px; }}
        \\.sidebar-ws-meta {{ font-size: 10px; opacity: 0.8; }}
        \\.sidebar-add {{ border-radius: 6px; padding: 6px 12px; }}
        \\.sidebar-branch-icon {{ opacity: 0.8; }}
        \\.sidebar-branch-text {{ font-size: 10px; opacity: 0.8; }}
        \\.sidebar-branch-sep {{ font-size: 10px; opacity: 0.8; padding: 0 1px; }}
        \\.sidebar-status-icon {{ opacity: 0.8; }}
        \\
    , .{cfg.background_opacity}) catch return;

    w.print(
        \\.sidebar-pin-icon {{ opacity: 0.8; }}
        \\
    , .{}) catch return;

    w.print(
        \\.sidebar-row-dragging {{ opacity: 0.6; }}
        \\.sidebar-row-drag-over {{ background: alpha({s}, 0.15); border-top: 2px solid alpha({s}, 0.6); }}
        \\.pane-focused {{ outline: 2px solid transparent; outline-offset: -2px; background-color: {s}; }}
        \\.pane-unfocused {{ outline: 2px solid transparent; outline-offset: -2px; background-color: {s}; }}
        \\.pane-unfocused > * {{ opacity: 0.80; }}
        \\.pane-focus-bar {{ background: mix({s}, {s}, 0.5); opacity: 0; transition: opacity 100ms ease-in-out; }}
        \\.multi-pane .pane-focused .pane-focus-bar {{ opacity: 1; }}
        \\.pane-notification {{ outline: 2px solid {s}; outline-offset: -2px; background-color: {s}; }}
        \\.pane-drop-target {{ outline: 2px dashed alpha({s}, 0.6); outline-offset: -2px; background-color: {s}; }}
        \\
    , .{ accent, accent, pane_bg, pane_bg, pane_bg, accent, notify, pane_bg, notify, pane_bg }) catch return;

    w.print(
        \\.sidebar-badge {{ background-color: {s}; color: {s}; border-radius: 50%; min-width: 18px; min-height: 18px; font-size: 9px; font-weight: 600; padding: 0; }}
        \\.notif-bell-badge {{ background-color: {s}; color: {s}; border-radius: 50%; min-width: 16px; min-height: 16px; font-size: 8px; font-weight: 700; padding: 0; margin-top: 2px; margin-right: 2px; }}
        \\.sidebar-notif-preview {{ font-size: 10px; opacity: 0.8; }}
        \\.sidebar-status-entry {{ font-size: 10px; opacity: 0.8; }}
        \\.sidebar-show-more-btn {{ font-size: 10px; padding: 0; min-height: 0; opacity: 0.8; margin-top: 2px; margin-bottom: 2px; }}
        \\.sidebar-show-more-btn:hover {{ opacity: 1.0; }}
        \\.sidebar-progress-label {{ font-size: 10px; opacity: 0.8; }}
        \\.sidebar-col-dots {{ font-size: 8px; opacity: 0.5; margin-top: 2px; letter-spacing: 1px; }}
        \\
    , .{ accent, accent_fg, accent, accent_fg }) catch return;

    w.print(
        \\.search-overlay {{ background-color: alpha(@window_bg_color, 0.95); border-radius: 6px; padding: 4px 8px; margin: 8px; border: 1px solid alpha(@window_fg_color, 0.25); }}
        \\.search-overlay button {{ padding: 0; }}
        \\.search-match-label {{ color: alpha(@window_fg_color, 0.6); font-size: 0.85em; min-width: 50px; }}
        \\.pane-zoomed {{ outline: 2px solid rgba(255, 200, 0, 0.3); outline-offset: -2px; }}
        \\.pane-flash {{ outline: 2px solid alpha({s}, 1.0); outline-offset: -2px; }}
        \\
    , .{notify}) catch return;

    w.print(
        \\popover.notification-popover > contents {{ background-color: mix(@window_bg_color, @window_fg_color, 0.15); border: none; }}
        \\popover.notification-popover > arrow {{ background-color: mix(@window_bg_color, @window_fg_color, 0.15); }}
        \\.notif-list {{ background-color: transparent; }}
        \\.notif-row {{ padding: 10px 8px; border-radius: 6px; }}
        \\.notif-row:hover {{ background-color: alpha(@window_fg_color, 0.05); }}
        \\.notif-unread-dot {{ color: {s}; font-size: 8px; min-width: 12px; }}
        \\.notif-title {{ font-weight: bold; font-size: 12px; }}
        \\.notif-time {{ font-size: 10px; opacity: 0.5; }}
        \\.notif-body {{ font-size: 11px; opacity: 0.6; }}
        \\
    , .{accent}) catch return;

    w.print(
        \\.sidebar-close-btn {{ min-width: 16px; min-height: 16px; padding: 0; margin: 0; border-radius: 50%; opacity: 0.7; transition: opacity 0.14s ease-in-out; }}
        \\.sidebar-close-btn:hover {{ opacity: 1.0; background-color: alpha(@window_fg_color, 0.1); }}
        \\.sidebar-ws-ports {{ font-size: 10px; opacity: 0.8; }}
        \\.sidebar-progress trough {{ min-height: 3px; border-radius: 1.5px; background-color: alpha(@window_fg_color, 0.2); }}
        \\.sidebar-progress progress {{ min-height: 3px; border-radius: 1.5px; background-color: {s}; }}
        \\.sidebar-footer {{ padding: 4px 6px; border-top: 1px solid alpha(@window_fg_color, 0.15); }}
        \\.sidebar-footer button {{ min-width: 28px; min-height: 28px; padding: 4px; border-radius: 6px; }}
        \\
    , .{accent}) catch return;

    // Vertical tab bar styles
    w.print(
        \\.vtab-bar {{ padding: 5px 0 2px 0; }}
        \\.vtab-wrapper {{ margin: 1px 6px; }}
        \\.vtab {{ padding: 5px 6px 6px 6px; border-radius: 6px; transition: background-color 150ms ease-in-out; }}
        \\.vtab:hover {{ background-color: alpha(@window_fg_color, 0.04); }}
        \\.vtab-selected {{ background-color: mix(@window_bg_color, @accent_bg_color, 0.35); }}
        \\.vtab-selected:hover {{ background-color: mix(@window_bg_color, @accent_bg_color, 0.45); }}
        \\.vtab-sep-line {{ background-color: alpha(@window_fg_color, 0.12); min-height: 1px; border-radius: 0; }}
        \\.vtab-close {{ min-width: 16px; min-height: 16px; padding: 0; margin: 4px; border-radius: 50%; opacity: 0.7; transition: opacity 150ms ease-in-out; }}
        \\.vtab-close:hover {{ opacity: 1.0; background-color: alpha(@window_fg_color, 0.1); }}
        \\.vtab-dragging {{ box-shadow: 0 2px 8px alpha(black, 0.3); }}
        \\.vtab-attention {{ }}
        \\.vtab-color-bar {{ min-width: 3px; border-radius: 2px; margin-left: 5px; margin-top: 5px; margin-bottom: 6px; }}
        \\
    , .{}) catch return;

    // Backdrop (window unfocused): dim sidebar to match libadwaita tab bar behavior.
    // libadwaita applies filter: opacity(0.5) to the entire tab content area,
    // which uniformly dims everything while preserving accent colors on selected tabs.
    w.print(
        \\.sidebar:backdrop .vtab-bar {{ filter: opacity(0.5); transition: filter 200ms ease-in-out; }}
        \\.sidebar:backdrop .sidebar-footer {{ filter: opacity(0.5); transition: filter 200ms ease-in-out; }}
        \\
    , .{}) catch return;

    w.print(
        \\.column-has-divider {{ border-left: 1px solid alpha(@window_fg_color, 0.12); }}
        \\.column-has-right-divider {{ border-right: 1px solid alpha(@window_fg_color, 0.12); }}
        \\.row-has-divider {{ border-top: 1px solid alpha(@window_fg_color, 0.12); }}
        \\.resize-handle {{ background: none; }}
        \\.command-palette-overlay {{ background-color: rgba(0, 0, 0, 0.24); }}
        \\.command-palette {{ background-color: @window_bg_color; border-radius: 8px; border: 1px solid alpha(@window_fg_color, 0.18); box-shadow: 0 5px 10px alpha(black, 0.24); min-width: 340px; }}
        \\.command-palette-entry {{ font-size: 13px; padding: 7px 9px; border: none; background: transparent; }}
        \\.command-palette-result {{ padding: 3px 12px; min-height: 24px; }}
        \\.command-palette-shortcut {{ font-size: 11px; font-weight: 500; color: alpha(@window_fg_color, 0.6); background-color: alpha(@window_fg_color, 0.08); border-radius: 4px; padding: 1px 6px; }}
        \\.command-palette-kind {{ font-size: 11px; color: alpha(@window_fg_color, 0.5); }}
        \\.command-palette-empty {{ font-size: 13px; color: alpha(@window_fg_color, 0.5); padding: 8px 12px; }}
        \\.command-palette-hint {{ font-size: 11px; color: alpha(@window_fg_color, 0.5); padding: 6px 9px; }}
        \\.command-palette-disabled {{ opacity: 0.4; }}
        \\.command-palette-subtitle {{ font-size: 11px; color: alpha(@window_fg_color, 0.5); }}
        \\
    , .{}) catch return;

    const pos = stream.pos;
    if (pos >= css_buf.len) return;
    css_buf[pos] = 0;

    if (css_provider_global) |provider| {
        c.gtk_css_provider_load_from_string(provider, @ptrCast(&css_buf));
    } else {
        const provider = c.gtk_css_provider_new();
        c.gtk_css_provider_load_from_string(provider, @ptrCast(&css_buf));
        c.gtk_style_context_add_provider_for_display(
            c.gdk_display_get_default(),
            @ptrCast(provider),
            c.GTK_STYLE_PROVIDER_PRIORITY_APPLICATION,
        );
        css_provider_global = provider;
    }

    // Sync window transparency: toggle the "background" CSS class on all
    // windows.  Adwaita paints a solid background when this class is present;
    // removing it lets the GL renderer's alpha show through.
    // Mirrors ghostty's syncAppearance() (ghostty/src/apprt/gtk/class/window.zig:682-685).
    if (window_manager) |wm| {
        for (wm.windows.items) |state| {
            const win: *c.GtkWidget = @ptrCast(state.gtk_window);
            if (cfg.background_opacity >= 1.0)
                c.gtk_widget_add_css_class(win, "background")
            else
                c.gtk_widget_remove_css_class(win, "background");
            blur.syncBlur(@ptrCast(state.gtk_window));
        }
    }
}

/// Handle system dark/light preference changes.
/// When in default mode (no explicit theme), re-resolve the theme and
/// update all terminal surfaces + UI chrome.
fn onSystemDarkChanged(_: *c.GObject, _: *c.GParamSpec, _: c.gpointer) callconv(.c) void {
    if (config_mod.get().theme_len > 0) return;
    reloadTheme();
}

/// Re-resolve the ghostty theme colors, update every terminal surface,
/// and regenerate the UI CSS. Used both on system dark/light changes and
/// at startup after session restore.
pub fn reloadTheme() void {
    const theme_mod = @import("theme.zig");
    const ghostty_bridge = @import("ghostty_bridge.zig");
    const cfg = config_mod.get();

    // When in default mode (no explicit theme), release any forced dark/light
    // override BEFORE resolving the theme name so that
    // resolveDefaultThemeName() sees the actual system preference.
    if (cfg.theme_len == 0) {
        const style_manager = c.adw_style_manager_get_default();
        c.adw_style_manager_set_color_scheme(style_manager, c.ADW_COLOR_SCHEME_PREFER_DARK);
    }

    // Build one ghostty config for color queries and all surface updates.
    const new_config = c.ghostty_config_new() orelse {
        loadThemeCss();
        return;
    };
    c.ghostty_config_load_default_files(@ptrCast(new_config));
    ghostty_bridge.applySeanceConfigPublic(@ptrCast(new_config));
    c.ghostty_config_finalize(@ptrCast(new_config));
    theme_mod.queryGhosttyColors(@ptrCast(new_config));

    // Update existing terminal surfaces with the new theme
    if (window_manager) |wm| {
        for (wm.windows.items) |state| {
            for (state.workspaces.items) |ws| {
                for (ws.columns.items) |col| {
                    for (col.groups.items) |grp| {
                        for (grp.panels.items) |panel| {
                            const pane = panel.asTerminal() orelse continue;
                            applyConfigToPane(pane, @ptrCast(new_config));
                        }
                    }
                }
            }
        }
    }

    c.ghostty_config_free(@ptrCast(new_config));

    loadThemeCss();
}

/// Connect to AdwStyleManager's notify::dark signal to track system dark/light changes.
/// Must be called once during app startup.
pub fn initThemeTracking() void {
    const style_manager = c.adw_style_manager_get_default();
    _ = c.g_signal_connect_data(
        @as(c.gpointer, @ptrCast(style_manager)),
        "notify::dark",
        @as(c.GCallback, @ptrCast(&onSystemDarkChanged)),
        null,
        null,
        0,
    );
}
