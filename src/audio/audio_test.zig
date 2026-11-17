//! Integration tests: the FLAC decoder is verified BIT-EXACT against the
//! `flac` encoder + `ffmpeg` decoder on locally generated fixtures
//! (several bit depths, rates, channel counts, compression levels).
const std = @import("std");
const wav = @import("wav.zig");
const flac = @import("flac.zig");

fn childFail() noreturn {
    _ = std.os.linux.exit(127);
}

/// Run a CLI tool (absolute path), stdio -> /dev/null, return exit code.
fn runCli(alloc: std.mem.Allocator, argv: []const []const u8) !u8 {
    const pid_rc = std.os.linux.fork();
    if (@as(i64, @bitCast(pid_rc)) < 0) return error.ForkFailed;
    if (pid_rc == 0) {
        const devnull = std.posix.openat(std.posix.AT.FDCWD, "/dev/null", .{ .ACCMODE = .WRONLY }, 0) catch childFail();
        _ = std.os.linux.dup2(devnull, 0);
        _ = std.os.linux.dup2(devnull, 1);
        _ = std.os.linux.dup2(devnull, 2);
        var args = try alloc.allocSentinel(?[*:0]const u8, argv.len, null);
        for (argv, 0..) |a, i| {
            const b = try alloc.allocSentinel(u8, a.len, 0);
            @memcpy(b, a);
            args[i] = b.ptr;
        }
        var envp = [_]?[*:0]const u8{ try zstr(alloc, "PATH=/usr/bin:/bin"), null };
        _ = std.os.linux.execve(args[0].?, @ptrCast(args.ptr), @ptrCast(envp[0..].ptr));
        childFail();
    }
    var status: i32 = 0;
    while (true) {
        const wrc = std.os.linux.waitpid(@as(i32, @intCast(pid_rc)), &status, 0);
        if (@as(i64, @bitCast(wrc)) < 0) {
            if (std.os.linux.errno(wrc) == .INTR) continue;
            return error.WaitFailed;
        }
        break;
    }
    const st: u32 = @bitCast(status);
    if (std.os.linux.W.IFEXITED(st)) return std.os.linux.W.EXITSTATUS(st);
    return 255;
}

fn zstr(alloc: std.mem.Allocator, s: []const u8) ![*:0]u8 {
    const b = try alloc.allocSentinel(u8, s.len, 0);
    @memcpy(b, s);
    return b.ptr;
}

/// Deterministic pseudo-musical signal (sine + harmonics + noise), raw ints.
fn synth(alloc: std.mem.Allocator, frames: usize, ch: u16, bps: u16, rate: u32) ![]i64 {
    const out = try alloc.alloc(i64, frames * ch);
    const maxv: i64 = (@as(i64, 1) << @intCast(bps - 1)) - 1;
    for (out, 0..) |*s, i| {
        const t: f64 = @as(f64, @floatFromInt(i / ch)) / @as(f64, @floatFromInt(rate));
        const v = @sin(2.0 * std.math.pi * 220.0 * t) * 0.6 +
            @sin(2.0 * std.math.pi * 331.0 * t + 0.7) * 0.3 +
            @sin(2.0 * std.math.pi * 1237.0 * t) * 0.1;
        const noise: i64 = @intCast(@mod(@as(i64, @intCast(i * 2654435761)), @as(i64, 2001)) - 1000);
        s.* = @as(i64, @intFromFloat(v * @as(f64, @floatFromInt(maxv)) * 0.9)) + @divTrunc(noise, 8);
    }
    return out;
}

