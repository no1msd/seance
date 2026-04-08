const std = @import("std");
const builtin = @import("builtin");

const is_linux = builtin.os.tag == .linux;

/// Standard ports to exclude from display.
const excluded_ports = [_]u16{ 22, 53, 631, 5353 };

/// Per-pane port scan result.
pub const PanePorts = struct {
    panel_id: u64,
    ports: [16]u16 = [_]u16{0} ** 16,
    ports_len: usize = 0,
};

/// Inode-to-port mapping entry.
const InodePort = struct {
    inode: u64,
    port: u16,
};

/// PID-to-ports mapping entry.
const PidPorts = struct {
    pid: u32,
    ports: [16]u16 = [_]u16{0} ** 16,
    ports_len: usize = 0,
};

/// Scan for listening TCP ports and attribute them to seance panes via SEANCE_PANEL_ID.
/// `panel_ids` is the set of pane IDs to look for.
/// Returns a slice of result_buf filled with per-pane port results.
///
/// Currently only implemented on Linux (reads /proc). On other platforms this
/// returns an empty slice.  The internal helpers are retained so a macOS
/// implementation can be added later without changing the public API.
pub fn scanPorts(panel_ids: []const u64, result_buf: []PanePorts) []PanePorts {
    if (!is_linux) return result_buf[0..0];
    return scanPortsLinux(panel_ids, result_buf);
}

fn scanPortsLinux(panel_ids: []const u64, result_buf: []PanePorts) []PanePorts {
    if (panel_ids.len == 0) return result_buf[0..0];

    // Phase 1: Parse /proc/net/tcp{,6} for LISTEN sockets → {inode → port}
    var inode_ports: [512]InodePort = undefined;
    var inode_count: usize = 0;
    inode_count = scanTcpFile("/proc/net/tcp", &inode_ports, inode_count);
    inode_count = scanTcpFile("/proc/net/tcp6", &inode_ports, inode_count);

    if (inode_count == 0) return result_buf[0..0];

    // Phase 2: Walk /proc/<pid>/fd/ to find which PIDs own listen inodes
    var pid_ports_buf: [256]PidPorts = undefined;
    var pid_ports_count: usize = 0;
    matchPidFds(inode_ports[0..inode_count], &pid_ports_buf, &pid_ports_count);

    if (pid_ports_count == 0) return result_buf[0..0];

    // Phase 3: Read /proc/<pid>/environ to extract SEANCE_PANEL_ID, attribute ports
    var result_count: usize = 0;
    for (pid_ports_buf[0..pid_ports_count]) |pp| {
        const panel_id = readPanelId(pp.pid) orelse continue;

        // Check if this panel_id is one we're looking for
        var found = false;
        for (panel_ids) |pid| {
            if (pid == panel_id) {
                found = true;
                break;
            }
        }
        if (!found) continue;

        // Find or create result entry for this panel_id
        var entry: ?*PanePorts = null;
        for (result_buf[0..result_count]) |*r| {
            if (r.panel_id == panel_id) {
                entry = r;
                break;
            }
        }
        if (entry == null) {
            if (result_count >= result_buf.len) continue;
            result_buf[result_count] = .{ .panel_id = panel_id };
            entry = &result_buf[result_count];
            result_count += 1;
        }

        // Add ports from this PID
        const e = entry.?;
        for (pp.ports[0..pp.ports_len]) |port| {
            if (e.ports_len >= e.ports.len) break;
            if (!isDuplicate(e.ports[0..e.ports_len], port)) {
                e.ports[e.ports_len] = port;
                e.ports_len += 1;
            }
        }
    }

    // Sort ports within each result
    for (result_buf[0..result_count]) |*r| {
        sortPorts(r.ports[0..r.ports_len]);
    }

    return result_buf[0..result_count];
}

/// Parse /proc/net/tcp or tcp6, extracting inode and port for LISTEN sockets.
fn scanTcpFile(path: []const u8, buf: []InodePort, start: usize) usize {
    var count = start;
    const file = std.fs.openFileAbsolute(path, .{}) catch return count;
    defer file.close();

    var read_buf: [131072]u8 = undefined;
    const n = file.readAll(&read_buf) catch return count;
    const content = read_buf[0..n];

    var lines = std.mem.splitScalar(u8, content, '\n');
    _ = lines.next(); // skip header

    while (lines.next()) |line| {
        if (count >= buf.len) break;
        if (line.len == 0) continue;
        if (parseTcpLine(line)) |entry| {
            if (!isExcluded(entry.port)) {
                // Dedup by inode
                var dup = false;
                for (buf[0..count]) |existing| {
                    if (existing.inode == entry.inode) {
                        dup = true;
                        break;
                    }
                }
                if (!dup) {
                    buf[count] = entry;
                    count += 1;
                }
            }
        }
    }

    return count;
}

