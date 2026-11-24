# Internals — how the competition actually works (source-verified)

_2026-11-19 · every claim below cites a file from a shallow clone of the upstream repo (commit hashes in §10). No code is copied into Cipher; these are mechanisms, licenses observed (MIT / MIT / Apache-2.0). This document exists because readme-level research is not research._

Clones (all 2026-11-18/19): `justrach/nanoui @ dd37daa`, `egoist/mygo @ main`, `zed-industries/zed @ main` (tree listing via GitHub API, individual files fetched raw; full clone deliberately avoided).

## 1. nanoui (Zig) — the architecture, from source

**Runtime packaging trick.** `src/rt.zig`: on macOS the entire backend (windowing, renderer, text, layout, paint) compiles once into `libnanoui-rt.a`; the app root links it, so editing an app's view re-analyzes only the app. An explicit SafeAllocator wraps debug builds. Consequence for us: nothing similar exists in Cipher; worth adopting later for the widget layer (measure first: our app rebuilds are already fast).

**Platform abstraction is compile-time, not dlopen-table-per-OS.** `src/platform.zig`: `switch (os)` selects `linux/`, `windows/`, `android/`, `ios/`, `macOS` modules at comptime; `runFor(seconds)` is the headless time-advance hook used between frames in tests.

**Linux = GTK, dlopen'd, hand-written tables.** `src/linux/gtk.zig` (352 lines) loads `libgtk-4.so.1` (else `libgtk-3.so.0`) plus GLib/GObject/cairo via dlopen/dlsym, declares the whole API as three Zig structs (`Api`, `Api3`, `Api4`) of `*const fn(...)` fields — the exact same *technique* Cipher uses for libwayland-client. It even loads `gtk4-layer-shell` ahead of GTK for layer-surface windows (`LayerShell` struct) — a real `zwlr_layer_shell_v1` client today, behind GTK. `NANOUI_GTK=3` forces the older path.

**How frames are presented on Linux (the part that matters).** The window's content widget is either `GtkGLArea` (GPU) or `GtkDrawingArea` (CPU/cairo) (`src/linux/surface.zig`, `src/linux/surface_gtk4.zig`). The GL path requests **OpenGL 3.0**; if GTK hands back an OpenGL ES context (NVIDIA's EGL does), the renderer is switched to ES by reading `GL_VERSION` at runtime (`src/linux/glarea.zig::start`). There is **no CPU fallback by default** on Linux — `NANOUI_RENDERER=cpu` is the opt-in. So on Linux nanoui is: GTK window → GtkGLArea → GLEW-less hand-loaded GL → their renderer → compositor (via EGL inside GTK). **nanoui has no direct Wayland/Vulkan path on Linux.** Idle CPU = 0 only because nothing ticks when nothing changes.

**Text** is their own TrueType reader/shaper (`src/ui/text_tt.zig`, `src/ui/rich*.zig`, `src/ui/shaper.zig`) with wrap caches (`wrap_cache.zig`), glyph atlas (`atlas_tt.zig`), CJK break rules (`cjk_break.zig`), and composite-glyph support. Sizable but comparable to Cipher's stack (Cipher: SFNT parser + R8 atlas — nanoui has richer shaping: grapheme clusters, bidi? they have `spans` + composite; depth here is theirs, we have parity on the basics only).

**Layout is two-pass flexbox** (`src/ui/layout.zig`): `measure` bottom-up sizes from content; `arrange` top-down distributes free space among grow boxes. Widget answers come from the previous frame's layout (widgets read last frame's rects — documented contract, avoids a second layout pass per interaction).

**Motion** (`src/ui/motion.zig`, 220 lines + 25 helpers): physical spring, mass 1, stiffness `(2π/response)²`, damping `4π·damping/response`, **stepped at 480 Hz** with semi-implicit Euler; tweens are CSS cubic-beziers; entries keyed by `wyhash(id ^ salt)` in an AutoHashMap; entries not asked for in 120 frames are pruned (bounded state); Reduce Motion drops state and jumps to target. This is a clean, copyable *design* (we implement our own).

**Tester / snapshot harness** (`src/ui/tester.zig`, `tester_script.zig`): the same `frame()` a window runs, input simulated in-process (clickText/typeText/scroll), clock advanced by `dt = 1/60`, frames rendered offscreen — Metal on macOS, **the portable CPU raster where text is nanoui's own** — to PNG. `--nanoui-snapshot=shot.png --nanoui-script="click:X;type:Y"` and a `--nanoui-wait` for async content; plus `--nanoui-play` for paced demo playback. This is the exact shape of our `cipher snapshot` target; nothing here is beyond our means (our software-shm path already renders offscreen).

