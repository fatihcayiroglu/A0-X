#!/usr/bin/env python3

from pathlib import Path
import subprocess
import tempfile

ROOT = Path(__file__).resolve().parents[1]
RTL = ROOT / "rtl/memory/a0_mshr_table.sv"
TB = ROOT / "tests/rtl/a0_mshr_capacity_tb.sv"
COUNTS = (2, 4, 8, 16, 32)


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
    for count in COUNTS:
        with tempfile.TemporaryDirectory(
            prefix=f"a0_rtl8a_mshr_capacity_{count}_"
        ) as temp_dir:
            obj = Path(temp_dir) / "obj_dir"
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
                    "a0_mshr_capacity_tb",
                    f"-GMSHR_COUNT={count}",
                    "--Mdir",
                    str(obj),
                    str(RTL),
                    str(TB),
                ]
            )
            simulation = run([str(obj / "Va0_mshr_capacity_tb")])
            marker = f"RTL8A_MSHR_CAPACITY=PASS count={count}"
            if marker not in simulation:
                raise RuntimeError(f"missing marker: {marker}")

    print("RTL8A_MSHR_CAPACITY_SWEEP=PASS counts=2,4,8,16,32")


if __name__ == "__main__":
    main()
