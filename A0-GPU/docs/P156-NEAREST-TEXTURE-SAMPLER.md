# P156 — first synchronous nearest-neighbor 2D texture sampler

P156 adds a **standalone, synthesizable 16×16 RGBA8888 nearest-texel sampler** intended as the first texture datapath building block for future A0-X fragment shader programs. This is separate from P155/P153 and is **not** currently part of the pixel shader ISA or active framebuffer.

The sampler has single-clock write and sample ports, deterministic **sample-over-write priority on contention**, an 8-bit response ID, and a registered `rsp_valid/rsp_ready` output which holds RGBA, ID and presence stable through arbitrary consumer stalls. When the host is ready, it can accept a **sample on every clock**. The single-port memory cannot write and sample on the same edge. A bitmap tracks which texels have been initialized: resetting the texture marks all texels absent and causes unwritten RGBA reads to return **zero and present=false**, hiding stale FPGA RAM bytes while preserving block RAM inference. Every texel must be explicitly written before being considered initialized.

Sample coordinates are signed **16-bit integer texel indices**, not normalized floating-point UVs. `sample_repeat=0` clamps negative and out-of-range indices to the nearest edge; `sample_repeat=1` wraps modulo texture width/height via low-bit masking. Texture dimensions must be positive powers of two between 2 and 256. Default FPGA qualification uses 16×16; a follow-up may add interpolated attributes, normalized coordinates, bilinear filtering, mipmaps and actual shader texture-fetch instructions.

## Required real evidence

- True Icarus RTL with an independent signed integer addressing and RGBA scoreboard: all 256 texels initialized with distinct data, >2,170 tested sample requests, 2,048 deterministic randomized signed out-of-range clamp/repeat requests, **128 consecutive accepted sample inputs (one per clock)**, exact response IDs and all 32 RGBA bits.
- Deliberate same-cycle single-port sample/write contention must give sample priority and stall the write without altering memory. Host stalls must hold full response ID/RGBA/presence. Physical reset must invalidate all previous texels, return zero for uninitialized reads and permit fresh writes, without stale output leaks.
- Genuine Yosys `synth_ecp5` and nextpnr ECP5-85K CABGA756 speed6 seed1, externally unconstrained package pins, 5MHz artificial research target. Assert exact **130 top-level I/O bits** and real `DP16KD` block RAM mapping (not merely RTL register arrays), bounded resources and full placed/routed timing report.
- Do not merge the PR if its latest exact-head tests are failed/skipped/pending, or if new edits break inherited relevant workflows.

This is not VRAM, a texture cache, a GPU texture unit with hardware interpolation, a GPU shader execution integration, a driver, PCIe, a physical board or game FPS evidence. The quoted route clock frequency is always a nonphysical tool estimate.
