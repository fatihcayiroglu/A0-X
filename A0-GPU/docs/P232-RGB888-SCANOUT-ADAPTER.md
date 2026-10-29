# P232 — RGB888-only experimental scanout interface

## Relationship to verified work

P232 is a separate draft stacked directly on P231 #108 (which is itself stacked on physically verified P226 #103). The unchanged P226 design remains the registered full 48-bit source. Its packed pixel word is **{RGB888[23:0], depth24[23:0]}**, as documented in P138/P172. Sending all 48 bits to display pins would expose a non-display field; interpreting it as three RGB16 channels would be wrong.

P232 adds a synthesized color-only top and adapter. The 24-bit external bus is `rgb888 = video_pixel[47:24]` during valid display, otherwise zero. The raw asynchronous reset and pixel fault also immediately mask RGB, DE, and pixel CE; sync pins idle high under reset/fault. Host bus, clock crossing, physical frame commit, dual frame banks, VBlank staging, pixel cadence, and reset supervisor remain P226's. No new clock domain, no altered latency, and no fake PHY.

## Acceptance

- Full RGB24 test patterns with different lower 24-bit depth payloads must preserve *exactly* the same RGB24; inactive/blank, fault and asynchronous reset must never leak stale color.
- A second complete P232 hardware wrapper consumes the **same** committed memory transactions and independent host/pixel clocks as the P231 test harness. Compare its host/fault/status, CE/DE/HS/VS, and RGB24 continuously to the independently instantiated P226 source.
- Require both full-frame P231 and color-only P232 markers in each **12** cases (four dividers 3/4/65/255 and three real opposing clock ratios). P231 asserts two complete 8-word colored frame epochs, atomic VBlank, no torn frame, invalid-lane protection, 2 ns reset, and stopped-clock recovery. Every run must be a real simulator PASS, not a skipped success.
- Independently synthesize, map and physically route the *actual P232 top* using Yosys + nextpnr ECP5-85K CABGA381 speed-6 seed 1. Enforce **exactly 59 I/O bits**, at least 15 real EBR blocks, non-vacuous LUT/FF counts, no unmapped/blackbox/latches, and independently routed host and pixel clocks both >=10 MHz (experimental floor). Report actual frequency/resources, not hypothetical gains.
- Preserve first failure and logs, no retries or relaxed gate. The original P226 uses 83 I/O bits; this change removes only **24 output depth bits**, not any host/clock/fault interface.

## Strict limitations

RGB888 + HS/VS/DE + clock-enable is **not** a ready-to-connect HDMI/DP monitor interface. There is no pixel clock PHY, monitor mode discovery/EDID, pin assignment/voltage constraint, link serialization, PLL, electrical SI check, formal CDC MTBF, board signoff, or consumer GPU performance validation. The output remains a pixel-clock-enable stream. ECP5 routing is experimental physical tool evidence, not a PCB/ASIC GPU.

The pixel scanout may synthesize smaller than P226 because unused Z24 display bits are optimized away; do not pretend a same-function area or speed Pareto improvement. No merge without review, exact-head green CI, and owner approval.
