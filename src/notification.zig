const std = @import("std");

pub const Notification = struct {
    pane_id: u64,
    workspace_id: u64,
    pane_group_id: u64,
    title: [256]u8 = [_]u8{0} ** 256,
    title_len: usize = 0,
    subtitle: [256]u8 = [_]u8{0} ** 256,
    subtitle_len: usize = 0,
    body: [512]u8 = [_]u8{0} ** 512,
    body_len: usize = 0,
    timestamp: i64,
    read: bool = false,

    pub fn getTitle(self: *const Notification) []const u8 {
        return self.title[0..self.title_len];
    }

    pub fn getSubtitle(self: *const Notification) []const u8 {
        return self.subtitle[0..self.subtitle_len];
    }

    pub fn getBody(self: *const Notification) []const u8 {
        return self.body[0..self.body_len];
    }

    pub fn setTitle(self: *Notification, text: []const u8) void {
        const len = @min(text.len, self.title.len);
        @memcpy(self.title[0..len], text[0..len]);
        self.title_len = len;
    }

    pub fn setSubtitle(self: *Notification, text: []const u8) void {
        const len = @min(text.len, self.subtitle.len);
        @memcpy(self.subtitle[0..len], text[0..len]);
        self.subtitle_len = len;
    }

    pub fn setBody(self: *Notification, text: []const u8) void {
        const len = @min(text.len, self.body.len);
        @memcpy(self.body[0..len], text[0..len]);
        self.body_len = len;
    }
};

