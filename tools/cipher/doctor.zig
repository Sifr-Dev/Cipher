//! `cipher doctor` — is this machine able to run cipher apps?
//! Checks zig, the Wayland session, the dlopen'd runtime libs, a Vulkan
//! instance with at least one physical device, and a usable font.
//! Exit 0 only when every hard check passes.
const std = @import("std");
const util = @import("util.zig");

extern "c" fn dlopen(path: [*:0]const u8, mode: c_int) ?*anyopaque;
extern "c" fn dlclose(handle: ?*anyopaque) c_int;
extern "c" fn dlsym(handle: ?*anyopaque, name: [*:0]const u8) ?*anyopaque;
const RTLD_NOW: c_int = 2;

// Minimal Vulkan handles for instance creation + enumeration (v1.0 structs).
const VkApplicationInfo = extern struct {
    sType: i32,
    pNext: ?*const anyopaque,
    pApplicationName: [*c]const u8,
    applicationVersion: u32,
    pEngineName: [*c]const u8,
    engineVersion: u32,
    apiVersion: u32,
};
const VkInstanceCreateInfo = extern struct {
    sType: i32,
    pNext: ?*const anyopaque,
    flags: u32,
    pApplicationInfo: ?*const anyopaque,
    enabledLayerCount: u32,
    ppEnabledLayerNames: ?*const anyopaque,
    enabledExtensionCount: u32,
    ppEnabledExtensionNames: ?*const anyopaque,
};
const VkExtensionProperties = extern struct {
    extensionName: [256]u8,
    specVersion: u32,
};
const VK_SUCCESS: i32 = 0;
const VK_STRUCTURE_TYPE_APPLICATION_INFO: i32 = 0;
const VK_STRUCTURE_TYPE_INSTANCE_CREATE_INFO: i32 = 1;

const vkCreateInstanceFn = *const fn (info: ?*const anyopaque, alloc: ?*const anyopaque, out: *?*anyopaque) callconv(.c) i32;
const vkEnumerateInstanceExtensionPropertiesFn = *const fn (layer: ?[*:0]const u8, count: *u32, props: ?[*]VkExtensionProperties) callconv(.c) i32;
const vkEnumeratePhysicalDevicesFn = *const fn (instance: ?*anyopaque, count: *u32, devices: ?[*]?*anyopaque) callconv(.c) i32;
const vkDestroyInstanceFn = *const fn (instance: ?*anyopaque, alloc: ?*const anyopaque) callconv(.c) void;

pub const Report = struct {
    hard_failures: u32 = 0,
    warnings: u32 = 0,
};

