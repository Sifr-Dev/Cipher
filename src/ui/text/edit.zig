//! UTF-8 text editing buffer: grapheme-cluster cursor, selection, word/line
//! motions, bounded undo/redo, and IME composition state. This is the
//! framework's single source of truth for editable text; `widgets.textInput`
//! and `Runtime.textField` are presentations over it.
//!
//! Invariants enforced here (and therefore everywhere above it):
//!   * `cursor` and `anchor` always sit on extended-grapheme-cluster
//!     boundaries — never inside a codepoint, never inside a composed
//!     cluster (e + U+0301, emoji ZWJ sequences, regional-indicator flags).
//!   * IME preedit text never mutates the buffer; only `commit` and
//!     `deleteSurrounding` do, exactly as the text-input protocol requires.
//!   * invalid UTF-8 never panics and never stalls a motion (each bad byte
//!     is one replacement-character cluster).
//!
//! Undo model: the history is a list of *result* states. Index 0 is the
//! initial state; every new edit group appends the resulting state and
//! truncates the redo tail. Consecutive edits sharing an `edit_key` update
//! the tip state instead of appending, so typing a word is one undo step
//! while a paste is always its own step.
const std = @import("std");
const grapheme = @import("grapheme.zig");

pub const Error = error{
    OutOfMemory,
    /// The edit would exceed the per-field ceiling.
    TooLarge,
};

pub const Motion = enum {
    left,
    right,
    word_left,
    word_right,
    line_start,
    line_end,
    doc_start,
    doc_end,
    up,
    down,
};

/// What kind of change produced an undo step. Apps use this to tell the
/// compositor why the surrounding text changed.
pub const ChangeCause = enum { input_method, other };

const Snapshot = struct {
    text: []u8,
    cursor: usize,
    anchor: usize,
};

const MAX_UNDO = 128;
pub const MAX_TEXT = 1 << 20; // 1 MiB per field: a ceiling, not a policy.

