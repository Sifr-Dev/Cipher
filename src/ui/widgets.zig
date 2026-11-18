//! Higher-level widgets built on the immediate-mode Ui: slider, checkbox,
//! scrollable list, text input, tabs, progress bar. Custom widgets draw from
//! the previous frame's rect (prev_rects), like button hit-testing.
const std = @import("std");
const layout = @import("layout.zig");
const ui_mod = @import("ui.zig");
const input = @import("../framework/input.zig");

const C = ui_mod;

const zero_rect = layout.Rect{ .x = 0, .y = 0, .w = 0, .h = 0 };

fn lineH(ui: *ui_mod.Ui) f32 {
    const f = ui.atlas.font;
    return @as(f32, @floatFromInt(f.ascender - f.descender + f.line_gap)) * ui.atlas.scale;
}

fn ascent(ui: *ui_mod.Ui) f32 {
    return @as(f32, @floatFromInt(ui.atlas.font.ascender)) * ui.atlas.scale;
}

/// Horizontal slider. `value` is read and written.
pub fn slider(ui: *ui_mod.Ui, w: f32, min: f32, max: f32, value: *f32) !void {
    const id = ui.next_id;
    ui.next_id += 1;
    const st = try ui.wstate(id, .{ .slider = value.* });
    const n = try ui.newNode();
    n.id = id;
    n.w = .{ .fixed = w };
    n.h = .{ .fixed = 24 };
    try ui.current().addChild(ui.allocator(), n);

    const kb = ui.beginFocusable(id);
    const prev = ui.prev_rects.get(id) orelse zero_rect;
    if (ui.mouse_pressed and prev.contains(ui.mouse_x, ui.mouse_y)) {
        ui.active = id;
        ui.focus_index = kb.pos;
    }
    if (kb.focused) {
        const mult: f32 = if (ui.kb_shift) 10 else 1;
        const step = (max - min) / 100.0 * mult;
        if (ui.kb_arrow_left) st.slider = @max(min, st.slider - step);
        if (ui.kb_arrow_right) st.slider = @min(max, st.slider + step);
    }
    if (ui.active == id and ui.mouse_down and prev.w > 0) {
        const frac = std.math.clamp((ui.mouse_x - prev.x) / prev.w, 0.0, 1.0);
        st.slider = min + frac * (max - min);
    }
    if (!ui.mouse_down) ui.active = 0;
    value.* = std.math.clamp(st.slider, min, max);
    st.slider = value.*;

    if (prev.w > 0) {
        const track = layout.Rect{ .x = prev.x, .y = prev.y + prev.h / 2 - 2, .w = prev.w, .h = 4 };
        try ui.addRect(track, C.COLOR_BUTTON);
        const frac = if (max > min) (value.* - min) / (max - min) else 0;
        const hw: f32 = 8;
        const hx = prev.x + frac * (prev.w - hw * 2) + hw;
        try ui.addRect(.{ .x = hx - hw / 2, .y = prev.y + 2, .w = hw, .h = prev.h - 4 }, C.COLOR_TEXT);
    }
}

/// Checkbox with label. Returns true if toggled this frame.
pub fn checkbox(ui: *ui_mod.Ui, label: []const u8, value: *bool) !bool {
    const id = ui.next_id;
    ui.next_id += 1;
    const st = try ui.wstate(id, .{ .checkbox = value.* });
    const n = try ui.newNode();
    n.id = id;
    n.w = .{ .fixed = 18 };
    n.h = .{ .fixed = 18 };
    try ui.current().addChild(ui.allocator(), n);
    const kb = ui.beginFocusable(id);
    const prev = ui.prev_rects.get(id) orelse zero_rect;
    var toggled = false;
    if (ui.mouse_pressed and prev.contains(ui.mouse_x, ui.mouse_y)) {
        st.checkbox = !st.checkbox;
        toggled = true;
        ui.focus_index = kb.pos;
    }
    if (kb.focused and ui.activate_pressed) {
        st.checkbox = !st.checkbox;
        toggled = true;
    }
    value.* = st.checkbox;
    if (prev.w > 0) {
        try ui.addRect(prev, C.COLOR_BUTTON);
        if (st.checkbox) {
            const m: f32 = 4;
            try ui.addRect(.{ .x = prev.x + m, .y = prev.y + m, .w = prev.w - 2 * m, .h = prev.h - 2 * m }, C.COLOR_BUTTON_ACTIVE);
        }
        try ui.addText(prev.x + prev.w + 8, prev.y + prev.h - 4, label, C.COLOR_TEXT);
    }
    return toggled;
}

