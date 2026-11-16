//! Absolute-minimal compute probe: one shader, one storage image, one readback.
const std = @import("std");

const VK_SUCCESS: i32 = 0;
const API : u32 = (0 << 29) | (1 << 22) | (2 << 12);
const S_APP: u32 = 0; const S_INST: u32 = 1; const S_Q: u32 = 2; const S_DEV: u32 = 3; const S_SUB: u32 = 4;
const S_MEM: u32 = 5; const S_BUF: u32 = 12; const S_IMG: u32 = 14; const S_VIEW: u32 = 15; const S_SHADER: u32 = 16;
const S_STAGE: u32 = 18; const S_PLY: u32 = 30; const S_DL: u32 = 32; const S_PL: u32 = 33; const S_ALLOC: u32 = 34;
const S_WRITE: u32 = 35; const S_COMPUTE: u32 = 29; const S_CMDP: u32 = 39; const S_CMDA: u32 = 40; const S_BEGIN: u32 = 42;
const S_BARRIER: u32 = 45;

const VkResult = i32;
const VkInstance = *anyopaque;
const VkPhysicalDevice = *anyopaque;
const VkDevice = *anyopaque;
const VkQueue = *anyopaque;
const VkCommandPool = *anyopaque;
const VkCommandBuffer = *anyopaque;
const VkImage = *anyopaque;
const VkImageView = *anyopaque;
const VkShaderModule = *anyopaque;
const VkPipelineLayout = *anyopaque;
const VkPipeline = *anyopaque;
const VkDescriptorSetLayout = *anyopaque;
const VkDescriptorPool = *anyopaque;
const VkDescriptorSet = *anyopaque;
const VkBuffer = *anyopaque;
const VkDeviceMemory = *anyopaque;