pub fn run(alloc: std.mem.Allocator) !u8 {
    var rep = Report{};
    std.debug.print("cipher doctor — is this machine ready for cipher apps?\n\n", .{});

    // 1. zig
    var zig_buf: [512]u8 = undefined;
    if (util.findZig(&zig_buf)) |z| {
        const out = util.runCapture(alloc, z, &.{"version"}, 4096) catch "";
        const v = std.mem.trim(u8, out, " \r\n");
        if (std.mem.startsWith(u8, v, "0.17.")) {
            ok("zig {s}", .{v});
        } else {
            warn("zig {s} (cipher is built and tested against 0.17.x)", .{v});
        }
    } else {
        fail("zig not found on PATH (or in $ZIG)", .{});
        rep.hard_failures += 1;
    }

    // 2. Wayland session
    const display = util.env("WAYLAND_DISPLAY") orelse "wayland-0";
    const runtime_dir = util.env("XDG_RUNTIME_DIR") orelse "/run/user"; // best effort
    const session_type = util.env("XDG_SESSION_TYPE") orelse "?";
    var sock_buf: [4096]u8 = undefined;
    const sock = if (std.mem.startsWith(u8, display, "/")) display else std.fmt.bufPrint(&sock_buf, "{s}/{s}", .{ runtime_dir, display }) catch "";
    if (util.exists(sock) or session_type.len > 0 and std.mem.eql(u8, session_type, "wayland")) {
        ok("wayland session (WAYLAND_DISPLAY={s}, XDG_SESSION_TYPE={s})", .{ display, session_type });
    } else {
        fail("no Wayland session (WAYLAND_DISPLAY={s}, socket {s} missing)", .{ display, sock });
        rep.hard_failures += 1;
    }

    // 3. dlopen'd runtime libraries (same sonames the framework probes)
    checkLibs(&rep, &.{
        "libwayland-client.so.0",
        "/usr/lib/libwayland-client.so.0",
        "libwayland-client.so",
    }, "libwayland-client", true);
    checkLibs(&rep, &.{"libxkbcommon.so.0"}, "libxkbcommon", false);

    // 4. Vulkan: instance + at least one physical device
    rep = checkVulkan(rep);

    // 5. A font cipher apps can use
    const font_candidates = [_][]const u8{
        "/usr/share/fonts/TTF/JetBrainsMonoNerdFontMono-Regular.ttf",
        "/usr/share/fonts/TTF/JetBrainsMono-Regular.ttf",
        "/usr/share/fonts/liberation/LiberationSans-Regular.ttf",
        "/usr/share/fonts/TTF/DejaVuSans.ttf",
        "/usr/share/fonts/truetype/dejavu/DejaVuSans.ttf",
        "/usr/share/fonts/TTF/LiberationMono-Regular.ttf",
    };
    var font_ok = false;
    for (font_candidates) |f| {
        if (util.exists(f)) {
            font_ok = true;
            break;
        }
    }
    if (font_ok) {
        ok("font found", .{});
    } else {
        warn("no optional system font found; the built-in Instrument Sans font requires no installation", .{});
    }

    std.debug.print("\n", .{});
    if (rep.hard_failures == 0) {
        std.debug.print("cipher doctor: OK — this machine can build and run cipher apps.\n", .{});
        return 0;
    }
    std.debug.print("cipher doctor: {d} hard problem(s) ({d} warning(s)):\n", .{ rep.hard_failures, rep.warnings });
    std.debug.print("hints:\n", .{});
    std.debug.print("  arch:    pacman -S vulkan-icd-loader vulkan-swrast  # software ICD (llvmpipe)\n", .{});
    std.debug.print("           pacman -S vulkan-radeon / vulkan-intel / nvidia-utils   # your driver\n", .{});
    std.debug.print("  debian:  apt install libvulkan1 mesa-vulkan-drivers\n", .{});
    std.debug.print("  wayland: any Wayland compositor (GNOME, KDE, wlroots-based) — no X11 needed\n", .{});
    return 1;
}

fn ok(comptime fmt: []const u8, args: anytype) void {
    std.debug.print("  ✓ " ++ fmt ++ "\n", args);
}
fn warn(comptime fmt: []const u8, args: anytype) void {
    std.debug.print("  ! " ++ fmt ++ "\n", args);
}
fn fail(comptime fmt: []const u8, args: anytype) void {
    std.debug.print("  ✗ " ++ fmt ++ "\n", args);
}

/// Try candidate sonames in order; report once for the logical library.
fn checkLibs(rep: *Report, candidates: []const []const u8, label: []const u8, hard: bool) void {
    for (candidates) |name| {
        var buf: [256]u8 = undefined;
        if (name.len >= buf.len) continue;
        @memcpy(buf[0..name.len], name);
        buf[name.len] = 0;
        const z: [*:0]const u8 = @ptrCast(&buf);
        const h = dlopen(z, RTLD_NOW);
        if (h) |handle| {
            _ = dlclose(handle);
            ok("{s}", .{label});
            return;
        }
    }
    if (hard) {
        fail("{s} not loadable (tried {s})", .{ label, joinHint(candidates) });
        rep.hard_failures += 1;
    } else {
        warn("{s} not loadable", .{label});
        rep.warnings += 1;
    }
}

fn joinHint(candidates: []const []const u8) []const u8 {
    return if (candidates.len == 0) "" else candidates[0];
}

