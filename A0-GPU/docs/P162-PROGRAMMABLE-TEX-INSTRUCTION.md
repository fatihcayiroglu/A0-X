# P162 — real bilinear TEX in a programmable UNORM shader sequence

P161 integrated a real texture fetch in a fixed per-fragment path, but its
host-selected shader opcode was not an instruction-sequenced TEX operation.
P162 **extends P151's eight-register / sixteen-slot sequential shader**
with an instruction-class bit for the existing P159/P158/P156 texture BRAM,
while preserving the exact P150 eight-op arithmetic class.

## Instruction format and execution semantics

The 25-bit instruction format is `{is_tex, alpha8, lane_mask4, op3, dst3, srcA3, srcB3}`.
When `is_tex=0`, the low 24 bits implement unchanged P151/P150 SIMD4 UNORM8
arithmetic. When `is_tex=1`, the `srcA` register holds signed **Q8.8 texel**
coordinates `{V[15:0],U[15:0]}`; `alpha8[0]` selects repeat instead of
clamp. The instruction must have `alpha8[7:1]=0`, `op3=0`, `srcB3=0`, or a
sticky fault occurs **before** any fetch or destination write.

For a successful TEX, the selected destination channels are replaced by the
actual *two-pass rounded bilinear* RGBA from the physical texture BRAM;
unmasked destination lanes retain their previous values. An instruction
retires only after its P158 response returns the correct program-counter
tag **and** `rsp_present=1`. A missing weighted tap raises a sticky fault,
does not retire the offending instruction and leaves its destination intact.
Previously retired instructions are not rolled back. This is a bounded
experiment, not a general GPU texture-fault handling scheme.

One instruction is in flight. Program `ALU -> TEX -> ALU` dependencies are
interlocked through register writeback; no following instruction issues
until the preceding result commits. The host may write registers,
instructions, or a 16x16 RGBA texture one transaction at a time while idle.
Simultaneous configuration types, or `start` with any configuration write,
raise a latched protocol fault. Busy writes are ignored; the texture
write-ready signal deasserts during sampling and shader execution.

## Required evidence (no skip or green by retry)

- Real Icarus runs **48 16-instruction programs** with four TEX operations
  each, evaluating 768 dependent mixed arithmetic/texture instructions,
  all eight register values after each program, fractional/negative/border
  coordinates, clamp/repeat, zero/partial lane masks and host write rejection.
- The expected outputs come from a **separate scalar bilinear and exact
  integer UNORM `/255` oracle**, not signals from the design under test.
- 256 real texture writes plus idle read-after-write mutation; a valid
  zero-fraction single-tap lookup; a missing weighted-tap sticky fault with
  destination intact; malformed TEX, bad launch and concurrent
  start/texture-write traps; final reset recovery and new mixed program.
- Yosys must map the **actual P162 + P158 + P156 + P150** design to an
  ECP5-85K CABGA756 speed6 with real DP16KD BRAM and DSP; nextpnr must
  fully route, pass the 5 MHz tool target, and produce timing/resource JSON.
  This is a tool estimate without a real board or pinned external timing.

P162 does **not** yet insert this shader program between rasterization and
framebuffer in P161, interpolate perspective-correct vertex UVs, support
texture gradients/mipmaps, implement a compiler, schedule warps, supply
external VRAM/PCIe/drivers or demonstrate game performance. P163 should
attach programmable invocations to the pixel path, with independent exact
pixel/depth and resource tests, rather than claiming hardware equivalence
to an Nvidia desktop GPU based on isolated research modules.
