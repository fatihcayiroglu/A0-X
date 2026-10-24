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

## Scope limits

This is still an ECP5 FPGA **research** design with no physical pin assignment, no board bitstream verification, external VRAM, real PCIe endpoint, monitor scanout, signed physical CDC qualification, production GPU driver, game support or measured FPS.
