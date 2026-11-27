// Test shim at src/ level for the audio sink module.
const std = @import("std");

test {
    _ = @import("audio/sink.zig");
    _ = @import("audio/sink_null.zig");
    _ = @import("audio/sink_wav.zig");
    _ = @import("audio/sink_pulse.zig");
    _ = @import("audio/sink_alsa.zig");
    _ = @import("audio/wav.zig");
    _ = @import("audio/sink_test.zig");
}