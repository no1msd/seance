// src/ctl.zig — CLI client for controlling a running seance instance via socket API
//
// Usage: seance ctl <command> [args...]
//    or: seance <command> [args...]  (when symlinked)

const std = @import("std");
const posix = std.posix;
const Allocator = std.mem.Allocator;
const JsonValue = std.json.Value;
const Stringify = std.json.Stringify;

// ── Entry point ─────────────────────────────────────────────────────────

/// Run the CLI. `skip` is how many argv entries to skip (1 for "seance", 2 for "seance ctl").
pub fn run(skip: usize) u8 {
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    const alloc = arena.allocator();

    const all_args = std.process.argsAlloc(alloc) catch {
        werr("seance: failed to read arguments\n");
        return 1;
    };

    if (all_args.len <= skip) {
        printUsage();
        return 1;
    }

    const args = all_args[skip..];

    // Parse global flags
    var socket_override: ?[]const u8 = null;
    var json_mode = false;
    var g_workspace: ?u64 = null;
    var g_surface: ?u64 = null;
    var i: usize = 0;

    while (i < args.len) : (i += 1) {
        const a = args[i];
        if (eql(a, "--socket")) {
            i += 1;
            if (i >= args.len) {
                werr("seance: --socket requires a value\n");
                return 1;
            }
            socket_override = args[i];
        } else if (eql(a, "--json")) {
            json_mode = true;
        } else if (eql(a, "--workspace")) {
            i += 1;
            if (i >= args.len) {
                werr("seance: --workspace requires a value\n");
                return 1;
            }
            g_workspace = parseU64(args[i]) orelse {
                werr("seance: invalid workspace id\n");
                return 1;
            };
        } else if (eql(a, "--surface")) {
            i += 1;
            if (i >= args.len) {
                werr("seance: --surface requires a value\n");
                return 1;
            }
            g_surface = parseU64(args[i]) orelse {
                werr("seance: invalid surface id\n");
                return 1;
            };
        } else break; // command name
    }

    if (i >= args.len) {
        printUsage();
        return 1;
    }

    const command = args[i];
    const rest = args[i + 1 ..];

    // Resolve socket path
    var path_buf: [std.fs.max_path_bytes]u8 = undefined;
    const socket_path = getSocketPath(socket_override, &path_buf) orelse {
        werr("seance: cannot determine socket path (HOME not set?)\n");
        return 1;
    };

    const ctx = Ctx{
        .alloc = alloc,
        .socket_path = socket_path,
        .json = json_mode,
        .workspace = g_workspace,
        .surface = g_surface,
        .rest = rest,
    };

    return dispatch(ctx, command);
}

// ── Context / options ───────────────────────────────────────────────────

const Ctx = struct {
    alloc: Allocator,
    socket_path: []const u8,
    json: bool,
    workspace: ?u64,
    surface: ?u64,
    rest: []const []const u8,
};

// ── Command dispatch ────────────────────────────────────────────────────

fn dispatch(ctx: Ctx, command: []const u8) u8 {
    if (eql(command, "ping")) return cmdPing(ctx);
    if (eql(command, "identify")) return cmdIdentify(ctx);
    if (eql(command, "capabilities")) return cmdCapabilities(ctx);
    if (eql(command, "tree")) return cmdTree(ctx);
    if (eql(command, "list-windows")) return cmdListWindows(ctx);
    if (eql(command, "new-window")) return cmdNewWindow(ctx);
    if (eql(command, "close-window")) return cmdCloseWindow(ctx);
    if (eql(command, "list-workspaces")) return cmdListWorkspaces(ctx);
    if (eql(command, "new-workspace")) return cmdNewWorkspace(ctx);
    if (eql(command, "select-workspace")) return cmdSelectWorkspace(ctx);
    if (eql(command, "close-workspace")) return cmdCloseWorkspace(ctx);
    if (eql(command, "rename-workspace")) return cmdRenameWorkspace(ctx);
    if (eql(command, "list-surfaces")) return cmdListSurfaces(ctx);
    if (eql(command, "split")) return cmdSplit(ctx);
    if (eql(command, "close-surface")) return cmdCloseSurface(ctx);
    if (eql(command, "send")) return cmdSend(ctx);
    if (eql(command, "send-key")) return cmdSendKey(ctx);
    if (eql(command, "read-screen")) return cmdReadScreen(ctx);
    if (eql(command, "notify")) return cmdNotify(ctx);
    if (eql(command, "list-notifications")) return cmdListNotifications(ctx);
    if (eql(command, "clear-notifications")) return cmdClearNotifications(ctx);
    if (eql(command, "move-column")) return cmdMoveColumn(ctx);
    if (eql(command, "expel-pane")) return cmdExpelPane(ctx);
    if (eql(command, "resize-column")) return cmdResizeColumn(ctx);
    if (eql(command, "resize-row")) return cmdResizeRow(ctx);
    if (eql(command, "reorder-surface")) return cmdReorderSurface(ctx);
    if (eql(command, "reorder-workspace")) return cmdReorderWorkspace(ctx);
    if (eql(command, "move-workspace")) return cmdMoveWorkspace(ctx);
    if (eql(command, "last-workspace")) return cmdLastWorkspace(ctx);
    if (eql(command, "last-pane")) return cmdLastPane(ctx);
    if (eql(command, "claude-hook")) return cmdClaudeHook(ctx);
    if (eql(command, "codex-hook")) return cmdCodexHook(ctx);
    if (eql(command, "help") or eql(command, "--help") or eql(command, "-h")) {
        printUsage();
        return 0;
    }
    wfmt("seance: unknown command '{s}'\n", .{command});
    return 1;
}

// ── Socket I/O ──────────────────────────────────────────────────────────

const SocketErr = error{
    NotRunning,
    ConnectFailed,
    Timeout,
    ReadFailed,
    WriteFailed,
    EmptyResponse,
};

const ApiResponse = struct {
    ok: bool,
    raw: []const u8,
    result: JsonValue,
};

fn apiCall(alloc: Allocator, socket_path: []const u8, method: []const u8, params_json: ?[]const u8) !ApiResponse {
    const request = if (params_json) |p|
        std.fmt.allocPrint(alloc, "{{\"id\":\"1\",\"method\":\"{s}\",\"params\":{s}}}\n", .{ method, p }) catch return SocketErr.WriteFailed
    else
        std.fmt.allocPrint(alloc, "{{\"id\":\"1\",\"method\":\"{s}\"}}\n", .{method}) catch return SocketErr.WriteFailed;

    std.fs.accessAbsolute(socket_path, .{}) catch return SocketErr.NotRunning;

    const sock = posix.socket(posix.AF.UNIX, posix.SOCK.STREAM, 0) catch return SocketErr.ConnectFailed;
    defer posix.close(sock);

    var addr: posix.sockaddr.un = .{ .family = posix.AF.UNIX, .path = undefined };
    @memset(&addr.path, 0);
    const copy_len = @min(socket_path.len, addr.path.len - 1);
    for (0..copy_len) |idx| {
        addr.path[idx] = @intCast(socket_path[idx]);
    }

    posix.connect(sock, @ptrCast(&addr), @sizeOf(posix.sockaddr.un)) catch return SocketErr.ConnectFailed;

    const tv: posix.timeval = .{ .sec = 5, .usec = 0 };
    posix.setsockopt(sock, posix.SOL.SOCKET, posix.SO.RCVTIMEO, std.mem.asBytes(&tv)) catch {};

    _ = posix.write(sock, request) catch return SocketErr.WriteFailed;

    // Read response
    var response: std.ArrayList(u8) = .empty;
    var buf: [16384]u8 = undefined;
    while (true) {
        const n = posix.read(sock, &buf) catch return SocketErr.ReadFailed;
        if (n == 0) break;
        response.appendSlice(alloc, buf[0..n]) catch return SocketErr.ReadFailed;
        if (std.mem.indexOfScalar(u8, buf[0..n], '\n') != null) break;
    }

    if (response.items.len == 0) return SocketErr.EmptyResponse;

    const trimmed = std.mem.trim(u8, response.items, &[_]u8{ '\r', '\n', ' ' });

    const parsed = std.json.parseFromSlice(JsonValue, alloc, trimmed, .{}) catch return SocketErr.ReadFailed;

    if (parsed.value != .object) return SocketErr.ReadFailed;

    const ok_val = parsed.value.object.get("ok");
    const ok = if (ok_val) |v| (v == .bool and v.bool) else false;

    if (!ok) {
        if (parsed.value.object.get("error")) |err_val| {
            if (err_val == .object) {
                if (err_val.object.get("message")) |msg| {
                    if (msg == .string) {
                        wfmt("seance: {s}\n", .{msg.string});
                        return SocketErr.ReadFailed;
                    }
                }
            }
        }
        werr("seance: request failed\n");
        return SocketErr.ReadFailed;
    }

    const result = parsed.value.object.get("result") orelse JsonValue{ .object = std.json.ObjectMap.init(alloc) };

    return ApiResponse{
        .ok = true,
        .raw = trimmed,
        .result = result,
    };
}

fn printSocketError(err: anyerror) void {
    if (err == SocketErr.NotRunning) {
        werr("seance: seance is not running (socket not found)\n");
    } else if (err == SocketErr.ConnectFailed) {
        werr("seance: could not connect to seance\n");
    } else if (err == SocketErr.Timeout) {
        werr("seance: request timed out\n");
    } else if (err == SocketErr.EmptyResponse) {
        werr("seance: empty response from seance\n");
    } else {
        // ReadFailed, WriteFailed — error message already printed by apiCall
    }
}

// ── Command handlers ────────────────────────────────────────────────────

fn cmdPing(ctx: Ctx) u8 {
    _ = apiCall(ctx.alloc, ctx.socket_path, "system.ping", null) catch |e| {
        printSocketError(e);
        return 1;
    };
    if (ctx.json) {
        wout("{\"pong\":true}\n");
    } else {
        wout("pong\n");
    }
    return 0;
}

