# P137 — bounded linear raster framebuffer addressing

Status: **draft; real RTL and ECP5 results required before approval**.

## Motivation and change

P102 takes the current raster X,Y scan coordinate and computes its local color/depth RAM index with `raster_y*FRAME_WIDTH + raster_x` in the active pixel pipeline. P136's scan emits every framebuffer position in row-major order, including uncovered locations, and P102 hardwires `pixel_ready=1`. P137 replaces this coordinate multiplication with a narrow, single-register linear index: set to 0 on reset and triangle launch; increment on each active raster clock; wrap to 0 after final scan location. No extra latency or change to the public interface is intended.

**Crucial invariant:** This counter tracks raster *scan steps*, **not only pixels which pass coverage/depth/scissor**. It must count invisible locations, otherwise valid pixels would write to the wrong framebuffer address. Clearing continues to use its original independent `clear_index`. Debug reads retain their existing asynchronous coordinate-address computation; P137 **does not** claim physical multiported RAM or VRAM.

## Required qualification

1. Freeze pre-P137 P102 in `A0-GPU/tests/rtl/a0_p137_p102_reference.sv` with only its module name altered.
2. Real Icarus P102-vs-frozen-reference cycle-by-cycle comparison in 4x4, 7x5, 8x8 framebuffers: compare `initialized/busy/clear_ready/tri_ready/clear_done/tri_done/pixel_wrote/read_valid` and 24-bit colors/depths at moving debug addresses; after every clear/draw compare every valid framebuffer location and invalid X/Y reads.
3. Exercise initialization, clears, broad triangles, both windings, depth compares, depth writing on/off, blending, scissor, zero-area, changes to input vertices after launch, and shared reset mid-draw.
4. Preserve inherited P126–P136 exact-head CI including P132 direct-P102 framebuffer differential and P136 cycle-exact raster qualification.
5. Synthesize/route the full P133+P132+P102 design on real ECP5-85K with the same 4x4, seed=1, CABGA756 speed=6 and 5 MHz internal threshold. Report the **actual** Fmax vs P136 49.91 MHz, resource count and IO. If performance regresses, **do not merge** without resolving or explicitly reevaluating the design against performance goals.

## Limitations

This is a bounded 4x4 FPGA **research mapping** (with additional 7x5/8x8 RTL simulation), not a physical graphics card, external VRAM, physical multiport framebuffer, PCIe device, complete independent CDC skew analysis, production display timing, GPU driver, or gaming performance evidence. There is no assertion of pixels-per-second throughput gain until timing and real pipeline behavior are compared.
