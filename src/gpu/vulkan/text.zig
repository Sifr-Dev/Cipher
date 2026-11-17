//! GPU text pipeline: a second graphics pipeline that draws glyph quads from
//! a vertex buffer, sampling a device-local R8 atlas texture (uploaded from
//! the CPU atlas built by src/ui/text/atlas.zig). Same present path as
//! frame.zig: render pass into an offscreen color attachment, then
//! vkCmdCopyImageToBuffer into a host-visible buffer (BGRA == wl_shm ARGB8888).
const std = @import("std");
const d = @import("device.zig");
const shader = @import("shader.zig");

pub const Vulkan = d.Vulkan;
pub const Device = d.Device;

/// One quad in pixel coordinates (y-down) + atlas UVs + color.
pub const Quad = struct {
    x: f32,
    y: f32,
    w: f32,
    h: f32,
    u0: f32,
    v0: f32,
    u1: f32,
    v1: f32,
    color: [4]f32,
};

const Vertex = extern struct {
    pos: [2]f32,
    uv: [2]f32,
    color: [4]f32,
};

/// Must match layout(push_constant) in text.vert / text.frag.
pub const PushConstants = extern struct {
    extent: [4]f32, // xy = width/height in pixels
};

const MAX_QUADS: usize = 65536; // a 200x60 terminal = 12k cells -> rects + glyph quads

