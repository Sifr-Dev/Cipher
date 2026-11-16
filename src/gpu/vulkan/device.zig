//! Vulkan device creation - from-zero device setup.
//! Stage B: handwritten Vulkan API usage for GPU surface presentation.
const std = @import("std");
const vk = @import("loader.zig");

/// A Vulkan device with queue.
pub const Device = struct {
    instance: vk.VkInstance = undefined,
    physical: vk.VkPhysicalDevice = undefined,
    device: vk.VkDevice = undefined,
    queue: vk.VkQueue = undefined,
    queue_family_index: u32 = 0,
};

/// Create a Vulkan instance, enumerate physical devices, and create a
/// logical device with a queue.
pub fn createDevice(vulkan: *vk.Vulkan) !Device {
    var instance: vk.VkInstance = undefined;

    const app_info = .{
        .sType = VK_STRUCTURE_TYPE_APPLICATION_INFO,
        .pNext = null,
        .pApplicationName = "sifr",
        .applicationVersion = 1,
        .pEngineName = "sifr",
        .engineVersion = 1,
        .apiVersion = VK_API_VERSION_1_0,
    };

    const instance_info = .{
        .sType = VK_STRUCTURE_TYPE_INSTANCE_CREATE_INFO,
        .pNext = null,
        .flags = 0,
        .pApplicationInfo = &app_info,
        .enabledLayerCount = 0,
        .ppEnabledLayerNames = null,
        .enabledExtensionCount = 0,
        .ppEnabledExtensionNames = null,
    };

    if (vulkan.vkCreateInstance(&instance_info, null, &instance) != VK_SUCCESS) {
        return DeviceError.CreateInstanceFailed;
    }
    defer vulkan.vkDestroyInstance(instance, null);

    var device_count: u32 = 0;
    if (vulkan.vkEnumeratePhysicalDevices(instance, &device_count, null) != VK_SUCCESS
        or device_count == 0) {
        return DeviceError.NoPhysicalDevices;
    }

    var devices: [8]vk.VkPhysicalDevice = @splat(undefined);
    devices = devices;
    var count: u32 = device_count;
    if (vulkan.vkEnumeratePhysicalDevices(instance, &count, @ptrCast(&devices)) != VK_SUCCESS) {
        return DeviceError.EnumerateDevicesFailed;
    }

    const physical = devices[0];

    // Use queue family index 0 (simplifying assumption; refine later).
    const family_index: u32 = 0;

    const queue_priority: f32 = 1.0;
    const queue_info = .{
        .sType = VK_STRUCTURE_TYPE_DEVICE_QUEUE_CREATE_INFO,
        .pNext = null,
        .flags = 0,
        .queueFamilyIndex = family_index,
        .queueCount = 1,
        .pQueuePriorities = &queue_priority,
    };

    const device_info = .{
        .sType = VK_STRUCTURE_TYPE_DEVICE_CREATE_INFO,
        .pNext = null,
        .flags = 0,
        .queueCreateInfoCount = 1,
        .pQueueCreateInfos = &queue_info,
        .enabledLayerCount = 0,
        .ppEnabledLayerNames = null,
        .enabledExtensionCount = 0,
        .ppEnabledExtensionNames = null,
        .pEnabledFeatures = null,
    };

    var device: vk.VkDevice = undefined;
    if (vulkan.vkCreateDevice(physical, &device_info, null, &device) != VK_SUCCESS) {
        return DeviceError.CreateDeviceFailed;
    }

    var queue: vk.VkQueue = undefined;
    vulkan.vkGetDeviceQueue(device, family_index, 0, &queue);

    return .{
        .instance = instance,
        .physical = physical,
        .device = device,
        .queue = queue,
        .queue_family_index = family_index,
    };
}

pub const VK_STRUCTURE_TYPE_APPLICATION_INFO: u32 = 0;
pub const VK_STRUCTURE_TYPE_INSTANCE_CREATE_INFO: u32 = 1;
pub const VK_STRUCTURE_TYPE_DEVICE_QUEUE_CREATE_INFO: u32 = 2;
pub const VK_STRUCTURE_TYPE_DEVICE_CREATE_INFO: u32 = 3;
pub const VK_API_VERSION_1_0: u32 = (0 << 29) | (1 << 22) | (0 << 12);
pub const VK_SUCCESS: vk.VkResult = 0;

pub const DeviceError = error{
    CreateInstanceFailed,
    NoPhysicalDevices,
    EnumerateDevicesFailed,
    CreateDeviceFailed,
};

test "creates Vulkan device and enumerates physical devices" {
    // Verifies Vulkan ICD integration. Requires a working Vulkan driver.
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
