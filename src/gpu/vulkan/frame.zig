//! GPU frame pipeline: a headless Vulkan graphics pipeline renders a frame
//! into an offscreen color-attachment image (fullscreen triangle + fragment
//! shader), then vkCmdCopyImageToBuffer lands it in a host-visible buffer
//! whose bytes are directly wl_shm ARGB8888 (the fragment shader stores BGRA).
//!
//! History note: an earlier compute-pipeline version appeared to segfault in
//! the NVIDIA ICD on vkCmdBindPipeline. Khronos validation layers showed the
//! real cause was wrong enum constants in our own device.zig (bind point,
//! pipeline-stage, layout and usage values). With the constants corrected per
//! vulkan_core.h, the graphics path runs on both the NVIDIA 620.70.06 ICD and
//! lavapipe; see docs/decision-records/.
const std = @import("std");
const d = @import("device.zig");
const shader = @import("shader.zig");

pub const Vulkan = d.Vulkan;
pub const Device = d.Device;

/// Must match layout(push_constant) in ui.frag.
pub const PushConstants = extern struct {
    extent_x: u32,
    extent_y: u32,
    center_x: u32,
    center_y: u32,
    radius: u32,
};

pub const FramePipeline = struct {
    width: u32,
    height: u32,

    image: d.VkImage = undefined,
    image_view: d.VkImageView = undefined,
    image_mem: d.VkDeviceMemory = undefined,
    buffer: d.VkBuffer = undefined,
    buffer_mem: d.VkDeviceMemory = undefined,
    mapped: [*]u8 = undefined,

    pool: d.VkCommandPool = undefined,
    cmd: d.VkCommandBuffer = undefined,
    vert_module: d.VkShaderModule = undefined,
    frag_module: d.VkShaderModule = undefined,
    render_pass: d.VkRenderPass = undefined,
    framebuffer: d.VkFramebuffer = undefined,
    pipeline_layout: d.VkPipelineLayout = undefined,
    pipeline: d.VkPipeline = undefined,
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

    pub fn init(vk: *Vulkan, dev: *const Device, width: u32, height: u32) !FramePipeline {
        var self = FramePipeline{ .width = width, .height = height };
        const dev_handle = dev.device;
        const family = dev.queue_family_index;
        const size: u64 = @as(u64, width) * height * 4;

        // 1. Color-attachment image (R8G8B8A8, optimal tiling — supported for
        //    COLOR_ATTACHMENT on this driver, unlike STORAGE).
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
        if (vk.vkCreateImage(dev_handle, &image_info, null, &self.image) != d.VK_SUCCESS)
            return error.CreateImageFailed;

        var img_reqs: d.VkMemoryRequirements = undefined;
        vk.vkGetImageMemoryRequirements(dev_handle, self.image, &img_reqs);
        const img_type = try findMemoryType(vk, dev, img_reqs.memoryTypeBits, d.VK_MEMORY_PROPERTY_DEVICE_LOCAL_BIT);
        const img_alloc = d.VkMemoryAllocateInfo{
            .sType = d.VK_STRUCTURE_TYPE_MEMORY_ALLOCATE_INFO,
            .pNext = null,
            .allocationSize = img_reqs.size,
            .memoryTypeIndex = img_type,
        };
        if (vk.vkAllocateMemory(dev_handle, &img_alloc, null, &self.image_mem) != d.VK_SUCCESS)
            return error.AllocateImageMemoryFailed;
        if (vk.vkBindImageMemory(dev_handle, self.image, self.image_mem, 0) != d.VK_SUCCESS)
            return error.BindImageMemoryFailed;

        // 2. Image view.
        const view_info = d.VkImageViewCreateInfo{
            .sType = d.VK_STRUCTURE_TYPE_IMAGE_VIEW_CREATE_INFO,
            .pNext = null,
            .flags = 0,
            .image = self.image,
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
        if (vk.vkCreateImageView(dev_handle, &view_info, null, &self.image_view) != d.VK_SUCCESS)
            return error.CreateImageViewFailed;

        // 3. Host-visible staging buffer (transfer-dst).
        const buffer_info = d.VkBufferCreateInfo{
            .sType = d.VK_STRUCTURE_TYPE_BUFFER_CREATE_INFO,
            .pNext = null,
            .flags = 0,
            .size = size,
            .usage = d.VK_IMAGE_USAGE_TRANSFER_DST_BIT,
            .sharingMode = d.VK_SHARING_MODE_EXCLUSIVE,
            .queueFamilyIndexCount = 0,
            .pQueueFamilyIndices = null,
        };
        if (vk.vkCreateBuffer(dev_handle, &buffer_info, null, &self.buffer) != d.VK_SUCCESS)
            return error.CreateBufferFailed;
        var buf_reqs: d.VkMemoryRequirements = undefined;
        vk.vkGetBufferMemoryRequirements(dev_handle, self.buffer, &buf_reqs);
        const buf_type = try findMemoryType(vk, dev, buf_reqs.memoryTypeBits, d.VK_MEMORY_PROPERTY_HOST_VISIBLE_BIT | d.VK_MEMORY_PROPERTY_HOST_COHERENT_BIT);
        const buf_alloc = d.VkMemoryAllocateInfo{
            .sType = d.VK_STRUCTURE_TYPE_MEMORY_ALLOCATE_INFO,
            .pNext = null,
            .allocationSize = buf_reqs.size,
            .memoryTypeIndex = buf_type,
        };
        if (vk.vkAllocateMemory(dev_handle, &buf_alloc, null, &self.buffer_mem) != d.VK_SUCCESS)
            return error.AllocateBufferMemoryFailed;
        if (vk.vkBindBufferMemory(dev_handle, self.buffer, self.buffer_mem, 0) != d.VK_SUCCESS)
            return error.BindBufferMemoryFailed;
        var mapped: *anyopaque = undefined;
        if (vk.vkMapMemory(dev_handle, self.buffer_mem, 0, size, 0, &mapped) != d.VK_SUCCESS)
            return error.MapMemoryFailed;
        self.mapped = @ptrCast(mapped);

        // 4. Render pass: one color attachment, UNDEFINED -> TRANSFER_SRC_OPTIMAL.
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
        if (vk.vkCreateRenderPass(dev_handle, &rp_info, null, &self.render_pass) != d.VK_SUCCESS)
            return error.CreateRenderPassFailed;

        // 5. Framebuffer.
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

        // 6. Shader modules.
        self.vert_module = try createModule(vk, dev_handle, shader.ui_vert_spv);
        self.frag_module = try createModule(vk, dev_handle, shader.ui_frag_spv);

        // 7. Pipeline layout: 20-byte push constants for the fragment stage.
        const push_range = d.VkPushConstantRange{
            .stageFlags = d.VK_SHADER_STAGE_FRAGMENT_BIT,
            .offset = 0,
            .size = @sizeOf(PushConstants),
        };
        const pl_info = d.VkPipelineLayoutCreateInfo{
            .sType = d.VK_STRUCTURE_TYPE_PIPELINE_LAYOUT_CREATE_INFO,
            .pNext = null,
            .flags = 0,
            .setLayoutCount = 0,
            .pSetLayouts = null,
            .pushConstantRangeCount = 1,
            .pPushConstantRanges = @ptrCast(&push_range),
        };
        if (vk.vkCreatePipelineLayout(dev_handle, &pl_info, null, &self.pipeline_layout) != d.VK_SUCCESS)
            return error.CreatePipelineLayoutFailed;

        // 8. Graphics pipeline: fullscreen triangle, no vertex input.
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
        const vi = d.VkPipelineVertexInputStateCreateInfo{
            .sType = d.VK_STRUCTURE_TYPE_PIPELINE_VERTEX_INPUT_STATE_CREATE_INFO,
            .pNext = null,
            .flags = 0,
            .vertexBindingDescriptionCount = 0,
            .pVertexBindingDescriptions = null,
            .vertexAttributeDescriptionCount = 0,
            .pVertexAttributeDescriptions = null,
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

        // 9. Command pool + buffer.
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

        // 10. Fence, created signaled.
        const fence_info = d.VkFenceCreateInfo{
            .sType = d.VK_STRUCTURE_TYPE_FENCE_CREATE_INFO,
            .pNext = null,
            .flags = d.VK_FENCE_CREATE_SIGNALED_BIT,
        };
        if (vk.vkCreateFence(dev_handle, &fence_info, null, &self.fence) != d.VK_SUCCESS)
            return error.CreateFenceFailed;

        return self;
    }

    /// Host-visible frame bytes, BGRA order == wl_shm ARGB8888 on little-endian.
    pub fn pixels(self: *const FramePipeline) []const u8 {
        const len = @as(usize, self.width) * self.height * 4;
        return self.mapped[0..len];
    }

    /// Render one frame on the GPU and block until the copy is complete.
    pub fn render(self: *FramePipeline, vk: *Vulkan, dev: *const Device, cx: u32, cy: u32, radius: u32) !void {
        const dev_handle = dev.device;

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

        // Barrier 1: UNDEFINED -> COLOR_ATTACHMENT_OPTIMAL (contents discarded,
        // which is fine: the render pass clears and redraws every pixel).
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

        // Render pass (final layout of the attachment becomes TRANSFER_SRC_OPTIMAL).
        const clear = d.VkClearValue{ .color = .{ 0, 0, 0, 0 } };
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
        const pc = PushConstants{
            .extent_x = self.width,
            .extent_y = self.height,
            .center_x = cx,
            .center_y = cy,
            .radius = radius,
        };
        vk.vkCmdPushConstants(self.cmd, self.pipeline_layout, d.VK_SHADER_STAGE_FRAGMENT_BIT, 0, @sizeOf(PushConstants), @ptrCast(&pc));
        vk.vkCmdDraw(self.cmd, 3, 1, 0, 0);
        vk.vkCmdEndRenderPass(self.cmd);

        // Barrier 2: make the color-attachment writes visible to the copy.
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
};
