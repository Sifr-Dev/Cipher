//! WAV-file capture sink — writes interleaved PCM to a RIFF/WAVE file.
//!
//! Used by tests to round-trip frames through the real Sink contract and
//! verify the bytes that would have reached the device. The 44-byte header is
//! patched with the final data length on close, so the file is always valid.
const std = @import("std");
const sink = @import("sink.zig");

const WavCtx = struct {
    fd: std.posix.fd_t,
    data_bytes: u64 = 0,
    closed: bool = false,
};

fn writeAllFd(fd: std.posix.fd_t, data: []const u8) !void {
    var off: usize = 0;
    while (off < data.len) {
        const rc = std.os.linux.write(fd, data[off..].ptr, data.len - off);
        if (@as(i64, @bitCast(rc)) < 0) return error.WriteFailed;
        off += @intCast(rc);
    }
}

fn writeFn(ctx: *anyopaque, pcm: []const u8) sink.WriteError!void {
    const self: *WavCtx = @ptrCast(@alignCast(ctx));
    if (self.closed) return error.Closed;
    writeAllFd(self.fd, pcm) catch return error.WriteFailed;
    self.data_bytes += pcm.len;
}

fn drainFn(ctx: *anyopaque) void {
    _ = ctx; // file writes are synchronous; nothing to drain
}

fn closeFn(ctx: *anyopaque) void {
    const self: *WavCtx = @ptrCast(@alignCast(ctx));
    if (self.closed) return;
    self.closed = true;
    // Patch RIFF chunk size and data chunk size with the real lengths.
    patchU32(self.fd, 4, @intCast(36 + self.data_bytes));
    patchU32(self.fd, 40, @intCast(self.data_bytes));
    _ = std.c.close(self.fd);
}

fn patchU32(fd: std.posix.fd_t, offset: u64, v: u32) void {
    const b = [4]u8{
        @truncate(v),
        @truncate(v >> 8),
        @truncate(v >> 16),
        @truncate(v >> 24),
    };
    _ = std.os.linux.pwrite(fd, &b, b.len, @bitCast(offset));
}

const vtable = sink.VTable{
    .write = &writeFn,
    .drain = &drainFn,
    .close = &closeFn,
};

fn writeU32LE(dst: []u8, v: u32) void {
    dst[0] = @truncate(v);
    dst[1] = @truncate(v >> 8);
    dst[2] = @truncate(v >> 16);
    dst[3] = @truncate(v >> 24);
}
fn writeU16LE(dst: []u8, v: u16) void {
    dst[0] = @truncate(v);
    dst[1] = @truncate(v >> 8);
}

pub fn open(allocator: std.mem.Allocator, config: sink.Config, path: []const u8) !sink.Sink {
    _ = allocator;
    const fd = try std.posix.openat(std.posix.AT.FDCWD, path, .{ .ACCMODE = .RDWR, .CREAT = true, .TRUNC = true }, 0o644);
    errdefer _ = std.c.close(fd);
    // Placeholder header; sizes patched on close.
    var hdr: [44]u8 = undefined;
    @memset(&hdr, 0);
    @memcpy(hdr[0..4], "RIFF");
    writeU32LE(hdr[4..8], 36);
    @memcpy(hdr[8..12], "WAVE");
    @memcpy(hdr[12..16], "fmt ");
    writeU32LE(hdr[16..20], 16);
    writeU16LE(hdr[20..22], 1); // PCM
    writeU16LE(hdr[22..24], config.channels);
    writeU32LE(hdr[24..28], config.rate);
    const block_align: u16 = config.channels * @as(u16, @intCast(config.format.bytesPerSample()));
    writeU32LE(hdr[28..32], config.rate * @as(u32, block_align));
    writeU16LE(hdr[32..34], block_align);
    writeU16LE(hdr[34..36], @intCast(@intFromEnum(config.format)));
    @memcpy(hdr[36..40], "data");
    writeU32LE(hdr[40..44], 0);
    try writeAllFd(fd, &hdr);
    const ctx = try std.heap.page_allocator.create(WavCtx);
    ctx.* = .{ .fd = fd };
    return .{ .vtable = &vtable, .ctx = ctx, .config = config };
}