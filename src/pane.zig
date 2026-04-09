const std = @import("std");
const c = @import("c.zig").c;
const config_mod = @import("config.zig");
const SearchOverlay = @import("search_overlay.zig").SearchOverlay;
const ghostty_bridge = @import("ghostty_bridge.zig");
const opengl = @import("gl.zig");

pub const Pane = struct {
    pub const cwd_cap = 512;

    id: u64,
    workspace_id: u64,
    pane_group_id: u64,
    surface: c.ghostty_surface_t = null,
    gl_area: ?*c.GtkGLArea = null,
    widget: *c.GtkWidget, // outer wrapper box (for CSS border)
    cwd: [cwd_cap]u8 = [_]u8{0} ** cwd_cap,
    cwd_len: usize = 0,
    has_unread: bool = false,

    search_overlay: SearchOverlay = undefined,
    flash_step: u8 = 0,
    flash_timeout: c.guint = 0,
    notif_border_timeout: c.guint = 0,
    // IME state
    im_context: ?*c.GtkIMContext = null,
    im_composing: bool = false,
    im_buf: [32]u8 = undefined,
    im_len: usize = 0,
    in_keyevent: bool = false,
    surface_initialized: bool = false,
    pending_init_width: u32 = 0,
    pending_init_height: u32 = 0,
    // Cached terminal title (updated via ghostty SET_TITLE action)
    cached_title: [256]u8 = [_]u8{0} ** 256,
    cached_title_len: usize = 0,
    // User-assigned custom title (overrides cached_title for tab display)
    custom_title: [256]u8 = [_]u8{0} ** 256,
    custom_title_len: usize = 0,
    // Shell integration metadata (reported via socket)
    shell_git_branch: [128]u8 = [_]u8{0} ** 128,
    shell_git_branch_len: usize = 0,
    shell_git_dirty: bool = false,
    shell_state: ShellState = .unknown,
    // Vim detection (updated by periodic check)
    is_vim_active: bool = false,
    // Scrollbar overlay state (updated via ghostty SCROLLBAR action)
    scrollbar_widget: ?*c.GtkWidget = null,
    scrollbar_total: u64 = 0,
    scrollbar_offset: u64 = 0,
    scrollbar_len: u64 = 0,
    scrollbar_visible: bool = false,
    scrollbar_hide_timeout: c.guint = 0,
    title_refresh_timeout: c.guint = 0,
    /// Animation progress for appearing/disappearing in stacked mode.
    /// 0.0 = fully hidden (scale 50%, opacity 0), 1.0 = fully visible.
    stacked_open_anim: f64 = 1.0,
    /// True when this pane is animating out during a stacked→tabbed transition.
    stacked_closing: bool = false,
    /// Animated y position as fraction of available column height (0.0–1.0).
    stacked_frac_y: f64 = 0.0,
    /// Animated height as fraction of available column height.
    stacked_frac_h: f64 = 1.0,
    /// Horizontal pixel offset applied during layout; used when a panel
    /// moves between columns. Starts at (old_screen_x - new_screen_x)
    /// and lerps toward 0 each frame.
    stacked_offset_x: f64 = 0.0,
    /// Relative height weight for stacked layout. Default 1.0 gives equal
    /// distribution. Higher weight = taller pane relative to siblings.
    height_weight: f64 = 1.0,
    // Scrollback replay file path (set during session restore, consumed by initSurface)
    replay_scrollback_path: [256:0]u8 = [_:0]u8{0} ** 256,

    pub const ShellState = enum { unknown, prompt, running };

    pub fn create(alloc: std.mem.Allocator, cwd_z: ?[*:0]const u8, workspace_id: u64, pane_group_id: u64) !*Pane {
        const pane_id = nextId();

        // Create GLArea for ghostty rendering
        const gl_area_widget = c.gtk_gl_area_new();
        const gl_area: *c.GtkGLArea = @ptrCast(gl_area_widget);
        c.gtk_gl_area_set_has_depth_buffer(gl_area, 0);
        c.gtk_gl_area_set_has_stencil_buffer(gl_area, 0);
        c.gtk_gl_area_set_auto_render(gl_area, 0);
        // Ghostty requires desktop OpenGL (not OpenGL ES) — match ghostty's
        // own GTK apprt which uses allowed-apis: gl in the surface blueprint.
        c.gtk_gl_area_set_allowed_apis(gl_area, c.GDK_GL_API_GL);
        c.gtk_widget_set_hexpand(gl_area_widget, 1);
        c.gtk_widget_set_vexpand(gl_area_widget, 1);
        c.gtk_widget_set_focusable(gl_area_widget, 1);
        c.gtk_widget_set_focus_on_click(gl_area_widget, 1);

        // Widget hierarchy: wrapper box > overlay > gl_area
        const overlay = c.gtk_overlay_new();
        c.gtk_overlay_set_child(@ptrCast(overlay), gl_area_widget);
        c.gtk_widget_set_hexpand(overlay, 1);
        c.gtk_widget_set_vexpand(overlay, 1);

        const wrapper = c.gtk_box_new(c.GTK_ORIENTATION_VERTICAL, 0);
        c.gtk_box_append(@ptrCast(wrapper), overlay);
        c.gtk_widget_set_hexpand(wrapper, 1);
        c.gtk_widget_set_vexpand(wrapper, 1);
        c.gtk_widget_add_css_class(wrapper, "pane-unfocused");
        c.gtk_widget_set_cursor_from_name(gl_area_widget, "text");

        // Initialize pane struct
        const pane = try alloc.create(Pane);
        pane.* = .{
            .id = pane_id,
            .workspace_id = workspace_id,
            .pane_group_id = pane_group_id,
            .gl_area = gl_area,
            .widget = wrapper,
        };
        c.g_object_set_data(@as(*c.GObject, @ptrCast(gl_area_widget)), "seance-pane", @ptrCast(pane));

        // Weak pointer: when gl_area is finalized (e.g. after
        // adw_tab_view_close_page disposes the wrapper chain), pane.gl_area
        // is atomically set to NULL.  disconnectSignals then becomes a
        // safe no-op in the programmatic-close path, where destroy() runs
        // after the tab page has already been disposed.
        c.g_object_add_weak_pointer(
            @as(*c.GObject, @ptrCast(gl_area_widget)),
            @ptrCast(&pane.gl_area),
        );

        if (cwd_z) |dir| {
            const dir_slice = std.mem.sliceTo(dir, 0);
            const len = @min(dir_slice.len, pane.cwd.len);
            @memcpy(pane.cwd[0..len], dir_slice[0..len]);
            pane.cwd_len = len;
        }

        // GLArea signals
        connectSignal(gl_area, "realize", &onGlRealize, pane);
        connectSignal(gl_area, "unrealize", &onGlUnrealize, pane);
        connectSignal(gl_area, "render", &onGlRender, pane);
        connectSignal(gl_area, "resize", &onGlResize, pane);

        // Input controllers (key, IME, motion, click, scroll, focus)
        setupInputControllers(gl_area_widget, pane);

        // Overlay widgets (focus bar, search, scrollbar)
        setupOverlays(overlay, pane);

        // File drop target
        setupDropTarget(pane);

        return pane;
    }

    /// Disconnect signal handlers on the gl_area so GTK won't fire
    /// callbacks into this pane after it is freed or the widget is
    /// finalized. Safe to call multiple times, and safe to call after
    /// the gl_area has already been finalized (the weak pointer added
    /// in create() will have nulled self.gl_area in that case).
    pub fn disconnectSignals(self: *Pane) void {
        if (self.gl_area) |gl| {
            // Remove our weak pointer so a later finalization of gl_area
            // (in paths where the widget outlives this call) doesn't try
            // to write to &self.gl_area after self has been freed.
            c.g_object_remove_weak_pointer(
                @as(*c.GObject, @ptrCast(gl)),
                @ptrCast(&self.gl_area),
            );
            c.g_object_set_data(@as(*c.GObject, @ptrCast(gl)), "seance-pane", null);
            _ = c.g_signal_handlers_disconnect_matched(
                @as(c.gpointer, @ptrCast(gl)),
                c.G_SIGNAL_MATCH_DATA,
                0,
                0,
                null,
                null,
                @as(c.gpointer, @ptrCast(self)),
            );
            self.gl_area = null;
        }
    }

    pub fn destroy(self: *Pane, alloc: std.mem.Allocator) void {
        if (self.notif_border_timeout != 0) {
            _ = c.g_source_remove(self.notif_border_timeout);
            self.notif_border_timeout = 0;
        }
        if (self.flash_timeout != 0) {
            _ = c.g_source_remove(self.flash_timeout);
        }
        if (self.scrollbar_hide_timeout != 0) {
            _ = c.g_source_remove(self.scrollbar_hide_timeout);
            self.scrollbar_hide_timeout = 0;
        }
        if (self.title_refresh_timeout != 0) {
            _ = c.g_source_remove(self.title_refresh_timeout);
            self.title_refresh_timeout = 0;
        }
        self.disconnectSignals();
        if (self.surface) |s| {
            c.ghostty_surface_free(s);
            self.surface = null;
        }
        if (self.im_context) |ctx| {
            c.g_object_unref(@ptrCast(ctx));
            self.im_context = null;
        }
        alloc.destroy(self);
    }

    pub fn getCwd(self: *Pane) ?[]const u8 {
        if (self.cwd_len > 0) return self.cwd[0..self.cwd_len];
        return null;
    }

    /// Copy the pane's CWD into `buf` as a null-terminated string.
    pub fn cwdZ(self: *const Pane, buf: *[cwd_cap + 1]u8) ?[*:0]const u8 {
        if (self.cwd_len == 0) return null;
        @memcpy(buf[0..self.cwd_len], self.cwd[0..self.cwd_len]);
        buf[self.cwd_len] = 0;
        return @ptrCast(buf);
    }

    pub fn focus(self: *Pane) void {
        if (self.gl_area) |gl| {
            _ = c.gtk_widget_grab_focus(@as(*c.GtkWidget, @ptrCast(gl)));
        }
        c.gtk_widget_remove_css_class(self.widget, "pane-unfocused");
        c.gtk_widget_add_css_class(self.widget, "pane-focused");

        if (self.surface) |s| {
            c.ghostty_surface_set_focus(s, true);
        }

        if (self.has_unread) {
            const Window = @import("window.zig");
            if (Window.window_manager) |wm| {
                if (wm.findByWorkspaceId(self.workspace_id)) |state| {
                    if (!state.notif_center.suppress_focus_clear) {
                        state.notif_center.clearForPane(self.id, @ptrCast(self));
                    }
                }
            }
        } else {
            c.gtk_widget_remove_css_class(self.widget, "pane-notification");
        }
    }

    pub fn unfocus(self: *Pane) void {
        c.gtk_widget_remove_css_class(self.widget, "pane-focused");
        if (self.surface) |s| {
            c.ghostty_surface_set_focus(s, false);
        }
        if (self.has_unread) {
            c.gtk_widget_add_css_class(self.widget, "pane-notification");
        } else {
            c.gtk_widget_add_css_class(self.widget, "pane-unfocused");
        }
    }

    pub fn clearScrollback(self: *Pane) void {
        if (self.surface) |s| {
            // Send clear screen escape sequences through ghostty
            const seq = "\x1b[H\x1b[2J\x1b[3J";
            c.ghostty_surface_text(s, seq, seq.len);
        }
    }

    pub fn updateScrollbar(self: *Pane, total: u64, offset: u64, len: u64) void {
        self.scrollbar_total = total;
        self.scrollbar_offset = offset;
        self.scrollbar_len = len;

        const has_scrollback = total > len;
        const at_bottom = (offset + len) >= total;

        if (has_scrollback and !at_bottom) {
            // Show scrollbar and reset hide timer
            if (!self.scrollbar_visible) {
                self.scrollbar_visible = true;
                if (self.scrollbar_widget) |w| c.gtk_widget_set_visible(w, 1);
            }
            // Reset auto-hide timeout
            if (self.scrollbar_hide_timeout != 0) {
                _ = c.g_source_remove(self.scrollbar_hide_timeout);
                self.scrollbar_hide_timeout = 0;
            }
        } else if (has_scrollback and at_bottom) {
            // At bottom with scrollback: briefly show then auto-hide
            if (!self.scrollbar_visible) {
                self.scrollbar_visible = true;
                if (self.scrollbar_widget) |w| c.gtk_widget_set_visible(w, 1);
            }
            if (self.scrollbar_hide_timeout != 0) {
                _ = c.g_source_remove(self.scrollbar_hide_timeout);
            }
            self.scrollbar_hide_timeout = c.g_timeout_add(800, @ptrCast(&scrollbarHideTimeoutCb), @ptrCast(self));
        } else {
            // No scrollback content — hide immediately
            self.scrollbar_visible = false;
            if (self.scrollbar_widget) |w| c.gtk_widget_set_visible(w, 0);
        }

        // Redraw the scrollbar
        if (self.scrollbar_widget) |w| c.gtk_widget_queue_draw(w);
    }

    pub fn notify(self: *Pane) void {
        self.has_unread = true;
        c.gtk_widget_remove_css_class(self.widget, "pane-unfocused");
        c.gtk_widget_add_css_class(self.widget, "pane-notification");
    }

    pub fn checkVimStatus(self: *Pane) bool {
        // Vim detection requires child PID which ghostty manages internally.
        // For now, maintain current state (detected via shell integration reports).
        _ = self;
        return false;
    }

    pub fn triggerFlash(self: *Pane) void {
        if (self.flash_timeout != 0) {
            _ = c.g_source_remove(self.flash_timeout);
            self.flash_timeout = 0;
        }
        c.gtk_widget_remove_css_class(self.widget, "pane-flash");
        self.flash_step = 0;
        advanceFlash(self);
    }

    /// Queue a GL redraw on this pane's GLArea.
    pub fn queueRedraw(self: *Pane) void {
        if (self.gl_area) |gl| {
            c.gtk_gl_area_queue_render(gl);
        }
    }

    /// Schedule a deferred render after GTK layout completes.
    /// Useful after reparenting (e.g., split) to ensure the pane gets rendered.
    pub fn queueDeferredRedraw(self: *Pane) void {
        _ = c.g_idle_add(deferredRedrawCb, @ptrCast(self));
    }

    pub fn getCachedTitle(self: *const Pane) ?[]const u8 {
        if (self.cached_title_len == 0) return null;
        return self.cached_title[0..self.cached_title_len];
    }

    /// Returns the display title for this pane: custom title if set, otherwise cached terminal title.
    pub fn getDisplayTitle(self: *const Pane) ?[]const u8 {
        if (self.custom_title_len > 0) return self.custom_title[0..self.custom_title_len];
        return self.getCachedTitle();
    }

    pub fn setCustomTitle(self: *Pane, title: []const u8) void {
        const len = @min(title.len, self.custom_title.len);
        @memcpy(self.custom_title[0..len], title[0..len]);
        self.custom_title_len = len;
    }

    pub fn clearCustomTitle(self: *Pane) void {
        self.custom_title_len = 0;
    }

    /// Update CWD from ghostty PWD action.  Returns true if the value changed.
    pub fn updateCwd(self: *Pane, pwd: []const u8) bool {
        const len = @min(pwd.len, self.cwd.len);
        if (len == self.cwd_len and std.mem.eql(u8, self.cwd[0..len], pwd[0..len]))
            return false;
        @memcpy(self.cwd[0..len], pwd[0..len]);
        self.cwd_len = len;
        return true;
    }

    /// Write text to the terminal PTY (as if typed).
    pub fn writeInput(self: *Pane, text: []const u8) void {
        if (self.surface) |s| {
            c.ghostty_surface_text(s, text.ptr, text.len);
        }
    }
};

