# P176: Larger and asymmetric framebuffer oracles

## Purpose

P175 closed one shader-preload cycle per pixel at 8×8 and 16×16 with an unchanged 4×4 legacy route. The next risk is geometry and framebuffer scaling. P176 **changes no synthesizable RTL** and extends independent host-observable proofs to larger and non-square dimensions.

## Exact acceptance checks

- P172/P176 full-image P102 versus host-framebuffer equality at **8×8, 16×16, 32×16, 16×32, 32×32**, testing both programmed shader cases, clears, fault responses and every addressed pixel.
- Demand exactly `5*W*H` verified framebuffer reads, `2*W*H` covered fragments and no hidden test skips on every shape.
- Detect line-stride/row-major addressing defects with 32×16 and 16×32 at equal pixel counts but different row lengths.
- At 32×32, verify **5,120 full-frame pixel observations** and 2,048 shaded fragment coverages. Including all five P172 shapes, 11,840 pixel observations are required.
- P173 runs two actual shader/raster/RMW programs at **4×4, 8×8, 16×16, 32×32**, and preserves all P174 cycle envelopes (`52*N+2`, `35*N+2`). On scaled shapes require the existing P175 stronger envelopes (`51*N+2`, `34*N+2`). Emit actual cycle counters rather than extrapolating them.
- Preserve separate unchanged **4×4 ≥40 MHz** and **16×16 ≥36.5 MHz** ECP5 routes; no 32×32 physical timing or 32×32 device-fit claim is made by this patch.

## Limitations

A 32×32 synthetic shader test is still not a practical-resolution benchmark, gaming frame rate, real VRAM bus bandwidth, PCIe transaction rate or RTX-class GPU comparison. P176's new evidence measures scaling and correctness of the existing research pipeline only. Any test timeout, geometry error, missing pixel, shader mismatch or cycle-budget regression blocks integration.

## Future measured work

Once the 32×32 oracle is green, test 64×64+ physical resource use and realistic memory-pressure kernels separately, with explicit VRAM bandwidth and cache-hit diagnostics; do not infer 1080p or 4K readiness from this proof.
