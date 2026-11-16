//! Cipher GPU feasibility probe: headless Vulkan on the NVIDIA ICD.
//! No window, no surface, no swapchain. Proves the driver works from a
//! from-zero process: instance, device, queue, image memory allocation,
//! and buffer allocation. Run with: zig build probe
const std = @import("std");

const VK_MAKE_API_VERSION_0_1_2_0 = (0 << 29) | (1 << 22) | (2 << 12); // 0x00102000
const VK_SUCCESS: i32 = 0;
const VK_STRUCTURE_TYPE_APPLICATION_INFO: u32 = 0;
const VK_STRUCTURE_TYPE_INSTANCE_CREATE_INFO: u32 = 1;
const VK_STRUCTURE_TYPE_DEVICE_QUEUE_CREATE_INFO: u32 = 2;
const VK_STRUCTURE_TYPE_DEVICE_CREATE_INFO: u32 = 3;
const VK_STRUCTURE_TYPE_MEMORY_ALLOCATE_INFO: u32 = 5;
const VK_STRUCTURE_TYPE_IMAGE_CREATE_INFO: u32 = 14;
const VK_STRUCTURE_TYPE_COMMAND_POOL_CREATE_INFO: u32 = 19;
const VK_STRUCTURE_TYPE_BUFFER_CREATE_INFO: u32 = 12;
const VK_STRUCTURE_TYPE_COMMAND_BUFFER_ALLOCATE_INFO: u32 = 20;
const VK_FORMAT_R8G8B8A8_UNORM: u32 = 37;

const VkResult = i32;
const VkInstance = *anyopaque;
const VkPhysicalDevice = *anyopaque;
const VkDevice = *anyopaque;
const VkQueue = *anyopaque;
const VkCommandPool = *anyopaque;
const VkCommandBuffer = *anyopaque;
const VkImage = *anyopaque;
const VkDeviceMemory = *anyopaque;
const VkBuffer = *anyopaque;

const VkApplicationInfo = extern struct {
    sType: u32,
    pNext: ?*const anyopaque,
    pApplicationName: [*:0]const u8,
    applicationVersion: u32,
    pEngineName: [*:0]const u8,
    engineVersion: u32,
    apiVersion: u32,
};

const VkInstanceCreateInfo = extern struct {
    sType: u32,
    pNext: ?*const anyopaque,
    flags: u32,
    pApplicationInfo: ?*const VkApplicationInfo,
    enabledLayerCount: u32,
    ppEnabledLayerNames: ?[*]const [*:0]const u8,
    enabledExtensionCount: u32,
    ppEnabledExtensionNames: ?[*]const [*:0]const u8,
};

const VkPhysicalDeviceProperties = extern struct {
    apiVersion: u32,
    driverVersion: u32,
    vendorID: u32,
    deviceID: u32,
    deviceType: u32,
    deviceName: [256]u8,
    pipelineCacheUUID: [16]u8,
    limits: [504]u8,
    sparseProperties: [8]u8,
};

const VkQueueFamilyProperties = extern struct {
    queueFlags: u32,
    queueCount: u32,
    timestampValidBits: u32,
    minImageTransferGranularityWidth: i32,
    minImageTransferGranularityHeight: i32,
    minImageTransferGranularityDepth: i32,
};

const VkDeviceQueueCreateInfo = extern struct {
    sType: u32,
    pNext: ?*const anyopaque,
    flags: u32,
    queueFamilyIndex: u32,
    queueCount: u32,
    pQueuePriorities: ?*const f32,
};

const VkDeviceCreateInfo = extern struct {
    sType: u32,
    pNext: ?*const anyopaque,
    flags: u32,
    queueCreateInfoCount: u32,
    pQueueCreateInfos: ?*const VkDeviceQueueCreateInfo,
    enabledLayerCount: u32,
    ppEnabledLayerNames: ?[*]const [*:0]const u8,
    enabledExtensionCount: u32,
    ppEnabledExtensionNames: ?[*]const [*:0]const u8,
    pEnabledFeatures: ?*const anyopaque,
};

const VkMemoryRequirements = extern struct {
    size: u64,
    alignment: u64,
    memoryTypeBits: u32,
};

const VkMemoryType = extern struct {
    propertyFlags: u32,
    heapIndex: u32,
};

const VkMemoryHeap = extern struct {
    size: u64,
    flags: u32,
    _pad: u32,
};

