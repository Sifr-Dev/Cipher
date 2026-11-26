//! Wayland client for Cipher — dlopen'd libwayland-client + libxkbcommon.
//! Minimal wrapper for exactly what the runtime needs; nothing else.
//! The public surface mirrors the old wire-client facade so the runtime
//! doesn't change shape:
//!   Connection.connect()  -> roundtrip, populate globals
//!   setNonBlocking()      -> fd is put in nonblocking mode
//!   drain()               -> returns number of events (WouldBlock = 0)
//!   Event { sender, opcode, payload(), read32, readI32, fixed24_8, fd }
//! Globals are raw proxy pointers exposed in `ids`.

const std = @import("std");
const wayland_tables = @import("wayland_tables.zig");
const wl_interface = wayland_tables.wl_interface;
const wl_message = wayland_tables.wl_message;

// ====================================================================
// libwayland-client + libxkbcommon — dlopen'd, per the framework's
// rule that the display component provides itself; nothing to install.

var libwayland: ?*anyopaque = null;
var w: Wayland = undefined;
var g_xkb: ?Xkb = null;

fn load() !void {
    if (libwayland != null) return;
    libwayland = try openLib(&[_][*:0]const u8{ "libwayland-client.so.0", "/usr/lib/libwayland-client.so.0" });
    const h = libwayland.?;
    w = .{
        .wl_display_connect = sym(*const fn (?[*:0]const u8) callconv(.c) ?*wl_display, h, "wl_display_connect"),
        .wl_display_disconnect = sym(*const fn (*wl_display) callconv(.c) void, h, "wl_display_disconnect"),
        .wl_display_get_fd = sym(*const fn (*wl_display) callconv(.c) i32, h, "wl_display_get_fd"),
        .wl_display_roundtrip = sym(*const fn (*wl_display) callconv(.c) i32, h, "wl_display_roundtrip"),
        .wl_display_prepare_read = sym(*const fn (*wl_display) callconv(.c) i32, h, "wl_display_prepare_read"),
        .wl_display_read_events = sym(*const fn (*wl_display) callconv(.c) i32, h, "wl_display_read_events"),
        .wl_display_cancel_read = sym(*const fn (*wl_display) callconv(.c) void, h, "wl_display_cancel_read"),
        .wl_display_get_error = sym(*const fn (*wl_display) callconv(.c) i32, h, "wl_display_get_error"),
        .wl_display_dispatch_pending = sym(*const fn (*wl_display) callconv(.c) i32, h, "wl_display_dispatch_pending"),
        .wl_display_flush = sym(*const fn (*wl_display) callconv(.c) i32, h, "wl_display_flush"),
        .wl_proxy_marshal = sym(*const fn (*anyopaque, u32, ...) callconv(.c) ?*wl_proxy, h, "wl_proxy_marshal"),
        .wl_proxy_marshal_constructor = sym(*const fn (*anyopaque, u32, *const wl_interface, ...) callconv(.c) ?*wl_proxy, h, "wl_proxy_marshal_constructor"),
        .wl_proxy_marshal_flags = sym(*const fn (*anyopaque, u32, ?*const wl_interface, u32, u32, ...) callconv(.c) ?*wl_proxy, h, "wl_proxy_marshal_flags"),
        .wl_proxy_add_listener = sym(*const fn (*anyopaque, *const anyopaque, ?*anyopaque) callconv(.c) i32, h, "wl_proxy_add_listener"),
        .wl_proxy_get_version = sym(*const fn (*anyopaque) callconv(.c) u32, h, "wl_proxy_get_version"),
    };
    loadXkb();
}

fn loadXkb() void {
    const handle = openLib(&[_][*:0]const u8{ "libxkbcommon.so.0", "/usr/lib/libxkbcommon.so.0" }) catch return;
    g_xkb = .{
        .context_new = sym(*const fn (u32) callconv(.c) ?*xkb_context, handle, "xkb_context_new"),
        .context_unref = sym(*const fn (*xkb_context) callconv(.c) void, handle, "xkb_context_unref"),
        .keymap_new_from_string = sym(*const fn (*xkb_context, [*:0]const u8, u32, u32) callconv(.c) ?*xkb_keymap, handle, "xkb_keymap_new_from_string"),
        .keymap_unref = sym(*const fn (*xkb_keymap) callconv(.c) void, handle, "xkb_keymap_unref"),
        .state_new = sym(*const fn (*xkb_keymap) callconv(.c) ?*xkb_state, handle, "xkb_state_new"),
        .state_unref = sym(*const fn (*xkb_state) callconv(.c) void, handle, "xkb_state_unref"),
        .state_update_mask = sym(*const fn (*xkb_state, u32, u32, u32, u32, u32, u32) callconv(.c) u32, handle, "xkb_state_update_mask"),
        .state_update_key = sym(*const fn (*xkb_state, u32, u32) callconv(.c) u32, handle, "xkb_state_update_key"),
        .state_key_get_one_sym = sym(*const fn (*xkb_state, u32) callconv(.c) u32, handle, "xkb_state_key_get_one_sym"),
        .keysym_to_utf8 = sym(*const fn (u32, [*]u8, usize) callconv(.c) i32, handle, "xkb_keysym_to_utf8"),
    };
}

const Wayland = struct {
    wl_display_connect: *const fn (?[*:0]const u8) callconv(.c) ?*wl_display,
    wl_display_disconnect: *const fn (*wl_display) callconv(.c) void,
    wl_display_get_fd: *const fn (*wl_display) callconv(.c) i32,
    wl_display_roundtrip: *const fn (*wl_display) callconv(.c) i32,
    wl_display_prepare_read: *const fn (*wl_display) callconv(.c) i32,
    wl_display_read_events: *const fn (*wl_display) callconv(.c) i32,
    wl_display_cancel_read: *const fn (*wl_display) callconv(.c) void,
    wl_display_get_error: *const fn (*wl_display) callconv(.c) i32,
    wl_display_dispatch_pending: *const fn (*wl_display) callconv(.c) i32,
    wl_display_flush: *const fn (*wl_display) callconv(.c) i32,
    wl_proxy_marshal: *const fn (*anyopaque, u32, ...) callconv(.c) ?*wl_proxy,
    wl_proxy_marshal_constructor: *const fn (*anyopaque, u32, *const wl_interface, ...) callconv(.c) ?*wl_proxy,
    wl_proxy_marshal_flags: *const fn (*anyopaque, u32, ?*const wl_interface, u32, u32, ...) callconv(.c) ?*wl_proxy,
    wl_proxy_add_listener: *const fn (*anyopaque, *const anyopaque, ?*anyopaque) callconv(.c) i32,
    wl_proxy_get_version: *const fn (*anyopaque) callconv(.c) u32,
};

const Xkb = struct {
    context_new: *const fn (u32) callconv(.c) ?*xkb_context,
    context_unref: *const fn (*xkb_context) callconv(.c) void,
    keymap_new_from_string: *const fn (*xkb_context, [*:0]const u8, u32, u32) callconv(.c) ?*xkb_keymap,
    keymap_unref: *const fn (*xkb_keymap) callconv(.c) void,
    state_new: *const fn (*xkb_keymap) callconv(.c) ?*xkb_state,
    state_unref: *const fn (*xkb_state) callconv(.c) void,
    state_update_mask: *const fn (*xkb_state, u32, u32, u32, u32, u32, u32) callconv(.c) u32,
    state_update_key: *const fn (*xkb_state, u32, u32) callconv(.c) u32,
    state_key_get_one_sym: *const fn (*xkb_state, u32) callconv(.c) u32,
    keysym_to_utf8: *const fn (u32, [*]u8, usize) callconv(.c) i32,
};

fn openLib(paths: []const [*:0]const u8) !*anyopaque {
    for (paths) |p| {
        if (dlopen(p, RTLD_LAZY | RTLD_GLOBAL)) |h| return h;
    }
    return error.DlOpenFailed;
}
const RTLD_LAZY = 1;
const RTLD_GLOBAL = 0x100;

/// xkb is optional — absent libxkbcommon, key events still work via evdev codes,
/// just without layout-aware text.
fn xkb() *const Xkb {
    return &(g_xkb orelse unreachable); // call sites only reach here when g_xkb != null
}

fn sym(comptime T: type, lib: *anyopaque, name: [*:0]const u8) T {
    if (dlsym(lib, name)) |p| {
        return @ptrCast(p);
    }
    @panic("required symbol missing from libwayland-client");
}

// ====================================================================
// opaque handle types
// ====================================================================
const wl_display = opaque {};
const wl_registry = opaque {};
const wl_proxy = opaque {};
const wl_compositor = opaque {};
const wl_shm = opaque {};
const wl_shm_pool = opaque {};
const wl_buffer = opaque {};
const wl_region = opaque {};
pub const wl_surface = opaque {};
const wl_seat = opaque {};
const wl_keyboard = opaque {};
const wl_pointer = opaque {};
const wl_output = opaque {};
const wl_subcompositor = opaque {};
const wl_data_device_manager = opaque {};
const wl_data_device = opaque {};
const wl_data_offer = opaque {};
const wl_data_source = opaque {};
const xdg_wm_base = opaque {};
const xdg_surface = opaque {};
const xdg_toplevel = opaque {};
pub const zwp_text_input_manager_v3 = opaque {};
pub const zwp_text_input_v3 = opaque {};
const xkb_context = opaque {};
const xkb_keymap = opaque {};
const xkb_state = opaque {};

