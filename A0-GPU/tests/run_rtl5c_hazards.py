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


def write_hex(path, values, width):

    mask = (1 << (width * 4)) - 1

    path.write_text(
        "".join(
            f"{value & mask:0{width}x}\n"
            for value in values
        )
    )


def run(args, cwd):

    result = subprocess.run(
        args,
        cwd=cwd,
        text=True,
        stdout=subprocess.PIPE,
        stderr=subprocess.STDOUT,
    )

    if result.returncode != 0:

        print(
            result.stdout
        )

        raise RuntimeError(
            "Command failed: "
            + " ".join(
                str(x)
                for x in args
            )
        )

    return result.stdout


def main():

    verilator = shutil.which(
        "verilator"
    )

    if verilator is None:
        raise RuntimeError(
            "verilator not found"
        )


    program = assemble_source(
        """
        VADD V3, V1, V2
        VXOR V4, V5, V6
        VADD V7, V4, V1
        VADD V8, V1, V2
        VXOR V8, V5, V6
        VCMP_LT P3, V1, V2
        @P3 VADD V9, V1, V2
        HALT
        """
    )


    if len(program) != 8:
        raise RuntimeError(
            "RTL5C Phase2 expected 8 program words"
        )


    halt_word = assemble_source(
        "HALT"
    )[0]


    padded = (
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
        prefix="a0_rtl5c_hazards_"
    ) as temp:

        work = Path(temp)

        obj = (
            work
            / "obj_dir"
        )


        write_hex(
            work / "program.hex",
            padded,
            16,
        )


        build_output = run(
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
                "a0_wave_core_rtl5c_hazards_tb",

                "--Mdir",
                str(obj),

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
                    / "tests/rtl/a0_wave_core_rtl5c_hazards_tb.sv"
                ),
            ],
            work,
        )


        exe = (
            obj
            / "Va0_wave_core_rtl5c_hazards_tb"
        )


        if not exe.exists():

            print(
                build_output
            )

            raise RuntimeError(
                "RTL5C Phase2 executable missing"
            )


        output = run(
            [str(exe)],
            work,
        )


        print(
            output,
            end="",
        )


        required = [
            "RTL5C_PHASE2_TB=PASS",

            "VECTOR_ISSUES=7",
            "VECTOR_RETIREMENTS=7",
            "INDEPENDENT_HANDOFFS=3",

            "VECTOR_WAW_PENDING_HAZARD=PASS",
            "VECTOR_WAW_HANDOFF_BLOCKED=PASS",
            "VECTOR_WAW_ISSUE_AFTER_RELEASE=PASS",
            "WAW_EXTRA_BUBBLE_CYCLES=1",

            "PREDICATE_RAW_PENDING_HAZARD=PASS",
            "PREDICATE_RAW_HANDOFF_BLOCKED=PASS",
            "PREDICATE_RAW_ISSUE_AFTER_RELEASE=PASS",
            "PREDICATE_RAW_EXTRA_BUBBLE_CYCLES=1",

            "PHASE2_ARCHITECTURAL_RESULT_MATCH=PASS",
            "PHASE2_SCOREBOARDS_EMPTY=PASS",
        ]


        for marker in required:

            if marker not in output:

                raise RuntimeError(
                    "Missing RTL5C Phase2 marker: "
                    + marker
                )


    print(
        "RTL5C_PHASE2_HAZARD_GATE=PASS"
    )

    print(
        "LIVE_VECTOR_WAW_STALL=PASS"
    )

    print(
        "LIVE_PREDICATE_RAW_STALL=PASS"
    )


if __name__ == "__main__":
    main()
