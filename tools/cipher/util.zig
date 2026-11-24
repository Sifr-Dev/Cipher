//! Small platform helpers shared by the cipher CLI — deliberately thin,
//! syscall-level, no framework dependency (a CLI must not pull a UI runtime).
const std = @import("std");

/// getenv with a stack sentinel conversion.
pub fn env(name: []const u8) ?[]const u8 {
    var buf: [512]u8 = undefined;
    if (name.len >= buf.len) return null;
    @memcpy(buf[0..name.len], name);
    buf[name.len] = 0;
    const p = std.c.getenv(@ptrCast(&buf)) orelse return null;
    return std.mem.span(p);
}

/// True if `path` exists and is a regular file or directory we can open.
pub fn exists(path: []const u8) bool {
    const fd = std.posix.openat(std.posix.AT.FDCWD, path, .{ .ACCMODE = .RDONLY }, 0) catch return false;
    _ = std.c.close(fd);
    return true;
}

pub fn isDir(path: []const u8) bool {
    const fd = std.posix.openat(std.posix.AT.FDCWD, path, .{ .ACCMODE = .RDONLY, .DIRECTORY = true }, 0) catch return false;
    _ = std.c.close(fd);
    return true;
}

/// Write a file from the repo root or the user's cwd.
pub fn writeFile(path: []const u8, contents: []const u8) !void {
    const fd = try std.posix.openat(std.posix.AT.FDCWD, path, .{ .ACCMODE = .WRONLY, .CREAT = true, .TRUNC = true }, 0o644);
    defer _ = std.c.close(fd);
    var off: usize = 0;
    while (off < contents.len) {
        const n = std.os.linux.write(fd, contents[off..].ptr, contents.len - off);
        if (std.posix.errno(n) != .SUCCESS) return error.WriteFailed;
        if (n == 0) return error.WriteFailed;
        off += @intCast(n);
    }
}

/// Create one directory level (parent must exist). EEXIST is not an error.
pub fn makeDir(path: []const u8) !void {
    var buf: [4096]u8 = undefined;
    if (path.len >= buf.len) return error.NameTooLong;
    @memcpy(buf[0..path.len], path);
    buf[path.len] = 0;
    const rc = std.os.linux.mkdir(@ptrCast(&buf), 0o755);
    switch (std.posix.errno(rc)) {
        .SUCCESS, .EXIST => {},
        else => return error.MakeDirFailed,
    }
}

/// Locate `zig`: $ZIG if set and executable-looking, else first "zig" on $PATH.
pub fn findZig(buf: []u8) ?[]const u8 {
    if (env("ZIG")) |z| {
        if (exists(z)) return z;
    }
    const path = env("PATH") orelse return null;
    var it = std.mem.splitScalar(u8, path, ':');
    while (it.next()) |dir| {
        const joined = std.fmt.bufPrint(buf, "{s}/zig", .{dir}) catch continue;
        if (exists(joined)) return joined;
    }
    return null;
}

/// fork+exec with inherited stdio; returns the child's exit code.
pub fn runInherit(program: []const u8, args: []const []const u8) !u8 {
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    const pid = std.os.linux.fork();
    if (@as(i64, @bitCast(pid)) < 0) return error.ForkFailed;
    const child = @as(std.posix.pid_t, @intCast(pid));
    if (child == 0) {
        const argv = alloc.allocSentinel([*c]const u8, args.len + 1, @as([*c]const u8, null)) catch std.os.linux.exit(127);
        argv[0] = allocSentinelZ(alloc, program) catch std.os.linux.exit(127);
        for (args, 0..) |a, i| {
            argv[i + 1] = allocSentinelZ(alloc, a) catch std.os.linux.exit(127);
        }
        const rc = std.c.execve(@ptrCast(argv[0]), @ptrCast(argv.ptr), @ptrCast(std.c.environ));
        _ = rc;
        _ = std.os.linux.exit(127);
    }
    var status: c_int = 0;
    const got = std.c.waitpid(child, &status, 0);
    if (got < 0) return error.WaitFailed;
    if ((status & 0x7f) == 0) return @intCast((status >> 8) & 0xff); // exited
    return @intCast(128 + (status & 0x7f)); // killed by signal
}

/// fork+exec with piped stdout/stderr; captures up to `max` bytes.
pub fn runCapture(alloc: std.mem.Allocator, program: []const u8, args: []const []const u8, max: usize) ![]u8 {
    var pfd: [2]i32 = undefined;
    const rc = std.os.linux.pipe2(@ptrCast(&pfd), .{ .CLOEXEC = true });
    if (std.posix.errno(rc) != .SUCCESS) return error.PipeFailed;

    const pid = std.os.linux.fork();
    if (@as(i64, @bitCast(pid)) < 0) {
        _ = std.c.close(pfd[0]);
        _ = std.c.close(pfd[1]);
        return error.ForkFailed;
    }
    const child = @as(std.posix.pid_t, @intCast(pid));
    if (child == 0) {
        _ = std.c.close(pfd[0]);
        _ = std.os.linux.dup2(pfd[1], 1);
        _ = std.os.linux.dup2(pfd[1], 2);
        var argv_buf = std.heap.ArenaAllocator.init(std.heap.page_allocator);
        const a2 = argv_buf.allocator();
        const argv = a2.allocSentinel([*c]const u8, args.len + 1, @as([*c]const u8, null)) catch std.os.linux.exit(127);
        argv[0] = allocSentinelZ(a2, program) catch std.os.linux.exit(127);
        for (args, 0..) |a, i| {
            argv[i + 1] = allocSentinelZ(a2, a) catch std.os.linux.exit(127);
        }
        _ = std.c.execve(@ptrCast(argv[0]), @ptrCast(argv.ptr), @ptrCast(std.c.environ));
        _ = std.os.linux.exit(127);
    }
    _ = std.c.close(pfd[1]);
    var out = std.ArrayList(u8).empty;
    errdefer out.deinit(alloc);
    var buf: [4096]u8 = undefined;
    while (out.items.len < max) {
        const n = std.posix.read(pfd[0], buf[0..@min(buf.len, max - out.items.len)]) catch |e| switch (e) {
            error.WouldBlock => break,
            else => break,
        };
        if (n == 0) break;
        try out.appendSlice(alloc, buf[0..n]);
    }
    _ = std.c.close(pfd[0]);
    var status: c_int = 0;
    _ = std.c.waitpid(child, &status, 0);
    return out.toOwnedSlice(alloc);
}

fn allocSentinelZ(alloc: std.mem.Allocator, s: []const u8) ![*c]const u8 {
    const b = try alloc.dupeSentinel(u8, s, 0);
    return b.ptr;
}

test "process helpers preserve argv and capture output" {
    const rc = try runInherit("/bin/sh", &.{ "-c", "exit 23" });
    try std.testing.expectEqual(@as(u8, 23), rc);
    const out = try runCapture(std.testing.allocator, "/bin/sh", &.{ "-c", "printf process-ok" }, 64);
    defer std.testing.allocator.free(out);
    try std.testing.expectEqualStrings("process-ok", out);
}
