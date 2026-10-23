# P132 — bounded, single-clock P102 command/readback contract (draft)

Status: **RTL CANDIDATE — automated real-Icarus tests, direct-P102 differential comparison and ECP5-85K route gates implemented; verify current commit's Actions before merge.** This contract replaces P131's oversized *external* P102 parallel debug interface without changing the P102 arithmetic, depth, blend, or framebuffer semantics.

## Boundary

- One `clk` and active-low synchronous-observed `rst_n`; no asynchronous clock domain crossing is claimed.
- Inputs: `req_valid`, `req_write`, `req_addr[7:0]`, `req_wdata[31:0]`.
- Outputs: `req_ready`, `rsp_valid`, `rsp_rdata[31:0]`, `rsp_error`.
- A request transfers **only** on rising edge with `req_valid && req_ready`. One outstanding response at a time. `req_ready=0` whenever a response is pending; response held until `rsp_ready` (an additional input).
- Every accepted request gets exactly one response. Registers are 32-bit, little-endian byte-addressed, word-aligned. Unaligned, reserved, or unsupported operations return an error without changing state. No partial writes.
- Requests, completion status, and readback use the same clock. No external bus/PCIe/AXI protocol claims. No arbitrary host-driven combinational P102 inputs.

## Register addresses

| Address | Name | Direction | Meaning |
| --- | --- | --- | --- |
| 0x00 | ID | R | Constant `0x41305832` (ASCII A0X2) |
| 0x04 | STATUS | R | bit0 initialized, bit1 busy, bit2 clear_done latched, bit3 tri_done latched, bit4 last_error; reading does **not** clear flags |
| 0x08 | CONTROL | W | bit0 launch clear, bit1 launch triangle, bit2 acknowledge sticky completion/error bits; bits 1:0 cannot both be set |
| 0x0C | CLEAR_COLOR | RW | low 24 bits |
| 0x10 | CLEAR_DEPTH | RW | low 24 bits |
| 0x14 | X0_Y0 | RW | x0 signed 16 in low half, y0 signed 16 in high half |
| 0x18 | X1_Y1 | RW | same for vertex 1 |
| 0x1C | X2_Y2 | RW | same for vertex 2 |
| 0x20 | TRI_COLOR | RW | low 24 bits |
| 0x24 | TRI_DEPTH | RW | low 24 bits |
| 0x28 | TRI_MODE | RW | depth_compare_op[1:0], depth_write bit2, blend_enable bit3, source_alpha[15:8], scissor_enable bit16; all reserved bits must be zero |
| 0x2C | SCISSOR_XY | RW | X[15:0], Y[31:16] |
| 0x30 | SCISSOR_WH | RW | width[15:0], height[31:16] |
| 0x34 | READ_XY | RW | framebuffer X[15:0], Y[31:16] |
| 0x38 | READ_COLOR | R | valid in bit31, RGB[23:0] |
| 0x3C | READ_DEPTH | R | valid in bit31, depth[23:0] |

## Transaction semantics and ordering

1. Reset clears all configuration, pending response, sticky flags and in-flight launch request. P102 remains uninitialized until clear completes.
2. Writes to staging registers are permitted while the P102 engine is busy, but an accepted launch snapshots **all** relevant registers atomically. Subsequent writes cannot alter an in-flight operation.
3. `CONTROL.clear` may launch only if P102 `clear_ready` is true. `CONTROL.triangle` may launch only if `tri_ready` is true. Otherwise return `rsp_error` (no retry queue, no silently dropped job).
4. The launch pulse must last exactly one cycle at the P102 input. A successful write response means **accepted**, not **completed**. Poll sticky completion bits in STATUS to observe completion.
5. Readback must snapshot `READ_COLOR` and `READ_DEPTH` using the selected coordinates on their respective accepted reads. Invalid coordinates return valid=0 and zero data; no out-of-bounds access.
6. A request held valid while `req_ready=0` must not be executed twice; response data/error remain stable until `rsp_valid && rsp_ready`.
7. Reset during clear/draw invalidates response and clears sticky events. Concurrent completion and acknowledgment must have specified precedence (completion wins, to avoid losing an event).
8. Reserved bits in CONTROL or TRI_MODE are errors and must leave registers/state unchanged. Reads of write-only or writes to read-only addresses are errors.

## Qualification gates (required before merging; implemented gates run in GitHub Actions)

- Real Icarus testbench covers reset, write/read roundtrip, clear, triangle, readback, invalid address/misalignment, reserved bits, launch while busy, completion acknowledgment, sustained response backpressure, and response reset. The differential test covers depth, blend and scissor. Additional explicit no-duplicate-launch and snapshot-under-midflight-write directed tests remain useful hardening.
- Differential Icarus test compares every pixel's color/depth with independently driven direct P102 through clear, triangle, depth, blend, and scissor workload; fails on any mismatch.
- Yosys synthesis of the wrapper **and** P102; prove no unresolved hierarchy and no latch cells.
- ECP5-85K nextpnr place-route with genuine mapped utilization and internal timing. Require top-level IO count be below a documented package budget. No `--timing-allow-fail`; preserve P126/P129/P130/P131 regression gates.
- Evidence must mark NOT_RUN when real tools absent, FAIL on mismatches, PASS only when actually executed. Never describe synthesis/route as board certification.

## Explicitly outside P132

No physical PCB, pinout/LPF, external I/O timing, CDC, PCIe enumeration, DMA, VRAM, display timing, driver or measured GPU performance. Future external host buses must add explicit clock-domain and backpressure protocol qualification.
