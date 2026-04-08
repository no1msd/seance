const std = @import("std");

pub const OscNotification = struct {
    /// Title slice (points into Scanner.buf). Null for OSC 9 / body-only notifications.
    title: ?[]const u8,
    /// Body slice (points into Scanner.buf). Always present.
    body: []const u8,
};

/// Stateful byte-by-byte scanner that detects OSC 9, OSC 99, and OSC 777
/// notification sequences in a terminal data stream.
///
/// Usage: call `feed()` for each byte of PTY output. When a complete
/// notification OSC is found, `feed()` returns the parsed notification.
/// The returned slices point into the scanner's internal buffer and are
/// only valid until the next call to `feed()` that transitions out of
/// the `osc_body` state.
pub const Scanner = struct {
    state: State = .normal,
    buf: [2048]u8 = undefined,
    buf_len: usize = 0,
    osc_num: u32 = 0,

    const State = enum {
        normal,
        esc,
        osc_num_start,
        osc_body,
        osc_body_esc,
    };

    /// Feed a single byte. Returns a notification when a complete
    /// OSC 9/99/777 sequence has been received, or null otherwise.
    pub fn feed(self: *Scanner, byte: u8) ?OscNotification {
        switch (self.state) {
            .normal => {
                if (byte == 0x1b) {
                    self.state = .esc;
                }
                return null;
            },
            .esc => {
                if (byte == ']') {
                    self.state = .osc_num_start;
                    self.osc_num = 0;
                    self.buf_len = 0;
                } else {
                    self.state = .normal;
                }
                return null;
            },
            .osc_num_start => {
                if (byte >= '0' and byte <= '9') {
                    self.osc_num = self.osc_num *| 10 +| @as(u32, byte - '0');
                    return null;
                } else if (byte == ';') {
                    if (self.osc_num == 9 or self.osc_num == 99 or self.osc_num == 777) {
                        self.state = .osc_body;
                    } else {
                        self.state = .normal;
                    }
                    return null;
                } else {
                    self.state = .normal;
                    return null;
                }
            },
            .osc_body => {
                if (byte == 0x07) { // BEL terminator
                    self.state = .normal;
                    return self.parseNotification();
                } else if (byte == 0x1b) {
                    self.state = .osc_body_esc;
                    return null;
                } else if (byte < 0x20 and byte != '\t') {
                    // Other C0 controls (except TAB) shouldn't appear in OSC body;
                    // treat as malformed — discard accumulated data.
                    self.state = .normal;
                    return null;
                } else {
                    if (self.buf_len < self.buf.len) {
                        self.buf[self.buf_len] = byte;
                        self.buf_len += 1;
                    }
                    return null;
                }
            },
            .osc_body_esc => {
                if (byte == '\\') { // ST (String Terminator)
                    self.state = .normal;
                    return self.parseNotification();
                } else {
                    // Not a valid ST; include ESC in buffer and re-evaluate byte
                    if (self.buf_len < self.buf.len) {
                        self.buf[self.buf_len] = 0x1b;
                        self.buf_len += 1;
                    }
                    // If this byte is another ESC, stay in esc state within body
                    if (byte == 0x1b) {
                        // Remain in osc_body_esc
                        return null;
                    }
                    if (self.buf_len < self.buf.len) {
                        self.buf[self.buf_len] = byte;
                        self.buf_len += 1;
                    }
                    self.state = .osc_body;
                    return null;
                }
            },
        }
    }

    fn parseNotification(self: *Scanner) ?OscNotification {
        if (self.buf_len == 0) return null;
        const data = self.buf[0..self.buf_len];
        return switch (self.osc_num) {
            9 => parseOsc9(data),
            99 => parseOsc99(data),
            777 => parseOsc777(data),
            else => null,
        };
    }

    /// Parse OSC 9: plain text notification.
    /// Filters out ConEmu-style sub-commands (e.g. `4;0;` for progress)
    /// which start with a digit followed by a semicolon.
    fn parseOsc9(data: []const u8) ?OscNotification {
        if (data.len >= 2 and data[0] >= '0' and data[0] <= '9' and data[1] == ';') {
            return null;
        }
        return .{ .title = null, .body = data };
    }

    /// Parse OSC 777: `notify;title;body`
    fn parseOsc777(data: []const u8) ?OscNotification {
        const first_semi = std.mem.indexOfScalar(u8, data, ';') orelse
            return .{ .title = null, .body = data };
        const cmd = data[0..first_semi];
        if (!std.mem.eql(u8, cmd, "notify")) return null;

        const rest = data[first_semi + 1 ..];
        if (rest.len == 0) return null;

        const second_semi = std.mem.indexOfScalar(u8, rest, ';');
        if (second_semi) |idx| {
            return .{
                .title = rest[0..idx],
                .body = rest[idx + 1 ..],
            };
        } else {
            // Only title, no body — use title as body too
            return .{ .title = null, .body = rest };
        }
    }

    /// Parse OSC 99: `metadata;body`
    /// The first semicolon separates colon-delimited metadata (key=value pairs)
    /// from the body. No semicolon means no body.
    fn parseOsc99(data: []const u8) ?OscNotification {
        const semi = std.mem.indexOfScalar(u8, data, ';') orelse return null;
        const body = data[semi + 1 ..];
        if (body.len == 0) return null;
        return .{ .title = null, .body = body };
    }
};

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