fn cmdIdentify(ctx: Ctx) u8 {
    const resp = apiCall(ctx.alloc, ctx.socket_path, "system.identify", null) catch |e| {
        printSocketError(e);
        return 1;
    };
    if (ctx.json) {
        printJson(ctx.alloc, resp.result);
    } else if (resp.result == .object) {
        const fields = [_][]const u8{ "window_index", "workspace_id", "workspace_index", "pane_group_id", "surface_id" };
        for (fields) |key| {
            wfmt("{s}: {s}\n", .{ prettyLabel(key), jsonValStr(ctx.alloc, resp.result.object.get(key) orelse .null) });
        }
    }
    return 0;
}

fn cmdCapabilities(ctx: Ctx) u8 {
    const resp = apiCall(ctx.alloc, ctx.socket_path, "system.capabilities", null) catch |e| {
        printSocketError(e);
        return 1;
    };
    if (ctx.json) {
        printJson(ctx.alloc, resp.result);
    } else if (resp.result == .object) {
        if (resp.result.object.get("methods")) |methods| {
            if (methods == .array) {
                for (methods.array.items) |m| {
                    if (m == .string) wfmt("  {s}\n", .{m.string});
                }
            }
        }
    }
    return 0;
}

fn cmdTree(ctx: Ctx) u8 {
    const resp = apiCall(ctx.alloc, ctx.socket_path, "system.tree", null) catch |e| {
        printSocketError(e);
        return 1;
    };
    if (ctx.json) {
        printJson(ctx.alloc, resp.result);
        return 0;
    }

    const windows = getArray(resp.result, "windows") orelse {
        wout("(empty)\n");
        return 0;
    };

    for (windows, 0..) |window, win_i| {
        if (window != .object) continue;
        const win_active = getBool(window, "active");
        const win_title = getStr(window, "title");
        const win_idx = jsonValStr(ctx.alloc, window.object.get("index") orelse .null);
        if (win_i > 0) wout("\n");
        wfmt("{s}Window {s}: \"{s}\"\n", .{ if (win_active) "* " else "  ", win_idx, win_title });

        const workspaces = getArray(window, "workspaces") orelse continue;
        for (workspaces, 0..) |ws, ws_i| {
            if (ws != .object) continue;
            const ws_last = (ws_i == workspaces.len - 1);
            const ws_branch: []const u8 = if (ws_last) "└── " else "├── ";
            const ws_cont: []const u8 = if (ws_last) "    " else "│   ";

            const ws_active = getBool(ws, "active");
            const ws_title = getStr(ws, "title");
            const ws_id = jsonValStr(ctx.alloc, ws.object.get("id") orelse .null);
            const pinned: []const u8 = if (getBool(ws, "pinned")) " [pinned]" else "";
            const ws_marker: []const u8 = if (ws_active) " ◀" else "";

            wfmt("  {s}[{s}] \"{s}\"{s}{s}\n", .{ ws_branch, ws_id, ws_title, pinned, ws_marker });

            const groups = getArray(ws, "pane_groups") orelse continue;
            for (groups, 0..) |grp, grp_i| {
                if (grp != .object) continue;
                const grp_last = (grp_i == groups.len - 1);
                const grp_branch: []const u8 = if (grp_last) "└── " else "├── ";
                const grp_cont: []const u8 = if (grp_last) "    " else "│   ";

                const grp_id = jsonValStr(ctx.alloc, grp.object.get("id") orelse .null);
                const grp_focused = getBool(grp, "focused");

                wfmt("  {s}{s}Group {s}{s}\n", .{
                    ws_cont,
                    grp_branch,
                    grp_id,
                    if (grp_focused) " [focused]" else "",
                });

                const surfaces = getArray(grp, "surfaces") orelse continue;
                for (surfaces, 0..) |surf, surf_i| {
                    if (surf != .object) continue;
                    const surf_last = (surf_i == surfaces.len - 1);
                    const surf_branch: []const u8 = if (surf_last) "└── " else "├── ";

                    const surf_id = jsonValStr(ctx.alloc, surf.object.get("id") orelse .null);
                    const surf_title = getStr(surf, "title");
                    const surf_cwd = getStr(surf, "cwd");
                    const surf_focused = getBool(surf, "focused");
                    const surf_selected = getBool(surf, "selected");

                    const label = if (surf_title.len > 0) surf_title else surf_cwd;

                    var markers_buf: [64]u8 = undefined;
                    var markers_pos: usize = 0;
                    if (surf_selected and !surf_focused) {
                        const m = " [selected]";
                        @memcpy(markers_buf[markers_pos .. markers_pos + m.len], m);
                        markers_pos += m.len;
                    }
                    if (surf_focused) {
                        const m = " ◀";
                        @memcpy(markers_buf[markers_pos .. markers_pos + m.len], m);
                        markers_pos += m.len;
                    }

                    wfmt("  {s}{s}{s}{s}: \"{s}\"{s}\n", .{
                        ws_cont,
                        grp_cont,
                        surf_branch,
                        surf_id,
                        label,
                        markers_buf[0..markers_pos],
                    });
                }
            }
        }
    }
    return 0;
}

fn cmdListWindows(ctx: Ctx) u8 {
    const resp = apiCall(ctx.alloc, ctx.socket_path, "window.list", null) catch |e| {
        printSocketError(e);
        return 1;
    };
    if (ctx.json) {
        printJson(ctx.alloc, resp.result);
        return 0;
    }
    const windows = getArray(resp.result, "windows") orelse {
        wout("No windows\n");
        return 0;
    };
    if (windows.len == 0) {
        wout("No windows\n");
        return 0;
    }
    wout("     INDEX  TITLE           WORKSPACES\n");
    wout("     -----  -----           ----------\n");
    for (windows) |w| {
        if (w != .object) continue;
        const active: []const u8 = if (getBool(w, "active")) "*" else " ";
        wfmt("{s}    {s}  {s}  {s}\n", .{
            active,
            jsonValStr(ctx.alloc, w.object.get("index") orelse .null),
            padRight(ctx.alloc, getStr(w, "title"), 16),
            jsonValStr(ctx.alloc, w.object.get("workspace_count") orelse .null),
        });
    }
    return 0;
}

fn cmdNewWindow(ctx: Ctx) u8 {
    const resp = apiCall(ctx.alloc, ctx.socket_path, "window.create", null) catch |e| {
        printSocketError(e);
        return 1;
    };
    if (ctx.json) {
        printJson(ctx.alloc, resp.result);
    } else {
        wfmt("Created window {s}\n", .{jsonValStr(ctx.alloc, resp.result.object.get("index") orelse .null)});
    }
    return 0;
}

fn cmdCloseWindow(ctx: Ctx) u8 {
    const params = if (ctx.rest.len > 0)
        std.fmt.allocPrint(ctx.alloc, "{{\"window_id\":{s}}}", .{ctx.rest[0]}) catch return 1
    else
        null;
    _ = apiCall(ctx.alloc, ctx.socket_path, "window.close", params) catch |e| {
        printSocketError(e);
        return 1;
    };
    if (ctx.json) {
        wout("{}\n");
    } else {
        if (ctx.rest.len > 0) {
            wfmt("Closed window {s}\n", .{ctx.rest[0]});
        } else {
            wout("Closed active window\n");
        }
    }
    return 0;
}

fn cmdMoveWorkspace(ctx: Ctx) u8 {
    var workspace_id: ?[]const u8 = null;
    var target_window: ?[]const u8 = null;
    var ri: usize = 0;
    while (ri < ctx.rest.len) : (ri += 1) {
        if (eql(ctx.rest[ri], "--window") and ri + 1 < ctx.rest.len) {
            ri += 1;
            target_window = ctx.rest[ri];
        } else {
            workspace_id = ctx.rest[ri];
        }
    }
    const ws_id = workspace_id orelse {
        werr("usage: move-workspace WORKSPACE_ID --window WINDOW_INDEX\n");
        return 1;
    };
    const win_id = target_window orelse {
        werr("usage: move-workspace WORKSPACE_ID --window WINDOW_INDEX\n");
        return 1;
    };
    const params = std.fmt.allocPrint(ctx.alloc, "{{\"workspace_id\":{s},\"target_window_id\":{s}}}", .{ ws_id, win_id }) catch return 1;
    _ = apiCall(ctx.alloc, ctx.socket_path, "workspace.move_to_window", params) catch |e| {
        printSocketError(e);
        return 1;
    };
    if (ctx.json) {
        wout("{}\n");
    } else {
        wfmt("Moved workspace {s} to window {s}\n", .{ ws_id, win_id });
    }
    return 0;
}

fn cmdListWorkspaces(ctx: Ctx) u8 {
    var window_id: ?u64 = null;
    var ri: usize = 0;
    while (ri < ctx.rest.len) : (ri += 1) {
        if (eql(ctx.rest[ri], "--window") and ri + 1 < ctx.rest.len) {
            ri += 1;
            window_id = parseU64(ctx.rest[ri]);
        }
    }
    const params = if (window_id) |wid|
        std.fmt.allocPrint(ctx.alloc, "{{\"window_id\":{d}}}", .{wid}) catch null
    else
        null;
    const resp = apiCall(ctx.alloc, ctx.socket_path, "workspace.list", params) catch |e| {
        printSocketError(e);
        return 1;
    };
    if (ctx.json) {
        printJson(ctx.alloc, resp.result);
        return 0;
    }
    const workspaces = getArray(resp.result, "workspaces") orelse {
        wout("No workspaces\n");
        return 0;
    };
    if (workspaces.len == 0) {
        wout("No workspaces\n");
        return 0;
    }
    wout("     ID   INDEX  TITLE           TABS  CWD                            BRANCH\n");
    wout("     --   -----  -----           ----  ---                            ------\n");
    for (workspaces) |ws| {
        if (ws != .object) continue;
        const active: []const u8 = if (getBool(ws, "active")) "*" else " ";
        const pinned: []const u8 = if (getBool(ws, "pinned")) " [pinned]" else "";
        wfmt("{s}    {s}  {s}  {s}  {s}  {s}  {s}{s}\n", .{
            active,
            padRight(ctx.alloc, jsonValStr(ctx.alloc, ws.object.get("id") orelse .null), 4),
            padRight(ctx.alloc, jsonValStr(ctx.alloc, ws.object.get("index") orelse .null), 5),
            padRight(ctx.alloc, getStr(ws, "title"), 16),
            padRight(ctx.alloc, jsonValStr(ctx.alloc, ws.object.get("panel_count") orelse .null), 4),
            padRight(ctx.alloc, getStr(ws, "cwd"), 30),
            getStr(ws, "git_branch"),
            pinned,
        });
    }
    return 0;
}

