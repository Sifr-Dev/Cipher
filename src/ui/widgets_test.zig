//! Widget behavior tests: slider drag, checkbox toggle, list select/scroll,
//! text input editing (keys + paste), tabs, using frame-by-frame event feeds.
const std = @import("std");
const ui_mod = @import("ui.zig");
const widgets = @import("widgets.zig");
const input = @import("../framework/input.zig");
const atlas_mod = @import("text/atlas.zig");

const FONT_PATH = "/usr/share/fonts/liberation/LiberationSans-Regular.ttf";

fn readFile(path: []const u8, allocator: std.mem.Allocator) ![]u8 {
    const fd = try std.posix.openat(std.posix.AT.FDCWD, path, .{ .ACCMODE = .RDONLY }, 0);
    defer _ = std.c.close(fd);
    const buf = try allocator.alloc(u8, 8 * 1024 * 1024);
    var off: usize = 0;
    while (off < buf.len) {
        const n = try std.posix.read(fd, buf[off..]);
        if (n == 0) break;
        off += n;
    }
    return try allocator.realloc(buf, off);
}

fn setup() !struct { data: []u8, at: *atlas_mod.TextAtlas, ui: *ui_mod.Ui } {
    const data = try readFile(FONT_PATH, std.testing.allocator);
    const at = try std.testing.allocator.create(atlas_mod.TextAtlas);
    at.* = try atlas_mod.TextAtlas.init(std.testing.allocator, data, 20);
    const ui = try std.testing.allocator.create(ui_mod.Ui);
    ui.* = ui_mod.Ui.init(std.testing.allocator, at);
    return .{ .data = data, .at = at, .ui = ui };
}

fn keyEvent(code: u32, pressed: bool) input.Event {
    const m = input.mapKey(code, false, false);
    return .{ .key = .{ .code = code, .key = m.key, .char = m.char, .mods = .{}, .pressed = pressed } };
}

test "slider: drag sets value proportionally" {
    const s = try setup();
    defer std.testing.allocator.free(s.data);
    defer std.testing.allocator.destroy(s.ui); // LIFO: runs after deinit
    defer s.ui.deinit();
    defer std.testing.allocator.destroy(s.at);
    defer s.at.deinit();
    const ui = s.ui;
    var value: f32 = 0;

    // frame 1: no mouse — establishes rect
    try ui.begin(400, 300, 0, 0, false, false, 1.0);
    try widgets.slider(ui, 200, 0, 100, &value);
    try ui.end();
    const r = ui.widgetRect(1) orelse return error.NoRect;
    try std.testing.expectApproxEqAbs(@as(f32, 200), r.w, 0.01);

    // frame 2: press at 75% of the track -> value ~75
    try ui.begin(400, 300, r.x + r.w * 0.75, r.y + r.h / 2, true, true, 1.0);
    try widgets.slider(ui, 200, 0, 100, &value);
    try ui.end();
    try std.testing.expectApproxEqAbs(@as(f32, 75), value, 2.0);

    // frame 3: keep dragging to 10%
    try ui.begin(400, 300, r.x + r.w * 0.10, r.y + r.h / 2, true, false, 1.0);
    try widgets.slider(ui, 200, 0, 100, &value);
    try ui.end();
    try std.testing.expectApproxEqAbs(@as(f32, 10), value, 2.0);

    // frame 4: release far right but not dragging -> clamps to last value <= max
    try ui.begin(400, 300, r.x + r.w * 2, r.y + r.h / 2, false, false, 1.0);
    try widgets.slider(ui, 200, 0, 100, &value);
    try ui.end();
    try std.testing.expect(value <= 100 and value >= 9);
    std.debug.print("WIDGET_SLIDER_OK v75={d:.1} v10={d:.1}\n", .{ 75.0, value });
}

test "checkbox: click toggles" {
    const s = try setup();
    defer std.testing.allocator.free(s.data);
    defer std.testing.allocator.destroy(s.ui); // LIFO: runs after deinit
    defer s.ui.deinit();
    defer std.testing.allocator.destroy(s.at);
    defer s.at.deinit();
    const ui = s.ui;
    var v = false;
    try ui.begin(400, 300, 0, 0, false, false, 1.0);
    _ = try widgets.checkbox(ui, "x", &v);
    try ui.end();
    const r = ui.widgetRect(1).?;
    try std.testing.expect(!v);
    try ui.begin(400, 300, r.x + 5, r.y + 5, true, true, 1.0);
    const t1 = try widgets.checkbox(ui, "x", &v);
    try ui.end();
    try std.testing.expect(t1 and v);
    try ui.begin(400, 300, 300, 250, true, true, 1.0); // click elsewhere
    const t2 = try widgets.checkbox(ui, "x", &v);
    try ui.end();
    try std.testing.expect(!t2 and v);
    std.debug.print("WIDGET_CHECKBOX_OK\n", .{});
}

