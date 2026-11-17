// Test shim at src/ level for the audio modules.
const std = @import("std");

test {
    _ = @import("audio/wav.zig");
    _ = @import("audio/flac.zig");
    _ = @import("audio/lrc.zig");
    _ = @import("audio/playlist.zig");
    _ = @import("audio/pulse.zig");
    _ = @import("audio/player.zig");
    _ = @import("audio/audio_test.zig");
}