/// Scrollable single-selection list. `items` are the row strings; `sel` is the
/// selected index (-1 = none). Rows are clickable; wheel scrolls when hovered.
pub fn listView(ui: *ui_mod.Ui, w: f32, rows: u32, items: []const []const u8, sel: *i32) !void {
    const id = ui.next_id;
    ui.next_id += 1;
    const st = try ui.wstate(id, .{ .list = .{ .sel = sel.* } });
    const lh = lineH(ui);
    const n = try ui.newNode();
    n.id = id;
    n.w = .{ .fixed = w };
    n.h = .{ .fixed = lh * @as(f32, @floatFromInt(rows)) + 4 };
    try ui.current().addChild(ui.allocator(), n);

    const kb = ui.beginFocusable(id);
    if (kb.focused) {
        const last: i32 = @intCast(items.len -| 1);
        if (ui.kb_arrow_up) st.list.sel = @max(0, st.list.sel - 1);
        if (ui.kb_arrow_down) st.list.sel = @min(last, st.list.sel + 1);
    }
    const prev = ui.prev_rects.get(id) orelse zero_rect;
    if (prev.w > 0) {
        // wheel scroll when hovered
        if (prev.contains(ui.mouse_x, ui.mouse_y)) {
            for (ui.events) |e| {
                if (e == .wheel and e.wheel.dy != 0) st.list.scroll -= e.wheel.dy * lh;
            }
        }
        if (ui.mouse_pressed and prev.contains(ui.mouse_x, ui.mouse_y)) ui.focus_index = kb.pos;
        const max_scroll = @max(0, @as(f32, @floatFromInt(items.len)) * lh - (prev.h - 4));
        st.list.scroll = std.math.clamp(st.list.scroll, 0, max_scroll);
        // click a row
        if (ui.mouse_pressed and prev.contains(ui.mouse_x, ui.mouse_y)) {
            const row = @as(i32, @intFromFloat(@floor((ui.mouse_y - prev.y - 2 + st.list.scroll) / lh)));
            if (row >= 0 and row < items.len) st.list.sel = row;
        }
        // draw
        try ui.addRect(prev, C.COLOR_PANEL);
        const first: usize = @intFromFloat(@floor(st.list.scroll / lh));
        var i: usize = first;
        while (i < items.len) : (i += 1) {
            const ry = prev.y + 2 + @as(f32, @floatFromInt(i)) * lh - st.list.scroll;
            if (ry + lh < prev.y + 2 or ry > prev.y + prev.h - 2) continue;
            const r = layout.Rect{ .x = prev.x + 2, .y = ry, .w = prev.w - 4, .h = lh };
            const is_sel = @as(i32, @intCast(i)) == st.list.sel;
            try ui.addRect(r, if (is_sel) C.COLOR_BUTTON_ACTIVE else C.COLOR_BUTTON);
            try ui.addText(r.x + 6, r.y + ascent(ui) * 0.8, items[i], if (is_sel) C.COLOR_VOID else C.COLOR_TEXT);
        }
    }
    sel.* = st.list.sel;
}

/// Single-line text input. `buf` is a caller-owned []u8 used as storage;
/// contents persist in widget state across frames. Click to focus, then type.
pub fn textInput(ui: *ui_mod.Ui, w: f32, buf: []u8, hint: []const u8) ![]u8 {
    const id = ui.next_id;
    ui.next_id += 1;
    const st = try ui.wstate(id, .{ .text = .{ .len = 0, .cursor = 0 } });
    if (st.text.len == 0 and buf.len > 0) {
        const n = @min(buf.len, st.text.buf.len);
        @memcpy(st.text.buf[0..n], buf[0..n]);
        st.text.len = n;
        st.text.cursor = n;
    }
    const n = try ui.newNode();
    n.id = id;
    n.w = .{ .fixed = w };
    n.h = .{ .fixed = lineH(ui) + 10 };
    try ui.current().addChild(ui.allocator(), n);

    const kb = ui.beginFocusable(id);
    const prev = ui.prev_rects.get(id) orelse zero_rect;
    if (ui.mouse_pressed) {
        if (prev.contains(ui.mouse_x, ui.mouse_y)) {
            ui.active = id;
            ui.focus_index = kb.pos;
        } else if (ui.active == id) ui.active = 0;
    }
    const focused = ui.active == id or kb.focused;
    if (focused) {
        for (ui.events) |e| {
            switch (e) {
                .key => |k| {
                    if (!k.pressed) continue;
                    if (k.mods.ctrl() or k.mods.alt()) continue;
                    switch (k.key) {
                        .backspace => {
                            if (st.text.cursor > 0 and st.text.len > 0) {
                                const c = st.text.cursor;
                                @memcpy(st.text.buf[c - 1 .. st.text.len - 1], st.text.buf[c..st.text.len]);
                                st.text.len -= 1;
                                st.text.cursor -= 1;
                            }
                        },
                        .delete => {
                            if (st.text.cursor < st.text.len) {
                                const c = st.text.cursor;
                                @memcpy(st.text.buf[c..st.text.len - 1], st.text.buf[c + 1 .. st.text.len]);
                                st.text.len -= 1;
                            }
                        },
                        .left => st.text.cursor = if (st.text.cursor > 0) st.text.cursor - 1 else 0,
                        .right => st.text.cursor = @min(st.text.cursor + 1, st.text.len),
                        .home => st.text.cursor = 0,
                        .end => st.text.cursor = st.text.len,
                        else => {
                            if (k.char) |c| {
                                if (c >= 0x20 and c < 0x7F and st.text.len < st.text.buf.len) {
                                    const ci = st.text.cursor;
                                    @memcpy(st.text.buf[ci + 1 .. st.text.len + 1], st.text.buf[ci..st.text.len]);
                                    st.text.buf[ci] = @intCast(c);
                                    st.text.len += 1;
                                    st.text.cursor += 1;
                                }
                            }
                        },
                    }
                },
                .paste => |p| {
                    for (p) |ch| {
                        if (ch >= 0x20 and ch < 0x7F and st.text.len < st.text.buf.len) {
                            const ci = st.text.cursor;
                            @memcpy(st.text.buf[ci + 1 .. st.text.len + 1], st.text.buf[ci..st.text.len]);
                            st.text.buf[ci] = ch;
                            st.text.len += 1;
                            st.text.cursor += 1;
                        }
                    }
                },
                else => {},
            }
        }
    }
    if (prev.w > 0) {
        try ui.addRect(prev, if (focused) C.COLOR_BUTTON_HOT else C.COLOR_BUTTON);
        const text = st.text.buf[0..st.text.len];
        if (text.len > 0) {
            try ui.addText(prev.x + 8, prev.y + prev.h - 7, text, C.COLOR_TEXT);
        } else {
            try ui.addText(prev.x + 8, prev.y + prev.h - 7, hint, C.COLOR_TEXT_DIM);
        }
        if (focused) {
            const before = text[0..@min(st.text.cursor, text.len)];
            const tw = (ui.atlas.measure(before) catch 0) / ui.scale;
            try ui.addRect(.{ .x = prev.x + 8 + tw, .y = prev.y + 5, .w = 2, .h = prev.h - 10 }, C.COLOR_TEXT);
        }
    }
    return st.text.buf[0..st.text.len];
}

