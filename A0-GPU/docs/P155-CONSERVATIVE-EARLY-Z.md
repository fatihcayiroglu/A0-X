# P155 — conservative early depth rejection before fragment shader

P155 is an **experimental, optional** alternative to the verified P153/P154 shader raster; the originals remain unchanged. For a covered triangle pixel inside the scissor rectangle and configured depth op LESS / LESS_EQUAL, P155 first issues a synchronous *read-only* depth lookup through the actual P144/P139/P138 FPGA block RAM. If the incoming 24-bit unsigned depth cannot pass, the pixel is acknowledged to the stallable P38 raster **without executing any P151/P150 shader program and without writing either framebuffer value**. For a depth pass, the original P153 shader→P144 RMW proceeds unchanged; P144 checks depth again before commit. This is safe under the prototype's serialized single-fragment writes. Memory read errors latch FAULT and never silently advance. Host debug replies are only exposed during IDLE, never while P155 performs an internal Early-Z depth lookup. Alpha blend and scissor rules are preserved.

The separate 76-bit P155 packed host-command top sets MODE bit5 as the opt-in early-depth flag. Reserved bits 6–7 remain forbidden. Register 24 provides the per-draw count of definitely rejected covered fragments; it resets for each clear/draw. The programmable shader input format and full signed-16bit triangle vertices remain unchanged.

**Important performance trade-off:** Passing fragments must pay an extra synchronous BRAM depth read before shader and RMW, so Early-Z may make visible scenes slower. Its intended benefit is reducing expensive shader invocations in occluded scenes; no universal speedup or render FPS is claimed.

## Required evidence before merge

- Actual Icarus P155 full RGB+depth frame differential vs unchanged original P102 on 4x4, 7x5 and 8x8: 5 clears and 5 draws, including 2x2 scissor, zero-width scissor, reset while active, full triangle, **fully depth-occluded LESS** and **equal-depth LESS_EQUAL acceptance**, along with all 48-bit framebuffer reads after each clear/draw.
- Nonvacuous Early-Z: precisely 16/35/64 covered pixels rejected *before* P151 under the occluded scene, with no shader completion or framebuffer write for those pixels, while the equal-depth pass produces P102-identical shaded RGB and stored depth.
- Real narrow 76-bit packed host mode bit5 and reserved bit6, register24 rejected count and exact host P102 framebuffer in a full occluded scene. Re-run inherited P153/P154 tests at the PR exact head, not based on an older branch.
- Genuine ECP5-85K Yosys+nextpnr CABGA756 speed6 seed1, 4x4, 5MHz artificial internal research target, external pins unconstrained; real BRAM (>=2 DP16KD), shader DSP (>=4 MULT18X18D), no unmapped cells and bounded 76-bit host port.
- No physical card, PCIe, external VRAM, game FPS, graphics driver, shader compiler or FP32 is supported by these tests.
