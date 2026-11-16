//! Software pixel rasterizer for the SIFR scene, sized for Cipher's
//! shared-memory surface: one u32 per pixel (0xAARRGGBB, little-endian).
const std = @import("std");
const geometry = @import("geometry.zig");

pub const WIDTH = 640;
pub const HEIGHT = 400;

pub const VOID32: u32 = 0xFF04060B;
pub const RAISED32: u32 = 0xFF171B21;
pub const LINE32: u32 = 0xFF2D3038;
pub const TEXT32: u32 = 0xFFF3F7FE;
pub const BRASS32: u32 = 0xFFEAB444;

pub fn clear(pixels: []u32, color: u32) void {
    @memset(pixels, color);
}

fn plot(pixels: []u32, x: i32, y: i32, color: u32) void {
    if (x < 0 or y < 0 or x >= WIDTH or y >= HEIGHT) return;
    pixels[@intCast(y * WIDTH + x)] = color;
}

fn fillDisc(pixels: []u32, cx: i32, cy: i32, radius: i32, color: u32) void {
    var y: i32 = -radius;
    while (y <= radius) : (y += 1) {
        var x: i32 = -radius;
        while (x <= radius) : (x += 1) {
            if (x * x + y * y <= radius * radius) plot(pixels, cx + x, cy + y, color);
        }
    }
}

fn ringBand(pixels: []u32, cx: i32, cy: i32, radius: i32, thickness: i32, color: u32) void {
    const outer = radius * radius;
    const inner = (radius - thickness) * (radius - thickness);
    var y: i32 = -radius;
    while (y <= radius) : (y += 1) {
        var x: i32 = -radius;
        while (x <= radius) : (x += 1) {
            const d = x * x + y * y;
            if (d <= outer and d >= inner) plot(pixels, cx + x, cy + y, color);
        }
    }
}

pub fn render(pixels: []u32, time: f64) void {
    clear(pixels, VOID32);

    ringBand(pixels, WIDTH / 2, HEIGHT / 2, 140, 2, LINE32);
    ringBand(pixels, WIDTH / 2, HEIGHT / 2, 96, 2, LINE32);
    ringBand(pixels, WIDTH / 2, HEIGHT / 2, 52, 2, LINE32);

    const spin = @sin(time * 0.4) * 6.0;
    var i: usize = 0;
    while (i < geometry.CELL_COUNT) : (i += 1) {
        const cell = geometry.cellCenter(i, 140.0);
        const x: i32 = @intFromFloat(@as(f64, WIDTH) / 2.0 + cell.x + spin);
        const y: i32 = @intFromFloat(@as(f64, HEIGHT) / 2.0 + cell.y);
        fillDisc(pixels, x, y, if (i == 0) 9 else 6, if (i == 0) BRASS32 else TEXT32);
    }

    fillDisc(pixels, WIDTH / 2, HEIGHT / 2, 12, BRASS32);
}

/// Dumps the frame as binary PPM for evidence, using raw syscalls only.
pub fn writePpm(pixels: []const u32, path_c: [:0]const u8) !void {
    const fd_rc = std.os.linux.openat(std.os.linux.AT.FDCWD, path_c, .{ .ACCMODE = .WRONLY, .CREAT = true, .TRUNC = true }, 0o644);
    if (@as(i64, @bitCast(fd_rc)) < 0) return error.OpenFailed;
    const fd: i32 = @intCast(fd_rc);
    defer _ = std.os.linux.close(fd);

    const header = std.fmt.comptimePrint("P6 {} {} 255\n", .{ WIDTH, HEIGHT });
    var written: usize = 0;
    while (written < header.len) {
        const rc = std.os.linux.write(fd, header[written..].ptr, header.len - written);
        if (@as(i64, @bitCast(rc)) < 0) return error.WriteFailed;
        written += @intCast(rc);
    }

    var rgb: [3]u8 = undefined;
    for (pixels) |pixel| {
        rgb[0] = @truncate(pixel >> 16);
        rgb[1] = @truncate(pixel >> 8);
        rgb[2] = @truncate(pixel);
        const rc = std.os.linux.write(fd, &rgb, 3);
        if (@as(i64, @bitCast(rc)) < 0) return error.WriteFailed;
    }
}

test "render draws the brass center and index dot" {
    var pixels: [WIDTH * HEIGHT]u32 = undefined;
    render(&pixels, 0.0);
    var count: usize = 0;
    for (pixels) |pixel| {
        if (pixel == BRASS32) count += 1;
    }
    try std.testing.expect(count > 40);
}
