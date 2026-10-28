# P223 — Zero-bubble registered EBR FIFO refill (experimental ECP5)

Status: **stacked DRAFT** on P222; not merged into `main`. No physical board signoff.

## Measurable optimization

P216 used `prefetch = r_release_q && !rd_valid_q && !empty`.
Even if the reader was continuously ready and the RAM already held more
packets, its registered data output became invalid between accepted words.

P223 is a **new top-level hardware variant**, preserving the P216 source:
```systemverilog
wire consume = rd_valid && rd_ready;
wire prefetch = r_release_q && !empty && (!rd_valid_q || consume);
```

- The read pointer points to the next **RAM** word; the output register has
  already consumed its own earlier RAM slot. The empty comparison therefore
  applies to the next candidate, not to the current registered output.
- A valid word stays stable while `rd_ready=0`; only an accepted word permits
  replacement on that edge. Synchronous RAM read is retained for ECP5 EBR.
- When RAM contains more than one word and the sink is always ready, a
  replacement can be loaded on each read rising edge with no forced bubble.
- Empty queue and output-under-backpressure remain fail-closed. No
  speculative pointer advance into an uncommitted word.

## Reproducible tests

1. **Old-versus-new physical-register simulation**: `a0_p223_zero_bubble_fifo_tb.sv`
   runs two independently clocked FIFOs with identical 32×92-bit payloads.
   It requires all data to match and a 16-beat consecutive ready/valid window;
   for a 32-entry preloaded packet stream, P223's last pop is at read edge 31,
   versus at least edge 62 for legacy P216. Both are read at constant
   ready=1 following actual preload and 12 clocks of stable backpressure.
   Test both 8 ns host/14 ns pixel and 14 ns host/8 ns pixel clock periods.
   Challenge a fully registered live output with a **2 ns asynchronous reset**;
   neither variant may leak or replay stale packets after release.
2. **Real full-queue EBR frame test**: `a0_p223_saturated_split_queue_tb.sv`
   uses actual P203–P210 committed physical frame producer. Runs 8 and 1024
   frame words × both independent clock ratios using a deliberately narrow
   `FIFO_ADDR_BITS=3` queue. Requires physically full FIFO, stable head
   under 24 pixel edges of backpressure, first/last markers and epoch order,
   and no stale EBR frame after 2 ns full-queue reset.
3. Retain **all P175–P222 tests and mutations**, including 24 compiling
   FIFO-full dynamic mutants and previous 83-pin P216 routed baseline.
   All checks run without retries; failed runs remain evidence, not green.
4. **New real P223 Yosys ECP5 synthesis + nextpnr route** on
   `LFE5U-85F CABGA381 -6`; require 83 top-level I/O bits, at least 21
   `DP16KD` blocks, no unmapped/latches, two independently routed clocks
   with experimental floor 10 MHz. New and baseline netlists/routes are
   independently saved in CI evidence.

## Scope / non-claims

Read-edge latency is **functional RTL throughput under a preloaded FIFO**.
It is not video/PCIe bandwidth, game FPS, actual power consumption, the
silicon's measured Fmax, or proof of formal CDC/metastability MTBF.
The physical ECP5 result is an **unconstrained board-level demonstration**
with no pin map, production SI/PI, temperature/voltage corners, video PHY,
physical FPGA board measurement, or actual discrete GPU chip. Baseline
Fmax and optimized Fmax are reported independently; the optimization may
affect routed timing. Further tests are required before any deployment.

**Merge policy:** stacked draft PR, no merge until explicit owner approval,
independent review, and exact-head required checks all pass.
