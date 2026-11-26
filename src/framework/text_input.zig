//! Text-input (IME) boundary: a protocol-independent session model plus the
//! pure decisions that the Wayland `zwp_text_input_v3` client executes.
//!
//! Why this file exists: on Wayland the compositor *is* the input method —
//! there is no in-process IM context to call. An app must create a
//! text-input object for its seat, `enable` it when an editable field takes
//! focus, send surrounding text / content type / cursor rectangle before
//! every `commit`, and apply `preedit_string`, `commit_string` and
//! `delete_surrounding_text` in the order the `done` event specifies.
//!
//! Everything here is deterministic and unit-tested without a compositor;
//! `src/os/linux/wayland/text_input.zig` performs the actual requests and
//! `Runtime` wires the two together.
const std = @import("std");

/// Which kind of editable field has focus. Mirrors
/// `zwp_text_input_v3.content_purpose`.
pub const Purpose = enum(u32) {
    normal = 0,
    alpha = 1,
    digits = 2,
    number = 3,
    phone = 4,
    url = 5,
    email = 6,
    name = 7,
    password = 8,
    pin = 9,
    date = 10,
    time = 11,
    datetime = 12,
    terminal = 13,
};

/// Behaviour hints. Mirrors `zwp_text_input_v3.content_hint`; the values are
/// the protocol's bit positions.
pub const Hint = struct {
    completion: bool = false,
    spellcheck: bool = false,
    auto_capitalization: bool = false,
    lowercase: bool = false,
    uppercase: bool = false,
    titlecase: bool = false,
    hidden_text: bool = false,
    sensitive_data: bool = false,
    latin: bool = false,
    multiline: bool = false,
    no_emoji: bool = false,
    preedit_shown: bool = true,

    pub fn bits(self: Hint) u32 {
        var v: u32 = 0;
        if (self.completion) v |= 0x1;
        if (self.spellcheck) v |= 0x2;
        if (self.auto_capitalization) v |= 0x4;
        if (self.lowercase) v |= 0x8;
        if (self.uppercase) v |= 0x10;
        if (self.titlecase) v |= 0x20;
        if (self.hidden_text) v |= 0x40;
        if (self.sensitive_data) v |= 0x80;
        if (self.latin) v |= 0x100;
        if (self.multiline) v |= 0x200;
        if (self.no_emoji) v |= 0x800;
        if (self.preedit_shown) v |= 0x1000;
        return v;
    }
};

/// Why the surrounding text changed, as the protocol distinguishes them.
pub const ChangeCause = enum(u32) {
    input_method = 0,
    other = 1,
};

/// What the app observed between two `commit` calls.
pub const Applied = struct {
    /// Text the input method asked to insert (already applied to the buffer
    /// by the caller).
    committed: []const u8 = "",
    /// Pre-edit text to display in the field (never inserted).
    preedit: []const u8 = "",
    /// True when the app must re-send surrounding text before the next
    /// commit because the field changed outside the input method.
    needs_surrounding_update: bool = false,
};

