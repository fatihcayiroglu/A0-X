# P175 — isolated scaled programmed-fragment core

## Scope and isolation contract

P175 experiments demonstrated a deterministic one-clock-per-pixel reduction for the legacy screen-offset UV shader path, but changing the shared P163 RTL perturbed the unrelated 4×4 ECP5 placement and failed mandatory frequency thresholds. PR #51 is intentionally blocked and remains as a full negative-evidence record.

This successor uses **new, explicitly selected RTL variants** rather than patching the legacy implementation:

- Legacy 4×4 instantiates `a0_p163_packed_programmed_command_top` and `a0_p163_programmed_fragment_core`, both bit-for-bit unchanged from the passing P174 production baseline.
- Scaled 8×8 and 16×16 instantiate `a0_p175_scaled_programmed_command_top` and `a0_p175_scaled_programmed_fragment_core`, selected by elaboration-time framebuffer parameters in the P102 differential bench.
- The scaled core preloads shader R0 screen-offset UV at the raster-pixel handoff and enters PREP_REG at R1. Affine/perspective UV paths retain their separately verified request/response sequence.
- **No host-visible register, request/response, or shader-programming contract changes** are intended. This is an explicitly selected research variant, not a production default.

## Mandatory, fail-closed acceptance evidence

1. Run P102 independent full-framebuffer comparison for every pixel on 4×4, 8×8 and 16×16 with representative programmed shader variants, clears, scissor/depth/blend and fault handling. Do not bypass failures or reduce test coverage.
2. Run P173 exact `core_tri_done` timing: baseline upper bounds `52*N+2` and `35*N+2` at every shape; stronger scaled 8×8/16×16 bounds `51*N+2` and `34*N+2` respectively; unchanged 4×4 output and timing.
3. Independently route the unchanged P171 legacy 4×4 top with **Fmax ≥ 40 MHz**.
4. Synthesize/place-and-route the isolated 16×16 top with **Fmax ≥ 36.5 MHz**, **77 real IO**, **exactly 5 DP16KD BRAM**, **≤72 MULT18X18D DSP**, no latches, no missing/unmapped cells; publish complete route reports.
5. Require all workflows to run on the exact PR head. A nonzero exit, missing evidence, skipped required jobs, or unverified head **blocks merge**.

### Interpret performance accurately

These are tiny synthetic shader-program pixel-cycle measurements at a routed FPGA frequency, **not** real-world GPU/RTX 6090 performance or game FPS. Performance changes must be independently verified in the complete architecture, including memory and realistic workloads.

### Trade-off and follow-up

Isolation avoids unwanted perturbation of the proven 4×4 RTL at the cost of **duplicating the ~15 KB programmed-fragment core and ~12 KB packed host top**. Keep both variants under identical functional contract tests, flag any future interface change that needs synchronized edits, and consider a clean common submodule extraction only once placement stability and unchanged legacy frequency are proven. The historical failed P175 PR #51 must remain traceable.
