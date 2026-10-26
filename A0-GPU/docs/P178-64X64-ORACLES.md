# P178: 64×64 independent programmed framebuffer and cycle oracles

P176 verified independent P102-versus-host framebuffer correctness through 32×32 and non-square 32×16/16×32. P178 introduces a **separate simulation-only workflow** `.github/workflows/a0-p178-large-oracles.yml` without editing the existing P172/P173 gates or synthesizable RTL.

## Exact-head acceptance

- Run the real Icarus RTL testbench `a0_p172_scaled_programmed_fragment_p102_tb.sv` at **64×32, 32×64 and 64×64**. Each must emit exactly one P172 full-frame oracle marker and one P173 measured draw-cycle marker. Reject absent, duplicate or malformed markers.
- The P102-derived independent expected framebuffer must exactly match every host readback after clears and both shader/raster/texture/depth-blend programs, including negative bus cases and missing-texture fail-closed behavior. Each shape checks `5*W*H` observed pixels, `2*W*H` covered fragments, ≥8 host rejections, one busy denial, one missing-texture fault and 256 texture writes.
- New three-shape total: **40,960** host pixel observations and **16,384** covered fragments; 64×64 alone: **20,480** observations and **8,192** shaded fragments. Together with P176's **11,840** pixel observations and **4,736** covered fragments across its five smaller shapes, the independently gated combined scope is **52,800** observations and **21,120** shaded fragments across eight shapes.
- Check actual `core_tri_done` timing for both programs at each shape; enforce P174 ceilings `52*N+2` / `35*N+2` and stricter P175 scaled ceilings `51*N+2` / `34*N+2`, where `N=W*H`. The equal-area transposed 64×32 and 32×64 pairs must have equal measured cycles, both strictly faster than the 64×64 case.
- Preserve raw RTL compile and simulation logs as a CI artifact. A timeout, wrong oracle, abnormal timing, wrong geometry or missing artifact is a blocker. **Do not edit existing P172/P173 workflows or physical-route ratchets.**

This is only a pixel-accurate simulation and command-completion timing boundary. It is **not** 64×64 FPGA fit, display throughput, game benchmark, desktop GPU, nor a performance comparison to RTX 6090. P177 separately investigates whether a 32×32 instance can be physically routed, and remains a blocking experiment until its actual result is available.
