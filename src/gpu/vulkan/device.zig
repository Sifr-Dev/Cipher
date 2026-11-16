//! Vulkan device creation — dlopen-based libvulkan.so.1 binding.
//! Stage B: handwritten Vulkan API usage for GPU surface presentation.
const std = @import("std");

pub const VkResult = i32;
pub const VK_SUCCESS: VkResult = 0;
pub const VkInstance = *anyopaque;
pub const VkPhysicalDevice = *anyopaque;
pub const VkDevice = *anyopaque;
pub const VkQueue = *anyopaque;

pub const VkApplicationInfo = extern struct {
    sType: u32,
    pNext: ?*const anyopaque,
    pApplicationName: *const u8,
    applicationVersion: u32,
    pEngineName: *const u8,
    engineVersion: u32,
    apiVersion: u32,
};

pub const VkInstanceCreateInfo = extern struct {
    sType: u32,
    pNext: ?*const anyopaque,
    flags: u32,
    pApplicationInfo: ?*const VkApplicationInfo,
    enabledLayerCount: u32,
    ppEnabledLayerNames: ?**const u8,
    enabledExtensionCount: u32,
    ppEnabledExtensionNames: ?**const u8,
};

pub const VkDeviceQueueCreateInfo = extern struct {
    sType: u32,
    pNext: ?*const anyopaque,
    flags: u32,
    queueFamilyIndex: u32,
    queueCount: u32,
    pQueuePriorities: *const f32,
};

pub const VkDeviceCreateInfo = extern struct {
    sType: u32,
    pNext: ?*const anyopaque,
    flags: u32,
    queueCreateInfoCount: u32,
    pQueueCreateInfos: ?*const VkDeviceQueueCreateInfo,
    enabledLayerCount: u32,
    ppEnabledLayerNames: ?**const u8,
    enabledExtensionCount: u32,
    ppEnabledExtensionNames: ?**const u8,
    pEnabledFeatures: ?*const anyopaque,
};

pub const VK_STRUCTURE_TYPE_APPLICATION_INFO: u32 = 0;
pub const VK_STRUCTURE_TYPE_INSTANCE_CREATE_INFO: u32 = 1;
pub const VK_STRUCTURE_TYPE_DEVICE_QUEUE_CREATE_INFO: u32 = 2;
pub const VK_STRUCTURE_TYPE_DEVICE_CREATE_INFO: u32 = 3;
pub const VK_API_VERSION_1_0: u32 = (0 << 29) | (1 << 22) | (0 << 12);

/// A Vulkan device with queue.
pub const Device = struct {
    instance: VkInstance = undefined,
    physical: VkPhysicalDevice = undefined,
    device: VkDevice = undefined,
    queue: VkQueue = undefined,
    queue_family_index: u32 = 0,
};

/// Vulkan function table resolved via std.c.dlopen/dlsym.
pub const Vulkan = struct {
    handle: *anyopaque,

    vkCreateInstance: *const fn (*const VkInstanceCreateInfo, ?*const anyopaque, *VkInstance) callconv(.c) VkResult,
    vkEnumeratePhysicalDevices: *const fn (VkInstance, *u32, ?[*]VkPhysicalDevice) callconv(.c) VkResult,
    vkGetPhysicalDeviceQueueFamilyProperties: *const fn (VkPhysicalDevice, *u32, ?*const anyopaque) callconv(.c) void,
    vkCreateDevice: *const fn (VkPhysicalDevice, *const VkDeviceCreateInfo, ?*const anyopaque, *VkDevice) callconv(.c) VkResult,
    vkGetDeviceQueue: *const fn (VkDevice, u32, u32, *VkQueue) callconv(.c) void,
    vkDestroyDevice: *const fn (VkDevice, ?*const anyopaque) callconv(.c) void,
    vkDestroyInstance: *const fn (VkInstance, ?*const anyopaque) callconv(.c) void,
};