test "flac decoder bit-exact vs flac+ffmpeg CLI fixtures (bps/rates/channels/levels)" {
    const alloc = std.testing.allocator;
    const dir = "/tmp/opencode/flac-fixtures";
    _ = try runCli(alloc, &.{ "/usr/bin/mkdir", "-p", dir });
    const cases = [_]struct { rate: u32, ch: u16, bps: u16, level: []const u8, name: []const u8, frames: usize }{
        .{ .rate = 44100, .ch = 2, .bps = 16, .level = "-5", .name = "s16_44k_st", .frames = 22050 },
        .{ .rate = 48000, .ch = 2, .bps = 24, .level = "-8", .name = "s24_48k_st", .frames = 24000 },
        .{ .rate = 96000, .ch = 1, .bps = 16, .level = "-0", .name = "s16_96k_mono", .frames = 48000 },
        .{ .rate = 44100, .ch = 2, .bps = 24, .level = "-3", .name = "s24_44k_st", .frames = 22050 },
        .{ .rate = 8000, .ch = 1, .bps = 16, .level = "-8", .name = "s16_8k_mono", .frames = 4000 },
        .{ .rate = 44100, .ch = 2, .bps = 16, .level = "-8", .name = "s16_44k_st_l8", .frames = 44100 },
    };
    var all_ok = true;
    for (cases) |c| {
        const wav_path = try std.fmt.allocPrint(alloc, "{s}/{s}.wav", .{ dir, c.name });
        defer alloc.free(wav_path);
        const flac_path = try std.fmt.allocPrint(alloc, "{s}/{s}.flac", .{ dir, c.name });
        defer alloc.free(flac_path);
        const raw_path = try std.fmt.allocPrint(alloc, "{s}/{s}.s32", .{ dir, c.name });
        defer alloc.free(raw_path);

        const samples = try synth(alloc, c.frames, c.ch, c.bps, c.rate);
        defer alloc.free(samples);
        try wav.write(alloc, wav_path, c.rate, c.ch, c.bps, samples);

        // encode with the reference flac encoder (with vorbis tags)
        const rc1 = try runCli(alloc, &.{ "/usr/bin/flac", "-f", "-s", c.level, "--tag=TITLE=Fixture Song", "--tag=ARTIST=Tester", "--tag=LYRICS=[00:01.00]hello lyric", "-o", flac_path, wav_path });
        try std.testing.expectEqual(@as(u8, 0), rc1);

        // reference decode: ffmpeg -> s32le raw
        const rc2 = try runCli(alloc, &.{ "/usr/bin/ffmpeg", "-y", "-loglevel", "error", "-i", flac_path, "-f", "s32le", "-c:a", "pcm_s32le", raw_path });
        try std.testing.expectEqual(@as(u8, 0), rc2);
        const raw = try wav.readFileAll(alloc, raw_path, 1024 * 1024 * 1024);
        defer alloc.free(raw);
        const ref_n = raw.len / 4;

        // our decoder
        var dec = try flac.decodeFile(alloc, flac_path);
        defer dec.deinit();

        try std.testing.expectEqual(c.rate, dec.sample_rate);
        try std.testing.expectEqual(c.ch, dec.channels);
        try std.testing.expectEqual(c.bps, dec.bits_per_sample);
        try std.testing.expectEqual(@as(usize, c.frames * c.ch), dec.samples.len);
        try std.testing.expectEqual(ref_n, dec.samples.len);
        const shift: u6 = @intCast(32 - c.bps);
        var mismatches: usize = 0;
        for (dec.samples, 0..) |s, i| {
            const got: i32 = @intCast(s << shift);
            const want: i32 = @bitCast(readU32LE(raw[i * 4 ..][0..4]));
            if (got != want) mismatches += 1;
        }
        if (mismatches != 0 or !dec.md5_ok) all_ok = false;
        // vorbis comments
        const title = dec.comment("TITLE") orelse "";
        const lyrics = dec.comment("LYRICS") orelse "";
        try std.testing.expectEqualStrings("Fixture Song", title);
        try std.testing.expect(std.mem.indexOf(u8, lyrics, "hello lyric") != null);
        std.debug.print("FLAC_BITEXACT_OK name={s} rate={d} ch={d} bps={d} samples={d} mismatches={d} md5_ok={} title={s}\n", .{ c.name, c.rate, c.ch, c.bps, dec.samples.len, mismatches, dec.md5_ok, title });
    }
    try std.testing.expect(all_ok);
}

fn readU32LE(b: []const u8) u32 {
    return @as(u32, b[0]) | (@as(u32, b[1]) << 8) | (@as(u32, b[2]) << 16) | (@as(u32, b[3]) << 24);
}
