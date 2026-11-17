# DR-004: Immediate-mode UI over a from-zero flexbox layout, drawn as GPU quads

## Decision

Two layers:

1. `src/ui/layout.zig` — flexbox subset (row/column, gap, padding,
   fixed/grow/fit sizes, cross-axis stretch), implemented as two passes:
   `measure` (bottom-up intrinsic sizes) and `arrange` (top-down rects).
2. `src/ui/ui.zig` — immediate-mode API (`begin/panel/label/button/spacer/end`)
   over a per-frame arena; `end()` runs layout and emits `DrawCmd`s
   (`rect` with color, `text` run). Widget hit-testing reads rects persisted
   from the previous frame (`prev_rects`), since the arena is reset each frame.

Rendering: `buildQuads()` in `root.zig` maps rects to quads sampling the
reserved white atlas texel (0,0) (coverage 1 → solid vertex color) and text
runs to per-glyph quads; one `vkCmdDraw` renders all quads through the text
pipeline (per-vertex RGBA color), then the frame is copied to wl_shm.

## Why immediate mode

Matches the zero-dependency/from-zero goal and keeps the demo stateless per
frame; ids are sequential per frame and rects persist for input.

## Evidence

- Layout exact: column pad 8/gap 10 → child A `(8,8,100,20)`, B `(8,38,384,50)`;
  row grow over 300px with fixed 100 → grow1=66.67, grow2=133.33.
- UI: panel+label+button emits exactly 4 draw cmds (2 rects, 2 texts);
  button rect `(12,43,276,39)`; click returns true only when pressed at the
  button center (frame 2), false elsewhere (frame 3).
- Live app: `sifr: render path = vulkan-gpu-ui`, `WAYLAND_PROTOCOL_OK frames=24`
  on umbriel with NVIDIA and lavapipe, exit 0.

## Wayland protocol bugs fixed along the way (found via strace)

- `get_toplevel` was sent to `xdg_wm_base` opcode 1 — that opcode on
  `wm_base` is `create_positioner`; the compositor made the object a
  positioner and rejected the next request
  (`invalid arguments for xdg_positioner#10.set_anchor_rect`). Correct call:
  `xdg_surface.get_toplevel` (opcode 1 on xdg_surface).
- `get_keyboard`/`get_pointer` were sent to the `wl_seat` **global name**
  instead of the bound seat object → compositor reset (EPIPE). Fixed.
- Keyboard event indices corrected: `key@1`, `state@2` (time@0).
