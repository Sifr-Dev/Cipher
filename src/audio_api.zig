//! Public re-exports of the audio modules (offline music player stack).
//! Module root at src/ level, same pattern as term_api.zig.
pub const wav = @import("audio/wav.zig");
pub const flac = @import("audio/flac.zig");
pub const lrc = @import("audio/lrc.zig");
pub const playlist = @import("audio/playlist.zig");
pub const pulse = @import("audio/pulse.zig");
pub const player = @import("audio/player.zig");
