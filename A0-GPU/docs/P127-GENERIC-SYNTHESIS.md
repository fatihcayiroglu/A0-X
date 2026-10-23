# P127 — Generic Yosys synthesis qualification

**Scope:** Yosys generic, technology-independent synthesis of selected *existing* A0-X RTL modules. This is **not** FPGA pin assignment, vendor cell mapping, timing closure, place-and-route, board programming, functional equivalence proof, or ASIC tapeout.

The CI job installs an actual `yosys` executable, then performs strict hierarchy checks, generic `synth`, `check -assert`, and JSON netlist inspection. The result contains RTL SHA256, Yosys version, cell counts and cell types, and retained per-target Yosys logs. Any target that is not run, fails synthesis, has an unexpected inferred latch, or has unresolved RTL/memory primitives causes the job to fail. Empty or missing evidence also fails.

Initial targets:

- `a0_p68_depth_compare` (simple combinational depth compare)
- `a0_scanout_telemetry_fifo_p117`, `FIFO_DEPTH=4`
- `a0_scanout_telemetry_loss_fifo_p118`, `FIFO_DEPTH=4`
- `a0_scanout_telemetry_loss_fifo_p118`, `FIFO_DEPTH=7` (non-power-of-two queue)

Run with `python3 -B A0-GPU/tools/a0_p127_synthesis.py --evidence EVIDENCE/P127/synthesis`. `yosys` must be installed. Run unit tests with `python3 -B -m unittest discover -s A0-GPU/tests -p test_p127_synthesis.py`.

**Limits:** Generic gate counts are not FPGA LUT / FF / BRAM utilization; no cell delays or static timing constraints are measured. Even full PASS does **not** mean a full GPU has been synthesized or that a physical GPU is ready. P126's 18 actual RTL simulation tests are separately required.