pub const EditBuffer = struct {
    allocator: std.mem.Allocator,
    bytes: std.ArrayList(u8) = .empty,
    /// Display-only composition text (never part of `text()`).
    preedit_bytes: std.ArrayList(u8) = .empty,
    cursor: usize = 0,
    anchor: usize = 0,
    history: std.ArrayList(Snapshot) = .empty,
    history_index: usize = 0,
    /// Coalescing tag for the current undo run (0 = never merge).
    last_edit_key: u32 = 0,
    /// Set by mutations so callers know whether to notify the IME.
    dirty: bool = true,
    /// Cause of the most recent change.
    last_cause: ChangeCause = .other,
    /// Last reported IME language (BCP 47 tag), for diagnostics.
    language: []const u8 = "",
    /// Sticky horizontal goal for Up/Down, like real editors: moving through
    /// a short line and back restores the original column. Null unless the
    /// previous motion was vertical.
    goal_column: ?usize = null,

    pub fn init(allocator: std.mem.Allocator) EditBuffer {
        return .{ .allocator = allocator };
    }

    pub fn deinit(self: *EditBuffer) void {
        for (self.history.items) |h| self.allocator.free(h.text);
        self.history.deinit(self.allocator);
        self.preedit_bytes.deinit(self.allocator);
        self.bytes.deinit(self.allocator);
    }

    pub fn text(self: *const EditBuffer) []const u8 {
        return self.bytes.items;
    }

    pub fn len(self: *const EditBuffer) usize {
        return self.bytes.items.len;
    }

    // ---- queries ---------------------------------------------------------

    pub fn hasSelection(self: *const EditBuffer) bool {
        return self.cursor != self.anchor;
    }

    pub fn selectionStart(self: *const EditBuffer) usize {
        return @min(self.cursor, self.anchor);
    }

    pub fn selectionEnd(self: *const EditBuffer) usize {
        return @max(self.cursor, self.anchor);
    }

    pub fn selectedText(self: *const EditBuffer) []const u8 {
        return self.bytes.items[self.selectionStart()..self.selectionEnd()];
    }

    /// Byte offset of the cursor inside `text()`.
    pub fn cursorByte(self: *const EditBuffer) usize {
        return self.cursor;
    }

    /// Cluster index of the current cursor (0-based).
    pub fn cursorCluster(self: *const EditBuffer) usize {
        return grapheme.count(self.bytes.items[0..@min(self.cursor, self.bytes.items.len)]);
    }

    pub fn clusterCount(self: *const EditBuffer) usize {
        return grapheme.count(self.bytes.items);
    }

    /// Byte offset inside `text()` for the cursor that sits `count` clusters
    /// from the start (click-to-caret hit testing).
    pub fn offsetOfCluster(self: *const EditBuffer, count: usize) usize {
        var i: usize = 0;
        var n: usize = 0;
        while (i < self.bytes.items.len and n < count) : (n += 1) i += grapheme.clusterLen(self.bytes.items[i..]);
        return i;
    }

    pub fn canUndo(self: *const EditBuffer) bool {
        return self.history_index > 0;
    }

    pub fn canRedo(self: *const EditBuffer) bool {
        return self.history_index + 1 < self.history.items.len;
    }

    // ---- lifecycle -------------------------------------------------------

    /// Replace the whole contents (loading a value, or an app resetting the
    /// field). This resets undo history to that state.
    pub fn setText(self: *EditBuffer, value: []const u8) !void {
        if (value.len > MAX_TEXT) return error.TooLarge;
        self.bytes.clearRetainingCapacity();
        try self.bytes.appendSlice(self.allocator, value);
        self.cursor = self.bytes.items.len;
        self.anchor = self.cursor;
        self.preedit_bytes.clearRetainingCapacity();
        for (self.history.items) |h| self.allocator.free(h.text);
        self.history.clearRetainingCapacity();
        try self.captureState();
        self.last_edit_key = 0;
        self.dirty = true;
        self.last_cause = .other;
    }

    /// Reset history around the current text (used on focus gain).
    pub fn resetHistory(self: *EditBuffer) !void {
        for (self.history.items) |h| self.allocator.free(h.text);
        self.history.clearRetainingCapacity();
        try self.captureState();
        self.last_edit_key = 0;
    }

    pub fn clearSelection(self: *EditBuffer) void {
        self.anchor = self.cursor;
    }

    pub fn selectAll(self: *EditBuffer) void {
        self.anchor = 0;
        self.cursor = self.bytes.items.len;
        self.endEditRun();
    }

    pub fn setCursorByte(self: *EditBuffer, offset: usize, extend: bool) void {
        const snapped = grapheme.floorBoundary(self.bytes.items, offset);
        self.cursor = snapped;
        self.goal_column = null;
        if (!extend) self.anchor = snapped;
        if (!extend) self.endEditRun();
    }

    /// Place the cursor at a cluster index (click-to-caret).
    pub fn setCursorCluster(self: *EditBuffer, index: usize, extend: bool) void {
        self.setCursorByte(self.offsetOfCluster(index), extend);
    }

    // ---- history ---------------------------------------------------------

    fn captureState(self: *EditBuffer) !void {
        // Drop the redo tail first so a new edit cannot be undone into a
        // dead branch.
        while (self.history.items.len > self.history_index + 1) {
            const s = self.history.pop().?;
            self.allocator.free(s.text);
        }
        const copy = try self.allocator.dupe(u8, self.bytes.items);
        errdefer self.allocator.free(copy);
        try self.history.append(self.allocator, .{
            .text = copy,
            .cursor = self.cursor,
            .anchor = self.anchor,
        });
        self.history_index = self.history.items.len - 1;
        if (self.history.items.len > MAX_UNDO + 1) {
            const old = self.history.orderedRemove(0);
            self.allocator.free(old.text);
            self.history_index -= 1;
        }
    }

    /// Update the tip snapshot with the current state (coalesced typing run).
    fn updateTip(self: *EditBuffer) !void {
        const s = &self.history.items[self.history_index];
        self.allocator.free(s.text);
        s.text = try self.allocator.dupe(u8, self.bytes.items);
        s.cursor = self.cursor;
        s.anchor = self.anchor;
    }

    fn recordEdit(self: *EditBuffer, key: u32, cause: ChangeCause) !void {
        self.dirty = true;
        self.goal_column = null;
        self.last_cause = cause;
        if (key != 0 and key == self.last_edit_key and self.history.items.len > 0 and
            self.history_index + 1 == self.history.items.len)
        {
            try self.updateTip();
            return;
        }
        self.last_edit_key = key;
        // Undo is best effort: a failed snapshot must never fail the edit.
        self.captureState() catch {
            self.last_edit_key = 0;
        };
    }

    pub fn endEditRun(self: *EditBuffer) void {
        self.last_edit_key = 0;
    }

    pub fn undo(self: *EditBuffer) bool {
        if (!self.canUndo()) return false;
        self.history_index -= 1;
        return self.restore();
    }

    pub fn redo(self: *EditBuffer) bool {
        if (!self.canRedo()) return false;
        self.history_index += 1;
        return self.restore();
    }

    fn restore(self: *EditBuffer) bool {
        const s = self.history.items[self.history_index];
        self.bytes.clearRetainingCapacity();
        self.bytes.appendSlice(self.allocator, s.text) catch return false;
        self.cursor = @min(s.cursor, self.bytes.items.len);
        self.anchor = @min(s.anchor, self.bytes.items.len);
        self.last_edit_key = 0;
        self.dirty = true;
        return true;
    }

    // ---- mutations -------------------------------------------------------

    fn replaceSelection(self: *EditBuffer, value: []const u8) !void {
        const start = self.selectionStart();
        const end = self.selectionEnd();
        const new_len = self.bytes.items.len - (end - start) + value.len;
        if (new_len > MAX_TEXT) return error.TooLarge;
        try self.bytes.replaceRange(self.allocator, start, end - start, value);
        self.cursor = start + value.len;
        self.anchor = self.cursor;
    }

    fn deleteSelection(self: *EditBuffer) !bool {
        if (!self.hasSelection()) return false;
        try self.replaceSelection("");
        return true;
    }

    /// Insert text at the cursor, replacing the selection. `key` groups
    /// consecutive edits into one undo step (0 = a standalone edit).
    pub fn insert(self: *EditBuffer, value: []const u8, key: u32, cause: ChangeCause) !void {
        if (value.len == 0) return;
        try self.replaceSelection(value);
        try self.recordEdit(key, cause);
    }

    /// Delete the selected cluster(s), else the cluster before the cursor.
    pub fn deleteBackward(self: *EditBuffer, cause: ChangeCause) !bool {
        if (self.hasSelection()) {
            _ = try self.deleteSelection();
            try self.recordEdit(0, cause);
            return true;
        }
        if (self.cursor == 0) return false;
        const start = grapheme.prevBoundary(self.bytes.items, self.cursor);
        try self.bytes.replaceRange(self.allocator, start, self.cursor - start, "");
        self.cursor = start;
        self.anchor = start;
        try self.recordEdit(0, cause);
        return true;
    }

    /// Delete the selected cluster(s), else the cluster after the cursor.
    pub fn deleteForward(self: *EditBuffer, cause: ChangeCause) !bool {
        if (self.hasSelection()) {
            _ = try self.deleteSelection();
            try self.recordEdit(0, cause);
            return true;
        }
        if (self.cursor >= self.bytes.items.len) return false;
        const end = grapheme.nextBoundary(self.bytes.items, self.cursor);
        try self.bytes.replaceRange(self.allocator, self.cursor, end - self.cursor, "");
        self.anchor = self.cursor;
        try self.recordEdit(0, cause);
        return true;
    }

    /// Delete the word before the cursor (Ctrl+Backspace).
    pub fn deleteWordBackward(self: *EditBuffer, cause: ChangeCause) !bool {
        if (self.hasSelection()) {
            _ = try self.deleteSelection();
            try self.recordEdit(0, cause);
            return true;
        }
        if (self.cursor == 0) return false;
        const start = self.wordBoundaryLeft(self.cursor);
        try self.bytes.replaceRange(self.allocator, start, self.cursor - start, "");
        self.cursor = start;
        self.anchor = start;
        try self.recordEdit(0, cause);
        return true;
    }

    /// Delete the word after the cursor (Ctrl+Delete).
    pub fn deleteWordForward(self: *EditBuffer, cause: ChangeCause) !bool {
        if (self.hasSelection()) {
            _ = try self.deleteSelection();
            try self.recordEdit(0, cause);
            return true;
        }
        if (self.cursor >= self.bytes.items.len) return false;
        const end = self.wordBoundaryRight(self.cursor);
        try self.bytes.replaceRange(self.allocator, self.cursor, end - self.cursor, "");
        self.anchor = self.cursor;
        try self.recordEdit(0, cause);
        return true;
    }

    // ---- word classification --------------------------------------------

    fn isWordCp(cp: u21) bool {
        // Letters/digits/underscore are word characters. Everything above
        // ASCII is treated as word content so CJK and accented words move as
        // a unit instead of character-by-character.
        if (cp == '_') return true;
        if (cp < 0x80) return cp < 0x80 and std.ascii.isAlphanumeric(@as(u8, @intCast(cp)));
        return !isSpaceCp(cp);
    }

    fn isSpaceCp(cp: u21) bool {
        return cp == ' ' or cp == '\t' or cp == '\n' or cp == '\r' or
            cp == 0x00A0 or cp == 0x2000 or (cp >= 0x2002 and cp <= 0x200A) or
            cp == 0x3000 or cp == 0x2028 or cp == 0x2029 or cp == 0x202F or cp == 0x205F;
    }

    fn cpBefore(buf: []const u8, at: usize) struct { cp: u21, start: usize } {
        if (at == 0) return .{ .cp = 0, .start = 0 };
        const start = grapheme.prevBoundary(buf, at);
        const d = grapheme.decode(buf[start..at]);
        return .{ .cp = d.cp, .start = start };
    }

    fn cpAt(buf: []const u8, at: usize) struct { cp: u21, len: usize } {
        if (at >= buf.len) return .{ .cp = 0, .len = 0 };
        const d = grapheme.decode(buf[at..]);
        return .{ .cp = d.cp, .len = d.len };
    }

    pub fn wordBoundaryLeft(self: *const EditBuffer, from: usize) usize {
        const buf = self.bytes.items;
        var at = @min(from, buf.len);
        while (at > 0) {
            const c = cpBefore(buf, at);
            if (!isWordCp(c.cp)) at = c.start else break;
        }
        while (at > 0) {
            const c = cpBefore(buf, at);
            if (isWordCp(c.cp)) at = c.start else break;
        }
        return at;
    }

    /// End of the next word: skip whitespace, then the word run.
    pub fn wordBoundaryRight(self: *const EditBuffer, from: usize) usize {
        const buf = self.bytes.items;
        var at = @min(from, buf.len);
        while (at < buf.len) {
            const c = cpAt(buf, at);
            if (!isWordCp(c.cp)) at += c.len else break;
        }
        while (at < buf.len) {
            const c = cpAt(buf, at);
            if (isWordCp(c.cp)) at += c.len else break;
        }
        return at;
    }

    // ---- motion ----------------------------------------------------------

    /// Move the caret. `extend` keeps the anchor (Shift+arrows).
    pub fn move(self: *EditBuffer, motion: Motion, extend: bool) void {
        const buf = self.bytes.items;
        const prev_cursor = self.cursor;
        switch (motion) {
            .left => {
                if (!extend and self.hasSelection()) {
                    self.cursor = self.selectionStart();
                } else {
                    self.cursor = grapheme.prevBoundary(buf, self.cursor);
                }
            },
            .right => {
                if (!extend and self.hasSelection()) {
                    self.cursor = self.selectionEnd();
                } else {
                    self.cursor = grapheme.nextBoundary(buf, self.cursor);
                }
            },
            .word_left => {
                if (!extend and self.hasSelection()) {
                    self.cursor = self.selectionStart();
                } else {
                    self.cursor = self.wordBoundaryLeft(self.cursor);
                }
            },
            .word_right => {
                if (!extend and self.hasSelection()) {
                    self.cursor = self.selectionEnd();
                } else {
                    self.cursor = self.wordBoundaryRight(self.cursor);
                }
            },
            .line_start => self.cursor = self.lineStartAt(self.cursor),
            .line_end => self.cursor = self.lineEndAt(self.cursor),
            .doc_start => self.cursor = 0,
            .doc_end => self.cursor = buf.len,
            .up, .down => {
                if (self.goal_column == null) self.goal_column = self.columnAt(self.cursor);
                const dir: i32 = if (motion == .up) -1 else 1;
                self.cursor = self.verticalTarget(self.cursor, dir) orelse
                    (if (dir < 0) @as(usize, 0) else buf.len);
            },
        }
        if (motion != .up and motion != .down) self.goal_column = null;
        if (!extend) self.anchor = self.cursor;
        if (!extend) self.endEditRun();
        if (prev_cursor != self.cursor) self.dirty = true;
    }

    fn lineStartAt(self: *const EditBuffer, at: usize) usize {
        const buf = self.bytes.items;
        var i = @min(at, buf.len);
        while (i > 0 and buf[i - 1] != '\n') i -= 1;
        return grapheme.floorBoundary(buf, i);
    }

    fn lineEndAt(self: *const EditBuffer, at: usize) usize {
        const buf = self.bytes.items;
        var i = @min(at, buf.len);
        while (i < buf.len and buf[i] != '\n') i += 1;
        return grapheme.floorBoundary(buf, i);
    }

    fn columnAt(self: *const EditBuffer, at: usize) usize {
        return grapheme.count(self.bytes.items[self.lineStartAt(at)..at]);
    }

    fn offsetAtColumn(self: *const EditBuffer, line_start: usize, column: usize) usize {
        var i = line_start;
        var n: usize = 0;
        while (i < self.bytes.items.len and self.bytes.items[i] != '\n' and n < column) : (n += 1) {
            i += grapheme.clusterLen(self.bytes.items[i..]);
        }
        return i;
    }

    fn verticalTarget(self: *const EditBuffer, at: usize, direction: i32) ?usize {
        const col = self.goal_column orelse self.columnAt(at);
        if (direction < 0) {
            const start = self.lineStartAt(at);
            if (start == 0) return null;
            const prev_start = self.lineStartAt(start - 1);
            return self.offsetAtColumn(prev_start, col);
        }
        const end = self.lineEndAt(at);
        if (end >= self.bytes.items.len) return null;
        return self.offsetAtColumn(end + 1, col);
    }

    // ---- IME composition -------------------------------------------------

    /// Replace the pre-edit string. Display-only: the buffer is untouched.
    pub fn setPreedit(self: *EditBuffer, value: []const u8) !void {
        self.preedit_bytes.clearRetainingCapacity();
        try self.preedit_bytes.appendSlice(self.allocator, value);
    }

    pub fn preedit(self: *const EditBuffer) []const u8 {
        return self.preedit_bytes.items;
    }

    /// Commit an IME string: delete `before` bytes before and `after` bytes
    /// after the cursor, then insert the committed text. Byte counts that
    /// land inside a cluster are widened outward so the buffer stays valid.
    pub fn commitIme(self: *EditBuffer, committed: []const u8, before: usize, after: usize) !void {
        try self.setPreedit("");
        const buf = self.bytes.items;
        var start = @min(self.cursor, buf.len);
        var remaining_before = before;
        while (remaining_before > 0 and start > 0) {
            const prev = grapheme.prevBoundary(buf, start);
            remaining_before -|= start - prev;
            start = prev;
        }
        var end = @min(self.cursor, buf.len);
        var remaining_after = after;
        while (remaining_after > 0 and end < buf.len) {
            const next = grapheme.nextBoundary(buf, end);
            remaining_after -|= next - end;
            end = next;
        }
        self.anchor = start;
        self.cursor = end;
        try self.replaceSelection(committed);
        try self.recordEdit(0, .input_method);
    }
};