fn cmdNewWorkspace(ctx: Ctx) u8 {
    const title = findNamedArg(ctx.rest, "--title");
    const params = if (title) |t|
        std.fmt.allocPrint(ctx.alloc, "{{\"title\":\"{s}\"}}", .{t}) catch null
    else
        null;
    const resp = apiCall(ctx.alloc, ctx.socket_path, "workspace.create", params) catch |e| {
        printSocketError(e);
        return 1;
    };
    if (ctx.json) {
        printJson(ctx.alloc, resp.result);
    } else {
        wfmt("Created workspace {s} (index {s})\n", .{
            jsonValStr(ctx.alloc, resp.result.object.get("id") orelse .null),
            jsonValStr(ctx.alloc, resp.result.object.get("index") orelse .null),
        });
    }
    return 0;
}

fn cmdSelectWorkspace(ctx: Ctx) u8 {
    if (ctx.rest.len < 1) {
        werr("usage: select-workspace ID\n");
        return 1;
    }
    const params = std.fmt.allocPrint(ctx.alloc, "{{\"workspace_id\":{s}}}", .{ctx.rest[0]}) catch return 1;
    _ = apiCall(ctx.alloc, ctx.socket_path, "workspace.select", params) catch |e| {
        printSocketError(e);
        return 1;
    };
    if (ctx.json) {
        wout("{}\n");
    } else {
        wfmt("Selected workspace {s}\n", .{ctx.rest[0]});
    }
    return 0;
}

fn cmdCloseWorkspace(ctx: Ctx) u8 {
    if (ctx.rest.len < 1) {
        werr("usage: close-workspace ID\n");
        return 1;
    }
    const params = std.fmt.allocPrint(ctx.alloc, "{{\"workspace_id\":{s}}}", .{ctx.rest[0]}) catch return 1;
    _ = apiCall(ctx.alloc, ctx.socket_path, "workspace.close", params) catch |e| {
        printSocketError(e);
        return 1;
    };
    if (ctx.json) {
        wout("{}\n");
    } else {
        wfmt("Closed workspace {s}\n", .{ctx.rest[0]});
    }
    return 0;
}

fn cmdRenameWorkspace(ctx: Ctx) u8 {
    if (ctx.rest.len < 2) {
        werr("usage: rename-workspace ID TITLE\n");
        return 1;
    }
    const params = std.fmt.allocPrint(ctx.alloc, "{{\"workspace_id\":{s},\"title\":\"{s}\"}}", .{ ctx.rest[0], ctx.rest[1] }) catch return 1;
    _ = apiCall(ctx.alloc, ctx.socket_path, "workspace.rename", params) catch |e| {
        printSocketError(e);
        return 1;
    };
    if (ctx.json) {
        wout("{}\n");
    } else {
        wfmt("Renamed workspace {s} to '{s}'\n", .{ ctx.rest[0], ctx.rest[1] });
    }
    return 0;
}

fn cmdListSurfaces(ctx: Ctx) u8 {
    var ws_filter: ?u64 = ctx.workspace;
    var ri: usize = 0;
    while (ri < ctx.rest.len) : (ri += 1) {
        if (eql(ctx.rest[ri], "--workspace") and ri + 1 < ctx.rest.len) {
            ri += 1;
            ws_filter = parseU64(ctx.rest[ri]);
        }
    }
    const params = if (ws_filter) |wid|
        std.fmt.allocPrint(ctx.alloc, "{{\"workspace_id\":{d}}}", .{wid}) catch null
    else
        null;
    const resp = apiCall(ctx.alloc, ctx.socket_path, "surface.list", params) catch |e| {
        printSocketError(e);
        return 1;
    };
    if (ctx.json) {
        printJson(ctx.alloc, resp.result);
        return 0;
    }
    const surfaces = getArray(resp.result, "surfaces") orelse {
        wout("No surfaces\n");
        return 0;
    };
    if (surfaces.len == 0) {
        wout("No surfaces\n");
        return 0;
    }
    wout("     ID   WORKSPACE  GROUP  CWD\n");
    wout("     --   ---------  -----  ---\n");
    for (surfaces) |s| {
        if (s != .object) continue;
        const focused: []const u8 = if (getBool(s, "focused")) "*" else " ";
        const unread: []const u8 = if (getBool(s, "has_unread")) " [unread]" else "";
        wfmt("{s}    {s}  {s}  {s}  {s}{s}\n", .{
            focused,
            padRight(ctx.alloc, jsonValStr(ctx.alloc, s.object.get("id") orelse .null), 4),
            padRight(ctx.alloc, jsonValStr(ctx.alloc, s.object.get("workspace_id") orelse .null), 9),
            padRight(ctx.alloc, jsonValStr(ctx.alloc, s.object.get("pane_group_id") orelse .null), 5),
            padRight(ctx.alloc, getStr(s, "cwd"), 30),
            unread,
        });
    }
    return 0;
}

fn cmdSplit(ctx: Ctx) u8 {
    const dir = findNamedArg(ctx.rest, "--direction");
    const params = if (dir) |d|
        std.fmt.allocPrint(ctx.alloc, "{{\"direction\":\"{s}\"}}", .{d}) catch null
    else
        null;
    const resp = apiCall(ctx.alloc, ctx.socket_path, "surface.split", params) catch |e| {
        printSocketError(e);
        return 1;
    };
    if (ctx.json) {
        printJson(ctx.alloc, resp.result);
    } else {
        wfmt("Created surface {s}\n", .{jsonValStr(ctx.alloc, resp.result.object.get("surface_id") orelse .null)});
    }
    return 0;
}

fn cmdCloseSurface(ctx: Ctx) u8 {
    if (ctx.rest.len < 1) {
        werr("usage: close-surface ID\n");
        return 1;
    }
    const params = std.fmt.allocPrint(ctx.alloc, "{{\"surface_id\":{s}}}", .{ctx.rest[0]}) catch return 1;
    _ = apiCall(ctx.alloc, ctx.socket_path, "surface.close", params) catch |e| {
        printSocketError(e);
        return 1;
    };
    if (ctx.json) {
        wout("{}\n");
    } else {
        wfmt("Closed surface {s}\n", .{ctx.rest[0]});
    }
    return 0;
}

fn cmdSend(ctx: Ctx) u8 {
    var text: ?[]const u8 = null;
    var surface_id: ?u64 = ctx.surface;
    var ri: usize = 0;
    while (ri < ctx.rest.len) : (ri += 1) {
        if (eql(ctx.rest[ri], "--surface") and ri + 1 < ctx.rest.len) {
            ri += 1;
            surface_id = parseU64(ctx.rest[ri]);
        } else if (text == null) {
            text = ctx.rest[ri];
        }
    }
    const t = text orelse {
        werr("usage: send TEXT [--surface N]\n");
        return 1;
    };
    const escaped = jsonEscapeAlloc(ctx.alloc, t);
    const params = if (surface_id) |sid|
        std.fmt.allocPrint(ctx.alloc, "{{\"text\":\"{s}\",\"surface_id\":{d}}}", .{ escaped, sid }) catch return 1
    else
        std.fmt.allocPrint(ctx.alloc, "{{\"text\":\"{s}\"}}", .{escaped}) catch return 1;
    _ = apiCall(ctx.alloc, ctx.socket_path, "surface.send_text", params) catch |e| {
        printSocketError(e);
        return 1;
    };
    return 0;
}

fn cmdSendKey(ctx: Ctx) u8 {
    var key: ?[]const u8 = null;
    var surface_id: ?u64 = ctx.surface;
    var ri: usize = 0;
    while (ri < ctx.rest.len) : (ri += 1) {
        if (eql(ctx.rest[ri], "--surface") and ri + 1 < ctx.rest.len) {
            ri += 1;
            surface_id = parseU64(ctx.rest[ri]);
        } else if (key == null) {
            key = ctx.rest[ri];
        }
    }
    const k = key orelse {
        werr("usage: send-key KEY [--surface N]\n");
        return 1;
    };
    const params = if (surface_id) |sid|
        std.fmt.allocPrint(ctx.alloc, "{{\"key\":\"{s}\",\"surface_id\":{d}}}", .{ k, sid }) catch return 1
    else
        std.fmt.allocPrint(ctx.alloc, "{{\"key\":\"{s}\"}}", .{k}) catch return 1;
    _ = apiCall(ctx.alloc, ctx.socket_path, "surface.send_key", params) catch |e| {
        printSocketError(e);
        return 1;
    };
    return 0;
}

fn cmdReadScreen(ctx: Ctx) u8 {
    var lines: ?u64 = null;
    var surface_id: ?u64 = ctx.surface;
    var ri: usize = 0;
    while (ri < ctx.rest.len) : (ri += 1) {
        if (eql(ctx.rest[ri], "--lines") and ri + 1 < ctx.rest.len) {
            ri += 1;
            lines = parseU64(ctx.rest[ri]);
        } else if (eql(ctx.rest[ri], "--surface") and ri + 1 < ctx.rest.len) {
            ri += 1;
            surface_id = parseU64(ctx.rest[ri]);
        }
    }
    // Build params
    var pbuf: [128]u8 = undefined;
    var plen: usize = 0;
    plen += bufCopy(pbuf[plen..], "{");
    var have_field = false;
    if (lines) |l| {
        const s = std.fmt.bufPrint(pbuf[plen..], "\"lines\":{d}", .{l}) catch return 1;
        plen += s.len;
        have_field = true;
    }
    if (surface_id) |sid| {
        if (have_field) {
            plen += bufCopy(pbuf[plen..], ",");
        }
        const s = std.fmt.bufPrint(pbuf[plen..], "\"surface_id\":{d}", .{sid}) catch return 1;
        plen += s.len;
    }
    plen += bufCopy(pbuf[plen..], "}");
    const params = if (plen > 2) pbuf[0..plen] else null;

    const resp = apiCall(ctx.alloc, ctx.socket_path, "surface.read_screen", params) catch |e| {
        printSocketError(e);
        return 1;
    };
    if (ctx.json) {
        printJson(ctx.alloc, resp.result);
    } else if (resp.result == .object) {
        wout(getStr(resp.result, "text"));
        wout("\n");
    }
    return 0;
}

