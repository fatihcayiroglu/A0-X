#!/usr/bin/env python3
"""Focused correctness and research-contract gate for A0 SIM16."""

from __future__ import annotations

import math
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
if str(ROOT) not in sys.path:
    sys.path.insert(0, str(ROOT))

from benchmarks.sim16_mlp_study import (
    CAPACITIES,
    POLICIES,
    WAVE_COUNTS,
    capacity_speedups,
    collect,
    policy_scores,
    trace_conservation,
)
from sim.a0_mlp_model import (
    Instruction,
    MLPConfig,
    NonBlockingMemoryStudy,
    run_workload,
)


def require(condition: bool, message: str) -> None:
    if not condition:
        raise AssertionError(message)


def main() -> None:
    # 1) Basic MSHR capacity must improve a deliberately independent miss stream.
    cap1 = run_workload(
        "independent_mlp",
        8,
        1,
        "lrr",
    )
    cap8 = run_workload(
        "independent_mlp",
        8,
        8,
        "lrr",
    )
    require(
        cap8.cycles < cap1.cycles,
        "8 MSHRs did not improve independent MLP workload",
    )
    require(
        cap8.peak_mshr_occupancy == 8,
        "8-entry MSHR configuration was not actually exercised",
    )
    print("SIM16_CAPACITY_EFFECT=PASS")

    # 2) Same-line misses from separate waves must merge into one MSHR.
    programs = [
        [Instruction.load(8, 7), Instruction.halt()],
        [Instruction.load(9, 7), Instruction.halt()],
    ]
    merged = NonBlockingMemoryStudy(
        programs,
        MLPConfig(
            mshr_capacity=2,
            l2_capacity_lines=0,
            dram_latency=20,
            scheduler_policy="lrr",
        ),
    ).run()
    require(
        merged.dram_misses == 1,
        "same-line misses did not share one DRAM miss",
    )
    require(
        merged.mshr_merges == 1,
        "same-line miss merge path was not exercised",
    )
    print("SIM16_MSHR_MERGE=PASS")

    # 3) A dependent chain should saturate earlier than independent MLP.
    dep8 = run_workload(
        "dependent_chain",
        8,
        8,
        "lrr",
    )
    dep16 = run_workload(
        "dependent_chain",
        8,
        16,
        "lrr",
    )
    indep8 = run_workload(
        "independent_mlp",
        8,
        8,
        "lrr",
    )
    indep16 = run_workload(
        "independent_mlp",
        8,
        16,
        "lrr",
    )
    require(
        dep16.cycles == dep8.cycles,
        "dependent-chain workload should be saturated by 8 MSHRs",
    )
    require(
        indep16.cycles < indep8.cycles,
        "independent workload should still benefit above 8 MSHRs",
    )
    print("SIM16_DEPENDENCY_LIMIT=PASS")

    # 4) Full research matrix.
    results = collect()
    require(
        trace_conservation(results),
        "scheduler/capacity sweep changed per-wave instruction traces",
    )
    print("SIM16_TRACE_CONSERVATION=PASS")

    speedups = capacity_speedups(results)
    scores = policy_scores(results)

    # MSHR 32 is the first tested point after which the next doubling is <2%.
    lrr16 = speedups["lrr", 16]
    lrr32 = speedups["lrr", 32]
    lrr64 = speedups["lrr", 64]
    increment_16_to_32 = lrr32 / lrr16 - 1.0
    increment_32_to_64 = lrr64 / lrr32 - 1.0

    require(
        increment_16_to_32 > 0.02,
        "16->32 MSHR gain unexpectedly fell below the research threshold",
    )
    require(
        increment_32_to_64 < 0.02,
        "32->64 MSHR gain did not show the expected saturation knee",
    )
    print("SIM16_MSHR_KNEE_32=PASS")

    # SIM15 a0_adaptive_v0 is intentionally *not* MSHR-pressure-aware.
    # SIM16 must detect that it is not robust at small MSHR counts.
    adaptive2_worst = scores[
        2,
        "a0_adaptive_v0",
    ][1]
    adaptive4_worst = scores[
        4,
        "a0_adaptive_v0",
    ][1]
    require(
        adaptive2_worst > 0.05,
        "SIM15 adaptive v0 unexpectedly showed no low-MSHR regression",
    )
    require(
        adaptive4_worst > 0.05,
        "SIM15 adaptive v0 unexpectedly showed no 4-MSHR regression",
    )
    print("SIM16_ADAPTIVE_V0_NOT_FREEZE=PASS")

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
        "SIM16_INCREMENT_16_TO_32="
        f"{increment_16_to_32:.6f}"
    )
    print(
        "SIM16_INCREMENT_32_TO_64="
        f"{increment_32_to_64:.6f}"
    )
    print(
        "SIM16_ADAPTIVE_V0_WORST_REGRESSION_MSHR2="
        f"{adaptive2_worst:.6f}"
    )
    print(
        "SIM16_ADAPTIVE_V0_WORST_REGRESSION_MSHR4="
        f"{adaptive4_worst:.6f}"
    )
    print("SIM16_MLP_CONTRACT=PASS")
    print("SIM16_MLP_DRIVER=PASS")


if __name__ == "__main__":
    main()
