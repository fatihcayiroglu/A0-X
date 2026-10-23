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

sys.path.insert(0, str(SIM))

from a0_asm import assemble_source
from a0_sim import A0GPU, WAVE_SIZE


VECTOR_REG_COUNT = 64
SCALAR_REG_COUNT = 32
PREDICATE_REG_COUNT = 16
PROGRAM_WORDS = 256


def write_hex(path, values, width):
    mask = (1 << (width * 4)) - 1

    path.write_text(
        "".join(
            f"{value & mask:0{width}x}\n"
            for value in values
        )
    )


def read_hex(path, count):
    values = [
        int(line.strip(), 16)
        for line in path.read_text().splitlines()
        if line.strip()
    ]

    if len(values) != count:
        raise RuntimeError(
            f"{path.name}: expected {count}, "
            f"found {len(values)}"
        )

    return values


def run_command(args, cwd):
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
            + " ".join(str(x) for x in args)
        )

    return result.stdout


def mask_to_u32(mask):
    value = 0

    for lane, enabled in enumerate(mask):
        if enabled:
            value |= 1 << lane

    return value


def main():
    verilator = shutil.which("verilator")

    if verilator is None:
        raise RuntimeError(
            "verilator not found"
        )

    source = """
    loop:
        SADD S0, S0, S1
        SCMP_LT Q0, S0, S2
        BRA Q0, loop

        VCMP_LT P0, V1, V2

        SPLIT P0
        VADD V3, V3, V4

        ELSE
        VMUL V3, V3, V5

        JOIN

        JMP done
        VADD V3, V3, V6

    done:
        HALT
    """

    program = assemble_source(source)

    if len(program) != 12:
        raise RuntimeError(
            f"Expected 12 RTL1 instructions, "
            f"got {len(program)}"
        )

    halt_word = assemble_source("HALT")[0]

    initial_vector = [
        [0] * WAVE_SIZE
        for _ in range(VECTOR_REG_COUNT)
    ]

    initial_scalar = [
        0
        for _ in range(SCALAR_REG_COUNT)
    ]

    for lane in range(WAVE_SIZE):
        initial_vector[1][lane] = lane
        initial_vector[2][lane] = 16

        initial_vector[3][lane] = 100
        initial_vector[4][lane] = 7
        initial_vector[5][lane] = 2

        # JMP must prevent this operand from
        # affecting architectural V3.
        initial_vector[6][lane] = 1000

    initial_scalar[0] = 0
    initial_scalar[1] = 1
    initial_scalar[2] = 5

    gpu = A0GPU(wave_id=0)

    gpu.load_program(list(program))

    for reg in range(VECTOR_REG_COUNT):
        for lane in range(WAVE_SIZE):
            gpu.vector_regs[reg][lane] = (
                initial_vector[reg][lane]
            )

    for reg in range(SCALAR_REG_COUNT):
        gpu.scalar_regs[reg] = (
            initial_scalar[reg]
        )

    steps = 0

    with contextlib.redirect_stdout(
        io.StringIO()
    ):
        while not gpu.halted:
            gpu.step()
            steps += 1

            if steps > 128:
                raise RuntimeError(
                    "Python RTL1 golden timeout"
                )

    if gpu.scalar_regs[0] != 5:
        raise RuntimeError(
            "Python loop did not reach S0=5"
        )

    expected_v = [
        gpu.vector_regs[reg][lane]
        & 0xFFFFFFFF
        for reg in range(VECTOR_REG_COUNT)
        for lane in range(WAVE_SIZE)
    ]

    expected_s = [
        value & 0xFFFFFFFF
        for value in gpu.scalar_regs
    ]

    expected_p = [
        mask_to_u32(mask)
        for mask in gpu.predicate_regs
    ]

    expected_q = [
        int(value)
        for value in gpu.scalar_predicate_regs
    ]

    expected_exec = mask_to_u32(
        gpu.exec_mask
    )

    expected_pc = gpu.pc

    expected_reconv = len(
        gpu.reconvergence_stack
    )

    if expected_exec != 0xFFFFFFFF:
        raise RuntimeError(
            "Python EXEC_MASK not restored"
        )

    if expected_reconv != 0:
        raise RuntimeError(
            "Python reconvergence stack not empty"
        )

    flat_initial_v = [
        initial_vector[reg][lane]
        for reg in range(VECTOR_REG_COUNT)
        for lane in range(WAVE_SIZE)
    ]

    padded_program = (
        list(program)
        + [halt_word]
        * (PROGRAM_WORDS - len(program))
    )

    with tempfile.TemporaryDirectory(
        prefix="a0_rtl1_"
    ) as temp:
        work = Path(temp)

        write_hex(
            work / "program.hex",
            padded_program,
            16,
        )

        write_hex(
            work / "vregs_init.hex",
            flat_initial_v,
            8,
        )

        write_hex(
            work / "sregs_init.hex",
            initial_scalar,
            8,
        )

        obj = work / "obj_dir"

        run_command(
            [
                verilator,
                "--binary",
                "--timing",
                "-Wno-fatal",
                "-Werror-PINMISSING",
                "-Werror-WIDTHEXPAND",
                "-Wno-WIDTH",
                "--top-module",
                "a0_wave_core_rtl1_tb",
                "--Mdir",
                str(obj),
                "-o",
                "a0_wave_core_rtl1_tb",
                str(ROOT / "rtl" / "core" / "a0_scoreboard.sv"),
                str(ROOT / "rtl" / "core" / "a0_dependency_classifier.sv"),
                str(ROOT / "rtl" / "core" / "a0_lane_sequencer.sv"),
                str(ROOT / "rtl" / "core" / "a0_regfile_banked.sv"),
                str(ROOT / "rtl" / "core" / "a0_operand_collector.sv"),
                str(ROOT / "rtl" / "core" / "a0_vector_operand_path.sv"),
                str(
                    ROOT
                    / "rtl/core/a0_wave_core.sv"
                ),
                str(
                    ROOT
                    / "tests/rtl/"
                    "a0_wave_core_rtl1_tb.sv"
                ),
            ],
            ROOT,
        )

        output = run_command(
            [
                str(
                    obj
                    / "a0_wave_core_rtl1_tb"
                )
            ],
            work,
        )

        rtl_v = read_hex(
            work / "rtl_vregs.hex",
            VECTOR_REG_COUNT * WAVE_SIZE,
        )

        rtl_s = read_hex(
            work / "rtl_sregs.hex",
            SCALAR_REG_COUNT,
        )

        rtl_p = read_hex(
            work / "rtl_preds.hex",
            PREDICATE_REG_COUNT,
        )

        rtl_q = read_hex(
            work / "rtl_qpreds.hex",
            PREDICATE_REG_COUNT,
        )

        control = read_hex(
            work / "rtl_control.hex",
            3,
        )

    rtl_exec = control[0]
    rtl_pc = control[1]
    rtl_reconv = control[2]

    for index, (expected, actual) in enumerate(
        zip(expected_v, rtl_v)
    ):
        if expected != actual:
            reg = index // WAVE_SIZE
            lane = index % WAVE_SIZE

            raise RuntimeError(
                f"RTL1_VECTOR_DIFF "
                f"V{reg}[{lane}] "
                f"python=0x{expected:08X} "
                f"rtl=0x{actual:08X}"
            )

    for reg, (expected, actual) in enumerate(
        zip(expected_s, rtl_s)
    ):
        if expected != actual:
            raise RuntimeError(
                f"RTL1_SCALAR_DIFF S{reg} "
                f"python=0x{expected:08X} "
                f"rtl=0x{actual:08X}"
            )

    for pred, (expected, actual) in enumerate(
        zip(expected_p, rtl_p)
    ):
        if expected != actual:
            raise RuntimeError(
                f"RTL1_PRED_DIFF P{pred} "
                f"python=0x{expected:08X} "
                f"rtl=0x{actual:08X}"
            )

    for pred, (expected, actual) in enumerate(
        zip(expected_q, rtl_q)
    ):
        if expected != actual:
            raise RuntimeError(
                f"RTL1_QPRED_DIFF Q{pred} "
                f"python={expected} "
                f"rtl={actual}"
            )

    if expected_exec != rtl_exec:
        raise RuntimeError(
            "RTL1_EXEC_DIFF "
            f"python=0x{expected_exec:08X} "
            f"rtl=0x{rtl_exec:08X}"
        )

    if expected_pc != rtl_pc:
        raise RuntimeError(
            "RTL1_PC_DIFF "
            f"python={expected_pc} "
            f"rtl={rtl_pc}"
        )

    if expected_reconv != rtl_reconv:
        raise RuntimeError(
            "RTL1_RECONV_DIFF "
            f"python={expected_reconv} "
            f"rtl={rtl_reconv}"
        )

    print(output.strip())

    print("RTL1_DIFF=PASS")
    print(f"PROGRAM_WORDS={len(program)}")
    print(f"PYTHON_STEPS={steps}")
    print(
        "VECTOR_WORDS_COMPARED="
        f"{len(expected_v)}"
    )
    print(
        "SCALAR_WORDS_COMPARED="
        f"{len(expected_s)}"
    )
    print(
        "VECTOR_PREDICATES_COMPARED="
        f"{len(expected_p)}"
    )
    print(
        "SCALAR_PREDICATES_COMPARED="
        f"{len(expected_q)}"
    )
    print(
        f"FINAL_EXEC_MASK="
        f"0x{rtl_exec:08X}"
    )
    print(
        f"FINAL_RECONV_DEPTH="
        f"{rtl_reconv}"
    )


if __name__ == "__main__":
    main()
