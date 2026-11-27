//! Audio output sink — a framework module for streaming sound to the OS.
//!
//! This is not a music player. It is the minimal surface an application needs
//! to be heard: open a sink for a given sample rate, channel count and sample
//! format, then push interleaved PCM frames. Backends (ALSA on Linux, PulseAudio
//! where present) are loaded with dlopen at runtime, so a program that never
//! calls `open` does not link, load or pay for any audio library.
//!
//! Steady-state `write` is allocation-free and bounded: it hands the caller's
//! buffer straight to the backend and never grows an internal queue. Underrun
//! and a busy device are reported as errors the caller can handle; the sink
//! never aborts the process and never silently drops audio.
//!
//! Opt in at build time by importing the `audio` module and calling
//! `audio.sink.open(...)`. Apps that make no sound import nothing.
const std = @import("std");

pub const Format = enum(u8) {
    s16le = 16,
    f32le = 32,

    pub fn bytesPerSample(self: Format) usize {
        return @intCast(@intFromEnum(self) / 8);
    }

    pub fn name(self: Format) []const u8 {
        return switch (self) {
            .s16le => "s16le",
            .f32le => "f32le",
        };
    }
};

pub const Config = struct {
    rate: u32,
    channels: u8,
    format: Format = .s16le,

    /// Reject configurations no backend can honour, before any device is
    /// touched. Mono and stereo only; 8 kHz..384 kHz; s16le/f32le only.
    pub fn validate(self: Config) !void {
        if (self.channels != 1 and self.channels != 2) return error.UnsupportedChannels;
        if (self.rate < 8000 or self.rate > 384000) return error.UnsupportedRate;
        _ = self.format; // enum type already constrains the set
    }

    pub fn bytesPerFrame(self: Config) usize {
        return @as(usize, self.channels) * self.format.bytesPerSample();
    }
};

/// Errors `write` can return. All are recoverable by the caller; none abort.
pub const WriteError = error{
    /// The device queue is full right now (non-blocking backend). Retry later.
    DeviceBusy,
    /// The backend drained its buffer and needs a prepare/recover cycle.
    Underrun,
    /// The backend reported a hard write failure.
    WriteFailed,
    /// The sink was already closed.
    Closed,
};

pub const VTable = struct {
    write: *const fn (ctx: *anyopaque, pcm: []const u8) WriteError!void,
    drain: *const fn (ctx: *anyopaque) void,
    close: *const fn (ctx: *anyopaque) void,
};

/// A live output stream. One of the backends in this module owns `ctx`.
pub const Sink = struct {
    vtable: *const VTable,
    ctx: *anyopaque,
    config: Config,
    closed: bool = false,

    /// Push interleaved PCM already encoded in `config.format`. The buffer is
    /// consumed synchronously; steady-state calls allocate nothing. `pcm.len`
    /// must be a whole number of frames.
    pub fn write(self: *Sink, pcm: []const u8) WriteError!void {
        if (self.closed) return error.Closed;
        const frame = self.config.bytesPerFrame();
        if (frame == 0 or pcm.len % frame != 0) return error.WriteFailed;
        return self.vtable.write(self.ctx, pcm);
    }

    /// Block until everything written so far has reached the device.
    pub fn drain(self: *Sink) void {
        if (self.closed) return;
        self.vtable.drain(self.ctx);
    }

    /// Release the device and the sink. Idempotent.
    pub fn close(self: *Sink) void {
        if (self.closed) return;
        self.closed = true;
        self.vtable.close(self.ctx);
    }
};

/// Backends this build can attempt, in priority order.
pub const Backend = enum {
    null_sink,
    wav_capture,
    pulse,
    alsa,

    pub fn name(self: Backend) []const u8 {
        return switch (self) {
            .null_sink => "null",
            .wav_capture => "wav",
            .pulse => "pulse",
            .alsa => "alsa",
        };
    }
};

/// Probe which real backends are loadable on this host, without opening a
/// device. `null` and `wav` are always available (they are in-process).
pub fn enumerate(allocator: std.mem.Allocator) ![3]bool {
    // Returns [pulse_loadable, alsa_loadable, _reserved].
    const pulse_ok = blk: {
        const lib = std.c.dlopen("libpulse-simple.so.0", .{ .NOW = true }) orelse break :blk false;
        _ = std.c.dlclose(lib);
        break :blk true;
    };
    const alsa_ok = blk: {
        const lib = std.c.dlopen("libasound.so.2", .{ .NOW = true }) orelse break :blk false;
        _ = std.c.dlclose(lib);
        break :blk true;
    };
    _ = allocator;
    return .{ pulse_ok, alsa_ok, false };
}

/// Open the best available real backend for `config`. Tries Pulse first (it
/// also serves PipeWire), then ALSA. Returns a clear error when no backend is
/// present rather than dropping audio on the floor.
pub fn open(allocator: std.mem.Allocator, config: Config) !Sink {
    try config.validate();
    const avail = try enumerate(allocator);
    if (avail[0]) {
        if (openPulse(allocator, config)) |s| return s else |_| {}
    }
    if (avail[1]) {
        if (openAlsa(allocator, config)) |s| return s else |_| {}
    }
    return error.NoBackend;
}

/// Open a specific backend by name. Used by tests and by callers that know
/// which server they want.
pub fn openBackend(allocator: std.mem.Allocator, backend: Backend, config: Config) !Sink {
    try config.validate();
    return switch (backend) {
        .null_sink => nullSinkOpen(config),
        .wav_capture => error.WavCaptureNeedsPath,
        .pulse => openPulse(allocator, config),
        .alsa => openAlsa(allocator, config),
    };
}

const null_mod = @import("sink_null.zig");
const wav_mod = @import("sink_wav.zig");
const pulse_mod = @import("sink_pulse.zig");
const alsa_mod = @import("sink_alsa.zig");

fn nullSinkOpen(config: Config) !Sink {
    return null_mod.open(config);
}

fn openPulse(allocator: std.mem.Allocator, config: Config) !Sink {
    _ = allocator;
    return pulse_mod.open(config);
}

fn openAlsa(allocator: std.mem.Allocator, config: Config) !Sink {
    _ = allocator;
    return alsa_mod.open(config);
}

/// Open a WAV-file capture sink. Used by tests to round-trip frames to disk.
pub fn openWav(allocator: std.mem.Allocator, config: Config, path: []const u8) !Sink {
    try config.validate();
    return wav_mod.open(allocator, config, path);
}

// Re-export the backend helpers tests reach for.
pub const nullOpen = nullSinkOpen;