test "init/deinit and setText clamp cursor" {
    var b = EditBuffer.init(std.testing.allocator);
    defer b.deinit();
    try b.setText("hello");
    try std.testing.expectEqualStrings("hello", b.text());
    try std.testing.expectEqual(@as(usize, 5), b.cursor);
    try std.testing.expect(!b.hasSelection());
    std.debug.print("EDIT_INIT_OK\n", .{});
}

test "insert, backspace, delete across grapheme clusters" {
    var b = EditBuffer.init(std.testing.allocator);
    defer b.deinit();
    try b.insert("a", 1, .other);
    try b.insert("e\u{0301}", 1, .other); // e + combining acute
    try b.insert("\u{1F44B}\u{1F3FD}", 1, .other); // waving hand + skin tone
    try std.testing.expectEqual(@as(usize, 3), b.cursorCluster());
    try std.testing.expect(try b.deleteBackward(.other));
    // The skin-tone modifier went with the wave.
    try std.testing.expectEqualStrings("ae\u{0301}", b.text());
    try std.testing.expect(try b.deleteBackward(.other));
    try std.testing.expectEqualStrings("a", b.text());
    try std.testing.expect(!(try b.deleteForward(.other)));
    // Delete forward removes a whole cluster.
    b.move(.line_start, false);
    try std.testing.expect(try b.deleteForward(.other));
    try std.testing.expectEqualStrings("", b.text());
    std.debug.print("EDIT_GRAPHEME_DELETE_OK\n", .{});
}

