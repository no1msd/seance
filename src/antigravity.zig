const std = @import("std");
const io = @import("io.zig");
const Allocator = std.mem.Allocator;

// This stays inert outside an instrumented agy invocation, including after
// Séance is uninstalled. Resolve the binary through the wrapper's environment
// because AppImage mount paths change between launches.
const callback_prefix =
    \\# seance-antigravity-v1
    \\seance_agy_input=$(cat)
    \\if [ -n "${SEANCE_AGY_SESSION_DIR:-}" ] && [ -x "${SEANCE_AGY_BIN:-}" ]; then
    \\  printf '%s' "$seance_agy_input" | timeout 2 "$SEANCE_AGY_BIN" ctl antigravity-hook state >/dev/null 2>&1 || :
    \\fi
    \\
;

/// Wrap the user's callback, preserving its output and all other settings.
/// An explicitly disabled callback remains disabled; we do not change that
/// preference just to obtain status events.
pub fn withStatusLine(alloc: Allocator, source: []const u8) ![]const u8 {
    const parsed = try std.json.parseFromSlice(std.json.Value, alloc, source, .{});
    defer parsed.deinit();
    const arena = parsed.arena.allocator();
    var config = parsed.value;
    if (config != .object) return error.InvalidConfig;
    var status = config.object.get("statusLine") orelse .null;
    if (status == .null) {
        status = .{ .object = .empty };
        try status.object.put(arena, "type", .{ .string = "command" });
        try status.object.put(arena, "stack_with_default", .{ .bool = true });
    }
    if (status != .object) return error.InvalidStatusLine;
    if (status.object.get("enabled")) |enabled| {
        if (enabled != .bool) return error.InvalidStatusLine;
        if (!enabled.bool) return error.StatusLineDisabled;
    }
    if (status.object.get("type")) |kind| {
        if (kind != .string or !std.mem.eql(u8, kind.string, "command")) return error.InvalidStatusLine;
    }
    const command = status.object.get("command") orelse std.json.Value{ .string = "" };
    if (command != .string) return error.InvalidStatusLine;
    if (command.string.len == 0 and !status.object.contains("stack_with_default"))
        try status.object.put(arena, "stack_with_default", .{ .bool = true });
    if (std.mem.startsWith(u8, command.string, callback_prefix)) return alloc.dupe(u8, source);
    const wrapped = if (command.string.len == 0) callback_prefix else try std.fmt.allocPrint(arena, "{s}printf '%s' \"$seance_agy_input\" | (\n{s}\n)\n", .{ callback_prefix, command.string });
    try status.object.put(arena, "command", .{ .string = wrapped });
    try config.object.put(arena, "statusLine", status);
    return std.json.Stringify.valueAlloc(alloc, config, .{ .whitespace = .indent_2 });
}

/// agy has no per-launch settings override. Install one persistent, inert
/// callback with an original-file backup. Resolve symlinks before replacement
/// and serialize concurrent pane launches through a separate stable lock file.
pub fn install(alloc: Allocator, path: []const u8) !void {
    const parent = std.fs.path.dirname(path) orelse ".";
    try std.Io.Dir.cwd().createDirPath(io.get(), parent);
    const resolved = std.Io.Dir.cwd().realPathFileAlloc(io.get(), path, alloc) catch |err| switch (err) {
        error.FileNotFound => blk: {
            if (std.Io.Dir.cwd().statFile(io.get(), path, .{ .follow_symlinks = false })) |stat| {
                if (stat.kind == .sym_link) return error.DanglingSymlink;
            } else |stat_err| switch (stat_err) {
                error.FileNotFound => {},
                else => return stat_err,
            }
            break :blk try std.fs.path.join(alloc, &.{
                try std.Io.Dir.cwd().realPathFileAlloc(io.get(), parent, alloc), std.fs.path.basename(path),
            });
        },
        else => return err,
    };
    const lock_path = try std.fmt.allocPrint(alloc, "{s}.seance.lock", .{resolved});
    const lock = try std.Io.Dir.createFileAbsolute(io.get(), lock_path, .{
        .truncate = false,
        .lock = .exclusive,
        .permissions = .fromMode(0o600),
    });
    defer lock.close(io.get());
    const source = try readConfig(alloc, resolved);
    const result = try withStatusLine(alloc, source);
    if (std.mem.eql(u8, source, result)) return;
    if (std.Io.Dir.cwd().statFile(io.get(), resolved, .{})) |stat| {
        if (stat.permissions.readOnly()) return error.AccessDenied;
    } else |err| switch (err) {
        error.FileNotFound => {},
        else => return err,
    }

    const backup_path = try std.fmt.allocPrint(alloc, "{s}.seance-backup", .{resolved});
    var backup = try std.Io.Dir.cwd().createFileAtomic(io.get(), backup_path, .{ .permissions = .fromMode(0o600) });
    defer backup.deinit(io.get());
    try backup.file.writeStreamingAll(io.get(), source);
    backup.link(io.get()) catch |err| switch (err) {
        error.PathAlreadyExists => {},
        else => return err,
    };
    var output = try std.Io.Dir.cwd().createFileAtomic(io.get(), resolved, .{
        .replace = true,
        .permissions = .fromMode(0o600),
    });
    defer output.deinit(io.get());
    try output.file.writeStreamingAll(io.get(), result);
    // agy does not share our lock. Do not overwrite a settings save that
    // happened while we prepared the callback.
    if (!std.mem.eql(u8, source, try readConfig(alloc, resolved))) return error.ConfigChanged;
    try output.replace(io.get());
}

