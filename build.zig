const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const root_mod = b.createModule(.{
        .root_source_file = b.path("src/root.zig"),
        .target = target,
        .optimize = optimize,
    });

    const exe = b.addExecutable(.{
        .name = "sifr",
        .root_module = root_mod,
    });
    b.installArtifact(exe);

    const run_cmd = b.addRunArtifact(exe);
    run_cmd.step.dependOn(b.getInstallStep());

    const run_step = b.step("run", "Run sifr framework surface proof");
    run_step.dependOn(&run_cmd.step);

    const test_step = b.step("test", "Run all tests");
    const units = .{
        .{ "src/core/types.zig", "core_types" },
        .{ "src/os/linux/wayland/client.zig", "wayland_client" },
        .{ "src/gpu/vulkan/loader.zig", "vulkan_loader" },
        .{ "src/gpu/vulkan/loader_test.zig", "vulkan_loader_test" },
        .{ "src/gpu/vulkan/device.zig", "vulkan_device" },
        .{ "src/gpu/vulkan/device_test.zig", "vulkan_device_test" },
    };
    inline for (units) |unit| {
        const mod = b.createModule(.{
            .root_source_file = b.path(unit[0]),
            .target = target,
            .optimize = optimize,
        });
        const tests = b.addTest(.{
            .root_module = mod,
        });
        const run_tests = b.addRunArtifact(tests);
        test_step.dependOn(&run_tests.step);
    }
}
