#!/usr/bin/env python3

from pathlib import Path
import subprocess
import sys


ROOT = Path(__file__).resolve().parents[1]


def run(script: str) -> None:
    result = subprocess.run(
        [
            sys.executable,
            str(ROOT / script),
        ],
        cwd=ROOT,
        text=True,
    )

    if result.returncode:
        raise SystemExit(result.returncode)


def main() -> None:
    print(
        "=== RTL9C1_CORE_L1_TARGETED ==="
    )

    run(
        "tests/run_rtl9c1_core_l1.py"
    )

    print(
        "RTL9C1_CORE_L1_TARGETED=PASS"
    )

    print()
    print(
        "=== RTL9C1_RTL9B2_FULL_REGRESSION ==="
    )

    run(
        "tests/run_rtl9b2_gate.py"
    )

    print(
        "RTL9C1_RTL9B2_FULL_REGRESSION=PASS"
    )

    print()
    print("RTL9C1_GATE=PASS")
    print("RTL9C1_COMMIT_ALLOWED=YES")


if __name__ == "__main__":
    main()
