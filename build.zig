const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const root_mod = b.createModule(.{
        .root_source_file = b.path("src/root.zig"),
        .target = target,
        .optimize = optimize,
    });
    root_mod.link_libc = true;

    const exe = b.addExecutable(.{
        .name = "sifr",
        .root_module = root_mod,
    });
    b.installArtifact(exe);

    const run_cmd = b.addRunArtifact(exe);
    run_cmd.step.dependOn(b.getInstallStep());

    const run_step = b.step("run", "Run sifr framework surface proof");
    run_step.dependOn(&run_cmd.step);

    // Reusable framework modules + example app. addModule() also registers
    // these modules for external consumers (build.zig.zon path/url dep):
    //   const cipher = b.dependency("cipher", .{}).module("cipher");
    const cipher_mod = b.addModule("cipher", .{
        .root_source_file = b.path("src/cipher.zig"),
        .target = target,
        .optimize = optimize,
    });
    cipher_mod.link_libc = true;
    const term_mod = b.addModule("term", .{
        .root_source_file = b.path("src/term_api.zig"),
        .target = target,
        .optimize = optimize,
    });
    term_mod.link_libc = true;
    const audio_mod = b.addModule("audio", .{
        .root_source_file = b.path("src/audio_api.zig"),
        .target = target,
        .optimize = optimize,
    });
    audio_mod.link_libc = true;

    const hello_mod = b.createModule(.{
        .root_source_file = b.path("apps/hello.zig"),
        .target = target,
        .optimize = optimize,
    });
    hello_mod.link_libc = true;
    hello_mod.addImport("cipher", cipher_mod);
    const hello = b.addExecutable(.{
        .name = "cipher-hello",
        .root_module = hello_mod,
    });
    b.installArtifact(hello);
    const run_hello = b.addRunArtifact(hello);
    run_hello.step.dependOn(b.getInstallStep());
    const run_hello_step = b.step("run-hello", "Run the cipher hello app (Esc quits)");
    run_hello_step.dependOn(&run_hello.step);

    // NOTE: the showcase apps (rex, cipherterm, nocturne) live in the
    // separate sifr-apps project, which consumes this framework by path —
    // this repo is the framework itself plus the hello example.

    // cipher-bench — hillclimb-style benchmark scenes (examples/bench).
    const bench_mod = b.createModule(.{
        .root_source_file = b.path("examples/bench/main.zig"),
        .target = target,
        .optimize = optimize,
    });
    bench_mod.link_libc = true;
    bench_mod.addImport("cipher", cipher_mod);
    const bench = b.addExecutable(.{ .name = "cipher-bench", .root_module = bench_mod });
    b.installArtifact(bench);
    const run_bench = b.addRunArtifact(bench);
    run_bench.step.dependOn(b.getInstallStep());
    b.step("run-bench", "Run the cipher benchmark (args after --)").dependOn(&run_bench.step);

    // cipher — the framework's command-line tool (scaffold/build/run/doctor).
    const cipher_cli_mod = b.createModule(.{
        .root_source_file = b.path("tools/cipher/main.zig"),
        .target = target,
        .optimize = optimize,
    });
    cipher_cli_mod.link_libc = true;
    const cipher_cli = b.addExecutable(.{ .name = "cipher", .root_module = cipher_cli_mod });
    b.installArtifact(cipher_cli);
    const run_cipher = b.addRunArtifact(cipher_cli);
    b.step("run-cipher", "Run the cipher CLI (args after --)").dependOn(&run_cipher.step);

    const test_step = b.step("test", "Run all tests");
    const units = .{
        .{ "src/core/types.zig", "core_types" },
        .{ "src/os/linux/wayland/wayland_client.zig", "wayland_client" },
        .{ "src/gpu/vulkan/loader.zig", "vulkan_loader" },
        .{ "src/gpu/vulkan/loader_test.zig", "vulkan_loader_test" },
        .{ "src/gpu/vulkan/device.zig", "vulkan_device" },
        .{ "src/gpu/vulkan/device_test.zig", "vulkan_device_test" },
        .{ "src/gpu/vulkan/frame.zig", "vulkan_frame" },
        .{ "src/gpu/vulkan/frame_test.zig", "vulkan_frame_test" },
        .{ "src/ui/text/font.zig", "text_font" },
        .{ "src/ui/text/raster.zig", "text_raster" },
        .{ "src/ui/text/atlas.zig", "text_atlas" },
        .{ "src/ui/text/text_test.zig", "text_test" },
        .{ "src/ui_shim.zig", "ui_shim" },
        .{ "src/framework_shim.zig", "framework_shim" },
        .{ "src/term_shim.zig", "term_shim" },
        .{ "src/audio_shim.zig", "audio_shim" },
        .{ "src/gpu/vulkan/text.zig", "vulkan_text" },
        .{ "src/gpu_text_test.zig", "gpu_text_test" },
    };
    inline for (units) |unit| {
        const mod = b.createModule(.{
            .root_source_file = b.path(unit[0]),
            .target = target,
            .optimize = optimize,
        });
        mod.link_libc = true;
        const tests = b.addTest(.{
            .root_module = mod,
        });
        const run_tests = b.addRunArtifact(tests);
        test_step.dependOn(&run_tests.step);
    }
}
