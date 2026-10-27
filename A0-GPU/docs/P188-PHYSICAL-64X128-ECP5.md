# P188: 64x128 physical ECP5 scaling experiment (draft)

## Baseline and scope
This branch stacks on P187 PR #64 (head `9e8fcea153ae6785849db3a7a4500ea76550db51`), itself above P186 and P180. The P187 exact-head 32x64 ECP5 route completed at 41.79 MHz, 77 IO, 7 DP16KD, 72 MULT18X18D, 12,277 LUT4 and 5,098 TRELLIS_FF. The 64x64 P186 specialized route was 42.59 MHz. These are FPGA fabric clocks, **not** game FPS or a physical GPU card.

## Single experiment
Try the existing unchanged, fully initialized P175 programmable host at **64x128 = 8,192 pixels**, through **actual** Yosys ECP5 mapping and nextpnr-ecp5 placement and routing. No synthesized RTL is modified and standalone framebuffer semantics are untouched. Use LFE5U-85F, CABGA756, speed grade 6, seed 1, default placer. The P186/P187 fully cleared guard is enabled because 8192 >= 2048; no uninitialized pixel may be exposed via the specialized bank.

## Must-pass evidence
- New real Icarus test checks read masking before initialization, visible written data after initialization, suppression after invalidation and reset, for both banks and upper-half pixel indices (including 8191).
- Real route (not simulation or synthesis-only) must complete and report clock >=**30.00 MHz** experimental quality floor, exactly 77 IO, 13..64 DP16KD, 40..72 DSP, 0 < TRELLIS_FF < 9195 and populated LUT4 within ECP5 capacity. This is a target, not a predicted result; preserve failure artifacts.
- No waiver, retry, substitute benchmark or relaxed geometry. Keep prior P172/P177/P179/P180/P186/P187 exact-head checks as integration gates, with independent color/depth/frame oracles. If a check is absent or not triggered on this PR, rerun on its exact head before integrating.
- Keep stacked **draft** and do not merge into P187, P180 or main until reviewed, all exact-head checks pass and parent PRs are approved. An FPGA fit is not evidence of PCIe, driver, VRAM hardware, game FPS or RTX-class performance.
