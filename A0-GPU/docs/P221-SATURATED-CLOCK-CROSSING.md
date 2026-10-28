# P221 — Saturated real EBR split-reset CDC queue

**Stack:** P221 draft on [P220 #97](https://github.com/fatihcayiroglu/A0-X/pull/97), preserving the original P216 synthesizable RTL. No hardware board configuration changes.

## Purpose

P212 proved two independent full frames under ordinary periodic backpressure. P221 drives the complete P216 host/pixel split-reset frame queue with a deliberately narrow **8-entry physical dual-clock FIFO** (`FIFO_ADDR_BITS=3` test configuration) until the actual FIFO `full` flag asserts. Test reads use the real upstream committed P203-to-P210 EBR pipeline; they are not fabricated pixel packets.

For both 8-word and 1024-word frames and for two independent host/pixel clock ratios (8ns/14ns and 14ns/8ns):

1. A partial source frame must fail closed.
2. Commit complete source frame epoch 1 and withhold downstream consumption until the FIFO **truly fills**. Require `busy`, a valid first packet, immutable pixel data/index/epoch and sustained `full` for 24 pixel-clock edges.
3. Concurrently commit all addresses of a second physical frame (epoch 2) while draining the backpressured pixel stream. Require ordered indices, start/end markers, exact 48-bit values, at least one complete old frame, and a frame-boundary-only change to epoch 2 (never a torn or prematurely published frame).
4. Stop reading again until the FIFO becomes **full on epoch 2**; apply a 2ns asynchronous raw reset while full. Assert both independent domain resets, immediate invalid/zero pixel output, zero FIFO Gray pointers, no stale replay after release, and actual upstream EBR scrub.

Positive marker `P221_SATURATED_CDC_PASS` requires all four full scenarios. Every scenario is compiled and executed in CI at the exact PR head; failed/partial/skipped tests do not count as pass.

## Physical scope

P221 inherits P175–P220 positive/negative gates and real ECP5-85K CABGA381 Yosys/nextpnr routing of the **unchanged default P216 top** (83 I/O, >=21 DP16KD, both routed host/pixel clock frequencies >=10MHz). The narrow 8-entry FIFO is a **test parameter** and is *not* the physically routed top configuration. No physical board pins or oscillator are assigned, and the result is not MTBF/formal CDC/board timing certification, video PHY, or production GPU proof. Draft, independent review and owner approval before any merge.
