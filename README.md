![SIFR identity V2 — the cipher disk at shift zero](.github/assets/readme-header-dark.png)

# cipher

Cipher is an original native Linux graphics and application framework written in Zig. Part of the SIFR identity: precision, reduction to essentials, mathematical structure, clarity, efficiency, and expressive simplicity.

**Status:** early vertical slice. One XCB-backed window rendering the 24-cell SIFR cipher ring (brass index at 12 o'clock) is implemented and runs. Not yet: scene system, compositing, text, layout, accessibility, or GPU backends. No wheels are reinvented: the framework targets native Linux directly rather than wrapping an existing UI toolkit.

## What exists today

| Component | State |
|---|---|
| `src/geometry.zig` | 24-cell cipher ring geometry, unit-tested |
| `src/main.zig` | XCB window, void/raised/line/text/brass tokens, expose/key event loop |
| `src/c.h` | translate-c boundary (`xcb/xcb.h`) |

## Naming

`Cipher` is the product name. SIFR (the voice and identity) comes from *sifr* — zero — which descends from the same word as *cipher*. The ring is a shift-zero cipher disk; the framework is the same idea in software: reduce to the essential symbols and make them carry meaning.

## Requirements

- Zig 0.17.1
- X11 headers and `libxcb` (Xlib/XCB; Wayland path planned)
- Linux with a running X11/XWayland session for the window; tests run headless.

## Build and run

```bash
zig build test    # geometry tests
zig build         # debug binary
zig build -Doptimize=ReleaseFast
zig-out/bin/cipher
```

The window closes on any key press. It is verified to map, draw, and accept focus on the development machine (Linux 7.3, Wayland session via XWayland); x11grab cannot capture the Wayland frame, so visual verification is by direct desktop observation.

## Design constraints

- No runtime services, daemons, or background processes beyond the app itself.
- No desktop-shell dependencies; native Linux windowing first (X11/XCB now, Wayland next).
- Explicit memory ownership; no hidden global state.
- Square corners, 1 px hairlines, brass as the sole accent (`#eab444` on `#04060b`).

## Roadmap (honest)

1. X11 window + SIFR ring (done)
2. Wayland client path with XDG shell integration
3. Scene graph, render graph, batching
4. Software rasterizer fallback; EGL/GL and Vulkan backends behind a backend interface
5. Text shaping and layout
6. `mobilis` terminal and `harmonis` music player built on Cipher
7. Accessible-DOM fallback path for web-facing surfaces

## License

Not declared yet; owner will select before release.
