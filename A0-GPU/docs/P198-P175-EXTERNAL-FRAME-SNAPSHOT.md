# P198 — Post-render P175 framebuffer snapshot to P197 word port

## Real integration boundary
The real P175 programmable host top has **internal color+depth BRAM**, not an external memory command port. Replacing that internal memory, bypassing depth/blending, or treating a separate FIFO's injected pixels as a rendered frame would be misleading.

P198 adds a synthesizable **post-render snapshot sequencer**:
1. After a P175 draw has completed, the sequencer takes exclusive ownership of the actual P175 6-bit research register bus (no simultaneous CPU/host traffic).
2. Per pixel it sets READ_XY, issues the existing asynchronous COMMAND=3 host framebuffer read, and reads RGB and depth result registers 18 and 19.
3. It publishes the actual 48-bit {RGB888,depth24} pixel with global 16-bit X/Y and valid/ready to the actual P195 two-word FIFO.
4. In the exact-head Icarus acceptance bench, P195 drives the actual synthesizable P197 read/write arbitration logic, which talks to the P196 65,536-word **simulation-only** backing-memory model.

This is **post-render export**, not live framebuffer remapping or VRAM replacement. P175 core RTL is not modified.

## Data integrity and failure behavior
- Fail closed if any host register command returns an error or a non-24-bit RGB/depth result, and remain in a failed state until common reset.
- Keep a valid pixel stable under P195 backpressure and advance the global cursor only when accepted.
- `done` counts 65,536 pixels **accepted by P195**, NOT committed to physical storage. Consumers must independently drain the FIFO and memory controller.
- Reset cancels the snapshot protocol; accepted P196 model writes persist, while P175 core is uninitialized until fully cleared and new P195 pending writes are discarded. Physical hardware must implement its own reset epoch contract.
- No concurrent host register access is allowed during the exporter lease; no scanout coherency is implied.

## Actual CI acceptance
1. Run actual Icarus 256×256 P175 full clear of 65,536 words, two genuinely shaded depth-tested triangles including (254,255)/(255,255) and the prior P194 pixel-oracle and post-reset protection.
2. Use the real P175 host register response path to export every pixel in strictly increasing global XY order. Scoreboard every P195-accepted 48-bit word against every P197 backend accepted write without duplication or reordering.
3. Concurrently issue 200 external-memory reads of the known first pixel during ongoing export; exercise deterministic stalls. Read back high-corner shaded RGB/depth, then reset both protocols and prove P196 test memory still retains the last completed frame.
4. Independently synthesize the P198 sequencer with Yosys and require `check -assert`; preserve raw logs/compiled simulation artifacts even on first failure. No retries or skipped assertions.

## Honest next steps
Actual external-memory integration requires a backpressure-aware P175 RMW replacement or coherent shadow-write interface, arbitration with raster and host, physical memory PHY/board support, and new FPGA placement+route. This step alone is **not** DDR, VRAM, DMA, PCIe, a production display engine, or proof of performance versus any graphics card.

Draft stacked on #74, pending independent review and exact-head CI; no authorization to merge parent PRs or deploy.
