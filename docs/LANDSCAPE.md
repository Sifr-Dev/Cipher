# Cipher — the landscape, the verdict, the scope

_2026-11-18 · researched with primary sources (each linked) and local measurements · this document is the answer to: “is the current project scoped right, or do we scrap it and build from scratch?”_

## 0. What this document is

A full-stack audit of every serious competitor to what Cipher wants to be, a
depth audit of Cipher itself, a verdict on keep-vs-scrap, and the concrete
scope that follows. It contains:

- what was measured locally, on which hardware (RTX 4060 Laptop, Wayland
  compositor `umbriel`, Zig 0.17.1, Arch);
- what was read from competitors’ own repositories/pages (attributed inline);
- what is *not* measured yet (explicitly marked, not padded);
- the verdict, the architecture, the roadmap, the kill-criteria.

## 1. Measured facts about Cipher today (local, 2026-11-18)

| fact | value | method |
|---|---|---|
| terminal glyph render on Wayland | works, WSI direct present | live runs, exit 0; `render path = vulkan-wsi` in logs |
| release binary — janus | **312 KB** | `zig build -Doptimize=ReleaseSmall` 2026-11-18 |
| release binary — nocturne | 349 KB | same |
| release binary — rex (CLI) | 216 KB | same |
| unit suite | 41/41 runtime tests pass (direct runner); other suites green | 2026-11-18; cold `zig build test` prints spurious `failed command` lines, exit 0 — **pre-existing runner quirk, reproduced on unmodified HEAD** |
| compositor | umbriel (wlroots-based) | live |
| fallback path | wl_shm + software raster, pixel-identical dump to GPU path | `CIPHER_DUMP_FRAME` |
| zero-copy GPU→compositor | yes, `VK_KHR_wayland_surface` + swapchain present, no readback | `src/gpu/vulkan/swapchain.zig` |
| VT stack | xterm-grade parser, grid, kitty keyboard protocol, mode 2026 | unit tests + live negotiation in janus |
| idle CPU | **not measured** (expected ~0 given poll-blocking loop — unverified) | — |
| RSS, GPU app (debug build) | ~270 MB (debug symbols dominate) | `JANUS_EXIT rss_kb=` |
| accessibility (AT-SPI2) | **none** — deferred per owner | — |

### Measured on this machine (2026-11-19, nanoui hillclimb, unmodified)

CPU-raster scenes (their Linux path without Metal), MY host:

| scene | nanoui frame CPU (median) | build | layout | paint |
|---|---:|---:|---:|---:|
| text (300 changing labels) | 0.374 ms | 0.042 ms | 0.121 ms | 0.181 ms |
| boxes (600 shadowed boxes) | 0.238 ms | 0.074 ms | 0.051 ms | 0.085 ms |
| dashboard (12 cards) | 0.104 ms | 0.015 ms | 0.023 ms | 0.057 ms |

Caveats recorded honestly: no GPU timestamps on this path (their Metal numbers
are theirs, not ours); encode CPU on the CPU raster is 4–75 ms (that is the real
cost of the shadow/blend rasterizer in software, not of frame logic); our
Cipher comparison does **not exist yet** — there is no Cipher hillclimb
harness, so any "we are faster" claim today would be fabrication. Their
CPU-frame numbers reproduce on our hardware; our verdict in §4 therefore rests
on *scope/depth judgment*, not on measured head-to-head speed. Until D8/D9
lands, treat every comparative speed claim as provisional. Encode/render-path
differences (GTK+EGL vs direct WSI) are unmeasured in both directions.

Reading: the hardest layers are done and verified. The gaps are almost all
*breadth* (product surface) and a handful of strategic *depth* moves (§6–§7).

## 2. The field

### 2.1 Qt (C++ / QML) — https://www.qt.io/development/qt-framework
World-class breadth: widgets, Qt Quick (QML + scene graph), 3D, charts,
networking, SQL, Multimedia, accessibility (UIA/AT-SPI/IAccessible2), iOS/
Android, embedded, MCUs, automotive, functional safety, 1B+ devices claimed.
C++ since 1991, Qt 6 current. **Depth**: wayland via QPA plugins; RHI over
Vulkan/GL/D3D/Metal. **Weight**: megabytes of abstraction between app and
pixel; licensing model (commercial/LGPL) is a cost gate; install footprint is
large by design. Not a display-technology problem — a product-army problem.

