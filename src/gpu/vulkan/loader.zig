//! Vulkan function loader — dlopen-based ICD binding.
//! No libvulkan dependency in the application binary.
//! Stage B of FIRST-VERTICAL-SLICE.md.
const std = @import("std");

pub const VkResult = i32;
pub const VK_SUCCESS: VkResult = 0;

pub const VkInstance = *anyopaque;
pub const VkPhysicalDevice = *anyopaque;
pub const VkDevice = *anyopaque;
pub const VkQueue = *anyopaque;
pub const VkCommandPool = *anyopaque;
pub const VkCommandBuffer = *anyopaque;
pub const VkImage = *anyopaque;
pub const VkImageView = *anyopaque;
pub const VkShaderModule = *anyopaque;
pub const VkPipelineLayout = *anyopaque;
pub const VkPipeline = *anyopaque;
pub const VkDescriptorSetLayout = *anyopaque;
pub const VkDescriptorPool = *anyopaque;
pub const VkDescriptorSet = *anyopaque;
pub const VkBuffer = *anyopaque;
pub const VkDeviceMemory = *anyopaque;
pub const VkSemaphore = *anyopaque;
pub const VkFence = *anyopaque;

pub const Vulkan = struct {
    lib: std.DynLib,

    vkCreateInstance: *const fn (?*const anyopaque, ?*const anyopaque, ?*VkInstance) callconv(.c) VkResult,
    vkEnumeratePhysicalDevices: *const fn (VkInstance, ?*u32, ?[*]VkPhysicalDevice) callconv(.c) VkResult,
    vkGetPhysicalDeviceProperties: *const fn (VkPhysicalDevice, ?*const anyopaque) callconv(.c) void,
    vkGetPhysicalDeviceQueueFamilyProperties: *const fn (VkPhysicalDevice, ?*u32, ?*const anyopaque) callconv(.c) void,
    vkGetPhysicalDeviceMemoryProperties: *const fn (VkPhysicalDevice, ?*const anyopaque) callconv(.c) void,
    vkCreateDevice: *const fn (VkPhysicalDevice, ?*const anyopaque, ?*const anyopaque, ?*VkDevice) callconv(.c) VkResult,
    vkGetDeviceQueue: *const fn (VkDevice, u32, u32, ?*VkQueue) callconv(.c) void,
    vkCreateCommandPool: *const fn (VkDevice, ?*const anyopaque, ?*const anyopaque, ?*VkCommandPool) callconv(.c) VkResult,
    vkAllocateCommandBuffers: *const fn (VkDevice, ?*const anyopaque, ?[*]VkCommandBuffer) callconv(.c) VkResult,
    vkCreateImage: *const fn (VkDevice, ?*const anyopaque, ?*const anyopaque, ?*VkImage) callconv(.c) VkResult,
    vkGetImageMemoryRequirements: *const fn (VkDevice, VkImage, ?*const anyopaque) callconv(.c) void,
    vkBindImageMemory: *const fn (VkDevice, VkImage, VkDeviceMemory, u64) callconv(.c) VkResult,
    vkCreateImageView: *const fn (VkDevice, ?*const anyopaque, ?*const anyopaque, ?*VkImageView) callconv(.c) VkResult,
    vkCreateShaderModule: *const fn (VkDevice, ?*const anyopaque, ?*const anyopaque, ?*VkShaderModule) callconv(.c) VkResult,
    vkCreateDescriptorSetLayout: *const fn (VkDevice, ?*const anyopaque, ?*const anyopaque, ?*VkDescriptorSetLayout) callconv(.c) VkResult,
    vkCreateDescriptorPool: *const fn (VkDevice, ?*const anyopaque, ?*const anyopaque, ?*VkDescriptorPool) callconv(.c) VkResult,
    vkAllocateDescriptorSets: *const fn (VkDevice, ?*const anyopaque, ?*const anyopaque, ?[*]VkDescriptorSet) callconv(.c) VkResult,
    vkUpdateDescriptorSets: *const fn (VkDevice, u32, ?*const anyopaque, u32, ?*const anyopaque) callconv(.c) void,
    vkCreatePipelineLayout: *const fn (VkDevice, ?*const anyopaque, ?*const anyopaque, ?*VkPipelineLayout) callconv(.c) VkResult,
    vkCreateComputePipelines: *const fn (VkDevice, ?*anyopaque, u32, ?*const anyopaque, ?*const anyopaque, ?[*]VkPipeline) callconv(.c) VkResult,
    vkCreateBuffer: *const fn (VkDevice, ?*const anyopaque, ?*const anyopaque, ?*VkBuffer) callconv(.c) VkResult,
    vkGetBufferMemoryRequirements: *const fn (VkDevice, VkBuffer, ?*const anyopaque) callconv(.c) void,
    vkAllocateMemory: *const fn (VkDevice, ?*const anyopaque, ?*const anyopaque, ?*VkDeviceMemory) callconv(.c) VkResult,
    vkBindBufferMemory: *const fn (VkDevice, VkBuffer, VkDeviceMemory, u64) callconv(.c) VkResult,
    vkBeginCommandBuffer: *const fn (VkCommandBuffer, ?*const anyopaque) callconv(.c) VkResult,
    vkEndCommandBuffer: *const fn (VkCommandBuffer) callconv(.c) VkResult,
    vkCmdBindPipeline: *const fn (VkCommandBuffer, u32, VkPipeline) callconv(.c) void,
    vkCmdBindDescriptorSets: *const fn (VkCommandBuffer, u32, VkPipelineLayout, u32, u32, ?*const VkDescriptorSet, u32, ?*const u32) callconv(.c) void,
    vkCmdPushConstants: *const fn (VkCommandBuffer, VkPipelineLayout, u32, u32, u32, ?*const anyopaque) callconv(.c) void,
    vkCmdDispatch: *const fn (VkCommandBuffer, u32, u32, u32) callconv(.c) void,
    vkCmdPipelineBarrier: *const fn (VkCommandBuffer, u32, u32, u32, u32, ?*const anyopaque, u32, ?*const anyopaque, u32, ?*const anyopaque) callconv(.c) void,
    vkCmdCopyImageToBuffer: *const fn (VkCommandBuffer, VkImage, u32, VkBuffer, u32, ?*const anyopaque) callconv(.c) void,
    vkCmdCopyBufferToImage: *const fn (VkCommandBuffer, VkBuffer, VkImage, u32, u32, ?*const anyopaque) callconv(.c) void,
    vkQueueSubmit: *const fn (VkQueue, u32, ?*const anyopaque, ?*anyopaque) callconv(.c) VkResult,
    vkQueueWaitIdle: *const fn (VkQueue) callconv(.c) VkResult,
    vkMapMemory: *const fn (VkDevice, VkDeviceMemory, u64, u64, u32, ?*?*anyopaque) callconv(.c) VkResult,
    vkUnmapMemory: *const fn (VkDevice, VkDeviceMemory) callconv(.c) void,
    vkDestroyDevice: *const fn (VkDevice, ?*const anyopaque) callconv(.c) void,
    vkDestroyInstance: *const fn (VkInstance, ?*const anyopaque) callconv(.c) void,
};

