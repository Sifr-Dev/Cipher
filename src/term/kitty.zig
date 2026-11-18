//! Kitty keyboard protocol encoder.
//!
//! Implements the escape-code grammar from the kitty keyboard protocol spec:
//!   CSI number [:alternate-keys] [; modifiers[:event-type]] [; text-as-codepoints] u
//!   CSI 1 ; modifiers [ABCDEFHPQS]      (arrows, Home, End, F1-F4)
//!   CSI number ; modifiers ~            (Insert, Delete, PgUp, PgDn, F5+)
//!
//! Progressive enhancement flags implemented:
//!   0b1    disambiguate escape codes
//!   0b10   report event types     (:1 press, :2 repeat, :3 release)
//!   0b100  report alternate keys  (shifted key; base layout unknown)
//!   0b1000 report all keys        (implies disambiguation)
//!   0b10000 report associated text
//!
//! Wayland delivers releases (pressed=false) but cannot distinguish repeat
//! from press; repeats are reported as :1. Documented limitation.

const std = @import("std");
const grid_mod = @import("grid.zig");
const input = @import("../framework/input.zig");

pub const KBD_DISAMBIGUATE: u8 = grid_mod.Grid.KBD_DISAMBIGUATE;
pub const KBD_EVENT_TYPES: u8 = grid_mod.Grid.KBD_EVENT_TYPES;
pub const KBD_ALTERNATE_KEYS: u8 = grid_mod.Grid.KBD_ALTERNATE_KEYS;
pub const KBD_REPORT_ALL_KEYS: u8 = grid_mod.Grid.KBD_REPORT_ALL_KEYS;
pub const KBD_REPORT_TEXT: u8 = grid_mod.Grid.KBD_REPORT_TEXT;

const MOD_SHIFT: u32 = 1;
const MOD_ALT: u32 = 2;
const MOD_CTRL: u32 = 4;
const MOD_SUPER: u32 = 8;
const MOD_HYPER: u32 = 16;
const MOD_META: u32 = 32;
const MOD_CAPS: u32 = 64;
const MOD_NUM: u32 = 128;

fn modBits(m: input.Mods) u32 {
    var bits: u32 = 0;
    if (m.shift()) bits |= MOD_SHIFT;
    if (m.alt()) bits |= MOD_ALT;
    if (m.ctrl()) bits |= MOD_CTRL;
    if (m.caps()) bits |= MOD_CAPS;
    return bits;
}

/// The key's base (unshifted) codepoint per the spec.
fn baseCode(ev: input.KeyEvent) ?u32 {
    switch (ev.key) {
        .esc => return 27,
        .enter, .keypad_enter => return 13,
        .tab => return 9,
        .backspace => return 127,
        .printable => {
            const c = ev.char orelse return null;
            const cp: u32 = @intCast(c);
            if (!ev.mods.shift()) return cp;
            if (cp >= 'A' and cp <= 'Z') return cp + 32;
            return switch (cp) {
                ')' => '9', '!' => '1', '@' => '2', '#' => '3', '$' => '4',
                '%' => '5', '^' => '6', '&' => '7', '*' => '8', '(' => '9',
                '_' => '-', '+' => '=', '{' => '[', '}' => ']', '|' => '\\',
                ':' => ';', '"' => '\'', '<' => ',', '>' => '.', '?' => '/',
                '~' => '`',
                else => cp,
            };
        },
        else => return null,
    }
}

/// Shifted variant of the key for the alternate-keys sub-field.
/// Only present when shift is held and the key actually changes.
fn shiftedCode(ev: input.KeyEvent) ?u32 {
    const c = ev.char orelse return null;
    if (!ev.mods.shift()) return null;
    const cp: u32 = @intCast(c);
    if (cp == (baseCode(ev) orelse return null)) return null;
    return cp;
}

