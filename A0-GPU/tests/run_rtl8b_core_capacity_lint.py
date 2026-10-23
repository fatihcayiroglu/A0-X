#!/usr/bin/env python3
"""Strict parameter elaboration/lint sweep for the RTL8B live core."""

from pathlib import Path
import subprocess

ROOT = Path(__file__).resolve().parents[1]

COUNTS = (2, 4, 8, 16, 32)

SOURCES = [
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


def run(command: list[str]) -> None:
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
            "command failed with exit code "
            f"{result.returncode}: "
            + " ".join(command)
        )


def main() -> None:
    for count in COUNTS:
        run(
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
                f"-GMSHR_COUNT={count}",
                *SOURCES,
            ]
        )
        print(f"RTL8B_CORE_MSHR_CAPACITY=PASS count={count}")

    print("RTL8B_CORE_MSHR_CAPACITY_SWEEP=PASS counts=2,4,8,16,32")


if __name__ == "__main__":
    main()
