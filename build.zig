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
    root_mod.addAnonymousImport("resources", .{ .root_source_file = b.path("resources.zig") });

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
    cipher_mod.addAnonymousImport("resources", .{ .root_source_file = b.path("resources.zig") });
    const term_mod = b.addModule("term", .{
        .root_source_file = b.path("src/term_api.zig"),
        .target = target,
        .optimize = optimize,
    });
    term_mod.link_libc = true;
    term_mod.addAnonymousImport("resources", .{ .root_source_file = b.path("resources.zig") });
    const audio_mod = b.addModule("audio", .{
        .root_source_file = b.path("src/audio_api.zig"),
        .target = target,
        .optimize = optimize,
    });
    audio_mod.link_libc = true;

    // audio-sink example — opt-in. Built and run only via `zig build run-audio-sink`
    // so the default build does not compile or link the audio output module.
    const audio_sink_mod = b.createModule(.{
        .root_source_file = b.path("examples/audio_sink/main.zig"),
        .target = target,
        .optimize = optimize,
    });
    audio_sink_mod.link_libc = true;
    audio_sink_mod.addImport("audio", audio_mod);
    const audio_sink = b.addExecutable(.{ .name = "cipher-audio-sink", .root_module = audio_sink_mod });
    const run_audio_sink = b.addRunArtifact(audio_sink);
    b.step("run-audio-sink", "Play a short tone through the audio sink (Pulse/ALSA; no-op without a server)").dependOn(&run_audio_sink.step);

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

    // NOTE: the apps built on this framework (janus, nebula, nocturne, …)
    // each live in their own repository and consume Cipher as a pinned
    // dependency — this repo is the framework itself plus the hello example.

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

    // snapdiff — snapshot contract gate (software path is byte-deterministic).
    const snap_mod = b.createModule(.{
        .root_source_file = b.path("tools/snapdiff/main.zig"),
        .target = target,
        .optimize = optimize,
    });
    snap_mod.link_libc = true;
    const snap = b.addExecutable(.{ .name = "snapdiff", .root_module = snap_mod });
    b.installArtifact(snap);

    const hello_for_snap = b.addRunArtifact(hello);
    hello_for_snap.setEnvironmentVariable("CIPHER_FORCE_SOFTWARE", "1");
    hello_for_snap.setEnvironmentVariable("CIPHER_DUMP_FRAME", ".zig-cache/snapshot-hello.ppm");
    hello_for_snap.setEnvironmentVariable("CIPHER_MAX_FRAMES", "3");
    hello_for_snap.step.dependOn(b.getInstallStep());

    const snap_check = b.addRunArtifact(snap);
    snap_check.addArg("check");
    snap_check.addArg(".zig-cache/snapshot-hello.ppm");
    snap_check.addArg("tests/golden/hello.sha256");
    snap_check.step.dependOn(&hello_for_snap.step);
    b.step("snapshot", "Run the software-path snapshot gate against tests/golden/hello.sha256 (needs a Wayland session)").dependOn(&snap_check.step);

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
        .{ "src/ui/motion.zig", "ui_motion" },
        .{ "src/framework_shim.zig", "framework_shim" },
        .{ "src/framework_ime_shim.zig", "framework_ime_shim" },
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
        mod.addAnonymousImport("resources", .{ .root_source_file = b.path("resources.zig") });
        const tests = b.addTest(.{
            .root_module = mod,
        });
        const run_tests = b.addRunArtifact(tests);
        test_step.dependOn(&run_tests.step);
    }
}
