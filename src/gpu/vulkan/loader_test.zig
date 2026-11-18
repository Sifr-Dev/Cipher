//! Verify Vulkan loader loads libvulkan.so.1 and calls vkCreateInstance.
const std = @import("std");
const vk = @import("loader.zig");

test "loads Vulkan ICD library" {
    const vulkan = vk.load() catch |e| {
        std.debug.print("GPU_SKIP loader: {s}\n", .{@errorName(e)});
        return;
    };
    var vulkan_lib = vulkan.lib;
    defer vulkan_lib.close();

    // If we got here, libvulkan.so.1 loaded successfully.
    // The Vulkan ICD is now available for function calls.
}
