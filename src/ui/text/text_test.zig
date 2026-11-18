//! Text engine tests against a real font on disk:
//! /usr/share/fonts/liberation/LiberationSans-Regular.ttf
//! Verifies SFNT parsing, cmap, glyf outlines (simple + composite), the
//! scanline rasterizer (exact coverage properties + determinism), and the
//! atlas/drawText path. Dumps a PPM for visual evidence.
const std = @import("std");
const font = @import("font.zig");
const raster = @import("raster.zig");
const atlas_mod = @import("atlas.zig");

/// Locate a real SFNT on disk. Paths differ across distros
/// (Arch: /usr/share/fonts/liberation/, Debian/Ubuntu: /usr/share/fonts/truetype/liberation/);
/// returns null (tests skip with a clear note) when none is present.
fn findFont(comptime candidates: []const []const u8) ?[]const u8 {
    for (candidates) |p| {
        const fd = std.posix.openat(std.posix.AT.FDCWD, p, .{ .ACCMODE = .RDONLY }, 0) catch continue;
        _ = std.c.close(fd);
        return p;
    }
    return null;
}
const LIBERATION_CANDIDATES = [_][]const u8{
    "/usr/share/fonts/liberation/LiberationSans-Regular.ttf",
    "/usr/share/fonts/truetype/liberation/LiberationSans-Regular.ttf",
    "/usr/share/fonts/truetype/freefont/FreeSans.ttf",
};
const MATH_CANDIDATES = [_][]const u8{
    "/usr/share/fonts/TTF/DejaVuMathTeXGyre.ttf",
    "/usr/share/fonts/truetype/dejavu/DejaVuMathTeXGyre.ttf",
    "/usr/share/fonts/dejavu/DejaVuMathTeXGyre.ttf",
};
fn fontPath() ?[]const u8 {
    return findFont(&LIBERATION_CANDIDATES);
}

fn mathFontPath() ?[]const u8 {
    return findFont(&MATH_CANDIDATES);
}

fn readFile(path: []const u8, allocator: std.mem.Allocator) ![]u8 {
    const fd = try std.posix.openat(std.posix.AT.FDCWD, path, .{ .ACCMODE = .RDONLY }, 0);
    defer _ = std.c.close(fd);
    const buf = try allocator.alloc(u8, 8 * 1024 * 1024);
    var off: usize = 0;
    while (off < buf.len) {
        const n = try std.posix.read(fd, buf[off..]);
        if (n == 0) break;
        off += n;
    }
    return try allocator.realloc(buf, off);
}

fn loadFont(allocator: std.mem.Allocator) !?struct { data: []u8, f: font.Font } {
    const path = fontPath() orelse {
        std.debug.print("TEXT_SKIP no LiberationSans on disk\n", .{});
        return null;
    };
    const data = try readFile(path, allocator);
    const f = try font.Font.load(data);
    return .{ .data = data, .f = f };
}

test "SFNT directory: LiberationSans parses with sane tables" {
    const maybe = try loadFont(std.testing.allocator);
    if (maybe == null) return;
    const t = maybe.?;
    defer std.testing.allocator.free(t.data);
    try std.testing.expectEqual(@as(u16, 2048), t.f.units_per_em);
    try std.testing.expect(t.f.num_glyphs > 2000);
    try std.testing.expect(t.f.index_to_loc_format == 0 or t.f.index_to_loc_format == 1);
    try std.testing.expect(t.f.ascender > 0);
    try std.testing.expect(t.f.descender < 0);
    try std.testing.expect(t.f.num_h_metrics > 0);
    std.debug.print("TEXT_FONT_OK glyphs={d} upem={d} asc={d} desc={d} locfmt={d}\n", .{
        t.f.num_glyphs, t.f.units_per_em, t.f.ascender, t.f.descender, t.f.index_to_loc_format,
    });
}

test "cmap: 'A' resolves, space resolves with no outline, unknown -> 0" {
    const maybe = try loadFont(std.testing.allocator);
    if (maybe == null) return;
    const t = maybe.?;
    defer std.testing.allocator.free(t.data);
    const gid_a = try t.f.glyphIndex('A');
    const gid_space = try t.f.glyphIndex(' ');
    const gid_unknown = try t.f.glyphIndex(0x0F0000);
    try std.testing.expect(gid_a != 0);
    try std.testing.expect(gid_space != 0);
    try std.testing.expectEqual(@as(u16, 0), gid_unknown);
    const adv_a = try t.f.advanceWidth(gid_a);
    const adv_space = try t.f.advanceWidth(gid_space);
    try std.testing.expect(adv_a > 500 and adv_a < 2000); // font units at upem 2048
    try std.testing.expect(adv_space > 200 and adv_space < adv_a);
    var o_space = try t.f.outline(gid_space, std.testing.allocator);
    defer o_space.deinit(std.testing.allocator);
    try std.testing.expectEqual(@as(usize, 0), o_space.contours.len);
    std.debug.print("TEXT_CMAP_OK gid_A={d} adv_A={d} adv_space={d}\n", .{ gid_a, adv_a, adv_space });
}

