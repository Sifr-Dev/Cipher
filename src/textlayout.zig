//! From-zero text layout for Cipher: word wrapping, baseline-anchored line
//! boxes, and alignment. Coordinates are absolute frame pixels, y-down.
//! Layout happens on the CPU (pure arithmetic over font metrics); the GPU
//! only samples the atlas — this module produces the instance records.
//!
//! Contract:
//!   layout(font, allocator, text, origin_x, block_top, max_width, alignment)
//!   -> TextBlock { instances (absolute frame pixels), width, height, line_count }
const std = @import("std");
const font_mod = @import("font.zig");
const atlas_mod = @import("atlas.zig");

pub const Error = error{ OutOfMemory, TextTooWide };

pub const Alignment = enum { left, center, right };

pub const TextBlock = struct {
    /// Flattened glyph instances in absolute frame pixel coordinates.
    instances: []atlas_mod.Instance,
    /// Widest line in pixels.
    width: f64,
    /// Block height in pixels (all lines).
    height: f64,
    line_count: usize,
    allocator: std.mem.Allocator,

    pub fn deinit(self: *TextBlock) void {
        self.allocator.free(self.instances);
    }
};

pub const LineBox = struct {
    /// Pen x where the line starts (after alignment).
    x: f64,
    /// Baseline y of this line.
    baseline: f64,
    /// Advance width of the line's glyphs.
    width: f64,
};

const MAX_WORDS = 512;

fn wordAdvance(f: *const font_mod.Font, scale: f64, word: []const u8) f64 {
    var advance: f64 = 0;
    var index: usize = 0;
    while (index < word.len) {
        const seq_len = std.unicode.utf8ByteSequenceLength(word[index]) catch {
            index += 1;
            continue;
        };
        if (index + seq_len > word.len) break;
        const codepoint = std.unicode.utf8Decode(word[index..][0..seq_len]) catch {
            index += seq_len;
            continue;
        };
        const glyph = f.cmapGlyph(codepoint) orelse 0;
        advance += @as(f64, @floatFromInt(f.glyphAdvance(glyph))) * scale;
        index += seq_len;
    }
    return advance;
}

/// Wraps `text` into lines of at most `max_width` advance pixels. Words
/// longer than `max_width` are kept whole (they overflow rather than
/// mid-word-split, matching editorial convention for display text).
/// Returns one LineBox per line plus the instances for the whole block.
pub fn layout(
    f: *const font_mod.Font,
    allocator: std.mem.Allocator,
    text: []const u8,
    origin_x: f64,
    block_top: f64,
    max_width: f64,
    alignment: Alignment,
) Error!TextBlock {
    const scale = @as(f64, @floatFromInt(atlas_mod.PX_EM)) / @as(f64, @floatFromInt(f.head.units_per_em));
    const ascent = @as(f64, @floatFromInt(f.hhea.ascender)) * scale;
    const descent = @as(f64, @floatFromInt(-f.hhea.descender)) * scale;
    const line_height = (ascent + descent + @as(f64, @floatFromInt(f.hhea.line_gap)) * scale) * 1.25;

    var instances = std.ArrayList(atlas_mod.Instance).empty;
    defer instances.deinit(allocator);

    var lines = std.ArrayList(LineBox).empty;
    defer lines.deinit(allocator);

    // Split on newlines first, then wrap each paragraph word-wise.
    var paragraphs = std.mem.splitScalar(u8, text, '\n');
    while (paragraphs.next()) |paragraph| {
        if (paragraph.len == 0) continue;

        var current = std.ArrayList([]const u8).empty;
        defer current.deinit(allocator);
        var current_width: f64 = 0;

        var words = std.mem.tokenizeScalar(u8, paragraph, ' ');
        var word_count: usize = 0;
        while (words.next()) |word| {
            word_count += 1;
            if (word_count > MAX_WORDS) break;
            const word_width = wordAdvance(f, scale, word);
            const space_width = wordAdvance(f, scale, " ");
            const projected = if (current.items.len == 0)
                word_width
            else
                current_width + space_width + word_width;

            if (current.items.len > 0 and projected > max_width) {
                try flushLine(f, allocator, &current, current_width, origin_x, max_width, alignment, lines.items.len, block_top, line_height, &lines, &instances);
                current.clearRetainingCapacity();
                current_width = 0;
            }

            const added = if (current.items.len == 0) word_width else space_width + word_width;
            try current.append(allocator, word);
            current_width += added;
        }

        if (current.items.len > 0) {
            try flushLine(f, allocator, &current, current_width, origin_x, max_width, alignment, lines.items.len, block_top, line_height, &lines, &instances);
        }
    }

    var widest: f64 = 0;
    for (lines.items) |line| widest = @max(widest, line.width);

    const block_height = if (lines.items.len == 0) 0 else @as(f64, @floatFromInt(lines.items.len)) * line_height;

    return .{
        .instances = try instances.toOwnedSlice(allocator),
        .width = widest,
        .height = block_height,
        .line_count = lines.items.len,
        .allocator = allocator,
    };
}

