//! Public re-exports of the audio module.
//! Module root at src/ level, same pattern as term_api.zig.
//!
//! `sink` is the framework audio-output module: a device-independent output
//! sink (ALSA/Pulse via dlopen, plus null and WAV-capture backends for tests).
//! Apps opt in by importing this module and calling sink.open(...); apps that
//! make no sound import nothing and link nothing.
pub const sink = @import("audio/sink.zig");
pub const wav = @import("audio/wav.zig");