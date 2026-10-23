# P50 — Host transport cycle-trace qualification contract

**Scope:** P49 complete-frame arbitration; P45–P49 inherited HDL smoke suites.
**Mode:** simulation qualification infrastructure, **not** a new manufactured GPU capability.

## Why

P49 has two host-output lanes: A0GR (16-byte result) and A0GF (32-byte frame telemetry).
Prior Python models and a handcrafted HDL bench did not prove cycle-by-cycle equivalence
under long contention, solo traffic, reset, or randomized ready stalls.
P50 generates a deterministic, independently inspectable software-oracle trace and
builds a SystemVerilog bench which compares **observable pins** before each active clock
edge. This does *not* replace physical transport validation.

## Trace format

`A0-GPU/tools/a0_fair_trace_p50.py` writes UTF-8, a single comment header followed
by 10 decimal columns per clock cycle:

1. `rst_n`
2. `result_valid`
3. `result_byte`
4. `telemetry_valid`
5. `telemetry_byte`
6. `host_ready`
7. `expected_host_valid`
8. `expected_host_byte` (0 if invalid)
9. `expected_result_ready`
10. `expected_telemetry_ready`

The reference generator preserves upstream `valid` + `data` until handshake (apart
from reset); it never invalidates partway through a pending frame. Readiness is
sampled for accepted bytes. All expected values derive from the independent Python
P49 reference (`a0_fair_arbiter_p49.py`) and genuine encoded A0GR/A0GF payloads.

The SystemVerilog bench `a0_host_tx_fair_arbiter_p50_trace_tb.sv` checks every
cycle's host_valid, accepted-byte value, result_ready and telemetry_ready using
4-state (`!==`) comparisons. A mismatch calls `$fatal(1)` and fails the suite.

## Reproduction

```bash
cd A0-GPU
python -m unittest discover -s tests -p 'test_*.py' -q
python tools/a0_fair_trace_p50.py --seed 50050 --cycles 6000 \
  --out /tmp/a0-p50-trace.txt --summary /tmp/a0-p50-trace.json
python tests/run_p50_rtl_gate.py --receipt /tmp/a0-p50-rtl.json
```

The HDL gate calls the P45, P46, P47, P48 and P49 existing HDL gates first.
It then runs the P50 pin replay with a *real* Icarus or Verilator executable.
It emits status `PASS` only after all commands exit 0, `FAIL` for real failures,
and `NOT_RUN` (exit 2) when the simulator is not available. Tool versions are
included when a tool is present. This local development runner is not a
substitute for the separately specified canonical P37 Linux/Verilator gate.

The 6000-cycle default is intended for functionality, not performance. Regenerate
with multiple seeds before phase closure. Capture raw RTL logs and identify
exact simulator binary/version, operating system, hashes and run commands.

## Acceptance and remaining blockers

- [x] Deterministic Python software reference trace generation and replay.
- [x] Python mutation/negative tests detect corrupted expected output and source protocol violations.
- [x] A0GR/A0GF accepted software trace is parseable with CRC checking by P49 decoder.
- [x] Add a SystemVerilog on-pin comparison bench and strict gate script.
- [ ] Execute P45–P49 RTL benches successfully with a real simulator.
- [ ] Execute the P50 on-pin replay with a real simulator for multiple seeds.
- [ ] Audit raw simulation logs for all required regressions and source hashes.
- [ ] Complete P37 canonical inherited qualification and packaging independently.
- [ ] FPGA/ASIC/PCIe proof, driver compatibility and measured performance.

**P50 remains DEVELOPMENT / RTL NOT RUN** until mandatory RTL test requirements pass.
