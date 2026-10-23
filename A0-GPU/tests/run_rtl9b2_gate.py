#!/usr/bin/env python3

from pathlib import Path
import subprocess
import sys

ROOT = Path(__file__).resolve().parents[1]


def run(script):
    result = subprocess.run(
        [sys.executable, str(ROOT / script)],
        cwd=ROOT,
        text=True,
    )

    if result.returncode:
        raise SystemExit(result.returncode)


def main():
    print("=== RTL9B2_TARGETED_INTEGRATION ===")
    run("tests/run_rtl9b2_integration.py")
    print("RTL9B2_TARGETED_INTEGRATION=PASS")

    print()
    print("=== RTL9B2_RTL9B1_FULL_REGRESSION ===")
    run("tests/run_rtl9b1_gate.py")
    print("RTL9B2_RTL9B1_FULL_REGRESSION=PASS")

    print()
    print("RTL9B2_GATE=PASS")
    print("RTL9B2_COMMIT_ALLOWED=YES")


if __name__ == "__main__":
    main()
