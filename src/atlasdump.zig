//! Builds the glyph atlas and dumps it as a PPM evidence image.
const std = @import("std");
const font = @import("font.zig");
const atlas_mod = @import("atlas.zig");

pub fn main(init: std.process.Init) !void {
    const gpa = init.gpa;

    var args_iter = std.process.Args.Iterator.init(init.minimal.args);
    _ = args_iter.next();
    const path = args_iter.next() orelse {
        std.debug.print("usage: atlasdump <font.ttf> [out.ppm]\n", .{});
        std.process.exit(2);
    };
    const out_path: [:0]const u8 = "/tmp/opencode/atlas.ppm";

    const bytes = try std.Io.Dir.cwd().readFileAlloc(init.io, path, gpa, .limited(64 * 1024 * 1024));
    defer gpa.free(bytes);
    const parsed = try font.Font.parse(bytes);

    var atlas = atlas_mod.Atlas.init(gpa);
    try atlas.build(&parsed, gpa);

    const instances = try atlas_mod.Atlas.instancesFor(&parsed, gpa, "SIFR Cipher 0123456789", 16.0, 120.0);
    defer gpa.free(instances);

    try writePpm(&atlas.pixels, out_path);
    std.debug.print("atlasdump: wrote {s} ({d} glyphs, 10x10 grid, cell {d}px)\n", .{ out_path, instances.len, atlas_mod.CELL });
}

fn writePpm(pixels: []const u8, path_c: [:0]const u8) !void {
    const fd_rc = std.os.linux.openat(std.os.linux.AT.FDCWD, path_c, .{ .ACCMODE = .WRONLY, .CREAT = true, .TRUNC = true }, 0o644);
    if (@as(i64, @bitCast(fd_rc)) < 0) return error.OpenFailed;
    const fd: i32 = @intCast(fd_rc);
    defer _ = std.os.linux.close(fd);

    const header = "P6 480 480 255\n";
    var written: usize = 0;
    while (written < header.len) {
        const rc = std.os.linux.write(fd, header[written..].ptr, header.len - written);
        if (@as(i64, @bitCast(rc)) < 0) return error.WriteFailed;
        written += @intCast(rc);
    }

    var rgb: [3]u8 = undefined;
    for (pixels) |alpha| {
        rgb = .{ alpha, alpha, alpha };
        const rc = std.os.linux.write(fd, &rgb, 3);
        if (@as(i64, @bitCast(rc)) < 0) return error.WriteFailed;
    }
}