**hillclimb** (`hillclimb/`): benchmark scenes built offscreen, 30 frames warmup → 300 measured ×3, lowest median kept; per-scene CPU build/layout/paint, encode, GPU timestamps, process CPU/frame, draw-item counts; compares vs previous run and best run, ±5% noise band; history.jsonl. **This is the methodology contract we should adopt for our comparative claims** (D8/D9) instead of asserting wins.

**Formal methods**: `lean-proofs/` contains real Lean 4 proofs (SurfaceLifecycle, RetainedScroll, LiveResize, BuildSplit, Speedometer3*, NanomonRankings…). Ambitious — unusual and credible; we don't need to match it to compete, but it signals the project culture: prove the model, then the pixels.

**CI for Linux** is a container with GTK 3+4, WebKitGTK, Xvfb (`tools/linux.Dockerfile`) — they test through GTK, so a virtual X server suffices. Our CI needs a headless **Wayland** compositor (wlroots headless or cage) instead; GTK can't help us.

**The 600-line limit** is enforced in build (`tools/lines.zig`, `zig build lines`) — every module stays reviewable; a policy with teeth.

## 2. MyGo (Go) — the same story one level down in effort

**Linux surface is GTK too.** `internal/linux/surface.go`: a `GtkGLArea` (GL path) or `GtkDrawingArea` (cairo CPU path) — frames drawn in memory are paced by **GTK's frame clock**; input through `GtkIMContext`; a `TickCallback` paints the CPU path before GTK repaints. No Vulkan, no direct Wayland, no scanout. purego (dlopen) instead of cgo.

**DMA-BUF exists only as a workaround** (`internal/linux/dmabuf.go`): it *disables* WebKitGTK's DMA-BUF renderer (blank windows on NVIDIA/VMs), probed via `LinkDMABUFProbe`, env kill-switch honoured. **No zero-copy import/export for app content** — same as everyone else.

**Partial redraw is implemented and tested** (`internal/gpu/damage.go`): per-buffer age tracking (`maxAges=4`), up to 8 dirty rectangles (`maxRects=8`), scissored redraws over preserved buffers, EGL buffer-age awareness. This is the most complete damage implementation in the field — directly relevant to our D4 (damage-driven redraw); we'll study its semantics before writing ours.

**Frame pacing**: both nanoui and MyGo ride GTK's frame clock for vsync — zero compensation for a compositor that throttles; we have the opposite (we own the frame callback).

**Scale check**: MyGo is thousands of files (clipboard, trays, portals, media, notifications, i18n, updater, plugins): a full platform-services framework with packaging (nsis, rpm, PKGBUILD, installers, signed updates). Feature-parity is a lifetime; depth-parity on Linux is not their game either.

## 3. GPUI (Zed, Rust) — crate-mediated but genuinely deep

**Linux backend** `crates/gpui_linux/`: `wayland-client` (Rust crates, not hand-bound), `gpui_wgpu` (**wgpu → Vulkan**), `calloop-wayland-source` event loop, `smithay`-family protocols, layer_shell support, X11 via `x11rb`, `accesskit_unix` for **accessibility on Linux**, ashpd for portals, 2627-line `wayland/window.rs` with frame-callback-gated presentation. No `wp_linux_drm_syncobj` explicit sync yet; wgpu is a translation layer on top of Vulkan (some driver wins, some overhead vs our direct binding). They support X11 as a first-class citizen; we deliberately don't.

**Reading of it**: GPUI is what we are doing, implemented in Rust with crates, hardened by Zed's user base, and optimized for a single app (an editor), not a toolkit anybody can pick up. Its Linux quality today is still visibly younger than macOS (repeat community reports of Wayland flakiness; we can't verify claims beyond code, so: noted, not relied on).

## 4. What this changes in our position (verified, not vibes)

| claim | verification | consequence |
|---|---|---|
| no Linux incumbent runs without GTK except us | nanoui/mygo source above | Cipher's zero-GTK path is the moat; keep it |
| direct Vulkan present is table stakes *for us*, unknown to them | their GL/EGL paths | our WSI work stands; D1–D4 widen the gap |
| snapshot testing is proven possible in pure Zig | nanoui testimonial `tester.zig` | D9 is schedulable now |
| damage-driven redraw is proven hard but tractable | mygo `internal/gpu/damage.go` + gpui absence | D4 needs buffer-age equivalent on our WSI path (swapchain acquire tells us image index; we can track ages) |
| frame pacing via GTK clock vs via frame callback | both | ours is more direct; explicit sync is still the true leap |
| Lean proofs are not mandatory to be credible | their hillclimb was enough to make their case | we adopt measurement discipline (D8/D9) |