const WL_MARSHAL_FLAG_DESTROY: u32 = 1 << 0;
const XKB_KEYMAP_FORMAT_TEXT_V1: u32 = 1;
const XKB_KEYMAP_USE_FOR_STATE: u32 = 1;

extern fn dlopen(path: [*:0]const u8, mode: c_int) ?*anyopaque;
extern fn dlsym(handle: ?*anyopaque, symbol: [*:0]const u8) ?*anyopaque;

const wl_registry_listener = extern struct {
    global: ?*const fn (?*anyopaque, *wl_registry, u32, [*:0]const u8, u32) callconv(.c) void = null,
    global_remove: ?*const fn (?*anyopaque, *wl_registry, u32) callconv(.c) void = null,
};
const wl_shm_listener = extern struct {
    format: ?*const fn (?*anyopaque, *wl_shm, u32) callconv(.c) void = null,
};
const xdg_wm_base_listener = extern struct {
    ping: ?*const fn (?*anyopaque, *xdg_wm_base, u32) callconv(.c) void = null,
};
const xdg_surface_listener = extern struct {
    configure: ?*const fn (?*anyopaque, *xdg_surface, u32) callconv(.c) void = null,
};
const xdg_toplevel_listener = extern struct {
    configure: ?*const fn (?*anyopaque, *xdg_toplevel, i32, i32, *const wl_array) callconv(.c) void = null,
    close: ?*const fn (?*anyopaque, *xdg_toplevel) callconv(.c) void = null,
    configure_bounds: ?*const fn (?*anyopaque, *xdg_toplevel, i32, i32) callconv(.c) void = null,
    wm_capabilities: ?*const fn (?*anyopaque, *xdg_toplevel, *const wl_array) callconv(.c) void = null,
};
const wl_seat_listener = extern struct {
    capabilities: ?*const fn (?*anyopaque, *wl_seat, u32) callconv(.c) void = null,
    name: ?*const fn (?*anyopaque, *wl_seat, [*:0]const u8) callconv(.c) void = null,
};
const wl_keyboard_listener = extern struct {
    keymap: ?*const fn (?*anyopaque, *wl_keyboard, u32, i32, u32) callconv(.c) void = null,
    enter: ?*const fn (?*anyopaque, *wl_keyboard, u32, *wl_surface, *const wl_array) callconv(.c) void = null,
    leave: ?*const fn (?*anyopaque, *wl_keyboard, u32, *wl_surface) callconv(.c) void = null,
    key: ?*const fn (?*anyopaque, *wl_keyboard, u32, u32, u32, u32) callconv(.c) void = null,
    modifiers: ?*const fn (?*anyopaque, *wl_keyboard, u32, u32, u32, u32, u32) callconv(.c) void = null,
    repeat_info: ?*const fn (?*anyopaque, *wl_keyboard, i32, i32) callconv(.c) void = null,
};
const wl_pointer_listener = extern struct {
    enter: ?*const fn (?*anyopaque, *wl_pointer, u32, *wl_surface, wl_fixed_t, wl_fixed_t) callconv(.c) void = null,
    leave: ?*const fn (?*anyopaque, *wl_pointer, u32, *wl_surface) callconv(.c) void = null,
    motion: ?*const fn (?*anyopaque, *wl_pointer, u32, wl_fixed_t, wl_fixed_t) callconv(.c) void = null,
    button: ?*const fn (?*anyopaque, *wl_pointer, u32, u32, u32, u32) callconv(.c) void = null,
    axis: ?*const fn (?*anyopaque, *wl_pointer, u32, u32, i32) callconv(.c) void = null,
    frame: ?*const fn (?*anyopaque, *wl_pointer) callconv(.c) void = null,
    axis_source: ?*const fn (?*anyopaque, *wl_pointer, u32) callconv(.c) void = null,
    axis_stop: ?*const fn (?*anyopaque, *wl_pointer, u32, u32) callconv(.c) void = null,
    axis_discrete: ?*const fn (?*anyopaque, *wl_pointer, u32, i32) callconv(.c) void = null,
    axis_value120: ?*const fn (?*anyopaque, *wl_pointer, u32, i32) callconv(.c) void = null,
    axis_relative_direction: ?*const fn (?*anyopaque, *wl_pointer, u32, u32) callconv(.c) void = null,
    warp: ?*const fn (?*anyopaque, *wl_pointer, u32, wl_fixed_t, wl_fixed_t) callconv(.c) void = null,
};
const wl_output_listener = extern struct {
    geometry: ?*const fn (?*anyopaque, *wl_output, i32, i32, i32, i32, i32, [*:0]const u8, [*:0]const u8, i32) callconv(.c) void = null,
    mode: ?*const fn (?*anyopaque, *wl_output, u32, i32, i32, i32) callconv(.c) void = null,
    done: ?*const fn (?*anyopaque, *wl_output) callconv(.c) void = null,
    scale: ?*const fn (?*anyopaque, *wl_output, i32) callconv(.c) void = null,
    name: ?*const fn (?*anyopaque, *wl_output, [*:0]const u8) callconv(.c) void = null,
    description: ?*const fn (?*anyopaque, *wl_output, [*:0]const u8) callconv(.c) void = null,
};
const wl_data_device_listener = extern struct {
    data_offer: ?*const fn (?*anyopaque, *wl_data_device, *wl_data_offer) callconv(.c) void = null,
    enter: ?*const fn (?*anyopaque, *wl_data_device, u32, *wl_surface, wl_fixed_t, wl_fixed_t, ?*wl_data_offer) callconv(.c) void = null,
    leave: ?*const fn (?*anyopaque, *wl_data_device) callconv(.c) void = null,
    motion: ?*const fn (?*anyopaque, *wl_data_device, u32, wl_fixed_t, wl_fixed_t) callconv(.c) void = null,
    drop: ?*const fn (?*anyopaque, *wl_data_device) callconv(.c) void = null,
    selection: ?*const fn (?*anyopaque, *wl_data_device, ?*wl_data_offer) callconv(.c) void = null,
};
const wl_data_offer_listener = extern struct {
    offer: ?*const fn (?*anyopaque, *wl_data_offer, [*:0]const u8) callconv(.c) void = null,
    source_actions: ?*const fn (?*anyopaque, *wl_data_offer, u32) callconv(.c) void = null,
    action: ?*const fn (?*anyopaque, *wl_data_offer, u32) callconv(.c) void = null,
};
const wl_data_source_listener = extern struct {
    target: ?*const fn (?*anyopaque, *wl_data_source, ?[*:0]const u8) callconv(.c) void = null,
    send: ?*const fn (?*anyopaque, *wl_data_source, [*:0]const u8, i32) callconv(.c) void = null,
    cancelled: ?*const fn (?*anyopaque, *wl_data_source) callconv(.c) void = null,
    dnd_drop_performed: ?*const fn (?*anyopaque, *wl_data_source) callconv(.c) void = null,
    dnd_finished: ?*const fn (?*anyopaque, *wl_data_source) callconv(.c) void = null,
    action: ?*const fn (?*anyopaque, *wl_data_source, u32) callconv(.c) void = null,
};
const wl_callback_listener = extern struct {
    done: ?*const fn (?*anyopaque, *anyopaque, u32) callconv(.c) void = null,
};
// zwp_text_input_v3: the compositor acts as the input method. Signals land in
// Connection.ime_events (see `ImeEvent`) rather than the u32-only facade queue,
// because preedit and commit strings travel with them.
pub const zwp_text_input_v3_listener = extern struct {
    enter: ?*const fn (?*anyopaque, *zwp_text_input_v3, *wl_surface) callconv(.c) void = null,
    leave: ?*const fn (?*anyopaque, *zwp_text_input_v3, *wl_surface) callconv(.c) void = null,
    preedit_string: ?*const fn (?*anyopaque, *zwp_text_input_v3, ?[*:0]const u8, i32, i32) callconv(.c) void = null,
    commit_string: ?*const fn (?*anyopaque, *zwp_text_input_v3, ?[*:0]const u8) callconv(.c) void = null,
    delete_surrounding_text: ?*const fn (?*anyopaque, *zwp_text_input_v3, u32, u32) callconv(.c) void = null,
    done: ?*const fn (?*anyopaque, *zwp_text_input_v3, u32) callconv(.c) void = null,
    action: ?*const fn (?*anyopaque, *zwp_text_input_v3, u32, u32) callconv(.c) void = null,
    language: ?*const fn (?*anyopaque, *zwp_text_input_v3, ?[*:0]const u8) callconv(.c) void = null,
    preedit_hint: ?*const fn (?*anyopaque, *zwp_text_input_v3, u32, u32, u32) callconv(.c) void = null,
};
const wl_array = extern struct {
    size: usize,
    alloc: usize,
    data: ?*anyopaque,
};
const wl_fixed_t = i32;