test "arrow keys never land inside a cluster" {
    var b = EditBuffer.init(std.testing.allocator);
    defer b.deinit();
    try b.setText("a\u{1F44B}\u{1F3FD}b");
    b.move(.line_start, false);
    try std.testing.expectEqual(@as(usize, 0), b.cursor);
    b.move(.right, false);
    try std.testing.expectEqual(@as(usize, 1), b.cursor); // after 'a'
    b.move(.right, false);
    try std.testing.expectEqual(@as(usize, 1 + 8), b.cursor); // after the emoji cluster
    b.move(.right, false);
    try std.testing.expectEqual(b.len(), b.cursor);
    b.move(.right, false);
    try std.testing.expectEqual(b.len(), b.cursor); // clamped
    b.move(.line_start, false);
    b.move(.left, false);
    try std.testing.expectEqual(@as(usize, 0), b.cursor);
    std.debug.print("EDIT_CURSOR_OK\n", .{});
}

test "selection: select all, replace on insert, shift-delete" {
    var b = EditBuffer.init(std.testing.allocator);
    defer b.deinit();
    try b.setText("hello world");
    b.selectAll();
    try std.testing.expectEqualStrings("hello world", b.selectedText());
    try b.insert("hi", 0, .other);
    try std.testing.expectEqualStrings("hi", b.text());
    try std.testing.expectEqual(@as(usize, 2), b.cursor);
    // Shift+left selects one cluster.
    b.move(.left, true);
    try std.testing.expectEqualStrings("i", b.selectedText());
    try std.testing.expect(try b.deleteBackward(.other));
    try std.testing.expectEqualStrings("h", b.text());
    std.debug.print("EDIT_SELECTION_OK\n", .{});
}

