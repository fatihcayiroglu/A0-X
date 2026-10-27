# P190: 128x128 tile-local Q8.8 screen UV contract (first step)

## Confirmed limit
The integrated P175 core rejects dimensions beyond 128x128, even though P138/P139/P144 address up to 65,536 pixels. Its optimized legacy UV preload uses only `raster_x[6:0]` and `raster_y[6:0]` because signed 16-bit Q8.8 shader coordinates cannot directly express +128..+255. Merely removing P175's geometry guard would silently wrap texture coordinates: prohibited.

## Standalone mathematical interface
`a0_p190_tiled_screen_uv` takes **global framebuffer pixels** (16-bit x/y), signed Q8.8 UV offset, and an explicit `tile_enable` opt-in. In legacy mode it rejects x/y >127. In tile mode it maps screen shader UV integer position to x mod 128 / y mod 128 and keeps the original offset fractional byte. A signed nine-bit integer add detects overflow before narrowing to 16-bit Q8.8. Both output UVs are zero on any invalid input and `invalid` is asserted. Global x/y are deliberately **not transformed** for depth, framebuffer addressing or triangle coverage.

This defines a repeating screen-coordinate *shader mode*; it does not claim that UVs remain globally continuous across tile borders. Higher-level software must explicitly select this behavior. It is not currently wired into P175; its default behavior and 128x128 geometry guard remain unchanged.

## Evidence and non-goals
Real Icarus vectors cover all 0..255 x values with signed and fractional UV offsets, original legacy window, explicit wrap semantics, 16-bit maximum x/y, and overflow with fault-zero masking. Genuine Yosys synthesis and no-latch check are required. Expected marker: `P190_TILED_SCREEN_UV_PASS cases=1545`. If these fail, preserve raw CI artifacts and leave draft.

Before integration into P175, add a compile-time opt-in guarded larger geometry, use the checked result for both immediate and delayed shader R0 preload, test host-visible pixels crossing x/y 127->128 including depth and reset, and rerun P180 independent 128x128 oracles plus P172/P177/P179/P186/P187/P188/P189 actual FPGA regressions at the exact candidate head. Do not weaken the old 16x16 timing ratchet. Physical 256x256 feasibility, device BRAM fit, drivers, game FPS and physical card are **not established** here.