const XkbState = struct {
    ctx: *xkb_context,
    keymap: *xkb_keymap,
    state: *xkb_state,
};

// ====================================================================
// facade surface: Event / ObjectIds / ShmBuffer / Error
// ====================================================================

pub const wl_compositor_interface = wayland_tables.wl_compositor_interface;
pub const wl_shm_interface = wayland_tables.wl_shm_interface;
pub const wl_seat_interface = wayland_tables.wl_seat_interface;
pub const wl_output_interface = wayland_tables.wl_output_interface;
pub const wl_data_device_manager_interface = wayland_tables.wl_data_device_manager_interface;
pub const wl_data_device_interface = wayland_tables.wl_data_device_interface;
pub const wl_data_offer_interface = wayland_tables.wl_data_offer_interface;
pub const wl_data_source_interface = wayland_tables.wl_data_source_interface;
pub const wl_surface_interface = wayland_tables.wl_surface_interface;
pub const wl_buffer_interface = wayland_tables.wl_buffer_interface;
pub const wl_shm_pool_interface = wayland_tables.wl_shm_pool_interface;
pub const xdg_wm_base_interface = wayland_tables.xdg_wm_base_interface;
pub const xdg_surface_interface = wayland_tables.xdg_surface_interface;
pub const xdg_toplevel_interface = wayland_tables.xdg_toplevel_interface;
pub const wl_keyboard_interface = wayland_tables.wl_keyboard_interface;
pub const wl_pointer_interface = wayland_tables.wl_pointer_interface;
pub const wl_callback_interface = wayland_tables.wl_callback_interface;
pub const zwp_text_input_manager_v3_interface = wayland_tables.zwp_text_input_manager_v3_interface;
pub const zwp_text_input_v3_interface = wayland_tables.zwp_text_input_v3_interface;

pub const Error = error{
    ConnectFailed,
    SocketFailed,
    WriteFailed,
    ReadFailed,
    ProtocolError,
    OutOfMemory,
    MapFailed,
    FdError,
    WouldBlock,
    PollFailed,
    BindFailed,
    UnknownGlobal,
};

pub const WL_DISPLAY: u32 = 1;

pub const Event = struct {
    sender: u32 = 0,
    opcode: u16 = 0,
    payload_len: usize = 0,
    fd: ?i32 = null,
    _buffer: [8192]u8 = undefined,

    pub const MAX_MESSAGE: usize = 8192;

    pub fn payload(self: *const Event) []const u8 {
        return self._buffer[0..self.payload_len];
    }
    pub fn read32(self: *const Event, index: usize) u32 {
        return std.mem.readInt(u32, self.payload()[index * 4 ..][0..4], .little);
    }
    pub fn readI32(self: *const Event, index: usize) i32 {
        return @bitCast(self.read32(index));
    }
    pub fn fixed24_8(self: *const Event, index: usize) f64 {
        const s: i32 = @bitCast(self.read32(index));
        return @as(f64, @floatFromInt(s >> 8)) + @as(f64, @floatFromInt(s & 0xff)) / 256.0;
    }
};

/// One zwp_text_input_v3 signal, translated out of the C callback. Payload
/// semantics per opcode are documented at `ImeOpcode`.
pub const ImeEvent = struct {
    opcode: ImeOpcode,
    /// UTF-8 text for preedit_string / commit_string / language.
    text: [4096]u8 = undefined,
    text_len: usize = 0,
    /// Numeric arguments, meaning depends on the opcode.
    a: i32 = 0,
    b: i32 = 0,
    c: i32 = 0,

    pub fn slice(self: *const ImeEvent) []const u8 {
        return self.text[0..self.text_len];
    }
};

pub const ImeOpcode = enum(u16) {
    /// a = wl_surface token (-1 when the compositor sent a null surface).
    enter = 0,
    /// a = wl_surface token.
    leave = 1,
    /// text = preedit; a = cursor_begin, b = cursor_end (bytes, -1 = hidden).
    preedit_string = 2,
    /// text = committed UTF-8.
    commit_string = 3,
    /// a = bytes before the cursor, b = bytes after.
    delete_surrounding_text = 4,
    /// a = serial.
    done = 5,
    /// a = action (1 = submit), b = serial.
    action = 6,
    /// text = BCP 47 language tag.
    language = 7,
    /// a = start, b = end, c = hint.
    preedit_hint = 8,
};

pub const ObjectIds = struct {
    registry: ?u32 = null,
    output: ?u32 = null,
    text_input_manager: ?u32 = null,
    text_input: ?u32 = null,
    compositor: ?u32 = null,
    shm: ?u32 = null,
    seat: ?u32 = null,
    wm_base: ?u32 = null,
    surface: u32 = 0,
    shm_pool: u32 = 0,
    buffer: u32 = 0,
    xdg_surface: u32 = 0,
    toplevel: u32 = 0,
    keyboard: ?u32 = null,
    pointer: ?u32 = null,
    frame_callback: ?u32 = null,
    sync_callback: ?u32 = null,
    linux_dmabuf: ?u32 = null,
};

pub const ShmBuffer = struct {
    width: u32,
    height: u32,
    stride: u32,
    pixels: []align(4096) u8,
    fd: i32,

    pub fn allocate(width: u32, height: u32) !ShmBuffer {
        const stride = width * 4;
        const size: usize = @intCast(stride * height);

        const memfd_rc = std.os.linux.memfd_create("sifr-shm", 1); // MFD_CLOEXEC
        if (@as(i64, @bitCast(memfd_rc)) < 0) return Error.OutOfMemory;
        const fd: i32 = @intCast(memfd_rc);
        errdefer _ = std.os.linux.close(fd);

        if (std.os.linux.ftruncate(fd, @intCast(size)) != 0) return Error.MapFailed;

        const mapped = std.posix.mmap(
            null,
            size,
            .{ .READ = true, .WRITE = true },
            .{ .TYPE = .SHARED, .POPULATE = true },
            fd,
            0,
        ) catch return Error.MapFailed;
        errdefer std.posix.munmap(mapped);

        return .{
            .width = width,
            .height = height,
            .stride = stride,
            .pixels = mapped,
            .fd = fd,
        };
    }

    pub fn deinit(self: *ShmBuffer) void {
        std.posix.munmap(self.pixels);
        _ = std.os.linux.close(self.fd);
    }
};

var next_token: u32 = 1;

