//! snapdiff — snapshot contract gate for rendered frames.
//!
//! The software-shm path is byte-deterministic on this machine (verified
//! 2026-11-19: identical md5/sha256 across runs of `cipher-hello` with
//! CIPHER_FORCE_SOFTWARE=1). This tool hashes a dumped frame and compares
//! it against a checked-in golden hash, so a rendering regression fails
//! loudly instead of shipping silently.
//!
//! Usage:
//!   snapdiff check <frame.ppm> <golden-file>   compare; exits 0 on match, 1 on mismatch
//!   snapdiff write <frame.ppm> <golden-file>   record the current hash as the new golden
//!
//! Golden files live in tests/golden/. When the font or rasterizer changes
//! intentionally, regenerate the golden with `snapdiff write` and review the
//! frame by eye before committing.
const std = @import("std");

const usage =
    \\snapdiff — snapshot contract gate for rendered frames
    \\
    \\  snapdiff check <frame.ppm> <golden-file>   exit 0 ok, 1 mismatch
    \\  snapdiff write <frame.ppm> <golden-file>   record current hash as golden
    \\
;

fn fileBytes(path: []const u8) ![]u8 {
    const fd = try std.posix.openat(std.posix.AT.FDCWD, path, .{ .ACCMODE = .RDONLY }, 0);
    defer _ = std.c.close(fd);
    var out = std.ArrayList(u8).empty;
    errdefer out.deinit(std.heap.page_allocator);
    var buf: [65536]u8 = undefined;
    while (true) {
        const n = std.posix.read(fd, &buf) catch break;
        if (n == 0) break;
        try out.appendSlice(std.heap.page_allocator, buf[0..n]);
    }
    return out.toOwnedSlice(std.heap.page_allocator);
}

fn sha256Hex(bytes: []const u8) [64]u8 {
    var digest: [32]u8 = undefined;
    std.crypto.hash.sha2.Sha256.hash(bytes, &digest, .{});
    var out: [64]u8 = undefined;
    for (digest, 0..) |b, i| {
        out[i * 2] = "0123456789abcdef"[b >> 4];
        out[i * 2 + 1] = "0123456789abcdef"[b & 0xf];
    }
    return out;
}

fn readGoldenHash(path: []const u8) ![64]u8 {
    const fd = try std.posix.openat(std.posix.AT.FDCWD, path, .{ .ACCMODE = .RDONLY }, 0);
    defer _ = std.c.close(fd);
    var buf: [8192]u8 = undefined;
    var n: usize = 0;
    while (n < buf.len) {
        const r = std.posix.read(fd, buf[n..]) catch break;
        if (r == 0) break;
        n += r;
    }
    const text = buf[0..n];
    // The file is "<hash>  <anything>" — first whitespace-delimited token is the hash.
    var it = std.mem.tokenizeAny(u8, text, " \n\t\r");
    const tok = it.next() orelse return error.EmptyGolden;
    if (tok.len != 64) return error.BadGolden;
    var out: [64]u8 = undefined;
    @memcpy(&out, tok);
    return out;
}

pub fn main(init: std.process.Init.Minimal) !void {
    const argv = init.args.vector;
    var args = std.ArrayList([]const u8).empty;
    defer args.deinit(std.heap.page_allocator);
    for (argv) |a| try args.append(std.heap.page_allocator, std.mem.span(a));
    const a = args.items;
    if (a.len != 4) {
        std.debug.print("{s}", .{usage});
        std.process.exit(2);
    }
    const mode = a[1];
    const frame = a[2];
    const golden = a[3];

    const bytes = try fileBytes(frame);
    defer std.heap.page_allocator.free(bytes);
    const h = sha256Hex(bytes);

    if (std.mem.eql(u8, mode, "check")) {
        const gh = readGoldenHash(golden) catch |e| {
            std.debug.print("snapdiff: cannot read golden {s}: {s}\n", .{ golden, @errorName(e) });
            std.process.exit(1);
        };
        if (std.mem.eql(u8, &h, &gh)) {
            std.debug.print("SNAP_OK {s} == golden\n", .{frame});
            return;
        }
        std.debug.print("SNAP_FAIL {s}\n  frame:  {s}\n  golden: {s}\n", .{ frame, h, gh });
        std.process.exit(1);
    } else if (std.mem.eql(u8, mode, "write")) {
        const text = try std.fmt.allocPrint(std.heap.page_allocator, "{s}  {s}\n", .{ h, std.fs.path.basename(frame) });
        defer std.heap.page_allocator.free(text);
        const fd = try std.posix.openat(std.posix.AT.FDCWD, golden, .{ .ACCMODE = .WRONLY, .CREAT = true, .TRUNC = true }, 0o644);
        defer _ = std.c.close(fd);
        var off: usize = 0;
        while (off < text.len) {
            const n = std.os.linux.write(fd, text[off..].ptr, text.len - off);
            if (std.posix.errno(n) != .SUCCESS) return error.WriteFailed;
            if (n == 0) return error.WriteFailed;
            off += @intCast(n);
        }
        std.debug.print("SNAP_GOLDEN {s} <- {s}\n", .{ golden, h });
        return;
    } else {
        std.debug.print("snapdiff: unknown mode '{s}'\n{s}", .{ mode, usage });
        std.process.exit(2);
    }
}