fn cmdNotify(ctx: Ctx) u8 {
    var title: []const u8 = "Notification";
    var body: []const u8 = "";
    var subtitle: []const u8 = "";
    var ws_id: ?u64 = ctx.workspace;
    var sf_id: ?u64 = ctx.surface;

    var ri: usize = 0;
    while (ri < ctx.rest.len) : (ri += 1) {
        if (eql(ctx.rest[ri], "--title") and ri + 1 < ctx.rest.len) {
            ri += 1;
            title = ctx.rest[ri];
        } else if (eql(ctx.rest[ri], "--body") and ri + 1 < ctx.rest.len) {
            ri += 1;
            body = ctx.rest[ri];
        } else if (eql(ctx.rest[ri], "--subtitle") and ri + 1 < ctx.rest.len) {
            ri += 1;
            subtitle = ctx.rest[ri];
        } else if (eql(ctx.rest[ri], "--workspace") and ri + 1 < ctx.rest.len) {
            ri += 1;
            ws_id = parseU64(ctx.rest[ri]);
        } else if (eql(ctx.rest[ri], "--surface") and ri + 1 < ctx.rest.len) {
            ri += 1;
            sf_id = parseU64(ctx.rest[ri]);
        }
    }

    var pbuf: [2048]u8 = undefined;
    var plen: usize = 0;
    const hdr = std.fmt.bufPrint(pbuf[plen..], "{{\"title\":\"{s}\",\"body\":\"{s}\"", .{
        jsonEscapeAlloc(ctx.alloc, title),
        jsonEscapeAlloc(ctx.alloc, body),
    }) catch return 1;
    plen += hdr.len;
    if (subtitle.len > 0) {
        const sub = std.fmt.bufPrint(pbuf[plen..], ",\"subtitle\":\"{s}\"", .{
            jsonEscapeAlloc(ctx.alloc, subtitle),
        }) catch return 1;
        plen += sub.len;
    }
    if (ws_id) |w| {
        const s = std.fmt.bufPrint(pbuf[plen..], ",\"workspace_id\":{d}", .{w}) catch return 1;
        plen += s.len;
    }
    if (sf_id) |s| {
        const sfmt = std.fmt.bufPrint(pbuf[plen..], ",\"surface_id\":{d}", .{s}) catch return 1;
        plen += sfmt.len;
    }
    plen += bufCopy(pbuf[plen..], "}");

    _ = apiCall(ctx.alloc, ctx.socket_path, "notification.create", pbuf[0..plen]) catch |e| {
        printSocketError(e);
        return 1;
    };
    if (ctx.json) wout("{}\n");
    return 0;
}

fn cmdListNotifications(ctx: Ctx) u8 {
    const resp = apiCall(ctx.alloc, ctx.socket_path, "notification.list", null) catch |e| {
        printSocketError(e);
        return 1;
    };
    if (ctx.json) {
        printJson(ctx.alloc, resp.result);
        return 0;
    }
    const notifs = getArray(resp.result, "notifications") orelse {
        wout("No notifications\n");
        return 0;
    };
    if (notifs.len == 0) {
        wout("No notifications\n");
        return 0;
    }
    wout("     INDEX  TITLE                BODY                             WORKSPACE  SURFACE\n");
    wout("     -----  -----                ----                             ---------  -------\n");
    for (notifs) |n| {
        if (n != .object) continue;
        const read_mark: []const u8 = if (getBool(n, "read")) " " else "*";
        wfmt("{s}    {s}  {s}  {s}  {s}  {s}\n", .{
            read_mark,
            padRight(ctx.alloc, jsonValStr(ctx.alloc, n.object.get("index") orelse .null), 5),
            padRight(ctx.alloc, getStr(n, "title"), 20),
            padRight(ctx.alloc, getStr(n, "body"), 33),
            padRight(ctx.alloc, jsonValStr(ctx.alloc, n.object.get("workspace_id") orelse .null), 9),
            jsonValStr(ctx.alloc, n.object.get("surface_id") orelse .null),
        });
    }
    return 0;
}

fn cmdClearNotifications(ctx: Ctx) u8 {
    _ = apiCall(ctx.alloc, ctx.socket_path, "notification.clear", null) catch |e| {
        printSocketError(e);
        return 1;
    };
    if (ctx.json) {
        wout("{}\n");
    } else {
        wout("Notifications cleared\n");
    }
    return 0;
}

// ── Column & surface operations ────────────────────────────────────────

fn cmdMoveColumn(ctx: Ctx) u8 {
    const dir = findNamedArg(ctx.rest, "--direction") orelse {
        werr("usage: move-column --direction left|right [--workspace N]\n");
        return 1;
    };
    if (!eql(dir, "left") and !eql(dir, "right")) {
        werr("direction must be 'left' or 'right'\n");
        return 1;
    }
    const ws_arg = findNamedArg(ctx.rest, "--workspace") orelse if (ctx.workspace) |w| std.fmt.allocPrint(ctx.alloc, "{d}", .{w}) catch null else null;
    const params = if (ws_arg) |ws|
        std.fmt.allocPrint(ctx.alloc, "{{\"direction\":\"{s}\",\"workspace_id\":{s}}}", .{ dir, ws }) catch return 1
    else
        std.fmt.allocPrint(ctx.alloc, "{{\"direction\":\"{s}\"}}", .{dir}) catch return 1;

    const resp = apiCall(ctx.alloc, ctx.socket_path, "column.move", params) catch |e| {
        printSocketError(e);
        return 1;
    };
    if (ctx.json) {
        printJson(ctx.alloc, resp.result);
    } else {
        wfmt("Moved column {s} (index {s})\n", .{
            dir,
            jsonValStr(ctx.alloc, resp.result.object.get("column_index") orelse .null),
        });
    }
    return 0;
}

fn cmdExpelPane(ctx: Ctx) u8 {
    const dir = findNamedArg(ctx.rest, "--direction") orelse {
        werr("usage: expel-pane --direction left|right [--surface N] [--workspace N]\n");
        return 1;
    };
    if (!eql(dir, "left") and !eql(dir, "right")) {
        werr("direction must be 'left' or 'right'\n");
        return 1;
    }

    const surface = findNamedArg(ctx.rest, "--surface") orelse if (ctx.surface) |s| std.fmt.allocPrint(ctx.alloc, "{d}", .{s}) catch null else null;
    const ws_arg = findNamedArg(ctx.rest, "--workspace") orelse if (ctx.workspace) |w| std.fmt.allocPrint(ctx.alloc, "{d}", .{w}) catch null else null;

    const params = if (surface != null and ws_arg != null)
        std.fmt.allocPrint(ctx.alloc, "{{\"direction\":\"{s}\",\"surface_id\":{s},\"workspace_id\":{s}}}", .{ dir, surface.?, ws_arg.? }) catch return 1
    else if (surface) |s|
        std.fmt.allocPrint(ctx.alloc, "{{\"direction\":\"{s}\",\"surface_id\":{s}}}", .{ dir, s }) catch return 1
    else if (ws_arg) |ws|
        std.fmt.allocPrint(ctx.alloc, "{{\"direction\":\"{s}\",\"workspace_id\":{s}}}", .{ dir, ws }) catch return 1
    else
        std.fmt.allocPrint(ctx.alloc, "{{\"direction\":\"{s}\"}}", .{dir}) catch return 1;

    const resp = apiCall(ctx.alloc, ctx.socket_path, "surface.expel", params) catch |e| {
        printSocketError(e);
        return 1;
    };
    if (ctx.json) {
        printJson(ctx.alloc, resp.result);
    } else {
        wfmt("Expelled pane {s} to column {s}\n", .{
            jsonValStr(ctx.alloc, resp.result.object.get("surface_id") orelse .null),
            jsonValStr(ctx.alloc, resp.result.object.get("column_index") orelse .null),
        });
    }
    return 0;
}

fn cmdResizeColumn(ctx: Ctx) u8 {
    var mode: ?[]const u8 = null;
    var ri: usize = 0;
    while (ri < ctx.rest.len) : (ri += 1) {
        if (eql(ctx.rest[ri], "--wider")) mode = "wider"
        else if (eql(ctx.rest[ri], "--narrower")) mode = "narrower"
        else if (eql(ctx.rest[ri], "--maximize")) mode = "maximize";
    }
    const m = mode orelse {
        werr("usage: resize-column --wider|--narrower|--maximize [--workspace N]\n");
        return 1;
    };
    const ws_arg = findNamedArg(ctx.rest, "--workspace") orelse if (ctx.workspace) |w| std.fmt.allocPrint(ctx.alloc, "{d}", .{w}) catch null else null;
    const params = if (ws_arg) |ws|
        std.fmt.allocPrint(ctx.alloc, "{{\"{s}\":true,\"workspace_id\":{s}}}", .{ m, ws }) catch return 1
    else
        std.fmt.allocPrint(ctx.alloc, "{{\"{s}\":true}}", .{m}) catch return 1;

    const resp = apiCall(ctx.alloc, ctx.socket_path, "column.resize", params) catch |e| {
        printSocketError(e);
        return 1;
    };
    if (ctx.json) {
        printJson(ctx.alloc, resp.result);
    } else {
        wfmt("Column width: {s}\n", .{
            jsonValStr(ctx.alloc, resp.result.object.get("width") orelse .null),
        });
    }
    return 0;
}

