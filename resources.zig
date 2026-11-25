//! Resources compiled into each application, not read from an installed
//! framework or host font directory at runtime.
//!
//! Instrument Sans is redistributed under the SIL Open Font License. Keep the
//! license with the source package and preserve its notice in distributions.

pub const default_font = @embedFile("assets/instrument-sans.ttf");
pub const default_font_license = @embedFile("assets/instrument-sans-OFL.txt");
