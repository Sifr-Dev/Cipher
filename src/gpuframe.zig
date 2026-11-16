//! GPU-frame renderer for Cipher: draws the SIFR ring with a compute shader
//! on the host's Vulkan driver, copies it to a host-visible buffer, and
//! presents the pixels through Cipher's hand-written Wayland wire client.
//!
//! From-zero boundaries:
//!   - no libwayland, no generated protocol, no toolkit — our socket speaks
//!     the Wayland wire protocol (see src/wayland.zig)
//!   - no graphics framework — our process talks to the Vulkan driver
//!     directly through our own loader (dlopen only; link_libc provided by
//!     the build module for this file only, exactly like the ICD needs)
const std = @import("std");
const wayland = @import("wayland.zig");
const geometry = @import("geometry.zig");
const font_mod = @import("font.zig");
const atlas_mod = @import("atlas.zig");
const Instance = atlas_mod.Instance;

const WIDTH = 640;
const HEIGHT = 400;
const FRAME_COUNT = 24;
const API_VERSION_1_2: u32 = (0 << 29) | (1 << 22) | (2 << 12);

const VOID32: u32 = 0xFF04060B;
const LINE32: u32 = 0xFF2D3038;
const TEXT32: u32 = 0xFFF3F7FE;
const BRASS32: u32 = 0xFFEAB444;

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
const VK_FORMAT_R8_UNORM: u32 = 9;
const VK_IMAGE_TYPE_2D: u32 = 1;
const VK_SAMPLE_COUNT_1_BIT: u32 = 1;
const VK_IMAGE_TILING_OPTIMAL: u32 = 0;
const VK_IMAGE_LAYOUT_GENERAL: u32 = 1;
const VK_IMAGE_LAYOUT_TRANSFER_SRC_OPTIMAL: u32 = 6;
const VK_IMAGE_LAYOUT_UNDEFINED: u32 = 0;
const VK_IMAGE_LAYOUT_TRANSFER_DST_OPTIMAL: u32 = 7;
const VK_IMAGE_USAGE_TRANSFER_SRC_BIT: u32 = 0x00000001;
const VK_IMAGE_USAGE_TRANSFER_DST_BIT: u32 = 0x00000002;
const VK_IMAGE_USAGE_STORAGE_BIT: u32 = 0x00000008;
const VK_IMAGE_USAGE_COLOR_ATTACHMENT_BIT: u32 = 0x00000010;
const VK_BUFFER_USAGE_TRANSFER_SRC_BIT: u32 = 0x00000001;
const VK_BUFFER_USAGE_TRANSFER_DST_BIT: u32 = 0x00000002;
const VK_BUFFER_USAGE_STORAGE_BUFFER_BIT: u32 = 0x00000020;
const VK_ACCESS_TRANSFER_WRITE_BIT: u32 = 0x00001000;
const VK_ACCESS_SHADER_READ_BIT: u32 = 0x00000020;
const VK_DESCRIPTOR_TYPE_STORAGE_BUFFER: u32 = 7;
const VK_SHARING_MODE_EXCLUSIVE: u32 = 0;
const VK_IMAGE_ASPECT_COLOR_BIT: u32 = 0x00000001;
const VK_IMAGE_VIEW_TYPE_2D: u32 = 1;
const VK_MEMORY_PROPERTY_DEVICE_LOCAL_BIT: u32 = 0x00000001;
const VK_MEMORY_PROPERTY_HOST_VISIBLE_BIT: u32 = 0x00000002;
const VK_MEMORY_PROPERTY_HOST_COHERENT_BIT: u32 = 0x00000004;
const VK_QUEUE_GRAPHICS_BIT: u32 = 0x00000001;
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

const VkImageSubresourceRange = VkSubresourceRange;

const VkSubresourceLayers = extern struct { aspectMask: u32, mipLevel: u32, baseArrayLayer: u32, layerCount: u32 };

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

const VkDescriptorBufferInfo = extern struct {
    buffer: VkBuffer,
    offset: u64,
    range: u64,
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

const VkSpecializationInfo = extern struct {};

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
    imageSubresource: VkSubresourceLayers,
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
    vkCmdDispatch: *const fn (VkCommandBuffer, u32, u32, u32) callconv(.c) void,
    vkCmdPipelineBarrier: *const fn (VkCommandBuffer, u32, u32, u32, u32, ?*const anyopaque, u32, ?*const anyopaque, u32, ?*const VkImageMemoryBarrier) callconv(.c) void,
    vkCmdCopyImageToBuffer: *const fn (VkCommandBuffer, VkImage, u32, VkBuffer, u32, ?*const VkBufferImageCopy) callconv(.c) void,
    vkCmdCopyBufferToImage: *const fn (VkCommandBuffer, VkBuffer, VkImage, u32, u32, ?*const VkBufferImageCopy) callconv(.c) void,
    vkQueueSubmit: *const fn (VkQueue, u32, ?*const VkSubmitInfo, ?*anyopaque) callconv(.c) VkResult,
    vkQueueWaitIdle: *const fn (VkQueue) callconv(.c) VkResult,
    vkMapMemory: *const fn (VkDevice, VkDeviceMemory, u64, u64, u32, ?*?*anyopaque) callconv(.c) VkResult,
    vkUnmapMemory: *const fn (VkDevice, VkDeviceMemory) callconv(.c) void,
    vkDestroyDevice: *const fn (VkDevice, ?*const anyopaque) callconv(.c) void,
    vkDestroyInstance: *const fn (VkInstance, ?*const anyopaque) callconv(.c) void,
};