/// Encode `ev` per the active progressive-enhancement flags.
/// Returns bytes written, or null to fall back to the legacy byte path.
pub fn encode(ev: input.KeyEvent, kbd_flags: u8, out: []u8) ?usize {
    const disambiguate = (kbd_flags & KBD_DISAMBIGUATE) != 0;
    const report_all = (kbd_flags & KBD_REPORT_ALL_KEYS) != 0;
    if (!disambiguate and !report_all) return null;

    const bits = modBits(ev.mods);

    // Which keys are escape-coded in disambiguate mode?
    const esc_coded =
        report_all or
        ev.key == .esc or
        ev.key == .enter or ev.key == .keypad_enter or ev.key == .tab or ev.key == .backspace or
        (bits & (MOD_CTRL | MOD_ALT | MOD_SUPER | MOD_HYPER | MOD_META)) != 0;

    // In disambiguate mode, unquoted text keys pass through as UTF-8.
    const is_text_key = ev.key == .printable;
    if (is_text_key and !esc_coded) return null;

    // ----- functional (non-text) keys: arrows, home/end, F-keys, etc. -----
    if (!is_text_key and !is_enter_tab_backspace_esc(ev)) {
        return encodeFunctional(ev, bits, out);
    }

    // ----- text-producing or escape-able keys: CSI u -----
    const cp = baseCode(ev) orelse return null;
    const ev_type: u32 = if (ev.pressed) 1 else 3;
    const want_alt = (kbd_flags & KBD_ALTERNATE_KEYS) != 0;
    const shifted = if (want_alt) shiftedCode(ev) else null;
    const with_text = (kbd_flags & KBD_REPORT_TEXT) != 0 and is_text_key and ev.char != null;
    const want_types = (kbd_flags & KBD_EVENT_TYPES) != 0;

    var buf: [160]u8 = undefined;
    var len: usize = 0;
    len += appendStr(&buf, len, "\x1b[") catch return null;
    len = appendU32(&buf, len, cp) catch return null;
    if (shifted) |s| {
        len = appendStr(&buf, len, ":") catch return null;
        len = appendU32(&buf, len, s) catch return null;
    }
    if (bits != 0 or want_types) {
        len = appendStr(&buf, len, ";") catch return null;
        len = appendU32(&buf, len, 1 + bits) catch return null;
        if (want_types) {
            len = appendStr(&buf, len, ":") catch return null;
            len = appendU32(&buf, len, ev_type) catch return null;
        }
    }
    if (with_text) {
        const ch = ev.char.?;
        len = appendStr(&buf, len, ";") catch return null;
        len = appendU32(&buf, len, @intCast(ch)) catch return null;
    }
    len = appendStr(&buf, len, "u") catch return null;

    if (len > out.len) return null;
    @memcpy(out[0..len], buf[0..len]);
    return len;
}

fn is_enter_tab_backspace_esc(ev: input.KeyEvent) bool {
    return switch (ev.key) {
        .enter, .keypad_enter, .tab, .backspace, .esc => true,
        else => false,
    };
}

const FunctionalForm = enum { final_letter, final_tilde };

