//! SPIR-V shaders, embedded at compile time as u32 words (4-byte aligned).
//! Sources: ui.vert / ui.frag (GLSL 450). Rebuild with:
//!   glslc -fshader-stage=vertex   --target-env=vulkan1.3 -O -o ui_vert.spv ui.vert
//!   glslc -fshader-stage=fragment --target-env=vulkan1.3 -O -o ui_frag.spv ui.frag
//!   spirv-val --target-env vulkan1.3 ui_vert.spv ui_frag.spv
const vert_bytes = @embedFile("ui_vert.spv");
const frag_bytes = @embedFile("ui_frag.spv");

const vert_arr: [vert_bytes.len]u8 = vert_bytes[0..vert_bytes.len].*;
const frag_arr: [frag_bytes.len]u8 = frag_bytes[0..frag_bytes.len].*;

pub const ui_vert_spv: []const u32 = &@as([vert_arr.len / 4]u32, @bitCast(vert_arr));
pub const ui_frag_spv: []const u32 = &@as([frag_arr.len / 4]u32, @bitCast(frag_arr));
