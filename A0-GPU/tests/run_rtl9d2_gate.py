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
            / "tests/run_rtl9d2_l2_cache.py"
        ),
        str(
            ROOT
            / "tests/run_rtl9d2_gate.py"
        ),
    ])

    print(
        "RTL9D2_PYTHON_COMPILE=PASS"
    )

    targeted = run([
        sys.executable,
        str(
            ROOT
            / "tests/run_rtl9d2_l2_cache.py"
        ),
    ])

    if (
        "RTL9D2_SHARED_L2_DRIVER=PASS"
        not in targeted
    ):
        raise RuntimeError(
            "RTL9D-2 targeted driver marker missing"
        )

    print(
        "RTL9D2_TARGETED_SHARED_L2=PASS"
    )

    regression = run([
        sys.executable,
        str(
            ROOT
            / "tests/run_rtl9d1_gate.py"
        ),
    ])

    if (
        "RTL9D1_GATE=PASS"
        not in regression
    ):
        raise RuntimeError(
            "RTL9D-1 full regression marker missing"
        )

    print(
        "RTL9D2_RTL9D1_FULL_REGRESSION=PASS"
    )

    run([
        "git",
        "diff",
        "--check",
    ])

    run([
        "git",
        "diff",
        "--cached",
        "--check",
    ])

    print(
        "RTL9D2_GIT_DIFF_CHECK=PASS"
    )

    print(
        "RTL9D2_GATE=PASS"
    )

    print(
        "RTL9D2_COMMIT_ALLOWED=YES"
    )


if __name__ == "__main__":
    main()
