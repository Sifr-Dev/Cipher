//! Minimal standalone Vulkan dispatch probe for isolating the black-image bug.
//! Run with: zig build probe2
const std = @import("std");

const VK_SUCCESS: i32 = 0;
const VK_STRUCTURE_TYPE_APPLICATION_INFO: u32 = 0;
const VK_STRUCTURE_TYPE_INSTANCE_CREATE_INFO: u32 = 1;
const VK_STRUCTURE_TYPE_DEVICE_QUEUE_CREATE_INFO: u32 = 2;
const VK_STRUCTURE_TYPE_DEVICE_CREATE_INFO: u32 = 3;
const VK_STRUCTURE_TYPE_SUBMIT_INFO: u32 = 4;
const VK_STRUCTURE_TYPE_MEMORY_ALLOCATE_INFO: u32 = 5;
const VK_STRUCTURE_TYPE_BUFFER_CREATE_INFO: u32 = 12;
const VK_STRUCTURE_TYPE_IMAGE_CREATE_INFO: u32 = 14;
const VK_STRUCTURE_TYPE_IMAGE_VIEW_CREATE_INFO: u32 = 15;
const VK_STRUCTURE_TYPE_SHADER_MODULE_CREATE_INFO: u32 = 16;
const VK_STRUCTURE_TYPE_PIPELINE_SHADER_STAGE_CREATE_INFO: u32 = 18;
const VK_STRUCTURE_TYPE_PIPELINE_LAYOUT_CREATE_INFO: u32 = 30;
const VK_STRUCTURE_TYPE_DESCRIPTOR_SET_LAYOUT_CREATE_INFO: u32 = 32;
const VK_STRUCTURE_TYPE_DESCRIPTOR_POOL_CREATE_INFO: u32 = 33;
const VK_STRUCTURE_TYPE_DESCRIPTOR_SET_ALLOCATE_INFO: u32 = 34;
const VK_STRUCTURE_TYPE_WRITE_DESCRIPTOR_SET: u32 = 35;
const VK_STRUCTURE_TYPE_COMPUTE_PIPELINE_CREATE_INFO: u32 = 29;
const VK_STRUCTURE_TYPE_COMMAND_POOL_CREATE_INFO: u32 = 39;
const VK_STRUCTURE_TYPE_COMMAND_BUFFER_ALLOCATE_INFO: u32 = 40;
const VK_STRUCTURE_TYPE_COMMAND_BUFFER_BEGIN_INFO: u32 = 42;
const VK_STRUCTURE_TYPE_IMAGE_MEMORY_BARRIER: u32 = 45;

const VK_FORMAT_R8G8B8A8_UNORM: u32 = 37;
const VK_IMAGE_TYPE_2D: u32 = 1;
const VK_SAMPLE_COUNT_1_BIT: u32 = 1;
const VK_IMAGE_TILING_OPTIMAL: u32 = 0;
const VK_IMAGE_LAYOUT_GENERAL: u32 = 1;
const VK_IMAGE_LAYOUT_TRANSFER_SRC_OPTIMAL: u32 = 6;
const VK_IMAGE_LAYOUT_UNDEFINED: u32 = 0;
const VK_IMAGE_USAGE_TRANSFER_SRC_BIT: u32 = 0x00000001;
const VK_IMAGE_USAGE_STORAGE_BIT: u32 = 0x00000008;
const VK_SHARING_MODE_EXCLUSIVE: u32 = 0;
const VK_IMAGE_ASPECT_COLOR_BIT: u32 = 0x00000001;
const VK_IMAGE_VIEW_TYPE_2D: u32 = 1;
const VK_MEMORY_PROPERTY_DEVICE_LOCAL_BIT: u32 = 0x00000001;
const VK_MEMORY_PROPERTY_HOST_VISIBLE_BIT: u32 = 0x00000002;
const VK_MEMORY_PROPERTY_HOST_COHERENT_BIT: u32 = 0x00000004;
const VK_QUEUE_COMPUTE_BIT: u32 = 0x00000002;
const VK_COMMAND_POOL_CREATE_TRANSIENT_BIT: u32 = 0x00000001;
const VK_COMMAND_BUFFER_USAGE_ONE_TIME_SUBMIT_BIT: u32 = 0x00000001;
const VK_SHADER_STAGE_COMPUTE_BIT: u32 = 0x00000020;
const VK_PIPELINE_BIND_POINT_COMPUTE: u32 = 1;
const VK_PIPELINE_STAGE_COMPUTE_SHADER_BIT: u32 = 0x00000800;
const VK_PIPELINE_STAGE_TRANSFER_BIT: u32 = 0x00001000;
const VK_ACCESS_SHADER_WRITE_BIT: u32 = 0x00000040;
const VK_ACCESS_TRANSFER_READ_BIT: u32 = 0x00000800;
const VK_DESCRIPTOR_TYPE_STORAGE_IMAGE: u32 = 3;
const VK_QUEUED_FAMILY_IGNORED: u32 = 0xffffffff;
const API_VERSION_1_2: u32 = (0 << 29) | (1 << 22) | (2 << 12);

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