pub const NotificationStore = struct {
    items: [100]?Notification = [_]?Notification{null} ** 100,
    head: usize = 0,
    count: usize = 0,

    pub fn push(self: *NotificationStore, notif: Notification) void {
        self.items[self.head] = notif;
        self.head = (self.head + 1) % self.items.len;
        if (self.count < self.items.len) {
            self.count += 1;
        }
    }

    pub fn unreadCount(self: *const NotificationStore) usize {
        var n: usize = 0;
        for (0..self.count) |i| {
            const idx = self.ringIndex(i);
            if (self.items[idx]) |item| {
                if (!item.read) n += 1;
            }
        }
        return n;
    }

    pub fn unreadForWorkspace(self: *const NotificationStore, ws_id: u64) usize {
        var n: usize = 0;
        for (0..self.count) |i| {
            const idx = self.ringIndex(i);
            if (self.items[idx]) |item| {
                if (!item.read and item.workspace_id == ws_id) n += 1;
            }
        }
        return n;
    }

    pub fn markAllRead(self: *NotificationStore, ws_id: u64) void {
        for (0..self.count) |i| {
            const idx = self.ringIndex(i);
            if (self.items[idx]) |*item| {
                if (item.workspace_id == ws_id) item.read = true;
            }
        }
    }

    pub fn mostRecentUnread(self: *const NotificationStore) ?*const Notification {
        if (self.count == 0) return null;
        // Iterate from newest to oldest
        var i: usize = self.count;
        while (i > 0) {
            i -= 1;
            const idx = self.ringIndex(i);
            if (self.items[idx]) |*item| {
                if (!item.read) return item;
            }
        }
        return null;
    }

    /// Return the latest notification for a workspace, prioritizing unread.
    /// Falls back to the latest read notification if no unread exist (seance behavior).
    pub fn latestForWorkspace(self: *const NotificationStore, ws_id: u64) ?*const Notification {
        if (self.count == 0) return null;
        var latest_any: ?*const Notification = null;
        // Iterate from newest to oldest
        var i: usize = self.count;
        while (i > 0) {
            i -= 1;
            const idx = self.ringIndex(i);
            if (self.items[idx]) |*item| {
                if (item.workspace_id == ws_id) {
                    if (!item.read) return item; // Unread found — return immediately
                    if (latest_any == null) latest_any = item; // Track latest (any status)
                }
            }
        }
        return latest_any;
    }

    /// Get notification by logical index (0 = newest, count-1 = oldest).
    pub fn getByIndex(self: *NotificationStore, index: usize) ?*Notification {
        if (index >= self.count) return null;
        // Map display index (0=newest) to ring offset (count-1=newest)
        const offset = self.count - 1 - index;
        const idx = self.ringIndex(offset);
        if (self.items[idx]) |*item| return item else return null;
    }

    /// Remove notification at logical index (0 = newest).
    pub fn removeAt(self: *NotificationStore, index: usize) void {
        if (index >= self.count) return;
        const offset = self.count - 1 - index;
        // Shift items to fill the gap: move items at offset+1..count-1 down by one
        var i: usize = offset;
        while (i + 1 < self.count) : (i += 1) {
            const dst = self.ringIndex(i);
            const src = self.ringIndex(i + 1);
            self.items[dst] = self.items[src];
        }
        // Clear the last slot (was newest before shift)
        const last = self.ringIndex(self.count - 1);
        self.items[last] = null;
        self.count -= 1;
        // Adjust head: the newest slot was vacated, so head retreats by one.
        self.head = (self.head + self.items.len - 1) % self.items.len;
    }

    /// Remove all notifications whose workspace_id matches.
    pub fn removeForWorkspace(self: *NotificationStore, workspace_id: u64) usize {
        return self.removeMatching(.workspace, workspace_id);
    }

    /// Remove all notifications whose pane_id matches.
    pub fn removeForPane(self: *NotificationStore, pane_id: u64) usize {
        return self.removeMatching(.pane, pane_id);
    }

    const MatchKind = enum { workspace, pane };

    fn removeMatching(self: *NotificationStore, kind: MatchKind, id: u64) usize {
        if (self.count == 0) return 0;
        // Collect surviving items into a temporary array, then copy back.
        var survivors: [100]Notification = undefined;
        var survivor_count: usize = 0;
        var removed: usize = 0;
        for (0..self.count) |i| {
            const idx = self.ringIndex(i);
            if (self.items[idx]) |item| {
                const matches = switch (kind) {
                    .workspace => item.workspace_id == id,
                    .pane => item.pane_id == id,
                };
                if (matches) {
                    removed += 1;
                } else {
                    survivors[survivor_count] = item;
                    survivor_count += 1;
                }
            }
        }
        if (removed == 0) return 0;
        // Reset and repopulate
        for (0..self.items.len) |i| self.items[i] = null;
        self.head = 0;
        self.count = 0;
        for (0..survivor_count) |i| {
            self.items[self.head] = survivors[i];
            self.head = (self.head + 1) % self.items.len;
            self.count += 1;
        }
        return removed;
    }

    /// Remove all notifications.
    pub fn clearAll(self: *NotificationStore) void {
        for (0..self.items.len) |i| {
            self.items[i] = null;
        }
        self.head = 0;
        self.count = 0;
    }

    fn ringIndex(self: *const NotificationStore, offset: usize) usize {
        // offset 0 = oldest, offset count-1 = newest
        // General formula that works whether the ring has wrapped or not.
        return (self.head + self.items.len - self.count + offset) % self.items.len;
    }
};