fn cmdResizeRow(ctx: Ctx) u8 {
    var mode: ?[]const u8 = null;
    var ri: usize = 0;
    while (ri < ctx.rest.len) : (ri += 1) {
        if (eql(ctx.rest[ri], "--taller")) mode = "taller"
        else if (eql(ctx.rest[ri], "--shorter")) mode = "shorter";
    }
    const m = mode orelse {
        werr("usage: resize-row --taller|--shorter [--surface N] [--workspace N]\n");
        return 1;
    };
    const surface = findNamedArg(ctx.rest, "--surface") orelse if (ctx.surface) |s| std.fmt.allocPrint(ctx.alloc, "{d}", .{s}) catch null else null;
    const ws_arg = findNamedArg(ctx.rest, "--workspace") orelse if (ctx.workspace) |w| std.fmt.allocPrint(ctx.alloc, "{d}", .{w}) catch null else null;

    const params = if (surface != null and ws_arg != null)
        std.fmt.allocPrint(ctx.alloc, "{{\"{s}\":true,\"surface_id\":{s},\"workspace_id\":{s}}}", .{ m, surface.?, ws_arg.? }) catch return 1
    else if (surface) |sid|
        std.fmt.allocPrint(ctx.alloc, "{{\"{s}\":true,\"surface_id\":{s}}}", .{ m, sid }) catch return 1
    else if (ws_arg) |ws|
        std.fmt.allocPrint(ctx.alloc, "{{\"{s}\":true,\"workspace_id\":{s}}}", .{ m, ws }) catch return 1
    else
        std.fmt.allocPrint(ctx.alloc, "{{\"{s}\":true}}", .{m}) catch return 1;

    _ = apiCall(ctx.alloc, ctx.socket_path, "surface.resize_row", params) catch |e| {
        printSocketError(e);
        return 1;
    };
    if (ctx.json) {
        wout("{}\n");
    } else {
        wfmt("Resized row {s}\n", .{m});
    }
    return 0;
}

fn cmdReorderSurface(ctx: Ctx) u8 {
    if (ctx.rest.len < 1) {
        werr("usage: reorder-surface <surface_id> --index N|--before ID|--after ID\n");
        return 1;
    }
    const surface_id = ctx.rest[0];
    _ = std.fmt.parseInt(u64, surface_id, 10) catch {
        werr("surface_id must be a number\n");
        return 1;
    };

    const index_arg = findNamedArg(ctx.rest, "--index");
    const before_arg = findNamedArg(ctx.rest, "--before");
    const after_arg = findNamedArg(ctx.rest, "--after");

    if (index_arg == null and before_arg == null and after_arg == null) {
        werr("usage: reorder-surface <surface_id> --index N|--before ID|--after ID\n");
        return 1;
    }

    const params = if (index_arg) |v|
        std.fmt.allocPrint(ctx.alloc, "{{\"surface_id\":{s},\"index\":{s}}}", .{ surface_id, v }) catch return 1
    else if (before_arg) |v|
        std.fmt.allocPrint(ctx.alloc, "{{\"surface_id\":{s},\"before\":{s}}}", .{ surface_id, v }) catch return 1
    else
        std.fmt.allocPrint(ctx.alloc, "{{\"surface_id\":{s},\"after\":{s}}}", .{ surface_id, after_arg.? }) catch return 1;

    const resp = apiCall(ctx.alloc, ctx.socket_path, "surface.reorder", params) catch |e| {
        printSocketError(e);
        return 1;
    };
    if (ctx.json) {
        printJson(ctx.alloc, resp.result);
    } else {
        wfmt("Surface {s} moved to index {s}\n", .{
            jsonValStr(ctx.alloc, resp.result.object.get("surface_id") orelse .null),
            jsonValStr(ctx.alloc, resp.result.object.get("index") orelse .null),
        });
    }
    return 0;
}

fn cmdReorderWorkspace(ctx: Ctx) u8 {
    if (ctx.rest.len < 1) {
        werr("usage: reorder-workspace <workspace_id> --index N|--before ID|--after ID\n");
        return 1;
    }
    const workspace_id = ctx.rest[0];
    _ = std.fmt.parseInt(u64, workspace_id, 10) catch {
        werr("workspace_id must be a number\n");
        return 1;
    };

    const index_arg = findNamedArg(ctx.rest, "--index");
    const before_arg = findNamedArg(ctx.rest, "--before");
    const after_arg = findNamedArg(ctx.rest, "--after");

    if (index_arg == null and before_arg == null and after_arg == null) {
        werr("usage: reorder-workspace <workspace_id> --index N|--before ID|--after ID\n");
        return 1;
    }

    const params = if (index_arg) |v|
        std.fmt.allocPrint(ctx.alloc, "{{\"workspace_id\":{s},\"index\":{s}}}", .{ workspace_id, v }) catch return 1
    else if (before_arg) |v|
        std.fmt.allocPrint(ctx.alloc, "{{\"workspace_id\":{s},\"before\":{s}}}", .{ workspace_id, v }) catch return 1
    else
        std.fmt.allocPrint(ctx.alloc, "{{\"workspace_id\":{s},\"after\":{s}}}", .{ workspace_id, after_arg.? }) catch return 1;

    const resp = apiCall(ctx.alloc, ctx.socket_path, "workspace.reorder", params) catch |e| {
        printSocketError(e);
        return 1;
    };
    if (ctx.json) {
        printJson(ctx.alloc, resp.result);
    } else {
        wfmt("Workspace {s} moved to index {s}\n", .{
            jsonValStr(ctx.alloc, resp.result.object.get("workspace_id") orelse .null),
            jsonValStr(ctx.alloc, resp.result.object.get("index") orelse .null),
        });
    }
    return 0;
}

fn cmdLastWorkspace(ctx: Ctx) u8 {
    const resp = apiCall(ctx.alloc, ctx.socket_path, "workspace.last", null) catch |e| {
        printSocketError(e);
        return 1;
    };
    if (ctx.json) {
        printJson(ctx.alloc, resp.result);
    } else {
        wfmt("Switched to workspace {s}\n", .{jsonValStr(ctx.alloc, resp.result.object.get("workspace_id") orelse .null)});
    }
    return 0;
}

fn cmdLastPane(ctx: Ctx) u8 {
    const ws_arg = findNamedArg(ctx.rest, "--workspace") orelse if (ctx.workspace) |w| std.fmt.allocPrint(ctx.alloc, "{d}", .{w}) catch null else null;
    const params = if (ws_arg) |ws|
        std.fmt.allocPrint(ctx.alloc, "{{\"workspace_id\":{s}}}", .{ws}) catch return 1
    else
        null;

    const resp = apiCall(ctx.alloc, ctx.socket_path, "surface.last", params) catch |e| {
        printSocketError(e);
        return 1;
    };
    if (ctx.json) {
        printJson(ctx.alloc, resp.result);
    } else {
        wfmt("Switched to surface {s}\n", .{jsonValStr(ctx.alloc, resp.result.object.get("surface_id") orelse .null)});
    }
    return 0;
}

// ── Agent hooks ────────────────────────────────────────────────────────

const StatusKeyMode = enum { session, surface };

const AgentConfig = struct {
    name: []const u8,
    display_name: []const u8,
    usage: []const u8,
    pid_env: []const u8,
    response: []const u8,
    status_key_prefix: []const u8,
    status_key_mode: StatusKeyMode,
    has_ask_user_handling: bool,
    has_notification_hook: bool,
    has_post_tool_hook: bool,
    session_dir_env: ?[]const u8,
};

const claude_agent = AgentConfig{
    .name = "Claude",
    .display_name = "Claude Code",
    .usage = "usage: claude-hook <session-start|prompt-submit|pre-tool-use|notification|stop|session-end>\n",
    .pid_env = "SEANCE_CLAUDE_PID",
    .response = "OK\n",
    .status_key_prefix = "claude",
    .status_key_mode = .session,
    .has_ask_user_handling = true,
    .has_notification_hook = true,
    .has_post_tool_hook = false,
    .session_dir_env = null,
};

const codex_agent = AgentConfig{
    .name = "Codex",
    .display_name = "Codex CLI",
    .usage = "usage: codex-hook <session-start|session-end|prompt-submit|pre-tool-use|post-tool-use|stop>\n",
    .pid_env = "SEANCE_CODEX_PID",
    .response = "{\"continue\":true}\n",
    .status_key_prefix = "codex",
    .status_key_mode = .surface,
    .has_ask_user_handling = false,
    .has_notification_hook = false,
    .has_post_tool_hook = true,
    .session_dir_env = "SEANCE_CODEX_SESSION_DIR",
};

fn cmdClaudeHook(ctx: Ctx) u8 {
    return cmdAgentHook(ctx, claude_agent);
}

fn cmdCodexHook(ctx: Ctx) u8 {
    return cmdAgentHook(ctx, codex_agent);
}

const HookCtx = struct {
    alloc: Allocator,
    socket_path: []const u8,
    input: JsonValue,
    session_id: ?[]const u8,
    workspace: ?u64,
    surface: ?u64,
    store: SessionStore,
    agent: AgentConfig,

    fn getStatusKey(self: HookCtx) []const u8 {
        return switch (self.agent.status_key_mode) {
            .surface => if (self.surface) |sf|
                std.fmt.allocPrint(self.alloc, "{s}-{d}", .{ self.agent.status_key_prefix, sf }) catch self.agent.status_key_prefix
            else
                self.agent.status_key_prefix,
            .session => self.session_id orelse self.agent.status_key_prefix,
        };
    }
};

