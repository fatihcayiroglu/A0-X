# P138 — dual-bank framebuffer scratchpad (research prototype)

**Status: draft.** This is a separate two-lane storage building block, NOT wired to P102 or the public command bus. Its purpose is to prove safe parallel bank accesses before the risky renderer integration.

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
3. Map full P138 standalone research module through actual Yosys `synth_ecp5` and genuine nextpnr ECP5-85K `CABGA756` speed grade 6, fixed seed 1, `--freq 5`, unconstrained external pins. Reject unmapped primitives, latches, invalid utilization or missed target. Do not assert that this is inference of real FPGA block RAM unless mapping report explicitly confirms `DP16KD`.
4. Rerun inherited P126–P137 workflows when file filters apply. No claims about global GPU throughput because integration is not yet present.
5. Remain draft until **all P138 jobs on the same exact PR head** pass and concrete resource evidence is recorded.

## Forward work

P139/P140 candidate: merge banked storage into P102 with a staged one-request-per-pixel path; then carefully introduce 2 pixel lanes and a paired raster/depth/blend pipeline, explicitly handling same-bank hazards, dependent blending/depth, initialization, stall propagation, visible reads, and existing external command semantics. Keep independent full-frame differential against the frozen pre-change P102.

## Limits

No production memory controller, ECC, VRAM or actual multi-port silicon memory guarantee, physical card, DMA, PCIe, independent clock CDC sign-off, guaranteed timing, physical pin constraints, display scanout, or measured games/FPS.
