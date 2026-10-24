# P143 — incremental two-pixel raster edges, no per-pixel multipliers

Status: **draft**; not merged until actual RTL and ECP5 results on final PR head pass.

The P142 dual opaque raster achieved exact two-address/cycle writes, but its two independent P38 coverage functions evaluated six signed 36-bit edge products per clock. The resulting full prototype routed ECP5-85K research clock Fmax was **27.449 MHz**, lower than single-pixel P141's ~38.23 MHz.

P143 preserves the P142 interface and opaque-only contract, still using genuine P139/P138 dual-bank BRAM. Each triangle snapshots three raw-oriented initial 36-bit edge values at pixel center (0.5,0.5) and signed 18-bit x/y deltas on launch. Each **accepted pair** evaluates two adjacent linear pixels by adding:

`E(x+1,y) = E(x,y) - 2*dy`

`E(0,y+1) = row_start(y) + 2*dx`

Two one-position advances create the **next pair's** starting edge. For an odd-width frame, a pair can straddle a row boundary. For a width-1 frame, both steps wrap rows. The second step must start from the **updated intermediate row origin**, not the previous row's origin. Winding sign and top-left ownership remain the frozen P136/P142 original rules, and the original single-write-per-bank constraint holds. Degenerate triangle, reset, scissor, host read semantics and the limited opaque-depth-ALWAYS contract are unchanged.

## Fail-closed tests

- P142's full independent original P102 RGB/depth framebuffer oracle reruns on 4x4,7x5,8x8 including 3 full-cover, reverse-winding, partial, scissor, degenerate and reset-during-raster triangles. Require exact accepted writes and full draw clocks ceil(PIXELS/2).
- New real Icarus regression on **1x9, 9x1, 6x6** catches row-boundary and the double-wrap width-1 case; non-vacuous pixel write counts and exact frame outputs required. A follow-on randomized large-coordinate fuzz suite should be added before claiming the edge algorithm is production-qualified.
- Full real Yosys ECP5 technology mapping and nextpnr ECP5-85K place-and-route, exact same 4x4 CABGA756 speed6 seed1 and `--freq 5 --lpf-allow-unconstrained` as P142. Require >=2 genuine DP16KD, no unmapped cells/latches, external research IO <=384, and **GPU mapped Fmax >=27.44 MHz**. Record whether actually improved, don't assume.
- Keep P126/P127/P132/P134 and other triggered inherited regressions successful on the exact latest head. Never bypass evidence or merge on a failing gate.

This prototype still does not implement programmatic shaders, alpha/depth-dependent dual lanes, hardware PCIe/VRAM/display/driver, physical CDC sign-off, real board operation or FPS measurements.
