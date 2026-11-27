//! Retained, UTF-8-aware text editing state and its immediate-mode renderer.
//! TextField owns the buffer, selection and text-input-v3 session. Runtime
//! supplies frame events and sends the session's ordered request batches.
const std = @import("std");
const grapheme = @import("../ui/text/grapheme.zig");
const edit = @import("../ui/text/edit.zig");
const input = @import("input.zig");
const ui_mod = @import("../ui/ui.zig");
const layout = @import("../ui/layout.zig");
const ti = @import("text_input.zig");

pub const EditBuffer = edit.EditBuffer;
pub const Motion = edit.Motion;
pub const Purpose = ti.Purpose;
pub const Hint = ti.Hint;

pub const Props = struct {
    purpose: Purpose = .normal,
    hint: Hint = .{},
    placeholder: []const u8 = "",
    secret: bool = false,
    clipboard: bool = true,
    submit_on_enter: bool = false,
};

pub const Outcome = struct {
    changed: bool = false,
    submitted: bool = false,
    focused: bool = false,
    blurred: bool = false,
    had_ime_commit: bool = false,
};

pub const ClipboardAction = enum { copy, cut, paste };

pub const TextField = struct {
    buffer: EditBuffer,
    props: Props = .{},
    session: ti.Session = .{},
    id: u32 = 0,
    bounds: layout.Rect = .{},
    focused: bool = false,
    scroll_x: f32 = 0,
    scroll_y: f32 = 0,
    caret_x: f32 = 0,
    caret_y: f32 = 0,
    caret_h: f32 = 0,
    needs_surrounding: bool = true,
    sync_cause: ti.ChangeCause = .input_method,
    last: Outcome = .{},
    runtime_seen: u64 = 0,
    ime_frame: u64 = 0,
    caret_phase: f32 = 0,
    dragging: bool = false,
    ime_surface: bool = false,
    needs_disable_commit: bool = false,
    pending: ti.Pending = .{},
    pending_action: u32 = 0,
    last_revision: u64 = 0,
    last_cursor: usize = 0,
    last_anchor: usize = 0,
    language_buf: [128]u8 = undefined,
    language_len: usize = 0,
    secret_cells: [256]u8 = undefined,

    pub fn init(allocator: std.mem.Allocator, props: Props) TextField {
        return .{ .buffer = EditBuffer.init(allocator), .props = props };
    }

    pub fn deinit(self: *TextField) void {
        self.buffer.deinit();
    }

    pub fn text(self: *const TextField) []const u8 {
        return self.buffer.text();
    }

    pub fn setText(self: *TextField, value: []const u8) !void {
        try self.buffer.setText(value);
        self.needs_surrounding = true;
        self.pending.clear();
        self.pending_action = 0;
    }

    pub fn focus(self: *TextField) void {
        if (self.focused) return;
        self.focused = true;
        self.needs_disable_commit = false;
        self.last.focused = true;
        self.needs_surrounding = true;
        self.pending.clear();
        self.pending_action = 0;
        if (self.ime_surface) self.session.enableField(self.props.purpose, self.props.hint);
    }

    pub fn blur(self: *TextField) void {
        if (!self.focused) return;
        self.focused = false;
        self.last.blurred = true;
        self.dragging = false;
        self.pending.clear();
        self.pending_action = 0;
        self.buffer.setPreedit("") catch {};
        if (self.session.enabled) {
            self.session.disableField();
            self.needs_disable_commit = true;
        }
    }

    pub fn click(self: *TextField, x_inside: f32, atlas: anytype, extend: bool) void {
        self.clickAt(x_inside, 0, atlas, extend);
    }

    pub fn clickAt(self: *TextField, x_inside: f32, y_inside: f32, atlas: anytype, extend: bool) void {
        self.focus();
        const pos = self.hitPosition(x_inside, y_inside, atlas);
        self.buffer.setCursorByte(pos.byte, extend);
        self.dragging = true;
        self.needs_surrounding = true;
    }

    pub fn dragTo(self: *TextField, x_inside: f32, atlas: anytype) void {
        self.dragAt(x_inside, 0, atlas);
    }

    pub fn dragAt(self: *TextField, x_inside: f32, y_inside: f32, atlas: anytype) void {
        if (!self.dragging) return;
        self.buffer.setCursorByte(self.hitPosition(x_inside, y_inside, atlas).byte, true);
        self.needs_surrounding = true;
    }

    pub fn endDrag(self: *TextField) void {
        self.dragging = false;
    }

    const Hit = struct { byte: usize, x: f32 = 0, y: f32 = 0 };

    fn hitPosition(self: *const TextField, x_inside: f32, y_inside: f32, atlas: anytype) Hit {
        const contents = self.text();
        if (!self.props.hint.multiline) return .{ .byte = atlas.cursorByteAt(contents, x_inside + self.scroll_x) };
        const line_h = lineHeight(atlas);
        var line: usize = if (line_h > 0) @intFromFloat(@max(0, @floor((y_inside + self.scroll_y) / line_h))) else 0;
        var start: usize = 0;
        while (line > 0 and start < contents.len) : (line -= 1) {
            start = (std.mem.indexOfScalarPos(u8, contents, start, '\n') orelse return .{ .byte = contents.len }) + 1;
        }
        const end = std.mem.indexOfScalarPos(u8, contents, start, '\n') orelse contents.len;
        return .{ .byte = start + atlas.cursorByteAt(contents[start..end], x_inside + self.scroll_x) };
    }

    pub fn handleKey(self: *TextField, k: input.KeyEvent) bool {
        if (!k.pressed) return false;
        const shift = k.mods.shift();
        const ctrl = k.mods.ctrl();
        if (k.mods.alt()) return false;
        if (ctrl) {
            switch (k.key) {
                .right => {
                    self.buffer.move(.word_right, shift);
                    self.needs_surrounding = true;
                    return true;
                },
                .left => {
                    self.buffer.move(.word_left, shift);
                    self.needs_surrounding = true;
                    return true;
                },
                .home => {
                    self.buffer.move(.doc_start, shift);
                    self.needs_surrounding = true;
                    return true;
                },
                .end => {
                    self.buffer.move(.doc_end, shift);
                    self.needs_surrounding = true;
                    return true;
                },
                .delete => {
                    self.noteMutation(self.buffer.deleteWordForward(.other) catch false);
                    return true;
                },
                .backspace => {
                    self.noteMutation(self.buffer.deleteWordBackward(.other) catch false);
                    return true;
                },
                .printable => if (k.char) |c| {
                    if (!self.props.clipboard and (c == 'c' or c == 'C' or c == 'x' or c == 'X' or c == 'v' or c == 'V')) return true;
                    if (self.props.clipboard and (c == 'c' or c == 'C' or c == 'x' or c == 'X' or c == 'v' or c == 'V')) return true;
                    if (c == 'a' or c == 'A') {
                        self.buffer.selectAll();
                        self.needs_surrounding = true;
                        return true;
                    }
                    if (c == 'z' or c == 'Z') {
                        const changed = if (shift) self.buffer.redo() else self.buffer.undo();
                        if (changed) {
                            self.last.changed = true;
                            self.needs_surrounding = true;
                        }
                        return true;
                    }
                    if (c == 'y') {
                        if (self.buffer.redo()) {
                            self.last.changed = true;
                            self.needs_surrounding = true;
                        }
                        return true;
                    }
                },
                else => {},
            }
            return false;
        }
        switch (k.key) {
            .backspace => {
                self.noteMutation(self.buffer.deleteBackward(.other) catch false);
                return true;
            },
            .delete => {
                self.noteMutation(self.buffer.deleteForward(.other) catch false);
                return true;
            },
            .left => {
                self.buffer.move(.left, shift);
                self.needs_surrounding = true;
                return true;
            },
            .right => {
                self.buffer.move(.right, shift);
                self.needs_surrounding = true;
                return true;
            },
            .up => {
                self.buffer.move(.up, shift);
                self.needs_surrounding = true;
                return true;
            },
            .down => {
                self.buffer.move(.down, shift);
                self.needs_surrounding = true;
                return true;
            },
            .home => {
                self.buffer.move(.line_start, shift);
                self.needs_surrounding = true;
                return true;
            },
            .end => {
                self.buffer.move(.line_end, shift);
                self.needs_surrounding = true;
                return true;
            },
            .enter, .keypad_enter => {
                if (self.props.hint.multiline and !self.props.submit_on_enter) self.noteInsert("\n", 0) else self.last.submitted = true;
                return true;
            },
            .tab => return false,
            .esc => return false,
            .printable, .space => {
                if (k.char) |cp| if (cp >= 0x20 and cp != 0x7F) {
                    var bytes: [8]u8 = undefined;
                    const n = std.unicode.utf8Encode(cp, &bytes) catch return true;
                    self.noteInsert(bytes[0..n], typingKey(k.code));
                };
                return true;
            },
            else => return false,
        }
    }

    fn typingKey(code: u32) u32 {
        return code | 0x1000_0000;
    }

    fn noteInsert(self: *TextField, value: []const u8, key: u32) void {
        const before = self.buffer.revision;
        self.buffer.insert(value, key, .other) catch return;
        self.noteMutation(self.buffer.revision != before);
    }

    fn noteMutation(self: *TextField, changed: bool) void {
        if (!changed) return;
        self.last.changed = true;
        self.needs_surrounding = true;
        self.sync_cause = .other;
    }

    /// Runtime handles clipboard I/O; these methods remain useful to custom
    /// hosts that provide their own selection backend.
    pub fn paste(self: *TextField, data: []const u8) void {
        var clean = std.ArrayList(u8).empty;
        defer clean.deinit(self.buffer.allocator);
        var slice = data;
        if (!self.props.hint.multiline) {
            clean.appendSlice(self.buffer.allocator, data) catch return;
            for (clean.items) |*c| if (c.* == '\n' or c.* == '\r' or c.* == '\t') {
                c.* = ' ';
            };
            slice = clean.items;
        }
        self.noteInsert(slice, 0);
        self.buffer.endEditRun();
    }

    pub fn copyText(self: *const TextField) []const u8 {
        return self.buffer.selectedText();
    }

    pub fn cut(self: *TextField) void {
        self.noteMutation(self.buffer.deleteBackward(.other) catch false);
    }

    pub fn clipboardAction(self: *const TextField, k: input.KeyEvent) ?ClipboardAction {
        if (!self.props.clipboard or !k.pressed or !k.mods.ctrl() or k.mods.alt() or k.key != .printable) return null;
        const c = k.char orelse return null;
        return switch (c) {
            'c', 'C' => .copy,
            'x', 'X' => .cut,
            'v', 'V' => .paste,
            else => null,
        };
    }

    /// Synchronize compositor surface focus independently of logical field
    /// focus. Events before the first frame are retained by Runtime.
    pub fn setSurfaceFocus(self: *TextField, focused: bool) void {
        self.handleIme(if (focused) .enter else .leave);
    }

    /// Queue one event. No commit/delete/preedit is applied until `done`.
    pub fn handleIme(self: *TextField, ev: input.ImeEvent) void {
        switch (ev) {
            .enter => {
                self.ime_surface = true;
                self.session.setFocus(true);
                self.session.have_surrounding = false;
                self.needs_surrounding = true;
                self.pending.clear();
                self.pending_action = 0;
                if (self.focused) self.session.enableField(self.props.purpose, self.props.hint);
            },
            .leave => {
                self.ime_surface = false;
                self.session.invalidateAfterLeave();
                self.pending.clear();
                self.pending_action = 0;
                self.buffer.setPreedit("") catch {};
                self.needs_surrounding = true;
                self.needs_disable_commit = false;
            },
            .preedit => |p| {
                if (p.cursor_begin < -1 or p.cursor_end < -1 or p.cursor_begin > p.cursor_end) return;
                if (p.cursor_begin >= 0 and (p.cursor_end > p.text.len or
                    !grapheme.isCodepointBoundary(p.text, @intCast(p.cursor_begin)) or
                    !grapheme.isCodepointBoundary(p.text, @intCast(p.cursor_end)))) return;
                self.pending.preedit = p.text;
                self.pending.preedit_cursor_begin = p.cursor_begin;
                self.pending.preedit_cursor_end = p.cursor_end;
            },
            .commit => |value| self.pending.commit = value,
            .delete_surrounding => |d| {
                self.pending.delete_before = d.before;
                self.pending.delete_after = d.after;
            },
            .done => |serial| self.applyDone(serial),
            .action => |a| self.pending_action = a,
            .language => |lang| {
                const n = @min(lang.len, self.language_buf.len);
                @memcpy(self.language_buf[0..n], lang[0..n]);
                self.language_len = n;
                self.buffer.language = self.language_buf[0..n];
                self.session.language = self.buffer.language;
            },
        }
    }

    fn applyDone(self: *TextField, serial: u32) void {
        if (!self.focused) {
            self.pending.clear();
            self.pending_action = 0;
            self.session.noteDone(serial);
            return;
        }
        const revision = self.buffer.revision;
        const had_commit = self.pending.commit.len > 0;
        self.buffer.applyIme(
            self.pending.commit,
            self.pending.delete_before,
            self.pending.delete_after,
            self.pending.preedit,
            self.pending.preedit_cursor_begin,
            self.pending.preedit_cursor_end,
        ) catch return;
        self.pending.clear();
        if (self.buffer.revision != revision) {
            self.last.changed = true;
            self.last.had_ime_commit = self.last.had_ime_commit or had_commit;
            self.needs_surrounding = true;
        } else {
            self.needs_surrounding = true;
        }
        self.sync_cause = if (self.buffer.revision != revision) .input_method else .other;
        if (self.pending_action == 1) self.last.submitted = true;
        self.pending_action = 0;
        self.session.noteDone(serial);
    }

    pub fn syncIme(self: *TextField, atlas: anytype, bounds: layout.Rect, window_h: f32) bool {
        _ = window_h;
        if (!self.focused) return self.needs_disable_commit and self.session.pending;
        if (!self.ime_surface) return false;
        if (self.buffer.revision != self.last_revision or self.buffer.cursor != self.last_cursor or self.buffer.anchor != self.last_anchor) {
            self.needs_surrounding = true;
            self.session.setChangeCause(switch (self.buffer.last_cause) {
                .input_method => .input_method,
                .other => .other,
            });
        }
        self.last_revision = self.buffer.revision;
        self.last_cursor = self.buffer.cursor;
        self.last_anchor = self.buffer.anchor;
        if (self.needs_surrounding) {
            self.session.setChangeCause(self.sync_cause);
            const w = ti.Session.surroundingWindow(self.text(), self.buffer.cursor, self.buffer.anchor, 4000);
            self.session.setSurrounding(self.text()[w.start..w.end], w.cursor, w.anchor);
            self.needs_surrounding = false;
        }
        const caret = self.caretGeometry(atlas, bounds);
        self.caret_x = caret.x;
        self.caret_y = caret.y;
        self.caret_h = caret.h;
        self.session.setCursorRect(caret.x, caret.y, 2, caret.h);
        return self.session.pending;
    }

    const Caret = struct { x: f32, y: f32, h: f32 };

    fn caretGeometry(self: *TextField, atlas: anytype, bounds: layout.Rect) Caret {
        const pad: f32 = 8;
        const lh = lineHeight(atlas);
        var line_start: usize = 0;
        var line: usize = 0;
        const cursor = self.buffer.cursor;
        while (std.mem.indexOfScalarPos(u8, self.text(), line_start, '\n')) |nl| {
            if (nl >= cursor) break;
            line_start = nl + 1;
            line += 1;
        }
        const logical_h = if (self.props.hint.multiline) lh else @max(lh, bounds.h - 8);
        const target_y = @as(f32, @floatFromInt(line)) * lh;
        if (self.props.hint.multiline) {
            if (target_y < self.scroll_y) self.scroll_y = target_y;
            if (target_y + lh > self.scroll_y + bounds.h - 2 * pad) self.scroll_y = @max(0, target_y + lh - bounds.h + 2 * pad);
        }
        const before_w = if (self.props.secret)
            @as(f32, @floatFromInt(grapheme.count(self.text()[line_start..cursor]))) * atlas.measureWidth("*")
        else
            atlas.measureWidth(self.text()[line_start..cursor]);
        const available = @max(0, bounds.w - 2 * pad);
        if (before_w < self.scroll_x) self.scroll_x = before_w;
        if (before_w > self.scroll_x + available - 2) self.scroll_x = @max(0, before_w - available + 2);
        if (atlas.measureWidth(if (self.props.secret) "" else self.text()[line_start..(std.mem.indexOfScalarPos(u8, self.text(), line_start, '\n') orelse self.text().len)]) <= available) self.scroll_x = 0;
        return .{
            .x = bounds.x + pad + before_w - self.scroll_x,
            .y = bounds.y + pad + target_y - self.scroll_y + (if (self.props.hint.multiline) @as(f32, 0) else @max(0, (bounds.h - 2 * pad - lh) / 2)),
            .h = logical_h,
        };
    }

    fn lineHeight(atlas: anytype) f32 {
        return @as(f32, @floatFromInt(atlas.font.ascender - atlas.font.descender + atlas.font.line_gap)) * atlas.scale;
    }

    pub fn draw(self: *TextField, ui: *ui_mod.Ui, rect: layout.Rect, atlas: anytype) !void {
        try ui.addRect(rect, if (self.focused) ui_mod.COLOR_BUTTON_HOT else ui_mod.COLOR_BUTTON);
        if (self.focused) try ui.addRect(.{ .x = rect.x, .y = rect.y + rect.h - 1, .w = rect.w, .h = 1 }, ui_mod.COLOR_FOCUS_RING);
        const pad: f32 = 8;
        const lh = lineHeight(atlas);
        const baseline = @as(f32, @floatFromInt(atlas.font.ascender)) * atlas.scale;
        const contents = self.text();
        const preedit = self.buffer.preedit();
        if (self.props.secret) {
            const n = @min(self.buffer.clusterCount(), self.secret_cells.len);
            for (self.secret_cells[0..n]) |*c| c.* = '*';
            try ui.addText(rect.x + pad - self.scroll_x, rect.y + rect.h - 7, self.secret_cells[0..n], ui_mod.COLOR_TEXT);
        } else if (self.props.hint.multiline) {
            try self.drawMultiline(ui, rect, atlas, lh, baseline);
        } else {
            const caret = self.buffer.cursor;
            const top = rect.y + pad + (rect.h - 2 * pad - lh) / 2;
            try self.drawSelection(ui, rect, atlas, pad, top, lh, 0, contents.len);
            const y = rect.y + rect.h - 7;
            if (contents.len == 0 and preedit.len == 0) {
                try ui.addText(rect.x + pad, y, self.props.placeholder, ui_mod.COLOR_TEXT_DIM);
            } else {
                try ui.addText(rect.x + pad - self.scroll_x, y, contents[0..caret], ui_mod.COLOR_TEXT);
                const cx = rect.x + pad + atlas.measureWidth(contents[0..caret]) - self.scroll_x;
                try ui.addText(cx, y, preedit, ui_mod.COLOR_TEXT);
                const pw = atlas.measureWidth(preedit);
                if (pw > 0) try ui.addRect(.{ .x = cx, .y = y + 3, .w = pw, .h = 1 }, ui_mod.COLOR_FOCUS_RING);
                try ui.addText(cx + pw, y, contents[caret..], ui_mod.COLOR_TEXT);
            }
        }
        if (self.focused and @mod(self.caret_phase, 1.0) < 0.6) {
            try ui.addRect(.{ .x = self.caret_x, .y = self.caret_y, .w = 2, .h = self.caret_h }, ui_mod.COLOR_TEXT);
        }
    }

    fn drawSelection(self: *TextField, ui: *ui_mod.Ui, rect: layout.Rect, atlas: anytype, pad: f32, top: f32, lh: f32, line_start: usize, line_end: usize) !void {
        const start = @max(line_start, self.buffer.selectionStart());
        const end = @min(line_end, self.buffer.selectionEnd());
        if (start >= end) return;
        const contents = self.text();
        try ui.addRect(.{
            .x = rect.x + pad + atlas.measureWidth(contents[line_start..start]) - self.scroll_x,
            .y = top,
            .w = atlas.measureWidth(contents[start..end]),
            .h = lh,
        }, ui_mod.COLOR_BUTTON_ACTIVE);
    }

    fn drawMultiline(self: *TextField, ui: *ui_mod.Ui, rect: layout.Rect, atlas: anytype, lh: f32, baseline: f32) !void {
        const pad: f32 = 8;
        const contents = self.text();
        const preedit = self.buffer.preedit();
        var start: usize = 0;
        var row: usize = 0;
        while (start <= contents.len) {
            const nl = std.mem.indexOfScalarPos(u8, contents, start, '\n');
            const end = nl orelse contents.len;
            const top = rect.y + pad + @as(f32, @floatFromInt(row)) * lh - self.scroll_y;
            if (top + lh >= rect.y and top < rect.y + rect.h) {
                const sel_start = @max(start, self.buffer.selectionStart());
                const sel_end = @min(end, self.buffer.selectionEnd());
                if (sel_start < sel_end) {
                    const x = rect.x + pad + atlas.measureWidth(contents[start..sel_start]) - self.scroll_x;
                    try ui.addRect(.{ .x = x, .y = top, .w = atlas.measureWidth(contents[sel_start..sel_end]), .h = lh }, ui_mod.COLOR_BUTTON_ACTIVE);
                }
                const y = top + baseline;
                if (self.buffer.cursor >= start and self.buffer.cursor <= end) {
                    const c = self.buffer.cursor;
                    try ui.addText(rect.x + pad - self.scroll_x, y, contents[start..c], ui_mod.COLOR_TEXT);
                    const cx = rect.x + pad + atlas.measureWidth(contents[start..c]) - self.scroll_x;
                    try ui.addText(cx, y, preedit, ui_mod.COLOR_TEXT);
                    const pw = atlas.measureWidth(preedit);
                    if (pw > 0) try ui.addRect(.{ .x = cx, .y = y + 3, .w = pw, .h = 1 }, ui_mod.COLOR_FOCUS_RING);
                    try ui.addText(cx + pw, y, contents[c..end], ui_mod.COLOR_TEXT);
                } else {
                    try ui.addText(rect.x + pad - self.scroll_x, y, contents[start..end], ui_mod.COLOR_TEXT);
                }
            }
            if (nl == null) break;
            start = end + 1;
            row += 1;
        }
        if (contents.len == 0 and preedit.len == 0) try ui.addText(rect.x + pad, rect.y + pad + baseline, self.props.placeholder, ui_mod.COLOR_TEXT_DIM);
    }
};

