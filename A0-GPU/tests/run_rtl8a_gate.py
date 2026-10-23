#!/usr/bin/env python3
"""A0 RTL8A MSHR foundation full verification gate."""

from pathlib import Path
import subprocess

ROOT = Path(__file__).resolve().parents[1]


def run(name, command):
    print()
    print(f"=== {name} ===", flush=True)
    result = subprocess.run(command, cwd=ROOT, text=True)
    if result.returncode != 0:
        raise RuntimeError(f"{name} failed with exit code {result.returncode}")
    print(f"{name}=PASS", flush=True)


def main():
    run(
        "RTL8A_PYTHON_COMPILE",
        [
            "python3",
            "-m",
            "py_compile",
            "sim/a0_mshr_model.py",
            "tests/run_rtl8a_mshr.py",
            "tests/run_rtl8a_mshr_capacity.py",
            "tests/run_rtl8a_mshr_diff.py",
            "tests/run_rtl8a_gate.py",
        ],
    )

    run(
        "RTL8A_PRODUCTION_LINT",
        [
            "verilator",
            "--lint-only",
            "--timing",
            "-Wall",
            "-Wno-UNUSEDSIGNAL",
            "-Wno-UNUSEDPARAM",
            "-Werror-PINMISSING",
            "-Werror-WIDTHEXPAND",
            "-Werror-WIDTHTRUNC",
            "--top-module",
            "a0_mshr_table",
            "rtl/memory/a0_mshr_table.sv",
        ],
    )

    run(
        "RTL8A_MSHR_DIRECTED",
        ["python3", "tests/run_rtl8a_mshr.py"],
    )

    run(
        "RTL8A_MSHR_CAPACITY_SWEEP",
        ["python3", "tests/run_rtl8a_mshr_capacity.py"],
    )

    run(
        "RTL8A_MSHR_10K_DIFF",
        ["python3", "tests/run_rtl8a_mshr_diff.py"],
    )

    run(
        "RTL7C_FULL_REGRESSION",
        ["python3", "tests/run_rtl7c_gate.py"],
    )

    run(
        "RTL8A_GIT_DIFF_CHECK",
        ["git", "diff", "--check"],
    )

    print()
    print("RTL8A_GATE=PASS")
    print("RTL8A_COMMIT_ALLOWED=YES")


if __name__ == "__main__":
    main()