/// Parse a single line from /proc/net/tcp, returning inode and port if LISTEN.
fn parseTcpLine(line: []const u8) ?InodePort {
    // Format: "  sl  local_address  rem_address  st  tx_queue:rx_queue  tr:tm->when  retrnsmt  uid  timeout  inode ..."
    //          0    1               2            3   4                  5             6         7    8        9
    var it = std.mem.tokenizeScalar(u8, line, ' ');

    _ = it.next() orelse return null; // 0: sl
    const local = it.next() orelse return null; // 1: local_address
    _ = it.next() orelse return null; // 2: rem_address
    const st = it.next() orelse return null; // 3: state

    // State 0A = LISTEN
    if (!std.mem.eql(u8, st, "0A")) return null;

    _ = it.next() orelse return null; // 4: tx_queue:rx_queue
    _ = it.next() orelse return null; // 5: tr:tm->when
    _ = it.next() orelse return null; // 6: retrnsmt
    _ = it.next() orelse return null; // 7: uid
    _ = it.next() orelse return null; // 8: timeout
    const inode_str = it.next() orelse return null; // 9: inode

    // Parse port from local_address (HEXIP:HEXPORT)
    const colon_idx = std.mem.indexOfScalar(u8, local, ':') orelse return null;
    const port_hex = local[colon_idx + 1 ..];
    const port = std.fmt.parseInt(u16, port_hex, 16) catch return null;

    // Parse inode
    const inode = std.fmt.parseInt(u64, inode_str, 10) catch return null;
    if (inode == 0) return null;

    return .{ .inode = inode, .port = port };
}

/// Walk /proc/<pid>/fd/ to match socket inodes against known listen inodes.
fn matchPidFds(inode_ports: []const InodePort, pid_buf: []PidPorts, pid_count: *usize) void {
    var proc_dir = std.fs.openDirAbsolute("/proc", .{ .iterate = true }) catch return;
    defer proc_dir.close();

    var proc_iter = proc_dir.iterate();
    while (proc_iter.next() catch null) |entry| {
        if (entry.kind != .directory) continue;
        const pid = std.fmt.parseInt(u32, entry.name, 10) catch continue;

        // Skip kernel threads (no exe symlink)
        var exe_path_buf: [64]u8 = undefined;
        const exe_path = std.fmt.bufPrint(&exe_path_buf, "/proc/{d}/exe", .{pid}) catch continue;
        std.fs.accessAbsolute(exe_path, .{}) catch continue;

        var path_buf: [64]u8 = undefined;
        const fd_path = std.fmt.bufPrint(&path_buf, "/proc/{d}/fd", .{pid}) catch continue;

        var fd_dir = std.fs.openDirAbsolute(fd_path, .{ .iterate = true }) catch continue;
        defer fd_dir.close();

        var pp: PidPorts = .{ .pid = pid };

        var fd_iter = fd_dir.iterate();
        while (fd_iter.next() catch null) |fd_entry| {
            // Read symlink target
            var link_buf: [128]u8 = undefined;
            const link = fd_dir.readLink(fd_entry.name, &link_buf) catch continue;

            // Match "socket:[<inode>]"
            if (std.mem.startsWith(u8, link, "socket:[")) {
                if (link.len > 9 and link[link.len - 1] == ']') {
                    const inode_str = link[8 .. link.len - 1];
                    const inode = std.fmt.parseInt(u64, inode_str, 10) catch continue;

                    // Look up in inode_ports
                    for (inode_ports) |ip| {
                        if (ip.inode == inode) {
                            if (pp.ports_len < pp.ports.len) {
                                if (!isDuplicate(pp.ports[0..pp.ports_len], ip.port)) {
                                    pp.ports[pp.ports_len] = ip.port;
                                    pp.ports_len += 1;
                                }
                            }
                            break;
                        }
                    }
                }
            }
        }

        if (pp.ports_len > 0) {
            if (pid_count.* < pid_buf.len) {
                pid_buf[pid_count.*] = pp;
                pid_count.* += 1;
            }
        }
    }
}

/// Read /proc/<pid>/environ and extract SEANCE_PANEL_ID value.
fn readPanelId(pid: u32) ?u64 {
    var path_buf: [64]u8 = undefined;
    const path = std.fmt.bufPrint(&path_buf, "/proc/{d}/environ", .{pid}) catch return null;

    const file = std.fs.openFileAbsolute(path, .{}) catch return null;
    defer file.close();

    var buf: [32768]u8 = undefined;
    const n = file.readAll(&buf) catch return null;
    const content = buf[0..n];

    const needle = "SEANCE_PANEL_ID=";

    // environ is null-delimited
    var it = std.mem.splitScalar(u8, content, 0);
    while (it.next()) |env_var| {
        if (std.mem.startsWith(u8, env_var, needle)) {
            const val = env_var[needle.len..];
            return std.fmt.parseInt(u64, val, 10) catch null;
        }
    }

    return null;
}