pub fn load() !Vulkan {
    const handle = std.c.dlopen("/usr/lib/libvulkan.so.1", .{ .LAZY = true }) orelse return error.DlOpenFailed;

    const create_instance = std.c.dlsym(handle, "vkCreateInstance") orelse return error.DlsymFailed;
    const enumerate_physical_devices = std.c.dlsym(handle, "vkEnumeratePhysicalDevices") orelse return error.DlsymFailed;
    const get_physical_device_queue_family_properties = std.c.dlsym(handle, "vkGetPhysicalDeviceQueueFamilyProperties") orelse return error.DlsymFailed;
    const create_device = std.c.dlsym(handle, "vkCreateDevice") orelse return error.DlsymFailed;
    const get_device_queue = std.c.dlsym(handle, "vkGetDeviceQueue") orelse return error.DlsymFailed;
    const destroy_device = std.c.dlsym(handle, "vkDestroyDevice") orelse return error.DlsymFailed;
    const destroy_instance = std.c.dlsym(handle, "vkDestroyInstance") orelse return error.DlsymFailed;

    return .{
        .handle = handle,
        .vkCreateInstance = @ptrCast(create_instance),
        .vkEnumeratePhysicalDevices = @ptrCast(enumerate_physical_devices),
        .vkGetPhysicalDeviceQueueFamilyProperties = @ptrCast(get_physical_device_queue_family_properties),
        .vkCreateDevice = @ptrCast(create_device),
        .vkGetDeviceQueue = @ptrCast(get_device_queue),
        .vkDestroyDevice = @ptrCast(destroy_device),
        .vkDestroyInstance = @ptrCast(destroy_instance),
    };
}

/// Create a Vulkan instance, enumerate physical devices, and create a
/// logical device with a queue. The caller owns the returned Device and
/// must call vkDestroyDevice and vkDestroyInstance when done.
pub fn createDevice(vulkan: *Vulkan, out: *Device) !void {
    var instance: VkInstance = undefined;

    const app_info = VkApplicationInfo{
        .sType = VK_STRUCTURE_TYPE_APPLICATION_INFO,
        .pNext = null,
        .pApplicationName = &"sifr"[0],
        .applicationVersion = 1,
        .pEngineName = &"sifr"[0],
        .engineVersion = 1,
        .apiVersion = VK_API_VERSION_1_0,
    };

    const instance_info = VkInstanceCreateInfo{
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

    var device_count: u32 = 0;
    if (vulkan.vkEnumeratePhysicalDevices(instance, &device_count, null) != VK_SUCCESS
        or device_count == 0) {
        vulkan.vkDestroyInstance(instance, null);
        return DeviceError.NoPhysicalDevices;
    }

    var devices: [8]VkPhysicalDevice = @splat(undefined);
    devices = devices;
    var count: u32 = device_count;
    const device_ptr: [*]VkPhysicalDevice = @ptrCast(&devices);
    if (vulkan.vkEnumeratePhysicalDevices(instance, &count, device_ptr) != VK_SUCCESS) {
        vulkan.vkDestroyInstance(instance, null);
        return DeviceError.EnumerateDevicesFailed;
    }

    const physical = devices[0];
    const family_index: u32 = 0;

    const queue_priority: f32 = 1.0;
    const queue_info = VkDeviceQueueCreateInfo{
        .sType = VK_STRUCTURE_TYPE_DEVICE_QUEUE_CREATE_INFO,
        .pNext = null,
        .flags = 0,
        .queueFamilyIndex = family_index,
        .queueCount = 1,
        .pQueuePriorities = &queue_priority,
    };

    const device_info = VkDeviceCreateInfo{
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

    var device: VkDevice = undefined;
    if (vulkan.vkCreateDevice(physical, &device_info, null, &device) != VK_SUCCESS) {
        vulkan.vkDestroyInstance(instance, null);
        return DeviceError.CreateDeviceFailed;
    }

    var queue: VkQueue = undefined;
    vulkan.vkGetDeviceQueue(device, family_index, 0, &queue);

    out.* = .{
        .instance = instance,
        .physical = physical,
        .device = device,
        .queue = queue,
        .queue_family_index = family_index,
    };
}

pub const DeviceError = error{
    DlOpenFailed,
    DlsymFailed,
    CreateInstanceFailed,
    NoPhysicalDevices,
    EnumerateDevicesFailed,
    CreateDeviceFailed,
};

test "creates Vulkan device and enumerates physical devices" {
    // Verifies Vulkan ICD integration. Requires a working Vulkan driver.
    var vulkan = try load();
    defer _ = std.c.dlclose(vulkan.handle);

    var device: Device = undefined;
    try createDevice(&vulkan, &device);
    defer vulkan.vkDestroyDevice(device.device, null);
    defer vulkan.vkDestroyInstance(device.instance, null);

    try std.testing.expect(device.queue_family_index == 0);

    std.debug.print("Vulkan device created: queue_family={d}\n", .{device.queue_family_index});
}