pub const NotificationCenter = struct {
    store: NotificationStore = .{},
    ctx: ?*anyopaque = null, // WindowState pointer (opaque to avoid circular import)
    suppress_focus_clear: bool = false, // set during notification-panel jump to prevent clearing all pane notifications

    // Callbacks (wired by window.zig during init)
    on_sidebar_refresh: ?*const fn (*anyopaque) void = null,
    on_play_sound: ?*const fn (*anyopaque) void = null,
    on_pane_notify: ?*const fn (*anyopaque, bool) void = null,
    on_pane_trigger_flash: ?*const fn (*anyopaque) void = null,
    on_tab_badge_update: ?*const fn (*anyopaque, u64, bool) void = null,
    on_desktop_notify: ?*const fn ([*:0]const u8, [*:0]const u8) void = null,
    on_find_pane: ?*const fn (*anyopaque, u64) ?*anyopaque = null,
    on_check_visible: ?*const fn (*anyopaque, u64, u64) Visibility = null,
    on_clear_ws_visuals: ?*const fn (*anyopaque) void = null,

    pub const Visibility = struct { visible: bool, in_active_group: bool };

    pub const EmitOptions = struct {
        title: []const u8 = "Notification",
        subtitle: []const u8 = "",
        body: []const u8 = "",
        pane_id: u64,
        workspace_id: u64,
        pane_group_id: u64 = 0,
        play_sound: bool = true,
        flash: bool = true,
        desktop_notify: bool = true,
        check_visibility: bool = true,
    };

    /// Central notification creation. ALL notification sources call this.
    pub fn emit(self: *NotificationCenter, opts: EmitOptions) void {
        const ctx = self.ctx orelse return;

        // 1. Visibility check — skip if pane is currently focused
        var vis: Visibility = .{ .visible = false, .in_active_group = false };
        if (opts.check_visibility) {
            if (self.on_check_visible) |cb| {
                vis = cb(ctx, opts.pane_id, opts.workspace_id);
                if (vis.visible) return;
            }
        }

        // 2. Create and push Notification to store
        var notif = Notification{
            .pane_id = opts.pane_id,
            .workspace_id = opts.workspace_id,
            .pane_group_id = opts.pane_group_id,
            .timestamp = std.time.timestamp(),
            .read = false,
        };
        notif.setTitle(opts.title);
        notif.setSubtitle(opts.subtitle);
        notif.setBody(opts.body);
        self.store.push(notif);

        // 3. Mark pane as unread + CSS
        if (self.on_find_pane) |find| {
            if (find(ctx, opts.pane_id)) |pane_ptr| {
                if (self.on_pane_notify) |cb| cb(pane_ptr, true);
                // 4. Trigger flash
                if (opts.flash) {
                    if (self.on_pane_trigger_flash) |cb| cb(pane_ptr);
                }
            }
        }

        // 5. Tab badge
        if (self.on_tab_badge_update) |cb| cb(ctx, opts.pane_id, true);

        // 6. Sidebar
        if (self.on_sidebar_refresh) |cb| cb(ctx);

        // 7. Sound
        if (opts.play_sound) {
            if (self.on_play_sound) |cb| cb(ctx);
        }

        // 8. Desktop notification (libnotify) — only if not in active group
        if (opts.desktop_notify and !vis.in_active_group) {
            if (self.on_desktop_notify) |cb| {
                var title_z: [257]u8 = undefined;
                const tlen = @min(opts.title.len, title_z.len - 1);
                @memcpy(title_z[0..tlen], opts.title[0..tlen]);
                title_z[tlen] = 0;

                // Build combined body: subtitle + body
                var body_z: [770]u8 = undefined;
                var bpos: usize = 0;
                if (opts.subtitle.len > 0) {
                    const slen = @min(opts.subtitle.len, 256);
                    @memcpy(body_z[bpos..][0..slen], opts.subtitle[0..slen]);
                    bpos += slen;
                    if (opts.body.len > 0) {
                        body_z[bpos] = '\n';
                        bpos += 1;
                    }
                }
                if (opts.body.len > 0) {
                    const blen = @min(opts.body.len, 512);
                    @memcpy(body_z[bpos..][0..blen], opts.body[0..blen]);
                    bpos += blen;
                }
                body_z[bpos] = 0;

                cb(@ptrCast(title_z[0..tlen :0]), @ptrCast(body_z[0..bpos :0]));
            }
        }
    }

    /// Central clearing for a pane (called on focus). Handles store, CSS, tab badge, sidebar.
    pub fn clearForPane(self: *NotificationCenter, pane_id: u64, pane_ptr: ?*anyopaque) void {
        const ctx = self.ctx orelse return;
        _ = self.store.removeForPane(pane_id);

        // Clear pane CSS
        if (pane_ptr) |pp| {
            if (self.on_pane_notify) |cb| cb(pp, false);
        }

        // Clear tab badge
        if (self.on_tab_badge_update) |cb| cb(ctx, pane_id, false);

        // Refresh sidebar
        if (self.on_sidebar_refresh) |cb| cb(ctx);
    }

    /// Mark all notifications read for a workspace + clear pane/tab visuals + refresh UI.
    pub fn markWorkspaceRead(self: *NotificationCenter, ws_id: u64, ws_ptr: *anyopaque) void {
        const ctx = self.ctx orelse return;
        self.store.markAllRead(ws_id);
        if (self.on_clear_ws_visuals) |cb| cb(ws_ptr);
        if (self.on_sidebar_refresh) |cb| cb(ctx);
    }

    /// Clear all notifications globally + refresh UI.
    pub fn clearAll(self: *NotificationCenter) void {
        const ctx = self.ctx orelse return;
        self.store.clearAll();
        if (self.on_sidebar_refresh) |cb| cb(ctx);
    }
};

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

