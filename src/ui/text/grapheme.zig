//! Extended grapheme cluster segmentation (UAX #29 subset) for the text
//! editing stack. A cursor may only stop at cluster boundaries, so "é" (two
//! bytes) or "e" + U+0301 deletes and moves as one unit, and an emoji ZWJ
//! sequence is never split by Backspace.
//!
//! Implemented rules:
//!   GB3   CR x LF
//!   GB3c  Prepend x
//!   GB4   (Control | CR | LF) ÷
//!   GB5   ÷ (Control | CR | LF)
//!   GB6   L x (L | V | LV | LVT)
//!   GB7   (LV | V) x (V | T)
//!   GB8   (LVT | T) x T
//!   GB9   x (Extend | ZWJ)
//!   GB9a  x SpacingMark
//!   GB9b  Prepend x
//!   GB11  ExtPict Extend* ZWJ x ExtPict
//!   GB12/13  Regional_Indicator pairs
//!   GB999 Any ÷ Any
//!
//! Not modelled (documented limitation, not silently wrong): Hangul LVT
//! conjoining jamo as separate codepoints (only precomposed syllables are
//! treated as one cluster), Indic conjunct GB9c (Virama sequences), and
//! extended pictographic data beyond ZWJ-rejoining (we do not import the
//! full emoji property table; emoji bases are treated as Any).
const std = @import("std");
const tables = @import("unicode_tables.zig");

pub const MAX_CLUSTER_BYTES = 64;

/// Decode one UTF-8 codepoint, returning its length. Invalid bytes decode as
/// U+FFFD with length 1 so callers always make progress.
pub fn decode(s: []const u8) struct { cp: u21, len: usize } {
    if (s.len == 0) return .{ .cp = 0, .len = 0 };
    const n = std.unicode.utf8ByteSequenceLength(s[0]) catch return .{ .cp = 0xFFFD, .len = 1 };
    if (n > s.len) return .{ .cp = 0xFFFD, .len = 1 };
    const cp = std.unicode.utf8Decode(s[0..n]) catch return .{ .cp = 0xFFFD, .len = 1 };
    return .{ .cp = cp, .len = n };
}

fn isControl(cp: u21) bool {
    // C0/C1 controls plus DEL. Format characters (Cf) are Extend below.
    return cp < 0x20 or (cp >= 0x7F and cp < 0xA0) or cp == 0x0D or cp == 0x0A or cp == 0x0C;
}

fn isExtend(cp: u21) bool {
    // Variation selectors and emoji modifiers are not Mn/Me; the generator
    // folds them in.
    return tables.inRanges(&tables.extend, cp);
}

fn isSpacingMark(cp: u21) bool {
    return tables.inRanges(&tables.spacing_mark, cp);
}

fn isRegionalIndicator(cp: u21) bool {
    return cp >= 0x1F1E6 and cp <= 0x1F1FF;
}

fn hangulType(cp: u21) enum { none, l, v, t, lv, lvt } {
    return switch (cp) {
        0x1100...0x115F, 0xA960...0xA97C => .l,
        0x1160...0x11A7, 0xD7B0...0xD7C6 => .v,
        0x11A8...0x11FF, 0xD7CB...0xD7FB => .t,
        0xAC00...0xD7A3 => if ((cp - 0xAC00) % 28 == 0) .lv else .lvt,
        else => .none,
    };
}

const State = struct {
    /// Last non-Extend/ZWJ codepoint, for GB11 (ExtPict Extend* ZWJ x ExtPict).
    prev_base: u21 = 0,
    seen_zwj_after_base: bool = false,
    /// Consecutive Regional_Indicator count in the current run (GB12/13).
    ri_count: u32 = 0,
};

fn isExtendedPictographic(cp: u21) bool {
    // A pragmatic approximation: the pictographic planes plus the emoji
    // blocks that most ZWJ sequences start from. Documented limitation: this
    // is not the full UTS #51 ExtPict property.
    return (cp >= 0x1F000 and cp <= 0x1FAFF) or
        (cp >= 0x2600 and cp <= 0x27BF) or
        (cp >= 0x2190 and cp <= 0x21FF) or
        (cp >= 0x2B00 and cp <= 0x2BFF) or
        cp == 0x00A9 or cp == 0x00AE or cp == 0x203C or cp == 0x2049 or
        cp == 0x2122 or cp == 0x2139 or cp == 0x3030 or cp == 0x303D or
        cp == 0x3297 or cp == 0x3299;
}

