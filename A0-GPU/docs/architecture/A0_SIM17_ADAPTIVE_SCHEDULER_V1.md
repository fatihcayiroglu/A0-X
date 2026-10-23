# A0 SIM17 — MSHR-pressure-aware adaptive scheduler v1

Status: measured research candidate, not a frozen RTL scheduler policy.

## Why SIM17 exists

SIM15 showed that locality-aware scheduling can reduce cache traffic, but its
first `a0_adaptive_v0` heuristic had no knowledge of memory-level parallelism.
SIM16 then exposed the failure mode: at 2 and 4 MSHRs, v0 could regress by
about 17.3% and 10.5% versus LRR on some workloads.

SIM17 does not try to maximize benchmark geomean at any cost. Its target is a
safer Pareto point:

> retain useful locality wins while eliminating measured regressions versus
> the LRR baseline in the current deterministic matrix.

## v1 decision table

`a0_adaptive_v1` keeps LRR as the default and adds two bounded exceptions.

### 1. Pressure-sensitive same-line merge priority

The scheduler computes:

```
mshr_pressure = outstanding_mshrs / mshr_capacity
```

If a ready memory instruction targets a line that already has an outstanding
MSHR, the request can merge without consuming another miss slot. v1 gives
such a wave priority when either:

- MSHR pressure is at least 50%, or
- another wave is already stalled because the MSHR pool is full.

This makes MSHR occupancy/capacity a direct scheduler input.

### 2. Bounded locality continuation

The SIM16 matrix showed that unrestricted greedy continuation is dangerous.
v1 therefore permits locality-greedy continuation only when all of these are
true:

- MSHR capacity is 8 or fewer entries,
- aggregate memory working set exceeds L2 capacity,
- the previously issued wave is still ready,
- its next instruction is memory,
- its previous issued instruction was also memory.

The final condition is a dynamic **memory-burst continuity** signal. It avoids
turning a load/consumer/load dependency chain into GTO-like scheduling.

### 3. LRR fallback

Every other case returns to LRR.

This is deliberate. Experiments that aggressively prioritized ready
non-memory waves under MSHR pressure created new regressions in independent
MLP workloads, so those variants were rejected rather than hidden.

## Full matrix

The study reuses SIM16's matrix:

- workloads: five classes,
- waves: 1, 2, 4, 8, 16,
- MSHRs: 1, 2, 4, 8, 16, 32, 64,
- policies: LRR, GTO, oldest-ready, adaptive v0, adaptive v1.

That produces 175 workload/wave/MSHR points per policy.

## Current result

Relative to LRR over the complete matrix:

| Policy | Geomean speedup | Worst cycle regression |
|---|---:|---:|
| GTO | ~1.136x | ~17.3% |
| oldest-ready | ~1.001x | 0% |
| adaptive v0 | ~1.119x | ~17.3% |
| **adaptive v1** | **~1.087x** | **0%** |

Adaptive v1's exact LRR comparison in the deterministic matrix is:

- 18 wins,
- 157 ties,
- 0 losses.

At the two capacities where v0 showed its most important weakness:

- 2 MSHRs: v1 improves geomean over v0 and removes the 17.3% regression.
- 4 MSHRs: v1 improves geomean over v0 and removes the 10.5% regression.

At larger capacities v1 intentionally falls back toward LRR instead of taking
small locality wins that require accepting new worst-case regressions.

## What this does *not* prove

v1 is not ready to hardwire into production RTL. SIM16/SIM17 still omit:

- DRAM channel and bank contention,
- return-path bandwidth,
- memory-controller arbitration,
- cache-bank conflicts,
- TLB/page-walk effects,
- store ordering and atomics,
- scheduler hardware area/timing cost.

The result supports an RTL scheduler **interface** that exposes MSHR pressure
and merge/locality metadata. It does not justify freezing the exact thresholds
forever.

## Recommended RTL consequence

For the upcoming true multi-wave RTL stage:

1. Keep LRR as the correctness/reference policy.
2. Expose scheduler inputs for MSHR occupancy/capacity and merge readiness.
3. Preserve a configurable policy hook rather than hardwiring v1.
4. Prototype 16 and 32 MSHR memory configurations later, as indicated by
   SIM16.
5. Re-run the policy study after a bandwidth-aware memory-controller model
   exists.

## Verification contract

`tests/run_sim17_scheduler_v1.py` requires:

- per-wave trace conservation,
- v1 geomean speedup greater than 8%,
- zero measured regression versus LRR,
- exact 18/157/0 win/tie/loss result,
- recovery of the 2/4-MSHR v0 failure cases,
- explicit same-line pressure merge execution,
- merge, locality, and LRR-fallback modes all exercised.

`tests/run_sim17_gate.py` additionally reruns the complete SIM16 gate and its
entire historical regression chain.
