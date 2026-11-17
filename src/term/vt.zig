//! VT100/xterm escape-sequence parser. Feed bytes from the pty; it drives a
//! Grid. Supports: CSI cursor movement/erase/insert/delete/scroll/SGR/DECSTBM,
//! OSC (title, 7501 agent status — parsed and ignored), alt screen (1049),
//! bracketed paste (2004), cursor visibility (25), save/restore cursor,
//! scroll regions, reverse index. Mouse modes are parsed but reported as
//! "ignored" so the app can decide.
const std = @import("std");
const grid_mod = @import("grid.zig");
const Grid = grid_mod.Grid;

pub const ParserError = error{OutOfMemory};

pub const Parser = struct {
    state: State = .ground,
    csi_params: [16]i32 = std.mem.zeroes([16]i32),
    csi_nparams: usize = 0,
    csi_private: u8 = 0, // '?' or other private marker
    osc_buf: [8192]u8 = undefined,
    osc_len: usize = 0,
    osc_is_7501: bool = false,
    last_was_cr: bool = false,
    // Minimal streaming UTF-8 decoder state kept in the parser.
    utf8_buf: [4]u8 = undefined,
    utf8_len: usize = 0,
    utf8_need: usize = 0,

    /// Last OSC 7501 payload seen (agent status), for apps that care.
    pub var last_osc_7501: [256]u8 = undefined;
    pub var last_osc_7501_len: usize = 0;
    pub var last_title: [256]u8 = undefined;
    pub var last_title_len: usize = 0;

    pub const State = enum { ground, esc, csi, osc, osc_esc, charset };

    pub fn feed(self: *Parser, g: *Grid, bytes: []const u8) !void {
        for (bytes) |b| try self.byte(g, b);
    }

    fn byte(self: *Parser, g: *Grid, b: u8) !void {
        switch (self.state) {
            .ground => try self.ground(g, b),
            .esc => try self.esc(g, b),
            .csi => try self.csi(g, b),
            .osc => try self.oscByte(g, b),
            .osc_esc => {
                if (b == '\\') {
                    self.finishOsc();
                } else {
                    self.state = .osc;
                    try self.oscByte(g, b);
                }
            },
            .charset => {
                self.state = .ground; // ESC ( X — charset designation ignored
            },
        }
    }

    fn ground(self: *Parser, g: *Grid, b: u8) ParserError!void {
        switch (b) {
            0x1B => self.state = .esc,
            0x0A, 0x0B, 0x0C => try g.newline(), // LF/VT/FF
            0x0D => g.carriageReturn(),
            0x08 => g.backspace(),
            0x09 => g.tab(),
            0x00...0x07, 0x0E...0x1A, 0x1C...0x1F => {}, // other C0 ignored
            else => {
                // decode UTF-8 incrementally: collect continuation bytes
                if (b < 0x80) {
                    try g.putChar(@intCast(b));
                } else {
                    // start of multibyte; decode greedily from a tiny window is
                    // impossible here, so buffer via utf8 state:
                    try self.utf8(g, b);
                }
            },
        }
    }


    fn utf8(self: *Parser, g: *Grid, b: u8) ParserError!void {
        if (self.utf8_need == 0) {
            if (b & 0xE0 == 0xC0) {
                self.utf8_need = 2;
            } else if (b & 0xF0 == 0xE0) {
                self.utf8_need = 3;
            } else if (b & 0xF8 == 0xF0) {
                self.utf8_need = 4;
            } else {
                try g.putChar(0xFFFD); // invalid lead
                return;
            }
            self.utf8_len = 0;
            self.utf8_buf[self.utf8_len] = b;
            self.utf8_len += 1;
            self.utf8_need -= 1;
        } else {
            if (b & 0xC0 != 0x80) {
                // invalid continuation: emit replacement, reprocess byte
                try g.putChar(0xFFFD);
                self.utf8_need = 0;
                try self.ground(g, b);
                return;
            }
            self.utf8_buf[self.utf8_len] = b;
            self.utf8_len += 1;
            self.utf8_need -= 1;
            if (self.utf8_need == 0) {
                const cp = std.unicode.utf8Decode(self.utf8_buf[0..self.utf8_len]) catch 0xFFFD;
                try g.putChar(cp);
            }
        }
    }

    fn esc(self: *Parser, g: *Grid, b: u8) !void {
        switch (b) {
            '[' => {
                self.state = .csi;
                self.csi_nparams = 0;
                self.csi_params = std.mem.zeroes([16]i32);
                self.csi_private = 0;
            },
            ']' => {
                self.state = .osc;
                self.osc_len = 0;
                self.osc_is_7501 = false;
            },
            '(' , ')', '*', '+' => self.state = .charset,
            '7' => {
                g.saveCursor();
                self.state = .ground;
            },
            '8' => {
                g.restoreCursor();
                self.state = .ground;
            },
            'D' => { // IND
                try g.newline();
                self.state = .ground;
            },
            'E' => { // NEL
                try g.newline();
                g.carriageReturn();
                self.state = .ground;
            },
            'M' => { // RI reverse index
                try g.scrollDown(1);
                self.state = .ground;
            },
            'c' => { // RIS full reset
                try g.reset();
                self.state = .ground;
            },
            '=', '>' => self.state = .ground, // keypad modes
            '\\' => self.state = .ground, // ST
            else => self.state = .ground,
        }
    }

    fn param(self: *Parser, idx: usize, default: i32) i32 {
        if (idx < self.csi_nparams) {
            const v = self.csi_params[idx];
            return if (v == 0) default else v;
        }
        return default;
    }

    fn csi(self: *Parser, g: *Grid, b: u8) !void {
        if (b == '?' or b == '>' or b == '!' or b == ' ') {
            if (self.csi_nparams == 0 and self.csi_private == 0) self.csi_private = b;
            return;
        }
        if (b >= '0' and b <= '9') {
            if (self.csi_nparams == 0) self.csi_nparams = 1;
            const i = self.csi_nparams - 1;
            if (i < 16) {
                const cur = self.csi_params[i];
                self.csi_params[i] = std.math.clamp(cur * 10 + @as(i32, b - '0'), -1_000_000, 1_000_000);
            }
            return;
        }
        if (b == ';') {
            if (self.csi_nparams < 16) self.csi_nparams += 1;
            return;
        }
        if (b < 0x40 or b > 0x7E) return; // malformed; ignore byte
        const final = b;
        self.state = .ground;
        const priv = self.csi_private;
        self.csi_private = 0;
        if (priv == '?') {
            try self.csiPrivateMode(g, final);
            return;
        }
        try self.csiDispatch(g, final);
    }

    fn csiPrivateMode(self: *Parser, g: *Grid, final: u8) !void {
        const on = final == 'h';
        for (0..self.csi_nparams) |i| {
            const v = self.csi_params[i];
            switch (v) {
                25 => g.cursor_visible = on,
                2004 => g.bracketed_paste = on,
                1049, 1047, 1048 => {
                    if (on) try g.enterAltScreen() else g.leaveAltScreen();
                },
                1000, 1002, 1003, 1006 => {}, // mouse modes: parsed, ignored
                else => {},
            }
        }
    }

    fn csiDispatch(self: *Parser, g: *Grid, final: u8) !void {
        switch (final) {
            'A' => g.cy -|= @intCast(@max(0, self.param(0, 1) - 1)), // CUU
            'B' => g.cy = @min(g.rows - 1, g.cy + @as(u32, @intCast(@max(0, self.param(0, 1) - 1)))), // CUD
            'C' => g.cx = @min(g.cols - 1, g.cx + @as(u32, @intCast(@max(0, self.param(0, 1) - 1)))), // CUF
            'D' => g.cx -|= @intCast(@max(0, self.param(0, 1) - 1)), // CUB
            'E' => { // CNL
                g.cy = @min(g.rows - 1, g.cy + @as(u32, @intCast(@max(0, self.param(0, 1) - 1))));
                g.cx = 0;
            },
            'F' => { // CPL
                g.cy -|= @intCast(@max(0, self.param(0, 1) - 1));
                g.cx = 0;
            },
            'G', '`' => g.cx = @min(g.cols - 1, @as(u32, @intCast(@max(0, self.param(0, 1) - 1)))), // CHA/HPA
            'H', 'f' => { // CUP/HVP
                const row = @max(1, self.param(0, 1));
                const col = @max(1, self.param(1, 1));
                g.moveCursor(@intCast(col - 1), @intCast(row - 1));
            },
            'd' => g.cy = @intCast(@max(0, self.param(0, 1) - 1)), // VPA
            'J' => g.eraseInDisplay(@intCast(@max(0, self.csi_params[0]))),
            'K' => g.eraseInLine(@intCast(@max(0, self.csi_params[0]))),
            'L' => try g.insertLines(@intCast(@max(1, self.param(0, 1)))),
            'M' => try g.deleteLines(@intCast(@max(1, self.param(0, 1)))),
            'P' => g.deleteChars(@intCast(@max(1, self.param(0, 1)))),
            '@' => g.insertChars(@intCast(@max(1, self.param(0, 1)))),
            'S' => try g.scrollRegionUp(@intCast(@max(1, self.param(0, 1)))),
            'T' => try g.scrollDown(@intCast(@max(1, self.param(0, 1)))),
            'X' => g.eraseChars(@intCast(@max(1, self.param(0, 1)))),
            'r' => { // DECSTBM
                const top = @max(1, self.param(0, 1));
                const bottom = @max(top, self.param(1, @as(i32, @intCast(g.rows))));
                g.setScrollRegion(@intCast(top), @intCast(bottom));
            },
            's' => g.saveCursor(),
            'u' => g.restoreCursor(),
            'm' => self.sgr(g),
            else => {}, // DA, DECSCUSR, etc: ignored
        }
    }

    fn sgr(self: *Parser, g: *Grid) void {
        if (self.csi_nparams == 0) {
            self.csi_nparams = 1;
            self.csi_params[0] = 0;
        }
        var i: usize = 0;
        while (i < self.csi_nparams) : (i += 1) {
            const p = self.csi_params[i];
            switch (p) {
                0 => {
                    g.cur_fg = grid_mod.DEFAULT_COLOR;
                    g.cur_bg = grid_mod.DEFAULT_COLOR;
                    g.cur_attrs = .{};
                },
                1 => g.cur_attrs.bold = true,
                4 => g.cur_attrs.underline = true,
                7 => g.cur_attrs.reverse = true,
                22 => g.cur_attrs.bold = false,
                24 => g.cur_attrs.underline = false,
                27 => g.cur_attrs.reverse = false,
                30...37 => g.cur_fg = grid_mod.PALETTE_FLAG | @as(u32, @intCast(p - 30)),
                38 => {
                    // 38;5;n or 38;2;r;g;b
                    if (i + 1 < self.csi_nparams and self.csi_params[i + 1] == 5 and i + 2 < self.csi_nparams) {
                        g.cur_fg = grid_mod.PALETTE_FLAG | @as(u32, @intCast(self.csi_params[i + 2] & 0xFF));
                        i += 2;
                    } else if (i + 1 < self.csi_nparams and self.csi_params[i + 1] == 2 and i + 4 < self.csi_nparams) {
                        const r: u32 = @intCast(self.csi_params[i + 2] & 0xFF);
                        const gg: u32 = @intCast(self.csi_params[i + 3] & 0xFF);
                        const b: u32 = @intCast(self.csi_params[i + 4] & 0xFF);
                        g.cur_fg = 0xFF000000 | (r << 16) | (gg << 8) | b;
                        i += 4;
                    }
                },
                39 => g.cur_fg = grid_mod.DEFAULT_COLOR,
                40...47 => g.cur_bg = grid_mod.PALETTE_FLAG | @as(u32, @intCast(p - 40)),
                48 => {
                    if (i + 1 < self.csi_nparams and self.csi_params[i + 1] == 5 and i + 2 < self.csi_nparams) {
                        g.cur_bg = grid_mod.PALETTE_FLAG | @as(u32, @intCast(self.csi_params[i + 2] & 0xFF));
                        i += 2;
                    } else if (i + 1 < self.csi_nparams and self.csi_params[i + 1] == 2 and i + 4 < self.csi_nparams) {
                        const r: u32 = @intCast(self.csi_params[i + 2] & 0xFF);
                        const gg: u32 = @intCast(self.csi_params[i + 3] & 0xFF);
                        const b: u32 = @intCast(self.csi_params[i + 4] & 0xFF);
                        g.cur_bg = 0xFF000000 | (r << 16) | (gg << 8) | b;
                        i += 4;
                    }
                },
                49 => g.cur_bg = grid_mod.DEFAULT_COLOR,
                90...97 => g.cur_fg = grid_mod.PALETTE_FLAG | @as(u32, @intCast(p - 90 + 8)),
                100...107 => g.cur_bg = grid_mod.PALETTE_FLAG | @as(u32, @intCast(p - 100 + 8)),
                else => {},
            }
        }
    }

    fn oscByte(self: *Parser, g: *Grid, b: u8) !void {
        _ = g;
        if (b == 0x07) {
            self.finishOsc();
            return;
        }
        if (b == 0x1B) {
            self.state = .osc_esc;
            return;
        }
        if (self.osc_len < self.osc_buf.len) {
            self.osc_buf[self.osc_len] = b;
            self.osc_len += 1;
            if (self.osc_len == 4 and std.mem.eql(u8, self.osc_buf[0..4], "7501")) self.osc_is_7501 = true;
        }
    }

    fn finishOsc(self: *Parser) void {
        const data = self.osc_buf[0..self.osc_len];
        // OSC <code> ; <payload>
        var semi: usize = 0;
        while (semi < data.len and data[semi] != ';') semi += 1;
        const code = if (semi > 0) data[0..semi] else data;
        const payload = if (semi < data.len) data[semi + 1 ..] else &[_]u8{};
        if (std.mem.eql(u8, code, "0") or std.mem.eql(u8, code, "2")) {
            const n = @min(payload.len, last_title.len);
            @memcpy(last_title[0..n], payload[0..n]);
            last_title_len = n;
        } else if (std.mem.eql(u8, code, "7501")) {
            const n = @min(payload.len, last_osc_7501.len);
            @memcpy(last_osc_7501[0..n], payload[0..n]);
            last_osc_7501_len = n;
        }
        self.osc_len = 0;
        self.osc_is_7501 = false;
        self.state = .ground;
    }
};