pub const Connection = struct {
    display: *wl_display,
    fd: i32,
    registry: *wl_registry,
    registry_token: u32 = 0,
    globals: std.ArrayList(Global) = .empty,
    events: std.ArrayList(Event) = .empty,
    ime_events: std.ArrayList(ImeEvent) = .empty,
    ptr_tokens: std.AutoHashMap(u64, u32),
    token_ptrs: std.AutoHashMap(u32, u64),
    alloc: std.mem.Allocator,
    xkb: ?XkbState = null,

    pub const Global = struct {
        name: u32,
        interface: []const u8,
        version: u32,
    };

    pub fn connect(allocator: std.mem.Allocator) !*Connection {
        if (libwayland == null) try load();

        const display = w.wl_display_connect(null) orelse return Error.ConnectFailed;
        errdefer w.wl_display_disconnect(display);

        const self = allocator.create(Connection) catch return Error.OutOfMemory;
        errdefer allocator.destroy(self);
        self.* = Connection{
            .display = display,
            .fd = w.wl_display_get_fd(display),
            .registry = undefined,
            .globals = .empty,
            .events = .empty,
            .ime_events = .empty,
            .ptr_tokens = std.AutoHashMap(u64, u32).init(allocator),
            .token_ptrs = std.AutoHashMap(u32, u64).init(allocator),
            .alloc = allocator,
        };

        const reg_proxy = w.wl_proxy_marshal_flags(@ptrCast(display), 1, &wayland_tables.wl_registry_interface, 1, 0, @as(?*const anyopaque, null)) orelse return Error.ConnectFailed;
        self.registry = @ptrCast(reg_proxy);
        self.registry_token = self.tokenize(reg_proxy);

        // NOTE: wl_display itself cannot take a listener (libwayland-client keeps
        // an internal one); protocol errors surface via wl_display_get_error().
        if (w.wl_proxy_add_listener(reg_proxy, @ptrCast(&REGISTRY_LISTENER), @ptrCast(self)) != 0) return Error.ConnectFailed;

        if (w.wl_display_roundtrip(display) < 0) return Error.ConnectFailed;
        return self;
    }

    /// disconnect + free the heap Connection. Listeners reference this
    /// Connection's heap address; do not move it after listeners are set.
    pub fn destroy(self: *Connection) void {
        self.disconnect();
        self.alloc.destroy(self);
    }

    pub fn disconnect(self: *Connection) void {
        w.wl_display_disconnect(self.display);
        if (self.xkb) |*x| {
            xkb().state_unref(x.state);
            xkb().keymap_unref(x.keymap);
            xkb().context_unref(x.ctx);
            self.xkb = null;
        }
        for (self.globals.items) |g| self.alloc.free(g.interface);
        self.globals.deinit(self.alloc);
        self.events.deinit(self.alloc);
        self.ime_events.deinit(self.alloc);
        self.ptr_tokens.deinit();
        self.token_ptrs.deinit();
    }

    /// Text (codepoint) for an evdev key press under the current xkb layout,
    /// or null when no keymap is loaded / key produces no text.
    pub fn keyChar(self: *Connection, evdev_key: u32) ?u21 {
        const x = &(self.xkb orelse return null);
        const keysym = xkb().state_key_get_one_sym(x.state, evdev_key + 8); // evdev -> xkb offset
        if (keysym == 0) return null;
        var buf: [16]u8 = undefined;
        const n = xkb().keysym_to_utf8(keysym, &buf, buf.len);
        if (n <= 1) return null; // NUL-only or nothing
        return std.unicode.utf8Decode(buf[0 .. @intCast(n - 1)]) catch null;
    }

    pub fn flush(self: *Connection) void {
        _ = w.wl_display_flush(self.display);
    }

    pub fn setNonBlocking(self: *Connection) void {
        _ = self;
    }

    pub fn tokenize(self: *Connection, proxy: ?*anyopaque) u32 {
        if (proxy == null) return 0;
        const p: u64 = @intFromPtr(proxy);
        if (self.ptr_tokens.get(p)) |t| return t;
        next_token += 1;
        const t = next_token;
        self.ptr_tokens.put(p, t) catch return 0;
        self.token_ptrs.put(t, p) catch {};
        return t;
    }

    pub fn proxyFromToken(self: *Connection, token: u32) ?*anyopaque {
        const p = self.token_ptrs.get(token) orelse return null;
        return @ptrFromInt(p);
    }

    pub fn versionOf(self: *Connection, token: u32) u32 {
        const proxy = self.proxyFromToken(token) orelse return 1;
        return w.wl_proxy_get_version(proxy);
    }

    pub fn findGlobal(self: *Connection, name: []const u8) ?Global {
        for (self.globals.items) |g| {
            if (std.mem.eql(u8, g.interface, name)) return g;
        }
        return null;
    }

    /// Bind a global by interface name; returns its token. Version is
    /// clamped to what the compositor advertised.
    pub fn bindGlobal(self: *Connection, name: []const u8, interface: *const anyopaque, version: u32) !u32 {
        const ref = self.findGlobal(name) orelse return Error.UnknownGlobal;
        const v = @min(ref.version, version);
        const iface: *const wl_interface = @alignCast(@ptrCast(interface));
        const obj = w.wl_proxy_marshal_flags(@ptrCast(self.registry), 0, iface, v, 0, ref.name, iface.name, v, @as(?*const anyopaque, null)) orelse return Error.BindFailed;
        return self.tokenize(obj);
    }

    /// Dispatch any events already pending; do not read from the fd.
    pub fn drainPending(self: *Connection) !usize {
        _ = w.wl_display_flush(self.display);
        const disp = w.wl_display_dispatch_pending(self.display);
        if (disp < 0) return Error.ProtocolError;
        return @intCast(disp);
    }

    /// Wait up to timeout_ms for events and dispatch them.
    pub fn waitDispatch(self: *Connection, timeout_ms: i32) !usize {
        _ = w.wl_display_flush(self.display);
        const pending = w.wl_display_dispatch_pending(self.display);
        if (pending < 0) return Error.ProtocolError;
        if (pending > 0) return @intCast(pending);

        if (w.wl_display_prepare_read(self.display) == -1) {
            const p2 = w.wl_display_dispatch_pending(self.display);
            if (p2 < 0) return self.protocolError();
            return @intCast(p2);
        }
        var pfd = [_]std.posix.pollfd{.{ .fd = self.fd, .events = std.posix.POLL.IN, .revents = 0 }};
        const rc = std.posix.poll(&pfd, timeout_ms) catch {
            w.wl_display_cancel_read(self.display);
            return Error.PollFailed;
        };
        if (rc == 0) {
            w.wl_display_cancel_read(self.display);
            return 0;
        }
        if (w.wl_display_read_events(self.display) < 0) {
            w.wl_display_cancel_read(self.display);
            return Error.ReadFailed;
        }
        const disp = w.wl_display_dispatch_pending(self.display);
        if (disp < 0) return self.protocolError();
        return @intCast(disp);
    }

    fn protocolError(self: *Connection) Error {
        const code = w.wl_display_get_error(self.display);
        std.debug.print("cipher: wayland protocol error {d}\n", .{code});
        return Error.ProtocolError;
    }

    pub fn clearEvents(self: *Connection) void {
        self.events.clearRetainingCapacity();
        self.ime_events.clearRetainingCapacity();
    }

    // ---- generic marshalling (used by the text-input transport) ------------

    /// Marshal a request that creates no new object. `args` is a tuple of the
    /// request's wire arguments.
    pub fn marshalVoid(self: *Connection, token: u32, opcode: u32, args: anytype) void {
        const proxy = self.proxyFromToken(token) orelse return;
        _ = @call(.auto, w.wl_proxy_marshal, .{ proxy, opcode } ++ args);
    }

    /// Marshal a constructor request (`new_id` first argument) and tokenize
    /// the new proxy. Returns null when the proxy or object is unusable.
    pub fn marshalConstructor(self: *Connection, token: u32, opcode: u32, iface: *const anyopaque, args: anytype) ?u32 {
        const proxy = self.proxyFromToken(token) orelse return null;
        const i: *const wl_interface = @alignCast(@ptrCast(iface));
        const obj = @call(.auto, w.wl_proxy_marshal_flags, .{ proxy, opcode, i, self.versionOf(token), 0, @as(?*const anyopaque, null) } ++ args) orelse return null;
        return self.tokenize(obj);
    }

    pub fn registerListener(self: *Connection, token: u32, listener: *const anyopaque) void {
        const proxy = self.proxyFromToken(token) orelse return;
        if (w.wl_proxy_add_listener(proxy, listener, @ptrCast(self)) != 0) {
            std.debug.print("cipher: wl_proxy_add_listener failed for token {d}\n", .{token});
        }
    }

    /// Destroy a proxy with an explicit destructor opcode.
    pub fn destroyProxy(self: *Connection, token: u32, opcode: u32) void {
        const proxy = self.proxyFromToken(token) orelse return;
        _ = w.wl_proxy_marshal_flags(proxy, opcode, null, self.versionOf(token), WL_MARSHAL_FLAG_DESTROY);
    }

    /// Queue one text-input (IME) event for the runtime to drain.
    pub fn pushImeEvent(self: *Connection, opcode: ImeOpcode, text: ?[]const u8, nums: []const i32) !void {
        var ev = ImeEvent{ .opcode = opcode };
        if (text) |t| {
            const n = @min(t.len, ev.text.len);
            @memcpy(ev.text[0..n], t[0..n]);
            ev.text_len = n;
        }
        if (nums.len > 0) ev.a = nums[0];
        if (nums.len > 1) ev.b = nums[1];
        if (nums.len > 2) ev.c = nums[2];
        try self.ime_events.append(self.alloc, ev);
    }

    pub fn roundtrip(self: *Connection) i32 {
        return w.wl_display_roundtrip(self.display);
    }
};

fn tokenizeFromData(data: ?*anyopaque, proxy: ?*anyopaque) u32 {
    const self: *Connection = @alignCast(@ptrCast(data orelse return 0));
    return self.tokenize(proxy);
}

