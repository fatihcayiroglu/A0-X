# P222 — FIFO saturation negative fault-injection proof

**Draft stack:** P222 on [P221 #98](https://github.com/fatihcayiroglu/A0-X/pull/98). No production RTL changes.

## What P222 proves

P221 genuinely filled the physical P216 split-reset dual-clock FIFO at 8 entries while transmitting real committed host EBR pixels. P222 tests that those full/backpressure/frame guards **fail on a broken implementation** rather than always passing. Every positive baseline and every negative case runs the entire P221 end-to-end test under both host/pixel clock orderings and at both frame sizes (8, 1024 words).

First, the **four intact RTL cases** must pass and emit their P221 saturation markers. Then six single-mutation RTL variants, run four times each (**24 dynamic negative executions**), deliberately cause:

1. Missing FIFO full detection.
2. Write-ready asserted despite full FIFO (overflow/backpressure bypass).
3. Read pointer advances two entries per packet (skip/reordering).
4. FIFO payload read from the next physical memory address.
5. Reversed frame-start and frame-end packet markers.
6. Invalid prefetch while the FIFO is empty.

Each mutant **must compile successfully**, then be rejected by a real `P212` or `P221` HDL `FATAL` functional assertion. A green mutant, compilation error, unrelated crash, or timeout is a **failed test**. The exact first failure for every mutant, frame size, and clock mode is recorded in `EVIDENCE/P222/mutation/first_failures.json`. There are no retries, fake green, hidden skips, or partial coverage credit.

The P222 workflow also retains all inherited P175–P221 gates, including P220's 18 mutation negatives, and physically synthesizes/routes the **unchanged default P216** top with Yosys+nextpnr ECP5-85K CABGA381 and two separately reported clock Fmax figures. The 8-entry FIFO is a test configuration only, not the mapped physical top.

This is dynamic simulation fault sensitivity, **not** formal CDC/metastability MTBF, a physical board/oscillator/pin/PVT signoff, a finished HDMI/DP GPU, or commercial performance proof. The branch remains a draft pending independent review and explicit owner approval.
