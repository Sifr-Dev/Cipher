# DR-001: Binding Vulkan via dlopen/dlsym + hand-written extern structs

## Decision

Bind `libvulkan.so.1` at runtime with `std.c.dlopen`/`std.c.dlsym` and declare
the used Vulkan functions as typed `callconv(.c)` function pointers in a
`Vulkan` struct (`src/gpu/vulkan/device.zig`). Declare C-ABI structs as
Zig `extern struct`; all handles are `*anyopaque` (8 bytes, same as the C
API on LP64).

## Why

Zero-dependency requirement: no link-time `-lvulkan`, no generated bindings,
no C wrapper. The loader trampolines dispatch through the device dispatch
table, so dlsym'd entry points work for instance/device/command functions.

## Verification

- Device creation verified live on RTX 4060 (NVIDIA 620.70.06): instance,
  enumerate (1 physical device), device, queue all `VK_SUCCESS`;
  `Vulkan device created: queue_family=0`.
- Struct layouts: a gcc probe (`offsetof`/`sizeof` against
  `/usr/include/vulkan/vulkan.h`) and a Zig probe (`@offsetOf`/`@sizeOf`)
  were diffed — 114 field checks, all identical.

## Root-cause note (corrects an earlier misdiagnosis)

An earlier "NVIDIA bind segfault" at `vkCmdBeginRenderPass` was first
attributed to the driver, then to wrong enum constants (bind point, stages,
layouts, usage — those *were* wrong and were fixed). The final, actual cause:
our `VkRenderPassBeginInfo` had a phantom `flags` field. The real struct in
`vulkan_core.h` has **no** flags member (size 64, `renderPass@16`), so our
`renderPass` sat at offset 24 and the ICD read offset 16 (= 0) as the handle
→ null-handle deref (`memcpy` from `0x1` inside the ICD; validation reported
`renderPass Invalid VkRenderPass Object 0x0` and showed our renderPass value
in the framebuffer slot — an 8-byte shift). A ground-truth C probe using the
real `vulkan.h` (`/tmp/vkgfx_ref.c`) ran the same flow successfully, which
pinned the discrepancy to our struct. Fix: remove the field; re-diff all
layouts against the header.

## Zig 0.17.1 traps hit (for the record)

- `callconv(.c)` (not `.C`); one-arg `@ptrCast`; `@alignCast` for alignment
  increases; `extern struct` for C ABI; `@embedFile` returns `[N:0]u8`
  (strip sentinel before `@bitCast` to `[]const u32`); test modules calling
  `std.c.dlopen` need `link_libc = true`; `std.posix.openat(AT.FDCWD, …)`;
  `std.c.write(fd, ptr, len)`; `bool` in FFI is 1 byte vs C `VkBool32` — kept
  to true-only uses.
