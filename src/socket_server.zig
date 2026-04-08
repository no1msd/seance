const std = @import("std");
const c = @import("c.zig").c;

pub const SocketServer = struct {
    fd: c_int = -1,
    watch_id: c.guint = 0,
    path_buf: [std.fs.max_path_bytes]u8 = undefined,
    path_len: usize = 0,

    /// Return the resolved socket path (expanded, no ~).
    /// Prefers XDG_RUNTIME_DIR for runtime sockets, falls back to $HOME/.seance/.
    pub fn resolvedPath(buf: []u8) ?[]const u8 {
        const config_mod = @import("config.zig");
        const cfg = config_mod.get();
        if (cfg.socket_path_len > 0) {
            const len = @min(cfg.socket_path_len, buf.len);
            @memcpy(buf[0..len], cfg.socket_path[0..len]);
            return buf[0..len];
        }
        if (std.posix.getenv("XDG_RUNTIME_DIR")) |runtime_dir| {
            return std.fmt.bufPrint(buf, "{s}/seance/seance.sock", .{runtime_dir}) catch null;
        }
        const home = std.posix.getenv("HOME") orelse return null;
        return std.fmt.bufPrint(buf, "{s}/.seance/seance.sock", .{home}) catch null;
    }

    pub fn start(self: *SocketServer) void {
        const path = resolvedPath(&self.path_buf) orelse return;
        self.path_len = path.len;

        // Ensure parent directory exists (owner-only access)
        if (std.mem.lastIndexOfScalar(u8, path, '/')) |sep| {
            var dir_buf: [std.fs.max_path_bytes]u8 = undefined;
            if (sep <= dir_buf.len) {
                @memcpy(dir_buf[0..sep], path[0..sep]);
                std.fs.makeDirAbsolute(dir_buf[0..sep]) catch |e| switch (e) {
                    error.PathAlreadyExists => {},
                    else => return,
                };
                // Restrict directory to owner-only so other users cannot
                // traverse to the socket even if XDG_RUNTIME_DIR is unset.
                dir_buf[sep] = 0;
                if (std.c.chmod(@ptrCast(dir_buf[0..sep].ptr), 0o700) != 0) return;
            }
        }

        // Remove stale socket file — but first check if another instance owns it
        // by attempting a connect.  If it succeeds, another seance is alive.
        if (std.fs.accessAbsolute(path, .{})) {
            if (isSocketAlive(path)) {
                std.log.warn("socket_server: another seance instance is using {s}", .{path});
                std.log.err("seance: another instance is already running ({s})", .{path});
                return;
            }
            // Socket is stale, safe to remove
            std.posix.unlink(path) catch {};
        } else |_| {}

        // Create Unix domain socket
        const fd = std.posix.socket(std.posix.AF.UNIX, std.posix.SOCK.STREAM | std.posix.SOCK.NONBLOCK, 0) catch return;
        self.fd = @intCast(fd);

        // Bind
        var addr = std.posix.sockaddr.un{ .path = undefined, .family = std.posix.AF.UNIX };
        @memset(&addr.path, 0);
        const copy_len = @min(path.len, addr.path.len - 1);
        for (0..copy_len) |i| {
            addr.path[i] = @intCast(path[i]);
        }
        std.posix.bind(fd, @ptrCast(&addr), @sizeOf(std.posix.sockaddr.un)) catch {
            std.posix.close(fd);
            self.fd = -1;
            return;
        };

        // Restrict socket to owner-only access
        std.posix.fchmod(fd, 0o600) catch {
            std.posix.close(fd);
            self.fd = -1;
            return;
        };

        // Listen
        std.posix.listen(fd, 128) catch {
            std.posix.close(fd);
            self.fd = -1;
            return;
        };

        // Watch for incoming connections via GIOChannel
        const channel = c.g_io_channel_unix_new(self.fd);
        _ = c.g_io_channel_set_encoding(channel, null, null);
        c.g_io_channel_set_buffered(channel, 0);
        self.watch_id = c.g_io_add_watch(channel, c.G_IO_IN, @ptrCast(&onIncoming), @ptrCast(self));
        c.g_io_channel_unref(channel);
    }

    pub fn stop(self: *SocketServer) void {
        if (self.watch_id != 0) {
            _ = c.g_source_remove(self.watch_id);
            self.watch_id = 0;
        }
        if (self.fd >= 0) {
            std.posix.close(@intCast(self.fd));
            self.fd = -1;
        }
        if (self.path_len > 0) {
            std.posix.unlink(self.path_buf[0..self.path_len]) catch {};
            self.path_len = 0;
        }
    }

    /// Check if a socket file is owned by a running instance by trying to connect.
    fn isSocketAlive(path: []const u8) bool {
        const probe = std.posix.socket(std.posix.AF.UNIX, std.posix.SOCK.STREAM, 0) catch return false;
        defer std.posix.close(probe);
        var addr = std.posix.sockaddr.un{ .path = undefined, .family = std.posix.AF.UNIX };
        @memset(&addr.path, 0);
        const plen = @min(path.len, addr.path.len - 1);
        for (0..plen) |i| {
            addr.path[i] = @intCast(path[i]);
        }
        if (std.posix.connect(probe, @ptrCast(&addr), @sizeOf(std.posix.sockaddr.un))) |_| {
            return true;
        } else |_| {
            return false;
        }
    }

    fn onIncoming(_: ?*c.GIOChannel, _: c.GIOCondition, user_data: c.gpointer) callconv(.c) c.gboolean {
        const self: *SocketServer = @ptrCast(@alignCast(user_data));
        if (self.fd < 0) return 0;

        // Accept connection
        const conn_fd = std.posix.accept(@intCast(self.fd), null, null, 0) catch return 1;
        defer std.posix.close(conn_fd);

        // Guard: don't let a slow client stall the GTK main thread.
        // Data from local Unix sockets arrives in microseconds; 10 ms is generous.
        var pfd = [1]std.posix.pollfd{.{
            .fd = conn_fd,
            .events = std.posix.POLL.IN,
            .revents = 0,
        }};
        _ = std.posix.poll(&pfd, 10) catch return 1;
        if (pfd[0].revents & std.posix.POLL.IN == 0) return 1;

        // Read command (short messages, single read is fine)
        var buf: [4096]u8 = undefined;
        const n = std.posix.read(conn_fd, &buf) catch return 1;
        if (n == 0) return 1;

        // Trim trailing newline/whitespace
        const line = std.mem.trimRight(u8, buf[0..n], &[_]u8{ '\r', '\n', ' ' });

        var resp_buf: [16384]u8 = undefined;
        const response = handleJsonRequest(line, &resp_buf);
        _ = std.posix.write(conn_fd, response) catch {};

        return 1; // continue watching
    }

    // ── JSON protocol ─────────────────────────────────────────────────

    fn handleJsonRequest(line: []const u8, resp_buf: []u8) []const u8 {
        // Parse the JSON request
        const parsed = std.json.parseFromSlice(std.json.Value, std.heap.page_allocator, line, .{}) catch {
            return writeJsonError(resp_buf, "null", "parse_error", "Invalid JSON");
        };
        defer parsed.deinit();

        const root = parsed.value;
        if (root != .object) {
            return writeJsonError(resp_buf, "null", "parse_error", "Request must be a JSON object");
        }

        // Extract id
        var id_buf: [128]u8 = undefined;
        const id_str = extractId(root.object, &id_buf);

        // Extract method
        const method_val = root.object.get("method") orelse {
            return writeJsonError(resp_buf, id_str, "invalid_request", "Missing 'method' field");
        };
        const method = switch (method_val) {
            .string => |s| s,
            else => return writeJsonError(resp_buf, id_str, "invalid_request", "'method' must be a string"),
        };

        // Extract params (optional)
        const params = root.object.get("params");

        // Dispatch
        return dispatchMethod(method, params, id_str, resp_buf);
    }

    fn extractId(obj: std.json.ObjectMap, buf: []u8) []const u8 {
        const id_val = obj.get("id") orelse return "null";
        return switch (id_val) {
            .string => |s| std.fmt.bufPrint(buf, "\"{s}\"", .{s}) catch "null",
            .integer => |n| std.fmt.bufPrint(buf, "{d}", .{n}) catch "null",
            .float => |f| std.fmt.bufPrint(buf, "{d}", .{@as(i64, @intFromFloat(f))}) catch "null",
            else => "null",
        };
    }

    fn dispatchMethod(method: []const u8, params: ?std.json.Value, id: []const u8, buf: []u8) []const u8 {
        // System methods
        if (eql(method, "system.ping")) return handleSystemPing(id, buf);
        if (eql(method, "system.identify")) return handleSystemIdentify(id, buf);
        if (eql(method, "system.capabilities")) return handleSystemCapabilities(id, buf);
        if (eql(method, "system.tree")) return handleSystemTree(id, buf);

        // Window methods
        if (eql(method, "window.list")) return handleWindowList(id, buf);
        if (eql(method, "window.current")) return handleWindowCurrent(id, buf);
        if (eql(method, "window.create")) return handleWindowCreate(id, buf);
        if (eql(method, "window.close")) return handleWindowClose(params, id, buf);

        // Workspace methods
        if (eql(method, "workspace.list")) return handleWorkspaceList(params, id, buf);
        if (eql(method, "workspace.current")) return handleWorkspaceCurrent(id, buf);
        if (eql(method, "workspace.create")) return handleWorkspaceCreate(params, id, buf);
        if (eql(method, "workspace.select")) return handleWorkspaceSelect(params, id, buf);
        if (eql(method, "workspace.close")) return handleWorkspaceClose(params, id, buf);
        if (eql(method, "workspace.rename")) return handleWorkspaceRename(params, id, buf);
        if (eql(method, "workspace.next")) return handleWorkspaceNext(id, buf);
        if (eql(method, "workspace.previous")) return handleWorkspacePrevious(id, buf);
        if (eql(method, "workspace.last")) return handleWorkspaceLast(id, buf);
        if (eql(method, "workspace.move_to_window")) return handleWorkspaceMoveToWindow(params, id, buf);
        if (eql(method, "workspace.reorder")) return handleWorkspaceReorder(params, id, buf);

        // Column methods
        if (eql(method, "column.move")) return handleColumnMove(params, id, buf);
        if (eql(method, "column.resize")) return handleColumnResize(params, id, buf);

        // Surface methods
        if (eql(method, "surface.last")) return handleSurfaceLast(params, id, buf);
        if (eql(method, "surface.list")) return handleSurfaceList(params, id, buf);
        if (eql(method, "surface.focus")) return handleSurfaceFocus(params, id, buf);
        if (eql(method, "surface.split")) return handleSurfaceSplit(params, id, buf);
        if (eql(method, "surface.close")) return handleSurfaceClose(params, id, buf);
        if (eql(method, "surface.send_text")) return handleSurfaceSendText(params, id, buf);
        if (eql(method, "surface.send_key")) return handleSurfaceSendKey(params, id, buf);
        if (eql(method, "surface.trigger_flash")) return handleSurfaceTriggerFlash(params, id, buf);
        if (eql(method, "surface.health")) return handleSurfaceHealth(params, id, buf);
        if (eql(method, "surface.read_screen")) return handleSurfaceReadScreen(params, id, buf);
        if (eql(method, "surface.expel")) return handleSurfaceExpel(params, id, buf);
        if (eql(method, "surface.resize_row")) return handleSurfaceResizeRow(params, id, buf);
        if (eql(method, "surface.reorder")) return handleSurfaceReorder(params, id, buf);

        // Notification methods
        if (eql(method, "notification.create")) return handleNotificationCreate(params, id, buf);
        if (eql(method, "notification.list")) return handleNotificationList(id, buf);
        if (eql(method, "notification.clear")) return handleNotificationClear(id, buf);

        // Workspace metadata methods
        if (eql(method, "workspace.set_status")) return handleWorkspaceSetStatus(params, id, buf);
        if (eql(method, "workspace.clear_status")) return handleWorkspaceClearStatus(params, id, buf);
        if (eql(method, "workspace.log")) return handleWorkspaceLog(params, id, buf);
        if (eql(method, "workspace.clear_log")) return handleWorkspaceClearLog(params, id, buf);
        if (eql(method, "workspace.set_progress")) return handleWorkspaceSetProgress(params, id, buf);
        if (eql(method, "workspace.clear_progress")) return handleWorkspaceClearProgress(params, id, buf);

        // Shell integration methods
        if (eql(method, "surface.report_cwd")) return handleSurfaceReportCwd(params, id, buf);
        if (eql(method, "surface.report_git")) return handleSurfaceReportGit(params, id, buf);
        if (eql(method, "surface.clear_git")) return handleSurfaceClearGit(params, id, buf);
        if (eql(method, "surface.report_state")) return handleSurfaceReportState(params, id, buf);

        return writeJsonError(buf, id, "method_not_found", "Unknown method");
    }

    fn eql(a: []const u8, b: []const u8) bool {
        return std.mem.eql(u8, a, b);
    }

    // ── Response helpers ────────────────────────────────────────────────

    fn writeJsonOk(buf: []u8, id: []const u8, result: []const u8) []const u8 {
        return std.fmt.bufPrint(buf, "{{\"id\":{s},\"ok\":true,\"result\":{s}}}\n", .{ id, result }) catch
            "{\"id\":null,\"ok\":false,\"error\":{\"code\":\"internal\",\"message\":\"Response too large\"}}\n";
    }

    fn writeJsonError(buf: []u8, id: []const u8, code: []const u8, message: []const u8) []const u8 {
        return std.fmt.bufPrint(buf, "{{\"id\":{s},\"ok\":false,\"error\":{{\"code\":\"{s}\",\"message\":\"{s}\"}}}}\n", .{ id, code, message }) catch
            "{\"id\":null,\"ok\":false,\"error\":{\"code\":\"internal\",\"message\":\"Response too large\"}}\n";
    }

    fn getParamString(params: ?std.json.Value, key: []const u8) ?[]const u8 {
        const p = params orelse return null;
        if (p != .object) return null;
        const val = p.object.get(key) orelse return null;
        return switch (val) {
            .string => |s| s,
            else => null,
        };
    }

    fn getParamInt(params: ?std.json.Value, key: []const u8) ?u64 {
        const p = params orelse return null;
        if (p != .object) return null;
        const val = p.object.get(key) orelse return null;
        return switch (val) {
            .integer => |n| if (n >= 0) @intCast(n) else null,
            .float => |f| if (f >= 0) @intCast(@as(i64, @intFromFloat(f))) else null,
            .string => |s| std.fmt.parseInt(u64, s, 10) catch null,
            else => null,
        };
    }

    fn getParamBool(params: ?std.json.Value, key: []const u8) ?bool {
        const p = params orelse return null;
        if (p != .object) return null;
        const val = p.object.get(key) orelse return null;
        return switch (val) {
            .bool => |b| b,
            else => null,
        };
    }

    fn getWindowManager() ?*@import("window_manager.zig").WindowManager {
        const Window = @import("window.zig");
        return Window.window_manager;
    }

    fn getActiveState() ?*@import("window.zig").WindowState {
        const wm = getWindowManager() orelse return null;
        return wm.active_window;
    }

    /// Escape a string for safe JSON embedding. Writes to buf and returns the slice.
    fn jsonEscapeString(input: []const u8, buf: []u8) []const u8 {
        var pos: usize = 0;
        for (input) |ch| {
            const needed: usize = switch (ch) {
                '"', '\\' => 2,
                '\n' => 2,
                '\r' => 2,
                '\t' => 2,
                else => if (ch < 0x20) 6 else 1,
            };
            if (pos + needed > buf.len) break;
            switch (ch) {
                '"' => {
                    buf[pos] = '\\';
                    buf[pos + 1] = '"';
                    pos += 2;
                },
                '\\' => {
                    buf[pos] = '\\';
                    buf[pos + 1] = '\\';
                    pos += 2;
                },
                '\n' => {
                    buf[pos] = '\\';
                    buf[pos + 1] = 'n';
                    pos += 2;
                },
                '\r' => {
                    buf[pos] = '\\';
                    buf[pos + 1] = 'r';
                    pos += 2;
                },
                '\t' => {
                    buf[pos] = '\\';
                    buf[pos + 1] = 't';
                    pos += 2;
                },
                else => {
                    if (ch < 0x20) {
                        const esc = std.fmt.bufPrint(buf[pos .. pos + 6], "\\u{X:0>4}", .{ch}) catch break;
                        pos += esc.len;
                    } else {
                        buf[pos] = ch;
                        pos += 1;
                    }
                },
            }
        }
        return buf[0..pos];
    }

    // ── System handlers ─────────────────────────────────────────────────

    fn handleSystemPing(id: []const u8, buf: []u8) []const u8 {
        return writeJsonOk(buf, id, "{\"pong\":true}");
    }

    fn handleSystemIdentify(id: []const u8, buf: []u8) []const u8 {
        const wm = getWindowManager() orelse return writeJsonError(buf, id, "not_ready", "Window manager not initialized");
        const state = wm.active_window orelse return writeJsonError(buf, id, "not_ready", "No active window");

        const ws = state.activeWorkspace() orelse return writeJsonError(buf, id, "not_ready", "No active workspace");
        const group = ws.focusedGroup() orelse return writeJsonError(buf, id, "not_ready", "No focused pane group");
        const pane = group.focusedTerminalPane();

        var result_buf: [512]u8 = undefined;

        // Find window index
        var win_idx: usize = 0;
        for (wm.windows.items, 0..) |w, i| {
            if (w == state) {
                win_idx = i;
                break;
            }
        }

        const result = if (pane) |p|
            std.fmt.bufPrint(&result_buf, "{{\"window_index\":{d},\"workspace_id\":{d},\"workspace_index\":{d},\"pane_group_id\":{d},\"surface_id\":{d}}}", .{
                win_idx,
                ws.id,
                state.active_workspace,
                group.id,
                p.id,
            }) catch return writeJsonError(buf, id, "internal", "Buffer overflow")
        else
            std.fmt.bufPrint(&result_buf, "{{\"window_index\":{d},\"workspace_id\":{d},\"workspace_index\":{d},\"pane_group_id\":{d},\"surface_id\":null}}", .{
                win_idx,
                ws.id,
                state.active_workspace,
                group.id,
            }) catch return writeJsonError(buf, id, "internal", "Buffer overflow");

        return writeJsonOk(buf, id, result);
    }

    fn handleSystemCapabilities(id: []const u8, buf: []u8) []const u8 {
        const methods =
            "[\"system.ping\",\"system.identify\",\"system.capabilities\",\"system.tree\"," ++
            "\"window.list\",\"window.current\",\"window.create\",\"window.close\"," ++
            "\"workspace.list\",\"workspace.current\",\"workspace.create\",\"workspace.select\"," ++
            "\"workspace.close\",\"workspace.rename\",\"workspace.next\",\"workspace.previous\"," ++
            "\"workspace.last\",\"workspace.move_to_window\",\"workspace.reorder\"," ++
            "\"workspace.set_status\",\"workspace.clear_status\"," ++
            "\"workspace.log\",\"workspace.clear_log\"," ++
            "\"workspace.set_progress\",\"workspace.clear_progress\"," ++
            "\"column.move\",\"column.resize\"," ++
            "\"surface.last\"," ++
            "\"surface.list\",\"surface.focus\",\"surface.split\",\"surface.close\"," ++
            "\"surface.send_text\",\"surface.send_key\",\"surface.trigger_flash\",\"surface.health\"," ++
            "\"surface.read_screen\",\"surface.expel\",\"surface.resize_row\",\"surface.reorder\"," ++
            "\"notification.create\",\"notification.list\",\"notification.clear\"," ++
            "\"surface.report_cwd\",\"surface.report_git\",\"surface.clear_git\",\"surface.report_state\"]";
        var result_buf: [1024]u8 = undefined;
        const result = std.fmt.bufPrint(&result_buf, "{{\"methods\":{s}}}", .{methods}) catch
            return writeJsonError(buf, id, "internal", "Buffer overflow");
        return writeJsonOk(buf, id, result);
    }

    fn handleSystemTree(id: []const u8, buf: []u8) []const u8 {
        const wm = getWindowManager() orelse return writeJsonError(buf, id, "not_ready", "Window manager not initialized");

        var result_buf: [65536]u8 = undefined;
        var pos: usize = 0;
        var overflow = false;

        const W = struct {
            /// Append a literal slice, setting overflow on truncation.
            fn slice(r: *[65536]u8, p: *usize, ov: *bool, s: []const u8) void {
                const n = copySlice(r.*[p.*..], s);
                p.* += n;
                if (n < s.len) ov.* = true;
            }
            /// Append via bufPrint, setting overflow on exhaustion.
            fn print(r: *[65536]u8, p: *usize, ov: *bool, comptime fmt: []const u8, args: anytype) void {
                const out = std.fmt.bufPrint(r.*[p.*..], fmt, args) catch {
                    ov.* = true;
                    return;
                };
                p.* += out.len;
            }
        };

        W.slice(&result_buf, &pos, &overflow, "{\"windows\":[");

        for (wm.windows.items, 0..) |state, win_idx| {
            if (overflow) break;
            if (win_idx > 0) W.slice(&result_buf, &pos, &overflow, ",");

            var win_title_esc: [256]u8 = undefined;
            const win_title = if (state.activeWorkspace()) |ws| ws.getTitle() else "seance";
            const escaped_win_title = jsonEscapeString(win_title, &win_title_esc);
            const is_active_win = (wm.active_window == state);

            W.print(&result_buf, &pos, &overflow, "{{\"index\":{d},\"title\":\"{s}\",\"active\":{s},\"workspaces\":[", .{
                win_idx,
                escaped_win_title,
                if (is_active_win) "true" else "false",
            });

            for (state.workspaces.items, 0..) |ws, ws_idx| {
                if (overflow) break;
                if (ws_idx > 0) W.slice(&result_buf, &pos, &overflow, ",");

                var ws_title_esc: [256]u8 = undefined;
                const escaped_ws_title = jsonEscapeString(ws.getTitle(), &ws_title_esc);
                const is_active_ws = (ws_idx == state.active_workspace);

                W.print(&result_buf, &pos, &overflow, "{{\"id\":{d},\"index\":{d},\"title\":\"{s}\",\"active\":{s},\"pinned\":{s},\"pane_groups\":[", .{
                    ws.id,
                    ws_idx,
                    escaped_ws_title,
                    if (is_active_ws) "true" else "false",
                    if (ws.is_pinned) "true" else "false",
                });

                const fg = ws.focusedGroup();
                var first_group = true;
                for (ws.columns.items) |col| {
                    if (overflow) break;
                    for (col.groups.items) |grp| {
                        if (overflow) break;
                        if (!first_group) W.slice(&result_buf, &pos, &overflow, ",");
                        first_group = false;

                        const is_focused_grp = if (fg) |f| f.id == grp.id else false;

                        W.print(&result_buf, &pos, &overflow, "{{\"id\":{d},\"focused\":{s},\"surfaces\":[", .{
                            grp.id,
                            if (is_focused_grp) "true" else "false",
                        });

                        var first_surf = true;
                        for (grp.panels.items, 0..) |panel, panel_idx| {
                            if (overflow) break;
                            const pane = panel.asTerminal() orelse continue;
                            if (!first_surf) W.slice(&result_buf, &pos, &overflow, ",");
                            first_surf = false;

                            var title_esc: [256]u8 = undefined;
                            const pane_title = pane.getDisplayTitle() orelse "";
                            const escaped_title = jsonEscapeString(pane_title, &title_esc);

                            var cwd_esc: [1024]u8 = undefined;
                            const cwd = pane.getCwd() orelse "";
                            const escaped_cwd = jsonEscapeString(cwd, &cwd_esc);

                            const is_selected = (grp.active_panel == panel_idx);

                            W.print(&result_buf, &pos, &overflow, "{{\"id\":{d},\"title\":\"{s}\",\"cwd\":\"{s}\",\"selected\":{s},\"focused\":{s}}}", .{
                                pane.id,
                                escaped_title,
                                escaped_cwd,
                                if (is_selected) "true" else "false",
                                if (is_focused_grp and is_selected) "true" else "false",
                            });
                        }

                        W.slice(&result_buf, &pos, &overflow, "]}");
                    }
                }

                W.slice(&result_buf, &pos, &overflow, "]}");
            }

            W.slice(&result_buf, &pos, &overflow, "]}");
        }

        if (overflow) return writeJsonError(buf, id, "overflow", "Tree response exceeded buffer size");

        W.slice(&result_buf, &pos, &overflow, "]}");
        return writeJsonOk(buf, id, result_buf[0..pos]);
    }

    // ── Window handlers ─────────────────────────────────────────────────

    fn handleWindowList(id: []const u8, buf: []u8) []const u8 {
        const wm = getWindowManager() orelse return writeJsonError(buf, id, "not_ready", "Window manager not initialized");

        var result_buf: [8192]u8 = undefined;
        var pos: usize = 0;

        pos += copySlice(result_buf[pos..], "{\"windows\":[");

        for (wm.windows.items, 0..) |state, i| {
            if (i > 0) pos += copySlice(result_buf[pos..], ",");

            var title_esc: [256]u8 = undefined;
            const title = if (state.activeWorkspace()) |ws| ws.getTitle() else "seance";
            const escaped_title = jsonEscapeString(title, &title_esc);

            const is_active = (wm.active_window == state);
            const entry = std.fmt.bufPrint(result_buf[pos..], "{{\"index\":{d},\"title\":\"{s}\",\"active\":{s},\"workspace_count\":{d}}}", .{
                i,
                escaped_title,
                if (is_active) "true" else "false",
                state.workspaces.items.len,
            }) catch break;
            pos += entry.len;
        }

        pos += copySlice(result_buf[pos..], "]}");
        return writeJsonOk(buf, id, result_buf[0..pos]);
    }

    fn handleWindowCurrent(id: []const u8, buf: []u8) []const u8 {
        const wm = getWindowManager() orelse return writeJsonError(buf, id, "not_ready", "Window manager not initialized");
        const state = wm.active_window orelse return writeJsonError(buf, id, "no_window", "No active window");

        var win_idx: usize = 0;
        for (wm.windows.items, 0..) |w, i| {
            if (w == state) {
                win_idx = i;
                break;
            }
        }

        var title_esc: [256]u8 = undefined;
        const title = if (state.activeWorkspace()) |ws| ws.getTitle() else "seance";
        const escaped_title = jsonEscapeString(title, &title_esc);

        var result_buf: [512]u8 = undefined;
        const result = std.fmt.bufPrint(&result_buf, "{{\"index\":{d},\"title\":\"{s}\",\"workspace_count\":{d}}}", .{
            win_idx,
            escaped_title,
            state.workspaces.items.len,
        }) catch return writeJsonError(buf, id, "internal", "Buffer overflow");
        return writeJsonOk(buf, id, result);
    }

    fn handleWindowCreate(id: []const u8, buf: []u8) []const u8 {
        const wm = getWindowManager() orelse return writeJsonError(buf, id, "not_ready", "Window manager not initialized");
        const state = wm.newWindow() orelse return writeJsonError(buf, id, "create_failed", "Failed to create window");

        var win_idx: usize = 0;
        for (wm.windows.items, 0..) |w, i| {
            if (w == state) {
                win_idx = i;
                break;
            }
        }

        var result_buf: [128]u8 = undefined;
        const result = std.fmt.bufPrint(&result_buf, "{{\"index\":{d}}}", .{win_idx}) catch
            return writeJsonError(buf, id, "internal", "Buffer overflow");
        return writeJsonOk(buf, id, result);
    }

    fn handleWindowClose(params: ?std.json.Value, id: []const u8, buf: []u8) []const u8 {
        const wm = getWindowManager() orelse return writeJsonError(buf, id, "not_ready", "Window manager not initialized");
        const win_idx = getParamInt(params, "window_id") orelse {
            // Close active window
            const state = wm.active_window orelse return writeJsonError(buf, id, "no_window", "No active window");
            c.gtk_window_close(@ptrCast(state.gtk_window));
            return writeJsonOk(buf, id, "{}");
        };
        if (win_idx >= wm.windows.items.len) return writeJsonError(buf, id, "not_found", "Window not found");
        const state = wm.windows.items[win_idx];
        c.gtk_window_close(@ptrCast(state.gtk_window));
        return writeJsonOk(buf, id, "{}");
    }

    // ── Workspace handlers ──────────────────────────────────────────────

    fn handleWorkspaceList(params: ?std.json.Value, id: []const u8, buf: []u8) []const u8 {
        const wm = getWindowManager() orelse return writeJsonError(buf, id, "not_ready", "Window manager not initialized");

        // Optionally scope to a specific window
        const state = if (getParamInt(params, "window_id")) |win_idx| blk: {
            if (win_idx >= wm.windows.items.len) return writeJsonError(buf, id, "not_found", "Window not found");
            break :blk wm.windows.items[win_idx];
        } else wm.active_window orelse return writeJsonError(buf, id, "no_window", "No active window");

        var result_buf: [8192]u8 = undefined;
        var pos: usize = 0;

        pos += copySlice(result_buf[pos..], "{\"workspaces\":[");

        for (state.workspaces.items, 0..) |ws, i| {
            if (i > 0) pos += copySlice(result_buf[pos..], ",");

            var title_esc: [256]u8 = undefined;
            const escaped_title = jsonEscapeString(ws.getTitle(), &title_esc);

            var cwd_esc: [1024]u8 = undefined;
            const cwd = ws.getActivePaneCwd() orelse "";
            const escaped_cwd = jsonEscapeString(cwd, &cwd_esc);

            var git_part: [192]u8 = undefined;
            const git_str = if (ws.getGitBranch()) |branch| blk: {
                var branch_esc: [128]u8 = undefined;
                const escaped_branch = jsonEscapeString(branch, &branch_esc);
                break :blk std.fmt.bufPrint(&git_part, ",\"git_branch\":\"{s}\"", .{escaped_branch}) catch "";
            } else "";

            const panel_count: usize = if (ws.focusedGroup()) |fg| fg.panels.items.len else 0;
            const entry = std.fmt.bufPrint(result_buf[pos..], "{{\"id\":{d},\"index\":{d},\"title\":\"{s}\",\"active\":{s},\"pinned\":{s},\"panel_count\":{d},\"cwd\":\"{s}\"{s}}}", .{
                ws.id,
                i,
                escaped_title,
                if (i == state.active_workspace) "true" else "false",
                if (ws.is_pinned) "true" else "false",
                panel_count,
                escaped_cwd,
                git_str,
            }) catch break;
            pos += entry.len;
        }

        pos += copySlice(result_buf[pos..], "]}");
        return writeJsonOk(buf, id, result_buf[0..pos]);
    }

    fn handleWorkspaceCurrent(id: []const u8, buf: []u8) []const u8 {
        const state = getActiveState() orelse return writeJsonError(buf, id, "not_ready", "No active window");
        const ws = state.activeWorkspace() orelse return writeJsonError(buf, id, "no_workspace", "No active workspace");

        var title_esc: [256]u8 = undefined;
        const escaped_title = jsonEscapeString(ws.getTitle(), &title_esc);

        var cwd_esc: [1024]u8 = undefined;
        const cwd = ws.getActivePaneCwd() orelse "";
        const escaped_cwd = jsonEscapeString(cwd, &cwd_esc);

        const panel_count: usize = if (ws.focusedGroup()) |fg| fg.panels.items.len else 0;
        var result_buf: [1024]u8 = undefined;
        const result = std.fmt.bufPrint(&result_buf, "{{\"id\":{d},\"index\":{d},\"title\":\"{s}\",\"panel_count\":{d},\"cwd\":\"{s}\",\"pinned\":{s}}}", .{
            ws.id,
            state.active_workspace,
            escaped_title,
            panel_count,
            escaped_cwd,
            if (ws.is_pinned) "true" else "false",
        }) catch return writeJsonError(buf, id, "internal", "Buffer overflow");
        return writeJsonOk(buf, id, result);
    }

    fn handleWorkspaceCreate(params: ?std.json.Value, id: []const u8, buf: []u8) []const u8 {
        const state = getActiveState() orelse return writeJsonError(buf, id, "not_ready", "No active window");

        // Optional title param
        const title = getParamString(params, "title");

        state.newWorkspace() catch return writeJsonError(buf, id, "create_failed", "Failed to create workspace");

        // The new workspace is now active
        const ws = state.activeWorkspace() orelse return writeJsonError(buf, id, "internal", "Workspace disappeared");

        // Apply custom title if provided
        if (title) |t| {
            ws.setCustomTitle(t);
            state.sidebar.refresh();
            state.sidebar.setActive(state.active_workspace);
        }

        var result_buf: [256]u8 = undefined;
        const result = std.fmt.bufPrint(&result_buf, "{{\"id\":{d},\"index\":{d}}}", .{
            ws.id,
            state.active_workspace,
        }) catch return writeJsonError(buf, id, "internal", "Buffer overflow");
        return writeJsonOk(buf, id, result);
    }

    fn handleWorkspaceSelect(params: ?std.json.Value, id: []const u8, buf: []u8) []const u8 {
        const state = getActiveState() orelse return writeJsonError(buf, id, "not_ready", "No active window");

        // Accept workspace_id (the u64 id) or index
        if (getParamInt(params, "workspace_id")) |ws_id| {
            for (state.workspaces.items, 0..) |ws, i| {
                if (ws.id == ws_id) {
                    state.selectWorkspace(i);
                    return writeJsonOk(buf, id, "{}");
                }
            }
            return writeJsonError(buf, id, "not_found", "Workspace not found");
        }

        if (getParamInt(params, "index")) |idx| {
            if (idx >= state.workspaces.items.len) return writeJsonError(buf, id, "not_found", "Workspace index out of range");
            state.selectWorkspace(idx);
            return writeJsonOk(buf, id, "{}");
        }

        return writeJsonError(buf, id, "invalid_params", "Missing workspace_id or index");
    }

    fn handleWorkspaceClose(params: ?std.json.Value, id: []const u8, buf: []u8) []const u8 {
        const state = getActiveState() orelse return writeJsonError(buf, id, "not_ready", "No active window");

        if (getParamInt(params, "workspace_id")) |ws_id| {
            for (state.workspaces.items, 0..) |ws, i| {
                if (ws.id == ws_id) {
                    state.closeWorkspace(i);
                    return writeJsonOk(buf, id, "{}");
                }
            }
            return writeJsonError(buf, id, "not_found", "Workspace not found");
        }

        if (getParamInt(params, "index")) |idx| {
            if (idx >= state.workspaces.items.len) return writeJsonError(buf, id, "not_found", "Workspace index out of range");
            state.closeWorkspace(idx);
            return writeJsonOk(buf, id, "{}");
        }

        // Default: close active workspace
        state.closeWorkspace(state.active_workspace);
        return writeJsonOk(buf, id, "{}");
    }

    fn handleWorkspaceRename(params: ?std.json.Value, id: []const u8, buf: []u8) []const u8 {
        const state = getActiveState() orelse return writeJsonError(buf, id, "not_ready", "No active window");
        const title = getParamString(params, "title") orelse return writeJsonError(buf, id, "invalid_params", "Missing 'title' parameter");

        // Find workspace by ID or use active
        const ws = if (getParamInt(params, "workspace_id")) |ws_id| blk: {
            for (state.workspaces.items) |w| {
                if (w.id == ws_id) break :blk w;
            }
            return writeJsonError(buf, id, "not_found", "Workspace not found");
        } else state.activeWorkspace() orelse return writeJsonError(buf, id, "no_workspace", "No active workspace");

        ws.setCustomTitle(title);
        state.sidebar.refresh();
        state.sidebar.setActive(state.active_workspace);

        return writeJsonOk(buf, id, "{}");
    }

    fn handleWorkspaceNext(id: []const u8, buf: []u8) []const u8 {
        const state = getActiveState() orelse return writeJsonError(buf, id, "not_ready", "No active window");
        state.nextWorkspace();
        return writeJsonOk(buf, id, "{}");
    }

    fn handleWorkspacePrevious(id: []const u8, buf: []u8) []const u8 {
        const state = getActiveState() orelse return writeJsonError(buf, id, "not_ready", "No active window");
        state.prevWorkspace();
        return writeJsonOk(buf, id, "{}");
    }

    fn handleWorkspaceLast(id: []const u8, buf: []u8) []const u8 {
        const state = getActiveState() orelse return writeJsonError(buf, id, "not_ready", "No active window");
        const ws = state.lastWorkspace() orelse return writeJsonError(buf, id, "no_history", "No previous workspace");
        var result_buf: [128]u8 = undefined;
        // Find the index of the workspace we switched to
        for (state.workspaces.items, 0..) |w, i| {
            if (w.id == ws.id) {
                const result = std.fmt.bufPrint(&result_buf, "{{\"workspace_id\":{d},\"index\":{d}}}", .{ ws.id, i }) catch
                    return writeJsonError(buf, id, "internal", "Buffer overflow");
                return writeJsonOk(buf, id, result);
            }
        }
        return writeJsonError(buf, id, "internal", "Workspace not found after switch");
    }

    fn handleWorkspaceMoveToWindow(params: ?std.json.Value, id: []const u8, buf: []u8) []const u8 {
        const wm = getWindowManager() orelse return writeJsonError(buf, id, "not_ready", "Window manager not initialized");
        const ws_id = getParamInt(params, "workspace_id") orelse return writeJsonError(buf, id, "invalid_params", "Missing 'workspace_id'");
        const target_win_idx = getParamInt(params, "target_window_id") orelse return writeJsonError(buf, id, "invalid_params", "Missing 'target_window_id'");

        if (target_win_idx >= wm.windows.items.len) return writeJsonError(buf, id, "not_found", "Target window not found");
        const target = wm.windows.items[target_win_idx];

        if (wm.moveWorkspaceToWindow(ws_id, target)) {
            return writeJsonOk(buf, id, "{}");
        } else {
            return writeJsonError(buf, id, "move_failed", "Failed to move workspace");
        }
    }

    // ── Surface handlers ────────────────────────────────────────────────

    fn handleSurfaceLast(params: ?std.json.Value, id: []const u8, buf: []u8) []const u8 {
        const state = getActiveState() orelse return writeJsonError(buf, id, "not_ready", "No active window");
        const ws = if (getParamInt(params, "workspace_id")) |ws_id| blk: {
            for (state.workspaces.items) |w| {
                if (w.id == ws_id) break :blk w;
            }
            return writeJsonError(buf, id, "not_found", "Workspace not found");
        } else state.activeWorkspace() orelse return writeJsonError(buf, id, "no_workspace", "No active workspace");

        if (!ws.lastPane()) return writeJsonError(buf, id, "no_history", "No previous pane");

        // Return the surface we switched to
        const grp = ws.focusedGroup() orelse return writeJsonOk(buf, id, "{}");
        const pane = grp.focusedTerminalPane() orelse return writeJsonOk(buf, id, "{}");
        var result_buf: [128]u8 = undefined;
        const result = std.fmt.bufPrint(&result_buf, "{{\"surface_id\":{d}}}", .{pane.id}) catch
            return writeJsonError(buf, id, "internal", "Buffer overflow");
        return writeJsonOk(buf, id, result);
    }

    fn handleSurfaceList(params: ?std.json.Value, id: []const u8, buf: []u8) []const u8 {
        const wm = getWindowManager() orelse return writeJsonError(buf, id, "not_ready", "Window manager not initialized");
        const state = wm.active_window orelse return writeJsonError(buf, id, "no_window", "No active window");
        var result_buf: [8192]u8 = undefined;
        var pos: usize = 0;

        pos += copySlice(result_buf[pos..], "{\"surfaces\":[");

        const ws_filter = getParamInt(params, "workspace_id");
        var first = true;

        for (state.workspaces.items) |ws| {
            if (ws_filter) |filt| {
                if (ws.id != filt) continue;
            }
            collectSurfaces(ws, &result_buf, &pos, &first);
        }

        pos += copySlice(result_buf[pos..], "]}");
        return writeJsonOk(buf, id, result_buf[0..pos]);
    }

    fn collectSurfaces(ws: *@import("workspace.zig").Workspace, result_buf: []u8, pos: *usize, first: *bool) void {
        const fg = ws.focusedGroup();
        for (ws.columns.items) |col| {
            if (col.closing) continue;
            for (col.groups.items) |grp| {
                for (grp.panels.items) |panel| {
                    const pane = panel.asTerminal() orelse continue;
                    if (!first.*) pos.* += copySlice(result_buf[pos.*..], ",");
                    first.* = false;

                    var cwd_esc: [1024]u8 = undefined;
                    const cwd = pane.getCwd() orelse "";
                    const escaped_cwd = jsonEscapeString(cwd, &cwd_esc);

                    const is_focused = if (fg) |f| blk: {
                        break :blk f.id == grp.id and (if (f.focusedTerminalPane()) |fp| fp.id == pane.id else false);
                    } else false;

                    const entry = std.fmt.bufPrint(result_buf[pos.*..], "{{\"id\":{d},\"workspace_id\":{d},\"pane_group_id\":{d},\"focused\":{s},\"has_unread\":{s},\"cwd\":\"{s}\"}}", .{
                        pane.id,
                        ws.id,
                        grp.id,
                        if (is_focused) "true" else "false",
                        if (pane.has_unread) "true" else "false",
                        escaped_cwd,
                    }) catch return;
                    pos.* += entry.len;
                }
            }
        }
    }

    fn handleSurfaceFocus(params: ?std.json.Value, id: []const u8, buf: []u8) []const u8 {
        const surface_id = getParamInt(params, "surface_id") orelse return writeJsonError(buf, id, "invalid_params", "Missing 'surface_id' parameter");
        const wm = getWindowManager() orelse return writeJsonError(buf, id, "not_ready", "Window manager not initialized");
        const state = wm.findByPaneId(surface_id) orelse return writeJsonError(buf, id, "not_found", "Surface not found");
        // Find workspace and pane group containing the surface
        for (state.workspaces.items, 0..) |ws, ws_idx| {
            const grp = ws.findGroupContainingPane(surface_id) orelse continue;
            state.selectWorkspace(ws_idx);
            // Guard against onFocusEnter re-entry: switchToPanel in
            // stacked mode calls gtk_widget_grab_focus which fires
            // onFocusEnter, interfering with focus history tracking.
            ws.restructuring = true;
            // Find the panel index within the group
            for (grp.panels.items, 0..) |panel, pi| {
                if (panel.getId() == surface_id) {
                    grp.switchToPanel(pi);
                    break;
                }
            }
            _ = ws.focusColumnContainingPane(surface_id);
            grp.focus();
            ws.restructuring = false;
            return writeJsonOk(buf, id, "{}");
        }

        return writeJsonError(buf, id, "not_found", "Surface not found");
    }

    fn handleSurfaceSplit(params: ?std.json.Value, id: []const u8, buf: []u8) []const u8 {
        const state = getActiveState() orelse return writeJsonError(buf, id, "not_ready", "No active window");
        _ = params;

        state.splitFocused();

        // Return the new pane's ID
        const ws = state.activeWorkspace() orelse return writeJsonOk(buf, id, "{}");
        const group = ws.focusedGroup() orelse return writeJsonOk(buf, id, "{}");
        if (group.focusedTerminalPane()) |pane| {
            var result_buf: [128]u8 = undefined;
            const result = std.fmt.bufPrint(&result_buf, "{{\"surface_id\":{d}}}", .{pane.id}) catch return writeJsonOk(buf, id, "{}");
            return writeJsonOk(buf, id, result);
        }
        return writeJsonOk(buf, id, "{}");
    }

    fn handleSurfaceClose(params: ?std.json.Value, id: []const u8, buf: []u8) []const u8 {
        const surface_id = getParamInt(params, "surface_id") orelse {
            // Close focused pane
            const state = getActiveState() orelse return writeJsonError(buf, id, "not_ready", "No active window");
            state.closeFocusedPane();
            return writeJsonOk(buf, id, "{}");
        };
        const wm = getWindowManager() orelse return writeJsonError(buf, id, "not_ready", "Window manager not initialized");
        const state = wm.findByPaneId(surface_id) orelse return writeJsonError(buf, id, "not_found", "Surface not found");
        state.closePaneById(surface_id);
        return writeJsonOk(buf, id, "{}");
    }

    fn handleSurfaceSendText(params: ?std.json.Value, id: []const u8, buf: []u8) []const u8 {
        const text = getParamString(params, "text") orelse return writeJsonError(buf, id, "invalid_params", "Missing 'text' parameter");

        // Find the target pane
        const pane = if (getParamInt(params, "surface_id")) |surface_id| blk: {
            const wm = getWindowManager() orelse return writeJsonError(buf, id, "not_ready", "Window manager not initialized");
            for (wm.windows.items) |state| {
                for (state.workspaces.items) |ws| {
                    if (ws.findPaneById(surface_id)) |p| break :blk p;
                }
            }
            return writeJsonError(buf, id, "not_found", "Surface not found");
        } else blk: {
            const state = getActiveState() orelse return writeJsonError(buf, id, "not_ready", "No active window");
            const ws = state.activeWorkspace() orelse return writeJsonError(buf, id, "no_workspace", "No active workspace");
            const group = ws.focusedGroup() orelse return writeJsonError(buf, id, "no_tab", "No focused pane group");
            break :blk group.focusedTerminalPane() orelse return writeJsonError(buf, id, "no_surface", "No focused terminal pane");
        };

        pane.writeInput(text);
        return writeJsonOk(buf, id, "{}");
    }

    fn handleSurfaceSendKey(params: ?std.json.Value, id: []const u8, buf: []u8) []const u8 {
        const key = getParamString(params, "key") orelse return writeJsonError(buf, id, "invalid_params", "Missing 'key' parameter");
        // Map common key names to escape sequences
        var seq_buf: [32]u8 = undefined;
        const sequence = mapKeyToSequence(key, &seq_buf) orelse return writeJsonError(buf, id, "invalid_key", "Unrecognized key name");

        // Find target pane (same logic as send_text)
        const pane = if (getParamInt(params, "surface_id")) |surface_id| blk: {
            const wm = getWindowManager() orelse return writeJsonError(buf, id, "not_ready", "Window manager not initialized");
            for (wm.windows.items) |state| {
                for (state.workspaces.items) |ws| {
                    if (ws.findPaneById(surface_id)) |p| break :blk p;
                }
            }
            return writeJsonError(buf, id, "not_found", "Surface not found");
        } else blk: {
            const state = getActiveState() orelse return writeJsonError(buf, id, "not_ready", "No active window");
            const ws = state.activeWorkspace() orelse return writeJsonError(buf, id, "no_workspace", "No active workspace");
            const group = ws.focusedGroup() orelse return writeJsonError(buf, id, "no_tab", "No focused pane group");
            break :blk group.focusedTerminalPane() orelse return writeJsonError(buf, id, "no_surface", "No focused terminal pane");
        };

        pane.writeInput(sequence);
        return writeJsonOk(buf, id, "{}");
    }

    fn mapKeyToSequence(key: []const u8, buf: []u8) ?[]const u8 {
        // Common key names to terminal escape sequences
        if (eql(key, "enter") or eql(key, "return")) return "\r";
        if (eql(key, "tab")) return "\t";
        if (eql(key, "escape") or eql(key, "esc")) return "\x1b";
        if (eql(key, "backspace")) return "\x7f";
        if (eql(key, "delete")) return "\x1b[3~";
        if (eql(key, "up")) return "\x1b[A";
        if (eql(key, "down")) return "\x1b[B";
        if (eql(key, "right")) return "\x1b[C";
        if (eql(key, "left")) return "\x1b[D";
        if (eql(key, "home")) return "\x1b[H";
        if (eql(key, "end")) return "\x1b[F";
        if (eql(key, "page_up")) return "\x1b[5~";
        if (eql(key, "page_down")) return "\x1b[6~";
        if (eql(key, "space")) return " ";

        // ctrl+letter (ctrl+c, ctrl+d, etc.)
        if (key.len == 6 and std.mem.startsWith(u8, key, "ctrl+")) {
            const ch = key[5];
            if (ch >= 'a' and ch <= 'z') {
                buf[0] = ch - 'a' + 1;
                return buf[0..1];
            }
        }

        // Single character: send as-is
        if (key.len == 1) {
            buf[0] = key[0];
            return buf[0..1];
        }

        return null;
    }

    fn handleSurfaceReadScreen(params: ?std.json.Value, id: []const u8, buf: []u8) []const u8 {
        const max_lines: u64 = 500;
        const default_lines: u64 = 50;

        // Parse optional lines parameter
        var lines = getParamInt(params, "lines") orelse default_lines;
        if (lines == 0) lines = default_lines;
        if (lines > max_lines) lines = max_lines;

        // Find the target pane (same pattern as send_text)
        const pane = if (getParamInt(params, "surface_id")) |surface_id| blk: {
            const wm = getWindowManager() orelse return writeJsonError(buf, id, "not_ready", "Window manager not initialized");
            for (wm.windows.items) |state| {
                for (state.workspaces.items) |ws| {
                    if (ws.findPaneById(surface_id)) |p| break :blk p;
                }
            }
            return writeJsonError(buf, id, "not_found", "Surface not found");
        } else blk: {
            const state = getActiveState() orelse return writeJsonError(buf, id, "not_ready", "No active window");
            const ws = state.activeWorkspace() orelse return writeJsonError(buf, id, "no_workspace", "No active workspace");
            const group = ws.focusedGroup() orelse return writeJsonError(buf, id, "no_tab", "No focused pane group");
            break :blk group.focusedTerminalPane() orelse return writeJsonError(buf, id, "no_surface", "No focused terminal pane");
        };

        const surface = pane.surface orelse return writeJsonError(buf, id, "terminal_destroyed", "Terminal has been destroyed");

        // Get terminal grid dimensions from ghostty
        const size = c.ghostty_surface_size(surface);
        const rows: i64 = @intCast(size.rows);
        const cols: i64 = @intCast(size.columns);

        // Read the last N lines of visible text via ghostty_surface_read_text.
        // We select a viewport region: the bottom `lines` rows of the viewport.
        const lines_u32: u32 = @intCast(lines);
        const top_y: u32 = if (size.rows > lines_u32) size.rows - lines_u32 else 0;

        const sel = c.ghostty_selection_s{
            .top_left = .{
                .tag = c.GHOSTTY_POINT_VIEWPORT,
                .coord = c.GHOSTTY_POINT_COORD_TOP_LEFT,
                .x = 0,
                .y = top_y,
            },
            .bottom_right = .{
                .tag = c.GHOSTTY_POINT_VIEWPORT,
                .coord = c.GHOSTTY_POINT_COORD_BOTTOM_RIGHT,
                .x = size.columns,
                .y = size.rows,
            },
            .rectangle = false,
        };

        var text_result: c.ghostty_text_s = std.mem.zeroes(c.ghostty_text_s);
        const got_text = c.ghostty_surface_read_text(surface, sel, &text_result);

        // JSON-escape the terminal text
        var text_esc_buf: [12000]u8 = undefined;
        var escaped: []const u8 = "";

        if (got_text and text_result.text != null and text_result.text_len > 0) {
            const text_slice = text_result.text[0..text_result.text_len];
            escaped = jsonEscapeString(text_slice, &text_esc_buf);
        }

        const shell_state_str = switch (pane.shell_state) {
            .unknown => "unknown",
            .prompt => "prompt",
            .running => "running",
        };

        const result = std.fmt.bufPrint(buf, "{{\"id\":{s},\"ok\":true,\"result\":{{\"text\":\"{s}\",\"cursor_row\":0,\"cursor_col\":0,\"rows\":{d},\"cols\":{d},\"shell_state\":\"{s}\"}}}}\n", .{
            id,
            escaped,
            rows,
            cols,
            shell_state_str,
        }) catch
            writeJsonError(buf, id, "internal", "Response too large");

        if (got_text) c.ghostty_surface_free_text(surface, &text_result);

        return result;
    }

    fn handleSurfaceTriggerFlash(params: ?std.json.Value, id: []const u8, buf: []u8) []const u8 {
        const surface_id = getParamInt(params, "surface_id") orelse {
            const state = getActiveState() orelse return writeJsonError(buf, id, "not_ready", "No active window");
            const ws = state.activeWorkspace() orelse return writeJsonError(buf, id, "no_workspace", "No workspace");
            const group = ws.focusedGroup() orelse return writeJsonError(buf, id, "no_tab", "No focused pane group");
            if (group.focusedTerminalPane()) |pane| pane.triggerFlash();
            return writeJsonOk(buf, id, "{}");
        };

        const wm = getWindowManager() orelse return writeJsonError(buf, id, "not_ready", "Window manager not initialized");
        for (wm.windows.items) |state| {
            for (state.workspaces.items) |ws| {
                if (ws.findPaneById(surface_id)) |pane| {
                    pane.triggerFlash();
                    return writeJsonOk(buf, id, "{}");
                }
            }
        }
        return writeJsonError(buf, id, "not_found", "Surface not found");
    }

    fn handleSurfaceHealth(params: ?std.json.Value, id: []const u8, buf: []u8) []const u8 {
        const surface_id = getParamInt(params, "surface_id") orelse return writeJsonError(buf, id, "invalid_params", "Missing 'surface_id' parameter");
        const wm = getWindowManager() orelse return writeJsonError(buf, id, "not_ready", "Window manager not initialized");

        for (wm.windows.items) |state| {
            for (state.workspaces.items) |ws| {
                if (ws.findPaneById(surface_id)) |pane| {
                    const alive = pane.surface != null;
                    var result_buf: [64]u8 = undefined;
                    const result = std.fmt.bufPrint(&result_buf, "{{\"alive\":{s}}}", .{
                        if (alive) "true" else "false",
                    }) catch return writeJsonError(buf, id, "internal", "Buffer overflow");
                    return writeJsonOk(buf, id, result);
                }
            }
        }
        return writeJsonError(buf, id, "not_found", "Surface not found");
    }

    // ── Notification handlers ───────────────────────────────────────────

    fn handleNotificationCreate(params: ?std.json.Value, id: []const u8, buf: []u8) []const u8 {
        const title = getParamString(params, "title") orelse "Notification";
        const subtitle = getParamString(params, "subtitle") orelse "";
        const body = getParamString(params, "body") orelse "";

        const Window = @import("window.zig");
        const wm = Window.window_manager orelse return writeJsonError(buf, id, "not_ready", "Window manager not initialized");

        const state = if (getParamInt(params, "surface_id")) |sid|
            wm.findByPaneId(sid)
        else if (getParamInt(params, "workspace_id")) |wid|
            wm.findByWorkspaceId(wid)
        else
            wm.active_window;

        const s = state orelse return writeJsonError(buf, id, "not_found", "Target not found");

        // Default to focused pane when surface_id/workspace_id are omitted
        const active_ws = s.activeWorkspace();
        const surface_id = getParamInt(params, "surface_id") orelse blk: {
            if (active_ws) |ws| {
                if (ws.focusedGroup()) |fg| {
                    if (fg.focusedTerminalPane()) |fp| break :blk fp.id;
                }
            }
            break :blk 0;
        };
        const workspace_id = getParamInt(params, "workspace_id") orelse
            if (active_ws) |ws| ws.id else 0;

        s.notif_center.emit(.{
            .title = title,
            .subtitle = subtitle,
            .body = body,
            .pane_id = surface_id,
            .workspace_id = workspace_id,
        });
        return writeJsonOk(buf, id, "{}");
    }

    fn handleNotificationList(id: []const u8, buf: []u8) []const u8 {
        const state = getActiveState() orelse return writeJsonError(buf, id, "not_ready", "No active window");

        var result_buf: [8192]u8 = undefined;
        var pos: usize = 0;

        pos += copySlice(result_buf[pos..], "{\"notifications\":[");

        var first = true;
        for (0..state.notif_center.store.count) |i| {
            const notif = state.notif_center.store.getByIndex(i) orelse continue;
            if (!first) pos += copySlice(result_buf[pos..], ",");
            first = false;

            var title_esc: [512]u8 = undefined;
            const escaped_title = jsonEscapeString(notif.getTitle(), &title_esc);
            var subtitle_esc: [512]u8 = undefined;
            const escaped_subtitle = jsonEscapeString(notif.getSubtitle(), &subtitle_esc);
            var body_esc: [1024]u8 = undefined;
            const escaped_body = jsonEscapeString(notif.getBody(), &body_esc);

            const entry = std.fmt.bufPrint(result_buf[pos..], "{{\"index\":{d},\"title\":\"{s}\",\"subtitle\":\"{s}\",\"body\":\"{s}\",\"workspace_id\":{d},\"surface_id\":{d},\"pane_group_id\":{d},\"read\":{s},\"timestamp\":{d}}}", .{
                i,
                escaped_title,
                escaped_subtitle,
                escaped_body,
                notif.workspace_id,
                notif.pane_id,
                notif.pane_group_id,
                if (notif.read) "true" else "false",
                notif.timestamp,
            }) catch break;
            pos += entry.len;
        }

        pos += copySlice(result_buf[pos..], "]}");
        return writeJsonOk(buf, id, result_buf[0..pos]);
    }

    fn handleNotificationClear(id: []const u8, buf: []u8) []const u8 {
        const state = getActiveState() orelse return writeJsonError(buf, id, "not_ready", "No active window");
        state.notif_center.clearAll();
        return writeJsonOk(buf, id, "{}");
    }

    // ── Column & surface operation handlers ──────────────────────────────

    fn handleColumnMove(params: ?std.json.Value, id: []const u8, buf: []u8) []const u8 {
        const state = getActiveState() orelse return writeJsonError(buf, id, "not_ready", "No active window");
        const dir_str = getParamString(params, "direction") orelse return writeJsonError(buf, id, "invalid_params", "Missing 'direction' parameter");

        const workspace_mod = @import("workspace.zig");
        const direction: workspace_mod.Workspace.ExpelDirection = if (eql(dir_str, "left"))
            .left
        else if (eql(dir_str, "right"))
            .right
        else
            return writeJsonError(buf, id, "invalid_params", "direction must be 'left' or 'right'");

        const ws = if (getParamInt(params, "workspace_id")) |ws_id| blk: {
            for (state.workspaces.items) |w| {
                if (w.id == ws_id) break :blk w;
            }
            return writeJsonError(buf, id, "not_found", "Workspace not found");
        } else state.activeWorkspace() orelse return writeJsonError(buf, id, "no_workspace", "No active workspace");

        ws.moveColumn(direction);

        var result_buf: [64]u8 = undefined;
        const result = std.fmt.bufPrint(&result_buf, "{{\"column_index\":{d}}}", .{ws.focused_column}) catch
            return writeJsonError(buf, id, "internal", "Buffer overflow");
        return writeJsonOk(buf, id, result);
    }

    fn handleColumnResize(params: ?std.json.Value, id: []const u8, buf: []u8) []const u8 {
        const state = getActiveState() orelse return writeJsonError(buf, id, "not_ready", "No active window");
        const Column = @import("column.zig").Column;

        const ws = if (getParamInt(params, "workspace_id")) |ws_id| blk: {
            for (state.workspaces.items) |w| {
                if (w.id == ws_id) break :blk w;
            }
            return writeJsonError(buf, id, "not_found", "Workspace not found");
        } else state.activeWorkspace() orelse return writeJsonError(buf, id, "no_workspace", "No active workspace");

        if (getParamBool(params, "maximize") orelse false) {
            ws.maximizeColumn();
        } else if (getParamBool(params, "wider") orelse false) {
            ws.resizeColumnWidth(Column.resize_step);
        } else if (getParamBool(params, "narrower") orelse false) {
            ws.resizeColumnWidth(-Column.resize_step);
        } else {
            return writeJsonError(buf, id, "invalid_params", "One of 'wider', 'narrower', or 'maximize' required");
        }

        // Return the current target width of the focused column
        if (ws.focused_column < ws.columns.items.len) {
            const col = &ws.columns.items[ws.focused_column];
            var result_buf: [64]u8 = undefined;
            const result = std.fmt.bufPrint(&result_buf, "{{\"width\":{d:.4}}}", .{col.target_width}) catch
                return writeJsonError(buf, id, "internal", "Buffer overflow");
            return writeJsonOk(buf, id, result);
        }
        return writeJsonOk(buf, id, "{}");
    }

    fn handleSurfaceExpel(params: ?std.json.Value, id: []const u8, buf: []u8) []const u8 {
        const state = getActiveState() orelse return writeJsonError(buf, id, "not_ready", "No active window");
        const dir_str = getParamString(params, "direction") orelse return writeJsonError(buf, id, "invalid_params", "Missing 'direction' parameter");

        const workspace_mod = @import("workspace.zig");
        const direction: workspace_mod.Workspace.ExpelDirection = if (eql(dir_str, "left"))
            .left
        else if (eql(dir_str, "right"))
            .right
        else
            return writeJsonError(buf, id, "invalid_params", "direction must be 'left' or 'right'");

        const ws = if (getParamInt(params, "workspace_id")) |ws_id| blk: {
            for (state.workspaces.items) |w| {
                if (w.id == ws_id) break :blk w;
            }
            return writeJsonError(buf, id, "not_found", "Workspace not found");
        } else state.activeWorkspace() orelse return writeJsonError(buf, id, "no_workspace", "No active workspace");

        // If surface_id given, focus it first
        if (getParamInt(params, "surface_id")) |surface_id| {
            _ = ws.focusColumnContainingPane(surface_id);
        }

        ws.expelPane(direction);

        // Return the surface id and new column index
        var surface_id: u64 = 0;
        if (ws.focusedGroup()) |grp| {
            if (grp.focusedTerminalPane()) |pane| surface_id = pane.id;
        }
        var result_buf: [128]u8 = undefined;
        const result = std.fmt.bufPrint(&result_buf, "{{\"surface_id\":{d},\"column_index\":{d}}}", .{
            surface_id,
            ws.focused_column,
        }) catch return writeJsonError(buf, id, "internal", "Buffer overflow");
        return writeJsonOk(buf, id, result);
    }

    fn handleSurfaceResizeRow(params: ?std.json.Value, id: []const u8, buf: []u8) []const u8 {
        const state = getActiveState() orelse return writeJsonError(buf, id, "not_ready", "No active window");

        const ws = if (getParamInt(params, "workspace_id")) |ws_id| blk: {
            for (state.workspaces.items) |w| {
                if (w.id == ws_id) break :blk w;
            }
            return writeJsonError(buf, id, "not_found", "Workspace not found");
        } else state.activeWorkspace() orelse return writeJsonError(buf, id, "no_workspace", "No active workspace");

        // If surface_id given, focus it first
        if (getParamInt(params, "surface_id")) |surface_id| {
            _ = ws.focusColumnContainingPane(surface_id);
        }

        if (getParamBool(params, "taller") orelse false) {
            ws.resizeRowHeight(0.2);
        } else if (getParamBool(params, "shorter") orelse false) {
            ws.resizeRowHeight(-0.2);
        } else {
            return writeJsonError(buf, id, "invalid_params", "One of 'taller' or 'shorter' required");
        }

        return writeJsonOk(buf, id, "{}");
    }

    fn handleSurfaceReorder(params: ?std.json.Value, id: []const u8, buf: []u8) []const u8 {
        const state = getActiveState() orelse return writeJsonError(buf, id, "not_ready", "No active window");
        const surface_id = getParamInt(params, "surface_id") orelse return writeJsonError(buf, id, "invalid_params", "Missing 'surface_id' parameter");

        // Find the pane group containing this surface
        for (state.workspaces.items) |ws| {
            const grp = ws.findGroupContainingPane(surface_id) orelse continue;

            // Find current panel index
            var from: ?usize = null;
            for (grp.panels.items, 0..) |panel, i| {
                if (panel.getId() == surface_id) {
                    from = i;
                    break;
                }
            }
            const from_idx = from orelse return writeJsonError(buf, id, "internal", "Panel index not found");

            // Determine target index
            const to_idx: usize = if (getParamInt(params, "index")) |idx| blk: {
                break :blk @min(@as(usize, @intCast(idx)), grp.panels.items.len - 1);
            } else if (getParamInt(params, "before")) |before_id| blk: {
                for (grp.panels.items, 0..) |panel, i| {
                    if (panel.getId() == before_id) break :blk i;
                }
                return writeJsonError(buf, id, "not_found", "Target surface not found");
            } else if (getParamInt(params, "after")) |after_id| blk: {
                for (grp.panels.items, 0..) |panel, i| {
                    if (panel.getId() == after_id) break :blk @min(i + 1, grp.panels.items.len - 1);
                }
                return writeJsonError(buf, id, "not_found", "Target surface not found");
            } else {
                return writeJsonError(buf, id, "invalid_params", "One of 'index', 'before', or 'after' required");
            };

            grp.reorderPanel(from_idx, to_idx);

            // Find final index after reorder
            var final_idx: usize = 0;
            for (grp.panels.items, 0..) |panel, i| {
                if (panel.getId() == surface_id) {
                    final_idx = i;
                    break;
                }
            }

            var result_buf: [128]u8 = undefined;
            const result = std.fmt.bufPrint(&result_buf, "{{\"surface_id\":{d},\"index\":{d}}}", .{
                surface_id,
                final_idx,
            }) catch return writeJsonError(buf, id, "internal", "Buffer overflow");
            return writeJsonOk(buf, id, result);
        }

        return writeJsonError(buf, id, "not_found", "Surface not found");
    }

    fn handleWorkspaceReorder(params: ?std.json.Value, id: []const u8, buf: []u8) []const u8 {
        const state = getActiveState() orelse return writeJsonError(buf, id, "not_ready", "No active window");
        const workspace_id = getParamInt(params, "workspace_id") orelse return writeJsonError(buf, id, "invalid_params", "Missing 'workspace_id' parameter");

        // Find workspace index
        var from: ?usize = null;
        for (state.workspaces.items, 0..) |ws, i| {
            if (ws.id == workspace_id) {
                from = i;
                break;
            }
        }
        const from_idx = from orelse return writeJsonError(buf, id, "not_found", "Workspace not found");

        // Determine target index
        const to_idx: usize = if (getParamInt(params, "index")) |idx| blk: {
            break :blk @min(@as(usize, @intCast(idx)), state.workspaces.items.len - 1);
        } else if (getParamInt(params, "before")) |before_id| blk: {
            for (state.workspaces.items, 0..) |ws, i| {
                if (ws.id == before_id) break :blk i;
            }
            return writeJsonError(buf, id, "not_found", "Target workspace not found");
        } else if (getParamInt(params, "after")) |after_id| blk: {
            for (state.workspaces.items, 0..) |ws, i| {
                if (ws.id == after_id) break :blk @min(i + 1, state.workspaces.items.len - 1);
            }
            return writeJsonError(buf, id, "not_found", "Target workspace not found");
        } else {
            return writeJsonError(buf, id, "invalid_params", "One of 'index', 'before', or 'after' required");
        };

        state.reorderWorkspace(from_idx, to_idx);

        // Find final index after reorder
        var final_idx: usize = 0;
        for (state.workspaces.items, 0..) |ws, i| {
            if (ws.id == workspace_id) {
                final_idx = i;
                break;
            }
        }

        // Detect silently rejected reorder (e.g. pinned/unpinned boundary)
        if (final_idx == from_idx and to_idx != from_idx) {
            return writeJsonError(buf, id, "invalid_params", "Cannot reorder across pinned/unpinned boundary");
        }

        var result_buf: [128]u8 = undefined;
        const result = std.fmt.bufPrint(&result_buf, "{{\"workspace_id\":{d},\"index\":{d}}}", .{
            workspace_id,
            final_idx,
        }) catch return writeJsonError(buf, id, "internal", "Buffer overflow");
        return writeJsonOk(buf, id, result);
    }

    // ── Workspace metadata handlers ────────────────────────────────────

    fn findWorkspaceById(ws_id: u64) ?struct { ws: *@import("workspace.zig").Workspace, state: *@import("window.zig").WindowState } {
        const Window = @import("window.zig");
        const wm = Window.window_manager orelse return null;
        for (wm.windows.items) |state| {
            for (state.workspaces.items) |ws| {
                if (ws.id == ws_id) return .{ .ws = ws, .state = state };
            }
        }
        return null;
    }

    fn getParamFloat(params: ?std.json.Value, key: []const u8) ?f64 {
        const p = params orelse return null;
        if (p != .object) return null;
        const val = p.object.get(key) orelse return null;
        return switch (val) {
            .float => |f| f,
            .integer => |n| @floatFromInt(n),
            else => null,
        };
    }

    fn getParamI32(params: ?std.json.Value, key: []const u8) i32 {
        const p = params orelse return 0;
        if (p != .object) return 0;
        const val = p.object.get(key) orelse return 0;
        return switch (val) {
            .integer => |n| if (n >= std.math.minInt(i32) and n <= std.math.maxInt(i32)) @intCast(n) else 0,
            .float => |f| @intFromFloat(std.math.clamp(f, @as(f64, std.math.minInt(i32)), @as(f64, std.math.maxInt(i32)))),
            else => 0,
        };
    }

    fn handleWorkspaceSetStatus(params: ?std.json.Value, id: []const u8, buf: []u8) []const u8 {
        const ws_id = getParamInt(params, "workspace_id") orelse return writeJsonError(buf, id, "invalid_params", "Missing 'workspace_id'");
        const key = getParamString(params, "key") orelse return writeJsonError(buf, id, "invalid_params", "Missing 'key'");
        const value = getParamString(params, "value") orelse return writeJsonError(buf, id, "invalid_params", "Missing 'value'");
        const priority = getParamI32(params, "priority");

        const is_agent = getParamBool(params, "is_agent") orelse false;
        const display_name = getParamString(params, "display_name");

        const result = findWorkspaceById(ws_id) orelse return writeJsonError(buf, id, "not_found", "Workspace not found");
        result.ws.setStatus(key, value, priority, is_agent, display_name);
        result.state.sidebar.refresh();
        result.state.sidebar.setActive(result.state.active_workspace);
        return writeJsonOk(buf, id, "{}");
    }

    fn handleWorkspaceClearStatus(params: ?std.json.Value, id: []const u8, buf: []u8) []const u8 {
        const ws_id = getParamInt(params, "workspace_id") orelse return writeJsonError(buf, id, "invalid_params", "Missing 'workspace_id'");
        const key = getParamString(params, "key") orelse return writeJsonError(buf, id, "invalid_params", "Missing 'key'");

        const result = findWorkspaceById(ws_id) orelse return writeJsonError(buf, id, "not_found", "Workspace not found");
        _ = result.ws.clearStatus(key);
        result.state.sidebar.refresh();
        result.state.sidebar.setActive(result.state.active_workspace);
        return writeJsonOk(buf, id, "{}");
    }

    fn handleWorkspaceLog(params: ?std.json.Value, id: []const u8, buf: []u8) []const u8 {
        const ws_id = getParamInt(params, "workspace_id") orelse return writeJsonError(buf, id, "invalid_params", "Missing 'workspace_id'");
        const message = getParamString(params, "message") orelse return writeJsonError(buf, id, "invalid_params", "Missing 'message'");
        const level_str = getParamString(params, "level") orelse "info";

        const Workspace = @import("workspace.zig");
        const level: Workspace.LogLevel = if (eql(level_str, "info"))
            .info
        else if (eql(level_str, "progress"))
            .progress
        else if (eql(level_str, "success"))
            .success
        else if (eql(level_str, "warning"))
            .warning
        else if (eql(level_str, "error"))
            .@"error"
        else
            .info;

        const result = findWorkspaceById(ws_id) orelse return writeJsonError(buf, id, "not_found", "Workspace not found");
        result.ws.appendLog(message, level, std.time.timestamp());
        result.state.sidebar.refresh();
        result.state.sidebar.setActive(result.state.active_workspace);
        return writeJsonOk(buf, id, "{}");
    }

    fn handleWorkspaceClearLog(params: ?std.json.Value, id: []const u8, buf: []u8) []const u8 {
        const ws_id = getParamInt(params, "workspace_id") orelse return writeJsonError(buf, id, "invalid_params", "Missing 'workspace_id'");

        const result = findWorkspaceById(ws_id) orelse return writeJsonError(buf, id, "not_found", "Workspace not found");
        result.ws.clearLog();
        result.state.sidebar.refresh();
        result.state.sidebar.setActive(result.state.active_workspace);
        return writeJsonOk(buf, id, "{}");
    }

    fn handleWorkspaceSetProgress(params: ?std.json.Value, id: []const u8, buf: []u8) []const u8 {
        const ws_id = getParamInt(params, "workspace_id") orelse return writeJsonError(buf, id, "invalid_params", "Missing 'workspace_id'");
        const value = getParamFloat(params, "value") orelse return writeJsonError(buf, id, "invalid_params", "Missing 'value'");
        const label = getParamString(params, "label");

        const result = findWorkspaceById(ws_id) orelse return writeJsonError(buf, id, "not_found", "Workspace not found");
        result.ws.setProgress(value, label);
        result.state.sidebar.refresh();
        result.state.sidebar.setActive(result.state.active_workspace);
        return writeJsonOk(buf, id, "{}");
    }

    fn handleWorkspaceClearProgress(params: ?std.json.Value, id: []const u8, buf: []u8) []const u8 {
        const ws_id = getParamInt(params, "workspace_id") orelse return writeJsonError(buf, id, "invalid_params", "Missing 'workspace_id'");

        const result = findWorkspaceById(ws_id) orelse return writeJsonError(buf, id, "not_found", "Workspace not found");
        result.ws.clearProgress();
        result.state.sidebar.refresh();
        result.state.sidebar.setActive(result.state.active_workspace);
        return writeJsonOk(buf, id, "{}");
    }

    // ── Shell integration JSON v2 handlers ─────────────────────────────

    fn handleSurfaceReportCwd(params: ?std.json.Value, id: []const u8, buf: []u8) []const u8 {
        const surface_id = getParamInt(params, "surface_id") orelse return writeJsonError(buf, id, "invalid_params", "Missing 'surface_id'");
        const cwd = getParamString(params, "cwd") orelse return writeJsonError(buf, id, "invalid_params", "Missing 'cwd'");

        const result = findPaneAndWorkspace(surface_id) orelse return writeJsonError(buf, id, "not_found", "Surface not found");
        const pane = result.pane;
        const len = @min(cwd.len, pane.cwd.len);
        @memcpy(pane.cwd[0..len], cwd[0..len]);
        pane.cwd_len = len;

        if (isFocusedPane(result.ws, surface_id)) {
            result.state.sidebar.refresh();
            result.state.sidebar.setActive(result.state.active_workspace);
        }
        return writeJsonOk(buf, id, "{}");
    }

    fn handleSurfaceReportGit(params: ?std.json.Value, id: []const u8, buf: []u8) []const u8 {
        const surface_id = getParamInt(params, "surface_id") orelse return writeJsonError(buf, id, "invalid_params", "Missing 'surface_id'");
        const branch = getParamString(params, "branch") orelse return writeJsonError(buf, id, "invalid_params", "Missing 'branch'");

        const dirty_val = if (params) |p| blk: {
            if (p != .object) break :blk false;
            const val = p.object.get("dirty") orelse break :blk false;
            break :blk switch (val) {
                .bool => |b| b,
                else => false,
            };
        } else false;

        const result = findPaneAndWorkspace(surface_id) orelse return writeJsonError(buf, id, "not_found", "Surface not found");
        const pane = result.pane;
        const blen = @min(branch.len, pane.shell_git_branch.len);

        const pane_changed = blen != pane.shell_git_branch_len or
            dirty_val != pane.shell_git_dirty or
            !std.mem.eql(u8, pane.shell_git_branch[0..blen], branch[0..blen]);

        if (pane_changed) {
            @memcpy(pane.shell_git_branch[0..blen], branch[0..blen]);
            pane.shell_git_branch_len = blen;
            pane.shell_git_dirty = dirty_val;
        }

        // Always sync workspace when the pane is focused — the pane may have
        // received its data while it wasn't focused (e.g. during startup),
        // leaving the workspace out of sync.
        if (isFocusedPane(result.ws, surface_id)) {
            const ws = result.ws;
            const ws_changed = blen != ws.git_branch_len or
                dirty_val != ws.git_dirty or
                !std.mem.eql(u8, ws.git_branch[0..blen], branch[0..blen]);

            if (ws_changed) {
                ws.git_branch_len = blen;
                @memcpy(ws.git_branch[0..blen], branch[0..blen]);
                ws.git_dirty = dirty_val;
            }

            if (pane_changed or ws_changed) {
                result.state.sidebar.refresh();
                result.state.sidebar.setActive(result.state.active_workspace);
            }
        }
        return writeJsonOk(buf, id, "{}");
    }

    fn handleSurfaceClearGit(params: ?std.json.Value, id: []const u8, buf: []u8) []const u8 {
        const surface_id = getParamInt(params, "surface_id") orelse return writeJsonError(buf, id, "invalid_params", "Missing 'surface_id'");

        const result = findPaneAndWorkspace(surface_id) orelse return writeJsonError(buf, id, "not_found", "Surface not found");

        // Already cleared — skip
        if (result.pane.shell_git_branch_len == 0 and !result.pane.shell_git_dirty)
            return writeJsonOk(buf, id, "{}");

        result.pane.shell_git_branch_len = 0;
        result.pane.shell_git_dirty = false;

        if (isFocusedPane(result.ws, surface_id)) {
            result.ws.git_branch_len = 0;
            result.ws.git_dirty = false;
            result.state.sidebar.refresh();
            result.state.sidebar.setActive(result.state.active_workspace);
        }
        return writeJsonOk(buf, id, "{}");
    }

    fn handleSurfaceReportState(params: ?std.json.Value, id: []const u8, buf: []u8) []const u8 {
        const surface_id = getParamInt(params, "surface_id") orelse return writeJsonError(buf, id, "invalid_params", "Missing 'surface_id'");
        const state_str = getParamString(params, "state") orelse return writeJsonError(buf, id, "invalid_params", "Missing 'state'");

        const Pane = @import("pane.zig").Pane;
        const shell_state: Pane.ShellState = if (eql(state_str, "prompt"))
            .prompt
        else if (eql(state_str, "running"))
            .running
        else
            return writeJsonError(buf, id, "invalid_params", "state must be 'prompt' or 'running'");

        const result = findPaneAndWorkspace(surface_id) orelse return writeJsonError(buf, id, "not_found", "Surface not found");
        result.pane.shell_state = shell_state;
        return writeJsonOk(buf, id, "{}");
    }

    /// Find a pane by panel_id across all windows/workspaces.
    /// Returns the pane and its containing workspace if found.
    fn findPaneAndWorkspace(panel_id: u64) ?struct { pane: *@import("pane.zig").Pane, ws: *@import("workspace.zig").Workspace, state: *@import("window.zig").WindowState } {
        const Window = @import("window.zig");
        const wm = Window.window_manager orelse return null;
        for (wm.windows.items) |state| {
            for (state.workspaces.items) |ws| {
                if (ws.findPaneById(panel_id)) |pane| {
                    return .{ .pane = pane, .ws = ws, .state = state };
                }
            }
        }
        return null;
    }

    /// Check if a pane is the focused pane of its workspace's focused group.
    fn isFocusedPane(ws: *@import("workspace.zig").Workspace, pane_id: u64) bool {
        const fg = ws.focusedGroup() orelse return false;
        const fp = fg.focusedTerminalPane() orelse return false;
        return fp.id == pane_id;
    }

};

fn copySlice(dest: []u8, src: []const u8) usize {
    const len = @min(src.len, dest.len);
    @memcpy(dest[0..len], src[0..len]);
    return len;
}
