![SIFR identity V2 — the cipher disk at shift zero](.github/assets/readme-header-dark.png)

# cipher

Cipher is an original native Linux windowing and graphics framework, written from the wire up in Zig. Part of SIFR: precision, reduction to essentials, mathematical structure, clarity.

**Status:** the Wayland wire client is handwritten and verified end-to-end on a live compositor: registry, xdg-shell toplevel, shared-memory surface, full configure → frame callback → commit → teardown cycle. No protocol code is generated, no library is linked, no C dependency exists anywhere in the tree.

## What exists today

Cipher is at the earliest vertical-slice stage, with every slice verified on a real compositor/GPU driver. Notable events:

- **GPU-drawn frame, verified (2026-11-16).** `zig build && ./zig-out/bin/gpuframe` dispatches a real compute shader (`src/ring.comp`, ours) that rasterizes the SIFR ring on the NVIDIA ICD, copies the result into host-visible memory, and presents it through Cipher's own Wayland wire client on `wayland-0` — exit 0, `WAYLAND_PROTOCOL_OK frames=24`, and the frame dump (`/tmp/opencode/gpuframe.ppm`) shows the correct identity: void background, hairline circles, 23 bone cells, 1 brass index at 12 o'clock, brass center dot — all computed on the GPU.
- **Root cause found of the "silent black image" bug class:** a `VkBufferImageCopy` was carrying a 20-byte `VkSubresourceRange` where the spec requires a 16-byte `VkSubresourceLayers` — every image command with that payload silently produced no pixels while all `vk*CommandBuffer*rc=0`. Fixed by introducing `VkSubresourceLayers`; verified with a minimal 8×8 probe that image→buffer roundtrip, clear, and dispatch→image→copy all return correct bytes.

- **Headless Vulkan probe (`zig build probe`) PASSED on the NVIDIA ICD** with only `libvulkan.so.1` dlopen'd by our binary: instance → physical device `NVIDIA GeForce RTX 4060 Laptop GPU` (vendor `10de`, api `404165`) → logical device + queue (family 0) → command pool + buffer → 640×400 `R8G8B8A8_UNORM` image allocated and bound → host-visible, host-coherent 1 MB staging buffer allocated and bound. End to end in 241 ms.
- The Wayland wire client is hand-marshaled end to end — no generated bindings, no GTK, no X11, no libc-linked GPU stack. The probe links libc only so `std.DynLib` can route through `dlopen` (the zero-runtime ELF loader has no relocations; calling ICD functions through it crashes confirmed by experiment).
- The compositor answered with `wl_seat` (pointer + keyboard capabilities); the client created `wl_keyboard`/`wl_pointer`, received the 35,910-byte xkb keymap with its fd, closed the fd, and reports focus, keys, and pointer motion/buttons.
- Frame pacing works through `wl_surface.frame` callbacks across 24 frames.
- Input terminates the app cleanly: Escape (key code 1), `q` (key code 16), or a press on the brass center quit `main` through the normal commit/frame-callback path.

Roadmap continues below.

| Component | State |
|---|---|
| `src/wayland.zig` | Raw Wayland wire client: `wl_display` marshaling, `wl_registry`, `wl_compositor`, `wl_shm` (memfd + `SCM_RIGHTS`), `wl_surface`, `wl_seat`/`wl_keyboard`/`wl_pointer` (keymap fd closed correctly), `xdg_wm_base`, `xdg_surface`, `xdg_toplevel` — hand-encoded from the upstream XML semantics. Receive path is a buffered `recvmsg` loop that survives coalesced messages |
| `src/geometry.zig` | 24-cell cipher-ring geometry, unit-tested |
| `src/render.zig` | CPU rasterizer for the SIFR ring; A8R8G8B8 pixels, PPM evidence dump |
| `src/vulkan_probe.zig` | Headless Vulkan probe, NVIDIA ICD (`zig build probe`) — PROBE_OK |
| `src/font.zig` | From-zero SFNT reader: table directory, `head`/`maxp`/`hhea`/`hmtx`, `loca`, `cmap` (formats 4/12), glyph bounds — verified on bundled Instrument Sans and Geist Mono (SIL OFL 1.1; licenses in `assets/`) |
| `src/outline.zig` | From-zero `glyf` reader: simple + composite outlines with 2×2/scale/xy-scale matrices and point-matching arguments |
| `assets/` | Instrument Sans + Geist Mono, decompressed from the OFL-licensed fontsource variable fonts (`.ttf` committed; licenses included) |
| `src/main.zig` | App lifecycle: connect → bind → seat/keyboard/pointer → configure → render/commit/frame-callback loop |

## Requirements

- Zig 0.17.1
- Linux with a running Wayland compositor (verified on `wayland-0`)
- No other dependencies — not GTK, not X11, not libwayland. The kernel's syscall layer is the only floor.

## Build, test, run

```bash
zig build test   # ring geometry + rasterizer tests
zig build        # debug binary
zig build -Doptimize=ReleaseFast

./zig-out/bin/cipher --frames 24
```

`--frames N` runs N frames then exits cleanly; the terminal prints `WAYLAND_PROTOCOL_OK frames=N`. An SPPM dump of the final frame is written to `/tmp/opencode/cipher_frame.ppm` for evidence.

## Built from zero — what that means here

No generated protocol bindings, no external crates/packages, no FFI to a toolkit. The Wayland client is marshaling over `AF_UNIX` sockets and `memfd_create`. The rendering is ours. The only planned third-party runtime surfaces, if any, will be system GPU driver API entry points (and only ever reached through our own loader) — nothing will sit between Cipher and the hardware beyond the driver itself.

## Roadmap

- [x] Wayland window + verified frame loop on `wayland-0` (commit/configure/frame pacing)
- [x] Input: `wl_seat`/`wl_keyboard`/`wl_pointer` — focus, key handling, clean quit (verified live)
- [x] Headless Vulkan probe against the NVIDIA ICD — device, queue, image, host-visible buffer (verified, 2026-11-16, `PROBE_OK`)
- [x] GPU-drawn SIFR ring (compute shader) → host-visible memory → wl_shm present
- [ ] Scene graph, render graph, batching
- [ ] Text (own TrueType reader, glyph atlas), flexbox layout, motion
- [ ] `mobilis` terminal and `harmonis` music player built on Cipher
- [ ] Accessibility: own tree, `AT-SPI2` bridge later — never via a toolkit

## License

Not declared yet; the owner will select one before public release.
