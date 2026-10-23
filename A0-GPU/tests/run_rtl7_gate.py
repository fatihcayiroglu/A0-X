#!/usr/bin/env python3
"""A0 RTL7A resident-wave context/scheduler full gate."""

from __future__ import annotations

import subprocess
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
        "RTL7_PYTHON_COMPILE",
        [
            "python3",
            "-m",
            "py_compile",
            "sim/a0_wave_scheduler_model.py",
            "tests/run_rtl7_context_file.py",
            "tests/run_rtl7_scheduler.py",
            "tests/run_rtl7_frontend.py",
            "tests/run_rtl7_scheduler_diff.py",
            "tests/run_rtl7_gate.py",
        ],
    )

    run(
        "RTL7_PRODUCTION_LINT",
        [
            "verilator",
            "--lint-only",
            "--timing",
            "-Wall",
            "-Wno-fatal",
            "-Werror-PINMISSING",
            "-Werror-WIDTHEXPAND",
            "-Werror-WIDTHTRUNC",
            "-Wno-BLKSEQ",
            "-Wno-UNUSEDSIGNAL",
            "-Wno-UNUSEDPARAM",
            "--top-module",
            "a0_multi_wave_frontend",
            "rtl/scheduler/a0_wave_context_file.sv",
            "rtl/scheduler/a0_wave_scheduler.sv",
            "rtl/scheduler/a0_multi_wave_frontend.sv",
        ],
    )

    run(
        "RTL7_CONTEXT_FILE",
        [
            "python3",
            "tests/run_rtl7_context_file.py",
        ],
    )

    run(
        "RTL7_WAVE_SCHEDULER",
        [
            "python3",
            "tests/run_rtl7_scheduler.py",
        ],
    )

    run(
        "RTL7_MULTI_WAVE_FRONTEND",
        [
            "python3",
            "tests/run_rtl7_frontend.py",
        ],
    )

    run(
        "RTL7_SCHEDULER_10K_DIFF",
        [
            "python3",
            "tests/run_rtl7_scheduler_diff.py",
        ],
    )

    run(
        "SIM17_FULL_REGRESSION",
        [
            "python3",
            "tests/run_sim17_gate.py",
        ],
    )

    run(
        "RTL7_GIT_DIFF_CHECK",
        [
            "git",
            "diff",
            "--check",
        ],
    )

    print()
    print("RTL7A_GATE=PASS")
    print("RTL7A_COMMIT_ALLOWED=YES")


if __name__ == "__main__":
    main()
