#!/usr/bin/env python3
"""A0 RTL8C buffered-store / conflict-aware-ordering closure gate."""

from __future__ import annotations

from pathlib import Path
import subprocess
import sys


ROOT = Path(__file__).resolve().parents[1]

REQUIRED_FILES = [
    ROOT / "rtl/memory/a0_store_queue.sv",
    ROOT / "tests/rtl/a0_store_queue_tb.sv",
    ROOT / "tests/rtl/a0_store_queue_capacity_tb.sv",
    ROOT / "tests/rtl/a0_multi_wave_core_rtl8c_multi_store_tb.sv",
    ROOT / "tests/rtl/a0_multi_wave_core_rtl8c_load_bypass_tb.sv",
    ROOT / "tests/rtl/a0_store_queue_rtl8c5_age_tb.sv",
    ROOT / "tests/run_rtl8c_store_queue.py",
    ROOT / "tests/run_rtl8c_store_queue_capacity.py",
    ROOT / "tests/run_rtl8c_multi_store.py",
    ROOT / "tests/run_rtl8c_load_bypass.py",
    ROOT / "tests/run_rtl8c5_age.py",
    ROOT / "docs/architecture/A0_RTL8C_NON_BLOCKING_STORES.md",
]


def run(command: list[str], title: str) -> str:
    print()
    print("=" * 60)
    print(title)
    print("=" * 60)

    result = subprocess.run(
        command,
        cwd=ROOT,
        text=True,
        stdout=subprocess.PIPE,
        stderr=subprocess.STDOUT,
    )
    print(result.stdout, end="")
    if result.returncode != 0:
        raise RuntimeError(
            f"{title} failed with exit code {result.returncode}: "
            + " ".join(command)
        )
    return result.stdout