test "word motions and word deletion" {
    var b = EditBuffer.init(std.testing.allocator);
    defer b.deinit();
    try b.setText("alpha beta  gamma");
    b.move(.line_start, false);
    b.move(.word_right, false);
    try std.testing.expectEqual(@as(usize, 5), b.cursor); // end of "alpha"
    b.move(.word_right, false);
    try std.testing.expectEqual(@as(usize, 10), b.cursor); // end of "beta"
    b.move(.word_left, false);
    try std.testing.expectEqual(@as(usize, 6), b.cursor); // start of "beta"
    b.move(.doc_end, false);
    try std.testing.expect(try b.deleteWordBackward(.other));
    try std.testing.expectEqualStrings("alpha beta  ", b.text());
    std.debug.print("EDIT_WORD_OK\n", .{});
}

test "vertical motion keeps the column" {
    var b = EditBuffer.init(std.testing.allocator);
    defer b.deinit();
    try b.setText("abcdef\nxy\nzzzzzz");
    b.setCursorByte(4, false); // column 4 of line 0
    b.move(.down, false);
    try std.testing.expectEqual(@as(usize, 9), b.cursor); // clamped to end of "xy"
    b.move(.down, false);
    try std.testing.expectEqual(@as(usize, 14), b.cursor); // column 4 of "zzzzzz"
    b.move(.up, false);
    try std.testing.expectEqual(@as(usize, 9), b.cursor);
    std.debug.print("EDIT_VERTICAL_OK\n", .{});
}