/// Encode arrows / home / end / F1-F4 as `CSI 1 ; mods [A-Z]`,
/// and Insert/Delete/PgUp/PgDn/F5+ as `CSI number ; mods ~`.
fn encodeFunctional(ev: input.KeyEvent, bits: u32, out: []u8) ?usize {
    const cmd: union(enum) { letter: u8, tilde: u8 } = switch (ev.key) {
        .up => .{ .letter = 'A' },
        .down => .{ .letter = 'B' },
        .right => .{ .letter = 'C' },
        .left => .{ .letter = 'D' },
        .home => .{ .letter = 'H' },
        .end => .{ .letter = 'F' },
        .f1 => .{ .letter = 'P' },
        .f2 => .{ .letter = 'Q' },
        .f3 => .{ .letter = 'R' },
        .f4 => .{ .letter = 'S' },
        .insert => .{ .tilde = 2 },
        .delete => .{ .tilde = 3 },
        .page_up => .{ .tilde = 5 },
        .page_down => .{ .tilde = 6 },
        .f5 => .{ .tilde = 15 },
        .f6 => .{ .tilde = 17 },
        .f7 => .{ .tilde = 18 },
        .f8 => .{ .tilde = 19 },
        .f9 => .{ .tilde = 20 },
        .f10 => .{ .tilde = 21 },
        .f11 => .{ .tilde = 23 },
        .f12 => .{ .tilde = 24 },
        else => return null, // unmapped functional key: legacy fallback
    };

    var buf: [80]u8 = undefined;
    var len: usize = 0;
    len += appendStr(&buf, len, "\x1b[") catch return null;
    switch (cmd) {
        .letter => {
            if (bits != 0) {
                len = appendStr(&buf, len, "1;") catch return null;
                len = appendU32(&buf, len, 1 + bits) catch return null;
                len = appendByte(&buf, len, cmd.letter) catch return null;
            } else {
                // no modifiers: parameters omitted entirely
                len = appendByte(&buf, len, cmd.letter) catch return null;
            }
        },
        .tilde => {
            len = appendU32(&buf, len, cmd.tilde) catch return null;
            if (bits != 0) {
                len = appendStr(&buf, len, ";") catch return null;
                len = appendU32(&buf, len, 1 + bits) catch return null;
            }
            len = appendStr(&buf, len, "~") catch return null;
        },
    }

    if (len > out.len) return null;
    @memcpy(out[0..len], buf[0..len]);
    return len;
}

fn appendStr(buf: []u8, len: usize, s: []const u8) !usize {
    if (len + s.len > buf.len) return error.NoSpace;
    @memcpy(buf[len..][0..s.len], s);
    return len + s.len;
}

fn appendByte(buf: []u8, len: usize, b: u8) !usize {
    if (len + 1 > buf.len) return error.NoSpace;
    buf[len] = b;
    return len + 1;
}

fn appendU32(buf: []u8, len: usize, v: u32) !usize {
    const s = std.fmt.bufPrint(buf[len..], "{d}", .{v}) catch return error.NoSpace;
    return len + s.len;
}

// ---- unit tests ----

test "ctrl+c encodes as CSI 99;5u" {
    const ev = input.KeyEvent{ .code = 46, .key = .printable, .char = 'c', .mods = .{ .raw = 0x4 }, .pressed = true };
    var buf: [64]u8 = undefined;
    const n = encode(ev, KBD_DISAMBIGUATE, &buf).?;
    try std.testing.expectEqualStrings("\x1b[99;5u", buf[0..n]);
}

test "disambiguate plain letter stays legacy (null)" {
    const ev = input.KeyEvent{ .code = 30, .key = .printable, .char = 'a', .mods = .{}, .pressed = true };
    var buf: [64]u8 = undefined;
    try std.testing.expect(encode(ev, KBD_DISAMBIGUATE, &buf) == null);
}

test "report-all encodes plain letter as CSI u" {
    const ev = input.KeyEvent{ .code = 30, .key = .printable, .char = 'a', .mods = .{}, .pressed = true };
    var buf: [64]u8 = undefined;
    const n = encode(ev, KBD_REPORT_ALL_KEYS, &buf).?;
    try std.testing.expectEqualStrings("\x1b[97u", buf[0..n]);
}

test "release reports event type 3" {
    const ev = input.KeyEvent{ .code = 30, .key = .printable, .char = 'a', .mods = .{ .raw = 0x4 }, .pressed = false };
    var buf: [64]u8 = undefined;
    const n = encode(ev, KBD_DISAMBIGUATE | KBD_EVENT_TYPES, &buf).?;
    try std.testing.expectEqualStrings("\x1b[97;5:3u", buf[0..n]);
}

test "ctrl+shift+a carries shifted-key alternate sub-field" {
    const ev = input.KeyEvent{ .code = 30, .key = .printable, .char = 'A', .mods = .{ .raw = 0x5 }, .pressed = true };
    var buf: [64]u8 = undefined;
    const n = encode(ev, KBD_DISAMBIGUATE | KBD_ALTERNATE_KEYS, &buf).?;
    try std.testing.expectEqualStrings("\x1b[97:65;6u", buf[0..n]);
}

