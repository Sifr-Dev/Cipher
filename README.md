<p align="center">
  <picture>
    <source media="(prefers-color-scheme: dark)" srcset=".github/banner-dark.svg">
    <img alt="cipher — built from zero" src=".github/banner-light.svg" width="100%">
  </picture>
</p>

# cipher

[![ci](https://github.com/mohamedsalahi/sifr-native/actions/workflows/ci.yml/badge.svg)](https://github.com/mohamedsalahi/sifr-native/actions/workflows/ci.yml)

zero-dependency, vulkan-native Linux UI framework for Zig. no toolkit. no glue. every byte is ours.

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

## verified evidence (2026-11-17, RTX 4060 Laptop + lavapipe)

- `zig build test` → exit 0 (twice consecutively); `term_shim` 27/27; `audio_shim` 8/8
  incl. FLAC bit-exact vs `flac`/`ffmpeg` on 6 fixtures (16/24-bit, 8–96 kHz,
  mono/stereo, -0/-3/-5/-8; mismatches=0, md5_ok=true).
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

## shown running

built-from-zero apps prove the framework end to end:

| app | what | evidence |
| --- | --- | --- |
| rex + cipherterm | multiplexer server + scriptable CLI + GPU terminal (tabs, themes, status bar) | live umbriel/NVIDIA: vulkan-gpu-ui, 120 frames in 0.9 ms/frame, mouse/keys/resize/paste |
| nocturne | offline FLAC music player (from-zero decoder, synced LRC/VORBIS lyrics, crossfade) | live umbriel/NVIDIA: exit 0, track auto-advance at track end; offline WAV render exactly 5.000000 s |
| cipher-hello | framework smoke app (every widget) | `WAYLAND_PROTOCOL_OK frames=24/120`, exit 0 |

Both apps live in the separate **sifr-apps** project, which consumes this
framework as a path dependency — exactly how an app is built on Qt.

## speed & footprint vs toolkits (2026-11-17)

minimal hello window, 120 frames, umbriel/NVIDIA — see `sifr-apps/bench/BENCH.md`:

| | cipher | gtk4 | qt6 |
| --- | --- | --- | --- |
| linked .so mapppings | **4** | 113 | 45 |
| wall ms (process exec) | 2344–2386 | 2239–2277 | 1961–1962 |
| peak RSS | 286 MB | 300–326 MB | 47–48 MB |

Cipher is the only one of the three with zero toolkit dependencies; Vulkan
dlopen means the GPU ABI is never a link-time constraint. RSS is dominated by
the NVIDIA Vulkan allocator floor, not by this framework (~20 MB above it).
ReleaseFast Vulkan path is currently unstable on NVIDIA (tracked); debug is
the verified path.

## license
`MIT` — see `LICENSE`. built from zero.
