# P154 — scissor-before-shader clipping for actual per-covered-fragment raster

**DRAFT — no merge until exact-current-head independent Icarus and full FPGA CI PASS.**

P153 successfully runs a real P151/P150 8-bit UNORM microprogram for every *triangle-covered pixel* on its P38 raster, writes true P144 depth/alpha RMW to P139/P138 BRAM, and supports full signed-16-bit triangle vertices via an unchanged narrow 76-I/O-bit packed host research bus. However, P153's existing `REG_SCISSOR_XY` and `REG_SCISSOR_WH` registers were inert and MODE bit4 was explicitly rejected. P154 enables actual **scissor clipping before expensive fragment shader invocation**.

The unchanged P59 rectangle-coverage primitive uses unsigned pixel coordinates and **17-bit nonwrapping** coordinate+width/height endpoint addition, and rejects a width or height of zero. P154 snapshots the scissor enable and XY/WH values on triangle launch (later host configuration changes cannot affect the ongoing draw). On a P38 *triangle-covered* pixel:
- Inside the scissor (or disabled): load R0 pixel XY, execute the real P151 microprogram, run P144 depth/alpha BRAM RMW, advance P38 only on successfully acknowledged completion.
- Outside the scissor: assert P38 `pixel_ready` directly in the scan state and advance **without** loading R0, running a shader, issuing a pixel memory write, modifying depth, or increasing `shaded_pixels`.
- Zero-sized rectangle: discard every covered pixel **without hanging** the triangle completion protocol or falsely reporting shader invocations.
- Underlying BRAM clear, busy/host debug read restrictions, shader faults and reset safety are retained.

P154 does NOT alter P38's winding/top-left coverage, does not change P150/P151 ALU results or the framebuffer depth/blend arithmetic, does not add per-vertex varying interpolation, texture coordinates, multisampling, waves, FP32, external VRAM or physical PCIe.

## Independent qualification

- Real Icarus P154 direct complete-frame P102 reference, covering 4x4, 7x5, 8x8 on each of three clears/draws with exact RGB888/depth24 pixel reads: **2x2 scissor at (1,1)** generates **4** shader invocations/BRAM fragment commits even on larger screens, **zero-width scissor** generates **0** shader invocations and still completes, and **scissor disabled** invokes the shader for all pixels, preserving P153 compatibility.
- Real P153 packed-command bus P154 test: set existing REG_SCISSOR_XY/WH and MODE bit4; reject reserved MODE bit5; draw a full signed-16-bit triangle with only 4 pixels covered by scissor. Assert the packed shader completed count matches P102 clipped coverage and that all framebuffer color/depth words match.
- Inherited P153 direct/packed full-frame tests must keep passing on the same exact code head with scissor explicitly disabled, including zero skipped shaders when clipping is off.
- Full genuine Yosys+nextpnr ECP5-85K CABGA756 speed6 seed1 4x4 research model, 5MHz tool target, unconstrained external pin assignments: require **76 external bits**, real DP16KD and MULT18X18D resources, mapped full P153/P154 shader/BRAM top. Any failure leaves the PR draft.

No real board, actual sustained fragment shaders per cycle, physical timing sign-off, GPU driver or game FPS is claimed.


## First genuine RTL and FPGA evidence — 24 October 2026

For the P154 implementation, actual Icarus independently checked three complete 4x4/7x5/8x8 scenes against unchanged P102 with the P59 scissor enabled/disabled. Source is **real P153 P38/P151/P150 + P144/P139/P138 BRAM**, not a mocked shader.

| Framebuffer | P102 RGB/depth readbacks | P151 invocations across 3 draws | Active 2x2 scissor | Zero-width scissor | Unclipped draw |
|---|---:|---:|---:|---:|---:|
| 4x4 | 96 | 20 | 4 | 0 | 16 |
| 7x5 | 210 | 39 | 4 | 0 | 35 |
| 8x8 | 384 | 68 | 4 | 0 | 64 |

Separate real 76-pin-equivalent P153 packet interface test set scissor MODE bit4 and XY/WH registers, then confirmed **only 4 shader invocations** and matching 24-bit RGB and 24-bit stored depth on **every pixel** in all three frame sizes; reserved MODE bit5 remains rejected. Inherited full-scene P153 tests explicitly leave scissor disabled, so P153's original full invocation count is still required, not skipped.

The first P154 top after this change was placed and routed in real Yosys/nextpnr ECP5-85K (CABGA756 speed6 seed1, 4x4 internal framebuffer, 5MHz research target, unconstrained pins): **76 research I/O signals**, **4 real DP16KD BRAMs**, **22 real MULT18X18D DSPs**, and a **33.304 MHz tool-estimated Fmax** versus P153's earlier 34.491MHz. It is a small clock-estimate regression, not hidden as a speedup; avoiding shader work in clipped scenes is not yet an externally timed FPS claim. These results require the final exact-head CI rerun to pass before any merge.

