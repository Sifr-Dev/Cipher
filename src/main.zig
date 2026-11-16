const std = @import("std");
const geometry = @import("geometry.zig");
const render = @import("render.zig");
const wayland = @import("wayland.zig");

const WIDTH = render.WIDTH;
const HEIGHT = render.HEIGHT;
const FRAME_COUNT = 24;

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

const Global = struct {
    name: u32,
    interface_len: usize,
    interface: [32]u8,
    version: u32,

    fn iface(self: *const Global) []const u8 {
        return self.interface[0..self.interface_len];
    }
};

const Client = struct {
    connection: wayland.Connection,
    ids: wayland.ObjectIds = .{},
    debug: bool = false,
    configured: bool = false,
    serial: u32 = 0,
    frame_index: u32 = 0,
    globals_len: usize = 0,
    globals: [8]Global = undefined,
    seat: ?u32 = null,
    keyboard: ?u32 = null,
    pointer: ?u32 = null,
    quit_requested: bool = false,
    pointer_x: f64 = -1,
    pointer_y: f64 = -1,
    keyboard_focused: bool = false,

    const wanted = [_][]const u8{ "wl_compositor", "wl_shm", "xdg_wm_base", "wl_seat" };

    fn rememberGlobal(self: *Client, name: u32, interface: []const u8, version: u32) void {
        for (wanted) |needle| {
            if (!std.mem.eql(u8, interface, needle)) continue;
            if (self.findGlobal(needle) != null) return; // first advertisement wins
            if (self.globals_len >= self.globals.len) return;
            var global = Global{
                .name = name,
                .interface_len = @min(interface.len, 32),
                .interface = undefined,
                .version = version,
            };
            @memcpy(global.interface[0..global.interface_len], interface[0..global.interface_len]);
            self.globals[self.globals_len] = global;
            self.globals_len += 1;
            return;
        }
    }

    fn findGlobal(self: *Client, interface: []const u8) ?*const Global {
        for (self.globals[0..self.globals_len]) |*global| {
            if (std.mem.eql(u8, global.iface(), interface)) return global;
        }
        return null;
    }

    fn next(self: *Client) !wayland.Event {
        var event: wayland.Event = undefined;
        try self.connection.recv(&event);

        if (self.debug) {
            std.debug.print("event sender={d} opcode={d} len={d}\n", .{ event.sender, event.opcode, event.len });
        }

        if (event.sender == wayland.WL_DISPLAY and event.opcode == 0) {
            var reader = Reader{ .data = event.payload() };
            const object_id = reader.read32();
            const code = reader.read32();
            const message = reader.str();
            std.debug.print("wayland error object={d} code={d}: {s}\n", .{ object_id, code, message });
            return wayland.Error.ProtocolError;
        }

        if (self.ids.wm_base != null and event.sender == self.ids.wm_base.? and event.opcode == 0) {
            // xdg_wm_base ping: answer pong with the same serial.
            var pong: [4]u8 = undefined;
            std.mem.writeInt(u32, &pong, event.read32(0), .little);
            try self.connection.send(self.ids.wm_base.?, 3, &pong);
        }

        if (self.seat != null and event.sender == self.seat.?) {
            if (event.opcode == 0) {
                const capabilities = event.read32(0);
                std.debug.print("cipher: seat capabilities {d}\n", .{capabilities});
            }
        }

        if (self.keyboard != null and event.sender == self.keyboard.?) {
            switch (event.opcode) {
                0 => {
                    const size = event.read32(1);
                    if (event.fd) |fdv| _ = std.os.linux.close(fdv);
                    std.debug.print("cipher: keymap received (size {d}), fd closed\n", .{size});
                },
                1 => {
                    self.keyboard_focused = true;
                    std.debug.print("cipher: keyboard focus acquired\n", .{});
                },
                2 => {
                    self.keyboard_focused = false;
                    std.debug.print("cipher: keyboard focus lost\n", .{});
                },
                3 => {
                    const key = event.read32(2);
                    const state = event.read32(3);
                    if (state == 1) {
                        if (key == 1 or key == 16) {
                            std.debug.print("cipher: quit key pressed\n", .{});
                            self.quit_requested = true;
                        } else {
                            std.debug.print("cipher: key {d} pressed\n", .{key});
                        }
                    }
                },
                4 => {}, // modifiers: state tracked implicitly by the compositor for now
                5 => {}, // repeat_info: rate/delay; handled by key repeat later
                else => {},
            }
        }

        if (self.pointer != null and event.sender == self.pointer.?) {
            switch (event.opcode) {
                0 => std.debug.print("cipher: pointer entered surface\n", .{}),
                1 => {
                    self.pointer_x = -1;
                    self.pointer_y = -1;
                },
                2 => {
                    self.pointer_x = event.fixed24_8(1);
                    self.pointer_y = event.fixed24_8(2);
                },
                3 => {
                    const button = event.read32(2);
                    const state = event.read32(3);
                    if (state == 1) {
                        std.debug.print("cipher: button {d} pressed at ({d:.1}, {d:.1})\n", .{ button, self.pointer_x, self.pointer_y });
                        const dx = self.pointer_x - @as(f64, WIDTH) / 2.0;
                        const dy = self.pointer_y - @as(f64, HEIGHT) / 2.0;
                        if (dx * dx + dy * dy <= 144.0) {
                            std.debug.print("cipher: brass center clicked; closing\n", .{});
                            self.quit_requested = true;
                        }
                    }
                },
                else => {},
            }
        }

        return event;
    }

    fn waitForSyncDone(self: *Client) !void {
        while (true) {
            const event = try self.next();
            if (self.ids.sync_callback != null and event.sender == self.ids.sync_callback.? and event.opcode == 0) {
                return;
            }
        }
    }

    fn collectGlobals(self: *Client) !void {
        while (true) {
            const event = try self.next();
            if (self.ids.registry != null and event.sender == self.ids.registry.? and event.opcode == 0) {
                var reader = Reader{ .data = event.payload() };
                const name = reader.read32();
                const interface = reader.str();
                const version = reader.read32();
                self.rememberGlobal(name, interface, version);
                if (self.debug) {
                    std.debug.print("global {d} {s} v{d}\n", .{ name, interface, version });
                }
                continue;
            }
            if (self.ids.sync_callback != null and event.sender == self.ids.sync_callback.? and event.opcode == 0) {
                return;
            }
        }
    }

    fn bindRequired(self: *Client) !void {
        const binds = .{
            .{ "wl_compositor", 4 },
            .{ "wl_shm", 1 },
            .{ "xdg_wm_base", 6 },
            .{ "wl_seat", 5 },
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
            if (std.mem.eql(u8, interface, "wl_seat")) {
                self.ids.seat = object_id;
                self.seat = object_id;
            }
        }
    }

    fn setString(self: *Client, object_id: u32, opcode: u16, value: []const u8) !void {
        var cursor = wayland.Cursor{};
        cursor.str(value);
        try self.connection.send(object_id, opcode, cursor.slice());
    }

    fn waitForConfigure(self: *Client) !void {
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

    fn requestFrameCallback(self: *Client) !void {
        const callback = self.ids.new();
        self.ids.frame_callback = callback;
        var cursor = wayland.Cursor{};
        cursor.writeU32(callback);
        try self.connection.send(self.ids.surface.?, 3, cursor.slice()); // wl_surface.frame
    }

    fn waitForFrameDone(self: *Client) !void {
        while (true) {
            const event = try self.next();
            if (self.ids.frame_callback != null and event.sender == self.ids.frame_callback.? and event.opcode == 0) {
                return;
            }
        }
    }
};

pub fn main(init: std.process.Init.Minimal) !void {
    var frame_count: u32 = FRAME_COUNT;
    var args_iter = std.process.Args.Iterator.init(init.args);
    _ = args_iter.next();
    while (args_iter.next()) |arg| {
        if (std.mem.eql(u8, arg, "--frames")) {
            if (args_iter.next()) |raw| {
                frame_count = std.fmt.parseUnsigned(u32, raw, 10) catch frame_count;
            }
        }
    }

    const runtime_dir = std.process.Environ.getPosix(init.environ, "XDG_RUNTIME_DIR") orelse "/run/user/1000";
    const display_name = std.process.Environ.getPosix(init.environ, "WAYLAND_DISPLAY") orelse "wayland-0";

    var app = Client{
        .connection = try wayland.Connection.connect(runtime_dir, display_name),
    };
    defer app.connection.disconnect();

    // get_registry: asks the compositor to list its globals.
    {
        app.ids.registry = app.ids.new();
        var cursor = wayland.Cursor{};
        cursor.writeU32(app.ids.registry.?);
        try app.connection.send(wayland.WL_DISPLAY, 1, cursor.slice());
    }

    // sync: forces the compositor to deliver globals before the done event.
    {
        app.ids.sync_callback = app.ids.new();
        var cursor = wayland.Cursor{};
        cursor.writeU32(app.ids.sync_callback.?);
        try app.connection.send(wayland.WL_DISPLAY, 0, cursor.slice());
    }

    try app.collectGlobals();
    try app.bindRequired();

    const seat = app.seat orelse return wayland.Error.ProtocolError;
    {
        app.keyboard = app.ids.new();
        var cursor = wayland.Cursor{};
        cursor.writeU32(app.keyboard.?);
        try app.connection.send(seat, 1, cursor.slice()); // get_keyboard
    }
    {
        app.pointer = app.ids.new();
        var cursor = wayland.Cursor{};
        cursor.writeU32(app.pointer.?);
        try app.connection.send(seat, 0, cursor.slice()); // get_pointer
    }
    std.debug.print("cipher: bound wl_compositor={d} wl_shm={d} xdg_wm_base={d}\n", .{ app.ids.compositor.?, app.ids.shm.?, app.ids.wm_base.? });

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
        try app.connection.sendFd(app.ids.shm.?, 0, cursor.slice(), shm.fd); // create_pool, fd via SCM_RIGHTS
        app.ids.shm_pool = pool_id;
    }
    {
        var cursor = wayland.Cursor{};
        cursor.writeU32(buffer_id);
        cursor.writeI32(0); // offset
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

    // Initial commit without a buffer: xdg_surface answers with configure.
    try app.connection.send(app.ids.surface.?, 6, &.{}); // commit

    try app.waitForConfigure();
    std.debug.print("cipher: xdg toplevel configured (serial {d})\n", .{app.serial});

    const pixels_u32: []u32 = @ptrCast(@alignCast(shm.pixels));
    while (app.frame_index < frame_count and !app.quit_requested) : (app.frame_index += 1) {
        render.render(pixels_u32, @as(f64, @floatFromInt(app.frame_index)) / 60.0);

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

        if (app.frame_index + 1 == frame_count) {
            try render.writePpm(pixels_u32, "/tmp/opencode/cipher_frame.ppm");
        }

        try app.waitForFrameDone();
    }

    // Teardown: destroy every client-created object we hold.
    if (app.keyboard) |id| try app.connection.send(id, 0, &.{}); // wl_keyboard.release
    if (app.pointer) |id| try app.connection.send(id, 1, &.{}); // wl_pointer.release
    if (app.seat) |id| try app.connection.send(id, 3, &.{}); // wl_seat.release
    if (app.ids.toplevel) |id| try app.connection.send(id, 0, &.{}); // xdg_toplevel.destroy
    if (app.ids.xdg_surface) |id| try app.connection.send(id, 0, &.{}); // xdg_surface.destroy
    if (app.ids.buffer) |id| try app.connection.send(id, 0, &.{}); // wl_buffer.destroy
    if (app.ids.shm_pool) |id| try app.connection.send(id, 1, &.{}); // wl_shm_pool.destroy
    if (app.ids.surface) |id| try app.connection.send(id, 0, &.{}); // wl_surface.destroy

    std.debug.print("cipher: WAYLAND_PROTOCOL_OK frames={d}\n", .{frame_count});
}
