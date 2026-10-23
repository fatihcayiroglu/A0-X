#!/usr/bin/env python3

from pathlib import Path
import subprocess
import tempfile

ROOT = Path(__file__).resolve().parents[1]

SOURCES = [
    ROOT / "rtl/core/a0_scoreboard.sv",
    ROOT / "rtl/core/a0_dependency_classifier.sv",
    ROOT / "rtl/core/a0_lane_sequencer.sv",
    ROOT / "rtl/core/a0_operand_collector.sv",
    ROOT / "rtl/core/a0_regfile_banked_contexted.sv",
    ROOT / "rtl/core/a0_vector_operand_path_contexted.sv",
    ROOT / "rtl/scheduler/a0_wave_context_file.sv",
    ROOT / "rtl/scheduler/a0_wave_scheduler.sv",
    ROOT / "rtl/scheduler/a0_multi_wave_frontend.sv",
    ROOT / "rtl/scheduler/a0_wave_scoreboard_bank.sv",
    ROOT / "rtl/memory/a0_mshr_table.sv",
    ROOT / "rtl/memory/a0_wave_load_mshr_bridge.sv",
    ROOT / "rtl/memory/a0_store_queue.sv",
    ROOT / "rtl/memory/a0_l1_line_cache.sv",
    ROOT / "rtl/memory/a0_memory_service_boundary.sv",
    ROOT / "rtl/core/a0_multi_wave_core.sv",
    ROOT / "tests/rtl/a0_multi_wave_core_rtl7c_memory_edges_tb.sv",
]

MARKERS = [
    "RTL7C_ALL_MASKED_MEMORY_NOOP=PASS",
    "RTL7C_ADDRESS_FAULT_NO_ACCESS=PASS",
    "RTL7C_BACKEND_FAULT_COMPLETION=PASS",
    "RTL7C_MEMORY_EDGE_TB=PASS",
]


def run(command):
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
            + " ".join(map(str, command))
        )
    return result.stdout


def main():
    with tempfile.TemporaryDirectory(
        prefix="a0_rtl7c_memory_edges_"
    ) as temp_dir:
        build_dir = Path(temp_dir) / "obj_dir"

        run(
            [
                "verilator",
                "--binary",
                "--timing",
                "-Wall",
                "-Wno-BLKSEQ",
                "-Wno-UNUSEDSIGNAL",
                "-Wno-UNUSEDPARAM",
                "-Werror-PINMISSING",
                "-Werror-WIDTHEXPAND",
                "-Werror-WIDTHTRUNC",
                "--top-module",
                "a0_multi_wave_core_rtl7c_memory_edges_tb",
                "--Mdir",
                str(build_dir),
                *map(str, SOURCES),
            ]
        )

        output = run(
            [
                str(
                    build_dir
                    / "Va0_multi_wave_core_rtl7c_memory_edges_tb"
                )
            ]
        )

        missing = [
            marker
            for marker in MARKERS
            if marker not in output
        ]
        if missing:
            raise RuntimeError(
                "missing RTL7C edge marker(s): "
                + ", ".join(missing)
            )

    print("RTL7C_MEMORY_EDGE_DRIVER=PASS")


if __name__ == "__main__":
    main()