const REGISTRY_LISTENER = wl_registry_listener{ .global = registryGlobal, .global_remove = registryGlobalRemove };
const XDG_WM_BASE_LISTENER = xdg_wm_base_listener{ .ping = xdgWmBasePingListener };
const XDG_SURFACE_LISTENER = xdg_surface_listener{ .configure = xdgSurfaceConfigureListener };
const XDG_TOPLEVEL_LISTENER = xdg_toplevel_listener{ .configure = xdgToplevelConfigureListener, .close = xdgToplevelCloseListener, .configure_bounds = xdgToplevelConfigureBoundsListener, .wm_capabilities = xdgToplevelWmCapabilitiesListener };
const WL_SEAT_LISTENER = wl_seat_listener{ .capabilities = seatCapabilitiesListener, .name = seatNameListener };
const WL_KEYBOARD_LISTENER = wl_keyboard_listener{
    .keymap = keyboardKeymapListener,
    .enter = keyboardEnterListener,
    .leave = keyboardLeaveListener,
    .key = keyboardKeyListener,
    .modifiers = keyboardModifiersListener,
    .repeat_info = keyboardRepeatInfoListener,
};
const WL_POINTER_LISTENER = wl_pointer_listener{
    .enter = pointerEnterListener,
    .leave = pointerLeaveListener,
    .motion = pointerMotionListener,
    .button = pointerButtonListener,
    .axis = pointerAxisListener,
    .frame = pointerFrameListener,
    .axis_source = pointerAxisSourceListener,
    .axis_stop = pointerAxisStopListener,
    .axis_discrete = pointerAxisDiscreteListener,
    .axis_value120 = pointerAxisValue120Listener,
    .axis_relative_direction = pointerAxisRelativeDirectionListener,
    .warp = pointerWarpListener,
};
const WL_OUTPUT_LISTENER = wl_output_listener{
    .geometry = outputGeometryListener,
    .mode = outputModeListener,
    .done = outputDoneListener,
    .scale = outputScaleListener,
    .name = outputNameListener,
    .description = outputDescriptionListener,
};
const WL_SHM_LISTENER = wl_shm_listener{ .format = shmFormatListener };
const WL_DATA_DEVICE_LISTENER = wl_data_device_listener{
    .data_offer = dataDeviceDataOfferListener,
    .enter = dataDeviceEnterListener,
    .leave = dataDeviceLeaveListener,
    .motion = dataDeviceMotionListener,
    .drop = dataDeviceDropListener,
    .selection = dataDeviceSelectionListener,
};
const WL_DATA_OFFER_LISTENER = wl_data_offer_listener{ .offer = dataOfferOfferListener, .source_actions = dataOfferSourceActionsListener, .action = dataOfferActionListener };
const WL_CALLBACK_LISTENER = wl_callback_listener{ .done = frameDoneListener };
const WL_DATA_SOURCE_LISTENER = wl_data_source_listener{
    .target = dataSourceTargetListener,
    .send = dataSourceSendListener,
    .cancelled = dataSourceCancelledListener,
    .dnd_drop_performed = dataSourceDndDropPerformedListener,
    .dnd_finished = dataSourceDndFinishedListener,
    .action = dataSourceActionListener,
};

fn registryGlobal(data: ?*anyopaque, registry: *wl_registry, name: u32, interface: [*:0]const u8, version: u32) callconv(.c) void {
    _ = registry;
    const self: *Connection = @alignCast(@ptrCast(data orelse return));
    const len = std.mem.len(interface);
    const copy = self.alloc.dupe(u8, interface[0..len]) catch return;
    self.globals.append(self.alloc, .{ .name = name, .interface = copy, .version = version }) catch {
        self.alloc.free(copy);
        return;
    };
}
fn registryGlobalRemove(data: ?*anyopaque, registry: *wl_registry, name: u32) callconv(.c) void {
    _ = data;
    _ = registry;
    _ = name;
}

// ---- typed request helpers (used by the runtime) ---------------------------

pub const CString = struct {
    len: usize,
    bytes: [8192]u8,
    fn from(v: []const u8) CString {
        var out = CString{ .len = v.len, .bytes = undefined };
        std.mem.copyForwards(u8, out.bytes[0..v.len], v);
        out.bytes[v.len] = 0;
        return out;
    }
};

pub fn compositorCreateSurface(conn: *Connection, compositor: u32) !u32 {
    const com: *wl_compositor = @ptrCast(conn.proxyFromToken(compositor) orelse return Error.BindFailed);
    const s = w.wl_proxy_marshal_flags(com, 0, &wayland_tables.wl_surface_interface, conn.versionOf(compositor), 0, @as(?*const anyopaque, null)) orelse return Error.OutOfMemory;
    return conn.tokenize(s);
}

pub fn wmBasePong(conn: *Connection, wm_base: u32, serial: u32) void {
    const base: *xdg_wm_base = @ptrCast(conn.proxyFromToken(wm_base) orelse return);
    _ = w.wl_proxy_marshal(base, 3, serial);
}

pub fn wmBaseCreateXdgSurface(conn: *Connection, wm_base: u32, surface: u32) !u32 {
    const base: *xdg_wm_base = @ptrCast(conn.proxyFromToken(wm_base) orelse return Error.BindFailed);
    const surf: *wl_surface = @ptrCast(conn.proxyFromToken(surface) orelse return Error.BindFailed);
    const s = w.wl_proxy_marshal_flags(base, 2, &wayland_tables.xdg_surface_interface, conn.versionOf(wm_base), 0, @as(?*const anyopaque, null), surf) orelse return Error.OutOfMemory;
    return conn.tokenize(s);
}

pub fn xdgSurfaceGetToplevel(conn: *Connection, xs: u32) !u32 {
    const s: *xdg_surface = @ptrCast(conn.proxyFromToken(xs) orelse return Error.BindFailed);
    const t = w.wl_proxy_marshal_flags(s, 1, &wayland_tables.xdg_toplevel_interface, conn.versionOf(xs), 0, @as(?*const anyopaque, null)) orelse return Error.OutOfMemory;
    return conn.tokenize(t);
}

pub fn toplevelSetTitle(conn: *Connection, toplevel: u32, title: []const u8) void {
    const t: *xdg_toplevel = @ptrCast(conn.proxyFromToken(toplevel) orelse return);
    _ = w.wl_proxy_marshal(t, 2, &CString.from(title).bytes);
}

pub fn toplevelSetAppId(conn: *Connection, toplevel: u32, app_id: []const u8) void {
    const t: *xdg_toplevel = @ptrCast(conn.proxyFromToken(toplevel) orelse return);
    _ = w.wl_proxy_marshal(t, 3, &CString.from(app_id).bytes);
}

pub fn toplevelSetMaxSize(conn: *Connection, toplevel: u32, width: i32, height: i32) void {
    const t: *xdg_toplevel = @ptrCast(conn.proxyFromToken(toplevel) orelse return);
    _ = w.wl_proxy_marshal(t, 7, width, height);
}

pub fn toplevelSetMinSize(conn: *Connection, toplevel: u32, width: i32, height: i32) void {
    const t: *xdg_toplevel = @ptrCast(conn.proxyFromToken(toplevel) orelse return);
    _ = w.wl_proxy_marshal(t, 8, width, height);
}

pub fn surfaceCommit(conn: *Connection, surface: u32) void {
    const s: *wl_surface = @ptrCast(conn.proxyFromToken(surface) orelse return);
    _ = w.wl_proxy_marshal(s, 6);
}

pub fn surfaceSetBufferScale(conn: *Connection, surface: u32, scale: i32) void {
    const s: *wl_surface = @ptrCast(conn.proxyFromToken(surface) orelse return);
    _ = w.wl_proxy_marshal(s, 8, scale);
}

pub fn surfaceDamage(conn: *Connection, surface: u32, x: i32, y: i32, width: i32, height: i32) void {
    const s: *wl_surface = @ptrCast(conn.proxyFromToken(surface) orelse return);
    _ = w.wl_proxy_marshal(s, 2, x, y, width, height);
}

pub fn surfaceAttach(conn: *Connection, surface: u32, buffer: u32, x: i32, y: i32) void {
    const s: *wl_surface = @ptrCast(conn.proxyFromToken(surface) orelse return);
    const b: *wl_buffer = @ptrCast(conn.proxyFromToken(buffer) orelse return);
    _ = w.wl_proxy_marshal(s, 1, b, x, y);
}

pub fn surfaceFrame(conn: *Connection, surface: u32) !u32 {
    const s: *wl_surface = @ptrCast(conn.proxyFromToken(surface) orelse return Error.BindFailed);
    const cb = w.wl_proxy_marshal_flags(s, 3, &wayland_tables.wl_callback_interface, conn.versionOf(surface), 0, @as(?*const anyopaque, null)) orelse return Error.OutOfMemory;
    const token = conn.tokenize(cb);
    reg(conn, token, @ptrCast(&WL_CALLBACK_LISTENER));
    return token;
}

fn frameDoneListener(data: ?*anyopaque, cb: *anyopaque, serial: u32) callconv(.c) void {
    _ = serial;
    pushEvent(data, cb, 0, null, 0, .{});
}

pub fn xdgSurfaceAckConfigure(conn: *Connection, xs: u32, serial: u32) void {
    const s: *xdg_surface = @ptrCast(conn.proxyFromToken(xs) orelse return);
    _ = w.wl_proxy_marshal(s, 4, serial);
}

pub fn seatGetKeyboard(conn: *Connection, seat: u32) !u32 {
    const s: *wl_seat = @ptrCast(conn.proxyFromToken(seat) orelse return Error.BindFailed);
    const k = w.wl_proxy_marshal_flags(s, 1, &wayland_tables.wl_keyboard_interface, conn.versionOf(seat), 0, @as(?*const anyopaque, null)) orelse return Error.OutOfMemory;
    return conn.tokenize(k);
}

pub fn seatGetPointer(conn: *Connection, seat: u32) !u32 {
    const s: *wl_seat = @ptrCast(conn.proxyFromToken(seat) orelse return Error.BindFailed);
    const p = w.wl_proxy_marshal_flags(s, 0, &wayland_tables.wl_pointer_interface, conn.versionOf(seat), 0, @as(?*const anyopaque, null)) orelse return Error.OutOfMemory;
    return conn.tokenize(p);
}