fn sym(comptime T: type, lib: *std.DynLib, comptime name: [:0]const u8) T {
    return lib.lookup(T, name) orelse @panic("missing vulkan symbol: " ++ name);
}

pub fn load() !Vulkan {
    var lib = try std.DynLib.open("libvulkan.so.1");
    errdefer lib.close();

    return .{
        .lib = lib,
        .vkCreateInstance = sym(*const fn (?*const anyopaque, ?*const anyopaque, ?*VkInstance) callconv(.c) VkResult, &lib, "vkCreateInstance"),
        .vkEnumeratePhysicalDevices = sym(*const fn (VkInstance, ?*u32, ?[*]VkPhysicalDevice) callconv(.c) VkResult, &lib, "vkEnumeratePhysicalDevices"),
        .vkGetPhysicalDeviceProperties = sym(*const fn (VkPhysicalDevice, ?*const anyopaque) callconv(.c) void, &lib, "vkGetPhysicalDeviceProperties"),
        .vkGetPhysicalDeviceQueueFamilyProperties = sym(*const fn (VkPhysicalDevice, ?*u32, ?*const anyopaque) callconv(.c) void, &lib, "vkGetPhysicalDeviceQueueFamilyProperties"),
        .vkGetPhysicalDeviceMemoryProperties = sym(*const fn (VkPhysicalDevice, ?*const anyopaque) callconv(.c) void, &lib, "vkGetPhysicalDeviceMemoryProperties"),
        .vkCreateDevice = sym(*const fn (VkPhysicalDevice, ?*const anyopaque, ?*const anyopaque, ?*VkDevice) callconv(.c) VkResult, &lib, "vkCreateDevice"),
        .vkGetDeviceQueue = sym(*const fn (VkDevice, u32, u32, ?*VkQueue) callconv(.c) void, &lib, "vkGetDeviceQueue"),
        .vkCreateCommandPool = sym(*const fn (VkDevice, ?*const anyopaque, ?*const anyopaque, ?*VkCommandPool) callconv(.c) VkResult, &lib, "vkCreateCommandPool"),
        .vkAllocateCommandBuffers = sym(*const fn (VkDevice, ?*const anyopaque, ?[*]VkCommandBuffer) callconv(.c) VkResult, &lib, "vkAllocateCommandBuffers"),
        .vkCreateImage = sym(*const fn (VkDevice, ?*const anyopaque, ?*const anyopaque, ?*VkImage) callconv(.c) VkResult, &lib, "vkCreateImage"),
        .vkGetImageMemoryRequirements = sym(*const fn (VkDevice, VkImage, ?*const anyopaque) callconv(.c) void, &lib, "vkGetImageMemoryRequirements"),
        .vkBindImageMemory = sym(*const fn (VkDevice, VkImage, VkDeviceMemory, u64) callconv(.c) VkResult, &lib, "vkBindImageMemory"),
        .vkCreateImageView = sym(*const fn (VkDevice, ?*const anyopaque, ?*const anyopaque, ?*VkImageView) callconv(.c) VkResult, &lib, "vkCreateImageView"),
        .vkCreateShaderModule = sym(*const fn (VkDevice, ?*const anyopaque, ?*const anyopaque, ?*VkShaderModule) callconv(.c) VkResult, &lib, "vkCreateShaderModule"),
        .vkCreateDescriptorSetLayout = sym(*const fn (VkDevice, ?*const anyopaque, ?*const anyopaque, ?*VkDescriptorSetLayout) callconv(.c) VkResult, &lib, "vkCreateDescriptorSetLayout"),
        .vkCreateDescriptorPool = sym(*const fn (VkDevice, ?*const anyopaque, ?*const anyopaque, ?*VkDescriptorPool) callconv(.c) VkResult, &lib, "vkCreateDescriptorPool"),
        .vkAllocateDescriptorSets = sym(*const fn (VkDevice, ?*const anyopaque, ?*const anyopaque, ?[*]VkDescriptorSet) callconv(.c) VkResult, &lib, "vkAllocateDescriptorSets"),
        .vkUpdateDescriptorSets = sym(*const fn (VkDevice, u32, ?*const anyopaque, u32, ?*const anyopaque) callconv(.c) void, &lib, "vkUpdateDescriptorSets"),
        .vkCreatePipelineLayout = sym(*const fn (VkDevice, ?*const anyopaque, ?*const anyopaque, ?*VkPipelineLayout) callconv(.c) VkResult, &lib, "vkCreatePipelineLayout"),
        .vkCreateComputePipelines = sym(*const fn (VkDevice, ?*anyopaque, u32, ?*const anyopaque, ?*const anyopaque, ?[*]VkPipeline) callconv(.c) VkResult, &lib, "vkCreateComputePipelines"),
        .vkCreateBuffer = sym(*const fn (VkDevice, ?*const anyopaque, ?*const anyopaque, ?*VkBuffer) callconv(.c) VkResult, &lib, "vkCreateBuffer"),
        .vkGetBufferMemoryRequirements = sym(*const fn (VkDevice, VkBuffer, ?*const anyopaque) callconv(.c) void, &lib, "vkGetBufferMemoryRequirements"),
        .vkAllocateMemory = sym(*const fn (VkDevice, ?*const anyopaque, ?*const anyopaque, ?*VkDeviceMemory) callconv(.c) VkResult, &lib, "vkAllocateMemory"),
        .vkBindBufferMemory = sym(*const fn (VkDevice, VkBuffer, VkDeviceMemory, u64) callconv(.c) VkResult, &lib, "vkBindBufferMemory"),
        .vkBeginCommandBuffer = sym(*const fn (VkCommandBuffer, ?*const anyopaque) callconv(.c) VkResult, &lib, "vkBeginCommandBuffer"),
        .vkEndCommandBuffer = sym(*const fn (VkCommandBuffer) callconv(.c) VkResult, &lib, "vkEndCommandBuffer"),
        .vkCmdBindPipeline = sym(*const fn (VkCommandBuffer, u32, VkPipeline) callconv(.c) void, &lib, "vkCmdBindPipeline"),
        .vkCmdBindDescriptorSets = sym(*const fn (VkCommandBuffer, u32, VkPipelineLayout, u32, u32, ?*const VkDescriptorSet, u32, ?*const u32) callconv(.c) void, &lib, "vkCmdBindDescriptorSets"),
        .vkCmdPushConstants = sym(*const fn (VkCommandBuffer, VkPipelineLayout, u32, u32, u32, ?*const anyopaque) callconv(.c) void, &lib, "vkCmdPushConstants"),
        .vkCmdDispatch = sym(*const fn (VkCommandBuffer, u32, u32, u32) callconv(.c) void, &lib, "vkCmdDispatch"),
        .vkCmdPipelineBarrier = sym(*const fn (VkCommandBuffer, u32, u32, u32, u32, ?*const anyopaque, u32, ?*const anyopaque, u32, ?*const anyopaque) callconv(.c) void, &lib, "vkCmdPipelineBarrier"),
        .vkCmdCopyImageToBuffer = sym(*const fn (VkCommandBuffer, VkImage, u32, VkBuffer, u32, ?*const anyopaque) callconv(.c) void, &lib, "vkCmdCopyImageToBuffer"),
        .vkCmdCopyBufferToImage = sym(*const fn (VkCommandBuffer, VkBuffer, VkImage, u32, u32, ?*const anyopaque) callconv(.c) void, &lib, "vkCmdCopyBufferToImage"),
        .vkQueueSubmit = sym(*const fn (VkQueue, u32, ?*const anyopaque, ?*anyopaque) callconv(.c) VkResult, &lib, "vkQueueSubmit"),
        .vkQueueWaitIdle = sym(*const fn (VkQueue) callconv(.c) VkResult, &lib, "vkQueueWaitIdle"),
        .vkMapMemory = sym(*const fn (VkDevice, VkDeviceMemory, u64, u64, u32, ?*?*anyopaque) callconv(.c) VkResult, &lib, "vkMapMemory"),
        .vkUnmapMemory = sym(*const fn (VkDevice, VkDeviceMemory) callconv(.c) void, &lib, "vkUnmapMemory"),
        .vkDestroyDevice = sym(*const fn (VkDevice, ?*const anyopaque) callconv(.c) void, &lib, "vkDestroyDevice"),
        .vkDestroyInstance = sym(*const fn (VkInstance, ?*const anyopaque) callconv(.c) void, &lib, "vkDestroyInstance"),
    };
}
