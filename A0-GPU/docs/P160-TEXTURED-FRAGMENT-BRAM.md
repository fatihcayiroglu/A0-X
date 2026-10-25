# P160 — first actual textured fragment path to RGB/depth BRAM

P160 joins four independently proven primitives in a new bounded research
wrapper: **P38 raster coverage → P159 optimized P158/P156 true texture BRAM
bilinear filter → P150 four-channel UNORM arithmetic → P144 dual-bank
framebuffer RGB/depth RMW**. A covered raster pixel is not released until its
texture lookup, ALU response and framebuffer memory transaction complete.

This does not change P153/P155's existing programmable research shader; it is
a separate **fixed single-operation texture/ALU path** to establish an actual
pixel-level connection. No false claim is made that the P151 program now has a
`TEX` instruction.

## Exact behavior and limits

- Texture has 16×16 RGBA8 cells. Writes are idle-only and never interleave
  with fragment sampling. Unwritten contributing texels cause a **latched
  fail-closed fault**, not a framebuffer write or stale BRAM exposure.
- Each triangle has a signed Q8.8 **screen-space UV offset**, and each raster
  fragment uses `u=(pixel_x<<8)+offset_u`, `v=(pixel_y<<8)+offset_v`. All four
  P159 bilinear taps use P156's clamp/repeat convention. This is **not**
  vertex-attribute or perspective-correct texture coordinate interpolation.
- Texture RGBA is ALU operand A. The triangle selects any of P150's eight
  arithmetic operations, operand B, alpha and per-lane mask. The resulting
  lower 24 RGB bits feed the real P144 depth/blend RMW path; the upper byte
  remains arithmetic data, not a dynamic blending alpha.
- Raster, sampler, ALU and pixel memory are single-in-flight/serialized. This
  is deliberately a correctness demonstration, not a throughput claim.
- Reset flushes outstanding stages and invalidates P156 texel presence.
  Unexpected response tags, missing texels or framebuffer errors fail closed.

## Hard acceptance gates

Actual Icarus verifies three full 4×4 textured triangles against the
**unchanged P102** frame/depth oracle and independent scalar bilinear + UNORM
per-channel math, including clamp and repeat boundary UVs. Check 112 full
frame pixels across four clears and three draws, exact covered-fragment
counts, blocked host reads and a post-reset missing-texture fail-closed case.

Genuine Yosys `synth_ecp5` and nextpnr ECP5-85K full route must infer at
least **three true DP16KD BRAMs** (texture plus two framebuffer banks) and
**eight DSP** primitives, with no unresolved cells/latches and a 5 MHz
artificial tool timing target. Evidence is retained on any failure. These are
tool estimates with unconstrained external pins, not physical board tests.

Future P161+ work: actual shader ISA texture fetch, interpolated vertex UVs,
perspective correction, LOD/mipmaps, multi-fragment throughput, drivers and
physical board qualification.
