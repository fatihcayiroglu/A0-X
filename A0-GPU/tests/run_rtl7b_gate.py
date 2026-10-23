#!/usr/bin/env python3
"""A0 RTL7B live multi-wave execution full gate."""

from pathlib import Path
import subprocess

ROOT = Path(__file__).resolve().parents[1]


def run(name, command):
    print()
    print(f"=== {name} ===", flush=True)
    result = subprocess.run(command, cwd=ROOT, text=True)
    if result.returncode != 0:
        raise RuntimeError(
            f"{name} failed with exit code {result.returncode}"
        )
    print(f"{name}=PASS", flush=True)


def main():
    run(
        "RTL7B_PYTHON_COMPILE",
        [
            "python3",
            "-m",
            "py_compile",
            "tests/run_rtl7b_live_multi_wave.py",
            "tests/run_rtl7b_context_vrf_diff.py",
            "tests/run_rtl7b_scoreboard_bank.py",
            "tests/run_rtl7b_context_regfile.py",
            "tests/run_rtl7b_gate.py",
        ],
    )

    run(
        "RTL7B_PRODUCTION_LINT",
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
        ],
    )

    run(
        "RTL7B_WAVE_SCOREBOARD_BANK",
        ["python3", "tests/run_rtl7b_scoreboard_bank.py"],
    )

    run(
        "RTL7B_CONTEXTED_REGFILE",
        ["python3", "tests/run_rtl7b_context_regfile.py"],
    )

    run(
        "RTL7B_CONTEXT_VRF_10K_DIFF",
        ["python3", "tests/run_rtl7b_context_vrf_diff.py"],
    )

    run(
        "RTL7B_LIVE_MULTI_WAVE",
        ["python3", "tests/run_rtl7b_live_multi_wave.py"],
    )

    # RTL7A recursively includes SIM17 -> SIM16 -> SIM15 -> RTL6B -> RTL6
    # and the complete historical RTL/Python regression chain.
    run(
        "RTL7A_FULL_REGRESSION",
        ["python3", "tests/run_rtl7_gate.py"],
    )

    run(
        "RTL7B_GIT_DIFF_CHECK",
        ["git", "diff", "--check"],
    )

    print()
    print("RTL7B_GATE=PASS")
    print("RTL7B_COMMIT_ALLOWED=YES")


if __name__ == "__main__":
    main()
