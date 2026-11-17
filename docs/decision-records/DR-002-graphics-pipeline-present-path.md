# DR-002: Present path = graphics render pass → vkCmdCopyImageToBuffer → wl_shm

## Decision

Render UI frames with a **graphics pipeline** into an offscreen
`R8G8B8A8_UNORM` color attachment (loadOp clear, storeOp store,
finalLayout `TRANSFER_SRC_OPTIMAL`), then `vkCmdCopyImageToBuffer` into a
host-visible coherent buffer, and `memcpy` those bytes into the wl_shm
buffer. The fragment shader stores **BGRA-swizzled** color so the host copy
is byte-identical to wl_shm ARGB8888 on little-endian.

## Why not compute

An earlier compute-shader version existed; the graphics path is simpler to
reason about for quads/text (vertex input, viewport, render pass), and the
copy-to-buffer present is identical. No compute-specific needs (no
post-processing buffers) exist.

## Byte-order details that mattered

- Fragment shaders write `vec4(c.b, c.g, c.r, c.a)` into the RGBA attachment
  → buffer bytes are `B,G,R,A` = wl_shm ARGB8888 u32 `0xAARRGGBB` LE.
- `vkCmdClear` writes **unswizzled** RGBA, so the clear color must be given
  in BGRA order (`{11/255, 6/255, 4/255, 1}` for void `#04060B`) to match.
- Pixel→NDC mapping: with a positive-height viewport, NDC y=-1 is the **top**
  row, so pixel y-down maps as `ndc.y = y/H*2 - 1` (the flipped version drew
  quads upside down).
- Push constants use std430-ish layout: a `vec4` after a `vec2` lands at
  offset 16, not 8 — CPU push-constant structs use two `vec4`s to match.

## Evidence

- `GPU_FRAME_OK bytes=12288 corner=04060B center=EBB545` — exact pixel asserts
  on NVIDIA 620.70.06 and lavapipe, clean under Khronos validation.
- `GPU_TEXT_OK bytes=61440 solid=45B5EBFF hole/void=0B0604FF` — glyph quad
  through the atlas texture, exact pixels, second frame with moved quad.
- PPM dumps: `/tmp/sifr_frame.ppm`, `/tmp/sifr_gpu_text.ppm`.
- Live: `sifr: render path = vulkan-gpu-ui` + `WAYLAND_PROTOCOL_OK frames=24`
  on umbriel, both ICDs, exit 0.
