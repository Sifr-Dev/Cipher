//! Verify Vulkan device creation works on live hardware via dlopen'd
//! libvulkan.so.1 using std.c.dlopen/dlsym.
const std = @import("std");
const vulkan_device = @import("device.zig");

test "creates Vulkan device and enumerates physical devices" {
    // Verifies Vulkan ICD integration. Requires a working Vulkan driver.
    var vulkan = try vulkan_device.load();
    // Don't dlclose or explicitly destroy: process exit handles cleanup,
    // and explicit destruction can crash in the NVIDIA ICD teardown path.
    // All Vulkan creation calls are verified to return VK_SUCCESS.

    var device: vulkan_device.Device = undefined;
    try vulkan_device.createDevice(&vulkan, &device);

    try std.testing.expect(device.queue_family_index == 0);

    std.debug.print("Vulkan device created: queue_family={d}\n", .{device.queue_family_index});
}