fn cmdAgentHook(ctx: Ctx, agent: AgentConfig) u8 {
    if (ctx.rest.len == 0) {
        werr(agent.usage);
        return 1;
    }

    const hook_cmd = ctx.rest[0];
    const hook_rest = ctx.rest[1..];

    var ws_override: ?u64 = ctx.workspace;
    var sf_override: ?u64 = ctx.surface;
    var ri: usize = 0;
    while (ri < hook_rest.len) : (ri += 1) {
        if (eql(hook_rest[ri], "--workspace") and ri + 1 < hook_rest.len) {
            ri += 1;
            ws_override = parseU64(hook_rest[ri]);
        } else if (eql(hook_rest[ri], "--surface") and ri + 1 < hook_rest.len) {
            ri += 1;
            sf_override = parseU64(hook_rest[ri]);
        }
    }

    // Read stdin (hook payload)
    const stdin_file: std.fs.File = .stdin();
    const stdin_data = stdin_file.readToEndAlloc(ctx.alloc, 1024 * 1024) catch "";
    const input = blk: {
        const trimmed = std.mem.trim(u8, stdin_data, &[_]u8{ '\r', '\n', ' ' });
        if (trimmed.len == 0) break :blk JsonValue{ .object = std.json.ObjectMap.init(ctx.alloc) };
        const parsed = std.json.parseFromSlice(JsonValue, ctx.alloc, trimmed, .{}) catch
            break :blk JsonValue{ .object = std.json.ObjectMap.init(ctx.alloc) };
        break :blk parsed.value;
    };

    const session_id = extractSessionId(input);
    const store = SessionStore.init(ctx.alloc);

    // Resolve workspace/surface from overrides, session store, or env
    var ws = ws_override;
    var sf = sf_override;
    if (ws == null or sf == null) {
        if (session_id) |sid| {
            if (store.lookup(sid)) |rec| {
                if (ws == null) ws = getJsonInt(rec, "workspace_id");
                if (sf == null) sf = getJsonInt(rec, "surface_id");
            }
        }
    }
    if (ws == null) ws = envInt("SEANCE_WORKSPACE_ID");
    if (sf == null) sf = envInt("SEANCE_SURFACE_ID");

    const h = HookCtx{
        .alloc = ctx.alloc,
        .socket_path = ctx.socket_path,
        .input = input,
        .session_id = session_id,
        .workspace = ws,
        .surface = sf,
        .store = store,
        .agent = agent,
    };

    if (eql(hook_cmd, "session-start")) return agentHookSessionStart(h);
    if (eql(hook_cmd, "session-end")) return agentHookSessionEnd(h);
    if (eql(hook_cmd, "prompt-submit")) return agentHookPromptSubmit(h);
    if (eql(hook_cmd, "pre-tool-use")) return agentHookPreToolUse(h);
    if (eql(hook_cmd, "post-tool-use")) {
        if (agent.has_post_tool_hook) return agentHookPostToolUse(h);
    }
    if (eql(hook_cmd, "notification")) {
        if (agent.has_notification_hook) return agentHookNotification(h);
    }
    if (eql(hook_cmd, "stop")) return agentHookStop(h);

    wfmt("seance: unknown hook '{s}'\n", .{hook_cmd});
    return 1;
}

fn setAgentStatus(h: HookCtx, ws: u64, value: []const u8, priority: i32) void {
    const sk = jsonEscapeAlloc(h.alloc, h.getStatusKey());
    const p = std.fmt.allocPrint(h.alloc, "{{\"workspace_id\":{d},\"key\":\"{s}\",\"value\":\"{s}\",\"priority\":{d},\"is_agent\":true,\"display_name\":\"{s}\"}}", .{ ws, sk, jsonEscapeAlloc(h.alloc, value), priority, h.agent.name }) catch null;
    _ = apiCall(h.alloc, h.socket_path, "workspace.set_status", p) catch {};
}

fn emitNotification(h: HookCtx, ws: u64, title: []const u8, body: []const u8, focused: bool) void {
    var pbuf: [2048]u8 = undefined;
    var plen: usize = 0;
    const hdr = std.fmt.bufPrint(pbuf[plen..], "{{\"title\":\"{s}\",\"body\":\"{s}\"", .{ jsonEscapeAlloc(h.alloc, title), jsonEscapeAlloc(h.alloc, body) }) catch "";
    plen += hdr.len;
    const wsf = std.fmt.bufPrint(pbuf[plen..], ",\"workspace_id\":{d}", .{ws}) catch "";
    plen += wsf.len;
    if (h.surface) |sf| {
        const sff = std.fmt.bufPrint(pbuf[plen..], ",\"surface_id\":{d}", .{sf}) catch "";
        plen += sff.len;
    }
    if (focused) {
        plen += bufCopy(pbuf[plen..], ",\"read\":true");
    }
    plen += bufCopy(pbuf[plen..], "}");
    _ = apiCall(h.alloc, h.socket_path, "notification.create", pbuf[0..plen]) catch {};
}

fn agentHookSessionStart(h: HookCtx) u8 {
    const cwd = extractCwd(h.input);
    const pid = envInt(h.agent.pid_env) orelse @as(u64, @intCast(std.c.getpid()));

    if (h.session_id) |sid| {
        var fields = JsonFields.init(h.alloc);
        if (h.workspace) |w| fields.putInt("workspace_id", w);
        if (h.surface) |s| fields.putInt("surface_id", s);
        fields.putInt("pid", pid);
        fields.putFloat("started_at", @floatFromInt(std.time.timestamp()));
        if (cwd) |c| fields.putStr("cwd", c);
        h.store.upsert(sid, fields);
    }

    wout(h.agent.response);
    return 0;
}

fn agentHookPromptSubmit(h: HookCtx) u8 {
    if (h.workspace) |ws| {
        setAgentStatus(h, ws, "Running", 10);
    }
    wout(h.agent.response);
    return 0;
}

fn agentHookPreToolUse(h: HookCtx) u8 {
    const tool_name = getNestedString(h.input, "tool_name") orelse
        getNestedString(h.input, "tool.name") orelse
        getNestedString(h.input, "input.tool_name");

    if (h.agent.has_ask_user_handling) {
        if (tool_name) |tn| {
            if (eql(tn, "AskUserQuestion")) {
                const tool_input = if (h.input == .object) (h.input.object.get("tool_input") orelse h.input.object.get("input") orelse .null) else JsonValue.null;
                if (tool_input == .object) {
                    if (tool_input.object.get("question")) |q| {
                        if (q == .string) {
                            if (h.session_id) |sid| {
                                var fields = JsonFields.init(h.alloc);
                                fields.putStr("last_body", q.string);
                                h.store.upsert(sid, fields);
                            }
                        }
                    }
                }
                wout(h.agent.response);
                return 0;
            }
        }
    }

    if (h.workspace) |ws| {
        const desc = toolDescription(h.alloc, tool_name, h.input);
        setAgentStatus(h, ws, desc, 10);
    }
    wout(h.agent.response);
    return 0;
}

fn agentHookPostToolUse(h: HookCtx) u8 {
    if (h.workspace) |ws| {
        setAgentStatus(h, ws, "Running", 10);
    }
    wout(h.agent.response);
    return 0;
}

fn agentHookNotification(h: HookCtx) u8 {
    const summary = summarizeNotification(h.input);
    var body = summary.body;

    // Check for saved question from AskUserQuestion
    if (h.session_id) |sid| {
        if (h.store.lookup(sid)) |rec| {
            const saved = getJsonStr(rec, "last_body");
            if (saved.len > 0) {
                body = saved;
                var clear_fields = JsonFields.init(h.alloc);
                clear_fields.putStr("last_body", "");
                h.store.upsert(sid, clear_fields);
            }
        }
    }

    // Update session
    if (h.session_id) |sid| {
        var fields = JsonFields.init(h.alloc);
        fields.putStr("last_subtitle", summary.subtitle);
        fields.putStr("last_body", body);
        h.store.upsert(sid, fields);
    }

    if (h.workspace) |ws| {
        const focused = isWorkspaceFocused(h.alloc, h.socket_path, ws);
        const notif_body = std.fmt.allocPrint(h.alloc, "{s}: {s}", .{ summary.subtitle, body }) catch body;
        const notif_title = h.agent.display_name;
        emitNotification(h, ws, notif_title, notif_body, focused);
        setAgentStatus(h, ws, "Needs input", 10);
    }

    wout(h.agent.response);
    return 0;
}

fn agentHookStop(h: HookCtx) u8 {
    const cwd = extractCwd(h.input);
    var title: []const u8 = "Completed";
    var body: []const u8 = "";

    if (cwd) |c| {
        const project = std.fs.path.basename(c);
        if (project.len > 0) {
            title = std.fmt.allocPrint(h.alloc, "Completed in {s}", .{project}) catch "Completed";
        }
    }

    const last_msg = getNestedString(h.input, "last_assistant_message");
    if (last_msg) |msg| {
        const collapsed = collapseWhitespace(h.alloc, msg);
        body = if (collapsed.len > 200) collapsed[0..200] else collapsed;
    } else if (h.session_id) |sid| {
        if (h.store.lookup(sid)) |rec| {
            const saved_body = getJsonStr(rec, "last_body");
            if (saved_body.len > 0) {
                body = saved_body;
            } else {
                body = getJsonStr(rec, "last_subtitle");
            }
            if (cwd == null) {
                const rec_cwd = getJsonStr(rec, "cwd");
                if (rec_cwd.len > 0) {
                    const project = std.fs.path.basename(rec_cwd);
                    if (project.len > 0) {
                        title = std.fmt.allocPrint(h.alloc, "Completed in {s}", .{project}) catch title;
                    }
                }
            }
        }
    }

    if (h.session_id) |sid| {
        var fields = JsonFields.init(h.alloc);
        fields.putStr("last_subtitle", title);
        fields.putStr("last_body", body);
        h.store.upsert(sid, fields);
    }

    if (h.workspace) |ws| {
        const focused = isWorkspaceFocused(h.alloc, h.socket_path, ws);
        emitNotification(h, ws, title, body, focused);
        setAgentStatus(h, ws, "Idle", 5);
    }

    wout(h.agent.response);
    return 0;
}

fn agentHookSessionEnd(h: HookCtx) u8 {
    if (h.session_id) |sid| {
        _ = h.store.consume(sid);
    }
    if (h.workspace) |ws| {
        const sk = jsonEscapeAlloc(h.alloc, h.getStatusKey());
        const cp = std.fmt.allocPrint(h.alloc, "{{\"workspace_id\":{d},\"key\":\"{s}\"}}", .{ ws, sk }) catch null;
        _ = apiCall(h.alloc, h.socket_path, "workspace.clear_status", cp) catch {};
    }

    if (h.agent.session_dir_env) |env_name| {
        if (std.posix.getenv(env_name)) |dir| {
            std.fs.deleteTreeAbsolute(dir) catch {};
        }
    }

    wout(h.agent.response);
    return 0;
}

// ── Hook helpers ────────────────────────────────────────────────────────

fn extractSessionId(data: JsonValue) ?[]const u8 {
    const paths = [_][]const u8{ "session_id", "sessionId", "notification.session_id", "data.session_id", "session.id", "context.session_id" };
    for (paths) |p| {
        if (getNestedString(data, p)) |v| return v;
    }
    return null;
}

fn extractCwd(data: JsonValue) ?[]const u8 {
    const paths = [_][]const u8{ "cwd", "working_directory", "workingDirectory", "project_dir", "projectDir" };
    for (paths) |p| {
        if (getNestedString(data, p)) |v| return v;
    }
    return null;
}

