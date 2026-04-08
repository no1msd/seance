const std = @import("std");
const c = @import("c.zig").c;
const Pane = @import("pane.zig").Pane;

pub const SearchOverlay = struct {
    container: *c.GtkWidget, // horizontal box with search widgets
    entry: *c.GtkWidget, // GtkSearchEntry
    prev_button: *c.GtkWidget,
    next_button: *c.GtkWidget,
    close_button: *c.GtkWidget,
    match_label: *c.GtkWidget, // label for match status
    pane: *Pane,
    is_visible: bool = false,
    search_total: isize = 0,
    search_selected: isize = 0,

    pub fn create(pane: *Pane) SearchOverlay {
        // Outer container: horizontal box
        const hbox = c.gtk_box_new(c.GTK_ORIENTATION_HORIZONTAL, 4);
        c.gtk_widget_add_css_class(hbox, "search-overlay");
        c.gtk_widget_set_halign(hbox, c.GTK_ALIGN_END);
        c.gtk_widget_set_valign(hbox, c.GTK_ALIGN_START);
        c.gtk_widget_set_margin_top(hbox, 4);
        c.gtk_widget_set_margin_end(hbox, 4);

        // Search entry
        const entry = c.gtk_search_entry_new();
        c.gtk_widget_set_size_request(entry, 200, -1);
        c.gtk_widget_add_css_class(entry, "search-entry");
        c.gtk_box_append(@ptrCast(hbox), entry);

        // Previous button
        const prev_btn = c.gtk_button_new_with_label("\xe2\x97\x82"); // ◂
        c.gtk_widget_add_css_class(@ptrCast(prev_btn), "flat");
        c.gtk_widget_set_tooltip_text(@ptrCast(prev_btn), "Previous match (Shift+Enter)");
        c.gtk_widget_set_size_request(@ptrCast(prev_btn), 28, 28);
        c.gtk_box_append(@ptrCast(hbox), @ptrCast(prev_btn));

        // Next button
        const next_btn = c.gtk_button_new_with_label("\xe2\x96\xb8"); // ▸
        c.gtk_widget_add_css_class(@ptrCast(next_btn), "flat");
        c.gtk_widget_set_tooltip_text(@ptrCast(next_btn), "Next match (Enter)");
        c.gtk_widget_set_size_request(@ptrCast(next_btn), 28, 28);
        c.gtk_box_append(@ptrCast(hbox), @ptrCast(next_btn));

        // Match status label
        const label = c.gtk_label_new("");
        c.gtk_widget_add_css_class(label, "search-match-label");
        c.gtk_widget_set_size_request(label, 80, -1);
        c.gtk_box_append(@ptrCast(hbox), label);

        // Close button
        const close_btn = c.gtk_button_new_with_label("\xc3\x97"); // ×
        c.gtk_widget_add_css_class(@ptrCast(close_btn), "flat");
        c.gtk_widget_set_tooltip_text(@ptrCast(close_btn), "Close (Escape)");
        c.gtk_box_append(@ptrCast(hbox), @ptrCast(close_btn));

        // Hide by default
        c.gtk_widget_set_visible(hbox, 0);

        // Connect signals with pane pointer as user_data.
        _ = c.g_signal_connect_data(
            @as(c.gpointer, @ptrCast(entry)),
            "search-changed",
            @as(c.GCallback, @ptrCast(&onSearchChanged)),
            @ptrCast(pane),
            null,
            0,
        );

        _ = c.g_signal_connect_data(
            @as(c.gpointer, @ptrCast(entry)),
            "activate",
            @as(c.GCallback, @ptrCast(&onActivate)),
            @ptrCast(pane),
            null,
            0,
        );

        _ = c.g_signal_connect_data(
            @as(c.gpointer, @ptrCast(prev_btn)),
            "clicked",
            @as(c.GCallback, @ptrCast(&onPrevClicked)),
            @ptrCast(pane),
            null,
            0,
        );

        _ = c.g_signal_connect_data(
            @as(c.gpointer, @ptrCast(next_btn)),
            "clicked",
            @as(c.GCallback, @ptrCast(&onNextClicked)),
            @ptrCast(pane),
            null,
            0,
        );

        _ = c.g_signal_connect_data(
            @as(c.gpointer, @ptrCast(close_btn)),
            "clicked",
            @as(c.GCallback, @ptrCast(&onCloseClicked)),
            @ptrCast(pane),
            null,
            0,
        );

        // Key controller on the entry for Escape and Shift+Enter
        const key_ctrl = c.gtk_event_controller_key_new();
        _ = c.g_signal_connect_data(
            @as(c.gpointer, @ptrCast(key_ctrl)),
            "key-pressed",
            @as(c.GCallback, @ptrCast(&onEntryKeyPress)),
            @ptrCast(pane),
            null,
            0,
        );
        c.gtk_widget_add_controller(entry, @ptrCast(key_ctrl));

        return SearchOverlay{
            .container = hbox,
            .entry = entry,
            .prev_button = @ptrCast(prev_btn),
            .next_button = @ptrCast(next_btn),
            .close_button = @ptrCast(close_btn),
            .match_label = label,
            .pane = pane,
        };
    }

    pub fn show(self: *SearchOverlay) void {
        self.is_visible = true;
        c.gtk_widget_set_visible(self.container, 1);
        _ = c.gtk_widget_grab_focus(self.entry);
    }

    pub fn hide(self: *SearchOverlay) void {
        self.is_visible = false;
        c.gtk_widget_set_visible(self.container, 0);
        c.gtk_editable_set_text(@ptrCast(self.entry), "");
        c.gtk_label_set_text(@ptrCast(self.match_label), "");
        self.search_total = 0;
        self.search_selected = 0;
        // Tell ghostty to end the search and clear highlights
        if (self.pane.surface) |s| {
            _ = c.ghostty_surface_binding_action(s, "end_search", 10);
        }
        // Return focus to GLArea
        if (self.pane.gl_area) |gl| {
            _ = c.gtk_widget_grab_focus(@as(*c.GtkWidget, @ptrCast(gl)));
        }
    }

    pub fn toggle(self: *SearchOverlay) void {
        if (self.is_visible) {
            self.hide();
        } else {
            self.show();
        }
    }

    pub fn findNext(self: *SearchOverlay) void {
        if (self.pane.surface) |s| {
            _ = c.ghostty_surface_binding_action(s, "navigate_search:next", 20);
        }
    }

    pub fn findPrev(self: *SearchOverlay) void {
        if (self.pane.surface) |s| {
            _ = c.ghostty_surface_binding_action(s, "navigate_search:previous", 24);
        }
    }

    pub fn setSearchFromSelection(self: *SearchOverlay) void {
        if (self.pane.surface) |s| {
            _ = c.ghostty_surface_binding_action(s, "search_selection", 16);
        }
        if (!self.is_visible) self.show();
    }

    pub fn updateMatchLabel(self: *SearchOverlay) void {
        if (self.search_total <= 0) {
            c.gtk_label_set_text(@ptrCast(self.match_label), "No matches");
            return;
        }
        // Ghostty's selected is 0-based from bottom; invert to 1-based from top
        const current = self.search_total - self.search_selected;
        if (current < 1 or current > self.search_total) {
            c.gtk_label_set_text(@ptrCast(self.match_label), "");
            return;
        }
        var buf: [64]u8 = undefined;
        if (std.fmt.bufPrintZ(&buf, "{d}/{d}", .{ current, self.search_total })) |text| {
            c.gtk_label_set_text(@ptrCast(self.match_label), text);
        } else |_| {}
    }
};

