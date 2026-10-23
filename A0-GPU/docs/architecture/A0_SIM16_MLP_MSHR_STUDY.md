# A0 SIM16 — Non-Blocking Memory / MSHR Study

Status: research model, not RTL and not a frozen hardware sizing decision.

## Purpose

SIM16 answers a question that must be resolved before a true multi-wave,
non-blocking A0 memory pipeline is committed to RTL:

> How much memory-level parallelism is useful, where does MSHR capacity stop
> paying off, and does the SIM15 scheduler policy remain robust once memory
> requests can overlap?

The current RTL memory path is still fundamentally blocking. SIM16 therefore
models a **future** non-blocking LSU as a separate timing study rather than
silently changing the architectural golden model.

## Modeled mechanisms

- 1 instruction issue per cycle across resident waves.
- In-order instruction stream per wave.
- RAW/WAW register readiness.
- A wave may advance past an issued load if the next instruction is independent.
- Configurable MSHR capacity: 1, 2, 4, 8, 16, 32, 64.
- One MSHR per distinct outstanding L2 miss line.
- Same-line miss merging.
- Finite LRU L2.
- Fixed L2-hit and DRAM-miss latency.
- Scheduler policies:
  - LRR
  - GTO
  - oldest-ready
  - SIM15 `a0_adaptive_v0`

## Deliberately not modeled yet

- DRAM channel/bank contention.
- Return bandwidth.
- Memory-controller queueing.
- Store-buffer ordering.
- Atomics.
- TLB/page-walk effects.
- Cache-bank conflicts.
- Area/power cost per MSHR.

Because these are omitted, the capacity sweep is an **upper-bound timing
study**. A measured 32-entry performance knee does not mean "build exactly 32
MSHRs" without a later area/bandwidth study.

## Workloads

`independent_mlp`
: Eight independent loads are exposed before dependent ALU consumers.
  This stresses per-wave non-blocking MLP.

`dependent_chain`
: Every load is immediately consumed.
  Extra MSHRs cannot break true dependencies.

`mixed_overlap`
: Loads are interleaved with independent ALU work and periodic consumers.

`shared_locality`
: Waves reuse a small shared line set that fits in L2.

`thrash_locality`
: Each wave owns a small hot set, but the aggregate resident working set
  exceeds L2. This exposes scheduler-locality effects.

## Sweep

- Waves: 1, 2, 4, 8, 16.
- MSHRs: 1, 2, 4, 8, 16, 32, 64.
- Policies: LRR, GTO, oldest-ready, `a0_adaptive_v0`.
- Five workload classes.

Every policy/capacity combination must preserve the per-wave issued
instruction and memory-instruction signatures.

## Current study result

With the deterministic SIM16 model:

- LRR geomean speedup versus 1 MSHR:
  - 16 MSHRs: about 4.91x
  - 32 MSHRs: about 5.34x
  - 64 MSHRs: about 5.38x
- 16 -> 32 still provides a meaningful gain.
- 32 -> 64 adds less than 2% geomean in this matrix.

Therefore **32 is the first measured saturation knee in the current model**.
This is a performance-study result, not a frozen hardware capacity.

A second important result is that SIM15 `a0_adaptive_v0` is not robust at
small MSHR counts. In the full matrix it can regress materially relative to
LRR at 2 and 4 MSHRs. That is expected: v0 only knows a working-set/L2
heuristic and has no MSHR-pressure signal.

Therefore:

> Do not freeze `a0_adaptive_v0` into RTL.

The next scheduler candidate should incorporate at least:

- current MSHR occupancy / pressure,
- number of memory-stalled waves,
- number of ready non-memory waves,
- known same-line merge opportunities,
- L2 locality/pressure.

## Architectural consequence

SIM16 supports the following next-step structure:

1. Keep 16 and 32 MSHRs as the primary RTL9 prototype points.
2. Do not spend area on 64 before bandwidth/area modeling proves value.
3. Build the multi-wave scheduler so MSHR pressure is a first-class input.
4. Preserve the ability for independent loads from one wave to remain
   outstanding concurrently.
5. Add DRAM bandwidth/channel modeling before final MSHR sizing.

## Verification contract

`tests/run_sim16_mlp_study.py` proves:

- real capacity benefit on independent misses,
- MSHR occupancy reaches the configured limit,
- same-line MSHR merging,
- true dependency saturation,
- instruction-trace conservation across the full matrix,
- the 32-entry saturation knee,
- the low-capacity weakness of `a0_adaptive_v0`.

`tests/run_sim16_gate.py` additionally reruns the entire SIM15 gate, which
already includes the RTL6B live-core gate, RTL6 foundation gate, historical
RTL regressions, randomized differential tests, and Python regression.
