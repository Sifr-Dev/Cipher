//! Vulkan swapchain — direct Vulkan->Wayland presentation
//! (VK_KHR_wayland_surface + VK_KHR_swapchain).
//!
//! Attaches to an existing Wayland wl_surface (by proxy pointer) and owns the
//! swapchain, its images/views/framebuffers, a render pass pipeline-compatible
//! with text.zig's (same attachment format/samples/load/store; only the final
//! layout differs: PRESENT_SRC_KHR instead of TRANSFER_SRC_OPTIMAL), plus the
//! acquire/present synchronization.
//!
//! Fallback contract: any init failure returns an error and the caller falls
//! back to the wl_shm readback path. Runtime recreation (resize / out-of-date)
//! goes through recreate(), which keeps the render pass and rebuilds the
//! swapchain + views + framebuffers.

const std = @import("std");
const d = @import("device.zig");

pub const Vulkan = d.Vulkan;
pub const Device = d.Device;

pub const VK_MAX_FRAMES_IN_FLIGHT: u32 = 2;

pub const Swapchain = struct {
    surface: d.VkSurfaceKHR,
    swapchain: ?d.VkSwapchainKHR = null,
    images: []d.VkImage = &.{},
    views: []d.VkImageView = &.{},
    framebuffers: []d.VkFramebuffer = &.{},
    acquire_sem: []d.VkSemaphore = &.{},
    render_sem: []d.VkSemaphore = &.{},
    n_images: u32 = 0,
    width: u32,
    height: u32,
    format: u32,
    color_space: u32,
    render_pass: d.VkRenderPass = undefined,
    has_render_pass: bool = false,
    frame_index: u32 = 0,
    alloc: std.mem.Allocator,

    fn createRenderPass(vk: *Vulkan, dev: *const Device, format: u32) !d.VkRenderPass {
        const attachment = d.VkAttachmentDescription{
            .flags = 0,
            .format = format,
            .samples = d.VK_SAMPLE_COUNT_1_BIT,
            .loadOp = d.VK_ATTACHMENT_LOAD_OP_CLEAR,
            .storeOp = d.VK_ATTACHMENT_STORE_OP_STORE,
            .stencilLoadOp = 0,
            .stencilStoreOp = 0,
            .initialLayout = d.VK_IMAGE_LAYOUT_UNDEFINED,
            .finalLayout = d.VK_IMAGE_LAYOUT_PRESENT_SRC_KHR,
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
        if (vk.vkCreateRenderPass(dev.device, &rp_info, null, &rp) != d.VK_SUCCESS)
            return error.CreateRenderPassFailed;
        return rp;
    }

    /// Create the surface+swapchain. Returns error on ANY failure; the caller
    /// then falls back to the wl_shm readback path.
    pub fn init(vk: *Vulkan, dev: *const Device, display: ?*anyopaque, surface: ?*anyopaque, width: u32, height: u32, alloc: std.mem.Allocator) !Swapchain {
        // Surface first — fails hard if the platform surface can't be made.
        const surf_info = d.VkWaylandSurfaceCreateInfoKHR{
            .sType = d.VK_STRUCTURE_TYPE_WAYLAND_SURFACE_CREATE_INFO_KHR,
            .pNext = null,
            .flags = 0,
            .display = display,
            .surface = surface,
        };
        var surface_handle: d.VkSurfaceKHR = undefined;
        if (vk.vkCreateWaylandSurfaceKHR(dev.instance, &surf_info, null, &surface_handle) != d.VK_SUCCESS)
            return error.CreateSurfaceFailed;
        errdefer vkSafeDestroySurface(vk, dev.instance, surface_handle);

        // Queue family must present.
        var supported: d.VkBool32 = 0;
        if (vk.vkGetPhysicalDeviceSurfaceSupportKHR(dev.physical, dev.queue_family_index, surface_handle, &supported) != d.VK_SUCCESS or supported == 0)
            return error.NoPresentSupport;

        // Surface capabilities.
        var caps: d.VkSurfaceCapabilitiesKHR = undefined;
        if (vk.vkGetPhysicalDeviceSurfaceCapabilitiesKHR(dev.physical, surface_handle, &caps) != d.VK_SUCCESS)
            return error.GetCapsFailed;

        // Choose a supported surface format. Use it for the image views and
        // render pass alike; a mismatched attachment format is invalid.
        // Fragment shaders currently store B,G,R,A, so an RGBA surface has
        // the same byte order as the software ARGB framebuffer.
        var format_count: u32 = 0;
        if (vk.vkGetPhysicalDeviceSurfaceFormatsKHR(dev.physical, surface_handle, &format_count, null) != d.VK_SUCCESS)
            return error.GetFormatsFailed;
        const formats = try alloc.alloc(d.VkSurfaceFormatKHR, format_count);
        defer alloc.free(formats);
        if (vk.vkGetPhysicalDeviceSurfaceFormatsKHR(dev.physical, surface_handle, &format_count, formats.ptr) != d.VK_SUCCESS)
            return error.GetFormatsFailed;
        const preferred = [_]u32{ d.VK_FORMAT_R8G8B8A8_UNORM, d.VK_FORMAT_B8G8R8A8_UNORM, d.VK_FORMAT_R8G8B8A8_SRGB, d.VK_FORMAT_B8G8R8A8_SRGB };
        var chosen_format: u32 = 0;
        var chosen_color_space: u32 = 0;
        var found = false;
        for (preferred) |want| {
            for (formats) |*f| {
                if (f.format == want) {
                    chosen_format = f.format;
                    chosen_color_space = f.colorSpace;
                    found = true;
                    break;
                }
            }
            if (found) break;
        }
        if (!found) return error.NoSuitableFormat;

        // Present mode: MAILBOX if available, else FIFO.
        var pm_count: u32 = 0;
        if (vk.vkGetPhysicalDeviceSurfacePresentModesKHR(dev.physical, surface_handle, &pm_count, null) != d.VK_SUCCESS)
            return error.GetPresentModesFailed;
        const pms = try alloc.alloc(u32, pm_count);
        defer alloc.free(pms);
        if (vk.vkGetPhysicalDeviceSurfacePresentModesKHR(dev.physical, surface_handle, &pm_count, @ptrCast(pms.ptr)) != d.VK_SUCCESS)
            return error.GetPresentModesFailed;
        var present_mode: u32 = d.VK_PRESENT_MODE_FIFO_KHR;
        for (pms) |*m| {
            if (m.* == d.VK_PRESENT_MODE_MAILBOX_KHR) {
                present_mode = d.VK_PRESENT_MODE_MAILBOX_KHR;
                break;
            }
        }

        // Extent: currentExtent (fixed) or requested clamped.
        var extent: d.VkExtent2D = caps.currentExtent;
        if (extent.width == 0xffffffff or extent.height == 0xffffffff) {
            extent = .{
                .width = std.math.clamp(width, caps.minImageExtent.width, caps.maxImageExtent.width),
                .height = std.math.clamp(height, caps.minImageExtent.height, caps.maxImageExtent.height),
            };
        }

        const min_images = if (caps.minImageCount < 3) 3 else caps.minImageCount;
        const max_images = if (caps.maxImageCount == 0) min_images + 1 else caps.maxImageCount;
        const image_count = @min(min_images, max_images);

        // PreTransform: identity if supported, else current.
        var pre_transform: u32 = d.VK_SURFACE_TRANSFORM_IDENTITY_BIT_KHR;
        if ((caps.supportedTransforms & d.VK_SURFACE_TRANSFORM_IDENTITY_BIT_KHR) == 0)
            pre_transform = caps.currentTransform;

        // Composite alpha: OPAQUE if supported, else INHERITED.
        const composite_alpha: u32 = if ((caps.supportedCompositeAlpha & d.VK_COMPOSITE_ALPHA_OPAQUE_BIT_KHR) != 0)
            d.VK_COMPOSITE_ALPHA_OPAQUE_BIT_KHR
        else
            d.VK_COMPOSITE_ALPHA_INHERITED_BIT_KHR;

        const usage = d.VK_IMAGE_USAGE_COLOR_ATTACHMENT_BIT;

        const sc_info = d.VkSwapchainCreateInfoKHR{
            .sType = d.VK_STRUCTURE_TYPE_SWAPCHAIN_CREATE_INFO_KHR,
            .pNext = null,
            .flags = 0,
            .surface = surface_handle,
            .minImageCount = image_count,
            .imageFormat = chosen_format,
            .imageColorSpace = chosen_color_space,
            .imageExtent = extent,
            .imageArrayLayers = 1,
            .imageUsage = usage,
            .imageSharingMode = d.VK_SHARING_MODE_EXCLUSIVE,
            .queueFamilyIndexCount = 0,
            .pQueueFamilyIndices = null,
            .preTransform = pre_transform,
            .compositeAlpha = composite_alpha,
            .presentMode = present_mode,
            .clipped = 1,
            .oldSwapchain = null,
        };
        var swapchain_handle: d.VkSwapchainKHR = undefined;
        if (vk.vkCreateSwapchainKHR(dev.device, &sc_info, null, &swapchain_handle) != d.VK_SUCCESS)
            return error.CreateSwapchainFailed;

        // Images + views.
        var img_count: u32 = 0;
        if (vk.vkGetSwapchainImagesKHR(dev.device, swapchain_handle, &img_count, null) != d.VK_SUCCESS)
            return error.GetSwapchainImagesFailed;
        const images = try alloc.alloc(d.VkImage, img_count);
        defer alloc.free(images);
        if (vk.vkGetSwapchainImagesKHR(dev.device, swapchain_handle, &img_count, @ptrCast(images.ptr)) != d.VK_SUCCESS)
            return error.GetSwapchainImagesFailed;

        const views = try alloc.alloc(d.VkImageView, img_count);
        errdefer vkSafeDestroyViews(vk, dev.device, views);
        for (0..img_count) |i| {
            const view_info = d.VkImageViewCreateInfo{
                .sType = d.VK_STRUCTURE_TYPE_IMAGE_VIEW_CREATE_INFO,
                .pNext = null,
                .flags = 0,
                .image = images[i],
                .viewType = d.VK_IMAGE_VIEW_TYPE_2D,
                .format = chosen_format,
                .components = .{ .r = 0, .g = 0, .b = 0, .a = 0 },
                .subresourceRange = .{
                    .aspectMask = d.VK_IMAGE_ASPECT_COLOR_BIT,
                    .baseMipLevel = 0,
                    .levelCount = 1,
                    .baseArrayLayer = 0,
                    .layerCount = 1,
                },
            };
            if (vk.vkCreateImageView(dev.device, &view_info, null, &views[i]) != d.VK_SUCCESS)
                return error.CreateImageViewFailed;
        }

        // Render pass (pipeline-compatible with text.zig's; final layout PRESENT_SRC_KHR).
        const render_pass = try createRenderPass(vk, dev, chosen_format);

        // Framebuffers.
        const framebuffers = try alloc.alloc(d.VkFramebuffer, img_count);
        errdefer vkSafeDestroyFramebuffers(vk, dev.device, framebuffers);
        for (0..img_count) |i| {
            const fb_info = d.VkFramebufferCreateInfo{
                .sType = d.VK_STRUCTURE_TYPE_FRAMEBUFFER_CREATE_INFO,
                .pNext = null,
                .flags = 0,
                .renderPass = render_pass,
                .attachmentCount = 1,
                .pAttachments = @ptrCast(&views[i]),
                .width = extent.width,
                .height = extent.height,
                .layers = 1,
            };
            if (vk.vkCreateFramebuffer(dev.device, &fb_info, null, &framebuffers[i]) != d.VK_SUCCESS)
                return error.CreateFramebufferFailed;
        }

        // Sync objects.
        const acquire_sem = try alloc.alloc(d.VkSemaphore, VK_MAX_FRAMES_IN_FLIGHT);
        errdefer vkSafeDestroySemaphores(vk, dev.device, acquire_sem);
        const render_sem = try alloc.alloc(d.VkSemaphore, VK_MAX_FRAMES_IN_FLIGHT);
        errdefer vkSafeDestroySemaphores(vk, dev.device, render_sem);
        for (0..VK_MAX_FRAMES_IN_FLIGHT) |i| {
            const sem_info = d.VkSemaphoreCreateInfo{ .sType = d.VK_STRUCTURE_TYPE_SEMAPHORE_CREATE_INFO, .pNext = null, .flags = 0 };
            if (vk.vkCreateSemaphore(dev.device, &sem_info, null, &acquire_sem[i]) != d.VK_SUCCESS)
                return error.CreateSemaphoreFailed;
            if (vk.vkCreateSemaphore(dev.device, &sem_info, null, &render_sem[i]) != d.VK_SUCCESS)
                return error.CreateSemaphoreFailed;
        }

        const images_copy = try alloc.dupe(d.VkImage, images);
        errdefer alloc.free(images_copy);

        return .{
            .surface = surface_handle,
            .swapchain = swapchain_handle,
            .images = images_copy,
            .views = views,
            .framebuffers = framebuffers,
            .acquire_sem = acquire_sem,
            .render_sem = render_sem,
            .n_images = img_count,
            .width = extent.width,
            .height = extent.height,
            .format = chosen_format,
            .color_space = chosen_color_space,
            .render_pass = render_pass,
            .has_render_pass = true,
            .frame_index = 0,
            .alloc = alloc,
        };
    }

    fn vkSafeDestroySurface(vk: *Vulkan, instance: d.VkInstance, surface: d.VkSurfaceKHR) void {
        vk.vkDestroySurfaceKHR(instance, surface, null);
    }
    fn vkSafeDestroyViews(vk: *Vulkan, dev: d.VkDevice, views: []d.VkImageView) void {
        for (views) |v| vk.vkDestroyImageView(dev, v, null);
    }
    fn vkSafeDestroyFramebuffers(vk: *Vulkan, dev: d.VkDevice, fbs: []d.VkFramebuffer) void {
        for (fbs) |fb| vk.vkDestroyFramebuffer(dev, fb, null);
    }
    fn vkSafeDestroySemaphores(vk: *Vulkan, dev: d.VkDevice, sems: []d.VkSemaphore) void {
        for (sems) |s| vk.vkDestroySemaphore(dev, s, null);
    }

    /// Acquire the next swapchain image. Returns the image index and which
    /// acquire semaphore the submission must wait on.
    pub fn acquire(self: *Swapchain, vk: *Vulkan, dev: *const Device) !u32 {
        const idx = self.frame_index % VK_MAX_FRAMES_IN_FLIGHT;
        var image_index: u32 = undefined;
        const rc = vk.vkAcquireNextImageKHR(dev.device, self.swapchain.?, std.math.maxInt(u64), self.acquire_sem[idx], @as(?*anyopaque, null), &image_index);
        if (rc == d.VK_SUBOPTIMAL_KHR or rc == d.VK_SUCCESS) {
            return image_index;
        }
        return error.AcquireFailed;
    }

    /// Present the rendered image. Returns error.OutOfDate when the swapchain
    /// must be recreated (resize).
    pub fn present(self: *Swapchain, vk: *Vulkan, dev: *const Device, image_index: u32) !void {
        const idx = self.frame_index % VK_MAX_FRAMES_IN_FLIGHT;
        const wait = [_]d.VkSemaphore{self.render_sem[idx]};
        const swapchains = [_]d.VkSwapchainKHR{self.swapchain.?};
        const indices = [_]u32{image_index};
        const present_info = d.VkPresentInfoKHR{
            .sType = d.VK_STRUCTURE_TYPE_PRESENT_INFO_KHR,
            .pNext = null,
            .waitSemaphoreCount = 1,
            .pWaitSemaphores = &wait,
            .swapchainCount = 1,
            .pSwapchains = &swapchains,
            .pImageIndices = &indices,
            .pResults = null,
        };
        const rc = vk.vkQueuePresentKHR(dev.queue, &present_info);
        self.frame_index += 1;
        if (rc == d.VK_ERROR_OUT_OF_DATE_KHR or rc == d.VK_SUBOPTIMAL_KHR)
            return error.OutOfDate;
        if (rc != d.VK_SUCCESS)
            return error.PresentFailed;
    }

    /// Recreate swapchain at a new size, reusing the render pass.
    pub fn recreate(self: *Swapchain, vk: *Vulkan, dev: *const Device, width: u32, height: u32) !void {
        // Recreate images/views/framebuffers/swapchain at the new extent.
        // Simplest robust path: tear down everything but the surface+render pass
        // and re-run the same init sequence inline.
        self.deinitSwapchain(vk, dev);

        var caps: d.VkSurfaceCapabilitiesKHR = undefined;
        if (vk.vkGetPhysicalDeviceSurfaceCapabilitiesKHR(dev.physical, self.surface, &caps) != d.VK_SUCCESS)
            return error.GetCapsFailed;
        var extent: d.VkExtent2D = caps.currentExtent;
        if (extent.width == 0xffffffff or extent.height == 0xffffffff) {
            extent = .{
                .width = std.math.clamp(width, caps.minImageExtent.width, caps.maxImageExtent.width),
                .height = std.math.clamp(height, caps.minImageExtent.height, caps.maxImageExtent.height),
            };
        }
        const pm_count: u32 = 0;
        _ = pm_count;
        const min_images = if (caps.minImageCount < 3) 3 else caps.minImageCount;
        const max_images = if (caps.maxImageCount == 0) min_images + 1 else caps.maxImageCount;
        const image_count = @min(min_images, max_images);
        const sc_info = d.VkSwapchainCreateInfoKHR{
            .sType = d.VK_STRUCTURE_TYPE_SWAPCHAIN_CREATE_INFO_KHR,
            .pNext = null,
            .flags = 0,
            .surface = self.surface,
            .minImageCount = image_count,
            .imageFormat = self.format,
            .imageColorSpace = self.color_space,
            .imageExtent = extent,
            .imageArrayLayers = 1,
            .imageUsage = d.VK_IMAGE_USAGE_COLOR_ATTACHMENT_BIT,
            .imageSharingMode = d.VK_SHARING_MODE_EXCLUSIVE,
            .queueFamilyIndexCount = 0,
            .pQueueFamilyIndices = null,
            .preTransform = caps.currentTransform,
            .compositeAlpha = d.VK_COMPOSITE_ALPHA_OPAQUE_BIT_KHR,
            .presentMode = d.VK_PRESENT_MODE_FIFO_KHR,
            .clipped = 1,
            .oldSwapchain = null,
        };
        var swapchain_handle: d.VkSwapchainKHR = undefined;
        if (vk.vkCreateSwapchainKHR(dev.device, &sc_info, null, &swapchain_handle) != d.VK_SUCCESS)
            return error.CreateSwapchainFailed;

        var img_count: u32 = 0;
        if (vk.vkGetSwapchainImagesKHR(dev.device, swapchain_handle, &img_count, null) != d.VK_SUCCESS)
            return error.GetSwapchainImagesFailed;
        const images = try self.alloc.alloc(d.VkImage, img_count);
        defer self.alloc.free(images);
        if (vk.vkGetSwapchainImagesKHR(dev.device, swapchain_handle, &img_count, @ptrCast(images.ptr)) != d.VK_SUCCESS)
            return error.GetSwapchainImagesFailed;
        const views = try self.alloc.alloc(d.VkImageView, img_count);
        for (0..img_count) |i| {
            const view_info = d.VkImageViewCreateInfo{
                .sType = d.VK_STRUCTURE_TYPE_IMAGE_VIEW_CREATE_INFO,
                .pNext = null,
                .flags = 0,
                .image = images[i],
                .viewType = d.VK_IMAGE_VIEW_TYPE_2D,
                .format = self.format,
                .components = .{ .r = 0, .g = 0, .b = 0, .a = 0 },
                .subresourceRange = .{
                    .aspectMask = d.VK_IMAGE_ASPECT_COLOR_BIT,
                    .baseMipLevel = 0,
                    .levelCount = 1,
                    .baseArrayLayer = 0,
                    .layerCount = 1,
                },
            };
            if (vk.vkCreateImageView(dev.device, &view_info, null, &views[i]) != d.VK_SUCCESS)
                return error.CreateImageViewFailed;
        }
        const framebuffers = try self.alloc.alloc(d.VkFramebuffer, img_count);
        for (0..img_count) |i| {
            const fb_info = d.VkFramebufferCreateInfo{
                .sType = d.VK_STRUCTURE_TYPE_FRAMEBUFFER_CREATE_INFO,
                .pNext = null,
                .flags = 0,
                .renderPass = self.render_pass,
                .attachmentCount = 1,
                .pAttachments = @ptrCast(&views[i]),
                .width = extent.width,
                .height = extent.height,
                .layers = 1,
            };
            if (vk.vkCreateFramebuffer(dev.device, &fb_info, null, &framebuffers[i]) != d.VK_SUCCESS)
                return error.CreateFramebufferFailed;
        }
        const images_copy = try self.alloc.dupe(d.VkImage, images);
        self.images = images_copy;
        self.views = views;
        self.framebuffers = framebuffers;
        self.swapchain = swapchain_handle;
        self.n_images = img_count;
        self.width = extent.width;
        self.height = extent.height;
    }

    fn deinitSwapchain(self: *Swapchain, vk: *Vulkan, dev: *const Device) void {
        if (self.swapchain) |sc| {
            for (self.framebuffers) |fb| vk.vkDestroyFramebuffer(dev.device, fb, null);
            for (self.views) |v| vk.vkDestroyImageView(dev.device, v, null);
            if (self.images.len > 0) self.alloc.free(self.images);
            if (self.views.len > 0) self.alloc.free(self.views);
            if (self.framebuffers.len > 0) self.alloc.free(self.framebuffers);
            vk.vkDestroySwapchainKHR(dev.device, sc, null);
            self.swapchain = null;
            self.images = &.{};
            self.views = &.{};
            self.framebuffers = &.{};
        }
    }

    /// Full teardown: swapchain + views + framebuffers + render pass + surface.
    pub fn deinit(self: *Swapchain, vk: *Vulkan, dev: *const Device) void {
        if (self.swapchain != null) self.deinitSwapchain(vk, dev);
        if (self.has_render_pass) vk.vkDestroyRenderPass(dev.device, self.render_pass, null);
        vkSafeDestroySemaphores(vk, dev.device, self.acquire_sem);
        vkSafeDestroySemaphores(vk, dev.device, self.render_sem);
        if (self.acquire_sem.len > 0) self.alloc.free(self.acquire_sem);
        if (self.render_sem.len > 0) self.alloc.free(self.render_sem);
        vkSafeDestroySurface(vk, dev.instance, self.surface);
    }
};
