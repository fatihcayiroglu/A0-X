#!/usr/bin/env python3

from pathlib import Path

import shutil
import subprocess
import tempfile


ROOT = Path(__file__).resolve().parents[1]


def run_command(
    args,
    *,
    cwd,
):
    result = subprocess.run(
        args,
        cwd=cwd,
        text=True,
        stdout=subprocess.PIPE,
        stderr=subprocess.STDOUT,
    )

    if result.returncode != 0:
        print(result.stdout)

        raise RuntimeError(
            "Command failed: "
            + " ".join(
                str(arg)
                for arg in args
            )
        )

    return result.stdout


def main():

    verilator = shutil.which(
        "verilator"
    )

    if verilator is None:
        raise RuntimeError(
            "verilator was not found in PATH"
        )


    with tempfile.TemporaryDirectory(
        prefix="a0_rtl5b_scoreboard_"
    ) as temporary_directory:

        work = Path(
            temporary_directory
        )

        obj_dir = (
            work
            / "obj_dir"
        )


        output = run_command(
            [
                verilator,
                "--binary",
                "--timing",
                "-Wall",
                "-Wno-fatal",
                "-Werror-PINMISSING",
                "-Werror-WIDTHEXPAND",
                "-Wno-UNUSEDSIGNAL",
                "-Wno-UNUSEDPARAM",
                "-Wno-BLKSEQ",
                "-Wno-TIMESCALEMOD",
                "-Wno-WIDTHTRUNC",
                "--top-module",
                "a0_scoreboard_tb",
                "--Mdir",
                str(obj_dir),
                str(
                    ROOT
                    / "rtl"
                    / "core"
                    / "a0_scoreboard.sv"
                ),
                str(
                    ROOT
                    / "tests"
                    / "rtl"
                    / "a0_scoreboard_tb.sv"
                ),
            ],
            cwd=work,
        )


        executable = (
            obj_dir
            / "Va0_scoreboard_tb"
        )

        if not executable.exists():
            print(output)

            raise RuntimeError(
                "RTL5B scoreboard executable "
                "was not produced"
            )


        rtl_output = run_command(
            [
                str(executable),
            ],
            cwd=work,
        )

        print(
            rtl_output,
            end="",
        )


        required_markers = [
            "RTL5B_SCOREBOARD_TB=PASS",
            "VECTOR_RAW_HAZARD=PASS",
            "VECTOR_WAW_HAZARD=PASS",
            "VECTOR_SRC2_RAW_HAZARD=PASS",
            "VECTOR_NO_FALSE_HAZARD=PASS",
            "PREDICATE_RAW_HAZARD=PASS",
            "PREDICATE_WAW_HAZARD=PASS",
            "RESERVATION_RELEASE=PASS",
            "RELEASE_RESERVE_SAME_CYCLE=PASS",
            "INVALID_QUERY_BLOCKED=PASS",
        ]


        for marker in required_markers:

            if marker not in rtl_output:

                raise RuntimeError(
                    "RTL5B missing marker: "
                    + marker
                )


    print("RTL5B_SCOREBOARD_GATE=PASS")
    print("VECTOR_REG_COUNT=64")
    print("PREDICATE_REG_COUNT=16")
    print("RAW_CLASSIFICATION=PASS")
    print("WAW_CLASSIFICATION=PASS")
    print("NO_FALSE_HAZARD=PASS")


if __name__ == "__main__":
    main()
