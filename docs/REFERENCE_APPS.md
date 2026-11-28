![SIFR identity V2 — the cipher disk at shift zero](.github/assets/readme-header-dark.png)

# Reference applications and what Phantom is not

Research recorded before any architecture decision, so that the design is deliberate rather than accidental.

## References studied

**nanoui** — `https://github.com/justrach/nanoui` (Zig 0.17, ~0.7 MB apps, one dependency, MIT)
- Views are immediate mode: a function of app state, re-run on each event.
- Linux backend: **GTK 4, or GTK 3 when absent**, both loaded via `dlopen` at run time — never linked, never a build-time requirement. Windows are Wayland clients when the session is Wayland. Input methods (pinyin/IM), clipboard, dialogs, layer-shell surfaces all come from the platform.
- Native UI is drawn through **OpenGL inside a `GtkGLArea`**, with its own GL loader; the CPU renderer (`NANOUI_RENDERER=cpu`) produces pixel-identical output.
- Its own TrueType reader (`src/ui/tt/`), own flexbox (`src/ui/layout.zig`), own Gaussian shadows, own SVG/icons, own motion framework (`ui.motion`), offscreen `ui.Tester` for screenshot/widget tests without a window.
- A1: Liquid Glass is their rendering, not ours; do not copy visual language.
- A2: accessibility is documented as not-yet on Linux and Windows — a genuine opening for Phantom to be first to own that tree.

**mygo** — `https://mygo.run` and `https://github.com/egoist/mygo` (Go, ~7 MB apps, MIT)
- Same architecture shape in Go: native UI drawn on the GPU (Metal/D3D/OpenGL), web frontends via the system webview, typed IPC, single-binary apps with installers and auto-updates.
- Screen-reader support on the docs page is a promise we should meet and exceed.

## What Phantom is

Phantom aims at the same native-UI-on-the-GPU experience with **nothing between the app and the hardware except the GPU driver itself** — no GTK, no X11, no WebKitGTK, no toolkit, no generated protocol bindings, and no C in our tree.

| Layer | nanoui | mygo | Phantom (committed) |
|---|---|---|---|
| Windows | GTK via dlopen | platform SDKs | Raw Wayland wire protocol, ours |
| GPU | GL in GtkGLArea | Metal/D3D/OpenGL | Our own loader for the driver; software present as floor |
| Text | own TrueType reader | platform text stack | Own TrueType reader + atlas |
| Layout | own flexbox | own flexbox-ish | Own flexbox |
| UI model | immediate mode | immediate mode | immediate mode |
| IPC/types | nanoui.js generated | typed client generated | TBD |
| a11y | not yet (Linux, Windows) | screen-reader claims | Own tree from day one |

Trade-off, stated honestly: by not using GTK, Phantom owns the Wayland surface protocol, the input-method problem, the clipboard, the accessibility bridge, and the compositor negotiations — all of which nanoui/mygo lean on their platforms for. That is the point of the project: the complete path to desktop superiority, not a shortcut around it. The risk is real (input methods and a11y are hard); the payoff is a framework that owes nothing to anyone above the driver.