// ── Pane.create() helpers ──────────────────────────────────────────

fn connectSignal(source: anytype, signal: [*:0]const u8, handler: anytype, data: anytype) void {
    _ = c.g_signal_connect_data(
        @as(c.gpointer, @ptrCast(source)),
        signal,
        @as(c.GCallback, @ptrCast(handler)),
        @as(c.gpointer, @ptrCast(data)),
        null,
        0,
    );
}

fn setupInputControllers(gl_area_widget: *c.GtkWidget, pane: *Pane) void {
    // Key controller
    const key_ctrl = c.gtk_event_controller_key_new();
    connectSignal(key_ctrl, "key-pressed", &onKeyPressed, pane);
    connectSignal(key_ctrl, "key-released", &onKeyReleased, pane);
    c.gtk_widget_add_controller(gl_area_widget, @ptrCast(key_ctrl));

    // IME context
    const im_context = c.gtk_im_multicontext_new();
    pane.im_context = @ptrCast(im_context);
    connectSignal(im_context, "commit", &onImCommit, pane);
    connectSignal(im_context, "preedit-start", &onImPreeditStart, pane);
    connectSignal(im_context, "preedit-changed", &onImPreeditChanged, pane);
    connectSignal(im_context, "preedit-end", &onImPreeditEnd, pane);

    // Motion controller
    const motion_ctrl = c.gtk_event_controller_motion_new();
    connectSignal(motion_ctrl, "motion", &onMouseMotion, pane);
    connectSignal(motion_ctrl, "enter", &onMouseEnter, pane);
    c.gtk_widget_add_controller(gl_area_widget, @ptrCast(motion_ctrl));

    // Click gesture
    const click_ctrl = c.gtk_gesture_click_new();
    c.gtk_gesture_single_set_button(@ptrCast(click_ctrl), 0); // all buttons
    connectSignal(click_ctrl, "pressed", &onMousePress, pane);
    connectSignal(click_ctrl, "released", &onMouseRelease, pane);
    c.gtk_widget_add_controller(gl_area_widget, @ptrCast(click_ctrl));

    // Scroll controller
    const scroll_ctrl = c.gtk_event_controller_scroll_new(
        c.GTK_EVENT_CONTROLLER_SCROLL_BOTH_AXES | c.GTK_EVENT_CONTROLLER_SCROLL_DISCRETE,
    );
    connectSignal(scroll_ctrl, "scroll", &onScroll, pane);
    c.gtk_widget_add_controller(gl_area_widget, @ptrCast(scroll_ctrl));

    // Focus controller
    const focus_ctrl = c.gtk_event_controller_focus_new();
    connectSignal(focus_ctrl, "enter", &onFocusEnter, pane);
    c.gtk_widget_add_controller(gl_area_widget, @ptrCast(focus_ctrl));
}