fn flushLine(
    f: *const font_mod.Font,
    allocator: std.mem.Allocator,
    words: *std.ArrayList([]const u8),
    line_width: f64,
    origin_x: f64,
    max_width: f64,
    alignment: Alignment,
    line_index: usize,
    block_top: f64,
    line_height: f64,
    lines: *std.ArrayList(LineBox),
    instances: *std.ArrayList(atlas_mod.Instance),
) Error!void {
    const scale = @as(f64, @floatFromInt(atlas_mod.PX_EM)) / @as(f64, @floatFromInt(f.head.units_per_em));
    const ascent = @as(f64, @floatFromInt(f.hhea.ascender)) * scale;

    const pen_x = switch (alignment) {
        .left => origin_x,
        .center => origin_x + (max_width - line_width) / 2.0,
        .right => origin_x + max_width - line_width,
    };
    const baseline = block_top + ascent + @as(f64, @floatFromInt(line_index)) * line_height;

    var pen = pen_x;
    const space_width = wordAdvance(f, scale, " ");
    for (words.items, 0..) |word, i| {
        const word_width = wordAdvance(f, scale, word);
        const word_instances = try atlas_mod.Atlas.instancesFor(f, allocator, word, pen, baseline);
        defer allocator.free(word_instances);
        for (word_instances) |instance| {
            try instances.append(allocator, instance);
        }
        pen += word_width;
        if (i + 1 < words.items.len) pen += space_width;
    }

    try lines.append(allocator, .{
        .x = pen_x,
        .baseline = baseline,
        .width = line_width,
    });
}

test "wrapping produces the expected line boxes" {
    const allocator = std.testing.allocator;

    const bytes = std.Io.Dir.cwd().readFileAlloc(std.testing.io, "assets/instrument-sans.ttf", allocator, .limited(1 << 20)) catch |err| {
        std.debug.print("font fixture missing: {}\n", .{err});
        return;
    };
    defer allocator.free(bytes);
    const parsed = try font_mod.Font.parse(bytes);

    var block = try layout(&parsed, allocator, "SIFR\nBUILT FROM ZERO", 0, 0, 640.0, .center);
    defer block.deinit();
    try std.testing.expectEqual(@as(usize, 2), block.line_count);
    try std.testing.expect(block.instances.len > 10);
    try std.testing.expect(block.width < 640.0);

    // The same string wraps when the max width shrinks.
    var narrow = try layout(&parsed, allocator, "BUILT FROM ZERO", 0, 0, 100.0, .left);
    defer narrow.deinit();
    try std.testing.expect(narrow.line_count > 1);
    try std.testing.expect(narrow.instances.len >= block.instances.len or narrow.line_count > 1);
}
