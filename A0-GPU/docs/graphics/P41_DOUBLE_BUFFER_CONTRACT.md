# P41 — Double-buffered local frame ownership (development; Python reference checked; RTL not simulated)

P41 introduces `rtl/graphics/a0_triangle_double_buffer_display_p41.sv` and **does not replace** any P36/P37 production design, the earlier P39 framebuffer, or P40 scanout. This is an experiment in two static on-chip RGB888 framebuffers, with *one* owning render commands and *one* owning readout.

## Ownership model

* Reset selects front/display=0, back/render=1; both uninitialized.
* CLEAR and TRIANGLE commands are accepted **only** by the hidden back bank. No automatic copy of the front to the back is performed. A cleared bank must complete its full clear before drawing triangles.
* The producer decides when its frame is finished. `swap_valid && swap_ready` latches precisely one pending swap; this freezes render commands and `swap_ready` until a commit. The producer should hold valid until ready if making a synchronous request.
* `swap_ready` requires the render bank initialized, idle, and no other CLEAR/TRIANGLE command offered in the same cycle. The producer must wait for every `tri_done` and `clear_done` before requesting swap; the `render_busy` indication is an additional guard but does not replace per-command completion.
* If there is no initialized display bank, commit takes place on a subsequent rising edge without waiting for a frame. Otherwise, with scanning enabled, commit occurs only after `frame_done` signals an **accepted** final pixel of the previous frame. If scanning is disabled, abort and commit immediately on the next edge.
* On swap commit, scanout is disabled for one cycle, flushing any prefetched pixel from the old bank and restarting the next frame at (0,0) from the new front. `swap_done` pulses for one cycle following this commit.
* The old front becomes the new back. It may contain an older frame; clear before drawing a complete replacement. Rendering commands must not touch the active front.

## Known limitations / unresolved proof

* New RTL is authored and has passed a **limited noncanonical Verilator parse/elaboration check** with a placeholder std package, but has **not** passed an actual HDL simulation, canonical lint, synthesis, or formal verification. 13 Python reference tests and the inherited Python suite pass; these do not certify RTL behavior. The user requested all tests possible in this environment, with external-tool and physical tests later.
* Both banks currently implement P39's simulation-friendly combinational read arrays. This does not prove SRAM inference, dual-port SRAM timing, CDC safety, DMA, PCIe, DRAM/VRAM, HDMI/DisplayPort or real VSync synchronization.
* Output ready/valid is still a logical pixel stream, not a monitor pixel clock. `frame_done` refers to accepted logical pixels, not physical VBlank.
* `scan_enable` deassertion aborts the partial frame. Swap while disabled is immediate. No timestamp, dropped-frame counter, swap timeout, queued multi-swap or front-bank direct modification is provided.
* P37 is not canonically closed and P38–P41 are independent development modules pending full RTL and system integration.

## Verification roadmap (see `P41-STATUS.md` for executed versus pending gates)

1. Fresh HDL compilation and lint for P38, P39, P40, and P41, with exact tool versions; fix real warnings without changing previous milestone evidence.
2. Reset both banks; clear hidden bank and draw triangle. Before swap, scanout must be invalid. After accepted swap, first pixel is (0,0) with appropriate color.
3. While scanning a stable front frame, clear/draw back bank with opposite colors and force random `pixel_ready` stalls. Every accepted pixel before `swap_done` must use the original front image; no tearing.
4. Request swap mid-frame: no early commit; exactly one swap and one restart on accepted `frame_done`.
5. Deassert `scan_enable` mid-frame while swap pending: verify abort, immediate swap and no extraneous partial-frame continuation.
6. During pending swap, assert CLEAR/TRIANGLE inputs and show no acceptance until `swap_done`.
7. Two full swaps (ping-pong), raster/clear for both banks, degenerate triangles, height/width=1, reset mid-clear/swap, backpressure across EOF and SOF.
8. Assertion-based checks for bank ownership and stable stalled outputs, then mutation tests that must fail when bank isolation or boundary commit is broken.
9. FPGA BRAM inference and timing/resource checks for a real target; redesign P39 memory interface as synchronous memory if necessary.
10. Integrate with actual A0-X memory transactions, command scheduling and driver-level frame submission. This is not accomplished in P41.
