# P191: integrated, opt-in tiled Q8.8 host rendering above 128

## Scope
P190 #67 proved the standalone `a0_p190_tiled_screen_uv` signed-byte + modulo-128 transform using 1,545 exact Icarus vectors and Yosys. P189 #66 physically routed **128x128 at 41.03 MHz**. P191 first wires the converter to **both immediate and delayed R0 seed paths** of P175. It adds a compile-time `TILED_SCREEN_UV` parameter to the scaled core and host top.

Default `TILED_SCREEN_UV=0` retains original <=128 geometry restriction and original hand-optimized nine-bit path. With opt-in true, allow width and height <=256 and <=65,536 pixels, while keeping global framebuffer x/y and P38 triangle geometry. Legacy *screen-offset UV* repeats per 128-pixel tile and still fails closed for signed Q8.8 offset overflow. Affine and perspective vertex UV modes retain their established interpolation/fault rules, not tile-local reinterpretation. This is an explicitly different shader coordinate mode; it does not claim global texture continuity.

## Required verification
- Real Icarus host-visible output on `256x4` and `4x256` proves (129,1) or (1,129) uses local R0 UV (1,1) while framebuffer color/depth stays at the actual global address. It also checks an uncovered low-address pixel, shader retirement count, accepted clear/full memory initialization, host denial after reset and re-clear. The 77-pin command bus and legacy default are unchanged.
- Real ECP5-85K CABGA756 speed-6 seed-1 Yosys+nextpnr **256x4** route with 77 IO, 5..32 BRAM, 40..72 DSP, <9195 FF, nonzero LUT4 and Fmax >=30 MHz; preserve failure evidence. A 256x4 route is not a 256x256 route.
- ALL inherited P126/P138/P139/P144/P172/P173/P177/P178/P179/P180/P186/P187/P188/P189 physical and full-frame oracles must be revalidated at exact integration head; any absent/failed workflow blocks merge. In particular default P172 16x16 must retain >=36.5 MHz.
- Remain a **draft stacked on P190 #67**, with prior #57/#63/#64/#65/#66 also unmerged pending independent review. Do not claim an RTX-like card, PCIe, real VRAM, driver or game FPS.

## Known gaps
- No full 256x256 exact pixel/depth/frame verification or ECP5 routability claim yet. An ECP5-85K's memory packing and routing at 65,536 pixels need a separate physical experiment.
- Mode selection is a compile-time research parameter, not yet a discoverable end-user driver control.
