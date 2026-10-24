# P141 — exact opaque/scissor fast paths for the P140 BRAM renderer

**Status: candidate, unqualified until exact PR-head tests have completed successfully.**

## Bottleneck and change

P140 stalls the raster for a synchronous BRAM read before any covered pixel can be written. Two situations do **not** need this read:

1. The triangle's snapshotted depth compare is ALWAYS, depth writing is enabled, blending is disabled, and scissor accepts the pixel: the new packed {RGB888,depth24} replaces the entire old word, so the previous word has no bearing on the result. **Write on the initial covered pixel cycle without reading** and advance the raster on the same accepted write.
2. The scissor rejects the covered pixel: skip the BRAM read entirely and advance the raster. There is no pixel_wrote event.

Everything else—including blending, depth comparison requiring stored depth, and depth_write disabled—**must retain P140's original read/modify/write path**. Pixel_wrote fires exactly once for every actual pixel write. Lane 0 must respect its acceptance handshake. Host reads remain on P139's second bank-aware ready/valid lane, retaining same-bank stalls and invalid-coordinate behavior. This **does not** increase the number of shaded lanes.

## Verification

- Freeze the exact original P140 trial in `A0-GPU/tests/rtl/a0_p141_p140_reference.sv` by **only renaming the module**.
- Run actual Icarus for both original and optimized P140 with the same clear/draw commands, four geometries/modes and 4x4, 7x5, 8x8 frames. Read and compare **all** RGB/depth pixels after every operation. Count writes **per completed draw**, not across deliberately aborted triangles.
- Require strictly fewer accepted command-to-done raster cycles for opaque depth ALWAYS + write enabled + blend disabled, and for scissor-rejected triangles; equal cycle counts for blending and no-depth-write cases. Reject any vacuous test without enough covered/written pixels.
- Preserve the original P140 vs P102 frame-differential regression (including live host bank-conflict behavior), as well as P126/P127/P132/P134 inherited tests.
- Map and route full P141/P140/P139/P138/P136 pipeline on real ECP5-85K CABGA756, speed6, seed1, 4x4 framebuffer, unconstrained pins, 5MHz research target, require at least 2 actual mapped DP16KD RAM cells and report GPU trial Fmax vs P140's **37.20 MHz**. Report any change as a tradeoff; do not claim actual GPU throughput improved until pipeline integration and physical clock targets are fully characterized.

## Limits

This is a bounded behavioral + FPGA tool research result, **not a physical GPU**, no PCIe, external VRAM, genuine shader engine, driver, display, actual raster pixel/s, FPS, production CDC, or hardware clock validation. Existing P102/P132/P133 are retained, unchanged.
