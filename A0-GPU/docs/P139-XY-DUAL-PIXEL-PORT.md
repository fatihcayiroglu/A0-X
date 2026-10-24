# P139 — two-lane XY framebuffer coordinate front-end

Status: **draft**; standalone research module requires real P139 test/route evidence before integration.

## Contract

The P139 module accepts **two independent (x,y) pixel requests** and forwards valid coordinates to the verified P138 two-bank 48-bit packed RGB888/depth24 scratchpad. A pixel index is `y*FRAME_WIDTH+x`; bank selection is linear index parity. Different bank requests may issue two independent writes, reads or a read+write in one clock. When requests compete for the same bank, lane 0 has priority and lane 1 asserts `req1_ready=0`, requiring an explicit retry.

X and Y bounds are checked **before** truncating the linear index. An out-of-bounds request is acknowledged with a deterministic error pulse and zero response data; it never occupies a bank or stalls the other lane. Responses use P138's fixed registered one-cycle pulse protocol; there is no `rsp_ready`, DMA or queue for downstream backpressure. Reads before writes or after reset return zero via P138 validity metadata, not by resetting the RAM array.

## Real qualification before merge

- Independent golden XY-indexed framebuffer array, not linked to either bank's internal storage. Test on **4×4, 7×5, 8×8, 32×32**, including row-parity transitions for odd width, 48-bit round-trip integrity, 500+ accepted dual operations per size, **160 bank collisions + retries**, invalid X and invalid Y while the other lane continues, reset/reuse and output one-cycle pulse behavior.
- Genuine Icarus RTL for P139 + real P138, not a mock. Fail closed for any missing marker, timeout or incomplete coverage; archive per-shape logs.
- Genuine ECP5-85K Yosys synthesis and nextpnr routed resource report of the complete P139+P138 standalone structure, at 4×4 fixed geometry, seed 1, CABGA756 speed grade 6, unconstrained external pins, 5 MHz internal research target. Require actual `DP16KD >= 2`; report exact mapped count and tool Fmax.
- Preserve all existing applicable P126-P138 gates on exact current PR head. Do not merge until every required job is green.

## Architectural boundary

**P139 is not wired into the existing P102/P132/P133 GPU raster/command pipeline.** It only establishes safe two-coordinate request routing into the real FPGA banked storage. The raster still scans one position per clock and has independent color/depth arrays. Do not claim two rasterized pixels per clock, real graphics throughput, VRAM, PCIe, gaming performance, physical board timing, or complete CDC qualification.

The subsequent step must decide how to route raster writes, depth comparisons and blending through synchronous read/modify/write stages with stalls and ordering, then run differential full-frame checks against frozen P102. Parallel pixel throughput must be measured only after that actual integration.
