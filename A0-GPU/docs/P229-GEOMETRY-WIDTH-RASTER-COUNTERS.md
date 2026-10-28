# P229 — Elaborated raster geometry counter widths

**Independent sibling from exact-head-green P226 #103, NOT failed P227/P228.**
P226 retains original Rust-adjacent A0-X FPGA display architecture; this
experiment changes only pixel-clock *raster counters* in the isolated RTL.
No real GPU silicon, measured gaming FPS, video PHY, DDR/PCIe or board signoff.

## Rationale and exact RTL change

In P226 the horizontal and vertical raster clocks and pixel frequency
divider are all declared 16 bits, even if active geometry totals are much
smaller. The physical P226 critical path from registered packet data
to `h_q.CE` is 2.8 ns logic plus 7.9 ns routing; P228's rejected
experiment moved its critical path to `div_q.CE` with more LUT usage.

P229 uses elaborated `$clog2(HT)`, `$clog2(VT)`, and
`$clog2(PIXEL_DIV)` widths. The existing parameter legality checks
already require `HT,VT` between 5 and 65535, `PIXEL_DIV` between
3 and 65535, `WORDS` a power of two from 4 to 1024. Each width thus
represents all values 0 through bound-1 exactly, for non-power-of-two
and power-of-two totals. **No change** to epoch comparisons, pixel BRAM
writes, reset/scrub, CDC, FIFO, frame publication or duplicate refusal.

## Real testing

- Six P229 EBR-backed raster runs: 8/1024 words × three independent
  host/pixel ratios, complete two-frame atomic VBlank output,
  duplicate frame drops, 2 ns asynchronous reset and stopped clocks.
- Two additional 8-word full-frame runs with non-power-of-two
  `PIXEL_DIV=65` and `PIXEL_DIV=255`, to rule out truncation and
  prematurely rolled-over counters.
- Each run checks counter widths, bounds at all live pixel cycles,
  and nonzero samples in the high half of each counter's range,
  as well as inherited invalid stale-data controls.
- Preserve *all* earlier P175–P226 positive and negative/mutant
  tests, same-seed physically routed P216/P223/P224/P226.
- Physically route P229 on LFE5U-85F CABGA381 speed6 seed1, same
  independent host and pixel clocks. Require exactly 83 I/O,
  ≥21 EBR, 4600–(P226-1) FF, zero unmapped/blackbox/latches.
- **Strict prospective area/timing Pareto:** P229 LUT4 **< P226**,
  P229 pixel Fmax **≥ P226**, host Fmax **≥90% of P226**.
  If this is red, preserve first failure; never weaken the gate,
  retry into green or merge without owner approval and review.

Not production GPU readiness or physical device qualification.
