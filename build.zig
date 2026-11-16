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
    const test_step = b.step("test", "Run geometry unit tests");
    test_step.dependOn(&run_geo_tests.step);

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
}
