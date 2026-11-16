//! Verify Vulkan device creation works on live hardware via dlopen'd
//! libvulkan.so.1 using std.c.dlopen/dlsym.
const std = @import("std");
const vulkan_device = @import("device.zig");

test "creates Vulkan device and enumerates physical devices" {
    // Verifies Vulkan ICD integration. Requires a working Vulkan driver.
    var vulkan = try vulkan_device.load();
    defer _ = std.c.dlclose(vulkan.handle);

    var device: vulkan_device.Device = undefined;
    try vulkan_device.createDevice(&vulkan, &device);
    defer vulkan.vkDestroyDevice(device.device, null);
    defer vulkan.vkDestroyInstance(device.instance, null);

    try std.testing.expect(device.queue_family_index == 0);

    std.debug.print("Vulkan device created: queue_family={d}\n", .{device.queue_family_index});
}
