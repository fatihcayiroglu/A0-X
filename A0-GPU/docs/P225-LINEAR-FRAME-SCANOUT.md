# P225 — Sequential scanout BRAM address generation

Status: stacked **draft** above P224. No merge until owner approval and independent review.

## Why change the hardware?

P224's pixel-local physical frame BRAM read used
`10'(v_q*H_ACTIVE+h_q)` for every prefetched active pixel. Even though the
horizontal and vertical raster counters advance predictably in row-major order,
this forced a combinational row-stride/address network in the pixel path.

P225 introduces a separate **10-bit registered scanout index**, initialized
to zero on asynchronous pixel reset and on initial frame start. It advances
by exactly one at each *active* pixel clock-enable tick, **never** during
horizontal or vertical blanking, and resets at the full-frame boundary.

The fetch still occurs at `PIXEL_DIV-2` and display at `PIXEL_DIV-1`,
so the next pixel address is stable before the physical synchronous BRAM
read. No pixel clock domain or FIFO ready/valid boundary changes. The
underlying P223 zero-bubble queue, P224 92-bit ingress register, 32-bit
frame epochs, atomic VBlank swap, and fault/reset barriers are kept.

The 10-bit counter covers at most 1024 words, exactly the validated raster
geometry limit. At 1024 words, incrementing the final index naturally
wraps to zero; full-frame boundary also resets it explicitly. Partial
frames and invalid geometry remain rejected.

## Evidence gates

1. `a0_p225_linear_scanout_raster_tb.sv`: six complete physical EBR
   real-image journeys (8/1024 words × three host/pixel clock ratios),
   unchanged full two-epoch pixel/sync checks. On every real pixel-clock
   prefetch, assert the **registered physical BRAM address equals the
   old row-major expression**. Require enough samples to cover a complete
   active frame and at least one line transition. Include 2ns reset,
   faulted incomplete frame, full local pixel BRAM scrub, VBlank swap and
   stopped-clock recovery.
2. Retain all previous P175–P224 positive and fault-injection gates,
   including P223's one-packet-every-pixel FIFO test and P224's six
   frame routes. Preserve first failed tests without retries.
3. Independently synthesize/route the real P225 top on the same ECP5-85K
   CABGA381 speed-6 target, timing floor 10 MHz, seed1. Compare exact-run
   P224 and P225 I/O=83, physical `DP16KD`≥21, FF/LUT usage,
   independent host/pixel Fmax, no latches/blackboxes. Any regression
   must be described honestly; resource/timing wins require measurements.

This experiment is **not** a discrete GPU, board-signoff clock,
PCIe/video PHY, CDC MTBF proof or gaming FPS. ECP5 timing is unconstrained
by any real board pin map, voltage/temperature PVT or external I/O timing.