// Signal callbacks

fn onSearchChanged(entry: *c.GtkSearchEntry, user_data: c.gpointer) callconv(.c) void {
    const pane: *Pane = @ptrCast(@alignCast(user_data));
    const surface = pane.surface orelse return;
    const text = c.gtk_editable_get_text(@ptrCast(entry));
    const needle = if (text != null) std.mem.span(text) else "";
    if (needle.len == 0) {
        // Empty search — end any active search
        _ = c.ghostty_surface_binding_action(surface, "end_search", 10);
        c.gtk_label_set_text(@ptrCast(pane.search_overlay.match_label), "");
        return;
    }
    // Build "search:<needle>" action string
    var buf: [512]u8 = undefined;
    if (std.fmt.bufPrintZ(&buf, "search:{s}", .{needle})) |action_str| {
        _ = c.ghostty_surface_binding_action(surface, action_str.ptr, action_str.len);
    } else |_| {}
    // Navigate to nearest match so ghostty sends back total/selected counts
    pane.search_overlay.findNext();
}

fn onActivate(_: *c.GtkSearchEntry, user_data: c.gpointer) callconv(.c) void {
    const pane: *Pane = @ptrCast(@alignCast(user_data));
    pane.search_overlay.findNext();
}

fn onPrevClicked(_: *c.GtkButton, user_data: c.gpointer) callconv(.c) void {
    const pane: *Pane = @ptrCast(@alignCast(user_data));
    pane.search_overlay.findNext();
}

fn onNextClicked(_: *c.GtkButton, user_data: c.gpointer) callconv(.c) void {
    const pane: *Pane = @ptrCast(@alignCast(user_data));
    pane.search_overlay.findPrev();
}

fn onCloseClicked(_: *c.GtkButton, user_data: c.gpointer) callconv(.c) void {
    const pane: *Pane = @ptrCast(@alignCast(user_data));
    pane.search_overlay.hide();
}

fn onEntryKeyPress(
    _: *c.GtkEventControllerKey,
    keyval: c.guint,
    _: c.guint,
    gdk_state: c.GdkModifierType,
    user_data: c.gpointer,
) callconv(.c) c.gboolean {
    const pane: *Pane = @ptrCast(@alignCast(user_data));
    const shift = (gdk_state & c.GDK_SHIFT_MASK) != 0;

    if (keyval == c.GDK_KEY_Escape) {
        pane.search_overlay.hide();
        return 1;
    }

    // Shift+Enter = previous match
    if (keyval == c.GDK_KEY_Return and shift) {
        pane.search_overlay.findPrev();
        return 1;
    }

    return 0;
}
