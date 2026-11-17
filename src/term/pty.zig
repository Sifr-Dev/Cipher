//! PTY spawn: openpty + fork + login_tty + exec. Master fd is nonblocking.
//! Pure libc/syscalls — no libutil dependency.
const std = @import("std");

// glibc >= 2.34 ships these in libc proper (formerly libutil); we link libc.
extern "c" fn openpty(amaster: *i32, aslave: *i32, name: ?[*:0]u8, termp: ?*anyopaque, winp: ?*const anyopaque) c_int;
extern "c" fn login_tty(fd: i32) c_int;
extern "c" fn execvpe(file: [*c]const u8, argv: [*c]const [*c]const u8, envp: [*c]const [*c]const u8) c_int;
extern "c" fn execvp(file: [*c]const u8, argv: [*c]const [*c]const u8) c_int;

pub fn nowNs() i64 {
    var ts: std.os.linux.timespec = undefined;
    _ = std.os.linux.clock_gettime(.MONOTONIC, &ts);
    return ts.sec * 1_000_000_000 + ts.nsec;
}

pub const Pty = struct {
    master_fd: i32,
    slave_fd: i32,
    pid: std.posix.pid_t,
    exited: bool = false,
    exit_status: c_int = 0,

    pub const SpawnOptions = struct {
        cols: u32 = 80,
        rows: u32 = 24,
        cwd: ?[]const u8 = null,
        env: ?[]const []const u8 = null, // null = inherit environ
    };

    /// Spawn a command in a new pty. argv[0] is the program.
    pub fn spawn(allocator: std.mem.Allocator, argv: []const []const u8, opts: SpawnOptions) !Pty {
        var master: i32 = undefined;
        var slave: i32 = undefined;
        var winsize = std.posix.winsize{
            .row = @intCast(opts.rows),
            .col = @intCast(opts.cols),
            .xpixel = 0,
            .ypixel = 0,
        };
        const rc = openpty(&master, &slave, null, null, @ptrCast(&winsize));
        if (rc != 0) return error.OpenptyFailed;
        errdefer {
            _ = std.c.close(master);
            _ = std.c.close(slave);
        }

        const pid_rc = std.os.linux.fork();
        if (@as(i64, @bitCast(pid_rc)) < 0) return error.ForkFailed;
        const pid: std.posix.pid_t = @intCast(pid_rc);
        if (pid == 0) {
            // child
            _ = std.c.close(master);
            if (login_tty(slave) != 0) _ = std.os.linux.exit(127);
            if (opts.cwd) |cwd| { var z: [4096]u8 = undefined; @memcpy(z[0..cwd.len], cwd); z[cwd.len] = 0; _ = std.os.linux.chdir(@ptrCast(z[0..cwd.len].ptr)); }
            // build C argv / envp
            const cargv = try allocator.allocSentinel([*c]u8, argv.len, @as([*c]u8, null));
            defer allocator.free(cargv);
            for (argv, 0..) |a, i| {
                const buf = try allocator.allocSentinel(u8, a.len, 0);
                @memcpy(buf, a);
                cargv[i] = @ptrCast(buf.ptr);
            }
            var cenvp: [*c]const [*c]const u8 = null;
            if (opts.env) |env| {
                const ce = try allocator.allocSentinel([*c]const u8, env.len, @as([*c]const u8, null));
                for (env, 0..) |e, i| {
                    const buf = try allocator.allocSentinel(u8, e.len, 0);
                    @memcpy(buf, e);
                    ce[i] = @ptrCast(buf.ptr);
                }
                cenvp = @ptrCast(ce.ptr);
            }
            if (cenvp) |ce| {
                _ = execvpe(cargv[0], @ptrCast(cargv.ptr), ce);
            } else {
                _ = execvp(cargv[0], @ptrCast(cargv.ptr));
            }
            _ = std.os.linux.exit(127);
        }
        // parent
        _ = std.c.close(slave);
        // nonblocking master
        const flags = std.os.linux.fcntl(master, std.os.linux.F.GETFL, 0);
        if (@as(i64, @bitCast(flags)) >= 0)
            _ = std.os.linux.fcntl(master, std.os.linux.F.SETFL, flags | 0x800);
        return .{ .master_fd = master, .slave_fd = -1, .pid = pid };
    }

    /// Nonblocking read; error.WouldBlock when no data.
    pub fn read(self: *const Pty, buf: []u8) !usize {
        while (true) {
            const rc = std.os.linux.read(self.master_fd, buf.ptr, buf.len);
            if (@as(i64, @bitCast(rc)) < 0) {
                const err = std.os.linux.errno(rc);
                if (err == .AGAIN) return error.WouldBlock;
                if (err == .INTR) continue;
                if (err == .IO) return 0; // EIO: child closed the pty
                return error.ReadFailed;
            }
            return @intCast(rc);
        }
    }

    pub fn write(self: *const Pty, data: []const u8) !void {
        var off: usize = 0;
        while (off < data.len) {
            const rc = std.os.linux.write(self.master_fd, data[off..].ptr, data.len - off);
            if (@as(i64, @bitCast(rc)) < 0) {
                const err = std.os.linux.errno(rc);
                if (err == .AGAIN or err == .INTR) {
                    var fds = [_]std.os.linux.pollfd{.{ .fd = self.master_fd, .events = std.os.linux.POLL.OUT, .revents = 0 }};
                    _ = std.os.linux.poll(&fds, 1, 1000);
                    continue;
                }
                return error.WriteFailed;
            }
            off += @intCast(rc);
        }
    }

    pub fn resize(self: *const Pty, cols: u32, rows: u32) void {
        var ws = std.posix.winsize{
            .row = @intCast(rows),
            .col = @intCast(cols),
            .xpixel = 0,
            .ypixel = 0,
        };
        _ = std.os.linux.ioctl(self.master_fd, std.os.linux.T.IOCSWINSZ, @intFromPtr(&ws));
    }

    /// Check (nonblocking) whether the child exited; reaps it if so.
    pub fn pollExit(self: *Pty) void {
        if (self.exited) return;
        var status: c_int = 0;
        const rc = std.os.linux.waitpid(self.pid, &status, std.os.linux.W.NOHANG);
        if (@as(i64, @bitCast(rc)) > 0) {
            self.exited = true;
            self.exit_status = status;
        }
    }

    pub fn kill(self: *Pty) void {
        self.pollExit();
        if (!self.exited) {
            _ = std.os.linux.kill(self.pid, std.os.linux.SIG.HUP);
            _ = std.os.linux.kill(self.pid, std.os.linux.SIG.KILL);
        }
        var status: c_int = 0;
        _ = std.os.linux.waitpid(self.pid, &status, 0);
        self.exited = true;
        _ = std.c.close(self.master_fd);
    }

    pub fn deinit(self: *Pty) void {
        if (!self.exited) self.kill();
    }
};

