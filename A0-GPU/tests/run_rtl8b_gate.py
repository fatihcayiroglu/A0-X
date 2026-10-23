#!/usr/bin/env python3
"""A0 RTL8B live MSHR integration full verification gate."""

from __future__ import annotations

from pathlib import Path
import subprocess

ROOT = Path(__file__).resolve().parents[1]


PRODUCTION_SOURCES = [
    "rtl/core/a0_scoreboard.sv",
    "rtl/core/a0_dependency_classifier.sv",
    "rtl/core/a0_lane_sequencer.sv",
    "rtl/core/a0_operand_collector.sv",
    "rtl/core/a0_regfile_banked_contexted.sv",
    "rtl/core/a0_vector_operand_path_contexted.sv",
    "rtl/scheduler/a0_wave_context_file.sv",
    "rtl/scheduler/a0_wave_scheduler.sv",
    "rtl/scheduler/a0_multi_wave_frontend.sv",
    "rtl/scheduler/a0_wave_scoreboard_bank.sv",
    "rtl/memory/a0_mshr_table.sv",
    "rtl/memory/a0_wave_load_mshr_bridge.sv",
    "rtl/memory/a0_store_queue.sv",
    "rtl/memory/a0_l1_line_cache.sv",
    "rtl/memory/a0_memory_service_boundary.sv",
    "rtl/core/a0_multi_wave_core.sv",
]


def run(name: str, command: list[str]) -> None:
    print()
    print(f"=== {name} ===", flush=True)
    result = subprocess.run(command, cwd=ROOT, text=True)
    if result.returncode != 0:
        raise RuntimeError(
            f"{name} failed with exit code {result.returncode}"
        )
    print(f"{name}=PASS", flush=True)


def main() -> None:
    run(
        "RTL8B_PYTHON_COMPILE",
        [
            "python3",
            "-m",
            "py_compile",
            "tests/run_rtl8b_load_mshr_bridge.py",
            "tests/run_rtl8b_live_mshr.py",
            "tests/run_rtl8b_mshr_edges.py",
            "tests/run_rtl8b_store_serialization.py",
            "tests/run_rtl8b_core_capacity_lint.py",
            "tests/run_rtl8b_gate.py",
            "tests/run_rtl7b_live_multi_wave.py",
            "tests/run_rtl7b_gate.py",
            "tests/run_rtl7c_live_memory.py",
            "tests/run_rtl7c_memory_edges.py",
            "tests/run_rtl7c_gate.py",
        ],
    )

    run(
        "RTL8B_PRODUCTION_LINT",
        [
            "verilator",
            "--lint-only",
            "--timing",
            "-Wall",
            "-Wno-BLKSEQ",
            "-Wno-UNUSEDSIGNAL",
            "-Wno-UNUSEDPARAM",
            "-Werror-PINMISSING",
            "-Werror-WIDTHEXPAND",
            "-Werror-WIDTHTRUNC",
            "--top-module",
            "a0_multi_wave_core",
            *PRODUCTION_SOURCES,
        ],
    )

    run(
        "RTL8B_LOAD_MSHR_BRIDGE",
        ["python3", "tests/run_rtl8b_load_mshr_bridge.py"],
    )

    run(
        "RTL8B_LIVE_MSHR_CORE",
        ["python3", "tests/run_rtl8b_live_mshr.py"],
    )

    run(
        "RTL8B_MSHR_INTEGRATION_EDGES",
        ["python3", "tests/run_rtl8b_mshr_edges.py"],
    )

    run(
        "RTL8B_STORE_SERIALIZATION",
        ["python3", "tests/run_rtl8b_store_serialization.py"],
    )

    run(
        "RTL8B_CORE_MSHR_CAPACITY_SWEEP",
        ["python3", "tests/run_rtl8b_core_capacity_lint.py"],
    )

    # RTL8A recursively runs RTL7C -> RTL7B -> RTL7A -> SIM17 -> ...
    run(
        "RTL8A_FULL_REGRESSION",
        ["python3", "tests/run_rtl8a_gate.py"],
    )

    run(
        "RTL8B_GIT_DIFF_CHECK",
        ["git", "diff", "--check"],
    )

    print()
    print("RTL8B_GATE=PASS")
    print("RTL8B_COMMIT_ALLOWED=YES")


if __name__ == "__main__":
    main()
