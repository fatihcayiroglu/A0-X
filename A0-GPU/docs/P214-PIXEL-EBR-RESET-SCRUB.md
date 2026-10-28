# P214 — physical reset scrub of both pixel-clock-local EBR frame banks

**Draft stacked on P213 (#90).** This closes the P213 reset-remanence gap: it no longer relies solely on validity masking.

## Pixel-domain reset contract
- The two 1024×48 pixel-local EBR banks in `a0_p213_atomic_pixel_raster` each have a single physical write port. A 10-bit `scrub_addr_q` steps through **every** legal frame address; the high-priority single write path drives **both banks to zero every pixel clock** while `scrub_done_q=0`. Only after the last address is written can regular staging writes be accepted. The read path remains registered and independent, preserving actual EBR inference.
- `rst_n` asynchronously clears epoch, front/stage validity, counters and scrub state. Scrub may write address zero repeatedly while reset stays asserted, then walks the entire geometry after release. Incoming FIFO output is explicitly **not consumed** until full scrub completes; upstream FIFO backpressure preserves unconsumed samples. The video raster cannot start without a subsequent complete fresh frame.
- Reset aborts any in-progress capture. No stale valid output, HSYNC/VSYNC raster, or deferred old pixel can emerge before a newly complete epoch. Correct use requires reset shared between the two domains as already required by P212.
- Physically scrubbing pixels is not equivalent to guaranteed secure erasure against invasive hardware inspection or memory remanence under voltage/power loss. There is no claim of measured side-channel isolation.

## Tests
- Inherit all real P175→P213 positive/negative RTL gates and exact-head first-failure evidence.
- New `a0_p214_pixel_ebr_scrub_tb` runs both **8** and **1024** words. After cold and post-use resets it waits for the complete scrub walk, directly reads **every address of both physical frame arrays** in simulation and requires zero, then verifies two full distinct asynchronous-clock raster epochs, duplicate suppression, VBlank-only front swap, no tearing, front lock and reset non-exposure.
- Actual Yosys `synth_ecp5` and nextpnr ECP5-85K CABGA381 physical route must still expose exactly **83 top I/O bits**, **≥21 real DP16KD EBR** (15 original plus 6 pixel-local), no black boxes/latches and post-route Fmax ≥10MHz. Preserve failure artifact. No retry/skip/waiver.

## Remaining
Pixel PLL, real board oscillator and clock constraints, CDC static timing/MTBF and asynchronous reset-release audits, HDMI/DP encoding and PHY, live monitor, PCIe, production drivers, VRAM bandwidth and graphics performance are **not** completed. Keep draft/stacked, no merge without independent review and explicit user authorization.
