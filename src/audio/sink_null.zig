//! Null sink — a deterministic, device-free backend for tests.
//!
//! Accepts frames in any validated config, counts them, and discards the
//! bytes. Steady-state write allocates nothing. Used to exercise the Sink
//! contract and to prove the framework's audio path without a sound card.
const std = @import("std");
const sink = @import("sink.zig");

const NullCtx = struct {
    frames_written: u64 = 0,
    drained: bool = false,
    closed: bool = false,
};

var g_ctx: NullCtx = .{};

fn writeFn(ctx: *anyopaque, pcm: []const u8) sink.WriteError!void {
    const self: *NullCtx = @ptrCast(@alignCast(ctx));
    if (self.closed) return error.Closed;
    // Caller already validated whole-frame length in Sink.write.
    _ = pcm;
    self.frames_written += 1;
}

fn drainFn(ctx: *anyopaque) void {
    const self: *NullCtx = @ptrCast(@alignCast(ctx));
    self.drained = true;
}

fn closeFn(ctx: *anyopaque) void {
    const self: *NullCtx = @ptrCast(@alignCast(ctx));
    self.closed = true;
}

const vtable = sink.VTable{
    .write = &writeFn,
    .drain = &drainFn,
    .close = &closeFn,
};

pub fn open(config: sink.Config) !sink.Sink {
    g_ctx = .{};
    return .{ .vtable = &vtable, .ctx = &g_ctx, .config = config };
}

/// Test accessor: how many write() calls the null sink accepted.
pub fn framesWritten() u64 {
    return g_ctx.frames_written;
}

test "null sink accepts frames and counts writes" {
    var s = try open(.{ .rate = 48000, .channels = 2, .format = .s16le });
    defer s.close();
    const frame_bytes = s.config.bytesPerFrame();
    var buf: [4 * 4]u8 = undefined;
    @memset(&buf, 0);
    try s.write(buf[0..frame_bytes]);
    try s.write(buf[0 .. 2 * frame_bytes]);
    s.drain();
    try std.testing.expectEqual(@as(u64, 2), framesWritten());
    std.debug.print("SINK_NULL_OK\n", .{});
}