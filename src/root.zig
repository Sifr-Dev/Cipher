//! sifr framework root module — first vertical slice: native GPU surface.
//! Pure-Zig Wayland client + wl_shm diagnostic presentation.
//! Stage A of FIRST-VERTICAL-SLICE.md.
const std = @import("std");
const types = @import("core/types.zig");
const wayland = @import("os/linux/wayland/client.zig");
const device = @import("gpu/vulkan/device.zig");
const frame = @import("gpu/vulkan/frame.zig");
const text_gpu = @import("gpu/vulkan/text.zig");
const ui_mod = @import("ui/ui.zig");
const atlas_mod = @import("ui/text/atlas.zig");

const resources = @import("resources");
const UI_PX: f32 = 20;

/// 0xAARRGGBB -> linear-ish [4]f32 rgba for the GPU vertex color.
fn rgba01(c: u32) [4]f32 {
    return .{
        @as(f32, @floatFromInt((c >> 16) & 0xFF)) / 255.0,
        @as(f32, @floatFromInt((c >> 8) & 0xFF)) / 255.0,
        @as(f32, @floatFromInt(c & 0xFF)) / 255.0,
        @as(f32, @floatFromInt((c >> 24) & 0xFF)) / 255.0,
    };
}

/// Convert UI draw commands into GPU quads (rects sample the reserved white
/// texel (0,0); text runs expand to per-glyph quads from the atlas).
fn buildQuads(atlas: *atlas_mod.TextAtlas, cmds: []const ui_mod.DrawCmd, out: []text_gpu.Quad) !usize {
    var n: usize = 0;
    for (cmds) |c| {
        switch (c) {
            .rect => |r| {
                if (n >= out.len) return error.TooManyQuads;
                out[n] = .{
                    .x = r.rect.x,
                    .y = r.rect.y,
                    .w = r.rect.w,
                    .h = r.rect.h,
                    .u0 = 0,
                    .v0 = 0,
                    .u1 = 0,
                    .v1 = 0,
                    .color = rgba01(r.color),
                };
                n += 1;
            },
            .shadow_rect => |s| {
                if (n >= out.len) return error.TooManyQuads;
                const margin_x = s.aux[1] * 2.0 + 2.0;
                const margin_top = s.aux[1] * 2.0 + 2.0;
                const margin_bottom = s.aux[1] * 2.0 + @abs(s.aux[3]) + 2.0;
                const cx = s.rect.x + s.rect.w / 2.0;
                const cy = s.rect.y + s.rect.h / 2.0;
                out[n] = .{
                    .x = s.rect.x - margin_x,
                    .y = s.rect.y - margin_top,
                    .w = s.rect.w + 2 * margin_x,
                    .h = s.rect.h + margin_top + margin_bottom,
                    .u0 = 2,
                    .v0 = 2,
                    .u1 = 2,
                    .v1 = 2,
                    .color = rgba01(s.color),
                    .aux1 = .{ cx, cy, s.rect.w / 2.0, s.rect.h / 2.0 },
                    .aux2 = .{ s.aux[0], s.aux[1], s.aux[2], s.aux[3] },
                };
                n += 1;
            },
            .text => |t| {
                var pen = t.x;
                const col = rgba01(t.color);
                var i: usize = 0;
                while (i < t.str.len) {
                    const d = atlas_mod.TextAtlas.decodeUtf8(t.str[i..]) orelse {
                        i += 1;
                        continue;
                    };
                    const g = try atlas.glyph(d.cp);
                    if (g.w > 0 and g.h > 0) {
                        if (n >= out.len) return error.TooManyQuads;
                        const aw = @as(f32, @floatFromInt(atlas.atlas_w));
                        const ah = @as(f32, @floatFromInt(atlas.atlas_h));
                        out[n] = .{
                            .x = pen + g.bearing_x,
                            .y = t.baseline - g.top,
                            .w = @floatFromInt(g.w),
                            .h = @floatFromInt(g.h),
                            .u0 = @as(f32, @floatFromInt(g.atlas_x)) / aw,
                            .v0 = @as(f32, @floatFromInt(g.atlas_y)) / ah,
                            .u1 = @as(f32, @floatFromInt(g.atlas_x + g.w)) / aw,
                            .v1 = @as(f32, @floatFromInt(g.atlas_y + g.h)) / ah,
                            .color = col,
                        };
                        n += 1;
                    }
                    pen += g.advance;
                    i += d.len;
                }
            },
        }
    }
    return n;
}

