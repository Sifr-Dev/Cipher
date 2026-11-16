const std = @import("std");
const font = @import("font.zig");
const outline = @import("outline.zig");

pub fn main(init: std.process.Init) !void {
    const gpa = init.gpa;

    var args_iter = std.process.Args.Iterator.init(init.minimal.args);
    _ = args_iter.next();
    const path = args_iter.next() orelse {
        std.debug.print("usage: glyphcheck <font.ttf> [codepoint ...]\n", .{});
        std.process.exit(2);
    };

    const bytes = try std.Io.Dir.cwd().readFileAlloc(init.io, path, gpa, .limited(64 * 1024 * 1024));
    defer gpa.free(bytes);
    const parsed = try font.Font.parse(bytes);

    var total: usize = 0;
    while (args_iter.next()) |raw| {
        const codepoint = try std.fmt.parseUnsigned(u32, raw, 0);
        const glyph = parsed.cmapGlyph(codepoint) orelse 0;
        total += 1;
        const header = parsed.glyphHeader(glyph) orelse {
            std.debug.print("U+{x:0>4} glyph {d}: no glyf entry (blank)\n", .{ codepoint, glyph });
            continue;
        };
        var out = outline.parseGlyph(&parsed, glyph, gpa) catch |err| {
            std.debug.print("U+{x:0>4} glyph {d}: parse error {s}\n", .{ codepoint, glyph, @errorName(err) });
            continue;
        };
        defer out.deinit();
        std.debug.print("U+{x:0>4} glyph {d}: contours={d} points={d} raw_contours={d} bounds x=[{d:.1},{d:.1}] y=[{d:.1},{d:.1}]\n", .{
            codepoint,
            glyph,
            out.contours.len,
            out.points.len,
            header.number_of_contours,
            out.x_min,
            out.x_max,
            out.y_min,
            out.y_max,
        });
    }

    std.debug.print("checked {d} codepoints\n", .{total});
}
