# P201: automatic full-frame capture and atomic publication

## Claim and boundaries

P201 adds a **synthesizable control-plane coordinator**, not new GPU
processing, memory storage, a DDR PHY or a PCIe driver. It replaces
testbench-generated P198 export-start, P199 stage-begin and stage-seal
signals with hardware-owned decisions. Actual pixel data still flows through
P175 -> P198 -> P195 -> P197 -> P200 -> P199 and two **P196 simulation-only
physical bank models**.

## Contract

- A single one-cycle `capture_request` reserves the opposite P199 staging
  bank and starts the genuine P198 **post-render** readback only after
  staging has begun.
- Require P198 to have entered BUSY before using DONE, which also prevents
  an old DONE level from a previous captured frame being mistaken for this
  frame's completion.
- Require P198 DONE, exactly `FRAME_WORDS` queued pixels, zero P195 FIFO
  words, and exactly `FRAME_WORDS` P199 **physical-port accepted writes**
  before asserting one seal pulse. This is a hardware-side drain contract,
  not a testbench sleep.
- Wait for the P199 atomic publication of the expected next epoch. Reject
  overlapping capture requests, partial export, counter overflow, or any
  exporter/epoch/router fault. A fault remains sticky until reset.
- A second capture may start without reset, preserving the first published
  bank while new P175 contents are copied to staging.

## Exact-head CI requirements

1. Real Icarus RTL simulation wires P201 into the existing two-frame
   full 256x256 P175 rendering, P198 host snapshot, P195 queue, P197
   arbiter, synthesizable P200 bank router and P199 epoch controller.
   It checks 131,072 actual 48-bit pixel commits, 200 old-frame reads
   during new-frame staging, exactly two hardware `stage_begin` pulses,
   exactly two hardware seal pulses and two atomic publications.
2. A separate small-parameter negative test faults on early DONE (one of
   two pixels missing), faults on a duplicate capture request, holds a
   sticky failure, refuses to seal while the queue/commit path has not
   drained, and accepts one legal publication only after drain.
3. Real Yosys synthesis on the new P201 RTL, `check -assert` and
   zero reported structural problems.
4. No skips, no reruns, no synthesized-memory/physical-hardware claims.

## Out-of-scope

This is still a post-render host-bus snapshot—not live in-raster coherent
VRAM, board-attached memory, display scanout, 3D driver, GPU benchmark,
or game FPS. P196's 65,536-word arrays are simulation-only. A real memory
controller, physical FPGA route, multi-port snooping and production
fault recovery remain future work.

## Merge gate

Stack draft PR P201 on P200 (#77), P199 (#76), P198 (#75), and earlier
stack. Do not merge parents/child without independent review and all
exact-head CI gates. Preserve failed evidence and fix causes, never retry
the exact same failed head to claim green.
