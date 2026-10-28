# P226 — Remove the 92-bit valid-to-zero mux on pixel EBR ingress

Experimental **draft**, stacked on verified P224 #101 (NOT on the
regressing P225 experiment). Never merge without owner approval and
independent review.

## Physical timing rationale

The exact-head P224 routed ECP5 pixel critical path starts at
`raster.pipe_valid_q`, passes through the `src_epoch` data mux
before a 32-bit frame-epoch comparison and continues to staging-bank
controls. At that stage the code did this on **all 92 bits**:

```systemverilog
assign {src_end,src_start,src_epoch,src_index,src_data} =
    pipe_valid_q ? pipe_packet_q : 92'd0;
```

The 92-bit packet is **already held in a pixel-clock-local register**.
P226 removes the redundant data mux and keeps `src_valid=pipe_valid_q`.
All actual destination actions remain controlled by
`consume = src_valid && scrub_done_q && !local_fault_q && !src_fault`
and (for bank writes) `!bad_sample && !skip_ingest`.
On asynchronous pixel reset, both validity and payload still clear.

A dormant pipe can therefore retain an old *internal* payload while
invalid, without making any BRAM write or displaying any stale pixels.
This is a real hardware datapath change, not a test-only change.
It preserves P223's one-beat-per-pixel-clock FIFO and P224's registered
barrier.

## Fail-closed proof

- `a0_p226_unmuxed_pixel_ingress_tb.sv` checks the full real P224
  EBR raster stream under 8/1024-word × three opposite clock ratios.
  Requires two exact atomic displayed frame epochs, 2ns reset,
  VBlank publication, stopped-clock recovery, no torn frames.
- Additional live monitor asserts **whenever ingress validity is low**,
  after reset scrub and without a pre-existing fault, neither physical
  framebuffer bank write enables nor the packet-consume strobe can fire.
  This must execute in every clock/frame combination.
- Keep all inherited P175–P224 tests, negative mutants and unchanged
  real P216, P223, P224 ECP5 routes.
- Synthesize/route new P226 top separately on the same LFE5U-85F
  CABGA381 speed-6 seed1. Require 83 I/O, 21 real EBR, unmapped/latch
  cells zero, independent host/pixel clocks. Compare against exact-job
  P224 LUT4, FF, host/pixel Fmax; do not infer gain without actual data.

No physical FPGA board, video/PCIe PHY, CDC MTBF/PVT/pin signoff, or
consumer GPU gaming/FPS claim is made.