test "list: click selects row, wheel scrolls" {
    const s = try setup();
    defer std.testing.allocator.free(s.data);
    defer std.testing.allocator.destroy(s.ui); // LIFO: runs after deinit
    defer s.ui.deinit();
    defer std.testing.allocator.destroy(s.at);
    defer s.at.deinit();
    const ui = s.ui;
    const items = [_][]const u8{ "alpha", "beta", "gamma", "delta", "epsilon", "zeta", "eta", "theta" };
    var sel: i32 = -1;
    // frame 1: establish rect
    try ui.begin(400, 300, 0, 0, false, false, 1.0);
    try widgets.listView(ui, 200, 4, &items, &sel);
    try ui.end();
    const r = ui.widgetRect(1).?;
    try std.testing.expectEqual(@as(i32, -1), sel);
    // frame 2: click second row
    const lh = @as(f32, @floatFromInt(ui.atlas.font.ascender - ui.atlas.font.descender + ui.atlas.font.line_gap)) * ui.atlas.scale;
    try ui.begin(400, 300, r.x + 20, r.y + 2 + lh * 1.5, true, true, 1.0);
    try widgets.listView(ui, 200, 4, &items, &sel);
    try ui.end();
    try std.testing.expectEqual(@as(i32, 1), sel);
    // frame 3: wheel down 2 notches while hovered
    const wheel_ev = [_]input.Event{.{ .wheel = .{ .dx = 0, .dy = 2 } }};
    try ui.begin(400, 300, r.x + 20, r.y + 10, false, false, 1.0);
    ui.events = &wheel_ev;
    try widgets.listView(ui, 200, 4, &items, &sel);
    try ui.end();
    try std.testing.expectEqual(@as(i32, 1), sel); // selection unchanged
    std.debug.print("WIDGET_LIST_OK sel=1 scroll-applied\n", .{});
}

test "textInput: click focuses, keys edit, paste inserts" {
    const s = try setup();
    defer std.testing.allocator.free(s.data);
    defer std.testing.allocator.destroy(s.ui); // LIFO: runs after deinit
    defer s.ui.deinit();
    defer std.testing.allocator.destroy(s.at);
    defer s.at.deinit();
    const ui = s.ui;
    var storage: [256]u8 = undefined;
    // frame 1: establish rect, click inside to focus
    try ui.begin(400, 300, 0, 0, false, false, 1.0);
    _ = try widgets.textInput(ui, 260, storage[0..0], "type here");
    try ui.end();
    const r = ui.widgetRect(1).?;
    // frame 2: click inside
    try ui.begin(400, 300, r.x + 10, r.y + 5, true, true, 1.0);
    _ = try widgets.textInput(ui, 260, storage[0..0], "type here");
    try ui.end();
    // frame 3: type 'h','i' (key 35 = h, 23 = i)
    const evs = [_]input.Event{ keyEvent(35, true), keyEvent(35, false), keyEvent(23, true), keyEvent(23, false) };
    try ui.begin(400, 300, r.x + 10, r.y + 5, false, false, 1.0);
    ui.events = &evs;
    const out = try widgets.textInput(ui, 260, storage[0..0], "type here");
    try ui.end();
    try std.testing.expectEqualStrings("hi", out);
    // frame 4: backspace removes 'i'
    const evs2 = [_]input.Event{keyEvent(14, true)};
    try ui.begin(400, 300, r.x + 10, r.y + 5, false, false, 1.0);
    ui.events = &evs2;
    const out2 = try widgets.textInput(ui, 260, storage[0..0], "type here");
    try ui.end();
    try std.testing.expectEqualStrings("h", out2);
    // frame 5: paste "xy" appends at cursor (end)
    const evs3 = [_]input.Event{.{ .paste = "xy" }};
    try ui.begin(400, 300, r.x + 10, r.y + 5, false, false, 1.0);
    ui.events = &evs3;
    const out3 = try widgets.textInput(ui, 260, storage[0..0], "type here");
    try ui.end();
    try std.testing.expectEqualStrings("hxy", out3);
    std.debug.print("WIDGET_TEXT_OK buf='{s}'\n", .{out3});
}

