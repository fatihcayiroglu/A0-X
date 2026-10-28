# P224 — Pixel EBR ingress register cut and routed timing comparison

**Status:** experimental stacked draft on P223 #100. No production merge.

## Timing issue measured in P223

Exact-head ECP5-85K/CABGA381 physical route of P223
([CI #40755467240](https://github.com/fatihcayiroglu/A0-X/actions/runs/40755467240))
reported **host 50.41 MHz, pixel 56.56 MHz, 13,567 LUT4, 4,636 FF,
21 DP16KD, and 83 I/O**. The reported pixel critical path starts at
`raster.source.queue.mem.*.DOB*` (registered FIFO EBR data),
decodes `src_epoch`, carries through the index/epoch guard and
`bank_write_addr` logic and finishes at the staging write controls.
This is a genuine physical routed path, not a guessed logic bottleneck.

## Optimization

P224 preserves P223's one-accepted-packet-per-read-clock registered
FIFO. Between its EBR output and the stage-bank epoch comparator, insert
a **92-bit, pixel-clock-local registered valid/payload boundary**.

- A source packet is recorded on the same pixel rising edge on which its
  `pixel_valid && pixel_ready` transaction completes.
- The destination compares and stores the **previous** registered packet
  on that edge. Processing and capture overlap, so the pipe can accept
  one packet each pixel cycle, with one extra cycle of initial latency.
- When the pixel raster cannot process a packet (ongoing reset scrubbing,
  fault), its `pixel_ready` is low and the register must not advance.
- Raw pixel reset asynchronously clears both pipeline validity and payload
  so a previously prefetched epoch cannot be replayed after reset.
- Existing ordering, 32-bit epoch fences, full-frame VBlank publication,
  pixel BRAM reset scrub, and both local clock-domain resets remain in force.

## Exact verification required

- Copy the **full P219 two-epoch real EBR display journey** onto the
  P224 top: 8 and 1024 words, three independent clock ratios and phases,
  2ns raw reset, stop/restart local clocks, no torn frame, VBlank swap,
  duplicate drop, no stale epoch.
- Preserve all preceding P175–P223 positive and negative gates, including
  P223's verified 32/32 zero-bubble FIFO and saturated queue tests.
- Synthesize **both** P223 and P224 tops for the same physical ECP5-85K
  CABGA381 speed-6 device with identical `nextpnr` seed and 10 MHz
  experimental floor. Verify 83 I/O bits, at least 21 real EBR blocks,
  no unmapped/latch cells, and two independently routed clock reports.
  Compare FF/LUT counts and independent host/pixel Fmax; do not call an
  unfavorable result an optimization.

## Important boundaries

Yosys/nextpnr unrouted board I/O cannot establish tested physical hardware
or real gaming performance. No pin map, signal/power integrity, voltage
or temperature corners, independent CDC MTBF proof, video PHY or production
GPU silicon. Functional zero-bubble transfer rate is not a gaming FPS
benchmark. **Never merge without owner approval and independent review.**