fn setupOverlays(overlay: *c.GtkWidget, pane: *Pane) void {
    // Focus-indicator bar (accent bar at top edge, driven by CSS)
    const focus_bar = c.gtk_box_new(c.GTK_ORIENTATION_HORIZONTAL, 0);
    c.gtk_widget_set_valign(focus_bar, c.GTK_ALIGN_START);
    c.gtk_widget_set_hexpand(focus_bar, 1);
    c.gtk_widget_set_size_request(focus_bar, -1, 3);
    c.gtk_widget_set_can_target(focus_bar, 0);
    c.gtk_widget_set_can_focus(focus_bar, 0);
    c.gtk_widget_add_css_class(focus_bar, "pane-focus-bar");
    c.gtk_overlay_add_overlay(@ptrCast(overlay), focus_bar);

    // Search overlay
    pane.search_overlay = SearchOverlay.create(pane);
    c.gtk_overlay_add_overlay(@ptrCast(overlay), pane.search_overlay.container);

    // Scrollbar overlay (thin drawing area on the right edge)
    const scrollbar_da = c.gtk_drawing_area_new();
    c.gtk_widget_set_can_target(scrollbar_da, 0);
    c.gtk_widget_set_can_focus(scrollbar_da, 0);
    c.gtk_widget_set_halign(scrollbar_da, c.GTK_ALIGN_END);
    c.gtk_widget_set_valign(scrollbar_da, c.GTK_ALIGN_FILL);
    c.gtk_widget_set_size_request(scrollbar_da, 8, -1);
    c.gtk_widget_set_visible(scrollbar_da, 0);
    c.gtk_drawing_area_set_draw_func(
        @ptrCast(scrollbar_da),
        @ptrCast(&drawScrollbarCb),
        @ptrCast(pane),
        null,
    );
    c.gtk_overlay_add_overlay(@ptrCast(overlay), scrollbar_da);
    pane.scrollbar_widget = scrollbar_da;
}

// ── GLArea callbacks ────────────────────────────────────────────────

fn deferredRedrawCb(user_data: c.gpointer) callconv(.c) c.gboolean {
    const pane: *Pane = @ptrCast(@alignCast(user_data));
    if (pane.surface != null) {
        pane.queueRedraw();
    }
    return c.G_SOURCE_REMOVE;
}

fn onGlRealize(_: *c.GtkGLArea, user_data: c.gpointer) callconv(.c) void {
    const pane: *Pane = @ptrCast(@alignCast(user_data));
    const gl_area = pane.gl_area orelse return;

    std.log.debug("pane {d}: onGlRealize", .{pane.id});

    c.gtk_gl_area_make_current(gl_area);
    if (c.gtk_gl_area_get_error(gl_area)) |gl_err| {
        const msg: [*c]const u8 = gl_err.*.message orelse "unknown";
        std.log.err("pane {d}: GL context error on realize: {s}", .{ pane.id, msg });
        return;
    }

    // If the surface already exists (reparenting — not first creation),
    // reinitialize the renderer's GPU resources for the new GL context.
    if (pane.surface) |s| {
        if (c.ghostty_surface_renderer_realize(s) != 0) {
            std.log.warn("pane {d}: renderer realize failed", .{pane.id});
        }
    }

    // Set up IM context with the widget
    if (pane.im_context) |ctx| {
        c.gtk_im_context_set_client_widget(@ptrCast(ctx), @as(*c.GtkWidget, @ptrCast(gl_area)));
    }
}

fn onGlUnrealize(_: *c.GtkGLArea, user_data: c.gpointer) callconv(.c) void {
    const pane: *Pane = @ptrCast(@alignCast(user_data));
    std.log.debug("pane {d}: onGlUnrealize", .{pane.id});

    // Deinitialize the renderer's GPU resources before the GL context
    // is destroyed. This is needed when the widget is reparented (split/
    // close) so resources can be recreated on the new context.
    if (pane.surface != null) {
        if (pane.gl_area) |gl| {
            c.gtk_gl_area_make_current(gl);
            if (c.gtk_gl_area_get_error(gl) == null) {
                c.ghostty_surface_renderer_unrealize(pane.surface.?);
            } else {
                std.log.warn("pane {d}: GL context error in unrealize, resources may leak", .{pane.id});
            }
        }
    }

    if (pane.im_context) |ctx| {
        c.gtk_im_context_set_client_widget(@ptrCast(ctx), null);
    }
}

fn onGlRender(_: *c.GtkGLArea, _: *c.GdkGLContext, user_data: c.gpointer) callconv(.c) c.gboolean {
    const pane: *Pane = @ptrCast(@alignCast(user_data));

    // Deferred surface creation: if onGlResize stored pending dimensions
    // but the surface hasn't been created yet, create it now inside the
    // render callback where GTK guarantees the GL context is current and
    // the widget tree layout is settled.
    if (pane.surface == null and pane.pending_init_width > 0 and pane.pending_init_height > 0) {
        std.log.debug("pane {d}: deferred initSurface in onGlRender {d}x{d}", .{
            pane.id, pane.pending_init_width, pane.pending_init_height,
        });
        initSurface(pane, pane.pending_init_width, pane.pending_init_height);
        pane.pending_init_width = 0;
        pane.pending_init_height = 0;

        // Process pending ghostty messages and schedule a follow-up render
        // so the renderer thread's first frame gets picked up.
        ghostty_bridge.tick();
        pane.queueDeferredRedraw();
        // Skip ghostty_surface_draw on this frame — the surface was just
        // created with the app's default config and the config update may
        // not be reflected in the renderer yet.  Clear the framebuffer to
        // the current theme background so the user sees the correct color
        // instead of a flash of the old theme.
        clearToThemeBg();

        return 1;
    }

    if (pane.surface) |s| {
        c.ghostty_surface_draw(s);
    }
    return 1;
}

/// Clear the GL framebuffer to the current theme's background color.
/// Used to avoid a flash of stale colors when a surface is first created.
fn clearToThemeBg() void {
    const theme_mod = @import("theme.zig");
    const colors = theme_mod.resolveColors();
    const bg = colors.window_bg;
    const r = @as(f32, @floatFromInt(parseHex2(bg[1..3].*))) / 255.0;
    const g = @as(f32, @floatFromInt(parseHex2(bg[3..5].*))) / 255.0;
    const b = @as(f32, @floatFromInt(parseHex2(bg[5..7].*))) / 255.0;
    opengl.glClearColor(r, g, b, 1.0);
    opengl.glClear(opengl.GL_COLOR_BUFFER_BIT);
}