fn readConfig(alloc: Allocator, path: []const u8) ![]const u8 {
    const file = std.Io.Dir.openFileAbsolute(io.get(), path, .{}) catch |err| switch (err) {
        error.FileNotFound => return "{}",
        else => return err,
    };
    defer file.close(io.get());
    return io.readToEndAlloc(file, alloc, 1024 * 1024);
}

pub const Snapshot = struct {
    agent_state: []const u8,
    conversation_id: []const u8 = "",
    session_id: []const u8 = "",
    tool_confirmation_pending: bool = false,
    task_count: u32 = 0,
    cwd: []const u8 = "",
};

pub const Phase = enum {
    starting,
    working,
    needs_input,
    idle,
    failed,

    pub fn label(self: Phase) []const u8 {
        return switch (self) {
            .starting => "Starting",
            .working => "Running",
            .needs_input => "Needs input",
            .idle, .failed => "Idle",
        };
    }
};

pub const State = struct {
    phase: Phase = .starting,
    conversation_id: []const u8 = "",
    seen: bool = false,
    closed: bool = false,
};

pub const Update = struct {
    state: State,
    changed: bool,
    notification: enum { none, permission, idle } = .none,
};

pub fn transition(previous: State, snapshot: Snapshot) ?Update {
    if (previous.closed) return null;
    const phase: Phase = if (snapshot.tool_confirmation_pending) .needs_input else blk: {
        const name = snapshot.agent_state;
        if (std.mem.eql(u8, name, "idle")) break :blk if (snapshot.task_count > 0) .working else .idle;
        for ([_][]const u8{ "thinking", "working", "tool_use" }) |busy|
            if (std.mem.eql(u8, name, busy)) break :blk .working;
        for ([_][]const u8{ "initializing", "authenticating" }) |starting|
            if (std.mem.eql(u8, name, starting)) break :blk .starting;
        if (std.mem.eql(u8, name, "error")) break :blk .failed;
        return null;
    };
    const session = if (snapshot.conversation_id.len > 0) snapshot.conversation_id else snapshot.session_id;
    const same_session = previous.seen and std.mem.eql(u8, previous.conversation_id, session);
    var result = Update{
        .state = .{ .phase = phase, .conversation_id = session, .seen = true },
        .changed = !same_session or phase != previous.phase,
    };
    if (phase == .needs_input and (!same_session or previous.phase != .needs_input)) {
        result.notification = .permission;
    } else if (same_session and phase == .idle and (previous.phase == .working or previous.phase == .needs_input)) {
        // The status callback also becomes idle after cancellation. Describe
        // readiness, rather than asserting successful task completion.
        result.notification = .idle;
    }
    return result;
}

pub const Tracker = struct {
    file: std.Io.File,
    state: State,

    pub fn open(alloc: Allocator, directory: []const u8) !Tracker {
        const path = try std.fs.path.join(alloc, &.{ directory, "state.json" });
        // Never recreate this file: an exiting wrapper closes tracking before
        // clearing the sidebar, and late callbacks must remain harmless.
        const file = try std.Io.Dir.openFileAbsolute(io.get(), path, .{ .mode = .read_write, .lock = .exclusive });
        errdefer file.close(io.get());
        const input = try io.readToEndAlloc(file, alloc, 16 * 1024);
        const parsed = try std.json.parseFromSlice(State, alloc, input, .{ .ignore_unknown_fields = true });
        return .{ .file = file, .state = parsed.value };
    }

    pub fn save(self: *Tracker, alloc: Allocator, state: State) !void {
        const json = try std.json.Stringify.valueAlloc(alloc, state, .{});
        try self.file.writePositionalAll(io.get(), json, 0);
        try self.file.setLength(io.get(), json.len);
        self.state = state;
    }

    pub fn close(self: Tracker) void {
        self.file.close(io.get());
    }
};
