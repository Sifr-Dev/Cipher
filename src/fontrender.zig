//! Renders a short string with the from-zero SFNT reader + rasterizer and
//! dumps a PPM evidence image. Usage: zig run src/fontrender.zig -- <font> <px> [text]
const std = @import("std");
const font = @import("font.zig");
const outline = @import("outline.zig");
const rasterize = @import("rasterize.zig");

pub fn main(init: std.process.Init) !void {
    const gpa = init.gpa;

    var args_iter = std.process.Args.Iterator.init(init.minimal.args);
    _ = args_iter.next();
    const path = args_iter.next() orelse {
        std.debug.print("usage: fontrender <font.ttf> <px> [text]\n", .{});
        std.process.exit(2);
    };
    const px = try std.fmt.parseUnsigned(u32, args_iter.next() orelse "72", 10);
    const text: []const u8 = args_iter.next() orelse "SIFR Cipher";

    const bytes = try std.Io.Dir.cwd().readFileAlloc(init.io, path, gpa, .limited(64 * 1024 * 1024));
    defer gpa.free(bytes);
    const parsed = try font.Font.parse(bytes);

    const scale = @as(f64, @floatFromInt(px)) / @as(f64, @floatFromInt(parsed.head.units_per_em));

    const width: usize = 1024;
    const height: usize = 256;
    var canvas = try rasterize.Canvas.init(gpa, width, height);
    defer canvas.deinit();
    canvas.clear(0);

    const origin_x: f64 = 24.0;
    const baseline_y: f64 = @as(f64, height) * 0.72;
    var pen_x: f64 = origin_x;

    var index: usize = 0;
    while (index < text.len) {
        const seq_len = std.unicode.utf8ByteSequenceLength(text[index]) catch break;
        const codepoint = std.unicode.utf8Decode(text[index..][0..seq_len]) catch break;
        const glyph = parsed.cmapGlyph(codepoint) orelse 0;

        if (glyph != 0) {
            var out = try outline.parseGlyph(&parsed, glyph, gpa);
            defer out.deinit();
            for (out.points) |*p| {
                const gx = p.x;
                const gy = p.y;
                p.x = gx * scale + pen_x;
                p.y = baseline_y - gy * scale;
            }
            try rasterize.fillGlyph(&canvas, &out, 0, 0);
        }
        pen_x += @as(f64, @floatFromInt(parsed.glyphAdvance(glyph))) * scale;
        index += seq_len;
    }

    try writePpm(&canvas, "/tmp/opencode/fontrender.ppm");
    std.debug.print("fontrender: wrote /tmp/opencode/fontrender.ppm ({d}x{d})\n", .{ width, height });
}

fn writePpm(canvas: *const rasterize.Canvas, path_c: [:0]const u8) !void {
    const fd_rc = std.os.linux.openat(std.os.linux.AT.FDCWD, path_c, .{ .ACCMODE = .WRONLY, .CREAT = true, .TRUNC = true }, 0o644);
    if (@as(i64, @bitCast(fd_rc)) < 0) return error.OpenFailed;
    const fd: i32 = @intCast(fd_rc);
    defer _ = std.os.linux.close(fd);

    var header_buf: [48]u8 = undefined;
    const header = std.fmt.bufPrint(&header_buf, "P6 {d} {d} 255\n", .{ canvas.width, canvas.height }) catch return error.HeaderTooLong;
    var written: usize = 0;
    while (written < header.len) {
        const rc = std.os.linux.write(fd, header[written..].ptr, header.len - written);
        if (@as(i64, @bitCast(rc)) < 0) return error.WriteFailed;
        written += @intCast(rc);
    }

    var rgb: [3]u8 = undefined;
    for (canvas.pixels) |alpha| {
        rgb = .{ alpha, alpha, alpha };
        const rc = std.os.linux.write(fd, &rgb, 3);
        if (@as(i64, @bitCast(rc)) < 0) return error.WriteFailed;
    }
}
