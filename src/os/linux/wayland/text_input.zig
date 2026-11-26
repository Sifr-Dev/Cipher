//! Wayland `zwp_text_input_v3` client: the IME transport.
//!
//! On Wayland the compositor acts as the input method. This module owns the
//! text-input object for the runtime's seat and turns its signals into the
//! framework's `input.Event.ime` records. Behaviour (when to enable, which
//! state to send, how to apply a commit) lives in `framework/text_input.zig`
//! so it stays unit-testable without a compositor; this file is the wire.
//!
//! Protocol: https://wayland.app/protocols/text-input-unstable-v3
const std = @import("std");
const conn_mod = @import("wayland_client.zig");
const wayland_tables = @import("wayland_tables.zig");

const Connection = conn_mod.Connection;
const ti = @import("../../../framework/text_input.zig");

/// Request opcodes on zwp_text_input_v3 (protocol order).
pub const req = struct {
    pub const destroy: u32 = 0;
    pub const enable: u32 = 1;
    pub const disable: u32 = 2;
    pub const set_surrounding_text: u32 = 3;
    pub const set_text_change_cause: u32 = 4;
    pub const set_content_type: u32 = 5;
    pub const set_cursor_rectangle: u32 = 6;
    pub const commit: u32 = 7;
};

pub const mgr = struct {
    pub const destroy: u32 = 0;
    pub const get_text_input: u32 = 1;
};

/// The runtime-facing handle: one text-input object bound to the seat.
pub const TextInput = struct {
    conn: *Connection,
    manager: u32,
    object: u32,

    /// Bind the manager global and create the per-seat text-input object.
    pub fn create(conn: *Connection, seat: u32) !TextInput {
        const global = conn.findGlobal("zwp_text_input_manager_v3") orelse return error.NoTextInputManager;
        const manager = try conn.bindGlobal("zwp_text_input_manager_v3", &wayland_tables.zwp_text_input_manager_v3_interface, @min(global.version, 2));
        const seat_proxy = conn.proxyFromToken(seat) orelse return error.BindFailed;
        const object = conn.marshalConstructor(manager, mgr.get_text_input, &wayland_tables.zwp_text_input_v3_interface, .{seat_proxy}) orelse return error.TextInputCreateFailed;
        conn.registerListener(object, @ptrCast(&TEXT_INPUT_LISTENER));
        return .{ .conn = conn, .manager = manager, .object = object };
    }

    pub fn destroy(self: *TextInput) void {
        self.conn.destroyProxy(self.object, req.destroy);
        self.conn.destroyProxy(self.manager, mgr.destroy);
    }

    // ---- requests ---------------------------------------------------------

    pub fn enable(self: TextInput) void {
        self.conn.marshalVoid(self.object, req.enable, .{});
    }

    pub fn disable(self: TextInput) void {
        self.conn.marshalVoid(self.object, req.disable, .{});
    }

    pub fn setSurroundingText(self: TextInput, text: []const u8, cursor: u64, anchor: u64) void {
        var z = ZString{};
        z.set(text);
        self.conn.marshalVoid(self.object, req.set_surrounding_text, .{ z.ptr(), @as(u32, @intCast(cursor)), @as(u32, @intCast(anchor)) });
    }

    pub fn setTextChangeCause(self: TextInput, cause: u32) void {
        self.conn.marshalVoid(self.object, req.set_text_change_cause, .{cause});
    }

    pub fn setContentType(self: TextInput, hint: u32, purpose: u32) void {
        self.conn.marshalVoid(self.object, req.set_content_type, .{ hint, purpose });
    }

    pub fn setCursorRectangle(self: TextInput, x: i32, y: i32, w: i32, h: i32) void {
        self.conn.marshalVoid(self.object, req.set_cursor_rectangle, .{ x, y, w, h });
    }

    pub fn commit(self: TextInput) void {
        self.conn.marshalVoid(self.object, req.commit, .{});
    }

    /// Send a `framework.text_input.Session` request batch in order, then the
    /// single commit that applies it atomically.
    pub fn sendBatch(self: TextInput, batch: []const ti.Session.Request) void {
        for (batch) |r| switch (r) {
            .enable => self.enable(),
            .disable => self.disable(),
            .surrounding => |s| self.setSurroundingText(s.text, s.cursor, s.anchor),
            .content_type => |c| self.setContentType(c.hint, c.purpose),
            .cursor_rect => |c| self.setCursorRectangle(c.x, c.y, c.w, c.h),
            .change_cause => |c| self.setTextChangeCause(@intFromEnum(c)),
            .commit => self.commit(),
        };
    }
};

/// Fixed-size NUL-terminated UTF-8 buffer for one request argument. Wayland
/// copies string arguments during the marshal call, so a per-request stack
/// buffer is safe (same pattern as `conn_mod.CString`).
pub const ZString = struct {
    bytes: [4096]u8 = undefined,
    len: usize = 0,

    pub fn set(self: *ZString, text: []const u8) void {
        const n = @min(text.len, self.bytes.len - 1);
        @memcpy(self.bytes[0..n], text[0..n]);
        self.bytes[n] = 0;
        self.len = n;
    }

    pub fn ptr(self: *const ZString) [*:0]const u8 {
        return @ptrCast(&self.bytes);
    }
};

