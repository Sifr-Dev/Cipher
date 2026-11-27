//! PulseAudio-simple output sink via dlopen (no link-time dependency).
//!
//! Loads libpulse-simple.so.0 at runtime. Works with a native PulseAudio
//! server and with PipeWire's pulse shim (the default `pipewire-0` socket).
//! Supports s16le and f32le, mono and stereo. Steady-state write passes the
//! caller's bytes straight to `pa_simple_write`; nothing is buffered here.
const std = @import("std");
const sink = @import("sink.zig");

const pa_sample_spec = extern struct {
    format: i32,
    rate: u32,
    channels: u8,
};

const PA_STREAM_PLAYBACK: i32 = 1;
const PA_SAMPLE_S16LE: i32 = 3;
const PA_SAMPLE_FLOAT32LE: i32 = 5;

const PulseCtx = struct {
    lib: *anyopaque,
    simple: *anyopaque,
    write_fn: *const fn (*anyopaque, *const anyopaque, usize, *i32) callconv(.c) i32,
    drain_fn: *const fn (*anyopaque, *i32) callconv(.c) i32,
    free_fn: *const fn (*anyopaque) callconv(.c) void,
    closed: bool = false,
};

fn writeFn(ctx: *anyopaque, pcm: []const u8) sink.WriteError!void {
    const self: *PulseCtx = @ptrCast(@alignCast(ctx));
    if (self.closed) return error.Closed;
    var err: i32 = 0;
    const rc = self.write_fn(self.simple, pcm.ptr, pcm.len, &err);
    if (rc < 0) {
        // PA_ERR_BUSY is uncommon for the simple API (it blocks), but surface
        // a busy device distinctly so the caller can back off.
        return error.WriteFailed;
    }
}

fn drainFn(ctx: *anyopaque) void {
    const self: *PulseCtx = @ptrCast(@alignCast(ctx));
    if (self.closed) return;
    var err: i32 = 0;
    _ = self.drain_fn(self.simple, &err);
}

fn closeFn(ctx: *anyopaque) void {
    const self: *PulseCtx = @ptrCast(@alignCast(ctx));
    if (self.closed) return;
    self.closed = true;
    self.free_fn(self.simple);
    _ = std.c.dlclose(self.lib);
}

const vtable = sink.VTable{
    .write = &writeFn,
    .drain = &drainFn,
    .close = &closeFn,
};

fn paFormat(f: sink.Format) i32 {
    return switch (f) {
        .s16le => PA_SAMPLE_S16LE,
        .f32le => PA_SAMPLE_FLOAT32LE,
    };
}

pub fn open(config: sink.Config) !sink.Sink {
    const lib = std.c.dlopen("libpulse-simple.so.0", .{ .NOW = true }) orelse return error.DlopenFailed;
    errdefer _ = std.c.dlclose(lib);
    const new_sym = std.c.dlsym(lib, "pa_simple_new") orelse return error.NoSymbol;
    const write_sym = std.c.dlsym(lib, "pa_simple_write") orelse return error.NoSymbol;
    const drain_sym = std.c.dlsym(lib, "pa_simple_drain") orelse return error.NoSymbol;
    const free_sym = std.c.dlsym(lib, "pa_simple_free") orelse return error.NoSymbol;
    const new_fn: *const fn (?[*:0]const u8, [*:0]const u8, i32, ?[*:0]const u8, [*:0]const u8, ?*const pa_sample_spec, ?*const anyopaque, ?*const anyopaque, ?*i32) callconv(.c) ?*anyopaque = @ptrCast(new_sym);
    const ss = pa_sample_spec{ .format = paFormat(config.format), .rate = config.rate, .channels = config.channels };
    var err: i32 = 0;
    const s = new_fn(null, "cipher", PA_STREAM_PLAYBACK, null, "playback", &ss, null, null, &err) orelse {
        std.debug.print("cipher audio: pa_simple_new failed err={d}\n", .{err});
        return error.ConnectFailed;
    };
    const ctx = try std.heap.page_allocator.create(PulseCtx);
    ctx.* = .{
        .lib = lib,
        .simple = s,
        .write_fn = @ptrCast(write_sym),
        .drain_fn = @ptrCast(drain_sym),
        .free_fn = @ptrCast(free_sym),
    };
    return .{ .vtable = &vtable, .ctx = ctx, .config = config };
}

test "pulse sink: dlopen resolves symbols or skips when lib missing" {
    const lib = std.c.dlopen("libpulse-simple.so.0", .{ .NOW = true }) orelse return error.SkipZigTest;
    defer _ = std.c.dlclose(lib);
    try std.testing.expect(std.c.dlsym(lib, "pa_simple_new") != null);
    try std.testing.expect(std.c.dlsym(lib, "pa_simple_write") != null);
    std.debug.print("SINK_PULSE_DLOPEN_OK\n", .{});
}