fn load() !Vulkan {
    var lib = try std.DynLib.open("libvulkan.so.1");
    errdefer lib.close();

    const vkCreateInstance = sym(*const fn (?*const VkInstanceCreateInfo, ?*const anyopaque, ?*VkInstance) callconv(.c) VkResult, &lib, "vkCreateInstance");
    const vkEnumeratePhysicalDevices = sym(*const fn (VkInstance, ?*u32, ?[*]VkPhysicalDevice) callconv(.c) VkResult, &lib, "vkEnumeratePhysicalDevices");
    const vkGetPhysicalDeviceProperties = sym(*const fn (VkPhysicalDevice, ?*VkPhysicalDeviceProperties) callconv(.c) void, &lib, "vkGetPhysicalDeviceProperties");
    const vkGetPhysicalDeviceQueueFamilyProperties = sym(*const fn (VkPhysicalDevice, ?*u32, ?[*]VkQueueFamilyProperties) callconv(.c) void, &lib, "vkGetPhysicalDeviceQueueFamilyProperties");
    const vkGetPhysicalDeviceMemoryProperties = sym(*const fn (VkPhysicalDevice, ?*VkPhysicalDeviceMemoryProperties) callconv(.c) void, &lib, "vkGetPhysicalDeviceMemoryProperties");
    const vkCreateDevice = sym(*const fn (VkPhysicalDevice, ?*const VkDeviceCreateInfo, ?*const anyopaque, ?*VkDevice) callconv(.c) VkResult, &lib, "vkCreateDevice");
    const vkGetDeviceQueue = sym(*const fn (VkDevice, u32, u32, ?*VkQueue) callconv(.c) void, &lib, "vkGetDeviceQueue");
    const vkCreateCommandPool = sym(*const fn (VkDevice, ?*const VkCommandPoolCreateInfo, ?*const anyopaque, ?*VkCommandPool) callconv(.c) VkResult, &lib, "vkCreateCommandPool");
    const vkAllocateCommandBuffers = sym(*const fn (VkDevice, ?*const VkCommandBufferAllocateInfo, ?[*]VkCommandBuffer) callconv(.c) VkResult, &lib, "vkAllocateCommandBuffers");
    const vkCreateImage = sym(*const fn (VkDevice, ?*const VkImageCreateInfo, ?*const anyopaque, ?*VkImage) callconv(.c) VkResult, &lib, "vkCreateImage");
    const vkGetImageMemoryRequirements = sym(*const fn (VkDevice, VkImage, ?*VkMemoryRequirements) callconv(.c) void, &lib, "vkGetImageMemoryRequirements");
    const vkBindImageMemory = sym(*const fn (VkDevice, VkImage, VkDeviceMemory, u64) callconv(.c) VkResult, &lib, "vkBindImageMemory");
    const vkCreateImageView = sym(*const fn (VkDevice, ?*const VkImageViewCreateInfo, ?*const anyopaque, ?*VkImageView) callconv(.c) VkResult, &lib, "vkCreateImageView");
    const vkCreateShaderModule = sym(*const fn (VkDevice, ?*const VkShaderModuleCreateInfo, ?*const anyopaque, ?*VkShaderModule) callconv(.c) VkResult, &lib, "vkCreateShaderModule");
    const vkCreateDescriptorSetLayout = sym(*const fn (VkDevice, ?*const VkDescriptorSetLayoutCreateInfo, ?*const anyopaque, ?*VkDescriptorSetLayout) callconv(.c) VkResult, &lib, "vkCreateDescriptorSetLayout");
    const vkCreateDescriptorPool = sym(*const fn (VkDevice, ?*const VkDescriptorPoolCreateInfo, ?*const anyopaque, ?*VkDescriptorPool) callconv(.c) VkResult, &lib, "vkCreateDescriptorPool");
    const vkAllocateDescriptorSets = sym(*const fn (VkDevice, ?*const VkDescriptorSetAllocateInfo, ?[*]VkDescriptorSet) callconv(.c) VkResult, &lib, "vkAllocateDescriptorSets");
    const vkUpdateDescriptorSets = sym(*const fn (VkDevice, u32, ?*const VkWriteDescriptorSet, u32, ?*const anyopaque) callconv(.c) void, &lib, "vkUpdateDescriptorSets");
    const vkCreatePipelineLayout = sym(*const fn (VkDevice, ?*const VkPipelineLayoutCreateInfo, ?*const anyopaque, ?*VkPipelineLayout) callconv(.c) VkResult, &lib, "vkCreatePipelineLayout");
    const vkCreateComputePipelines = sym(*const fn (VkDevice, ?*anyopaque, u32, ?*const VkComputePipelineCreateInfo, ?*const anyopaque, ?[*]VkPipeline) callconv(.c) VkResult, &lib, "vkCreateComputePipelines");
    const vkCreateBuffer = sym(*const fn (VkDevice, ?*const VkBufferCreateInfo, ?*const anyopaque, ?*VkBuffer) callconv(.c) VkResult, &lib, "vkCreateBuffer");
    const vkGetBufferMemoryRequirements = sym(*const fn (VkDevice, VkBuffer, ?*VkMemoryRequirements) callconv(.c) void, &lib, "vkGetBufferMemoryRequirements");
    const vkAllocateMemory = sym(*const fn (VkDevice, ?*const VkMemoryAllocateInfo, ?*const anyopaque, ?*VkDeviceMemory) callconv(.c) VkResult, &lib, "vkAllocateMemory");
    const vkBindBufferMemory = sym(*const fn (VkDevice, VkBuffer, VkDeviceMemory, u64) callconv(.c) VkResult, &lib, "vkBindBufferMemory");
    const vkBeginCommandBuffer = sym(*const fn (VkCommandBuffer, ?*const VkCommandBufferBeginInfo) callconv(.c) VkResult, &lib, "vkBeginCommandBuffer");
    const vkEndCommandBuffer = sym(*const fn (VkCommandBuffer) callconv(.c) VkResult, &lib, "vkEndCommandBuffer");
    const vkCmdBindPipeline = sym(*const fn (VkCommandBuffer, u32, VkPipeline) callconv(.c) void, &lib, "vkCmdBindPipeline");
    const vkCmdBindDescriptorSets = sym(*const fn (VkCommandBuffer, u32, VkPipelineLayout, u32, u32, ?*const VkDescriptorSet, u32, ?*const u32) callconv(.c) void, &lib, "vkCmdBindDescriptorSets");
    const vkCmdPushConstants = sym(*const fn (VkCommandBuffer, VkPipelineLayout, u32, u32, u32, ?*const anyopaque) callconv(.c) void, &lib, "vkCmdPushConstants");
    const vkCmdDispatch = sym(*const fn (VkCommandBuffer, u32, u32, u32) callconv(.c) void, &lib, "vkCmdDispatch");
    const vkCmdPipelineBarrier = sym(*const fn (VkCommandBuffer, u32, u32, u32, u32, ?*const anyopaque, u32, ?*const anyopaque, u32, ?*const VkImageMemoryBarrier) callconv(.c) void, &lib, "vkCmdPipelineBarrier");
    const vkCmdCopyImageToBuffer = sym(*const fn (VkCommandBuffer, VkImage, u32, VkBuffer, u32, ?*const VkBufferImageCopy) callconv(.c) void, &lib, "vkCmdCopyImageToBuffer");
    const vkCmdCopyBufferToImage = sym(*const fn (VkCommandBuffer, VkBuffer, VkImage, u32, u32, ?*const VkBufferImageCopy) callconv(.c) void, &lib, "vkCmdCopyBufferToImage");
    const vkQueueSubmit = sym(*const fn (VkQueue, u32, ?*const VkSubmitInfo, ?*anyopaque) callconv(.c) VkResult, &lib, "vkQueueSubmit");
    const vkQueueWaitIdle = sym(*const fn (VkQueue) callconv(.c) VkResult, &lib, "vkQueueWaitIdle");
    const vkMapMemory = sym(*const fn (VkDevice, VkDeviceMemory, u64, u64, u32, ?*?*anyopaque) callconv(.c) VkResult, &lib, "vkMapMemory");
    const vkUnmapMemory = sym(*const fn (VkDevice, VkDeviceMemory) callconv(.c) void, &lib, "vkUnmapMemory");
    const vkDestroyDevice = sym(*const fn (VkDevice, ?*const anyopaque) callconv(.c) void, &lib, "vkDestroyDevice");
    const vkDestroyInstance = sym(*const fn (VkInstance, ?*const anyopaque) callconv(.c) void, &lib, "vkDestroyInstance");

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
        .vkCreateImageView = vkCreateImageView,
        .vkCreateShaderModule = vkCreateShaderModule,
        .vkCreateDescriptorSetLayout = vkCreateDescriptorSetLayout,
        .vkCreateDescriptorPool = vkCreateDescriptorPool,
        .vkAllocateDescriptorSets = vkAllocateDescriptorSets,
        .vkUpdateDescriptorSets = vkUpdateDescriptorSets,
        .vkCreatePipelineLayout = vkCreatePipelineLayout,
        .vkCreateComputePipelines = vkCreateComputePipelines,
        .vkCreateBuffer = vkCreateBuffer,
        .vkGetBufferMemoryRequirements = vkGetBufferMemoryRequirements,
        .vkAllocateMemory = vkAllocateMemory,
        .vkBindBufferMemory = vkBindBufferMemory,
        .vkBeginCommandBuffer = vkBeginCommandBuffer,
        .vkEndCommandBuffer = vkEndCommandBuffer,
        .vkCmdBindPipeline = vkCmdBindPipeline,
        .vkCmdBindDescriptorSets = vkCmdBindDescriptorSets,
        .vkCmdPushConstants = vkCmdPushConstants,
        .vkCmdDispatch = vkCmdDispatch,
        .vkCmdPipelineBarrier = vkCmdPipelineBarrier,
        .vkCmdCopyImageToBuffer = vkCmdCopyImageToBuffer,
        .vkCmdCopyBufferToImage = vkCmdCopyBufferToImage,
        .vkQueueSubmit = vkQueueSubmit,
        .vkQueueWaitIdle = vkQueueWaitIdle,
        .vkMapMemory = vkMapMemory,
        .vkUnmapMemory = vkUnmapMemory,
        .vkDestroyDevice = vkDestroyDevice,
        .vkDestroyInstance = vkDestroyInstance,
    };
}

fn sym(comptime T: type, lib: *std.DynLib, comptime name: [:0]const u8) T {
    return lib.lookup(T, name) orelse @panic("missing vulkan symbol " ++ name);
}

fn findMemoryType(props: *const VkPhysicalDeviceMemoryProperties, filter: u32, required: u32) ?u32 {
    var i: u32 = 0;
    while (i < props.memoryTypeCount) : (i += 1) {
        if ((props.memoryTypes[i].propertyFlags & required) == required and (filter & (@as(u32, 1) << @intCast(i))) != 0) return i;
    }
    return null;
}

const State = struct {
    vk: Vulkan,
    debug_const: bool = false,
    instance: VkInstance = undefined,
    device: VkDevice = undefined,
    queue: VkQueue = undefined,
    physical: VkPhysicalDevice = undefined,
    compute_family: u32 = 0,
    image: VkImage = undefined,
    image_view: VkImageView = undefined,
    image_memory: VkDeviceMemory = undefined,
    staging_buffer: VkBuffer = undefined,
    staging_memory: VkDeviceMemory = undefined,
    staging_memory_size: usize = 0,
    descriptor_set: VkDescriptorSet = undefined,
    pipeline_layout: VkPipelineLayout = undefined,
    pipeline: VkPipeline = undefined,
    command_pool: VkCommandPool = undefined,
    command_buffer: VkCommandBuffer = undefined,
    descriptor_pool: VkDescriptorPool = undefined,
    atlas_image: VkImage = undefined,
    atlas_image_view: VkImageView = undefined,
    atlas_memory: VkDeviceMemory = undefined,
    text_pipeline_layout: VkPipelineLayout = undefined,
    text_pipeline: VkPipeline = undefined,
    text_descriptor_set: VkDescriptorSet = undefined,
    text_descriptor_pool: VkDescriptorPool = undefined,
    glyph_buffer: VkBuffer = undefined,
    glyph_memory: VkDeviceMemory = undefined,
    glyph_mapped: ?[*]Instance = null,
    font_bytes: []const u8 = &.{},
    font_parsed: font_mod.Font = undefined,

    fn destroy(self: *State) void {
        _ = self.vk.vkDestroyDevice(self.device, null);
        _ = self.vk.vkDestroyInstance(self.instance, null);
        self.vk.lib.close();
    }
};

