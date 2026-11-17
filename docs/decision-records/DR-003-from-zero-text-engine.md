# DR-003: From-zero text engine (no FreeType/HarfBuzz)

## Decision

Parse SFNT/TrueType directly (`src/ui/text/font.zig`), rasterize with a
hand-written scanline rasterizer (`src/ui/text/raster.zig`), pack glyphs into
an R8 atlas (`src/ui/text/atlas.zig`), and draw text as textured quads on the
GPU (`src/gpu/vulkan/text.zig`).

## Scope chosen

- cmap formats 4 and 12 (Unicode BMP + full); formats 0/6 not needed for the
  demo fonts.
- glyf simple glyphs (all flag encodings: short vectors, repeats, same/positive
  bits) + composite glyphs recursively (args as words/bytes, scale / x&y scale
  / 2×2 matrices) — covers Latin + accents (é verified: 3 contours).
- hmtx advances + lsb; head unitsPerEm/indexToLocFormat; hhea ascender/
  descender/lineGap for line height.
- Rasterizer: adaptive quadratic flattening (pixel-space flatness, ≤64
  segments), scanline nonzero-winding fill with 4 vertical subsamples and
  exact horizontal coverage → u8 coverage. Deterministic (asserted by
  re-render equality).

## Deliberately out of scope

No shaping (no HarfBuzz): codepoint → glyph → advance only. No kerning.
Stated in ARCHITECTURE.md limitations.

## Evidence (vs /usr/share/fonts/liberation/LiberationSans-Regular.ttf)

- `TEXT_FONT_OK glyphs=2620 upem=2048 asc=1854 desc=-434 locfmt=1`
- `TEXT_CMAP_OK gid_A=36 adv_A=1366 adv_space=569`
- `TEXT_OUTLINE_OK A contours=2 bbox=(4,0)-(1362,1409)`; `TEXT_COMPOSITE_OK é contours=3 ymax=1508`
- `TEXT_RASTER_OK full=432 ink=558 partial=126 left=277 right=281` (64px 'A':
  solid interior, empty corners, AA edges, left/right ink within 5%,
  deterministic)
- `TEXT_ATLAS_OK measure_H=23.11 ink=693 brassish=480` + `/tmp/sifr_text.ppm`
- GPU: `GPU_TEXT_OK bytes=61440 solid=45B5EBFF hole/void=0B0604FF` +
  `/tmp/sifr_gpu_text.ppm` (NVIDIA + lavapipe, validation clean)
