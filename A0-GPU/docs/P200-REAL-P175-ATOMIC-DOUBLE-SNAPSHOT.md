# P200 — Real P175 post-render atomic two-bank snapshot

## Goal

Prove that two successive **real 256×256 frames rendered by P175** can
be snapshotted via the existing P198 host register-bus readback and published
to an external logical reader atomically. Avoid any claim of continuous
render-time coherence or physical DDR/VRAM.

## Data and control contract

1. P175 draws the full first image into its actual internal framebuffer.
2. P199 opens epoch 1; the P198 post-render host-register snapshot iterates
   all pixels through P195 (two-word FIFO) into P197 (single-port arbiter).
3. The synthesizable P200 router maps P197's logical 48-bit word requests
   to physical bank 1; the **P196 bank is simulation-only**.
4. Publication is forbidden until all 65,536 ordered memory write
   handshakes have committed and the controller receives an explicit seal.
5. P175 then clears/renders a *different* second 256×256 image while old
   external bank 1 stays published. The rearmed P198 sequencer exports all
   65,536 pixels to bank 0. Two hundred concurrent logical reads of old
   frame data must remain unchanged under actual backpressure.
6. The old bank stays active after all second-frame commits and until the
   second seal. The controller then atomically switches readers to bank 0.
7. Exact old/new RGB and depth at opposite framebuffer corners, ordered
   addresses and bank separation, reset invalidation, and no stale published
   lease are asserted in RTL simulation.

## Hardware scope

- **Synthesizable:** P198 sequencer with restart from COMPLETE; P195 queue;
  P197 arbitration; P199 epoch publication; P200 physical two-bank word
  router, including read-response origin tracking and fail-closed faults.
- **Simulation only:** two independent P196 65,536×48 word arrays, with
  deterministic write and read stalls. No FPGA board, external memory
  controller, DRAM timing, DDR PHY, PCIe endpoint, or real GPU hardware.
- **Not implemented:** true live render-time bank coherent writes, VRAM
  persistence across power cycles, game/driver/FPS performance, display scanout.

## Required exact-head CI evidence

- Icarus compiles and simulates the *actual* P175 full-frame RTL twice.
- Marker (only emitted after all assertions):
  `P200_REAL_P175_ATOMIC_DUAL_SNAPSHOT_PASS frame=256x256 epochs=2 exported=131072 old_reads=200 no_torn_reads=1 real_p175=1 rearmed_exporter=1 routed_banks=1 backpressure=1 reset_fail_closed=1`
- Yosys synthesizes the P200 router and rearmed P198 sequencer separately;
  both require `check -assert` and zero reported structural issues.
- Parent P198/P199 tests remain mandatory. No skip, retry, ignored failure,
  or fabricated green. All evidence belongs to a specific tested commit.

## Integration and review

Draft P200 is stacked on P199 (#76), itself stacked on P198 (#75).
Independent review and all exact-head CI gates must complete before
integrating parent or child. This change is not release-quality silicon.
