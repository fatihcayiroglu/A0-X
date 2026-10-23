#!/usr/bin/env python3

from pathlib import Path

import shutil
import subprocess
import sys
import tempfile


ROOT = Path(__file__).resolve().parents[1]
SIM = ROOT / "sim"

sys.path.insert(
    0,
    str(SIM),
)

from a0_asm import assemble_source


PROGRAM_WORDS = 16


def write_hex(
    path,
    values,
    width,
):
    mask = (
        1 << (width * 4)
    ) - 1

    path.write_text(
        "".join(
            f"{value & mask:0{width}x}\n"
            for value in values
        )
    )


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


    program = assemble_source(
        """
        VADD V3, V1, V2
        VCMP_LT P2, V1, V2
        @P2 VADD V4, V1, V2
        HALT
        """
    )


    if len(program) != 4:
        raise RuntimeError(
            "RTL5B expected exactly "
            "four program words"
        )


    halt_word = assemble_source(
        "HALT"
    )[0]


    padded_program = (
        list(program)
        + [
            halt_word
            for _ in range(
                PROGRAM_WORDS
                - len(program)
            )
        ]
    )


    with tempfile.TemporaryDirectory(
        prefix="a0_rtl5b_core_"
    ) as temporary_directory:

        work = Path(
            temporary_directory
        )

        obj_dir = (
            work
            / "obj_dir"
        )


        write_hex(
            work / "program.hex",
            padded_program,
            16,
        )


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
                "a0_wave_core_rtl5b_tb",
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
                    / "rtl/core/a0_lane_sequencer.sv"
                ),
                str(ROOT / "rtl" / "core" / "a0_regfile_banked.sv"),
                str(ROOT / "rtl" / "core" / "a0_operand_collector.sv"),
                str(ROOT / "rtl" / "core" / "a0_vector_operand_path.sv"),

                str(
                    ROOT
                    / "rtl/core/a0_wave_core.sv"
                ),

                str(
                    ROOT
                    / "tests/rtl/a0_wave_core_rtl5b_tb.sv"
                ),
            ],
            cwd=work,
        )


        executable = (
            obj_dir
            / "Va0_wave_core_rtl5b_tb"
        )


        if not executable.exists():

            print(build_output)

            raise RuntimeError(
                "RTL5B core executable "
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
            "RTL5B_CORE_TB=PASS",
            "CORE_VECTOR_ISSUES=3",
            "CORE_VECTOR_RETIREMENTS=3",
            "VECTOR_DEST_RESERVATION=PASS",
            "PREDICATE_DEST_RESERVATION=PASS",
            "BUSY_HELD_UNTIL_RETIRE=PASS",
            "RETIRE_RELEASE=PASS",
            "PREDICATE_SOURCE_NOT_RESERVED=PASS",
            "CORE_FALSE_STALLS=0",
            "ARCHITECTURAL_RESULT_MATCH=PASS",
        ]


        for marker in required_markers:

            if marker not in rtl_output:

                raise RuntimeError(
                    "RTL5B missing core marker: "
                    + marker
                )


    print(
        "RTL5B_CORE_INTEGRATION_GATE=PASS"
    )

    print(
        "CLASSIFIER_LIVE_CORE=PASS"
    )

    print(
        "SCOREBOARD_LIVE_CORE=PASS"
    )

    print(
        "ISSUE_RESERVE_RETIRE_RELEASE=PASS"
    )


if __name__ == "__main__":
    main()
