# P212 — Gray-pointer dual-clock pixel FIFO, real P210 committed EBR source

This is a **draft, stacked on P211 (#88)**. The goal is safe transport between an independent host/scanout clock and pixel-consumer clock; no HDMI/DP, monitor PLL or real board evidence is claimed.

## Modules
- `a0_p212_gray_async_fifo`: synthesizable 92-bit (48 pixel + 10 word index + 32 epoch + frame-start/end) dual-clock FIFO, default depth 64. Independent binary write/read pointers are encoded into Gray before crossing domains, and each crossing uses a dedicated two-flop synchronizer. Full detection in the write domain inverts the top two synchronized Gray bits; empty detection in the read domain compares synchronized producer pointer with the read pointer. Writes occur only on `wr_valid&&wr_ready`. A synchronously prefetched read output remains stable until `rd_valid&&rd_ready`.
- Both domains share an asynchronously asserted `rst_n`; each locally delays release by two clock edges. The FIFO does not scrub physical RAM; it clears all pointer/valid state and **masks read data to zero when invalid**. Operational use requires both domains to observe the same reset. Separately resetting only one live clock domain is not supported.
- `a0_p212_async_frame_queue` connects the unchanged P210 real EBR pixel producer to the FIFO. The consumer has its own `pixel_clk` and ready/valid interface. The host-domain sticky source fault is synchronized through two flops to `pixel_fault` in the read domain; after fault, no pixel is exposed.
- In this buffering stage, P210's publication fence means its last old pixel was **enqueued**, not displayed or consumed by the asynchronous sink. All buffered samples retain exact epoch/index/frame-end tagging. A consumer must validate these; the current P211 raster is **not yet integrated with this asynchronous FIFO**.
- A slow consumer creates backpressure through FIFO full, naturally stopping P210 read requests without losing or duplicating a FIFO entry. The frontend may enqueue repeated old complete frames until a new publication occurs; this is allowed and not a tear.

## Proofs
- Independent FIFO `a0_p212_gray_async_fifo_tb` in both 8/14 ns and 14/8 ns clock ratios: full, denied overflow, backpressure-stable output, 300+ wraparound transactions under concurrent writes/reads, reset with queued data, post-reset clean first write.
- End-to-end `a0_p212_async_frame_queue_tb` at 8 and 1024 words: actual P203→P210 committed EBR chain, two independent banks/epochs, asynchronous pixel consumer, host writes while pixel reads, repeated old frames allowed but no incomplete/mixed-epoch frame or invalid marker, sticky fault synchronizer on incomplete publication, reset scrub and output masking.
- CI repeats inherited real hardware RTL tests and physically synthesizes/place-routes the exact P212 top using ECP5-85K CABGA381. It must confirm 125 top I/O bits, ≥12 actual EBR blocks (plus any inferred FIFO EBR), no blackboxes/latches, and nonzero routed clock reports. The physical placement is **not** a proof of independent-clock timing exceptions or metastability MTBF; that requires CDC reviews, constraints and board testing.

## Known limitations
The 64-entry FIFO adds transport elasticity, not an entire 1024-word frame or a finished scanline buffer. No HD display timings, independently clocked P211 raster, PLL, line DMA, HDMI/DP PHY, external VRAM, PCIe, board constraints, electrical measurements or usable GPU driver yet. No merge without independent review, exact-head CI and explicit user authorization.