fn isWorkspaceFocused(alloc: Allocator, socket_path: []const u8, workspace_id: u64) bool {
    const resp = apiCall(alloc, socket_path, "system.identify", null) catch return false;
    if (resp.result == .object) {
        const ws = getJsonInt(resp.result, "workspace_id") orelse return false;
        return ws == workspace_id;
    }
    return false;
}

fn toolDescription(alloc: Allocator, tool_name: ?[]const u8, data: JsonValue) []const u8 {
    const tn = tool_name orelse return "Running";
    const tool_input = if (data == .object)
        (data.object.get("tool_input") orelse data.object.get("input") orelse .null)
    else
        JsonValue.null;

    const ti_obj = if (tool_input == .object) tool_input.object else null;

    if (eql(tn, "Read")) return tiFileDesc(alloc, ti_obj, "Reading");
    if (eql(tn, "Edit")) return tiFileDesc(alloc, ti_obj, "Editing");
    if (eql(tn, "Write")) return tiFileDesc(alloc, ti_obj, "Writing");
    if (eql(tn, "Bash")) {
        if (ti_obj) |obj| {
            if (obj.get("command")) |cmd| {
                if (cmd == .string) {
                    const s = if (cmd.string.len > 30) cmd.string[0..30] else cmd.string;
                    return std.fmt.allocPrint(alloc, "Running {s}", .{s}) catch "Running command";
                }
            }
        }
        return "Running command";
    }
    if (eql(tn, "Glob")) return tiPatternDesc(alloc, ti_obj, "Searching");
    if (eql(tn, "Grep")) return tiPatternDesc(alloc, ti_obj, "Searching");
    if (eql(tn, "Agent")) {
        if (ti_obj) |obj| {
            if (obj.get("description")) |d| {
                if (d == .string) {
                    return if (d.string.len > 40) d.string[0..40] else d.string;
                }
            }
        }
        return "Agent";
    }
    if (eql(tn, "WebFetch")) return "Fetching URL";
    if (eql(tn, "WebSearch")) return tiQueryDesc(alloc, ti_obj, "Searching web");
    return tn;
}

fn tiFileDesc(alloc: Allocator, obj: ?std.json.ObjectMap, verb: []const u8) []const u8 {
    if (obj) |o| {
        if (o.get("file_path")) |fp| {
            if (fp == .string) return std.fmt.allocPrint(alloc, "{s} {s}", .{ verb, std.fs.path.basename(fp.string) }) catch verb;
        }
    }
    return verb;
}

fn tiPatternDesc(alloc: Allocator, obj: ?std.json.ObjectMap, verb: []const u8) []const u8 {
    if (obj) |o| {
        if (o.get("pattern")) |p| {
            if (p == .string) {
                const s = if (p.string.len > 30) p.string[0..30] else p.string;
                return std.fmt.allocPrint(alloc, "{s} {s}", .{ verb, s }) catch verb;
            }
        }
    }
    return verb;
}

fn tiQueryDesc(alloc: Allocator, obj: ?std.json.ObjectMap, fallback: []const u8) []const u8 {
    if (obj) |o| {
        if (o.get("query")) |q| {
            if (q == .string) {
                const s = if (q.string.len > 30) q.string[0..30] else q.string;
                return std.fmt.allocPrint(alloc, "Search: {s}", .{s}) catch fallback;
            }
        }
    }
    return fallback;
}

const NotifSummary = struct {
    subtitle: []const u8,
    body: []const u8,
};

fn summarizeNotification(data: JsonValue) NotifSummary {
    if (data != .object) return .{ .subtitle = "Attention", .body = "Claude needs your attention" };

    const inner = data.object.get("notification") orelse data.object.get("data") orelse data;
    if (inner != .object) return .{ .subtitle = "Attention", .body = "Claude needs your attention" };

    var signal: []const u8 = "";
    const signal_keys = [_][]const u8{ "event", "event_name", "hook_event_name", "type", "kind", "notification_type", "matcher", "reason" };
    for (signal_keys) |key| {
        if (inner.object.get(key)) |val| {
            if (val == .string) {
                signal = val.string;
                break;
            }
        }
    }

    var message: []const u8 = "";
    const msg_keys = [_][]const u8{ "message", "body", "text", "prompt", "error", "description" };
    for (msg_keys) |key| {
        if (inner.object.get(key)) |val| {
            if (val == .string) {
                message = val.string;
                break;
            }
        }
    }

    const subtitle_result = categorize(signal, message);
    const body_result = if (message.len == 0) "Claude needs your attention" else if (message.len > 180) message[0..180] else message;

    return .{ .subtitle = subtitle_result, .body = body_result };
}

fn categorize(signal: []const u8, message: []const u8) []const u8 {
    if (containsAny(signal, &.{ "permission", "approve", "approval" }) or
        containsAny(message, &.{ "permission", "approve", "approval" })) return "Permission";
    if (containsAny(signal, &.{ "error", "failed", "exception" }) or
        containsAny(message, &.{ "error", "failed", "exception" })) return "Error";
    if (containsAny(signal, &.{ "complet", "finish", "done", "success" }) or
        containsAny(message, &.{ "complet", "finish", "done", "success" })) return "Completed";
    if (containsAny(signal, &.{ "idle", "wait", "input" }) or
        containsAny(message, &.{ "idle", "wait", "input" })) return "Waiting";
    return "Attention";
}

fn containsAny(haystack: []const u8, needles: []const []const u8) bool {
    for (needles) |needle| {
        if (std.mem.indexOf(u8, haystack, needle) != null) return true;
    }
    return false;
}

fn collapseWhitespace(alloc: Allocator, s: []const u8) []const u8 {
    var result: std.ArrayList(u8) = .empty;
    var in_ws = false;
    for (s) |ch| {
        if (ch == ' ' or ch == '\t' or ch == '\n' or ch == '\r') {
            if (!in_ws) {
                result.append(alloc, ' ') catch {};
                in_ws = true;
            }
        } else {
            result.append(alloc, ch) catch {};
            in_ws = false;
        }
    }
    return result.items;
}

// ── Session store ───────────────────────────────────────────────────────

const SessionStore = struct {
    path: []const u8,
    alloc: Allocator,

    fn init(alloc: Allocator) SessionStore {
        if (std.posix.getenv("SEANCE_CLAUDE_HOOK_STATE_PATH")) |p| {
            return .{ .path = p, .alloc = alloc };
        }
        const home = std.posix.getenv("HOME") orelse "/tmp";
        const path = std.fmt.allocPrint(alloc, "{s}/.seance/claude-hook-sessions.json", .{home}) catch "/tmp/claude-hook-sessions.json";
        return .{ .path = path, .alloc = alloc };
    }

    fn lookup(self: SessionStore, session_id: []const u8) ?JsonValue {
        const data = self.readStore() orelse return null;
        const sessions = data.object.get("sessions") orelse return null;
        if (sessions != .object) return null;
        return sessions.object.get(session_id);
    }

    fn upsert(self: SessionStore, session_id: []const u8, fields: JsonFields) void {
        var data = self.readStore() orelse blk: {
            var obj = std.json.ObjectMap.init(self.alloc);
            obj.put("version", JsonValue{ .integer = 1 }) catch return;
            obj.put("sessions", JsonValue{ .object = std.json.ObjectMap.init(self.alloc) }) catch return;
            break :blk JsonValue{ .object = obj };
        };

        const sessions = if (data.object.getPtr("sessions")) |s| s else return;
        if (sessions.* != .object) return;

        if (!sessions.object.contains(session_id)) {
            var rec = std.json.ObjectMap.init(self.alloc);
            rec.put("session_id", JsonValue{ .string = session_id }) catch {};
            sessions.object.put(session_id, JsonValue{ .object = rec }) catch {};
        }

        if (sessions.object.getPtr(session_id)) |rec_ptr| {
            if (rec_ptr.* == .object) {
                for (fields.keys.items, fields.values.items) |k, v| {
                    rec_ptr.object.put(k, v) catch {};
                }
                rec_ptr.object.put("updated_at", JsonValue{ .float = @floatFromInt(std.time.timestamp()) }) catch {};
            }
        }

        self.pruneOld(sessions);
        self.writeStore(data);
    }

    fn consume(self: SessionStore, session_id: []const u8) ?JsonValue {
        var data = self.readStore() orelse return null;
        const sessions = if (data.object.getPtr("sessions")) |s| s else return null;
        if (sessions.* != .object) return null;

        const kv = sessions.object.fetchSwapRemove(session_id);
        if (kv) |entry| {
            self.writeStore(data);
            return entry.value;
        }
        return null;
    }

    fn readStore(self: SessionStore) ?JsonValue {
        const file = std.fs.openFileAbsolute(self.path, .{}) catch return null;
        defer file.close();
        const content = file.readToEndAlloc(self.alloc, 1024 * 1024) catch return null;
        if (content.len == 0) return null;
        const parsed = std.json.parseFromSlice(JsonValue, self.alloc, content, .{}) catch return null;
        if (parsed.value != .object) return null;
        if (parsed.value.object.get("version")) |v| {
            if (v != .integer or v.integer != 1) return null;
        }
        return parsed.value;
    }

    fn writeStore(self: SessionStore, data: JsonValue) void {
        // Ensure parent directory exists
        if (std.mem.lastIndexOfScalar(u8, self.path, '/')) |sep| {
            std.fs.makeDirAbsolute(self.path[0..sep]) catch |e| switch (e) {
                error.PathAlreadyExists => {},
                else => return,
            };
        }

        const file = std.fs.createFileAbsolute(self.path, .{}) catch return;
        defer file.close();

        // Serialize using Stringify.valueAlloc and write
        const json_bytes = Stringify.valueAlloc(self.alloc, data, .{ .whitespace = .indent_2 }) catch return;
        file.writeAll(json_bytes) catch return;
    }

    fn pruneOld(self: SessionStore, sessions: *JsonValue) void {
        if (sessions.* != .object) return;
        const cutoff: f64 = @floatFromInt(std.time.timestamp() - 7 * 86400);
        var to_remove: std.ArrayList([]const u8) = .empty;
        var it = sessions.object.iterator();
        while (it.next()) |entry| {
            if (entry.value_ptr.* == .object) {
                if (entry.value_ptr.object.get("updated_at")) |ua| {
                    const ts: f64 = switch (ua) {
                        .float => ua.float,
                        .integer => @floatFromInt(ua.integer),
                        else => 0,
                    };
                    if (ts < cutoff) {
                        to_remove.append(self.alloc, entry.key_ptr.*) catch {};
                    }
                }
            }
        }
        for (to_remove.items) |key| {
            _ = sessions.object.fetchSwapRemove(key);
        }
    }
};