const testing = std.testing;

fn makeTestNotif(pane_id: u64, ws_id: u64) Notification {
    return .{ .pane_id = pane_id, .workspace_id = ws_id, .pane_group_id = 0, .timestamp = @intCast(pane_id) };
}

fn makeTestNotifRead(pane_id: u64, ws_id: u64) Notification {
    var n = makeTestNotif(pane_id, ws_id);
    n.read = true;
    return n;
}

// --- NotificationStore: push / getByIndex ---

test "NotificationStore: push and getByIndex ordering" {
    var store = NotificationStore{};
    store.push(makeTestNotif(1, 10));
    store.push(makeTestNotif(2, 10));
    store.push(makeTestNotif(3, 10));

    try testing.expectEqual(@as(usize, 3), store.count);
    try testing.expectEqual(@as(u64, 3), store.getByIndex(0).?.pane_id); // newest
    try testing.expectEqual(@as(u64, 2), store.getByIndex(1).?.pane_id);
    try testing.expectEqual(@as(u64, 1), store.getByIndex(2).?.pane_id); // oldest
    try testing.expect(store.getByIndex(3) == null);
}

test "NotificationStore: push past capacity evicts oldest" {
    var store = NotificationStore{};
    for (0..100) |i| store.push(makeTestNotif(@intCast(i), 1));
    try testing.expectEqual(@as(usize, 100), store.count);
    try testing.expectEqual(@as(u64, 99), store.getByIndex(0).?.pane_id);
    try testing.expectEqual(@as(u64, 0), store.getByIndex(99).?.pane_id);

    // Push one more — item 0 evicted
    store.push(makeTestNotif(100, 1));
    try testing.expectEqual(@as(usize, 100), store.count);
    try testing.expectEqual(@as(u64, 100), store.getByIndex(0).?.pane_id);
    try testing.expectEqual(@as(u64, 1), store.getByIndex(99).?.pane_id);
}

test "NotificationStore: full scan after multiple wraps" {
    var store = NotificationStore{};
    // Push 250 items — wraps twice
    for (0..250) |i| store.push(makeTestNotif(@intCast(i), 1));
    try testing.expectEqual(@as(usize, 100), store.count);
    // Buffer should contain items 150..249
    for (0..100) |i| {
        const expected: u64 = 249 - @as(u64, @intCast(i));
        try testing.expectEqual(expected, store.getByIndex(i).?.pane_id);
    }
}

// --- unreadCount / markAllRead ---

test "NotificationStore: unreadCount and markAllRead" {
    var store = NotificationStore{};
    store.push(makeTestNotif(1, 10)); // unread, ws 10
    store.push(makeTestNotifRead(2, 10)); // read, ws 10
    store.push(makeTestNotif(3, 20)); // unread, ws 20
    store.push(makeTestNotif(4, 10)); // unread, ws 10

    try testing.expectEqual(@as(usize, 3), store.unreadCount());
    try testing.expectEqual(@as(usize, 2), store.unreadForWorkspace(10));
    try testing.expectEqual(@as(usize, 1), store.unreadForWorkspace(20));

    store.markAllRead(10);
    try testing.expectEqual(@as(usize, 1), store.unreadCount());
    try testing.expectEqual(@as(usize, 0), store.unreadForWorkspace(10));
    try testing.expectEqual(@as(usize, 1), store.unreadForWorkspace(20));
}

// --- removeAt ---

test "NotificationStore: removeAt from non-full buffer" {
    var store = NotificationStore{};
    store.push(makeTestNotif(1, 1));
    store.push(makeTestNotif(2, 1));
    store.push(makeTestNotif(3, 1));

    store.removeAt(1); // remove middle (pane_id=2)
    try testing.expectEqual(@as(usize, 2), store.count);
    try testing.expectEqual(@as(u64, 3), store.getByIndex(0).?.pane_id);
    try testing.expectEqual(@as(u64, 1), store.getByIndex(1).?.pane_id);
}

