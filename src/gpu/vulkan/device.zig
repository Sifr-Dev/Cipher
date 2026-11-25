//! Vulkan device creation — dlopen-based libvulkan.so.1 binding.
//! Stage B: handwritten Vulkan API usage for GPU surface presentation.
const std = @import("std");

pub const VkResult = i32;
pub const VK_SUCCESS: VkResult = 0;
pub const VK_SUBOPTIMAL_KHR: VkResult = 1000001003;
pub const VK_ERROR_OUT_OF_DATE_KHR: VkResult = -1000001004;
pub const VkInstance = *anyopaque;
pub const VkPhysicalDevice = *anyopaque;
pub const VkDevice = *anyopaque;
pub const VkQueue = *anyopaque;
pub const VkBool32 = u32;
pub const VK_TRUE: VkBool32 = 1;
pub const VK_FALSE: VkBool32 = 0;
pub const VkSurfaceKHR = *anyopaque;
pub const VkSwapchainKHR = *anyopaque;
pub const VK_PRESENT_MODE_MAILBOX_KHR: u32 = 1;
pub const VK_PRESENT_MODE_IMMEDIATE_KHR: u32 = 0;
pub const VK_PRESENT_MODE_FIFO_KHR: u32 = 2;
pub const VK_PRESENT_MODE_FIFO_RELAXED_KHR: u32 = 3;
pub const VK_COMPOSITE_ALPHA_OPAQUE_BIT_KHR: u32 = 0x1;
pub const VK_COMPOSITE_ALPHA_INHERITED_BIT_KHR: u32 = 0x8;
pub const VK_SURFACE_TRANSFORM_IDENTITY_BIT_KHR: u32 = 0x0;
pub const VK_IMAGE_LAYOUT_PRESENT_SRC_KHR: u32 = 1000001002;
pub const VK_SHARING_MODE_CONCURRENT: u32 = 1;
pub const VK_STRUCTURE_TYPE_SWAPCHAIN_CREATE_INFO_KHR: u32 = 1000001000;
pub const VK_STRUCTURE_TYPE_PRESENT_INFO_KHR: u32 = 1000001001;
pub const VK_STRUCTURE_TYPE_WAYLAND_SURFACE_CREATE_INFO_KHR: u32 = 1000006000;
pub const VK_QUEUE_GRAPHICS_BIT: u32 = 0x00000001;
pub const VK_COLOR_SPACE_SRGB_NONLINEAR_KHR: u32 = 0;
pub const VK_FORMAT_B8G8R8A8_UNORM: u32 = 44;
pub const VK_FORMAT_R8G8B8A8_SRGB: u32 = 43;
pub const VK_FORMAT_R8G8B8A8_UNORM: u32 = 37;
pub const VK_FORMAT_B8G8R8A8_SRGB: u32 = 50;

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
pub const VK_STRUCTURE_TYPE_SUBMIT_INFO: u32 = 4;
pub const VK_STRUCTURE_TYPE_MEMORY_ALLOCATE_INFO: u32 = 5;
pub const VK_STRUCTURE_TYPE_FENCE_CREATE_INFO: u32 = 8;
pub const VK_STRUCTURE_TYPE_SEMAPHORE_CREATE_INFO: u32 = 9;
pub const VK_STRUCTURE_TYPE_BUFFER_CREATE_INFO: u32 = 12;
pub const VK_STRUCTURE_TYPE_IMAGE_CREATE_INFO: u32 = 14;
pub const VK_STRUCTURE_TYPE_IMAGE_VIEW_CREATE_INFO: u32 = 15;
pub const VK_STRUCTURE_TYPE_SHADER_MODULE_CREATE_INFO: u32 = 16;
pub const VK_STRUCTURE_TYPE_PIPELINE_SHADER_STAGE_CREATE_INFO: u32 = 18;
pub const VK_STRUCTURE_TYPE_COMPUTE_PIPELINE_CREATE_INFO: u32 = 29;
pub const VK_STRUCTURE_TYPE_PIPELINE_LAYOUT_CREATE_INFO: u32 = 30;
pub const VK_STRUCTURE_TYPE_DESCRIPTOR_SET_LAYOUT_CREATE_INFO: u32 = 32;
pub const VK_STRUCTURE_TYPE_DESCRIPTOR_POOL_CREATE_INFO: u32 = 33;
pub const VK_STRUCTURE_TYPE_DESCRIPTOR_SET_ALLOCATE_INFO: u32 = 34;
pub const VK_STRUCTURE_TYPE_WRITE_DESCRIPTOR_SET: u32 = 35;
pub const VK_STRUCTURE_TYPE_COMMAND_POOL_CREATE_INFO: u32 = 39;
pub const VK_STRUCTURE_TYPE_COMMAND_BUFFER_ALLOCATE_INFO: u32 = 40;
pub const VK_STRUCTURE_TYPE_COMMAND_BUFFER_BEGIN_INFO: u32 = 42;
pub const VK_STRUCTURE_TYPE_SAMPLER_CREATE_INFO: u32 = 31;
pub const VK_STRUCTURE_TYPE_IMAGE_MEMORY_BARRIER: u32 = 45;
pub const VK_API_VERSION_1_0: u32 = (0 << 29) | (1 << 22) | (0 << 12);

// Image type / view type
pub const VK_IMAGE_TYPE_2D: u32 = 1;
pub const VK_IMAGE_VIEW_TYPE_2D: u32 = 1;

// Descriptor types and pool flags
pub const VK_DESCRIPTOR_TYPE_STORAGE_IMAGE: u32 = 3;
pub const VK_DESCRIPTOR_POOL_CREATE_FREE_DESCRIPTOR_SET_BIT: u32 = 0x00000001;

// Queue family index wildcard for barriers
pub const VK_QUEUE_FAMILY_IGNORED: u32 = 0xFFFFFFFF;

// Fence create flag
pub const VK_FENCE_CREATE_SIGNALED_BIT: u32 = 0x00000001;

// Image usage (vulkan_core.h)
pub const VK_IMAGE_USAGE_TRANSFER_SRC_BIT: u32 = 0x00000001;
pub const VK_IMAGE_USAGE_TRANSFER_DST_BIT: u32 = 0x00000002;

// Buffer usage (vulkan_core.h)
pub const VK_BUFFER_USAGE_TRANSFER_SRC_BIT: u32 = 0x00000001;
pub const VK_BUFFER_USAGE_TRANSFER_DST_BIT: u32 = 0x00000002;
pub const VK_BUFFER_USAGE_VERTEX_BUFFER_BIT: u32 = 0x00000080;
pub const VK_IMAGE_USAGE_SAMPLED_BIT: u32 = 0x00000004;
pub const VK_IMAGE_USAGE_STORAGE_BIT: u32 = 0x00000008;

// Sharing mode
pub const VK_SHARING_MODE_EXCLUSIVE: u32 = 0;

// Image layout (vulkan_core.h)
pub const VK_IMAGE_LAYOUT_UNDEFINED: u32 = 0;
pub const VK_IMAGE_LAYOUT_GENERAL: u32 = 1;
pub const VK_IMAGE_LAYOUT_TRANSFER_SRC_OPTIMAL: u32 = 6;
pub const VK_IMAGE_LAYOUT_TRANSFER_DST_OPTIMAL: u32 = 7;

// Access flags (vulkan_core.h)
pub const VK_ACCESS_SHADER_WRITE_BIT: u32 = 0x00000040;
pub const VK_ACCESS_COLOR_ATTACHMENT_WRITE_BIT: u32 = 0x00000100;
pub const VK_ACCESS_TRANSFER_READ_BIT: u32 = 0x00000800;
pub const VK_ACCESS_TRANSFER_WRITE_BIT: u32 = 0x00001000;

// Pipeline stages (vulkan_core.h)
pub const VK_PIPELINE_STAGE_TOP_OF_PIPE_BIT: u32 = 0x00000001;
pub const VK_PIPELINE_STAGE_FRAGMENT_SHADER_BIT: u32 = 0x00000080;
pub const VK_PIPELINE_STAGE_COLOR_ATTACHMENT_OUTPUT_BIT: u32 = 0x00000400;
pub const VK_PIPELINE_STAGE_COMPUTE_SHADER_BIT: u32 = 0x00000800;
pub const VK_PIPELINE_STAGE_TRANSFER_BIT: u32 = 0x00001000;
pub const VK_PIPELINE_STAGE_BOTTOM_OF_PIPE_BIT: u32 = 0x00002000;

// Image aspect
pub const VK_IMAGE_ASPECT_COLOR_BIT: u32 = 0x00000001;

// Component swizzle
pub const VK_COMPONENT_SWIZZLE_IDENTITY: u32 = 0;

// Formats
// Samples
pub const VK_SAMPLE_COUNT_1_BIT: u32 = 0x00000001;

// Tiling (vulkan_core.h)
pub const VK_IMAGE_TILING_OPTIMAL: u32 = 0;
pub const VK_IMAGE_TILING_LINEAR: u32 = 1;

