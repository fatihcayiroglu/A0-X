# P215 — dual-clock-qualified reset release for actual EBR frame pipeline

**Stacked draft on P214 (#91).** This is not a PLL, HDMI/DP interface, board signoff, formal CDC/MTBF proof or production GPU.

## Reset problem closed
P212 Gray FIFO and P214 pixel-local EBR scrub already use independent clocks. A very short external reset pulse can be *missed* by a synchronous-reset host pipeline while the pixel-domain asynchronous reset clears its state. That creates a split-reset risk. P215 adds a common reset supervisor without changing the committed frame, FIFO or VBlank datapath.

`a0_p215_dual_clock_reset_supervisor`:
- Asynchronously asserts two local 2-bit reset-release pipelines whenever `raw_rst_n` goes low, even for a pulse shorter than either host/pixel clock period.
- Each pipeline shifts in a high level on its own clock. `fabric_rst_n` remains **low until at least two host rising edges AND at least two pixel rising edges** after raw reset release.
- If either clock stops during reset release, fabric reset remains asserted. The shared fabric reset drives the unchanged P214/P213 raster, P212 FIFO, and P210 committed physical EBR source. After release, the existing pixel EBR scrub must still finish before pixel acquisition starts.
- This enforces a minimum reset observation window but **does not prove arbitrary asynchronous reset recovery/removal timing, clock-gating signoff, metastability MTBF, live reconfiguration, or power-sequencing behavior**. No board-specific pin/oscillator assumptions.

`a0_p215_supervised_pixel_raster` wraps P213/P214 and preserves the same 83 I/O bits including two external clocks.

## Required evidence
- `a0_p215_dual_clock_reset_supervisor_tb`: both host/pixel clock-speed orderings, six 2-ns reset pulses per setting, asynchronous assertion, two-edge release per clock, and stopped-pixel-clock refusal to release.
- `a0_p215_supervised_pixel_raster_tb`: 8-word and 1024-word real P203→P214 source chain, complete front frames 1/2, duplicate drain, VBlank swap, exact video/blank sync, both pixel EBR scrubs, and a **2-ns raw reset pulse after actual use**. The test checks both full pixel memory arrays zero afterwards, source fault cleared and video held black.
- Inherited P175–P214 tests must remain green. Hardware gate requires actual Yosys ECP5 mapped cells, 83 I/O bits, ≥21 DP16KD EBR, nextpnr ECP5-85K CABGA381 route, both **host_clk** and **pixel_clk** physically reported with nonzero Fmax and experimental ≥10MHz floor. These reports do not constitute CDC false-path/MTBF constraints. Preserve artifacts for failures; no retries/skips/waivers.

## Known limits
No oscillator or PLL instantiated or clock pins constrained, no differential video PHY or output, no independent board timing constraints or formal CDC lint, no PCIe/DDR/driver/performance proof. Keep **draft and stacked** for independent review, do not merge without explicit owner authorization.
