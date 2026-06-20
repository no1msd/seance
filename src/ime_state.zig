const std = @import("std");

pub const InKeyEvent = enum { none, composing, not_composing };

pub const CommitRoute = enum {
    associate_with_key,
    send_direct,
};

pub const FilterDecision = enum {
    continue_key_event,
    consume,
};

pub fn beginKeyEvent(im_composing: bool) InKeyEvent {
    return if (im_composing) .composing else .not_composing;
}

pub fn commitRoute(in_keyevent: InKeyEvent) CommitRoute {
    return switch (in_keyevent) {
        .not_composing => .associate_with_key,
        .none, .composing => .send_direct,
    };
}

pub fn filterDecision(
    im_handled: bool,
    im_composing: bool,
    in_keyevent: InKeyEvent,
    im_len: usize,
) FilterDecision {
    if (!im_handled) return .continue_key_event;
    if (im_composing) return .consume;
    if (in_keyevent == .composing) return .consume;
    if (im_len == 0) return .consume;
    return .continue_key_event;
}

test "IME state: plain key commit stays associated with key event" {
    const in_keyevent = beginKeyEvent(false);
    try std.testing.expectEqual(InKeyEvent.not_composing, in_keyevent);
    try std.testing.expectEqual(CommitRoute.associate_with_key, commitRoute(in_keyevent));
    try std.testing.expectEqual(
        FilterDecision.continue_key_event,
        filterDecision(true, false, in_keyevent, 1),
    );
}

test "IME state: Korean composition commit is sent directly and consumes key" {
    const in_keyevent = beginKeyEvent(true);
    try std.testing.expectEqual(InKeyEvent.composing, in_keyevent);
    try std.testing.expectEqual(CommitRoute.send_direct, commitRoute(in_keyevent));
    try std.testing.expectEqual(
        FilterDecision.consume,
        filterDecision(true, false, in_keyevent, 0),
    );
}

test "IME state: active preedit consumes key without encoding" {
    try std.testing.expectEqual(
        FilterDecision.consume,
        filterDecision(true, true, .not_composing, 0),
    );
}

test "IME state: handled empty event is consumed" {
    try std.testing.expectEqual(
        FilterDecision.consume,
        filterDecision(true, false, .not_composing, 0),
    );
}

test "IME state: unhandled event continues to normal key encoding" {
    try std.testing.expectEqual(
        FilterDecision.continue_key_event,
        filterDecision(false, false, .not_composing, 0),
    );
}
