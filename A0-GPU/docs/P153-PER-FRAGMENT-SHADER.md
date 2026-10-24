# P153 — Genuine per-covered-pixel UNORM shader path

**DRAFT research experiment; not merged until required real RTL evidence.**

P152 successfully connected P151/P150 shader microprogram result to a *triangle-constant source color*. P153 moves to a separate deliberately low-throughput **per-covered-fragment invocation**: P38's stallable exact triangle edge/top-left coverage emits each covered pixel coordinate. P153 snapshots its (x,y), loads per-fragment input vector R0 as `{8'hff,y[7:0],x[7:0],8'h40}` into the actual P151 eight-register sequencer, executes a real configured P150 SIMD UNORM program, reads committed destination register R2 as that single fragment's RGB, and writes the color/depth through the real single lane of P144/P139/P138 BRAM read/modify/write. P38 `pixel_ready` becomes true **only on successful RMW completion**. Non-covered positions advance without shader invocations; the next covered pixel cannot overtake the previous one.

The real P151 program/instruction memory is configured at idle only. Per-fragment R0 update is serialized before issuing each shader microprogram, so no program data race exists. Shared reset aborts any outstanding shader/RMW activity and invalidates framebuffer. Host debug reads are suppressed during scan/shader/depth operations. Clear walks the framebuffer and writes every pixel through actual BRAM; no fake initialized status is returned before completion. Memory or shader error fail closed and are reset-recoverable.

**Scope limitations:** Only one covered pixel can be in flight. R0 coordinate inputs truncate X/Y to 8 bits in this intentionally bounded initial pixel attribute contract even though the triangle geometry remains full signed16; tests use framebuffer sizes 4×4, 7×5, 8×8. There are no interpolated per-vertex attributes, derivatives, textures, arbitrary shader entrypoints, FP32, wavefront scheduler, PCIe, external VRAM or actual physical board. This is a research fragment pipeline, not a competitive GPU shader throughput benchmark.

## Independent acceptance tests

- Run real Icarus on 4×4,7×5,8×8 with P38 coverage, genuine P151/P150 shader, P144/P139/P138 RMW and unchanged original P102. P102 provides independent winding-aware coverage/depth, and an independent scalar model calculates per-pixel UNORM shader RGB from real pixel X/Y for ADD_SAT, LERP and MUL. Assert each RGB/depth framebuffer word and exact per-covered-pixel invocation count.
- Test both triangle winding orders, multiple clears, 16bit signed full coverage coordinates −257/+1024, actual readback including invalid coordinates, host backpressure during active pixel shader operations and reset mid-draw. Never count uncovered pixel locations as shader invocations.
- For a routed FPGA research milestone, add a **compact command wrapper** preserving full triangle vertices and actual shader configuration. Route full P153+P151+P150+P144+BRAM ECP5-85K CABGA756 rather than only the standalone shader ALU. Do not claim real FPGA fit until the complete top passes Yosys and nextpnr.


## Verified actual RTL and complete FPGA research route — 24 October 2026

Code head `7cbb587f` passed **all five** triggered GitHub Actions workflows (P126, P127, P132, P134, P153), including real Icarus direct and packed host-path tests **plus actual full Yosys/nextpnr ECP5 place-and-route**. The initial red P153 FPGA job was a workflow build-path mistake referring to nonexistent P153 module names, not a proven timing failure; those paths were corrected to the real committed `a0_p153_fragment_shader_trial.sv` and `a0_p153_packed_fragment_command_top.sv` modules before this qualification.

| Framebuffer | Clears | Draws | Independent full RGB+depth pixel checks | Genuine per-fragment shader invocations | Packed-bus covered pixels / shader invocations |
|---|---:|---:|---:|---:|---:|
| 4×4 | 3 | 3 | 96 | 48 | 16 / 16 |
| 7×5 | 3 | 3 | 210 | 105 | 35 / 35 |
| 8×8 | 3 | 3 | 384 | 192 | 64 / 64 |

The direct RTL frame model uses unchanged P102 for triangle winding and coverage/depth together with an independently calculated scalar shader RGB result. The real P151/P150 shader is invoked **once per covered fragment** (not on uncovered pixels), then its output flows through actual P144 depth/alpha RMW and P139/P138 dual-bank BRAM. Separate full signed16-vertex packed-bus tests check the real host access path and pixel color/depth results. Tests additionally exercise reverse winding, multiple shader arithmetic modes, invalid readback coordinates, host backpressure and reset mid-draw.

**Complete FPGA model**: real Yosys `synth_ecp5` and nextpnr on ECP5-85K CABGA756 speed6 seed1, 4×4 internal frame, 5MHz research clock target, externally unconstrained package pins. The integrated P153 packed top routed with **76 logical I/O bits**, **4 real `DP16KD` block RAM cells** and **22 `MULT18X18D` DSP multiplier primitives**, with **34.491 MHz tool-estimated maximum clock frequency**. This is not a physical board, PCIe link, usable GPU shader compiler, fragment throughput benchmark, application game FPS or thermal/electrical sign-off.

**Limitations:** Only one shader-covered pixel is in flight. Instructions are serialized for each pixel. The `R0` fragment attribute uses low eight bits of X and Y, with no interpolated vertex attributes or texture coordinates. A higher reported Fmax of this different synthesis top does not establish a frame-rate improvement over earlier P145/P152 architectures. Final documentation-head CI must pass before merging.