fn makeKey(code: u32, k: input.Key, char: ?u21, mods: u32) input.KeyEvent {
    return .{ .code = code, .key = k, .char = char, .mods = .{ .raw = mods }, .pressed = true };
}

test "field: focus waits for surface enter; blur queues disable" {
    var f = TextField.init(std.testing.allocator, .{});
    defer f.deinit();
    f.focus();
    try std.testing.expect(!f.session.enabled);
    f.handleIme(.enter);
    try std.testing.expect(f.session.enabled);
    f.blur();
    try std.testing.expect(f.session.pending);
    try std.testing.expect(!f.focused);
}

test "field: typing is grapheme-safe and undoable" {
    var f = TextField.init(std.testing.allocator, .{});
    defer f.deinit();
    f.focus();
    try std.testing.expect(f.handleKey(makeKey(30, .printable, 'h', 0)));
    try std.testing.expect(f.handleKey(makeKey(30, .printable, 'i', 0)));
    try std.testing.expectEqualStrings("hi", f.text());
    try std.testing.expect(f.handleKey(makeKey(44, .printable, 'z', 4)));
    try std.testing.expectEqualStrings("", f.text());
}

test "field: done applies commit and preedit atomically" {
    var f = TextField.init(std.testing.allocator, .{});
    defer f.deinit();
    try f.setText("ab");
    f.focus();
    f.handleIme(.enter);
    f.handleIme(.{ .preedit = .{ .text = "にほ", .cursor_begin = 0, .cursor_end = 6 } });
    f.handleIme(.{ .commit = "日本" });
    try std.testing.expectEqualStrings("ab", f.text());
    try std.testing.expectEqual(@as(usize, 0), f.buffer.preedit().len);
    f.handleIme(.{ .done = 0 });
    try std.testing.expectEqualStrings("ab日本", f.text());
    try std.testing.expectEqualStrings("にほ", f.buffer.preedit());
    try std.testing.expect(f.last.changed);
    try std.testing.expect(f.last.had_ime_commit);
}