test "pty: spawn cat, write, read echo back" {
    const alloc = std.testing.allocator;
    var pty = try Pty.spawn(alloc, &[_][]const u8{ "/bin/cat", "-" }, .{});
    defer pty.deinit();
    try pty.write("hello pty\n");
    var buf: [256]u8 = undefined;
    var got = std.ArrayList(u8).empty;
    defer got.deinit(alloc);
    const deadline = nowNs() + 3 * std.time.ns_per_s;
    while (got.items.len < "hello pty\n".len and nowNs() < deadline) {
        const n = pty.read(&buf) catch continue;
        if (n == 0) break;
        try got.appendSlice(alloc, buf[0..n]);
    }
    // tty echo + ONLCR: output contains the line (possibly as \r\n and twice)
    try std.testing.expect(std.mem.indexOf(u8, got.items, "hello pty") != null);
    std.debug.print("PTY_ECHO_OK got={d} bytes containing 'hello pty'\n", .{got.items.len});
}

test "pty: run command and capture output + exit" {
    const alloc = std.testing.allocator;
    var pty = try Pty.spawn(alloc, &[_][]const u8{ "/bin/sh", "-c", "printf 'out123\\n'; exit 42" }, .{});
    var buf: [256]u8 = undefined;
    var got = std.ArrayList(u8).empty;
    defer got.deinit(alloc);
    const deadline = nowNs() + 3 * std.time.ns_per_s;
    while (nowNs() < deadline) {
        pty.pollExit();
        if (pty.exited) {
            // drain remaining
            while (true) {
                const n = pty.read(&buf) catch break;
                if (n == 0) break;
                try got.appendSlice(alloc, buf[0..n]);
            }
            break;
        }
        const n = pty.read(&buf) catch continue;
        if (n > 0) try got.appendSlice(alloc, buf[0..n]);
    }
    try std.testing.expect(pty.exited);
    try std.testing.expect(std.mem.indexOf(u8, got.items, "out123") != null);
    // exit status 42 -> WEXITSTATUS
    const code = std.os.linux.W.EXITSTATUS(@as(u32, @bitCast(pty.exit_status)));
    try std.testing.expectEqual(@as(u8, 42), @as(u8, code));
    std.debug.print("PTY_RUN_OK out='{s}' exit={d}\n", .{ got.items, code });
}
