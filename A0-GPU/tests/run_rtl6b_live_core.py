#!/usr/bin/env python3

from __future__ import annotations

import subprocess
import tempfile
from pathlib import Path


ROOT = Path(__file__).resolve().parents[1]

REQUIRED_MARKERS = [
    "RTL6B_BANKED_SOURCE_PROOF=PASS",
    "RTL6B_SAME_BANK_CONFLICT=PASS",
    "RTL6B_LOAD_TO_ALU_REFILL=PASS",
    "RTL6B_REFILL_ISSUE_ISOLATION=PASS",
    "RTL6B_RELEASE_ENABLE_LATCH=PASS",
    "RTL6B_LIVE_CORE_TB=PASS",
]


def run(command: list[str], cwd: Path) -> str:
    result = subprocess.run(
        command,
        cwd=cwd,
        text=True,
        stdout=subprocess.PIPE,
        stderr=subprocess.STDOUT,
        check=False,
    )

    if result.returncode != 0:
        print(result.stdout)
        raise RuntimeError(
            f"command failed with exit code {result.returncode}: "
            + " ".join(command)
        )

    return result.stdout


def main() -> None:
    with tempfile.TemporaryDirectory(prefix="a0_rtl6b_live_") as temp:
        work = Path(temp)
        obj = work / "obj_dir"

        sources = [
            ROOT / "rtl/core/a0_scoreboard.sv",
            ROOT / "rtl/core/a0_dependency_classifier.sv",
            ROOT / "rtl/core/a0_lane_sequencer.sv",
            ROOT / "rtl/core/a0_regfile_banked.sv",
            ROOT / "rtl/core/a0_operand_collector.sv",
            ROOT / "rtl/core/a0_vector_operand_path.sv",
            ROOT / "rtl/core/a0_wave_core.sv",
            ROOT / "tests/rtl/a0_wave_core_rtl6b_tb.sv",
        ]

        build = run(
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
                "a0_wave_core_rtl6b_tb",
                "--Mdir",
                str(obj),
                *map(str, sources),
            ],
            ROOT,
        )

        executable = obj / "Va0_wave_core_rtl6b_tb"
        if not executable.exists():
            print(build)
            raise RuntimeError("RTL6B Verilator executable missing")

        output = run([str(executable)], ROOT)
        print(output, end="")

        missing = [
            marker for marker in REQUIRED_MARKERS if marker not in output
        ]
        if missing:
            raise RuntimeError(
                "RTL6B missing required markers: " + ", ".join(missing)
            )

        print("RTL6B_LIVE_CORE_DRIVER=PASS")


if __name__ == "__main__":
    main()