fn parseHex2(s: [2]u8) u8 {
    return std.fmt.parseInt(u8, &s, 16) catch 0;
}

fn onGlResize(_: *c.GtkGLArea, width: c.gint, height: c.gint, user_data: c.gpointer) callconv(.c) void {
    const pane: *Pane = @ptrCast(@alignCast(user_data));
    std.log.debug("pane {d}: onGlResize {d}x{d} surface_exists={}", .{ pane.id, width, height, pane.surface != null });

    if (pane.surface) |s| {
        // Update content scale on resize (no separate signal for scale changes)
        if (pane.gl_area) |gl| {
            const scale: f64 = @floatFromInt(c.gtk_widget_get_scale_factor(@as(*c.GtkWidget, @ptrCast(gl))));
            c.ghostty_surface_set_content_scale(s, scale, scale);
        }
        c.ghostty_surface_set_size(s, @intCast(width), @intCast(height));
        return;
    }

    // First resize: store dimensions and queue a render so that the surface
    // will be created inside onGlRender (where the GL context is guaranteed
    // current by GTK's render pipeline and the layout is fully settled).
    if (width > 0 and height > 0) {
        pane.pending_init_width = @intCast(width);
        pane.pending_init_height = @intCast(height);
        if (pane.gl_area) |gl| {
            c.gtk_gl_area_queue_render(gl);
        }
    } else {
        std.log.warn("pane {d}: skipping initSurface due to zero dimensions", .{pane.id});
    }
}

fn initSurface(pane: *Pane, width: u32, height: u32) void {
    const gl_area = pane.gl_area orelse return;
    const app = ghostty_bridge.getApp();
    if (app == null) {
        std.log.err("pane: ghostty app not initialized", .{});
        return;
    }

    c.gtk_gl_area_make_current(gl_area);
    if (c.gtk_gl_area_get_error(gl_area) != null) {
        std.log.err("pane: GL context error during surface init", .{});
        return;
    }

    // Build environment variables
    const cfg = config_mod.get();

    var cwd_buf: [Pane.cwd_cap + 1]u8 = undefined;
    const cwd_z = pane.cwdZ(&cwd_buf);

    // Environment variables for shell integration
    var ws_buf: [64]u8 = undefined;
    const ws_key = "SEANCE_WORKSPACE_ID";
    const ws_val: [*:0]const u8 = std.fmt.bufPrintZ(ws_buf[0..63], "{d}", .{pane.workspace_id}) catch "0";

    var tab_buf: [64]u8 = undefined;
    const tab_key = "SEANCE_PANE_GROUP_ID";
    const tab_val: [*:0]const u8 = std.fmt.bufPrintZ(tab_buf[0..63], "{d}", .{pane.pane_group_id}) catch "0";

    var pane_buf: [64]u8 = undefined;
    const pane_key = "SEANCE_SURFACE_ID";
    const pane_val: [*:0]const u8 = std.fmt.bufPrintZ(pane_buf[0..63], "{d}", .{pane.id}) catch "0";

    var panel_buf: [64]u8 = undefined;
    const panel_key = "SEANCE_PANEL_ID";
    const panel_val: [*:0]const u8 = std.fmt.bufPrintZ(panel_buf[0..63], "{d}", .{pane.id}) catch "0";

    // Socket path
    const socket_server = @import("socket_server.zig");
    var socket_path_raw: [std.fs.max_path_bytes]u8 = undefined;
    var socket_env_val_buf: [std.fs.max_path_bytes]u8 = undefined;
    const socket_key = "SEANCE_SOCKET_PATH";
    var socket_val: ?[*:0]const u8 = null;
    if (socket_server.SocketServer.resolvedPath(&socket_path_raw)) |sp| {
        if (std.fmt.bufPrintZ(&socket_env_val_buf, "{s}", .{sp})) |sv| {
            socket_val = sv;
        } else |_| {}
    }

    // Shell integration dir and bin dir
    var int_env_val_buf: [std.fs.max_path_bytes]u8 = undefined;
    const int_key = "SEANCE_SHELL_INTEGRATION_DIR";
    var int_val: ?[*:0]const u8 = null;
    var bin_env_val_buf: [std.fs.max_path_bytes]u8 = undefined;
    const bin_key = "SEANCE_BIN_DIR";
    var bin_val: ?[*:0]const u8 = null;
    {
        var exe_buf: [std.fs.max_path_bytes]u8 = undefined;
        if (std.fs.selfExePath(&exe_buf)) |exe_path| {
            if (std.fs.path.dirname(exe_path)) |exe_dir| {
                if (std.fs.path.dirname(exe_dir)) |prefix| {
                    if (std.fmt.bufPrintZ(&int_env_val_buf, "{s}/share/shell-integration", .{prefix})) |iv| {
                        int_val = iv;
                    } else |_| {}
                    if (std.fmt.bufPrintZ(&bin_env_val_buf, "{s}/share/bin", .{prefix})) |bv| {
                        bin_val = bv;
                    } else |_| {}
                }
            }
        } else |_| {}
    }

    // Prepend SEANCE_BIN_DIR to PATH so wrapper scripts are found
    var path_env_buf: [4096]u8 = undefined;
    var path_val: ?[*:0]const u8 = null;
    if (bin_val) |bv| {
        const bin_dir = std.mem.sliceTo(bv, 0);
        if (std.posix.getenv("PATH")) |existing_path| {
            if (std.fmt.bufPrintZ(&path_env_buf, "{s}:{s}", .{ bin_dir, existing_path })) |pv| {
                path_val = pv;
            } else |_| {}
        } else {
            path_val = bv;
        }
    }

    // Port range env vars
    const Window = @import("window.zig");
    var port_buf: [64]u8 = undefined;
    var port_end_buf: [64]u8 = undefined;
    var port_range_buf: [64]u8 = undefined;
    var port_val: ?[*:0]const u8 = null;
    var port_end_val: ?[*:0]const u8 = null;
    var port_range_val: ?[*:0]const u8 = null;
    if (Window.window_manager) |wm| {
        if (wm.findByWorkspaceId(pane.workspace_id)) |state| {
            for (state.workspaces.items) |ws| {
                if (ws.id == pane.workspace_id and ws.port_ordinal != std.math.maxInt(u32)) {
                    const port_start = cfg.port_base + ws.port_ordinal * cfg.port_range;
                    const port_end = port_start + cfg.port_range - 1;
                    if (std.fmt.bufPrintZ(&port_buf, "{d}", .{port_start})) |v| {
                        port_val = v;
                    } else |_| {}
                    if (std.fmt.bufPrintZ(&port_end_buf, "{d}", .{port_end})) |v| {
                        port_end_val = v;
                    } else |_| {}
                    if (std.fmt.bufPrintZ(&port_range_buf, "{d}", .{cfg.port_range})) |v| {
                        port_range_val = v;
                    } else |_| {}
                    break;
                }
            }
        }
    }

    // Build env var array
    var env_vars: [18]c.ghostty_env_var_s = undefined;
    var env_count: usize = 0;

    env_vars[env_count] = .{ .key = ws_key, .value = ws_val };
    env_count += 1;
    env_vars[env_count] = .{ .key = tab_key, .value = tab_val };
    env_count += 1;
    env_vars[env_count] = .{ .key = pane_key, .value = pane_val };
    env_count += 1;
    env_vars[env_count] = .{ .key = panel_key, .value = panel_val };
    env_count += 1;
    if (socket_val) |sv| {
        env_vars[env_count] = .{ .key = socket_key, .value = sv };
        env_count += 1;
    }
    if (int_val) |iv| {
        env_vars[env_count] = .{ .key = int_key, .value = iv };
        env_count += 1;
    }
    if (bin_val) |bv| {
        env_vars[env_count] = .{ .key = bin_key, .value = bv };
        env_count += 1;
    }
    if (path_val) |pv| {
        env_vars[env_count] = .{ .key = "PATH", .value = pv };
        env_count += 1;
    }
    if (!cfg.claude_code_hooks) {
        env_vars[env_count] = .{ .key = "SEANCE_CLAUDE_HOOKS_DISABLED", .value = "1" };
        env_count += 1;
    }
    if (!cfg.codex_hooks) {
        env_vars[env_count] = .{ .key = "SEANCE_CODEX_HOOKS_DISABLED", .value = "1" };
        env_count += 1;
    }
    if (!cfg.pi_hooks) {
        env_vars[env_count] = .{ .key = "SEANCE_PI_HOOKS_DISABLED", .value = "1" };
        env_count += 1;
    }
    env_vars[env_count] = .{ .key = "SEANCE_SHELL_INTEGRATION", .value = "1" };
    env_count += 1;
    env_vars[env_count] = .{ .key = "TERM_PROGRAM", .value = "ghostty" };
    env_count += 1;
    if (pane.replay_scrollback_path[0] != 0) {
        env_vars[env_count] = .{ .key = "SEANCE_RESTORE_SCROLLBACK_FILE", .value = &pane.replay_scrollback_path };
        env_count += 1;
    }
    if (port_val) |pv| {
        env_vars[env_count] = .{ .key = "SEANCE_PORT", .value = pv };
        env_count += 1;
    }
    if (port_end_val) |pv| {
        env_vars[env_count] = .{ .key = "SEANCE_PORT_END", .value = pv };
        env_count += 1;
    }
    if (port_range_val) |pv| {
        env_vars[env_count] = .{ .key = "SEANCE_PORT_RANGE", .value = pv };
        env_count += 1;
    }

    const scale: f64 = @floatFromInt(c.gtk_widget_get_scale_factor(@as(*c.GtkWidget, @ptrCast(gl_area))));

    var surface_config = c.ghostty_surface_config_new();
    surface_config.platform_tag = c.GHOSTTY_PLATFORM_NONE;
    surface_config.userdata = @ptrCast(pane);
    surface_config.scale_factor = scale;
    surface_config.font_size = 0; // use config default
    surface_config.working_directory = cwd_z;
    surface_config.env_vars = &env_vars;
    surface_config.env_var_count = env_count;
    surface_config.context = c.GHOSTTY_SURFACE_CONTEXT_TAB;

    const surface = c.ghostty_surface_new(app, &surface_config);
    if (surface == null) {
        std.log.err("pane: ghostty_surface_new failed", .{});
        return;
    }

    // Apply current seance config (including theme) to the new surface.
    // The ghostty_app was created at startup with the original config,
    // so new surfaces need to be updated to reflect any config changes
    // made since then (e.g. theme changes in settings).
    {
        const new_config = c.ghostty_config_new() orelse {
            std.log.warn("pane: failed to create config for new surface", .{});
            c.ghostty_surface_free(surface);
            return;
        };
        ghostty_bridge.applySeanceDefaultsPublic(@ptrCast(new_config));
        c.ghostty_config_load_default_files(@ptrCast(new_config));
        ghostty_bridge.applySeanceConfigPublic(@ptrCast(new_config));
        c.ghostty_config_finalize(@ptrCast(new_config));
        c.ghostty_surface_update_config(surface, new_config);
        c.ghostty_config_free(@ptrCast(new_config));
    }

    pane.surface = surface;
    pane.surface_initialized = true;

    // Set initial content scale and size
    c.ghostty_surface_set_content_scale(surface, scale, scale);
    c.ghostty_surface_set_size(surface, width, height);
    c.ghostty_surface_set_focus(surface, true);

    std.log.debug("pane: ghostty surface created for pane {d} ({d}x{d})", .{ pane.id, width, height });
}