test "OSC 9: simple notification" {
    var s = Scanner{};
    const input = "\x1b]9;Build completed\x07";
    var result: ?OscNotification = null;
    for (input) |byte| {
        if (s.feed(byte)) |n| result = n;
    }
    try std.testing.expect(result != null);
    try std.testing.expectEqualStrings("Build completed", result.?.body);
    try std.testing.expect(result.?.title == null);
}

test "OSC 9: ST terminator" {
    var s = Scanner{};
    const input = "\x1b]9;Hello world\x1b\\";
    var result: ?OscNotification = null;
    for (input) |byte| {
        if (s.feed(byte)) |n| result = n;
    }
    try std.testing.expect(result != null);
    try std.testing.expectEqualStrings("Hello world", result.?.body);
}

test "OSC 777: notify with title and body" {
    var s = Scanner{};
    const input = "\x1b]777;notify;Build;Build completed successfully\x07";
    var result: ?OscNotification = null;
    for (input) |byte| {
        if (s.feed(byte)) |n| result = n;
    }
    try std.testing.expect(result != null);
    try std.testing.expectEqualStrings("Build", result.?.title.?);
    try std.testing.expectEqualStrings("Build completed successfully", result.?.body);
}

test "OSC 777: notify without body (title only)" {
    var s = Scanner{};
    const input = "\x1b]777;notify;Done\x07";
    var result: ?OscNotification = null;
    for (input) |byte| {
        if (s.feed(byte)) |n| result = n;
    }
    try std.testing.expect(result != null);
    try std.testing.expect(result.?.title == null);
    try std.testing.expectEqualStrings("Done", result.?.body);
}

test "OSC 777: non-notify subcommand is ignored" {
    var s = Scanner{};
    const input = "\x1b]777;container;name;mycontainer\x07";
    var result: ?OscNotification = null;
    for (input) |byte| {
        if (s.feed(byte)) |n| result = n;
    }
    try std.testing.expect(result == null);
}

test "OSC 99: simple body" {
    var s = Scanner{};
    const input = "\x1b]99;i=1:d=0;Build finished\x07";
    var result: ?OscNotification = null;
    for (input) |byte| {
        if (s.feed(byte)) |n| result = n;
    }
    try std.testing.expect(result != null);
    try std.testing.expectEqualStrings("Build finished", result.?.body);
}

test "OSC 99: no body separator means no payload" {
    var s = Scanner{};
    // No semicolon in data after "99;" — entire string is metadata, no body
    const input = "\x1b]99;Hello\x07";
    var result: ?OscNotification = null;
    for (input) |byte| {
        if (s.feed(byte)) |n| result = n;
    }
    try std.testing.expect(result == null);
}

test "OSC 99: empty metadata with bare body" {
    var s = Scanner{};
    // Empty metadata before first semicolon, body follows
    const input = "\x1b]99;;Hello\x07";
    var result: ?OscNotification = null;
    for (input) |byte| {
        if (s.feed(byte)) |n| result = n;
    }
    try std.testing.expect(result != null);
    try std.testing.expectEqualStrings("Hello", result.?.body);
}

test "non-notification OSC is ignored" {
    var s = Scanner{};
    const input = "\x1b]0;window title\x07";
    var result: ?OscNotification = null;
    for (input) |byte| {
        if (s.feed(byte)) |n| result = n;
    }
    try std.testing.expect(result == null);
}

test "interleaved normal data and OSC" {
    var s = Scanner{};
    const input = "hello\x1b]9;Alert\x07world";
    var result: ?OscNotification = null;
    for (input) |byte| {
        if (s.feed(byte)) |n| result = n;
    }
    try std.testing.expect(result != null);
    try std.testing.expectEqualStrings("Alert", result.?.body);
}

