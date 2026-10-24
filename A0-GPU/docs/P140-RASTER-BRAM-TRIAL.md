# P140 — experimental P102 raster-to-P139/P138 FPGA BRAM integration

**Status: candidate verified on code/workflow head `4e3abe83`, latest documentation-head CI required before merge.**

## Initial measured research evidence (24 October 2026)

The genuine [P140 Actions run 40078458739](https://github.com/fatihcayiroglu/A0-X/actions/runs/40078458739) passed all P140 jobs. New RTL tests compare original P102 with the actual P140-P139-P138 synchronous BRAM renderer:

| Geometry | RGB/depth pixel reads checked | Completed-draw writes: original / BRAM | Concurrent host reads accepted | Host reads stalled on bank collisions |
|---|---:|---:|---:|---:|
| 4×4 | 112 | 60 / 60 | 30 | 26 |
| 7×5 | 245 | 135 / 135 | 29 | 27 |
| 8×8 | 448 | 244 / 244 | 29 | 27 |

Each test includes two clears, five completed triangle draws, winding reversal, blend, depth and scissor, one degenerate triangle, invalid host coordinate reads and abort/reinitialization via reset. An earlier test falsely compared aggregate writes across a deliberately aborted triangle; the corrected test checks **each completed draw separately** and still verifies all final frame pixels. Different progress before mid-operation reset does not imply lost committed output, and is excluded from completed-draw equality.

Real Yosys mapped **4 DP16KD FPGA BRAM cells** and nextpnr ECP5-85K placed/routed the integrated P140 research design (4×4, seed 1, CABGA756/speed 6, unconstrained pins, 5 MHz internal target). Final tool-reported Fmax was **37.20 MHz**. This is a new synchronous BRAM read/modify/write pipeline and is **slower in mapped-clock Fmax than the old P137 register-based 50.44 MHz research design**; it may also require more clocks per covered pixel. Do **not** describe it as a throughput or performance improvement. Main P102 and P132 are unchanged.



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
