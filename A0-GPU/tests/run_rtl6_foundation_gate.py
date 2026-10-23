#!/usr/bin/env python3

from pathlib import Path
import subprocess


ROOT = Path(__file__).resolve().parents[1]

RTL_DRIVERS = [
    "tests/run_rtl0_diff.py",
    "tests/run_rtl1_diff.py",
    "tests/run_rtl2_diff.py",
    "tests/run_rtl3a_diff.py",
    "tests/run_rtl3b_diff.py",
    "tests/run_rtl3b_boundary.py",
    "tests/run_rtl4a_diff.py",
    "tests/run_rtl4b_diff.py",
    "tests/run_rtl5a_diff.py",
    "tests/run_rtl5b_classifier.py",
    "tests/run_rtl5b_scoreboard.py",
    "tests/run_rtl5b_core.py",
    "tests/run_rtl5c_core.py",
    "tests/run_rtl5c_hazards.py",
    "tests/run_rtl5d_issue_queue.py",
    "tests/run_rtl5e_queue_diff.py",
]

RTL6_DRIVERS = [
    "tests/run_rtl6_regfile.py",
    "tests/run_rtl6_operand_collector.py",
    "tests/run_rtl6_operand_diff.py",
]


def run(name, command):
    print(f"\n=== {name} ===")
    result = subprocess.run(
        command,
        cwd=ROOT,
        text=True,
        stdout=subprocess.PIPE,
        stderr=subprocess.STDOUT,
    )
    print(result.stdout, end="")
    if result.returncode != 0:
        raise RuntimeError(f"{name} failed with exit code {result.returncode}")
    print(f"{name}=PASS")


def main():
    run(
        "RTL6_PYTHON_COMPILE",
        ["python3", "-m", "compileall", "-q", "sim", "tests"],
    )

    run(
        "RTL6_REGFILE_LINT",
        [
            "verilator",
            "--lint-only",
            "--timing",
            "--top-module",
            "a0_regfile_banked_tb",
            "-Wall",
            "-Wno-BLKSEQ",
            "-Wno-UNUSEDSIGNAL",
            "-Werror-PINMISSING",
            "-Werror-WIDTHEXPAND",
            "-Werror-WIDTHTRUNC",
            "rtl/core/a0_regfile_banked.sv",
            "tests/rtl/a0_regfile_banked_tb.sv",
        ],
    )

    run(
        "RTL6_COLLECTOR_LINT",
        [
            "verilator",
            "--lint-only",
            "--timing",
            "--top-module",
            "a0_operand_collector_tb",
            "-Wall",
            "-Wno-BLKSEQ",
            "-Wno-UNUSEDSIGNAL",
            "-Werror-PINMISSING",
            "-Werror-WIDTHEXPAND",
            "-Werror-WIDTHTRUNC",
            "rtl/core/a0_regfile_banked.sv",
            "rtl/core/a0_operand_collector.sv",
            "tests/rtl/a0_operand_collector_tb.sv",
        ],
    )

    for driver in RTL6_DRIVERS:
        run(Path(driver).stem, ["python3", driver])

    for driver in RTL_DRIVERS:
        run(Path(driver).stem, ["python3", driver])

    run("RTL6_PYTHON_REGRESSION", ["python3", "tests/test_a0_regression.py"])
    run("RTL6_GIT_DIFF_CHECK", ["git", "diff", "--check"])

    print("\nRTL6_FOUNDATION_GATE=PASS")
    print("RTL6_FOUNDATION_COMMIT_ALLOWED=YES")


if __name__ == "__main__":
    main()