pub fn shmCreatePool(conn: *Connection, shm: u32, fd: i32, size: i32) !u32 {
    const s: *wl_shm = @ptrCast(conn.proxyFromToken(shm) orelse return Error.BindFailed);
    const p = w.wl_proxy_marshal_flags(s, 0, &wayland_tables.wl_shm_pool_interface, conn.versionOf(shm), 0, @as(?*const anyopaque, null), fd, size) orelse return Error.OutOfMemory;
    return conn.tokenize(p);
}

pub fn shmPoolCreateBuffer(conn: *Connection, pool: u32, offset: i32, width: i32, height: i32, stride: i32, format: u32) !u32 {
    const p: *wl_shm_pool = @ptrCast(conn.proxyFromToken(pool) orelse return Error.BindFailed);
    const b = w.wl_proxy_marshal_flags(p, 0, &wayland_tables.wl_buffer_interface, conn.versionOf(pool), 0, @as(?*const anyopaque, null), offset, width, height, stride, format) orelse return Error.OutOfMemory;
    return conn.tokenize(b);
}

pub fn dataDeviceManagerCreateDataSource(conn: *Connection, ddm: u32) !u32 {
    const m: *wl_data_device_manager = @ptrCast(conn.proxyFromToken(ddm) orelse return Error.BindFailed);
    const s = w.wl_proxy_marshal_flags(m, 0, &wayland_tables.wl_data_source_interface, conn.versionOf(ddm), 0, @as(?*const anyopaque, null)) orelse return Error.OutOfMemory;
    return conn.tokenize(s);
}

pub fn dataDeviceManagerGetDataDevice(conn: *Connection, ddm: u32, seat: u32) !u32 {
    const m: *wl_data_device_manager = @ptrCast(conn.proxyFromToken(ddm) orelse return Error.BindFailed);
    const s: *wl_seat = @ptrCast(conn.proxyFromToken(seat) orelse return Error.BindFailed);
    const d = w.wl_proxy_marshal_flags(m, 1, &wayland_tables.wl_data_device_interface, conn.versionOf(ddm), 0, @as(?*const anyopaque, null), s) orelse return Error.OutOfMemory;
    return conn.tokenize(d);
}

pub fn dataDeviceSetSelection(conn: *Connection, dd: u32, source: u32, serial: u32) void {
    const d: *wl_data_device = @ptrCast(conn.proxyFromToken(dd) orelse return);
    const s: *wl_data_source = @ptrCast(conn.proxyFromToken(source) orelse return);
    _ = w.wl_proxy_marshal(d, 1, s, serial);
}

pub fn dataSourceOffer(conn: *Connection, source: u32, mime_type: []const u8) void {
    const s: *wl_data_source = @ptrCast(conn.proxyFromToken(source) orelse return);
    _ = w.wl_proxy_marshal(s, 0, &CString.from(mime_type).bytes);
}

pub fn dataOfferAccept(conn: *Connection, offer: u32, serial: u32, mime_type: ?[]const u8) void {
    const o: *wl_data_offer = @ptrCast(conn.proxyFromToken(offer) orelse return);
    if (mime_type) |m| {
        _ = w.wl_proxy_marshal(o, 0, serial, &CString.from(m).bytes);
    } else {
        _ = w.wl_proxy_marshal(o, 0, serial, @as(?[*:0]const u8, null));
    }
}

pub fn dataOfferReceive(conn: *Connection, offer: u32, mime_type: []const u8, fd: i32) void {
    const o: *wl_data_offer = @ptrCast(conn.proxyFromToken(offer) orelse return);
    _ = w.wl_proxy_marshal(o, 1, &CString.from(mime_type).bytes, fd);
}

pub fn dataOfferSetActions(conn: *Connection, offer: u32, source_actions: u32, action: u32) void {
    const o: *wl_data_offer = @ptrCast(conn.proxyFromToken(offer) orelse return);
    _ = w.wl_proxy_marshal(o, 4, source_actions, action);
}



pub fn dataSourceSetActions(conn: *Connection, source: u32, actions: u32) void {
    const s: *wl_data_source = @ptrCast(conn.proxyFromToken(source) orelse return);
    _ = w.wl_proxy_marshal(s, 2, actions);
}

pub fn dataSourceDestroy(conn: *Connection, source: u32) void {
    const s: *wl_data_source = @ptrCast(conn.proxyFromToken(source) orelse return);
    _ = w.wl_proxy_marshal_flags(s, 1, null, 1, WL_MARSHAL_FLAG_DESTROY);
}

pub fn shmPoolDestroy(conn: *Connection, pool: u32) void {
    const p: *wl_shm_pool = @ptrCast(conn.proxyFromToken(pool) orelse return);
    _ = w.wl_proxy_marshal_flags(p, 1, null, 1, WL_MARSHAL_FLAG_DESTROY);
}

pub fn surfaceDestroy(conn: *Connection, surface: u32) void {
    const s: *wl_surface = @ptrCast(conn.proxyFromToken(surface) orelse return);
    _ = w.wl_proxy_marshal_flags(s, 0, null, 1, WL_MARSHAL_FLAG_DESTROY);
}

pub fn xdgToplevelDestroy(conn: *Connection, toplevel: u32) void {
    const t: *xdg_toplevel = @ptrCast(conn.proxyFromToken(toplevel) orelse return);
    _ = w.wl_proxy_marshal_flags(t, 0, null, 1, WL_MARSHAL_FLAG_DESTROY);
}

pub fn xdgSurfaceDestroy(conn: *Connection, xs: u32) void {
    const s: *xdg_surface = @ptrCast(conn.proxyFromToken(xs) orelse return);
    _ = w.wl_proxy_marshal_flags(s, 0, null, 1, WL_MARSHAL_FLAG_DESTROY);
}

pub fn wmBaseDestroy(conn: *Connection, wm_base: u32) void {
    const base: *xdg_wm_base = @ptrCast(conn.proxyFromToken(wm_base) orelse return);
    _ = w.wl_proxy_marshal_flags(base, 0, null, 1, WL_MARSHAL_FLAG_DESTROY);
}

pub fn seatRelease(conn: *Connection, seat: u32) void {
    const s: *wl_seat = @ptrCast(conn.proxyFromToken(seat) orelse return);
    _ = w.wl_proxy_marshal_flags(s, 3, null, 1, WL_MARSHAL_FLAG_DESTROY);
}

pub fn keyboardRelease(conn: *Connection, keyboard: u32) void {
    const k: *wl_keyboard = @ptrCast(conn.proxyFromToken(keyboard) orelse return);
    _ = w.wl_proxy_marshal_flags(k, 0, null, 1, WL_MARSHAL_FLAG_DESTROY);
}

pub fn pointerRelease(conn: *Connection, pointer: u32) void {
    const p: *wl_pointer = @ptrCast(conn.proxyFromToken(pointer) orelse return);
    _ = w.wl_proxy_marshal_flags(p, 1, null, 1, WL_MARSHAL_FLAG_DESTROY);
}

pub fn dataDeviceRelease(conn: *Connection, dd: u32) void {
    const d: *wl_data_device = @ptrCast(conn.proxyFromToken(dd) orelse return);
    _ = w.wl_proxy_marshal_flags(d, 2, null, 1, WL_MARSHAL_FLAG_DESTROY);
}

pub fn dataDeviceDestroyOffer(conn: *Connection, offer: u32) void {
    const o: *wl_data_offer = @ptrCast(conn.proxyFromToken(offer) orelse return);
    _ = w.wl_proxy_marshal_flags(o, 2, null, 1, WL_MARSHAL_FLAG_DESTROY);
}

pub fn dataDeviceManagerRelease(conn: *Connection, ddm: u32) void {
    const m: *wl_data_device_manager = @ptrCast(conn.proxyFromToken(ddm) orelse return);
    _ = w.wl_proxy_marshal_flags(m, 2, null, 1, WL_MARSHAL_FLAG_DESTROY);
}

pub fn bufferDestroy(conn: *Connection, buffer: u32) void {
    const b: *wl_buffer = @ptrCast(conn.proxyFromToken(buffer) orelse return);
    _ = w.wl_proxy_marshal_flags(b, 0, null, 1, WL_MARSHAL_FLAG_DESTROY);
}

pub fn dataOfferDestroy(conn: *Connection, offer: u32) void {
    const o: *wl_data_offer = @ptrCast(conn.proxyFromToken(offer) orelse return);
    _ = w.wl_proxy_marshal_flags(o, 2, null, 1, WL_MARSHAL_FLAG_DESTROY);
}

// ---- listener callbacks — translate C args -> facade Event records ----------

fn pushEvent(data: ?*anyopaque, proxy: ?*anyopaque, opcode: u16, fd: ?i32, comptime n_args: usize, args: [n_args]u32) void {
    const self: *Connection = @alignCast(@ptrCast(data orelse return));
    var e = Event{
        .sender = self.tokenize(proxy),
        .opcode = opcode,
        .fd = fd,
    };
    var payload_len: usize = 0;
    for (args) |a| {
        std.mem.writeInt(u32, e._buffer[payload_len..][0..4], a, .little);
        payload_len += 4;
    }
    e.payload_len = payload_len;
    self.events.append(self.alloc, e) catch {};
}

