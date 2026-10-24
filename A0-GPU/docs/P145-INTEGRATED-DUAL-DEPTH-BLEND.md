# P145 — experimental dual triangle raster integrated with depth + alpha BRAM RMW

**Draft until actual exact-head CI passes.** P145 is a separately instantiated experimental top and does NOT replace original P102/P132/P133.

P145 combines the *actual P143 two-position incremental signed edge raster*, two independent P59 scissor checks, and the new P144 two-lane depth+alpha read/modify/write engine. P144 accesses real P139/P138 dual-bank ECP5 framebuffer RAM. Adjacent linear pixels target different banks, including row crossings on odd-width frames; each pixel has its own depth acceptance and independent RGB blend computation. Input triangle state, colors and depth/blend/scissor parameters are all snapshotted on launch. Noncovered lanes never write a pixel, and write count is the sum of completed successful P144 lane commits.

An issued pair waits for the **actual P144 response** before advancing edge interpolators or linear raster index. No lane can be double-submitted while memory is busy. Same-bank errors and invalid memory responses stop the renderer in a latched `fault` state, never silently progressing or signaling false draw completion; reset clears fault. Clear packets directly write up to two pixels and host debug reads are allowed **only when renderer is idle**, deliberately unlike P140's concurrently accepted host-debug contract.

Because synchronous read/modify/write needs separate read and write edges, and this integration waits for registered completion before changing scan coordinates, **do not claim a sustained two blended pixels per clock**. This phase prioritizes full-pixel correctness, transaction ordering, and visible fail-closed stalls over throughput. A follow-on can remove the extra completion bubble via a proven pending-commit handshake.

## Qualification

- Real Icarus with independent unchanged P102 reference. Compare all 24-bit RGB and 24-bit depth values after each clear and finished triangle on 4x4, 7x5, 8x8 frames. Include modes ALWAYS, LESS, LESS_EQUAL, depth-write disable, RGB alpha blend, scissor, reverse winding, degenerate triangle and reset during an in-progress draw.
- Count actual committed P144 writes per lane, assert exact sum matches original P102's completed-draw writes, exercise simultaneous two-write beats, and verify host reads stall while P145 renders.
- Genuine full top Yosys synth_ecp5 + nextpnr ECP5-85K CABGA756 speed6 seed1, fixed 5MHz internal research target, unconstrained external pins. Require at least two true DP16KD cells, no unmapped logic and bounded utilization; report actual Fmax, no unsupported comparisons against P143's different, opaque-only timing model.
- The newest P145 and inherited P126, P127, P132, P134 workflows must all succeed on the same PR head. Keep the PR draft until those gates pass.

## First actual real RTL + FPGA qualification — 24 October 2026

The actual P145 direct full-16-bit core and the signed-8-bit **physical-pin-bounded wrapper** each passed genuine Icarus comparisons against the independent original P102 full-color/full-depth framebuffer:

| Framebuffer | Clear operations | Completed triangles | Compared color/depth pixels | P102 completed-draw writes | P145 completed-draw writes | Actual two-pixel commit cycles |
|---|---:|---:|---:|---:|---:|---:|
| 4×4 | 2 | 5 | 112 | 60 | 60 | 29 |
| 7×5 | 2 | 5 | 245 | 135 | 135 | 64 |
| 8×8 | 2 | 5 | 448 | 244 | 244 | 117 |

Depth, blend, scissor, winding, zero-area triangle, host-read stall, invalid debug XY and shared reset scenarios are covered. A P145 `fault` is asserted by the test if unexpected. The tests were run against unchanged P102 RTL, not a copied renderer, and include the P144/P139/P138 real BRAM RTL.

**Physical research package constraint:** The all-16-bit-vertex direct top requires **366 I/O bits** but ECP5-85K CABGA756 provides only **365 TRELLIS_IO** cells, so the first direct route correctly failed. We did not raise a threshold or pretend the pins exist. `a0_p145_bounded_pin_top` sign-extends **six signed 8-bit vertex inputs** to the unchanged P145 internal 16-bit coordinates; it therefore supports a bounded vertex domain only. All directed P102 frame-equivalence tests for this exact wrapper passed.

Real Yosys synthesis + nextpnr ECP5-85K CABGA756 speed6 seed1, 4×4 model, 5MHz minimum internal target and unconstrained external pins **fully routed the bounded top** using **318 / 365 external IOs** and **4 actual mapped `DP16KD` BRAM cells**. The routed tool-reported single-clock Fmax was **27.41MHz**. These are not physical timing/sign-off or production IO assignments.

There are read, write and response/advance beats per covered pair; therefore **no sustained 2 blended pixels per cycle claim** is established. This is a substantial correctness/integration milestone, not a demonstrated speedup over the separate P143 opaque-only raster.

All exact-final-head Actions jobs must pass before this research prototype can be merged.

No physical GPU, VRAM chip, PCIe, scanout, driver, shader ISA, thermal evidence, real board frequency or gaming FPS is qualified here.
