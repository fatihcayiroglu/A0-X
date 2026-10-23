#!/usr/bin/env python3

from pathlib import Path
import subprocess
import sys


ROOT = Path(__file__).resolve().parents[1]


def run(cmd):
    result = subprocess.run(
        cmd,
        cwd=ROOT,
        text=True,
        stdout=subprocess.PIPE,
        stderr=subprocess.STDOUT,
    )

    print(
        result.stdout,
        end="",
    )

    if result.returncode:
        raise RuntimeError(
            "command failed: "
            + " ".join(cmd)
        )

    return result.stdout


def main():
    run([
        sys.executable,
        "-m",
        "py_compile",
        str(
            ROOT
            / "tests/run_rtl9d1_line_fabric.py"
        ),
        str(
            ROOT
            / "tests/run_rtl9d1_gate.py"
        ),
    ])

    print(
        "RTL9D1_PYTHON_COMPILE=PASS"
    )

    targeted = run([
        sys.executable,
        str(
            ROOT
            / "tests/run_rtl9d1_line_fabric.py"
        ),
    ])

    if (
        "RTL9D1_LINE_FABRIC_DRIVER=PASS"
        not in targeted
    ):
        raise RuntimeError(
            "RTL9D-1 targeted driver marker missing"
        )

    print(
        "RTL9D1_TARGETED_LINE_FABRIC=PASS"
    )

    regression = run([
        sys.executable,
        str(
            ROOT
            / "tests/run_rtl9c1_gate.py"
        ),
    ])

    if (
        "RTL9C1_GATE=PASS"
        not in regression
    ):
        raise RuntimeError(
            "RTL9C-1 full regression marker missing"
        )

    print(
        "RTL9D1_RTL9C1_FULL_REGRESSION=PASS"
    )

    run([
        "git",
        "diff",
        "--check",
    ])

    print(
        "RTL9D1_GIT_DIFF_CHECK=PASS"
    )

    print(
        "RTL9D1_GATE=PASS"
    )

    print(
        "RTL9D1_COMMIT_ALLOWED=YES"
    )


if __name__ == "__main__":
    main()
