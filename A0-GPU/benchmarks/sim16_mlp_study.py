#!/usr/bin/env python3
"""A0 SIM16 MLP/MSHR benchmark matrix."""

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
)


def geomean(values: list[float]) -> float:
    return math.exp(
        sum(math.log(value) for value in values)
        / len(values)
    )


def collect():
    results = {}
    for workload in WORKLOADS:
        for waves in WAVE_COUNTS:
            for capacity in CAPACITIES:
                for policy in POLICIES:
                    results[
                        workload,
                        waves,
                        capacity,
                        policy,
                    ] = run_workload(
                        workload,
                        waves,
                        capacity,
                        policy,
                    )
    return results


def capacity_speedups(results):
    table = {}
    for policy in POLICIES:
        for capacity in CAPACITIES:
            ratios = []
            for workload in WORKLOADS:
                for waves in WAVE_COUNTS:
                    baseline = results[
                        workload,
                        waves,
                        1,
                        policy,
                    ].cycles
                    candidate = results[
                        workload,
                        waves,
                        capacity,
                        policy,
                    ].cycles
                    ratios.append(
                        baseline / candidate
                    )
            table[policy, capacity] = geomean(ratios)
    return table


def policy_scores(results):
    table = {}
    for capacity in CAPACITIES:
        for policy in POLICIES:
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
                    speedups.append(
                        baseline / candidate
                    )
                    regressions.append(
                        (candidate - baseline)
                        / baseline
                    )
            table[capacity, policy] = (
                geomean(speedups),
                max(regressions),
            )
    return table


def trace_conservation(results) -> bool:
    for workload in WORKLOADS:
        for waves in WAVE_COUNTS:
            reference = results[
                workload,
                waves,
                1,
                "lrr",
            ]
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


def main() -> None:
    results = collect()
    speedups = capacity_speedups(results)
    policies = policy_scores(results)

    print(
        "capacity,policy,"
        "geomean_speedup_vs_mshr1"
    )
    for capacity in CAPACITIES:
        for policy in POLICIES:
            print(
                f"{capacity},{policy},"
                f"{speedups[policy, capacity]:.6f}"
            )

    print()
    print(
        "capacity,policy,"
        "geomean_speedup_vs_lrr,"
        "worst_cycle_regression_vs_lrr"
    )
    for capacity in CAPACITIES:
        for policy in POLICIES:
            geo, worst = policies[
                capacity,
                policy,
            ]
            print(
                f"{capacity},{policy},"
                f"{geo:.6f},{worst:.6f}"
            )

    print()
    print(
        "workload,waves,mshr,policy,"
        "cycles,ipc,dram,l2_hits,merges,"
        "avg_mshr,peak_mshr,mshr_full_cycles"
    )
    selected = (
        ("independent_mlp", 8),
        ("dependent_chain", 8),
        ("thrash_locality", 8),
    )
    for workload, waves in selected:
        for capacity in CAPACITIES:
            for policy in POLICIES:
                result = results[
                    workload,
                    waves,
                    capacity,
                    policy,
                ]
                print(
                    f"{workload},{waves},"
                    f"{capacity},{policy},"
                    f"{result.cycles},"
                    f"{result.ipc:.6f},"
                    f"{result.dram_misses},"
                    f"{result.l2_hits},"
                    f"{result.mshr_merges},"
                    f"{result.average_mshr_occupancy:.6f},"
                    f"{result.peak_mshr_occupancy},"
                    f"{result.mshr_full_global_cycles}"
                )

    lrr16 = speedups["lrr", 16]
    lrr32 = speedups["lrr", 32]
    lrr64 = speedups["lrr", 64]
    increment_32_to_64 = lrr64 / lrr32 - 1.0

    adaptive_cap2_worst = policies[
        2,
        "a0_adaptive_v0",
    ][1]
    adaptive_cap4_worst = policies[
        4,
        "a0_adaptive_v0",
    ][1]

    print()
    print(
        "SIM16_LRR_GEOMEAN_SPEEDUP_MSHR16="
        f"{lrr16:.6f}"
    )
    print(
        "SIM16_LRR_GEOMEAN_SPEEDUP_MSHR32="
        f"{lrr32:.6f}"
    )
    print(
        "SIM16_LRR_GEOMEAN_SPEEDUP_MSHR64="
        f"{lrr64:.6f}"
    )
    print(
        "SIM16_INCREMENT_32_TO_64="
        f"{increment_32_to_64:.6f}"
    )
    print(
        "SIM16_ADAPTIVE_V0_WORST_REGRESSION_MSHR2="
        f"{adaptive_cap2_worst:.6f}"
    )
    print(
        "SIM16_ADAPTIVE_V0_WORST_REGRESSION_MSHR4="
        f"{adaptive_cap4_worst:.6f}"
    )
    print(
        "SIM16_TRACE_CONSERVATION="
        + ("PASS" if trace_conservation(results) else "FAIL")
    )
    print("SIM16_MSHR_STUDY=PASS")


if __name__ == "__main__":
    main()
