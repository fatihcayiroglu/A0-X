#!/usr/bin/env python3

from pathlib import Path
import subprocess
import tempfile

ROOT = Path(__file__).resolve().parents[1]

SOURCES = [
    ROOT / "rtl/memory/a0_mshr_table.sv",
    ROOT / "rtl/memory/a0_wave_load_mshr_bridge.sv",
    ROOT / "tests/rtl/a0_wave_load_mshr_bridge_tb.sv",
]

MARKERS = [
    "RTL8B_BRIDGE_RESET=PASS",
    "RTL8B_BRIDGE_MULTI_LINE_ALLOC=PASS",
    "RTL8B_BRIDGE_OUT_OF_ORDER_REASSEMBLY=PASS",
    "RTL8B_BRIDGE_MERGE_WHILE_FULL=PASS",
    "RTL8B_BRIDGE_SAME_LINE_FANOUT=PASS",
    "RTL8B_LOAD_MSHR_BRIDGE_TB=PASS",
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
        prefix="a0_rtl8b_load_mshr_bridge_"
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
                "a0_wave_load_mshr_bridge_tb",
                "--Mdir",
                str(build_dir),
                *map(str, SOURCES),
            ]
        )
        output = run(
            [str(build_dir / "Va0_wave_load_mshr_bridge_tb")]
        )
        missing = [marker for marker in MARKERS if marker not in output]
        if missing:
            raise RuntimeError(
                "missing RTL8B bridge marker(s): " + ", ".join(missing)
            )

    print("RTL8B_LOAD_MSHR_BRIDGE_DRIVER=PASS")


if __name__ == "__main__":
    main()
