# P231 — Full-frame pixel-divider boundary regression

## Baseline
This test-only proposal is stacked on the physically green P226 head `29e00bb66214bdceb47118a4cff69c6a1ff5e937`. It **does not modify synthesizable RTL**. P226's measured 13,323 LUT4 / 4,729 FF and the existing routed frequencies remain the physical reference; P231 makes **no area/frequency improvement claim**.

## Test contract
Run the unchanged `a0_p226_domain_local_reset_raster` against actual committed frame memories and the 92-bit Gray-clock-crossing FIFO:
- `PIXEL_DIV = 3` (smallest legal), `4`, `65` (non-power-of-two above 64) and `255`.
- For each divider, run three independently phased host/pixel clock relationships: host 4ns vs pixel 7ns half-period; host 7ns vs pixel 4ns; host 5ns vs pixel 6ns.
- Each of twelve executions verifies two full, indexed, nonzero 8-pixel frames and two epochs across VBlank, exact horizontal/vertical sync and DE, blanking, unbroken pixel-clock-enable cadence, duplicate-epoch drain, and rejected source mutation.
- It exercises an incomplete-frame fatal path, a 2ns asynchronous reset including physical EBR scrub, stale-nonzero invalid pipeline payload, stopped clocks with pixel-first restart and remote-ready hold.
- Each run must reach a strict non-vacuous PASS marker. All `$fatal`s and compilation errors are real CI failures. No retries, `skip`, `continue-on-error`, or silent fallback.
- Save every test output and the exact source SHA as an artifact. First failing run is dispositive.

## Deliberate scope
This is simulation evidence for divider parameter correctness and real FPGA-targeted RTL, **not** timing closure at these dividers, PLL design, real monitor/EDID negotiation, HDMI/DisplayPort, board bring-up, game rendering, or a competitor GPU benchmark. An individual red divider configuration remains a real blocker; do not assert all twelve passed without inspecting the exact-head CI.

## Why this regression matters
Previous P227–P230 micro-optimizations failed physical acceptance, while the GPU still needs dependable software-configurable display timing. This test strengthens parameter behavior without weakening the physically green P226 design or promoting an unmeasured optimization.