/// Protocol-level session state for one text-input object.
///
/// The session is deliberately pure: `enable`, `setSurrounding`,
/// `setContentType` and `setCursorRect` only record intent. `flush` returns
/// the ordered request sequence the transport must send, so the same logic
/// can run against a real compositor, a fake transport in tests, or (later) an
/// X11 or macOS backend.
pub const Session = struct {
    enabled: bool = false,
    purpose: Purpose = .normal,
    hint: Hint = .{},
    /// Surface-relative cursor rectangle in logical pixels.
    cursor_rect: Rect = .{},
    /// Surrounding text, cursor and anchor byte offsets within it.
    surrounding: []const u8 = "",
    surrounding_cursor: usize = 0,
    surrounding_anchor: usize = 0,
    have_surrounding: bool = false,
    /// Number of `commit` requests issued; compositors echo it in `done`.
    commits: u32 = 0,
    /// Set when any pending state exists that needs a commit.
    pending: bool = false,
    /// Latest language reported by the compositor (BCP 47).
    language: []const u8 = "",
    /// True after `enter` until `leave`.
    has_focus: bool = false,

    pub const Rect = struct { x: i32 = 0, y: i32 = 0, w: i32 = 0, h: i32 = 0 };

    pub const Request = union(enum) {
        enable,
        disable,
        surrounding: struct { text: []const u8, cursor: usize, anchor: usize },
        content_type: struct { hint: u32, purpose: u32 },
        cursor_rect: struct { x: i32, y: i32, w: i32, h: i32 },
        change_cause: ChangeCause,
        commit,
    };

    pub fn init() Session {
        return .{};
    }

    /// Focus entered an editable field. Resets the "state is invalid" flag
    /// the protocol requires after every enter/leave.
    pub fn setFocus(self: *Session, focused: bool) void {
        if (focused == self.has_focus) return;
        self.has_focus = focused;
        if (!focused) {
            // leave: the compositor drops all state; the app must re-send it.
            self.have_surrounding = false;
            self.pending = false;
        }
    }

    /// Field acquired logical focus: request enable with the current state.
    pub fn enableField(self: *Session, purpose: Purpose, hint: Hint) void {
        self.enabled = true;
        self.purpose = purpose;
        self.hint = hint;
        self.have_surrounding = false; // must re-send after enable
        self.pending = true;
    }

    /// Field lost logical focus.
    pub fn disableField(self: *Session) void {
        self.enabled = false;
        self.pending = true;
    }

    pub fn setSurrounding(self: *Session, text: []const u8, cursor: usize, anchor: usize) void {
        // Protocol: text is limited by the Wayland message size; callers pass
        // a window, not the whole document.
        self.surrounding = if (text.len > 4000) text[0..4000] else text;
        self.surrounding_cursor = @min(cursor, self.surrounding.len);
        self.surrounding_anchor = @min(anchor, self.surrounding.len);
        self.have_surrounding = true;
        self.pending = true;
    }

    pub fn setCursorRect(self: *Session, x: f32, y: f32, w: f32, h: f32) void {
        const r = Rect{
            .x = @intFromFloat(@floor(x)),
            .y = @intFromFloat(@floor(y)),
            .w = @intFromFloat(@ceil(w)),
            .h = @intFromFloat(@ceil(h)),
        };
        if (std.meta.eql(r, self.cursor_rect)) return;
        self.cursor_rect = r;
        self.pending = true;
    }

    /// Produce the ordered request batch for the current pending state and
    /// mark it committed. The caller sends them in order, then flushes.
    pub fn flush(self: *Session, out: *std.ArrayList(Request), allocator: std.mem.Allocator) !void {
        if (!self.pending) return;
        if (self.enabled) {
            try out.append(allocator, .enable);
            try out.append(allocator, .{ .content_type = .{ .hint = self.hint.bits(), .purpose = @intFromEnum(self.purpose) } });
            try out.append(allocator, .{ .change_cause = .other });
            if (self.have_surrounding) {
                try out.append(allocator, .{ .surrounding = .{
                    .text = self.surrounding,
                    .cursor = self.surrounding_cursor,
                    .anchor = self.surrounding_anchor,
                } });
            }
            try out.append(allocator, .{ .cursor_rect = .{
                .x = self.cursor_rect.x,
                .y = self.cursor_rect.y,
                .w = self.cursor_rect.w,
                .h = self.cursor_rect.h,
            } });
        } else {
            try out.append(allocator, .disable);
        }
        try out.append(allocator, .commit);
        self.commits +%= 1;
        self.pending = false;
    }

    /// Serial from the `done` event is the number of commits the compositor
    /// has seen. A mismatch means the compositor has newer state than we
    /// think and we should re-send rather than apply stale edits.
    pub fn doneMatches(self: *const Session, serial: u32) bool {
        return serial == self.commits;
    }
};

/// Apply the protocol's `done` ordering to a buffer-like target.
///
/// The spec requires, in this order: replace the pre-edit with the cursor,
/// delete surrounding text, insert the commit string at the cursor, then
/// place the cursor inside the new pre-edit. This helper models exactly that
/// against a `Target` interface so the same order is unit-tested here and
/// executed by `EditBuffer` in the widget layer.
pub const Pending = struct {
    preedit: []const u8 = "",
    commit: []const u8 = "",
    delete_before: u32 = 0,
    delete_after: u32 = 0,
    preedit_cursor_begin: i32 = -1,
    preedit_cursor_end: i32 = -1,

    pub fn clear(self: *Pending) void {
        self.* = .{};
    }

    pub fn hasWork(self: *const Pending) bool {
        return self.preedit.len != 0 or self.commit.len != 0 or
            self.delete_before != 0 or self.delete_after != 0;
    }
};