## 5. Concrete adoptions & adaptations (not copies)

1. **`cipher snapshot` + Tester parity** — model exactly nanoui's `Tester` (same frame fn, scripted input, hand clock, offscreen PNG). Our CPU raster already renders offscreen; wire `ui.uiFrame` into a `test` step — see D9.
2. **Springs** — implement our own 480 Hz spring with wyhash-keyed entries and 120-frame pruning; reduce-motion aware. No emojis, no copied curve tables.
3. **hillclimb-style harness** — port the *methodology* (warmup/measure/best-of-N, ±5% noise, jsonl history) to a Cipher bench app; compare against janus scenes first (our own regression gate), then optionally nanoui scenes later with attribution.
4. **600-line policy** as review guidance in CONTRIBUTING.md (not enforced in CI yet; nanoui enforces it — consider `zig build lines` after first gallery lands).
5. **Frame callbacks** — GPUI and we both gate presents on `wl_callback.done`; D1 replaces this with syncobj-timeline acquire on capable compositors (Mutter/KWin) with graceful fallback — uncontested by anyone reviewed here.
6. **Linux CI via headless Wayland**, not Xvfb, stated explicitly to avoid nanoui's pattern.
7. **libnanoui-rt.a-style precompiled runtime** — later; measure Cipher's rebuild times first.
8. **dmabuf interchange** — MyGo only *disables* WebKit's; GPUI doesn't use it; we implement it (D3) and lead.

## 6. Licensing of influence

nanoui MIT, MyGo MIT, GPUI Apache-2.0. All permit reading and architectural influence with attribution. Cipher will implement its own equivalents (already the case for our text/VT/layout stacks) and keep THIRD_PARTY_NOTICES precise if any file is adapted directly. No verbatim ports.

## 7. What remains genuinely unknown until we build it

- nanoui's text shaping beats ours today (composite glyphs, grapheme clusters). Verify our atlas path under Arabic/Indic/emoji and close the gap — that is a real feature gap, not ideology.
- MyGo's damage.go delta semantics vs our quad batching: unverified interplay; spike required before D4 is scheduled.
- Whether `umbriel` supports `wp_linux_drm_syncobj_v1` for D1 (affects D1 fallback scope) — needs a compositor matrix test (Mutter 48+/KWin 6.2+ do).

## 8. Addendum — nanomon / nanoterm (app-level proof)

Already covered in LANDSCAPE.md; source confirms the pattern: pinned nanoui commit, `ui.Tester`-driven page tests writing /tmp PNGs, samples-only-while-visible, virtualized table, `/proc` on Linux, GTK runtime dep on Linux releases (libgtk-3-0 + fonts-dejavu-core) — i.e., the strongest shipping Zig terminal/monitor to date ships with a GTK floor we don't have.

## 9. Corrections to earlier claims (honesty log)

- LANDSCAPE.md said nanoui “Linux requires OpenGL; CPU only with NANOUI_RENDERER=cpu” — **confirmed by source** (`glarea.zig` header). The sentence stays.
- “nanoui has no direct Wayland path” — **confirmed**: GTK/EGL everywhere on Linux; no wl_surface outside GTK.
- “mygo has damage tracking” — **upgraded from suspicion to verified** (`internal/gpu/damage.go`, tests in `damage_test.go`).
- “gpui has accessibility on Linux” — confirmed: `accesskit_unix` optional dep behind `wayland`/`x11` features.
- “gpui uses wgpu” — confirmed (`gpui_wgpu` with `font-kit`).
- “nanoui renders on Metal/D3D11/CPU elsewhere” — confirmed (`metal.zig`, `d3d11*.zig`, `cpu raster via portable renderer`).

## 10. Provenance

- `git clone --depth 1 --filter=blob:none https://github.com/justrach/nanoui` → `dd37daada8aee51bbd45ff4bd2d3681531a5d2ab` (2026-11-16)
- `git clone --depth 1 --filter=blob:none https://github.com/egoist/mygo` → HEAD @ 2026-11-18 (see `git log -1` in clone)
- `curl` raw.githubusercontent.com/zed-industries/zed/main (Cargo.toml, linux/wayland.rs, wayland/display.rs, 2627-line wayland/window.rs) + GitHub git-trees API (tree truncated at 5364 entries; enough to locate crates)