test "undo groups a typing run and standalone edits are separate steps" {
    var b = EditBuffer.init(std.testing.allocator);
    defer b.deinit();
    try b.setText("x");
    b.endEditRun();
    // A run of single-character inserts with the same key is one undo step.
    try b.insert("a", 1, .other);
    try b.insert("b", 1, .other);
    try b.insert("c", 1, .other);
    try std.testing.expectEqualStrings("xabc", b.text());
    try std.testing.expect(b.canUndo());
    try std.testing.expect(b.undo());
    try std.testing.expectEqualStrings("x", b.text());
    // A standalone edit (key 0) is its own step.
    try b.insert("!", 0, .other);
    try std.testing.expect(b.undo());
    try std.testing.expectEqualStrings("x", b.text());
    try std.testing.expect(b.canRedo());
    try std.testing.expect(b.redo());
    try std.testing.expectEqualStrings("x!", b.text());
    std.debug.print("EDIT_UNDO_OK\n", .{});
}

test "undo history is bounded" {
    var b = EditBuffer.init(std.testing.allocator);
    defer b.deinit();
    try b.setText("");
    var i: usize = 0;
    while (i < 400) : (i += 1) try b.insert("a", 0, .other);
    try std.testing.expect(b.history.items.len <= 129);
    std.debug.print("EDIT_UNDO_BOUNDED_OK n={d}\n", .{b.history.items.len});
}

