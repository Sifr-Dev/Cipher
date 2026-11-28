//! cipher — the command-line tool for the cipher framework.
//! Apps in cipher need two things: zig, and this framework. This tool
//! scaffolds an app, wraps zig build/run, and checks the machine.
const std = @import("std");
const util = @import("util.zig");
const scaffold = @import("scaffold.zig");
const doctor = @import("doctor.zig");

pub const version = "0.1.0";

const usage =
    \\cipher — native desktop apps in zig, zero install footstep
    \\
    \\  cipher new <name> [--cipher PATH]   scaffold a runnable app
    \\  cipher build [ARGS…]                zig build ARGS
    \\  cipher run [ARGS…]                  zig build run -- ARGS
    \\  cipher doctor                       check zig + Wayland + Vulkan + fonts
    \\  cipher version                      print version
    \\
    \\Docs: https://github.com/Sifr-Dev/Phantom
    \\
;

pub fn main(init: std.process.Init.Minimal) !void {
    const alloc = std.heap.page_allocator;
    var argv = std.ArrayList([]const u8).empty;
    defer argv.deinit(alloc);
    for (init.args.vector) |a| try argv.append(alloc, std.mem.span(a));

    const args = argv.items;
    const cmd: []const u8 = if (args.len > 1) args[1] else "help";

    if (std.mem.eql(u8, cmd, "new")) {
        std.process.exit(try scaffold.run(alloc, args[2..]));
    } else if (std.mem.eql(u8, cmd, "build")) {
        std.process.exit(try runZig(args[2..], &.{"build"}));
    } else if (std.mem.eql(u8, cmd, "run")) {
        std.process.exit(try runZig(args[2..], &.{ "build", "run", "--" }));
    } else if (std.mem.eql(u8, cmd, "doctor")) {
        std.process.exit(try doctor.run(alloc));
    } else if (std.mem.eql(u8, cmd, "version") or std.mem.eql(u8, cmd, "--version") or std.mem.eql(u8, cmd, "-V")) {
        std.debug.print("cipher {s} (zig >= 0.17.1)\n", .{version});
    } else {
        std.debug.print("{s}", .{usage});
        if (!std.mem.eql(u8, cmd, "help") and !std.mem.eql(u8, cmd, "--help") and !std.mem.eql(u8, cmd, "-h")) std.process.exit(2);
    }
}

fn runZig(extra: []const []const u8, base: []const []const u8) !u8 {
    // findZig writes into storage that must remain alive through exec.
    var zig_buf: [512]u8 = undefined;
    const zig = util.findZig(&zig_buf) orelse {
        std.debug.print("cipher: zig not found on PATH (set $ZIG to the zig binary)\n", .{});
        return 127;
    };
    var argv = std.ArrayList([]const u8).empty;
    defer argv.deinit(std.heap.page_allocator);
    const alloc = std.heap.page_allocator;
    // runInherit supplies argv[0]; base contains only zig's subcommand.
    try argv.appendSlice(alloc, base);
    try argv.appendSlice(alloc, extra);
    return util.runInherit(zig, argv.items);
}
