# P136 — exact incremental triangle-edge rasterization

Status: **verified RTL and research ECP5 mapping candidate; latest PR-head regression confirmation required before merge.** Base: P135 main merge `a47ed049`.

## Original bottleneck and final architecture

The original P38 rasterizer calculated three signed triangle edge functions at **every pixel scan position**, using pixel-position-dependent multiplications:

`E(P) = dx * (2*y+1 - 2*y0) - dy * (2*x+1 - 2*x0)`

At triangle launch P136 now captures each raw-oriented edge value at pixel center `(0.5, 0.5)` plus signed 18-bit per-pixel and per-row increments:

`E(x+1,y) = E(x,y) - 2*dy`
`E(0,y+1) = E(0,y) + 2*dx`

**Crucial timing correction:** Preserve raw input winding (A→B, B→C, C→A) and register a *single orientation bit*, rather than muxing vertices before computing origin edge products. For negative winding, the candidate compares each raw edge for `<0` with the reversed top-left edge ownership; for positive winding, compares for `>0` with the original top-left convention. Consequently the signed input-area calculation has no long combinational dependency through the edge math. Scan/valid/done/backpressure, degenerate triangles and reset semantics remain identical.

This removes **pixel-dependent edge multiplication** from active raster scanning; it still contains multiplication on triangle setup. It does not establish any real raster throughput or game FPS claim.

## Why three iterations were necessary

All three candidates matched the frozen 64-bit original P38 in cycle-by-cycle RTL tests. But the first mapped design reduced reported GPU Fmax from P135's **36.50 MHz** to **26.28 MHz**: input area → winding normalization mux → wide edge setup was the bottleneck. Parallel precomputation of both normalized winding edge sets improved that to **29.35 MHz**, still a regression. Final raw-oriented edge storage and a single winding flag removed that critical setup cascade, producing **49.91 MHz** final GPU Fmax.

This is **49.91/36.50 = ~1.367**, or approximately **36.7% higher tool-reported GPU Fmax**, using the comparable ECP5-85K model.

## Qualification

- Actual Icarus simulation against the frozen independent original P130 **64-bit** edge reference: 8x8, 7x5, 4x4 frames; dense and corner triangles, both windings, negative coordinate extremes, pixel backpressure, register mutation during raster, degen triangles, reset midway, and exact cycle-by-cycle ready/valid/x/y/done agreement.
- Independent original P130 196-triangle cycle-by-cycle regression also passed.
- Full genuine Yosys ECP5 synthesis plus `nextpnr-ecp5 --85k --package CABGA756 --speed 6 --freq 5 --seed 1 --lpf-allow-unconstrained`: final head `69b55e63` reported **GPU Fmax 49.91016 MHz**, host Fmax **133.12 MHz**. Two independent clocks checked, mapped cells and I/O bounded, minimum tool timing 5 MHz passed.
- CI now **rejects** proposed GPU Fmax below P135's 36.50 MHz baseline. All required workflows must pass on the **exact final PR head** before merge.
- P129/P130/P132/P134 inherited regressions are particularly important to catch changed pixels, pipeline behavior, or frame buffer state. No skips accepted.

## Scope limits

These are RTL and **research FPGA mapping estimates**, not a physical GPU, bitstream loaded onto a real board, PCIe implementation, VRAM, physical CDC/skew sign-off, independent pin timing constraints, real raster pixel throughput measurement, measured cooling or graphics benchmarks. The 4x4 mapped model and artificial 5 MHz constraint must never be advertised as gaming-hardware performance.
