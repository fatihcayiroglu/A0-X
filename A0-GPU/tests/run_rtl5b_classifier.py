#!/usr/bin/env python3

from pathlib import Path

import shutil
import subprocess
import tempfile


ROOT = Path(__file__).resolve().parents[1]


def run_command(args, *, cwd):

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
        prefix="a0_rtl5b_classifier_"
    ) as temporary_directory:

        work = Path(
            temporary_directory
        )

        obj_dir = work / "obj_dir"

        build_output = run_command(
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
                "a0_dependency_classifier_tb",
                "--Mdir",
                str(obj_dir),
                str(
                    ROOT
                    / "rtl/core/a0_scoreboard.sv"
                ),
                str(
                    ROOT
                    / "rtl/core/a0_dependency_classifier.sv"
                ),
                str(
                    ROOT
                    / "tests/rtl/a0_dependency_classifier_tb.sv"
                ),
            ],
            cwd=work,
        )

        executable = (
            obj_dir
            / "Va0_dependency_classifier_tb"
        )

        if not executable.exists():
            print(build_output)

            raise RuntimeError(
                "RTL5B classifier executable "
                "was not produced"
            )

        rtl_output = run_command(
            [str(executable)],
            cwd=work,
        )

        print(
            rtl_output,
            end="",
        )

        required_markers = [
            "RTL5B_CLASSIFIER_TB=PASS",
            "ALU_DEPENDENCY_CLASS=PASS",
            "PREDICATED_ALU_CLASS=PASS",
            "COMPARE_PREDICATE_DEST=PASS",
            "VLOADX_DEPENDENCY_CLASS=PASS",
            "VSTOREX_DEPENDENCY_CLASS=PASS",
            "SPLIT_PREDICATE_SOURCE=PASS",
            "CLASSIFIER_SCOREBOARD_RAW=PASS",
            "CLASSIFIER_SCOREBOARD_WAW=PASS",
            "CLASSIFIER_SCOREBOARD_PRED_RAW=PASS",
            "CLASSIFIER_SCOREBOARD_PRED_WAW=PASS",
            "UNTRACKED_OPCODE_BLOCKED=PASS",
        ]

        for marker in required_markers:

            if marker not in rtl_output:

                raise RuntimeError(
                    "RTL5B missing classifier marker: "
                    + marker
                )


    print("RTL5B_CLASSIFIER_GATE=PASS")
    print("VECTOR_DEPENDENCY_DECODE=PASS")
    print("PREDICATE_DEPENDENCY_DECODE=PASS")
    print("CLASSIFIER_SCOREBOARD_INTEGRATION=PASS")


if __name__ == "__main__":
    main()
