//! Cipher app runtime: owns the Wayland connection, the window, keyboard /
//! pointer / clipboard input, and the vsync frame loop. Apps implement
//! `onInit` / `onEvent` / `onFrame` and draw with the immediate-mode `Ui`;
//! the runtime renders the UI through the GPU text pipeline into wl_shm.
//!
//! Run an app with `cipher.runtime.run(MyApp, &app)`.
const std = @import("std");
const wayland = @import("../os/linux/wayland/client.zig");
const device = @import("../gpu/vulkan/device.zig");
const text_gpu = @import("../gpu/vulkan/text.zig");
const atlas_mod = @import("../ui/text/atlas.zig");
const ui_mod = @import("../ui/ui.zig");
const input = @import("input.zig");

pub const DEFAULT_FONT = "/usr/share/fonts/liberation/LiberationSans-Regular.ttf";
pub const DEFAULT_UI_PX: f32 = 20;
pub const DEFAULT_W: u32 = 960;
pub const DEFAULT_H: u32 = 600;

pub const Options = struct {
    title: []const u8 = "cipher",
    app_id: []const u8 = "cipher",
    font_path: []const u8 = DEFAULT_FONT,
    /// Extra fonts tried (in order) when the primary misses a glyph.
    /// Their SFNT data must stay alive for the process lifetime; apps
    /// typically pass paths (the runtime reads them) rather than buffers.
    fallback_font_paths: []const []const u8 = &.{},
    /// Integer buffer scale for HiDPI (1 = normal, 2 = 200%). Can be
    /// overridden at startup with CIPHER_FORCE_SCALE=<n>. A compositor that
    /// sends wl_output.scale changes the value dynamically (best effort).
    scale: u32 = 1,
    /// Fractional density factor for HiDPI (e.g. 1.5 = render at 150% device
    /// pixels with a 1:1 mapping; the umbriel compositor reports scale 1 for
    /// such surfaces). Set via CIPHER_FORCE_SCALE_FRAC. The
    /// wp_fractional_scale/wp_viewporter session-object path was removed —
    /// umbriel kills the client connection when those objects are created.
    fractional_scale: f32 = 1.0,
    ui_px: f32 = DEFAULT_UI_PX,
    width: u32 = DEFAULT_W,
    height: u32 = DEFAULT_H,
};

fn readFileAlloc(path: []const u8, allocator: std.mem.Allocator) ![]u8 {
    const fd = try std.posix.openat(std.posix.AT.FDCWD, path, .{ .ACCMODE = .RDONLY }, 0);
    defer _ = std.c.close(fd);
    const buf = try allocator.alloc(u8, 16 * 1024 * 1024);
    var off: usize = 0;
    while (off < buf.len) {
        const n = try std.posix.read(fd, buf[off..]);
        if (n == 0) break;
        off += n;
    }
    return try allocator.realloc(buf, off);
}

/// 0xAARRGGBB -> linear-ish rgba for the GPU vertex color.
pub fn rgba01(c: u32) [4]f32 {
    return .{
        @as(f32, @floatFromInt((c >> 16) & 0xFF)) / 255.0,
        @as(f32, @floatFromInt((c >> 8) & 0xFF)) / 255.0,
        @as(f32, @floatFromInt(c & 0xFF)) / 255.0,
        @as(f32, @floatFromInt((c >> 24) & 0xFF)) / 255.0,
    };
}

