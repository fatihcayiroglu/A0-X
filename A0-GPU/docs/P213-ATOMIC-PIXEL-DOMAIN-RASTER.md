# P213 — atomic pixel-domain frame staging and VBlank-only raster publication

**Stacked draft on P212 (#89). No physical monitor or HDMI/DP is claimed.**

## Architecture and contract
- Unchanged P203→P210 committed producer EBRs and P212 asynchronous 92-bit Gray FIFO deliver ordered `{frame_end,frame_start,epoch,index,pixel[47:0]}` to an independent `pixel_clk` domain.
- A pixel-domain parser requires monotonic nonzero epochs, exact 0..WORDS−1 index sequence and the expected frame-start/end markers. Wrong order or mixed-epoch partial frames latch `pixel_fault`, blank all output and stop consuming. Source fault is synchronized through the P212 two-flop path.
- The parser **drains duplicate full epochs** without rewriting or displaying them. New epochs are written into a *non-front* local 1024×48 EBR staging bank. A bank becomes publishable only after every word of the frame arrives. If a newer different epoch starts before pending publication, old pending state is invalidated while the back bank is rewritten.
- On the first full frame, the raster starts only after a valid staged bank exists. Subsequent completely assembled epochs are swapped to the front only on the last *blanked* raster slot, between displayed frames. Active reads use a clocked prefetch from a protected front EBR bank. Thus host input stalls or repeated old FIFO frames cannot create mixed-epoch displayed scans.
- Video still exposes a single pixel-clock `pixel_ce` divided strobe, active-low HSYNC/VSYNC, DE and 48-bit words; H/V front/sync/back porches are parameterized. Blanking pixel data is zero. Display retains a complete old frame until a fresh full epoch is assembled, so input underflow is not directly visible as a torn scan.
- The two local frame banks are **not scrubbed to zeros on reset**; their validity/epoch pointers reset and all output remains invalid/black until a fresh complete frame has been assembled. This is logical non-exposure, not physical remanence erasure.

## Evidence required
- Real P203→P212 physical memory chain with independent host/pixel clocks and **8-word and 1024-word** staging runs.
- First valid frame, concurrent host write to the other bank, FIFO repeated old epochs discarded, exactly epoch1 displayed throughout frame1 and epoch2 displayed throughout frame2, no mid-frame mutation, exact HSYNC/VSYNC/DE/blanking, fixed pixel CE cadence, published-front write lock, reset non-exposure.
- Inherit all P175–P212 real tests, then Yosys `synth_ecp5` and nextpnr ECP5-85K CABGA381 physical route on P213 top. Demand exactly **83 top I/O bits**, **at least 21 DP16KD EBR** (P212’s 15 plus pixel-domain staging), no latches or black boxes, and post-route experimental Fmax ≥10MHz. Always preserve failure artifacts; no waivers/retries.

## Still missing
Pixel PLL and physical oscillator constraints, clock-domain and metastability signoff, HDMI/DisplayPort signaling/EDID, board pin constraints, actual display capture, sustained real-time bandwidth, multi-resolution frame allocation, external DDR, PCIe, drivers and any RTX-class performance evidence. Keep PR **draft**, stacked; no merge without independent review and explicit owner authorization.