const VkApplicationInfo = extern struct { sType: u32, pNext: ?*const anyopaque, pApplicationName: [*:0]const u8, applicationVersion: u32, pEngineName: [*:0]const u8, engineVersion: u32, apiVersion: u32 };
const VkInstanceCreateInfo = extern struct { sType: u32, pNext: ?*const anyopaque, flags: u32, pApplicationInfo: ?*const VkApplicationInfo, enabledLayerCount: u32, ppEnabledLayerNames: ?[*]const [*:0]const u8, enabledExtensionCount: u32, ppEnabledExtensionNames: ?[*]const [*:0]const u8 };
const VkQueueFamilyProperties = extern struct { queueFlags: u32, queueCount: u32, timestampValidBits: u32, minImageTransferGranularityWidth: i32, minImageTransferGranularityHeight: i32, minImageTransferGranularityDepth: i32 };
const VkDeviceQueueCreateInfo = extern struct { sType: u32, pNext: ?*const anyopaque, flags: u32, queueFamilyIndex: u32, queueCount: u32, pQueuePriorities: ?*const f32 };
const VkDeviceCreateInfo = extern struct { sType: u32, pNext: ?*const anyopaque, flags: u32, queueCreateInfoCount: u32, pQueueCreateInfos: ?*const VkDeviceQueueCreateInfo, enabledLayerCount: u32, ppEnabledLayerNames: ?[*]const [*:0]const u8, enabledExtensionCount: u32, ppEnabledExtensionNames: ?[*]const [*:0]const u8, pEnabledFeatures: ?*const anyopaque };
const VkMemoryRequirements = extern struct { size: u64, alignment: u64, memoryTypeBits: u32 };
const VkMemoryType = extern struct { propertyFlags: u32, heapIndex: u32 };
const VkMemoryHeap = extern struct { size: u64, flags: u32, _p: u32 };
const VkPhysicalDeviceMemoryProperties = extern struct { memoryTypeCount: u32, memoryTypes: [32]VkMemoryType, memoryHeapCount: u32, memoryHeaps: [16]VkMemoryHeap };
const VkMemoryAllocateInfo = extern struct { sType: u32, pNext: ?*const anyopaque, allocationSize: u64, memoryTypeIndex: u32 };
const VkBufferCreateInfo = extern struct { sType: u32, pNext: ?*const anyopaque, flags: u32, size: u64, usage: u32, sharingMode: u32, queueFamilyIndexCount: u32, pQueueFamilyIndices: ?*const u32 };
const VkSubresourceRange = extern struct { aspectMask: u32, baseMipLevel: u32, levelCount: u32, baseArrayLayer: u32, layerCount: u32 };
const VkSubresourceLayers = extern struct { aspectMask: u32, mipLevel: u32, baseArrayLayer: u32, layerCount: u32 };
const VkImageCreateInfo = extern struct { sType: u32, pNext: ?*const anyopaque, flags: u32, imageType: u32, format: u32, extentWidth: u32, extentHeight: u32, extentDepth: u32, mipLevels: u32, arrayLayers: u32, samples: u32, tiling: u32, usage: u32, sharingMode: u32, queueFamilyIndexCount: u32, pQueueFamilyIndices: ?*const u32, initialLayout: u32 };
const VkImageViewCreateInfo = extern struct { sType: u32, pNext: ?*const anyopaque, flags: u32, image: VkImage, viewType: u32, format: u32, componentsR: u32, componentsG: u32, componentsB: u32, componentsA: u32, subresourceRange: VkSubresourceRange };
const VkShaderModuleCreateInfo = extern struct { sType: u32, pNext: ?*const anyopaque, flags: u32, codeSize: usize, pCode: ?[*]const u32 };
const VkPipelineShaderStageCreateInfo = extern struct { sType: u32, pNext: ?*const anyopaque, flags: u32, stage: u32, module: VkShaderModule, pName: [*:0]const u8, pSpecializationInfo: ?*const anyopaque };
const VkPushConstantRange = extern struct { stageFlags: u32, offset: u32, size: u32 };
const VkPipelineLayoutCreateInfo = extern struct { sType: u32, pNext: ?*const anyopaque, flags: u32, setLayoutCount: u32, pSetLayouts: ?*const VkDescriptorSetLayout, pushConstantRangeCount: u32, pPushConstantRanges: ?*const VkPushConstantRange };
const VkDescriptorSetLayoutBinding = extern struct { binding: u32, descriptorType: u32, descriptorCount: u32, stageFlags: u32, pImmutableSamplers: ?*const anyopaque };
const VkDescriptorSetLayoutCreateInfo = extern struct { sType: u32, pNext: ?*const anyopaque, flags: u32, bindingCount: u32, pBindings: ?*const VkDescriptorSetLayoutBinding };
const VkDescriptorPoolSize = extern struct { type: u32, descriptorCount: u32 };
const VkDescriptorPoolCreateInfo = extern struct { sType: u32, pNext: ?*const anyopaque, flags: u32, maxSets: u32, poolSizeCount: u32, pPoolSizes: ?*const VkDescriptorPoolSize };
const VkDescriptorSetAllocateInfo = extern struct { sType: u32, pNext: ?*const anyopaque, descriptorPool: VkDescriptorPool, descriptorSetCount: u32, pSetLayouts: ?*const VkDescriptorSetLayout };
const VkDescriptorImageInfo = extern struct { sampler: ?*anyopaque, imageView: VkImageView, imageLayout: u32 };
const VkWriteDescriptorSet = extern struct { sType: u32, pNext: ?*const anyopaque, dstSet: VkDescriptorSet, dstBinding: u32, dstArrayElement: u32, descriptorCount: u32, descriptorType: u32, pImageInfo: ?*const VkDescriptorImageInfo, pBufferInfo: ?*const anyopaque, pTexelBufferView: ?*const anyopaque };
const VkComputePipelineCreateInfo = extern struct { sType: u32, pNext: ?*const anyopaque, flags: u32, stage: VkPipelineShaderStageCreateInfo, layout: VkPipelineLayout, basePipelineHandle: ?*anyopaque, basePipelineIndex: i32 };
const VkCommandPoolCreateInfo = extern struct { sType: u32, pNext: ?*const anyopaque, flags: u32, queueFamilyIndex: u32 };
const VkCommandBufferAllocateInfo = extern struct { sType: u32, pNext: ?*const anyopaque, commandPool: VkCommandPool, level: u32, commandBufferCount: u32 };
const VkCommandBufferBeginInfo = extern struct { sType: u32, pNext: ?*const anyopaque, flags: u32, pInheritanceInfo: ?*const anyopaque };
const VkSubmitInfo = extern struct { sType: u32, pNext: ?*const anyopaque, waitSemaphoreCount: u32, pWaitSemaphores: ?*const anyopaque, pWaitDstStageMask: ?*const u32, commandBufferCount: u32, pCommandBuffers: ?*const VkCommandBuffer, signalSemaphoreCount: u32, pSignalSemaphores: ?*const anyopaque };
const VkBufferImageCopy = extern struct { bufferOffset: u64, bufferRowLength: u32, bufferImageHeight: u32, imageSubresource: VkSubresourceLayers, imageOffsetX: i32, imageOffsetY: i32, imageOffsetZ: i32, imageExtentWidth: u32, imageExtentHeight: u32, imageExtentDepth: u32 };
const VkImageMemoryBarrier = extern struct { sType: u32, pNext: ?*const anyopaque, srcAccessMask: u32, dstAccessMask: u32, oldLayout: u32, newLayout: u32, srcQueueFamilyIndex: u32, dstQueueFamilyIndex: u32, image: VkImage, subresourceRange: VkSubresourceRange };

