#!/usr/bin/env python3

from pathlib import Path
import subprocess
import tempfile

ROOT = Path(__file__).resolve().parents[1]
RTL = ROOT / "rtl/memory/a0_mshr_table.sv"
TB = ROOT / "tests/rtl/a0_mshr_table_tb.sv"

MARKERS = [
    "RTL8A_MSHR_RESET=PASS",
    "RTL8A_MSHR_SAME_LINE_MERGE=PASS",
    "RTL8A_MSHR_DUPLICATE_WAITER_GUARD=PASS",
    "RTL8A_MSHR_FULL_BACKPRESSURE=PASS",
    "RTL8A_MSHR_MERGE_WHILE_FULL=PASS",
    "RTL8A_MSHR_UNIQUE_MISS_ISSUE=PASS",
    "RTL8A_MSHR_RESPONSE_TAG_GUARD=PASS",
    "RTL8A_MSHR_OUT_OF_ORDER_RESPONSE=PASS",
    "RTL8A_MSHR_ENTRY_REUSE=PASS",
    "RTL8A_MSHR_DRAINING_LINE_GUARD=PASS",
    "RTL8A_MSHR_WAITER_DRAIN=PASS",
    "RTL8A_MSHR_FAULT_FANOUT=PASS",
    "RTL8A_MSHR_SAME_CYCLE_ISSUE_RESPONSE=PASS",
    "RTL8A_MSHR_TABLE_TB=PASS",
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
            f"command failed ({result.returncode}): "
            + " ".join(map(str, command))
        )
    return result.stdout


def main():
    with tempfile.TemporaryDirectory(prefix="a0_rtl8a_mshr_") as temp_dir:
        obj = Path(temp_dir) / "obj_dir"
        output = run(
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
                "a0_mshr_table_tb",
                "--Mdir",
                str(obj),
                str(RTL),
                str(TB),
            ]
        )
        del output
        simulation = run([str(obj / "Va0_mshr_table_tb")])
        missing = [marker for marker in MARKERS if marker not in simulation]
        if missing:
            raise RuntimeError("missing marker(s): " + ", ".join(missing))
        print("RTL8A_MSHR_DIRECTED_DRIVER=PASS")


if __name__ == "__main__":
    main()
