# P167 — Real perspective-correct UV to programmable TEX/ALU framebuffer

This stage connects the P166 standalone exact rational unit to the actual P38 raster -> P162 per-fragment shader -> P156/P158 texture BRAM -> P144 RGB/depth framebuffer. It does **not** build a physical GPU, PCIe endpoint, graphics driver, GDDR, or verify a GPU gaming FPS claim.

## Compatibility-preserving packed 77-pin host protocol

Legacy register addresses, instruction encoding, seed writes, texture uploads, pixel host reads and device identity are preserved. New 6-bit addresses on the existing 32-bit data bus:

| Address | Meaning | Constraint |
| --- | --- | --- |
| 28 | Existing `AFFINE_MODE` | 0 screen-space coordinates, 1 P164 affine, **unchanged** |
| 29–31 | Existing vertex signed Q8.8 `UV0/UV1/UV2` | V high16; U low16, unchanged |
| 32 | `INV_W0` | unsigned 16-bit positive inverse-W, upper16 write bits must be zero |
| 33 | `INV_W1` | same |
| 34 | `INV_W2` | same |
| 35 | `PERSPECTIVE_ENABLE` | only bit0 valid, reserved bits rejected |

**Selection:** `PERSPECTIVE_ENABLE=1` selects perspective-correct P166; otherwise `AFFINE_MODE=1` selects P164; otherwise the legacy screen X/Y coordinate mode. Perspective explicitly takes priority over affine if both are set. This preserves P165 legacy tests that reject writing value 2 to register 28.

All modes retain the signed `UV_OFFSET` at address 6, applied *after* either P164 or P166 interpolation, with a 17-bit checked addition and permanent fail-closed on signed Q8.8 overflow. A perspective draw with any zero inverse-W is rejected before raster launch. Other P166 numerical errors, tag mismatches, or a bounded UV response timeout abort active draw without framebuffer commit.

## Hardware flow and draw invariants

1. On accepted triangle submission, P167 snapshots vertices, vertex UV, inverse-W triples, mode, UV offset, depth state and shader program selection. Later host configuration writes do not affect the active triangle.
2. For every P38 covered pixel, exactly one of P164 or P166 receives a tagged valid/ready request. Its response is checked before R0 seed data is written into the P162 shader.
3. The shader is reset to all eight per-pixel register seeds and executes its real programmable TEX and SIMD ALU instructions, including clamp/repeat and lane masks. P144 then performs actual depth compare, depth write and optional blend.
4. Raster advances **only** after the framebuffer write acknowledgement. Any missing weighted texture tap, shader fault or perspective UV error prevents the associated pixel commit. The host can read actual RGB/depth BRAM results.

## Validation

- All previously defined P163 **and** P165 independent P102 real-frame regressions remain mandatory; their ECP5 routes must still pass with P166 included.
- P166's standalone 4,035-case exact perspective rational arithmetic oracle remains mandatory.
- New P167 real 4x4 full-frame P102 RGB/depth comparison plus separate software scalar rational perspective UV and bilinear/TEX/SIMD oracle:
  - two distinct perspective real shader programs; one legacy screen and two affine regression frames;
  - 256 real uploaded texture texels, clamp/repeat, masked instructions;
  - simultaneous affine-and-perspective enable proving priority;
  - busy host geometry/UV/inverse-W mutation proving immutable draw snapshot;
  - invalid and reserved-bit register writes, zero inverse-W draw reject;
  - missing texture taps, affine overflow and perspective UV offset overflow all fail closed;
  - 208 complete framebuffer RGB/depth readback comparisons, exact shader and TEX retirement counts.
- Full **77-pin** top level ECP5-85K CABGA756 speed6 Yosys synth and nextpnr place/route with signed multiplier/BRAM resource gates and 5MHz *research* target; no skipped tests or made-up resource reports.

## Next engineering work

Measure per-fragment throughput and build a shared resource-scheduled P164/P166 pipeline to reduce area/power and increase effective frame rate. Add real PCIe/VRAM interfaces and OS drivers in later milestones. ECP5 routed MHz numbers are not directly comparable to RTX 6090 game performance.
