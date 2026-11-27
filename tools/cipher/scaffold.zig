//! `cipher new <name>` — scaffold a runnable cipher app with a path
//! dependency on the framework. The fingerprint is computed the way zig
//! computes it (non-zero/non-0xffffffff id + CRC32 of the package name), so
//! the generated package builds on the first try.
const std = @import("std");
const util = @import("util.zig");

const usage =
    \\cipher new <name> [--cipher PATH]
    \\
    \\  Creates ./<name>/ as a cipher app: build.zig, build.zig.zon,
    \\  src/main.zig (a running window — Esc quits), README, .gitignore.
    \\
    \\  PATH is the framework checkout (default: $CIPHER_HOME, else
    \\  ../Cipher relative to where you create the app). A relative
    \\  path is used verbatim; an absolute one is relativized to the app.
    \\
;

pub fn run(alloc: std.mem.Allocator, argv: []const []const u8) !u8 {
    if (argv.len < 1) {
        std.debug.print("{s}", .{usage});
        return 2;
    }
    var name: ?[]const u8 = null;
    var cipher_arg: ?[]const u8 = null;
    var i: usize = 0;
    while (i < argv.len) : (i += 1) {
        const a = argv[i];
        if (std.mem.eql(u8, a, "--cipher")) {
            if (i + 1 >= argv.len) {
                std.debug.print("cipher new: --cipher needs a path\n", .{});
                return 2;
            }
            cipher_arg = argv[i + 1];
            i += 1;
        } else if (std.mem.startsWith(u8, a, "--")) {
            std.debug.print("cipher new: unknown option {s}\n{s}", .{ a, usage });
            return 2;
        } else if (name == null) {
            name = a;
        } else {
            std.debug.print("cipher new: unexpected argument {s}\n", .{a});
            return 2;
        }
    }
    const n = name orelse {
        std.debug.print("{s}", .{usage});
        return 2;
    };
    if (!validName(n)) {
        std.debug.print("cipher new: '{s}' is not a valid name (letters, digits, '-' and '_', 1-64 chars)\n", .{n});
        return 2;
    }

    if (util.exists(n)) {
        std.debug.print("cipher new: '{s}' already exists\n", .{n});
        return 1;
    }

    // Resolve the framework path to absolute, then relativize it against the
    // APP directory (build.zig.zon paths resolve from the package root).
    var cwd_buf: [4096]u8 = undefined;
    const cwd_len = std.os.linux.getcwd(&cwd_buf, cwd_buf.len);
    if (std.posix.errno(cwd_len) != .SUCCESS) {
        std.debug.print("cipher new: cannot read cwd\n", .{});
        return 1;
    }
    const cwd: []const u8 = cwd_buf[0..cwd_len];
    const app_dir = try std.fs.path.join(alloc, &.{ cwd, n });
    defer alloc.free(app_dir);

    const chosen = cipher_arg orelse util.env("CIPHER_HOME") orelse "../Cipher";
    const abs = if (std.fs.path.isAbsolute(chosen))
        try alloc.dupe(u8, chosen)
    else blk: {
        const joined = try std.fs.path.resolve(alloc, &.{ cwd, chosen });
        break :blk joined;
    };
    defer alloc.free(abs);
    if (!util.isDir(abs)) {
        std.debug.print("cipher new: framework not found at {s}\n       (pass --cipher PATH or set CIPHER_HOME)\n", .{abs});
        return 1;
    }
    const cipher_rel = try std.fs.path.relativeAlloc(alloc, app_dir, null, app_dir, abs);
    defer alloc.free(cipher_rel);

    // Fingerprint: non-zero/non-0xffffffff id + CRC32(zon name), as zig does.
    var prng = std.Random.DefaultPrng.init(blk: {
        var ts: std.os.linux.timespec = undefined;
        _ = std.os.linux.clock_gettime(.REALTIME, &ts);
        break :blk (@as(u64, @intCast(ts.sec)) << 32) ^ @as(u64, @intCast(ts.nsec)) ^ (@as(u64, @intCast(std.c.getpid())) << 1);
    });
    const id = prng.random().intRangeLessThan(u32, 1, 0xffffffff);
    const zn = try alloc.dupe(u8, n);
    std.mem.replaceScalar(u8, zn, '-', '_');
    defer alloc.free(zn);
    const checksum = std.hash.Crc32.hash(zn);
    // zig's Fingerprint is a packed struct(u64) { id: u32, checksum: u32 } —
    // first field occupies the LOW bits: upper half = CRC32(name), lower = id.
    const fingerprint = (@as(u64, checksum) << 32) | @as(u64, id);

    const src_dir = try std.fs.path.join(alloc, &.{ n, "src" });
    defer alloc.free(src_dir);
    try util.makeDir(n);
    try util.makeDir(src_dir);

    var zon_name = std.ArrayList(u8).empty;
    defer zon_name.deinit(alloc);
    for (zn) |c| try zon_name.append(alloc, c);

    const w = struct {
        fn path(alloc_: std.mem.Allocator, dir: []const u8, file: []const u8) ![]u8 {
            return std.fs.path.join(alloc_, &.{ dir, file });
        }
    };

    const build_zig = try std.fmt.allocPrint(alloc,
        \\const std = @import("std");
        \\
        \\pub fn build(b: *std.Build) void {{
        \\    const target = b.standardTargetOptions(.{{}});
        \\    const optimize = b.standardOptimizeOption(.{{}});
        \\
        \\    const cipher = b.dependency("cipher", .{{ .target = target, .optimize = optimize }}).module("cipher");
        \\
        \\    const app_mod = b.createModule(.{{
        \\        .root_source_file = b.path("src/main.zig"),
        \\        .target = target,
        \\        .optimize = optimize,
        \\    }});
        \\    app_mod.link_libc = true;
        \\    app_mod.addImport("cipher", cipher);
        \\
        \\    const exe = b.addExecutable(.{{ .name = "{s}", .root_module = app_mod }});
        \\    b.installArtifact(exe);
        \\    const run = b.addRunArtifact(exe);
        \\    b.step("run", "Run {s}").dependOn(&run.step);
        \\}}
        \\
    , .{ n, n });
    defer alloc.free(build_zig);

    const fingerprint_hex = fingerprint;
    const build_zon = try std.fmt.allocPrint(alloc,
        \\.{{
        \\    .name = .{s},
        \\    .version = "0.1.0",
        \\    .fingerprint = 0x{x},
        \\    .minimum_zig_version = "0.17.1",
        \\    .dependencies = .{{
        \\        .cipher = .{{ .path = "{s}" }},
        \\    }},
        \\    .paths = .{{ "build.zig", "build.zig.zon", "src", "README.md" }},
        \\}}
        \\
    , .{ zon_name.items, fingerprint_hex, cipher_rel });
    defer alloc.free(build_zon);

    const main_zig = try std.fmt.allocPrint(alloc,
        \\//! {s} — an app built on the cipher framework.
        \\//! Esc quits; edit src/main.zig and rebuild with `zig build run`.
        \\const std = @import("std");
        \\const cipher = @import("cipher");
        \\
        \\pub const App = struct {{
        \\    frames: u64 = 0,
        \\
        \\    pub fn onEvent(self: *App, rt: *cipher.runtime.Runtime, ev: cipher.input.Event) void {{
        \\        _ = self;
        \\        switch (ev) {{
        \\            .key => |k| {{ if (k.pressed and k.key == .esc) rt.requestQuit(); }},
        \\            .close => rt.requestQuit(),
        \\            else => {{}},
        \\        }}
        \\    }}
        \\
        \\    pub fn onFrame(self: *App, rt: *cipher.runtime.Runtime) !void {{
        \\        const u = rt.ui() orelse return;
        \\        self.frames += 1;
        \\        try u.panel(.{{ .fixed = 460 }}, .{{ .fixed = 170 }}, 16, 12);
        \\        try u.label("{s}", cipher.ui.COLOR_TEXT);
        \\        var buf: [64]u8 = undefined;
        \\        const s = try std.fmt.bufPrint(&buf, "frame {{d}} — zero-install native window", .{{self.frames}});
        \\        try u.label(s, cipher.ui.COLOR_TEXT_DIM);
        \\        if (try u.button("Esc quits")) rt.requestQuit();
        \\        u.endPanel();
        \\    }}
        \\}};
        \\
        \\pub fn main(init: std.process.Init.Minimal) !void {{
        \\    _ = init;
        \\    var app = App{{}};
        \\    try cipher.runtime.run(App, &app);
        \\}}
        \\
    , .{ n, n });
    defer alloc.free(main_zig);

    const readme = try std.fmt.allocPrint(alloc,
        \\# {s}
        \\
        \\An app built with the [cipher](https://github.com/Sifr-Dev/Cipher) framework.
        \\
        \\## Run it
        \\
        \\```sh
        \\zig build run
        \\```
        \\
        \\Requires Zig 0.17.1 and a Wayland session (XWayland not required).
        \\No Cipher runtime or installed font is required. The default font
        \\and its OFL license are compiled into the executable. Platform
        \\requirements are the system C loader, a Wayland session and its
        \\libraries, and a Vulkan ICD for GPU acceleration (software fallback:
        \\`CIPHER_FORCE_SOFTWARE=1`).
        \\
        \\The framework source this app builds against is at `{s}` (see
        \\`build.zig.zon`); re-point it there if you move the checkout.
        \\
    , .{ n, cipher_rel });
    defer alloc.free(readme);

    const gitignore = ".zig-cache/\nzig-out/\n";

    const agents = try std.fmt.allocPrint(alloc,
        \\# Working on {s}
        \\
        \\- Build: `zig build` · run: `zig build run` · test: `zig build test`
        \\- The app imports `cipher` from the framework checkout in build.zig.zon
        \\- CIPHER_MAX_FRAMES=N runs N frames then exits (headless checks)
        \\- CIPHER_DUMP_FRAME=/path.ppm dumps the frame (readback verification)
        \\- Never commit .zig-cache/ or zig-out/
        \\
    , .{n});
    defer alloc.free(agents);

    const files = .{
        .{ "build.zig", build_zig },
        .{ "build.zig.zon", build_zon },
        .{ "src/main.zig", main_zig },
        .{ "README.md", readme },
        .{ ".gitignore", gitignore },
        .{ "AGENTS.md", agents },
    };
    inline for (files) |f| {
        const p = try w.path(alloc, n, f[0]);
        defer alloc.free(p);
        try util.writeFile(p, f[1]);
    }

    std.debug.print(
        \\created {s}/ — an app that already runs.
        \\
        \\  cd {s}
        \\  zig build run
        \\
        \\Framework: {s}
        \\
    , .{ n, n, cipher_rel });
    return 0;
}

fn validName(n: []const u8) bool {
    if (n.len == 0 or n.len > 64) return false;
    for (n, 0..) |c, i| {
        const ok = (c >= 'a' and c <= 'z') or (c >= 'A' and c <= 'Z') or (c >= '0' and c <= '9') or c == '-' or c == '_';
        if (!ok) return false;
        if (i == 0 and (c == '-' or c == '_')) return false;
    }
    return true;
}
