//! Terminal cell grid with scrollback, wrap, scroll regions, and alt screen.
//! Pure data structure — rendering lives in the app; parsing lives in vt.zig.
//!
//! Lines live in a fixed-capacity ring buffer: appending a line at the bottom
//! is O(cols) (memset of a reused cell array) with no per-line allocation and
//! no memmove of the tail — that is what makes scrollback-heavy output fast.
const std = @import("std");

/// Color encoding in Cell.fg/bg:
///   0                 -> theme default
///   0x01_000000|idx   -> xterm 256-palette index
///   0x02_RRGGBB       -> direct 24-bit RGB (renderer forces opaque)
pub const DEFAULT_COLOR: u32 = 0;
pub const PALETTE_FLAG: u32 = 0x0100_0000;
pub const TRUECOLOR_FLAG: u32 = 0x0200_0000;

pub const Attr = packed struct(u8) {
    bold: bool = false,
    underline: bool = false,
    reverse: bool = false,
    _pad: u5 = 0,
};

pub const Cell = struct {
    cp: u21 = ' ',
    fg: u32 = DEFAULT_COLOR,
    bg: u32 = DEFAULT_COLOR,
    attrs: Attr = .{},
};

pub const Line = struct {
    cells: []Cell,
    wrapped: bool = false, // soft-wrapped continuation of the previous line
};

