#!/usr/bin/env python3
"""A0 SIM17 full verification gate."""

from __future__ import annotations

import subprocess
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]


def run(name: str, command: list[str]) -> None:
    print()
    print(f"=== {name} ===", flush=True)
    result = subprocess.run(command, cwd=ROOT, text=True)
    if result.returncode != 0:
        raise RuntimeError(f"{name} failed with exit code {result.returncode}")
    print(f"{name}=PASS", flush=True)


def main() -> None:
    run(
        "SIM17_PYTHON_COMPILE",
        [
            "python3",
            "-m",
            "py_compile",
            "sim/a0_mlp_model.py",
            "benchmarks/sim17_scheduler_v1_study.py",
            "tests/run_sim17_scheduler_v1.py",
            "tests/run_sim17_gate.py",
        ],
    )

    run(
        "SIM17_FOCUSED_SCHEDULER_V1",
        ["python3", "tests/run_sim17_scheduler_v1.py"],
    )

    run(
        "SIM17_BENCHMARK_REPORT",
        ["python3", "benchmarks/sim17_scheduler_v1_study.py"],
    )

    # SIM16 gate already reruns SIM15, RTL6B, RTL6 foundation, the
    # historical RTL chain, randomized differential tests, and Python tests.
    run(
        "SIM16_FULL_REGRESSION",
        ["python3", "tests/run_sim16_gate.py"],
    )

    run("SIM17_GIT_DIFF_CHECK", ["git", "diff", "--check"])

    print()
    print("SIM17_GATE=PASS")
    print("SIM17_COMMIT_ALLOWED=YES")


if __name__ == "__main__":
    main()
