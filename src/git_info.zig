const std = @import("std");

/// Read the current git branch from a working directory by walking up
/// to find .git/HEAD. Returns the branch name, short SHA for detached HEAD,
/// or null if not in a git repo.
pub fn getBranch(buf: []u8, cwd: []const u8) ?[]const u8 {
    var dir: []const u8 = cwd;
    var path_buf: [std.fs.max_path_bytes]u8 = undefined;

    while (true) {
        const head_path = std.fmt.bufPrint(&path_buf, "{s}/.git/HEAD", .{dir}) catch return null;

        if (readFileContent(head_path, buf)) |content| {
            const trimmed = std.mem.trimRight(u8, content, "\n\r ");
            const prefix = "ref: refs/heads/";
            if (std.mem.startsWith(u8, trimmed, prefix)) {
                const branch = trimmed[prefix.len..];
                // Copy branch name to start of buffer
                std.mem.copyForwards(u8, buf[0..branch.len], branch);
                return buf[0..branch.len];
            }
            // Detached HEAD — return short SHA (already at start of buf)
            return trimmed[0..@min(trimmed.len, 7)];
        }

        // Go up one directory
        const parent = std.fs.path.dirname(dir) orelse return null;
        if (std.mem.eql(u8, parent, dir)) return null;
        dir = parent;
    }
}

/// Check if a git repo at `cwd` has uncommitted changes (staged or unstaged).
/// Uses `git diff-index --quiet HEAD --` which is a fast plumbing command.
/// Returns true if dirty, false if clean or on any error.
pub fn isDirty(alloc: std.mem.Allocator, cwd: []const u8) bool {
    const result = std.process.Child.run(.{
        .allocator = alloc,
        .argv = &[_][]const u8{ "git", "-C", cwd, "diff-index", "--quiet", "HEAD", "--" },
        .max_output_bytes = 1,
    }) catch return false;
    alloc.free(result.stdout);
    alloc.free(result.stderr);
    return switch (result.term) {
        .Exited => |code| code != 0,
        else => false,
    };
}

fn readFileContent(path: []const u8, buf: []u8) ?[]const u8 {
    const file = std.fs.openFileAbsolute(path, .{}) catch return null;
    defer file.close();
    const n = file.read(buf) catch return null;
    if (n == 0) return null;
    return buf[0..n];
}
