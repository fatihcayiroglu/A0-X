# P163 — Real per-fragment programmable TEX/ALU execution and RGB/depth BRAM

P161 rasterized with a fixed selected shader arithmetic operation; P162
executed real TEX and arithmetic instructions but not for raster fragments.
P163 unifies these physical research blocks in one actual data path:

P38 raster coverage → eight per-pixel register loads → P162 sequential 1–16
instruction program (P159/P158/P156 texture BRAM and P150 UNORM8 SIMD) →
programmable output register → P144/P139/P138 real depth/blend RGB BRAM.

## Per-fragment semantics

- Program memory (16 × 25-bit), 16×16 RGBA texture contents and register
  seeds R1..R7 are uploaded by the host **only when idle**. R0 is reserved
  for `{V[15:0],U[15:0]}` signed Q8.8 texel position per covered pixel,
  computed as integer screen pixel XY × 256 + signed draw UV offset.
- Every covered pixel is a **new invocation**: write all eight P162 registers
  (R0 coordinate and R1..R7 configured seeds), execute the exact configured
  instruction count, wait until the selected output register commits, and
  supply its low 24 bits as the source RGB for P144 depth and blend.
- The raster's pixel-ready handshake is withheld until the actual framebuffer
  read-modify-write response succeeds. Missing texture tap, wrong TEX ID,
  malformed instruction or framebuffer failure faults the core and cannot
  release an unwritten/incomplete fragment as successful. Previous committed
  framebuffer pixels are not rolled back.
- Shader programs are not silently skipped; per-draw counters record covered
  fragments, retired instructions and retired TEX operations. Host reads
  return **actual BRAM** contents, not predicted pixel values.

## 77-bit real host I/O

One-clock no-CDC request bus is `{clk,rst_n,valid,write,addr6,wdata32}` with
`{ready,rsp_valid,rsp_error,rdata32}` responses. Total **77 RTL I/O bits**.
Register addresses:

| Address | Register | Meaning |
|---:|---|---|
| 0–2 | CLEAR_RGB / CLEAR_DEPTH / TRI_DEPTH | 24-bit colors/depth |
| 3–5 | V0 / V1 / V2 | signed 16-bit XY triangle vertices |
| 6 | UV_OFFSET | signed Q8.8 V high16 / U low16 |
| 7 | FB_MODE | depth op bits 1:0, depth-write bit2, blend bit3, alpha bits 15:8 |
| 8 | SHADER_CFG | program length bits 4:0 (1–16), output reg bits 7:5 |
| 9–10 | SEED_INDEX / SEED_DATA | indexes 1–7; one RGBA vector seed |
| 11–12 | INSN_INDEX / INSN_DATA | slot 0–15; 25-bit P162 instruction |
| 13–14 | TEXTURE_XY / TEXTURE_RGBA | 4-bit texel XY and real 32-bit upload |
| 15 | READ_XY | framebuffer host read coordinates |
| 16 | COMMAND | 1 clear, 2 draw triangle, 3 framebuffer read |
| 17 | STATUS | initialization, busy/fault, done flags, readiness, cached read |
| 18–19 | PIXEL_RGB / PIXEL_DEPTH | cached real BRAM pixel (after command 3) |
| 20–23 | SHADED_COUNT / SHADER_INSNS / TEXTURE_OPS / LAST_RGB | physical telemetry |
| 24 | IDENT | `A0163001` |
| 25–27 | TEX_WRITES / INSN_WRITES / SEED_WRITES | host upload counts |

Malformed host writes are rejected with `rsp_error`; a bad in-program TEX
encountered during execution latches a core fault. Unsupported accesses do
not silently turn into a successful command. In-flight pixel reads defer the
host response until real BRAM data arrives.

## Required independent validation

Run full actual Icarus on original P38, P162, P144, P102 and P163 modules.
Program at least two different instruction sequences (including 1× and 2×
bilinear TEX per pixel, multiply/add/lerp and partial masks), upload full
256-texel image via 77-bit host protocol, issue real triangles and compare
every RGB/depth framebuffer pixel to **unchanged P102 coverage/depth and a
separate scalar texture/math oracle**. Check shaded-pixel and total retired
instruction/TEX counts against exact covered fragments. Also check busy
program upload refusal, malformed host writes and a post-reset weighted-tap
texture absence causing sticky fault before framebuffer corruption.

Fully route **the entire real host-programmable RTL top**, not a constrained
control subset, with Yosys/nextpnr ECP5-85K CABGA756 speed6, 5 MHz research
target, 77 pins, texture/framebuffer DP16KD and shader DSP arithmetic.

P163 is still a slow, one-fragment-at-a-time proof: **no perspective-correct
vertex UV interpolation**, production shader language/compiler, FP32,
texture caches/mipmapping, concurrency/warp scheduling, VRAM, PCIe, driver,
game integration, physical board measurement or claim to RTX-class speed.
