# P146 — overlapped pair-completion/next-request acceptance

**Status: draft candidate; no claim of success before real Icarus and ECP5 exact-head checks pass.**

## Bottleneck and design

P145 feeds its two independently tested triangle pixel candidates into P144's two-bank BRAM read/modify/write engine. A new pair launches, P144 reads both packed RGB/depth words, commits conditional writes, returns a registered completion, and only then does P145 advance its raster. The original implementation spends a bubble between that completion and acceptance of the next pair.

P146 preserves the complete **16-bit internal triangle/depth/alpha model** and its existing signed-8-bit bounded FPGA top, but on a successful nonfinal P144 completion **offers the next pair of pixel coordinates at that same edge**. The lookahead address is `scan_index+2`. Its two pixel edge values are derived from P143's row-aware signed edge deltas, preserving winding, top-left ownership and odd-width row crossing. P144 must be idle/ready before the request is offered; on a final pair or any memory error the optimization is suppressed. On a failure, fault remains latched and the raster does not advance. There is still exactly **one** accepted request per stage, with two writes at most and registered responses.

This is a *control-path improvement*, **not speculative framebuffer writing**. The new packet is accepted only after the previous packet has committed successfully. Full depth/alpha read and write semantics remain unchanged. The remaining memory read/write beats still bound performance; do not claim sustained two blended pixels/clock.

## Verification before merge

1. Freeze previous P145 literally in `A0-GPU/tests/rtl/a0_p145_pre_p146_reference.sv` with only the module name changed. The P146 independent A/B test instantiates both original P145 and optimized P145 alongside the unchanged P102 reference with real P144/P139/P138 BRAM. The same commands are fed to all, and every RGB/depth word is checked after clear and each triangle.
2. Measure **actual command-to-done clocks** per draw on 4x4,7x5,8x8. Require no slower draw and at least two strictly faster completed draws, nonvacuous dual-lane commits, exact writes and zero faults. Include ALWAYS/LESS/LESS_EQUAL, alpha blending, depth_write off, scissor, degenerate, reset while busy, and host backpressure.
3. Existing P145 direct-core and bounded-pin independent P102 frame tests must continue to pass; run genuine Yosys+nextpnr ECP5-85K full bounded wrapper (CABGA756, speed6, seed1, 4x4, 5MHz artificial target, unconstrained external pins). Require four physical RAM slices or at least 2 genuine DP16KD, bounded I/O (less than package capacity) and report mapped Fmax vs P145's **27.41MHz**. A timing regression must be reported, not hidden by the RTL cycle-speedup figure.
4. Do not merge if any required exact-current-head CI is missing, skipped, red or still running. The original P102/P132/P133 remain unchanged.

## Observed real RTL and ECP5 evidence — 24 October 2026

Exact code head `4b14ecdf` had six GitHub Actions workflows all green: P126, P127, P132, P134, P145 and P146. The real Icarus A/B test instantiates frozen original P145, new P146, and independent unchanged P102 side by side. No frame read is omitted; every RGB/depth word is checked against P102, and all completed-draw write counts match P102 and original P145.

| Frame | Total original draw clocks (4 active draws) | New draw clocks | Saved clocks | Same completed-draw writes | RGB/depth pixels read back |
|---|---:|---:|---:|---:|---:|
| 4×4 | 96 | 68 | 29.17% | 60 | 112 |
| 7×5 | 216 | 148 | 31.48% | 135 | 245 |
| 8×8 | 384 | 260 | 32.29% | 244 | 448 |

The fifth zero-area triangle completes immediately in **0 clocks in both versions** and is excluded from non-vacuous speedup counts. Every one of the four actual draws is strictly faster and no output value differs. Scissor, depth comparison LESS/LESS_EQUAL, alpha blending, depth-write disable, reset while drawing, host stall and odd row crossing remain tested.

The **first** P146 combinational lookahead version improved cycles but reduced the 4×4 full routed ECP5 bounded-wrapper Fmax to **20.22 MHz** compared to pre-P146 P145 **27.41 MHz**. Pre-registering the signed next-pair edge/row values during the existing RMW memory beat raised the **second** actual Yosys/nextpnr ECP5-85K route estimate to **21.43 MHz**, still below P145. Same 4×4, package CABGA756/speed 6, seed 1, 5MHz tool target and unconstrained pins: **318/365 FPGA I/O cells, 4 DP16KD RAM primitives**, placed and routed. The final CI enforces **>=20 MHz** under this narrowly comparable research setup; latest-head retest is mandatory.

**Clock-versus-cycle tradeoff:** the routed Fmax estimate decreases about 21.8%, despite 29–32% fewer RTL draw clocks. A rough **predicted** elapsed-time comparison combining those two *different nonphysical estimates* is slightly favorable to P146 for these test scenes. This is *not* measured chip speed, total pixel/s, monitor scanout, gaming FPS, board timing closure, or evidence of sustained two blended pixels per clock. Future work should reduce the lookahead critical path further before physical integration.

## Scope limits

This is still an ECP5 FPGA **research** design with no physical pin assignment, no board bitstream verification, external VRAM, real PCIe endpoint, monitor scanout, signed physical CDC qualification, production GPU driver, game support or measured FPS.
