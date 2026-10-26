# P172 — Scaling the host-programmed framebuffer to 8×8 and 16×16

Status: candidate; not a claim of physical GPU readiness or commercial graphics performance.

## Goal

Prove that the existing P171 register-decoupled, two-bank, 48-bit RGB888+Z24 framebuffer works at more than the original 4×4 research footprint.

- **8×8**: 64 pixels = 4× the original 4×4 storage.
- **16×16**: 256 pixels = 16× the original storage.
- The same P163 77-wire memory-mapped host control bus, P38 raster, P162 programmable TEX/ALU shader, P166 affine/perspective UV and P144 BRAM RMW are used unchanged.
- The 4×4 default and established P163/P165/P167 tests remain unchanged.

## Nonvacuous correctness evidence

An independent, parameterized P163/P102 differential oracle runs twice, for both W=H=8 and 16.

For each shape it exercises:
- 256 actual texture uploads, seed and ISA programming;
- two real rasterized shader draws with different programs and repeat modes;
- two fully checked clear/draw frames plus a final reset-and-clear case;
- **five complete framebuffer readbacks**: 320 pixel comparisons at 8×8 and 1,280 at 16×16, including every edge and background pixel;
- per-covered-pixel shader instruction and texture retirement totals;
- rejection of malformed host commands and unauthorized busy-state configuration;
- fail-closed missing weighted TEX taps after reset, with no forbidden framebuffer write.

No empty tests or skipped pixels count toward this gate.

## Genuine 16×16 FPGA implementation

The P172 workflow elaborates `a0_p163_packed_programmed_command_top` using Yosys `chparam -set FRAME_WIDTH 16 -set FRAME_HEIGHT 16`, synthesizes the full top, and routes for a real ECP5-85K CABGA756 using `nextpnr-ecp5 --seed 1`.

Required evidence: exactly 77 host IO pins, at least 3 DP16KD BRAMs, 40 to 72 MULT18X18D DSPs, no abstract or inferred-latch cells, and **Fmax >=15 MHz** at this new 256-pixel geometry. The 15 MHz floor is a first explicit **scaled-geometry** acceptance target, not an assertion that it matches the prior **4×4, 40.47 MHz** implementation. Record the exact achieved MHz, FFs and BRAMs and evaluate the capacity/clock tradeoff honestly.

Any red or pending exact-head check blocks merging to main.
