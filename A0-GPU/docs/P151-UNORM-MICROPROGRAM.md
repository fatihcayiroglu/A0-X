# P151 — eight-register, sixteen-instruction UNORM microprogram executor

**Research draft. No merge until real Icarus and ECP5 exact-head CI are green.**

P150 implemented a stand-alone four-component fixed-point UNORM8 arithmetic primitive, but it did not execute an instruction sequence or honor register dependencies. P151 wraps **the real P150 RTL** with a small **8×32-bit vector register file**, **16×24-bit instruction memory**, a bounded fetch/issue/wait/commit sequencer, and a final `done` pulse with exact `retired_count`.

## Instruction and run contract

The host may program register values or instruction slots **only while idle**. Instruction encoding is 24 bits: `{alpha[7:0], lane_mask[3:0], opcode[2:0], dst[2:0], srcA[2:0], srcB[2:0]}`. Its opcodes inherit all eight exact per-channel P150 modes, including saturating operations and correct UNORM8 division/alpha LERP. The start signal specifies **1–16 instructions**, running sequentially from slot 0. Length 0 or length >16 is rejected with a latched fault. A simultaneous start and configuration-write attempt is a latched protocol error. Only reset clears fault.

There is exactly **one shader ALU request in flight**, and no new instruction issues until the previous result is **committed to destination register**. This preserves all RAW/WAW dependencies without speculation. P150's returned instruction PC tag is verified at retirement; an unexpected tag latches a fault. Writes while running are ignored and must not corrupt either the executing instruction stream or registers. Reset clears all registers, program memory and pending ALU output, with no replay.

The register read port is a synchronous-clock-domain combinational debug observation of an eight-register research block; **not** a production multiport register file. Program storage is bounded, no branch/loop, predication, attribute interpolation, invocation dispatch, warp scheduling, FP16/FP32, texture mapping, shader compiler or integration into P145/P149 yet.

## Strict tests

- Actual Icarus HDL for full **P151 + unchanged P150**, with independent scalar exact `/255` oracle, all eight arithmetic opcodes and each lane mask represented across at least **49 full 16-instruction programs** plus single/partial-length cases; 8 actual vector registers tested by readback after every program.
- True **read-after-write dependencies**: the next instruction's source A equals the immediately preceding destination register, checked after each complete program. Busy-time register and instruction writes cannot change the result.
- Require at least **792 retired instructions**, more than 700 dependent instruction transitions, 9 ignored concurrent busy writes, 400+ register reads. Zero-length and same-cycle start/host-write must fault and require reset; reset clears all memory and permits a clean one-instruction run.
- Genuine Yosys `synth_ecp5` + nextpnr ECP5-85K CABGA756 speed6 seed1, 5MHz research timing target, unconstrained pins. Require no unmapped/latch primitives, actual DSP multipliers from P150, bounded full top I/O, generated complete timing and resource report. Do not compare this standalone shader sequencer's frequency with the full P149 raster subsystem as if already integrated.
- Inherited P126/P127 and any other triggered exact-head regressions must pass. If a gate is missing/red/pending, remain draft.

## Initial verified RTL + ECP5 evidence — 24 October 2026

Actual head `2c4c6c21`: P126, P127 and P151 exact-head GitHub Actions all PASS. The real P151+P150 Icarus full sequential execution test verified **52 programs**, **793 retired SIMD instructions**, **741 explicit read-after-write source dependencies**, **10 ignored configuration write attempts during busy**, **424 independent full-register readback checks** and **two latched fail-closed launch errors** (zero-length and simultaneous start/write). Reset cleared instruction memory and all eight vector registers; a subsequent one-instruction program matched the scalar mathematical oracle.

Full genuine Yosys+nextpnr ECP5-85K CABGA756 speed6 seed1, 5MHz internal tool target, externally unconstrained pins mapped and routed the combined P151+P150 engine: **117 top-level RTL I/O bits**, **700 TRELLIS_FF**, **8 MULT18X18D FPGA DSP multipliers**, with an estimated **33.594 MHz** routed Fmax. This is a different integrated shader-sequencer research top from P150's standalone 169.46MHz ALU; it demonstrates significant program-control and register mux overhead, not an integrated A0-X GPU shader clock.

The final documentation-only commit must also pass same-head CI before merge. This design still does not fetch attribute buffers, produce raster pipeline colors, execute real application shader binaries, or replace any host CPU's graphics stack.

This is a meaningful sequential shader-execution **prototype**, not a modern RTX-class GPU or measured gaming FPS.
