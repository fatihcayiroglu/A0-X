# P199: Fail-closed atomic two-bank frame publication

## Why
P198 copies the actual P175 rendered framebuffer to an external `{RGB,depth}` word stream **after** drawing. Updating that same visible backing memory in-place while readers inspect it would expose a partially refreshed frame (tearing and mixed epochs).

## Synthesizable hardware contract
New `a0_p199_atomic_frame_bank_epoch.sv` tracks a **published/active bank** and an opposite **staging/write bank**. Two separate physical memory banks must be mapped by the caller. This module does **not** instantiate memory and does **not** directly modify P175's live framebuffer.

- `stage_begin` starts a new staging epoch on the bank opposite the currently published frame. Until publication, all valid `read_accept` requests hold the current bank.
- Every `write_commit` must have the **next expected word address**, contiguous from BASE through BASE+FRAME_WORDS-1. A missing, duplicated, out-of-order, over-count, or early/duplicate seal is a sticky fail-closed fault.
- A `stage_seal` is valid only after **all FRAME_WORDS words have been accepted by the backing physical port**, not just queued by P195 or produced by P198. The controller then blocks new readers.
- The active-bank selector flips only once any already accepted reader has returned its matching `read_complete`. The published epoch increments once per completed sealed frame, while the old published bank remains immutable during staging.
- Reset revokes publication/leases and clears fault. Physical memories may retain bytes, but are **not valid to display/read** until a complete new publication cycle.

The controller assumes one outstanding read across the memory port, as already enforced by P197. The caller must gate logical memory command acceptance with `read_permitted/write_permitted` and route each to the published/staging bank; resets must flush memory responses. No per-pixel blending, color/depth RMW, physical memory PHY or PCIe coherence is provided.

## Real CI acceptance
A real Icarus test connects:
- P195 actual 2-entry ordered pixel FIFO,
- P197 actual synthesizeable read/write arbiter,
- P199 actual synthesizeable bank epoch state machine,
- **two separate P196 simulation-only 65,536-word backing-memory models**, one per physical bank.

For each of two 256×256 epochs, submit/commit **65,536 actual writes**, independently check each word address, 48-bit payload and physical bank, and require exact counts. During the second staging epoch, issue 200 external reads of the still-published first epoch; require no mixed/torn data. Exercise deterministic stalls, active-reader lease during the seal, zero early publication, post-publish readback from the new bank, injected invalid write order with sticky fault, and reset invalidation. The new hardware epoch sequencer is independently synthesized by real Yosys `check -assert`.

This is not yet the P198 live exporter connected through a hardware bank/address mapper; the memory-bank routing is verified in the testbench. Next integration should use actual P175 snapshots from P198 as the staged producer, then move to FPGA place/route and physical memory hardware. No VRAM/board/driver/game FPS performance claim.

Stacked **draft** on P198 #75; preserve first failing test evidence and require independent review before any parent merge.
