# P104 dual-bank command-to-frame research contract

Status: **development candidate; RTL unqualified**. This is a prototype source module, not FPGA, timing closure, or physical GPU evidence.

## Block boundary

- `a0_graphics_command_frontend_p43`: serializes CLEAR, TRIANGLE, PRESENT and emits 16-bit tagged results.
- Two instances of `a0_triangle_scissor_depth_blend_p102`: independent on-chip *behavioral* color and depth arrays; each bank has its own initialized bit and rasterizer.
- `a0_sync_frame_scanout_p42`: emits a one-shot frame through `pixel_valid/pixel_ready`, with start-of-frame/end-of-line/end-of-frame flags.
- P104 owns `display_bank` and its complement `render_bank`; all clears/draws target the *render* bank. Front output reads only the display bank.

## Handoff and concurrency

1. Following reset the display bank is bank 0 and render bank is bank 1; neither is initialized. CLEAR must initialize the render bank before the first PRESENT. Both color and depth memory values for every pixel are reset only via an explicit CLEAR, not assumed from uninitialized RTL arrays.
2. A PRESENT is accepted only when the back bank is initialized and not busy, no swap is pending and `scan_enable` allows starting the request. An accepted request latches pending regardless of subsequent `scan_enable` changes.
3. If no front frame is active, the bank swap commits on a later clock. If a front frame is active, the swap waits for the final pixel to be *accepted* (`pixel_valid && pixel_ready`). A stalled front pixel must remain stable, even during back-bank clears or draws.
4. The scanout `enable` is deliberately suppressed when the prior `frame_done` pulse is visible, to prevent an outstanding speculative read from the old display bank during a frame-boundary flip. A newly committed bank is scanned on subsequent clocks only.
5. PRESENT completion is emitted on bank commit, **not on scan completion**. The host can submit a CLEAR or TRIANGLE to the newly available back bank while the front scan drains. Front-bank readback is not a host DMA pathway.
6. Another PRESENT can wait at most one pending bank flip; the P43 frontend serializes commands. No flip can occur during the outgoing frame. Reset aborts both frame and pending swaps and invalidates both initialized flags.

## Explicit limitations and unsettled risks

The P102 banks use an asynchronous debug-array read behind a register, not true dual-port VRAM or an inferred FPGA BRAM guaranteed across devices. P43's fragment configuration comes from extra *pins*, not P45's binary command format. The design has no HDMI/DP timing, production driver/PCIe protocol, shader compiler, multi-command FIFO, QoS arbitration or synthesis resource evidence. Only one one-shot frame is emitted per PRESENT, not periodic refresh. Queued PRESENT may stall indefinitely if the receiving pixel consumer never asserts ready; this is deliberate backpressure, not a verified liveness guarantee. Dropping scan_enable after request acceptance does not cancel an active frame.

**Qualification:** Python `P104DoubleBankReference` gives independent *logical behavior* only; it is not cycle-by-cycle RTL simulation. The Icarus testbench covers ownership, pending swap, held first pixel, concurrent back clear, two full frames, reset, tags and invalid operations. This testbench is unexecuted until `python tests/run_p104_dual_bank.py` exits 0 under an installed real simulator. Exit 2 = NOT RUN. CI workflow is manual `workflow_dispatch`, not evidence that CI ran.
