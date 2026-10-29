# P230 — Isolated pixel-frequency divider counter width

**DRAFT experiment stacked directly on green P226 #103.**
Not built from failed P227, P228 or P229. No board, consumer GPU
silicon, display PHY, video protocol, DDR or real-game performance claim.

## Controlled experiment

P229 narrowed all three raster counters (`h_q/v_q/div_q`), saved 30 FF
but **increased LUT by 98** and reduced pixel Fmax by 0.80% on the
same ECP5-85K CABGA381 seed. This red result is preserved on P229 #106.

P230 changes *only* `div_q` from a fixed `logic[15:0]` to
`logic[$clog2(PIXEL_DIV)-1:0]`. The Yosys-legal parameter
`3 <= PIXEL_DIV <= 65535` guarantees all 0..(DIV-1)
values fit. The independent h/v counters stay 16 bits as in P226.
No RTL edit to reset, fault, epoch comparison, BRAM, FIFO, CDC,
per-frame duplicate rejection, VBlank or public validity.
The default divider 64 uses a 6-bit register and must still tick
only once per 64 pixel-clock edges.

## Proof and first-failure-only gate

- Six physical-EBR end-to-end tests: 8/1024 frame words × three
  different host/pixel clock ratios; exactly two atomic frame epochs,
  no torn pixels, short and stopped-clock reset, stale invalid data,
  duplicate suppression, and fail-closed mutation behavior.
- Two extra complete 8-word raster runs for non-power-of-two
  `PIXEL_DIV=65` and `255`, verifying divider width, bounded states,
  high-half visits and **actual rollover**. All checks require nonzero
  execution counts; no test skip.
- Retain unchanged prior P175–P226 actual positive/negative gates
  and independently re-route P216, P223, P224, P226 references on
  LFE5U-85F CABGA381 speed6 seed1.
- P230 physical top must keep 83 pins, ≥21 EBR, independent clocks,
  zero unmapped/blackbox/latch cells, at least 4600 FF **but strictly
  fewer FF than P226**.
- Prespecified physical Pareto: **P230 LUT4 < P226 LUT4**,
  **P230 pixel Fmax ≥ P226**, and **host Fmax ≥90% P226**.
  Do not loosen on failure, retry false negatives into green,
  or merge without owner approval and independent review.

Real FPGA place/route is not physical-board qualification.
