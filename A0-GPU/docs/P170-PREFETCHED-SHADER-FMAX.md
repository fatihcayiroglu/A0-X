# P170 — Shader instruction lookahead and decoded operand registers

## Measured P169 starting point
The fully routed P163 integrated host on ECP5-85K used 77 IO, 5 BRAM,
72 DSP and reached **32.28 MHz**. After registering P166 geometry,
the critical path moved to P162's instruction RAM mux, register-file mux
and P150's exact UNORM ALU result in the same clock cycle.

## Change
Preserve the P162 25-bit ISA, full 8-register state, TEX semantics and
all 16 program slots, while using existing controller cycles:

1. On valid start, prefetch instruction 0 into a 25-bit register.
2. On each non-final ALU/TEX retirement, prefetch instruction PC+1 into
   the same register at the same edge that advances PC.
3. In the existing DECODE cycle, snapshot both source registers by the
   registered instruction's source fields. P150 and P158 read these
   32-bit operand snapshots, never a live program-counter or register
   index mux.
4. Preserve signed TEX UV interpretation, mask, uniform alpha, response
   tag validation, fail-closed invalid opcode, register writeback and
   output timing. No additional instruction cycles.

## Acceptance
- The pre-existing independent scalar P162 test checks 50 full
  programs, 772 retired instructions, 194 TEX samples, 8 registers,
  busy-write isolation, missing texels and malformed instruction rejection.
- A new 16-instruction serially dependent four-lane ADD shader must
  exactly produce 0x11121314 after **48 cycles**, with no hidden bubbles.
- P163, P165 and P167 full independent P102 RGB/depth framebuffer tests
  must remain green; shaders run TEX+ALU in real covered pixel loops.
- Fully route real P163 host top ECP5-85K with 77 IO, >=3 BRAM,
  <=72 DSP and **Fmax >=35 MHz** (versus P169 32.28 MHz).

Scope is research RTL FPGA timing, not hardware board or graphics
performance parity with an unreleased high-end consumer GPU.