// ---- listener translation -------------------------------------------------

const TEXT_INPUT_LISTENER = conn_mod.zwp_text_input_v3_listener{
    .enter = tiEnter,
    .leave = tiLeave,
    .preedit_string = tiPreedit,
    .commit_string = tiCommit,
    .delete_surrounding_text = tiDelete,
    .done = tiDone,
    .action = tiAction,
    .language = tiLanguage,
    .preedit_hint = tiPreeditHint,
};

fn tiEnter(data: ?*anyopaque, proxy: *conn_mod.zwp_text_input_v3, surface: *conn_mod.wl_surface) callconv(.c) void {
    const self: *Connection = @alignCast(@ptrCast(data orelse return));
    _ = proxy;
    self.pushImeEvent(.enter, null, &.{@bitCast(self.tokenize(@ptrCast(surface)))}) catch {};
}

fn tiLeave(data: ?*anyopaque, proxy: *conn_mod.zwp_text_input_v3, surface: *conn_mod.wl_surface) callconv(.c) void {
    const self: *Connection = @alignCast(@ptrCast(data orelse return));
    _ = proxy;
    self.pushImeEvent(.leave, null, &.{@bitCast(self.tokenize(@ptrCast(surface)))}) catch {};
}

fn tiPreedit(data: ?*anyopaque, proxy: *conn_mod.zwp_text_input_v3, text: ?[*:0]const u8, begin: i32, end: i32) callconv(.c) void {
    const self: *Connection = @alignCast(@ptrCast(data orelse return));
    _ = proxy;
    const s: ?[]const u8 = if (text) |t| std.mem.span(t) else null;
    self.pushImeEvent(.preedit_string, s, &.{ begin, end }) catch {};
}

fn tiCommit(data: ?*anyopaque, proxy: *conn_mod.zwp_text_input_v3, text: ?[*:0]const u8) callconv(.c) void {
    const self: *Connection = @alignCast(@ptrCast(data orelse return));
    _ = proxy;
    const s: ?[]const u8 = if (text) |t| std.mem.span(t) else null;
    self.pushImeEvent(.commit_string, s, &.{}) catch {};
}

fn tiDelete(data: ?*anyopaque, proxy: *conn_mod.zwp_text_input_v3, before: u32, after: u32) callconv(.c) void {
    const self: *Connection = @alignCast(@ptrCast(data orelse return));
    _ = proxy;
    self.pushImeEvent(.delete_surrounding_text, null, &.{ @bitCast(before), @bitCast(after) }) catch {};
}

fn tiDone(data: ?*anyopaque, proxy: *conn_mod.zwp_text_input_v3, serial: u32) callconv(.c) void {
    const self: *Connection = @alignCast(@ptrCast(data orelse return));
    _ = proxy;
    self.pushImeEvent(.done, null, &.{@bitCast(serial)}) catch {};
}

fn tiAction(data: ?*anyopaque, proxy: *conn_mod.zwp_text_input_v3, action: u32, serial: u32) callconv(.c) void {
    const self: *Connection = @alignCast(@ptrCast(data orelse return));
    _ = proxy;
    self.pushImeEvent(.action, null, &.{ @bitCast(action), @bitCast(serial) }) catch {};
}

fn tiLanguage(data: ?*anyopaque, proxy: *conn_mod.zwp_text_input_v3, language: ?[*:0]const u8) callconv(.c) void {
    const self: *Connection = @alignCast(@ptrCast(data orelse return));
    _ = proxy;
    const s: ?[]const u8 = if (language) |t| std.mem.span(t) else null;
    self.pushImeEvent(.language, s, &.{}) catch {};
}

fn tiPreeditHint(data: ?*anyopaque, proxy: *conn_mod.zwp_text_input_v3, start: u32, end: u32, hint: u32) callconv(.c) void {
    const self: *Connection = @alignCast(@ptrCast(data orelse return));
    _ = proxy;
    self.pushImeEvent(.preedit_hint, null, &.{ @bitCast(start), @bitCast(end), @bitCast(hint) }) catch {};
}

test "ZString truncates to the fixed buffer and stays NUL-terminated" {
    var z = ZString{};
    z.set("hello");
    try std.testing.expectEqualStrings("hello", std.mem.span(z.ptr()));
    var big: [5000]u8 = undefined;
    @memset(&big, 'x');
    z.set(&big);
    try std.testing.expectEqual(@as(usize, 4095), std.mem.span(z.ptr()).len);
    std.debug.print("IME_ZSTRING_OK\n", .{});
}

test "request opcodes match the generated interface table" {
    const methods = wayland_tables.zwp_text_input_v3_interface.methods.?;
    try std.testing.expectEqualStrings("enable", std.mem.span(methods[req.enable].name));
    try std.testing.expectEqualStrings("disable", std.mem.span(methods[req.disable].name));
    try std.testing.expectEqualStrings("set_surrounding_text", std.mem.span(methods[req.set_surrounding_text].name));
    try std.testing.expectEqualStrings("set_content_type", std.mem.span(methods[req.set_content_type].name));
    try std.testing.expectEqualStrings("commit", std.mem.span(methods[req.commit].name));
    std.debug.print("IME_OPCODES_OK\n", .{});
}