test "shift+a alone passes through as text (null) in disambiguate" {
    const ev = input.KeyEvent{ .code = 30, .key = .printable, .char = 'A', .mods = .{ .raw = 0x1 }, .pressed = true };
    var buf: [64]u8 = undefined;
    try std.testing.expect(encode(ev, KBD_DISAMBIGUATE | KBD_ALTERNATE_KEYS, &buf) == null);
}

test "associated text reported as third field" {
    const ev = input.KeyEvent{ .code = 30, .key = .printable, .char = 'A', .mods = .{ .raw = 0x1 }, .pressed = true };
    var buf: [64]u8 = undefined;
    const n = encode(ev, KBD_REPORT_ALL_KEYS | KBD_REPORT_TEXT, &buf).?;
    try std.testing.expectEqualStrings("\x1b[97;2;65u", buf[0..n]);
}

test "enter/tab/backspace encode as CSI u under report-all" {
    const names = [_]input.Key{ .enter, .tab, .backspace };
    const cps = [_]u32{ 13, 9, 127 };
    for (names, cps) |k, cp| {
        const ev = input.KeyEvent{ .code = 0, .key = k, .char = null, .mods = .{}, .pressed = true };
        var buf: [64]u8 = undefined;
        const n = encode(ev, KBD_REPORT_ALL_KEYS, &buf).?;
        var want: [24]u8 = undefined;
        const want_s = try std.fmt.bufPrint(&want, "\x1b[{d}u", .{cp});
        try std.testing.expectEqualStrings(want_s, buf[0..n]);
    }
}

test "escape key encodes as CSI 27u under disambiguate" {
    const ev = input.KeyEvent{ .code = 1, .key = .esc, .char = null, .mods = .{}, .pressed = true };
    var buf: [64]u8 = undefined;
    const n = encode(ev, KBD_DISAMBIGUATE, &buf).?;
    try std.testing.expectEqualStrings("\x1b[27u", buf[0..n]);
}

test "arrows encode as CSI 1;mods A under disambiguate" {
    const ev = input.KeyEvent{ .code = 103, .key = .up, .char = null, .mods = .{ .raw = 0x4 }, .pressed = true };
    var buf: [64]u8 = undefined;
    const n = encode(ev, KBD_DISAMBIGUATE, &buf).?;
    try std.testing.expectEqualStrings("\x1b[1;5A", buf[0..n]);
}

test "plain arrows drop parameters" {
    const ev = input.KeyEvent{ .code = 103, .key = .up, .char = null, .mods = .{}, .pressed = true };
    var buf: [64]u8 = undefined;
    const n = encode(ev, KBD_DISAMBIGUATE, &buf).?;
    try std.testing.expectEqualStrings("\x1b[A", buf[0..n]);
}

test "insert/delete/home/end F-keys use CSI number;mods ~" {
    const cases = [_]struct { key: input.Key, num: u32 }{
        .{ .key = .insert, .num = 2 },
        .{ .key = .delete, .num = 3 },
        .{ .key = .page_up, .num = 5 },
        .{ .key = .page_down, .num = 6 },
        .{ .key = .f5, .num = 15 },
        .{ .key = .f6, .num = 17 },
        .{ .key = .f12, .num = 24 },
    };
    for (cases) |c| {
        const ev = input.KeyEvent{ .code = 0, .key = c.key, .char = null, .mods = .{ .raw = 0x1 }, .pressed = true };
        var buf: [64]u8 = undefined;
        const n = encode(ev, KBD_DISAMBIGUATE, &buf).?;
        var want: [24]u8 = undefined;
        const want_s = try std.fmt.bufPrint(&want, "\x1b[{d};2~", .{c.num});
        try std.testing.expectEqualStrings(want_s, buf[0..n]);
    }
}

test "event types omitted when flag off" {
    const ev = input.KeyEvent{ .code = 1, .key = .esc, .char = null, .mods = .{}, .pressed = false };
    var buf: [64]u8 = undefined;
    const n = encode(ev, KBD_DISAMBIGUATE, &buf).?;
    try std.testing.expectEqualStrings("\x1b[27u", buf[0..n]);
}
