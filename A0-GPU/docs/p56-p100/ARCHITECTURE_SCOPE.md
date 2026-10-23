# A0-X P56–P100 prototype scope, not a finished GPU

This checkpoint contains 45 **software-level development milestones**, one focused
acceptance test per phase, and five small **unverified RTL candidate modules**.
The milestones do NOT represent 45 physically verified silicon features.

## Newly created, independent experimental paths

- `sim/a0_nextgen_graphics_p56_p80.py`: bounded RGBA/framebuffer,
  integer-coordinate, pixel-centred rasterization, per-pixel interpolants,
  optional Z test, simple alpha blending, texture nearest/bilinear, and
  straight-line four-component fragment program.
- `sim/a0_nextgen_compute_p81_p85.py`: lane-masked, lockstep *software*
  integer compute model with bounded register/memory, uniform barriers and
  deterministic group-sum. Not a warp scheduler or SPIR-V implementation.
- `sim/a0_nextgen_runtime_p86_p95.py`: in-process handle table, immutable
  command buffers, conservative resource hazard rule, synchronous queue/fence,
  strict CRC-protected trace envelope; **not** a PCIe, DMA or OS driver.
- `tools/a0_p100_integrated_demo.py`: reproducible software-generated PPM,
  graphics CRC and compute buffer output; **not** hardware scanout.
- `rtl/graphics/a0_p59_scissor_coverage.sv`, `rtl/graphics/a0_p68_depth_compare.sv`,
  `rtl/graphics/a0_p70_rgb_blend.sv`, `rtl/texture/a0_p74_nearest_texel_address.sv`,
  `rtl/core/a0_p83_lane_mask_filter.sv`: minimal standalone RTL **candidates**
  with one testbench. These are **not** wired into the P43/P46 RTL datapath.

## Explicit limitations

- Graphics triangles use integer screen-space vertices and affine interpolants:
  no clip-space geometry, perspective correction, MSAA, stencil, geometry shader,
  tessellation or sophisticated occlusion.
- Colors are treated as linear floats; no sRGB transfer function.
- Shader is a tiny bounded interpreter (MOV/ADD/MUL/MAD/MIN/MAX/SAT/TEX),
  not GLSL/SPIR-V, nor a shader compiler or native machine ISA.
- Compute is a sequential software reference, not physical parallel cores.
- Queues are synchronous and conservative; a failed queue can have partial
  effects. No atomic rollback, preemption, isolation or driver certification.
- Real RTL simulation, lint, formal, FPGA, ASIC, memory controller timings,
  power, real FPS, Windows/Linux drivers, Vulkan/DirectX conformance, and
  physical tapeout are **NOT RUN/NOT IMPLEMENTED**.
- P37 canonical closure and previous P45–P55 RTL verification remain OPEN.
- This is NOT a release-ready GPU or a quantitative competitor to NVIDIA.

## Retained frozen checkpoint

Earlier P55 and inherited P36/P37 source/evidence files are included unchanged.
The P36 ~1.4 GB original verification ZIP is NOT embedded (the previous
independent P36 review is included); do not use this package as a substitute
for missing original P36 publication artifacts.

## Later independent RTL qualification

Run `bash tests/rtl/run_p100_candidate_gate.sh` with Icarus installed. Then
run the inherited P51 full RTL gate and the P37 canonical qualification,
collect logs and preserve tool/version identity. The manual CI example in
`.github/workflows/a0-p100-manual-verification.yml` is included but not run.
Never call the development checkpoint CLOSED just because Python tests pass.