// ── Key event handling ──────────────────────────────────────────────

fn translateMods(state: c.GdkModifierType) c.ghostty_input_mods_e {
    var mods: c_uint = c.GHOSTTY_MODS_NONE;
    const s: c_uint = @bitCast(state);
    if (s & c.GDK_SHIFT_MASK != 0) mods |= c.GHOSTTY_MODS_SHIFT;
    if (s & c.GDK_CONTROL_MASK != 0) mods |= c.GHOSTTY_MODS_CTRL;
    if (s & c.GDK_ALT_MASK != 0) mods |= c.GHOSTTY_MODS_ALT;
    if (s & c.GDK_SUPER_MASK != 0) mods |= c.GHOSTTY_MODS_SUPER;
    if (s & c.GDK_LOCK_MASK != 0) mods |= c.GHOSTTY_MODS_CAPS;
    return @intCast(mods);
}

fn addSidedMods(mods: *c_uint, keyval: c.guint, is_release: bool) void {
    switch (keyval) {
        c.GDK_KEY_Shift_L => {
            if (!is_release) mods.* |= c.GHOSTTY_MODS_SHIFT;
        },
        c.GDK_KEY_Shift_R => {
            if (!is_release) mods.* |= c.GHOSTTY_MODS_SHIFT;
            mods.* |= c.GHOSTTY_MODS_SHIFT_RIGHT;
        },
        c.GDK_KEY_Control_L => {
            if (!is_release) mods.* |= c.GHOSTTY_MODS_CTRL;
        },
        c.GDK_KEY_Control_R => {
            if (!is_release) mods.* |= c.GHOSTTY_MODS_CTRL;
            mods.* |= c.GHOSTTY_MODS_CTRL_RIGHT;
        },
        c.GDK_KEY_Alt_L => {
            if (!is_release) mods.* |= c.GHOSTTY_MODS_ALT;
        },
        c.GDK_KEY_Alt_R => {
            if (!is_release) mods.* |= c.GHOSTTY_MODS_ALT;
            mods.* |= c.GHOSTTY_MODS_ALT_RIGHT;
        },
        c.GDK_KEY_Super_L => {
            if (!is_release) mods.* |= c.GHOSTTY_MODS_SUPER;
        },
        c.GDK_KEY_Super_R => {
            if (!is_release) mods.* |= c.GHOSTTY_MODS_SUPER;
            mods.* |= c.GHOSTTY_MODS_SUPER_RIGHT;
        },
        else => {},
    }
}

fn onKeyPressed(
    controller: *c.GtkEventControllerKey,
    keyval: c.guint,
    keycode: c.guint,
    state: c.GdkModifierType,
    user_data: c.gpointer,
) callconv(.c) c.gboolean {
    const pane: *Pane = @ptrCast(@alignCast(user_data));
    return @intFromBool(handleKeyEvent(pane, controller, keyval, keycode, state, false));
}

fn onKeyReleased(
    controller: *c.GtkEventControllerKey,
    keyval: c.guint,
    keycode: c.guint,
    state: c.GdkModifierType,
    user_data: c.gpointer,
) callconv(.c) void {
    const pane: *Pane = @ptrCast(@alignCast(user_data));
    _ = handleKeyEvent(pane, controller, keyval, keycode, state, true);
}

fn handleKeyEvent(
    pane: *Pane,
    controller: *c.GtkEventControllerKey,
    keyval: c.guint,
    keycode: c.guint,
    state: c.GdkModifierType,
    is_release: bool,
) bool {
    const surface = pane.surface orelse return false;
    const event = c.gtk_event_controller_get_current_event(@ptrCast(controller));

    // IME handling
    if (pane.im_context) |ctx| {
        const was_composing = pane.im_composing;
        pane.in_keyevent = true;
        defer pane.in_keyevent = false;

        const im_handled = c.gtk_im_context_filter_keypress(@ptrCast(ctx), event) != 0;
        defer pane.im_len = 0;

        if (im_handled) {
            if (pane.im_composing) return true;
            if (was_composing) return true;
            if (pane.im_len == 0) return true;
        }
    }

    // If no text from IME, try to get text from keyval
    if (pane.im_len == 0) {
        const unicode = c.gdk_keyval_to_unicode(keyval);
        if (unicode > 0 and unicode >= 0x20) {
            if (std.math.cast(u21, unicode)) |cp| {
                if (std.unicode.utf8Encode(cp, &pane.im_buf)) |len| {
                    pane.im_len = len;
                } else |_| {}
            }
        }
    }

    // Build modifier state
    var mods: c_uint = @intCast(translateMods(state));
    addSidedMods(&mods, keyval, is_release);

    // Get consumed modifiers from GDK event
    var consumed: c_uint = 0;
    if (event) |ev| {
        const consumed_raw = c.gdk_key_event_get_consumed_modifiers(ev);
        consumed = @intCast(translateMods(@bitCast(@as(c_uint, @bitCast(consumed_raw)) & @as(c_uint, @bitCast(c.GDK_MODIFIER_MASK)))));
    }

    // Build text pointer (null-terminated)
    var text_ptr: ?[*]const u8 = null;
    if (pane.im_len > 0) {
        pane.im_buf[pane.im_len] = 0;
        text_ptr = &pane.im_buf;
    }

    // Get unshifted codepoint
    const unshifted = c.gdk_keyval_to_unicode(c.gdk_keyval_to_lower(keyval));

    const key_ev = c.ghostty_input_key_s{
        .action = if (is_release) c.GHOSTTY_ACTION_RELEASE else c.GHOSTTY_ACTION_PRESS,
        .mods = @intCast(mods),
        .consumed_mods = @intCast(consumed),
        .keycode = keycode,
        .text = text_ptr,
        .unshifted_codepoint = @intCast(if (unshifted > 0) unshifted else 0),
        .composing = pane.im_composing,
    };

    return c.ghostty_surface_key(surface, key_ev);
}

