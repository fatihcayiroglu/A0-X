# P142 — two opaque raster pixels per clock into real FPGA banked BRAM

**Status:** Research draft, not qualified until exact-head real RTL and ECP5 mapping succeed. P141 main baseline: `203dea11`.

## Architecture

P142 adds a **separate** `a0_p142_dual_opaque_raster_bram` top that takes one depth-ALWAYS, depth-writing, fully opaque triangle and scans **two adjacent linear pixel positions per clock**. Each position is independently tested using the exact 36-bit signed original P38 edge function, the normalized winding-side/top-left ownership rule, and optional P59 scissor gating. Each covered pixel issues an independent 48-bit packed `{RGB888, depth24}` write to the existing P139/P138 two-bank ECP5 BRAM.

Adjacent **linear** pixel addresses always have opposite parity, so simultaneous covered writes reach distinct banks even when FRAME_WIDTH is odd and a pair crosses a scanline boundary. The final pair can have only lane 0 for odd-sized framebuffers. Clear also uses paired writes. A synchronous host debug read is available only while the renderer is idle; host read responses are explicitly tagged to avoid confusing a prior render write acknowledgement with a host read.

This is a restricted **opaque-only** graphics path. It deliberately has **no programmable blending, LESS depth test, texture mapping, or depth-write disable mode**. All such modes continue through P141/P140's original single-lane read/modify/write engine. This is not a drop-in P102/P132/P133 replacement, and active P102/P132 source files remain unchanged.

## Required gates

1. Real Icarus simulation of P142 plus P139/P138 bank RAM versus unchanged P102 color/depth frame output on **4x4, 7x5 and 8x8**, including two clears, three fully covered triangles, reversed winding, partial triangle, scissor-clipped triangle, degenerate triangle, invalid debug XY and shared reset during an unfinished draw.
2. Every 48-bit pixel is compared after every successful clear/draw. Count accepted writes for each draw and assert three full-screen draws complete in exactly **ceil(PIXELS/2)** raster clocks, while original P102 needs PIXELS clocks. Non-vacuous simultaneous two-write pulses must be observed and enumerated. Odd-row geometry must pass, including a pair split across rows.
3. Real Yosys `synth_ecp5` and nextpnr ECP5-85K CABGA756 speed6, 4x4, seed1 and 5MHz minimum research timing threshold; at least 2 real `DP16KD` mapped cells; bounds and no unmapped cells/latches. Record clock Fmax and mapped cell count; explicitly note when timing/area is worse than P141.
4. Inherited P126, P127, P132, P134, P140 and P141 regression workflows must pass on the exact PR head. No missing, skipped, failed or pending gates may be considered success.
5. Remain a draft until all checks complete. P143 could later integrate transparent/depth-dependent RMW paths with hazard-safe pending pixel FIFOs and rigorous ordering; this PR must not claim support before it exists.

## Scope caveat

The 2 pixels/clock number refers **only to test RTL's eligible opaque draws**, not a full graphics pipeline or GPU throughput benchmark. This project has no finished PCB, physical FPGA bitstream tests, actual VRAM, PCIe device, shader ISA, shader cores, display output, production driver, physical CDC timing signoff, independent clock skew constraints or game FPS measurements.
