# P175 — One-cycle shader R0 preload at the raster boundary

P173 independently measured `52*N+2` clocks for a 5-instruction/2-TEX
draw and `35*N+2` clocks for a 3-instruction/1-TEX draw (N = covered
framebuffer pixels). P174 placed those costs under a no-regression CI gate.

## Change

For measured 8×8 and larger framebuffers, when P163 presents a valid pixel
and the shader is ready, the legacy direct screen-offset UV mode (`uv_mode_q==0`) now writes R0 (the packed
signed Q8.8 UV seed) to the P162 shader **in that same raster-capture cycle**.
P163 enters PREP_REG at R1 instead of repeating R0 on the following clock.
All seven other user-defined seed registers are still refreshed, in order,
before shader launch. If shader is unexpectedly not ready at the boundary,
it falls back to the existing R0-first PREP_REG procedure. Affine and
perspective paths are unchanged and continue to use the checked shared UV
interpolator, which must finish before R0 is written.

The optimization is deliberately disabled by elaboration for 4×4 to protect
P171's ≥40 MHz historical FPGA timing gate. This is an RTL timing overlap,
not reduced work, dropped fragments, a
different shader program or skipped framebuffer writes.

## Required evidence

- The original P102 independent full-frame comparisons, shader retirement
  counts, host malformed/busy rejection and missing-tap fail-closed cases
  remain strict at 4×4, 8×8, 16×16.
- P173's hardware-completion monitor must measure **at least one fewer
  clock per pixel** in both shader programs **at 8×8 and 16×16**: no more
  than `51*N+2` and `34*N+2` clocks. The original 4×4 configuration
  deliberately retains its exact P171 synthesis/timing and P174 baseline
  budget (`52*N+2`, `35*N+2`); P174's no-regression gate remains.
- The real 16×16 ECP5-85K full-host route must still preserve 77 host pins,
  5 BRAM, at most 72 DSP, and achieve **≥36.5 MHz**; a frequency regression
  beyond this would offset the ~2%-3% cycle improvement.
- Affine and perspective regression gates must remain green, not be skipped.

Only measured routed FPGA Fmax and cycle cost are claimed. No external VRAM,
PCIe, display, real board, silicon, or 3D-game FPS is implied.