// ── IME callbacks ───────────────────────────────────────────────────

fn onImCommit(_: *c.GtkIMContext, text: [*:0]const u8, user_data: c.gpointer) callconv(.c) void {
    const pane: *Pane = @ptrCast(@alignCast(user_data));
    const text_slice = std.mem.sliceTo(text, 0);

    if (pane.in_keyevent) {
        // Store for association with the key event
        const len = @min(text_slice.len, pane.im_buf.len - 1);
        @memcpy(pane.im_buf[0..len], text_slice[0..len]);
        pane.im_len = len;
    } else {
        // Outside key event: send directly to ghostty
        if (pane.surface) |s| {
            c.ghostty_surface_text(s, text, text_slice.len);
        }
    }
}

fn onImPreeditStart(_: *c.GtkIMContext, user_data: c.gpointer) callconv(.c) void {
    const pane: *Pane = @ptrCast(@alignCast(user_data));
    pane.im_composing = true;
}

fn onImPreeditChanged(ctx: *c.GtkIMContext, user_data: c.gpointer) callconv(.c) void {
    const pane: *Pane = @ptrCast(@alignCast(user_data));
    if (pane.surface) |s| {
        var preedit_text: [*c]u8 = null;
        var cursor_pos: c.gint = 0;
        c.gtk_im_context_get_preedit_string(@ptrCast(ctx), &preedit_text, null, &cursor_pos);
        if (preedit_text) |pt| {
            const text_slice = std.mem.sliceTo(pt, 0);
            c.ghostty_surface_preedit(s, pt, text_slice.len);
            c.g_free(@ptrCast(pt));
        }
    }
}

fn onImPreeditEnd(_: *c.GtkIMContext, user_data: c.gpointer) callconv(.c) void {
    const pane: *Pane = @ptrCast(@alignCast(user_data));
    pane.im_composing = false;
    if (pane.surface) |s| {
        c.ghostty_surface_preedit(s, null, 0);
    }
}

// ── Mouse callbacks ─────────────────────────────────────────────────

fn translateMouseButton(button: c.guint) c.ghostty_input_mouse_button_e {
    return switch (button) {
        1 => c.GHOSTTY_MOUSE_LEFT,
        2 => c.GHOSTTY_MOUSE_MIDDLE,
        3 => c.GHOSTTY_MOUSE_RIGHT,
        4 => c.GHOSTTY_MOUSE_FOUR,
        5 => c.GHOSTTY_MOUSE_FIVE,
        6 => c.GHOSTTY_MOUSE_SIX,
        7 => c.GHOSTTY_MOUSE_SEVEN,
        8 => c.GHOSTTY_MOUSE_EIGHT,
        else => c.GHOSTTY_MOUSE_UNKNOWN,
    };
}

fn onMouseMotion(
    controller: *c.GtkEventControllerMotion,
    x: f64,
    y: f64,
    user_data: c.gpointer,
) callconv(.c) void {
    const pane: *Pane = @ptrCast(@alignCast(user_data));
    const surface = pane.surface orelse return;
    const event = c.gtk_event_controller_get_current_event(@ptrCast(controller));
    const gtk_mods = if (event) |ev| c.gdk_event_get_modifier_state(ev) else @as(c.GdkModifierType, @bitCast(@as(c_uint, 0)));
    const mods = translateMods(gtk_mods);

    const scale = getScale(pane);
    c.ghostty_surface_mouse_pos(surface, x * scale, y * scale, mods);

}

fn onMousePress(
    gesture: *c.GtkGestureClick,
    _: c.gint,
    _: f64,
    _: f64,
    user_data: c.gpointer,
) callconv(.c) void {
    const pane: *Pane = @ptrCast(@alignCast(user_data));
    const surface = pane.surface orelse return;

    // Grab focus if we don't have it
    if (pane.gl_area) |gl| {
        if (c.gtk_widget_has_focus(@as(*c.GtkWidget, @ptrCast(gl))) == 0) {
            _ = c.gtk_widget_grab_focus(@as(*c.GtkWidget, @ptrCast(gl)));
        }
    }

    const button_num = c.gtk_gesture_single_get_current_button(@ptrCast(gesture));
    const button = translateMouseButton(button_num);
    const event = c.gtk_event_controller_get_current_event(@as(*c.GtkEventController, @ptrCast(gesture)));
    const gtk_mods = if (event) |ev| c.gdk_event_get_modifier_state(ev) else @as(c.GdkModifierType, @bitCast(@as(c_uint, 0)));
    const mods = translateMods(gtk_mods);

    _ = c.ghostty_surface_mouse_button(surface, c.GHOSTTY_MOUSE_PRESS, button, mods);
}

fn onMouseRelease(
    gesture: *c.GtkGestureClick,
    _: c.gint,
    _: f64,
    _: f64,
    user_data: c.gpointer,
) callconv(.c) void {
    const pane: *Pane = @ptrCast(@alignCast(user_data));
    const surface = pane.surface orelse return;

    const button_num = c.gtk_gesture_single_get_current_button(@ptrCast(gesture));
    const button = translateMouseButton(button_num);
    const event = c.gtk_event_controller_get_current_event(@as(*c.GtkEventController, @ptrCast(gesture)));
    const gtk_mods = if (event) |ev| c.gdk_event_get_modifier_state(ev) else @as(c.GdkModifierType, @bitCast(@as(c_uint, 0)));
    const mods = translateMods(gtk_mods);

    _ = c.ghostty_surface_mouse_button(surface, c.GHOSTTY_MOUSE_RELEASE, button, mods);
}

fn onScroll(
    controller: *c.GtkEventControllerScroll,
    dx: f64,
    dy: f64,
    user_data: c.gpointer,
) callconv(.c) c.gboolean {
    const pane: *Pane = @ptrCast(@alignCast(user_data));
    const surface = pane.surface orelse return 0;
    _ = controller;

    // scroll_mods = 0 means no precision scrolling, no momentum
    // GTK4 scroll direction is inverted relative to Ghostty's expectation
    c.ghostty_surface_mouse_scroll(surface, dx, -dy, 0);
    return 1;
}

fn getScale(pane: *Pane) f64 {
    if (pane.gl_area) |gl| {
        return @floatFromInt(c.gtk_widget_get_scale_factor(@as(*c.GtkWidget, @ptrCast(gl))));
    }
    return 1.0;
}

// ── Scrollbar callbacks ─────────────────────────────────────────────

fn scrollbarHideTimeoutCb(user_data: c.gpointer) callconv(.c) c.gboolean {
    const pane: *Pane = @ptrCast(@alignCast(user_data));
    pane.scrollbar_visible = false;
    pane.scrollbar_hide_timeout = 0;
    if (pane.scrollbar_widget) |w| c.gtk_widget_set_visible(w, 0);
    return c.G_SOURCE_REMOVE;
}