const VkPhysicalDeviceMemoryProperties = extern struct {
    memoryTypeCount: u32,
    memoryTypes: [32]VkMemoryType,
    memoryHeapCount: u32,
    memoryHeaps: [16]VkMemoryHeap,
};

const VkMemoryAllocateInfo = extern struct {
    sType: u32,
    pNext: ?*const anyopaque,
    allocationSize: u64,
    memoryTypeIndex: u32,
};

const VkImageCreateInfo = extern struct {
    sType: u32,
    pNext: ?*const anyopaque,
    flags: u32,
    imageType: u32,
    format: u32,
    extentWidth: u32,
    extentHeight: u32,
    extentDepth: u32,
    mipLevels: u32,
    arrayLayers: u32,
    samples: u32,
    tiling: u32,
    usage: u32,
    sharingMode: u32,
    queueFamilyIndexCount: u32,
    pQueueFamilyIndices: ?*const u32,
    initialLayout: u32,
};

const VkBufferCreateInfo = extern struct {
    sType: u32,
    pNext: ?*const anyopaque,
    flags: u32,
    size: u64,
    usage: u32,
    sharingMode: u32,
    queueFamilyIndexCount: u32,
    pQueueFamilyIndices: ?*const u32,
};

const VkCommandPoolCreateInfo = extern struct {
    sType: u32,
    pNext: ?*const anyopaque,
    flags: u32,
    queueFamilyIndex: u32,
};

const VkCommandBufferAllocateInfo = extern struct {
    sType: u32,
    pNext: ?*const anyopaque,
    commandPool: VkCommandPool,
    level: u32,
    commandBufferCount: u32,
};

const Vulkan = struct {
    lib: std.DynLib,
    vkCreateInstance: *const fn (?*const VkInstanceCreateInfo, ?*const anyopaque, ?*VkInstance) callconv(.c) VkResult,
    vkEnumeratePhysicalDevices: *const fn (VkInstance, ?*u32, ?[*]VkPhysicalDevice) callconv(.c) VkResult,
    vkGetPhysicalDeviceProperties: *const fn (VkPhysicalDevice, ?*VkPhysicalDeviceProperties) callconv(.c) void,
    vkGetPhysicalDeviceQueueFamilyProperties: *const fn (VkPhysicalDevice, ?*u32, ?[*]VkQueueFamilyProperties) callconv(.c) void,
    vkGetPhysicalDeviceMemoryProperties: *const fn (VkPhysicalDevice, ?*VkPhysicalDeviceMemoryProperties) callconv(.c) void,
    vkCreateDevice: *const fn (VkPhysicalDevice, ?*const VkDeviceCreateInfo, ?*const anyopaque, ?*VkDevice) callconv(.c) VkResult,
    vkGetDeviceQueue: *const fn (VkDevice, u32, u32, ?*VkQueue) callconv(.c) void,
    vkCreateCommandPool: *const fn (VkDevice, ?*const VkCommandPoolCreateInfo, ?*const anyopaque, ?*VkCommandPool) callconv(.c) VkResult,
    vkAllocateCommandBuffers: *const fn (VkDevice, ?*const VkCommandBufferAllocateInfo, ?[*]VkCommandBuffer) callconv(.c) VkResult,
    vkCreateImage: *const fn (VkDevice, ?*const VkImageCreateInfo, ?*const anyopaque, ?*VkImage) callconv(.c) VkResult,
    vkGetImageMemoryRequirements: *const fn (VkDevice, VkImage, ?*VkMemoryRequirements) callconv(.c) void,
    vkBindImageMemory: *const fn (VkDevice, VkImage, VkDeviceMemory, u64) callconv(.c) VkResult,
    vkCreateBuffer: *const fn (VkDevice, ?*const VkBufferCreateInfo, ?*const anyopaque, ?*VkBuffer) callconv(.c) VkResult,
    vkGetBufferMemoryRequirements: *const fn (VkDevice, VkBuffer, ?*VkMemoryRequirements) callconv(.c) void,
    vkBindBufferMemory: *const fn (VkDevice, VkBuffer, VkDeviceMemory, u64) callconv(.c) VkResult,
    vkAllocateMemory: *const fn (VkDevice, ?*const VkMemoryAllocateInfo, ?*const anyopaque, ?*VkDeviceMemory) callconv(.c) VkResult,
};

