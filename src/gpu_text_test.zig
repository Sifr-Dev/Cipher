//! End-to-end GPU text test: build the CPU glyph atlas from a real TTF,
//! upload it to a device-local R8 texture, render a glyph quad at 20px through the
//! text graphics pipeline, copy to host, and assert EXACT pixels.
const std = @import("std");
const device = @import("gpu/vulkan/device.zig");
const text = @import("gpu/vulkan/text.zig");
const atlas_mod = @import("ui/text/atlas.zig");

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
fn fontPath() ?[]const u8 {
    return findFont(&LIBERATION_CANDIDATES);
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

test "GPU text: atlas upload + glyph quad renders exact pixels" {
    const fpath = fontPath() orelse {
        std.debug.print("GPU_SKIP gpu_text: LiberationSans not on disk\n", .{});
        return;
    };
    const data = try readFile(fpath, std.testing.allocator);
    defer std.testing.allocator.free(data);

    // CPU atlas at 64px, glyph 'A'.
    var at = try atlas_mod.TextAtlas.init(std.testing.allocator, data, 64);
    defer at.deinit();
    const g = try at.glyph('A');
    try std.testing.expect(g.w > 10 and g.h > 10);

    // Find a solid-interior texel (cov==255 with all 4 neighbors 255) and a
    // hole texel (cov==0 surrounded by ink) inside the glyph bitmap.
    const covAt = struct {
        fn f(a: *const atlas_mod.TextAtlas, gi: atlas_mod.GlyphInfo, ix: u32, iy: u32) u8 {
            return a.atlas[@as(usize, gi.atlas_y + iy) * a.atlas_w + gi.atlas_x + ix];
        }
    }.f;
    var solid: ?[2]u32 = null;
    var hole: ?[2]u32 = null;
    var zeros: usize = 0;
    var iy: u32 = 2;
    while (iy < g.h - 2) : (iy += 1) {
        var ix: u32 = 2;
        while (ix < g.w - 2) : (ix += 1) {
            const c = covAt(&at, g, ix, iy);
            if (c == 0 and ix > 1 and iy > 1) zeros += 1;
            if (solid == null and c == 255 and
                covAt(&at, g, ix - 1, iy) == 255 and covAt(&at, g, ix + 1, iy) == 255 and
                covAt(&at, g, ix, iy - 1) == 255 and covAt(&at, g, ix, iy + 1) == 255)
            {
                solid = .{ ix, iy };
            }
            if (hole == null and c == 0 and ix > 1 and iy > 1 and ix < g.w - 2 and iy < g.h - 2) {
                hole = .{ ix, iy };
            }
        }
    }
    try std.testing.expect(solid != null);
    try std.testing.expect(hole != null);
    const sp = solid.?;
    const hp = hole.?;
    std.debug.print("TEXT_GPU_TEXELS solid=({d},{d}) hole=({d},{d}) glyph={d}x{d} zeros={d}\n", .{ sp[0], sp[1], hp[0], hp[1], g.w, g.h, zeros });

    // GPU pipeline.
    var vk = device.load() catch |e| {
        std.debug.print("GPU_SKIP gpu_text: {s}\n", .{@errorName(e)});
        return;
    };
    var dev: device.Device = .{};
    device.createDevice(&vk, &dev) catch |e| {
        std.debug.print("GPU_SKIP gpu_text: createDevice {s}\n", .{@errorName(e)});
        return;
    };

    const W: u32 = 160;
    const H: u32 = 96;
    var gt = try text.GpuText.init(&vk, &dev, W, H, at.atlas_w, at.atlas_h);
    try gt.uploadAtlas(&vk, &dev, at.atlas);

    const brass: [4]f32 = .{ 235.0 / 255.0, 181.0 / 255.0, 69.0 / 255.0, 1.0 };
    const qx: f32 = 16;
    const qy: f32 = 16;
    const quad = text.Quad{
        .x = qx,
        .y = qy,
        .w = @floatFromInt(g.w),
        .h = @floatFromInt(g.h),
        .u0 = @as(f32, @floatFromInt(g.atlas_x)) / @as(f32, @floatFromInt(at.atlas_w)),
        .v0 = @as(f32, @floatFromInt(g.atlas_y)) / @as(f32, @floatFromInt(at.atlas_h)),
        .u1 = @as(f32, @floatFromInt(g.atlas_x + g.w)) / @as(f32, @floatFromInt(at.atlas_w)),
        .v1 = @as(f32, @floatFromInt(g.atlas_y + g.h)) / @as(f32, @floatFromInt(at.atlas_h)),
        .color = brass,
    };
    try gt.render(&vk, &dev, &.{quad});

    const px = gt.pixels();
    try std.testing.expectEqual(@as(usize, W * H * 4), px.len);
    const atPx = struct {
        fn f(p: []const u8, w: u32, x: u32, y: u32) []const u8 {
            const o = (@as(usize, y) * w + x) * 4;
            return p[o .. o + 4];
        }
    }.f;

    // Corner (outside glyph): exact void #04060B stored BGRA -> 0B 06 04 FF.
    try std.testing.expectEqualSlices(u8, &.{ 0x0B, 0x06, 0x04, 0xFF }, atPx(px, W, 0, 0));
    // Solid interior texel: exact brass #EBB545 -> BGRA bytes 45 B5 EB FF.
    const si = atPx(px, W, @as(u32, @intFromFloat(qx)) + sp[0], @as(u32, @intFromFloat(qy)) + sp[1]);
    try std.testing.expectEqualSlices(u8, &.{ 0x45, 0xB5, 0xEB, 0xFF }, si);
    // Counter hole texel: exact void again.
    const ho = atPx(px, W, @as(u32, @intFromFloat(qx)) + hp[0], @as(u32, @intFromFloat(qy)) + hp[1]);
    try std.testing.expectEqualSlices(u8, &.{ 0x0B, 0x06, 0x04, 0xFF }, ho);

    // Second frame: move the quad to the right; old spot back to void, new
    // spot brass at the solid texel.
    const qx2: f32 = 80;
    const quad2 = text.Quad{
        .x = qx2,
        .y = qy,
        .w = quad.w,
        .h = quad.h,
        .u0 = quad.u0,
        .v0 = quad.v0,
        .u1 = quad.u1,
        .v1 = quad.v1,
        .color = brass,
    };
    try gt.render(&vk, &dev, &.{quad2});
    const px2 = gt.pixels();
    try std.testing.expectEqualSlices(u8, &.{ 0x45, 0xB5, 0xEB, 0xFF }, atPx(px2, W, @as(u32, @intFromFloat(qx2)) + sp[0], @as(u32, @intFromFloat(qy)) + sp[1]));
    try std.testing.expectEqualSlices(u8, &.{ 0x0B, 0x06, 0x04, 0xFF }, atPx(px2, W, @as(u32, @intFromFloat(qx)) + sp[0], @as(u32, @intFromFloat(qy)) + sp[1]));

    std.debug.print("GPU_TEXT_OK bytes={d} solid=45B5EBFF hole/void=0B0604FF moved-frame verified\n", .{px2.len});

    // PPM dump of the second frame (BGRA -> RGB).
    var ppm: [W * H * 3]u8 = undefined;
    for (0..W * H) |i| {
        ppm[i * 3 + 0] = px2[i * 4 + 2];
        ppm[i * 3 + 1] = px2[i * 4 + 1];
        ppm[i * 3 + 2] = px2[i * 4 + 0];
    }
    var header_buf: [64]u8 = undefined;
    const header = try std.fmt.bufPrint(&header_buf, "P6\n{d} {d}\n255\n", .{ W, H });
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const file = try tmp.dir.createFile(std.testing.io, "gpu-text.ppm", .{});
    var writer_buf: [4096]u8 = undefined;
    var writer = file.writer(std.testing.io, &writer_buf);
    try writer.interface.writeAll(header);
    try writer.interface.writeAll(&ppm);
    try writer.interface.flush();
    file.close(std.testing.io);
    std.debug.print("GPU_TEXT_PPM .zig-cache/tmp/{s}/gpu-text.ppm {d}x{d}\n", .{ tmp.sub_path, W, H });
}