pub const Error = types.Error;

/// Application lifecycle and capability handle.
pub const Application = struct {
    diagnostics: types.Diagnostics = undefined,

    pub fn init(allocator: std.mem.Allocator) Application {
        return .{
            .diagnostics = types.initDiagnostics(allocator),
        };
    }

    pub fn run(self: *Application, process_init: std.process.Init.Minimal) !void {
        self.diagnostics.record("app", "start");
        defer self.diagnostics.record("app", "stop");

        const runtime_dir = std.process.Environ.getPosix(process_init.environ, "XDG_RUNTIME_DIR") orelse "/run/user/1000";
        const display_name = std.process.Environ.getPosix(process_init.environ, "WAYLAND_DISPLAY") orelse "wayland-0";

        self.diagnostics.record("wayland", "connect");
        var conn = try wayland.Connection.connect(runtime_dir, display_name);
        defer conn.disconnect();

        var ids = wayland.ObjectIds{};
        ids.registry = ids.new();

        // get_registry
        var cursor = wayland.Cursor{};
        cursor.writeU32(ids.registry.?);
        try conn.send(wayland.WL_DISPLAY, 1, cursor.slice());

        // sync to force global delivery
        ids.sync_callback = ids.new();
        cursor = wayland.Cursor{};
        cursor.writeU32(ids.sync_callback.?);
        try conn.send(wayland.WL_DISPLAY, 0, cursor.slice());

        // Collect globals
        var compositor_global: ?u32 = null;
        var shm_global: ?u32 = null;
        var wm_base_global: ?u32 = null;
        var seat_global: ?u32 = null;

        while (true) {
            var event = wayland.Event{};
            try conn.recv(&event);

            if (ids.registry != null and event.sender == ids.registry.? and event.opcode == 0) {
                // registry global event: name u32, interface string, version u32
                var pos: usize = 0;
                const name = std.mem.readInt(u32, event.payload()[0..4], .little);
                pos = 4;
                const iface_len = std.mem.readInt(u32, event.payload()[pos..][0..4], .little);
                pos += 4;
                const iface = event.payload()[pos..][0 .. iface_len - 1];
                pos += iface_len;
                while (pos % 4 != 0) pos += 1;
                const version = std.mem.readInt(u32, event.payload()[pos..][0..4], .little);

                if (std.mem.eql(u8, iface, "wl_compositor")) compositor_global = name;
                if (std.mem.eql(u8, iface, "wl_shm")) shm_global = name;
                if (std.mem.eql(u8, iface, "xdg_wm_base")) wm_base_global = name;
                if (std.mem.eql(u8, iface, "wl_seat")) seat_global = name;

                std.debug.print("global {d} '{s}' v{d}\n", .{ name, iface, version });
            }

            if (ids.sync_callback != null and event.sender == ids.sync_callback.? and event.opcode == 0) {
                break;
            }
        }

        const compositor = compositor_global orelse return error.ProtocolError;
        const shm = shm_global orelse return error.ProtocolError;
        const wm_base = wm_base_global orelse return error.ProtocolError;
        const seat = seat_global orelse return error.ProtocolError;

        // Bind required globals
        {
            const object_id = ids.new();
            cursor = wayland.Cursor{};
            cursor.writeU32(compositor);
            cursor.str("wl_compositor");
            cursor.writeU32(4);
            cursor.writeU32(object_id);
            try conn.send(ids.registry.?, 0, cursor.slice());
            ids.compositor = object_id;
        }
        {
            const object_id = ids.new();
            cursor = wayland.Cursor{};
            cursor.writeU32(shm);
            cursor.str("wl_shm");
            cursor.writeU32(1);
            cursor.writeU32(object_id);
            try conn.send(ids.registry.?, 0, cursor.slice());
            ids.shm = object_id;
        }
        {
            const object_id = ids.new();
            cursor = wayland.Cursor{};
            cursor.writeU32(wm_base);
            cursor.str("xdg_wm_base");
            cursor.writeU32(6);
            cursor.writeU32(object_id);
            try conn.send(ids.registry.?, 0, cursor.slice());
            ids.wm_base = object_id;
        }
        {
            const object_id = ids.new();
            cursor = wayland.Cursor{};
            cursor.writeU32(seat);
            cursor.str("wl_seat");
            cursor.writeU32(5);
            cursor.writeU32(object_id);
            try conn.send(ids.registry.?, 0, cursor.slice());
            ids.seat = object_id;
        }

        // Create surface
        ids.surface = ids.new();
        cursor = wayland.Cursor{};
        cursor.writeU32(ids.surface.?);
        try conn.send(ids.compositor.?, 0, cursor.slice());

        // Create xdg_surface
        ids.xdg_surface = ids.new();
        cursor = wayland.Cursor{};
        cursor.writeU32(ids.xdg_surface.?);
        cursor.writeU32(ids.surface.?);
        try conn.send(ids.wm_base.?, 2, cursor.slice());

        // Create toplevel: xdg_surface.get_toplevel (opcode 1 on xdg_surface,
        // NOT on wm_base — wm_base opcode 1 is create_positioner).
        ids.toplevel = ids.new();
        cursor = wayland.Cursor{};
        cursor.writeU32(ids.toplevel.?);
        cursor.writeU32(ids.xdg_surface.?);
        try conn.send(ids.xdg_surface.?, 1, cursor.slice());

        // Set title and app id
        var title_cursor = wayland.Cursor{};
        title_cursor.str("sifr");
        try conn.send(ids.toplevel.?, 2, title_cursor.slice());
        var appid_cursor = wayland.Cursor{};
        appid_cursor.str("sifr");
        try conn.send(ids.toplevel.?, 3, appid_cursor.slice());

        // Initial commit
        try conn.send(ids.surface.?, 6, &.{});

        // Wait for configure
        var configured: bool = false;
        var serial: u32 = 0;
        while (!configured) {
            var event = wayland.Event{};
            try conn.recv(&event);
            if (ids.xdg_surface != null and event.sender == ids.xdg_surface.? and event.opcode == 0) {
                serial = event.read32(0);
                var ack_cursor = wayland.Cursor{};
                ack_cursor.writeU32(serial);
                try conn.send(ids.xdg_surface.?, 4, ack_cursor.slice());
                configured = true;
            }
        }
        std.debug.print("sifr: xdg toplevel configured (serial {d})\n", .{serial});

        // Create wl_shm diagnostic buffer
        const width: u32 = 640;
        const height: u32 = 400;
        var shm_buf = try wayland.ShmBuffer.allocate(width, height);
        defer shm_buf.deinit();

        // GPU UI path (optional): Vulkan device + text atlas + immediate-mode
        // UI rendered as quads through the text pipeline, copied into wl_shm.
        // Falls back to the software rasterizer when no ICD/font is available.
        var vk: device.Vulkan = undefined;
        var dev: device.Device = .{};
        var gt: ?text_gpu.GpuText = null;
        var atlas: ?atlas_mod.TextAtlas = null;
        var ui: ?ui_mod.Ui = null;
        if (device.load()) |v| {
            vk = v;
            if (device.createDevice(&vk, &dev)) |_| {
                const a = atlas_mod.TextAtlas.init(std.heap.page_allocator, resources.default_font, UI_PX) catch |e| {
                    std.debug.print("sifr: embedded font initialization failed: {s}\n", .{@errorName(e)});
                    return error.FontLoadFailed;
                };
                atlas = a;
                if (text_gpu.GpuText.init(&vk, &dev, width, height, a.atlas_w, a.atlas_h)) |g| {
                    gt = g;
                    gt.?.uploadAtlas(&vk, &dev, a.atlas) catch {
                        gt = null;
                    };
                } else |_| {}
                if (gt != null) {
                    ui = ui_mod.Ui.init(std.heap.page_allocator, &atlas.?);
                }
            } else |_| {}
        } else |_| {}
        const gpu_ui = ui != null and gt != null;
        std.debug.print("sifr: render path = {s}\n", .{if (gpu_ui) "vulkan-gpu-ui" else "software-shm"});

        // Create shm pool and buffer
        ids.shm_pool = ids.new();
        cursor = wayland.Cursor{};
        cursor.writeU32(ids.shm_pool.?);
        cursor.writeI32(@intCast(shm_buf.pixels.len));
        try conn.sendFd(ids.shm.?, 0, cursor.slice(), shm_buf.fd);

        ids.buffer = ids.new();
        cursor = wayland.Cursor{};
        cursor.writeU32(ids.buffer.?);
        cursor.writeI32(0);
        cursor.writeI32(width);
        cursor.writeI32(height);
        cursor.writeI32(@intCast(shm_buf.stride));
        cursor.writeU32(0); // ARGB8888
        try conn.send(ids.shm_pool.?, 0, cursor.slice());

        // Get keyboard and pointer (requests go to the BOUND seat object,
        // not the registry global name).
        ids.keyboard = ids.new();
        cursor = wayland.Cursor{};
        cursor.writeU32(ids.keyboard.?);
        try conn.send(ids.seat.?, 1, cursor.slice()); // get_keyboard
        ids.pointer = ids.new();
        cursor = wayland.Cursor{};
        cursor.writeU32(ids.pointer.?);
        try conn.send(ids.seat.?, 0, cursor.slice()); // get_pointer

        // Frame loop
        var frame_index: u32 = 0;
        var quit_requested: bool = false;
        const frame_count: u32 = 24;
        var clicks: u32 = 0;
        var mouse_x: f32 = 0;
        var mouse_y: f32 = 0;
        var mouse_down: bool = false;
        var mouse_pressed: bool = false;

        while (frame_index < frame_count and !quit_requested) : (frame_index += 1) {
            const cy = @as(usize, @intCast(height)) / 2;
            const cx = @as(usize, @intCast(width)) / 2;
            const r: usize = 12;

            if (ui != null and gt != null) {
                // GPU UI: declare widgets, lay out, render quads, copy to shm.
                var clicks_buf: [40]u8 = undefined;
                const clicks_str = std.fmt.bufPrint(&clicks_buf, "Clicks: {d}", .{clicks}) catch "Clicks: ?";
                var u = &ui.?;
                u.begin(@floatFromInt(width), @floatFromInt(height), mouse_x, mouse_y, mouse_down, mouse_pressed, 1.0) catch {
                    ui = null;
                    continue;
                };
                u.panel(.{ .fixed = 340 }, .{ .fixed = 190 }, 16, 10) catch {
                    ui = null;
                    continue;
                };
                u.label("Cipher — native GPU UI", ui_mod.COLOR_TEXT) catch {};
                u.label(clicks_str, ui_mod.COLOR_TEXT_DIM) catch {};
                if (u.button("Click me") catch false) clicks += 1;
                u.endPanel();
                u.end() catch {
                    ui = null;
                    continue;
                };
                var quads: [4096]text_gpu.Quad = undefined;
                const n = buildQuads(&atlas.?, u.drawCmds(), &quads) catch {
                    ui = null;
                    continue;
                };
                gt.?.render(&vk, &dev, quads[0..n]) catch {
                    std.debug.print("sifr: gpu render failed, falling back to software\n", .{});
                    ui = null;
                    gt = null;
                    continue;
                };
                @memcpy(shm_buf.pixels, gt.?.pixels());
                mouse_pressed = false;
            } else {
                // Software fallback: clear to void, draw a brass center dot.
                var pixels: [640 * 400]u32 = undefined;
                for (&pixels) |*pp| pp.* = 0xFF04060B;
                var py = if (cy >= r) cy - r else 0;
                const py_end = if (cy + r < height) cy + r + 1 else height;
                while (py < py_end) : (py += 1) {
                    var px = if (cx >= r) cx - r else 0;
                    const px_end = if (cx + r < width) cx + r + 1 else width;
                    while (px < px_end) : (px += 1) {
                        const dx = if (px >= cx) px - cx else cx - px;
                        const dy = if (py >= cy) py - cy else cy - py;
                        if (dx * dx + dy * dy <= r * r) {
                            pixels[py * width + px] = 0xFFEAB444;
                        }
                    }
                }
                var shm_u32: []u32 = @ptrCast(@alignCast(shm_buf.pixels));
                for (0..width * height) |i| {
                    shm_u32[i] = pixels[i];
                }
            }

            // Attach, damage, commit
            cursor = wayland.Cursor{};
            cursor.writeU32(ids.buffer.?);
            cursor.writeI32(0);
            cursor.writeI32(0);
            try conn.send(ids.surface.?, 1, cursor.slice());
            cursor = wayland.Cursor{};
            cursor.writeI32(0);
            cursor.writeI32(0);
            cursor.writeI32(width);
            cursor.writeI32(height);
            try conn.send(ids.surface.?, 2, cursor.slice());
            try conn.send(ids.surface.?, 6, &.{});

            // Request frame callback
            ids.frame_callback = ids.new();
            cursor = wayland.Cursor{};
            cursor.writeU32(ids.frame_callback.?);
            try conn.send(ids.surface.?, 3, cursor.slice());
            try conn.send(ids.surface.?, 6, &.{});

            // Wait for frame done
            var frame_done: bool = false;
            while (!frame_done) {
                var event = wayland.Event{};
                try conn.recv(&event);

                if (ids.frame_callback != null and event.sender == ids.frame_callback.? and event.opcode == 0) {
                    frame_done = true;
                }

                // Keyboard quit: Escape or q (key event: time@0, key@1, state@2)
                if (ids.keyboard != null and event.sender == ids.keyboard.?) {
                    if (event.opcode == 3) {
                        const key = event.read32(1);
                        const state = event.read32(2);
                        if (state == 1 and (key == 1 or key == 16)) {
                            quit_requested = true;
                            frame_done = true;
                        }
                    }
                }

                // Pointer: motion (time@0, x@1, y@2 fixed24.8), button (time@0, button@1, state@2)
                if (ids.pointer != null and event.sender == ids.pointer.?) {
                    switch (event.opcode) {
                        2 => {
                            mouse_x = @floatCast(event.fixed24_8(1));
                            mouse_y = @floatCast(event.fixed24_8(2));
                        },
                        3 => {
                            const button = event.read32(1);
                            const state = event.read32(2);
                            if (button == 0x110) { // BTN_LEFT
                                if (state == 1) {
                                    mouse_down = true;
                                    mouse_pressed = true;
                                } else {
                                    mouse_down = false;
                                }
                            }
                        },
                        else => {},
                    }
                }

                if (event.sender == wayland.WL_DISPLAY and event.opcode == 0) {
                    std.debug.print("sifr: wayland error\n", .{});
                    return error.ProtocolError;
                }
            }
        }

        // Teardown
        if (ids.keyboard) |id| try conn.send(id, 0, &.{});
        if (ids.pointer) |id| try conn.send(id, 1, &.{});
        if (ids.seat) |id| try conn.send(id, 3, &.{});
        if (ids.toplevel) |id| try conn.send(id, 0, &.{});
        if (ids.xdg_surface) |id| try conn.send(id, 0, &.{});
        if (ids.buffer) |id| try conn.send(id, 0, &.{});
        if (ids.shm_pool) |id| try conn.send(id, 1, &.{});
        if (ids.surface) |id| try conn.send(id, 0, &.{});

        std.debug.print("sifr: WAYLAND_PROTOCOL_OK frames={d}\n", .{frame_index});
    }
};

pub fn main(init: std.process.Init.Minimal) !void {
    var app = Application.init(std.heap.page_allocator);
    try app.run(init);
}
