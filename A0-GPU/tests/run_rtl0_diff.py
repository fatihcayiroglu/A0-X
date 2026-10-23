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
SCALAR_REG_COUNT = 32
PREDICATE_REG_COUNT = 16
PROGRAM_WORDS = 256


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
    lines = [
        line.strip()
        for line in path.read_text().splitlines()
        if line.strip()
    ]

    if len(lines) != expected_count:
        raise RuntimeError(
            f"{path.name}: expected "
            f"{expected_count} values, "
            f"found {len(lines)}"
        )

    return [
        int(line, 16)
        for line in lines
    ]


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

    program_source = """
        VADD V3, V1, V2
        VSUB V4, V3, V2
        VMUL V5, V1, V2
        VAND V6, V1, V2
        VOR  V7, V1, V2
        VXOR V8, V1, V2

        SADD S2, S0, S1
        SSUB S3, S2, S1

        VCMP_EQ P0, V4, V1
        VCMP_LT P1, V1, V2
        VCMP_LE P2, V1, V2

        @P1 VADD V9, V1, V2

        HALT
    """

    program = assemble_source(
        program_source
    )

    halt_word = assemble_source(
        "HALT"
    )[0]

    if len(program) > PROGRAM_WORDS:
        raise RuntimeError(
            "RTL0 differential program "
            "exceeds program memory"
        )

    initial_vector = [
        [
            0
            for _ in range(WAVE_SIZE)
        ]
        for _ in range(VECTOR_REG_COUNT)
    ]

    initial_scalar = [
        0
        for _ in range(SCALAR_REG_COUNT)
    ]

    for lane in range(WAVE_SIZE):
        initial_vector[1][lane] = (
            lane + 1
        )

        initial_vector[2][lane] = 16

        initial_vector[9][lane] = (
            0xDEADBEEF
        )

    initial_scalar[0] = 100
    initial_scalar[1] = 7

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

    for reg in range(SCALAR_REG_COUNT):
        gpu.scalar_regs[
            reg
        ] = initial_scalar[
            reg
        ]

    steps = 0

    with contextlib.redirect_stdout(
        io.StringIO()
    ):
        while not gpu.halted:
            gpu.step()

            steps += 1

            if steps > 128:
                raise RuntimeError(
                    "Python golden model "
                    "did not halt"
                )

    expected_vector = [
        gpu.vector_regs[
            reg
        ][lane] & 0xFFFFFFFF
        for reg in range(VECTOR_REG_COUNT)
        for lane in range(WAVE_SIZE)
    ]

    expected_scalar = [
        gpu.scalar_regs[
            reg
        ] & 0xFFFFFFFF
        for reg in range(SCALAR_REG_COUNT)
    ]

    # Predicate bit lane N occupies bit N.
    #
    # P0: V4 == V1 -> all 32 lanes
    #
    # P1: V1 < 16  -> values 1..15
    #
    # P2: V1 <= 16 -> values 1..16

    expected_predicates = [
        0
        for _ in range(PREDICATE_REG_COUNT)
    ]

    expected_predicates[0] = 0xFFFFFFFF
    expected_predicates[1] = 0x00007FFF
    expected_predicates[2] = 0x0000FFFF

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

    flat_initial_vector = [
        initial_vector[
            reg
        ][lane]
        for reg in range(VECTOR_REG_COUNT)
        for lane in range(WAVE_SIZE)
    ]

    with tempfile.TemporaryDirectory(
        prefix="a0_rtl0_"
    ) as temporary_directory:

        work = Path(
            temporary_directory
        )

        write_hex(
            work / "program.hex",
            padded_program,
            16,
        )

        write_hex(
            work / "vregs_init.hex",
            flat_initial_vector,
            8,
        )

        write_hex(
            work / "sregs_init.hex",
            initial_scalar,
            8,
        )

        obj_dir = (
            work / "obj_dir"
        )

        build_output = run_command(
            [
                verilator,
                "--binary",
                "--timing",
                "-Wno-fatal",
                "-Werror-PINMISSING",
                "-Werror-WIDTHEXPAND",
                "-Wno-WIDTH",
                "--top-module",
                "a0_wave_core_tb",
                "--Mdir",
                str(obj_dir),
                "-o",
                "a0_wave_core_tb",
                str(ROOT / "rtl" / "core" / "a0_scoreboard.sv"),
                str(ROOT / "rtl" / "core" / "a0_dependency_classifier.sv"),
                str(ROOT / "rtl" / "core" / "a0_lane_sequencer.sv"),
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
                    / "a0_wave_core_tb.sv"
                ),
            ],
            cwd=ROOT,
        )

        executable = (
            obj_dir
            / "a0_wave_core_tb"
        )

        if not executable.exists():
            print(build_output)

            raise RuntimeError(
                "Verilator executable "
                "was not produced"
            )

        simulation_output = run_command(
            [
                str(executable)
            ],
            cwd=work,
        )

        rtl_vector = read_hex(
            work / "rtl_vregs.hex",
            VECTOR_REG_COUNT
            * WAVE_SIZE,
        )

        rtl_scalar = read_hex(
            work / "rtl_sregs.hex",
            SCALAR_REG_COUNT,
        )

        rtl_predicates = read_hex(
            work / "rtl_preds.hex",
            PREDICATE_REG_COUNT,
        )

    for index, (
        expected,
        actual,
    ) in enumerate(
        zip(
            expected_vector,
            rtl_vector,
        )
    ):
        if expected != actual:
            reg = (
                index // WAVE_SIZE
            )

            lane = (
                index % WAVE_SIZE
            )

            raise RuntimeError(
                "VECTOR_DIFF "
                f"V{reg}[{lane}] "
                f"python=0x{expected:08X} "
                f"rtl=0x{actual:08X}"
            )

    for reg, (
        expected,
        actual,
    ) in enumerate(
        zip(
            expected_scalar,
            rtl_scalar,
        )
    ):
        if expected != actual:
            raise RuntimeError(
                "SCALAR_DIFF "
                f"S{reg} "
                f"python=0x{expected:08X} "
                f"rtl=0x{actual:08X}"
            )

    for pred, (
        expected,
        actual,
    ) in enumerate(
        zip(
            expected_predicates,
            rtl_predicates,
        )
    ):
        if expected != actual:
            raise RuntimeError(
                "PREDICATE_DIFF "
                f"P{pred} "
                f"expected=0x{expected:08X} "
                f"rtl=0x{actual:08X}"
            )

    print(
        simulation_output.strip()
    )

    print(
        "RTL0_DIFF=PASS"
    )

    print(
        f"PROGRAM_WORDS={len(program)}"
    )

    print(
        "VECTOR_WORDS_COMPARED="
        f"{len(expected_vector)}"
    )

    print(
        "SCALAR_WORDS_COMPARED="
        f"{len(expected_scalar)}"
    )

    print(
        "PREDICATES_COMPARED="
        f"{len(expected_predicates)}"
    )


if __name__ == "__main__":
    main()
