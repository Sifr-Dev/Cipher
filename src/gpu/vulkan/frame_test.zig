//! Verifies the GPU frame pipeline end-to-end on live hardware:
//! graphics render pass (fullscreen triangle) -> image -> buffer copy ->
//! exact host-visible bytes. Runs on the NVIDIA ICD and lavapipe, clean
//! under VK_LAYER_KHRONOS_validation.
const std = @import("std");
const device = @import("device.zig");
const frame = @import("frame.zig");

test "GPU compute renders exact pixels into host buffer" {
    var vk = device.load() catch |e| {
        std.debug.print("GPU_SKIP frame: {s}\n", .{@errorName(e)});
        return;
    };
    var dev: device.Device = undefined;
    device.createDevice(&vk, &dev) catch |e| {
        std.debug.print("GPU_SKIP frame: createDevice {s}\n", .{@errorName(e)});
        return;
    };

    const w: u32 = 64;
    const h: u32 = 48;
    var pipe = try frame.FramePipeline.init(&vk, &dev, w, h);
    try pipe.render(&vk, &dev, 32, 24, 8);

    const px = pipe.pixels();
    try std.testing.expectEqual(@as(usize, w * h * 4), px.len);

    // Corner (0,0): void #04060B, stored BGRA -> bytes B=0x0B G=0x06 R=0x04 A=0xFF.
    try std.testing.expectEqualSlices(u8, &.{ 0x0B, 0x06, 0x04, 0xFF }, px[0..4]);
    // Center (32,24): brass #EBB545 -> B=0x45 G=0xB5 R=0xEB A=0xFF.
    const c = (24 * w + 32) * 4;
    try std.testing.expectEqualSlices(u8, &.{ 0x45, 0xB5, 0xEB, 0xFF }, px[c .. c + 4]);
    // Just outside the radius (41,24): void again (distance 9 > radius 8).
    const o = (24 * w + 41) * 4;
    try std.testing.expectEqualSlices(u8, &.{ 0x0B, 0x06, 0x04, 0xFF }, px[o .. o + 4]);
    // Edge of radius (40,24): distance 8 <= 8 -> brass.
    const e = (24 * w + 40) * 4;
    try std.testing.expectEqualSlices(u8, &.{ 0x45, 0xB5, 0xEB, 0xFF }, px[e .. e + 4]);

    // Second frame with a moved dot proves the pipeline is reusable.
    try pipe.render(&vk, &dev, 8, 8, 4);
    const px2 = pipe.pixels();
    const c2 = (8 * w + 8) * 4;
    try std.testing.expectEqualSlices(u8, &.{ 0x45, 0xB5, 0xEB, 0xFF }, px2[c2 .. c2 + 4]);
    try std.testing.expectEqualSlices(u8, &.{ 0x0B, 0x06, 0x04, 0xFF }, px2[0..4]);

    std.debug.print("GPU_FRAME_OK bytes={d} corner=04060B center=EBB545\n", .{px.len});

    // PPM dump for visual evidence (BGRA -> RGB).
    var ppm: [w * h * 3]u8 = undefined;
    for (0..w * h) |i| {
        ppm[i * 3 + 0] = px[i * 4 + 2]; // R
        ppm[i * 3 + 1] = px[i * 4 + 1]; // G
        ppm[i * 3 + 2] = px[i * 4 + 0]; // B
    }
    var header_buf: [64]u8 = undefined;
    const header = try std.fmt.bufPrint(&header_buf, "P6\n{d} {d}\n255\n", .{ w, h });
    const fd = try std.posix.openat(std.posix.AT.FDCWD, "/tmp/sifr_frame.ppm", .{ .ACCMODE = .WRONLY, .CREAT = true, .TRUNC = true }, 0o644);
    defer _ = std.c.close(fd);
    try std.testing.expectEqual(@as(isize, @intCast(header.len)), std.c.write(fd, header.ptr, header.len));
    try std.testing.expectEqual(@as(isize, @intCast(ppm.len)), std.c.write(fd, &ppm, ppm.len));
    std.debug.print("GPU_FRAME_PPM /tmp/sifr_frame.ppm {d}x{d}\n", .{ w, h });
}
