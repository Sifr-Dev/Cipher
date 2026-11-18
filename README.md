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

minimal hello window, 120 frames, umbriel/NVIDIA — full data in `sifr-apps/bench/BENCH.md`:

| | cipher (ReleaseSafe stripped) | gtk4 | qt6 |
| --- | --- | --- | --- |
| linked .so mappings | **3** | 113 | 45 |
| wall ms (process exec) | **854–999** | 2095–2104 | 1936–1966 |
| peak RSS | **23.4 MB (software path)** / ~270–325 MB (Vulkan) | ~294 MB | ~39–49 MB |
| heavy scene (CPU ms/frame) | **0.030–0.035** | not run | 0.925–0.950 |

Cipher is the only one of the three with zero toolkit dependencies; Wayland
and Vulkan are dlopen'd, never linked — and in software mode nothing is
needed at all. GPU RSS is dominated by the NVIDIA Vulkan allocator floor,
not by this framework.

See **where Qt and GTK still lead** below for the honest ledger.

## where Qt and GTK still lead (2026-11-18)

This framework is young and deliberately narrow. Honest ledger vs Qt6/GTK4:

**Qt/GTK win unconditionally today:** AT-SPI accessibility (screen readers),
input method editor (IME) integration, text shaping, widget breadth
(thousands of controls vs our ~15), theming, printing, internationalization,
tooling, stable ABI/API, and decades of battle-testing. Our HiDPI integer
scale works; fractional-scale protocol path was blocked by the umbriel
compositor killing the client on session-object creation (documented).
**We win today on:** startup (0.854s vs Qt 1.94–1.97s, GTK 2.10s),
per-frame CPU in our heavy scene (0.030–0.035ms vs Qt 0.925–0.950ms),
zero toolkit runtime dependencies (3 mappings vs 45/113), and 23.4 MB
software-shm RSS (vs Qt 38.6–40.4 MB). Software rendering path exists —
GPU-optional. Nothing here is a universal claim: our wins are measured
in specific scenes and measured honestly. If you need accessibility,
IME, or rich widget tooling today, use Qt or GTK; when you need a small,
fast, self-contained native binary and you control the whole stack,
Cipher is the pick.

`MIT` — see `LICENSE`. built from zero.