// Memory properties
pub const VK_MEMORY_PROPERTY_DEVICE_LOCAL_BIT: u32 = 0x00000001;
pub const VK_MEMORY_PROPERTY_HOST_VISIBLE_BIT: u32 = 0x00000002;
pub const VK_MEMORY_PROPERTY_HOST_COHERENT_BIT: u32 = 0x00000004;

// Command pool (vulkan_core.h)
pub const VK_COMMAND_POOL_CREATE_TRANSIENT_BIT: u32 = 0x00000001;
pub const VK_COMMAND_POOL_CREATE_RESET_COMMAND_BUFFER_BIT: u32 = 0x00000002;
pub const VK_COMMAND_BUFFER_LEVEL_PRIMARY: u32 = 0;

// Command buffer usage
pub const VK_COMMAND_BUFFER_USAGE_ONE_TIME_SUBMIT_BIT: u32 = 0x00000001;

// Pipeline bind point (vulkan_core.h): GRAPHICS=0, COMPUTE=1
pub const VK_PIPELINE_BIND_POINT_GRAPHICS: u32 = 0;
pub const VK_PIPELINE_BIND_POINT_COMPUTE: u32 = 1;

// Shader stage
pub const VK_SHADER_STAGE_COMPUTE_BIT: u32 = 0x00000020;

// Memory requirement structs
pub const VkMemoryRequirements = extern struct {
    size: u64,
    alignment: u64,
    memoryTypeBits: u32,
    _pad: u32,
};

pub const VkExtent3D = extern struct {
    width: u32,
    height: u32,
    depth: u32,
};

// Exact vulkan_core.h VkQueueFamilyProperties layout; there is no index field.
pub const VkPhysicalDeviceQueueFamilyProperties = extern struct {
    queueFlags: u32,
    queueCount: u32,
    timestampValidBits: u32,
    minImageTransferGranularity: VkExtent3D,
};

