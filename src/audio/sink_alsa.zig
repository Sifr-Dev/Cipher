//! ALSA output sink via dlopen (no link-time dependency).
//!
//! Loads libasound.so.2 at runtime and drives the "default" PCM device through
//! the simple `snd_pcm_set_params` API, which negotiates hardware parameters in
//! one call. Supports s16le and f32le, mono and stereo. Steady-state write
//! passes the caller's bytes to `snd_pcm_writei` with no internal buffering.
//!
//! Underrun (EPIPE) is recovered with `snd_pcm_recover` and the write is
//! retried once; a busy device (EBUSY) surfaces as `error.DeviceBusy` so the
//! caller can back off. The sink never aborts the process.
const std = @import("std");
const sink = @import("sink.zig");

const SND_PCM_STREAM_PLAYBACK: i32 = 0;
const SND_PCM_ACCESS_RW_INTERLEAVED: i32 = 3;
const SND_PCM_FORMAT_S16_LE: i32 = 2;
const SND_PCM_FORMAT_FLOAT_LE: i32 = 14;

// errno values ALSA reports through snd_pcm_writei's negative return.
const EPIPE: i32 = 32;
const ESTRPIPE: i32 = 86;
const EBUSY: i32 = 16;
const EAGAIN: i32 = 11;

const AlsaCtx = struct {
    lib: *anyopaque,
    pcm: *anyopaque,
    writei_fn: *const fn (*anyopaque, *const anyopaque, u32) callconv(.c) i64,
    recover_fn: *const fn (*anyopaque, i32, i32) callconv(.c) i32,
    drain_fn: *const fn (*anyopaque) callconv(.c) i32,
    close_fn: *const fn (*anyopaque) callconv(.c) i32,
    frame_size: usize,
    closed: bool = false,
};

fn writeFn(ctx: *anyopaque, pcm: []const u8) sink.WriteError!void {
    const self: *AlsaCtx = @ptrCast(@alignCast(ctx));
    if (self.closed) return error.Closed;
    // The Sink already validated the byte length is a whole number of frames.
    const frames: u32 = @intCast(pcm.len / self.frame_size);
    var rc = self.writei_fn(self.pcm, pcm.ptr, frames);
    if (rc < 0) {
        const err: i32 = @intCast(rc);
        if (err == -EPIPE or err == -ESTRPIPE) {
            // Underrun: prepare and retry the same buffer once.
            if (self.recover_fn(self.pcm, err, 1) == 0) {
                rc = self.writei_fn(self.pcm, pcm.ptr, frames);
            }
        }
        if (rc < 0) {
            const e: i32 = @intCast(rc);
            if (e == -EBUSY or e == -EAGAIN) return error.DeviceBusy;
            return error.Underrun;
        }
    }
}

fn drainFn(ctx: *anyopaque) void {
    const self: *AlsaCtx = @ptrCast(@alignCast(ctx));
    if (self.closed) return;
    _ = self.drain_fn(self.pcm);
}

fn closeFn(ctx: *anyopaque) void {
    const self: *AlsaCtx = @ptrCast(@alignCast(ctx));
    if (self.closed) return;
    self.closed = true;
    _ = self.close_fn(self.pcm);
    _ = std.c.dlclose(self.lib);
}

const vtable = sink.VTable{
    .write = &writeFn,
    .drain = &drainFn,
    .close = &closeFn,
};

fn alsaFormat(f: sink.Format) i32 {
    return switch (f) {
        .s16le => SND_PCM_FORMAT_S16_LE,
        .f32le => SND_PCM_FORMAT_FLOAT_LE,
    };
}

pub fn open(config: sink.Config) !sink.Sink {
    const lib = std.c.dlopen("libasound.so.2", .{ .NOW = true }) orelse return error.DlopenFailed;
    errdefer _ = std.c.dlclose(lib);
    const open_sym = std.c.dlsym(lib, "snd_pcm_open") orelse return error.NoSymbol;
    const setparams_sym = std.c.dlsym(lib, "snd_pcm_set_params") orelse return error.NoSymbol;
    const writei_sym = std.c.dlsym(lib, "snd_pcm_writei") orelse return error.NoSymbol;
    const recover_sym = std.c.dlsym(lib, "snd_pcm_recover") orelse return error.NoSymbol;
    const drain_sym = std.c.dlsym(lib, "snd_pcm_drain") orelse return error.NoSymbol;
    const close_sym = std.c.dlsym(lib, "snd_pcm_close") orelse return error.NoSymbol;

    const open_fn: *const fn (*?*anyopaque, [*:0]const u8, i32, i32) callconv(.c) i32 = @ptrCast(open_sym);
    const setparams_fn: *const fn (*anyopaque, i32, i32, u32, u32, i32, u32) callconv(.c) i32 = @ptrCast(setparams_sym);

    var pcm: ?*anyopaque = null;
    const rc = open_fn(&pcm, "default", SND_PCM_STREAM_PLAYBACK, 0);
    if (rc < 0 or pcm == null) {
        std.debug.print("cipher audio: snd_pcm_open failed rc={d}\n", .{rc});
        return error.ConnectFailed;
    }
    const cfn: *const fn (*anyopaque) callconv(.c) i32 = @ptrCast(close_sym);
    errdefer _ = cfn(pcm.?);

    const sp = setparams_fn(pcm.?, alsaFormat(config.format), SND_PCM_ACCESS_RW_INTERLEAVED, config.channels, config.rate, 0, 100000);
    if (sp < 0) {
        std.debug.print("cipher audio: snd_pcm_set_params failed rc={d}\n", .{sp});
        return error.UnsupportedConfig;
    }

    const ctx = try std.heap.page_allocator.create(AlsaCtx);
    ctx.* = .{
        .lib = lib,
        .pcm = pcm.?,
        .writei_fn = @ptrCast(writei_sym),
        .recover_fn = @ptrCast(recover_sym),
        .drain_fn = @ptrCast(drain_sym),
        .close_fn = @ptrCast(close_sym),
        .frame_size = config.bytesPerFrame(),
    };
    return .{ .vtable = &vtable, .ctx = ctx, .config = config };
}

test "alsa sink: dlopen resolves symbols or skips when lib missing" {
    const lib = std.c.dlopen("libasound.so.2", .{ .NOW = true }) orelse return error.SkipZigTest;
    defer _ = std.c.dlclose(lib);
    try std.testing.expect(std.c.dlsym(lib, "snd_pcm_open") != null);
    try std.testing.expect(std.c.dlsym(lib, "snd_pcm_writei") != null);
    std.debug.print("SINK_ALSA_DLOPEN_OK\n", .{});
}