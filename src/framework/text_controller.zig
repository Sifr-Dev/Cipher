//! Frame-level text field coordination, independent of a live compositor.
const std = @import("std");
const tf = @import("text_field.zig");
const input = @import("input.zig");
const layout = @import("../ui/layout.zig");

pub const Controller = struct {
    fields: std.ArrayList(*tf.TextField) = .empty,
    focused: ?*tf.TextField = null,
    surface: u32 = 0,
    surface_focused: bool = false,
    frame: u64 = 0,

    pub fn deinit(self: *Controller, allocator: std.mem.Allocator) void {
        self.fields.deinit(allocator);
    }

    pub fn beginFrame(self: *Controller) void {
        self.frame +%= 1;
        self.fields.clearRetainingCapacity();
    }

    pub fn setSurfaceFocus(self: *Controller, focused: bool) void {
        if (self.surface_focused == focused) return;
        self.surface_focused = focused;
        if (self.focused) |field| field.setSurfaceFocus(focused);
    }

    fn register(self: *Controller, field: *tf.TextField, allocator: std.mem.Allocator) !void {
        if (field.runtime_seen == self.frame) return;
        field.runtime_seen = self.frame;
        field.last = .{};
        field.caret_phase += 1.0 / 60.0;
        try self.fields.append(allocator, field);
        if (self.focused == null and field.focused) {
            self.focused = field;
            field.setSurfaceFocus(self.surface_focused);
        }
    }

    fn choose(self: *Controller, field: ?*tf.TextField) void {
        if (self.focused == field) return;
        if (self.focused) |old| old.blur();
        self.focused = field;
        if (field) |next| {
            next.focus();
            next.setSurfaceFocus(self.surface_focused);
        }
    }

    /// Route one frame's events. `keyboard_focused` follows Ui focus order;
    /// pointer focus uses the previous-frame rectangle, like other widgets.
    pub fn route(self: *Controller, allocator: std.mem.Allocator, field: *tf.TextField, rect: layout.Rect, events: []const input.Event, mouse_x: f32, mouse_y: f32, mouse_pressed: bool, mouse_down: bool, shift: bool, keyboard_focused: bool, atlas: anytype) !void {
        try self.register(field, allocator);
        field.bounds = rect;
        const clicked = mouse_pressed and rect.w > 0 and rect.contains(mouse_x, mouse_y);
        if (clicked) self.choose(field) else if (keyboard_focused) self.choose(field) else if (mouse_pressed and self.focused == field) self.choose(null);
        if (self.focused == field) {
            for (events) |ev| switch (ev) {
                .key => |k| {
                    if (k.pressed and k.key == .esc and field.focused) self.choose(null) else _ = field.handleKey(k);
                },
                .paste => |p| field.paste(p),
                .ime => |ime| field.handleIme(ime),
                .focus => |focused| if (!focused) self.choose(null),
                else => {},
            };
        }
        if (clicked and self.focused == field) field.clickAt(mouse_x - rect.x - 8, mouse_y - rect.y - 8, atlas, shift);
        if (field.dragging and mouse_down) field.dragAt(mouse_x - rect.x - 8, mouse_y - rect.y - 8, atlas);
        if (!mouse_down) field.endDrag();
    }

    pub fn clipboard(self: *Controller, field: *tf.TextField, ev: input.KeyEvent) ?tf.ClipboardAction {
        if (!field.focused or self.focused != field) return null;
        return field.clipboardAction(ev);
    }

    pub fn sync(self: *Controller, field: *tf.TextField, atlas: anytype, window_h: f32) bool {
        if (field.runtime_seen != self.frame) return false;
        return field.syncIme(atlas, field.bounds, window_h);
    }
};

const EmptyAtlas = struct {
    pub fn cursorByteAt(_: @This(), _: []const u8, _: f32) usize {
        return 0;
    }
};

test "controller: only focused field receives an IME done transaction" {
    var c = Controller{};
    defer c.deinit(std.testing.allocator);
    var a = tf.TextField.init(std.testing.allocator, .{});
    defer a.deinit();
    var b = tf.TextField.init(std.testing.allocator, .{});
    defer b.deinit();
    const atlas = EmptyAtlas{};
    c.beginFrame();
    c.setSurfaceFocus(true);
    try c.route(std.testing.allocator, &a, .{}, &.{}, 0, 0, false, false, false, true, atlas);
    try c.route(std.testing.allocator, &b, .{}, &.{}, 0, 0, false, false, false, false, atlas);
    const events = [_]input.Event{
        .{ .ime = .{ .commit = "日本" } },
        .{ .ime = .{ .done = 0 } },
    };
    c.beginFrame();
    try c.route(std.testing.allocator, &a, .{}, &events, 0, 0, false, false, false, true, atlas);
    try c.route(std.testing.allocator, &b, .{}, &events, 0, 0, false, false, false, false, atlas);
    try std.testing.expectEqualStrings("日本", a.text());
    try std.testing.expectEqual(@as(usize, 0), b.text().len);
    try std.testing.expect(a.last.had_ime_commit);
}

test "controller: click transfers focus and clears old composition" {
    var c = Controller{};
    defer c.deinit(std.testing.allocator);
    var a = tf.TextField.init(std.testing.allocator, .{});
    defer a.deinit();
    var b = tf.TextField.init(std.testing.allocator, .{});
    defer b.deinit();
    const atlas = EmptyAtlas{};
    c.beginFrame();
    c.setSurfaceFocus(true);
    try c.route(std.testing.allocator, &a, .{}, &.{}, 0, 0, false, false, false, true, atlas);
    a.handleIme(.{ .preedit = .{ .text = "x", .cursor_begin = 1, .cursor_end = 1 } });
    a.handleIme(.{ .done = 0 });
    c.beginFrame();
    try c.route(std.testing.allocator, &a, .{}, &.{}, 0, 0, false, false, false, false, atlas);
    try c.route(std.testing.allocator, &b, .{ .w = 100, .h = 30 }, &.{}, 10, 10, true, true, false, false, atlas);
    try std.testing.expect(!a.focused);
    try std.testing.expect(b.focused);
    try std.testing.expectEqual(@as(usize, 0), a.buffer.preedit().len);
    try std.testing.expect(a.needs_disable_commit);
}