/// Convert UI draw commands into GPU quads (rects sample the reserved white
/// texel (0,0); text expands to per-glyph quads from the atlas).
pub fn buildQuads(atlas: *atlas_mod.TextAtlas, cmds: []const ui_mod.DrawCmd, out_in: []text_gpu.Quad, offset: usize) !usize {
    const out = out_in[offset..];
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
            .text => |t| {
                var pen = t.x;
                const col = rgba01(t.color);
                var i: usize = 0;
                while (i < t.str.len) {
                    const d = atlas_mod.TextAtlas.decodeUtf8(t.str[i..]) orelse {
                        i += 1;
                        continue;
                    };
                    const g = atlas.glyphSafe(d.cp);
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
    return offset + n;
}

/// CPU rasterizer for one GPU-shaped quad (solid rect when the UVs are the
/// reserved (0,0)-(0,0) white texel, else an atlas-sampled glyph quad).
/// Blends source-over into the ARGB8888 (0xAARRGGBB) shm framebuffer.
/// Used only when no Vulkan device is available (CIPHER_FORCE_SOFTWARE=1
/// or headless/driverless sessions).
fn rasterQuad(px: []u32, fb_w: u32, fb_h: u32, q: text_gpu.Quad, atlas: []const u8, atlas_w: u32, atlas_h: u32) void {
    const solid = q.u0 == 0 and q.v0 == 0 and q.u1 == 0 and q.v1 == 0;
    const fw = @as(f32, @floatFromInt(fb_w));
    const fh = @as(f32, @floatFromInt(fb_h));
    const fx0 = @max(0.0, q.x);
    const fy0 = @max(0.0, q.y);
    const fx1 = @min(fw, q.x + q.w);
    const fy1 = @min(fh, q.y + q.h);
    if (fx1 <= fx0 or fy1 <= fy0) return;
    const ix0: i32 = @intFromFloat(@floor(fx0));
    const iy0: i32 = @intFromFloat(@floor(fy0));
    const ix1: i32 = @intFromFloat(@ceil(fx1));
    const iy1: i32 = @intFromFloat(@ceil(fy1));
    const cr = q.color[0];
    const cg = q.color[1];
    const cb = q.color[2];
    const ca = q.color[3];
    const afw = @as(f32, @floatFromInt(atlas_w));
    const afh = @as(f32, @floatFromInt(atlas_h));
    var py = iy0;
    while (py < iy1) : (py += 1) {
        var pxi = ix0;
        while (pxi < ix1) : (pxi += 1) {
            var cov: u32 = 255;
            if (!solid) {
                const u = (@as(f32, @floatFromInt(pxi)) + 0.5 - q.x) / q.w * (q.u1 - q.u0) + q.u0;
                const v = (@as(f32, @floatFromInt(py)) + 0.5 - q.y) / q.h * (q.v1 - q.v0) + q.v0;
                const tu: f32 = std.math.clamp(u, 0.0, @as(f32, @floatFromInt(atlas_w - 1)) / afw);
                const tv: f32 = std.math.clamp(v, 0.0, @as(f32, @floatFromInt(atlas_h - 1)) / afh);
                const tx: u32 = @intFromFloat(@floor(tu * afw));
                const ty: u32 = @intFromFloat(@floor(tv * afh));
                cov = atlas[@as(usize, ty) * @as(usize, atlas_w) + tx];
                if (cov == 0) continue;
            }
            const sa = @as(f32, @floatFromInt(cov)) / 255.0 * ca;
            if (sa <= 0) continue;
            const idx: usize = @as(usize, @intCast(py)) * @as(usize, fb_w) + @as(usize, @intCast(pxi));
            const dst = px[idx];
            const da = @as(f32, @floatFromInt((dst >> 24) & 0xFF)) / 255.0;
            const dr = @as(f32, @floatFromInt((dst >> 16) & 0xFF)) / 255.0;
            const dg = @as(f32, @floatFromInt((dst >> 8) & 0xFF)) / 255.0;
            const db = @as(f32, @floatFromInt(dst & 0xFF)) / 255.0;
            const oa = sa + da * (1 - sa);
            const orr = if (oa > 0) (cr * sa + dr * da * (1 - sa)) / oa else 0;
            const ogr = if (oa > 0) (cg * sa + dg * da * (1 - sa)) / oa else 0;
            const obl = if (oa > 0) (cb * sa + db * da * (1 - sa)) / oa else 0;
            px[idx] = (@as(u32, @intFromFloat(@round(oa * 255))) << 24) |
                (@as(u32, @intFromFloat(@round(orr * 255))) << 16) |
                (@as(u32, @intFromFloat(@round(ogr * 255))) << 8) |
                @as(u32, @intFromFloat(@round(obl * 255)));
        }
    }
}

/// Decode a text/uri-list payload into newline-separated local paths
/// (file:// prefix stripped, percent-escapes decoded).
pub fn uriListToPaths(allocator: std.mem.Allocator, data: []const u8) ![]u8 {
    var out = std.ArrayList(u8).empty;
    errdefer out.deinit(allocator);
    var lines = std.mem.splitScalar(u8, data, '\n');
    while (lines.next()) |line_raw| {
        const line = std.mem.trim(u8, line_raw, " \t\r");
        if (line.len == 0 or line[0] == '#') continue;
        const uri = if (std.mem.startsWith(u8, line, "file://")) line["file://".len..] else line;
        // percent-decode
        var i: usize = 0;
        while (i < uri.len) {
            if (uri[i] == '%' and i + 2 < uri.len) {
                const hex = uri[i + 1 .. i + 3];
                if (std.fmt.parseInt(u8, hex, 16)) |v| {
                    try out.append(allocator, v);
                    i += 3;
                    continue;
                } else |_| {}
            }
            try out.append(allocator, uri[i]);
            i += 1;
        }
        try out.append(allocator, '\n');
    }
    return out.toOwnedSlice(allocator);
}

/// The framework runtime. One per process; owns connection, window, GPU
/// pipelines, UI state, input, clipboard, and the frame loop.
pub const Runtime = struct {
    opts: Options,
    conn: wayland.Connection,
    ids: wayland.ObjectIds = .{},
    // bound globals
    g_compositor: u32 = 0,
    g_shm: u32 = 0,
    g_wm_base: u32 = 0,
    g_seat: u32 = 0,
    g_dm: u32 = 0,
    // objects
    surface: u32 = 0,
    xdg_surface: u32 = 0,
    toplevel: u32 = 0,
    shm_pool: u32 = 0,
    buffer: u32 = 0,
    keyboard: ?u32 = null,
    pointer: ?u32 = null,
    data_device: ?u32 = null,
    data_source: ?u32 = null,

    width: u32, // device pixels (logical * scale)
    height: u32,
    scale: u32 = 1, // wl_buffer scale (compositor HiDPI factor, integer)
    scale_pinned: bool = false, // CIPHER_FORCE_SCALE / Options.scale pins scale; wl_output is ignored then
    scale_f: f32 = 1.0, // effective emission scale (integer or fractional)
    fractional_scale: f32 = 1.0,
    fractional_active: bool = false,
    logical_w: u32 = 0,
    logical_h: u32 = 0,
    shm_buf: wayland.ShmBuffer,

    // GPU / UI
    vk: device.Vulkan = undefined,
    dev: device.Device = undefined,
    vk_loaded: bool = false,
    gt: ?text_gpu.GpuText = null,
    atlas: ?*atlas_mod.TextAtlas = null, // heap-boxed: Ui holds a pointer; Runtime is moved by value
    ui_state: ?ui_mod.Ui = null,
    font_data: ?[]u8 = null,
    quads_buf: []text_gpu.Quad,
    /// App-provided extra quads appended after the UI quads each frame
    /// (used by terminal renderers). present() consumes and clears it.
    extra_quads: ?[]const text_gpu.Quad = null,

    // input state
    mouse_x: f32 = 0,
    mouse_y: f32 = 0,
    mouse_down: bool = false,
    mouse_pressed: bool = false,
    mods_raw: u32 = 0,
    focused: bool = false,

    // clipboard
    selection_serial: u32 = 0,
    current_offer: ?u32 = null,
    offer_mimes: std.ArrayList([]u8),
    pending_offer: ?u32 = null,
    clipboard_text: ?[]u8 = null,

    // frame loop
    quit: bool = false,
    frame_due: bool = false,
    frame_cb: ?u32 = null,
    pending_events: std.ArrayList(input.Event),
    events_arena: std.heap.ArenaAllocator,
    app_ref: ?*const App = null,

    pub fn init(opts: Options) !Runtime {
        const runtime_dir: []const u8 = if (std.c.getenv("XDG_RUNTIME_DIR")) |p| std.mem.span(p) else "/run/user/1000";
        const display: []const u8 = if (std.c.getenv("WAYLAND_DISPLAY")) |p| std.mem.span(p) else "wayland-0";

        var self: Runtime = @import("../core/types.zig").zeroed(Runtime);
        self.opts = opts;
        // HiDPI scale: CIPHER_FORCE_SCALE beats Options.scale; integer clamp.
        var scale: u32 = opts.scale;
        var pinned = opts.scale != 1;
        if (std.c.getenv("CIPHER_FORCE_SCALE")) |p| {
            if (std.fmt.parseInt(u32, std.mem.span(p), 10)) |s| {
                if (s >= 1 and s <= 8) {
                    scale = s;
                    pinned = true;
                }
            } else |_| {}
        }
        var fractional: f32 = opts.fractional_scale;
        if (std.c.getenv("CIPHER_FORCE_SCALE_FRAC")) |p| {
            if (std.fmt.parseFloat(f32, std.mem.span(p))) |f| {
                if (f >= 1.0 and f <= 4.0) fractional = f;
            } else |_| {}
        }
        self.fractional_scale = fractional;
        self.fractional_active = fractional != 1.0;
        self.scale = scale;
        self.scale_pinned = pinned;
        self.scale_f = if (self.fractional_active) fractional else @as(f32, @floatFromInt(scale));
        self.logical_w = opts.width;
        self.logical_h = opts.height;
        const dev_w: u32 = @intFromFloat(@ceil(@as(f32, @floatFromInt(opts.width)) * self.scale_f));
        const dev_h: u32 = @intFromFloat(@ceil(@as(f32, @floatFromInt(opts.height)) * self.scale_f));
        std.debug.print("cipher: scale={d} fractional={} (opts {d}x{d} -> {d}x{d} device px)\n", .{ self.scale_f, self.fractional_active, opts.width, opts.height, dev_w, dev_h });
        self.conn = try wayland.Connection.connect(runtime_dir, display);
        self.ids = .{};
        self.width = dev_w;
        self.height = dev_h;
        self.shm_buf = try wayland.ShmBuffer.allocate(self.width, self.height);
        self.offer_mimes = .empty;
        self.pending_events = .empty;
        self.events_arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
        self.quads_buf = try std.heap.page_allocator.alloc(text_gpu.Quad, 65536);
        self.extra_quads = null;

        // Registry roundtrip to collect globals.
        var ids = &self.ids;
        ids.registry = ids.new();
        var cursor = wayland.Cursor{};
        cursor.writeU32(ids.registry.?);
        try self.conn.send(wayland.WL_DISPLAY, 1, cursor.slice());
        ids.sync_callback = ids.new();
        cursor = wayland.Cursor{};
        cursor.writeU32(ids.sync_callback.?);
        try self.conn.send(wayland.WL_DISPLAY, 0, cursor.slice());

        var compositor_g: ?u32 = null;
        var shm_g: ?u32 = null;
        var wm_base_g: ?u32 = null;
        var seat_g: ?u32 = null;
        var dm_g: ?u32 = null;
        var output_g: ?u32 = null;
        var output_v: u32 = 1;
        while (true) {
            var event = wayland.Event{};
            try self.conn.recv(&event);
            if (ids.registry != null and event.sender == ids.registry.? and event.opcode == 0) {
                var pos: usize = 0;
                const name = event.read32(0);
                pos = 4;
                const iface_len = event.read32(1);
                pos += 4;
                const iface = event.payload()[pos..][0 .. iface_len - 1];
                pos += iface_len;
                while (pos % 4 != 0) pos += 1;
                if (std.mem.eql(u8, iface, "wl_compositor")) compositor_g = name;
                if (std.mem.eql(u8, iface, "wl_shm")) shm_g = name;
                if (std.mem.eql(u8, iface, "xdg_wm_base")) wm_base_g = name;
                if (std.mem.eql(u8, iface, "wl_seat")) seat_g = name;
                if (std.mem.eql(u8, iface, "wl_data_device_manager")) dm_g = name;
                if (std.mem.eql(u8, iface, "wl_output")) {
                    output_g = name;
                    output_v = std.mem.readInt(u32, event.payload()[pos..][0..4], .little);
                }
                if (std.c.getenv("CIPHER_DEBUG_GLOBALS") != null) {
                    const ver = std.mem.readInt(u32, event.payload()[pos..][0..4], .little);
                    std.debug.print("cipher: global {s} v{d} name={d}\n", .{ iface, ver, name });
                }
            }
            if (ids.sync_callback != null and event.sender == ids.sync_callback.? and event.opcode == 0) break;
        }
        self.g_compositor = compositor_g orelse return error.NoCompositor;
        self.g_shm = shm_g orelse return error.NoShm;
        self.g_wm_base = wm_base_g orelse return error.NoWmBase;
        self.g_seat = seat_g orelse return error.NoSeat;
        self.g_dm = dm_g orelse return error.NoDataDeviceManager;

        // Bind globals.
        if (output_g) |og| {
            const oid = ids.new();
            self.ids.output = oid;
            cursor = wayland.Cursor{};
            cursor.writeU32(og);
            cursor.str("wl_output");
            cursor.writeU32(@min(output_v, 4));
            cursor.writeU32(oid);
            try self.conn.send(ids.registry.?, 0, cursor.slice());
        }
        const debug_globals = std.c.getenv("CIPHER_DEBUG_GLOBALS") != null;
        inline for (.{ .{ "wl_compositor", 4, &self.g_compositor, &self.ids.compositor }, .{ "wl_shm", 1, &self.g_shm, &self.ids.shm }, .{ "xdg_wm_base", 6, &self.g_wm_base, &self.ids.wm_base }, .{ "wl_seat", 5, &self.g_seat, &self.ids.seat } }) |b| {
            const object_id = ids.new();
            if (debug_globals) std.debug.print("cipher: bind {s} -> id {d}\n", .{ b[0], object_id });
            cursor = wayland.Cursor{};
            cursor.writeU32(b[2].*);
            cursor.str(b[0]);
            cursor.writeU32(b[1]);
            cursor.writeU32(object_id);
            try self.conn.send(ids.registry.?, 0, cursor.slice());
            b[3].* = object_id;
        }
        {
            const object_id = ids.new();
            cursor = wayland.Cursor{};
            cursor.writeU32(self.g_dm);
            cursor.str("wl_data_device_manager");
            cursor.writeU32(3);
            cursor.writeU32(object_id);
            try self.conn.send(ids.registry.?, 0, cursor.slice());
            self.g_dm = self.g_dm; // bound object id tracked below
            self.ids.linux_dmabuf = object_id; // reuse field as dm object id
        }

        // Surface + xdg shell.
        self.surface = ids.new();
        cursor = wayland.Cursor{};
        cursor.writeU32(self.surface);
        try self.conn.send(self.ids.compositor.?, 0, cursor.slice());
        self.xdg_surface = ids.new();
        cursor = wayland.Cursor{};
        cursor.writeU32(self.xdg_surface);
        cursor.writeU32(self.surface);
        try self.conn.send(self.ids.wm_base.?, 2, cursor.slice());
        self.toplevel = ids.new();
        cursor = wayland.Cursor{};
        cursor.writeU32(self.toplevel);
        cursor.writeU32(self.xdg_surface);
        try self.conn.send(self.xdg_surface, 1, cursor.slice());
        cursor = wayland.Cursor{};
        cursor.str(opts.title);
        try self.conn.send(self.toplevel, 2, cursor.slice());
        cursor = wayland.Cursor{};
        cursor.str(opts.app_id);
        try self.conn.send(self.toplevel, 3, cursor.slice());
        if (self.scale > 1) {
            cursor = wayland.Cursor{};
            cursor.writeI32(@intCast(self.scale));
            try self.conn.send(self.surface, 8, cursor.slice()); // wl_surface.set_buffer_scale
        }
        try self.conn.send(self.surface, 6, &.{}); // initial commit

        // Blocking wait for the first configure (socket still blocking).
        var configured = false;
        const debug_init_events = std.c.getenv("CIPHER_DEBUG_GLOBALS") != null;
        while (!configured) {
            var event = wayland.Event{};
            try self.conn.recv(&event);
            if (debug_init_events) std.debug.print("cipher: event sender={d} opcode={d} len={d}\n", .{ event.sender, event.opcode, event.payload().len });
            if (event.sender == self.xdg_surface and event.opcode == 0) {
                const serial = event.read32(0);
                cursor = wayland.Cursor{};
                cursor.writeU32(serial);
                try self.conn.send(self.xdg_surface, 4, cursor.slice());
                configured = true;
            }
            try self.dispatchInitEvent(&event);
        }

        // Shm pool + buffer at initial size.
        try self.makeShmObjects();

        // GPU + font + UI (all optional; software fallback presents clear color).
        const force_sw = std.c.getenv("CIPHER_FORCE_SOFTWARE") != null;
        // Load font + atlas unconditionally; software rendering works without Vulkan.
        if (readFileAlloc(opts.font_path, std.heap.page_allocator)) |font_data| {
            self.font_data = font_data;
            if (atlas_mod.TextAtlas.init(std.heap.page_allocator, font_data, opts.ui_px * self.scale_f)) |a| {
                const boxed = try std.heap.page_allocator.create(atlas_mod.TextAtlas);
                boxed.* = a;
                self.atlas = boxed;
                for (opts.fallback_font_paths) |fb_path| {
                    const fb_data = readFileAlloc(fb_path, std.heap.page_allocator) catch continue;
                    self.atlas.?.addFallback(fb_data) catch continue;
                }
                self.atlas.?.bake(32, 126) catch {};
                self.atlas.?.bake(160, 255) catch {};
                // UI state is created now regardless of GPU path so the
                // software-shm fallback can render the UI on CPU.
                self.ui_state = ui_mod.Ui.init(std.heap.page_allocator, self.atlas.?);
                // Optional GPU path
                if (!force_sw) if (device.load()) |v| {
                    self.vk = v;
                    if (device.createDevice(&self.vk, &self.dev)) {
                        self.vk_loaded = true;
                        if (text_gpu.GpuText.init(&self.vk, &self.dev, self.width, self.height, self.atlas.?.atlas_w, self.atlas.?.atlas_h)) |g| {
                            self.gt = g;
                            self.gt.?.uploadAtlas(&self.vk, &self.dev, self.atlas.?.atlas) catch {
                                std.debug.print("cipher: gpu block failed at uploadAtlas\n", .{});
                                self.gt = null;
                            };
                        } else |e| std.debug.print("cipher: gpu block failed at GpuText.init: {s}\n", .{@errorName(e)});
                    } else |e| std.debug.print("cipher: gpu block failed at createDevice: {s}\n", .{@errorName(e)});
                } else |e| std.debug.print("cipher: gpu block failed at load: {s}\n", .{@errorName(e)});
                // CIPHER_DUMP_ATLAS debug output
                if (std.c.getenv("CIPHER_DUMP_ATLAS")) |p| {
                    const fd = std.posix.openat(std.posix.AT.FDCWD, std.mem.span(p), .{ .ACCMODE = .WRONLY, .CREAT = true, .TRUNC = true }, 0o644) catch null;
                    if (fd) |f| {
                        defer _ = std.c.close(f);
                        var hdr_buf: [64]u8 = undefined;
                        const hdr = std.fmt.bufPrint(&hdr_buf, "P6\n{d} {d}\n255\n", .{ self.atlas.?.atlas_w, self.atlas.?.atlas_h }) catch unreachable;
                        _ = std.os.linux.write(f, hdr.ptr, hdr.len);
                        var buf3 = try std.heap.page_allocator.alloc(u8, self.atlas.?.atlas.len * 3);
                        defer std.heap.page_allocator.free(buf3);
                        for (self.atlas.?.atlas, 0..) |px, i| {
                            buf3[i * 3] = px;
                            buf3[i * 3 + 1] = px;
                            buf3[i * 3 + 2] = px;
                        }
                        _ = std.os.linux.write(f, buf3.ptr, buf3.len);
                    }
                }
            } else |_| {}
        } else |_| {}
        std.debug.print("cipher: render path = {s}\n", .{if (self.gt != null) "vulkan-gpu-ui" else "software-shm"});

        self.conn.setNonBlocking();
        return self;
    }

    /// Handle the few events that can arrive during the initial blocking wait.
    fn dispatchInitEvent(self: *Runtime, event: *wayland.Event) !void {
        if (event.sender == wayland.WL_DISPLAY and event.opcode == 0) {
            const obj = event.read32(0);
            const code = event.read32(1);
            const msglen: usize = @intCast(event.read32(2));
            const start: usize = 12;
            const msg = if (msglen > 0 and start + msglen - 1 <= event.payload().len) event.payload()[start .. start + msglen - 1] else "?";
            std.debug.print("cipher: WAYLAND_ERROR object={d} code={d} msg={s}\n", .{ obj, code, msg });
            return error.ProtocolError;
        }
        if (self.ids.output != null and event.sender == self.ids.output.? and event.opcode == 3) {
            const ns = event.readI32(0);
            if (ns >= 1) self.applyScale(@intCast(ns)) catch {};
            return;
        }
        if (self.ids.seat != null and event.sender == self.ids.seat.? and event.opcode == 0) {
            try self.onSeatCapabilities(event.read32(0));
        }
        if (self.keyboard != null and event.sender == self.keyboard.? and event.opcode == 0) {
            if (event.fd) |fd| _ = std.c.close(fd); // keymap: we assume evdev/us layout
        }
    }

    fn onSeatCapabilities(self: *Runtime, caps: u32) !void {
        var cursor = wayland.Cursor{};
        if (caps & 2 != 0 and self.keyboard == null) {
            const kbd = self.ids.new();
            cursor = wayland.Cursor{};
            cursor.writeU32(kbd);
            try self.conn.send(self.ids.seat.?, 1, cursor.slice());
            self.keyboard = kbd;
        }
        if (caps & 1 != 0 and self.pointer == null) {
            const ptr = self.ids.new();
            cursor = wayland.Cursor{};
            cursor.writeU32(ptr);
            try self.conn.send(self.ids.seat.?, 0, cursor.slice());
            self.pointer = ptr;
        }
        if (self.data_device == null) {
            const dd = self.ids.new();
            cursor = wayland.Cursor{};
            cursor.writeU32(dd);
            cursor.writeU32(self.ids.seat.?);
            try self.conn.send(self.ids.linux_dmabuf.?, 0, cursor.slice()); // dm object id stored there
            self.data_device = dd;
        }
    }

    /// Change the HiDPI buffer scale at runtime (wl_output.scale). Reallocates
    /// the shm buffer and GPU target at device resolution; layout, mouse
    /// coordinates and damage are scaled accordingly from then on.
    fn applyScale(self: *Runtime, ns: u32) !void {
        if (ns < 1 or ns > 8) return;
        if (self.scale_pinned) {
            std.debug.print("cipher: wl_output.scale={d} ignored (pinned to {d}; unset CIPHER_FORCE_SCALE to follow the compositor)\n", .{ ns, self.scale });
            return;
        }
        if (ns == self.scale) return;
        const lw = self.width / self.scale;
        const lh = self.height / self.scale;
        self.scale = ns;
        if (self.surface != 0) {
            var cursor = wayland.Cursor{};
            cursor.writeI32(@intCast(ns));
            try self.conn.send(self.surface, 8, cursor.slice()); // wl_surface.set_buffer_scale
        }
        if (self.logical_w != 0) try self.resize(self.logical_w, self.logical_h);
        std.debug.print("cipher: wl_output.scale -> {d} ({d}x{d} device px)\n", .{ ns, lw * ns, lh * ns });
    }

    fn makeShmObjects(self: *Runtime) !void {
        var cursor = wayland.Cursor{};
        self.shm_pool = self.ids.new();
        cursor = wayland.Cursor{};
        cursor.writeU32(self.shm_pool);
        cursor.writeI32(@intCast(self.shm_buf.pixels.len));
        try self.conn.sendFd(self.ids.shm.?, 0, cursor.slice(), self.shm_buf.fd);
        self.buffer = self.ids.new();
        cursor = wayland.Cursor{};
        cursor.writeU32(self.buffer);
        cursor.writeI32(0);
        cursor.writeI32(@intCast(self.width));
        cursor.writeI32(@intCast(self.height));
        cursor.writeI32(@intCast(self.shm_buf.stride));
        cursor.writeU32(0); // WL_SHM_FORMAT_ARGB8888
        try self.conn.send(self.shm_pool, 0, cursor.slice());
    }

    pub fn deinit(self: *Runtime) void {
        if (self.keyboard) |id| {
            _ = self.conn.send(id, 0, &.{}) catch {};
        }
        if (self.pointer) |id| _ = self.conn.send(id, 1, &.{}) catch {};
        if (self.data_device) |id| _ = self.conn.send(id, 2, &.{}) catch {};
        if (self.data_source) |id| _ = self.conn.send(id, 1, &.{}) catch {};
        if (self.toplevel != 0) _ = self.conn.send(self.toplevel, 0, &.{}) catch {};
        if (self.xdg_surface != 0) _ = self.conn.send(self.xdg_surface, 0, &.{}) catch {};
        if (self.buffer != 0) _ = self.conn.send(self.buffer, 0, &.{}) catch {};
        if (self.shm_pool != 0) _ = self.conn.send(self.shm_pool, 1, &.{}) catch {};
        if (self.surface != 0) _ = self.conn.send(self.surface, 0, &.{}) catch {};
        if (self.ui_state) |*u| u.deinit();
        if (self.gt) |*g| g.deinitSoft(&self.vk, &self.dev);
        if (self.atlas) |a| {
            a.deinit();
            std.heap.page_allocator.destroy(a);
        }
        self.shm_buf.deinit();
        for (self.offer_mimes.items) |m| std.heap.page_allocator.free(m);
        self.offer_mimes.deinit(std.heap.page_allocator);
        self.pending_events.deinit(std.heap.page_allocator);
        self.events_arena.deinit();
        std.heap.page_allocator.free(self.quads_buf);
        self.conn.disconnect();
    }

    /// Recreate shm buffer + GPU target at a new size.
    fn resize(self: *Runtime, logical_w: u32, logical_h: u32) !void {
        const eff: f32 = if (self.fractional_active) self.fractional_scale else @as(f32, @floatFromInt(self.scale));
        self.scale_f = eff;
        const w: u32 = @intFromFloat(@ceil(@as(f32, @floatFromInt(logical_w)) * eff));
        const h: u32 = @intFromFloat(@ceil(@as(f32, @floatFromInt(logical_h)) * eff));
        self.logical_w = logical_w;
        self.logical_h = logical_h;
        if (w == self.width and h == self.height) return;
        // destroy old buffer/pool objects
        if (self.buffer != 0) {
            _ = self.conn.send(self.buffer, 0, &.{}) catch {};
            self.buffer = 0;
        }
        if (self.shm_pool != 0) {
            _ = self.conn.send(self.shm_pool, 1, &.{}) catch {};
            self.shm_pool = 0;
        }
        self.shm_buf.deinit();
        self.width = w;
        self.height = h;
        self.shm_buf = try wayland.ShmBuffer.allocate(w, h);
        try self.makeShmObjects();
        // negotiate buffer<->surface mapping: integer buffer_scale when
        // scale > 1; fractional density scales render at device density
        // without an integer mapping (wl_output.scale reports scale 1 for
        // fractional modes, so surface pixels are delivered 1:1).
        var cursor = wayland.Cursor{};
        if (self.scale > 1) {
            cursor.writeI32(@intCast(self.scale));
            _ = self.conn.send(self.surface, 8, cursor.slice()) catch {};
        }
        if (self.gt) |*g| {
            g.deinitSoft(&self.vk, &self.dev);
            self.gt = null;
        }
        // Only re-create the GPU text pipeline when a Vulkan device exists;
        // in software mode self.vk/self.dev are never initialized.
        if (self.vk_loaded) {
            if (self.atlas) |a| {
                if (text_gpu.GpuText.init(&self.vk, &self.dev, w, h, a.atlas_w, a.atlas_h)) |g| {
                    self.gt = g;
                    self.gt.?.uploadAtlas(&self.vk, &self.dev, a.atlas) catch {};
                } else |_| {}
            }
        }
    }

    /// The immediate-mode UI for this frame (created when font+atlas load;
    /// works in both GPU and software-shm modes).
    pub fn ui(self: *Runtime) ?*ui_mod.Ui {
        return if (self.ui_state) |*u| u else null;
    }

    pub fn requestQuit(self: *Runtime) void {
        self.quit = true;
    }

    /// Set the system clipboard to UTF-8 text (used for copy/paste).
    pub fn setClipboard(self: *Runtime, text: []const u8) !void {
        const dd = self.data_device orelse return error.NoDataDevice;
        const src = self.ids.new();
        var cursor = wayland.Cursor{};
        cursor.writeU32(src);
        try self.conn.send(self.ids.linux_dmabuf.?, 0, cursor.slice()); // create_data_source
        cursor = wayland.Cursor{};
        cursor.str("text/plain;charset=utf-8");
        try self.conn.send(src, 0, cursor.slice()); // offer
        if (self.clipboard_text) |old| std.heap.page_allocator.free(old);
        self.clipboard_text = try std.heap.page_allocator.dupe(u8, text);
        self.data_source = src;
        cursor = wayland.Cursor{};
        cursor.writeU32(self.selection_serial);
        cursor.writeU32(src);
        try self.conn.send(dd, 1, cursor.slice()); // set_selection
    }

    // ---- event dispatch ----

    fn dispatch(self: *Runtime, app: *const App, event: *wayland.Event) !void {
        // wl_display
        if (event.sender == wayland.WL_DISPLAY) {
            if (event.opcode == 0) {
                const code = event.read32(1);
                const msg_len = event.read32(2);
                const msg = event.payload()[12..][0 .. msg_len - 1];
                std.debug.print("cipher: wayland error {d}: {s}\n", .{ code, msg });
                return error.ProtocolError;
            }
            return; // delete_id
        }
        if (self.ids.registry != null and event.sender == self.ids.registry.?) return;
        if (self.ids.shm != null and event.sender == self.ids.shm.?) return; // format
        if (self.ids.seat != null and event.sender == self.ids.seat.? and event.opcode == 0) {
            try self.onSeatCapabilities(event.read32(0));
            return;
        }
        if (self.keyboard != null and event.sender == self.keyboard.?) {
            switch (event.opcode) {
                0 => {
                    if (event.fd) |fd| _ = std.c.close(fd);
                },
                1 => {
                    self.focused = true;
                    app.onEvent(app.ptr, self, .{ .focus = true });
                },
                2 => {
                    self.focused = false;
                    app.onEvent(app.ptr, self, .{ .focus = false });
                },
                3 => { // key
                    const key = event.read32(2);
                    const state = event.read32(3);
                    const shift = self.mods_raw & 0x1 != 0;
                    const caps = self.mods_raw & 0x2 != 0;
                    const m = input.mapKey(key, shift, caps);
                    const ev = input.Event{ .key = .{
                        .code = key,
                        .key = m.key,
                        .char = m.char,
                        .mods = .{ .raw = self.mods_raw },
                        .pressed = state == 1,
                    } };
                    try self.enqueue(ev);
                    app.onEvent(app.ptr, self, ev);
                },
                4 => { // modifiers
                    const depressed = event.read32(1);
                    const latched = event.read32(2);
                    const locked = event.read32(3);
                    self.mods_raw = depressed | latched | locked;
                },
                else => {},
            }
            return;
        }
        if (self.pointer != null and event.sender == self.pointer.?) {
            switch (event.opcode) {
                2 => { // motion (logical coords; layout runs in logical px)
                    self.mouse_x = @floatCast(event.fixed24_8(1));
                    self.mouse_y = @floatCast(event.fixed24_8(2));
                    const ev = input.Event{ .mouse_move = .{ .x = self.mouse_x, .y = self.mouse_y } };
                    try self.enqueue(ev);
                    app.onEvent(app.ptr, self, ev);
                },
                3 => { // button
                    const button = event.read32(2);
                    const state = event.read32(3);
                    if (button == 0x110) {
                        self.mouse_down = state == 1;
                        if (state == 1) self.mouse_pressed = true;
                    }
                    const ev = input.Event{ .mouse_button = .{ .button = button, .pressed = state == 1 } };
                    try self.enqueue(ev);
                    app.onEvent(app.ptr, self, ev);
                },
                4 => { // axis
                    const axis = event.read32(1);
                    const value = event.fixed24_8(2);
                    if (axis == 0) {
                        const dy: f32 = @floatCast(value / 10.0); // one wheel notch ~ 10 units
                        const ev = input.Event{ .wheel = .{ .dx = 0, .dy = dy } };
                        try self.enqueue(ev);
                        app.onEvent(app.ptr, self, ev);
                    } else {
                        const ev = input.Event{ .wheel = .{ .dx = @floatCast(value / 10.0), .dy = 0 } };
                        try self.enqueue(ev);
                        app.onEvent(app.ptr, self, ev);
                    }
                },
                else => {},
            }
            return;
        }
        if (self.data_device != null and event.sender == self.data_device.?) {
            switch (event.opcode) {
                0 => { // data_offer: new id in payload[0]
                    self.pending_offer = event.read32(0);
                    self.clearOfferMimes();
                },
                4 => { // drop: receive the offered uri-list/text now
                    try self.receiveCurrentOffer();
                },
                5 => { // selection
                    self.selection_serial = event.read32(0);
                    const offer = event.read32(1);
                    if (offer != 0) {
                        self.current_offer = offer;
                        try self.receiveCurrentOffer();
                    }
                },
                else => {},
            }
            return;
        }
        if (self.pending_offer != null and event.sender == self.pending_offer.?) {
            if (event.opcode == 0) { // offer mime
                const len = event.read32(0);
                const mime = event.payload()[4..][0 .. len - 1];
                try self.offer_mimes.append(std.heap.page_allocator, try std.heap.page_allocator.dupe(u8, mime));
            }
            return;
        }
        if (self.current_offer != null and event.sender == self.current_offer.?) {
            if (event.opcode == 0) {
                const len = event.read32(0);
                const mime = event.payload()[4..][0 .. len - 1];
                try self.offer_mimes.append(std.heap.page_allocator, try std.heap.page_allocator.dupe(u8, mime));
            }
            return;
        }
        if (self.data_source != null and event.sender == self.data_source.?) {
            if (event.opcode == 1) { // send: mime + fd -> write clipboard text
                if (event.fd) |fd| {
                    if (self.clipboard_text) |t| {
                        _ = std.c.write(fd, t.ptr, t.len);
                    }
                    _ = std.c.close(fd);
                }
            }
            return;
        }
        if (self.ids.output != null and event.sender == self.ids.output.? and event.opcode == 3) {
            const ns = event.readI32(0);
            if (ns >= 1) self.applyScale(@intCast(ns)) catch |e| {
                std.debug.print("cipher: applyScale({d}) failed: {s}\n", .{ ns, @errorName(e) });
            };
            return;
        }
        if (event.sender == self.xdg_surface) {
            if (event.opcode == 0) { // configure
                const serial = event.read32(0);
                var cursor = wayland.Cursor{};
                cursor.writeU32(serial);
                try self.conn.send(self.xdg_surface, 4, cursor.slice());
            }
            return;
        }
        if (event.sender == self.toplevel) {
            switch (event.opcode) {
                0 => { // configure w,h,states (logical); buffer is scaled
                    const w = event.readI32(0);
                    const h = event.readI32(1);
                    if (w > 0 and h > 0) {
                        const lw: u32 = @intCast(w);
                        const lh: u32 = @intCast(h);
                        if (lw == self.logical_w and lh == self.logical_h) return;
                        self.resize(lw, lh) catch |e| {
                            std.debug.print("cipher: resize failed: {s}\n", .{@errorName(e)});
                        };
                        const ev = input.Event{ .resize = .{ .w = self.width, .h = self.height } };
                        try self.enqueue(ev);
                        app.onEvent(app.ptr, self, ev);
                    }
                },
                1 => { // close
                    const ev = input.Event.close;
                    app.onEvent(app.ptr, self, ev);
                },
                else => {},
            }
            return;
        }
        if (self.ids.wm_base != null and event.sender == self.ids.wm_base.? and event.opcode == 0) {
            const serial = event.read32(0);
            var cursor = wayland.Cursor{};
            cursor.writeU32(serial);
            try self.conn.send(self.ids.wm_base.?, 1, cursor.slice()); // pong
            return;
        }
        if (self.frame_cb != null and event.sender == self.frame_cb.?) {
            if (event.opcode == 0) self.frame_due = true;
            return;
        }
        // wl_buffer.release etc: ignore
    }

    fn clearOfferMimes(self: *Runtime) void {
        for (self.offer_mimes.items) |m| std.heap.page_allocator.free(m);
        self.offer_mimes.clearRetainingCapacity();
    }

    fn offerHasMime(self: *Runtime, needle: []const u8) bool {
        for (self.offer_mimes.items) |m| {
            if (std.mem.indexOf(u8, m, needle) != null) return true;
        }
        return false;
    }

    fn receiveCurrentOffer(self: *Runtime) !void {
        const offer = self.current_offer orelse return;
        const app_ptr_dummy: ?*const App = null;
        _ = app_ptr_dummy;
        const mime: []const u8 = if (self.offerHasMime("text/uri-list"))
            "text/uri-list"
        else if (self.offerHasMime("text/plain"))
            "text/plain;charset=utf-8"
        else
            return;
        // pipe: compositor writes into our write end
        var fds: [2]i32 = undefined;
        const prc = std.os.linux.pipe2(&fds, .{ .CLOEXEC = true });
        if (@as(i64, @bitCast(prc)) < 0) return error.PipeFailed;
        var cursor = wayland.Cursor{};
        cursor.str(mime);
        try self.conn.sendFd(offer, 0, cursor.slice(), fds[1]); // receive
        _ = std.c.close(fds[1]);
        var data = std.ArrayList(u8).empty;
        defer data.deinit(std.heap.page_allocator);
        var chunk: [4096]u8 = undefined;
        while (true) {
            const n = std.posix.read(fds[0], &chunk) catch break;
            if (n == 0) break;
            try data.appendSlice(std.heap.page_allocator, chunk[0..n]);
        }
        _ = std.c.close(fds[0]);
        if (data.items.len == 0) return;
        const is_uri = std.mem.indexOf(u8, mime, "uri-list") != null;
        const text = if (is_uri)
            try uriListToPaths(std.heap.page_allocator, data.items)
        else
            try std.heap.page_allocator.dupe(u8, data.items);
        const ev = input.Event{ .paste = text };
        try self.enqueue(ev);
        if (self.app_ref) |app| app.onEvent(app.ptr, self, ev);
    }

    fn enqueue(self: *Runtime, ev: input.Event) !void {
        // Strings in paste events must outlive the frame: copy into the arena.
        if (ev == .paste) {
            const copy = try self.events_arena.allocator().dupe(u8, ev.paste);
            try self.pending_events.append(std.heap.page_allocator, .{ .paste = copy });
        } else {
            try self.pending_events.append(std.heap.page_allocator, ev);
        }
    }

    // ---- frame loop ----

    fn pump(self: *Runtime, app: *const App, timeout_ms: i32) !void {
        var fds = [_]std.os.linux.pollfd{.{ .fd = self.conn.fd, .events = std.os.linux.POLL.IN, .revents = 0 }};
        const rc = std.os.linux.poll(&fds, 1, timeout_ms);
        if (@as(i64, @bitCast(rc)) < 0) {
            if (std.os.linux.errno(rc) == .INTR) return;
            return error.PollFailed;
        }
        if (rc == 0) return; // timeout
        // Drain everything available.
        while (true) {
            var event = wayland.Event{};
            self.conn.recv(&event) catch |e| switch (e) {
                error.WouldBlock => break,
                else => return e,
            };
            try self.dispatch(app, &event);
            if (self.quit) break;
        }
    }

    fn present(self: *Runtime, app: *const App) !void {
        if (self.ui_state != null) {
            var u = &self.ui_state.?;
            u.events = self.pending_events.items; // before begin(): begin() reads events for focus semantics
                        u.begin(@floatFromInt(self.logical_w), @floatFromInt(self.logical_h), self.mouse_x, self.mouse_y, self.mouse_down, self.mouse_pressed, self.scale_f) catch |e| {
                if (std.c.getenv("CIPHER_DEBUG_QUADS") != null) std.debug.print("cipher: ui.begin error: {s}\n", .{@errorName(e)});
                self.ui_state = null;
            };
            if (self.ui_state != null) {
                // Re-upload the atlas if a glyph was rasterized since the last upload
                if (self.atlas) |a| {
                    if (a.dirty) {
                        if (self.gt) |*g| {
                            g.uploadAtlas(&self.vk, &self.dev, a.atlas) catch {};
                        }
                        a.dirty = false;
                    }
                }
                app.onFrame(app.ptr, self) catch |e| {
                    if (std.c.getenv("CIPHER_DEBUG_QUADS") != null) std.debug.print("cipher: onFrame error: {s}\n", .{@errorName(e)});
                    self.ui_state = null;
                };
                if (self.ui_state != null) {
                    u.end() catch |e| {
                        if (std.c.getenv("CIPHER_DEBUG_QUADS") != null) std.debug.print("cipher: ui.end error: {s}\n", .{@errorName(e)});
                        self.ui_state = null;
                    };
                }
                if (self.ui_state != null) {
                    // background content first (terminal grid, app-drawn bg),
                    // UI widgets on top of it.
                    var n: usize = 0;
                    var eq_len: usize = 0;
                    if (self.extra_quads) |eq| {
                        const take = @min(eq.len, self.quads_buf.len);
                        if (take > 0) @memcpy(self.quads_buf[0..take], eq[0..take]);
                        eq_len = take;
                        n = eq_len;
                    }
                    self.extra_quads = null; // one frame only
                    n = buildQuads(self.atlas.?, u.drawCmds(), self.quads_buf, eq_len) catch |e| blk: {
                        if (std.c.getenv("CIPHER_DEBUG_QUADS") != null) std.debug.print("cipher: buildQuads error: {s}\n", .{@errorName(e)});
                        break :blk eq_len;
                    };
                    if (std.c.getenv("CIPHER_DEBUG_QUADS") != null) std.debug.print("cipher: quads n={d} extra={d} cmds={d} gt={}\n", .{ n, eq_len, u.drawCmds().len, self.gt != null });
                    if (self.gt) |*g| {
                        try g.render(&self.vk, &self.dev, self.quads_buf[0..n]);
                        const src = g.pixels();
                        @memcpy(self.shm_buf.pixels[0..src.len], src);
                    } else {
                        // Software-shm: clear to void, rasterize the same
                        // quad list on the CPU (solid rects + atlas glyphs).
                        const px: []u32 = @ptrCast(@alignCast(self.shm_buf.pixels));
                        for (px[0 .. self.width * self.height]) |*p| p.* = 0xFF04060B;
                        for (self.quads_buf[0..n]) |q| rasterQuad(px, self.width, self.height, q, self.atlas.?.atlas, self.atlas.?.atlas_w, self.atlas.?.atlas_h);
                    }
                }
            }
            self.mouse_pressed = false;
        } else {
            // Software fallback: clear to void, but still run the app's frame
            // logic so socket pumps/timers/benchmarks keep working and the
            // compositor keeps receiving vsync-synced commits.
            const px: []u32 = @ptrCast(@alignCast(self.shm_buf.pixels));
            for (px[0 .. self.width * self.height]) |*p| p.* = 0xFF04060B;
            app.onFrame(app.ptr, self) catch {};
            self.mouse_pressed = false;
        }
        self.pending_events.clearRetainingCapacity();
        _ = self.events_arena.reset(.free_all);

        // attach + damage + commit
        var cursor = wayland.Cursor{};
        cursor.writeU32(self.buffer);
        cursor.writeI32(0);
        cursor.writeI32(0);
        try self.conn.send(self.surface, 1, cursor.slice());
        cursor = wayland.Cursor{};
        cursor.writeI32(0);
        cursor.writeI32(0);
        cursor.writeI32(@intCast(self.logical_w));
        cursor.writeI32(@intCast(self.logical_h));
        try self.conn.send(self.surface, 2, cursor.slice());
        try self.conn.send(self.surface, 6, &.{});

        // request next vsync frame callback
        self.frame_cb = self.ids.new();
        cursor = wayland.Cursor{};
        cursor.writeU32(self.frame_cb.?);
        try self.conn.send(self.surface, 3, cursor.slice());
        try self.conn.send(self.surface, 6, &.{});
    }

    fn dumpFrame(self: *Runtime, n: u32) void {
        const path = std.c.getenv("CIPHER_DUMP_FRAME") orelse return;
        const p = std.mem.span(path);
        const fd = std.posix.openat(std.posix.AT.FDCWD, p, .{ .ACCMODE = .WRONLY, .CREAT = true, .TRUNC = true }, 0o644) catch return;
        defer _ = std.c.close(fd);
        var hdr: [128]u8 = undefined;
        const h = std.fmt.bufPrint(&hdr, "P6\n{d} {d}\n255\n", .{ self.width, self.height }) catch return;
        _ = std.os.linux.write(fd, h.ptr, h.len);
        // shm pixels are BGRA (ARGB8888 little-endian); emit RGB
        const stride = self.shm_buf.stride;
        var row_buf = std.heap.page_allocator.alloc(u8, self.width * 3) catch return;
        defer std.heap.page_allocator.free(row_buf);
        var y: u32 = 0;
        while (y < self.height) : (y += 1) {
            const src = self.shm_buf.pixels[y * stride ..][0 .. self.width * 4];
            var x: u32 = 0;
            while (x < self.width) : (x += 1) {
                row_buf[x * 3 + 0] = src[x * 4 + 2]; // R
                row_buf[x * 3 + 1] = src[x * 4 + 1]; // G
                row_buf[x * 3 + 2] = src[x * 4 + 0]; // B
            }
            _ = std.os.linux.write(fd, row_buf.ptr, row_buf.len);
        }
        std.debug.print("CIPHER_FRAME_DUMP frame={d} path={s} size={d}x{d}\n", .{ n, p, self.width, self.height });
    }

    fn runLoop(self: *Runtime, app: *const App) !void {
        var frames: u32 = 0;
        // Optional test cap: CIPHER_MAX_FRAMES=N quits cleanly after N frames.
        var max_frames: ?u32 = null;
        if (std.c.getenv("CIPHER_MAX_FRAMES")) |p| {
            if (std.fmt.parseInt(u32, std.mem.span(p), 10)) |n| max_frames = n else |_| {}
        }
        try self.present(app); // first frame immediately
        self.dumpFrame(0);
        while (!self.quit) {
            try self.pump(app, -1); // block until input or vsync callback
            if (self.frame_due) {
                self.frame_due = false;
                try self.present(app);
                self.dumpFrame(frames + 1);
                frames += 1;
                if (max_frames) |m| {
                    if (frames >= m) self.quit = true;
                }
            }
        }
        std.debug.print("cipher: WAYLAND_PROTOCOL_OK frames={d}\n", .{frames});
    }
};

pub const App = struct {
    ptr: *anyopaque,
    onInit: *const fn (ptr: *anyopaque, rt: *Runtime) anyerror!void,
    onEvent: *const fn (ptr: *anyopaque, rt: *Runtime, ev: input.Event) void,
    onFrame: *const fn (ptr: *anyopaque, rt: *Runtime) anyerror!void,
};

/// Run an app. `A` may define `onInit(rt)`, `onEvent(rt, ev)`, `onFrame(rt)`.
pub fn run(comptime A: type, app: *A) !void {
    const H = struct {
        fn onInit(p: *anyopaque, rt: *Runtime) anyerror!void {
            const self: *A = @ptrCast(@alignCast(p));
            if (@hasDecl(A, "onInit")) try self.onInit(rt);
        }
        fn onEvent(p: *anyopaque, rt: *Runtime, ev: input.Event) void {
            const self: *A = @ptrCast(@alignCast(p));
            if (@hasDecl(A, "onEvent")) self.onEvent(rt, ev);
        }
        fn onFrame(p: *anyopaque, rt: *Runtime) anyerror!void {
            const self: *A = @ptrCast(@alignCast(p));
            if (@hasDecl(A, "onFrame")) try self.onFrame(rt);
        }
    };
    const vtable = App{
        .ptr = app,
        .onInit = H.onInit,
        .onEvent = H.onEvent,
        .onFrame = H.onFrame,
    };
    var rt = try Runtime.init(.{});
    defer rt.deinit();
    rt.app_ref = &vtable;
    try vtable.onInit(vtable.ptr, &rt);
    try rt.runLoop(&vtable);
}

/// Run an app with custom options (title/font/size).
pub fn runWith(comptime A: type, app: *A, opts: Options) !void {
    const H = struct {
        fn onInit(p: *anyopaque, rt: *Runtime) anyerror!void {
            const self: *A = @ptrCast(@alignCast(p));
            if (@hasDecl(A, "onInit")) try self.onInit(rt);
        }
        fn onEvent(p: *anyopaque, rt: *Runtime, ev: input.Event) void {
            const self: *A = @ptrCast(@alignCast(p));
            if (@hasDecl(A, "onEvent")) self.onEvent(rt, ev);
        }
        fn onFrame(p: *anyopaque, rt: *Runtime) anyerror!void {
            const self: *A = @ptrCast(@alignCast(p));
            if (@hasDecl(A, "onFrame")) try self.onFrame(rt);
        }
    };
    const vtable = App{
        .ptr = app,
        .onInit = H.onInit,
        .onEvent = H.onEvent,
        .onFrame = H.onFrame,
    };
    var rt = try Runtime.init(opts);
    defer rt.deinit();
    rt.app_ref = &vtable;
    try vtable.onInit(vtable.ptr, &rt);
    try rt.runLoop(&vtable);
}

test "uriListToPaths decodes file:// URIs and percent escapes" {
    const data = "# comment\nfile:///home/sifr/My%20Music/song.flac\nfile:///tmp/a%2Bb.flac\nhttps://example.com/x\n";
    const out = try uriListToPaths(std.testing.allocator, data);
    defer std.testing.allocator.free(out);
    try std.testing.expectEqualStrings("/home/sifr/My Music/song.flac\n/tmp/a+b.flac\nhttps://example.com/x\n", out);
    std.debug.print("URILIST_OK\n", .{});
}

test "rgba01 byte order" {
    const c = rgba01(0xFF45B5EB);
    try std.testing.expectApproxEqAbs(@as(f32, 0x45) / 255.0, c[0], 1e-6);
    try std.testing.expectApproxEqAbs(@as(f32, 0xB5) / 255.0, c[1], 1e-6);
    try std.testing.expectApproxEqAbs(@as(f32, 0xEB) / 255.0, c[2], 1e-6);
    try std.testing.expectApproxEqAbs(1.0, c[3], 1e-6);
}