const JsonFields = struct {
    keys: std.ArrayList([]const u8),
    values: std.ArrayList(JsonValue),
    alloc: Allocator,

    fn init(alloc: Allocator) JsonFields {
        return .{
            .keys = .empty,
            .values = .empty,
            .alloc = alloc,
        };
    }

    fn putStr(self: *JsonFields, key: []const u8, value: []const u8) void {
        self.keys.append(self.alloc, key) catch {};
        self.values.append(self.alloc, JsonValue{ .string = value }) catch {};
    }

    fn putInt(self: *JsonFields, key: []const u8, value: u64) void {
        self.keys.append(self.alloc, key) catch {};
        self.values.append(self.alloc, JsonValue{ .integer = @intCast(value) }) catch {};
    }

    fn putFloat(self: *JsonFields, key: []const u8, value: f64) void {
        self.keys.append(self.alloc, key) catch {};
        self.values.append(self.alloc, JsonValue{ .float = value }) catch {};
    }
};

// ── JSON helpers ────────────────────────────────────────────────────────

fn getNestedString(root: JsonValue, path: []const u8) ?[]const u8 {
    var current = root;
    var it = std.mem.splitScalar(u8, path, '.');
    while (it.next()) |part| {
        if (current != .object) return null;
        current = current.object.get(part) orelse return null;
    }
    return switch (current) {
        .string => |s| s,
        else => null,
    };
}

fn getJsonInt(val: JsonValue, key: []const u8) ?u64 {
    if (val != .object) return null;
    const v = val.object.get(key) orelse return null;
    return switch (v) {
        .integer => |n| if (n >= 0) @intCast(n) else null,
        .float => |f| if (f >= 0) @intCast(@as(i64, @intFromFloat(f))) else null,
        else => null,
    };
}

fn getJsonStr(val: JsonValue, key: []const u8) []const u8 {
    if (val != .object) return "";
    const v = val.object.get(key) orelse return "";
    return switch (v) {
        .string => |s| s,
        else => "",
    };
}

fn getStr(val: JsonValue, key: []const u8) []const u8 {
    return getJsonStr(val, key);
}

fn getBool(val: JsonValue, key: []const u8) bool {
    if (val != .object) return false;
    const v = val.object.get(key) orelse return false;
    return switch (v) {
        .bool => |b| b,
        else => false,
    };
}

fn getArray(val: JsonValue, key: []const u8) ?[]const JsonValue {
    if (val != .object) return null;
    const v = val.object.get(key) orelse return null;
    if (v != .array) return null;
    return v.array.items;
}

fn jsonValStr(alloc: Allocator, val: JsonValue) []const u8 {
    return switch (val) {
        .string => |s| s,
        .integer => |n| std.fmt.allocPrint(alloc, "{d}", .{n}) catch "?",
        .float => |f| std.fmt.allocPrint(alloc, "{d:.0}", .{f}) catch "?",
        .bool => |b| if (b) "true" else "false",
        .null => "null",
        else => "?",
    };
}

fn jsonEscapeAlloc(alloc: Allocator, input: []const u8) []const u8 {
    var result: std.ArrayList(u8) = .empty;
    for (input) |ch| {
        switch (ch) {
            '"' => result.appendSlice(alloc, "\\\"") catch {},
            '\\' => result.appendSlice(alloc, "\\\\") catch {},
            '\n' => result.appendSlice(alloc, "\\n") catch {},
            '\r' => result.appendSlice(alloc, "\\r") catch {},
            '\t' => result.appendSlice(alloc, "\\t") catch {},
            else => {
                if (ch < 0x20) {
                    const esc = std.fmt.allocPrint(alloc, "\\u{X:0>4}", .{ch}) catch "";
                    result.appendSlice(alloc, esc) catch {};
                } else {
                    result.append(alloc, ch) catch {};
                }
            },
        }
    }
    return result.items;
}

// ── Output helpers ──────────────────────────────────────────────────────

fn printJson(alloc: Allocator, val: JsonValue) void {
    const json_bytes = Stringify.valueAlloc(alloc, val, .{ .whitespace = .indent_2 }) catch {
        wout("{}\n");
        return;
    };
    wout(json_bytes);
    wout("\n");
}

fn padRight(alloc: Allocator, s: []const u8, width: usize) []const u8 {
    if (s.len >= width) return s;
    const buf = alloc.alloc(u8, width) catch return s;
    @memcpy(buf[0..s.len], s);
    @memset(buf[s.len..], ' ');
    return buf;
}

fn prettyLabel(key: []const u8) []const u8 {
    if (eql(key, "window_index")) return "Window Index";
    if (eql(key, "workspace_id")) return "Workspace Id";
    if (eql(key, "workspace_index")) return "Workspace Index";
    if (eql(key, "pane_group_id")) return "Pane Group Id";
    if (eql(key, "surface_id")) return "Surface Id";
    return key;
}

fn wout(s: []const u8) void {
    const f: std.fs.File = .stdout();
    f.writeAll(s) catch {};
}

fn werr(s: []const u8) void {
    const f: std.fs.File = .stderr();
    f.writeAll(s) catch {};
}

fn wfmt(comptime fmt: []const u8, args: anytype) void {
    const f: std.fs.File = .stdout();
    var buf: [4096]u8 = undefined;
    var w = f.writer(&buf);
    w.interface.print(fmt, args) catch {};
    w.interface.flush() catch {};
}

// ── Utility ─────────────────────────────────────────────────────────────

fn eql(a: []const u8, b: []const u8) bool {
    return std.mem.eql(u8, a, b);
}

fn parseU64(s: []const u8) ?u64 {
    return std.fmt.parseInt(u64, s, 10) catch null;
}

fn envInt(name: []const u8) ?u64 {
    const val = std.posix.getenv(name) orelse return null;
    return parseU64(val);
}

fn findNamedArg(args: []const []const u8, name: []const u8) ?[]const u8 {
    var i: usize = 0;
    while (i < args.len) : (i += 1) {
        if (eql(args[i], name) and i + 1 < args.len) {
            return args[i + 1];
        }
    }
    return null;
}

fn getSocketPath(override: ?[]const u8, buf: []u8) ?[]const u8 {
    if (override) |p| return p;
    if (std.posix.getenv("SEANCE_SOCKET_PATH")) |p| return p;
    // Match SocketServer.resolvedPath: prefer XDG_RUNTIME_DIR, fall back to $HOME/.seance/
    if (std.posix.getenv("XDG_RUNTIME_DIR")) |runtime_dir| {
        return std.fmt.bufPrint(buf, "{s}/seance/seance.sock", .{runtime_dir}) catch null;
    }
    const home = std.posix.getenv("HOME") orelse return null;
    return std.fmt.bufPrint(buf, "{s}/.seance/seance.sock", .{home}) catch null;
}

fn bufCopy(dest: []u8, src: []const u8) usize {
    const len = @min(src.len, dest.len);
    @memcpy(dest[0..len], src[0..len]);
    return len;
}

// ── Usage ───────────────────────────────────────────────────────────────

pub fn printTopLevelUsage() void {
    wout(
        \\seance — terminal multiplexer
        \\
        \\Usage: seance              Start a new window (GUI)
        \\       seance ctl <cmd>    Control a running instance (CLI)
        \\
        \\Run 'seance ctl --help' for a list of CLI commands.
        \\
    );
}

fn printUsage() void {
    wout(
        \\seance ctl — CLI tool for controlling seance
        \\
        \\Usage: seance ctl [--socket PATH] [--json] [--workspace N] [--surface N] <command>
        \\   or: seance [options] <command>   (when symlinked)
        \\
        \\System:
        \\  ping                    Test connectivity
        \\  identify                Show current focused context
        \\  capabilities            List supported methods
        \\  tree                    Show window/workspace/pane hierarchy
        \\
        \\Windows:
        \\  list-windows            List open windows
        \\  new-window              Create a new window
        \\  close-window [INDEX]    Close a window (default: active)
        \\
        \\Workspaces:
        \\  list-workspaces         List workspaces [--window N]
        \\  new-workspace           Create workspace [--title T]
        \\  select-workspace ID     Focus a workspace
        \\  close-workspace ID      Close a workspace
        \\  rename-workspace ID T   Rename a workspace
        \\  reorder-workspace ID    Reorder workspace --index N|--before ID|--after ID
        \\  move-workspace ID       Move workspace to --window INDEX
        \\  last-workspace          Switch to last-active workspace
        \\  last-pane               Switch to last-focused pane [--workspace N]
        \\
        \\Columns:
        \\  move-column             Move column --direction left|right [--workspace N]
        \\  resize-column           Resize column --wider|--narrower|--maximize
        \\
        \\Surfaces:
        \\  list-surfaces           List surfaces [--workspace N]
        \\  split                   Split pane [--direction vertical|horizontal]
        \\  close-surface ID        Close a surface
        \\  send TEXT               Send text [--surface N]
        \\  send-key KEY            Send key (enter, ctrl+c, etc.) [--surface N]
        \\  read-screen             Read terminal [--lines N] [--surface N]
        \\  expel-pane              Expel pane --direction left|right [--surface N]
        \\  resize-row              Resize row --taller|--shorter [--surface N]
        \\  reorder-surface ID      Reorder tab --index N|--before ID|--after ID
        \\
        \\Notifications:
        \\  notify                  Send notification [--title T] [--body B]
        \\  list-notifications      List notifications
        \\  clear-notifications     Clear all notifications
        \\
        \\Claude Code Hooks:
        \\  claude-hook <event>     Handle Claude Code lifecycle event
        \\    Events: session-start, prompt-submit, pre-tool-use,
        \\            notification, stop, session-end
        \\
        \\Codex CLI Hooks:
        \\  codex-hook <event>      Handle Codex CLI lifecycle event
        \\    Events: session-start, session-end, prompt-submit,
        \\            pre-tool-use, post-tool-use, stop
        \\
    );
}