test "field: delete and replacement share one done transaction" {
    var f = TextField.init(std.testing.allocator, .{});
    defer f.deinit();
    try f.setText("abcd");
    f.focus();
    f.handleIme(.enter);
    f.handleIme(.{ .delete_surrounding = .{ .before = 1, .after = 1 } });
    f.handleIme(.{ .commit = "X" });
    try std.testing.expectEqualStrings("abcd", f.text());
    f.handleIme(.{ .done = 0 });
    try std.testing.expectEqualStrings("abcX", f.text());
    f.handleIme(.{ .preedit = .{ .text = "", .cursor_begin = -1, .cursor_end = -1 } });
    f.handleIme(.{ .done = 0 });
}

test "field: stale done still edits and leave clears preedit" {
    var f = TextField.init(std.testing.allocator, .{});
    defer f.deinit();
    f.focus();
    f.handleIme(.enter);
    f.handleIme(.{ .commit = "A" });
    f.handleIme(.{ .done = 99 });
    try std.testing.expectEqualStrings("A", f.text());
    try std.testing.expect(f.session.pending);
    f.handleIme(.{ .preedit = .{ .text = "x", .cursor_begin = 1, .cursor_end = 1 } });
    f.handleIme(.{ .done = 99 });
    try std.testing.expectEqualStrings("x", f.buffer.preedit());
    f.handleIme(.leave);
    try std.testing.expectEqual(@as(usize, 0), f.buffer.preedit().len);
    try std.testing.expect(!f.session.has_focus);
}

test "field: clipboard shortcuts are semantic even with capital characters" {
    var f = TextField.init(std.testing.allocator, .{});
    defer f.deinit();
    try std.testing.expectEqual(ClipboardAction.copy, f.clipboardAction(makeKey(46, .printable, 'C', 5)).?);
    try std.testing.expectEqual(ClipboardAction.cut, f.clipboardAction(makeKey(45, .printable, 'X', 5)).?);
    try std.testing.expectEqual(ClipboardAction.paste, f.clipboardAction(makeKey(47, .printable, 'V', 5)).?);
    f.paste("a\nb\tc");
    try std.testing.expectEqualStrings("a b c", f.text());
}
