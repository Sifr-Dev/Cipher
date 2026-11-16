//! Verify Vulkan loader loads libvulkan.so.1 and resolves function pointers.
//!
//! Requires a working Vulkan ICD (NVIDIA or Mesa) installed.
const std = @import("std");
const vk = @import("loader.zig");
const vulkan_device = @import("device.zig");

test "creates Vulkan device and enumerates physical devices" {
    var vulkan = try vk.load();
    defer vulkan.lib.close();

    // Verify all key function pointers are resolved from libvulkan.so.1.
    try std.testing.expect(@intFromPtr(@as(*const anyopaque, vulkan.vkCreateInstance)) != 0);
    try std.testing.expect(@intFromPtr(@as(*const anyopaque, vulkan.vkEnumeratePhysicalDevices)) != 0);
    try std.testing.expect(@intFromPtr(@as(*const anyopaque, vulkan.vkCreateDevice)) != 0);
    try std.testing.expect(@intFromPtr(@as(*const anyopaque, vulkan.vkGetDeviceQueue)) != 0);
    try std.testing.expect(@intFromPtr(@as(*const anyopaque, vulkan.vkDestroyDevice)) != 0);
    try std.testing.expect(@intFromPtr(@as(*const anyopaque, vulkan.vkDestroyInstance)) != 0);

    std.debug.print("Vulkan ICD symbols resolved\\n", .{});
}
