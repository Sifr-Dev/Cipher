# Getting started with cipher

One binary, zero install footstep. Phantom apps are single executables that need
nothing at runtime but a Wayland session and (for the GPU path) a Vulkan ICD.
No GTK, no Qt, no Electron, no toolkit of any kind inside the process.

This guide is for someone who has never seen this repo. Every command below was
run and verified on Linux with Zig 0.17.1 (Arch, Wayland compositor `umbriel`,
NVIDIA RTX 4060). If a step fails for you, `cipher doctor` (below) tells you
which piece your machine is missing.

## 0. Requirements

- **Zig 0.17.1** from https://ziglang.org/download/ (or `zigup`)
- A **Wayland** session (any compositor: GNOME, KDE Plasma, wlroots-based…)
- A **Vulkan ICD** matching your GPU (NVIDIA/AMD/Intel), or the software ICD
  (`vulkan-swrast` on Arch, `mesa-vulkan-drivers` on Debian) — cipher also
  runs with zero GPU via its wl_shm + software-raster fallback and it's fine
- **No installed font is required for the default UI.** Instrument Sans and
  its SIL OFL license are compiled into every app. Use `Options.font_data` for
  embedded SFNT bytes or `Options.font_path` for an explicit external font.
  An explicitly supplied font must load successfully; it is never silently
  replaced by a different fallback font.

Platform support today: **Linux**. macOS/Windows ports do not exist yet —
this document does not pretend otherwise.

## 1. Build the framework + CLI

```sh
git clone https://github.com/Sifr-Dev/Phantom.git Cipher
cd Cipher
zig build          # builds zig-out/bin/{sifr,cipher-hello,cipher}
```

`cipher` is the framework's command-line tool:

```sh
./zig-out/bin/cipher version    # cipher 0.1.0 (zig >= 0.17.1)
./zig-out/bin/cipher doctor     # checks this machine, prints what's missing
```

Expected doctor output on a ready machine (all-✓ is exit 0):

```
  ✓ zig 0.17.1
  ✓ wayland session
  ✓ libwayland-client
  ✓ libxkbcommon
  ✓ vulkan: N device(s), VK_KHR_wayland_surface present
  ✓ font found
cipher doctor: OK — this machine can build and run cipher apps.
```

## 2. Scaffold your first app

```sh
cd /wherever/you/keep/projects
CIPHER_HOME=/path/to/Cipher /path/to/Cipher/zig-out/bin/cipher new my-app
```

(or put `Cipher` next to your projects folder and just run
`cipher new my-app` — the tool finds a `../Cipher` sibling automatically,
or use `--cipher PATH`)

Output:

```
created my-app/ — an app that already runs.

  cd my-app
  zig build run
```

What you get: `build.zig` (a `cipher` path dependency), `build.zig.zon`
(with a correct fingerprint and Zig ≥ 0.17.1), `src/main.zig` (a window with a
panel, a label and a button — **Esc quits**), `README.md`, `.gitignore`,
`AGENTS.md` (notes for coding agents working in the repo).

## 3. Run it

```sh
cd my-app
zig build run
```

The window opens on your compositor; frames go straight from Vulkan to the
compositor via the swapchain (`render path = vulkan-wsi`).

Headless/CI check:

```sh
CIPHER_MAX_FRAMES=2 zig-out/bin/my-app
# cipher: WAYLAND_PROTOCOL_OK frames=2   → exit 0
CIPHER_DUMP_FRAME=/tmp/frame.ppm CIPHER_MAX_FRAMES=5 zig-out/bin/my-app
```

## 4. Edit it

`src/main.zig` — the app is two callbacks on a plain `App` struct:

```zig
pub const App = struct {
    pub fn onEvent(self: *App, rt: *cipher.runtime.Runtime, ev: cipher.input.Event) void {
        // keys, wheel, mouse, resize, paste, close, focus
    }
    pub fn onFrame(self: *App, rt: *cipher.runtime.Runtime) !void {
        const u = rt.ui() orelse return;   // framework UI services (immediate-mode)
        try u.panel(.{ .fixed = 460 }, .{ .fixed = 170 }, 16, 12);
        try u.label("hello", cipher.ui.COLOR_TEXT);
        try u.label("…", cipher.ui.COLOR_TEXT_DIM);
        if (try u.button("Click")) { /* ... */ }
        u.endPanel();
    }
};
```

The framework never paints unless you ask: widgets are drawn through the same
quad pipeline as everything else. There is no virtual DOM, no reconcile, no
runtime GC pause, no hidden framework thread — `onFrame` is your draw call.

Layout primitives: `u.panel(size, padding)`, `.dir = .row/.column`, labels,
buttons, sliders, checkboxes, tabs, text inputs, lists, progress bars…
(`cipher.widgets`). Keyboard/mouse/wheel come through `onEvent`; drag-select
and scrollback are framework-provided.

## 5. Ship it

```sh
zig build -Doptimize=ReleaseSmall
```

One binary in `zig-out/bin/`. On Wayland systems with a Vulkan ICD you have
everything it needs; the binary itself carries your app, the framework and the
default font. Inspect the executable your build actually produces:

```sh
ls -lh zig-out/bin/my-app
readelf -d zig-out/bin/my-app
```

On the tested Linux x86_64 configuration, the dynamic dependencies are the
system C library and ELF loader; there is no separately installed Phantom,
Zig, Qt or GTK runtime. The compositor, system libraries and applicable GPU
driver remain platform requirements.

Envs worth knowing: `CIPHER_MAX_FRAMES`, `CIPHER_DUMP_FRAME`,
`CIPHER_FORCE_SOFTWARE=1`, `CIPHER_DISABLE_WSI=1`, `CIPHER_UI_HEIGHT`.

## 6. Learn the framework

- `docs/ARCHITECTURE.md` — how the layers fit
- `docs/LANDSCAPE.md` + `docs/INTERNALS.md` — where cipher stands vs Qt/GTK/
  GPUI/MyGo/nanoui (with measured numbers)
- `apps/hello.zig` (in this repo) — the full widget tour;
  `zig build run-hello`, Esc quits, frames build every widget kind
- `examples/` — destined for a gallery (in progress, honest gap)

## 7. What cipher is *not* today (honest list)

- Not a widget-library completion of Qt/GTK — the kit is young (buttons,
  lists, tabs, text inputs…); motion/kit components/dialogs land via the
  roadmap (see `docs/LANDSCAPE.md` §5 and §8).
- Not accessible yet — AT-SPI2 work is scheduled (D7); nothing is claimed
  accessible today.
- Not cross-platform yet — Linux only today.
- Not a webview — if you want HTML, this is the wrong framework.
- Not "compatible with everything that already runs under Wayland" — it is a
  framework for building *new* apps, not a theme engine.

## 8. If something breaks

1. `./zig-out/bin/cipher doctor` — machine-level prerequisites
2. Run with `WAYLAND_DEBUG=1` (protocol-level Wayland errors)
3. `CIPHER_FORCE_SOFTWARE=1` — rules out GPU/driver trouble
4. File an issue with `cipher doctor` output + the failing command