def main() -> None:
    missing_files = [
        str(path.relative_to(ROOT))
        for path in REQUIRED_FILES
        if not path.exists()
    ]
    if missing_files:
        raise RuntimeError(
            "RTL8C required file(s) missing: "
            + ", ".join(missing_files)
        )

    runners = [
        ROOT / "tests/run_rtl8c_store_queue.py",
        ROOT / "tests/run_rtl8c_store_queue_capacity.py",
        ROOT / "tests/run_rtl8c_multi_store.py",
        ROOT / "tests/run_rtl8c_load_bypass.py",
        ROOT / "tests/run_rtl8c5_age.py",
        ROOT / "tests/run_rtl8b_gate.py",
        ROOT / "tests/run_rtl8c_gate.py",
    ]

    run(
        [sys.executable, "-m", "py_compile", *map(str, runners)],
        "RTL8C_PYTHON_COMPILE",
    )
    print("RTL8C_PYTHON_COMPILE=PASS")

    run(
        [sys.executable, "tests/run_rtl8c_store_queue.py"],
        "RTL8C_STORE_QUEUE_FOUNDATION",
    )
    print("RTL8C_STORE_QUEUE_FOUNDATION=PASS")

    run(
        [sys.executable, "tests/run_rtl8c_store_queue_capacity.py"],
        "RTL8C_STORE_QUEUE_PARAMETERIZATION",
    )
    print("RTL8C_STORE_QUEUE_PARAMETERIZATION=PASS")

    age_output = run(
        [sys.executable, "tests/run_rtl8c5_age.py"],
        "RTL8C5A_QUEUE_AGE_SOURCE_FOUNDATION",
    )
    required_age = [
        "RTL8C5_QUEUE_SEQUENCE_ORDER=PASS",
        "RTL8C5_PROBE_IGNORES_YOUNGER_STORE=PASS",
        "RTL8C5_PROBE_SELECTS_YOUNGEST_OLDER=PASS",
        "RTL8C5_DUPLICATE_STORE_SOURCE_AMBIGUOUS=PASS",
        "RTL8C5A_QUEUE_AGE_SOURCE_FOUNDATION=PASS",
    ]
    missing_age = [
        marker for marker in required_age
        if marker not in age_output
    ]
    if missing_age:
        raise RuntimeError(
            "RTL8C-5A queue age/source marker(s) missing: "
            + ", ".join(missing_age)
        )
    print("RTL8C5A_QUEUE_AGE_SOURCE_FOUNDATION_FROM_RTL8C=PASS")

    multi_output = run(
        [sys.executable, "tests/run_rtl8c_multi_store.py"],
        "RTL8C_MULTI_STORE_INTEGRATION",
    )
    required_multi = [
        "RTL8C_NO_STORE_RETIRE_BEFORE_RESPONSE=PASS",
        "RTL8C_PHYSICAL_STORE_RESPONSE_BUFFERED_DURING_PAUSE=PASS",
        "RTL8C5_STORE_SEQUENCE_MONOTONIC_CORE=PASS",
        "RTL8C5_PHYSICAL_STORE_SEQUENCE_PRESERVED=PASS",
        "RTL8C_MULTI_STORE_INTEGRATION_TB=PASS",
        "RTL8C_MULTI_STORE_DRIVER=PASS",
    ]
    missing_multi = [
        marker for marker in required_multi
        if marker not in multi_output
    ]
    if missing_multi:
        raise RuntimeError(
            "RTL8C multi-store closure marker(s) missing: "
            + ", ".join(missing_multi)
        )
    print("RTL8C_MULTI_STORE_INTEGRATION=PASS")
    print("RTL8C5A_AGE_SOURCE_FOUNDATION=PASS")

    bypass_output = run(
        [sys.executable, "tests/run_rtl8c_load_bypass.py"],
        "RTL8C_SAFE_LOAD_BYPASS",
    )

    required_bypass = [
        "RTL8C5B1_YOUNGER_STORE_BLOCKED_BY_OLDER_LOAD=PASS",
        "RTL8C5B1_QUEUED_PARTIAL_FORWARD_NO_MISS=PASS",
        "RTL8C5B1_DEPENDENCY_OVERRIDE_RESPECTS_OLDER_MSHR=PASS",
        "RTL8C_CONFLICT_SURVIVES_QUEUE_TO_PHYSICAL=PASS",
        "RTL8C_PAUSE_PRESERVES_LOAD_ORDER_WAIT=PASS",
        "RTL8C_PHYSICAL_STORE_NONCONFLICT_LOAD_BYPASS=PASS",
        "RTL8C_PHYSICAL_STORE_LINE_CONFLICT_HOLD=PASS",
        "RTL8C_PHYSICAL_STORE_RESPONSE_NO_REPLAY_DEADLOCK=PASS",
        "RTL8C5B1_PROVISIONAL_WAIT_BEFORE_STORE_RESPONSE=PASS",
        "RTL8C5B1_DEPENDENCY_AGE_SAFE_STORE_DRAIN=PASS",
        "RTL8C5B1_FORWARD_SUCCESS_DATA=PASS",
        "RTL8C5B1_ALL_FORWARD_PROVISIONAL_NO_MISS=PASS",
        "RTL8C5B1_STORE_FAULT_REPLAYS_FORWARDED_LANES=PASS",
        "RTL8C5B1_STORE_FAULT_DISCARDS_PROVISIONAL_DATA=PASS",
        "RTL8C5B1_FAULT_SAFE_QUEUED_FORWARDING=PASS",
        "RTL8C5B2_PHYSICAL_PARTIAL_FORWARD_SINGLE_MISS=PASS",
        "RTL8C5B2_PHYSICAL_PROVISIONAL_WAIT_BEFORE_RESPONSE=PASS",
        "RTL8C5B2_PHYSICAL_FORWARD_SUCCESS_DATA=PASS",
        "RTL8C5B2_PHYSICAL_ALL_FORWARD_PROVISIONAL_NO_MISS=PASS",
        "RTL8C5B2_PHYSICAL_STORE_FAULT_REPLAYS_FORWARDED_LANES=PASS",
        "RTL8C5B2_PHYSICAL_STORE_FAULT_DISCARDS_PROVISIONAL_DATA=PASS",
        "RTL8C5B2_YOUNGEST_QUEUED_BEATS_PHYSICAL=PASS",
        "RTL8C5B2_OLDER_PHYSICAL_RESOLVE_IGNORED=PASS",
        "RTL8C5B2_RESPONSE_CYCLE_PHYSICAL_FORWARD_SUPPRESSED=PASS",
        "RTL8C5B2_RESPONSE_CYCLE_REPLAY_NO_DEADLOCK=PASS",
        "RTL8C5B2_DUPLICATE_PHYSICAL_SOURCE_AMBIGUOUS=PASS",
        "RTL8C5B2_FAULT_SAFE_PHYSICAL_FORWARDING=PASS",
        "RTL8C_SAFE_LOAD_BYPASS_TB=PASS",
        "RTL8C_SAFE_LOAD_BYPASS_DRIVER=PASS",
        "RTL8C5B1_QUEUED_FORWARDING_DRIVER=PASS",
        "RTL8C5B2_PHYSICAL_FORWARDING_DRIVER=PASS",
    ]
    missing_bypass = [
        marker for marker in required_bypass
        if marker not in bypass_output
    ]
    if missing_bypass:
        raise RuntimeError(
            "RTL8C safe-bypass closure marker(s) missing: "
            + ", ".join(missing_bypass)
        )
    print("RTL8C_SAFE_LOAD_BYPASS=PASS")

    run(
        [sys.executable, "tests/run_rtl8b_gate.py"],
        "RTL8B_FULL_REGRESSION_FROM_RTL8C",
    )
    print("RTL8B_FULL_REGRESSION_FROM_RTL8C=PASS")

    diff = subprocess.run(
        ["git", "diff", "--check"],
        cwd=ROOT,
        text=True,
        stdout=subprocess.PIPE,
        stderr=subprocess.STDOUT,
    )
    print(diff.stdout, end="")
    if diff.returncode != 0:
        raise RuntimeError("git diff --check failed")
    print("RTL8C_GIT_DIFF_CHECK=PASS")

    print()
    print("RTL8C_GATE=PASS")
    print("RTL8C_COMMIT_ALLOWED=YES")


if __name__ == "__main__":
    main()
