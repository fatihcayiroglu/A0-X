# P233 — two-cycle real EBR scanout experiment

P233 builds upon P232 RGB888 scanout, retaining fully-qualified P231/P232 test and physical evidence on their original immutable PR heads. Existing P226/P232 and P231 source branches are NOT changed.

## Actual RTL change

P226's raster prefetches selected front-bank EBR data on `div_q == PIXEL_DIV-2`; it consumes the registered output and advances horizontal/vertical raster on `div_q == PIXEL_DIV-1`. For PIXEL_DIV=2, prefetch occurs at division phase 0, followed by consumption at phase 1. The EBR remains a synchronous one-clock read and no speculative latch or combinational RAM read is introduced. P233 changes the legal lower bound from 3 to 2; PIXEL_DIV=1 remains illegal because the current look-ahead doesn't prefetch the next address across a tick boundary.

## Strict acceptance gate

- Three independent host/pixel clock ratios, with 8 and 1024 full 48-bit framebuffer-word geometries, each require two distinct full RGB888 displayed frame epochs and correct pixel ordering.
- Reject incomplete frames, wrong VBlank switch, invalid stage writes, pixel CE cadence faults, stale data after 2ns asynchronous reset, and stopped clocks with pixel-first restart.
- Compare independent P233 full RGB888 physical wrapper and exact 48-bit source at every pixel edge, including sync signals and Z24 isolation.
- The inherited P232 twelve DIV=3/4/65/255 complete frame simulations and real ECP5-85K physical route MUST remain green on this P233 head; no backwards regression or source base retargeting.
- Do not infer throughput benefit from DIV=2 until actual directed real RTL timing evidence; and do not call enabled-pixel pulses a clock/PHY.

## Performance and scope

P232 routed host/pixel clocks 52.0183/92.1914 MHz, so the **theoretical maximum** enable cadence of PIXEL_DIV=2 is 46.0957 million pixel enables per second at that routed pixel domain Fmax; the actual P233 routed Fmax must be reported anew before accepting that number for P233. This is not monitor refresh / framebuffer throughput / physical board bandwidth. No HDMI/DisplayPort PHY, PLL, EDID, board pin map, PCIe, external VRAM or real consumer GPU throughput exists here.

All runs are real and first-failure only; no retries, skip, continue-on-error or accepting a compiler failure as success. Keep draft/unmerged pending review and explicit owner approval.
