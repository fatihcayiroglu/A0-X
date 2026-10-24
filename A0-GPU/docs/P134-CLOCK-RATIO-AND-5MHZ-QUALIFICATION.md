# P134 — host/GPU clock-ratio sweep and 5 MHz routed research target

Status: **draft / evidence required**. Based on P133 merged into `main` (PR #8, merge `583ca7c`).

## Purpose

Validate the existing P133 host-to-GPU command bridge under multiple non-identical clock frequencies and phases. Raise the ECP5-85K **research-only** internal timing target from 1 MHz to 5 MHz. These are verification and mapping milestones, not a new silicon GPU or production qualification.

## Test plan

- Icarus Verilog integration simulations at host/GPU half-periods (ns) and GPU initial phase: `(3,11,0)`, `(11,3,1)`, `(7,9,2)`, `(9,7,3)`, `(5,5,1)`, `(4,13,3)`.
- For each case, run the integrated real P133->P132->P102 test: 24 ordered write/read pairs, simultaneous request and response FIFO saturation, register readback, errors, response backpressure, and synchronous release from a shared reset.
- For each case, run the 41- and 33-bit independent FIFO tests: 512 sequence-checked transfers **per direction** after an in-flight reset, variable stalls, wraparound, held-data stability, and under/overflow guards.
- Fail immediately when any individual simulation does not exit successfully or is missing its exact PASS marker. Save per-ratio compile/execution logs, and a machine-readable summary. Do not count skipped or omitted cases as PASS.
- Real Yosys ECP5 mapping and nextpnr ECP5-85K place-and-route with `--freq 5`, speed grade 6, CABGA756, fixed seed 1 and parameterized 4x4 framebuffer. Reject non-positive or inadequate achieved/constraint frequencies, unbound I/O >96 bits, unmapped cells and latches.

## Important limitations

- `nextpnr --freq 5` is an internal tool timing target and applies to both reported clocks as implemented; this is **not** a realistic independent-clock signoff with all asynchronous paths constrained.
- Gray-coded multi-bit pointer crossings still need physical maximum-skew checks on each Gray bus, placement review, CDC/RDC analysis, metastability MTBF methodology and board-specific clock/reset specifications. They are **not** proven by these tests.
- External pins are unconstrained here; there is no FPGA bitstream, physical board, PCIe, display, VRAM, power, thermal, driver, or performance proof.
- No assertion that 5 MHz is the intended product clock frequency or that real hardware operates at this speed.

## Exit criteria

Both P134 jobs must pass on **the same exact PR head** alongside inherited P126/P127/P132/P133 gates where they are triggered. Keep the PR draft while any job is pending, skipped, or failing.
