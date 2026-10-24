# P150 — first bounded programmable UNORM8 SIMD4 arithmetic primitive

**Status: draft until exact-head genuine RTL and FPGA qualification.**

A0-X P149's host command transport is now the real verified research interface, but A0-X still lacks *programmable shader execution*. P150 begins that work with a fully independent and synthesizable **four-lane 8-bit RGBA / UNORM SIMD ALU**, accepting a programmable 3-bit opcode on each packet. It is **not yet wired to the P149 command bus, P145 triangle raster, registers, program counter, instruction fetch, texture unit or VRAM**, and must never be called a finished shader engine.

## Exact arithmetic

Four 8-bit components are operated on in parallel from `operand_a` and `operand_b`. `lane_mask` chooses which components to update, with disabled components passing through operand A. An 8-bit `req_id` is returned unchanged as `rsp_id`. The eight legal opcodes are:

| Opcode | Operation | Component semantics |
|---|---|---|
| 0 | MOV_A | a |
| 1 | MOV_B | b |
| 2 | ADD_SAT | min(255, a+b) |
| 3 | SUB_SAT | max(0, a−b) |
| 4 | MUL_UNORM8 | floor((a×b+127)/255) |
| 5 | MIN | min(a,b) |
| 6 | MAX | max(a,b) |
| 7 | LERP_UNORM8 | floor((a×(255−alpha)+b×alpha+127)/255) |

The **bounded exact divide-by-255** transform `(x+1+(x>>8))>>8` is used only for numerators `0..65,152`; it is mathematical integer division with the same nearest rounding as P135, not floating point. Neither component overflows into adjacent lanes.

The one-entry registered response slot supports **one entire RGBA vector packet accepted per rising edge** when the consumer is ready. `rsp_valid/rsp_ready` backpressure holds `rsp_id,rsp_data` stable without overwriting; valid requests remain unaccepted while the output is blocked. Active-low reset cancels outstanding response but does not replay input. All four lanes are component arithmetic, **not four independent programmable shader threads or GPUs**.

## Required verification

1. Genuine Icarus independent integer reference using actual `/255` (not the RTL shortcut), saturating arithmetic, all 8 opcodes, four masks (0,5,A,F), 6×6 source/destination extremes and six alpha extremes: **6,912 directed boundary operations**.
2. At least **2,048 deterministic pseudo-random packets**, checked one-by-one with matching IDs and expected 32-bit RGBA against the independent oracle; held-response stalls, reset flush and clean post-reset responses.
3. **128 consecutive accepted inputs, one per cycle**, with outputs matched in order; output latency/throughput measurement restricted to simulated RTL. No false claim of game FPS, floating point shader peak FLOPs or actual board speed.
4. Full genuine Yosys ECP5 technology mapping and nextpnr ECP5-85K CABGA756 speed6 seed1 `--freq 5 --lpf-allow-unconstrained`. Require no unmapped RTL cells or latches, bounded LUT/I/O resources, routed Fmax >=5MHz and generated netlist/placement timing logs. Do **not** demand a BRAM primitive: this pure ALU intentionally contains no framebuffer.
5. Keep inherited P126/P127/P132/P134 P149 main regressions green where applicable, and require the P150 workflow to pass on the **exact latest PR head** before merging as an experimental shader arithmetic block.

## Verified independent SIMD ALU results — 24 October 2026

On code head `c7e6532f`, genuine Icarus Verilog executed the *actual RTL* and compared each 4×8-bit component with an independent integer-math reference:

- **6,912 complete directed boundary operations**: all 8 opcodes, 6×6 source/destination extremes, 6 alpha extremes and 4 tested masks (0/5/A/F).
- **2,048 deterministic mixed packets**, every output vector and request ID checked, and **128 consecutive one-per-clock accepted inputs** with matching outputs.
- **1,660 output-stalled cycles** exercised while preserving response data and ID, plus **16 matching fresh post-reset replies** after cancelling an unconsumed result.
- Real multiplication and alpha interpolation obey `floor((numerator+127)/255)` integer semantics. No skipped or todo assertions were accepted.

Genuine Yosys ECP5 mapping and nextpnr ECP5-85K CABGA756 speed6 seed1, 5MHz internal tool target and **unconstrained physical pins** routed successfully:
- **133 RTL top I/O bits**; **626 `LUT4`** and **8 `MULT18X18D`** multiplier primitives, **41 registered `TRELLIS_FF`** cells.
- Real routed tool-estimated single-clock Fmax **169.46 MHz** (not a measured FPGA card clock). This is a *small standalone arithmetic top*, not the P149/P146 graphics engine; do not compare this frequency numerically to those full-system designs as a speedup.
- The user-selectable operations and stall-safe full-rate input are verified only within this simple SIMD primitive. No executable shader program, register file, scheduling, shader threads, vertex processing, texture filtering or FP32 functionality exists yet.

The final documentation-head workflow must pass separately before merge.

## Scope

No shader ISA or compiled program is executed yet, no register files, no floating point, FP16/FP32, texture fetch, derivatives, pipeline hazards, wavefront scheduling, VRAM, drivers, PCIe, monitor output or GPU benchmark. A future P151 may define a bounded vector instruction/register protocol and integrate the P150 ALU into a real instruction-execution sequencer.
