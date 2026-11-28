<p align="center">
  <picture>
    <source media="(prefers-color-scheme: dark)" srcset=".github/banner-dark.svg">
    <img alt="cipher — built from zero" src=".github/banner-light.svg" width="100%">
  </picture>
</p>

<div align="center">

# cipher

### A zero-dependency, Vulkan-native Linux UI framework for Zig.

<p>
  <img alt="Zig" src="https://img.shields.io/badge/ZIG-0.17.1-ffb86b?style=for-the-badge&logo=zig&logoColor=0b0d10&labelColor=1b1f27">
  <img alt="License MIT" src="https://img.shields.io/badge/LICENSE-MIT-2ea043?style=for-the-badge&labelColor=1b1f27">
  <img alt="Linux" src="https://img.shields.io/badge/LINUX-x86__64-58a6ff?style=for-the-badge&logo=linux&logoColor=0b0d10&labelColor=1b1f27">
</p>
<p>
  <img alt="Runtime deps" src="https://img.shields.io/badge/RUNTIME_DEPS-0-6ee7ff?style=for-the-badge&labelColor=1b1f27">
  <img alt="Wayland and Vulkan via dlopen" src="https://img.shields.io/badge/WAYLAND_+_VULKAN-DLOPEN-8957e5?style=for-the-badge&labelColor=1b1f27">
  <img alt="Tests" src="https://img.shields.io/badge/TESTS-107_PASSING-39c5cf?style=for-the-badge&labelColor=1b1f27">
</p>

</div>

> Zero-dependency, Vulkan-native Linux UI framework for Zig. No toolkit, no glue, every byte ours.

A from-zero, zero-dependency native Linux GPU UI framework written in Zig
0.17.1. No toolkit, no C wrapper, no build-time codegen: `libwayland-client`
is dlopen'd for the display component (like Vulkan is), an in-tree scanner
(`tools/gen_wayland_tables.py`) generates the wl_interface tables the C
library demands, a hand-written immediateness-mode UI rasterizes glyphs to an
R8 atlas, and a dlopen-bound `libvulkan.so.1` renders the UI and presents it
straight to the compositor through a `VK_KHR_wayland_surface` swapchain — no
readback, no wl_shm copy on the GPU path (wl_shm + software raster remains
the fallback). Everything else is hand-rolled: the TrueType parser, the
rasterizer, the layout engine, the widgets, the terminal stack, the FLAC
decoder.

## Pipeline

```
app (immediate-mode UI)
  → flexbox layout (src/ui/layout.zig)
  → draw commands: rects + text runs (src/ui/ui.zig)
  → glyph atlas (src/ui/text/: SFNT parser + scanline AA rasterizer, R8)
  → GPU quads (src/gpu/vulkan/text.zig: vertex buffer + atlas texture)
  → swapchain image → vkQueuePresentKHR → compositor vsync (WSI)
    └─ fallback without a usable ICD: offscreen render pass →
       vkCmdCopyImageToBuffer → host buffer → memcpy → wl_shm commit
```

Everything is hand-rolled: the wl_interface tables (tools/gen_wayland_tables.py
generates them from the system wayland-protocols XML), the Vulkan binding
(`libvulkan.so.1` via `dlopen`/`dlsym`, hand-written `extern struct`
definitions), the shaders (GLSL, embedded), the TrueType parser, the
rasterizer, and the layout engine. The legacy handwritten wire client
(src/os/linux/wayland/client.zig) is kept for reference only.

## Build / test / run

```sh
zig build          # builds zig-out/bin/sifr
zig build test     # runs all unit/integration tests (needs a Vulkan ICD)
zig build run      # runs against the live Wayland compositor
```

Requires Zig 0.17.1, a Wayland compositor (`WAYLAND_DISPLAY`,
`XDG_RUNTIME_DIR`), and a Vulkan ICD for the GPU path (NVIDIA 620.70.06 and
lavapipe both verified). The default Instrument Sans font and its OFL license
are compiled into each application; installed fonts are optional overrides.

## Build your own app

Start from the full walkthrough — [**docs/GETTING_STARTED.md**](docs/GETTING_STARTED.md).
The short version:

```sh
git clone https://github.com/Sifr-Dev/Cipher.git Cipher
cd Cipher && zig build && cd ..
./Cipher/zig-out/bin/cipher doctor                # zig + Wayland + Vulkan + fonts
CIPHER_HOME=$PWD/Cipher ./Cipher/zig-out/bin/cipher new my-app
cd my-app && zig build run                        # a window; Esc quits
```

The scaffold gives you `src/main.zig` (a panel, a label, a button), a correct
`build.zig.zon` path dependency on this checkout, and a README. Your binary
needs nothing at runtime but the system Wayland loader and a Vulkan ICD
(software fallback included). `apps/hello.zig` is the richer canonical
example (`zig build run-hello`, Esc quits); the apps below are the full-scale
ones, each in its own repository.

## Apps built on Cipher

<!-- BEGIN GENERATED APP INDEX -->
| App | Purpose | Status | Repository | Cipher |
| --- | --- | --- | --- | --- |
| [janus](https://github.com/Sifr-Dev/janus) | GPU-native terminal with panes, tabs and themes | active | https://github.com/Sifr-Dev/janus | pinned via -Dcipher-root |
| [nebula](https://github.com/Sifr-Dev/nebula) | Multiplexer engine: spawn/split/capture sessions over a unix socket | active | https://github.com/Sifr-Dev/nebula | pinned via -Dcipher-root |
| [nocturne](https://github.com/Sifr-Dev/nocturne) | Offline music player with bit-exact FLAC decode, LRC lyrics and crossfade | active | https://github.com/Sifr-Dev/nocturne | pinned via -Dcipher-root |
<!-- END GENERATED APP INDEX -->

This index is generated from `apps/manifest.json` by `tools/gen_app_index.py`;
do not edit the table by hand.

## verified evidence (2026-11-17, RTX 4060 Laptop + lavapipe)

- `zig build test` → exit 0 (twice consecutively); `term_shim` 27/27; `audio_shim`
  covers the output sink (null, WAV-capture round-trip, ALSA/Pulse dlopen probes;
  real-device test opens Pulse/PipeWire or skips cleanly when none is running).
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
src/os/linux/wayland/        dlopen'd libwayland-client wrapper (wayland_client.zig),
                             generated interface tables (wayland_tables.zig), xkb keymap via dlopen'd libxkbcommon
src/gpu/vulkan/              dlopen'd libvulkan: device, frame pipeline, text pipeline,
                             swapchain (WSI), shaders
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
| Janus | GPU-native terminal (tabs, panes, themes, status bar) | live umbriel/NVIDIA: `render path = vulkan-wsi`, exit 0, `WAYLAND_PROTOCOL_OK frames=30/40` |
| nocturne | offline FLAC music player (from-zero decoder, synced LRC/VORBIS lyrics, crossfade) | live umbriel/NVIDIA: exit 0, frames=41 |
| cipher-hello | framework smoke app (every widget) | `WAYLAND_PROTOCOL_OK frames=24/120`, exit 0 |

These apps each live in their own repository and consume this framework as a
pinned dependency — exactly how an app is built on Qt. The framework ships no
binaries; apps ship themselves.

## speed & footprint vs toolkits (2026-11-17)

minimal hello window, 120 frames, umbriel/NVIDIA — full data in the janus repository's `bench/BENCH.md`:

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
