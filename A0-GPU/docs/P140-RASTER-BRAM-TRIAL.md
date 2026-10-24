# P140 — experimental P102 raster-to-P139/P138 FPGA BRAM integration

**Status: draft and unqualified until exact-head real RTL and FPGA CI pass.**

## What is integrated

Unlike P138/P139 standalone memory tests, P140 **instantiates actual P136 raster, P59 scissor, P68 depth compare, P135 RGB blend, and the P139/P138 two-bank, 48-bit RGB888/depth24 RAM**. The new experimental top `a0_p140_raster_bram_trial` has the clear, triangle, configuration snapshot and status inputs of P102; but debug readback is now a **synchronous ready/valid interface** (lane 1 of P139), not P102's instantaneous asynchronous debug read. It is **not yet connected to existing P132 command bus or P133 CDC bridge**.

For each covered raster pixel:
1. Stall the raster and issue lane-0 synchronous BRAM read of the current XY pixel.
2. On its registered response, apply the original depth/scissor test and exact P135 RGB blend to original color+depth.
3. If accepted by depth, commit a packed color/depth write at the current XY position, then release the pixel. If rejected, advance without writing. Uncovered locations advance normally, matching P136's scan.
4. Clear writes the entire framebuffer, one XY word per clock, and resets validity on shared reset. Host debug requests can use the other bank with ready-based conflict arbitration.

## Verification contract

- Instantiate original unchanged P102 alongside new P140 in real Icarus. Drive the **same accepted** clear and triangle commands and snapshot configurations. Compare all RGB/depth pixels after each operation, including two clears, five triangles, positive/negative winding, depth write toggles, depth compare, alpha blending, scissor, degenerate triangles, and mid-render reset.
- Read every pixel through the new P139 lane-1 **synchronous** debug interface, checking P102's own asynchronous read at the same XY. Out-of-bounds X/Y reads must be errors with zero data.
- The original and P140 may take **different numbers of clocks**; verify final image and pixel write counts, not artificial cycle-for-cycle agreement.
- Real ECP5-85K synthesizability and routing of **the complete P140 top** with P139/P138 RAM; require >=2 real `DP16KD` primitives, no unmapped cells/latches, and the 5 MHz research-only internal target.
- Keep PR draft and **never merge unless latest-head P140 and inherited CI are all green**. If RTL differs, diagnose and fix rather than relaxing the oracle or skipping tests.

## Limitations

P140 is an **experimental single-pixel read/modify/write pipeline**, not an actual two-shaded-pixels-per-cycle rasterizer. It has a different debug read contract than P102 and is not a drop-in replacement for P132. Its two FPGA memory banks are real ECP5 mapped primitives, **not external VRAM**. This says nothing about a manufactured PCB, PCIe, displays, physical CDC timing/skew, GPU driver, game support or actual frames per second. Concurrent host read behavior under contention is a separate future qualification item. 