fn checkVulkan(rep_in: Report) Report {
    var rep = rep_in;
    const h = dlopen("libvulkan.so.1", RTLD_NOW) orelse {
        fail("libvulkan.so.1 not loadable (install your driver's Vulkan support)", .{});
        rep.hard_failures += 1;
        return rep;
    };
    defer _ = dlclose(h);

    const createInstance: ?vkCreateInstanceFn = @ptrCast(dlsym(h, "vkCreateInstance"));
    const enumExt: ?vkEnumerateInstanceExtensionPropertiesFn = @ptrCast(dlsym(h, "vkEnumerateInstanceExtensionProperties"));
    const enumPhys: ?vkEnumeratePhysicalDevicesFn = @ptrCast(dlsym(h, "vkEnumeratePhysicalDevices"));
    const destroyInstance: ?vkDestroyInstanceFn = @ptrCast(dlsym(h, "vkDestroyInstance"));
    if (createInstance == null or enumExt == null or enumPhys == null or destroyInstance == null) {
        fail("libvulkan.so.1 loads but is missing core symbols (ancient loader?)", .{});
        rep.hard_failures += 1;
        return rep;
    }

    const app_name: [*c]const u8 = "cipher-doctor";
    const app = VkApplicationInfo{
        .sType = VK_STRUCTURE_TYPE_APPLICATION_INFO,
        .pNext = null,
        .pApplicationName = app_name,
        .applicationVersion = 0x00010000,
        .pEngineName = "cipher",
        .engineVersion = 0x00010000,
        .apiVersion = 0x00400000, // Vulkan 1.0
    };
    // Instance creation works with zero extensions; we only inspect what's there.
    const ci = VkInstanceCreateInfo{
        .sType = VK_STRUCTURE_TYPE_INSTANCE_CREATE_INFO,
        .pNext = null,
        .flags = 0,
        .pApplicationInfo = &app,
        .enabledLayerCount = 0,
        .ppEnabledLayerNames = null,
        .enabledExtensionCount = 0,
        .ppEnabledExtensionNames = null,
    };
    var instance: ?*anyopaque = null;
    const rc = createInstance.?(&ci, null, &instance);
    if (rc != VK_SUCCESS) {
        fail("vkCreateInstance failed (rc={d}) — loader present but broken?", .{rc});
        rep.hard_failures += 1;
        return rep;
    }
    defer destroyInstance.?(instance, null);

    // Instance extensions worth having (best-effort enable when present).
    var ext_count: u32 = 0;
    _ = enumExt.?(null, &ext_count, null);
    const ext_props = std.heap.page_allocator.alloc(VkExtensionProperties, ext_count) catch {
        fail("out of memory enumerating extensions", .{});
        rep.warnings += 1;
        return rep;
    };
    defer std.heap.page_allocator.free(ext_props);
    var got: u32 = ext_count;
    var wayland_surface = false;
    if (enumExt.?(null, &got, ext_props.ptr) == VK_SUCCESS) {
        var i: u32 = 0;
        while (i < got) : (i += 1) {
            const nm = std.mem.span(@as([*:0]const u8, @ptrCast(&ext_props[i].extensionName)));
            if (std.mem.eql(u8, nm, "VK_KHR_wayland_surface")) wayland_surface = true;
        }
    }

    var dev_count: u32 = 0;
    if (enumPhys.?(instance, &dev_count, null) != VK_SUCCESS or dev_count == 0) {
        fail("no Vulkan physical devices (no driver for your GPU — try the software ICD: vulkan-swrast / mesa-vulkan-drivers)", .{});
        rep.hard_failures += 1;
        return rep;
    }

    if (wayland_surface) {
        ok("vulkan: {d} device(s), VK_KHR_wayland_surface present (WSI path; wl_shm fallback also available)", .{dev_count});
    } else {
        warn("vulkan: {d} device(s), but VK_KHR_wayland_surface missing — WSI present unavailable; cipher falls back to software-shm (slower)", .{dev_count});
        rep.warnings += 1;
    }
    return rep;
}
