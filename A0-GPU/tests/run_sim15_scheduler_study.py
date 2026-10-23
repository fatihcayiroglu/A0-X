#!/usr/bin/env python3

import sys
from pathlib import Path


ROOT = Path(__file__).resolve().parents[1]
BENCH_DIR = ROOT / "benchmarks"

sys.path.insert(0, str(BENCH_DIR))


from sim15_scheduler_study import run_study


def main():
    report = run_study()
    summary = report["policy_summary"]

    if not report["architectural_equivalence"]:
        raise RuntimeError(
            "SIM15 architecture equivalence failed"
        )

    adaptive = summary["a0_adaptive_v0"]
    lrr = summary["lrr"]
    gto = summary["gto"]

    if adaptive["geomean_speedup_vs_lrr"] <= 1.0:
        raise RuntimeError(
            "SIM15 adaptive candidate did not beat LRR "
            "on the benchmark matrix"
        )

    if adaptive["worst_cycle_regression_vs_lrr"] != 0.0:
        raise RuntimeError(
            "SIM15 adaptive candidate regressed a "
            "benchmark case versus LRR"
        )

    if (
        adaptive["total_dram_accesses"]
        > gto["total_dram_accesses"]
    ):
        raise RuntimeError(
            "SIM15 adaptive candidate lost GTO's "
            "memory-locality benefit"
        )

    if (
        adaptive["total_frontend_stall_events"]
        > lrr["total_frontend_stall_events"]
    ):
        raise RuntimeError(
            "SIM15 adaptive candidate increased total "
            "RTL6B frontend stall observations"
        )

    print(
        "SIM15_ADAPTIVE_GEOMEAN_SPEEDUP="
        f"{adaptive['geomean_speedup_vs_lrr']:.6f}"
    )
    print(
        "SIM15_ADAPTIVE_WORST_REGRESSION="
        f"{adaptive['worst_cycle_regression_vs_lrr']:.6f}"
    )
    print(
        "SIM15_ADAPTIVE_TOTAL_DRAM="
        f"{adaptive['total_dram_accesses']}"
    )
    print("SIM15_ARCH_EQ=PASS")
    print("SIM15_POLICY_CONTRACT=PASS")
    print("SIM15_SCHEDULER_DRIVER=PASS")


if __name__ == "__main__":
    main()