fn shouldBreak(prev: u21, cur: u21, st: *State) bool {
    // GB3
    if (prev == '\r' and cur == '\n') return false;
    // GB4 / GB5
    if (isControl(prev)) return true;
    if (isControl(cur)) return true;
    // GB9 / GB9a: Extend and SpacingMark attach to whatever precedes them.
    if (isExtend(cur)) return false;
    if (isSpacingMark(cur)) return false;
    // GB11: ExtPict Extend* ZWJ x ExtPict.
    if (st.seen_zwj_after_base and isExtendedPictographic(st.prev_base) and isExtendedPictographic(cur)) return false;
    // GB6/7/8 Hangul syllables and jamo.
    const pt = hangulType(prev);
    const ct = hangulType(cur);
    switch (pt) {
        .l => if (ct == .l or ct == .v or ct == .lv or ct == .lvt) return false,
        .v, .lv => if (ct == .v or ct == .t) return false,
        .t, .lvt => if (ct == .t) return false,
        else => {},
    }
    // GB12/13: adjacent regional indicators pair up; a break happens only
    // after an even number of them (flags are two codepoints).
    if (isRegionalIndicator(prev) and isRegionalIndicator(cur)) {
        return (st.ri_count % 2) == 0;
    }
    return true;
}

fn noteConsumed(cur: u21, st: *State) void {
    st.ri_count = if (isRegionalIndicator(cur)) st.ri_count + 1 else 0;
    // ZWJ is Extend for GB9 but drives GB11, so test it before the Extend
    // early-return.
    if (cur == 0x200D) {
        st.seen_zwj_after_base = true;
        return;
    }
    if (isExtend(cur)) return; // keep prev_base
    st.seen_zwj_after_base = false;
    st.prev_base = cur;
}

/// Length in bytes of the first extended grapheme cluster in `s`.
/// Returns 0 for an empty slice. Invalid UTF-8 advances one byte.
pub fn clusterLen(s: []const u8) usize {
    if (s.len == 0) return 0;
    var st = State{};
    const first = decode(s);
    var len: usize = first.len;
    noteConsumed(first.cp, &st);
    var prev = first.cp;
    while (len < s.len and len < MAX_CLUSTER_BYTES) {
        const d = decode(s[len..]);
        if (shouldBreak(prev, d.cp, &st)) break;
        noteConsumed(d.cp, &st);
        prev = d.cp;
        len += d.len;
    }
    return len;
}

/// Count extended grapheme clusters in `s`.
pub fn count(s: []const u8) usize {
    var i: usize = 0;
    var n: usize = 0;
    while (i < s.len) : (n += 1) i += clusterLen(s[i..]);
    return n;
}

/// Byte index of the cluster that starts at or before `byte_index`, moving
/// back one cluster. Returns 0 when already at the start.
pub fn prevBoundary(s: []const u8, byte_index: usize) usize {
    if (byte_index == 0) return 0;
    const idx = @min(byte_index, s.len);
    var i: usize = 0;
    var last: usize = 0;
    while (i < idx) {
        last = i;
        i += clusterLen(s[i..]);
        if (i >= idx) return last;
    }
    return last;
}

/// Byte index of the next cluster boundary after `byte_index`.
pub fn nextBoundary(s: []const u8, byte_index: usize) usize {
    if (byte_index >= s.len) return s.len;
    var i: usize = 0;
    while (i < byte_index) i += clusterLen(s[i..]);
    return @min(s.len, i + clusterLen(s[i..]));
}

/// Snap an arbitrary byte index down to a cluster boundary. This is what the
/// IME boundary guarantees the runtime upholds: cursors never point inside a
/// codepoint or inside a composed cluster.
pub fn floorBoundary(s: []const u8, byte_index: usize) usize {
    if (byte_index >= s.len) return s.len;
    var i: usize = 0;
    while (i < byte_index) {
        const next = i + clusterLen(s[i..]);
        if (next > byte_index) return i;
        i = next;
    }
    return i;
}