test "glyf: 'A' outline has 2 contours (outer + counter) with sane bbox" {
    const maybe = try loadFont(std.testing.allocator);
    if (maybe == null) return;
    const t = maybe.?;
    defer std.testing.allocator.free(t.data);
    const gid = try t.f.glyphIndex('A');
    var o = try t.f.outline(gid, std.testing.allocator);
    defer o.deinit(std.testing.allocator);
    try std.testing.expectEqual(@as(usize, 2), o.contours.len);
    try std.testing.expect(o.x_max > o.x_min);
    try std.testing.expect(o.y_max > o.y_min);
    try std.testing.expect(o.y_max < 2000); // cap height below ascender
    // every contour closed: at least 3 points
    for (o.contours) |c| try std.testing.expect(c.points.len >= 3);
    std.debug.print("TEXT_OUTLINE_OK A contours={d} bbox=({d},{d})-({d},{d})\n", .{
        o.contours.len, o.x_min, o.y_min, o.x_max, o.y_max,
    });
}

test "glyf: composite glyph 'é' (U+00E9) resolves via components" {
    const maybe = try loadFont(std.testing.allocator);
    if (maybe == null) return;
    const t = maybe.?;
    defer std.testing.allocator.free(t.data);
    const gid = try t.f.glyphIndex(0xE9);
    try std.testing.expect(gid != 0);
    var o = try t.f.outline(gid, std.testing.allocator);
    defer o.deinit(std.testing.allocator);
    try std.testing.expect(o.contours.len >= 2); // 'e' body + acute accent
    try std.testing.expect(o.y_max > 1500); // accent extends above x-height
    std.debug.print("TEXT_COMPOSITE_OK e-acute contours={d} ymax={d}\n", .{ o.contours.len, o.y_max });
}

test "rasterizer: 'A' at 64px has full-cover interior, empty corners, symmetric ink, deterministic" {
    const maybe = try loadFont(std.testing.allocator);
    if (maybe == null) return;
    const t = maybe.?;
    defer std.testing.allocator.free(t.data);
    const gid = try t.f.glyphIndex('A');
    var o = try t.f.outline(gid, std.testing.allocator);
    defer o.deinit(std.testing.allocator);

    const W: u32 = 96;
    const H: u32 = 96;
    const px: f32 = 64;
    // center the glyph: offset so that bbox center lands mid-buffer
    const scale = px / 2048.0;
    const off_x = @as(f32, @floatFromInt(W)) / 2 - @as(f32, @floatFromInt(o.x_min + o.x_max)) / 2 * scale;
    const off_y = @as(f32, @floatFromInt(H)) / 2 + @as(f32, @floatFromInt(o.y_min + o.y_max)) / 2 * scale;
    const buf = try raster.rasterizeGlyph(&o, px, t.f.units_per_em, W, H, off_x, off_y, std.testing.allocator);
    defer std.testing.allocator.free(buf);
    const buf2 = try raster.rasterizeGlyph(&o, px, t.f.units_per_em, W, H, off_x, off_y, std.testing.allocator);
    defer std.testing.allocator.free(buf2);

    // determinism
    try std.testing.expectEqualSlices(u8, buf, buf2);

    // corners empty
    try std.testing.expectEqual(@as(u8, 0), buf[0]);
    try std.testing.expectEqual(@as(u8, 0), buf[W - 1]);
    try std.testing.expectEqual(@as(u8, 0), buf[(H - 1) * W]);
    try std.testing.expectEqual(@as(u8, 0), buf[H * W - 1]);

    // interior fully covered somewhere
    var full: usize = 0;
    var ink: usize = 0;
    var partial: usize = 0;
    for (buf) |b| {
        if (b == 255) full += 1;
        if (b > 0) ink += 1;
        if (b > 0 and b < 255) partial += 1;
    }
    std.debug.print("TEXT_RASTER_STATS full={d} ink={d} partial={d}\n", .{ full, ink, partial });
    try std.testing.expect(full > 100); // solid interior
    try std.testing.expect(ink > 500); // 64px 'A' ~ 42x44 bbox, ~40% fill
    try std.testing.expect(partial > 50); // AA edges exist

    // rough left-right symmetry of ink (Liberation 'A' is symmetric)
    var left_ink: usize = 0;
    var right_ink: usize = 0;
    for (0..H) |y| {
        for (0..W / 2) |x| {
            if (buf[y * W + x] > 0) left_ink += 1;
            if (buf[y * W + (W - 1 - x)] > 0) right_ink += 1;
        }
    }
    const diff = @abs(@as(i32, @intCast(left_ink)) - @as(i32, @intCast(right_ink)));
    try std.testing.expect(diff * 20 < @as(i32, @intCast(left_ink))); // within 5%

    std.debug.print("TEXT_RASTER_OK full={d} ink={d} partial={d} left={d} right={d}\n", .{ full, ink, partial, left_ink, right_ink });
}

