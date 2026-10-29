# P236 — Real independent-host-clock tile upload to the P235 FPGA scanout

## Architecture and strict limitations

P236 adds a real synthesizable 35-bit packet CDC bridge on the physically accepted P235 top. The independent host port sends 768 ordered `{index[9:0],RGB888[23:0]}` beats followed by one `commit` marker. The existing P226 Gray-pointer asynchronous FIFO with double-register synchronizers is reused, not replaced with an unsafe combinational data/control path. The FIFO is 16 entries deep by default, and its `ready` signal provides lossless backpressure when the pixel clock stops or P235's staged bank is pending.

The P226 reset supervisor asserts asynchronously on either raw reset or loss of external pixel-clock lock, and releases separately in the host/pixel clock domains. Invalid host packet ordering, premature commit, and data sent after 768 words are rejected without enqueue; host fault latches until reset and remains HOST-LOCAL. Pixel data are consumed only via the P235 `load_ready`/`commit_ready` handshake. Actual P235 framebuffer data are two 768×RGB888 physical BRAM banks; the active bank never receives writes, and the next complete tile publishes only at final VBlank. No frame may be displayed prematurely.

This is **not** P233's source producer connected to P235's sink: it reuses P233/P226's *proven FIFO and reset machinery*, and accepts a distinct ordered tile upload stream. The original P233 framebuffer producer still uses 8/1024 words and epochs, whereas P235 requires 768 tile pixels; a real format/size conversion and application-level bridging remain.

## Strict qualification

- Four actual Icarus simulations: 640×480/800×600 × two opposite asynchronous host/pixel ratios.
- Each first transmits an invalid short frame and verifies host-only protocol rejection with dark output. After a real reset, send two 768-word distinct frames plus two ordered commit markers.
- Stop the pixel clock during real transfers; require FIFO full/backpressure rather than dropping or overwriting packets. Resume, use physical FIFO reads into physical frame BRAM, preserve 1,536 exact pixel words and two commits without any duplication.
- Full P234 timing reference on every output pixel-clock edge; independent expected RGB888 tile index and color; cover all 768 source entries in each front bank; prove two atomic VBlank front swaps and complete active frame coverage.
- Assert 2ns raw asynchronous reset during stopped pixel clock; RGB/DE must go dark immediately and old FIFO/frame contents cannot reappear without a complete fresh commit.
- Physically synthesize and independently route the *complete P236 top* on LFE5U-85F CABGA381 speed6 seed1 for both compile-time video modes, requiring exactly 70 I/O bits, at least five actual DP16KD including physical two-bank tile storage plus FIFO, no unmapped cells/latches, routed pixel clock >=25.175MHz or 40MHz (mode-specific), and separately routed host >=10MHz.
- Preserve real first-failure evidence; no retries, hidden skips, negative compile-as-pass or loosened physical frequency gate. Do not declare green before the exact-head workflows complete.

No manufactured GPU/board, monitor PHY (HDMI/DP), pixel PLL, pin/electrical mapping, EDID, PCIe, DDR/VRAM controller, file/driver integration, independent formal CDC metastability MTBF signoff, or game FPS benchmark exists. Mode selection is a compile-time FPGA elaboration parameter, not runtime auto detection. Physical timing of a routed FPGA netlist is not a real monitor benchmark. Keep PR DRAFT/unmerged until independent review and explicit owner approval.
