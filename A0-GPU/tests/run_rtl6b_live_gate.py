#!/usr/bin/env python3

from __future__ import annotations

import subprocess
from pathlib import Path


ROOT = Path(__file__).resolve().parents[1]


def run(name: str, command: list[str]) -> None:
    print(f"\n=== {name} ===")
    result = subprocess.run(
        command,
        cwd=ROOT,
        text=True,
        stdout=subprocess.PIPE,
        stderr=subprocess.STDOUT,
        check=False,
    )
    print(result.stdout, end="")
    if result.returncode != 0:
        raise RuntimeError(f"{name} failed with exit code {result.returncode}")
    print(f"{name}=PASS")


def main() -> None:
    run(
        "RTL6B_PYTHON_COMPILE",
        ["python3", "-m", "compileall", "-q", "sim", "tests"],
    )

    run(
        "RTL6B_LIVE_LINT",
        [
            "verilator",
            "--lint-only",
            "--timing",
            "--top-module",
            "a0_wave_core_rtl6b_tb",
            "-Wall",
            "-Wno-BLKSEQ",
            "-Wno-UNUSEDSIGNAL",
            "-Wno-UNUSEDPARAM",
            "-Werror-PINMISSING",
            "-Werror-WIDTHEXPAND",
            "-Werror-WIDTHTRUNC",
            "rtl/core/a0_scoreboard.sv",
            "rtl/core/a0_dependency_classifier.sv",
            "rtl/core/a0_lane_sequencer.sv",
            "rtl/core/a0_regfile_banked.sv",
            "rtl/core/a0_operand_collector.sv",
            "rtl/core/a0_vector_operand_path.sv",
            "rtl/core/a0_wave_core.sv",
            "tests/rtl/a0_wave_core_rtl6b_tb.sv",
        ],
    )

    run("RTL6B_LIVE_CORE", ["python3", "tests/run_rtl6b_live_core.py"])

    # The foundation gate includes the 10K operand differential, RTL0-5E
    # historical regression, Python architectural regression, and diff check.
    run("RTL6_FOUNDATION_REGRESSION", ["python3", "tests/run_rtl6_foundation_gate.py"])

    run("RTL6B_GIT_DIFF_CHECK", ["git", "diff", "--check"])

    print("\nRTL6B_LIVE_GATE=PASS")
    print("RTL6B_COMMIT_ALLOWED=YES")


if __name__ == "__main__":
    main()