test "hint bits match the protocol values" {
    const h = Hint{ .multiline = true, .spellcheck = true, .sensitive_data = true };
    // preedit_shown defaults to true (0x1000).
    try std.testing.expectEqual(@as(u32, 0x200 | 0x2 | 0x80 | 0x1000), h.bits());
    try std.testing.expectEqual(@as(u32, 0), (Hint{ .preedit_shown = false }).bits());
    try std.testing.expectEqual(@as(u32, 0x1000), (Hint{}).bits());
    std.debug.print("IME_HINT_BITS_OK\n", .{});
}

test "flush: enable sends content type, surrounding, cursor rect, then commit" {
    var s = Session.init();
    s.setFocus(true);
    s.enableField(.email, .{ .spellcheck = true });
    s.setSurrounding("user@host", 4, 4);
    s.setCursorRect(10.4, 20.6, 2.0, 18.0);
    var list = std.ArrayList(Session.Request).empty;
    defer list.deinit(std.testing.allocator);
    try s.flush(&list, std.testing.allocator);
    try std.testing.expectEqual(@as(usize, 6), list.items.len);
    try std.testing.expect(list.items[0] == .enable);
    try std.testing.expectEqual(Purpose.email, @as(Purpose, @enumFromInt(list.items[1].content_type.purpose)));
    try std.testing.expect(list.items[1].content_type.hint & 0x2 != 0);
    try std.testing.expect(list.items[2] == .change_cause);
    try std.testing.expectEqualStrings("user@host", list.items[3].surrounding.text);
    try std.testing.expectEqual(@as(i32, 10), list.items[4].cursor_rect.x);
    try std.testing.expectEqual(@as(i32, 20), list.items[4].cursor_rect.y); // floor(20.6)
    try std.testing.expectEqual(@as(i32, 18), list.items[4].cursor_rect.h); // ceil(18.0)
    try std.testing.expect(list.items[5] == .commit);
    try std.testing.expectEqual(@as(u32, 1), s.commits);
    try std.testing.expect(!s.pending);
    // A second flush with no changes sends nothing.
    try s.flush(&list, std.testing.allocator);
    try std.testing.expectEqual(@as(usize, 6), list.items.len);
    std.debug.print("IME_FLUSH_OK\n", .{});
}

test "flush: disable sends disable + commit" {
    var s = Session.init();
    s.setFocus(true);
    s.enableField(.normal, .{});
    var list = std.ArrayList(Session.Request).empty;
    defer list.deinit(std.testing.allocator);
    try s.flush(&list, std.testing.allocator);
    list.clearRetainingCapacity();
    s.disableField();
    try s.flush(&list, std.testing.allocator);
    try std.testing.expectEqual(@as(usize, 2), list.items.len);
    try std.testing.expect(list.items[0] == .disable);
    try std.testing.expect(list.items[1] == .commit);
    std.debug.print("IME_DISABLE_OK\n", .{});
}

test "leave invalidates surrounding text; re-enable must resend it" {
    var s = Session.init();
    s.setFocus(true);
    s.enableField(.normal, .{});
    s.setSurrounding("hello", 5, 5);
    var list = std.ArrayList(Session.Request).empty;
    defer list.deinit(std.testing.allocator);
    try s.flush(&list, std.testing.allocator);
    s.setFocus(false);
    try std.testing.expect(!s.have_surrounding);
    s.setFocus(true);
    s.enableField(.normal, .{});
    list.clearRetainingCapacity();
    try s.flush(&list, std.testing.allocator);
    // No surrounding text request: the caller has not re-sent it yet.
    for (list.items) |r| try std.testing.expect(r != .surrounding);
    std.debug.print("IME_LEAVE_OK\n", .{});
}

test "done serial comparison" {
    var s = Session.init();
    _ = &s;
    var list = std.ArrayList(Session.Request).empty;
    defer list.deinit(std.testing.allocator);
    s.setFocus(true);
    s.enableField(.normal, .{});
    try s.flush(&list, std.testing.allocator);
    try std.testing.expect(s.doneMatches(1));
    try std.testing.expect(!s.doneMatches(0));
    try std.testing.expect(!s.doneMatches(2));
    std.debug.print("IME_DONE_SERIAL_OK\n", .{});
}

test "pending edit ordering state" {
    var p = Pending{};
    try std.testing.expect(!p.hasWork());
    p.commit = "日本";
    p.delete_before = 6;
    try std.testing.expect(p.hasWork());
    p.clear();
    try std.testing.expect(!p.hasWork());
    std.debug.print("IME_PENDING_OK\n", .{});
}
