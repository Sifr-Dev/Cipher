//! sifr framework root module — first vertical slice: native GPU surface.
//! Pure-Zig Wayland client + wl_shm diagnostic presentation.
//! Stage A of FIRST-VERTICAL-SLICE.md.
const std = @import("std");
const types = @import("core/types.zig");
const wayland = @import("os/linux/wayland/client.zig");

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

        // Create toplevel
        ids.toplevel = ids.new();
        cursor = wayland.Cursor{};
        cursor.writeU32(ids.toplevel.?);
        cursor.writeU32(ids.xdg_surface.?);
        try conn.send(ids.wm_base.?, 1, cursor.slice());

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

        // Get keyboard and pointer
        ids.keyboard = ids.new();
        cursor = wayland.Cursor{};
        cursor.writeU32(ids.keyboard.?);
        try conn.send(seat, 1, cursor.slice()); // get_keyboard
        ids.pointer = ids.new();
        cursor = wayland.Cursor{};
        cursor.writeU32(ids.pointer.?);
        try conn.send(seat, 0, cursor.slice()); // get_pointer

        // Frame loop
        var frame_index: u32 = 0;
        var quit_requested: bool = false;
        const frame_count: u32 = 24;

        while (frame_index < frame_count and !quit_requested) : (frame_index += 1) {
            // Clear to void color
            var pixels: [640 * 400]u32 = undefined;
            for (&pixels) |*p| p.* = 0xFF04060B;

            // Draw a simple brass center dot
            const cy = @as(usize, @intCast(height)) / 2;
            const cx = @as(usize, @intCast(width)) / 2;
            const r: usize = 12;
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

            // Copy to shm buffer (pixels already in ARGB8888 little-endian layout)
            var shm_u32: []u32 = @ptrCast(@alignCast(shm_buf.pixels));
            for (0..width * height) |i| {
                shm_u32[i] = pixels[i];
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

                // Keyboard quit: Escape or q
                if (ids.keyboard != null and event.sender == ids.keyboard.?) {
                    if (event.opcode == 3) {
                        const key = event.read32(2);
                        const state = event.read32(3);
                        if (state == 1 and (key == 1 or key == 16)) {
                            quit_requested = true;
                            frame_done = true;
                        }
                    }
                }

                // Pointer motion/buttons
                if (ids.pointer != null and event.sender == ids.pointer.?) {
                    switch (event.opcode) {
                        2 => {
                            // pointer motion
                        },
                        3 => {
                            const button = event.read32(2);
                            const state = event.read32(3);
                            if (button == 0x110 and state == 1) { // BTN_LEFT pressed
                                std.debug.print("pointer: button left press\n", .{});
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