test "atlas: measure + drawText produce expected ink; PPM evidence" {
    const maybe = try loadFont(std.testing.allocator);
    if (maybe == null) return;
    const t = maybe.?;
    defer std.testing.allocator.free(t.data);
    var at = try atlas_mod.TextAtlas.init(std.testing.allocator, t.data, 32);
    defer at.deinit();

    const m_h = try at.measure("H");
    const m_hh = try at.measure("HH");
    try std.testing.expectApproxEqAbs(m_h * 2, m_hh, 0.01);
    const m_hi = try at.measure("Hi");
    try std.testing.expect(m_hi > m_h);

    const W: u32 = 320;
    const H: u32 = 96;
    const fb = try std.testing.allocator.alloc(u32, W * H);
    defer std.testing.allocator.free(fb);
    for (fb) |*p| p.* = 0xFF04060B; // void background
    try at.drawText(fb, W, H, 8, 64, "Cipher 0.17", 0xFFEBB545); // brass text

    var ink: usize = 0;
    var brassish: usize = 0;
    for (fb) |p| {
        if (p != 0xFF04060B) ink += 1;
        const r = (p >> 16) & 0xFF;
        const g = (p >> 8) & 0xFF;
        const b = p & 0xFF;
        if (r > 0x80 and g > 0x60 and b < 0x80) brassish += 1;
    }
    try std.testing.expect(ink > 400);
    try std.testing.expect(brassish > 200);

    // PPM dump (ARGB -> RGB)
    var ppm: [W * H * 3]u8 = undefined;
    for (0..W * H) |i| {
        ppm[i * 3 + 0] = @intCast((fb[i] >> 16) & 0xFF);
        ppm[i * 3 + 1] = @intCast((fb[i] >> 8) & 0xFF);
        ppm[i * 3 + 2] = @intCast(fb[i] & 0xFF);
    }
    var header_buf: [64]u8 = undefined;
    const header = try std.fmt.bufPrint(&header_buf, "P6\n{d} {d}\n255\n", .{ W, H });
    const fd = try std.posix.openat(std.posix.AT.FDCWD, "/tmp/sifr_text.ppm", .{ .ACCMODE = .WRONLY, .CREAT = true, .TRUNC = true }, 0o644);
    defer _ = std.c.close(fd);
    _ = std.c.write(fd, header.ptr, header.len);
    // write in chunks via posix.write loop
    var off: usize = 0;
    while (off < ppm.len) {
        const n = std.c.write(fd, ppm[off..].ptr, ppm.len - off);
        if (n <= 0) break;
        off += @as(usize, @intCast(n));
    }
    std.debug.print("TEXT_ATLAS_OK measure_H={d:.2} ink={d} brassish={d} ppm=/tmp/sifr_text.ppm\n", .{ m_h, ink, brassish });
}

test "glyphSafe: unmapped/astral codepoints never error, layout survives" {
    const fpath = fontPath() orelse return;
    const font_data = try readFile(fpath, std.testing.allocator);
    defer std.testing.allocator.free(font_data);
    var a = try atlas_mod.TextAtlas.init(std.testing.allocator, font_data, 24);
    defer a.deinit();
    // 0x0F0000 is unmapped in LiberationSans (cmap format 4 returns
    // .notdef=0 for cp > 0xFFFF); neither may error the string.
    const w = try a.measure("A\u{F0000}B");
    try std.testing.expect(w > 20); // ~3 advances at px=24 (~16px each)
    try std.testing.expect(w < 200);
    var fb: [256 * 64]u32 = undefined;
    @memset(&fb, 0xFF04060B);
    try a.drawText(&fb, 256, 64, 4, 40, "A\u{0F0000}B", 0xFFE8ECF4);
    std.debug.print("TEXT_GLYPHSAFE_OK measure={d:.1}\n", .{w});
}

test "font fallback: math glyph missing from primary rasterizes from fallback" {
    const alloc = std.testing.allocator;
    const prim_path = fontPath() orelse {
        std.debug.print("TEXT_FALLBACK_SKIP no LiberationSans on disk\n", .{});
        return;
    };
    const prim = try readFile(prim_path, alloc);
    defer alloc.free(prim);
    const math_path = mathFontPath() orelse {
        std.debug.print("TEXT_FALLBACK_SKIP no math fallback font on disk\n", .{});
        return;
    };
    const math = try readFile(math_path, alloc);
    defer alloc.free(math);
    // sanity: primary really lacks U+2208, fallback has it
    const pf = try font.Font.load(prim);
    const mf = try font.Font.load(math);
    try std.testing.expectEqual(@as(u16, 0), try pf.glyphIndex(0x2208));
    try std.testing.expect((try mf.glyphIndex(0x2208)) != 0);
    var a = try atlas_mod.TextAtlas.init(alloc, prim, 24);
    defer a.deinit();
    // atlas with fallback: real ink from the math font, same texture
    try a.addFallback(math);
    const with_fb = try a.glyph(0x2208);
    try std.testing.expect(with_fb.w > 4);
    try std.testing.expect(with_fb.h > 4);
    std.debug.print("TEXT_FALLBACK_OK U+2208 w={d} h={d} adv={d:.2}\n", .{ with_fb.w, with_fb.h, with_fb.advance });
}