/// Tab bar. `sel` is the selected tab index.
pub fn tabs(ui: *ui_mod.Ui, labels: []const []const u8, sel: *i32) !void {
    const base_id = ui.next_id;
    ui.next_id += @intCast(labels.len);
    const st = try ui.wstate(base_id, .{ .tabs = sel.* });
    const n = try ui.newNode();
    n.id = base_id;
    n.dir = .row;
    n.gap = 4;
    n.h = .{ .fixed = lineH(ui) + 10 };
    n.w = .fit;
    try ui.current().addChild(ui.allocator(), n);
    const kb = ui.beginFocusable(base_id);
    if (kb.focused) {
        const last: i32 = @intCast(labels.len -| 1);
        if (ui.kb_arrow_left and st.tabs > 0) st.tabs -= 1;
        if (ui.kb_arrow_right and st.tabs < last) st.tabs += 1;
    }
    for (labels, 0..) |lab, i| {
        const tid = base_id + 1 + @as(u32, @intCast(i));
        const tn = try ui.newNode();
        tn.id = tid;
        tn.w = .{ .fixed = @max(64, ui.atlas.measure(lab) catch 0 + 24) };
        tn.h = .{ .fixed = lineH(ui) + 10 };
        try n.addChild(ui.allocator(), tn);
        const prev = ui.prev_rects.get(tid) orelse zero_rect;
        if (ui.mouse_pressed and prev.contains(ui.mouse_x, ui.mouse_y)) {
            st.tabs = @intCast(i);
            ui.focus_index = kb.pos;
        }
        if (prev.w > 0) {
            const active = st.tabs == @as(i32, @intCast(i));
            try ui.addRect(prev, if (active) C.COLOR_BUTTON_ACTIVE else C.COLOR_BUTTON);
            const tw = (ui.atlas.measure(lab) catch 0) / ui.scale;
            try ui.addText(prev.x + (prev.w - tw) / 2, prev.y + prev.h - 7, lab, if (active) C.COLOR_VOID else C.COLOR_TEXT);
        }
    }
    sel.* = st.tabs;
}

/// Progress bar, frac in [0,1].
pub fn progress(ui: *ui_mod.Ui, w: f32, frac: f32) !void {
    const id = ui.next_id;
    ui.next_id += 1;
    const n = try ui.newNode();
    n.id = id;
    n.w = .{ .fixed = w };
    n.h = .{ .fixed = 8 };
    try ui.current().addChild(ui.allocator(), n);
    const prev = ui.prev_rects.get(id) orelse zero_rect;
    if (prev.w > 0) {
        try ui.addRect(prev, C.COLOR_BUTTON);
        const f = std.math.clamp(frac, 0, 1);
        try ui.addRect(.{ .x = prev.x, .y = prev.y, .w = prev.w * f, .h = prev.h }, C.COLOR_BUTTON_ACTIVE);
    }
}
