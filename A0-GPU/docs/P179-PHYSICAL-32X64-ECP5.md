# P179: physical ECP5 32×64 framebuffer scalability experiment

P177 established a **real** LFE5U-85F CABGA756 speed-grade-6 physical route at 32×32: **35.04 MHz**, 77 host pins, five BRAMs, 72 DSPs, 22,802 mapped LUT/comb primitives and 6,073 flip-flops. P178 separately established 64×32/32×64/64×64 end-to-end pixel oracles and shader timing in actual RTL simulation.

P179 changes only the physical-verification workflow, **not synthesizable RTL**, to measure whether a twofold framebuffer growth to **32×64 (2,048 pixels)** still physically places and routes.

## Strict real-hardware-fit contract

- Fresh `yosys synth_ecp5` of `a0_p175_scaled_programmed_command_top` at `FRAME_WIDTH=32, FRAME_HEIGHT=64` with `check -assert`.
- Fresh `nextpnr-ecp5` targeting LFE5U-85F, CABGA756, speed 6, seed 1 with a minimal **5 MHz experimental research routability floor**, not a throughput objective.
- Exactly 77 physical host pins; 5..32 inferred `DP16KD` RAM blocks; 40..72 actual `MULT18X18D` DSP blocks; valid nonzero `TRELLIS_COMB` and `TRELLIS_FF` mapped primitive counts within 83,640 each, and zero black boxes, high-level cells, or inferred latches.
- Route report must contain a positive **achieved** `fmax` meeting the experimental floor. Preserve complete Yosys netlist, synthesizer log, route timing/area report and nextpnr log as CI artifact **even on failure**. No skips, no simulation substituted for a physical route.
- Baseline 32×32 versus 32×64 is an *area/frequency trend* only; do not convert MHz directly to pixels/s or game FPS.

## Nonclaims and integration

This research workflow **must stay draft** until exact-head route plus host/RTL checks succeed and measurements are reviewed. A failure is evidence of an area or routing limitation, not grounds to soften the floor or hide a negative result. **Do not modify the existing P172/P173/P177/P178 ratchets.**

A successful 32×64 place-and-route is neither evidence of physically routable 64×64 nor a consumer-grade display engine, VRAM capacity, PCIe interface, game compatibility, or RTX 6090 competitive performance. Next research step is a separately gated physical 64×64 attempt and/or framebuffer storage architecture redesign based on the measured resource trend.
