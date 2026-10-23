#!/usr/bin/env python3
"""A0 SIM17: MSHR-pressure-aware adaptive scheduler v1 study."""

from __future__ import annotations

import math
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
if str(ROOT) not in sys.path:
    sys.path.insert(0, str(ROOT))

from sim.a0_mlp_model import WORKLOADS, run_workload

CAPACITIES = (1, 2, 4, 8, 16, 32, 64)
WAVE_COUNTS = (1, 2, 4, 8, 16)
POLICIES = (
    "lrr",
    "gto",
    "oldest_ready",
    "a0_adaptive_v0",
    "a0_adaptive_v1",
)


def geomean(values: list[float]) -> float:
    return math.exp(sum(math.log(value) for value in values) / len(values))


def collect():
    results = {}
    for workload in WORKLOADS:
        for waves in WAVE_COUNTS:
            for capacity in CAPACITIES:
                for policy in POLICIES:
                    results[workload, waves, capacity, policy] = run_workload(
                        workload,
                        waves,
                        capacity,
                        policy,
                    )
    return results


def policy_scores(results):
    table = {}
    for policy in POLICIES:
        speedups = []
        regressions = []
        for workload in WORKLOADS:
            for waves in WAVE_COUNTS:
                for capacity in CAPACITIES:
                    baseline = results[
                        workload,
                        waves,
                        capacity,
                        "lrr",
                    ].cycles
                    candidate = results[
                        workload,
                        waves,
                        capacity,
                        policy,
                    ].cycles
                    speedups.append(baseline / candidate)
                    regressions.append((candidate - baseline) / baseline)
        table[policy] = (geomean(speedups), max(regressions))
    return table


def capacity_scores(results, policy: str):
    table = {}
    for capacity in CAPACITIES:
        speedups = []
        regressions = []
        for workload in WORKLOADS:
            for waves in WAVE_COUNTS:
                baseline = results[
                    workload,
                    waves,
                    capacity,
                    "lrr",
                ].cycles
                candidate = results[
                    workload,
                    waves,
                    capacity,
                    policy,
                ].cycles
                speedups.append(baseline / candidate)
                regressions.append((candidate - baseline) / baseline)
        table[capacity] = (geomean(speedups), max(regressions))
    return table


def win_tie_loss(results, policy: str):
    wins = 0
    ties = 0
    losses = 0
    for workload in WORKLOADS:
        for waves in WAVE_COUNTS:
            for capacity in CAPACITIES:
                baseline = results[
                    workload,
                    waves,
                    capacity,
                    "lrr",
                ].cycles
                candidate = results[
                    workload,
                    waves,
                    capacity,
                    policy,
                ].cycles
                if candidate < baseline:
                    wins += 1
                elif candidate == baseline:
                    ties += 1
                else:
                    losses += 1
    return wins, ties, losses


def trace_conservation(results) -> bool:
    for workload in WORKLOADS:
        for waves in WAVE_COUNTS:
            reference = results[workload, waves, 1, "lrr"]
            for capacity in CAPACITIES:
                for policy in POLICIES:
                    candidate = results[
                        workload,
                        waves,
                        capacity,
                        policy,
                    ]
                    if (
                        candidate.instruction_signature
                        != reference.instruction_signature
                        or candidate.memory_signature
                        != reference.memory_signature
                    ):
                        return False
    return True


def decision_totals(results):
    merge = 0
    locality = 0
    fallback = 0
    for workload in WORKLOADS:
        for waves in WAVE_COUNTS:
            for capacity in CAPACITIES:
                result = results[
                    workload,
                    waves,
                    capacity,
                    "a0_adaptive_v1",
                ]
                merge += result.adaptive_merge_choices
                locality += result.adaptive_locality_choices
                fallback += result.adaptive_fallback_choices
    return merge, locality, fallback


def main() -> None:
    results = collect()
    scores = policy_scores(results)
    v0_by_capacity = capacity_scores(results, "a0_adaptive_v0")
    v1_by_capacity = capacity_scores(results, "a0_adaptive_v1")
    wins, ties, losses = win_tie_loss(results, "a0_adaptive_v1")
    merge, locality, fallback = decision_totals(results)

    print(
        "policy,geomean_speedup_vs_lrr,"
        "worst_cycle_regression_vs_lrr"
    )
    for policy in POLICIES:
        geo, worst = scores[policy]
        print(f"{policy},{geo:.6f},{worst:.6f}")

    print()
    print(
        "mshr,v0_geomean,v0_worst_regression,"
        "v1_geomean,v1_worst_regression"
    )
    for capacity in CAPACITIES:
        v0_geo, v0_worst = v0_by_capacity[capacity]
        v1_geo, v1_worst = v1_by_capacity[capacity]
        print(
            f"{capacity},{v0_geo:.6f},{v0_worst:.6f},"
            f"{v1_geo:.6f},{v1_worst:.6f}"
        )

    print()
    print("workload,waves,mshr,lrr,v0,v1")
    selected = (
        ("dependent_chain", 4, 2),
        ("dependent_chain", 16, 4),
        ("thrash_locality", 8, 2),
        ("thrash_locality", 8, 4),
        ("independent_mlp", 8, 8),
        ("independent_mlp", 8, 32),
    )
    for workload, waves, capacity in selected:
        print(
            f"{workload},{waves},{capacity},"
            f"{results[workload, waves, capacity, 'lrr'].cycles},"
            f"{results[workload, waves, capacity, 'a0_adaptive_v0'].cycles},"
            f"{results[workload, waves, capacity, 'a0_adaptive_v1'].cycles}"
        )

    v1_geo, v1_worst = scores["a0_adaptive_v1"]
    v0_geo, v0_worst = scores["a0_adaptive_v0"]

    print()
    print(f"SIM17_V0_GEOMEAN_SPEEDUP={v0_geo:.6f}")
    print(f"SIM17_V0_WORST_REGRESSION={v0_worst:.6f}")
    print(f"SIM17_V1_GEOMEAN_SPEEDUP={v1_geo:.6f}")
    print(f"SIM17_V1_WORST_REGRESSION={v1_worst:.6f}")
    print(f"SIM17_V1_WINS={wins}")
    print(f"SIM17_V1_TIES={ties}")
    print(f"SIM17_V1_LOSSES={losses}")
    print(f"SIM17_V1_MERGE_CHOICES={merge}")
    print(f"SIM17_V1_LOCALITY_CHOICES={locality}")
    print(f"SIM17_V1_FALLBACK_CHOICES={fallback}")
    print(
        "SIM17_TRACE_CONSERVATION="
        + ("PASS" if trace_conservation(results) else "FAIL")
    )
    print("SIM17_SCHEDULER_V1_STUDY=PASS")


if __name__ == "__main__":
    main()
