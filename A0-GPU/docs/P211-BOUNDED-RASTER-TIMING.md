# P211 — bounded single-clock raster timing for real P210 EBR frames

**Stacked draft on P210 (#87). This is an experimental clock-enable raster, not HDMI/DisplayPort or a production display controller.**

## Hardware contract
- `a0_p211_bounded_raster_timing` wraps P210 without altering its dual-bank committed physical EBR memory path. Default visible geometry is 32×32 48-bit pixels = **1024 frame words**, four actual 1024×48 EBR banks (12 ECP5 DP16KD blocks).
- One system `clk` and a parameterized `PIXEL_DIV` generate a periodic, one-cycle `pixel_ce` strobe. It is **not** an independent pixel PLL, true monitor pixel clock, or CDC-capable design.
- On each `pixel_ce`, registered `video_de` (data-enable), active-low `video_hsync` and `video_vsync`, and 48-bit `video_pixel` correspond to the same raster position. Counters cover every visible pixel, H front/sync/back porches and V front/sync/back porches; RGB is zero during all blank slots.
- Raster starts only after P210 has a validated first published pixel (index 0, frame start, nonzero epoch), so startup/scrub cannot produce a partial image.
- During each **active** slot P211 consumes exactly one `valid && ready` P210 pixel whose index, epoch and frame-start/end flags agree with the expected raster address. P210's previous last-pixel publication fence remains unchanged. A new epoch is allowed only at the next frame's word 0.
- If any active slot misses a pixel or sees a wrong index, epoch or marker, `underflow` and `fault` are sticky, `video_de=0` and `video_pixel=0` until reset. Horizontal/vertical sync and pixel enables keep running; downstream sees **black, not stale frame fragments**. Source is not acknowledged on a bad sample.
- No pixel-elastic FIFO is implemented. The producer must meet the fixed `PIXEL_DIV` budget; the default 64-cycle period is a conservative demonstration, **not real display bandwidth**.

## Tests and limitations
- `a0_p211_bounded_raster_timing_tb` uses **real P203→P210 RTL**, not a replacement RAM model, at 4×2 and 32×32 pixels. The tests read two complete frames from actual EBR banks, perform concurrent back writes, verify pixel order and epoch, all H/V blanking and sync slots, uninterrupted pixel-enable, queued publication at the last old pixel, published-front write lock and reset scrub.
- The independent `FAST=1` test deliberately requests a pixel every cycle and must prove actual physical EBR read-latency underflow, sticky fault and black output. No timeout/negative result may be counted as a success.
- CI requires Icarus, Yosys mapped ECP5 cells, nextpnr ECP5-85K CABGA381 speed6 physical route, **82 top-level I/O bits**, **≥12 DP16KD**, and post-route Fmax **≥10 MHz**. Artifact logs survive failures.
- Not yet present: dedicated pixel clock/PLL, asynchronous clocks/CDC, TMDS/HDMI, DisplayPort, EDID, line buffers, full HD monitor timings, external DDR, PCIe, board constraint file, physical board video capture, OS drivers, consumer GPU performance.

## Safe integration
This PR stays **draft** and is based on P210; it must not be independently merged onto main or interpreted as a finished display. Review exact-head CI and external implementation feedback before approval.
