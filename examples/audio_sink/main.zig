//! audio-sink example — the smallest program that makes sound with Cipher.
//!
//! It opens a 440 Hz sine through the best available backend (Pulse/PipeWire
//! or ALSA), writes a short tone, drains, and closes. If no audio server is
//! present it prints a clear message and exits 0 — it never drops audio
//! silently and never aborts.
//!
//! This example is opt-in: build it with `zig build run-audio-sink`. The
//! default `zig build` does not compile or link it, so apps that make no
//! sound pay nothing.
const std = @import("std");
const audio = @import("audio");

pub fn main(init: std.process.Init.Minimal) !void {
    _ = init;
    const config = audio.sink.Config{ .rate = 48000, .channels = 2, .format = .s16le };
    var s = audio.sink.open(std.heap.page_allocator, config) catch |e| {
        std.debug.print("audio-sink: no audio backend available ({s}); nothing played\n", .{@errorName(e)});
        return;
    };
    defer s.close();

    // One second of a 440 Hz sine, interleaved s16le stereo, generated on the
    // stack in fixed-size blocks — no per-write allocation.
    const frames_per_block = 512;
    const frame_bytes = config.bytesPerFrame();
    var block: [frames_per_block * 4]u8 = undefined;
    var phase: f64 = 0;
    const two_pi = 2.0 * std.math.pi;
    const step = two_pi * 440.0 / @as(f64, config.rate);
    var written: u64 = 0;
    const total_frames: u64 = config.rate;
    while (written < total_frames) {
        const n: usize = @min(frames_per_block, total_frames - written);
        for (0..n) |i| {
            const v: i16 = @intFromFloat(@sin(phase) * 8000.0);
            const b = std.mem.asBytes(&v);
            @memcpy(block[i * frame_bytes ..][0..2], b);
            @memcpy(block[i * frame_bytes + 2 ..][0..2], b);
            phase += step;
        }
        try s.write(block[0 .. n * frame_bytes]);
        written += n;
    }
    s.drain();
    std.debug.print("audio-sink: played {d} frames of 440 Hz tone\n", .{written});
}