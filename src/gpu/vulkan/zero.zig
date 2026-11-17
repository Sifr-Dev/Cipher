//! Zero-initialize a value's bytes (used for Vulkan/Wayland handle structs
//! whose fields are all written before use).
const std = @import("std");

pub fn zeroed(comptime T: type) T {
    var v: T = undefined;
    @memset(std.mem.asBytes(&v), 0);
    return v;
}
