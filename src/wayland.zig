//! Cipher's Wayland windowing substrate: a handwritten wire-protocol client.
//! No library dependency — no GTK, no libwayland, no libxcb — only the
//! kernel's socket syscalls and a memfd for shared memory. Marshaling
//! follows the upstream protocol XML by hand:
//!   sender u32, header u32 = (size << 16 | opcode)
//!   arguments are u32/i32; strings and arrays are u32-length prefixed,
//!   NUL-terminated / zero-padded to 4-byte boundaries;
//!   fds travel as SCM_RIGHTS control messages, never payload bytes.
//!
//! wl_display is implicitly object id 1; the `Ids` allocator hands out every
//! other object id starting at 2.
const std = @import("std");

pub const Error = error{
    ConnectFailed,
    SocketFailed,
    WriteFailed,
    ReadFailed,
    ProtocolError,
    OutOfMemory,
    MapFailed,
};

const HEADER = 8;
const MAX_MESSAGE = 8192;
pub const WL_DISPLAY: u32 = 1;

pub const Cursor = struct {
    bytes: [MAX_MESSAGE]u8 = undefined,
    len: usize = 0,

    pub fn writeU32(self: *Cursor, value: u32) void {
        std.mem.writeInt(u32, self.bytes[self.len..][0..4], value, .little);
        self.len += 4;
    }

    pub fn writeI32(self: *Cursor, value: i32) void {
        self.writeU32(@bitCast(value));
    }

    pub fn str(self: *Cursor, value: []const u8) void {
        self.writeU32(@intCast(value.len + 1));
        @memcpy(self.bytes[self.len..][0..value.len], value);
        self.bytes[self.len + value.len] = 0;
        self.len += value.len + 1;
        while (self.len % 4 != 0) : (self.len += 1) self.bytes[self.len] = 0;
    }

    pub fn slice(self: *const Cursor) []const u8 {
        return self.bytes[0..self.len];
    }
};

pub const Event = struct {
    sender: u32 = 0,
    opcode: u16 = 0,
    buf: [MAX_MESSAGE]u8 = undefined,
    len: usize = 0,

    pub fn payload(self: *const Event) []const u8 {
        return self.buf[0..self.len];
    }

    pub fn read32(self: *const Event, index: usize) u32 {
        return std.mem.readInt(u32, self.payload()[index * 4 ..][0..4], .little);
    }
};

pub const ObjectIds = struct {
    registry: ?u32 = null,
    compositor: ?u32 = null,
    shm: ?u32 = null,
    seat: ?u32 = null,
    wm_base: ?u32 = null,
    surface: ?u32 = null,
    shm_pool: ?u32 = null,
    buffer: ?u32 = null,
    xdg_surface: ?u32 = null,
    toplevel: ?u32 = null,
    frame_callback: ?u32 = null,
    sync_callback: ?u32 = null,
    next_id: u32 = 2,

    pub fn new(self: *ObjectIds) u32 {
        const id = self.next_id;
        self.next_id += 1;
        return id;
    }
};

pub const ShmBuffer = struct {
    width: u32,
    height: u32,
    pixels: []align(4096) u8,
    fd: i32,

    pub fn allocate(width: u32, height: u32) !ShmBuffer {
        const stride = width * 4;
        const size: usize = @intCast(stride * height);

        const memfd_rc = std.os.linux.memfd_create("cipher-shm", 1); // MFD_CLOEXEC
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

        return .{
            .width = width,
            .height = height,
            .pixels = mapped,
            .fd = fd,
        };
    }

    pub fn deinit(self: *ShmBuffer) void {
        std.posix.munmap(self.pixels);
        _ = std.os.linux.close(self.fd);
    }
};

