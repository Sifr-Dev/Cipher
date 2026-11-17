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

    // Reusable framework module + example app.
    const cipher_mod = b.createModule(.{
        .root_source_file = b.path("src/cipher.zig"),
        .target = target,
        .optimize = optimize,
    });
    cipher_mod.link_libc = true;

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

    // rex-clone: term API module + scriptable CLI + server.
    const term_mod = b.createModule(.{
        .root_source_file = b.path("src/term_api.zig"),
        .target = target,
        .optimize = optimize,
    });
    term_mod.link_libc = true;

    const rex_mod = b.createModule(.{
        .root_source_file = b.path("apps/rex.zig"),
        .target = target,
        .optimize = optimize,
    });
    rex_mod.link_libc = true;
    rex_mod.addImport("term", term_mod);
    const rex = b.addExecutable(.{
        .name = "rex",
        .root_module = rex_mod,
    });
    b.installArtifact(rex);
    const run_rex = b.addRunArtifact(rex);
    const run_rex_step = b.step("run-rex", "Run the rex CLI (args after --)");
    run_rex_step.dependOn(&run_rex.step);

    // rexterm: GPU terminal client (attaches to the rex server).
    const rexterm_mod = b.createModule(.{
        .root_source_file = b.path("apps/rexterm.zig"),
        .target = target,
        .optimize = optimize,
    });
    rexterm_mod.link_libc = true;
    rexterm_mod.addImport("term", term_mod);
    const rexterm = b.addExecutable(.{
        .name = "rexterm",
        .root_module = rexterm_mod,
    });
    b.installArtifact(rexterm);
    const run_rexterm = b.addRunArtifact(rexterm);
    const run_rexterm_step = b.step("run-rexterm", "Run the rexterm GPU terminal client (args after --)");
    run_rexterm_step.dependOn(&run_rexterm.step);

    const test_step = b.step("test", "Run all tests");
    const units = .{
        .{ "src/core/types.zig", "core_types" },
        .{ "src/os/linux/wayland/client.zig", "wayland_client" },
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