const Vulkan = struct {
    lib: std.DynLib,
    vkCreateInstance: *const fn (?*const VkInstanceCreateInfo, ?*const anyopaque, ?*VkInstance) callconv(.c) VkResult,
    vkEnumeratePhysicalDevices: *const fn (VkInstance, ?*u32, ?[*]VkPhysicalDevice) callconv(.c) VkResult,
    vkGetPhysicalDeviceQueueFamilyProperties: *const fn (VkPhysicalDevice, ?*u32, ?[*]VkQueueFamilyProperties) callconv(.c) void,
    vkGetPhysicalDeviceMemoryProperties: *const fn (VkPhysicalDevice, ?*VkPhysicalDeviceMemoryProperties) callconv(.c) void,
    vkCreateDevice: *const fn (VkPhysicalDevice, ?*const VkDeviceCreateInfo, ?*const anyopaque, ?*VkDevice) callconv(.c) VkResult,
    vkGetDeviceQueue: *const fn (VkDevice, u32, u32, ?*VkQueue) callconv(.c) void,
    vkCreateCommandPool: *const fn (VkDevice, ?*const VkCommandPoolCreateInfo, ?*const anyopaque, ?*VkCommandPool) callconv(.c) VkResult,
    vkAllocateCommandBuffers: *const fn (VkDevice, ?*const VkCommandBufferAllocateInfo, ?[*]VkCommandBuffer) callconv(.c) VkResult,
    vkCreateImage: *const fn (VkDevice, ?*const VkImageCreateInfo, ?*const anyopaque, ?*VkImage) callconv(.c) VkResult,
    vkGetImageMemoryRequirements: *const fn (VkDevice, VkImage, ?*VkMemoryRequirements) callconv(.c) void,
    vkBindImageMemory: *const fn (VkDevice, VkImage, VkDeviceMemory, u64) callconv(.c) VkResult,
    vkCreateImageView: *const fn (VkDevice, ?*const VkImageViewCreateInfo, ?*const anyopaque, ?*VkImageView) callconv(.c) VkResult,
    vkCreateShaderModule: *const fn (VkDevice, ?*const VkShaderModuleCreateInfo, ?*const anyopaque, ?*VkShaderModule) callconv(.c) VkResult,
    vkCreateDescriptorSetLayout: *const fn (VkDevice, ?*const VkDescriptorSetLayoutCreateInfo, ?*const anyopaque, ?*VkDescriptorSetLayout) callconv(.c) VkResult,
    vkCreateDescriptorPool: *const fn (VkDevice, ?*const VkDescriptorPoolCreateInfo, ?*const anyopaque, ?*VkDescriptorPool) callconv(.c) VkResult,
    vkAllocateDescriptorSets: *const fn (VkDevice, ?*const VkDescriptorSetAllocateInfo, ?[*]VkDescriptorSet) callconv(.c) VkResult,
    vkUpdateDescriptorSets: *const fn (VkDevice, u32, ?*const VkWriteDescriptorSet, u32, ?*const anyopaque) callconv(.c) void,
    vkCreatePipelineLayout: *const fn (VkDevice, ?*const VkPipelineLayoutCreateInfo, ?*const anyopaque, ?*VkPipelineLayout) callconv(.c) VkResult,
    vkCreateComputePipelines: *const fn (VkDevice, ?*anyopaque, u32, ?*const VkComputePipelineCreateInfo, ?*const anyopaque, ?[*]VkPipeline) callconv(.c) VkResult,
    vkCreateBuffer: *const fn (VkDevice, ?*const VkBufferCreateInfo, ?*const anyopaque, ?*VkBuffer) callconv(.c) VkResult,
    vkGetBufferMemoryRequirements: *const fn (VkDevice, VkBuffer, ?*VkMemoryRequirements) callconv(.c) void,
    vkAllocateMemory: *const fn (VkDevice, ?*const VkMemoryAllocateInfo, ?*const anyopaque, ?*VkDeviceMemory) callconv(.c) VkResult,
    vkBindBufferMemory: *const fn (VkDevice, VkBuffer, VkDeviceMemory, u64) callconv(.c) VkResult,
    vkBeginCommandBuffer: *const fn (VkCommandBuffer, ?*const VkCommandBufferBeginInfo) callconv(.c) VkResult,
    vkEndCommandBuffer: *const fn (VkCommandBuffer) callconv(.c) VkResult,
    vkCmdBindPipeline: *const fn (VkCommandBuffer, u32, VkPipeline) callconv(.c) void,
    vkCmdBindDescriptorSets: *const fn (VkCommandBuffer, u32, VkPipelineLayout, u32, u32, ?*const VkDescriptorSet, u32, ?*const u32) callconv(.c) void,
    vkCmdDispatch: *const fn (VkCommandBuffer, u32, u32, u32) callconv(.c) void,
    vkCmdClearColorImage: *const fn (VkCommandBuffer, VkImage, u32, ?*const anyopaque, u32, ?*const anyopaque) callconv(.c) void,
    vkCmdPipelineBarrier: *const fn (VkCommandBuffer, u32, u32, u32, u32, ?*const anyopaque, u32, ?*const anyopaque, u32, ?*const VkImageMemoryBarrier) callconv(.c) void,
    vkCmdCopyImageToBuffer: *const fn (VkCommandBuffer, VkImage, u32, VkBuffer, u32, ?*const VkBufferImageCopy) callconv(.c) void,
    vkCmdCopyBufferToImage: *const fn (VkCommandBuffer, VkBuffer, VkImage, u32, u32, ?*const VkBufferImageCopy) callconv(.c) void,
    vkCmdFillBuffer: *const fn (VkCommandBuffer, VkBuffer, u64, u64, u32) callconv(.c) void,
    vkQueueSubmit: *const fn (VkQueue, u32, ?*const VkSubmitInfo, ?*anyopaque) callconv(.c) VkResult,
    vkQueueWaitIdle: *const fn (VkQueue) callconv(.c) VkResult,
    vkMapMemory: *const fn (VkDevice, VkDeviceMemory, u64, u64, u32, ?*?*anyopaque) callconv(.c) VkResult,
    vkUnmapMemory: *const fn (VkDevice, VkDeviceMemory) callconv(.c) void,
};