pub const Connection = struct {
    fd: i32,

    pub fn connect(runtime_dir: []const u8, display: []const u8) !Connection {
        const path = try std.fmt.allocPrintSentinel(std.heap.page_allocator, "{s}/{s}", .{ runtime_dir, display }, 0);
        defer std.heap.page_allocator.free(path);

        const socket_rc = std.os.linux.socket(std.os.linux.AF.UNIX, std.os.linux.SOCK.STREAM | std.os.linux.SOCK.CLOEXEC, 0);
        if (@as(i64, @bitCast(socket_rc)) < 0) return Error.SocketFailed;
        const fd: i32 = @intCast(socket_rc);
        errdefer _ = std.os.linux.close(fd);

        var address: std.os.linux.sockaddr.un = undefined;
        @memset(std.mem.asBytes(&address), 0);
        address.family = std.os.linux.AF.UNIX;
        @memcpy(address.path[0..path.len], path);

        const connect_rc = std.os.linux.connect(fd, @ptrCast(&address), @sizeOf(std.os.linux.sockaddr.un));
        if (connect_rc != 0) return Error.ConnectFailed;

        return .{ .fd = fd };
    }

    pub fn disconnect(self: *Connection) void {
        _ = std.os.linux.close(self.fd);
    }

    pub fn send(self: *Connection, sender: u32, opcode: u16, payload: []const u8) !void {
        var message: [MAX_MESSAGE]u8 = undefined;
        std.mem.writeInt(u32, message[0..4], sender, .little);
        std.mem.writeInt(u32, message[4..8], (@as(u32, @intCast(HEADER + payload.len)) << 16) | opcode, .little);
        @memcpy(message[HEADER..][0..payload.len], payload);
        try writeAll(self.fd, message[0 .. HEADER + payload.len]);
    }

    pub fn sendFd(self: *Connection, sender: u32, opcode: u16, payload: []const u8, fd: i32) !void {
        var message: [MAX_MESSAGE]u8 = undefined;
        std.mem.writeInt(u32, message[0..4], sender, .little);
        std.mem.writeInt(u32, message[4..8], (@as(u32, @intCast(HEADER + payload.len)) << 16) | opcode, .little);
        @memcpy(message[HEADER..][0..payload.len], payload);
        const total = HEADER + payload.len;

        var control: [64]u8 align(@alignOf(usize)) = undefined;
        @memset(&control, 0);

        const cmsghdr_size = @sizeOf(std.os.linux.cmsghdr);
        const cm: *align(@alignOf(usize)) std.os.linux.cmsghdr = @ptrCast(@alignCast(&control));
        cm.len = cmsghdr_size + @sizeOf(i32);
        cm.level = std.os.linux.SOL.SOCKET;
        cm.type = std.os.linux.SCM.RIGHTS;
        const fd_bytes = std.mem.asBytes(&fd);
        @memcpy(control[cmsghdr_size..][0..@sizeOf(i32)], fd_bytes);
        const controllen = std.mem.alignForward(usize, cmsghdr_size + @sizeOf(i32), @sizeOf(usize));

        const iovecs = [_]std.posix.iovec_const{
            .{ .base = &message, .len = total },
        };
        const msg = std.os.linux.msghdr_const{
            .name = null,
            .namelen = 0,
            .iov = @ptrCast(&iovecs),
            .iovlen = 1,
            .control = &control,
            .controllen = controllen,
            .flags = 0,
        };
        const rc = std.os.linux.sendmsg(self.fd, @ptrCast(&msg), 0);
        if (@as(i64, @bitCast(rc)) < 0) return Error.WriteFailed;
    }

    pub fn recv(self: *Connection, event: *Event) !void {
        var header: [HEADER]u8 = undefined;
        try readExact(self.fd, &header);
        event.sender = std.mem.readInt(u32, header[0..4], .little);
        const size_opcode = std.mem.readInt(u32, header[4..8], .little);
        const size = size_opcode >> 16;
        event.opcode = @truncate(size_opcode);
        const payload_len = size - HEADER;
        if (payload_len > MAX_MESSAGE) return Error.ProtocolError;
        try readExact(self.fd, event.buf[0..payload_len]);
        event.len = payload_len;
    }
};

fn writeAll(fd: i32, buffer: []const u8) !void {
    var written: usize = 0;
    while (written < buffer.len) {
        const rc = std.os.linux.write(fd, buffer[written..].ptr, buffer[written..].len);
        if (@as(i64, @bitCast(rc)) < 0) return Error.WriteFailed;
        written += @intCast(rc);
    }
}

fn readExact(fd: i32, buffer: []u8) !void {
    var read: usize = 0;
    while (read < buffer.len) {
        const rc = std.os.linux.read(fd, buffer[read..].ptr, buffer[read..].len);
        if (@as(i64, @bitCast(rc)) < 0) return Error.ReadFailed;
        read += @intCast(rc);
    }
}

test "a payload round-trips u32 and strings through the wire" {
    var cursor = Cursor{};
    cursor.writeU32(0xdeadbeef);
    cursor.str("wl_compositor");
    cursor.writeI32(-42);

    const wire = cursor.slice();
    const first = std.mem.readInt(u32, wire[0..4], .little);
    try std.testing.expectEqual(@as(u32, 0xdeadbeef), first);

    const length = std.mem.readInt(u32, wire[4..8], .little);
    try std.testing.expectEqualStrings("wl_compositor", wire[8..][0 .. length - 1]);
    var offset: usize = 8 + length;
    while (offset % 4 != 0) offset += 1;

    const neg = std.mem.readInt(i32, wire[offset..][0..4], .little);
    try std.testing.expectEqual(@as(i32, -42), neg);
}