test "partial sequence across calls" {
    var s = Scanner{};
    const part1 = "\x1b]9;Hel";
    const part2 = "lo\x07";
    var result: ?OscNotification = null;
    for (part1) |byte| {
        if (s.feed(byte)) |n| result = n;
    }
    try std.testing.expect(result == null);
    for (part2) |byte| {
        if (s.feed(byte)) |n| result = n;
    }
    try std.testing.expect(result != null);
    try std.testing.expectEqualStrings("Hello", result.?.body);
}

test "OSC 9: ConEmu progress sub-command is ignored" {
    var s = Scanner{};
    const input = "\x1b]9;4;0;\x07";
    var result: ?OscNotification = null;
    for (input) |byte| {
        if (s.feed(byte)) |n| result = n;
    }
    try std.testing.expect(result == null);
}

test "empty body is ignored" {
    var s = Scanner{};
    const input = "\x1b]9;\x07";
    var result: ?OscNotification = null;
    for (input) |byte| {
        if (s.feed(byte)) |n| result = n;
    }
    try std.testing.expect(result == null);
}

test "multiple notifications in sequence" {
    var s = Scanner{};
    var count: usize = 0;
    var last_body: []const u8 = "";
    const input = "\x1b]9;First\x07some junk\x1b]9;Second\x07";
    for (input) |byte| {
        if (s.feed(byte)) |n| {
            count += 1;
            last_body = n.body;
        }
    }
    try std.testing.expectEqual(@as(usize, 2), count);
    try std.testing.expectEqualStrings("Second", last_body);
}

test "C0 control character in body aborts sequence" {
    var s = Scanner{};
    // \x01 (SOH) is a C0 control that should abort the OSC
    const input = "\x1b]9;he\x01llo\x07";
    var result: ?OscNotification = null;
    for (input) |byte| {
        if (s.feed(byte)) |n| result = n;
    }
    try std.testing.expect(result == null);
}

test "tab character in body is preserved" {
    var s = Scanner{};
    const input = "\x1b]9;col1\tcol2\x07";
    var result: ?OscNotification = null;
    for (input) |byte| {
        if (s.feed(byte)) |n| result = n;
    }
    try std.testing.expect(result != null);
    try std.testing.expectEqualStrings("col1\tcol2", result.?.body);
}

test "buffer overflow: body truncated at 2048 bytes" {
    var s = Scanner{};
    // Start OSC 9
    for ("\x1b]9;") |byte| _ = s.feed(byte);
    // Feed exactly 2048 + 100 bytes of body
    for (0..2148) |_| _ = s.feed('A');
    // Terminate
    const result = s.feed(0x07);
    try std.testing.expect(result != null);
    try std.testing.expectEqual(@as(usize, 2048), result.?.body.len);
}

test "ESC in body not followed by backslash is buffered" {
    var s = Scanner{};
    // ESC followed by 'x' in body — should include ESC and 'x' in body
    const input = "\x1b]9;ab\x1bxcd\x07";
    var result: ?OscNotification = null;
    for (input) |byte| {
        if (s.feed(byte)) |n| result = n;
    }
    try std.testing.expect(result != null);
    try std.testing.expectEqualStrings("ab\x1bxcd", result.?.body);
}

test "OSC 99: first semicolon splits metadata from body" {
    var s = Scanner{};
    // Per spec: first ';' in data separates metadata from payload.
    // metadata = "i=1", body = "d=0;p=1"
    const input = "\x1b]99;i=1;d=0;p=1\x07";
    var result: ?OscNotification = null;
    for (input) |byte| {
        if (s.feed(byte)) |n| result = n;
    }
    try std.testing.expect(result != null);
    try std.testing.expectEqualStrings("d=0;p=1", result.?.body);
}

test "OSC 99: body containing semicolons is preserved" {
    var s = Scanner{};
    // metadata = "i=1:d=0", body = "line1;line2;line3"
    const input = "\x1b]99;i=1:d=0;line1;line2;line3\x07";
    var result: ?OscNotification = null;
    for (input) |byte| {
        if (s.feed(byte)) |n| result = n;
    }
    try std.testing.expect(result != null);
    try std.testing.expectEqualStrings("line1;line2;line3", result.?.body);
}

test "OSC 99: metadata only (no body) returns null" {
    var s = Scanner{};
    // No semicolon after metadata — no body
    const input = "\x1b]99;i=1:d=0\x07";
    var result: ?OscNotification = null;
    for (input) |byte| {
        if (s.feed(byte)) |n| result = n;
    }
    try std.testing.expect(result == null);
}
