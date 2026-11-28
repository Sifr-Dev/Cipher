# Phantom bench — first same-hardware head-to-head (2026-11-19)

_Measured on this host (Ryzen 7 7435HS, RTX 4060 Laptop, Wayland/umbriel,
Zig 0.17.1, Linux). Nanoui column = the hillclimb binary built from the
2026-11-18 clone, run unmodified on this host (its `--only nanoui` scenes;
`hillclimb/README.md` methodology: 30 warmup, 300 frames ×3, lowest median;
our host-rendered CPU phases). Phantom column = `cipher-bench` (this repo,
examples/bench), same host, same date, WSI present; per-300-frame window
arithmetic means, three repeats, warmup 30 frames excluded once per process.
The harness does not calculate a median or choose the best repeat._

| scene | nanoui frame CPU (their labels: build+layout+paint) | cipher build+layout | cipher build+layout+encode | nanoui encode CPU |
|---|---:|---:|---:|---:|
| text (300 changing labels) | **0.374 ms** | 0.103 + 0.038 = **0.141 ms** | **0.166 ms** | 4.34 ms (CPU raster) |
| boxes (600 moving boxes) | **0.238 ms** | 0.127 + 0.016 = **0.143 ms** | **0.146 ms** | 75.5 ms (CPU raster) |
| dashboard (12 cards) | **0.104 ms** | 0.055 + 0.007 = **0.062 ms** | **0.065 ms** | 54.0 ms (CPU raster) |

Phantom `render_ms` (WSI): 18.0/11.9/17.1 ms — vsync-wait dominated, **not** GPU
time (no timestamps yet). Nanoui GPU column on Linux: 0.000 (no Metal) — their
CPU-raster numbers above are the comparable ones.

Repeat-to-repeat variance ≤ 2% per scene (build: 0.101–0.103 text,
0.125–0.127 boxes, 0.055 dashboard; layout std ≤ 0.002).

## Current shadowed-boxes measurement (2026-11-25)

The scene now renders 600 moving rounded rectangles with shadows. It was
rebuilt with `zig build -Doptimize=ReleaseSmall` and run on the same host and
compositor with `CIPHER_FRAME_TIMING=1 ./zig-out/bin/cipher-bench --scene boxes`.
These are arithmetic means over independent 300-frame windows after warmup:

| Window | Build | Layout | Encode | Build+layout | Including encode | `render_ms` |
|---|---:|---:|---:|---:|---:|---:|
| 1 | 0.162 ms | 0.042 ms | 0.006 ms | 0.204 ms | 0.210 ms | 6.747 ms |
| 2 | 0.161 ms | 0.041 ms | 0.006 ms | 0.202 ms | 0.208 ms | 6.752 ms |
| 3 | 0.159 ms | 0.042 ms | 0.005 ms | 0.201 ms | 0.206 ms | 6.738 ms |

`render_ms` includes presentation synchronization and is not a GPU timestamp.
The older `0.143 ms` boxes entry was for plain rectangles and is not comparable
to this scene. No nanoui remeasurement or GPU/CPU superiority claim is made.

## What this does and does not prove

**Historical comparison:** in the older table, Phantom's CPU-side frame cost
(view build + flexbox layout + quad construction) is ~2.0–2.3× lower than
nanoui's on those older scenes, plus ~15–150× lower encode CPU. Their encode
number is the cost of software Gaussian shadows + blend rasterization; ours is
a direct quad build. This is not a claim about the remeasured shadowed scene.

**Does not — stated plainly (owner correction applied, 2026-11-19):**
0. **This host has no CPU graphics output.** All presentation is GPU; the
   CPU-raster comparisons above are compute-only evidence. Presentation
   claims require GPU timestamps; until then, none are made.
1. **Different work per scene.** Their labels carry real text machinery
   (grapheme clusters, wrap caches, composite glyphs) — ours are single-line
   plain labels. Their boxes include rounded corners and 8-sample Gaussian
   shadows. The current Phantom boxes scene has rounded rectangles and shadows
   too, but its geometry and shadow filter are not identical to nanoui's. The
   older `0.143 ms` plain-rectangle result must not be presented as the cost of
   the current shadowed scene. See the remeasurement below.
2. **Feature asymmetry cuts the other way too:** nanoui ships motion, IME,
   accessibility on Apple, webview, kit components, mobile. Phantom ships a
   terminal, a FLAC decoder, and a 12-widget kit. Neither suite's number
   prices in what the other can't do.
3. **Warmup is once per process**, shared across scenes if run with the
   default `--repeats`; per-scene invocations were used for this table.
4. **No claims beyond CPU phases.** Present path (WSI vs their GL/EGL vs CPU
   raster) is unmeasured in both suites on identical drivers/compositors.
5. **One machine.** Ryzen 7 7435HS only. No Apple silicon, no Intel iGPU, no
   Mutter/KWin yet.

## The comparison axes that are valid on this host

This machine's CPU has **no graphics output** (Ryzen 7 7435HS) — every frame
presents through the RTX 4060 (Vulkan/WSI). Therefore:

- **Valid comparisons** (CPU compute is CPU in both suites): layout, widget
  build, and quad/command encoding — the `build/layout/encode` columns above.
- **Invalid as product claims**: any CPU-rasterized presentation comparison.
  The software-shm path exists in cipher purely as a portability fallback for
  machines without a Vulkan ICD; on this host it is not a shippable mode, is
  unmeasured, and is never claimed. Nanoui's Linux "frame CPU" reproduced on
  this host via their CPU-raster path, but that path is not the one this host
  ships or displays.
- **Unmeasured both ways until timestamps land**: the GPU present path. Our
  `render_ms` is vsync-wait dominated; nanoui's Linux GPU path (GTK+EGL into
  whatever GL the driver gives) has never been benchmarked on identical
  scenes here either. Neither side has a render-path win claim today.
- **The `2x` speedup in the table is capacity evidence, not a product
  metric** — it shows our layout/build/quad pipeline is cheap on shared CPU;
  it does not imply faster frames on screen, because presentation is GPU and
  unmeasured for both.

## How to reproduce

```sh
# cipher (this repo): per scene, three repeats of 300 measured frames
zig build -Doptimize=ReleaseFast
CIPHER_FRAME_TIMING=1 ./zig-out/bin/cipher-bench --scene text
CIPHER_FRAME_TIMING=1 ./zig-out/bin/cipher-bench --scene boxes
CIPHER_FRAME_TIMING=1 ./zig-out/bin/cipher-bench --scene dashboard
# nanoui (clone of justrach/nanoui @ dd37daa, unmodified):
cd hillclimb && zig build run -- --scene text,boxes,dashboard --only nanoui
```

`CIPHER_FRAME_TIMING=1` prints one `CIPHER_BENCH` line per 300 measured frames
(warmup excluded; each line is that window's mean).

## Next measurement milestones

- Same-window **rounded rect + shadow** has been implemented and remeasured;
  a comparison with identical competitor geometry and filtering is still needed.
- GPU timestamps (VK_EXT_calibrated_timestamps / query pool) to fill our
  render_ms with GPU time, not vsync waits
- Compositor matrix (umbriel/Mutter/KWin) + lavapipe software ICD
- Scroll/list scenes (1000 rows / 100k-row virtualized list) — needs a list
  widget first
