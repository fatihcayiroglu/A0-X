# P204: real ECP5 placement, routing and post-route timing for P203

## Scope

P203's transaction-tagged, commit-acknowledged external memory-controller
**bridge is synthesizable**, but prior generic Yosys success alone does not
establish physical fit or routing timing. P204 runs the **actual unchanged
P203 RTL** through Lattice ECP5 technology mapping and nextpnr physical
place-and-route.

- Device: **LFE5U-85F**, package **CABGA756**, speed grade **6**, fixed
  nextpnr seed **1**.
- Full original **337-pin P203 controller interface**; no constant tie-offs
  or toy subset is substituted to manufacture timing results.
- Clock target and minimum actual **post-route Fmax**: **10 MHz**. This is
  a first feasibility floor for one *control-plane module*, not a GPU
  clock target, memory bandwidth claim or frame rate.
- Run `synth_ecp5`, `check -assert`, and `nextpnr-ecp5` with
  `--freq 10` and **without** `--timing-allow-fail`. Parse
  `route.json` to require a positive achieved real routed Fmax and
  the declared clock floor. Fail on any tool/process error.
- Require exactly **337 mapped top-level I/O bits**, nonzero real
  `LUT4`/`TRELLIS_FF` primitive counts, zero unlowered design cells,
  and zero inferred `DP16KD` RAM or DSP in the P203-only controller.
  Memory itself remains a separate backend.
- Preserve the mapped netlist, complete Yosys and nextpnr logs, physical
  route configuration and timing/area JSON **even when failure occurs**.

## Functional and protocol regression in the same exact-head job

Before physical routing, rerun the full genuine P175 256×256 two-frame
simulation through P198/P195/P197/P200/P201/P202/P203, two test-only
tagged controller shims and P196 simulation-only memory banks:

- **131,072** externally memory-accepted 48-bit RGB+depth words.
- **200** old published frame reads while the next frame is staged.
- Exactly two automatic staging, sealing and publication operations.
- All independent P203 mismatch/error/timeout/flush negative tests.
- Generic Yosys structural check of P203.

No zero-test jobs, waived failures, changed thresholds after a failure,
or reruns of an identical failing head as a substitute for root-cause fixes.

## Deliberate nonclaims

This is **tool-produced physical FPGA placement and routing** of one
P203 control block, not a fabricated or powered physical FPGA board.
No pinout LPF is bound to an actual board; `--lpf-allow-unconstrained`
lets the tool assign legal package pins for a feasibility experiment.
Therefore no board-level I/O timing, signal integrity, DDR PHY,
actual VRAM controller, external timing closure, validated silicon
power or operating frequency, PCIe, game FPS or RTX-class performance
is implied. A full 256×256 P175 GPU on this ECP5 is not being routed.

This intentionally reuses the device and tooling family previously
proven in P131/P179. A successful P204 does not remove the urgent
need for **a narrow practical host/memory connector**; the P203 direct
interface exposes 337 pins and is not a practical consumer interface.

## Merge gate

Stack draft PR P204 on P203 (#80), P202 (#79), and ancestors.
Evidence must reference this PR's exact commit and independent review.
Do not merge without owner authorization.
