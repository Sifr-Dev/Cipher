# Cipher bench — first same-hardware head-to-head (2026-11-19)

_Measured on this host (Ryzen 7 7435HS, RTX 4060 Laptop, Wayland/umbriel,
Zig 0.17.1, Linux). Nanoui column = the hillclimb binary built from the
2026-11-18 clone, run unmodified on this host (its `--only nanoui` scenes;
`hillclimb/README.md` methodology: 30 warmup, 300 frames ×3, lowest median;
our host-rendered CPU phases). Cipher column = `cipher-bench` (this repo,
examples/bench), same host, same date, WSI present; per-300-measure window
means, 3 repeats, warmup 30 frames excluded once per process._

| scene | nanoui frame CPU (their labels: build+layout+paint) | cipher build+layout | cipher build+layout+encode | nanoui encode CPU |
|---|---:|---:|---:|---:|
| text (300 changing labels) | **0.374 ms** | 0.103 + 0.038 = **0.141 ms** | **0.166 ms** | 4.34 ms (CPU raster) |
| boxes (600 moving boxes) | **0.238 ms** | 0.127 + 0.016 = **0.143 ms** | **0.146 ms** | 75.5 ms (CPU raster) |
| dashboard (12 cards) | **0.104 ms** | 0.055 + 0.007 = **0.062 ms** | **0.065 ms** | 54.0 ms (CPU raster) |

Cipher `render_ms` (WSI): 18.0/11.9/17.1 ms — vsync-wait dominated, **not** GPU
time (no timestamps yet). Nanoui GPU column on Linux: 0.000 (no Metal) — their
CPU-raster numbers above are the comparable ones.

Repeat-to-repeat variance ≤ 2% per scene (build: 0.101–0.103 text,
0.125–0.127 boxes, 0.055 dashboard; layout std ≤ 0.002).

## What this does and does not prove

**Does:** Cipher's CPU-side frame cost (view build + flexbox layout + quad
construction) is ~2.0–2.3× lower than nanoui's on identical scenes, plus
~15–150× lower encode CPU. Their encode number is the cost of software
Gaussian shadows + blend rasterization; ours is a direct quad build.

**Does not — stated plainly:**
1. **Different work per scene.** Their labels carry real text machinery
   (grapheme clusters, wrap caches, composite glyphs) — ours are single-line
   plain labels. Their boxes include rounded corners and 8-sample Gaussian
   shadows — **cipher has no rounded rects or shadows yet**; our boxes scene
   issues plain colored rects. Their dashboard widgets are richer.
2. **Feature asymmetry cuts the other way too:** nanoui ships motion, IME,
   accessibility on Apple, webview, kit components, mobile. Cipher ships a
   terminal, a FLAC decoder, and a 12-widget kit. Neither suite's number
   prices in what the other can't do.
3. **Warmup is once per process**, shared across scenes if run with the
   default `--repeats`; per-scene invocations were used for this table.
4. **No claims beyond CPU phases.** Present path (WSI vs their GL/EGL vs CPU
   raster) is unmeasured in both suites on identical drivers/compositors.
5. **One machine.** Ryzen 7 7435HS only. No Apple silicon, no Intel iGPU, no
   Mutter/KWin yet.

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

- Same-window **rounded rect + shadow** in our toolkit, then re-measure boxes
  (the honest apples-to-apples, requires new widget code)
- GPU timestamps (VK_EXT_calibrated_timestamps / query pool) to fill our
  render_ms with GPU time, not vsync waits
- Compositor matrix (umbriel/Mutter/KWin) + lavapipe software ICD
- Scroll/list scenes (1000 rows / 100k-row virtualized list) — needs a list
  widget first