test "NotificationStore: removeAt newest from wrapped buffer" {
    var store = NotificationStore{};
    for (0..105) |i| store.push(makeTestNotif(@intCast(i), 1));
    // Contains items 5..104
    store.removeAt(0); // remove 104
    try testing.expectEqual(@as(usize, 99), store.count);
    try testing.expectEqual(@as(u64, 103), store.getByIndex(0).?.pane_id);
    try testing.expectEqual(@as(u64, 5), store.getByIndex(98).?.pane_id);
}

test "NotificationStore: removeAt oldest from wrapped buffer" {
    var store = NotificationStore{};
    for (0..105) |i| store.push(makeTestNotif(@intCast(i), 1));
    store.removeAt(99); // remove oldest (5)
    try testing.expectEqual(@as(usize, 99), store.count);
    try testing.expectEqual(@as(u64, 104), store.getByIndex(0).?.pane_id);
    try testing.expectEqual(@as(u64, 6), store.getByIndex(98).?.pane_id);
}

test "NotificationStore: removeAt middle from wrapped buffer" {
    var store = NotificationStore{};
    for (0..105) |i| store.push(makeTestNotif(@intCast(i), 1));
    // Item at index 50 has pane_id 104-50=54
    try testing.expectEqual(@as(u64, 54), store.getByIndex(50).?.pane_id);
    store.removeAt(50);
    try testing.expectEqual(@as(usize, 99), store.count);
    try testing.expectEqual(@as(u64, 104), store.getByIndex(0).?.pane_id);
    try testing.expectEqual(@as(u64, 5), store.getByIndex(98).?.pane_id);
    // Neighbors of removed item shifted
    try testing.expectEqual(@as(u64, 55), store.getByIndex(49).?.pane_id);
    try testing.expectEqual(@as(u64, 53), store.getByIndex(50).?.pane_id);
}

test "NotificationStore: full scan after removeAt from wrapped buffer" {
    var store = NotificationStore{};
    for (0..105) |i| store.push(makeTestNotif(@intCast(i), 1));
    store.removeAt(0); // remove 104
    // Should be 103, 102, ..., 5
    for (0..99) |i| {
        const expected: u64 = 103 - @as(u64, @intCast(i));
        try testing.expectEqual(expected, store.getByIndex(i).?.pane_id);
    }
}

test "NotificationStore: push after removeAt from non-full buffer" {
    var store = NotificationStore{};
    store.push(makeTestNotif(1, 1));
    store.push(makeTestNotif(2, 1));
    store.push(makeTestNotif(3, 1));
    store.removeAt(0); // remove newest (3)
    store.push(makeTestNotif(10, 1));
    try testing.expectEqual(@as(usize, 3), store.count);
    try testing.expectEqual(@as(u64, 10), store.getByIndex(0).?.pane_id);
    try testing.expectEqual(@as(u64, 2), store.getByIndex(1).?.pane_id);
    try testing.expectEqual(@as(u64, 1), store.getByIndex(2).?.pane_id);
}

test "NotificationStore: push after removeAt from wrapped buffer" {
    var store = NotificationStore{};
    for (0..105) |i| store.push(makeTestNotif(@intCast(i), 1));
    store.removeAt(0); // remove 104
    store.push(makeTestNotif(200, 1));
    try testing.expectEqual(@as(usize, 100), store.count);
    try testing.expectEqual(@as(u64, 200), store.getByIndex(0).?.pane_id);
    try testing.expectEqual(@as(u64, 5), store.getByIndex(99).?.pane_id);
}

test "NotificationStore: multiple removeAt from wrapped buffer" {
    var store = NotificationStore{};
    for (0..105) |i| store.push(makeTestNotif(@intCast(i), 1));
    store.removeAt(0); // remove 104
    store.removeAt(0); // remove 103
    store.removeAt(0); // remove 102
    try testing.expectEqual(@as(usize, 97), store.count);
    try testing.expectEqual(@as(u64, 101), store.getByIndex(0).?.pane_id);
    try testing.expectEqual(@as(u64, 5), store.getByIndex(96).?.pane_id);
}

