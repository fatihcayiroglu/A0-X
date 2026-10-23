# P129 — Real 4×4 raster/scissor/depth/blend integration witness

This adds no new hardware feature. It runs the existing experimental P102
integration in an **actual Icarus Verilog simulator** instead of treating
separate P68, P70, P38 tests as an end-to-end graphics proof.

Verified scenario (only when GitHub Actions returns a real-simulator PASS):

1. Clear sixteen pixels to black and maximum depth.
2. Render one triangular patch with six covered red pixels at depth 100;
   prove vertex and render state are snapshotted after transaction acceptance.
3. Reject six more covered fragments at depth 200 in LESS mode.
4. Render a nearer blue triangle with 50%-ish alpha (128/255), no depth
   write, and a 2×2 scissor producing three blended RGB pixels `0x7f0080`.
5. Validate all sixteen framebuffer color/depth readbacks, off-screen
   read gating, reset in the middle of a clear, and reinitialization.

`python3 -B A0-GPU/tools/a0_p129_graphics_gate.py --evidence EVIDENCE/P129/graphics`
requires `iverilog` and `vvp` and exits `2 NOT_RUN` if either is absent.
Synthetic or duplicate stdout witnesses cannot satisfy the gate.

P129 does **not** qualify a complete GPU, hardware display controller,
HDMI/DisplayPort output, PCIe, VRAM timing, fabrication, or programmed FPGA.
P128's selected-block HX8K PnR remains valid evidence for its limited scope,
not this larger graphics integration. FPGA mapping of the complete P102 top
and eventual graphics/compute/memory integration require separate gates.