pub const GpuText = struct {
    width: u32,
    height: u32,
    atlas_w: u32,
    atlas_h: u32,

    image: d.VkImage = undefined,
    image_view: d.VkImageView = undefined,
    image_mem: d.VkDeviceMemory = undefined,
    buffer: d.VkBuffer = undefined,
    buffer_mem: d.VkDeviceMemory = undefined,
    mapped: [*]u8 = undefined,

    atlas_image: d.VkImage = undefined,
    atlas_view: d.VkImageView = undefined,
    atlas_mem: d.VkDeviceMemory = undefined,
    sampler: d.VkSampler = undefined,

    desc_layout: d.VkDescriptorSetLayout = undefined,
    desc_pool: d.VkDescriptorPool = undefined,
    desc_set: d.VkDescriptorSet = undefined,

    vert_module: d.VkShaderModule = undefined,
    frag_module: d.VkShaderModule = undefined,
    render_pass: d.VkRenderPass = undefined,
    framebuffer: d.VkFramebuffer = undefined,
    pipeline_layout: d.VkPipelineLayout = undefined,
    pipeline: d.VkPipeline = undefined,

    vb: d.VkBuffer = undefined,
    vb_mem: d.VkDeviceMemory = undefined,
    vb_mapped: [*]u8 = undefined,

    pool: d.VkCommandPool = undefined,
    cmd: d.VkCommandBuffer = undefined,
    fence: d.VkFence = undefined,

    fn findMemoryType(vk: *Vulkan, dev: *const Device, type_bits: u32, properties: u32) !u32 {
        var props: d.VkPhysicalDeviceMemoryProperties = undefined;
        vk.vkGetPhysicalDeviceMemoryProperties(dev.physical, &props);
        var i: u32 = 0;
        while (i < props.memoryTypeCount) : (i += 1) {
            const bit: u32 = @as(u32, 1) << @intCast(i);
            if ((type_bits & bit) != 0 and
                (props.memoryTypes[i].propertyFlags & properties) == properties)
            {
                return i;
            }
        }
        return error.NoSuitableMemoryType;
    }

    fn createModule(vk: *Vulkan, dev_handle: d.VkDevice, spv: []const u32) !d.VkShaderModule {
        const info = d.VkShaderModuleCreateInfo{
            .sType = d.VK_STRUCTURE_TYPE_SHADER_MODULE_CREATE_INFO,
            .pNext = null,
            .flags = 0,
            .codeSize = spv.len * 4,
            .pCode = @ptrCast(spv.ptr),
        };
        var module: d.VkShaderModule = undefined;
        if (vk.vkCreateShaderModule(dev_handle, &info, null, &module) != d.VK_SUCCESS)
            return error.CreateShaderModuleFailed;
        return module;
    }

    fn makeHostBuffer(vk: *Vulkan, dev: *const Device, size: u64, usage: u32) !struct { d.VkBuffer, d.VkDeviceMemory, [*]u8 } {
        const dev_handle = dev.device;
        const binfo = d.VkBufferCreateInfo{
            .sType = d.VK_STRUCTURE_TYPE_BUFFER_CREATE_INFO,
            .pNext = null,
            .flags = 0,
            .size = size,
            .usage = usage,
            .sharingMode = d.VK_SHARING_MODE_EXCLUSIVE,
            .queueFamilyIndexCount = 0,
            .pQueueFamilyIndices = null,
        };
        var buf: d.VkBuffer = undefined;
        const rcs = vk.vkCreateBuffer(dev_handle, &binfo, null, &buf);
        if (rcs != d.VK_SUCCESS)
            return error.CreateBufferFailed;
        var reqs: d.VkMemoryRequirements = undefined;
        vk.vkGetBufferMemoryRequirements(dev_handle, buf, &reqs);
        const mt = try findMemoryType(vk, dev, reqs.memoryTypeBits, d.VK_MEMORY_PROPERTY_HOST_VISIBLE_BIT | d.VK_MEMORY_PROPERTY_HOST_COHERENT_BIT);
        const ainfo = d.VkMemoryAllocateInfo{
            .sType = d.VK_STRUCTURE_TYPE_MEMORY_ALLOCATE_INFO,
            .pNext = null,
            .allocationSize = reqs.size,
            .memoryTypeIndex = mt,
        };
        var mem: d.VkDeviceMemory = undefined;
        if (vk.vkAllocateMemory(dev_handle, &ainfo, null, &mem) != d.VK_SUCCESS)
            return error.AllocateMemoryFailed;
        if (vk.vkBindBufferMemory(dev_handle, buf, mem, 0) != d.VK_SUCCESS)
            return error.BindBufferMemoryFailed;
        var mapped: *anyopaque = undefined;
        if (vk.vkMapMemory(dev_handle, mem, 0, size, 0, &mapped) != d.VK_SUCCESS)
            return error.MapMemoryFailed;
        return .{ buf, mem, @ptrCast(mapped) };
    }

    fn makeColorTarget(vk: *Vulkan, dev: *const Device, width: u32, height: u32) !struct { d.VkImage, d.VkImageView, d.VkDeviceMemory } {
        const dev_handle = dev.device;
        const image_info = d.VkImageCreateInfo{
            .sType = d.VK_STRUCTURE_TYPE_IMAGE_CREATE_INFO,
            .pNext = null,
            .flags = 0,
            .imageType = d.VK_IMAGE_TYPE_2D,
            .format = d.VK_FORMAT_R8G8B8A8_UNORM,
            .extent = .{ .width = width, .height = height, .depth = 1 },
            .mipLevels = 1,
            .arrayLayers = 1,
            .samples = d.VK_SAMPLE_COUNT_1_BIT,
            .tiling = d.VK_IMAGE_TILING_OPTIMAL,
            .usage = d.VK_IMAGE_USAGE_COLOR_ATTACHMENT_BIT | d.VK_IMAGE_USAGE_TRANSFER_SRC_BIT,
            .sharingMode = d.VK_SHARING_MODE_EXCLUSIVE,
            .queueFamilyIndexCount = 0,
            .pQueueFamilyIndices = null,
            .initialLayout = d.VK_IMAGE_LAYOUT_UNDEFINED,
        };
        var image: d.VkImage = undefined;
        if (vk.vkCreateImage(dev_handle, &image_info, null, &image) != d.VK_SUCCESS)
            return error.CreateImageFailed;
        var reqs: d.VkMemoryRequirements = undefined;
        vk.vkGetImageMemoryRequirements(dev_handle, image, &reqs);
        const mt = try findMemoryType(vk, dev, reqs.memoryTypeBits, d.VK_MEMORY_PROPERTY_DEVICE_LOCAL_BIT);
        const ainfo = d.VkMemoryAllocateInfo{
            .sType = d.VK_STRUCTURE_TYPE_MEMORY_ALLOCATE_INFO,
            .pNext = null,
            .allocationSize = reqs.size,
            .memoryTypeIndex = mt,
        };
        var mem: d.VkDeviceMemory = undefined;
        if (vk.vkAllocateMemory(dev_handle, &ainfo, null, &mem) != d.VK_SUCCESS)
            return error.AllocateImageMemoryFailed;
        if (vk.vkBindImageMemory(dev_handle, image, mem, 0) != d.VK_SUCCESS)
            return error.BindImageMemoryFailed;
        const view_info = d.VkImageViewCreateInfo{
            .sType = d.VK_STRUCTURE_TYPE_IMAGE_VIEW_CREATE_INFO,
            .pNext = null,
            .flags = 0,
            .image = image,
            .viewType = d.VK_IMAGE_VIEW_TYPE_2D,
            .format = d.VK_FORMAT_R8G8B8A8_UNORM,
            .components = .{
                .r = d.VK_COMPONENT_SWIZZLE_IDENTITY,
                .g = d.VK_COMPONENT_SWIZZLE_IDENTITY,
                .b = d.VK_COMPONENT_SWIZZLE_IDENTITY,
                .a = d.VK_COMPONENT_SWIZZLE_IDENTITY,
            },
            .subresourceRange = .{
                .aspectMask = d.VK_IMAGE_ASPECT_COLOR_BIT,
                .baseMipLevel = 0,
                .levelCount = 1,
                .baseArrayLayer = 0,
                .layerCount = 1,
            },
        };
        var view: d.VkImageView = undefined;
        if (vk.vkCreateImageView(dev_handle, &view_info, null, &view) != d.VK_SUCCESS)
            return error.CreateImageViewFailed;
        return .{ image, view, mem };
    }

    fn makeRenderPass(vk: *Vulkan, dev: *const Device) !d.VkRenderPass {
        const dev_handle = dev.device;
        const attachment = d.VkAttachmentDescription{
            .flags = 0,
            .format = d.VK_FORMAT_R8G8B8A8_UNORM,
            .samples = d.VK_SAMPLE_COUNT_1_BIT,
            .loadOp = d.VK_ATTACHMENT_LOAD_OP_CLEAR,
            .storeOp = d.VK_ATTACHMENT_STORE_OP_STORE,
            .stencilLoadOp = 0,
            .stencilStoreOp = 0,
            .initialLayout = d.VK_IMAGE_LAYOUT_UNDEFINED,
            .finalLayout = d.VK_IMAGE_LAYOUT_TRANSFER_SRC_OPTIMAL,
        };
        const att_ref = d.VkAttachmentReference{
            .attachment = 0,
            .layout = d.VK_IMAGE_LAYOUT_COLOR_ATTACHMENT_OPTIMAL,
        };
        const subpass = d.VkSubpassDescription{
            .flags = 0,
            .pipelineBindPoint = d.VK_PIPELINE_BIND_POINT_GRAPHICS,
            .inputAttachmentCount = 0,
            .pInputAttachments = null,
            .colorAttachmentCount = 1,
            .pColorAttachments = @ptrCast(&att_ref),
            .pResolveAttachments = null,
            .pDepthStencilAttachment = null,
            .preserveAttachmentCount = 0,
            .pPreserveAttachments = null,
        };
        const dependency = d.VkSubpassDependency{
            .srcSubpass = d.VK_SUBPASS_EXTERNAL,
            .dstSubpass = 0,
            .srcStageMask = d.VK_PIPELINE_STAGE_COLOR_ATTACHMENT_OUTPUT_BIT,
            .dstStageMask = d.VK_PIPELINE_STAGE_COLOR_ATTACHMENT_OUTPUT_BIT,
            .srcAccessMask = 0,
            .dstAccessMask = d.VK_ACCESS_COLOR_ATTACHMENT_WRITE_BIT,
            .dependencyFlags = 0,
        };
        const rp_info = d.VkRenderPassCreateInfo{
            .sType = d.VK_STRUCTURE_TYPE_RENDER_PASS_CREATE_INFO,
            .pNext = null,
            .flags = 0,
            .attachmentCount = 1,
            .pAttachments = @ptrCast(&attachment),
            .subpassCount = 1,
            .pSubpasses = @ptrCast(&subpass),
            .dependencyCount = 1,
            .pDependencies = @ptrCast(&dependency),
        };
        var rp: d.VkRenderPass = undefined;
        if (vk.vkCreateRenderPass(dev_handle, &rp_info, null, &rp) != d.VK_SUCCESS)
            return error.CreateRenderPassFailed;
        return rp;
    }

    pub fn init(vk: *Vulkan, dev: *const Device, width: u32, height: u32, atlas_w: u32, atlas_h: u32) !GpuText {
        var self = @import("zero.zig").zeroed(GpuText);
        self.width = width;
        self.height = height;
        self.atlas_w = atlas_w;
        self.atlas_h = atlas_h;
        const dev_handle = dev.device;
        const family = dev.queue_family_index;
        const size: u64 = @as(u64, width) * height * 4;

        // Color target + host staging buffer.
        const target = try makeColorTarget(vk, dev, width, height);
        self.image = target[0];
        self.image_view = target[1];
        self.image_mem = target[2];
        const stage = try makeHostBuffer(vk, dev, size, d.VK_IMAGE_USAGE_TRANSFER_DST_BIT);
        self.buffer = stage[0];
        self.buffer_mem = stage[1];
        self.mapped = stage[2];

        // R8 atlas texture (device local) + view + sampler.
        const atlas_info = d.VkImageCreateInfo{
            .sType = d.VK_STRUCTURE_TYPE_IMAGE_CREATE_INFO,
            .pNext = null,
            .flags = 0,
            .imageType = d.VK_IMAGE_TYPE_2D,
            .format = d.VK_FORMAT_R8_UNORM,
            .extent = .{ .width = atlas_w, .height = atlas_h, .depth = 1 },
            .mipLevels = 1,
            .arrayLayers = 1,
            .samples = d.VK_SAMPLE_COUNT_1_BIT,
            .tiling = d.VK_IMAGE_TILING_OPTIMAL,
            .usage = d.VK_IMAGE_USAGE_TRANSFER_DST_BIT | d.VK_IMAGE_USAGE_SAMPLED_BIT,
            .sharingMode = d.VK_SHARING_MODE_EXCLUSIVE,
            .queueFamilyIndexCount = 0,
            .pQueueFamilyIndices = null,
            .initialLayout = d.VK_IMAGE_LAYOUT_UNDEFINED,
        };
        if (vk.vkCreateImage(dev_handle, &atlas_info, null, &self.atlas_image) != d.VK_SUCCESS)
            return error.CreateImageFailed;
        var areqs: d.VkMemoryRequirements = undefined;
        vk.vkGetImageMemoryRequirements(dev_handle, self.atlas_image, &areqs);
        const amt = try findMemoryType(vk, dev, areqs.memoryTypeBits, d.VK_MEMORY_PROPERTY_DEVICE_LOCAL_BIT);
        const aainfo = d.VkMemoryAllocateInfo{
            .sType = d.VK_STRUCTURE_TYPE_MEMORY_ALLOCATE_INFO,
            .pNext = null,
            .allocationSize = areqs.size,
            .memoryTypeIndex = amt,
        };
        if (vk.vkAllocateMemory(dev_handle, &aainfo, null, &self.atlas_mem) != d.VK_SUCCESS)
            return error.AllocateImageMemoryFailed;
        if (vk.vkBindImageMemory(dev_handle, self.atlas_image, self.atlas_mem, 0) != d.VK_SUCCESS)
            return error.BindImageMemoryFailed;
        const aview_info = d.VkImageViewCreateInfo{
            .sType = d.VK_STRUCTURE_TYPE_IMAGE_VIEW_CREATE_INFO,
            .pNext = null,
            .flags = 0,
            .image = self.atlas_image,
            .viewType = d.VK_IMAGE_VIEW_TYPE_2D,
            .format = d.VK_FORMAT_R8_UNORM,
            .components = .{
                .r = d.VK_COMPONENT_SWIZZLE_IDENTITY,
                .g = d.VK_COMPONENT_SWIZZLE_IDENTITY,
                .b = d.VK_COMPONENT_SWIZZLE_IDENTITY,
                .a = d.VK_COMPONENT_SWIZZLE_IDENTITY,
            },
            .subresourceRange = .{
                .aspectMask = d.VK_IMAGE_ASPECT_COLOR_BIT,
                .baseMipLevel = 0,
                .levelCount = 1,
                .baseArrayLayer = 0,
                .layerCount = 1,
            },
        };
        if (vk.vkCreateImageView(dev_handle, &aview_info, null, &self.atlas_view) != d.VK_SUCCESS)
            return error.CreateImageViewFailed;
        const sampler_info = d.VkSamplerCreateInfo{
            .sType = d.VK_STRUCTURE_TYPE_SAMPLER_CREATE_INFO,
            .pNext = null,
            .flags = 0,
            .magFilter = d.VK_SAMPLER_FILTER_LINEAR,
            .minFilter = d.VK_SAMPLER_FILTER_LINEAR,
            .mipmapMode = d.VK_SAMPLER_MIPMAP_MODE_NEAREST,
            .addressModeU = d.VK_SAMPLER_ADDRESS_MODE_CLAMP_TO_EDGE,
            .addressModeV = d.VK_SAMPLER_ADDRESS_MODE_CLAMP_TO_EDGE,
            .addressModeW = d.VK_SAMPLER_ADDRESS_MODE_CLAMP_TO_EDGE,
            .mipLodBias = 0,
            .anisotropyEnable = 0,
            .maxAnisotropy = 1,
            .compareEnable = 0,
            .compareOp = 0,
            .minLod = 0,
            .maxLod = 1,
            .borderColor = 0,
            .unnormalizedCoordinates = 0,
        };
        if (vk.vkCreateSampler(dev_handle, &sampler_info, null, &self.sampler) != d.VK_SUCCESS)
            return error.CreateSamplerFailed;

        // Descriptor set: binding 0 = combined image sampler (atlas).
        const binding = d.VkDescriptorSetLayoutBinding{
            .binding = 0,
            .descriptorType = d.VK_DESCRIPTOR_TYPE_COMBINED_IMAGE_SAMPLER,
            .descriptorCount = 1,
            .stageFlags = d.VK_SHADER_STAGE_FRAGMENT_BIT,
            .pImmutableSamplers = null,
        };
        const dl_info = d.VkDescriptorSetLayoutCreateInfo{
            .sType = d.VK_STRUCTURE_TYPE_DESCRIPTOR_SET_LAYOUT_CREATE_INFO,
            .pNext = null,
            .flags = 0,
            .bindingCount = 1,
            .pBindings = @ptrCast(&binding),
        };
        if (vk.vkCreateDescriptorSetLayout(dev_handle, &dl_info, null, &self.desc_layout) != d.VK_SUCCESS)
            return error.CreateDescriptorSetLayoutFailed;
        const pool_size = d.VkDescriptorPoolSize{
            .type = d.VK_DESCRIPTOR_TYPE_COMBINED_IMAGE_SAMPLER,
            .descriptorCount = 1,
        };
        const dp_info = d.VkDescriptorPoolCreateInfo{
            .sType = d.VK_STRUCTURE_TYPE_DESCRIPTOR_POOL_CREATE_INFO,
            .pNext = null,
            .flags = 0,
            .maxSets = 1,
            .poolSizeCount = 1,
            .pPoolSizes = @ptrCast(&pool_size),
        };
        if (vk.vkCreateDescriptorPool(dev_handle, &dp_info, null, &self.desc_pool) != d.VK_SUCCESS)
            return error.CreateDescriptorPoolFailed;
        const ds_info = d.VkDescriptorSetAllocateInfo{
            .sType = d.VK_STRUCTURE_TYPE_DESCRIPTOR_SET_ALLOCATE_INFO,
            .pNext = null,
            .descriptorPool = self.desc_pool,
            .descriptorSetCount = 1,
            .pSetLayouts = @ptrCast(&self.desc_layout),
        };
        if (vk.vkAllocateDescriptorSets(dev_handle, &ds_info, &self.desc_set) != d.VK_SUCCESS)
            return error.AllocateDescriptorSetsFailed;
        const img_info = d.VkDescriptorImageInfo{
            .sampler = self.sampler,
            .imageView = self.atlas_view,
            .imageLayout = d.VK_IMAGE_LAYOUT_SHADER_READ_ONLY_OPTIMAL,
        };
        const write = d.VkWriteDescriptorSet{
            .sType = d.VK_STRUCTURE_TYPE_WRITE_DESCRIPTOR_SET,
            .pNext = null,
            .dstSet = self.desc_set,
            .dstBinding = 0,
            .dstArrayElement = 0,
            .descriptorCount = 1,
            .descriptorType = d.VK_DESCRIPTOR_TYPE_COMBINED_IMAGE_SAMPLER,
            .pImageInfo = @ptrCast(&img_info),
            .pBufferInfo = null,
            .pTexelBufferView = null,
        };
        vk.vkUpdateDescriptorSets(dev_handle, 1, @ptrCast(&write), 0, null);

        // Render pass + framebuffer (same shape as frame.zig).
        self.render_pass = try makeRenderPass(vk, dev);
        const fb_info = d.VkFramebufferCreateInfo{
            .sType = d.VK_STRUCTURE_TYPE_FRAMEBUFFER_CREATE_INFO,
            .pNext = null,
            .flags = 0,
            .renderPass = self.render_pass,
            .attachmentCount = 1,
            .pAttachments = @ptrCast(&self.image_view),
            .width = width,
            .height = height,
            .layers = 1,
        };
        if (vk.vkCreateFramebuffer(dev_handle, &fb_info, null, &self.framebuffer) != d.VK_SUCCESS)
            return error.CreateFramebufferFailed;

        // Shaders + pipeline layout (set 0 + 24-byte push constants).
        self.vert_module = try createModule(vk, dev_handle, shader.text_vert_spv);
        self.frag_module = try createModule(vk, dev_handle, shader.text_frag_spv);
        const push_range = d.VkPushConstantRange{
            .stageFlags = d.VK_SHADER_STAGE_VERTEX_BIT | d.VK_SHADER_STAGE_FRAGMENT_BIT,
            .offset = 0,
            .size = @sizeOf(PushConstants),
        };
        const pl_info = d.VkPipelineLayoutCreateInfo{
            .sType = d.VK_STRUCTURE_TYPE_PIPELINE_LAYOUT_CREATE_INFO,
            .pNext = null,
            .flags = 0,
            .setLayoutCount = 1,
            .pSetLayouts = @ptrCast(&self.desc_layout),
            .pushConstantRangeCount = 1,
            .pPushConstantRanges = @ptrCast(&push_range),
        };
        if (vk.vkCreatePipelineLayout(dev_handle, &pl_info, null, &self.pipeline_layout) != d.VK_SUCCESS)
            return error.CreatePipelineLayoutFailed;

        // Vertex buffer (host visible): 6 vertices per quad.
        const vb = try makeHostBuffer(vk, dev, MAX_QUADS * 6 * @sizeOf(Vertex), d.VK_BUFFER_USAGE_VERTEX_BUFFER_BIT);
        self.vb = vb[0];
        self.vb_mem = vb[1];
        self.vb_mapped = vb[2];

        // Graphics pipeline with vertex input.
        const stages = [_]d.VkPipelineShaderStageCreateInfo{
            .{
                .sType = d.VK_STRUCTURE_TYPE_PIPELINE_SHADER_STAGE_CREATE_INFO,
                .pNext = null,
                .flags = 0,
                .stage = d.VK_SHADER_STAGE_VERTEX_BIT,
                .module = self.vert_module,
                .pName = &"main"[0],
                .pSpecializationInfo = null,
            },
            .{
                .sType = d.VK_STRUCTURE_TYPE_PIPELINE_SHADER_STAGE_CREATE_INFO,
                .pNext = null,
                .flags = 0,
                .stage = d.VK_SHADER_STAGE_FRAGMENT_BIT,
                .module = self.frag_module,
                .pName = &"main"[0],
                .pSpecializationInfo = null,
            },
        };
        const vb_binding = d.VkPipelineVertexInputBindingDescription{
            .binding = 0,
            .stride = @sizeOf(Vertex),
            .inputRate = d.VK_VERTEX_INPUT_RATE_VERTEX,
        };
        const vb_attrs = [_]d.VkPipelineVertexInputAttributeDescription{
            .{ .location = 0, .binding = 0, .format = d.VK_FORMAT_R32G32_SFLOAT, .offset = 0 },
            .{ .location = 1, .binding = 0, .format = d.VK_FORMAT_R32G32_SFLOAT, .offset = 8 },
            .{ .location = 2, .binding = 0, .format = d.VK_FORMAT_R32G32B32A32_SFLOAT, .offset = 16 },
        };
        const vi = d.VkPipelineVertexInputStateCreateInfo{
            .sType = d.VK_STRUCTURE_TYPE_PIPELINE_VERTEX_INPUT_STATE_CREATE_INFO,
            .pNext = null,
            .flags = 0,
            .vertexBindingDescriptionCount = 1,
            .pVertexBindingDescriptions = @ptrCast(&vb_binding),
            .vertexAttributeDescriptionCount = 3,
            .pVertexAttributeDescriptions = @ptrCast(&vb_attrs),
        };
        const ia = d.VkPipelineInputAssemblyStateCreateInfo{
            .sType = d.VK_STRUCTURE_TYPE_PIPELINE_INPUT_ASSEMBLY_STATE_CREATE_INFO,
            .pNext = null,
            .flags = 0,
            .topology = d.VK_PRIMITIVE_TOPOLOGY_TRIANGLE_LIST,
            .primitiveRestartEnable = 0,
        };
        const viewport = d.VkViewport{ .x = 0, .y = 0, .width = @floatFromInt(width), .height = @floatFromInt(height), .minDepth = 0, .maxDepth = 1 };
        const scissor = d.VkRect2D{ .offset = .{ .x = 0, .y = 0 }, .extent = .{ .width = width, .height = height } };
        const vps = d.VkPipelineViewportStateCreateInfo{
            .sType = d.VK_STRUCTURE_TYPE_PIPELINE_VIEWPORT_STATE_CREATE_INFO,
            .pNext = null,
            .flags = 0,
            .viewportCount = 1,
            .pViewports = @ptrCast(&viewport),
            .scissorCount = 1,
            .pScissors = @ptrCast(&scissor),
        };
        const rs = d.VkPipelineRasterizationStateCreateInfo{
            .sType = d.VK_STRUCTURE_TYPE_PIPELINE_RASTERIZATION_STATE_CREATE_INFO,
            .pNext = null,
            .flags = 0,
            .depthClampEnable = 0,
            .rasterizerDiscardEnable = 0,
            .polygonMode = d.VK_POLYGON_MODE_FILL,
            .cullMode = d.VK_CULL_MODE_NONE,
            .frontFace = d.VK_FRONT_FACE_COUNTER_CLOCKWISE,
            .depthBiasEnable = 0,
            .depthBiasConstantFactor = 0,
            .depthBiasClamp = 0,
            .depthBiasSlopeFactor = 0,
            .lineWidth = 1.0,
        };
        const ms = d.VkPipelineMultisampleStateCreateInfo{
            .sType = d.VK_STRUCTURE_TYPE_PIPELINE_MULTISAMPLE_STATE_CREATE_INFO,
            .pNext = null,
            .flags = 0,
            .rasterizationSamples = d.VK_SAMPLE_COUNT_1_BIT,
            .sampleShadingEnable = 0,
            .minSampleShading = 0,
            .pSampleMask = null,
            .alphaToCoverageEnable = 0,
            .alphaToOneEnable = 0,
        };
        const cba = d.VkPipelineColorBlendAttachmentState{
            .blendEnable = 0,
            .srcColorBlendFactor = 0,
            .dstColorBlendFactor = 0,
            .colorBlendOp = 0,
            .srcAlphaBlendFactor = 0,
            .dstAlphaBlendFactor = 0,
            .alphaBlendOp = 0,
            .colorWriteMask = d.VK_COLOR_COMPONENT_R_BIT | d.VK_COLOR_COMPONENT_G_BIT | d.VK_COLOR_COMPONENT_B_BIT | d.VK_COLOR_COMPONENT_A_BIT,
        };
        const cbs = d.VkPipelineColorBlendStateCreateInfo{
            .sType = d.VK_STRUCTURE_TYPE_PIPELINE_COLOR_BLEND_STATE_CREATE_INFO,
            .pNext = null,
            .flags = 0,
            .logicOpEnable = 0,
            .logicOp = 0,
            .attachmentCount = 1,
            .pAttachments = @ptrCast(&cba),
            .blendConstants = .{ 0, 0, 0, 0 },
        };
        const gp_info = d.VkGraphicsPipelineCreateInfo{
            .sType = d.VK_STRUCTURE_TYPE_GRAPHICS_PIPELINE_CREATE_INFO,
            .pNext = null,
            .flags = 0,
            .stageCount = 2,
            .pStages = &stages,
            .pVertexInputState = &vi,
            .pInputAssemblyState = &ia,
            .pTessellationState = null,
            .pViewportState = &vps,
            .pRasterizationState = &rs,
            .pMultisampleState = &ms,
            .pDepthStencilState = null,
            .pColorBlendState = &cbs,
            .pDynamicState = null,
            .layout = self.pipeline_layout,
            .renderPass = self.render_pass,
            .subpass = 0,
            .basePipelineHandle = null,
            .basePipelineIndex = -1,
        };
        if (vk.vkCreateGraphicsPipelines(dev_handle, null, 1, &gp_info, null, &self.pipeline) != d.VK_SUCCESS)
            return error.CreateGraphicsPipelineFailed;

        // Command pool + buffer + fence.
        const pool_info = d.VkCommandPoolCreateInfo{
            .sType = d.VK_STRUCTURE_TYPE_COMMAND_POOL_CREATE_INFO,
            .pNext = null,
            .flags = d.VK_COMMAND_POOL_CREATE_RESET_COMMAND_BUFFER_BIT,
            .queueFamilyIndex = family,
        };
        if (vk.vkCreateCommandPool(dev_handle, &pool_info, null, &self.pool) != d.VK_SUCCESS)
            return error.CreateCommandPoolFailed;
        const cmd_alloc = d.VkCommandBufferAllocateInfo{
            .sType = d.VK_STRUCTURE_TYPE_COMMAND_BUFFER_ALLOCATE_INFO,
            .pNext = null,
            .commandPool = self.pool,
            .level = d.VK_COMMAND_BUFFER_LEVEL_PRIMARY,
            .commandBufferCount = 1,
        };
        if (vk.vkAllocateCommandBuffers(dev_handle, &cmd_alloc, &self.cmd) != d.VK_SUCCESS)
            return error.AllocateCommandBuffersFailed;
        const fence_info = d.VkFenceCreateInfo{
            .sType = d.VK_STRUCTURE_TYPE_FENCE_CREATE_INFO,
            .pNext = null,
            .flags = d.VK_FENCE_CREATE_SIGNALED_BIT,
        };
        if (vk.vkCreateFence(dev_handle, &fence_info, null, &self.fence) != d.VK_SUCCESS)
            return error.CreateFenceFailed;

        return self;
    }


    /// Destroy all device-child objects (safe on NVIDIA; only
    /// vkDestroyDevice/vkDestroyInstance crash there). Used on resize.
    pub fn deinitSoft(self: *GpuText, vk: *Vulkan, dev: *const Device) void {
        const h = dev.device;
        vk.vkDestroyFence(h, self.fence, null);
        vk.vkDestroyCommandPool(h, self.pool, null);
        vk.vkDestroyPipeline(h, self.pipeline, null);
        vk.vkDestroyPipelineLayout(h, self.pipeline_layout, null);
        vk.vkDestroyFramebuffer(h, self.framebuffer, null);
        vk.vkDestroyRenderPass(h, self.render_pass, null);
        vk.vkDestroyShaderModule(h, self.vert_module, null);
        vk.vkDestroyShaderModule(h, self.frag_module, null);
        vk.vkDestroyDescriptorPool(h, self.desc_pool, null);
        vk.vkDestroyDescriptorSetLayout(h, self.desc_layout, null);
        vk.vkDestroySampler(h, self.sampler, null);
        vk.vkDestroyImageView(h, self.atlas_view, null);
        vk.vkDestroyImage(h, self.atlas_image, null);
        vk.vkFreeMemory(h, self.atlas_mem, null);
        vk.vkDestroyBuffer(h, self.vb, null);
        vk.vkFreeMemory(h, self.vb_mem, null);
        vk.vkDestroyImageView(h, self.image_view, null);
        vk.vkDestroyImage(h, self.image, null);
        vk.vkFreeMemory(h, self.image_mem, null);
        vk.vkDestroyBuffer(h, self.buffer, null);
        vk.vkFreeMemory(h, self.buffer_mem, null);
    }

    /// Host-visible frame bytes, BGRA order == wl_shm ARGB8888 on little-endian.
    pub fn pixels(self: *const GpuText) []const u8 {
        const len = @as(usize, self.width) * self.height * 4;
        return self.mapped[0..len];
    }

    fn submitAndWait(self: *GpuText, vk: *Vulkan, dev: *const Device) !void {
        const dev_handle = dev.device;
        const submit_info = d.VkSubmitInfo{
            .sType = d.VK_STRUCTURE_TYPE_SUBMIT_INFO,
            .pNext = null,
            .waitSemaphoreCount = 0,
            .pWaitSemaphores = null,
            .pWaitDstStageMask = null,
            .commandBufferCount = 1,
            .pCommandBuffers = @ptrCast(&self.cmd),
            .signalSemaphoreCount = 0,
            .pSignalSemaphores = null,
        };
        if (vk.vkQueueSubmit(dev.queue, 1, &submit_info, self.fence) != d.VK_SUCCESS)
            return error.QueueSubmitFailed;
        if (vk.vkWaitForFences(dev_handle, 1, @ptrCast(&self.fence), true, std.math.maxInt(u64)) != d.VK_SUCCESS)
            return error.WaitFenceFailed;
    }

    /// Upload the CPU atlas (R8, atlas_w*atlas_h bytes) into the device-local
    /// texture and transition it to SHADER_READ_ONLY_OPTIMAL.
    pub fn uploadAtlas(self: *GpuText, vk: *Vulkan, dev: *const Device, data: []const u8) !void {
        const dev_handle = dev.device;
        std.debug.assert(data.len == @as(usize, self.atlas_w) * self.atlas_h);
        const stage = try makeHostBuffer(vk, dev, data.len, d.VK_IMAGE_USAGE_TRANSFER_DST_BIT | d.VK_BUFFER_USAGE_TRANSFER_SRC_BIT);
        defer {
            vk.vkDestroyBuffer(dev_handle, stage[0], null);
            vk.vkFreeMemory(dev_handle, stage[1], null);
        }
        @memcpy(stage[2][0..data.len], data);

        if (vk.vkWaitForFences(dev_handle, 1, @ptrCast(&self.fence), true, std.math.maxInt(u64)) != d.VK_SUCCESS)
            return error.WaitFenceFailed;
        if (vk.vkResetFences(dev_handle, 1, @ptrCast(&self.fence)) != d.VK_SUCCESS)
            return error.ResetFenceFailed;
        const begin_info = d.VkCommandBufferBeginInfo{
            .sType = d.VK_STRUCTURE_TYPE_COMMAND_BUFFER_BEGIN_INFO,
            .pNext = null,
            .flags = d.VK_COMMAND_BUFFER_USAGE_ONE_TIME_SUBMIT_BIT,
            .pInheritanceInfo = null,
        };
        if (vk.vkBeginCommandBuffer(self.cmd, &begin_info) != d.VK_SUCCESS)
            return error.BeginCommandBufferFailed;
        const subrange = d.VkImageSubresourceRange{
            .aspectMask = d.VK_IMAGE_ASPECT_COLOR_BIT,
            .baseMipLevel = 0,
            .levelCount = 1,
            .baseArrayLayer = 0,
            .layerCount = 1,
        };
        const b1 = d.VkImageMemoryBarrier{
            .sType = d.VK_STRUCTURE_TYPE_IMAGE_MEMORY_BARRIER,
            .pNext = null,
            .srcAccessMask = 0,
            .dstAccessMask = d.VK_ACCESS_TRANSFER_WRITE_BIT,
            .oldLayout = d.VK_IMAGE_LAYOUT_UNDEFINED,
            .newLayout = d.VK_IMAGE_LAYOUT_TRANSFER_DST_OPTIMAL,
            .srcQueueFamilyIndex = d.VK_QUEUE_FAMILY_IGNORED,
            .dstQueueFamilyIndex = d.VK_QUEUE_FAMILY_IGNORED,
            .image = self.atlas_image,
            .subresourceRange = subrange,
        };
        vk.vkCmdPipelineBarrier(self.cmd, d.VK_PIPELINE_STAGE_TOP_OF_PIPE_BIT, d.VK_PIPELINE_STAGE_TRANSFER_BIT, 0, 0, null, 0, null, 1, @ptrCast(&b1));
        const copy = d.VkBufferImageCopy{
            .bufferOffset = 0,
            .bufferRowLength = 0,
            .bufferImageHeight = 0,
            .imageSubresource = .{
                .aspectMask = d.VK_IMAGE_ASPECT_COLOR_BIT,
                .mipLevel = 0,
                .baseArrayLayer = 0,
                .layerCount = 1,
            },
            .imageOffset = .{ .x = 0, .y = 0, .z = 0 },
            .imageExtent = .{ .width = self.atlas_w, .height = self.atlas_h, .depth = 1 },
        };
        vk.vkCmdCopyBufferToImage(self.cmd, stage[0], self.atlas_image, d.VK_IMAGE_LAYOUT_TRANSFER_DST_OPTIMAL, 1, @ptrCast(&copy));
        const b2 = d.VkImageMemoryBarrier{
            .sType = d.VK_STRUCTURE_TYPE_IMAGE_MEMORY_BARRIER,
            .pNext = null,
            .srcAccessMask = d.VK_ACCESS_TRANSFER_WRITE_BIT,
            .dstAccessMask = d.VK_ACCESS_SHADER_READ_BIT,
            .oldLayout = d.VK_IMAGE_LAYOUT_TRANSFER_DST_OPTIMAL,
            .newLayout = d.VK_IMAGE_LAYOUT_SHADER_READ_ONLY_OPTIMAL,
            .srcQueueFamilyIndex = d.VK_QUEUE_FAMILY_IGNORED,
            .dstQueueFamilyIndex = d.VK_QUEUE_FAMILY_IGNORED,
            .image = self.atlas_image,
            .subresourceRange = subrange,
        };
        vk.vkCmdPipelineBarrier(self.cmd, d.VK_PIPELINE_STAGE_TRANSFER_BIT, d.VK_PIPELINE_STAGE_FRAGMENT_SHADER_BIT, 0, 0, null, 0, null, 1, @ptrCast(&b2));
        if (vk.vkEndCommandBuffer(self.cmd) != d.VK_SUCCESS)
            return error.EndCommandBufferFailed;
        try submitAndWait(self, vk, dev);
    }

    /// Render glyph quads and copy the frame to the host buffer.
    pub fn render(self: *GpuText, vk: *Vulkan, dev: *const Device, quads: []const Quad) !void {
        const dev_handle = dev.device;
        if (quads.len > MAX_QUADS) return error.TooManyQuads;

        // Build the vertex array (2 triangles per quad).
        const verts = @as([*]Vertex, @ptrCast(@alignCast(self.vb_mapped)))[0 .. quads.len * 6];
        for (quads, 0..) |q, i| {
            const x1 = q.x + q.w;
            const y1 = q.y + q.h;
            const quad_verts = [6]Vertex{
                .{ .pos = .{ q.x, q.y }, .uv = .{ q.u0, q.v0 }, .color = q.color },
                .{ .pos = .{ x1, q.y }, .uv = .{ q.u1, q.v0 }, .color = q.color },
                .{ .pos = .{ x1, y1 }, .uv = .{ q.u1, q.v1 }, .color = q.color },
                .{ .pos = .{ q.x, q.y }, .uv = .{ q.u0, q.v0 }, .color = q.color },
                .{ .pos = .{ x1, y1 }, .uv = .{ q.u1, q.v1 }, .color = q.color },
                .{ .pos = .{ q.x, y1 }, .uv = .{ q.u0, q.v1 }, .color = q.color },
            };
            @memcpy(verts[i * 6 ..][0..6], &quad_verts);
        }

        if (vk.vkWaitForFences(dev_handle, 1, @ptrCast(&self.fence), true, std.math.maxInt(u64)) != d.VK_SUCCESS)
            return error.WaitFenceFailed;
        if (vk.vkResetFences(dev_handle, 1, @ptrCast(&self.fence)) != d.VK_SUCCESS)
            return error.ResetFenceFailed;
        const begin_info = d.VkCommandBufferBeginInfo{
            .sType = d.VK_STRUCTURE_TYPE_COMMAND_BUFFER_BEGIN_INFO,
            .pNext = null,
            .flags = d.VK_COMMAND_BUFFER_USAGE_ONE_TIME_SUBMIT_BIT,
            .pInheritanceInfo = null,
        };
        if (vk.vkBeginCommandBuffer(self.cmd, &begin_info) != d.VK_SUCCESS)
            return error.BeginCommandBufferFailed;

        const subrange = d.VkImageSubresourceRange{
            .aspectMask = d.VK_IMAGE_ASPECT_COLOR_BIT,
            .baseMipLevel = 0,
            .levelCount = 1,
            .baseArrayLayer = 0,
            .layerCount = 1,
        };
        const barrier1 = d.VkImageMemoryBarrier{
            .sType = d.VK_STRUCTURE_TYPE_IMAGE_MEMORY_BARRIER,
            .pNext = null,
            .srcAccessMask = 0,
            .dstAccessMask = d.VK_ACCESS_COLOR_ATTACHMENT_WRITE_BIT,
            .oldLayout = d.VK_IMAGE_LAYOUT_UNDEFINED,
            .newLayout = d.VK_IMAGE_LAYOUT_COLOR_ATTACHMENT_OPTIMAL,
            .srcQueueFamilyIndex = d.VK_QUEUE_FAMILY_IGNORED,
            .dstQueueFamilyIndex = d.VK_QUEUE_FAMILY_IGNORED,
            .image = self.image,
            .subresourceRange = subrange,
        };
        vk.vkCmdPipelineBarrier(self.cmd, d.VK_PIPELINE_STAGE_TOP_OF_PIPE_BIT, d.VK_PIPELINE_STAGE_COLOR_ATTACHMENT_OUTPUT_BIT, 0, 0, null, 0, null, 1, @ptrCast(&barrier1));

        // Clear in BGRA order (R8G8B8A8 attachment channels get B,G,R,A) so the
        // host copy is directly wl_shm ARGB8888: void #04060B -> bytes 0B 06 04 FF.
        const clear = d.VkClearValue{ .color = .{ 11.0 / 255.0, 6.0 / 255.0, 4.0 / 255.0, 1.0 } };
        const rp_begin = d.VkRenderPassBeginInfo{
            .sType = d.VK_STRUCTURE_TYPE_RENDER_PASS_BEGIN_INFO,
            .pNext = null,
            .renderPass = self.render_pass,
            .framebuffer = self.framebuffer,
            .renderArea = .{ .offset = .{ .x = 0, .y = 0 }, .extent = .{ .width = self.width, .height = self.height } },
            .clearValueCount = 1,
            .pClearValues = @ptrCast(&clear),
        };
        vk.vkCmdBeginRenderPass(self.cmd, &rp_begin, 0);
        vk.vkCmdBindPipeline(self.cmd, d.VK_PIPELINE_BIND_POINT_GRAPHICS, self.pipeline);
        vk.vkCmdBindDescriptorSets(self.cmd, d.VK_PIPELINE_BIND_POINT_GRAPHICS, self.pipeline_layout, 0, 1, @ptrCast(&self.desc_set), 0, null);
        const pc = PushConstants{
            .extent = .{ @floatFromInt(self.width), @floatFromInt(self.height), 0, 0 },
        };
        vk.vkCmdPushConstants(self.cmd, self.pipeline_layout, d.VK_SHADER_STAGE_VERTEX_BIT | d.VK_SHADER_STAGE_FRAGMENT_BIT, 0, @sizeOf(PushConstants), @ptrCast(&pc));
        const vb_off: u64 = 0;
        vk.vkCmdBindVertexBuffers(self.cmd, 0, 1, @ptrCast(&self.vb), @ptrCast(&vb_off));
        vk.vkCmdDraw(self.cmd, @intCast(quads.len * 6), 1, 0, 0);
        vk.vkCmdEndRenderPass(self.cmd);

        const barrier2 = d.VkImageMemoryBarrier{
            .sType = d.VK_STRUCTURE_TYPE_IMAGE_MEMORY_BARRIER,
            .pNext = null,
            .srcAccessMask = d.VK_ACCESS_COLOR_ATTACHMENT_WRITE_BIT,
            .dstAccessMask = d.VK_ACCESS_TRANSFER_READ_BIT,
            .oldLayout = d.VK_IMAGE_LAYOUT_TRANSFER_SRC_OPTIMAL,
            .newLayout = d.VK_IMAGE_LAYOUT_TRANSFER_SRC_OPTIMAL,
            .srcQueueFamilyIndex = d.VK_QUEUE_FAMILY_IGNORED,
            .dstQueueFamilyIndex = d.VK_QUEUE_FAMILY_IGNORED,
            .image = self.image,
            .subresourceRange = subrange,
        };
        vk.vkCmdPipelineBarrier(self.cmd, d.VK_PIPELINE_STAGE_COLOR_ATTACHMENT_OUTPUT_BIT, d.VK_PIPELINE_STAGE_TRANSFER_BIT, 0, 0, null, 0, null, 1, @ptrCast(&barrier2));

        const copy = d.VkBufferImageCopy{
            .bufferOffset = 0,
            .bufferRowLength = 0,
            .bufferImageHeight = 0,
            .imageSubresource = .{
                .aspectMask = d.VK_IMAGE_ASPECT_COLOR_BIT,
                .mipLevel = 0,
                .baseArrayLayer = 0,
                .layerCount = 1,
            },
            .imageOffset = .{ .x = 0, .y = 0, .z = 0 },
            .imageExtent = .{ .width = self.width, .height = self.height, .depth = 1 },
        };
        vk.vkCmdCopyImageToBuffer(self.cmd, self.image, d.VK_IMAGE_LAYOUT_TRANSFER_SRC_OPTIMAL, self.buffer, 1, @ptrCast(&copy));
        if (vk.vkEndCommandBuffer(self.cmd) != d.VK_SUCCESS)
            return error.EndCommandBufferFailed;
        try submitAndWait(self, vk, dev);
    }
};