fn shmFormatListener(data: ?*anyopaque, shm: *wl_shm, format: u32) callconv(.c) void {
    pushEvent(data, shm, 0, null, 1, .{format});
}
fn seatCapabilitiesListener(data: ?*anyopaque, seat: *wl_seat, caps: u32) callconv(.c) void {
    pushEvent(data, seat, 0, null, 1, .{caps});
}
fn seatNameListener(data: ?*anyopaque, seat: *wl_seat, name: [*:0]const u8) callconv(.c) void {
    _ = name;
    pushEvent(data, seat, 1, null, 0, .{});
}
fn keyboardKeymapListener(data: ?*anyopaque, kb: *wl_keyboard, format: u32, fd: i32, size: u32) callconv(.c) void {
    const self: *Connection = @alignCast(@ptrCast(data orelse { _ = std.os.linux.close(fd); return; }));
    // Format 1 = XKB v1 (text). Read the keymap from the fd and build an xkb state.
    const buf = self.alloc.alloc(u8, size) catch {
        _ = std.os.linux.close(fd);
        pushEvent(data, kb, 0, null, 2, .{ format, size });
        return;
    };
    defer self.alloc.free(buf);
    var got: usize = 0;
    while (got < size) {
        const n = std.posix.read(fd, buf[got..]) catch break;
        if (n == 0) break;
        got += n;
    }
    _ = std.os.linux.close(fd);
    if (format == 1 and got == size and g_xkb != null) {
        const ctx = xkb().context_new(0) orelse return;
        // NUL-terminate for the API
        const z = self.alloc.alloc(u8, size + 1) catch {
            xkb().context_unref(ctx);
            return;
        };
        @memcpy(z[0..size], buf);
        z[size] = 0;
        const keymap = xkb().keymap_new_from_string(ctx, @ptrCast(z.ptr), 1, 0); // 1 = XKB_KEYMAP_FORMAT_TEXT_V1
        self.alloc.free(z);
        if (keymap) |km| {
            const state = xkb().state_new(km) orelse {
                xkb().keymap_unref(km);
                xkb().context_unref(ctx);
                pushEvent(data, kb, 0, null, 2, .{ format, size });
                return;
            };
            if (self.xkb) |*old| {
                xkb().state_unref(old.state);
                xkb().keymap_unref(old.keymap);
                xkb().context_unref(old.ctx);
            }
            self.xkb = .{ .ctx = ctx, .keymap = km, .state = state };
        } else {
            xkb().context_unref(ctx);
        }
    }
    pushEvent(data, kb, 0, null, 2, .{ format, size });
}
fn keyboardEnterListener(data: ?*anyopaque, kb: *wl_keyboard, serial: u32, surface: *wl_surface, keys: *const wl_array) callconv(.c) void {
    _ = keys; // not needed
    pushEvent(data, kb, 1, null, 2, .{ serial, tokenizeFromData(data, @ptrCast(surface)) });
}
fn keyboardLeaveListener(data: ?*anyopaque, kb: *wl_keyboard, serial: u32, surface: *wl_surface) callconv(.c) void {
    pushEvent(data, kb, 2, null, 2, .{ serial, tokenizeFromData(data, @ptrCast(surface)) });
}
fn keyboardKeyListener(data: ?*anyopaque, kb: *wl_keyboard, serial: u32, time: u32, key: u32, state: u32) callconv(.c) void {
    const self: *Connection = @alignCast(@ptrCast(data orelse return));
    if (self.xkb) |*x| {
        _ = xkb().state_update_key(x.state, key + 8, if (state == 1) 1 else 0); // evdev -> xkb offset; 1 = DOWN
    }
    pushEvent(data, kb, 3, null, 4, .{ serial, time, key, state });
}
fn keyboardModifiersListener(data: ?*anyopaque, kb: *wl_keyboard, serial: u32, mods_depressed: u32, mods_latched: u32, mods_locked: u32, group: u32) callconv(.c) void {
    const self: *Connection = @alignCast(@ptrCast(data orelse return));
    if (self.xkb) |*x| {
        _ = xkb().state_update_mask(x.state, mods_depressed, mods_latched, mods_locked, 0, 0, group);
    }
    pushEvent(data, kb, 4, null, 5, .{ serial, mods_depressed, mods_latched, mods_locked, group });
}
fn keyboardRepeatInfoListener(data: ?*anyopaque, kb: *wl_keyboard, rate: i32, delay: i32) callconv(.c) void {
    pushEvent(data, kb, 5, null, 2, .{ @bitCast(rate), @bitCast(delay) });
}
fn pointerEnterListener(data: ?*anyopaque, ptr: *wl_pointer, serial: u32, surface: *wl_surface, x: wl_fixed_t, y: wl_fixed_t) callconv(.c) void {
    pushEvent(data, ptr, 0, null, 4, .{ serial, tokenizeFromData(data, @ptrCast(surface)), @bitCast(x), @bitCast(y) });
}
fn pointerLeaveListener(data: ?*anyopaque, ptr: *wl_pointer, serial: u32, surface: *wl_surface) callconv(.c) void {
    pushEvent(data, ptr, 1, null, 2, .{ serial, tokenizeFromData(data, @ptrCast(surface)) });
}
fn pointerMotionListener(data: ?*anyopaque, ptr: *wl_pointer, time: u32, x: wl_fixed_t, y: wl_fixed_t) callconv(.c) void {
    pushEvent(data, ptr, 2, null, 3, .{ time, @bitCast(x), @bitCast(y) });
}
fn pointerButtonListener(data: ?*anyopaque, ptr: *wl_pointer, serial: u32, time: u32, button: u32, state: u32) callconv(.c) void {
    pushEvent(data, ptr, 3, null, 4, .{ serial, time, button, state });
}
fn pointerAxisListener(data: ?*anyopaque, ptr: *wl_pointer, time: u32, axis: u32, value: wl_fixed_t) callconv(.c) void {
    pushEvent(data, ptr, 4, null, 3, .{ time, axis, @bitCast(value) });
}
fn pointerFrameListener(data: ?*anyopaque, ptr: *wl_pointer) callconv(.c) void {
    pushEvent(data, ptr, 5, null, 0, .{});
}
fn pointerAxisSourceListener(data: ?*anyopaque, ptr: *wl_pointer, source: u32) callconv(.c) void {
    pushEvent(data, ptr, 6, null, 1, .{source});
}
fn pointerAxisStopListener(data: ?*anyopaque, ptr: *wl_pointer, time: u32, axis: u32) callconv(.c) void {
    pushEvent(data, ptr, 7, null, 2, .{ time, axis });
}
fn pointerAxisDiscreteListener(data: ?*anyopaque, ptr: *wl_pointer, axis: u32, discrete: i32) callconv(.c) void {
    pushEvent(data, ptr, 8, null, 2, .{ axis, @as(u32, @bitCast(discrete)) });
}
fn pointerAxisValue120Listener(data: ?*anyopaque, ptr: *wl_pointer, axis: u32, value120: i32) callconv(.c) void {
    pushEvent(data, ptr, 9, null, 2, .{ axis, @as(u32, @bitCast(value120)) });
}
fn pointerAxisRelativeDirectionListener(data: ?*anyopaque, ptr: *wl_pointer, axis: u32, direction: u32) callconv(.c) void {
    pushEvent(data, ptr, 10, null, 2, .{ axis, direction });
}
fn pointerWarpListener(data: ?*anyopaque, ptr: *wl_pointer, time: u32, x: wl_fixed_t, y: wl_fixed_t) callconv(.c) void {
    pushEvent(data, ptr, 11, null, 3, .{ time, @bitCast(x), @bitCast(y) });
}
fn xdgToplevelConfigureBoundsListener(data: ?*anyopaque, t: *xdg_toplevel, width: i32, height: i32) callconv(.c) void {
    pushEvent(data, t, 2, null, 2, .{ @bitCast(width), @bitCast(height) });
}
fn xdgToplevelWmCapabilitiesListener(data: ?*anyopaque, t: *xdg_toplevel, capabilities: *const wl_array) callconv(.c) void {
    _ = capabilities;
    pushEvent(data, t, 3, null, 0, .{});
}
fn dataOfferSourceActionsListener(data: ?*anyopaque, offer: *wl_data_offer, source_actions: u32) callconv(.c) void {
    pushEvent(data, offer, 1, null, 1, .{source_actions});
}
fn dataOfferActionListener(data: ?*anyopaque, offer: *wl_data_offer, action: u32) callconv(.c) void {
    pushEvent(data, offer, 2, null, 1, .{action});
}
fn outputScaleListener(data: ?*anyopaque, output: *wl_output, scale: i32) callconv(.c) void {
    pushEvent(data, output, 3, null, 1, .{ @bitCast(scale) });
}
fn outputDoneListener(data: ?*anyopaque, output: *wl_output) callconv(.c) void {
    pushEvent(data, output, 2, null, 0, .{});
}
fn outputModeListener(data: ?*anyopaque, output: *wl_output, flags: u32, width: i32, height: i32, refresh: i32) callconv(.c) void {
    pushEvent(data, output, 1, null, 4, .{ flags, @bitCast(width), @bitCast(height), @bitCast(refresh) });
}
fn outputGeometryListener(data: ?*anyopaque, output: *wl_output, x: i32, y: i32, physical_width: i32, physical_height: i32, subpixel: i32, make: [*:0]const u8, model: [*:0]const u8, transform: i32) callconv(.c) void {
    _ = make;
    _ = model;
    _ = transform;
    pushEvent(data, output, 0, null, 5, .{ @intCast(x), @intCast(y), @intCast(physical_width), @intCast(physical_height), @intCast(subpixel) });
}
fn outputNameListener(data: ?*anyopaque, output: *wl_output, name: [*:0]const u8) callconv(.c) void {
    _ = name;
    pushEvent(data, output, 4, null, 0, .{});
}
fn outputDescriptionListener(data: ?*anyopaque, output: *wl_output, description: [*:0]const u8) callconv(.c) void {
    _ = description;
    pushEvent(data, output, 5, null, 0, .{});
}
fn xdgWmBasePingListener(data: ?*anyopaque, base: *xdg_wm_base, serial: u32) callconv(.c) void {
    pushEvent(data, base, 0, null, 1, .{serial});
}
fn xdgSurfaceConfigureListener(data: ?*anyopaque, s: *xdg_surface, serial: u32) callconv(.c) void {
    pushEvent(data, s, 0, null, 1, .{serial});
}
fn xdgToplevelConfigureListener(data: ?*anyopaque, t: *xdg_toplevel, width: i32, height: i32, states: *const wl_array) callconv(.c) void {
    _ = states;
    pushEvent(data, t, 0, null, 2, .{ @bitCast(width), @bitCast(height) });
}
fn xdgToplevelCloseListener(data: ?*anyopaque, t: *xdg_toplevel) callconv(.c) void {
    pushEvent(data, t, 1, null, 0, .{});
}
fn dataDeviceDataOfferListener(data: ?*anyopaque, dd: *wl_data_device, offer: *wl_data_offer) callconv(.c) void {
    const token = tokenizeFromData(data, @ptrCast(offer));
    // listen for its "offer" mime events immediately
    _ = w.wl_proxy_add_listener(offer, @ptrCast(&WL_DATA_OFFER_LISTENER), data);
    pushEvent(data, dd, 0, null, 1, .{token});
}
fn dataDeviceEnterListener(data: ?*anyopaque, dd: *wl_data_device, serial: u32, surface: *wl_surface, x: wl_fixed_t, y: wl_fixed_t, offer: ?*wl_data_offer) callconv(.c) void {
    pushEvent(data, dd, 1, null, 5, .{ serial, tokenizeFromData(data, @ptrCast(surface)), @bitCast(x), @bitCast(y), if (offer) |o| tokenizeFromData(data, @ptrCast(o)) else 0 });
}
fn dataDeviceLeaveListener(data: ?*anyopaque, dd: *wl_data_device) callconv(.c) void {
    pushEvent(data, dd, 2, null, 0, .{});
}
fn dataDeviceMotionListener(data: ?*anyopaque, dd: *wl_data_device, time: u32, x: wl_fixed_t, y: wl_fixed_t) callconv(.c) void {
    pushEvent(data, dd, 3, null, 3, .{ time, @bitCast(x), @bitCast(y) });
}
fn dataDeviceDropListener(data: ?*anyopaque, dd: *wl_data_device) callconv(.c) void {
    pushEvent(data, dd, 4, null, 0, .{});
}
fn dataDeviceSelectionListener(data: ?*anyopaque, dd: *wl_data_device, offer: ?*wl_data_offer) callconv(.c) void {
    pushEvent(data, dd, 5, null, 1, .{ if (offer) |o| tokenizeFromData(data, @ptrCast(o)) else 0 });
}
fn dataOfferOfferListener(data: ?*anyopaque, offer: *wl_data_offer, mime_type: [*:0]const u8) callconv(.c) void {
    const s = std.mem.span(mime_type);
    const self: *Connection = @alignCast(@ptrCast(data orelse return));
    var e = Event{ .sender = self.tokenize(@ptrCast(offer)), .opcode = 0, .fd = null };
    std.mem.writeInt(u32, e._buffer[0..4], @intCast(s.len + 1), .little);
    @memcpy(e._buffer[4..][0..s.len], s);
    e._buffer[4 + s.len] = 0;
    e.payload_len = 4 + s.len + 1;
    self.events.append(self.alloc, e) catch {};
}
fn dataSourceSendListener(data: ?*anyopaque, source: *wl_data_source, mime_type: [*:0]const u8, fd: i32) callconv(.c) void {
    _ = mime_type;
    pushEvent(data, source, 1, fd, 0, .{});
}
fn dataSourceTargetListener(data: ?*anyopaque, source: *wl_data_source, mime_type: ?[*:0]const u8) callconv(.c) void {
    _ = mime_type;
    pushEvent(data, source, 0, null, 0, .{});
}
fn dataSourceCancelledListener(data: ?*anyopaque, source: *wl_data_source) callconv(.c) void {
    pushEvent(data, source, 2, null, 0, .{});
}
fn dataSourceDndDropPerformedListener(data: ?*anyopaque, source: *wl_data_source) callconv(.c) void {
    pushEvent(data, source, 3, null, 0, .{});
}
fn dataSourceDndFinishedListener(data: ?*anyopaque, source: *wl_data_source) callconv(.c) void {
    pushEvent(data, source, 4, null, 0, .{});
}
fn dataSourceActionListener(data: ?*anyopaque, source: *wl_data_source, action: u32) callconv(.c) void {
    pushEvent(data, source, 5, null, 1, .{action});
}