fn load() !Vulkan {
    var lib = try std.DynLib.open("libvulkan.so.1");
    errdefer lib.close();

    const vkCreateInstance: *const fn (?*const VkInstanceCreateInfo, ?*const anyopaque, ?*VkInstance) callconv(.c) VkResult = lib.lookup(*const fn (?*const VkInstanceCreateInfo, ?*const anyopaque, ?*VkInstance) callconv(.c) VkResult, "vkCreateInstance") orelse return error.SymbolNotFound;
    const vkEnumeratePhysicalDevices: *const fn (VkInstance, ?*u32, ?[*]VkPhysicalDevice) callconv(.c) VkResult = lib.lookup(*const fn (VkInstance, ?*u32, ?[*]VkPhysicalDevice) callconv(.c) VkResult, "vkEnumeratePhysicalDevices") orelse return error.SymbolNotFound;
    const vkGetPhysicalDeviceProperties: *const fn (VkPhysicalDevice, ?*VkPhysicalDeviceProperties) callconv(.c) void = lib.lookup(*const fn (VkPhysicalDevice, ?*VkPhysicalDeviceProperties) callconv(.c) void, "vkGetPhysicalDeviceProperties") orelse return error.SymbolNotFound;
    const vkGetPhysicalDeviceQueueFamilyProperties: *const fn (VkPhysicalDevice, ?*u32, ?[*]VkQueueFamilyProperties) callconv(.c) void = lib.lookup(*const fn (VkPhysicalDevice, ?*u32, ?[*]VkQueueFamilyProperties) callconv(.c) void, "vkGetPhysicalDeviceQueueFamilyProperties") orelse return error.SymbolNotFound;
    const vkGetPhysicalDeviceMemoryProperties: *const fn (VkPhysicalDevice, ?*VkPhysicalDeviceMemoryProperties) callconv(.c) void = lib.lookup(*const fn (VkPhysicalDevice, ?*VkPhysicalDeviceMemoryProperties) callconv(.c) void, "vkGetPhysicalDeviceMemoryProperties") orelse return error.SymbolNotFound;
    const vkCreateDevice: *const fn (VkPhysicalDevice, ?*const VkDeviceCreateInfo, ?*const anyopaque, ?*VkDevice) callconv(.c) VkResult = lib.lookup(*const fn (VkPhysicalDevice, ?*const VkDeviceCreateInfo, ?*const anyopaque, ?*VkDevice) callconv(.c) VkResult, "vkCreateDevice") orelse return error.SymbolNotFound;
    const vkGetDeviceQueue: *const fn (VkDevice, u32, u32, ?*VkQueue) callconv(.c) void = lib.lookup(*const fn (VkDevice, u32, u32, ?*VkQueue) callconv(.c) void, "vkGetDeviceQueue") orelse return error.SymbolNotFound;
    const vkCreateCommandPool: *const fn (VkDevice, ?*const VkCommandPoolCreateInfo, ?*const anyopaque, ?*VkCommandPool) callconv(.c) VkResult = lib.lookup(*const fn (VkDevice, ?*const VkCommandPoolCreateInfo, ?*const anyopaque, ?*VkCommandPool) callconv(.c) VkResult, "vkCreateCommandPool") orelse return error.SymbolNotFound;
    const vkAllocateCommandBuffers: *const fn (VkDevice, ?*const VkCommandBufferAllocateInfo, ?[*]VkCommandBuffer) callconv(.c) VkResult = lib.lookup(*const fn (VkDevice, ?*const VkCommandBufferAllocateInfo, ?[*]VkCommandBuffer) callconv(.c) VkResult, "vkAllocateCommandBuffers") orelse return error.SymbolNotFound;
    const vkCreateImage: *const fn (VkDevice, ?*const VkImageCreateInfo, ?*const anyopaque, ?*VkImage) callconv(.c) VkResult = lib.lookup(*const fn (VkDevice, ?*const VkImageCreateInfo, ?*const anyopaque, ?*VkImage) callconv(.c) VkResult, "vkCreateImage") orelse return error.SymbolNotFound;
    const vkGetImageMemoryRequirements: *const fn (VkDevice, VkImage, ?*VkMemoryRequirements) callconv(.c) void = lib.lookup(*const fn (VkDevice, VkImage, ?*VkMemoryRequirements) callconv(.c) void, "vkGetImageMemoryRequirements") orelse return error.SymbolNotFound;
    const vkBindImageMemory: *const fn (VkDevice, VkImage, VkDeviceMemory, u64) callconv(.c) VkResult = lib.lookup(*const fn (VkDevice, VkImage, VkDeviceMemory, u64) callconv(.c) VkResult, "vkBindImageMemory") orelse return error.SymbolNotFound;
    const vkCreateBuffer: *const fn (VkDevice, ?*const VkBufferCreateInfo, ?*const anyopaque, ?*VkBuffer) callconv(.c) VkResult = lib.lookup(*const fn (VkDevice, ?*const VkBufferCreateInfo, ?*const anyopaque, ?*VkBuffer) callconv(.c) VkResult, "vkCreateBuffer") orelse return error.SymbolNotFound;
    const vkGetBufferMemoryRequirements: *const fn (VkDevice, VkBuffer, ?*VkMemoryRequirements) callconv(.c) void = lib.lookup(*const fn (VkDevice, VkBuffer, ?*VkMemoryRequirements) callconv(.c) void, "vkGetBufferMemoryRequirements") orelse return error.SymbolNotFound;
    const vkBindBufferMemory: *const fn (VkDevice, VkBuffer, VkDeviceMemory, u64) callconv(.c) VkResult = lib.lookup(*const fn (VkDevice, VkBuffer, VkDeviceMemory, u64) callconv(.c) VkResult, "vkBindBufferMemory") orelse return error.SymbolNotFound;
    const vkAllocateMemory: *const fn (VkDevice, ?*const VkMemoryAllocateInfo, ?*const anyopaque, ?*VkDeviceMemory) callconv(.c) VkResult = lib.lookup(*const fn (VkDevice, ?*const VkMemoryAllocateInfo, ?*const anyopaque, ?*VkDeviceMemory) callconv(.c) VkResult, "vkAllocateMemory") orelse return error.SymbolNotFound;

    return .{
        .lib = lib,
        .vkCreateInstance = vkCreateInstance,
        .vkEnumeratePhysicalDevices = vkEnumeratePhysicalDevices,
        .vkGetPhysicalDeviceProperties = vkGetPhysicalDeviceProperties,
        .vkGetPhysicalDeviceQueueFamilyProperties = vkGetPhysicalDeviceQueueFamilyProperties,
        .vkGetPhysicalDeviceMemoryProperties = vkGetPhysicalDeviceMemoryProperties,
        .vkCreateDevice = vkCreateDevice,
        .vkGetDeviceQueue = vkGetDeviceQueue,
        .vkCreateCommandPool = vkCreateCommandPool,
        .vkAllocateCommandBuffers = vkAllocateCommandBuffers,
        .vkCreateImage = vkCreateImage,
        .vkGetImageMemoryRequirements = vkGetImageMemoryRequirements,
        .vkBindImageMemory = vkBindImageMemory,
        .vkCreateBuffer = vkCreateBuffer,
        .vkGetBufferMemoryRequirements = vkGetBufferMemoryRequirements,
        .vkBindBufferMemory = vkBindBufferMemory,
        .vkAllocateMemory = vkAllocateMemory,
    };
}