fn drawScrollbarCb(
    _: *c.GtkDrawingArea,
    cr: *anyopaque, // cairo_t
    width_i: c_int,
    height_i: c_int,
    user_data: c.gpointer,
) callconv(.c) void {
    const pane: *Pane = @ptrCast(@alignCast(user_data));
    const width: f64 = @floatFromInt(width_i);
    const height: f64 = @floatFromInt(height_i);

    const total = pane.scrollbar_total;
    const offset = pane.scrollbar_offset;
    const len = pane.scrollbar_len;
    if (total == 0 or len == 0 or total <= len) return;

    const total_f: f64 = @floatFromInt(total);
    const offset_f: f64 = @floatFromInt(offset);
    const len_f: f64 = @floatFromInt(len);

    // Calculate thumb geometry
    const min_thumb: f64 = 20.0;
    const margin: f64 = 2.0;
    const track_height = height - margin * 2;
    var thumb_height = (len_f / total_f) * track_height;
    if (thumb_height < min_thumb) thumb_height = min_thumb;
    const max_offset = total_f - len_f;
    const thumb_y = if (max_offset > 0)
        margin + (offset_f / max_offset) * (track_height - thumb_height)
    else
        margin;

    // Draw thumb (rounded rectangle)
    const radius: f64 = 3.0;
    const x = margin;
    const w = width - margin * 2;
    c.cairo_new_path(@ptrCast(cr));
    // Top-left arc
    c.cairo_arc(@ptrCast(cr), x + radius, thumb_y + radius, radius, std.math.pi, 1.5 * std.math.pi);
    // Top-right arc
    c.cairo_arc(@ptrCast(cr), x + w - radius, thumb_y + radius, radius, 1.5 * std.math.pi, 2.0 * std.math.pi);
    // Bottom-right arc
    c.cairo_arc(@ptrCast(cr), x + w - radius, thumb_y + thumb_height - radius, radius, 0, 0.5 * std.math.pi);
    // Bottom-left arc
    c.cairo_arc(@ptrCast(cr), x + radius, thumb_y + thumb_height - radius, radius, 0.5 * std.math.pi, std.math.pi);
    c.cairo_close_path(@ptrCast(cr));

    c.cairo_set_source_rgba(@ptrCast(cr), 1.0, 1.0, 1.0, 0.35);
    c.cairo_fill(@ptrCast(cr));
}

// ── Focus callback ──────────────────────────────────────────────────

fn onFocusEnter(_: *c.GtkEventControllerFocus, user_data: c.gpointer) callconv(.c) void {
    const pane: *Pane = @ptrCast(@alignCast(user_data));
    const Window = @import("window.zig");
    const wm = Window.window_manager orelse return;
    const state = wm.findByWorkspaceId(pane.workspace_id) orelse return;

    const ws = state.activeWorkspace() orelse return;
    if (ws.restructuring) return;
    const grp = ws.findGroupContainingPane(pane.id) orelse return;

    // If already focused on this pane, just handle unread
    if (ws.focusedGroup()) |fg| {
        if (fg == grp) {
            if (fg.focusedTerminalPane()) |fp| {
                if (fp.id == pane.id) {
                    if (pane.has_unread) pane.focus();
                    return;
                }
            }
        }
        fg.unfocus();
    }

    const old_col = ws.focused_column;
    _ = ws.focusColumnContainingPane(pane.id);
    if (grp.findPanelById(pane.id)) |result| {
        grp.switchToPanel(result.index);
    }
    grp.focus();
    if (ws.focused_column != old_col) state.sidebar.refresh();
    state.updateWindowTitle();
}

fn onMouseEnter(
    _: *c.GtkEventControllerMotion,
    _: f64,
    _: f64,
    user_data: c.gpointer,
) callconv(.c) void {
    const pane: *Pane = @ptrCast(@alignCast(user_data));
    const cfg = config_mod.get();
    if (!cfg.focus_follows_mouse) return;

    // Don't focus if already focused
    if (pane.gl_area) |gl| {
        if (c.gtk_widget_has_focus(@as(*c.GtkWidget, @ptrCast(gl))) != 0) return;
    }

    // Don't focus if the window is not active
    const Window = @import("window.zig");
    const wm = Window.window_manager orelse return;
    const state = wm.findByWorkspaceId(pane.workspace_id) orelse return;
    if (c.gtk_window_is_active(@as(*c.GtkWindow, @ptrCast(state.gtk_window))) == 0) return;

    // Don't focus if a mouse button is pressed (user is dragging)
    const seat = c.gdk_display_get_default_seat(c.gdk_display_get_default());
    if (seat != null) {
        const pointer = c.gdk_seat_get_pointer(seat);
        if (pointer != null) {
            const mask = c.gdk_device_get_modifier_state(pointer);
            if (mask & (c.GDK_BUTTON1_MASK | c.GDK_BUTTON2_MASK | c.GDK_BUTTON3_MASK) != 0) return;
        }
    }

    if (pane.gl_area) |gl| {
        _ = c.gtk_widget_grab_focus(@as(*c.GtkWidget, @ptrCast(gl)));
    }
}

// ── Notification / bell handlers ────────────────────────────────────
// These are called from ghostty_bridge.zig action routing.

pub fn handleBell(pane: *Pane) void {
    const cfg = config_mod.get();
    if (!cfg.bell_notification) return;

    const Window = @import("window.zig");
    const wm = Window.window_manager orelse return;
    const state = wm.findByWorkspaceId(pane.workspace_id) orelse return;

    state.notif_center.emit(.{
        .title = "Bell",
        .body = "Terminal bell",
        .pane_id = pane.id,
        .workspace_id = pane.workspace_id,
        .pane_group_id = pane.pane_group_id,
        .desktop_notify = cfg.desktop_notifications,
    });
}

pub fn handleSetTitle(pane: *Pane, title: []const u8) void {
    if (title.len == 0) return;
    const tlen = @min(title.len, pane.cached_title.len);

    // Skip entirely if the title hasn't changed — avoids triggering a
    // sidebar rebuild on every single prompt.
    if (tlen == pane.cached_title_len and
        std.mem.eql(u8, pane.cached_title[0..tlen], title[0..tlen]))
        return;

    @memcpy(pane.cached_title[0..tlen], title[0..tlen]);
    pane.cached_title_len = tlen;

    // Debounce sidebar refresh: short-lived commands (e.g. `ls`) cause
    // rapid title changes (command name → prompt title) that flash in
    // the sidebar. Coalesce into one refresh after 250ms of quiet.
    if (pane.title_refresh_timeout != 0) {
        _ = c.g_source_remove(pane.title_refresh_timeout);
    }
    pane.title_refresh_timeout = c.g_timeout_add(250, titleRefreshCb, @ptrCast(pane));
}

fn titleRefreshCb(userdata: c.gpointer) callconv(.c) c.gboolean {
    const pane: *Pane = @ptrCast(@alignCast(userdata));
    pane.title_refresh_timeout = 0;

    const title = pane.cached_title[0..pane.cached_title_len];
    if (title.len == 0) return c.G_SOURCE_REMOVE;

    const Window = @import("window.zig");
    const wm = Window.window_manager orelse return c.G_SOURCE_REMOVE;
    const state = wm.findByWorkspaceId(pane.workspace_id) orelse return c.G_SOURCE_REMOVE;

    for (state.workspaces.items) |ws| {
        const grp = ws.findGroupContainingPane(pane.id) orelse continue;
        // Don't overwrite user-assigned custom tab title with terminal title
        if (pane.custom_title_len == 0) {
            grp.updateTitleForPane(pane.id, title);
        }
        if (ws.focusedGroup()) |fg| {
            if (fg == grp) {
                if (fg.focusedTerminalPane()) |fp| {
                    if (fp.id == pane.id) {
                        ws.setAutoTitle(title);
                        state.sidebar.refresh();
                        state.sidebar.setActive(state.active_workspace);
                        state.updateWindowTitle();
                    }
                }
            }
        }
        return c.G_SOURCE_REMOVE;
    }
    return c.G_SOURCE_REMOVE;
}

pub fn handleDesktopNotification(pane: *Pane, title_raw: ?[]const u8, body_raw: ?[]const u8) void {
    const cfg = config_mod.get();
    const Window = @import("window.zig");
    const wm = Window.window_manager orelse return;
    const state = wm.findByWorkspaceId(pane.workspace_id) orelse return;

    state.notif_center.emit(.{
        .title = title_raw orelse "Terminal Notification",
        .body = body_raw orelse "",
        .pane_id = pane.id,
        .workspace_id = pane.workspace_id,
        .pane_group_id = pane.pane_group_id,
        .desktop_notify = cfg.desktop_notifications,
    });
}

pub fn handleChildExited(pane: *Pane) void {
    _ = c.g_idle_add(@ptrCast(&idleClose), @ptrFromInt(pane.id));
}