### 2.2 GTK (C, LGPL) — https://www.gtk.org/
GTK 4.22.5 stable (Nov 2026), GNOME’s toolkit; C API, bindings in many
languages; GDK → wayland-client (dlopen’d), GSK renderer (GL/Vulkan/cairo).
Broad Linux coverage, AT-SPI2 accessibility, native-ish on Linux. **Weight**:
GLib/GObject object system, dynamic casts, signal machinery; binary and RAM
cost of a “simple” app is GTK + GSK + GL stack; portability off Linux is
second-class. Same abstraction-fat pattern as Qt, in C instead of C++.

### 2.3 GPUI (Rust, Zed) — https://gpui.rs/ · https://github.com/zed-industries/zed/tree/main/crates/gpui
Hybrid immediate/retained tree; Entity model with explicit lifetimes;
tailwind-style method chains; virtualized lists; wayland+x11 windowing
(rust wayland-client crates), DirectWrite/Win32 on Windows, Metal on macOS;
tightly coupled to Zed (pre-1.0, breaking changes frequent). **Depth**:
genuinely deep for its backends (ownBlade-style GPU UI) — but the framework
*is* Zed’s editor needs, not a general-purpose framework yet, and its memory
discipline is Rust’s. Excellent engineering benchmark for us; not a
general “any dev can use today” story.

### 2.4 MyGo (Go, no cgo) — https://github.com/egoist/mygo · https://mygo.egoist.dev/
Single Go binary; native UI drawn by the framework itself on the GPU (no
webview required); flexbox/grid, widgets, text editing + IME, virtualized
lists, SVG icons, animations, Liquid Glass, reader-mode, IPC typed
TypeScript client for optional web pages, huge system-integration surface
(menus, tray, notifications, shortcuts, deep links, updates), iOS/Android.
Measured on the author’s hardware: release counter ~14 MB (vs nanoui 4 MB),
apps ~11.8 MB “mygo” vs ~0.7 MB nanoui (their numbers, their machine —
Apple M3 Ultra, see §2.5). **MyGo is Go deeply committed to “web tech, but
native-drawn”; it is the design sibling nanoui ported to Zig.**

### 2.5 nanoui (Zig 0.17 — closest to us in *implementation*) — https://github.com/justrach/nanoui
Desktop/mobile apps in Zig with no webview required (web pages optional):
flexbox, glyph atlas, animations, GPUI-style method chains, virtualized
lists, SVG, IME on macOS/iOS/Linux, Liquid Glass, kit components, motion,
600+-line limit enforced in CI, Lean 4 specification proofs, hillclimb
benchmarks vs MyGo. **Platform mechanics**: Metal+CoreText on Apple;
**GTK 4 (else GTK 3, dlopen’d) + GtkGLArea OpenGL on Linux**; D3D11/CPU on
Windows; NativeActivity on Android. ~0.7 MB release apps. Real apps shipped:
nanoterm (terminal, Warp-like blocks + ACP agent), nanomon, nanostudio,
nanofly, nanomail, nanolight, nanodocs, nanobrowser (a Zig browser engine).
Apps ~0.7 MB; gallery tests; `nui` CLI scaffolds/checks/snapshots apps.

Their own benchmark table (their M3 Ultra; horizontal-frame medians; lower is
better) — *attribution: justrach/nanoui README, retrieved 2026-11-18; see
external claim as attributed, not reproduced; see docs/INTERNALS.md for what
their Linux path really does (GtkGLArea/OpenGL 3.0, GTK-clock frame pacing,
no direct Wayland/Vulkan)*:

| scene | frame CPU nanoui | frame CPU mygo | GPU nanoui | GPU mygo |
|---|---:|---:|---:|---:|
| 600 shadowed boxes | 0.061 ms | 0.301 ms | 0.140 ms | 1.616 ms |
| 300 changing labels | 0.108 ms | 0.418 ms | 0.065 ms | 0.056 ms |
| 1000-row scroll | 0.315 ms | 2.076 ms | 0.055 ms | 0.122 ms |
| 100k-row virtual list | 0.060 ms | 0.367 ms | 0.046 ms | 0.045 ms |
| 12-card dashboard | 0.015 ms | 0.087 ms | 0.098 ms | 0.295 ms |