pub const Grid = struct {
    allocator: std.mem.Allocator,
    cols: u32,
    rows: u32,
    ring: []Line, // fixed capacity = rows + scrollback_max
    cell_slab: []Cell = &.{}, // ONE alloc backing every ring line's cells
    view_buf: []Line, // scratch: viewport line pointers (screenLines)
    head: usize = 0, // ring slot of the oldest valid line
    count: usize = 0, // number of valid lines
    total: usize = 0, // total lines ever appended (absolute index base)
    scroll: usize = 0, // absolute index of first visible line
    scroll_top: u32 = 0, // DECSTBM region (viewport rows)
    scroll_bottom: u32 = 0, // inclusive; set to rows-1 at init/reset
    cx: u32 = 0,
    cy: u32 = 0, // cursor in viewport coords
    pending_wrap: bool = false,
    cur_attrs: Attr = .{},
    cur_fg: u32 = DEFAULT_COLOR,
    cur_bg: u32 = DEFAULT_COLOR,
    scrollback_max: usize = 10_000, // ring allocates capacity upfront: 10k lines x 100 cols x 16B = 16MB/pane
    alt: ?*Grid = null,
    saved_cursor: struct { cx: u32 = 0, cy: u32 = 0, fg: u32 = 0, bg: u32 = 0, attrs: Attr = .{} } = .{},
    cursor_visible: bool = true,
    bracketed_paste: bool = false,
    /// Kitty keyboard protocol progressive-enhancement flags (0 = legacy).
    kbd_flags: u8 = 0,
    kbd_stack: [32]u8 = undefined, // per-screen mode stack (this Grid IS the current screen)
    kbd_stack_len: usize = 0,
    /// DEC private mode 2026 (synchronized output): hold frame rendering while set.
    sync_output: bool = false,
    sync_since_ns: i64 = 0,

    pub fn init(allocator: std.mem.Allocator, cols: u32, rows: u32) !Grid {
        return initCapacity(allocator, cols, rows, 10_000);
    }

    pub fn initCapacity(allocator: std.mem.Allocator, cols: u32, rows: u32, scrollback_max: usize) !Grid {
        const cap = rows + scrollback_max;
        const ring = try allocator.alloc(Line, cap);
        const slab = try allocator.alloc(Cell, cap * @as(usize, cols));
        @memset(slab, .{});
        for (ring, 0..) |*l, i| l.cells = slab[i * @as(usize, cols) .. (i + 1) * @as(usize, cols)];
        const view_buf = try allocator.alloc(Line, rows);
        var g = Grid{
            .allocator = allocator,
            .cols = cols,
            .rows = rows,
            .ring = ring,
            .cell_slab = slab,
            .view_buf = view_buf,
            .scroll_bottom = rows - 1,
            .scrollback_max = scrollback_max,
        };
        g.count = rows;
        g.total = rows;
        g.scroll = 0;
        return g;
    }

    pub fn deinit(self: *Grid) void {
        self.allocator.free(self.cell_slab);
        self.allocator.free(self.ring);
        self.allocator.free(self.view_buf);
        if (self.alt) |a| {
            a.deinit();
            self.allocator.destroy(a);
            self.alt = null;
        }
    }

    fn slot(self: *const Grid, abs: usize) usize {
        return abs % self.ring.len;
    }

    pub fn lineAt(self: *const Grid, abs: usize) *Line {
        return &self.ring[self.slot(abs)];
    }

    /// Absolute index of viewport row cy.
    fn absLine(self: *const Grid, cy: u32) usize {
        return self.scroll + cy;
    }

    fn cellAt(self: *Grid, cx: u32, cy: u32) *Cell {
        return &self.lineAt(self.absLine(cy)).cells[cx];
    }

    /// The visible screen as `rows` line handles (copies pointers into a
    /// scratch buffer, so it works even when the ring wraps mid-viewport).
    pub fn screenLines(self: *Grid) []const Line {
        var i: u32 = 0;
        while (i < self.rows) : (i += 1) {
            self.view_buf[i] = self.ring[self.slot(self.scroll + i)];
        }
        return self.view_buf;
    }

    /// Append a blank line at the bottom (scrolling), reusing the evicted
    /// slot's cell array. O(cols).
    fn appendLine(self: *Grid) void {
        const s: usize = if (self.count < self.ring.len) blk: {
            const s = (self.head + self.count) % self.ring.len;
            self.count += 1;
            break :blk s;
        } else blk: {
            const s = self.head;
            self.head = (self.head + 1) % self.ring.len;
            break :blk s;
        };
        const l = &self.ring[s];
        @memset(l.cells, .{});
        l.wrapped = false;
        self.total += 1;
    }

    pub fn maxScroll(self: *const Grid) usize {
        return if (self.total > self.rows) self.total - self.rows else 0;
    }

    pub fn atBottom(self: *const Grid) bool {
        return self.scroll >= self.maxScroll();
    }

    pub fn scrollToBottom(self: *Grid) void {
        self.scroll = self.maxScroll();
    }

    pub fn viewScrollUp(self: *Grid, n: usize) void {
        self.scroll -|= n;
    }

    pub fn viewScrollDown(self: *Grid, n: usize) void {
        self.scroll = @min(self.scroll + n, self.maxScroll());
    }

    /// Put a printable codepoint at the cursor, wrapping as needed.
    pub fn putChar(self: *Grid, cp: u21) !void {
        if (self.pending_wrap) {
            self.pending_wrap = false;
            self.lineAt(self.absLine(self.cy)).wrapped = true;
            self.cx = 0;
            try self.newline();
        }
        const c = self.cellAt(self.cx, self.cy);
        c.* = .{ .cp = cp, .fg = self.cur_fg, .bg = self.cur_bg, .attrs = self.cur_attrs };
        self.cx += 1;
        if (self.cx >= self.cols) {
            self.cx = self.cols - 1;
            self.pending_wrap = true;
        }
    }

    fn scrollBottomRow(self: *const Grid) u32 {
        return @min(self.scroll_bottom, self.rows - 1);
    }

    /// LF: move down one row; scroll the region if at its bottom.
    pub fn newline(self: *Grid) !void {
        const bottom = self.scrollBottomRow();
        if (self.cy >= bottom) {
            try self.scrollRegionUp(1);
        } else if (self.cy + 1 < self.rows) {
            self.cy += 1;
        }
    }

    pub fn lineFeed(self: *Grid) !void {
        try self.newline();
    }

    /// Scroll the region [scroll_top..scroll_bottom] up by n lines. When the
    /// region is the full screen, lines leaving the top go to scrollback
    /// (they stay in the ring; we just advance `scroll` via appendLine).
    pub fn scrollRegionUp(self: *Grid, n: usize) !void {
        const top_v = self.scroll_top;
        const bottom_v = self.scrollBottomRow();
        if (bottom_v < top_v or bottom_v >= self.rows) return;
        const region = bottom_v - top_v + 1;
        const k: u32 = @intCast(@min(n, region));
        const full = top_v == 0 and bottom_v == self.rows - 1;
        if (full) {
            const was_bottom = self.atBottom();
            var i: u32 = 0;
            while (i < k) : (i += 1) self.appendLine();
            if (was_bottom) self.scrollToBottom(); // follow the tail
            if (self.cy >= self.rows) self.cy = self.rows - 1;
        } else {
            // shift lines up within the region, blank the bottom k
            const top_abs = self.absLine(top_v);
            const bottom_abs = self.absLine(bottom_v);
            var a = top_abs;
            while (a + k <= bottom_abs) : (a += 1) {
                const dst = self.lineAt(a);
                const src = self.lineAt(a + k);
                std.mem.copyForwards(Cell, dst.cells, src.cells);
                dst.wrapped = src.wrapped;
            }
            var b = bottom_abs - k + 1;
            while (b <= bottom_abs) : (b += 1) {
                const l = self.lineAt(b);
                @memset(l.cells, .{});
                l.wrapped = false;
            }
        }
    }

    /// Scroll the region down by n (reverse).
    pub fn scrollDown(self: *Grid, n: usize) !void {
        const top_v = self.scroll_top;
        const bottom_v = self.scrollBottomRow();
        if (bottom_v < top_v or bottom_v >= self.rows) return;
        const region = bottom_v - top_v + 1;
        const k: u32 = @intCast(@min(n, region));
        const top_abs = self.absLine(top_v);
        const bottom_abs = self.absLine(bottom_v);
        var a = bottom_abs;
        while (a >= top_abs + k) : (a -= 1) {
            const dst = self.lineAt(a);
            const src = self.lineAt(a - k);
            std.mem.copyForwards(Cell, dst.cells, src.cells);
            dst.wrapped = src.wrapped;
            if (a == top_abs + k) break;
        }
        var b = top_abs;
        while (b < top_abs + k) : (b += 1) {
            const l = self.lineAt(b);
            @memset(l.cells, .{});
            l.wrapped = false;
        }
    }

    pub fn carriageReturn(self: *Grid) void {
        self.cx = 0;
        self.pending_wrap = false;
    }

    pub fn backspace(self: *Grid) void {
        if (self.cx > 0) self.cx -= 1;
        self.pending_wrap = false;
    }

    pub fn tab(self: *Grid) void {
        const next = (self.cx / 8 + 1) * 8;
        self.cx = @min(next, self.cols - 1);
        self.pending_wrap = false;
    }

    pub fn moveCursor(self: *Grid, cx: u32, cy: u32) void {
        self.cx = @min(cx, self.cols - 1);
        self.cy = @min(cy, self.rows - 1);
        self.pending_wrap = false;
    }

    pub fn eraseInDisplay(self: *Grid, mode: u32) void {
        switch (mode) {
            0 => {
                self.eraseInLine(0);
                var y = self.cy + 1;
                while (y < self.rows) : (y += 1) @memset(self.lineAt(self.absLine(y)).cells, .{});
            },
            1 => {
                self.eraseInLine(1);
                var y: u32 = 0;
                while (y < self.cy) : (y += 1) @memset(self.lineAt(self.absLine(y)).cells, .{});
            },
            2, 3 => {
                var y: u32 = 0;
                while (y < self.rows) : (y += 1) @memset(self.lineAt(self.absLine(y)).cells, .{});
            },
            else => {},
        }
    }

    pub fn eraseInLine(self: *Grid, mode: u32) void {
        const line = self.lineAt(self.absLine(self.cy));
        switch (mode) {
            0 => @memset(line.cells[self.cx..], .{}),
            1 => @memset(line.cells[0 .. self.cx + 1], .{}),
            2 => @memset(line.cells, .{}),
            else => {},
        }
    }

    pub fn eraseChars(self: *Grid, n: u32) void {
        const line = self.lineAt(self.absLine(self.cy));
        const end: u32 = @min(self.cx + n, self.cols);
        @memset(line.cells[self.cx..end], .{});
    }

    pub fn deleteChars(self: *Grid, n: u32) void {
        const line = self.lineAt(self.absLine(self.cy));
        const k: u32 = @min(n, self.cols - self.cx);
        std.mem.copyForwards(Cell, line.cells[self.cx .. self.cols - k], line.cells[self.cx + k .. self.cols]);
        @memset(line.cells[self.cols - k ..], .{});
    }

    pub fn insertChars(self: *Grid, n: u32) void {
        const line = self.lineAt(self.absLine(self.cy));
        const k: u32 = @min(n, self.cols - self.cx);
        var i: usize = self.cols - 1;
        while (i >= self.cx + k) : (i -= 1) line.cells[i] = line.cells[i - k];
        @memset(line.cells[self.cx .. self.cx + k], .{});
    }

    pub fn insertLines(self: *Grid, n: u32) !void {
        const top_v = self.cy;
        const bottom_v = self.scrollBottomRow();
        if (bottom_v <= top_v or bottom_v >= self.rows) return;
        const k: u32 = @min(n, bottom_v - top_v);
        const top_abs = self.absLine(top_v);
        const bottom_abs = self.absLine(bottom_v);
        var a = bottom_abs;
        while (a > top_abs + k - 1) : (a -= 1) {
            const dst = self.lineAt(a);
            const src = self.lineAt(a - k);
            std.mem.copyForwards(Cell, dst.cells, src.cells);
            dst.wrapped = src.wrapped;
            if (a == top_abs + k) break;
        }
        var b = top_abs;
        while (b < top_abs + k) : (b += 1) @memset(self.lineAt(b).cells, .{});
    }

    pub fn deleteLines(self: *Grid, n: u32) !void {
        const top_v = self.cy;
        const bottom_v = self.scrollBottomRow();
        if (bottom_v < top_v or bottom_v >= self.rows) return;
        const k: u32 = @min(n, bottom_v - top_v + 1);
        const top_abs = self.absLine(top_v);
        const bottom_abs = self.absLine(bottom_v);
        var a = top_abs;
        while (a + k <= bottom_abs) : (a += 1) {
            const dst = self.lineAt(a);
            const src = self.lineAt(a + k);
            std.mem.copyForwards(Cell, dst.cells, src.cells);
            dst.wrapped = src.wrapped;
        }
        var b = bottom_abs - k + 1;
        while (b <= bottom_abs) : (b += 1) @memset(self.lineAt(b).cells, .{});
    }

    pub fn setScrollRegion(self: *Grid, top: u32, bottom: u32) void {
        self.scroll_top = if (top > 0) top - 1 else 0;
        self.scroll_bottom = if (bottom > 0) @min(bottom - 1, self.rows - 1) else self.rows - 1;
        self.cx = 0;
        self.cy = 0;
        self.pending_wrap = false;
    }

    pub fn saveCursor(self: *Grid) void {
        self.saved_cursor = .{ .cx = self.cx, .cy = self.cy, .fg = self.cur_fg, .bg = self.cur_bg, .attrs = self.cur_attrs };
    }

    pub fn restoreCursor(self: *Grid) void {
        self.cx = self.saved_cursor.cx;
        self.cy = self.saved_cursor.cy;
        self.cur_fg = self.saved_cursor.fg;
        self.cur_bg = self.saved_cursor.bg;
        self.cur_attrs = self.saved_cursor.attrs;
        self.pending_wrap = false;
    }

    pub fn enterAltScreen(self: *Grid) !void {
        if (self.alt != null) return;
        const main = try self.allocator.create(Grid);
        main.* = self.*;
        self.alt = main;
        // fresh ring for the alt screen
        const cap = self.rows; // alt screen has no scrollback
        const ring = try self.allocator.alloc(Line, cap);
        const slab = try self.allocator.alloc(Cell, cap * @as(usize, self.cols));
        @memset(slab, .{});
        for (ring, 0..) |*l, i| l.cells = slab[i * @as(usize, self.cols) .. (i + 1) * @as(usize, self.cols)];
        const vb = try self.allocator.alloc(Line, self.rows);
        self.view_buf = vb;
        self.cell_slab = slab;
        self.ring = ring;
        self.head = 0;
        self.count = self.rows;
        self.total = self.rows;
        self.scroll = 0;
        self.scroll_top = 0;
        self.scroll_bottom = self.rows - 1;
        self.cx = 0;
        self.cy = 0;
        self.pending_wrap = false;
    }

    pub fn leaveAltScreen(self: *Grid) void {
        const main = self.alt orelse return;
        self.allocator.free(self.cell_slab);
        self.allocator.free(self.ring);
        self.allocator.free(self.view_buf);
        self.* = main.*;
        self.alt = null;
        self.allocator.destroy(main);
    }

    // ---- kitty keyboard protocol + mode 2026 ----
    pub const KBD_DISAMBIGUATE: u8 = 1;
    pub const KBD_EVENT_TYPES: u8 = 2;
    pub const KBD_ALTERNATE_KEYS: u8 = 4;
    pub const KBD_REPORT_ALL_KEYS: u8 = 8;
    pub const KBD_REPORT_TEXT: u8 = 16;

    /// kitty "CSI = flags ; mode u" — mode 1 (or 0/default) replace flags,
    /// 2 set bits, 3 reset bits.
    pub fn setKbdFlags(self: *Grid, flags: i32, mode: i32) void {
        const f: u8 = @intCast(@as(u32, @bitCast(@as(i32, flags))) & 0xFF);
        switch (mode) {
            2 => self.kbd_flags |= f,
            3 => self.kbd_flags &= ~f,
            else => self.kbd_flags = f,
        }
    }

    /// kitty "CSI > flags u" — push current flags onto this screen's stack,
    /// evicting the oldest when full.
    pub fn pushKbdFlags(self: *Grid, flags: i32) void {
        const f: u8 = @intCast(@as(u32, @bitCast(@as(i32, flags))) & 0xFF);
        if (self.kbd_stack_len < 32) {
            self.kbd_stack[self.kbd_stack_len] = self.kbd_flags;
            self.kbd_stack_len += 1;
        } else {
            std.mem.copyForwards(u8, self.kbd_stack[0 .. 31], self.kbd_stack[1..32]);
            self.kbd_stack[31] = self.kbd_flags;
        }
        self.kbd_flags = f;
    }

    /// kitty "CSI < n u" — pop n entries; emptying the stack resets flags.
    pub fn popKbdFlags(self: *Grid, n: i32) void {
        var i: i32 = 0;
        while (i < n and self.kbd_stack_len > 0) : (i += 1) {
            self.kbd_stack_len -= 1;
            self.kbd_flags = self.kbd_stack[self.kbd_stack_len];
        }
        if (self.kbd_stack_len == 0) self.kbd_flags = 0;
    }

    /// DEC private mode 2026 — hold frame rendering while set (safety release
    /// is the renderer's job after a timeout).
    pub fn setSyncOutput(self: *Grid, on: bool) void {
        self.sync_output = on;
        self.sync_since_ns = if (on) blk: {
            var ts: std.os.linux.timespec = undefined;
            _ = std.os.linux.clock_gettime(.MONOTONIC, &ts);
            break :blk ts.sec * 1_000_000_000 + ts.nsec;
        } else 0;
    }

    pub fn reset(self: *Grid) !void {
        if (self.alt != null) self.leaveAltScreen();
        for (self.ring) |l| @memset(l.cells, .{});
        self.head = 0;
        self.count = self.rows;
        self.total = self.rows;
        self.scroll = 0;
        self.scroll_top = 0;
        self.scroll_bottom = self.rows - 1;
        self.cx = 0;
        self.cy = 0;
        self.pending_wrap = false;
        self.cur_fg = DEFAULT_COLOR;
        self.cur_bg = DEFAULT_COLOR;
        self.cur_attrs = .{};
    }

    /// Plain-text snapshot of lines [from_abs..total) (for `capture`).
    pub fn captureText(self: *const Grid, allocator: std.mem.Allocator, include_scrollback: bool) ![]u8 {
        var out = std.ArrayList(u8).empty;
        errdefer out.deinit(allocator);
        const start: usize = if (include_scrollback) self.total -| self.count else self.scroll;
        var a = start;
        while (a < self.total) : (a += 1) {
            const l = self.lineAt(a);
            var end = l.cells.len;
            while (end > 0 and l.cells[end - 1].cp == ' ') end -= 1;
            for (l.cells[0..end]) |c| {
                var buf: [4]u8 = undefined;
                const n = std.unicode.utf8Encode(c.cp, &buf) catch 1;
                try out.appendSlice(allocator, buf[0..n]);
            }
            try out.append(allocator, '\n');
        }
        return out.toOwnedSlice(allocator);
    }

    /// Resize the grid, preserving the bottom lines of the visible viewport.
    /// The alternate screen (and anything where correct preservation would be
    /// riskier than a reset) resets to a blank grid with the same size.
    pub fn resize(self: *Grid, allocator: std.mem.Allocator, new_cols: u32, new_rows: u32) !void {
        if (new_cols == self.cols and new_rows == self.rows) return;
        const was_alt = self.alt != null;
        const in_main = self.alt == null;
        const keep: u32 = if (in_main) @min(new_rows, self.rows) else 0;

        var fresh = try Grid.initCapacity(allocator, new_cols, new_rows, self.scrollback_max);
        errdefer fresh.deinit();

        if (keep > 0) {
            const src_start = self.rows - keep;
            const dst_start = new_rows - keep;
            var i: u32 = 0;
            while (i < keep) : (i += 1) {
                const src = self.lineAt(self.scroll + src_start + i);
                const dst = fresh.lineAt(dst_start + i);
                const n = @min(new_cols, self.cols);
                const src_cells = src.cells;
                const dst_cells = dst.cells;
                for (dst_cells, 0..) |*dcell, col| {
                    dcell.* = if (col < n) src_cells[col] else .{};
                }
            }
            // viewport-aligned counters (fresh has new_rows lines, no history yet beyond those kept)
            fresh.head = 0;
            fresh.total = new_rows;
            fresh.count = new_rows;
            fresh.scroll = 0;
        }

        // carry text mode state
        fresh.cur_fg = self.cur_fg;
        fresh.cur_bg = self.cur_bg;
        fresh.cur_attrs = self.cur_attrs;
        fresh.scroll_top = 0;
        fresh.scroll_bottom = new_rows - 1;
        fresh.cx = @min(self.cx, new_cols - 1);
        fresh.cy = @min(self.cy, new_rows - 1);
        fresh.pending_wrap = false;
        fresh.kbd_flags = self.kbd_flags;
        fresh.kbd_stack_len = self.kbd_stack_len;
        @memcpy(fresh.kbd_stack[0..fresh.kbd_stack_len], self.kbd_stack[0..self.kbd_stack_len]);
        fresh.sync_output = self.sync_output;
        fresh.sync_since_ns = self.sync_since_ns;
        fresh.cursor_visible = self.cursor_visible;
        fresh.bracketed_paste = self.bracketed_paste;

        // move fresh ownership into self; free the old allocations
        const old_ring = self.ring;
        const old_slab = self.cell_slab;
        const old_view = self.view_buf;
        self.ring = fresh.ring;
        self.cell_slab = fresh.cell_slab;
        self.view_buf = fresh.view_buf;
        self.head = fresh.head;
        self.total = fresh.total;
        self.count = fresh.count;
        self.scroll = fresh.scroll;
        self.scroll_top = fresh.scroll_top;
        self.scroll_bottom = fresh.scroll_bottom;
        self.cur_fg = fresh.cur_fg;
        self.cur_bg = fresh.cur_bg;
        self.cur_attrs = fresh.cur_attrs;
        self.cx = fresh.cx;
        self.cy = fresh.cy;
        self.pending_wrap = false;
        self.cols = new_cols;
        self.rows = new_rows;
        self.alt = null;
        allocator.free(old_slab);
        allocator.free(old_ring);
        allocator.free(old_view);
        _ = was_alt; // currently a reset when in alt screen; preserve-later
    }
};
