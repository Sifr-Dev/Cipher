const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{ .preferred_optimize_mode = .ReleaseFast });
    const exe_mod = b.createModule(.{
        .root_source_file = b.path("src/main.zig"),
        .target = target,
        .optimize = optimize,
    });

    const exe = b.addExecutable(.{
        .name = "cipher",
        .root_module = exe_mod,
    });
    b.installArtifact(exe);

    const run_cmd = b.addRunArtifact(exe);
    run_cmd.step.dependOn(b.getInstallStep());

    const run_step = b.step("run", "Run Cipher");
    run_step.dependOn(&run_cmd.step);

    const geo_mod = b.createModule(.{
        .root_source_file = b.path("src/geometry.zig"),
        .target = target,
        .optimize = optimize,
    });
    const geo_tests = b.addTest(.{
        .root_module = geo_mod,
    });
    const run_geo_tests = b.addRunArtifact(geo_tests);
    const test_step = b.step("test", "Run unit tests");
    test_step.dependOn(&run_geo_tests.step);

    inline for (.{
        .{ "src/rasterize.zig", "rasterize_tests" },
        .{ "src/flexbox.zig", "flexbox_tests" },
        .{ "src/textlayout.zig", "textlayout_tests" },
    }) |case| {
        const mod = b.createModule(.{
            .root_source_file = b.path(case[0]),
            .target = target,
            .optimize = optimize,
        });
        const tests = b.addTest(.{
            .root_module = mod,
        });
        const run_tests = b.addRunArtifact(tests);
        test_step.dependOn(&run_tests.step);
    }

    const probe_mod = b.createModule(.{
        .root_source_file = b.path("src/vulkan_probe.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
    });
    const probe = b.addExecutable(.{
        .name = "vkprobe",
        .root_module = probe_mod,
    });
    b.installArtifact(probe);
    const probe_step = b.step("probe", "Run headless Vulkan probe");
    const probe_run = b.addRunArtifact(probe);
    probe_run.step.dependOn(b.getInstallStep());
    probe_step.dependOn(&probe_run.step);

    const gpuframe_mod = b.createModule(.{
        .root_source_file = b.path("src/gpuframe.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
    });
    const gpuframe = b.addExecutable(.{
        .name = "gpuframe",
        .root_module = gpuframe_mod,
    });
    b.installArtifact(gpuframe);
    const gpuframe_step = b.step("gpuframe", "Run GPU-drawn SIFR frame on Wayland");
    const gpuframe_run = b.addRunArtifact(gpuframe);
    gpuframe_run.step.dependOn(b.getInstallStep());
    gpuframe_step.dependOn(&gpuframe_run.step);

    const probe3_mod = b.createModule(.{
        .root_source_file = b.path("src/probe3.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
    });
    const probe3 = b.addExecutable(.{
        .name = "vkprobe3",
        .root_module = probe3_mod,
    });
    b.installArtifact(probe3);
    const probe3_step = b.step("probe3", "Run bare compute probe");
    const probe3_run = b.addRunArtifact(probe3);
    probe3_run.step.dependOn(b.getInstallStep());
    probe3_step.dependOn(&probe3_run.step);
}