test "IME preedit never touches the buffer; commit replaces and deletes around" {
    var b = EditBuffer.init(std.testing.allocator);
    defer b.deinit();
    try b.setText("ab");
    try b.setPreedit("にほn");
    try std.testing.expectEqualStrings("ab", b.text());
    try std.testing.expectEqualStrings("にほn", b.preedit());
    try b.commitIme("日本", 0, 0);
    try std.testing.expectEqualStrings("ab日本", b.text());
    try std.testing.expectEqual(@as(usize, 0), b.preedit().len);
    // Delete two bytes before the cursor (widened to a whole kanji cluster)
    // and insert a replacement.
    try b.commitIme("X", 4, 0);
    try std.testing.expectEqualStrings("abX", b.text());
    std.debug.print("EDIT_IME_OK\n", .{});
}

test "invalid UTF-8 never panics or stalls" {
    var b = EditBuffer.init(std.testing.allocator);
    defer b.deinit();
    try b.setText("\xff\xfea");
    // Each invalid byte is one replacement cluster; the cursor starts at the
    // end (setText places it there).
    try std.testing.expectEqual(@as(usize, 3), b.cursorCluster());
    b.selectAll();
    try std.testing.expect(try b.deleteBackward(.other));
    try std.testing.expectEqualStrings("", b.text());
    std.debug.print("EDIT_INVALID_UTF8_OK\n", .{});
}
