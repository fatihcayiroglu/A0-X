# P136 — incremental, exact P38 triangle edge rasterization

Status: **draft research RTL candidate**; PR merge prohibited until real tests and performance evidence are reviewed. Base is P135 merged into main (`a47ed049`).

## Problem and design

Current P38 computes 3 signed 36-bit triangle edge functions from vertex differences and the 2*x+1, 2*y+1 pixel center **on every scan cycle**. Even when vertices are stable, pixel-position-dependent products remain in its combinational pixel acceptance path. These computations are suitable for incremental interpolation without changing covered pixels:

`E(P) = dx * (2*y+1 - 2*y0) - dy * (2*x+1 - 2*x0)`

`E(x+1,y) = E(x,y) - 2*dy`

`E(0,y+1) = E(0,y) + 2*dx`

At triangle command acceptance, normalize vertex winding exactly as before; snapshot the three initial edge values at pixel center `(0.5,0.5)` and 18-bit signed X/Y steps. Maintain 36-bit signed current and row-start accumulators. Move to the next pixel only if previous P38 would advance, honoring pixel backpressure, wrapping rows and reset. Top-left edge ownership and degenerate-triangle behavior are unchanged.

This **moves pixel-position multiplications to launch-time**; it does not eliminate multiplications from the overall silicon, nor does it make an actual GPU faster without mapping evidence.

## Required before merge

1. **Differential, cycle-for-cycle** real Icarus comparison against the frozen original **64-bit** P38 reference. Compare ready/valid/pixel x/y/done on every cycle, with 8x8, 7x5, and 4x4 frames; directed dense triangles, both windings, corner signed-16 coordinates, stalls, source register mutation after command, degenerate triangle, and mid-triangle reset.
2. Preserve independent P130 196-triangle real RTL reference gate.
3. Preserve inherited P126-P135 regression jobs, especially P132 pixel-by-pixel frame differential, P129 graphics chain, P133 CDC FIFO tests and P134 6 clock ratios. Any newly discovered mismatch is a real failure, not an acceptable test skip.
4. Map the full P133/P132/P102/P136 chain through genuine Yosys to ECP5-85K and nextpnr `CABGA756`, speed 6, seed 1, `--freq 5`, 4x4 frame, as in P135. Record mapped cells and GPU/host Fmax alongside P135's **36.50 MHz** GPU reference. Do not claim an optimization benefit until measured and compared.
5. Keep PR draft if any gate is failing, pending or missing; if throughput or fmax regresses, fix or revert.

## Limitations

These are simulated logic and **research FPGA mapping** metrics. 36-bit edge interpolation for 8-bit framebuffer colors and 4x4 mapped frame is not a card performance benchmark. No physical GPU, board/clock/CDC pin constraints, pixel-per-second characterization, VRAM, display or PCIe qualification.