pub const VkImageCreateInfo = extern struct {
    sType: u32,
    pNext: ?*const anyopaque,
    flags: u32,
    imageType: u32,
    format: u32,
    extent: VkExtent3D,
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

pub const VkImageViewCreateInfo = extern struct {
    sType: u32,
    pNext: ?*const anyopaque,
    flags: u32,
    image: VkImage,
    viewType: u32,
    format: u32,
    components: VkComponentMapping,
    subresourceRange: VkImageSubresourceRange,
};

pub const VkComponentMapping = extern struct {
    r: u32,
    g: u32,
    b: u32,
    a: u32,
};

pub const VkImageSubresourceRange = extern struct {
    aspectMask: u32,
    baseMipLevel: u32,
    levelCount: u32,
    baseArrayLayer: u32,
    layerCount: u32,
};

pub const VkBufferCreateInfo = extern struct {
    sType: u32,
    pNext: ?*const anyopaque,
    flags: u32,
    size: u64,
    usage: u32,
    sharingMode: u32,
    queueFamilyIndexCount: u32,
    pQueueFamilyIndices: ?*const u32,
};

pub const VkMemoryAllocateInfo = extern struct {
    sType: u32,
    pNext: ?*const anyopaque,
    allocationSize: u64,
    memoryTypeIndex: u32,
};

pub const VkCommandPoolCreateInfo = extern struct {
    sType: u32,
    pNext: ?*const anyopaque,
    flags: u32,
    queueFamilyIndex: u32,
};

pub const VkCommandBufferAllocateInfo = extern struct {
    sType: u32,
    pNext: ?*const anyopaque,
    commandPool: VkCommandPool,
    level: u32,
    commandBufferCount: u32,
};

pub const VkCommandBufferBeginInfo = extern struct {
    sType: u32,
    pNext: ?*const anyopaque,
    flags: u32,
    pInheritanceInfo: ?*const anyopaque,
};

pub const VkPipelineShaderStageCreateInfo = extern struct {
    sType: u32,
    pNext: ?*const anyopaque,
    flags: u32,
    stage: u32,
    module: VkShaderModule,
    pName: *const u8,
    pSpecializationInfo: ?*const anyopaque,
};

pub const VkComputePipelineCreateInfo = extern struct {
    sType: u32,
    pNext: ?*const anyopaque,
    flags: u32,
    stage: VkPipelineShaderStageCreateInfo,
    layout: VkPipelineLayout,
    basePipelineHandle: ?VkPipeline,
    basePipelineIndex: i32,
};

pub const VkPipelineLayoutCreateInfo = extern struct {
    sType: u32,
    pNext: ?*const anyopaque,
    flags: u32,
    setLayoutCount: u32,
    pSetLayouts: ?*const anyopaque,
    pushConstantRangeCount: u32,
    pPushConstantRanges: ?*const anyopaque,
};

pub const VkSemaphoreCreateInfo = extern struct {
    sType: u32,
    pNext: ?*const anyopaque,
    flags: u32,
};

pub const VkFenceCreateInfo = extern struct {
    sType: u32,
    pNext: ?*const anyopaque,
    flags: u32,
};

pub const VkSubmitInfo = extern struct {
    sType: u32,
    pNext: ?*const anyopaque,
    waitSemaphoreCount: u32,
    pWaitSemaphores: ?*const anyopaque,
    pWaitDstStageMask: ?[*]const u32,
    commandBufferCount: u32,
    pCommandBuffers: ?*const anyopaque,
    signalSemaphoreCount: u32,
    pSignalSemaphores: ?*const anyopaque,
};

pub const VkMemoryType = extern struct {
    propertyFlags: u32,
    heapIndex: u32,
};

pub const VkMemoryHeap = extern struct {
    size: u64,
    flags: u32,
};

pub const VK_MAX_MEMORY_TYPES: u32 = 32;
pub const VK_MAX_MEMORY_HEAPS: u32 = 16;

pub const VkPhysicalDeviceMemoryProperties = extern struct {
    memoryTypeCount: u32,
    memoryTypes: [VK_MAX_MEMORY_TYPES]VkMemoryType,
    memoryHeapCount: u32,
    memoryHeaps: [VK_MAX_MEMORY_HEAPS]VkMemoryHeap,
};

pub const VkPhysicalDeviceProperties = extern struct {
    apiVersion: u32,
    driverVersion: u32,
    vendorID: u32,
    deviceID: u32,
    deviceType: u32,
    deviceName: [256]u8,
    pipelineCacheUUID: [16]u8,
    limits: [256]u8,
    sparseProperties: [64]u8,
};

// Buffer image copy for vkCmdCopyImageToBuffer
pub const VkBufferImageCopy = extern struct {
    bufferOffset: u64,
    bufferRowLength: u32,
    bufferImageHeight: u32,
    imageSubresource: VkImageSubresourceLayers,
    imageOffset: VkOffset3D,
    imageExtent: VkExtent3D,
};

pub const VkImageSubresourceLayers = extern struct {
    aspectMask: u32,
    mipLevel: u32,
    baseArrayLayer: u32,
    layerCount: u32,
};

pub const VkOffset3D = extern struct {
    x: i32,
    y: i32,
    z: i32,
};

// Descriptor set layout / pool / writes
pub const VkDescriptorSetLayoutBinding = extern struct {
    binding: u32,
    descriptorType: u32,
    descriptorCount: u32,
    stageFlags: u32,
    pImmutableSamplers: ?*const anyopaque,
};

pub const VkDescriptorSetLayoutCreateInfo = extern struct {
    sType: u32,
    pNext: ?*const anyopaque,
    flags: u32,
    bindingCount: u32,
    pBindings: ?[*]const VkDescriptorSetLayoutBinding,
};

pub const VkDescriptorPoolSize = extern struct {
    type: u32,
    descriptorCount: u32,
};

pub const VkDescriptorPoolCreateInfo = extern struct {
    sType: u32,
    pNext: ?*const anyopaque,
    flags: u32,
    maxSets: u32,
    poolSizeCount: u32,
    pPoolSizes: ?[*]const VkDescriptorPoolSize,
};

pub const VkDescriptorSetAllocateInfo = extern struct {
    sType: u32,
    pNext: ?*const anyopaque,
    descriptorPool: VkDescriptorPool,
    descriptorSetCount: u32,
    pSetLayouts: *const VkDescriptorSetLayout,
};

pub const VkDescriptorImageInfo = extern struct {
    sampler: ?VkSampler,
    imageView: VkImageView,
    imageLayout: u32,
};

pub const VkWriteDescriptorSet = extern struct {
    sType: u32,
    pNext: ?*const anyopaque,
    dstSet: VkDescriptorSet,
    dstBinding: u32,
    dstArrayElement: u32,
    descriptorCount: u32,
    descriptorType: u32,
    pImageInfo: ?[*]const VkDescriptorImageInfo,
    pBufferInfo: ?*const anyopaque,
    pTexelBufferView: ?*const anyopaque,
};

// Shader module and push constants
pub const VkShaderModuleCreateInfo = extern struct {
    sType: u32,
    pNext: ?*const anyopaque,
    flags: u32,
    codeSize: usize,
    pCode: *const u32,
};

pub const VkPushConstantRange = extern struct {
    stageFlags: u32,
    offset: u32,
    size: u32,
};

// Image memory barrier for layout transitions
pub const VkImageMemoryBarrier = extern struct {
    sType: u32,
    pNext: ?*const anyopaque,
    srcAccessMask: u32,
    dstAccessMask: u32,
    oldLayout: u32,
    newLayout: u32,
    srcQueueFamilyIndex: u32,
    dstQueueFamilyIndex: u32,
    image: VkImage,
    subresourceRange: VkImageSubresourceRange,
};

// ---- Graphics pipeline / render pass structs ----
pub const VK_STRUCTURE_TYPE_RENDER_PASS_CREATE_INFO: u32 = 38;
pub const VK_STRUCTURE_TYPE_FRAMEBUFFER_CREATE_INFO: u32 = 37;
pub const VK_STRUCTURE_TYPE_RENDER_PASS_BEGIN_INFO: u32 = 43;
pub const VK_STRUCTURE_TYPE_GRAPHICS_PIPELINE_CREATE_INFO: u32 = 28;
pub const VK_STRUCTURE_TYPE_PIPELINE_VERTEX_INPUT_STATE_CREATE_INFO: u32 = 19;
pub const VK_STRUCTURE_TYPE_PIPELINE_INPUT_ASSEMBLY_STATE_CREATE_INFO: u32 = 20;
pub const VK_STRUCTURE_TYPE_PIPELINE_VIEWPORT_STATE_CREATE_INFO: u32 = 22;
pub const VK_STRUCTURE_TYPE_PIPELINE_RASTERIZATION_STATE_CREATE_INFO: u32 = 23;
pub const VK_STRUCTURE_TYPE_PIPELINE_MULTISAMPLE_STATE_CREATE_INFO: u32 = 24;
pub const VK_STRUCTURE_TYPE_PIPELINE_COLOR_BLEND_STATE_CREATE_INFO: u32 = 26;

pub const VK_IMAGE_USAGE_COLOR_ATTACHMENT_BIT: u32 = 0x00000010;
pub const VK_IMAGE_LAYOUT_COLOR_ATTACHMENT_OPTIMAL: u32 = 2;
pub const VK_IMAGE_LAYOUT_SHADER_READ_ONLY_OPTIMAL: u32 = 5;
pub const VK_ACCESS_SHADER_READ_BIT: u32 = 0x00000020;
pub const VK_FORMAT_R8_UNORM: u32 = 9;
pub const VK_FORMAT_R32G32_SFLOAT: u32 = 103;
pub const VK_FORMAT_R32G32B32A32_SFLOAT: u32 = 109;
pub const VK_DESCRIPTOR_TYPE_COMBINED_IMAGE_SAMPLER: u32 = 1;
pub const VK_SAMPLER_FILTER_NEAREST: u32 = 0;
pub const VK_SAMPLER_FILTER_LINEAR: u32 = 1;
pub const VK_SAMPLER_MIPMAP_MODE_NEAREST: u32 = 0;
pub const VK_SAMPLER_ADDRESS_MODE_CLAMP_TO_EDGE: u32 = 2;
pub const VK_VERTEX_INPUT_RATE_VERTEX: u32 = 0;
pub const VK_SHADER_STAGE_VERTEX_BIT: u32 = 0x00000001;
pub const VK_SHADER_STAGE_FRAGMENT_BIT: u32 = 0x00000010;
pub const VK_PRIMITIVE_TOPOLOGY_TRIANGLE_LIST: u32 = 3;
pub const VK_POLYGON_MODE_FILL: u32 = 0;
pub const VK_CULL_MODE_NONE: u32 = 0;
pub const VK_FRONT_FACE_COUNTER_CLOCKWISE: u32 = 0;
pub const VK_ATTACHMENT_LOAD_OP_CLEAR: u32 = 1;
pub const VK_ATTACHMENT_STORE_OP_STORE: u32 = 0;
pub const VK_SUBPASS_EXTERNAL: u32 = 0xFFFFFFFF;
pub const VK_COLOR_COMPONENT_R_BIT: u32 = 0x1;
pub const VK_COLOR_COMPONENT_G_BIT: u32 = 0x2;
pub const VK_COLOR_COMPONENT_B_BIT: u32 = 0x4;
pub const VK_COLOR_COMPONENT_A_BIT: u32 = 0x8;

pub const VkAttachmentDescription = extern struct {
    flags: u32,
    format: u32,
    samples: u32,
    loadOp: u32,
    storeOp: u32,
    stencilLoadOp: u32,
    stencilStoreOp: u32,
    initialLayout: u32,
    finalLayout: u32,
};

pub const VkAttachmentReference = extern struct {
    attachment: u32,
    layout: u32,
};

pub const VkSubpassDescription = extern struct {
    flags: u32,
    pipelineBindPoint: u32,
    inputAttachmentCount: u32,
    pInputAttachments: ?*const anyopaque,
    colorAttachmentCount: u32,
    pColorAttachments: ?[*]const VkAttachmentReference,
    pResolveAttachments: ?*const anyopaque,
    pDepthStencilAttachment: ?*const anyopaque,
    preserveAttachmentCount: u32,
    pPreserveAttachments: ?*const anyopaque,
};

pub const VkSubpassDependency = extern struct {
    srcSubpass: u32,
    dstSubpass: u32,
    srcStageMask: u32,
    dstStageMask: u32,
    srcAccessMask: u32,
    dstAccessMask: u32,
    dependencyFlags: u32,
};

pub const VkRenderPassCreateInfo = extern struct {
    sType: u32,
    pNext: ?*const anyopaque,
    flags: u32,
    attachmentCount: u32,
    pAttachments: ?[*]const VkAttachmentDescription,
    subpassCount: u32,
    pSubpasses: ?[*]const VkSubpassDescription,
    dependencyCount: u32,
    pDependencies: ?[*]const VkSubpassDependency,
};

pub const VkFramebufferCreateInfo = extern struct {
    sType: u32,
    pNext: ?*const anyopaque,
    flags: u32,
    renderPass: VkRenderPass,
    attachmentCount: u32,
    pAttachments: ?[*]const VkImageView,
    width: u32,
    height: u32,
    layers: u32,
};

pub const VkClearValue = extern union {
    color: [4]f32,
    depthStencil: extern struct { depth: f32, stencil: u32 },
};

// NOTE: VkRenderPassBeginInfo has NO `flags` field in vulkan_core.h
// (unlike VkRenderPassCreateInfo / VkFramebufferCreateInfo). Layout:
// sType@0, pNext@8, renderPass@16, framebuffer@24, renderArea@32,
// clearValueCount@48, pClearValues@56, size 64 — verified via offsetof
// against /usr/include/vulkan/vulkan.h.
pub const VkRenderPassBeginInfo = extern struct {
    sType: u32,
    pNext: ?*const anyopaque,
    renderPass: VkRenderPass,
    framebuffer: VkFramebuffer,
    renderArea: VkRect2D,
    clearValueCount: u32,
    pClearValues: ?[*]const VkClearValue,
};

pub const VkPipelineVertexInputBindingDescription = extern struct {
    binding: u32,
    stride: u32,
    inputRate: u32,
};

pub const VkPipelineVertexInputAttributeDescription = extern struct {
    location: u32,
    binding: u32,
    format: u32,
    offset: u32,
};

pub const VkPipelineVertexInputStateCreateInfo = extern struct {
    sType: u32,
    pNext: ?*const anyopaque,
    flags: u32,
    vertexBindingDescriptionCount: u32,
    pVertexBindingDescriptions: ?[*]const VkPipelineVertexInputBindingDescription,
    vertexAttributeDescriptionCount: u32,
    pVertexAttributeDescriptions: ?[*]const VkPipelineVertexInputAttributeDescription,
};

pub const VkSamplerCreateInfo = extern struct {
    sType: u32,
    pNext: ?*const anyopaque,
    flags: u32,
    magFilter: u32,
    minFilter: u32,
    mipmapMode: u32,
    addressModeU: u32,
    addressModeV: u32,
    addressModeW: u32,
    mipLodBias: f32,
    anisotropyEnable: u32,
    maxAnisotropy: f32,
    compareEnable: u32,
    compareOp: u32,
    minLod: f32,
    maxLod: f32,
    borderColor: u32,
    unnormalizedCoordinates: u32,
};

pub const VkPipelineInputAssemblyStateCreateInfo = extern struct {
    sType: u32,
    pNext: ?*const anyopaque,
    flags: u32,
    topology: u32,
    primitiveRestartEnable: u32,
};

pub const VkViewport = extern struct {
    x: f32,
    y: f32,
    width: f32,
    height: f32,
    minDepth: f32,
    maxDepth: f32,
};

pub const VkOffset2D = extern struct { x: i32, y: i32 };
pub const VkExtent2D = extern struct { width: u32, height: u32 };
pub const VkRect2D = extern struct { offset: VkOffset2D, extent: VkExtent2D };

pub const VkPipelineViewportStateCreateInfo = extern struct {
    sType: u32,
    pNext: ?*const anyopaque,
    flags: u32,
    viewportCount: u32,
    pViewports: ?[*]const VkViewport,
    scissorCount: u32,
    pScissors: ?[*]const VkRect2D,
};

pub const VkPipelineRasterizationStateCreateInfo = extern struct {
    sType: u32,
    pNext: ?*const anyopaque,
    flags: u32,
    depthClampEnable: u32,
    rasterizerDiscardEnable: u32,
    polygonMode: u32,
    cullMode: u32,
    frontFace: u32,
    depthBiasEnable: u32,
    depthBiasConstantFactor: f32,
    depthBiasClamp: f32,
    depthBiasSlopeFactor: f32,
    lineWidth: f32,
};

pub const VkPipelineMultisampleStateCreateInfo = extern struct {
    sType: u32,
    pNext: ?*const anyopaque,
    flags: u32,
    rasterizationSamples: u32,
    sampleShadingEnable: u32,
    minSampleShading: f32,
    pSampleMask: ?*const anyopaque,
    alphaToCoverageEnable: u32,
    alphaToOneEnable: u32,
};

pub const VkPipelineColorBlendAttachmentState = extern struct {
    blendEnable: u32,
    srcColorBlendFactor: u32,
    dstColorBlendFactor: u32,
    colorBlendOp: u32,
    srcAlphaBlendFactor: u32,
    dstAlphaBlendFactor: u32,
    alphaBlendOp: u32,
    colorWriteMask: u32,
};

pub const VkPipelineColorBlendStateCreateInfo = extern struct {
    sType: u32,
    pNext: ?*const anyopaque,
    flags: u32,
    logicOpEnable: u32,
    logicOp: u32,
    attachmentCount: u32,
    pAttachments: ?[*]const VkPipelineColorBlendAttachmentState,
    blendConstants: [4]f32,
};

pub const VkGraphicsPipelineCreateInfo = extern struct {
    sType: u32,
    pNext: ?*const anyopaque,
    flags: u32,
    stageCount: u32,
    pStages: [*]const VkPipelineShaderStageCreateInfo,
    pVertexInputState: *const VkPipelineVertexInputStateCreateInfo,
    pInputAssemblyState: *const VkPipelineInputAssemblyStateCreateInfo,
    pTessellationState: ?*const anyopaque,
    pViewportState: *const VkPipelineViewportStateCreateInfo,
    pRasterizationState: *const VkPipelineRasterizationStateCreateInfo,
    pMultisampleState: *const VkPipelineMultisampleStateCreateInfo,
    pDepthStencilState: ?*const anyopaque,
    pColorBlendState: *const VkPipelineColorBlendStateCreateInfo,
    pDynamicState: ?*const anyopaque,
    layout: VkPipelineLayout,
    renderPass: VkRenderPass,
    subpass: u32,
    basePipelineHandle: ?VkPipeline,
    basePipelineIndex: i32,
};

pub const VkRenderPass = *anyopaque;
pub const VkFramebuffer = *anyopaque;

// Vulkan handle types for the device wrapper (opaque pointers, as in the C API)
pub const VkCommandPool = *anyopaque;
pub const VkCommandBuffer = *anyopaque;
pub const VkImage = *anyopaque;
pub const VkImageView = *anyopaque;
pub const VkBuffer = *anyopaque;
pub const VkDeviceMemory = *anyopaque;
pub const VkShaderModule = *anyopaque;
pub const VkPipelineLayout = *anyopaque;
pub const VkPipeline = *anyopaque;
pub const VkSemaphore = *anyopaque;
pub const VkFence = *anyopaque;
pub const VkDescriptorSetLayout = *anyopaque;
pub const VkDescriptorPool = *anyopaque;
pub const VkDescriptorSet = *anyopaque;
pub const VkExtensionProperties = extern struct {
    extensionName: [256]u8,
    specVersion: u32,
};

pub const VkSurfaceCapabilitiesKHR = extern struct {
    minImageCount: u32,
    maxImageCount: u32,
    currentExtent: VkExtent2D,
    minImageExtent: VkExtent2D,
    maxImageExtent: VkExtent2D,
    maxImageArrayLayers: u32,
    supportedTransforms: u32,
    currentTransform: u32,
    supportedCompositeAlpha: u32,
    supportedUsageFlags: u32,
};
pub const VkSurfaceFormatKHR = extern struct {
    format: u32,
    colorSpace: u32,
};
pub const VkWaylandSurfaceCreateInfoKHR = extern struct {
    sType: u32,
    pNext: ?*const anyopaque,
    flags: u32,
    display: ?*anyopaque,
    surface: ?*anyopaque,
};
pub const VkSwapchainCreateInfoKHR = extern struct {
    sType: u32,
    pNext: ?*const anyopaque,
    flags: u32,
    surface: VkSurfaceKHR,
    minImageCount: u32,
    imageFormat: u32,
    imageColorSpace: u32,
    imageExtent: VkExtent2D,
    imageArrayLayers: u32,
    imageUsage: u32,
    imageSharingMode: u32,
    queueFamilyIndexCount: u32,
    pQueueFamilyIndices: ?*const u32,
    preTransform: u32,
    compositeAlpha: u32,
    presentMode: u32,
    clipped: VkBool32,
    oldSwapchain: ?*anyopaque,
};
pub const VkPresentInfoKHR = extern struct {
    sType: u32,
    pNext: ?*const anyopaque,
    waitSemaphoreCount: u32,
    pWaitSemaphores: ?[*]const VkSemaphore,
    swapchainCount: u32,
    pSwapchains: ?[*]const VkSwapchainKHR,
    pImageIndices: ?[*]const u32,
    pResults: ?[*]const VkResult,
};

pub const VkSampler = *anyopaque;
pub const VkPipelineCache = *anyopaque;

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

    // Instance/device lifecycle
    vkCreateInstance: *const fn (*const VkInstanceCreateInfo, ?*const anyopaque, *VkInstance) callconv(.c) VkResult,
    vkEnumeratePhysicalDevices: *const fn (VkInstance, *u32, ?[*]VkPhysicalDevice) callconv(.c) VkResult,
    vkGetPhysicalDeviceQueueFamilyProperties: *const fn (VkPhysicalDevice, *u32, ?[*]VkPhysicalDeviceQueueFamilyProperties) callconv(.c) void,
    vkCreateDevice: *const fn (VkPhysicalDevice, *const VkDeviceCreateInfo, ?*const anyopaque, *VkDevice) callconv(.c) VkResult,
    vkGetDeviceQueue: *const fn (VkDevice, u32, u32, *VkQueue) callconv(.c) void,
    vkDestroyDevice: *const fn (VkDevice, ?*const anyopaque) callconv(.c) void,
    vkDestroyInstance: *const fn (VkInstance, ?*const anyopaque) callconv(.c) void,

    // Command buffers
    vkCreateCommandPool: *const fn (VkDevice, ?*const anyopaque, ?*const anyopaque, *VkCommandPool) callconv(.c) VkResult,
    vkAllocateCommandBuffers: *const fn (VkDevice, ?*const anyopaque, *VkCommandBuffer) callconv(.c) VkResult,
    vkBeginCommandBuffer: *const fn (VkCommandBuffer, ?*const anyopaque) callconv(.c) VkResult,
    vkEndCommandBuffer: *const fn (VkCommandBuffer) callconv(.c) VkResult,
    vkCmdBindPipeline: *const fn (VkCommandBuffer, u32, VkPipeline) callconv(.c) void,
    vkCmdDispatch: *const fn (VkCommandBuffer, u32, u32, u32) callconv(.c) void,
    vkCmdPipelineBarrier: *const fn (VkCommandBuffer, u32, u32, u32, u32, ?*const anyopaque, u32, ?*const anyopaque, u32, ?*const anyopaque) callconv(.c) void,
    vkCmdCopyImageToBuffer: *const fn (VkCommandBuffer, VkImage, u32, VkBuffer, u32, ?*const anyopaque) callconv(.c) void,
    vkQueueSubmit: *const fn (VkQueue, u32, ?*const anyopaque, VkFence) callconv(.c) VkResult,
    vkQueueWaitIdle: *const fn (VkQueue) callconv(.c) VkResult,
    vkDeviceWaitIdle: *const fn (VkDevice) callconv(.c) VkResult,
    vkDestroyCommandPool: *const fn (VkDevice, VkCommandPool, ?*const anyopaque) callconv(.c) void,

    // Images and memory
    vkCreateImage: *const fn (VkDevice, ?*const anyopaque, ?*const anyopaque, *VkImage) callconv(.c) VkResult,
    vkGetImageMemoryRequirements: *const fn (VkDevice, VkImage, *VkMemoryRequirements) callconv(.c) void,
    vkBindImageMemory: *const fn (VkDevice, VkImage, VkDeviceMemory, u64) callconv(.c) VkResult,
    vkCreateImageView: *const fn (VkDevice, ?*const anyopaque, ?*const anyopaque, *VkImageView) callconv(.c) VkResult,
    vkCreateBuffer: *const fn (VkDevice, ?*const anyopaque, ?*const anyopaque, *VkBuffer) callconv(.c) VkResult,
    vkGetBufferMemoryRequirements: *const fn (VkDevice, VkBuffer, *VkMemoryRequirements) callconv(.c) void,
    vkBindBufferMemory: *const fn (VkDevice, VkBuffer, VkDeviceMemory, u64) callconv(.c) VkResult,
    vkAllocateMemory: *const fn (VkDevice, ?*const anyopaque, ?*const anyopaque, *VkDeviceMemory) callconv(.c) VkResult,
    vkMapMemory: *const fn (VkDevice, VkDeviceMemory, u64, u64, u32, **anyopaque) callconv(.c) VkResult,
    vkUnmapMemory: *const fn (VkDevice, VkDeviceMemory) callconv(.c) void,
    vkDestroyImage: *const fn (VkDevice, VkImage, ?*const anyopaque) callconv(.c) void,
    vkDestroyImageView: *const fn (VkDevice, VkImageView, ?*const anyopaque) callconv(.c) void,
    vkDestroyBuffer: *const fn (VkDevice, VkBuffer, ?*const anyopaque) callconv(.c) void,
    vkFreeMemory: *const fn (VkDevice, VkDeviceMemory, ?*const anyopaque) callconv(.c) void,

    // Shaders and pipelines
    vkCreateShaderModule: *const fn (VkDevice, ?*const anyopaque, ?*const anyopaque, *VkShaderModule) callconv(.c) VkResult,
    vkCreateComputePipelines: *const fn (VkDevice, ?VkPipelineCache, u32, ?*const anyopaque, ?*const anyopaque, *VkPipeline) callconv(.c) VkResult,
    vkCreatePipelineLayout: *const fn (VkDevice, ?*const anyopaque, ?*const anyopaque, *VkPipelineLayout) callconv(.c) VkResult,
    vkDestroyShaderModule: *const fn (VkDevice, VkShaderModule, ?*const anyopaque) callconv(.c) void,
    vkDestroyPipeline: *const fn (VkDevice, VkPipeline, ?*const anyopaque) callconv(.c) void,
    vkDestroyPipelineLayout: *const fn (VkDevice, VkPipelineLayout, ?*const anyopaque) callconv(.c) void,

    // Sync
    vkCreateSemaphore: *const fn (VkDevice, ?*const anyopaque, ?*const anyopaque, *VkSemaphore) callconv(.c) VkResult,
    vkDestroySemaphore: *const fn (VkDevice, VkSemaphore, ?*const anyopaque) callconv(.c) void,
    vkCreateFence: *const fn (VkDevice, ?*const anyopaque, ?*const anyopaque, *VkFence) callconv(.c) VkResult,
    vkDestroyFence: *const fn (VkDevice, VkFence, ?*const anyopaque) callconv(.c) void,
    vkWaitForFences: *const fn (VkDevice, u32, *const VkFence, VkBool32, u64) callconv(.c) VkResult,
    vkResetFences: *const fn (VkDevice, u32, *const VkFence) callconv(.c) VkResult,

    // Memory properties and descriptor management
    vkGetPhysicalDeviceMemoryProperties: *const fn (VkPhysicalDevice, *VkPhysicalDeviceMemoryProperties) callconv(.c) void,
    vkCreateDescriptorSetLayout: *const fn (VkDevice, *const VkDescriptorSetLayoutCreateInfo, ?*const anyopaque, *VkDescriptorSetLayout) callconv(.c) VkResult,
    vkDestroyDescriptorSetLayout: *const fn (VkDevice, VkDescriptorSetLayout, ?*const anyopaque) callconv(.c) void,
    vkCreateDescriptorPool: *const fn (VkDevice, *const VkDescriptorPoolCreateInfo, ?*const anyopaque, *VkDescriptorPool) callconv(.c) VkResult,
    vkDestroyDescriptorPool: *const fn (VkDevice, VkDescriptorPool, ?*const anyopaque) callconv(.c) void,
    vkAllocateDescriptorSets: *const fn (VkDevice, *const VkDescriptorSetAllocateInfo, *VkDescriptorSet) callconv(.c) VkResult,
    vkUpdateDescriptorSets: *const fn (VkDevice, u32, ?[*]const VkWriteDescriptorSet, u32, ?*const anyopaque) callconv(.c) void,
    vkCmdBindDescriptorSets: *const fn (VkCommandBuffer, u32, VkPipelineLayout, u32, u32, *const VkDescriptorSet, u32, ?*const u32) callconv(.c) void,
    vkCmdPushConstants: *const fn (VkCommandBuffer, VkPipelineLayout, u32, u32, u32, *const anyopaque) callconv(.c) void,

    // Graphics pipeline and render pass
    vkCreateRenderPass: *const fn (VkDevice, *const VkRenderPassCreateInfo, ?*const anyopaque, *VkRenderPass) callconv(.c) VkResult,
    vkCreateFramebuffer: *const fn (VkDevice, *const VkFramebufferCreateInfo, ?*const anyopaque, *VkFramebuffer) callconv(.c) VkResult,
    vkCreateGraphicsPipelines: *const fn (VkDevice, ?VkPipelineCache, u32, *const VkGraphicsPipelineCreateInfo, ?*const anyopaque, *VkPipeline) callconv(.c) VkResult,
    vkCmdBeginRenderPass: *const fn (VkCommandBuffer, *const VkRenderPassBeginInfo, u32) callconv(.c) void,
    vkCmdDraw: *const fn (VkCommandBuffer, u32, u32, u32, u32) callconv(.c) void,
    vkCmdEndRenderPass: *const fn (VkCommandBuffer) callconv(.c) void,
    vkCmdBindVertexBuffers: *const fn (VkCommandBuffer, u32, u32, ?[*]const VkBuffer, ?[*]const u64) callconv(.c) void,
    vkCmdCopyBufferToImage: *const fn (VkCommandBuffer, VkBuffer, VkImage, u32, u32, ?[*]const VkBufferImageCopy) callconv(.c) void,
    vkCreateSampler: *const fn (VkDevice, *const VkSamplerCreateInfo, ?*const anyopaque, *VkSampler) callconv(.c) VkResult,
    vkDestroyRenderPass: *const fn (VkDevice, VkRenderPass, ?*const anyopaque) callconv(.c) void,
    vkDestroyFramebuffer: *const fn (VkDevice, VkFramebuffer, ?*const anyopaque) callconv(.c) void,
    vkEnumerateInstanceExtensionProperties: *const fn (?*const anyopaque, *u32, ?*anyopaque) callconv(.c) VkResult,
    vkEnumerateDeviceExtensionProperties: *const fn (VkPhysicalDevice, ?*const anyopaque, *u32, ?*anyopaque) callconv(.c) VkResult,
    vkDestroySampler: *const fn (VkDevice, VkSampler, ?*const anyopaque) callconv(.c) void,
    // ---- WSI: surface + swapchain ----
    vkCreateWaylandSurfaceKHR: *const fn (VkInstance, *const anyopaque, ?*const anyopaque, *VkSurfaceKHR) callconv(.c) VkResult,
    vkDestroySurfaceKHR: *const fn (VkInstance, VkSurfaceKHR, ?*const anyopaque) callconv(.c) void,
    vkGetPhysicalDeviceSurfaceSupportKHR: *const fn (VkPhysicalDevice, u32, VkSurfaceKHR, *VkBool32) callconv(.c) VkResult,
    vkGetPhysicalDeviceSurfaceCapabilitiesKHR: *const fn (VkPhysicalDevice, VkSurfaceKHR, *anyopaque) callconv(.c) VkResult,
    vkGetPhysicalDeviceSurfaceFormatsKHR: *const fn (VkPhysicalDevice, VkSurfaceKHR, *u32, ?*anyopaque) callconv(.c) VkResult,
    vkGetPhysicalDeviceSurfacePresentModesKHR: *const fn (VkPhysicalDevice, VkSurfaceKHR, *u32, ?*u32) callconv(.c) VkResult,
    vkCreateSwapchainKHR: *const fn (VkDevice, *const anyopaque, ?*const anyopaque, *VkSwapchainKHR) callconv(.c) VkResult,
    vkDestroySwapchainKHR: *const fn (VkDevice, VkSwapchainKHR, ?*const anyopaque) callconv(.c) void,
    vkGetSwapchainImagesKHR: *const fn (VkDevice, VkSwapchainKHR, *u32, ?*VkImage) callconv(.c) VkResult,
    vkAcquireNextImageKHR: *const fn (VkDevice, VkSwapchainKHR, u64, VkSemaphore, ?*anyopaque, *u32) callconv(.c) VkResult,
    vkQueuePresentKHR: *const fn (VkQueue, *const VkPresentInfoKHR) callconv(.c) VkResult,
    vkGetDeviceProcAddr: *const fn (VkDevice, [*:0]const u8) callconv(.c) ?*const anyopaque,
};

