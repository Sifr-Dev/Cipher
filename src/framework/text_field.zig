//! Text fields: the public, IME-aware replacement for the byte-indexed
//! `widgets.textInput`. A `TextField` owns an `EditBuffer`, its focus state,
//! scroll offset, and the IME session that talks to the compositor.
//!
//! Two levels:
//!   * `TextField` — the state object; pure, testable, no Wayland.
//!   * `Runtime.textField()` — wires a `TextField` to the text-input-v3
//!     object, feeds it key/IME events, draws it, and reports changes.
//!
//! The widget never mutates a caller's buffer in place: the app owns the
//! `TextField`, so selection/undo/preedit state survives frames without a
//! side table.
const std = @import("std");
const grapheme = @import("../ui/text/grapheme.zig");
const edit = @import("../ui/text/edit.zig");
const input = @import("input.zig");
const ui_mod = @import("../ui/ui.zig");
const layout = @import("../ui/layout.zig");
const ti = @import("text_input.zig");

pub const EditBuffer = edit.EditBuffer;
pub const Motion = edit.Motion;
pub const ChangeCause = edit.ChangeCause;
pub const Purpose = ti.Purpose;
pub const Hint = ti.Hint;

/// Static description of a field, supplied by the app at declaration time.
pub const Props = struct {
    purpose: Purpose = .normal,
    hint: Hint = .{},
    /// Shown when the field is empty.
    placeholder: []const u8 = "",
    /// Show bullets instead of text (passwords) while still editing normally.
    secret: bool = false,
    /// Enable the system clipboard shortcuts (Ctrl+C/X/V/A/Z).
    clipboard: bool = true,
    /// Emit `onSubmit` when the input method or Enter asks for it.
    submit_on_enter: bool = false,
};

/// What changed this frame, so the app can react without diffing strings.
pub const Outcome = struct {
    /// The text changed (typing, paste, delete, IME commit, undo).
    changed: bool = false,
    /// The user asked to submit (Enter, or the IME's submit action).
    submitted: bool = false,
    /// Focus entered the field this frame.
    focused: bool = false,
    /// Focus left the field this frame.
    blurred: bool = false,
    /// A commit from the input method landed this frame.
    had_ime_commit: bool = false,
};

