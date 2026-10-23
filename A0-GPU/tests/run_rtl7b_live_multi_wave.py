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
    ROOT / "tests/rtl/a0_multi_wave_core_rtl7b_tb.sv",
]

MARKERS = [
    "RTL7B_VRF_OWNERSHIP_GUARD=PASS",
    "RTL7B_TWO_RESIDENT_WAVES=PASS",
    "RTL7B_PAUSE_PRESERVES_INFLIGHT=PASS",
    "RTL7B_INTERLEAVED_RETIRE=PASS",
    "RTL7B_CONTEXTED_VRF_CONFLICT=PASS",
    "RTL7B_SCALAR_PC_EXEC_ISOLATION=PASS",
    "RTL7B_PREDICATE_ISOLATION=PASS",
    "RTL7B_VECTOR_CONTEXT_ISOLATION=PASS",
    "RTL7B_EXEC_PREDICATION_ISOLATION=PASS",
    "RTL7B_WAVE_QUALIFIED_SCOREBOARD=PASS",
    "RTL7B_LIVE_MULTI_WAVE_CORE_TB=PASS",
]


def run(command, cwd=ROOT):
    result = subprocess.run(
        command,
        cwd=cwd,
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
        prefix="a0_rtl7b_live_multi_wave_"
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
                "a0_multi_wave_core_rtl7b_tb",
                "--Mdir",
                str(build_dir),
                *map(str, SOURCES),
            ]
        )

        output = run(
            [str(build_dir / "Va0_multi_wave_core_rtl7b_tb")]
        )

        missing = [
            marker for marker in MARKERS if marker not in output
        ]
        if missing:
            raise RuntimeError(
                "missing RTL7B marker(s): " + ", ".join(missing)
            )

    print("RTL7B_LIVE_MULTI_WAVE_DRIVER=PASS")


if __name__ == "__main__":
    main()