fn idleClose(user_data: c.gpointer) callconv(.c) c.gboolean {
    const pane_id: u64 = @intFromPtr(user_data);
    const Window = @import("window.zig");
    if (Window.window_manager) |wm| {
        if (wm.findByPaneId(pane_id)) |state| {
            state.closePaneById(pane_id);
        }
    }
    return 0;
}

fn advanceFlash(pane: *Pane) void {
    const flash_on = [_]bool{ false, true, false, true, false };
    if (pane.flash_step >= flash_on.len) return;
    if (flash_on[pane.flash_step]) {
        c.gtk_widget_add_css_class(pane.widget, "pane-flash");
    } else {
        c.gtk_widget_remove_css_class(pane.widget, "pane-flash");
    }
    pane.flash_step += 1;
    if (pane.flash_step < flash_on.len) {
        pane.flash_timeout = c.g_timeout_add(225, @ptrCast(&onFlashStep), @ptrCast(pane));
    } else {
        pane.flash_timeout = 0;
    }
}

fn onFlashStep(data: c.gpointer) callconv(.c) c.gboolean {
    const pane: *Pane = @ptrCast(@alignCast(data));
    advanceFlash(pane);
    return 0;
}

/// Context for async drop data read.
const DropReadCtx = struct {
    pane: *Pane,
    drop: *c.GdkDrop,
};

/// Set up drag-and-drop target on the GLArea for file drops.
fn setupDropTarget(pane: *Pane) void {
    const gl_widget: *c.GtkWidget = @ptrCast(pane.gl_area orelse return);

    const drop_target = c.gtk_drop_target_async_new(null, c.GDK_ACTION_COPY | c.GDK_ACTION_MOVE);
    _ = c.g_signal_connect_data(
        @as(c.gpointer, @ptrCast(drop_target)),
        "drop",
        @as(c.GCallback, @ptrCast(&onDropAsync)),
        @ptrCast(pane),
        null,
        0,
    );
    _ = c.g_signal_connect_data(
        @as(c.gpointer, @ptrCast(drop_target)),
        "drag-enter",
        @as(c.GCallback, @ptrCast(&onDragEnter)),
        @ptrCast(pane),
        null,
        0,
    );
    _ = c.g_signal_connect_data(
        @as(c.gpointer, @ptrCast(drop_target)),
        "drag-leave",
        @as(c.GCallback, @ptrCast(&onDragLeave)),
        @ptrCast(pane),
        null,
        0,
    );
    c.gtk_widget_add_controller(gl_widget, @ptrCast(drop_target));
}

/// GtkDropTargetAsync "drop" handler — starts async read of the file list.
fn onDropAsync(_: *c.GtkDropTargetAsync, drop: *c.GdkDrop, _: f64, _: f64, user_data: c.gpointer) callconv(.c) c.gboolean {
    const pane: *Pane = @ptrCast(@alignCast(user_data));

    const ctx_mem = c.g_malloc(@sizeOf(DropReadCtx)) orelse return 0;
    const ctx: *DropReadCtx = @ptrCast(@alignCast(ctx_mem));
    ctx.* = .{ .pane = pane, .drop = drop };

    // Read the drop payload as a GdkFileList (GTK deserialises text/uri-list).
    c.gdk_drop_read_value_async(
        drop,
        c.gdk_file_list_get_type(),
        c.G_PRIORITY_DEFAULT,
        null,
        @ptrCast(&onDropValueReady),
        @ptrCast(ctx),
    );
    return 1;
}

/// Async callback: GdkDrop value is ready — extract file paths and paste.
fn onDropValueReady(source_object: ?*c.GObject, res: ?*c.GAsyncResult, user_data: c.gpointer) callconv(.c) void {
    const ctx: *DropReadCtx = @ptrCast(@alignCast(user_data));
    defer c.g_free(@ptrCast(ctx));

    const drop: *c.GdkDrop = @ptrCast(source_object orelse {
        std.log.debug("pane: drop read callback with null source", .{});
        return;
    });

    var err: ?*c.GError = null;
    const value: *const c.GValue = c.gdk_drop_read_value_finish(drop, res, &err) orelse {
        if (err) |e| {
            if (e.message) |msg| {
                std.log.debug("pane: drop read failed: {s}", .{std.mem.sliceTo(msg, 0)});
            } else {
                std.log.debug("pane: drop read failed (no message)", .{});
            }
            c.g_error_free(e);
        }
        c.gdk_drop_finish(drop, 0);
        return;
    };

    const boxed = c.g_value_get_boxed(value) orelse {
        std.log.debug("pane: drop value has no boxed data", .{});
        c.gdk_drop_finish(drop, 0);
        return;
    };
    const files: ?*c.GSList = c.gdk_file_list_get_files(@ptrCast(@constCast(boxed)));

    var buf: [8192]u8 = undefined;
    var pos: usize = 0;
    var node: ?*c.GSList = files;

    while (node) |n| {
        const path_z: ?[*:0]const u8 = c.g_file_get_path(@ptrCast(@alignCast(n.data)));
        if (path_z) |p| {
            defer c.g_free(@ptrCast(@constCast(p)));
            const path = std.mem.sliceTo(p, 0);

            if (pos > 0 and pos < buf.len) {
                buf[pos] = ' ';
                pos += 1;
            }
            pos += escapeShellPath(path, buf[pos..]);
        }
        node = n.next;
    }

    if (pos > 0) {
        std.log.debug("pane: drop {d} path bytes onto pane {d}", .{ pos, ctx.pane.id });
        // Null-terminate for gdk_clipboard_set_text, then use ghostty's
        // paste_from_clipboard so the text goes through proper bracketed-paste.
        if (pos < buf.len) {
            buf[pos] = 0;
            const display = c.gdk_display_get_default();
            if (display) |d| {
                const clipboard = c.gdk_display_get_clipboard(d);
                if (clipboard) |cb| {
                    c.gdk_clipboard_set_text(cb, &buf);
                    if (ctx.pane.surface) |s| {
                        _ = c.ghostty_surface_binding_action(s, "paste_from_clipboard", 20);
                    }
                }
            }
        }
    } else {
        std.log.debug("pane: drop event but no file paths extracted", .{});
    }

    ctx.pane.focus();
    c.gtk_widget_remove_css_class(ctx.pane.widget, "pane-drop-target");
    c.gdk_drop_finish(drop, c.GDK_ACTION_COPY);
}

fn onDragEnter(_: *c.GtkDropTargetAsync, _: *c.GdkDrop, _: f64, _: f64, user_data: c.gpointer) callconv(.c) c.GdkDragAction {
    const pane: *Pane = @ptrCast(@alignCast(user_data));
    std.log.debug("pane: drag enter on pane {d}", .{pane.id});
    c.gtk_widget_add_css_class(pane.widget, "pane-drop-target");
    return c.GDK_ACTION_COPY;
}

fn onDragLeave(_: *c.GtkDropTargetAsync, _: *c.GdkDrop, user_data: c.gpointer) callconv(.c) void {
    const pane: *Pane = @ptrCast(@alignCast(user_data));
    c.gtk_widget_remove_css_class(pane.widget, "pane-drop-target");
}

fn isShellSpecial(ch: u8) bool {
    return switch (ch) {
        '\\', ' ', '(', ')', '[', ']', '{', '}', '<', '>', '"', '\'', '`', '!', '#', '$', '&', ';', '|', '*', '?', '\t' => true,
        else => false,
    };
}

fn escapeShellPath(path: []const u8, buf: []u8) usize {
    var pos: usize = 0;
    for (path) |ch| {
        if (isShellSpecial(ch)) {
            if (pos + 2 > buf.len) break;
            buf[pos] = '\\';
            buf[pos + 1] = ch;
            pos += 2;
        } else {
            if (pos + 1 > buf.len) break;
            buf[pos] = ch;
            pos += 1;
        }
    }
    return pos;
}

var id_counter: u64 = 0;

fn nextId() u64 {
    id_counter += 1;
    return id_counter;
}

// ── Clipboard paste ─────────────────────────────────────────────────

pub fn handlePaste(pane: *Pane) void {
    if (pane.surface) |s| {
        // Use ghostty's built-in paste handling
        _ = c.ghostty_surface_binding_action(s, "paste_from_clipboard", 20);
    }
}
