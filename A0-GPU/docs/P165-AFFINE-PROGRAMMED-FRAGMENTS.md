# P165 — Real per-vertex affine-UV programmable fragment pipeline

Status: research RTL; not a physical graphics card, not a PCIe endpoint, no real VRAM, native driver, or benchmark claim.

## Observable end-to-end implementation

The P163 packed **77-pin** host bus now controls the optional signed P164 vertex-UV interpolator through P38's covered-pixel handshake. Every accepted draw snapshots the triangle's signed integer-space vertices and three signed Q8.8 UV pairs. For each covered raster pixel, the actual P164 restoring divider generates a tagged U,V pair at the pixel center (affine barycentric weighting) before P162 initializes the shader's R0 with the interpolated coordinate plus the signed Q8.8 uniform offset. P162 executes its real programmable TEX/ALU instructions against P156/P158 BRAM and P144 stores depth-tested RGB.

P164's independent numerical oracle lives in its P164 workflow. P165 adds independent scalar signed 64-bit edge-weight arithmetic and a separate framebuffer/P102 color-depth oracle. No software result substitutes for the real RTL shader or BRAM.

## Host register additions (6-bit address, 32-bit data)

| Addr | Name | Write value | Read value |
| --- | --- | --- | --- |
| 28 | AFFINE_MODE | bit 0 selects per-vertex affine UV; all upper bits **must be zero** | zero-extended bit 0 |
| 29 | UV0 | [31:16] signed V0 Q8.8, [15:0] signed U0 Q8.8 | stored pair |
| 30 | UV1 | V1:U1 | stored pair |
| 31 | UV2 | V2:U2 | stored pair |
| 6 | UV_OFFSET | existing signed V:U additive offset | unchanged |

Default AFFINE_MODE=0 preserves P163's old screen X/Y Q8.8 mode. Configuration writes are allowed during an active triangle but are **not** applied mid-draw: the full geometry, vertex UV, offset, mode and shader draw controls are latched on draw acceptance. Rejected AFFINE_MODE reserved-bit writes must not mutate state.

## Protocol and safety

1. P38 holds each covered fragment until P144 accepts its eventual color/depth write. In affine mode, the core first issues exactly one P164 request for the fragment, with a new transaction tag.
2. The core waits for P164's response with a bounded watchdog. Any P164 invalid-area/quotient-overflow error, tag mismatch, timeout, or overflow when adding the uniform UV offset permanently fails the active draw closed until reset.
3. After valid interpolation, all 8 shader registers are freshly initialized, the real TEX/ALU program executes, and P144 performs depth-test/optional blend.
4. A framebuffer pixel is counted only after successful write acknowledgement. If texture taps are missing or the shader faults, the fragment does not commit.
5. The existing P163 screen-UV mode and its full P102 regression continue to run unchanged.

This stage is **affine, not perspective-correct**. It does not interpolate vertex reciprocal-W. Real routed ECP5 timing is a research FPGA measurement, not GPU gaming performance.

## Evidence gates

- P163 existing real framebuffer/TEX + missing-tap fail-closed regression still required and routed.
- P164 standalone 1,010 signed-UV oracle checks and real ECP5 route still required.
- P165 independent full-frame P102 depth/RGB oracle: two affine shader programs, a legacy-mode regression, host busy config-mutation snapshot, 77-pin host readback/reject checks, missing-tap fault and signed UV offset overflow fail-closed.
- P165 real Yosys ECP5 synth and full nextpnr ECP5-85K package CABGA756 speed 6 route, no black-box module or unbound latch, BRAM/DSP resource checks, 5MHz research target; preserve evidence artifacts.

## Planned next

Perspective-correct (reciprocal-W) UV interpolation and actual throughput improvements with traced resource/power/frequency tradeoffs, then PCIe/VRAM/driver milestones. No RTX 6090 comparison is justified by present emulation/simulation evidence.