fn sym(comptime T: type, lib: *std.DynLib, comptime name: [:0]const u8) T {
    return lib.lookup(T, name) orelse @panic("missing vulkan symbol " ++ name);
}

fn load() !Vulkan {
    var lib = try std.DynLib.open("libvulkan.so.1");
    errdefer lib.close();
    return .{
        .lib = lib,
        .vkCreateInstance = sym(*const fn (?*const VkInstanceCreateInfo, ?*const anyopaque, ?*VkInstance) callconv(.c) VkResult, &lib, "vkCreateInstance"),
        .vkEnumeratePhysicalDevices = sym(*const fn (VkInstance, ?*u32, ?[*]VkPhysicalDevice) callconv(.c) VkResult, &lib, "vkEnumeratePhysicalDevices"),
        .vkGetPhysicalDeviceQueueFamilyProperties = sym(*const fn (VkPhysicalDevice, ?*u32, ?[*]VkQueueFamilyProperties) callconv(.c) void, &lib, "vkGetPhysicalDeviceQueueFamilyProperties"),
        .vkGetPhysicalDeviceMemoryProperties = sym(*const fn (VkPhysicalDevice, ?*VkPhysicalDeviceMemoryProperties) callconv(.c) void, &lib, "vkGetPhysicalDeviceMemoryProperties"),
        .vkCreateDevice = sym(*const fn (VkPhysicalDevice, ?*const VkDeviceCreateInfo, ?*const anyopaque, ?*VkDevice) callconv(.c) VkResult, &lib, "vkCreateDevice"),
        .vkGetDeviceQueue = sym(*const fn (VkDevice, u32, u32, ?*VkQueue) callconv(.c) void, &lib, "vkGetDeviceQueue"),
        .vkCreateCommandPool = sym(*const fn (VkDevice, ?*const VkCommandPoolCreateInfo, ?*const anyopaque, ?*VkCommandPool) callconv(.c) VkResult, &lib, "vkCreateCommandPool"),
        .vkAllocateCommandBuffers = sym(*const fn (VkDevice, ?*const VkCommandBufferAllocateInfo, ?[*]VkCommandBuffer) callconv(.c) VkResult, &lib, "vkAllocateCommandBuffers"),
        .vkCreateImage = sym(*const fn (VkDevice, ?*const VkImageCreateInfo, ?*const anyopaque, ?*VkImage) callconv(.c) VkResult, &lib, "vkCreateImage"),
        .vkGetImageMemoryRequirements = sym(*const fn (VkDevice, VkImage, ?*VkMemoryRequirements) callconv(.c) void, &lib, "vkGetImageMemoryRequirements"),
        .vkBindImageMemory = sym(*const fn (VkDevice, VkImage, VkDeviceMemory, u64) callconv(.c) VkResult, &lib, "vkBindImageMemory"),
        .vkCreateImageView = sym(*const fn (VkDevice, ?*const VkImageViewCreateInfo, ?*const anyopaque, ?*VkImageView) callconv(.c) VkResult, &lib, "vkCreateImageView"),
        .vkCreateShaderModule = sym(*const fn (VkDevice, ?*const VkShaderModuleCreateInfo, ?*const anyopaque, ?*VkShaderModule) callconv(.c) VkResult, &lib, "vkCreateShaderModule"),
        .vkCreateDescriptorSetLayout = sym(*const fn (VkDevice, ?*const VkDescriptorSetLayoutCreateInfo, ?*const anyopaque, ?*VkDescriptorSetLayout) callconv(.c) VkResult, &lib, "vkCreateDescriptorSetLayout"),
        .vkCreateDescriptorPool = sym(*const fn (VkDevice, ?*const VkDescriptorPoolCreateInfo, ?*const anyopaque, ?*VkDescriptorPool) callconv(.c) VkResult, &lib, "vkCreateDescriptorPool"),
        .vkAllocateDescriptorSets = sym(*const fn (VkDevice, ?*const VkDescriptorSetAllocateInfo, ?[*]VkDescriptorSet) callconv(.c) VkResult, &lib, "vkAllocateDescriptorSets"),
        .vkUpdateDescriptorSets = sym(*const fn (VkDevice, u32, ?*const VkWriteDescriptorSet, u32, ?*const anyopaque) callconv(.c) void, &lib, "vkUpdateDescriptorSets"),
        .vkCreatePipelineLayout = sym(*const fn (VkDevice, ?*const VkPipelineLayoutCreateInfo, ?*const anyopaque, ?*VkPipelineLayout) callconv(.c) VkResult, &lib, "vkCreatePipelineLayout"),
        .vkCreateComputePipelines = sym(*const fn (VkDevice, ?*anyopaque, u32, ?*const VkComputePipelineCreateInfo, ?*const anyopaque, ?[*]VkPipeline) callconv(.c) VkResult, &lib, "vkCreateComputePipelines"),
        .vkCreateBuffer = sym(*const fn (VkDevice, ?*const VkBufferCreateInfo, ?*const anyopaque, ?*VkBuffer) callconv(.c) VkResult, &lib, "vkCreateBuffer"),
        .vkGetBufferMemoryRequirements = sym(*const fn (VkDevice, VkBuffer, ?*VkMemoryRequirements) callconv(.c) void, &lib, "vkGetBufferMemoryRequirements"),
        .vkAllocateMemory = sym(*const fn (VkDevice, ?*const VkMemoryAllocateInfo, ?*const anyopaque, ?*VkDeviceMemory) callconv(.c) VkResult, &lib, "vkAllocateMemory"),
        .vkBindBufferMemory = sym(*const fn (VkDevice, VkBuffer, VkDeviceMemory, u64) callconv(.c) VkResult, &lib, "vkBindBufferMemory"),
        .vkBeginCommandBuffer = sym(*const fn (VkCommandBuffer, ?*const VkCommandBufferBeginInfo) callconv(.c) VkResult, &lib, "vkBeginCommandBuffer"),
        .vkEndCommandBuffer = sym(*const fn (VkCommandBuffer) callconv(.c) VkResult, &lib, "vkEndCommandBuffer"),
        .vkCmdBindPipeline = sym(*const fn (VkCommandBuffer, u32, VkPipeline) callconv(.c) void, &lib, "vkCmdBindPipeline"),
        .vkCmdBindDescriptorSets = sym(*const fn (VkCommandBuffer, u32, VkPipelineLayout, u32, u32, ?*const VkDescriptorSet, u32, ?*const u32) callconv(.c) void, &lib, "vkCmdBindDescriptorSets"),
        .vkCmdDispatch = sym(*const fn (VkCommandBuffer, u32, u32, u32) callconv(.c) void, &lib, "vkCmdDispatch"),
        .vkCmdClearColorImage = sym(*const fn (VkCommandBuffer, VkImage, u32, ?*const anyopaque, u32, ?*const anyopaque) callconv(.c) void, &lib, "vkCmdClearColorImage"),
        .vkCmdPipelineBarrier = sym(*const fn (VkCommandBuffer, u32, u32, u32, u32, ?*const anyopaque, u32, ?*const anyopaque, u32, ?*const VkImageMemoryBarrier) callconv(.c) void, &lib, "vkCmdPipelineBarrier"),
        .vkCmdCopyImageToBuffer = sym(*const fn (VkCommandBuffer, VkImage, u32, VkBuffer, u32, ?*const VkBufferImageCopy) callconv(.c) void, &lib, "vkCmdCopyImageToBuffer"),
        .vkCmdCopyBufferToImage = sym(*const fn (VkCommandBuffer, VkBuffer, VkImage, u32, u32, ?*const VkBufferImageCopy) callconv(.c) void, &lib, "vkCmdCopyBufferToImage"),
        .vkCmdFillBuffer = sym(*const fn (VkCommandBuffer, VkBuffer, u64, u64, u32) callconv(.c) void, &lib, "vkCmdFillBuffer"),
        .vkQueueSubmit = sym(*const fn (VkQueue, u32, ?*const VkSubmitInfo, ?*anyopaque) callconv(.c) VkResult, &lib, "vkQueueSubmit"),
        .vkQueueWaitIdle = sym(*const fn (VkQueue) callconv(.c) VkResult, &lib, "vkQueueWaitIdle"),
        .vkMapMemory = sym(*const fn (VkDevice, VkDeviceMemory, u64, u64, u32, ?*?*anyopaque) callconv(.c) VkResult, &lib, "vkMapMemory"),
        .vkUnmapMemory = sym(*const fn (VkDevice, VkDeviceMemory) callconv(.c) void, &lib, "vkUnmapMemory"),
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
    const spv_bytes = @embedFile("onehot.spv");
    var code: [spv_bytes.len / 4]u32 = undefined;
    for (0..code.len) |i| code[i] = std.mem.readInt(u32, spv_bytes[i * 4 ..][0..4], .little);

    const app = VkApplicationInfo{ .sType = S_APP, .pNext = null, .pApplicationName = "probe3", .applicationVersion = 1, .pEngineName = "probe3", .engineVersion = 1, .apiVersion = API };
    const instance_info = VkInstanceCreateInfo{ .sType = S_INST, .pNext = null, .flags = 0, .pApplicationInfo = &app, .enabledLayerCount = 0, .ppEnabledLayerNames = null, .enabledExtensionCount = 0, .ppEnabledExtensionNames = null };

    var vk = try load();
    var instance: VkInstance = undefined;
    var rc = vk.vkCreateInstance(&instance_info, null, &instance);
    std.debug.print("instance rc={d}\n", .{rc});

    var count: u32 = 0;
    rc = vk.vkEnumeratePhysicalDevices(instance, &count, null);
    var devices: [4]VkPhysicalDevice = undefined;
    rc = vk.vkEnumeratePhysicalDevices(instance, &count, &devices);
    const physical = devices[0];

    var family_count: u32 = 0;
    vk.vkGetPhysicalDeviceQueueFamilyProperties(physical, &family_count, null);
    var families: [8]VkQueueFamilyProperties = undefined;
    vk.vkGetPhysicalDeviceQueueFamilyProperties(physical, &family_count, &families);

    const family: u32 = 0;
    std.debug.print("family={d} flags={x}\n", .{ family, families[0].queueFlags });

    const priority: f32 = 1.0;
    const qi = VkDeviceQueueCreateInfo{ .sType = S_Q, .pNext = null, .flags = 0, .queueFamilyIndex = family, .queueCount = 1, .pQueuePriorities = &priority };
    const di = VkDeviceCreateInfo{ .sType = S_DEV, .pNext = null, .flags = 0, .queueCreateInfoCount = 1, .pQueueCreateInfos = &qi, .enabledLayerCount = 0, .ppEnabledLayerNames = null, .enabledExtensionCount = 0, .ppEnabledExtensionNames = null, .pEnabledFeatures = null };
    var device: VkDevice = undefined;
    rc = vk.vkCreateDevice(physical, &di, null, &device);
    std.debug.print("device rc={d}\n", .{rc});
    var queue: VkQueue = undefined;
    vk.vkGetDeviceQueue(device, family, 0, &queue);

    const image_info = VkImageCreateInfo{ .sType = S_IMG, .pNext = null, .flags = 0, .imageType = 1, .format = 37, .extentWidth = 8, .extentHeight = 8, .extentDepth = 1, .mipLevels = 1, .arrayLayers = 1, .samples = 1, .tiling = 0, .usage = 0x0000000F, .sharingMode = 0, .queueFamilyIndexCount = 0, .pQueueFamilyIndices = null, .initialLayout = 7 };
    var image: VkImage = undefined;
    rc = vk.vkCreateImage(device, &image_info, null, &image);
    std.debug.print("image rc={d}\n", .{rc});
    var reqs: VkMemoryRequirements = undefined;
    vk.vkGetImageMemoryRequirements(device, image, &reqs);
    var mem_props: VkPhysicalDeviceMemoryProperties = undefined;
    vk.vkGetPhysicalDeviceMemoryProperties(physical, &mem_props);
    std.debug.print("image reqs size={d} align={d} typeBits={x}\n", .{ reqs.size, reqs.alignment, reqs.memoryTypeBits });
    var memory_type_index: u32 = 0;
    while (memory_type_index < mem_props.memoryTypeCount) : (memory_type_index += 1) {
        std.debug.print("mtype[{d}] flags={x} heap={d}\n", .{ memory_type_index, mem_props.memoryTypes[memory_type_index].propertyFlags, mem_props.memoryTypes[memory_type_index].heapIndex });
    }
    const mem_type = findMemoryType(&mem_props, reqs.memoryTypeBits, 0x00000001) orelse return error.NoLocal;
    std.debug.print("chosen image mem type={d}\n", .{mem_type});
    const image_alloc = VkMemoryAllocateInfo{ .sType = S_MEM, .pNext = null, .allocationSize = reqs.size, .memoryTypeIndex = mem_type };
    var image_memory: VkDeviceMemory = undefined;
    rc = vk.vkAllocateMemory(device, &image_alloc, null, &image_memory);
    std.debug.print("image memory rc={d}\n", .{rc});
    rc = vk.vkBindImageMemory(device, image, image_memory, 0);
    std.debug.print("bind image rc={d}\n", .{rc});

    const view_info = VkImageViewCreateInfo{ .sType = S_VIEW, .pNext = null, .flags = 0, .image = image, .viewType = 1, .format = 37, .componentsR = 0, .componentsG = 0, .componentsB = 0, .componentsA = 0, .subresourceRange = .{ .aspectMask = 1, .baseMipLevel = 0, .levelCount = 1, .baseArrayLayer = 0, .layerCount = 1 } };
    var view: VkImageView = undefined;
    rc = vk.vkCreateImageView(device, &view_info, null, &view);
    std.debug.print("view rc={d}\n", .{rc});

    const shader_info = VkShaderModuleCreateInfo{ .sType = S_SHADER, .pNext = null, .flags = 0, .codeSize = spv_bytes.len, .pCode = @ptrCast(&code) };
    var shader: VkShaderModule = undefined;
    rc = vk.vkCreateShaderModule(device, &shader_info, null, &shader);
    std.debug.print("shader rc={d}\n", .{rc});

    const bindings = [_]VkDescriptorSetLayoutBinding{ .{ .binding = 0, .descriptorType = 3, .descriptorCount = 1, .stageFlags = 0x20, .pImmutableSamplers = null } };
    const dsl_info = VkDescriptorSetLayoutCreateInfo{ .sType = S_DL, .pNext = null, .flags = 0, .bindingCount = 1, .pBindings = @ptrCast(&bindings) };
    var set_layout: VkDescriptorSetLayout = undefined;
    rc = vk.vkCreateDescriptorSetLayout(device, &dsl_info, null, &set_layout);

    const pool_sizes = [_]VkDescriptorPoolSize{ .{ .type = 3, .descriptorCount = 1 } };
    const pool_info = VkDescriptorPoolCreateInfo{ .sType = S_PL, .pNext = null, .flags = 0, .maxSets = 1, .poolSizeCount = 1, .pPoolSizes = @ptrCast(&pool_sizes) };
    var pool: VkDescriptorPool = undefined;
    rc = vk.vkCreateDescriptorPool(device, &pool_info, null, &pool);

    const alloc_info = VkDescriptorSetAllocateInfo{ .sType = S_ALLOC, .pNext = null, .descriptorPool = pool, .descriptorSetCount = 1, .pSetLayouts = @ptrCast(&set_layout) };
    var set: VkDescriptorSet = undefined;
    rc = vk.vkAllocateDescriptorSets(device, &alloc_info, @ptrCast(&set));

    const image_desc = VkDescriptorImageInfo{ .sampler = null, .imageView = view, .imageLayout = 1 };
    const writes = [_]VkWriteDescriptorSet{ .{ .sType = S_WRITE, .pNext = null, .dstSet = set, .dstBinding = 0, .dstArrayElement = 0, .descriptorCount = 1, .descriptorType = 3, .pImageInfo = &image_desc, .pBufferInfo = null, .pTexelBufferView = null } };
    vk.vkUpdateDescriptorSets(device, 1, @ptrCast(&writes), 0, null);

    const push_ranges = [_]VkPushConstantRange{ .{ .stageFlags = 0x20, .offset = 0, .size = 4 } };
    const pl_info = VkPipelineLayoutCreateInfo{ .sType = S_PLY, .pNext = null, .flags = 0, .setLayoutCount = 1, .pSetLayouts = @ptrCast(&set_layout), .pushConstantRangeCount = 1, .pPushConstantRanges = @ptrCast(&push_ranges) };
    var pipeline_layout: VkPipelineLayout = undefined;
    rc = vk.vkCreatePipelineLayout(device, &pl_info, null, &pipeline_layout);

    const stage = VkPipelineShaderStageCreateInfo{ .sType = S_STAGE, .pNext = null, .flags = 0, .stage = 0x20, .module = shader, .pName = "main", .pSpecializationInfo = null };
    const pipeline_info = VkComputePipelineCreateInfo{ .sType = S_COMPUTE, .pNext = null, .flags = 0, .stage = stage, .layout = pipeline_layout, .basePipelineHandle = null, .basePipelineIndex = -1 };
    var pipeline: VkPipeline = undefined;
    rc = vk.vkCreateComputePipelines(device, null, 1, &pipeline_info, null, @ptrCast(&pipeline));
    std.debug.print("pipeline rc={d}\n", .{rc});

    const cmd_pool_info = VkCommandPoolCreateInfo{ .sType = S_CMDP, .pNext = null, .flags = 1, .queueFamilyIndex = family };
    var cmd_pool: VkCommandPool = undefined;
    rc = vk.vkCreateCommandPool(device, &cmd_pool_info, null, &cmd_pool);
    std.debug.print("pool rc={d}\n", .{rc});
    const cmd_info = VkCommandBufferAllocateInfo{ .sType = S_CMDA, .pNext = null, .commandPool = cmd_pool, .level = 0, .commandBufferCount = 1 };
    var cmd: VkCommandBuffer = undefined;
    rc = vk.vkAllocateCommandBuffers(device, &cmd_info, @ptrCast(&cmd));

    const begin_info = VkCommandBufferBeginInfo{ .sType = S_BEGIN, .pNext = null, .flags = 1, .pInheritanceInfo = null };
    rc = vk.vkBeginCommandBuffer(cmd, &begin_info);

    if (false) {
        var clear_color: [4]f32 = .{ 1.0, 0.5, 0.0, 1.0 };
        const clear_range = VkSubresourceRange{ .aspectMask = 1, .baseMipLevel = 0, .levelCount = 1, .baseArrayLayer = 0, .layerCount = 1 };
        vk.vkCmdClearColorImage(cmd, image, 7, &clear_color, 1, &clear_range);
    } else {
        vk.vkCmdBindPipeline(cmd, 1, pipeline);
        vk.vkCmdBindDescriptorSets(cmd, 1, pipeline_layout, 0, 1, @ptrCast(&set), 0, null);
        vk.vkCmdDispatch(cmd, 1, 1, 1);
    }

    const staging_info = VkBufferCreateInfo{ .sType = S_BUF, .pNext = null, .flags = 0, .size = 8 * 8 * 4, .usage = 0x00000002, .sharingMode = 0, .queueFamilyIndexCount = 0, .pQueueFamilyIndices = null };
    var staging: VkBuffer = undefined;
    rc = vk.vkCreateBuffer(device, &staging_info, null, &staging);
    var staging_reqs: VkMemoryRequirements = undefined;
    vk.vkGetBufferMemoryRequirements(device, staging, &staging_reqs);
    const staging_mem_type = findMemoryType(&mem_props, staging_reqs.memoryTypeBits, 0x00000002 | 0x00000004) orelse return error.NoHost;
    const staging_alloc = VkMemoryAllocateInfo{ .sType = S_MEM, .pNext = null, .allocationSize = staging_reqs.size, .memoryTypeIndex = staging_mem_type };
    var staging_memory: VkDeviceMemory = undefined;
    rc = vk.vkAllocateMemory(device, &staging_alloc, null, &staging_memory);
    rc = vk.vkBindBufferMemory(device, staging, staging_memory, 0);

    const barrier = VkImageMemoryBarrier{ .sType = S_BARRIER, .pNext = null, .srcAccessMask = 0x00000040, .dstAccessMask = 0x00000800, .oldLayout = 1, .newLayout = 6, .srcQueueFamilyIndex = 4294967295, .dstQueueFamilyIndex = 4294967295, .image = image, .subresourceRange = .{ .aspectMask = 1, .baseMipLevel = 0, .levelCount = 1, .baseArrayLayer = 0, .layerCount = 1 } };
    vk.vkCmdPipelineBarrier(cmd, 0x00001000, 0x00001000, 0, 0, null, 0, null, 1, &barrier);

    const copy = VkBufferImageCopy{ .bufferOffset = 0, .bufferRowLength = 0, .bufferImageHeight = 0, .imageSubresource = .{ .aspectMask = 1, .mipLevel = 0, .baseArrayLayer = 0, .layerCount = 1 }, .imageOffsetX = 0, .imageOffsetY = 0, .imageOffsetZ = 0, .imageExtentWidth = 8, .imageExtentHeight = 8, .imageExtentDepth = 1 };
    vk.vkCmdCopyImageToBuffer(cmd, image, 6, staging, 1, &copy);

    rc = vk.vkEndCommandBuffer(cmd);
    const submit = VkSubmitInfo{ .sType = S_SUB, .pNext = null, .waitSemaphoreCount = 0, .pWaitSemaphores = null, .pWaitDstStageMask = null, .commandBufferCount = 1, .pCommandBuffers = @ptrCast(&cmd), .signalSemaphoreCount = 0, .pSignalSemaphores = null };
    rc = vk.vkQueueSubmit(queue, 1, &submit, null);
    rc = vk.vkQueueWaitIdle(queue);
    std.debug.print("submit rc={d} idle rc={d}\n", .{ rc, rc });

    var mapped: ?*anyopaque = null;
    rc = vk.vkMapMemory(device, staging_memory, 0, 8 * 8 * 4, 0, &mapped);
    const bytes = @as([*]const u8, @ptrCast(mapped))[0..256];
    var i: usize = 0;
    while (i < 16) : (i += 4) {
        std.debug.print("px{d}={}-{}-{}-{}\n", .{ i / 4, bytes[i], bytes[i + 1], bytes[i + 2], bytes[i + 3] });
    }
}