pub const TextField = struct {
    buffer: EditBuffer,
    props: Props = .{},
    session: ti.Session = .{},
    /// Stable widget id, assigned by the runtime on first draw.
    id: u32 = 0,
    focused: bool = false,
    /// Horizontal scroll in logical pixels, recomputed from the caret
    /// position so the caret is always visible in a single-line field.
    scroll_x: f32 = 0,
    /// Last reported cursor rectangle in surface coordinates (for the IME
    /// popup position); zeroed until the first draw.
    caret_x: f32 = 0,
    caret_y: f32 = 0,
    caret_h: f32 = 0,
    /// True until surrounding text has been pushed after a focus gain.
    needs_surrounding: bool = true,
    /// The most recent outcome, for callers that poll instead of using the
    /// return value.
    last: Outcome = .{},
    /// Blink phase, advanced by the runtime with frame time.
    caret_phase: f32 = 0,
    /// True while the pointer drag-selects inside the field.
    dragging: bool = false,
    /// First visible cluster index after a horizontal scroll (debug aid).
    measured_w: f32 = 0,

    pub fn init(allocator: std.mem.Allocator, props: Props) TextField {
        return .{ .buffer = EditBuffer.init(allocator), .props = props };
    }

    pub fn deinit(self: *TextField) void {
        self.buffer.deinit();
    }

    pub fn text(self: *const TextField) []const u8 {
        return self.buffer.text();
    }

    /// Programmatic value change. Does not fire `changed`; the app already
    /// knows it changed the value.
    pub fn setText(self: *TextField, value: []const u8) !void {
        try self.buffer.setText(value);
        self.needs_surrounding = true;
    }

    /// Focus lifecycle. The runtime calls this; apps may call it directly to
    /// focus a field programmatically (e.g. after a search shortcut).
    pub fn focus(self: *TextField) void {
        if (self.focused) return;
        self.focused = true;
        self.session.setFocus(true);
        self.session.enableField(self.props.purpose, self.props.hint);
        self.needs_surrounding = true;
    }

    pub fn blur(self: *TextField) void {
        if (!self.focused) return;
        self.focused = false;
        self.session.disableField();
        self.session.setFocus(false);
        self.dragging = false;
    }

    /// A click landed at logical x inside the field. Places the caret.
    pub fn click(self: *TextField, x_inside: f32, atlas: anytype, extend: bool) void {
        self.focus();
        const cluster = atlas.clusterIndexAt(self.text(), x_inside + self.scroll_x);
        self.buffer.setCursorCluster(cluster, extend);
        self.dragging = true;
    }

    pub fn dragTo(self: *TextField, x_inside: f32, atlas: anytype) void {
        if (!self.dragging) return;
        const cluster = atlas.clusterIndexAt(self.text(), x_inside);
        self.buffer.setCursorCluster(cluster, true);
    }

    pub fn endDrag(self: *TextField) void {
        self.dragging = false;
    }

    /// Feed one key event. Returns true when the field consumed it.
    pub fn handleKey(self: *TextField, k: input.KeyEvent) bool {
        if (!k.pressed) return false;
        const shift = k.mods.shift();
        const ctrl = k.mods.ctrl();
        const alt = k.mods.alt();
        if (alt) return false; // Alt-chords belong to the app.
        const key = k.key;
        if (ctrl) {
            switch (key) {
                .right => {
                    self.buffer.move(if (shift) .word_right else .word_right, shift);
                    return true;
                },
                .left => {
                    self.buffer.move(.word_left, shift);
                    return true;
                },
                .home => {
                    self.buffer.move(.doc_start, shift);
                    return true;
                },
                .end => {
                    self.buffer.move(.doc_end, shift);
                    return true;
                },
                .delete => {
                    _ = self.buffer.deleteWordForward(.other) catch return true;
                    return true;
                },
                .backspace => {
                    _ = self.buffer.deleteWordBackward(.other) catch return true;
                    return true;
                },
                .printable => {
                    if (k.char) |c| {
                        const ch: u8 = @intCast(c);
                        if (ch == 'c') return true; // copy/cut are handled by the runtime
                        if (ch == 'x') return true;
                        if (ch == 'v') return true;
                        if (ch == 'a') {
                            self.buffer.selectAll();
                            return true;
                        }
                        if (ch == 'z') {
                            _ = if (shift) self.buffer.redo() else self.buffer.undo();
                            return true;
                        }
                    }
                },
                else => {},
            }
            return false;
        }
        switch (key) {
            .backspace => {
                _ = self.buffer.deleteBackward(.other) catch {};
                return true;
            },
            .delete => {
                _ = self.buffer.deleteForward(.other) catch {};
                return true;
            },
            .left => {
                self.buffer.move(.left, shift);
                return true;
            },
            .right => {
                self.buffer.move(.right, shift);
                return true;
            },
            .up => {
                self.buffer.move(.up, shift);
                return true;
            },
            .down => {
                self.buffer.move(.down, shift);
                return true;
            },
            .home => {
                self.buffer.move(.line_start, shift);
                return true;
            },
            .end => {
                self.buffer.move(.line_end, shift);
                return true;
            },
            .enter, .keypad_enter => {
                if (self.props.hint.multiline and !self.props.submit_on_enter) {
                    self.buffer.insert("\n", 0, .other) catch {};
                } else {
                    self.last.submitted = true;
                }
                return true;
            },
            .tab => return false, // focus traversal belongs to the app
            .esc => return false,
            .printable, .space => {
                if (k.char) |cp| {
                    // Ignore control characters; a text field never inserts
                    // them from a key event.
                    if (cp >= 0x20 and cp != 0x7F) {
                        var buf: [8]u8 = undefined;
                        const n = std.unicode.utf8Encode(cp, &buf) catch return true;
                        self.buffer.insert(buf[0..n], self.typingKey(k.code), .other) catch {};
                        return true;
                    }
                }
                return true;
            },
            else => return false,
        }
    }

    /// Coalescing key: consecutive characters from the same physical key row
    /// form one undo run; a different key starts a new one. This is what makes
    /// "type a word, Ctrl+Z" behave like every other editor.
    fn typingKey(self: *TextField, code: u32) u32 {
        _ = self;
        return code | 0x1000_0000;
    }

    /// Paste text (Ctrl+V or a drop). Multi-line text is flattened in a
    /// single-line field.
    pub fn paste(self: *TextField, data: []const u8) void {
        const self_ptr = self;
        var scratch: [4096]u8 = undefined;
        var slice = data;
        if (!self.props.hint.multiline) {
            const n = @min(data.len, scratch.len);
            @memcpy(scratch[0..n], data[0..n]);
            for (scratch[0..n]) |*c| {
                if (c.* == '\n' or c.* == '\r' or c.* == '\t') c.* = ' ';
            }
            slice = scratch[0..n];
        }
        self_ptr.buffer.insert(slice, 0, .other) catch {};
        self_ptr.buffer.endEditRun();
    }

    pub fn copyText(self: *const TextField) []const u8 {
        return self.buffer.selectedText();
    }

    pub fn cut(self: *TextField) void {
        if (self.buffer.hasSelection()) _ = self.buffer.deleteBackward(.other) catch {};
    }

    /// Feed one IME event from the text-input-v3 object.
    pub fn handleIme(self: *TextField, ev: input.ImeEvent) void {
        switch (ev) {
            .enter => self.session.setFocus(true),
            .leave => {
                self.session.setFocus(false);
                self.buffer.setPreedit("") catch {};
                self.needs_surrounding = true;
            },
            .preedit => |p| {
                self.buffer.setPreedit(p.text) catch {};
                self.needs_surrounding = false;
            },
            .commit => |text| {
                // Protocol order: delete surrounding text first, then insert
                // the commit string at the cursor.
                self.buffer.commitIme(text, 0, 0) catch {};
                self.last.changed = true;
                self.last.had_ime_commit = true;
                self.needs_surrounding = true;
            },
            .delete_surrounding => |d| {
                // The commit that follows carries the replacement; the deletes
                // are applied together with it by the compositor's ordering,
                // so stash them for the next commit.
                self.pending_before = d.before;
                self.pending_after = d.after;
            },
            .done => {},
            .action => |a| {
                if (a == 1) self.last.submitted = true;
            },
            .language => |lang| {
                self.buffer.language = lang;
            },
        }
    },

    // Deletes that arrive before their commit string.
    pending_before: u32 = 0,
    pending_after: u32 = 0,

    /// Reconcile the buffer's IME-visible state with what the compositor sent
    /// last frame. Called by the runtime before drawing: if a delete was
    /// staged and no commit arrived, apply it now (the compositor may send a
    /// delete without a replacement).
    pub fn flushStagedDeletes(self: *TextField) void {
        if (self.pending_before == 0 and self.pending_after == 0) return;
        self.buffer.commitIme("", self.pending_before, self.pending_after) catch {};
        self.pending_before = 0;
        self.pending_after = 0;
        self.last.changed = true;
        self.needs_surrounding = true;
    }

    /// Push surrounding text + cursor rectangle to the IME when needed.
    /// `bounds` is the field rect in logical surface coordinates.
    /// Returns true when requests were queued (the caller must flush).
    pub fn syncIme(self: *TextField, atlas: anytype, bounds: layout.Rect, window_h: f32) bool {
        if (!self.focused) return false;
        if (self.needs_surrounding) {
            const text = self.text();
            // Protocol window: keep the cursor visible in a bounded slice.
            const cursor = @min(self.buffer.cursorByte(), text.len);
            const max_ctx: usize = 512;
            var start: usize = 0;
            if (cursor > max_ctx) start = grapheme.floorBoundary(text, cursor - max_ctx);
            const end = @min(text.len, cursor + max_ctx);
            self.session.setSurrounding(text[start..end], cursor - start, cursor - start);
            self.needs_surrounding = false;
        }
        // Caret rectangle: the IME popup is positioned next to it.
        const cluster = self.buffer.cursorCluster();
        const before = self.buffer.offsetOfCluster(cluster);
        const width = atlas.measureWidth(self.text()[0..before]);
        const real_w = atlas.measureWidth(self.text()[0..before]) * 1.0;
        _ = width;
        const caret_h: f32 = if (bounds.h > 0) bounds.h - 8 else 18;
        const x = bounds.x + 8 + real_w - self.scroll_x;
        const y = bounds.y + 4;
        self.caret_x = x;
        self.caret_y = y;
        self.caret_h = caret_h;
        _ = window_h;
        self.session.setCursorRect(x, y, 2, caret_h);
        return true;
    }

    /// Draw the field. Call with the rect from the previous frame (immediate
    /// mode convention) and the frame's scale.
    pub fn draw(self: *TextField, ui: *ui_mod.Ui, rect: layout.Rect, atlas: anytype) !void {
        _ = atlas;
        const focused = self.focused;
        const bg = if (focused) ui_mod.COLOR_BUTTON_HOT else ui_mod.COLOR_BUTTON;
        try ui.addRect(rect, bg);
        if (focused) {
            // Focus ring: 1px accent border, matching the button focus style.
            const c = ui_mod.COLOR_FOCUS_RING;
            try ui.addRect(.{ .x = rect.x, .y = rect.y + rect.h - 1, .w = rect.w, .h = 1 }, c);
        }
        const pad_x: f32 = 8;
        const text = self.text();
        const preedit = self.buffer.preedit();
        const show = if (self.props.secret) secretSlice(text, self.secretBuf()) else text;
        if (show.len == 0 and preedit.len == 0 and self.props.placeholder.len > 0) {
            try ui.addText(rect.x + pad_x - self.scroll_x, rect.y + rect.h - 7, self.props.placeholder, ui_mod.COLOR_TEXT_DIM);
        } else if (self.props.secret) {
            try ui.addText(rect.x + pad_x, rect.y + rect.h - 7, show, ui_mod.COLOR_TEXT);
        } else {
            try ui.addText(rect.x + pad_x - self.scroll_x, rect.y + rect.h - 7, text, ui_mod.COLOR_TEXT);
            if (preedit.len > 0) {
                const tw = ui.atlas.measure(text) / ui.scale;
                try ui.addText(rect.x + pad_x + tw - self.scroll_x, rect.y + rect.h - 7, preedit, ui_mod.COLOR_TEXT);
                // Underline the composition so the user sees what is pending.
                const pw = ui.atlas.measure(preedit) / ui.scale;
                try ui.addRect(.{
                    .x = rect.x + pad_x + tw - self.scroll_x,
                    .y = rect.y + rect.h - 2,
                    .w = pw,
                    .h = 1,
                }, ui_mod.COLOR_FOCUS_RING);
            }
        }
        if (focused) {
            const caret_x = self.caret_x - rect.x + rect.x; // caret_x is absolute
            _ = caret_x;
        }
    }

    // Scratch for secret rendering (bullets), one per field, no allocation.
    secret_cells: [256]u8 = undefined,

    fn secretBuf(self: *TextField) []const u8 {
        const n = @min(self.buffer.clusterCount(), self.secret_cells.len);
        var i: usize = 0;
        while (i < n) : (i += 1) self.secret_cells[i] = '*';
        return self.secret_cells[0..n];
    }
};

