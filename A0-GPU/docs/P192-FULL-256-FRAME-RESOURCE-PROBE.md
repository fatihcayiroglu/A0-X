# P192: full 256×256 framebuffer contract and ECP5 area feasibility

## Purpose
P191 #68 physically placed/routed a 256×4 opt-in renderer at 39.14 MHz and passed real host-visible 256×4 and 4×256 shader/depth/RGB checks. P192 is the next **experimental** full-size test; it does not assert that a 256×256 board implementation exists or that it achieves any clock rate.

A 256×256 color+depth buffer contains 65,536 globally addressed 48-bit pixels (384 KiB of packed data, excluding implementation overhead). The P175 opt-in `TILED_SCREEN_UV=1` mode maps the shader's *legacy screen-space Q8.8 UV* to modulo-128 local tiles; the framebuffer and depth address continue to use global X/Y, including (129,129) and (255,255). Affine and perspective UV remain separate modes. A full-width/height mode requires the P138 `FULL_CLEAR_GUARD` and **complete initialization of all pixels** before any host read or draw.

## Strict proof jobs

1. **Real Icarus 256×256:** run the actual P175 host top, P38 raster, P162 shader, and P144/P139/P138 framebuffer. Reject every missing/reordered accepted clear address from 0 through 65,535; require exactly 65,536 clear writes. Check RGB/depth at (0,0), (1,1), (129,129), and (255,255); reject out-of-range (256,0). Draw a triangle wholly in the high-high tile and verify local shader R0 UV (1,1), unchanged distant corners, output color/depth, and retired instruction counts. Reset must deny uninitialized host reads, then reprogram the reset-cleared RGB/depth registers and complete another 65,536-write initialization with corner readback. No skipped tests, no retries, timeout is an actual failure.
2. **Real LFE5U-85F-targeted Yosys synthesis, not placement/route:** use the same renderer with full `FRAME_WIDTH=256`, `FRAME_HEIGHT=256`, and `TILED_SCREEN_UV=1`. Emit an actual mapped ECP5 netlist and log. Explicitly report and bound 77 host IO bits, up to 208 EBR blocks, 72 DSPs, 83,640 LUT4s, and <9,195 FFs; reject unsupported/unmapped/latch cells. A Yosys pass proves only *mapped resource feasibility*, not timing closure, physical routing, board reliability, real VRAM, PCIe, driver support, power or FPS. If the capacity gate is red, preserve the original failure and raw artifacts rather than treating it as green.

This draft stacks on P191 #68. P191 itself remains draft pending inherited integration/review; do not merge P192 ahead of parents or represent a synthesis-only pass as a hardware-tested graphics card.

## Next engineering decision
If the full 256×256 area proof passes, add a separately bounded actual nextpnr physical timing experiment; if it fails, use the measured resource bottleneck to redesign bank packing or reduce the geometry before claiming routability. Independently review all exact-head green requirements before integration.