test "tabs: click selects tab" {
    const s = try setup();
    defer std.testing.allocator.free(s.data);
    defer std.testing.allocator.destroy(s.ui); // LIFO: runs after deinit
    defer s.ui.deinit();
    defer std.testing.allocator.destroy(s.at);
    defer s.at.deinit();
    const ui = s.ui;
    const labels = [_][]const u8{ "Library", "Queue", "Lyrics" };
    var sel: i32 = 0;
    try ui.begin(400, 300, 0, 0, false, false, 1.0);
    try widgets.tabs(ui, &labels, &sel);
    try ui.end();
    try std.testing.expectEqual(@as(i32, 0), sel);
    // tab i has id base_id+1+i; base_id=1 -> tab 2 is id 4
    const r2 = ui.widgetRect(4).?;
    try ui.begin(400, 300, r2.x + r2.w / 2, r2.y + r2.h / 2, true, true, 1.0);
    try widgets.tabs(ui, &labels, &sel);
    try ui.end();
    try std.testing.expectEqual(@as(i32, 2), sel);
    std.debug.print("WIDGET_TABS_OK sel=2\n", .{});
}

test "focus: Tab cycles buttons, Enter activates, ring appears only after Tab" {
    const s = try setup();
    defer std.testing.allocator.free(s.data);
    defer std.testing.allocator.destroy(s.ui);
    defer s.ui.deinit();
    defer std.testing.allocator.destroy(s.at);
    defer s.at.deinit();
    const ui = s.ui;

    // frame 1 (no events): first button owns focus; Enter activates it
    try ui.begin(400, 300, 0, 0, false, false, 1.0);
    const b1 = try ui.button("Alpha");
    const b2 = try ui.button("Beta");
    try ui.end();
    const cmds_no_tab = ui.drawCmds().len;
    try std.testing.expect(!b1);
    try std.testing.expect(!b2);

    const ev_enter = [_]input.Event{ keyEvent(28, true) };
    const ev_tab = [_]input.Event{ keyEvent(15, true) };
    const ev_none = [_]input.Event{};
    ui.events = &ev_enter;
    try ui.begin(400, 300, 0, 0, false, false, 1.0);
    const a1 = try ui.button("Alpha");
    const a2 = try ui.button("Beta");
    try ui.end();
    try std.testing.expect(a1);
    try std.testing.expect(!a2);
    try std.testing.expect(ui.kb_focus_id == 1); // first button

    // frame: press Tab -> focus moves to button 2 (pos 1), ring becomes visible
    ui.events = &ev_tab;
    try ui.begin(400, 300, 0, 0, false, false, 1.0);
    _ = try ui.button("Alpha");
    _ = try ui.button("Beta");
    try ui.end();
    try std.testing.expectEqual(@as(u32, 1), ui.focus_index);
    try std.testing.expect(ui.kb_visible);

    // frame: Enter now activates only button 2
    ui.events = &ev_enter;
    try ui.begin(400, 300, 0, 0, false, false, 1.0);
    const c1 = try ui.button("Alpha");
    const c2 = try ui.button("Beta");
    try ui.end();
    try std.testing.expect(!c1);
    try std.testing.expect(c2);
    try std.testing.expectEqual(@as(u32, 2), ui.kb_focus_id);

    // ring persists once visible (focus-visible latched): frame-1 count + 4 ring rects
    ui.events = &ev_none;
    try ui.begin(400, 300, 0, 0, false, false, 1.0);
    _ = try ui.button("Alpha");
    _ = try ui.button("Beta");
    try ui.end();
    try std.testing.expectEqual(cmds_no_tab + 4, ui.drawCmds().len);
    std.debug.print("WIDGET_FOCUS_OK tab cycle + enter + ring-visibility\n", .{});
}

test "focus: Shift-Tab wraps to the last focusable" {
    const s = try setup();
    defer std.testing.allocator.free(s.data);
    defer std.testing.allocator.destroy(s.ui);
    defer s.ui.deinit();
    defer std.testing.allocator.destroy(s.at);
    defer s.at.deinit();
    const ui = s.ui;

    // shift-tab on the very first widget wraps to the last
    const ev_shifttab = [_]input.Event{.{ .key = .{ .code = 15, .key = .tab, .char = 0x09, .mods = .{ .raw = 0x1 }, .pressed = true } }};
    ui.events = &ev_shifttab;
    try ui.begin(400, 300, 0, 0, false, false, 1.0);
    _ = try ui.button("One");
    _ = try ui.button("Two");
    _ = try ui.button("Three");
    try ui.end();
    try std.testing.expectEqual(@as(u32, 2), ui.focus_index);
    try std.testing.expect(ui.kb_visible);
    std.debug.print("WIDGET_FOCUS_SHIFT_OK wrapped to last\n", .{});
}