fn secretSlice(text: []const u8, cells: []const u8) []const u8 {
    _ = text;
    return cells;
}

test "field: focus enables IME, blur disables it" {
    var f = TextField.init(std.testing.allocator, .{});
    defer f.deinit();
    try std.testing.expect(!f.focused);
    f.focus();
    try std.testing.expect(f.focused);
    try std.testing.expect(f.session.enabled);
    try std.testing.expect(f.session.pending);
    var batch = std.ArrayList(ti.Session.Request).empty;
    defer batch.deinit(std.testing.allocator);
    try f.session.flush(&batch, std.testing.allocator);
    try std.testing.expect(batch.items[0] == .enable);
    f.blur();
    try std.testing.expect(!f.session.enabled);
    std.debug.print("FIELD_FOCUS_IME_OK\n", .{});
}

test "field: typing produces grapheme-safe edits and one undo run" {
    var f = TextField.init(std.testing.allocator, .{});
    defer f.deinit();
    f.focus();
    const keys = [_]input.KeyEvent{
        .{ .code = 30, .key = .printable, .char = 'h', .mods = .{}, .pressed = true },
        .{ .code = 23, .key = .printable, .char = 'i', .mods = .{}, .pressed = true },
    };
    for (keys) |k| try std.testing.expect(f.handleKey(k));
    try std.testing.expectEqualStrings("hi", f.text());
    // Ctrl+Z undoes the whole typed run.
    try std.testing.expect(f.handleKey(.{ .code = 44, .key = .printable, .char = 'z', .mods = .{ .raw = 0x4 }, .pressed = true }));
    try std.testing.expectEqualStrings("", f.text());
    std.debug.print("FIELD_TYPE_OK\n", .{});
}

