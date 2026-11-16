//! Scratch harness for the from-zero SFNT reader: prints table metrics,
//! cmap coverage, advances and glyph bounds for the bundled fonts.
const std = @import("std");
const font = @import("font.zig");

pub fn main(init: std.process.Init) !void {
    const gpa = init.gpa;

    var args_iter = std.process.Args.Iterator.init(init.minimal.args);
    _ = args_iter.next(); // program name
    const path = args_iter.next() orelse {
        std.debug.print("usage: ttfinfo <font.ttf> [text]\n", .{});
        std.process.exit(2);
    };
    var text: []const u8 = "SIFR Cipher";
    if (args_iter.next()) |raw| text = raw;

    const bytes = try std.Io.Dir.cwd().readFileAlloc(init.io, path, gpa, .limited(64 * 1024 * 1024));
    defer gpa.free(bytes);
    const parsed = try font.Font.parse(bytes);

    std.debug.print("units_per_em={d} glyphs={d} ascender={d} descender={d} line_gap={d}\n", .{
        parsed.head.units_per_em,
        parsed.maxp.num_glyphs,
        parsed.hhea.ascender,
        parsed.hhea.descender,
        parsed.hhea.line_gap,
    });
    std.debug.print("glyph bounds: x=[{d},{d}] y=[{d},{d}]\n", .{
        parsed.head.x_min,
        parsed.head.x_max,
        parsed.head.y_min,
        parsed.head.y_max,
    });

    var index: usize = 0;
    while (index < text.len) {
        const seq_len = std.unicode.utf8ByteSequenceLength(text[index]) catch {
            std.debug.print("invalid utf8 at byte {d}\n", .{index});
            std.process.exit(2);
        };
        const codepoint = std.unicode.utf8Decode(text[index..][0..seq_len]) catch {
            std.debug.print("invalid utf8 at byte {d}\n", .{index});
            std.process.exit(2);
        };
        const glyph = parsed.cmapGlyph(codepoint) orelse 0;
        std.debug.print("'{s}' U+{x:0>4} -> glyph {d} advance={d} lsb={d}\n", .{
            text[index .. index + seq_len],
            codepoint,
            glyph,
            parsed.glyphAdvance(glyph),
            parsed.glyphSideBearing(glyph),
        });
        index += seq_len;
    }

    for ([_]u16{ 0, 32, 65, 97 }) |sample| {
        const header = parsed.glyphHeader(sample) orelse {
            std.debug.print("glyph {d}: missing outlines\n", .{sample});
            continue;
        };
        std.debug.print("glyph {d}: contours={d} bounds x=[{d},{d}] y=[{d},{d}]\n", .{
            sample,
            header.number_of_contours,
            header.x_min,
            header.x_max,
            header.y_min,
            header.y_max,
        });
    }
}
