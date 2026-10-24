# P138 — dual-bank framebuffer scratchpad (research prototype)

**Status: draft; RTL equivalence and FPGA RAM mapping demonstrated, latest-head CI required for merge.** This is a separate two-lane storage building block, NOT wired to P102 or the public command bus. Its purpose is to prove safe parallel bank accesses before the risky renderer integration.

## Actual architecture

- Full framebuffer linear index maps to one of **two interleaved banks**: `bank = index[0]`, `offset = index >> 1`. Each bank stores a 48-bit packed `{RGB888, depth24}` word.
- Each clock accepts independently offered lane 0/lane 1 requests. Both are accepted **only when they target different valid physical banks**, permitting two bank operations per clock. A single bank services at most one read **or** write per clock.
- Same-bank conflict: lane 0 wins, lane 1 `req1_ready=0`; upstream MUST retain lane 1 request and retry later. This prevents silently dropped/reordered writes. An invalid index does not reserve a bank and returns an error pulse.
- Accepted read or write returns `rspN_valid` and error/data registered at the accepting edge, visible in the following clock period. One response per lane per cycle; **no response backpressure**. The downstream interface must capture each pulse.
- Reset invalidates valid metadata rather than clearing every data bit. Unwritten/reset locations return zero. Underlying array bits have no defined content until written. There are no atomic 2-bank transactions, ECC, parity, or cache coherence guarantees.

**Not yet integrated:** P102 currently remains a single-pixel-per-scan graphics datapath with separate color/depth memories. P138 does **not** make P102 process two pixels per cycle, does not provide physical external VRAM, PCIe DMA, scanout, or display-driver support.

## Strict gates before integration

1. Independent indexed 48-bit golden software array with validity bits in real Icarus Verilog; execute 4x4, 7x5 (odd size and non-power-of-two index errors), and 8x8. Validate all responses, errors, writes/reads, long dual-bank streams, same-bank stalls/retries, invalid indices, and reset invalidation every accepting cycle.
2. Require **500+ cycles of simultaneous dual-lane acceptance** and 1000+ total accepted operations, along with non-vacuous conflicting-bank and read/write coverage; no skips, no substituted mock clocks or seeded PASS messages.
3. Map full P138 standalone research module through actual Yosys `synth_ecp5` and genuine nextpnr ECP5-85K `CABGA756` speed grade 6, fixed seed 1, `--freq 5`, unconstrained external pins. Reject unmapped primitives, latches, invalid utilization or missed target. **Require at least two real mapped `DP16KD` FPGA block RAM primitives**, rather than silently accepting LUT/FF-only storage.
4. Rerun inherited P126–P137 workflows when file filters apply. No claims about global GPU throughput because integration is not yet present.
5. Remain draft until **all P138 jobs on the same exact PR head** pass and concrete resource evidence is recorded.

## Verified first results (2026-10-24)

- Independent actual Icarus Verilog golden-array matrix passed on 4×4, 7×5 and 8×8. Simultaneous dual acceptance: **568**, **633**, **736** cycles respectively; total accepted operations **1,140**, **1,277**, **1,476**. All read/write payloads compared bitwise, with explicit conflict/retry and reset; the 7×5 case reported 3 invalid-address errors as expected.
- The first synthesis version mapped zero ECP5 `DP16KD` cells, despite passing functional tests. It was **not considered a physically RAM-backed result**.
- Refactoring to one explicitly selected synchronous read/write memory port **per bank**, with registered read responses, produced **4 actual mapped `DP16KD` cells** on the 4×4 `a0_p138_dual_bank_framebuffer` top. Genuine ECP5-85K place-and-route passed the 5 MHz internal target and reported **236.69 MHz** one-clock Fmax in the standalone research module at seed 1. This Fmax does **not** include P102 raster/depth/blend logic and therefore cannot be compared to P137's 50.44 MHz.
- A new CI ratchet fails the latest PR head if fewer than two actual `DP16KD` cells are mapped. The latest documentation and workflow commits require revalidation before merge.

The presence of RAM primitives and independent bank ports validates an FPGA research implementation, not on-board memory integrity, real dual-pixel raster throughput, a physical graphics card, or production multiported VRAM.

## Forward work

P139/P140 candidate: merge banked storage into P102 with a staged one-request-per-pixel path; then carefully introduce 2 pixel lanes and a paired raster/depth/blend pipeline, explicitly handling same-bank hazards, dependent blending/depth, initialization, stall propagation, visible reads, and existing external command semantics. Keep independent full-frame differential against the frozen pre-change P102.

## Limits

No production memory controller, ECC, VRAM or actual multi-port silicon memory guarantee, physical card, DMA, PCIe, independent clock CDC sign-off, guaranteed timing, physical pin constraints, display scanout, or measured games/FPS.
