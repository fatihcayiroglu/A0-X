#!/usr/bin/env python3
"""Focused contract gate for A0 SIM17 adaptive scheduler v1."""

from __future__ import annotations

import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
if str(ROOT) not in sys.path:
    sys.path.insert(0, str(ROOT))

from benchmarks.sim17_scheduler_v1_study import (
    CAPACITIES,
    WORKLOADS,
    WAVE_COUNTS,
    capacity_scores,
    collect,
    decision_totals,
    policy_scores,
    trace_conservation,
    win_tie_loss,
)
from sim.a0_mlp_model import Instruction, MLPConfig, NonBlockingMemoryStudy


def require(condition: bool, message: str) -> None:
    if not condition:
        raise AssertionError(message)


def main() -> None:
    results = collect()
    scores = policy_scores(results)
    v0_by_capacity = capacity_scores(results, "a0_adaptive_v0")
    v1_by_capacity = capacity_scores(results, "a0_adaptive_v1")

    require(trace_conservation(results), "SIM17 changed per-wave traces")
    print("SIM17_TRACE_CONSERVATION=PASS")

    v1_geo, v1_worst = scores["a0_adaptive_v1"]
    v0_geo, v0_worst = scores["a0_adaptive_v0"]

    require(v1_geo > 1.08, "v1 geomean improvement is below 8%")
    require(v1_worst <= 0.0, "v1 regressed versus LRR")
    print("SIM17_V1_ZERO_REGRESSION=PASS")

    wins, ties, losses = win_tie_loss(results, "a0_adaptive_v1")
    require(wins == 18, f"unexpected v1 wins: {wins}")
    require(ties == 157, f"unexpected v1 ties: {ties}")
    require(losses == 0, f"unexpected v1 losses: {losses}")
    print("SIM17_V1_PARETO_SAFE=PASS")

    require(v0_worst > 0.17, "SIM16 v0 weakness was not reproduced")
    require(v1_worst < v0_worst, "v1 did not improve worst-case robustness")
    print("SIM17_V1_FIXES_V0_WORST_CASE=PASS")

    for capacity in (2, 4):
        v0_geo_cap, _ = v0_by_capacity[capacity]
        v1_geo_cap, v1_worst_cap = v1_by_capacity[capacity]
        require(
            v1_geo_cap > v0_geo_cap,
            f"v1 did not improve geomean at MSHR={capacity}",
        )
        require(
            v1_worst_cap <= 0.0,
            f"v1 regressed at MSHR={capacity}",
        )
    print("SIM17_LOW_MSHR_RECOVERY=PASS")

    # Explicitly exercise the pressure-sensitive same-line merge path.
    merge_programs = [
        [Instruction.load(8, 7), Instruction.halt()],
        [Instruction.load(9, 7), Instruction.halt()],
    ]
    merge_result = NonBlockingMemoryStudy(
        merge_programs,
        MLPConfig(
            mshr_capacity=2,
            l2_capacity_lines=0,
            dram_latency=20,
            scheduler_policy="a0_adaptive_v1",
        ),
    ).run()
    require(merge_result.mshr_merges == 1, "merge did not occur")
    require(
        merge_result.adaptive_merge_choices > 0,
        "v1 merge-priority mode was not exercised",
    )
    print("SIM17_PRESSURE_MERGE_MODE=PASS")

    merge, locality, fallback = decision_totals(results)
    require(merge > 0, "full matrix never exercised merge mode")
    require(locality > 0, "full matrix never exercised locality mode")
    require(fallback > 0, "full matrix never exercised LRR fallback")
    print("SIM17_DECISION_MODES_EXERCISED=PASS")

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
    print("SIM17_SCHEDULER_V1_CONTRACT=PASS")
    print("SIM17_SCHEDULER_V1_DRIVER=PASS")


if __name__ == "__main__":
    main()