// --- removeForWorkspace / removeForPane ---

test "NotificationStore: removeForWorkspace preserves order" {
    var store = NotificationStore{};
    store.push(makeTestNotif(1, 10));
    store.push(makeTestNotif(2, 20));
    store.push(makeTestNotif(3, 10));
    store.push(makeTestNotif(4, 20));
    store.push(makeTestNotif(5, 30));

    const removed = store.removeForWorkspace(20);
    try testing.expectEqual(@as(usize, 2), removed);
    try testing.expectEqual(@as(usize, 3), store.count);
    try testing.expectEqual(@as(u64, 5), store.getByIndex(0).?.pane_id);
    try testing.expectEqual(@as(u64, 3), store.getByIndex(1).?.pane_id);
    try testing.expectEqual(@as(u64, 1), store.getByIndex(2).?.pane_id);
}

test "NotificationStore: removeForWorkspace from wrapped buffer" {
    var store = NotificationStore{};
    for (0..105) |i| {
        store.push(makeTestNotif(@intCast(i), if (i % 2 == 0) @as(u64, 10) else @as(u64, 20)));
    }
    const removed = store.removeForWorkspace(10);
    try testing.expect(removed > 0);
    for (0..store.count) |i| {
        try testing.expectEqual(@as(u64, 20), store.getByIndex(i).?.workspace_id);
    }
}

test "NotificationStore: removeForPane" {
    var store = NotificationStore{};
    store.push(makeTestNotif(1, 10));
    store.push(makeTestNotif(2, 10));
    store.push(makeTestNotif(1, 20)); // same pane_id=1 as first
    const removed = store.removeForPane(1);
    try testing.expectEqual(@as(usize, 2), removed);
    try testing.expectEqual(@as(usize, 1), store.count);
    try testing.expectEqual(@as(u64, 2), store.getByIndex(0).?.pane_id);
}

// --- latestForWorkspace ---

test "NotificationStore: latestForWorkspace returns newest unread" {
    var store = NotificationStore{};
    store.push(makeTestNotif(1, 10));
    store.push(makeTestNotifRead(2, 10));
    store.push(makeTestNotif(3, 10));
    try testing.expectEqual(@as(u64, 3), store.latestForWorkspace(10).?.pane_id);
}

test "NotificationStore: latestForWorkspace falls back to newest read" {
    var store = NotificationStore{};
    store.push(makeTestNotifRead(1, 10));
    store.push(makeTestNotifRead(2, 10));
    store.push(makeTestNotif(3, 20)); // different ws
    try testing.expectEqual(@as(u64, 2), store.latestForWorkspace(10).?.pane_id);
}

test "NotificationStore: latestForWorkspace prefers old unread over newer read" {
    var store = NotificationStore{};
    store.push(makeTestNotif(1, 10)); // older unread
    store.push(makeTestNotifRead(2, 10)); // newer read
    try testing.expectEqual(@as(u64, 1), store.latestForWorkspace(10).?.pane_id);
}

test "NotificationStore: latestForWorkspace null for unknown workspace" {
    var store = NotificationStore{};
    try testing.expect(store.latestForWorkspace(10) == null);
    store.push(makeTestNotif(1, 20));
    try testing.expect(store.latestForWorkspace(10) == null);
}

// --- mostRecentUnread ---

test "NotificationStore: mostRecentUnread" {
    var store = NotificationStore{};
    store.push(makeTestNotif(1, 10));
    store.push(makeTestNotifRead(2, 20));
    store.push(makeTestNotif(3, 30));
    try testing.expectEqual(@as(u64, 3), store.mostRecentUnread().?.pane_id);
}

test "NotificationStore: mostRecentUnread null when all read" {
    var store = NotificationStore{};
    store.push(makeTestNotifRead(1, 10));
    try testing.expect(store.mostRecentUnread() == null);
}

// --- clearAll ---

test "NotificationStore: clearAll" {
    var store = NotificationStore{};
    for (0..50) |i| store.push(makeTestNotif(@intCast(i), 1));
    store.clearAll();
    try testing.expectEqual(@as(usize, 0), store.count);
    try testing.expect(store.getByIndex(0) == null);
}

