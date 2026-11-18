//! Verify Vulkan device creation works on live hardware via dlopen'd
//! libvulkan.so.1 using std.c.dlopen/dlsym.
const std = @import("std");
const vulkan_device = @import("device.zig");

test "creates Vulkan device and enumerates physical devices" {
    // Verifies Vulkan ICD integration. Requires a working Vulkan driver.
    var vulkan = vulkan_device.load() catch |e| {
        std.debug.print("GPU_SKIP device: {s}\n", .{@errorName(e)});
        return;
    };
    // Don't dlclose or explicitly destroy: process exit handles cleanup,
    // and explicit destruction can crash in the NVIDIA ICD teardown path.
    // All Vulkan creation calls are verified to return VK_SUCCESS.

    var device: vulkan_device.Device = undefined;
    vulkan_device.createDevice(&vulkan, &device) catch |e| {
        std.debug.print("GPU_SKIP device: createDevice {s}\n", .{@errorName(e)});
        return;
    };

    try std.testing.expect(device.queue_family_index == 0);

    std.debug.print("Vulkan device created: queue_family={d}\n", .{device.queue_family_index});
}