pub fn load() !Vulkan {
    // SONAME first (works on Debian/Ubuntu via ldconfig cache); absolute
    // Arch path as fallback.
    const handle = std.c.dlopen("libvulkan.so.1", .{ .LAZY = true }) orelse
        std.c.dlopen("/usr/lib/libvulkan.so.1", .{ .LAZY = true }) orelse
        return error.DlOpenFailed;

    const create_instance = std.c.dlsym(handle, "vkCreateInstance") orelse return error.DlsymFailed;
    const enumerate_physical_devices = std.c.dlsym(handle, "vkEnumeratePhysicalDevices") orelse return error.DlsymFailed;
    const get_physical_device_queue_family_properties = std.c.dlsym(handle, "vkGetPhysicalDeviceQueueFamilyProperties") orelse return error.DlsymFailed;
    const create_device = std.c.dlsym(handle, "vkCreateDevice") orelse return error.DlsymFailed;
    const get_device_queue = std.c.dlsym(handle, "vkGetDeviceQueue") orelse return error.DlsymFailed;
    const destroy_device = std.c.dlsym(handle, "vkDestroyDevice") orelse return error.DlsymFailed;
    const destroy_instance = std.c.dlsym(handle, "vkDestroyInstance") orelse return error.DlsymFailed;

    // Command buffers
    const create_command_pool = std.c.dlsym(handle, "vkCreateCommandPool") orelse return error.DlsymFailed;
    const allocate_command_buffers = std.c.dlsym(handle, "vkAllocateCommandBuffers") orelse return error.DlsymFailed;
    const begin_command_buffer = std.c.dlsym(handle, "vkBeginCommandBuffer") orelse return error.DlsymFailed;
    const end_command_buffer = std.c.dlsym(handle, "vkEndCommandBuffer") orelse return error.DlsymFailed;
    const cmd_bind_pipeline = std.c.dlsym(handle, "vkCmdBindPipeline") orelse return error.DlsymFailed;
    const cmd_dispatch = std.c.dlsym(handle, "vkCmdDispatch") orelse return error.DlsymFailed;
    const cmd_pipeline_barrier = std.c.dlsym(handle, "vkCmdPipelineBarrier") orelse return error.DlsymFailed;
    const cmd_copy_image_to_buffer = std.c.dlsym(handle, "vkCmdCopyImageToBuffer") orelse return error.DlsymFailed;
    const queue_submit = std.c.dlsym(handle, "vkQueueSubmit") orelse return error.DlsymFailed;
    const queue_wait_idle = std.c.dlsym(handle, "vkQueueWaitIdle") orelse return error.DlsymFailed;
    const device_wait_idle = std.c.dlsym(handle, "vkDeviceWaitIdle") orelse return error.DlsymFailed;
    const destroy_command_pool = std.c.dlsym(handle, "vkDestroyCommandPool") orelse return error.DlsymFailed;

    // Images and memory
    const create_image = std.c.dlsym(handle, "vkCreateImage") orelse return error.DlsymFailed;
    const get_image_memory_requirements = std.c.dlsym(handle, "vkGetImageMemoryRequirements") orelse return error.DlsymFailed;
    const bind_image_memory = std.c.dlsym(handle, "vkBindImageMemory") orelse return error.DlsymFailed;
    const create_image_view = std.c.dlsym(handle, "vkCreateImageView") orelse return error.DlsymFailed;
    const create_buffer = std.c.dlsym(handle, "vkCreateBuffer") orelse return error.DlsymFailed;
    const get_buffer_memory_requirements = std.c.dlsym(handle, "vkGetBufferMemoryRequirements") orelse return error.DlsymFailed;
    const bind_buffer_memory = std.c.dlsym(handle, "vkBindBufferMemory") orelse return error.DlsymFailed;
    const allocate_memory = std.c.dlsym(handle, "vkAllocateMemory") orelse return error.DlsymFailed;
    const map_memory = std.c.dlsym(handle, "vkMapMemory") orelse return error.DlsymFailed;
    const unmap_memory = std.c.dlsym(handle, "vkUnmapMemory") orelse return error.DlsymFailed;
    const destroy_image = std.c.dlsym(handle, "vkDestroyImage") orelse return error.DlsymFailed;
    const destroy_image_view = std.c.dlsym(handle, "vkDestroyImageView") orelse return error.DlsymFailed;
    const destroy_buffer = std.c.dlsym(handle, "vkDestroyBuffer") orelse return error.DlsymFailed;
    const free_memory = std.c.dlsym(handle, "vkFreeMemory") orelse return error.DlsymFailed;

    // Shaders and pipelines
    const create_shader_module = std.c.dlsym(handle, "vkCreateShaderModule") orelse return error.DlsymFailed;
    const create_compute_pipelines = std.c.dlsym(handle, "vkCreateComputePipelines") orelse return error.DlsymFailed;
    const create_pipeline_layout = std.c.dlsym(handle, "vkCreatePipelineLayout") orelse return error.DlsymFailed;
    const destroy_shader_module = std.c.dlsym(handle, "vkDestroyShaderModule") orelse return error.DlsymFailed;
    const destroy_pipeline = std.c.dlsym(handle, "vkDestroyPipeline") orelse return error.DlsymFailed;
    const destroy_pipeline_layout = std.c.dlsym(handle, "vkDestroyPipelineLayout") orelse return error.DlsymFailed;

    // Sync
    const create_semaphore = std.c.dlsym(handle, "vkCreateSemaphore") orelse return error.DlsymFailed;
    const destroy_semaphore = std.c.dlsym(handle, "vkDestroySemaphore") orelse return error.DlsymFailed;
    const create_fence = std.c.dlsym(handle, "vkCreateFence") orelse return error.DlsymFailed;
    const destroy_fence = std.c.dlsym(handle, "vkDestroyFence") orelse return error.DlsymFailed;
    const wait_for_fences = std.c.dlsym(handle, "vkWaitForFences") orelse return error.DlsymFailed;
    const reset_fences = std.c.dlsym(handle, "vkResetFences") orelse return error.DlsymFailed;

    // Memory properties and descriptors
    const get_physical_device_memory_properties = std.c.dlsym(handle, "vkGetPhysicalDeviceMemoryProperties") orelse return error.DlsymFailed;
    const create_descriptor_set_layout = std.c.dlsym(handle, "vkCreateDescriptorSetLayout") orelse return error.DlsymFailed;
    const destroy_descriptor_set_layout = std.c.dlsym(handle, "vkDestroyDescriptorSetLayout") orelse return error.DlsymFailed;
    const create_descriptor_pool = std.c.dlsym(handle, "vkCreateDescriptorPool") orelse return error.DlsymFailed;
    const destroy_descriptor_pool = std.c.dlsym(handle, "vkDestroyDescriptorPool") orelse return error.DlsymFailed;
    const allocate_descriptor_sets = std.c.dlsym(handle, "vkAllocateDescriptorSets") orelse return error.DlsymFailed;
    const update_descriptor_sets = std.c.dlsym(handle, "vkUpdateDescriptorSets") orelse return error.DlsymFailed;
    const cmd_bind_descriptor_sets = std.c.dlsym(handle, "vkCmdBindDescriptorSets") orelse return error.DlsymFailed;
    const cmd_push_constants = std.c.dlsym(handle, "vkCmdPushConstants") orelse return error.DlsymFailed;

    // Graphics pipeline and render pass
    const create_render_pass = std.c.dlsym(handle, "vkCreateRenderPass") orelse return error.DlsymFailed;
    const create_framebuffer = std.c.dlsym(handle, "vkCreateFramebuffer") orelse return error.DlsymFailed;
    const create_graphics_pipelines = std.c.dlsym(handle, "vkCreateGraphicsPipelines") orelse return error.DlsymFailed;
    const cmd_begin_render_pass = std.c.dlsym(handle, "vkCmdBeginRenderPass") orelse return error.DlsymFailed;
    const cmd_draw = std.c.dlsym(handle, "vkCmdDraw") orelse return error.DlsymFailed;
    const cmd_end_render_pass = std.c.dlsym(handle, "vkCmdEndRenderPass") orelse return error.DlsymFailed;
    const cmd_bind_vertex_buffers = std.c.dlsym(handle, "vkCmdBindVertexBuffers") orelse return error.DlsymFailed;
    const cmd_copy_buffer_to_image = std.c.dlsym(handle, "vkCmdCopyBufferToImage") orelse return error.DlsymFailed;
    const enum_instance_ext = std.c.dlsym(handle, "vkEnumerateInstanceExtensionProperties") orelse return error.DlsymFailed;
    const enum_device_ext = std.c.dlsym(handle, "vkEnumerateDeviceExtensionProperties") orelse return error.DlsymFailed;
    const create_sampler = std.c.dlsym(handle, "vkCreateSampler") orelse return error.DlsymFailed;
    const create_wayland_surface = std.c.dlsym(handle, "vkCreateWaylandSurfaceKHR") orelse return error.DlsymFailed;
    const destroy_surface = std.c.dlsym(handle, "vkDestroySurfaceKHR") orelse return error.DlsymFailed;
    const get_surf_support = std.c.dlsym(handle, "vkGetPhysicalDeviceSurfaceSupportKHR") orelse return error.DlsymFailed;
    const get_surf_caps = std.c.dlsym(handle, "vkGetPhysicalDeviceSurfaceCapabilitiesKHR") orelse return error.DlsymFailed;
    const get_surf_formats = std.c.dlsym(handle, "vkGetPhysicalDeviceSurfaceFormatsKHR") orelse return error.DlsymFailed;
    const get_surf_present_modes = std.c.dlsym(handle, "vkGetPhysicalDeviceSurfacePresentModesKHR") orelse return error.DlsymFailed;
    const create_swapchain = std.c.dlsym(handle, "vkCreateSwapchainKHR") orelse return error.DlsymFailed;
    const destroy_swapchain = std.c.dlsym(handle, "vkDestroySwapchainKHR") orelse return error.DlsymFailed;
    const get_swapchain_images = std.c.dlsym(handle, "vkGetSwapchainImagesKHR") orelse return error.DlsymFailed;
    const acquire_next_image = std.c.dlsym(handle, "vkAcquireNextImageKHR") orelse return error.DlsymFailed;
    const queue_present = std.c.dlsym(handle, "vkGetDeviceProcAddr") orelse return error.DlsymFailed;
    const destroy_render_pass = std.c.dlsym(handle, "vkDestroyRenderPass") orelse return error.DlsymFailed;
    const destroy_framebuffer = std.c.dlsym(handle, "vkDestroyFramebuffer") orelse return error.DlsymFailed;
    const destroy_sampler = std.c.dlsym(handle, "vkDestroySampler") orelse return error.DlsymFailed;

    return .{
        .handle = handle,
        .vkCreateInstance = @ptrCast(create_instance),
        .vkEnumeratePhysicalDevices = @ptrCast(enumerate_physical_devices),
        .vkGetPhysicalDeviceQueueFamilyProperties = @ptrCast(get_physical_device_queue_family_properties),
        .vkCreateDevice = @ptrCast(create_device),
        .vkGetDeviceQueue = @ptrCast(get_device_queue),
        .vkDestroyDevice = @ptrCast(destroy_device),
        .vkDestroyInstance = @ptrCast(destroy_instance),

        // Command buffers
        .vkCreateCommandPool = @ptrCast(create_command_pool),
        .vkAllocateCommandBuffers = @ptrCast(allocate_command_buffers),
        .vkBeginCommandBuffer = @ptrCast(begin_command_buffer),
        .vkEndCommandBuffer = @ptrCast(end_command_buffer),
        .vkCmdBindPipeline = @ptrCast(cmd_bind_pipeline),
        .vkCmdDispatch = @ptrCast(cmd_dispatch),
        .vkCmdPipelineBarrier = @ptrCast(cmd_pipeline_barrier),
        .vkCmdCopyImageToBuffer = @ptrCast(cmd_copy_image_to_buffer),
        .vkQueueSubmit = @ptrCast(queue_submit),
        .vkQueueWaitIdle = @ptrCast(queue_wait_idle),
        .vkDeviceWaitIdle = @ptrCast(device_wait_idle),
        .vkDestroyCommandPool = @ptrCast(destroy_command_pool),

        // Images and memory
        .vkCreateImage = @ptrCast(create_image),
        .vkGetImageMemoryRequirements = @ptrCast(get_image_memory_requirements),
        .vkBindImageMemory = @ptrCast(bind_image_memory),
        .vkCreateImageView = @ptrCast(create_image_view),
        .vkCreateBuffer = @ptrCast(create_buffer),
        .vkGetBufferMemoryRequirements = @ptrCast(get_buffer_memory_requirements),
        .vkBindBufferMemory = @ptrCast(bind_buffer_memory),
        .vkAllocateMemory = @ptrCast(allocate_memory),
        .vkMapMemory = @ptrCast(map_memory),
        .vkUnmapMemory = @ptrCast(unmap_memory),
        .vkDestroyImage = @ptrCast(destroy_image),
        .vkDestroyImageView = @ptrCast(destroy_image_view),
        .vkDestroyBuffer = @ptrCast(destroy_buffer),
        .vkFreeMemory = @ptrCast(free_memory),

        // Shaders and pipelines
        .vkCreateShaderModule = @ptrCast(create_shader_module),
        .vkCreateComputePipelines = @ptrCast(create_compute_pipelines),
        .vkCreatePipelineLayout = @ptrCast(create_pipeline_layout),
        .vkDestroyShaderModule = @ptrCast(destroy_shader_module),
        .vkDestroyPipeline = @ptrCast(destroy_pipeline),
        .vkDestroyPipelineLayout = @ptrCast(destroy_pipeline_layout),

        // Sync
        .vkCreateSemaphore = @ptrCast(create_semaphore),
        .vkDestroySemaphore = @ptrCast(destroy_semaphore),
        .vkCreateFence = @ptrCast(create_fence),
        .vkDestroyFence = @ptrCast(destroy_fence),
        .vkWaitForFences = @ptrCast(wait_for_fences),
        .vkResetFences = @ptrCast(reset_fences),

        // Memory properties and descriptors
        .vkGetPhysicalDeviceMemoryProperties = @ptrCast(get_physical_device_memory_properties),
        .vkCreateDescriptorSetLayout = @ptrCast(create_descriptor_set_layout),
        .vkDestroyDescriptorSetLayout = @ptrCast(destroy_descriptor_set_layout),
        .vkCreateDescriptorPool = @ptrCast(create_descriptor_pool),
        .vkDestroyDescriptorPool = @ptrCast(destroy_descriptor_pool),
        .vkAllocateDescriptorSets = @ptrCast(allocate_descriptor_sets),
        .vkUpdateDescriptorSets = @ptrCast(update_descriptor_sets),
        .vkCmdBindDescriptorSets = @ptrCast(cmd_bind_descriptor_sets),
        .vkCmdPushConstants = @ptrCast(cmd_push_constants),

        // Graphics pipeline and render pass
        .vkCreateRenderPass = @ptrCast(create_render_pass),
        .vkCreateFramebuffer = @ptrCast(create_framebuffer),
        .vkCreateGraphicsPipelines = @ptrCast(create_graphics_pipelines),
        .vkCmdBeginRenderPass = @ptrCast(cmd_begin_render_pass),
        .vkCmdDraw = @ptrCast(cmd_draw),
        .vkCmdEndRenderPass = @ptrCast(cmd_end_render_pass),
        .vkCmdBindVertexBuffers = @ptrCast(cmd_bind_vertex_buffers),
        .vkCmdCopyBufferToImage = @ptrCast(cmd_copy_buffer_to_image),
        .vkEnumerateInstanceExtensionProperties = @ptrCast(enum_instance_ext),
        .vkEnumerateDeviceExtensionProperties = @ptrCast(enum_device_ext),
        .vkCreateSampler = @ptrCast(create_sampler),
        .vkCreateWaylandSurfaceKHR = @ptrCast(create_wayland_surface),
        .vkDestroySurfaceKHR = @ptrCast(destroy_surface),
        .vkGetPhysicalDeviceSurfaceSupportKHR = @ptrCast(get_surf_support),
        .vkGetPhysicalDeviceSurfaceCapabilitiesKHR = @ptrCast(get_surf_caps),
        .vkGetPhysicalDeviceSurfaceFormatsKHR = @ptrCast(get_surf_formats),
        .vkGetPhysicalDeviceSurfacePresentModesKHR = @ptrCast(get_surf_present_modes),
        .vkCreateSwapchainKHR = @ptrCast(create_swapchain),
        .vkDestroySwapchainKHR = @ptrCast(destroy_swapchain),
        .vkGetSwapchainImagesKHR = @ptrCast(get_swapchain_images),
        .vkAcquireNextImageKHR = @ptrCast(acquire_next_image),
        .vkGetDeviceProcAddr = @ptrCast(queue_present),
        .vkQueuePresentKHR = undefined,
        .vkDestroyRenderPass = @ptrCast(destroy_render_pass),
        .vkDestroyFramebuffer = @ptrCast(destroy_framebuffer),
        .vkDestroySampler = @ptrCast(destroy_sampler),
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

    // WSI instance extensions (best-effort: present on NVIDIA/Mesa, skip if missing)
    var instance_extensions: [2][*:0]const u8 = undefined;
    var iext_count: u32 = 0;
    const ext_names = [2][*:0]const u8{
        "VK_KHR_surface",
        "VK_KHR_wayland_surface",
    };
    var ext_probe: [256]u32 = undefined;
    var ext_count: u32 = 256;
    if (vulkan.vkEnumerateInstanceExtensionProperties(null, &ext_count, null) == VK_SUCCESS) {
        // count only; we just check names we need
        _ = &ext_probe;
    }
    // Check each wanted extension exists; build the enable list from what's there.
    var inst_total: u32 = 0;
    _ = vulkan.vkEnumerateInstanceExtensionProperties(null, &inst_total, null);
    const ext_props = std.heap.page_allocator.alloc(VkExtensionProperties, inst_total) catch return DeviceError.CreateInstanceFailed;
    defer std.heap.page_allocator.free(ext_props);
    var got: u32 = inst_total;
    if (vulkan.vkEnumerateInstanceExtensionProperties(null, &got, ext_props.ptr) == VK_SUCCESS) {
        for (ext_names) |want| {
            var i: u32 = 0;
            while (i < got) : (i += 1) {
                const name_z: [*:0]const u8 = @ptrCast(&ext_props[i].extensionName);
                if (std.mem.eql(u8, std.mem.span(name_z), std.mem.span(want))) {
                    instance_extensions[iext_count] = want;
                    iext_count += 1;
                    break;
                }
            }
        }
    }
    const ext_ptr: ?**const u8 = if (iext_count > 0) @ptrCast(&instance_extensions) else null;

    const instance_info = VkInstanceCreateInfo{
        .sType = VK_STRUCTURE_TYPE_INSTANCE_CREATE_INFO,
        .pNext = null,
        .flags = 0,
        .pApplicationInfo = &app_info,
        .enabledLayerCount = 0,
        .ppEnabledLayerNames = null,
        .enabledExtensionCount = iext_count,
        .ppEnabledExtensionNames = ext_ptr,
    };

    if (vulkan.vkCreateInstance(&instance_info, null, &instance) != VK_SUCCESS) {
        return DeviceError.CreateInstanceFailed;
    }

    var device_count: u32 = 0;
    if (vulkan.vkEnumeratePhysicalDevices(instance, &device_count, null) != VK_SUCCESS or device_count == 0) {
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
    var family_count: u32 = 0;
    vulkan.vkGetPhysicalDeviceQueueFamilyProperties(physical, &family_count, null);
    const families = std.heap.page_allocator.alloc(VkPhysicalDeviceQueueFamilyProperties, family_count) catch {
        vulkan.vkDestroyInstance(instance, null);
        return DeviceError.CreateDeviceFailed;
    };
    defer std.heap.page_allocator.free(families);
    vulkan.vkGetPhysicalDeviceQueueFamilyProperties(physical, &family_count, families.ptr);
    const family_index: u32 = for (families, 0..) |family, index| {
        if (family.queueCount > 0 and (family.queueFlags & VK_QUEUE_GRAPHICS_BIT) != 0) break @intCast(index);
    } else {
        vulkan.vkDestroyInstance(instance, null);
        return DeviceError.NoGraphicsQueue;
    };

    const queue_priority: f32 = 1.0;
    const queue_info = VkDeviceQueueCreateInfo{
        .sType = VK_STRUCTURE_TYPE_DEVICE_QUEUE_CREATE_INFO,
        .pNext = null,
        .flags = 0,
        .queueFamilyIndex = family_index,
        .queueCount = 1,
        .pQueuePriorities = &queue_priority,
    };

    // Device extension: VK_KHR_swapchain (skip if missing)
    var device_extensions: [1][*:0]const u8 = undefined;
    var dext_count: u32 = 0;
    var dext_total: u32 = 0;
    _ = vulkan.vkEnumerateDeviceExtensionProperties(physical, null, &dext_total, null);
    const dext_props = std.heap.page_allocator.alloc(VkExtensionProperties, dext_total) catch return DeviceError.CreateDeviceFailed;
    defer std.heap.page_allocator.free(dext_props);
    var dext_got: u32 = dext_total;
    const enum_rc = vulkan.vkEnumerateDeviceExtensionProperties(physical, null, &dext_got, dext_props.ptr);
    if (enum_rc == VK_SUCCESS) {
        if (std.c.getenv("CIPHER_DEBUG_VKEXT") != null) {
            std.debug.print("cipher: device extensions enumerated: {d}\n", .{dext_got});
            var di: u32 = 0;
            while (di < dext_got) : (di += 1) {
                const nm: [*:0]const u8 = @ptrCast(&dext_props[di].extensionName);
                std.debug.print("cipher: dext[{d}]={s}\n", .{ di, std.mem.span(nm) });
            }
        }
        for (dext_props[0..dext_got]) |*p| {
            if (std.mem.eql(u8, std.mem.span(@as([*:0]const u8, @ptrCast(&p.extensionName))), "VK_KHR_swapchain")) {
                device_extensions[dext_count] = "VK_KHR_swapchain";
                dext_count += 1;
            }
        }
    } else {
        std.debug.print("cipher: vkEnumerateDeviceExtensionProperties failed with {d} (dext_got={d})\n", .{ enum_rc, dext_got });
    }
    const dext_ptr: ?**const u8 = if (dext_count > 0) @ptrCast(&device_extensions) else null;

    const device_info = VkDeviceCreateInfo{
        .sType = VK_STRUCTURE_TYPE_DEVICE_CREATE_INFO,
        .pNext = null,
        .flags = 0,
        .queueCreateInfoCount = 1,
        .pQueueCreateInfos = &queue_info,
        .enabledLayerCount = 0,
        .ppEnabledLayerNames = null,
        .enabledExtensionCount = dext_count,
        .ppEnabledExtensionNames = dext_ptr,
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
    // Present commands must be resolved for this device, not through a
    // process-global symbol that may bypass the selected driver's trampoline.
    const present = vulkan.vkGetDeviceProcAddr(device, "vkQueuePresentKHR") orelse {
        vulkan.vkDestroyDevice(device, null);
        vulkan.vkDestroyInstance(instance, null);
        return DeviceError.CreateDeviceFailed;
    };
    vulkan.vkQueuePresentKHR = @ptrCast(present);
}

pub const DeviceError = error{
    DlOpenFailed,
    DlsymFailed,
    CreateInstanceFailed,
    NoPhysicalDevices,
    EnumerateDevicesFailed,
    CreateDeviceFailed,
    NoGraphicsQueue,
};

test "Vulkan ABI values and queue-family layout match the C API" {
    try std.testing.expectEqual(@as(u32, 103), VK_FORMAT_R32G32_SFLOAT);
    try std.testing.expectEqual(@as(u32, 109), VK_FORMAT_R32G32B32A32_SFLOAT);
    try std.testing.expectEqual(@as(u32, 1000001001), VK_STRUCTURE_TYPE_PRESENT_INFO_KHR);
    try std.testing.expectEqual(@as(usize, 24), @sizeOf(VkPhysicalDeviceQueueFamilyProperties));
    try std.testing.expectEqual(@as(usize, 0), @offsetOf(VkPhysicalDeviceQueueFamilyProperties, "queueFlags"));
    try std.testing.expectEqual(@as(usize, 4), @offsetOf(VkPhysicalDeviceQueueFamilyProperties, "queueCount"));
    try std.testing.expectEqual(@as(usize, 8), @offsetOf(VkPhysicalDeviceQueueFamilyProperties, "timestampValidBits"));
    try std.testing.expectEqual(@as(usize, 12), @offsetOf(VkPhysicalDeviceQueueFamilyProperties, "minImageTransferGranularity"));
}

test "creates Vulkan device and enumerates physical devices" {
    // Verifies Vulkan ICD integration. Requires a working Vulkan driver;
    // prints GPU_SKIP and passes when none is reachable (GPU-less CI).
    var vulkan = load() catch |e| {
        std.debug.print("GPU_SKIP device(inline): {s}\n", .{@errorName(e)});
        return;
    };
    // Don't dlclose or explicitly destroy: process exit handles cleanup,
    // and explicit destruction can crash in the NVIDIA ICD teardown path.
    // All Vulkan creation calls (vkCreateInstance, vkEnumeratePhysicalDevices,
    // vkCreateDevice, vkGetDeviceQueue) are verified to return VK_SUCCESS.

    var device: Device = undefined;
    createDevice(&vulkan, &device) catch |e| {
        std.debug.print("GPU_SKIP device(inline): createDevice {s}\n", .{@errorName(e)});
        return;
    };

    var family_count: u32 = 0;
    vulkan.vkGetPhysicalDeviceQueueFamilyProperties(device.physical, &family_count, null);
    const families = try std.testing.allocator.alloc(VkPhysicalDeviceQueueFamilyProperties, family_count);
    defer std.testing.allocator.free(families);
    vulkan.vkGetPhysicalDeviceQueueFamilyProperties(device.physical, &family_count, families.ptr);
    try std.testing.expect(device.queue_family_index < families.len);
    try std.testing.expect((families[device.queue_family_index].queueFlags & VK_QUEUE_GRAPHICS_BIT) != 0);

    std.debug.print("Vulkan device created: queue_family={d}\n", .{device.queue_family_index});
}
