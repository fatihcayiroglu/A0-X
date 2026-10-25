# P168 — Shared UV resource optimization (real FPGA)

## Scope

Reuse **one** signed 80-bit rational UV interpolator in the P163 packed
programmable fragment pipeline instead of separately synthesizing both the
P164 affine module and P166 perspective module. No host port, register
address, shader opcode, depth behavior or framebuffer storage changes.

* Affine mode (existing host register 28): supply all inverse-W values as
  **one**. Weighted barycentric evaluation is then exactly the affine
  equation; the signed rational numerator is bounded within 64 bits. Load
  the 64-bit magnitude in the high 64 bits of the shared dividend shifter,
  and run exactly **64 restoring steps per component**, same as P164.
* Perspective mode (existing host register 35): retain snapshotted
  inverse-W0/1/2, signed 80-bit rational arithmetic and **80 restoring steps
  per component**. Positive nonzero inverse-W remains mandatory. Reset,
  request tags, error and backpressure behavior are unchanged.
* Screen mode (both flags zero) bypasses the interpolator as before.

## Strict acceptance

1. P168 independent RTL compares shared affine to the already oracle-tested
   P164 reference across 1,025 requests, reverse winding, signed outputs,
   degenerate triangles, out-of-frame extrapolation, reset and response
   backpressure, with valid affine responses at exactly 128 divider cycles.
2. Existing P163, P165 and P167 real P102 RGB+depth tests remain green.
   P166 independent signed perspective oracle (4,035 checks) remains green.
3. Fully route the **real 77-IO P163 host top** on ECP5 85K CABGA756 at
   >=5 MHz, prove shader/framebuffer BRAM and DSP remain present, and
   assert synthesized DSP count strictly less than the P167 baseline
   **84 DSP**, rather than accepting an unmeasured optimization claim.

## Limitations

This is FPGA resource consolidation, **not** an RTX-class throughput claim.
Both interpolation components remain serialized; full perspective is still
160 restoring divider cycles per covered sample. The 5 MHz gate is minimal
placement evidence, not a target consumer GPU clock, board or PCIe benchmark.
