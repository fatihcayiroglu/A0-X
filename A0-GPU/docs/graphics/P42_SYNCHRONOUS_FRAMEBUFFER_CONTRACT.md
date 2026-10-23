# P42 — synchronous framebuffer / pixel stream experiment

**Status:** experimental, HDL simulation and FPGA not yet demonstrated.

## Components

- `a0_sync_frame_ram_p42.sv`: registered 24-bit read port, one-clock read-valid response, sequential bulk clear, independent indexed writes. No array reset. Invalid/out-of-range reads suppress `read_valid`. While clearing, `initialized=0`, and writes are blocked. Reset invalidates the data but does **not** physically clear SRAM.
- `a0_sync_frame_scanout_p42.sv`: single outstanding request FSM `ISSUE -> WAIT_READ -> HOLD`; can deliver at most one RGB888 pixel every three clocks. Maintains `valid/data/xy/sof/eol/eof` stable under backpressure; registered `frame_done` pulse on accepted end-of-frame. Disable/uninitialized aborts and resumes at (0,0).
- `a0_triangle_double_buffer_sync_display_p42.sv`: integrates the **original P38 rasterizer** with two P42 sync memory banks and P42 scanner; gates render/scan to separate banks; freezes new draw/clear commands while swap pending; switches at frame boundary or if display is disabled or not yet initialized. New wrapper avoids touching archived P39–P41 sources.

## Limitations / release blockers

- FPGA BRAM mapping, usable clock frequency, timing closure, display timing, safety across clock domains and pinout are **not yet proven**. VRAM, PCIe, DMA, real monitor link and production A0-X GPU command scheduling are **not integrated**.
- Memory contents are undefined until clearing every address. `read_valid` is a registered response. A meaningful test must exercise **RTL simulation**, not only a Python reference. The current portable controller intentionally optimizes for correctness over throughput (<=1 pixel / 3 clocks).
- `clear_valid` is not a queue. A clear only starts on `clear_valid && clear_ready`; similarly `tri_valid && tri_ready`, `swap_valid && swap_ready`.
- The front and back always refer to distinct physical buffers. An accepted swap locks the rear until commit. On commit scanout is disabled for one cycle to flush prefetched reads.
- The two RAM banks share the same `clk` in this experiment. It is **not** a display-domain clock crossing implementation.
- Memory reads/writes can be dual-port *within each array*, but no same-address read/write semantics are specified for an actively writing/displayed bank. The wrapper prevents this condition by ownership.
- Due to full-frame sequential clear and single-pixel pipeline, do **not** market this as an ASIC-ready or production-performance framebuffer.

## Verification status

- `python -m unittest discover -s tests -p 'test_*py' -v` exercises reference programs, not synthesized logic.
- `python tests/run_p42_sync_display.py` demands real HDL execution and fails/blocks honestly if unavailable. `--python-only` is explicitly reference-only.
- HDL testbench `tests/rtl/a0_triangle_double_buffer_sync_display_p42_tb.sv` is provided for the strict gate. Testbench compilation/elaboration-only results do not imply behavioral PASS.

## Next verification before P42 closure

1. Run HDL testbench on supported Icarus or fully installed trusted Verilator, record fresh raw compile and execution logs with exit codes.
2. Extend HDL testbench with randomized stalls, reset and rasterized triangles; check asserted invariants via mutation testing.
3. Synthesize to chosen FPGA target, review BRAM inference reports, measure Fmax and logic/resource usage; benchmark versus the prior async framebuffer.
4. Design an explicit command/VRAM interface to the A0 production path after actual RTL performance evidence.
