# A0-SIM15 — Scheduler Policy and RTL6B Frontend Study

## Purpose

SIM15 turns wave scheduling from an intuition-driven choice into a measured
policy experiment. It compares deterministic scheduler policies in the
existing timing simulator while preserving the architectural simulator as the
source of truth.

SIM15 does **not** freeze the production scheduler. The benchmark matrix is
still synthetic and the timing model remains pre-MLP/MSHR. The results are a
selection signal for the next experiments, not a final hardware claim.

## Policies

The timing scheduler supports four policies:

- `lrr` — loose round robin. This is the historical/default behavior.
- `gto` — greedy-then-oldest. Continue the last-issued wave when possible,
  otherwise fall back to admission order.
- `oldest_ready` — select the wave that has gone longest without an issue.
- `a0_adaptive_v0` — locality-aware candidate derived from SIM15 data.

`a0_adaptive_v0` is intentionally simple. It keeps LRR as the base policy. It
only prefers a consecutive memory instruction from the last-issued wave when
the predicted active VLOADX/VSTOREX cache-line working set exceeds L2
capacity. This gives the candidate an observable reason to become greedy
rather than applying greediness unconditionally.

## RTL6B coarse vector frontend model

The default timing model remains `ideal` so existing timing regressions retain
their previous meaning.

SIM15 adds an opt-in `rtl6b_coarse` model for the integer/compare vector
sequence currently live in RTL6B:

- logical wave size: 32 lanes;
- default physical width: 8 lanes;
- four physical beats per logical vector instruction;
- four VRF banks;
- one read per bank per cycle;
- one-cycle synchronous VRF read response;
- bank mapping: `vector_register % vrf_bank_count`.

For one physical beat, the coarse operand-delivery time is:

```text
request_cycles + read_latency + bank_read_rounds
```

The whole instruction hold is:

```text
beat_count * per_beat_cycles + retire_cycles
```

With the reference parameters, a two-source conflict-free vector instruction
uses 13 coarse frontend cycles. If both sources alias one bank, each beat needs
one extra read round and the model adds four cycles, producing a 17-cycle hold.
This +4-cycle delta matches the four physical conflict beats exposed by the
RTL6B integration tests. The model is still a coarse timing abstraction, not a
cycle-perfect reproduction of `a0_wave_core.sv`.

## Instrumentation

SIM15 adds scheduler and frontend telemetry:

- issue trace with cycle, wave, PC, opcode, frontend hold, and VRF bank rounds;
- scheduler switches;
- maximum consecutive issue run;
- per-wave issue counts;
- per-wave maximum issue gap;
- frontend stall observations;
- VRF conflict instruction count;
- VRF conflict extra rounds;
- coarse VRF conflict penalty cycles;
- accumulated vector frontend hold cycles.

The existing dependency, functional-unit, completion, barrier, cache, and
latency-hiding metrics remain available.

## Benchmark matrix

`benchmarks/sim15_scheduler_study.py` evaluates wave counts 2, 4, and 8 over:

1. `latency_hiding` — dependent FP chains;
2. `cache_fits_l2` — independent repeated loads whose active working set fits
   the configured L2;
3. `cache_thrashes_l2` — the same access style with an intentionally small L2;
4. `vrf_clean` — conflict-free RTL6B-style integer vector sources;
5. `vrf_conflict` — same-bank RTL6B-style integer vector sources.

Every policy run starts from fresh wave state. The benchmark verifies the final
architectural fingerprint is identical across policies before publishing
performance results.

## Initial result

On the deterministic SIM15 matrix implemented with this milestone:

| policy | geometric-mean speedup vs LRR | worst cycle regression vs LRR | total cycles | total DRAM accesses | total frontend stall observations |
|---|---:|---:|---:|---:|---:|
| LRR | 1.000000 | 0.000000 | 730 | 128 | 1008 |
| GTO | 0.958429 | 0.404762 | 756 | 56 | 1312 |
| oldest-ready | 1.000000 | 0.000000 | 730 | 128 | 1008 |
| A0 adaptive v0 | **1.016233** | **0.000000** | **718** | **56** | **1008** |

The important observation is not the +1.62% number by itself. The matrix shows
why a fixed GTO policy is unsafe: it preserves locality but can lose substantial
latency hiding when the working set already fits in cache. The adaptive v0
candidate keeps LRR behavior in those cases and only becomes greedy under
predicted L2 pressure.

This result is not sufficient to freeze `a0_adaptive_v0`. SIM16 must add
memory-level parallelism/MSHR pressure, and later studies need broader compute,
graphics-shader, divergence, cache, and occupancy traces.

## Required verification

Focused scheduler study:

```text
python3 tests/run_sim15_scheduler_study.py
```

Human-readable matrix:

```text
python3 benchmarks/sim15_scheduler_study.py
```

Optional JSON report:

```text
python3 benchmarks/sim15_scheduler_study.py --json-out build/sim15.json
```

Full pre-commit gate:

```text
python3 tests/run_sim15_gate.py
```

The full gate also reruns the RTL6B regression chain because the RTL
differential drivers consume the same architectural simulator package.

## Non-goals

SIM15 does not add:

- RTL multi-wave contexts;
- a hardware wave selector;
- MSHRs or a non-blocking LSU;
- byte-address migration;
- a final cache geometry;
- a final issue width;
- compiler scheduling or register-bank allocation;
- a final production scheduler policy.

Those remain evidence-driven follow-on work.
