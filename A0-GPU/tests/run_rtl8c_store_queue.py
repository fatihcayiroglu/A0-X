#!/usr/bin/env python3
"""A0 RTL8C standalone whole-wave store queue verification."""

from __future__ import annotations

from pathlib import Path
import subprocess
import tempfile

ROOT = Path(__file__).resolve().parents[1]

SOURCES = [
    ROOT / "rtl/memory/a0_store_queue.sv",
    ROOT / "tests/rtl/a0_store_queue_tb.sv",
]


def run(command: list[str]) -> subprocess.CompletedProcess[str]:
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
    return result


def main() -> None:
    with tempfile.TemporaryDirectory(prefix="a0_rtl8c_store_queue_") as td:
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
                "a0_store_queue_tb",
                "--Mdir",
                str(obj_dir),
                *(str(source) for source in SOURCES),
            ]
        )

        simulation = run([str(obj_dir / "Va0_store_queue_tb")])

        required = [
            "RTL8C_STORE_QUEUE_RESET=PASS",
            "RTL8C_STORE_QUEUE_ENQUEUE_METADATA_DATA=PASS",
            "RTL8C_STORE_QUEUE_ACTIVE_WAVE_GUARD=PASS",
            "RTL8C_STORE_QUEUE_FULL_BACKPRESSURE=PASS",
            "RTL8C_STORE_QUEUE_CONFLICT_PROBE=PASS",
            "RTL8C_STORE_QUEUE_LINE_CONFLICT_PROBE=PASS",
            "RTL8C_STORE_QUEUE_FIFO_ORDER=PASS",
            "RTL8C_STORE_QUEUE_WAVE_REUSE_AFTER_DRAIN=PASS",
            "RTL8C_STORE_QUEUE_FINAL_DRAIN=PASS",
            "RTL8C_STORE_QUEUE_TB=PASS",
        ]

        missing = [
            marker for marker in required
            if marker not in simulation.stdout
        ]
        if missing:
            raise RuntimeError(
                "missing RTL8C store queue PASS markers: "
                + ", ".join(missing)
            )

    print("RTL8C_STORE_QUEUE_DRIVER=PASS")


if __name__ == "__main__":
    main()