**What nanoui does that we do not**: motion/springs, Liquid Glass, SVG,
virtualized lists, kit components (dialogs/toasts/tabs/selects), IME preedit,
web pages, accessibility (Apple only), `nui` CLI with snapshot testing,
mobile, a Lean proof portfolio, a shipped-apps ecosystem, hillclimb.
**What we do that nanoui does not**: Linux display path with **no GTK at all**
— dlopen’d `libwayland-client` with hand-verified `wl_interface` tables +
`dlopen`’d `libvulkan.so.1` driving a swapchain to the compositor (WSI);
a terminal stack (VT + kitty protocol); a FLAC decoder; a wl_shm software
fallback with pixel-parity. On Linux nanoui still pays GTK+GSK+GL for every
window; Cipher pays system `libwayland-client` + ICD only.

### 2.6 egui (Rust immediate-mode) — https://github.com/emilk/egui
Immediate-mode, winit+wgpu; excellent for debug UIs/tools; not a desktop-app
framework (no IME parity, no system integration, wgpu abstraction over APIs).

### 2.7 Electron / Tauri — the incumbent default (context, not a target)
Hundreds of MB, Chromium per app. “Zero install footstep” is the explicit
differentiation of everyone in §2.3–2.5 — and ours.

## 3. Depth audit — how far down does each stack actually go?

| layer | Qt | GTK | GPUI/zed | nanoui | **Cipher** |
|---|---|---|---|---|---|
| window/comp channel | wayland-client (plugin) | GDK→wayland-client | Rust wayland-client | **dlopen’d GTK** → wayland | **dlopen’d libwayland-client, in-tree generated interface tables** |
| present path | RHI (抽象) → Vulkan/GL | GSK → GL/Vulkan/cairo | blade/Vulkan | **GtkGLArea OpenGL** | **direct `VK_KHR_wayland_surface` swapchain present — zero readback** |
| text | Qt text engine/HarfBuzz | pango/harfbuzz | own + font-kit | own TT reader | **own TrueType parser + rasterizer + R8 atlas** |
| shaders | GLSL→spirv | GLSL | WGSL-ish/blade | GL+CPU paths | **own GLSL, embedded; own pipeline layout** |
| idle behavior | retained, ticks | retained-ish | frame-driven | event-driven | **frame-driven; poll-blocking; ~0 idle (unmeasured)** |
| VT/terminal | none | none | none | nanoterm (rich) | **full xterm parser + kitty protocol (janus)** |
| explicit sync (wp_linux_drm_syncobj) | Qt 6.10+ partial | GTK 4.14+ partial | no | no | **no — roadmap (§7)** |
| direct scanout, no compositor | partial (eglfs) | no | no | no | **no — roadmap (§7)** |

Where Vulkan stands (from https://vulkan.org — page 403 for scraper, spec
well-known): VK_KHR_display/VK_EXT_acquire_xlib_display allow presenting
**without a compositor** on DRM connectors; VK_KHR_wayland_surface for the
composited path; VK_KHR_win32_surface elsewhere. wl_shm remains the software
floor. Explicit synchronization on Wayland (`wp_linux_drm_syncobj_v1`) lets a
compositor and client hand off GPU timelines tear-free with lower latency
than implicit sync — adoption is real in 2026 (Mutter 48+, KWin 6.2+) but
**not required** for correctness; it is the latency/power frontier.