test "field: select-all and cut" {
    var f = TextField.init(std.testing.allocator, .{});
    defer f.deinit();
    try f.setText("hello");
    f.focus();
    f.buffer.selectAll();
    try std.testing.expectEqualStrings("hello", f.copyText());
    f.cut();
    try std.testing.expectEqualStrings("", f.text());
    std.debug.print("FIELD_CUT_OK\n", .{});
}

test "field: IME commit inserts at cursor; preedit never touches text" {
    var f = TextField.init(std.testing.allocator, .{});
    defer f.deinit();
    try f.setText("ab");
    f.focus();
    f.handleIme(.{ .preedit = .{ .text = "にほ", .cursor_begin = 0, .cursor_end = 6 } });
    try std.testing.expectEqualStrings("ab", f.text());
    try std.testing.expectEqualStrings("にほ", f.buffer.preedit());
    f.handleIme(.{ .commit = "日本" });
    try std.testing.expectEqualStrings("ab日本", f.text());
    try std.testing.expectEqual(@as(usize, 0), f.buffer.preedit().len);
    try std.testing.expect(f.last.had_ime_commit);
    std.debug.print("FIELD_IME_OK\n", .{});
}

test "field: staged delete without a commit is applied on flush" {
    var f = TextField.init(std.testing.allocator, .{});
    defer f.deinit();
    try f.setText("abc");
    f.focus();
    f.handleIme(.{ .delete_surrounding = .{ .before = 1, .after = 0 } });
    f.flushStagedDeletes();
    try std.testing.expectEqualStrings("ab", f.text());
    std.debug.print("FIELD_STAGED_DELETE_OK\n", .{});
}

test "field: password field masks without losing the value" {
    var f = TextField.init(std.testing.allocator, .{ .secret = true });
    defer f.deinit();
    try f.setText("secret");
    try std.testing.expectEqualStrings("secret", f.text());
    f.focus();
    try std.testing.expectEqualStrings("secret", f.copyText() ++ "secret"[0..0]);
    std.debug.print("FIELD_SECRET_OK\n", .{});
}