fn isExcluded(port: u16) bool {
    for (excluded_ports) |ep| {
        if (port == ep) return true;
    }
    return false;
}

fn isDuplicate(ports: []const u16, port: u16) bool {
    for (ports) |p| {
        if (p == port) return true;
    }
    return false;
}

pub fn sortPorts(ports: []u16) void {
    // Simple insertion sort (max 16 elements)
    var i: usize = 1;
    while (i < ports.len) : (i += 1) {
        const key = ports[i];
        var j: usize = i;
        while (j > 0 and ports[j - 1] > key) : (j -= 1) {
            ports[j] = ports[j - 1];
        }
        ports[j] = key;
    }
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

test "parseTcpLine: valid LISTEN line" {
    // sl  local_address          rem_address            st  tx:rx              tr:tm       retrnsmt  uid  timeout inode
    const line = "   0: 0100007F:1F90 00000000:0000 0A 00000000:00000000 00:00000000 00000000     0        0 12345 1 0000000000000000 100 0 0 10 0";
    const result = parseTcpLine(line);
    try std.testing.expect(result != null);
    try std.testing.expectEqual(@as(u16, 8080), result.?.port); // 0x1F90 = 8080
    try std.testing.expectEqual(@as(u64, 12345), result.?.inode);
}

test "parseTcpLine: non-LISTEN state returns null" {
    // State 01 = ESTABLISHED, not 0A = LISTEN
    const line = "   1: 0100007F:1F90 0100007F:D034 01 00000000:00000000 00:00000000 00000000     0        0 67890 1 0000000000000000 100 0 0 10 0";
    try std.testing.expect(parseTcpLine(line) == null);
}

test "parseTcpLine: zero inode returns null" {
    const line = "   0: 0100007F:1F90 00000000:0000 0A 00000000:00000000 00:00000000 00000000     0        0 0 1 0000000000000000 100 0 0 10 0";
    try std.testing.expect(parseTcpLine(line) == null);
}

test "parseTcpLine: malformed line returns null" {
    try std.testing.expect(parseTcpLine("") == null);
    try std.testing.expect(parseTcpLine("not a tcp line at all") == null);
    try std.testing.expect(parseTcpLine("   0:") == null);
}

test "parseTcpLine: port 80 (0050)" {
    const line = "   0: 00000000:0050 00000000:0000 0A 00000000:00000000 00:00000000 00000000     0        0 99999 1 0000000000000000 100 0 0 10 0";
    const result = parseTcpLine(line);
    try std.testing.expect(result != null);
    try std.testing.expectEqual(@as(u16, 80), result.?.port); // 0x0050 = 80
}

test "sortPorts: sorts in ascending order" {
    var ports = [_]u16{ 8080, 443, 80, 3000 };
    sortPorts(&ports);
    try std.testing.expectEqual(@as(u16, 80), ports[0]);
    try std.testing.expectEqual(@as(u16, 443), ports[1]);
    try std.testing.expectEqual(@as(u16, 3000), ports[2]);
    try std.testing.expectEqual(@as(u16, 8080), ports[3]);
}

test "sortPorts: already sorted is unchanged" {
    var ports = [_]u16{ 80, 443, 8080 };
    sortPorts(&ports);
    try std.testing.expectEqual(@as(u16, 80), ports[0]);
    try std.testing.expectEqual(@as(u16, 443), ports[1]);
    try std.testing.expectEqual(@as(u16, 8080), ports[2]);
}

test "sortPorts: single element and empty" {
    var single = [_]u16{42};
    sortPorts(&single);
    try std.testing.expectEqual(@as(u16, 42), single[0]);

    var empty: [0]u16 = .{};
    sortPorts(&empty); // should not crash
}

test "sortPorts: reverse order" {
    var ports = [_]u16{ 9000, 8000, 7000, 6000, 5000 };
    sortPorts(&ports);
    try std.testing.expectEqual(@as(u16, 5000), ports[0]);
    try std.testing.expectEqual(@as(u16, 9000), ports[4]);
}

test "isDuplicate: present and absent" {
    const ports = [_]u16{ 80, 443, 8080 };
    try std.testing.expect(isDuplicate(&ports, 443));
    try std.testing.expect(!isDuplicate(&ports, 3000));
}

test "isDuplicate: empty slice" {
    const empty: [0]u16 = .{};
    try std.testing.expect(!isDuplicate(&empty, 80));
}

test "isExcluded: standard excluded ports" {
    try std.testing.expect(isExcluded(22));   // SSH
    try std.testing.expect(isExcluded(53));   // DNS
    try std.testing.expect(isExcluded(631));  // CUPS
    try std.testing.expect(isExcluded(5353)); // mDNS
}

test "isExcluded: non-excluded ports" {
    try std.testing.expect(!isExcluded(80));
    try std.testing.expect(!isExcluded(8080));
    try std.testing.expect(!isExcluded(3000));
    try std.testing.expect(!isExcluded(0));
}
