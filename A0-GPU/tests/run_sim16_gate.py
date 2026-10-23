#!/usr/bin/env python3
"""A0 SIM16 full verification gate."""

from __future__ import annotations

import subprocess
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]


def run(name: str, command: list[str]) -> None:
    print()
    print(f"=== {name} ===", flush=True)
    result = subprocess.run(
        command,
        cwd=ROOT,
        text=True,
    )
    if result.returncode != 0:
        raise RuntimeError(
            f"{name} failed with exit code {result.returncode}"
        )
    print(f"{name}=PASS", flush=True)


def main() -> None:
    run(
        "SIM16_PYTHON_COMPILE",
        [
            "python3",
            "-m",
            "py_compile",
            "sim/a0_mlp_model.py",
            "benchmarks/sim16_mlp_study.py",
            "tests/run_sim16_mlp_study.py",
            "tests/run_sim16_gate.py",
        ],
    )

    run(
        "SIM16_FOCUSED_MLP_STUDY",
        [
            "python3",
            "tests/run_sim16_mlp_study.py",
        ],
    )

    run(
        "SIM16_BENCHMARK_REPORT",
        [
            "python3",
            "benchmarks/sim16_mlp_study.py",
        ],
    )

    # SIM15 full gate already includes Python regression and the full
    # RTL6B -> RTL6 -> RTL0...RTL5E historical regression chain.
    run(
        "SIM15_FULL_REGRESSION",
        [
            "python3",
            "tests/run_sim15_gate.py",
        ],
    )

    run(
        "SIM16_GIT_DIFF_CHECK",
        [
            "git",
            "diff",
            "--check",
        ],
    )

    print()
    print("SIM16_GATE=PASS")
    print("SIM16_COMMIT_ALLOWED=YES")


if __name__ == "__main__":
    main()
