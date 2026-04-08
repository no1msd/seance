const std = @import("std");
const builtin = @import("builtin");
const c = @import("c.zig").c;
const config_mod = @import("config.zig");

const is_linux = builtin.os.tag == .linux;

pub const SoundPlayer = struct {
    ca_ctx: if (is_linux) ?*c.ca_context else void = if (is_linux) null else {},
    last_play_time: i64 = 0,

    const min_interval_ms = 500;

    pub fn init() SoundPlayer {
        if (!is_linux) return .{};

        var ctx: ?*c.ca_context = null;
        if (c.ca_context_create(&ctx) == 0) {
            if (ctx) |context| {
                _ = c.ca_context_change_props(
                    context,
                    c.CA_PROP_APPLICATION_NAME,
                    "seance",
                    c.CA_PROP_APPLICATION_ID,
                    "seance",
                    @as(?*const u8, null),
                );
            }
            return .{ .ca_ctx = ctx };
        }
        return .{};
    }

    pub fn deinit(self: *SoundPlayer) void {
        if (!is_linux) return;
        if (self.ca_ctx) |ctx| {
            c.ca_context_destroy(ctx);
            self.ca_ctx = null;
        }
    }

    pub fn play(self: *SoundPlayer) void {
        const cfg = config_mod.get();
        self.playSound(cfg.notification_sound);
    }

    pub fn playSound(self: *SoundPlayer, sound: config_mod.NotificationSound) void {
        if (!is_linux) return;
        switch (sound) {
            .none => {},
            .default, .bell, .dialog_warning, .complete => self.playThrottledEvent(sound),
            .custom => |cust| self.playThrottledCustom(cust.path[0..cust.path_len]),
        }
    }

    /// Play a sound immediately, bypassing throttle. Used for sound preview in settings.
    pub fn playPreview(self: *SoundPlayer, sound: config_mod.NotificationSound) void {
        if (!is_linux) return;
        switch (sound) {
            .none => {},
            .default => self.playEventId("message-new-instant", "Notification"),
            .bell => self.playEventId("bell", "Terminal bell"),
            .dialog_warning => self.playEventId("dialog-warning", "Warning"),
            .complete => self.playEventId("complete", "Complete"),
            .custom => |cust| self.playCustom(cust.path[0..cust.path_len]),
        }
    }

    fn playThrottledEvent(self: *SoundPlayer, sound: config_mod.NotificationSound) void {
        const now = std.time.milliTimestamp();
        if (now - self.last_play_time < min_interval_ms) return;
        self.last_play_time = now;

        switch (sound) {
            .default => self.playEventId("message-new-instant", "Notification"),
            .bell => self.playEventId("bell", "Terminal bell"),
            .dialog_warning => self.playEventId("dialog-warning", "Warning"),
            .complete => self.playEventId("complete", "Complete"),
            else => {},
        }
    }

    fn playThrottledCustom(self: *SoundPlayer, path: []const u8) void {
        const now = std.time.milliTimestamp();
        if (now - self.last_play_time < min_interval_ms) return;
        self.last_play_time = now;
        self.playCustom(path);
    }

    fn playEventId(self: *SoundPlayer, event_id: [*:0]const u8, description: [*:0]const u8) void {
        const ctx = self.ca_ctx orelse return;
        var proplist: ?*c.ca_proplist = null;
        if (c.ca_proplist_create(&proplist) != 0) return;
        defer _ = c.ca_proplist_destroy(proplist);
        const pl = proplist orelse return;

        _ = c.ca_proplist_sets(pl, c.CA_PROP_EVENT_ID, event_id);
        _ = c.ca_proplist_sets(pl, c.CA_PROP_EVENT_DESCRIPTION, description);
        _ = c.ca_context_play_full(ctx, 0, pl, null, null);
    }

    fn playCustom(self: *SoundPlayer, path: []const u8) void {
        if (path.len == 0) return;
        const ctx = self.ca_ctx orelse return;
        var proplist: ?*c.ca_proplist = null;
        if (c.ca_proplist_create(&proplist) != 0) return;
        defer _ = c.ca_proplist_destroy(proplist);
        const pl = proplist orelse return;

        var path_z: [257]u8 = undefined;
        const len = @min(path.len, path_z.len - 1);
        @memcpy(path_z[0..len], path[0..len]);
        path_z[len] = 0;

        _ = c.ca_proplist_sets(pl, c.CA_PROP_MEDIA_FILENAME, @ptrCast(&path_z));
        _ = c.ca_proplist_sets(pl, c.CA_PROP_EVENT_DESCRIPTION, "Terminal notification");
        _ = c.ca_context_play_full(ctx, 0, pl, null, null);
    }
};
