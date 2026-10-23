#!/usr/bin/env python3

import subprocess
from pathlib import Path


ROOT = Path(__file__).resolve().parents[1]


def run(name, command):
    print()
    print(f"=== {name} ===")

    result = subprocess.run(
        command,
        cwd=ROOT,
        text=True,
    )

    if result.returncode != 0:
        raise RuntimeError(
            f"{name} failed with exit code "
            f"{result.returncode}"
        )

    print(f"{name}=PASS")


def main():
    run(
        "SIM15_PYTHON_COMPILE",
        [
            "python3",
            "-m",
            "py_compile",
            "sim/a0_sim.py",
            "benchmarks/sim15_scheduler_study.py",
            "tests/run_sim15_scheduler_study.py",
        ],
    )

    run(
        "SIM15_PYTHON_REGRESSION",
        [
            "python3",
            "-m",
            "unittest",
            "discover",
            "-s",
            "tests",
            "-q",
        ],
    )

    run(
        "SIM15_POLICY_STUDY",
        [
            "python3",
            "tests/run_sim15_scheduler_study.py",
        ],
    )

    run(
        "SIM15_BENCHMARK_REPORT",
        [
            "python3",
            "benchmarks/sim15_scheduler_study.py",
        ],
    )

    run(
        "SIM15_RTL6B_REGRESSION",
        [
            "python3",
            "tests/run_rtl6b_live_gate.py",
        ],
    )

    run(
        "SIM15_GIT_DIFF_CHECK",
        [
            "git",
            "diff",
            "--check",
        ],
    )

    print()
    print("SIM15_GATE=PASS")
    print("SIM15_COMMIT_ALLOWED=YES")


if __name__ == "__main__":
    main()
