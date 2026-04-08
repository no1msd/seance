const std = @import("std");

/// Fixed-capacity buffer for deferring a single error message as a
/// null-terminated string.  Used by config and session loading so errors
/// can be shown in a banner after window creation.
pub fn ErrorBuf(comptime overflow_msg: []const u8) type {
    return struct {
        // +1 reserves space for the sentinel null byte
        buf: [capacity + 1]u8 = [_]u8{0} ** (capacity + 1),
        len: usize = 0,

        const Self = @This();
        const capacity = 512;

        pub fn get(self: *Self) ?[*:0]const u8 {
            if (self.len == 0) return null;
            self.buf[self.len] = 0;
            return @ptrCast(&self.buf);
        }

        pub fn clear(self: *Self) void {
            self.len = 0;
        }

        pub fn set(self: *Self, comptime fmt: []const u8, args: anytype) void {
            const result = std.fmt.bufPrint(self.buf[0..capacity], fmt, args) catch {
                @memcpy(self.buf[0..overflow_msg.len], overflow_msg);
                self.len = overflow_msg.len;
                return;
            };
            self.len = result.len;
        }
    };
}
