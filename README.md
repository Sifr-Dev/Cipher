# Phantom

A zero-dependency, Vulkan-native Linux application framework written from scratch in Zig.

<p>
  <a href="https://github.com/Sifr-Dev/Phantom/actions/workflows/ci.yml"><img alt="CI" src="https://github.com/Sifr-Dev/Phantom/actions/workflows/ci.yml/badge.svg"></a>
  <img alt="Zig 0.17.1" src="https://img.shields.io/badge/ZIG-0.17.1-ffb86b?logo=zig&logoColor=white">
  <img alt="Tests: 160 passing" src="https://img.shields.io/badge/TESTS-160_PASSING-39c5cf">
  <img alt="License: MIT" src="https://img.shields.io/badge/LICENSE-MIT-2ea043">
  <img alt="Linux x86_64" src="https://img.shields.io/badge/LINUX-x86__64-58a6ff?logo=linux&logoColor=white">
</p>

> Repository: `https://github.com/Sifr-Dev/Phantom`. The package name (`.cipher`),
> build target and CLI binary (`cipher`) are unchanged for compatibility.

## What it is

Phantom is a from-zero native Linux GPU UI framework in Zig 0.17.1. It dlopen()s
`libwayland-client` and `libvulkan.so.1` instead of linking them, renders an
immediate-mode UI through a `VK_KHR_wayland_surface` swapchain, and falls back
to software rasterization over `wl_shm` when no Vulkan ICD is available.
Everything between the application and those two loaders is in this repository:
the Wayland interface tables, the Vulkan bindings, the TrueType parser, the
rasterizer, the layout engine, the widgets, the terminal stack, and the audio
sink.

## Current capabilities

- **Wayland display session over dlopen()** — `src/os/linux/wayland/wayland_client.zig`,
  generated interface tables in `src/os/linux/wayland/wayland_tables.zig`; covered
  by `zig build test` (`WAYLAND_PROTOCOL_OK`, `src/os/linux/wayland/wayland_client.zig`).
- **Vulkan UI presentation and software fallback** — `src/gpu/vulkan/swapchain.zig`,
  `src/gpu/vulkan/text.zig`, `src/gpu/vulkan/frame.zig`; exact-pixel tests emit
  `GPU_FRAME_OK bytes=12288` and `GPU_TEXT_OK bytes=61440` in `zig build test`.
- **From-zero TrueType engine** — SFNT parser (`src/ui/text/font.zig`), scanline
  rasterizer (`src/ui/text/raster.zig`), shelf-packed atlas (`src/ui/text/atlas.zig`);
  `zig build test` reports `TEXT_FONT_OK glyphs=2620 upem=2048` and
  `TEXT_RASTER_OK` on a real system font.
- **Immediate-mode flexbox UI and widgets** — `src/ui/layout.zig`, `src/ui/ui.zig`,
  `src/ui/widgets.zig`; `src/ui/widgets_test.zig` (12 tests) covers tabs, focus,
  tooltips, menus, scrollbars and text editing.
- **Terminal stack** — VT parser, grid, kitty keyboard protocol, PTY, server and
  JSON wire protocol under `src/term/`; exercised by `src/term/term_test.zig` and
  the e2e tests (`E2E_SPAWN_OK`, `SERVER_CAPTURE_OK` in `zig build test`).
- **Audio output sink** — `src/audio/sink.zig` with null, WAV-capture, ALSA and
  Pulse backends loaded through `dlopen`; `src/audio/sink_test.zig` (8 tests)
  includes a WAV round-trip and clean skips when no audio server is running.
- **Application framework and CLI** — `src/framework/runtime.zig`,
  `src/framework/input.zig`, text field/IME model; `cipher new`, `cipher doctor`
  and the scaffold are documented and exercised in `docs/GETTING_STARTED.md`.
- **Deterministic snapshot gate** — `zig build snapshot` regenerates the
  software frame and compares it with `tests/golden/hello.sha256`.
- **Zero link-time toolkit dependencies** — `ldd` on a built app shows only the
  C loader/libc; Wayland and Vulkan are resolved at runtime (`src/gpu/vulkan/loader.zig`).

## Quick start

```sh
git clone https://github.com/Sifr-Dev/Phantom.git Cipher
cd Cipher
zig build                      # builds zig-out/bin/cipher and the example apps
zig build test                 # unit and integration tests
./zig-out/bin/cipher doctor    # Zig + Wayland + Vulkan + fonts
```

Build your own app from the parent directory:

```sh
cd ..
CIPHER_HOME=$PWD/Cipher ./Cipher/zig-out/bin/cipher new my-app
cd my-app && zig build run     # a window; Esc quits
```