fn createVulkanObjects(state: *State) !void {
    const app_info = VkApplicationInfo{
        .sType = VK_STRUCTURE_TYPE_APPLICATION_INFO,
        .pNext = null,
        .pApplicationName = "cipher",
        .applicationVersion = 1,
        .pEngineName = "cipher",
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

    var instance: VkInstance = undefined;
    if (state.vk.vkCreateInstance(&instance_info, null, &instance) != VK_SUCCESS) {
        return error.CreateInstanceFailed;
    }
    state.instance = instance;

    var count: u32 = 0;
    if (state.vk.vkEnumeratePhysicalDevices(instance, &count, null) != VK_SUCCESS or count == 0) {
        return error.NoPhysicalDevices;
    }
    var devices: [4]VkPhysicalDevice = undefined;
    if (state.vk.vkEnumeratePhysicalDevices(instance, &count, &devices) != VK_SUCCESS) {
        return error.EnumerateDevicesFailed;
    }
    state.physical = devices[0];

    var family_count: u32 = 0;
    state.vk.vkGetPhysicalDeviceQueueFamilyProperties(state.physical, &family_count, null);
    var families: [16]VkQueueFamilyProperties = undefined;
    state.vk.vkGetPhysicalDeviceQueueFamilyProperties(state.physical, &family_count, &families);

    var i: u32 = 0;
    while (i < family_count) : (i += 1) {
        if ((families[i].queueFlags & VK_QUEUE_COMPUTE_BIT) != 0) {
            state.compute_family = i;
            break;
        }
    }

    const priority: f32 = 1.0;
    const queue_info = VkDeviceQueueCreateInfo{
        .sType = VK_STRUCTURE_TYPE_DEVICE_QUEUE_CREATE_INFO,
        .pNext = null,
        .flags = 0,
        .queueFamilyIndex = state.compute_family,
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
    if (state.vk.vkCreateDevice(state.physical, &device_info, null, &device) != VK_SUCCESS) {
        return error.CreateDeviceFailed;
    }
    state.device = device;

    var queue: VkQueue = undefined;
    state.vk.vkGetDeviceQueue(device, state.compute_family, 0, &queue);
    state.queue = queue;
}

fn createStorageImage(state: *State) !void {
    const image_info = VkImageCreateInfo{
        .sType = VK_STRUCTURE_TYPE_IMAGE_CREATE_INFO,
        .pNext = null,
        .flags = 0,
        .imageType = VK_IMAGE_TYPE_2D,
        .format = VK_FORMAT_R8G8B8A8_UNORM,
        .extentWidth = WIDTH,
        .extentHeight = HEIGHT,
        .extentDepth = 1,
        .mipLevels = 1,
        .arrayLayers = 1,
        .samples = VK_SAMPLE_COUNT_1_BIT,
        .tiling = VK_IMAGE_TILING_OPTIMAL,
        .usage = VK_IMAGE_USAGE_STORAGE_BIT | VK_IMAGE_USAGE_TRANSFER_SRC_BIT,
        .sharingMode = VK_SHARING_MODE_EXCLUSIVE,
        .queueFamilyIndexCount = 0,
        .pQueueFamilyIndices = null,
        .initialLayout = VK_IMAGE_LAYOUT_GENERAL,
    };
    var image: VkImage = undefined;
    if (state.vk.vkCreateImage(state.device, &image_info, null, &image) != VK_SUCCESS) {
        return error.CreateImageFailed;
    }
    state.image = image;

    var reqs: VkMemoryRequirements = undefined;
    state.vk.vkGetImageMemoryRequirements(state.device, image, &reqs);

    var mem_props: VkPhysicalDeviceMemoryProperties = undefined;
    state.vk.vkGetPhysicalDeviceMemoryProperties(state.physical, &mem_props);
    const image_memory_type = findMemoryType(&mem_props, reqs.memoryTypeBits, VK_MEMORY_PROPERTY_DEVICE_LOCAL_BIT) orelse return error.NoDeviceLocalMemory;
    const alloc = VkMemoryAllocateInfo{
        .sType = VK_STRUCTURE_TYPE_MEMORY_ALLOCATE_INFO,
        .pNext = null,
        .allocationSize = reqs.size,
        .memoryTypeIndex = image_memory_type,
    };
    var memory: VkDeviceMemory = undefined;
    if (state.vk.vkAllocateMemory(state.device, &alloc, null, &memory) != VK_SUCCESS) {
        return error.AllocateImageMemoryFailed;
    }
    state.image_memory = memory;
    if (state.vk.vkBindImageMemory(state.device, image, memory, 0) != VK_SUCCESS) {
        return error.BindImageMemoryFailed;
    }

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
    if (state.vk.vkCreateImageView(state.device, &view_info, null, &view) != VK_SUCCESS) {
        return error.CreateImageViewFailed;
    }
    state.image_view = view;
}

fn createStagingBuffer(state: *State) !void {
    const size: u64 = WIDTH * HEIGHT * 4;
    const info = VkBufferCreateInfo{
        .sType = VK_STRUCTURE_TYPE_BUFFER_CREATE_INFO,
        .pNext = null,
        .flags = 0,
        .size = size,
        .usage = 0x00000002, // VK_BUFFER_USAGE_TRANSFER_DST_BIT
        .sharingMode = VK_SHARING_MODE_EXCLUSIVE,
        .queueFamilyIndexCount = 0,
        .pQueueFamilyIndices = null,
    };
    var buffer: VkBuffer = undefined;
    if (state.vk.vkCreateBuffer(state.device, &info, null, &buffer) != VK_SUCCESS) {
        return error.CreateBufferFailed;
    }
    state.staging_buffer = buffer;

    var reqs: VkMemoryRequirements = undefined;
    state.vk.vkGetBufferMemoryRequirements(state.device, buffer, &reqs);
    state.staging_memory_size = @intCast(reqs.size);

    var mem_props: VkPhysicalDeviceMemoryProperties = undefined;
    state.vk.vkGetPhysicalDeviceMemoryProperties(state.physical, &mem_props);
    const host = findMemoryType(&mem_props, reqs.memoryTypeBits, VK_MEMORY_PROPERTY_HOST_VISIBLE_BIT | VK_MEMORY_PROPERTY_HOST_COHERENT_BIT) orelse return error.NoHostMemory;
    const alloc = VkMemoryAllocateInfo{
        .sType = VK_STRUCTURE_TYPE_MEMORY_ALLOCATE_INFO,
        .pNext = null,
        .allocationSize = reqs.size,
        .memoryTypeIndex = host,
    };
    var memory: VkDeviceMemory = undefined;
    if (state.vk.vkAllocateMemory(state.device, &alloc, null, &memory) != VK_SUCCESS) {
        return error.AllocateStagingFailed;
    }
    state.staging_memory = memory;
    if (state.vk.vkBindBufferMemory(state.device, buffer, memory, 0) != VK_SUCCESS) {
        return error.BindStagingFailed;
    }
}

const ring_spv_bytes = @embedFile("ring.spv");
const const_spv_bytes = @embedFile("const.spv");
const one_spv_bytes = @embedFile("one.spv");
const text_spv_bytes = @embedFile("text.spv");

const TextPush = extern struct {
    r: f32,
    g: f32,
    b: f32,
    a: f32,
    count: u32,
    frame_width: u32,
    frame_height: u32,
    cell: u32,
};

fn readFdAlloc(allocator: std.mem.Allocator, fd: i32) ![]u8 {
    defer _ = std.os.linux.close(fd);
    const cap: usize = 1 << 20;
    const buf = try allocator.alloc(u8, cap);
    var total: usize = 0;
    while (total < buf.len) {
        const rc = std.os.linux.read(fd, buf[total..].ptr, buf.len - total);
        const n = @as(i64, @bitCast(rc));
        if (n < 0) {
            allocator.free(buf);
            return error.ReadFailed;
        }
        if (n == 0) break;
        total += @intCast(n);
    }
    const exact = try allocator.dupe(u8, buf[0..total]);
    allocator.free(buf);
    return exact;
}

fn readFontFileAlloc(allocator: std.mem.Allocator) ![]u8 {
    const local: [:0]const u8 = "assets/instrument-sans.ttf";
    const absolute: [:0]const u8 = "/home/sifr/Projects/portfolio-improvement/repositories/sifr-native/assets/instrument-sans.ttf";
    const fd_rc = std.os.linux.openat(std.os.linux.AT.FDCWD, local, .{ .ACCMODE = .RDONLY }, 0);
    if (@as(i64, @bitCast(fd_rc)) >= 0) return readFdAlloc(allocator, @intCast(fd_rc));
    const fd2 = std.os.linux.openat(std.os.linux.AT.FDCWD, absolute, .{ .ACCMODE = .RDONLY }, 0);
    if (@as(i64, @bitCast(fd2)) < 0) return error.FontNotFound;
    return readFdAlloc(allocator, @intCast(fd2));
}

fn createAtlasAndText(state: *State) !void {
    const allocator = std.heap.page_allocator;

    const bytes = try readFontFileAlloc(allocator);
    state.font_bytes = bytes;
    state.font_parsed = font_mod.Font.parse(bytes) catch return error.FontParseFailed;

    var atlas = atlas_mod.Atlas.init(allocator);
    try atlas.build(&state.font_parsed, allocator);

    // Staging buffer for the atlas pixels (kept alive for process lifetime).
    const staging_size: u64 = atlas_mod.ATLAS * atlas_mod.ATLAS;
    const staging_info = VkBufferCreateInfo{
        .sType = VK_STRUCTURE_TYPE_BUFFER_CREATE_INFO,
        .pNext = null,
        .flags = 0,
        .size = staging_size,
        .usage = VK_BUFFER_USAGE_TRANSFER_SRC_BIT,
        .sharingMode = VK_SHARING_MODE_EXCLUSIVE,
        .queueFamilyIndexCount = 0,
        .pQueueFamilyIndices = null,
    };
    var staging: VkBuffer = undefined;
    if (state.vk.vkCreateBuffer(state.device, &staging_info, null, &staging) != VK_SUCCESS) {
        return error.CreateAtlasStagingFailed;
    }

    var staging_reqs: VkMemoryRequirements = undefined;
    state.vk.vkGetBufferMemoryRequirements(state.device, staging, &staging_reqs);
    var mem_props: VkPhysicalDeviceMemoryProperties = undefined;
    state.vk.vkGetPhysicalDeviceMemoryProperties(state.physical, &mem_props);
    const staging_type = findMemoryType(&mem_props, staging_reqs.memoryTypeBits, VK_MEMORY_PROPERTY_HOST_VISIBLE_BIT | VK_MEMORY_PROPERTY_HOST_COHERENT_BIT) orelse return error.NoStagingMemory;
    const staging_alloc = VkMemoryAllocateInfo{
        .sType = VK_STRUCTURE_TYPE_MEMORY_ALLOCATE_INFO,
        .pNext = null,
        .allocationSize = staging_reqs.size,
        .memoryTypeIndex = staging_type,
    };
    var staging_memory: VkDeviceMemory = undefined;
    if (state.vk.vkAllocateMemory(state.device, &staging_alloc, null, &staging_memory) != VK_SUCCESS) {
        return error.AllocateAtlasStagingFailed;
    }
    if (state.vk.vkBindBufferMemory(state.device, staging, staging_memory, 0) != VK_SUCCESS) {
        return error.BindAtlasStagingFailed;
    }
    var atlas_mapped: ?*anyopaque = null;
    if (state.vk.vkMapMemory(state.device, staging_memory, 0, staging_size, 0, &atlas_mapped) != VK_SUCCESS) {
        return error.MapAtlasStagingFailed;
    }
    @memcpy(@as([*]u8, @ptrCast(atlas_mapped))[0..@intCast(staging_size)], &atlas.pixels);
    state.vk.vkUnmapMemory(state.device, staging_memory);

    // Atlas image.
    const image_info = VkImageCreateInfo{
        .sType = VK_STRUCTURE_TYPE_IMAGE_CREATE_INFO,
        .pNext = null,
        .flags = 0,
        .imageType = VK_IMAGE_TYPE_2D,
        .format = VK_FORMAT_R8_UNORM,
        .extentWidth = atlas_mod.ATLAS,
        .extentHeight = atlas_mod.ATLAS,
        .extentDepth = 1,
        .mipLevels = 1,
        .arrayLayers = 1,
        .samples = VK_SAMPLE_COUNT_1_BIT,
        .tiling = VK_IMAGE_TILING_OPTIMAL,
        .usage = VK_IMAGE_USAGE_TRANSFER_DST_BIT | VK_IMAGE_USAGE_STORAGE_BIT,
        .sharingMode = VK_SHARING_MODE_EXCLUSIVE,
        .queueFamilyIndexCount = 0,
        .pQueueFamilyIndices = null,
        .initialLayout = VK_IMAGE_LAYOUT_UNDEFINED,
    };
    var atlas_image: VkImage = undefined;
    if (state.vk.vkCreateImage(state.device, &image_info, null, &atlas_image) != VK_SUCCESS) {
        return error.CreateAtlasImageFailed;
    }
    state.atlas_image = atlas_image;

    var image_reqs: VkMemoryRequirements = undefined;
    state.vk.vkGetImageMemoryRequirements(state.device, atlas_image, &image_reqs);
    const image_mem_type = findMemoryType(&mem_props, image_reqs.memoryTypeBits, VK_MEMORY_PROPERTY_DEVICE_LOCAL_BIT) orelse return error.NoAtlasDeviceLocalMemory;
    const image_alloc = VkMemoryAllocateInfo{
        .sType = VK_STRUCTURE_TYPE_MEMORY_ALLOCATE_INFO,
        .pNext = null,
        .allocationSize = image_reqs.size,
        .memoryTypeIndex = image_mem_type,
    };
    var atlas_memory: VkDeviceMemory = undefined;
    if (state.vk.vkAllocateMemory(state.device, &image_alloc, null, &atlas_memory) != VK_SUCCESS) {
        return error.AllocateAtlasMemoryFailed;
    }
    state.atlas_memory = atlas_memory;
    if (state.vk.vkBindImageMemory(state.device, atlas_image, atlas_memory, 0) != VK_SUCCESS) {
        return error.BindAtlasMemoryFailed;
    }

    const view_info = VkImageViewCreateInfo{
        .sType = VK_STRUCTURE_TYPE_IMAGE_VIEW_CREATE_INFO,
        .pNext = null,
        .flags = 0,
        .image = atlas_image,
        .viewType = VK_IMAGE_VIEW_TYPE_2D,
        .format = VK_FORMAT_R8_UNORM,
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
    var atlas_view: VkImageView = undefined;
    if (state.vk.vkCreateImageView(state.device, &view_info, null, &atlas_view) != VK_SUCCESS) {
        return error.CreateAtlasViewFailed;
    }
    state.atlas_image_view = atlas_view;

    // One-time upload: UNDEFINED -> TRANSFER_DST, copy, then TRANSFER_DST -> GENERAL.
    const cmd = state.command_buffer;
    const begin_info = VkCommandBufferBeginInfo{
        .sType = VK_STRUCTURE_TYPE_COMMAND_BUFFER_BEGIN_INFO,
        .pNext = null,
        .flags = VK_COMMAND_BUFFER_USAGE_ONE_TIME_SUBMIT_BIT,
        .pInheritanceInfo = null,
    };
    if (state.vk.vkBeginCommandBuffer(cmd, &begin_info) != VK_SUCCESS) return error.BeginAtlasUploadFailed;

    const to_dst = VkImageMemoryBarrier{
        .sType = VK_STRUCTURE_TYPE_IMAGE_MEMORY_BARRIER,
        .pNext = null,
        .srcAccessMask = 0,
        .dstAccessMask = VK_ACCESS_TRANSFER_WRITE_BIT,
        .oldLayout = VK_IMAGE_LAYOUT_UNDEFINED,
        .newLayout = VK_IMAGE_LAYOUT_TRANSFER_DST_OPTIMAL,
        .srcQueueFamilyIndex = VK_QUEUED_FAMILY_IGNORED,
        .dstQueueFamilyIndex = VK_QUEUED_FAMILY_IGNORED,
        .image = atlas_image,
        .subresourceRange = .{
            .aspectMask = VK_IMAGE_ASPECT_COLOR_BIT,
            .baseMipLevel = 0,
            .levelCount = 1,
            .baseArrayLayer = 0,
            .layerCount = 1,
        },
    };
    state.vk.vkCmdPipelineBarrier(cmd, 0x00000001, VK_PIPELINE_STAGE_TRANSFER_BIT, 0, 0, null, 0, null, 1, &to_dst);

    const copy = VkBufferImageCopy{
        .bufferOffset = 0,
        .bufferRowLength = 0,
        .bufferImageHeight = 0,
        .imageSubresource = .{
            .aspectMask = VK_IMAGE_ASPECT_COLOR_BIT,
            .mipLevel = 0,
            .baseArrayLayer = 0,
            .layerCount = 1,
        },
        .imageOffsetX = 0,
        .imageOffsetY = 0,
        .imageOffsetZ = 0,
        .imageExtentWidth = atlas_mod.ATLAS,
        .imageExtentHeight = atlas_mod.ATLAS,
        .imageExtentDepth = 1,
    };
    state.vk.vkCmdCopyBufferToImage(cmd, staging, atlas_image, VK_IMAGE_LAYOUT_TRANSFER_DST_OPTIMAL, 1, &copy);

    const to_general = VkImageMemoryBarrier{
        .sType = VK_STRUCTURE_TYPE_IMAGE_MEMORY_BARRIER,
        .pNext = null,
        .srcAccessMask = VK_ACCESS_TRANSFER_WRITE_BIT,
        .dstAccessMask = VK_ACCESS_SHADER_READ_BIT,
        .oldLayout = VK_IMAGE_LAYOUT_TRANSFER_DST_OPTIMAL,
        .newLayout = VK_IMAGE_LAYOUT_GENERAL,
        .srcQueueFamilyIndex = VK_QUEUED_FAMILY_IGNORED,
        .dstQueueFamilyIndex = VK_QUEUED_FAMILY_IGNORED,
        .image = atlas_image,
        .subresourceRange = .{
            .aspectMask = VK_IMAGE_ASPECT_COLOR_BIT,
            .baseMipLevel = 0,
            .levelCount = 1,
            .baseArrayLayer = 0,
            .layerCount = 1,
        },
    };
    state.vk.vkCmdPipelineBarrier(cmd, VK_PIPELINE_STAGE_TRANSFER_BIT, VK_PIPELINE_STAGE_COMPUTE_SHADER_BIT, 0, 0, null, 0, null, 1, &to_general);

    if (state.vk.vkEndCommandBuffer(cmd) != VK_SUCCESS) return error.EndAtlasUploadFailed;
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
    if (state.vk.vkQueueSubmit(state.queue, 1, &submit, null) != VK_SUCCESS) return error.AtlasUploadSubmitFailed;
    if (state.vk.vkQueueWaitIdle(state.queue) != VK_SUCCESS) return error.AtlasUploadWaitIdleFailed;

    // Glyph instance SSBO: 16 slots of 16-byte Instance, persistently mapped.
    const glyph_buffer_size: u64 = 16 * @sizeOf(Instance);
    const glyph_info = VkBufferCreateInfo{
        .sType = VK_STRUCTURE_TYPE_BUFFER_CREATE_INFO,
        .pNext = null,
        .flags = 0,
        .size = glyph_buffer_size,
        .usage = VK_BUFFER_USAGE_STORAGE_BUFFER_BIT,
        .sharingMode = VK_SHARING_MODE_EXCLUSIVE,
        .queueFamilyIndexCount = 0,
        .pQueueFamilyIndices = null,
    };
    var glyph_buffer: VkBuffer = undefined;
    if (state.vk.vkCreateBuffer(state.device, &glyph_info, null, &glyph_buffer) != VK_SUCCESS) {
        return error.CreateGlyphBufferFailed;
    }
    state.glyph_buffer = glyph_buffer;

    var glyph_reqs: VkMemoryRequirements = undefined;
    state.vk.vkGetBufferMemoryRequirements(state.device, glyph_buffer, &glyph_reqs);
    const glyph_mem_type = findMemoryType(&mem_props, glyph_reqs.memoryTypeBits, VK_MEMORY_PROPERTY_HOST_VISIBLE_BIT | VK_MEMORY_PROPERTY_HOST_COHERENT_BIT) orelse return error.NoGlyphMemory;
    const glyph_alloc = VkMemoryAllocateInfo{
        .sType = VK_STRUCTURE_TYPE_MEMORY_ALLOCATE_INFO,
        .pNext = null,
        .allocationSize = glyph_reqs.size,
        .memoryTypeIndex = glyph_mem_type,
    };
    var glyph_memory: VkDeviceMemory = undefined;
    if (state.vk.vkAllocateMemory(state.device, &glyph_alloc, null, &glyph_memory) != VK_SUCCESS) {
        return error.AllocateGlyphMemoryFailed;
    }
    state.glyph_memory = glyph_memory;
    if (state.vk.vkBindBufferMemory(state.device, glyph_buffer, glyph_memory, 0) != VK_SUCCESS) {
        return error.BindGlyphMemoryFailed;
    }
    var glyph_mapped: ?*anyopaque = null;
    if (state.vk.vkMapMemory(state.device, glyph_memory, 0, glyph_buffer_size, 0, &glyph_mapped) != VK_SUCCESS) {
        return error.MapGlyphMemoryFailed;
    }
    state.glyph_mapped = @ptrCast(@alignCast(glyph_mapped));
}


fn createComputePipeline(state: *State) !void {
    const spv_bytes = if (state.debug_const) one_spv_bytes else ring_spv_bytes;
    if (spv_bytes.len % 4 != 0) return error.BadSpvSize;

    var code: [8192]u32 = undefined;
    for (0..spv_bytes.len / 4) |i| {
        code[i] = std.mem.readInt(u32, spv_bytes[i * 4 ..][0..4], .little);
    }
    const code_slice = code[0 .. spv_bytes.len / 4];

    const shader_info = VkShaderModuleCreateInfo{
        .sType = VK_STRUCTURE_TYPE_SHADER_MODULE_CREATE_INFO,
        .pNext = null,
        .flags = 0,
        .codeSize = spv_bytes.len,
        .pCode = @ptrCast(code_slice),
    };
    var shader: VkShaderModule = undefined;
    if (state.vk.vkCreateShaderModule(state.device, &shader_info, null, &shader) != VK_SUCCESS) {
        return error.CreateShaderModuleFailed;
    }

    const bindings = [_]VkDescriptorSetLayoutBinding{
        .{
            .binding = 0,
            .descriptorType = VK_DESCRIPTOR_TYPE_STORAGE_IMAGE,
            .descriptorCount = 1,
            .stageFlags = VK_SHADER_STAGE_COMPUTE_BIT,
            .pImmutableSamplers = null,
        },
    };
    const layout_info = VkDescriptorSetLayoutCreateInfo{
        .sType = VK_STRUCTURE_TYPE_DESCRIPTOR_SET_LAYOUT_CREATE_INFO,
        .pNext = null,
        .flags = 0,
        .bindingCount = @intCast(bindings.len),
        .pBindings = @ptrCast(&bindings),
    };
    var set_layout: VkDescriptorSetLayout = undefined;
    if (state.vk.vkCreateDescriptorSetLayout(state.device, &layout_info, null, &set_layout) != VK_SUCCESS) {
        return error.CreateDescriptorSetLayoutFailed;
    }

    const pool_sizes = [_]VkDescriptorPoolSize{
        .{ .type = VK_DESCRIPTOR_TYPE_STORAGE_IMAGE, .descriptorCount = 1 },
    };
    const pool_info = VkDescriptorPoolCreateInfo{
        .sType = VK_STRUCTURE_TYPE_DESCRIPTOR_POOL_CREATE_INFO,
        .pNext = null,
        .flags = 0,
        .maxSets = 1,
        .poolSizeCount = @intCast(pool_sizes.len),
        .pPoolSizes = @ptrCast(&pool_sizes),
    };
    var pool: VkDescriptorPool = undefined;
    if (state.vk.vkCreateDescriptorPool(state.device, &pool_info, null, &pool) != VK_SUCCESS) {
        return error.CreateDescriptorPoolFailed;
    }
    state.descriptor_pool = pool;

    const alloc_info = VkDescriptorSetAllocateInfo{
        .sType = VK_STRUCTURE_TYPE_DESCRIPTOR_SET_ALLOCATE_INFO,
        .pNext = null,
        .descriptorPool = pool,
        .descriptorSetCount = 1,
        .pSetLayouts = &set_layout,
    };
    var set: VkDescriptorSet = undefined;
    if (state.vk.vkAllocateDescriptorSets(state.device, &alloc_info, @ptrCast(&set)) != VK_SUCCESS) {
        return error.AllocateDescriptorSetFailed;
    }
    state.descriptor_set = set;

    const image_info = VkDescriptorImageInfo{
        .sampler = null,
        .imageView = state.image_view,
        .imageLayout = VK_IMAGE_LAYOUT_GENERAL,
    };
    const writes = [_]VkWriteDescriptorSet{
        .{
            .sType = VK_STRUCTURE_TYPE_WRITE_DESCRIPTOR_SET,
            .pNext = null,
            .dstSet = set,
            .dstBinding = 0,
            .dstArrayElement = 0,
            .descriptorCount = 1,
            .descriptorType = VK_DESCRIPTOR_TYPE_STORAGE_IMAGE,
            .pImageInfo = &image_info,
            .pBufferInfo = null,
            .pTexelBufferView = null,
        },
    };
    state.vk.vkUpdateDescriptorSets(state.device, @intCast(writes.len), @ptrCast(&writes), 0, null);

    const push_ranges = [_]VkPushConstantRange{
        .{ .stageFlags = VK_SHADER_STAGE_COMPUTE_BIT, .offset = 0, .size = 4 },
    };
    const layout_create = VkPipelineLayoutCreateInfo{
        .sType = VK_STRUCTURE_TYPE_PIPELINE_LAYOUT_CREATE_INFO,
        .pNext = null,
        .flags = 0,
        .setLayoutCount = 1,
        .pSetLayouts = &set_layout,
        .pushConstantRangeCount = @intCast(push_ranges.len),
        .pPushConstantRanges = @ptrCast(&push_ranges),
    };
    var pipeline_layout: VkPipelineLayout = undefined;
    if (state.vk.vkCreatePipelineLayout(state.device, &layout_create, null, &pipeline_layout) != VK_SUCCESS) {
        return error.CreatePipelineLayoutFailed;
    }
    state.pipeline_layout = pipeline_layout;

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
    if (state.vk.vkCreateComputePipelines(state.device, null, 1, &pipeline_info, null, @ptrCast(&pipeline)) != VK_SUCCESS) {
        return error.CreateComputePipelineFailed;
    }
    state.pipeline = pipeline;

    const cmd_pool_info = VkCommandPoolCreateInfo{
        .sType = VK_STRUCTURE_TYPE_COMMAND_POOL_CREATE_INFO,
        .pNext = null,
        .flags = VK_COMMAND_POOL_CREATE_TRANSIENT_BIT,
        .queueFamilyIndex = state.compute_family,
    };
    var cmd_pool: VkCommandPool = undefined;
    if (state.vk.vkCreateCommandPool(state.device, &cmd_pool_info, null, &cmd_pool) != VK_SUCCESS) {
        return error.CreateCommandPoolFailed;
    }
    state.command_pool = cmd_pool;

    const cmd_info = VkCommandBufferAllocateInfo{
        .sType = VK_STRUCTURE_TYPE_COMMAND_BUFFER_ALLOCATE_INFO,
        .pNext = null,
        .commandPool = cmd_pool,
        .level = 0,
        .commandBufferCount = 1,
    };
    var cmd: VkCommandBuffer = undefined;
    if (state.vk.vkAllocateCommandBuffers(state.device, &cmd_info, @ptrCast(&cmd)) != VK_SUCCESS) {
        return error.AllocateCommandBufferFailed;
    }
    state.command_buffer = cmd;
}

fn createTextPipeline(state: *State) !void {
    const spv_bytes = text_spv_bytes;
    if (spv_bytes.len % 4 != 0) return error.BadTextSpvSize;

    var code: [8192]u32 = undefined;
    for (0..spv_bytes.len / 4) |i| {
        code[i] = std.mem.readInt(u32, spv_bytes[i * 4 ..][0..4], .little);
    }
    const code_slice = code[0 .. spv_bytes.len / 4];

    const shader_info = VkShaderModuleCreateInfo{
        .sType = VK_STRUCTURE_TYPE_SHADER_MODULE_CREATE_INFO,
        .pNext = null,
        .flags = 0,
        .codeSize = spv_bytes.len,
        .pCode = @ptrCast(code_slice),
    };
    var shader: VkShaderModule = undefined;
    if (state.vk.vkCreateShaderModule(state.device, &shader_info, null, &shader) != VK_SUCCESS) {
        return error.CreateTextShaderModuleFailed;
    }

    const bindings = [_]VkDescriptorSetLayoutBinding{
        .{ .binding = 0, .descriptorType = VK_DESCRIPTOR_TYPE_STORAGE_IMAGE, .descriptorCount = 1, .stageFlags = VK_SHADER_STAGE_COMPUTE_BIT, .pImmutableSamplers = null },
        .{ .binding = 1, .descriptorType = VK_DESCRIPTOR_TYPE_STORAGE_IMAGE, .descriptorCount = 1, .stageFlags = VK_SHADER_STAGE_COMPUTE_BIT, .pImmutableSamplers = null },
        .{ .binding = 2, .descriptorType = VK_DESCRIPTOR_TYPE_STORAGE_BUFFER, .descriptorCount = 1, .stageFlags = VK_SHADER_STAGE_COMPUTE_BIT, .pImmutableSamplers = null },
    };
    const set_layout_info = VkDescriptorSetLayoutCreateInfo{
        .sType = VK_STRUCTURE_TYPE_DESCRIPTOR_SET_LAYOUT_CREATE_INFO,
        .pNext = null,
        .flags = 0,
        .bindingCount = @intCast(bindings.len),
        .pBindings = @ptrCast(&bindings),
    };
    var set_layout: VkDescriptorSetLayout = undefined;
    if (state.vk.vkCreateDescriptorSetLayout(state.device, &set_layout_info, null, &set_layout) != VK_SUCCESS) {
        return error.CreateTextSetLayoutFailed;
    }

    const pool_sizes = [_]VkDescriptorPoolSize{
        .{ .type = VK_DESCRIPTOR_TYPE_STORAGE_IMAGE, .descriptorCount = 2 },
        .{ .type = VK_DESCRIPTOR_TYPE_STORAGE_BUFFER, .descriptorCount = 1 },
    };
    const pool_info = VkDescriptorPoolCreateInfo{
        .sType = VK_STRUCTURE_TYPE_DESCRIPTOR_POOL_CREATE_INFO,
        .pNext = null,
        .flags = 0,
        .maxSets = 1,
        .poolSizeCount = @intCast(pool_sizes.len),
        .pPoolSizes = @ptrCast(&pool_sizes),
    };
    var pool: VkDescriptorPool = undefined;
    if (state.vk.vkCreateDescriptorPool(state.device, &pool_info, null, &pool) != VK_SUCCESS) {
        return error.CreateTextDescriptorPoolFailed;
    }
    state.text_descriptor_pool = pool;

    const alloc_info = VkDescriptorSetAllocateInfo{
        .sType = VK_STRUCTURE_TYPE_DESCRIPTOR_SET_ALLOCATE_INFO,
        .pNext = null,
        .descriptorPool = pool,
        .descriptorSetCount = 1,
        .pSetLayouts = @ptrCast(&set_layout),
    };
    var set: VkDescriptorSet = undefined;
    if (state.vk.vkAllocateDescriptorSets(state.device, &alloc_info, @ptrCast(&set)) != VK_SUCCESS) {
        return error.AllocateTextDescriptorSetFailed;
    }
    state.text_descriptor_set = set;

    const frame_image_info = VkDescriptorImageInfo{
        .sampler = null,
        .imageView = state.image_view,
        .imageLayout = VK_IMAGE_LAYOUT_GENERAL,
    };
    const atlas_image_info = VkDescriptorImageInfo{
        .sampler = null,
        .imageView = state.atlas_image_view,
        .imageLayout = VK_IMAGE_LAYOUT_GENERAL,
    };
    const glyph_buffer_info = VkDescriptorBufferInfo{
        .buffer = state.glyph_buffer,
        .offset = 0,
        .range = 16 * @sizeOf(Instance),
    };
    const writes = [_]VkWriteDescriptorSet{
        .{
            .sType = VK_STRUCTURE_TYPE_WRITE_DESCRIPTOR_SET,
            .pNext = null,
            .dstSet = set,
            .dstBinding = 0,
            .dstArrayElement = 0,
            .descriptorCount = 1,
            .descriptorType = VK_DESCRIPTOR_TYPE_STORAGE_IMAGE,
            .pImageInfo = &frame_image_info,
            .pBufferInfo = null,
            .pTexelBufferView = null,
        },
        .{
            .sType = VK_STRUCTURE_TYPE_WRITE_DESCRIPTOR_SET,
            .pNext = null,
            .dstSet = set,
            .dstBinding = 1,
            .dstArrayElement = 0,
            .descriptorCount = 1,
            .descriptorType = VK_DESCRIPTOR_TYPE_STORAGE_IMAGE,
            .pImageInfo = &atlas_image_info,
            .pBufferInfo = null,
            .pTexelBufferView = null,
        },
        .{
            .sType = VK_STRUCTURE_TYPE_WRITE_DESCRIPTOR_SET,
            .pNext = null,
            .dstSet = set,
            .dstBinding = 2,
            .dstArrayElement = 0,
            .descriptorCount = 1,
            .descriptorType = VK_DESCRIPTOR_TYPE_STORAGE_BUFFER,
            .pImageInfo = null,
            .pBufferInfo = @ptrCast(&glyph_buffer_info),
            .pTexelBufferView = null,
        },
    };
    state.vk.vkUpdateDescriptorSets(state.device, @intCast(writes.len), @ptrCast(&writes), 0, null);

    const push_ranges = [_]VkPushConstantRange{
        .{ .stageFlags = VK_SHADER_STAGE_COMPUTE_BIT, .offset = 0, .size = @sizeOf(TextPush) },
    };
    const layout_create = VkPipelineLayoutCreateInfo{
        .sType = VK_STRUCTURE_TYPE_PIPELINE_LAYOUT_CREATE_INFO,
        .pNext = null,
        .flags = 0,
        .setLayoutCount = 1,
        .pSetLayouts = @ptrCast(&set_layout),
        .pushConstantRangeCount = @intCast(push_ranges.len),
        .pPushConstantRanges = @ptrCast(&push_ranges),
    };
    var pipeline_layout: VkPipelineLayout = undefined;
    if (state.vk.vkCreatePipelineLayout(state.device, &layout_create, null, &pipeline_layout) != VK_SUCCESS) {
        return error.CreateTextPipelineLayoutFailed;
    }
    state.text_pipeline_layout = pipeline_layout;

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
    if (state.vk.vkCreateComputePipelines(state.device, null, 1, &pipeline_info, null, @ptrCast(&pipeline)) != VK_SUCCESS) {
        return error.CreateTextComputePipelineFailed;
    }
    state.text_pipeline = pipeline;
}

fn writeGlyphInstances(state: *State) !u32 {
    const allocator = std.heap.page_allocator;
    const scale = @as(f64, @floatFromInt(atlas_mod.PX_EM)) / @as(f64, @floatFromInt(state.font_parsed.head.units_per_em));
    const text = "SIFR";
    // Widths for S, I, F, R in Instrument Sans (units) * scale = pixel width.
    var text_width: f64 = 0;
    var index: usize = 0;
    while (index < text.len) : (index += 1) {
        const glyph = state.font_parsed.cmapGlyph(text[index]) orelse 0;
        text_width += @as(f64, @floatFromInt(state.font_parsed.glyphAdvance(glyph))) * scale;
    }
    const pen_x = (@as(f64, @floatFromInt(WIDTH)) - text_width) / 2.0;
    const baseline_y: f64 = @as(f64, HEIGHT) - 24.0;

    const instances = try atlas_mod.Atlas.instancesFor(&state.font_parsed, allocator, text, pen_x, baseline_y);
    defer allocator.free(instances);

    const mapped = state.glyph_mapped orelse return error.GlyphBufferNotMapped;
    const count: u32 = @intCast(instances.len);
    for (0..instances.len) |i| {
        mapped[i] = instances[i];
    }
    return count;
}

fn recordFrame(state: *State, time: f32) !void {
    const cmd = state.command_buffer;

    const begin_info = VkCommandBufferBeginInfo{
        .sType = VK_STRUCTURE_TYPE_COMMAND_BUFFER_BEGIN_INFO,
        .pNext = null,
        .flags = VK_COMMAND_BUFFER_USAGE_ONE_TIME_SUBMIT_BIT,
        .pInheritanceInfo = null,
    };
    if (state.vk.vkBeginCommandBuffer(cmd, &begin_info) != VK_SUCCESS) return error.BeginCommandBufferFailed;

    state.vk.vkCmdBindPipeline(cmd, VK_PIPELINE_BIND_POINT_COMPUTE, state.pipeline);
    state.vk.vkCmdBindDescriptorSets(cmd, VK_PIPELINE_BIND_POINT_COMPUTE, state.pipeline_layout, 0, 1, @ptrCast(&state.descriptor_set), 0, null);
    state.vk.vkCmdPushConstants(cmd, state.pipeline_layout, VK_SHADER_STAGE_COMPUTE_BIT, 0, 4, @ptrCast(&time));
    state.vk.vkCmdDispatch(cmd, WIDTH / 8, HEIGHT / 8, 1);

    const glyph_count = writeGlyphInstances(state) catch 0;
    if (glyph_count > 0) {
        state.vk.vkCmdBindPipeline(cmd, VK_PIPELINE_BIND_POINT_COMPUTE, state.text_pipeline);
        state.vk.vkCmdBindDescriptorSets(cmd, VK_PIPELINE_BIND_POINT_COMPUTE, state.text_pipeline_layout, 0, 1, @ptrCast(&state.text_descriptor_set), 0, null);
        const push = TextPush{
            .r = 0.918,
            .g = 0.706,
            .b = 0.267,
            .a = 1.0,
            .count = glyph_count,
            .frame_width = WIDTH,
            .frame_height = HEIGHT,
            .cell = @intCast(atlas_mod.CELL),
        };
        state.vk.vkCmdPushConstants(cmd, state.text_pipeline_layout, VK_SHADER_STAGE_COMPUTE_BIT, 0, @sizeOf(TextPush), @ptrCast(&push));
        state.vk.vkCmdDispatch(cmd, WIDTH / 8, HEIGHT / 8, 1);
    }

    const barrier = VkImageMemoryBarrier{
        .sType = VK_STRUCTURE_TYPE_IMAGE_MEMORY_BARRIER,
        .pNext = null,
        .srcAccessMask = VK_ACCESS_SHADER_WRITE_BIT,
        .dstAccessMask = VK_ACCESS_TRANSFER_READ_BIT,
        .oldLayout = VK_IMAGE_LAYOUT_GENERAL,
        .newLayout = VK_IMAGE_LAYOUT_TRANSFER_SRC_OPTIMAL,
        .srcQueueFamilyIndex = VK_QUEUED_FAMILY_IGNORED,
        .dstQueueFamilyIndex = VK_QUEUED_FAMILY_IGNORED,
        .image = state.image,
        .subresourceRange = .{
            .aspectMask = VK_IMAGE_ASPECT_COLOR_BIT,
            .baseMipLevel = 0,
            .levelCount = 1,
            .baseArrayLayer = 0,
            .layerCount = 1,
        },
    };
    state.vk.vkCmdPipelineBarrier(cmd, VK_PIPELINE_STAGE_COMPUTE_SHADER_BIT, VK_PIPELINE_STAGE_TRANSFER_BIT, 0, 0, null, 0, null, 1, &barrier);

    const copy = VkBufferImageCopy{
        .bufferOffset = 0,
        .bufferRowLength = 0,
        .bufferImageHeight = 0,
        .imageSubresource = .{
            .aspectMask = VK_IMAGE_ASPECT_COLOR_BIT,
            .mipLevel = 0,
            .baseArrayLayer = 0,
            .layerCount = 1,
        },
        .imageOffsetX = 0,
        .imageOffsetY = 0,
        .imageOffsetZ = 0,
        .imageExtentWidth = WIDTH,
        .imageExtentHeight = HEIGHT,
        .imageExtentDepth = 1,
    };
    state.vk.vkCmdCopyImageToBuffer(cmd, state.image, VK_IMAGE_LAYOUT_TRANSFER_SRC_OPTIMAL, state.staging_buffer, 1, &copy);

    if (state.vk.vkEndCommandBuffer(cmd) != VK_SUCCESS) return error.EndCommandBufferFailed;

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
    if (state.vk.vkQueueSubmit(state.queue, 1, &submit, null) != VK_SUCCESS) return error.QueueSubmitFailed;
    if (state.vk.vkQueueWaitIdle(state.queue) != VK_SUCCESS) return error.QueueWaitIdleFailed;
}

const Reader = struct {
    data: []const u8,
    pos: usize = 0,

    fn read32(self: *Reader) u32 {
        const value = std.mem.readInt(u32, self.data[self.pos..][0..4], .little);
        self.pos += 4;
        return value;
    }

    fn str(self: *Reader) []const u8 {
        const length = self.read32();
        const result = self.data[self.pos..][0 .. length - 1];
        self.pos += length;
        while (self.pos % 4 != 0) self.pos += 1;
        return result;
    }
};

const WindowState = struct {
    ids: wayland.ObjectIds = .{},
    configured: bool = false,
    serial: u32 = 0,
    frame_index: u32 = 0,
    globals_len: usize = 0,
    globals: [8]Global = undefined,
    frame_callback: ?u32 = null,
    connection: wayland.Connection,

    const Global = struct {
        name: u32,
        interface_len: usize,
        interface: [32]u8,
        version: u32,

        fn iface(self: *const Global) []const u8 {
            return self.interface[0..self.interface_len];
        }
    };

    fn next(self: *WindowState) !wayland.Event {
        var event: wayland.Event = undefined;
        try self.connection.recv(&event);

        if (event.sender == wayland.WL_DISPLAY and event.opcode == 0) {
            var reader = Reader{ .data = event.payload() };
            const object_id = reader.read32();
            const code = reader.read32();
            const message = reader.str();
            std.debug.print("wayland error object={d} code={d}: {s}\n", .{ object_id, code, message });
            return wayland.Error.ProtocolError;
        }

        if (self.ids.wm_base != null and event.sender == self.ids.wm_base.? and event.opcode == 0) {
            var pong: [4]u8 = undefined;
            std.mem.writeInt(u32, &pong, event.read32(0), .little);
            try self.connection.send(self.ids.wm_base.?, 3, &pong);
        }

        return event;
    }

    fn collectGlobals(self: *WindowState) !void {
        while (true) {
            const event = try self.next();
            if (self.ids.registry != null and event.sender == self.ids.registry.? and event.opcode == 0) {
                var reader = Reader{ .data = event.payload() };
                const name = reader.read32();
                const interface = reader.str();
                const version = reader.read32();
                const wanted = [_][]const u8{ "wl_compositor", "wl_shm", "xdg_wm_base" };
                for (wanted) |needle| {
                    if (!std.mem.eql(u8, interface, needle)) continue;
                    if (self.findGlobal(needle) != null) continue;
                    if (self.globals_len >= self.globals.len) return error.ProtocolError;
                    const len = @min(interface.len, 32);
                    var global = Global{
                        .name = name,
                        .interface_len = len,
                        .interface = undefined,
                        .version = version,
                    };
                    @memcpy(global.interface[0..len], interface[0..len]);
                    self.globals[self.globals_len] = global;
                    self.globals_len += 1;
                    break;
                }
                continue;
            }
            if (self.ids.sync_callback != null and event.sender == self.ids.sync_callback.? and event.opcode == 0) {
                return;
            }
        }
    }

    fn findGlobal(self: *WindowState, interface: []const u8) ?*const Global {
        for (self.globals[0..self.globals_len]) |*global| {
            if (std.mem.eql(u8, global.iface(), interface)) return global;
        }
        return null;
    }

    fn bindRequired(self: *WindowState) !void {
        const binds = .{
            .{ "wl_compositor", 4 },
            .{ "wl_shm", 1 },
            .{ "xdg_wm_base", 6 },
        };

        inline for (binds) |entry| {
            const interface = entry[0];
            const cap = entry[1];
            const global = self.findGlobal(interface) orelse {
                std.debug.print("cipher: compositor did not advertise {s}\n", .{interface});
                return wayland.Error.ProtocolError;
            };
            const version = @min(global.version, cap);
            const object_id = self.ids.new();
            var cursor = wayland.Cursor{};
            cursor.writeU32(global.name);
            cursor.str(interface);
            cursor.writeU32(version);
            cursor.writeU32(object_id);
            try self.connection.send(self.ids.registry.?, 0, cursor.slice());

            if (std.mem.eql(u8, interface, "wl_compositor")) self.ids.compositor = object_id;
            if (std.mem.eql(u8, interface, "wl_shm")) self.ids.shm = object_id;
            if (std.mem.eql(u8, interface, "xdg_wm_base")) self.ids.wm_base = object_id;
        }
    }

    fn setString(self: *WindowState, object_id: u32, opcode: u16, value: []const u8) !void {
        var cursor = wayland.Cursor{};
        cursor.str(value);
        try self.connection.send(object_id, opcode, cursor.slice());
    }

    fn waitForConfigure(self: *WindowState) !void {
        while (true) {
            const event = try self.next();
            if (self.ids.xdg_surface != null and event.sender == self.ids.xdg_surface.? and event.opcode == 0) {
                self.serial = event.read32(0);
                var cursor = wayland.Cursor{};
                cursor.writeU32(self.serial);
                try self.connection.send(self.ids.xdg_surface.?, 4, cursor.slice()); // ack_configure
                self.configured = true;
                return;
            }
        }
    }

    fn requestFrameCallback(self: *WindowState) !void {
        const callback = self.ids.new();
        self.frame_callback = callback;
        var cursor = wayland.Cursor{};
        cursor.writeU32(callback);
        try self.connection.send(self.ids.surface.?, 3, cursor.slice()); // wl_surface.frame
    }

    fn waitForFrameDone(self: *WindowState) !void {
        while (true) {
            const event = try self.next();
            if (self.frame_callback != null and event.sender == self.frame_callback.? and event.opcode == 0) {
                return;
            }
        }
    }
};

pub fn main(init: std.process.Init.Minimal) !void {
    var monotonic: std.os.linux.timespec = undefined;
    _ = std.os.linux.clock_gettime(.MONOTONIC, &monotonic);

    var args_iter = std.process.Args.Iterator.init(init.args);
    _ = args_iter.next();
    var debug_const = false;
    while (args_iter.next()) |arg| {
        if (std.mem.eql(u8, arg, "--debug-const")) debug_const = true;
    }

    var vulkan_state = State{
        .vk = undefined,
        .debug_const = debug_const,
    };
    vulkan_state.vk = try load();
    defer vulkan_state.destroy();

    try createVulkanObjects(&vulkan_state);
    try createStorageImage(&vulkan_state);
    try createStagingBuffer(&vulkan_state);
    try createComputePipeline(&vulkan_state);
    try createAtlasAndText(&vulkan_state);
    try createTextPipeline(&vulkan_state);

    const runtime_dir = std.process.Environ.getPosix(init.environ, "XDG_RUNTIME_DIR") orelse "/run/user/1000";
    const display_name = std.process.Environ.getPosix(init.environ, "WAYLAND_DISPLAY") orelse "wayland-0";

    var app = WindowState{
        .connection = try wayland.Connection.connect(runtime_dir, display_name),
    };
    defer app.connection.disconnect();

    {
        app.ids.registry = app.ids.new();
        var cursor = wayland.Cursor{};
        cursor.writeU32(app.ids.registry.?);
        try app.connection.send(wayland.WL_DISPLAY, 1, cursor.slice()); // get_registry
    }
    {
        app.ids.sync_callback = app.ids.new();
        var cursor = wayland.Cursor{};
        cursor.writeU32(app.ids.sync_callback.?);
        try app.connection.send(wayland.WL_DISPLAY, 0, cursor.slice()); // sync
    }

    try app.collectGlobals();
    try app.bindRequired();

    const surface_id = app.ids.new();
    {
        var cursor = wayland.Cursor{};
        cursor.writeU32(surface_id);
        try app.connection.send(app.ids.compositor.?, 0, cursor.slice()); // create_surface
        app.ids.surface = surface_id;
    }

    var shm = try wayland.ShmBuffer.allocate(WIDTH, HEIGHT);
    defer shm.deinit();

    const pool_id = app.ids.new();
    const buffer_id = app.ids.new();
    {
        var cursor = wayland.Cursor{};
        cursor.writeU32(pool_id);
        cursor.writeI32(@intCast(shm.pixels.len));
        try app.connection.sendFd(app.ids.shm.?, 0, cursor.slice(), shm.fd); // create_pool
        app.ids.shm_pool = pool_id;
    }
    {
        var cursor = wayland.Cursor{};
        cursor.writeU32(buffer_id);
        cursor.writeI32(0);
        cursor.writeI32(WIDTH);
        cursor.writeI32(HEIGHT);
        cursor.writeI32(WIDTH * 4); // stride
        cursor.writeU32(0); // ARGB8888
        try app.connection.send(pool_id, 0, cursor.slice()); // create_buffer
        app.ids.buffer = buffer_id;
    }

    const xdg_surface_id = app.ids.new();
    {
        var cursor = wayland.Cursor{};
        cursor.writeU32(xdg_surface_id);
        cursor.writeU32(app.ids.surface.?);
        try app.connection.send(app.ids.wm_base.?, 2, cursor.slice()); // get_xdg_surface
        app.ids.xdg_surface = xdg_surface_id;
    }
    const toplevel_id = app.ids.new();
    {
        var cursor = wayland.Cursor{};
        cursor.writeU32(toplevel_id);
        try app.connection.send(app.ids.xdg_surface.?, 1, cursor.slice()); // get_toplevel
        app.ids.toplevel = toplevel_id;
    }

    try app.setString(app.ids.toplevel.?, 2, "Cipher — SIFR"); // set_title
    try app.setString(app.ids.toplevel.?, 3, "cipher"); // set_app_id

    try app.connection.send(app.ids.surface.?, 6, &.{}); // initial commit

    try app.waitForConfigure();
    std.debug.print("gpuframe: xdg toplevel configured (serial {d})\n", .{app.serial});

    const shm_pixels_u32: []u32 = @ptrCast(@alignCast(shm.pixels));
    while (app.frame_index < FRAME_COUNT) : (app.frame_index += 1) {
        const time: f32 = @as(f32, @floatFromInt(app.frame_index)) / 60.0;
        try recordFrame(&vulkan_state, time);

        var mapped: ?*anyopaque = null;
        if (vulkan_state.vk.vkMapMemory(vulkan_state.device, vulkan_state.staging_memory, 0, vulkan_state.staging_memory_size, 0, &mapped) != VK_SUCCESS) {
            return error.MapMemoryFailed;
        }
        const staging = @as([*]const u8, @ptrCast(mapped))[0..vulkan_state.staging_memory_size];

        for (0..WIDTH * HEIGHT) |i| {
            const src = staging[i * 4 ..][0..4];
            const dst = shm.pixels[i * 4 ..][0..4];
            dst[0] = src[2]; // B
            dst[1] = src[1]; // G
            dst[2] = src[0]; // R
            dst[3] = src[3]; // A
        }

        if (app.frame_index + 1 == FRAME_COUNT) {
            writePpm(staging, "/tmp/opencode/gpuframe.ppm") catch |err| {
                std.debug.print("gpuframe: ppm write failed: {}\n", .{err});
            };
        }

        vulkan_state.vk.vkUnmapMemory(vulkan_state.device, vulkan_state.staging_memory);

        _ = shm_pixels_u32;
        {
            var cursor = wayland.Cursor{};
            cursor.writeU32(app.ids.buffer.?);
            cursor.writeI32(0);
            cursor.writeI32(0);
            try app.connection.send(app.ids.surface.?, 1, cursor.slice()); // attach
        }
        {
            var cursor = wayland.Cursor{};
            cursor.writeI32(0);
            cursor.writeI32(0);
            cursor.writeI32(WIDTH);
            cursor.writeI32(HEIGHT);
            try app.connection.send(app.ids.surface.?, 2, cursor.slice()); // damage
        }
        try app.requestFrameCallback();
        try app.connection.send(app.ids.surface.?, 6, &.{}); // commit
        try app.waitForFrameDone();
    }

    if (app.ids.toplevel) |id| try app.connection.send(id, 0, &.{});
    if (app.ids.xdg_surface) |id| try app.connection.send(id, 0, &.{});
    if (app.ids.buffer) |id| try app.connection.send(id, 0, &.{});
    if (app.ids.shm_pool) |id| try app.connection.send(id, 1, &.{});
    if (app.ids.surface) |id| try app.connection.send(id, 0, &.{});

    std.debug.print("gpuframe: WAYLAND_PROTOCOL_OK frames={d}\n", .{FRAME_COUNT});
}

fn writePpm(staging: []const u8, path_c: [:0]const u8) !void {
    const fd_rc = std.os.linux.openat(std.os.linux.AT.FDCWD, path_c, .{ .ACCMODE = .WRONLY, .CREAT = true, .TRUNC = true }, 0o644);
    if (@as(i64, @bitCast(fd_rc)) < 0) return error.OpenFailed;
    const fd: i32 = @intCast(fd_rc);
    defer _ = std.os.linux.close(fd);

    const header = std.fmt.comptimePrint("P6 {} {} 255\n", .{ WIDTH, HEIGHT });
    var written: usize = 0;
    while (written < header.len) {
        const rc = std.os.linux.write(fd, header[written..].ptr, header.len - written);
        if (@as(i64, @bitCast(rc)) < 0) return error.WriteFailed;
        written += @intCast(rc);
    }

    var i: usize = 0;
    while (i < WIDTH * HEIGHT * 4) : (i += 4) {
        const pixel = [_]u8{ staging[i], staging[i + 1], staging[i + 2] };
        const rc = std.os.linux.write(fd, &pixel, 3);
        if (@as(i64, @bitCast(rc)) < 0) return error.WriteFailed;
    }
}
