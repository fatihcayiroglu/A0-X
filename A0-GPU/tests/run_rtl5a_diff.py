#!/usr/bin/env python3

from pathlib import Path

import contextlib
import io
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
from a0_sim import A0GPU, WAVE_SIZE


VECTOR_REG_COUNT = 64
PROGRAM_WORDS = 16


def write_hex(
    path,
    values,
    width,
):
    mask = (1 << (width * 4)) - 1

    path.write_text(
        "".join(
            f"{value & mask:0{width}x}\n"
            for value in values
        )
    )


def read_hex(
    path,
    expected_count,
):
    values = [
        int(line.strip(), 16)
        for line in path.read_text().splitlines()
        if line.strip()
    ]

    if len(values) != expected_count:
        raise RuntimeError(
            f"{path.name}: expected "
            f"{expected_count} values, "
            f"found {len(values)}"
        )

    return values


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
        VCMP_LT P1, V1, V2
        @P1 VADD V3, V1, V2
        HALT
        """
    )

    mutation_word = assemble_source(
        "VXOR V3, V1, V2"
    )[0]

    halt_word = assemble_source(
        "HALT"
    )[0]


    if len(program) != 3:
        raise RuntimeError(
            "RTL5A expected exactly 3 program words"
        )


    if (
        (program[1] >> 56) & 0xFF
    ) != 0x01:
        raise RuntimeError(
            "RTL5A target instruction is not VADD"
        )


    if (
        (mutation_word >> 56) & 0xFF
    ) != 0x06:
        raise RuntimeError(
            "RTL5A mutation instruction is not VXOR"
        )


    if (
        (program[1] >> 52) & 0x1
    ) != 1:
        raise RuntimeError(
            "RTL5A target VADD is not predicated"
        )


    if (
        (program[1] >> 24) & 0xF
    ) != 1:
        raise RuntimeError(
            "RTL5A target predicate is not P1"
        )


    initial_vector = [
        [
            0
            for _ in range(WAVE_SIZE)
        ]
        for _ in range(VECTOR_REG_COUNT)
    ]


    for lane in range(WAVE_SIZE):

        initial_vector[1][lane] = (
            lane + 1
        )

        initial_vector[2][lane] = 17

        initial_vector[3][lane] = (
            0xDEADBEEF
        )


    gpu = A0GPU(
        wave_id=0,
    )

    gpu.load_program(
        list(program)
    )


    for reg in range(VECTOR_REG_COUNT):

        for lane in range(WAVE_SIZE):

            gpu.vector_regs[
                reg
            ][lane] = initial_vector[
                reg
            ][lane]


    steps = 0

    with contextlib.redirect_stdout(
        io.StringIO()
    ):

        while not gpu.halted:

            gpu.step()

            steps += 1

            if steps > 32:
                raise RuntimeError(
                    "RTL5A Python golden model "
                    "did not halt"
                )


    expected_v3 = [
        gpu.vector_regs[3][lane]
        & 0xFFFFFFFF
        for lane in range(WAVE_SIZE)
    ]


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
        prefix="a0_rtl5a_"
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

        write_hex(
            work / "mutation.hex",
            [mutation_word],
            16,
        )


        verilator_output = run_command(
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
                "a0_wave_core_rtl5a_tb",
                "--Mdir",
                str(obj_dir),
                str(ROOT / "rtl" / "core" / "a0_scoreboard.sv"),
                str(ROOT / "rtl" / "core" / "a0_dependency_classifier.sv"),
                str(
                    ROOT
                    / "rtl"
                    / "core"
                    / "a0_lane_sequencer.sv"
                ),
                str(ROOT / "rtl" / "core" / "a0_regfile_banked.sv"),
                str(ROOT / "rtl" / "core" / "a0_operand_collector.sv"),
                str(ROOT / "rtl" / "core" / "a0_vector_operand_path.sv"),
                str(
                    ROOT
                    / "rtl"
                    / "core"
                    / "a0_wave_core.sv"
                ),
                str(
                    ROOT
                    / "tests"
                    / "rtl"
                    / "a0_wave_core_rtl5a_tb.sv"
                ),
            ],
            cwd=work,
        )


        executable = (
            obj_dir
            / "Va0_wave_core_rtl5a_tb"
        )


        if not executable.exists():
            print(verilator_output)

            raise RuntimeError(
                "RTL5A Verilator executable "
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
            "RTL5A_TB=PASS",
            "PHYSICAL_LANES=8",
            "ISSUED_OPCODE_LATCHED=PASS",
            "ISSUED_METADATA_LATCHED=PASS",
            "PROGRAM_MEMORY_MUTATION=PASS",
            "LIVE_DECODE_INDEPENDENCE=PASS",
            "PAUSE_STATE_STABLE=PASS",
            "NO_EARLY_VECTOR_WRITE=PASS",
            "VECTOR_PC_HOLD=PASS",
            "SINGLE_RETIREMENT=PASS",
        ]


        for marker in required_markers:

            if marker not in rtl_output:

                raise RuntimeError(
                    "RTL5A missing marker: "
                    + marker
                )


        rtl_v3 = read_hex(
            work / "rtl_v3.hex",
            WAVE_SIZE,
        )


        if rtl_v3 != expected_v3:

            for lane, (
                rtl_value,
                expected_value,
            ) in enumerate(
                zip(
                    rtl_v3,
                    expected_v3,
                )
            ):

                if rtl_value != expected_value:

                    raise RuntimeError(
                        "RTL5A V3 mismatch "
                        f"lane={lane} "
                        f"rtl=0x{rtl_value:08X} "
                        f"golden=0x{expected_value:08X}"
                    )

            raise RuntimeError(
                "RTL5A vector result mismatch"
            )


    print("RTL5A_DIFF=PASS")
    print(
        f"VECTOR_WORDS_COMPARED={WAVE_SIZE}"
    )
    print(
        "PREDICATED_RESULT_MATCH=PASS"
    )
    print(
        "LATCHED_EXECUTION_OPCODE=VADD"
    )
    print(
        "MUTATED_LIVE_OPCODE=VXOR"
    )


if __name__ == "__main__":
    main()
