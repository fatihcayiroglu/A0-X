# P121 — strict RTL qualification contract

P121 **does not add a new GPU datapath**. It consolidates 14 pre-existing
Icarus Verilog simulation gates into a required, reproducible, fail-closed
qualification command. The 14 gates cover P103, P104, P105, P106, P111,
P112, P113, P114, P115, P116, two P117 gates and two P118 gates.

## Running on an Icarus-equipped Linux machine

```bash
sudo apt-get update && sudo apt-get install -y iverilog
python3 A0-GPU/tools/a0_p121_rtl_qualification.py \
  --evidence EVIDENCE/P121/rtl_qualification
```

The corresponding manually dispatchable GitHub Actions workflow is
`.github/workflows/a0-p121-full-rtl-qualification.yml`. Push the project
files to a repository before manually dispatching this workflow; merely
including the workflow in a ZIP does not execute CI.

## Evidence and exit semantics

- **0 — PASS**: 14/14 sub-gates exited zero, each emitted exactly one expected
  HDL testbench witness, and no fatal/NOT_RUN diagnostic appeared.
- **1 — FAIL**: any gate failed, timed out, was skipped despite a nominal
  toolchain, or the evidence/sources are invalid. The gate continues through
  all 14 so the evidence includes independent failures.
- **2 — NOT RUN**: Icarus compiler or vvp runtime was absent. All 14 entries
  are recorded as NOT_RUN. This is **not** a passing test result.

The script writes `qualification.json` atomically, with SHA-256 source hashes,
per-test logs, hashes of the logs, toolchain paths, execution statuses and
an explicit `qualified` boolean. It doesn't accept a user-defined shortened
suite. Unit tests use **mocked runners** only to test rejection semantics;
those fixtures cannot qualify RTL or predict actual HDL behavior.

## Trust boundaries and next steps

- A positive CI run would qualify precisely the finite Icarus testbenches,
  not the entire synthesizable design, timing, safety, or real silicon.
- The old P103–P118 benches might fail when first run on actual Icarus;
  failures must be fixed in HDL/testbench and retested, not waived.
- The simulator and workflow were **not run** in the P121 authoring sandbox.
- No PCIe endpoint, DMA, VRAM, video PHY, FPGA board pinout, hardware
  prototype or measured performance is present.
- Next: run the workflow on an actual Ubuntu environment and address the
  first real RTL failure; then obtain synthesis and FPGA hardware evidence.

**Anti-mock safeguard:** injected tool lookup/executor runs are marked
`MOCK_ONLY` (sub-gates `MOCK_PASS`) and return nonzero even when all fake
markers appear. Only unmodified real subprocess execution can qualify RTL.
