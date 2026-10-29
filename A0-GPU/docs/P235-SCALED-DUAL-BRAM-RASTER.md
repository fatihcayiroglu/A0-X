# P235 — Real dual-bank BRAM tile, scaled into externally clocked VGA/SVGA

P235 is a new experimental FPGA display *data path* stacked on physically verified P234 #111. It does not modify P233's committed EBR host/async-CDC renderer or claim that a full 640×480/800×600 pixel framebuffer exists.

## Hardware contract

- Two actual 768-word × 24-bit writable pixel-clock-domain BRAM arrays; each stores a **32×24 RGB888 tile**.
- In 640×480 mode the tile scales **20×20** per source pixel; in 800×600 it scales **25×25**. No interpolation, GPU shader or full-resolution VRAM.
- P234 is the physical HS/VS/DE timing source. P235 maintains matching local pixel coordinates solely to prefetch the **next** BRAM address through a synchronous registered block RAM read; this ensures correct color on the next timing pixel.
- The loading port is **in the same pixel clock domain**. No host crossing, PCIe, DMA, DDR, memory controller, monitor link or clock generator is provided. Sequential `load_valid/load_index/load_rgb` transactions must cover all 768 indices in order before `commit_valid` may be accepted.
- While the front bank is scanned, all writes target the *opposite* bank; stage lock prevents overwriting a complete pending frame. Publication happens only at the final blanking boundary; switching bank/pixel read before or during an active row is forbidden.
- Before any complete first commit, DE=0 and RGB black. Premature commit, wrong accepted index or simultaneous load+commit causes sticky fail-closed fault. Raw reset and PLL lock loss mask RGB/DE asynchronously, even with pixel clock stopped; bank data are *not scrubbed* but are hidden by validity state until a fresh full rewrite/commit. HS/VS return to idle polarity.
- Eight-bit RGB components, including data values such as 0, are real written tile content, not a synthesizer-stubbed static colorbar.

## Gate

- Each mode must simulate **two complete, different 768-pixel written banks**, including the first bank's initial VBlank activation and the second bank's replacement.
- Compare the P235 front geometry to an independent unchanged P234 generator on every relevant edge. Compare all scaled active pixel colors to independently computed source tile indices and ensure black on every blanking output. Cover each of 768 source tile entries for both front banks. No torn frame, inactive front write or stale pre-commit pixel.
- Reject early commit after one real pixel write, exercise short raw reset during a stopped nonzero live output, confirm no stale frame replay despite non-scrubbed physical RAM.
- Independently synthesize and route *the actual P235 top* (not the P234 colorbar-only top) on LFE5U-85F CABGA381 speed6 seed1. Require 69 top I/O bits, >=2 DP16KD EBR, mapped control logic and no latches, and close external pixel-clock requirements 25.175 and 40 MHz for each mode. Log actual FF/LUT/EBR, routed Fmax; preserve first failure and evidence.
- No skipped tests, renamed failures, retries or loosened clock gates. PR remains draft unless approved and reviewed.

## Not yet delivered

This is **not a 640×480 or 800×600 VRAM framebuffer**. It is a correctly timed high-resolution *display of a small RAM tile*, suitable for next-stage proof of memory-to-scanout. There is no real pixel clock PLL, electrical pin mapping, external FPGA board test, HDMI/DP/VGA PHY, EDID, hotplug, mode auto-detection, full-frame host-write bandwidth, texture/GPU compute or commercial GPU benchmark. The P233 memory-producer crossing is independent and not connected to the P235 pixel-clock-local tile loader; engineering work to bridge them remains.
