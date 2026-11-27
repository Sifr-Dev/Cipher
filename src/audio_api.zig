//! Public re-exports of the audio modules.
//! Module root at src/ level, same pattern as term_api.zig.
//!
//! `sink` is the framework audio-output module: a device-independent output
//! sink (ALSA/Pulse via dlopen, plus null and WAV-capture backends for tests).
//! The remaining modules are the legacy offline player stack, retained only
//! until Nocturne's own decode path lands; they are not part of the framework
//! surface and will be removed.
pub const sink = @import("audio/sink.zig");
pub const wav = @import("audio/wav.zig");
pub const flac = @import("audio/flac.zig");
pub const lrc = @import("audio/lrc.zig");
pub const playlist = @import("audio/playlist.zig");
pub const pulse = @import("audio/pulse.zig");
pub const player = @import("audio/player.zig");