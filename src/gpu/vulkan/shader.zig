//! SPIR-V shaders, embedded at compile time as u32 words (4-byte aligned).
//! Sources: ui.vert/ui.frag (background dot) and text.vert/text.frag (glyph
//! quads sampling the R8 atlas). Rebuild with:
//!   glslc --target-env=vulkan1.0 -O -o ui_vert.spv ui.vert
//!   glslc --target-env=vulkan1.0 -O -o ui_frag.spv ui.frag
//!   glslc --target-env=vulkan1.0 -O -o text_vert.spv text.vert
//!   glslc --target-env=vulkan1.0 -O -o text_frag.spv text.frag
//!   spirv-val --target-env vulkan1.0 ui_vert.spv ui_frag.spv text_vert.spv text_frag.spv
const vert_bytes = @embedFile("ui_vert.spv");
const frag_bytes = @embedFile("ui_frag.spv");
const text_vert_bytes = @embedFile("text_vert.spv");
const text_frag_bytes = @embedFile("text_frag.spv");

const vert_arr: [vert_bytes.len]u8 = vert_bytes[0..vert_bytes.len].*;
const frag_arr: [frag_bytes.len]u8 = frag_bytes[0..frag_bytes.len].*;
const text_vert_arr: [text_vert_bytes.len]u8 = text_vert_bytes[0..text_vert_bytes.len].*;
const text_frag_arr: [text_frag_bytes.len]u8 = text_frag_bytes[0..text_frag_bytes.len].*;

pub const ui_vert_spv: []const u32 = &@as([vert_arr.len / 4]u32, @bitCast(vert_arr));
pub const ui_frag_spv: []const u32 = &@as([frag_arr.len / 4]u32, @bitCast(frag_arr));
pub const text_vert_spv: []const u32 = &@as([text_vert_arr.len / 4]u32, @bitCast(text_vert_arr));
pub const text_frag_spv: []const u32 = &@as([text_frag_arr.len / 4]u32, @bitCast(text_frag_arr));