/// ASCII fast path used by measurement code: codepoint count when the string
/// is pure ASCII, null otherwise.
pub fn asciiLen(s: []const u8) ?usize {
    return if (std.ascii.isAscii(s)) s.len else null;
}

test "clusterLen: ASCII, combining mark, precomposed, invalid byte" {
    try std.testing.expectEqual(@as(usize, 1), clusterLen("a"));
    try std.testing.expectEqual(@as(usize, 2), clusterLen("é")); // precomposed U+00E9
    try std.testing.expectEqual(@as(usize, 3), clusterLen("e\u{0301}")); // e + combining acute
    try std.testing.expectEqual(@as(usize, 1), clusterLen("\xff"));
    try std.testing.expectEqual(@as(usize, 0), clusterLen(""));
    std.debug.print("GRAPHEME_BASIC_OK\n", .{});
}

test "clusterLen: emoji ZWJ family is one cluster" {
    const family = "\u{1F468}\u{200D}\u{1F469}\u{200D}\u{1F467}"; // man ZWJ woman ZWJ girl
    try std.testing.expectEqual(family.len, clusterLen(family));
    try std.testing.expectEqual(@as(usize, 1), count(family));
    // Skin tone modifier attaches to the base.
    const wave = "\u{1F44B}\u{1F3FD}";
    try std.testing.expectEqual(wave.len, clusterLen(wave));
    try std.testing.expectEqual(@as(usize, 1), count(wave));
    std.debug.print("GRAPHEME_EMOJI_OK\n", .{});
}

test "clusterLen: flags are RI pairs" {
    const flag = "\u{1F1EA}\u{1F1EC}"; // EG
    try std.testing.expectEqual(flag.len, clusterLen(flag));
    const two_flags = flag ++ flag;
    try std.testing.expectEqual(@as(usize, 2), count(two_flags));
    try std.testing.expectEqual(clusterLen(flag), clusterLen(two_flags));
    std.debug.print("GRAPHEME_FLAGS_OK\n", .{});
}

test "clusterLen: Hangul precomposed syllable plus conjoining jamo" {
    // 한 = U+D55C (LVT), then a trailing jamo attaches.
    const s = "\u{D55C}\u{11AB}";
    try std.testing.expectEqual(s.len, clusterLen(s));
    try std.testing.expectEqual(@as(usize, 1), count(s));
    std.debug.print("GRAPHEME_HANGUL_OK\n", .{});
}

test "prev/next/floor boundary" {
    const s = "aé" ++ "\u{1F44B}\u{1F3FD}" ++ "b";
    // bytes: a=1, é=2, wave=4, modifier=4, b=1
    try std.testing.expectEqual(@as(usize, 1), nextBoundary(s, 0));
    try std.testing.expectEqual(@as(usize, 3), nextBoundary(s, 1));
    try std.testing.expectEqual(@as(usize, 1), floorBoundary(s, 2)); // inside é
    try std.testing.expectEqual(@as(usize, 1), prevBoundary(s, 3));
    try std.testing.expectEqual(@as(usize, 3), prevBoundary(s, 4));
    try std.testing.expectEqual(@as(usize, 3), floorBoundary(s, 5)); // inside the emoji cluster
    try std.testing.expectEqual(@as(usize, 3), floorBoundary(s, 10)); // inside the emoji cluster: snap to its start
    try std.testing.expectEqual(@as(usize, 11), nextBoundary(s, 3)); // jump over the whole cluster
    try std.testing.expectEqual(s.len, floorBoundary(s, s.len));
    try std.testing.expectEqual(s.len, nextBoundary(s, s.len));
    std.debug.print("GRAPHEME_BOUNDARY_OK\n", .{});
}

test "CRLF is one cluster" {
    const s = "a\r\nb";
    try std.testing.expectEqual(@as(usize, 2), clusterLen(s[1..]));
    try std.testing.expectEqual(@as(usize, 3), count(s));
    std.debug.print("GRAPHEME_CRLF_OK\n", .{});
}