// ---- listener registration (runtime calls these right after creating proxies)

fn reg(conn: *Connection, token: u32, listener: *const anyopaque) void {
    const proxy: *wl_proxy = @ptrCast(conn.proxyFromToken(token) orelse return);
    if (w.wl_proxy_add_listener(proxy, listener, @ptrCast(conn)) != 0) {
        std.debug.print("cipher: wl_proxy_add_listener failed for token {d}\n", .{token});
    }
}

pub fn listenWmBase(conn: *Connection, wm_base: u32) void {
    reg(conn, wm_base, @ptrCast(&XDG_WM_BASE_LISTENER));
}

pub fn listenXdgSurface(conn: *Connection, xs: u32) void {
    reg(conn, xs, @ptrCast(&XDG_SURFACE_LISTENER));
}

pub fn listenToplevel(conn: *Connection, toplevel: u32) void {
    reg(conn, toplevel, @ptrCast(&XDG_TOPLEVEL_LISTENER));
}

pub fn listenSeat(conn: *Connection, seat: u32) void {
    reg(conn, seat, @ptrCast(&WL_SEAT_LISTENER));
}

pub fn listenKeyboard(conn: *Connection, keyboard: u32) void {
    reg(conn, keyboard, @ptrCast(&WL_KEYBOARD_LISTENER));
}

pub fn listenPointer(conn: *Connection, pointer: u32) void {
    reg(conn, pointer, @ptrCast(&WL_POINTER_LISTENER));
}

pub fn listenOutput(conn: *Connection, output: u32) void {
    reg(conn, output, @ptrCast(&WL_OUTPUT_LISTENER));
}

pub fn listenShm(conn: *Connection, shm: u32) void {
    reg(conn, shm, @ptrCast(&WL_SHM_LISTENER));
}

pub fn listenDataDevice(conn: *Connection, dd: u32) void {
    reg(conn, dd, @ptrCast(&WL_DATA_DEVICE_LISTENER));
}

pub fn listenDataOffer(conn: *Connection, offer: u32) void {
    reg(conn, offer, @ptrCast(&WL_DATA_OFFER_LISTENER));
}

pub fn listenDataSource(conn: *Connection, source: u32) void {
    reg(conn, source, @ptrCast(&WL_DATA_SOURCE_LISTENER));
}

// ====================================================================
// smoke tests (no live compositor required)
// ====================================================================

test "event payload read helpers" {
    var e = Event{};
    std.mem.writeInt(u32, e._buffer[0..4], 0xffffffff, .little);
    e.payload_len = 4;
    try std.testing.expectEqual(@as(u32, 0xffffffff), e.read32(0));
    try std.testing.expectEqual(@as(i32, -1), e.readI32(0));
}

test "shm buffer allocate and deinit" {
    var shm = try ShmBuffer.allocate(64, 64);
    defer shm.deinit();
    try std.testing.expectEqual(64 * 4, shm.stride);
    try std.testing.expect(shm.pixels.len == 64 * 64 * 4);
}