X11 (https://www.x.org/) is effectively in maintenance; XWayland remains the
bridge — Cipher does not implement X11 as a target (deliberate; wayland-only
on Linux, with XWayland for legacy clients as-is).

Metal (https://developer.apple.com/metal/) is Apple’s tightly-integrated API;
not a Linux target; relevant if/when a macOS backend is attempted — Cipher is
Linux-first by design; Metal support is a port, not a rewrite (the renderer
is small: one text pipeline + solid fill; swapchain equivalent = CAMetalLayer).

## 4. Verdict: keep. Scrap the framing, not the foundation.

**Cipher should NOT be scrapped.** Reasons, with evidence:

1. **The hardest, riskiest layers are built and verified**: the hand-rolled
   Wayland client (interface tables verified byte-identical to scanner
   output, listener alignment crashes found and fixed live, UAF heap-boxed,
   all exit 0 on umbriel), the Vulkan loader and WSI swapchain (pixel-identical
   readback vs WSI), the own text stack, the VT stack — none of these exist in
   nanoui’s Linux path (which pays GTK), and none exist in Rust GUI frameworks
   without pulling crates that wrap the C lib.
2. **The competitive opening is precisely where we are deep**: zero-install
   apps on Linux with **no toolkit anywhere in the process**, <5 MB binaries,
   measured idle ≈ 0 — Qt/GTK cannot structurally follow (C++/GLib object tax),
   MyGo/nanoui chose GTK on Linux (nanoui) or webview-hybrid breadth,
   GPUI is Zed’s editor needs.
3. **What’s missing is mostly breadth**, and breadth is mechanical once the
   core is sound: springs/motion, SVG, virtualized lists, dialog/toast/tab
   kit, IME, AT-SPI2, multi-window, fractional scale, a test harness, docs,
   CLI, examples. Weeks-to-months, not years — and every one is individually
   verifiable.
4. **The grand ambition is *not* sci-fi**: explicit-sync presentation,
   compositor-free direct scanout as a framework mode, DMA-BUF interchange,
   damage-driven redraw, and a startup-to-pixel budget are all real, all
   unstandardized by incumbents, all achievable on top of what exists.
5. Scrapping would trade a verified driver/protocol port for a restart —
   the exact “college-student rewrite” failure mode this document exists to
   end. **No reset.** The cleanup list is instead: (a) reorganize into the
   layered architecture of §8; (b) retire the kept-for-reference legacy
   wire client and the rex socket protocol (already folded in-process this
   week); (c) stop shipping Janus/nocturne as “demos” and start shipping them
   as *reference apps* with measured numbers.

Abandoning Wayland or Vulkan “for our own creations” is **rejected**: driver
ecosystem, compositor interop, the security boundary, and the payoff math all
say the lever is *on top of and alongside* them, not instead of them. Metal is
optional future; Windows backend would come via Win32+Direct3D (D3D11 flip
chain like nanoui) — or not, if Linux remains the theatre. (Owner decision,
recorded honestly.)

## 5. What “the framework any dev can use” must have that we don’t (yet)

| # | gap | who has it | effort class |
|---|---|---|---|
| 1 | `cipher new` CLI: scaffold a buildable app, check toolchain | nui (nanoui), mygo | days |
| 2 | snapshot/offscreen test harness (`nui snapshot`) + UI-level Tester | nui | weeks |
| 3 | motion system (springs, presence, stagger) | nanoui/GPUI-motion | weeks |
| 4 | kit components: dialog, toast, tabs, select, popover, tooltip mgmt | nanoui Kit | weeks |
| 5 | virtualized list | nanoui/GPUI | weeks |
| 6 | SVG rendering | nanoui | weeks |
| 7 | images → GPU textures | nanoui | weeks |
| 8 | IME preedit (zwp_text_input_v3) + Linux IM integration | nanoui (partial), Qt, GTK | months |
| 9 | AT-SPI2 accessibility tree + events | Qt/GTK (mature) | **months** |
| 10 | multi-window + popups via subsurfaces/layer-shell | all | weeks |
| 11 | system integration: notifications (org.freedesktop.Notifications), tray, portals (file picker) | Qt/MyGo/nanoui | weeks–months |
| 12 | fractional scaling, output hotplug, xdg-decoration | all | weeks |
| 13 | CI matrix: lavapipe + at least one real compositor (umbriel in container), GPU-optional | nanoui (linux.Dockerfile) | weeks |
| 14 | docs good enough for a stranger (getting started, reference, examples) | partial (README + ARCHITECTURE) | weeks |
| 15 | example gallery (≥5 apps of distinct kinds: terminal, monitor, player, launcher, dashboard) | CipherDesk (2) + hello | months |

## 6. The depth roadmap — "leaps beyond" made concrete

Each item names the primitive, the protocol, the promise, and the proof.

**D1. Explicit synchronization by default** (`wp_linux_drm_syncobj_v1` +
Vulkan external timeline semaphore export/import). Client renders → exports
syncobj → compositor acquires it; zero implicit-sync guesses. On compositors
without the protocol: automatic fallback to implicit. *Promise*: lower frame
latency, no tearing, lower GPU power. *Proof*: vkQueuePresentKHR with acquire
timeline; wp_linux_drm_syncobj event protocol; measure frame pacing vs
umbriel/Mutter.

**D2. Compositor-free direct scanout** (`VK_KHR_display` / GBM+DRM atomic as
a second backend). Kiosk, HMI, digital signage, embedded: the app owns the
display. *Promise*: Linux fullscreen apps with the binary-size and latency of
a TUI and the pixels of a GPU app — a category no incumbent toolkit occupies
cleanly (eglfs is Qt-only and immature; GTK cannot). *Proof*: same `cipher`
module, two present backends behind one interface; atomic modeset; tear-free
flips; fallback to composited if DRM master unavailable.

**D3. DMA-BUF interchange** (`zwp_linux_dmabuf_v1` both directions). Export
our rendered frames for zero-copy screen recording / picture-in-picture /
compositor optimizations; import client buffers (thumbnails, camera, video)
without CPU touch. *Proof*: dmabuf modifier negotiation; vkAllocateMemory
export; wl_buffer release semantics honored.

**D4. Damage-driven rasterization.** Today the software path redraws and
memcpy’s the full buffer every commit; the GPU path draws all quads every
frame. Track a dirty-rect ledger per quad/glyph; skip frames with empty
dirty set; present partial wl_shm buffers via damage regions; on GPU, skip
draw call ranges. *Promise*: idle apps present exactly nothing. *Proof*:
frame-count under zero input (should be 0 beyond cursor), battery/CPU delta,
`CIPHER_DUMP_FRAME` diffs.

**D5. Subsurface-layered popups & overlays** (`wl_subsurface`,
`zwlr_layer_shell_v1` for layer surfaces). Menus/tooltips that composite
correctly, position independent of parent repaints, no override_redirect.
*Promise*: frame-consistent popups, zero flicker. *Proof*: subsurface sync
parent/child commits; umbriel + Mutter test.

**D6. Fractional scale + color management honesty** (`wp_fractional_scale_v1`,
`wp_viewporter`; `wp_color_manager_v1` when ready). Correct HiDPI text instead
of integer-only; HDR pipeline when compositors expose it. *Promise*: 1.25×/
1.5× displays that aren’t blurry. *Proof*: fractional-scale roundtrip test
with umbriel at scale 1.25; golden-frame dump diff.

**D7. AT-SPI2 from the ground up** (no toolkit to lean on — we speak
`org.a11y.Bus` + AT-SPI protocol directly, dlopen’d, like everything else).
*Promise*: a fully Zig-native accessible tree: roles, names, states,
actions, focus events. Orca-verification required before any “accessible”
claim. *Proof*: Accerciser/Orca read of janus + hello apps; CI smoke test
via AT-SPI XML.

**D8. Startup-to-pixel budget + measured idle ≈ 0.** execve → first frame
< 100 ms cold (ReleaseSmall), < 16 ms warm cache; idle RSS < 15 MB; idle CPU
= 0 in poll. *Proof*: `cipher bench` (exists) + a scripted harness; published
table with methodology (same machine class as nanoui’s hillclimb).

**D9. Snapshot-as-contract testing.** Every app + widget scene renders
headless to PNG; CI compares against golden images with perceptual tolerance;
`cipher snapshot --script` for scripted interaction (click/type/key). This is
how we keep Qt/GTK-grade regressions out without their C++ army. *Proof*:
canary scene that fails when a glyph raster changes.

## 7. Architecture: three layers, one binary, zero runtime deps beyond the system

```
apps (janus, nocturne, examples/*)        — ship themselves; framework ships none
  └─ Cipher UI   immediate-mode toolkit     — widgets, theme, motion, a11y hooks, CLI
       └─ Cipher Core  deep stack           — wayland client, vulkan, VT, text, shm fallback
```

Rules that make it a framework, not a demo:
1. **Every public surface is documented + tested** (no “internal” modules apps
   import); `term_api.zig`/`cipher.zig` style façade discipline; missing
   feature ⇒ either added or filed, never imported from src/ internals.
2. **The framework never links third-party C libraries at build time** —
   system libs are dlopen’d at runtime (wayland-client, xkbcommon, vulkan;
   optional: AT-SPI libdbus, portal client libs). Build requires only Zig.
3. **Zero install footstep**: a release artifact is one static-ish binary;
   Wayland libs are already on any Wayland system; software-shm fallback
   covers missing ICDs.
4. **A binary you can point at any compositor**: umbriel (wlroots), Mutter,
   KWin, Hyprland — behavior identical, only protocol versions differ.

## 8. Execution order (each step independently verifiable; no “big bang”)

1. (done) module split of Janus; framework consumer packaging.
2. docs: getting-started for strangers + examples gallery (hello → clock →
   text-view → monitor → player); each example runs in CI (headless dump).
3. `cipher` CLI: `new`/`build`/`run`/`doctor` (Zig-native; checks zig,
   wayland socket, libvulkan, font, ICD — remediation hints; no network).
4. D8 measurement harness (bench in CI, published JSON; honest caveats) —
   establishes the “we beat it or we say so” culture with receipts.
5. Motion + kit components (#3,#4) + snapshot testing (#9 → D9).
6. Multi-window + popups (D5), fractional scale (D6).
7. IME (#8) → AT-SPI2 (D7) — the two “months” items; gated on 5–6.
8. D4 damage-driven redraw; D1 explicit sync; D3 dmabuf; D2 direct scanout.
9. Comparative benchmark paper vs nanoui/mygo/gpui/Qt/GTK on identical
   scenes (their hillclimb, our machine class) — published with methodology.

## 9. Honest risks & kill-criteria

- **Compositor fragmentation**: only umbriel + CI lavapipe testable locally;
  Mutter/KWin behavior may differ (frame-callback batching, damage
  semantics). Mitigation: protocol-conformance smoke tests; explicit-sync as
  opt-in until soaked.
- **Zig churn**: 0.17.x tracked; API drift will bite; mitigation: pin, and
  CI on minimum_zig_version.
- **AT-SPI2 cost**: if D7 slips past ~2 months, accessibility ships as
  “partial (roles/text only, no custom actions)” and is labeled so. Never
  claim more than tested.
- **nanaoi velocity**: justrach’s project ships weekly; matching *breadth*
  is a losing race if we chase it; matching **depth + zero-dep Linux +
  verifiable receipts** is winnable. Benchmark, don’t mimic.
- **Kill-criteria for the “revolution” claim**: if after D1–D6 we cannot
  show (a) <30 MB RSS idle, (b) 0.0% idle CPU measured, (c) startup-to-pixel
  <100 ms, (d) a snapshot-verifiable app gallery, the framework is an
  excellent regional player, not a “new standard” — and we say exactly that.

## 10. Source verification

Every architectural claim in §2–§3 that depends on upstream internals is now
verified against shallow clones, in **docs/INTERNALS.md** (file-level
citations, licenses observed, corrections logged in its §9). Read that file
before repeating any "nanoui/mygo/gpui does X" statement.

## 11. Sources

Local: `sifr-native` tree (src/gpu/vulkan/*, src/os/linux/wayland/*,
src/term/*, docs/ decision records), 2026-11-18 live runs (release binaries
312/349/216 KB ReleaseSmall; exit 0; frame dumps), `umbriel` compositor.
External (retrieved 2026-11-18): justrach/nanoui README
(https://github.com/justrach/nanoui), justrach/nanoterm README,
egoist/mygo README (https://github.com/egoist/mygo), gpui.rs + zed
gpui README, zed GPUI crate page, qt.io development page, gtk.org,
x.org wiki, developer.apple.com/metal, vulkan.org (403 for automated read;
spec referenced from knowledge), Wayland protocol docs (wayland.app).
Nanoui benchmark numbers above are **theirs**, unverified by us — reproduced
only as attribution; no comparative claim is made here without our own
measurement, per D8/D9.
