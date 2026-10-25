# P171 — Registered framebuffer request coordinates

Status: candidate, subject to exact-head RTL correctness and actual routed ECP5 gates.

## Measured motivation

P170 reached **37.64 MHz** (77 physical host IOs, five DP16KD BRAMs, 72 MULT18X18D DSPs). Its routed critical path starts at `core.state_q`, enters the clear/pixel Y-coordinate selector in the P144 framebuffer request, traverses framebuffer address arithmetic/carry mapping and ends in the BRAM address control. This is no longer the P162 instruction-mux bottleneck removed by P170.

## Change

P163 now holds `fb_x_q/fb_y_q` as request coordinates:

- On **clear acceptance** it registers pixel (0,0).
- On each **successful, nonterminal clear completion**, it registers the coordinates of the next clear pixel while advancing the clear position. No extra beat or host-visible latency is inserted.
- On **successful shader completion**, it snapshots the raster pixel X/Y before the following WRITE_PIXEL beat.
- P144 receives only the registered pair, breaking the same-cycle FSM selection-to-address-calculation path. Readback requests retain their separate host X/Y path.

Failures still fail closed, and register contents cannot be changed by new live draw/configuration inputs after acceptance.

## Read/compare/writeback register boundary

The first routed candidate improved from 37.64 to **38.12 MHz**, but failed
the unchanged >=40 MHz acceptance gate. The revised critical path began
at BRAM read data, traversed dynamic depth/blend decisions and bank-write
validity metadata, then terminated at a validity flip-flop.

P144 therefore now has three sequential beats for a valid RMW packet:
BRAM read, registered depth/blend decision and conditional BRAM commit.
It snapshots the accepted request as before, and invalid/missing read
responses still fail closed without partial writes. A valid non-clear
RMW costs **one additional clock**; clears and invalid packets retain
their immediate one-cycle completion. Both Fmax and end-to-end pixel
latency must be reported; better MHz alone is not proof of faster frames.

## Required evidence

- Full independent P144 two-lane RGB/depth oracle on 4x4, 7x5, 8x8 and 32x32 framebuffers, including exact three-beat retirement and zero premature host priority.
- Real Icarus P163 oracle against independent P102 reference: five tested clear/frame phases with 80 full-frame pixels, malformed texture fail-closed evidence.
- Existing P165 affine and P167 perspective P102 framebuffer oracles on changed P163 source, including snapshot and inverse-W/overflow faults.
- Existing P163/P165/P167 full 77-IO place-route resource consistency gates.
- P171 genuine ECP5-85K CABGA756 Yosys+nextpnr route: **Fmax >= 40 MHz**, 77 pins, BRAM >= 3, **40 <= DSP <= 72**, no inferred latches/abstract cells. Proof marker `P171_REGISTERED_FB_COORDS_ECP5_PASS`.

Do not claim 40 MHz before evidence; a failed routed gate blocks merging. The FPGA clock is not proof of physical ASIC GPU FPS or discrete graphics-card readiness.
