# Cipher (sifr-native)

A from-zero, zero-dependency native Linux GPU UI framework written in Zig
0.17.1. No toolkit, no C wrapper, no build-time codegen: a handwritten
Wayland wire client talks to the compositor over a Unix socket, and a
dlopen-bound `libvulkan.so.1` renders the UI on the GPU; frames reach the
screen as `vkCmdCopyImageToBuffer` → wl_shm (software wl_shm fallback when
no Vulkan ICD is present).

## Pipeline

```
app (immediate-mode UI)
  → flexbox layout (src/ui/layout.zig)
  → draw commands: rects + text runs (src/ui/ui.zig)
  → glyph atlas (src/ui/text/: SFNT parser + scanline AA rasterizer, R8)
  → GPU quads (src/gpu/vulkan/text.zig: vertex buffer + atlas texture)
  → offscreen render pass → vkCmdCopyImageToBuffer → host buffer
  → memcpy into wl_shm ARGB8888 → wl_surface commit (src/os/linux/wayland/)
```

Everything is hand-rolled: the Wayland protocol client (src/os/linux/wayland/client.zig),
the Vulkan binding (src/gpu/vulkan/device.zig binds `libvulkan.so.1` via
`dlopen`/`dlsym` with hand-written `extern struct` definitions), the shaders
(GLSL compiled with `glslc --target-env=vulkan1.0`, embedded via `@embedFile`),
the TrueType parser, the rasterizer, and the layout engine.

## Build / test / run

```sh
zig build          # builds zig-out/bin/sifr
zig build test     # runs all unit/integration tests (needs a Vulkan ICD)
zig build run      # runs against the live Wayland compositor
```

Requires Zig 0.17.1, a Wayland compositor (`WAYLAND_DISPLAY`,
`XDG_RUNTIME_DIR`), and a Vulkan ICD for the GPU path (NVIDIA 620.70.06 and
lavapipe both verified). A font at `/usr/share/fonts/liberation/LiberationSans-Regular.ttf`
is used for text.

## Verified evidence (2026-11-17, RTX 4060 Laptop + lavapipe)

- `zig build test` → exit 0, 19 tests across 8 files.
- GPU frame pipeline exact pixels: `GPU_FRAME_OK bytes=12288 corner=04060B center=EBB545`
  (NVIDIA + lavapipe, clean under `VK_LAYER_KHRONOS_validation`), PPM at `/tmp/sifr_frame.ppm`.
- GPU text exact pixels: `GPU_TEXT_OK bytes=61440 solid=45B5EBFF hole/void=0B0604FF`,
  PPM at `/tmp/sifr_gpu_text.ppm`.
- Text engine vs real TTF: `TEXT_FONT_OK glyphs=2620 upem=2048`, cmap `gid_A=36 adv_A=1366`,
  rasterizer deterministic + symmetric ink, PPM at `/tmp/sifr_text.ppm`.
- Live compositor (umbriel): `sifr: render path = vulkan-gpu-ui` +
  `sifr: WAYLAND_PROTOCOL_OK frames=24`, exit 0, on both NVIDIA and lavapipe.

## Layout

```
src/root.zig                 app entry: Wayland session + frame loop + UI demo
src/core/types.zig           handles, errors, diagnostics
src/os/linux/wayland/        handwritten Wayland wire client (SCM_RIGHTS, wl_shm, xdg)
src/gpu/vulkan/              dlopen'd libvulkan: device, frame pipeline, text pipeline, shaders
src/ui/text/                 SFNT parser (font.zig), rasterizer (raster.zig), atlas (atlas.zig)
src/ui/                      flexbox layout (layout.zig), immediate-mode widgets (ui.zig)
docs/ARCHITECTURE.md         module map and data flow
docs/decision-records/       why things are the way they are (with evidence)
```

See `docs/ARCHITECTURE.md` for details and `docs/decision-records/` for the
decisions and the bug root-cause writeups.