fn findMemoryType(props: *const VkPhysicalDeviceMemoryProperties, filter: u32, required: u32) ?u32 {
    var i: u32 = 0;
    while (i < props.memoryTypeCount) : (i += 1) {
        if ((props.memoryTypes[i].propertyFlags & required) == required and (filter & (@as(u32, 1) << @intCast(i))) != 0) return i;
    }
    return null;
}

pub fn main() !void {
    var start_ts: std.os.linux.timespec = undefined;
    _ = std.os.linux.clock_gettime(.MONOTONIC, &start_ts);

    var vk = try load();
    defer vk.lib.close();

    const app_info = VkApplicationInfo{
        .sType = VK_STRUCTURE_TYPE_APPLICATION_INFO,
        .pNext = null,
        .pApplicationName = "cipher",
        .applicationVersion = 1,
        .pEngineName = "cipher",
        .engineVersion = 1,
        .apiVersion = VK_MAKE_API_VERSION_0_1_2_0,
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

    var instance: VkInstance = undefined;
    const instance_rc = vk.vkCreateInstance(&instance_info, null, &instance);
    if (instance_rc != VK_SUCCESS) {
        std.debug.print("vkCreateInstance failed rc={d}\n", .{instance_rc});
        return error.VulkanInstanceFailed;
    }
    std.debug.print("vkCreateInstance ok rc={d}\n", .{instance_rc});

    var count: u32 = 0;
    const enum_rc = vk.vkEnumeratePhysicalDevices(instance, &count, null);
    if (enum_rc != VK_SUCCESS) {
        std.debug.print("vkEnumeratePhysicalDevices(count) failed rc={d}\n", .{enum_rc});
        return error.EnumerateFailed;
    }
    std.debug.print("physical device count={d}\n", .{count});
    if (count == 0) return error.NoPhysicalDevices;

    var devices: [8]VkPhysicalDevice = undefined;
    const enum_rc2 = vk.vkEnumeratePhysicalDevices(instance, &count, &devices);
    if (enum_rc2 != VK_SUCCESS) return error.EnumerateFailed;

    const chosen = devices[0];
    var props: VkPhysicalDeviceProperties = undefined;
    vk.vkGetPhysicalDeviceProperties(chosen, &props);
    const device_name_end = std.mem.indexOfScalar(u8, &props.deviceName, 0) orelse props.deviceName.len;
    std.debug.print("device={s} vendor={x} device={x} api={x}\n", .{ props.deviceName[0..device_name_end], props.vendorID, props.deviceID, props.apiVersion });

    var queue_count: u32 = 0;
    vk.vkGetPhysicalDeviceQueueFamilyProperties(chosen, &queue_count, null);
    std.debug.print("queue families={d}\n", .{queue_count});
    var queues: [16]VkQueueFamilyProperties = undefined;
    vk.vkGetPhysicalDeviceQueueFamilyProperties(chosen, &queue_count, &queues);

    var graphics_family: ?u32 = null;
    var i: u32 = 0;
    while (i < queue_count) : (i += 1) {
        // VK_QUEUE_GRAPHICS_BIT = 0x1, VK_QUEUE_COMPUTE_BIT = 0x2
        if ((queues[i].queueFlags & 0x1) != 0 and graphics_family == null) graphics_family = i;
    }
    const family = graphics_family orelse return error.NoGraphicsQueue;

    const priority: f32 = 1.0;
    const queue_info = VkDeviceQueueCreateInfo{
        .sType = VK_STRUCTURE_TYPE_DEVICE_QUEUE_CREATE_INFO,
        .pNext = null,
        .flags = 0,
        .queueFamilyIndex = family,
        .queueCount = 1,
        .pQueuePriorities = &priority,
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
    const device_rc = vk.vkCreateDevice(chosen, &device_info, null, &device);
    if (device_rc != VK_SUCCESS) {
        std.debug.print("vkCreateDevice failed rc={d}\n", .{device_rc});
        return error.DeviceFailed;
    }
    std.debug.print("vkCreateDevice ok family={d}\n", .{family});

    var queue: VkQueue = undefined;
    vk.vkGetDeviceQueue(device, family, 0, &queue);
    std.debug.print("queue acquired (opaque handle: {*})\n", .{queue});

    const pool_info = VkCommandPoolCreateInfo{
        .sType = VK_STRUCTURE_TYPE_COMMAND_POOL_CREATE_INFO,
        .pNext = null,
        .flags = 0x2, // VK_COMMAND_POOL_CREATE_TRANSIENT_BIT
        .queueFamilyIndex = family,
    };
    var pool: VkCommandPool = undefined;
    if (vk.vkCreateCommandPool(device, &pool_info, null, &pool) != VK_SUCCESS) return error.PoolFailed;
    std.debug.print("command pool created\n", .{});

    const cmd_info = VkCommandBufferAllocateInfo{
        .sType = VK_STRUCTURE_TYPE_COMMAND_BUFFER_ALLOCATE_INFO,
        .pNext = null,
        .commandPool = pool,
        .level = 0,
        .commandBufferCount = 1,
    };
    var cmd: VkCommandBuffer = undefined;
    if (vk.vkAllocateCommandBuffers(device, &cmd_info, @ptrCast(&cmd)) != VK_SUCCESS) return error.CmdBufferFailed;
    std.debug.print("command buffer allocated\n", .{});

    const image_info = VkImageCreateInfo{
        .sType = VK_STRUCTURE_TYPE_IMAGE_CREATE_INFO,
        .pNext = null,
        .flags = 0,
        .imageType = 1, // VK_IMAGE_TYPE_2D
        .format = VK_FORMAT_R8G8B8A8_UNORM,
        .extentWidth = 640,
        .extentHeight = 400,
        .extentDepth = 1,
        .mipLevels = 1,
        .arrayLayers = 1,
        .samples = 1, // VK_SAMPLE_COUNT_1_BIT
        .tiling = 0, // VK_IMAGE_TILING_OPTIMAL
        .usage = 0x00000002 | 0x00000010 | 0x00000001, // TRANSFER_DST | COLOR_ATTACHMENT | TRANSFER_SRC
        .sharingMode = 0, // EXCLUSIVE
        .queueFamilyIndexCount = 0,
        .pQueueFamilyIndices = null,
        .initialLayout = 0,
    };
    var image: VkImage = undefined;
    if (vk.vkCreateImage(device, &image_info, null, &image) != VK_SUCCESS) return error.ImageFailed;
    std.debug.print("image created\n", .{});

    var mem_reqs: VkMemoryRequirements = undefined;
    vk.vkGetImageMemoryRequirements(device, image, &mem_reqs);
    std.debug.print("image memory size={d} alignment={d} typeBits={x}\n", .{ mem_reqs.size, mem_reqs.alignment, mem_reqs.memoryTypeBits });

    var mem_props: VkPhysicalDeviceMemoryProperties = undefined;
    vk.vkGetPhysicalDeviceMemoryProperties(chosen, &mem_props);

    const image_memory_type = findMemoryType(&mem_props, mem_reqs.memoryTypeBits, 0x1) orelse return error.NoDeviceLocalMemory;
    const image_alloc = VkMemoryAllocateInfo{
        .sType = VK_STRUCTURE_TYPE_MEMORY_ALLOCATE_INFO,
        .pNext = null,
        .allocationSize = mem_reqs.size,
        .memoryTypeIndex = image_memory_type,
    };
    var image_memory: VkDeviceMemory = undefined;
    if (vk.vkAllocateMemory(device, &image_alloc, null, &image_memory) != VK_SUCCESS) return error.ImageAllocFailed;
    if (vk.vkBindImageMemory(device, image, image_memory, 0) != VK_SUCCESS) return error.ImageBindFailed;
    std.debug.print("image memory allocated and bound\n", .{});

    const buffer_info = VkBufferCreateInfo{
        .sType = VK_STRUCTURE_TYPE_BUFFER_CREATE_INFO,
        .pNext = null,
        .flags = 0,
        .size = 640 * 400 * 4,
        .usage = 0x3, // TRANSFER_SRC | TRANSFER_DST
        .sharingMode = 0,
        .queueFamilyIndexCount = 0,
        .pQueueFamilyIndices = null,
    };
    var buffer: VkBuffer = undefined;
    if (vk.vkCreateBuffer(device, &buffer_info, null, &buffer) != VK_SUCCESS) return error.BufferFailed;

    var buffer_reqs: VkMemoryRequirements = undefined;
    vk.vkGetBufferMemoryRequirements(device, buffer, &buffer_reqs);
    const host_memory_type = findMemoryType(&mem_props, buffer_reqs.memoryTypeBits, 0x2 | 0x4) orelse return error.NoHostVisibleMemory;
    const buffer_alloc = VkMemoryAllocateInfo{
        .sType = VK_STRUCTURE_TYPE_MEMORY_ALLOCATE_INFO,
        .pNext = null,
        .allocationSize = buffer_reqs.size,
        .memoryTypeIndex = host_memory_type,
    };
    var buffer_memory: VkDeviceMemory = undefined;
    if (vk.vkAllocateMemory(device, &buffer_alloc, null, &buffer_memory) != VK_SUCCESS) return error.BufferAllocFailed;
    if (vk.vkBindBufferMemory(device, buffer, buffer_memory, 0) != VK_SUCCESS) return error.BufferBindFailed;
    std.debug.print("host-visible buffer allocated and bound (size={d})\n", .{buffer_reqs.size});

    var end_ts: std.os.linux.timespec = undefined;
    _ = std.os.linux.clock_gettime(.MONOTONIC, &end_ts);
    const diff_ns: i128 = (@as(i128, end_ts.sec) - @as(i128, start_ts.sec)) * 1_000_000_000 + (@as(i128, end_ts.nsec) - @as(i128, start_ts.nsec));
    const elapsed_ms = @as(f64, @floatFromInt(diff_ns)) / 1_000_000.0;
    std.debug.print("PROBE_OK vkheadless device_count={d} probe_ms={d:.3}\n", .{ count, elapsed_ms });
}