const VkSubresourceRange = extern struct {
    aspectMask: u32,
    baseMipLevel: u32,
    levelCount: u32,
    baseArrayLayer: u32,
    layerCount: u32,
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

const VkImageViewCreateInfo = extern struct {
    sType: u32,
    pNext: ?*const anyopaque,
    flags: u32,
    image: VkImage,
    viewType: u32,
    format: u32,
    componentsR: u32,
    componentsG: u32,
    componentsB: u32,
    componentsA: u32,
    subresourceRange: VkSubresourceRange,
};

const VkShaderModuleCreateInfo = extern struct {
    sType: u32,
    pNext: ?*const anyopaque,
    flags: u32,
    codeSize: usize,
    pCode: ?[*]const u32,
};

const VkPipelineShaderStageCreateInfo = extern struct {
    sType: u32,
    pNext: ?*const anyopaque,
    flags: u32,
    stage: u32,
    module: VkShaderModule,
    pName: [*:0]const u8,
    pSpecializationInfo: ?*const anyopaque,
};

const VkPushConstantRange = extern struct {
    stageFlags: u32,
    offset: u32,
    size: u32,
};

const VkPipelineLayoutCreateInfo = extern struct {
    sType: u32,
    pNext: ?*const anyopaque,
    flags: u32,
    setLayoutCount: u32,
    pSetLayouts: ?*const VkDescriptorSetLayout,
    pushConstantRangeCount: u32,
    pPushConstantRanges: ?*const VkPushConstantRange,
};

const VkDescriptorSetLayoutBinding = extern struct {
    binding: u32,
    descriptorType: u32,
    descriptorCount: u32,
    stageFlags: u32,
    pImmutableSamplers: ?*const anyopaque,
};

const VkDescriptorSetLayoutCreateInfo = extern struct {
    sType: u32,
    pNext: ?*const anyopaque,
    flags: u32,
    bindingCount: u32,
    pBindings: ?*const VkDescriptorSetLayoutBinding,
};

const VkDescriptorPoolSize = extern struct {
    type: u32,
    descriptorCount: u32,
};

const VkDescriptorPoolCreateInfo = extern struct {
    sType: u32,
    pNext: ?*const anyopaque,
    flags: u32,
    maxSets: u32,
    poolSizeCount: u32,
    pPoolSizes: ?*const VkDescriptorPoolSize,
};

const VkDescriptorSetAllocateInfo = extern struct {
    sType: u32,
    pNext: ?*const anyopaque,
    descriptorPool: VkDescriptorPool,
    descriptorSetCount: u32,
    pSetLayouts: ?*const VkDescriptorSetLayout,
};

const VkDescriptorImageInfo = extern struct {
    sampler: ?*anyopaque,
    imageView: VkImageView,
    imageLayout: u32,
};

const VkWriteDescriptorSet = extern struct {
    sType: u32,
    pNext: ?*const anyopaque,
    dstSet: VkDescriptorSet,
    dstBinding: u32,
    dstArrayElement: u32,
    descriptorCount: u32,
    descriptorType: u32,
    pImageInfo: ?*const VkDescriptorImageInfo,
    pBufferInfo: ?*const anyopaque,
    pTexelBufferView: ?*const anyopaque,
};

const VkComputePipelineCreateInfo = extern struct {
    sType: u32,
    pNext: ?*const anyopaque,
    flags: u32,
    stage: VkPipelineShaderStageCreateInfo,
    layout: VkPipelineLayout,
    basePipelineHandle: ?*anyopaque,
    basePipelineIndex: i32,
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

const VkCommandBufferBeginInfo = extern struct {
    sType: u32,
    pNext: ?*const anyopaque,
    flags: u32,
    pInheritanceInfo: ?*const anyopaque,
};

const VkSubmitInfo = extern struct {
    sType: u32,
    pNext: ?*const anyopaque,
    waitSemaphoreCount: u32,
    pWaitSemaphores: ?*const anyopaque,
    pWaitDstStageMask: ?*const u32,
    commandBufferCount: u32,
    pCommandBuffers: ?*const VkCommandBuffer,
    signalSemaphoreCount: u32,
    pSignalSemaphores: ?*const anyopaque,
};

const VkBufferImageCopy = extern struct {
    bufferOffset: u64,
    bufferRowLength: u32,
    bufferImageHeight: u32,
    imageSubresource: VkSubresourceRange,
    imageOffsetX: i32,
    imageOffsetY: i32,
    imageOffsetZ: i32,
    imageExtentWidth: u32,
    imageExtentHeight: u32,
    imageExtentDepth: u32,
};

const VkImageMemoryBarrier = extern struct {
    sType: u32,
    pNext: ?*const anyopaque,
    srcAccessMask: u32,
    dstAccessMask: u32,
    oldLayout: u32,
    newLayout: u32,
    srcQueueFamilyIndex: u32,
    dstQueueFamilyIndex: u32,
    image: VkImage,
    subresourceRange: VkSubresourceRange,
};

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
    vkCmdPushConstants: *const fn (VkCommandBuffer, VkPipelineLayout, u32, u32, u32, ?*const anyopaque) callconv(.c) void,
    vkCmdFillBuffer: *const fn (VkCommandBuffer, VkBuffer, u64, u64, u32) callconv(.c) void,
    vkCmdCopyBufferToImage: *const fn (VkCommandBuffer, VkBuffer, VkImage, u32, u32, ?*const VkBufferImageCopy) callconv(.c) void,
    vkCmdClearColorImage: *const fn (VkCommandBuffer, VkImage, u32, ?*const anyopaque, u32, ?*const anyopaque) callconv(.c) void,
    vkCmdDispatch: *const fn (VkCommandBuffer, u32, u32, u32) callconv(.c) void,
    vkCmdPipelineBarrier: *const fn (VkCommandBuffer, u32, u32, u32, u32, ?*const anyopaque, u32, ?*const anyopaque, u32, ?*const VkImageMemoryBarrier) callconv(.c) void,
    vkCmdCopyImageToBuffer: *const fn (VkCommandBuffer, VkImage, u32, VkBuffer, u32, ?*const VkBufferImageCopy) callconv(.c) void,
    vkQueueSubmit: *const fn (VkQueue, u32, ?*const VkSubmitInfo, ?*anyopaque) callconv(.c) VkResult,
    vkQueueWaitIdle: *const fn (VkQueue) callconv(.c) VkResult,
    vkMapMemory: *const fn (VkDevice, VkDeviceMemory, u64, u64, u32, ?*?*anyopaque) callconv(.c) VkResult,
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
        .vkCmdPushConstants = sym(*const fn (VkCommandBuffer, VkPipelineLayout, u32, u32, u32, ?*const anyopaque) callconv(.c) void, &lib, "vkCmdPushConstants"),
        .vkCmdFillBuffer = sym(*const fn (VkCommandBuffer, VkBuffer, u64, u64, u32) callconv(.c) void, &lib, "vkCmdFillBuffer"),
        .vkCmdCopyBufferToImage = sym(*const fn (VkCommandBuffer, VkBuffer, VkImage, u32, u32, ?*const VkBufferImageCopy) callconv(.c) void, &lib, "vkCmdCopyBufferToImage"),
        .vkCmdClearColorImage = sym(*const fn (VkCommandBuffer, VkImage, u32, ?*const anyopaque, u32, ?*const anyopaque) callconv(.c) void, &lib, "vkCmdClearColorImage"),
        .vkCmdDispatch = sym(*const fn (VkCommandBuffer, u32, u32, u32) callconv(.c) void, &lib, "vkCmdDispatch"),
        .vkCmdPipelineBarrier = sym(*const fn (VkCommandBuffer, u32, u32, u32, u32, ?*const anyopaque, u32, ?*const anyopaque, u32, ?*const VkImageMemoryBarrier) callconv(.c) void, &lib, "vkCmdPipelineBarrier"),
        .vkCmdCopyImageToBuffer = sym(*const fn (VkCommandBuffer, VkImage, u32, VkBuffer, u32, ?*const VkBufferImageCopy) callconv(.c) void, &lib, "vkCmdCopyImageToBuffer"),
        .vkQueueSubmit = sym(*const fn (VkQueue, u32, ?*const VkSubmitInfo, ?*anyopaque) callconv(.c) VkResult, &lib, "vkQueueSubmit"),
        .vkQueueWaitIdle = sym(*const fn (VkQueue) callconv(.c) VkResult, &lib, "vkQueueWaitIdle"),
        .vkMapMemory = sym(*const fn (VkDevice, VkDeviceMemory, u64, u64, u32, ?*?*anyopaque) callconv(.c) VkResult, &lib, "vkMapMemory"),
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
    const tosp_spv_bytes = @embedFile("tosp.spv");
    var code: [tosp_spv_bytes.len / 4]u32 = undefined;
    for (0..code.len) |i| {
        code[i] = std.mem.readInt(u32, tosp_spv_bytes[i * 4 ..][0..4], .little);
    }

    const app_info = VkApplicationInfo{
        .sType = VK_STRUCTURE_TYPE_APPLICATION_INFO,
        .pNext = null,
        .pApplicationName = "probe2",
        .applicationVersion = 1,
        .pEngineName = "probe2",
        .engineVersion = 1,
        .apiVersion = API_VERSION_1_2,
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

    const vk = try load();
    var instance: VkInstance = undefined;
    var rc = vk.vkCreateInstance(&instance_info, null, &instance);
    std.debug.print("vkCreateInstance rc={d}\n", .{rc});

    var count: u32 = 0;
    rc = vk.vkEnumeratePhysicalDevices(instance, &count, null);

    var devices: [2]VkPhysicalDevice = undefined;
    rc = vk.vkEnumeratePhysicalDevices(instance, &count, &devices);
    const physical = devices[0];

    var family_count: u32 = 0;
    vk.vkGetPhysicalDeviceQueueFamilyProperties(physical, &family_count, null);
    var families: [8]VkQueueFamilyProperties = undefined;
    vk.vkGetPhysicalDeviceQueueFamilyProperties(physical, &family_count, &families);

    var i: u32 = 0;
    while (i < family_count) : (i += 1) {
        std.debug.print("family[{d}] flags={x} count={d}\n", .{ i, families[i].queueFlags, families[i].queueCount });
    }

    var compute_family: u32 = 0;
    i = 0;
    while (i < family_count) : (i += 1) {
        if ((families[i].queueFlags & 0x00000001) != 0 and (families[i].queueFlags & VK_QUEUE_COMPUTE_BIT) != 0 and (families[i].queueFlags & 0x00000004) != 0) {
            compute_family = i;
            break;
        }
    }

    const priority: f32 = 1.0;
    const queue_info = VkDeviceQueueCreateInfo{
        .sType = VK_STRUCTURE_TYPE_DEVICE_QUEUE_CREATE_INFO,
        .pNext = null,
        .flags = 0,
        .queueFamilyIndex = compute_family,
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
    rc = vk.vkCreateDevice(physical, &device_info, null, &device);
    std.debug.print("vkCreateDevice rc={d}\n", .{rc});

    var queue: VkQueue = undefined;
    vk.vkGetDeviceQueue(device, compute_family, 0, &queue);

    const image_info = VkImageCreateInfo{
        .sType = VK_STRUCTURE_TYPE_IMAGE_CREATE_INFO,
        .pNext = null,
        .flags = 0,
        .imageType = VK_IMAGE_TYPE_2D,
        .format = VK_FORMAT_R8G8B8A8_UNORM,
        .extentWidth = 8,
        .extentHeight = 8,
        .extentDepth = 1,
        .mipLevels = 1,
        .arrayLayers = 1,
        .samples = VK_SAMPLE_COUNT_1_BIT,
        .tiling = VK_IMAGE_TILING_OPTIMAL,
        .usage = 0x0000000F, // STORAGE | COLOR_ATTACHMENT | TRANSFER_DST | TRANSFER_SRC
        .sharingMode = VK_SHARING_MODE_EXCLUSIVE,
        .queueFamilyIndexCount = 0,
        .pQueueFamilyIndices = null,
        .initialLayout = VK_IMAGE_LAYOUT_UNDEFINED,
    };
    var image: VkImage = undefined;
    rc = vk.vkCreateImage(device, &image_info, null, &image);
    std.debug.print("vkCreateImage rc={d}\n", .{rc});

    var reqs: VkMemoryRequirements = undefined;
    vk.vkGetImageMemoryRequirements(device, image, &reqs);

    var mem_props: VkPhysicalDeviceMemoryProperties = undefined;
    vk.vkGetPhysicalDeviceMemoryProperties(physical, &mem_props);
    const image_memory_type = findMemoryType(&mem_props, reqs.memoryTypeBits, VK_MEMORY_PROPERTY_DEVICE_LOCAL_BIT) orelse return error.NoDeviceLocal;
    const image_alloc = VkMemoryAllocateInfo{
        .sType = VK_STRUCTURE_TYPE_MEMORY_ALLOCATE_INFO,
        .pNext = null,
        .allocationSize = reqs.size,
        .memoryTypeIndex = image_memory_type,
    };
    var image_memory: VkDeviceMemory = undefined;
    rc = vk.vkAllocateMemory(device, &image_alloc, null, &image_memory);
    std.debug.print("vkAllocateMemory image reqs rc={d}\n", .{rc});

    rc = vk.vkBindImageMemory(device, image, image_memory, 0);
    std.debug.print("vkBindImageMemory rc={d}\n", .{rc});

    const view_info = VkImageViewCreateInfo{
        .sType = VK_STRUCTURE_TYPE_IMAGE_VIEW_CREATE_INFO,
        .pNext = null,
        .flags = 0,
        .image = image,
        .viewType = VK_IMAGE_VIEW_TYPE_2D,
        .format = VK_FORMAT_R8G8B8A8_UNORM,
        .componentsR = 0,
        .componentsG = 0,
        .componentsB = 0,
        .componentsA = 0,
        .subresourceRange = .{
            .aspectMask = VK_IMAGE_ASPECT_COLOR_BIT,
            .baseMipLevel = 0,
            .levelCount = 1,
            .baseArrayLayer = 0,
            .layerCount = 1,
        },
    };
    var view: VkImageView = undefined;
    rc = vk.vkCreateImageView(device, &view_info, null, &view);
    std.debug.print("vkCreateImageView rc={d}\n", .{rc});

    const shader_info = VkShaderModuleCreateInfo{
        .sType = VK_STRUCTURE_TYPE_SHADER_MODULE_CREATE_INFO,
        .pNext = null,
        .flags = 0,
        .codeSize = tosp_spv_bytes.len,
        .pCode = @ptrCast(&code),
    };
    var shader: VkShaderModule = undefined;
    rc = vk.vkCreateShaderModule(device, &shader_info, null, &shader);
    std.debug.print("vkCreateShaderModule rc={d}\n", .{rc});

    const bindings = [_]VkDescriptorSetLayoutBinding{
        .{
            .binding = 0,
            .descriptorType = 7, // VK_DESCRIPTOR_TYPE_STORAGE_BUFFER
            .descriptorCount = 1,
            .stageFlags = VK_SHADER_STAGE_COMPUTE_BIT,
            .pImmutableSamplers = null,
        },
    };
    const layout_info = VkDescriptorSetLayoutCreateInfo{
        .sType = VK_STRUCTURE_TYPE_DESCRIPTOR_SET_LAYOUT_CREATE_INFO,
        .pNext = null,
        .flags = 0,
        .bindingCount = 1,
        .pBindings = @ptrCast(&bindings),
    };
    var set_layout: VkDescriptorSetLayout = undefined;
    rc = vk.vkCreateDescriptorSetLayout(device, &layout_info, null, &set_layout);
    std.debug.print("vkCreateDescriptorSetLayout rc={d}\n", .{rc});

    const pool_sizes = [_]VkDescriptorPoolSize{
        .{ .type = 7, .descriptorCount = 1 },
    };
    const pool_info = VkDescriptorPoolCreateInfo{
        .sType = VK_STRUCTURE_TYPE_DESCRIPTOR_POOL_CREATE_INFO,
        .pNext = null,
        .flags = 0,
        .maxSets = 1,
        .poolSizeCount = 1,
        .pPoolSizes = @ptrCast(&pool_sizes),
    };
    var pool: VkDescriptorPool = undefined;
    rc = vk.vkCreateDescriptorPool(device, &pool_info, null, &pool);
    std.debug.print("vkCreateDescriptorPool rc={d}\n", .{rc});

    const alloc_info = VkDescriptorSetAllocateInfo{
        .sType = VK_STRUCTURE_TYPE_DESCRIPTOR_SET_ALLOCATE_INFO,
        .pNext = null,
        .descriptorPool = pool,
        .descriptorSetCount = 1,
        .pSetLayouts = @ptrCast(&set_layout),
    };
    var set: VkDescriptorSet = undefined;
    rc = vk.vkAllocateDescriptorSets(device, &alloc_info, @ptrCast(&set));
    std.debug.print("vkAllocateDescriptorSets rc={d}\n", .{rc});

    const buffer_desc = VkDescriptorBufferInfo{
        .buffer = buffer,
        .offset = 0,
        .range = 4,
    };
    const writes = [_]VkWriteDescriptorSet{
        .{
            .sType = VK_STRUCTURE_TYPE_WRITE_DESCRIPTOR_SET,
            .pNext = null,
            .dstSet = set,
            .dstBinding = 0,
            .dstArrayElement = 0,
            .descriptorCount = 1,
            .descriptorType = 7, // VK_DESCRIPTOR_TYPE_STORAGE_BUFFER
            .pImageInfo = null,
            .pBufferInfo = &buffer_desc,
            .pTexelBufferView = null,
        },
    };
    vk.vkUpdateDescriptorSets(device, 1, @ptrCast(&writes), 0, null);

    const push_ranges = [_]VkPushConstantRange{
        .{ .stageFlags = VK_SHADER_STAGE_COMPUTE_BIT, .offset = 0, .size = 4 },
    };
    const layout_create = VkPipelineLayoutCreateInfo{
        .sType = VK_STRUCTURE_TYPE_PIPELINE_LAYOUT_CREATE_INFO,
        .pNext = null,
        .flags = 0,
        .setLayoutCount = 1,
        .pSetLayouts = @ptrCast(&set_layout),
        .pushConstantRangeCount = 1,
        .pPushConstantRanges = @ptrCast(&push_ranges),
    };
    var pipeline_layout: VkPipelineLayout = undefined;
    rc = vk.vkCreatePipelineLayout(device, &layout_create, null, &pipeline_layout);
    std.debug.print("vkCreatePipelineLayout rc={d}\n", .{rc});

    const spv_bytes = @embedFile("tosp.spv");
const stage = VkPipelineShaderStageCreateInfo{
        .sType = VK_STRUCTURE_TYPE_PIPELINE_SHADER_STAGE_CREATE_INFO,
        .pNext = null,
        .flags = 0,
        .stage = VK_SHADER_STAGE_COMPUTE_BIT,
        .module = shader,
        .pName = "main",
        .pSpecializationInfo = null,
    };
    const pipeline_info = VkComputePipelineCreateInfo{
        .sType = VK_STRUCTURE_TYPE_COMPUTE_PIPELINE_CREATE_INFO,
        .pNext = null,
        .flags = 0,
        .stage = stage,
        .layout = pipeline_layout,
        .basePipelineHandle = null,
        .basePipelineIndex = -1,
    };
    var pipeline: VkPipeline = undefined;
    rc = vk.vkCreateComputePipelines(device, null, 1, &pipeline_info, null, @ptrCast(&pipeline));
    std.debug.print("vkCreateComputePipelines rc={d}\n", .{rc});

    const cmd_pool_info = VkCommandPoolCreateInfo{
        .sType = VK_STRUCTURE_TYPE_COMMAND_POOL_CREATE_INFO,
        .pNext = null,
        .flags = VK_COMMAND_POOL_CREATE_TRANSIENT_BIT,
        .queueFamilyIndex = compute_family,
    };
    var cmd_pool: VkCommandPool = undefined;
    rc = vk.vkCreateCommandPool(device, &cmd_pool_info, null, &cmd_pool);
    std.debug.print("vkCreateCommandPool rc={d}\n", .{rc});

    const cmd_info = VkCommandBufferAllocateInfo{
        .sType = VK_STRUCTURE_TYPE_COMMAND_BUFFER_ALLOCATE_INFO,
        .pNext = null,
        .commandPool = cmd_pool,
        .level = 0,
        .commandBufferCount = 1,
    };
    var cmd: VkCommandBuffer = undefined;
    rc = vk.vkAllocateCommandBuffers(device, &cmd_info, @ptrCast(&cmd));
    std.debug.print("vkAllocateCommandBuffers rc={d}\n", .{rc});

    const begin_info = VkCommandBufferBeginInfo{
        .sType = VK_STRUCTURE_TYPE_COMMAND_BUFFER_BEGIN_INFO,
        .pNext = null,
        .flags = VK_COMMAND_BUFFER_USAGE_ONE_TIME_SUBMIT_BIT,
        .pInheritanceInfo = null,
    };
    rc = vk.vkBeginCommandBuffer(cmd, &begin_info);
    std.debug.print("vkBeginCommandBuffer rc={d}\n", .{rc});

    const to_general = VkImageMemoryBarrier{
        .sType = VK_STRUCTURE_TYPE_IMAGE_MEMORY_BARRIER,
        .pNext = null,
        .srcAccessMask = 0,
        .dstAccessMask = VK_ACCESS_SHADER_WRITE_BIT,
        .oldLayout = VK_IMAGE_LAYOUT_UNDEFINED,
        .newLayout = VK_IMAGE_LAYOUT_GENERAL,
        .srcQueueFamilyIndex = VK_QUEUED_FAMILY_IGNORED,
        .dstQueueFamilyIndex = VK_QUEUED_FAMILY_IGNORED,
        .image = image,
        .subresourceRange = .{
            .aspectMask = VK_IMAGE_ASPECT_COLOR_BIT,
            .baseMipLevel = 0,
            .levelCount = 1,
            .baseArrayLayer = 0,
            .layerCount = 1,
        },
    };
    vk.vkCmdPipelineBarrier(cmd, 0x00000001, VK_PIPELINE_STAGE_COMPUTE_SHADER_BIT, 0, 0, null, 0, null, 1, &to_general);

    vk.vkCmdBindPipeline(cmd, VK_PIPELINE_BIND_POINT_COMPUTE, pipeline);
    vk.vkCmdBindDescriptorSets(cmd, VK_PIPELINE_BIND_POINT_COMPUTE, pipeline_layout, 0, 1, @ptrCast(&set), 0, null);
    vk.vkCmdDispatch(cmd, 8, 8, 1);

    const general_barrier = VkImageMemoryBarrier{
        .sType = VK_STRUCTURE_TYPE_IMAGE_MEMORY_BARRIER,
        .pNext = null,
        .srcAccessMask = VK_ACCESS_SHADER_WRITE_BIT,
        .dstAccessMask = VK_ACCESS_TRANSFER_READ_BIT,
        .oldLayout = VK_IMAGE_LAYOUT_GENERAL,
        .newLayout = VK_IMAGE_LAYOUT_TRANSFER_SRC_OPTIMAL,
        .srcQueueFamilyIndex = VK_QUEUED_FAMILY_IGNORED,
        .dstQueueFamilyIndex = VK_QUEUED_FAMILY_IGNORED,
        .image = image,
        .subresourceRange = .{
            .aspectMask = VK_IMAGE_ASPECT_COLOR_BIT,
            .baseMipLevel = 0,
            .levelCount = 1,
            .baseArrayLayer = 0,
            .layerCount = 1,
        },
    };
    vk.vkCmdPipelineBarrier(cmd, VK_PIPELINE_STAGE_COMPUTE_SHADER_BIT, VK_PIPELINE_STAGE_TRANSFER_BIT, 0, 0, null, 0, null, 1, &general_barrier);

    const buffer_info = VkBufferCreateInfo{
        .sType = VK_STRUCTURE_TYPE_BUFFER_CREATE_INFO,
        .pNext = null,
        .flags = 0,
        .size = 8 * 8 * 4,
        .usage = 0x00000002, // TRANSFER_DST
        .sharingMode = VK_SHARING_MODE_EXCLUSIVE,
        .queueFamilyIndexCount = 0,
        .pQueueFamilyIndices = null,
    };
    var buffer: VkBuffer = undefined;
    rc = vk.vkCreateBuffer(device, &buffer_info, null, &buffer);

    var buffer_reqs: VkMemoryRequirements = undefined;
    vk.vkGetBufferMemoryRequirements(device, buffer, &buffer_reqs);
    const host = findMemoryType(&mem_props, buffer_reqs.memoryTypeBits, VK_MEMORY_PROPERTY_HOST_VISIBLE_BIT | VK_MEMORY_PROPERTY_HOST_COHERENT_BIT) orelse return error.NoHostMemory;
    const buffer_alloc = VkMemoryAllocateInfo{
        .sType = VK_STRUCTURE_TYPE_MEMORY_ALLOCATE_INFO,
        .pNext = null,
        .allocationSize = buffer_reqs.size,
        .memoryTypeIndex = host,
    };
    var buffer_memory: VkDeviceMemory = undefined;
    rc = vk.vkAllocateMemory(device, &buffer_alloc, null, &buffer_memory);
    rc = vk.vkBindBufferMemory(device, buffer, buffer_memory, 0);

    const barrier = VkImageMemoryBarrier{
        .sType = VK_STRUCTURE_TYPE_IMAGE_MEMORY_BARRIER,
        .pNext = null,
        .srcAccessMask = 0x00000400, // VK_ACCESS_TRANSFER_WRITE_BIT
        .dstAccessMask = VK_ACCESS_TRANSFER_READ_BIT,
        .oldLayout = 7, // TRANSFER_DST_OPTIMAL
        .newLayout = VK_IMAGE_LAYOUT_TRANSFER_SRC_OPTIMAL,
        .srcQueueFamilyIndex = VK_QUEUED_FAMILY_IGNORED,
        .dstQueueFamilyIndex = VK_QUEUED_FAMILY_IGNORED,
        .image = image,
        .subresourceRange = .{
            .aspectMask = VK_IMAGE_ASPECT_COLOR_BIT,
            .baseMipLevel = 0,
            .levelCount = 1,
            .baseArrayLayer = 0,
            .layerCount = 1,
        },
    };
    vk.vkCmdPipelineBarrier(cmd, VK_PIPELINE_STAGE_TRANSFER_BIT, VK_PIPELINE_STAGE_TRANSFER_BIT, 0, 0, null, 0, null, 1, &barrier);


    const copy = VkBufferImageCopy{
        .bufferOffset = 0,
        .bufferRowLength = 0,
        .bufferImageHeight = 0,
        .imageSubresource = .{
            .aspectMask = VK_IMAGE_ASPECT_COLOR_BIT,
            .baseMipLevel = 0,
            .levelCount = 1,
            .baseArrayLayer = 0,
            .layerCount = 1,
        },
        .imageOffsetX = 0,
        .imageOffsetY = 0,
        .imageOffsetZ = 0,
        .imageExtentWidth = 8,
        .imageExtentHeight = 8,
        .imageExtentDepth = 1,
    };
    vk.vkCmdCopyImageToBuffer(cmd, image, VK_IMAGE_LAYOUT_TRANSFER_SRC_OPTIMAL, buffer, 1, &copy);

    rc = vk.vkEndCommandBuffer(cmd);
    std.debug.print("vkEndCommandBuffer rc={d}\n", .{rc});

    const submit = VkSubmitInfo{
        .sType = VK_STRUCTURE_TYPE_SUBMIT_INFO,
        .pNext = null,
        .waitSemaphoreCount = 0,
        .pWaitSemaphores = null,
        .pWaitDstStageMask = null,
        .commandBufferCount = 1,
        .pCommandBuffers = @ptrCast(&cmd),
        .signalSemaphoreCount = 0,
        .pSignalSemaphores = null,
    };
    rc = vk.vkQueueSubmit(queue, 1, &submit, null);
    std.debug.print("vkQueueSubmit rc={d}\n", .{rc});
    rc = vk.vkQueueWaitIdle(queue);
    std.debug.print("vkQueueWaitIdle rc={d}\n", .{rc});

    var mapped: ?*anyopaque = null;
    rc = vk.vkMapMemory(device, buffer_memory, 0, 8 * 8 * 4, 0, &mapped);
    std.debug.print("vkMapMemory rc={d}\n", .{rc});
    const bytes = @as([*]const u8, @ptrCast(mapped))[0..256];
    var index: usize = 0;
    while (index < 16) : (index += 4) {
        std.debug.print("px{d}={}-{}-{}-{}\n", .{ index / 4, bytes[index], bytes[index + 1], bytes[index + 2], bytes[index + 3] });
    }
}
