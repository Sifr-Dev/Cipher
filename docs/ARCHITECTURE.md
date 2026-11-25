# Architecture

## Modules

| Module | Role |
|---|---|
| `src/root.zig` | App entry. Connects to Wayland, runs the frame loop, declares the demo UI (panel, labels, button), converts draw commands to GPU quads, presents. |
| `src/os/linux/wayland/client.zig` | Handwritten Wayland wire client: Unix socket connect, 8-byte header framing (object id, size+opcode), SCM_RIGHTS fd passing, memfd + mmap wl_shm buffers, event decoder with fixed24.8, object id allocator. |
| `src/gpu/vulkan/loader.zig` / `device.zig` | `dlopen("/usr/lib/libvulkan.so.1")` + `dlsym` function table; hand-written `extern struct` Vulkan types (layouts diffed against `/usr/include/vulkan/vulkan.h` with gcc offsetof — 114 checks, all match); instance/device/queue creation. |
| `src/gpu/vulkan/frame.zig` | Offscreen graphics pipeline (fullscreen triangle, push-constant fragment shader) → `vkCmdCopyImageToBuffer` → host-visible buffer. Exact-pixel tested. |
| `src/gpu/vulkan/text.zig` | Text/UI pipeline: host-visible vertex buffer (pos+uv+rgba per vertex), device-local R8 atlas texture + sampler + descriptor set, graphics pipeline, same copy-to-host present path. |
| `src/gpu/vulkan/*.vert/.frag` | GLSL 450 sources; compiled to SPIR-V 1.0 with `glslc -O`, validated with `spirv-val`, embedded via `@embedFile`. Fragment shaders store BGRA so host bytes are wl_shm ARGB8888 directly. |
| `src/ui/text/font.zig` | From-zero SFNT parser: table directory, cmap formats 4/12, loca/glyf (simple + composite glyphs), head/hhea/hmtx. |
| `src/ui/text/raster.zig` | Adaptive quadratic-Bézier flattening + scanline nonzero-winding fill, 4 vertical subsamples with exact horizontal coverage → 8-bit coverage. |
| `src/ui/text/atlas.zig` | Shelf-packed 1024×1024 R8 glyph atlas (texel (0,0) reserved white for solid rects), UTF-8 decode, measure, CPU drawText (source-over). |
| `src/ui/layout.zig` | Flexbox subset: row/column, gap, padding, fixed/grow/fit, cross stretch. Two passes: measure (bottom-up) then arrange (top-down). |
| `src/ui/ui.zig` | Immediate-mode UI over layout+atlas: `begin/panel/label/button/spacer/end`, emits `DrawCmd`s (rect/text). Button hit-testing uses rects persisted across the per-frame arena (`prev_rects`). |

## Frame data flow (GPU path)

1. `ui.begin(w, h, mouse...)`; app declares widgets; `ui.end()` runs layout and
   emits draw commands.
2. `buildQuads()` turns each rect into a quad sampling the white atlas texel
   (coverage 1 → solid vertex color) and each text run into per-glyph quads
   (uv into the atlas rect).
3. `GpuText.render()`: fills the mapped vertex buffer, records one render pass
   (clear BGRA-swizzled void, bind pipeline, bind descriptor set, push
   constants, draw, end), barrier, `vkCmdCopyImageToBuffer`, submit, wait on
   fence.
4. `@memcpy(shm_buf.pixels, pipe.pixels())` — the fragment shader stores BGRA,
   so host bytes are exactly wl_shm ARGB8888 little-endian.
5. wl_surface attach + damage + commit + frame callback.

Software fallback: if no Vulkan ICD or no font is available, the same UI is
rasterized on the CPU (atlas `drawText` into the shm buffer) — same draw
commands, same layout.

## Tests

`zig build test` runs each module as a test binary (`link_libc` for the
dlopen/dlsym modules). Hardware tests run against whatever ICD is active;
`VK_ICD_FILENAMES=/usr/share/vulkan/icd.d/lvp_icd.json` selects lavapipe and
`VK_INSTANCE_LAYERS=VK_LAYER_KHRONOS_validation` adds validation (clean).
Evidence artifacts are written into per-test `.zig-cache/tmp` directories,
not fixed shared paths in `/tmp`. The default Instrument Sans font and its OFL
license are compiled into applications through the package-root `resources`
module. `Options.font_data` supplies borrowed embedded data;
`Options.font_path` opts into a runtime-owned external file.

### Snapshot gate

Rendering regressions are caught by a deterministic software-shm snapshot:
`CIPHER_FORCE_SOFTWARE=1 CIPHER_DUMP_FRAME=<frame.ppm> CIPHER_MAX_FRAMES=3`
produces a reference frame (same font, same machine ⇒ byte-identical hash
across runs). `zig build snapshot` regenerates the frame and checks it
against `tests/golden/hello.sha256` with `snapdiff check`; exit 0 = match.
The golden is specific to the bundled font, rasterizer and compositor-provided
window geometry — if you change the font, rasterizer, or theme defaults,
regenerate it with `snapdiff write`, inspect the frame, and document the
intentional visual change before committing. A mismatch fails the build. Verified 2026-11-19: the gate
catches a font swap (exits 1) and passes after revert (exits 0).

Requires a Wayland session (the software path still commits to wl_shm);
it is a local gate, not a headless CI step.

## Known limitations

- `vkDestroyDevice`/`vkDestroyInstance` crash in the NVIDIA ICD teardown path;
  tests skip explicit destruction (process exit cleans up).
- Flexbox subset only: no wrap, no align/justify beyond stretch, no min/max
  constraints beyond what's needed by the demo.
- Text: no shaping (harfbuzz-free), no kerning — codepoint → glyph → advance.
- Composite glyphs support translation + 2×2 transforms (enough for Latin
  accents like é).
