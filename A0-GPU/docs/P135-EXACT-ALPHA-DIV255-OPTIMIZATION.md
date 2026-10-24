# P135 — exact alpha-blend divide-by-255 optimization

Status: **research RTL and ECP5 mapping verified on P135 code commit `f2faac64`; PR #10 awaiting final exact-head green CI before merge.** Based on P134 main merge `317019e3`.

## Reproducible diagnosis

The P134 ECP5-85K 5 MHz run produced a tool-reported GPU Fmax of **9.77 MHz**, host Fmax of **84.85 MHz** (seed 1, CABGA756/speed 6, 4x4 framebuffer). The GPU critical path originates at the raster scan_y register, goes through raster_index, color framebuffer read, RGB alpha-blend arithmetic and memory data write logic. These are **FPGA mapping observations**, not measured physical-card performance.

## Proposed arithmetic change

Original P70 for each 8-bit channel computes:

`x = source * alpha + destination * (255 - alpha) + 127`

`out = floor(x / 255)`

For source, destination, alpha in [0,255], `127 <= x <= 65152`. Over this exact domain:

`floor(x / 255) == (x + 1 + (x >> 8)) >> 8`

This removes 3 explicit constant-divide operations in the P70 RTL without altering **any channel result**, when all intermediates remain 17-bit unsigned and the output is truncated to 8 bits only at the final stage. Unblended pixels must remain exactly equal to the source RGB value.

## Gates

1. Exhaustively verify the identity in Python for all integer x from 0 to 65,152 (not just random samples).
2. Use real Icarus Verilog for 65,536 multi-channel RGB/alpha patterns plus 768 black/white/bypass edge cases against an independent original P70 `/255` oracle.
3. Re-run inherited actual P126/P127/P132/P133/P134 workflows on the exact proposed head: all must be green.
4. Re-map the full P133/P132/P102 pipeline through actual Yosys and route the ECP5-85K with the **same** configuration as P134. Record both domain frequencies and fail if the GPU achieved Fmax is below the previous 9.77 MHz baseline. This comparison is diagnostic only: a small test FPGA, not real throughput or silicon clock qualification.
5. Keep PR draft and do not merge on skipped/failed or absent evidence. Further pipelining will be considered separately because it affects raster completion, read-after-write correctness and pixel ordering.

## First routed optimization result (2026-10-24)

The full P135 code commit `f2faac64` passed its dedicated equivalence and same-device ECP5 placement/routing gates. The deterministic nextpnr report (ECP5-85K CABGA756, speed 6, seed 1, 4x4 internal framebuffer, 5 MHz timing threshold, unconstrained external pins) reports **GPU Fmax 36.50 MHz vs P134 baseline 9.77 MHz**, about **3.74x**. Host reported Fmax is 155.79 MHz vs 84.85 MHz. Initial timing estimations differed; these are the final post-route figures. The P126, P127, P129, P131, P132 and P134 workflows also passed for code commit `f2faac64`.

These are **static tool predictions for a research FPGA mapped model**, not benchmark FPS, a manufactured GPU, an external timing signoff, or guaranteed hardware frequency. No performance gain for WolfOS, games or an actual PCIe device is implied. The final documentation commit must independently pass CI before merge.

## Out of scope

No physical CDC validation, VRAM, GPU driver, output/display controller, PCB, power or thermal measurements; no game support or real GPU performance claims.
