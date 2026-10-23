#!/usr/bin/env python3
"""RTL8C behavioral + lint STORE_QUEUE_DEPTH sweep."""

from __future__ import annotations

from pathlib import Path
import subprocess
import tempfile


ROOT = Path(__file__).resolve().parents[1]
DEPTHS = (1, 2, 3, 4, 5, 8, 16)

CORE_SOURCES = [
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
]

CAPACITY_SOURCES = [
    ROOT / "rtl/memory/a0_store_queue.sv",
    ROOT / "tests/rtl/a0_store_queue_capacity_tb.sv",
]


def run(command: list[str]) -> str:
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
            f"command failed with exit code {result.returncode}: "
            + " ".join(command)
        )
    return result.stdout


def main() -> None:
    for depth in DEPTHS:
        print()
        print("=" * 60)
        print(f"RTL8C STORE QUEUE CAPACITY depth={depth}")
        print("=" * 60)

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
                f"-GSTORE_QUEUE_DEPTH={depth}",
                *map(str, CORE_SOURCES),
            ]
        )
        print(f"RTL8C_STORE_QUEUE_DEPTH_LINT=PASS depth={depth}")

        with tempfile.TemporaryDirectory(
            prefix=f"a0_rtl8c_store_capacity_{depth}_"
        ) as td:
            obj_dir = Path(td) / "obj_dir"
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
                    "a0_store_queue_capacity_tb",
                    f"-GSTORE_QUEUE_DEPTH={depth}",
                    "--Mdir",
                    str(obj_dir),
                    *map(str, CAPACITY_SOURCES),
                ]
            )
            output = run(
                [str(obj_dir / "Va0_store_queue_capacity_tb")]
            )

        markers = [
            f"RTL8C_STORE_QUEUE_CAPACITY_FILL=PASS depth={depth}",
            f"RTL8C_STORE_QUEUE_POINTER_WRAP=PASS depth={depth}",
            (
                "RTL8C_STORE_QUEUE_SIMULTANEOUS_HANDSHAKE=PASS "
                f"depth={depth}"
            ),
            f"RTL8C_STORE_QUEUE_CAPACITY_TB=PASS depth={depth}",
        ]
        missing = [marker for marker in markers if marker not in output]
        if missing:
            raise RuntimeError(
                f"depth={depth} missing capacity marker(s): "
                + ", ".join(missing)
            )

        print(f"RTL8C_STORE_QUEUE_DEPTH_RUNTIME=PASS depth={depth}")

    depth_text = ",".join(map(str, DEPTHS))
    print(
        "RTL8C_STORE_QUEUE_DEPTH_LINT_SWEEP=PASS "
        f"depths={depth_text}"
    )
    print(
        "RTL8C_STORE_QUEUE_DEPTH_RUNTIME_SWEEP=PASS "
        f"depths={depth_text}"
    )
    print("RTL8C_STORE_QUEUE_CAPACITY_DRIVER=PASS")


if __name__ == "__main__":
    main()