Requirements: Zig 0.17.1, a Wayland compositor (`WAYLAND_DISPLAY`,
`XDG_RUNTIME_DIR`), and a Vulkan ICD for the GPU path. `apps/hello.zig` is the
canonical small example (`zig build run-hello`).

## Verification

Run on this host (Ryzen 7 7435HS, RTX 4060 Laptop, Wayland, Zig 0.17.1):

```sh
CIPHER_SKIP_PERF_GATE=1 zig build test
```

Observed: exit 0, **160 tests passed, 0 failed**, across 20 test executables
(the machine-dependent VT throughput gate is skipped by `CIPHER_SKIP_PERF_GATE`,
as in CI). Builds:

```sh
zig build
zig build -Doptimize=ReleaseSafe
zig build -Doptimize=ReleaseFast
```

All three exit 0 on this host. CI runs the same test command twice — once on a
shared runner without a GPU, once against lavapipe with
`VK_LAYER_KHRONOS_validation`; GPU-only tests skip honestly when no ICD exists.
See `.github/workflows/ci.yml`.

## Architecture

```
src/root.zig                 app entry: Wayland session, frame loop, demo UI
src/core/types.zig           handles, errors, diagnostics
src/os/linux/wayland/        dlopen'd libwayland-client wrapper + generated tables
src/gpu/vulkan/              dlopen'd libvulkan: device, pipelines, swapchain, shaders
src/ui/text/                 SFNT parser, rasterizer, atlas, grapheme/editing
src/ui/                      flexbox layout, immediate-mode widgets, motion
src/term/                    VT parser, grid, PTY, kitty keys, server, JSON protocol
src/audio/                   output sink (null/WAV/ALSA/Pulse) and WAV I/O
src/framework/               runtime loop, input events, text field and IME model
apps/                        hello, bench and app examples
docs/                        getting started, architecture, internals, benchmarks, ADRs
```

`docs/ARCHITECTURE.md` has the module map and frame data flow;
`docs/decision-records/` records the binding, pipeline, text-engine and UI
decisions with their evidence.

## Ecosystem

- **Janus** (`Sifr-Dev/janus`) — GPU-native terminal built on this framework.
- **Nebula** (`Sifr-Dev/nebula`) — terminal multiplexer/engine built on this framework.
- **Nocturne** (`Sifr-Dev/nocturne`) — offline FLAC player built on this framework.
- **CipherDesk** (`Sifr-Dev/CipherDesk`) — the earlier combined apps repository.
  It is **superseded and archived**; its apps now live in the three repositories
  above, and its remaining documentation is folded into Phantom. CipherDesk is
  not a separate product and receives no new work.

## Benchmarks

The measured comparison with Qt6/GTK4 and with nanoui lives in `docs/BENCH.md`;
the raw toolkit benches are in the Janus repository's `bench/BENCH.md`. Hardware:
Ryzen 7 7435HS, RTX 4060 Laptop, Wayland (umbriel), Zig 0.17.1, Linux; 120-frame
hello window, three 300-frame windows after a 30-frame warm-up, arithmetic
means. Headline results from that record: startup 0.854–0.999 s (Qt 1.94–1.97 s,
GTK 2.10 s), heavy-scene CPU 0.030–0.035 ms/frame (Qt 0.925–0.950 ms), and 3
linked `.so` mappings versus 45 (Qt) and 113 (GTK).

Limitations of those numbers: one machine, one compositor, a minimal scene, and
`render_ms` includes presentation/vsync rather than GPU timestamps. They are not
a general performance claim and are not extrapolated to other workloads.

## Limitations

- **Accessibility:** no AT-SPI bridge; screen-reader support is not claimed.
- **IME:** the text-input-v3 session and text field compile and pass unit tests,
  but a live IME round-trip against a real input method has not been verified.
- **Text:** no complex-script shaping (HarfBuzz-class); single-line and wrapped
  Latin editing only.
- **Widgets:** roughly 15 controls, not thousands; no printing, animation
  timeline, or theme engine.
- **Display scaling:** integer HiDPI scale works; the fractional-scale path was
  blocked by the test compositor and is not verified.
- **Stability:** no stable ABI or API guarantee; the framework is pre-1.0.
- **GPU memory:** the Vulkan path's resident memory is dominated by the NVIDIA
  allocator floor (~270–325 MB in the measured hello window), not by this code.

## Roadmap (NOT IMPLEMENTED)

- AT-SPI accessibility bridge and screen-reader semantics.
- Live IME round-trip verification and composition UI.
- Complex-script text shaping.
- Fractional-scale protocol support on a compositor that implements it.
- A broader widget set and a stable public API/ABI.
- GPU timestamp queries so presentation cost can be reported separately from vsync.

## License

MIT — see `LICENSE`. Built from zero.
