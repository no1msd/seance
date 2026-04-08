const std = @import("std");
const c = @import("c.zig").c;
const Pane = @import("pane.zig").Pane;

// Currently, only the terminal panel type exists. To add a non-terminal tab
// type (e.g. a settings editor, log viewer, etc.) in the future:
//   1. Create the new panel module (e.g. my_panel.zig) implementing the same
//      interface: getWidget, getId, focus, unfocus, destroy, triggerFlash.
//   2. Add a new variant to PanelType and Panel (e.g. my_panel: *MyPanel)
//      and update each method below to dispatch on it.
//   3. Update session.zig serialization/deserialization to handle the new type.

pub const PanelType = enum {
    terminal,
};

pub const Panel = union(PanelType) {
    terminal: *Pane,

    pub fn getWidget(self: Panel) *c.GtkWidget {
        return switch (self) {
            .terminal => |p| p.widget,
        };
    }

    pub fn getId(self: Panel) u64 {
        return switch (self) {
            .terminal => |p| p.id,
        };
    }

    pub fn focus(self: Panel) void {
        switch (self) {
            .terminal => |p| p.focus(),
        }
    }

    pub fn unfocus(self: Panel) void {
        switch (self) {
            .terminal => |p| p.unfocus(),
        }
    }

    pub fn disconnectSignals(self: Panel) void {
        switch (self) {
            .terminal => |p| p.disconnectSignals(),
        }
    }

    pub fn destroy(self: Panel, alloc: std.mem.Allocator) void {
        switch (self) {
            .terminal => |p| p.destroy(alloc),
        }
    }

    pub fn triggerFlash(self: Panel) void {
        switch (self) {
            .terminal => |p| p.triggerFlash(),
        }
    }

    /// Returns the terminal pane if this is a terminal panel, null otherwise.
    pub fn asTerminal(self: Panel) ?*Pane {
        return switch (self) {
            .terminal => |p| p,
        };
    }
};
