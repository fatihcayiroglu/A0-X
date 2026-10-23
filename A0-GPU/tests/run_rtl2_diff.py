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
from a0_sim import (
    A0GPU,
    MEMORY_WORDS,
    WAVE_SIZE,
)


VECTOR_REG_COUNT = 64
SCALAR_REG_COUNT = 32
PREDICATE_REG_COUNT = 16
SCALAR_PREDICATE_REG_COUNT = 16
PROGRAM_WORDS = 256


def write_hex(path, values, digits):
    mask = (1 << (digits * 4)) - 1

    path.write_text(
        "".join(
            f"{value & mask:0{digits}x}\n"
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
            + " ".join(
                str(item)
                for item in args
            )
        )

    return result.stdout


def mask_to_u32(mask):
    result = 0

    for lane, enabled in enumerate(mask):
        if enabled:
            result |= 1 << lane

    return result


def flatten_vectors(vectors):
    return [
        vectors[reg][lane]
        for reg in range(VECTOR_REG_COUNT)
        for lane in range(WAVE_SIZE)
    ]


def make_vector_state():
    return [
        [0] * WAVE_SIZE
        for _ in range(VECTOR_REG_COUNT)
    ]


def make_scalar_state():
    return [
        0
        for _ in range(SCALAR_REG_COUNT)
    ]


def make_memory_state():
    return [
        0
        for _ in range(MEMORY_WORDS)
    ]


def initialize_gpu(
    program,
    vectors,
    scalars,
    memory,
):
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
            ][lane] = (
                vectors[reg][lane]
                & 0xFFFFFFFF
            )

    for reg in range(SCALAR_REG_COUNT):
        gpu.scalar_regs[reg] = (
            scalars[reg]
            & 0xFFFFFFFF
        )

    for address in range(MEMORY_WORDS):
        gpu.memory[address] = (
            memory[address]
            & 0xFFFFFFFF
        )

    return gpu


def run_python_to_halt(gpu):
    steps = 0

    with contextlib.redirect_stdout(
        io.StringIO()
    ):
        while not gpu.halted:
            gpu.step()

            steps += 1

            if steps > 128:
                raise RuntimeError(
                    "Python RTL2 golden timeout"
                )

    return steps


def write_case(
    directory,
    program,
    vectors,
    scalars,
    memory,
):
    halt_word = assemble_source(
        "HALT"
    )[0]

    if len(program) > PROGRAM_WORDS:
        raise RuntimeError(
            "RTL2 program exceeds "
            "instruction memory"
        )

    padded_program = (
        list(program)
        + [halt_word]
        * (
            PROGRAM_WORDS
            - len(program)
        )
    )

    write_hex(
        directory / "program.hex",
        padded_program,
        16,
    )

    write_hex(
        directory / "vregs_init.hex",
        flatten_vectors(vectors),
        8,
    )

    write_hex(
        directory / "sregs_init.hex",
        scalars,
        8,
    )

    write_hex(
        directory / "memory_init.hex",
        memory,
        8,
    )


def compare_vectors(
    expected,
    actual,
):
    for index, (
        expected_value,
        actual_value,
    ) in enumerate(
        zip(expected, actual)
    ):
        if (
            expected_value
            != actual_value
        ):
            reg = (
                index
                // WAVE_SIZE
            )

            lane = (
                index
                % WAVE_SIZE
            )

            raise RuntimeError(
                "RTL2_VECTOR_DIFF "
                f"V{reg}[{lane}] "
                f"python="
                f"0x{expected_value:08X} "
                f"rtl="
                f"0x{actual_value:08X}"
            )


def compare_named_array(
    name,
    expected,
    actual,
):
    for index, (
        expected_value,
        actual_value,
    ) in enumerate(
        zip(expected, actual)
    ):
        if (
            expected_value
            != actual_value
        ):
            raise RuntimeError(
                f"RTL2_{name}_DIFF "
                f"[{index}] "
                f"python="
                f"0x{expected_value:08X} "
                f"rtl="
                f"0x{actual_value:08X}"
            )


def main():
    verilator = shutil.which(
        "verilator"
    )

    if verilator is None:
        raise RuntimeError(
            "verilator not found"
        )


    # ========================================================
    # Normal memory workload
    # ========================================================

    source = """
        VCMP_LT P0, V10, V11

        @P0 VLOADX V3, S0, V1, 0
        @P0 VADD V4, V3, V2
        @P0 VSTOREX V4, S1, V1, -4

        VLOADX V5, S2, V6, -10

        HALT
    """

    program = assemble_source(
        source
    )

    if len(program) != 6:
        raise RuntimeError(
            "RTL2 workload expected "
            f"6 instructions, got "
            f"{len(program)}"
        )


    vectors = make_vector_state()
    scalars = make_scalar_state()
    memory = make_memory_state()


    scalars[0] = 100
    scalars[1] = 320
    scalars[2] = 200


    for lane in range(WAVE_SIZE):

        # Addend for predicated arithmetic.
        vectors[2][lane] = 5

        # Sentinels prove masked lanes
        # retain architectural state.
        vectors[3][lane] = (
            0xDEADBEEF
        )

        vectors[4][lane] = (
            0xA5A5A5A5
        )

        # Unpredicated second VLOADX:
        # 200 + lane - 10
        # -> 190..221
        vectors[6][lane] = lane

        # Predicate:
        # lanes 0..15 active.
        vectors[10][lane] = lane
        vectors[11][lane] = 16

        if lane < 16:
            vectors[1][lane] = lane

            memory[
                100 + lane
            ] = (
                1000 + lane
            )

        else:
            # Deliberately invalid if this
            # lane were active:
            #
            # 100 + 5000 > memory bounds.
            vectors[1][lane] = 5000

        memory[
            190 + lane
        ] = (
            2000 + lane
        )


    # Store destination:
    #
    # 320 + lane - 4
    # -> 316..331 for active lanes.
    for lane in range(16):
        memory[
            316 + lane
        ] = (
            0xCCCC0000
            + lane
        )


    gpu = initialize_gpu(
        program,
        vectors,
        scalars,
        memory,
    )

    python_steps = (
        run_python_to_halt(gpu)
    )


    expected_vectors = [
        value & 0xFFFFFFFF
        for value
        in flatten_vectors(
            gpu.vector_regs
        )
    ]

    expected_scalars = [
        value & 0xFFFFFFFF
        for value
        in gpu.scalar_regs
    ]

    expected_predicates = [
        mask_to_u32(mask)
        for mask
        in gpu.predicate_regs
    ]

    expected_qpredicates = [
        int(value)
        for value
        in gpu.scalar_predicate_regs
    ]

    expected_memory = [
        value & 0xFFFFFFFF
        for value
        in gpu.memory
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
            "Python RTL2 EXEC_MASK "
            "not restored"
        )

    if expected_reconv != 0:
        raise RuntimeError(
            "Python RTL2 reconvergence "
            "stack not empty"
        )


    # Explicitly prove inactive lanes
    # were untouched despite their invalid
    # address contributions.
    for lane in range(
        16,
        WAVE_SIZE,
    ):
        if (
            gpu.vector_regs[3][lane]
            != 0xDEADBEEF
        ):
            raise RuntimeError(
                "Python masked VLOADX "
                f"modified V3[{lane}]"
            )

        if (
            gpu.vector_regs[4][lane]
            != 0xA5A5A5A5
        ):
            raise RuntimeError(
                "Python masked VADD "
                f"modified V4[{lane}]"
            )


    # ========================================================
    # Build RTL2
    # ========================================================

    with tempfile.TemporaryDirectory(
        prefix="a0_rtl2_"
    ) as temp:

        work = Path(temp)

        obj = (
            work
            / "obj_dir"
        )

        run_command(
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
                "--top-module",
                "a0_wave_core_rtl2_tb",
                "--Mdir",
                str(obj),
                "-o",
                "a0_wave_core_rtl2_tb",
                str(ROOT / "rtl" / "core" / "a0_scoreboard.sv"),
                str(ROOT / "rtl" / "core" / "a0_dependency_classifier.sv"),
                str(ROOT / "rtl" / "core" / "a0_lane_sequencer.sv"),
                str(ROOT / "rtl" / "core" / "a0_regfile_banked.sv"),
                str(ROOT / "rtl" / "core" / "a0_operand_collector.sv"),
                str(ROOT / "rtl" / "core" / "a0_vector_operand_path.sv"),
                str(
                    ROOT
                    / "rtl/core/"
                    "a0_wave_core.sv"
                ),
                str(
                    ROOT
                    / "tests/rtl/"
                    "a0_wave_core_rtl2_tb.sv"
                ),
            ],
            ROOT,
        )


        executable = (
            obj
            / "a0_wave_core_rtl2_tb"
        )


        # ====================================================
        # Normal case
        # ====================================================

        normal_dir = (
            work
            / "normal"
        )

        normal_dir.mkdir()

        write_case(
            normal_dir,
            program,
            vectors,
            scalars,
            memory,
        )


        normal_output = run_command(
            [
                str(executable),
            ],
            normal_dir,
        )


        if (
            "RTL2_TB=PASS"
            not in normal_output
        ):
            print(normal_output)

            raise RuntimeError(
                "RTL2 normal testbench "
                "did not report PASS"
            )


        rtl_vectors = read_hex(
            normal_dir
            / "rtl_vregs.hex",
            VECTOR_REG_COUNT
            * WAVE_SIZE,
        )

        rtl_scalars = read_hex(
            normal_dir
            / "rtl_sregs.hex",
            SCALAR_REG_COUNT,
        )

        rtl_predicates = read_hex(
            normal_dir
            / "rtl_preds.hex",
            PREDICATE_REG_COUNT,
        )

        rtl_qpredicates = read_hex(
            normal_dir
            / "rtl_qpreds.hex",
            SCALAR_PREDICATE_REG_COUNT,
        )

        rtl_memory = read_hex(
            normal_dir
            / "rtl_memory.hex",
            MEMORY_WORDS,
        )

        control = read_hex(
            normal_dir
            / "rtl_control.hex",
            4,
        )


        rtl_exec = control[0]
        rtl_pc = control[1]
        rtl_reconv = control[2]
        rtl_requests = control[3]


        compare_vectors(
            expected_vectors,
            rtl_vectors,
        )

        compare_named_array(
            "SCALAR",
            expected_scalars,
            rtl_scalars,
        )

        compare_named_array(
            "PREDICATE",
            expected_predicates,
            rtl_predicates,
        )

        compare_named_array(
            "QPREDICATE",
            expected_qpredicates,
            rtl_qpredicates,
        )

        compare_named_array(
            "MEMORY",
            expected_memory,
            rtl_memory,
        )


        if rtl_exec != expected_exec:
            raise RuntimeError(
                "RTL2_EXEC_DIFF "
                f"python="
                f"0x{expected_exec:08X} "
                f"rtl="
                f"0x{rtl_exec:08X}"
            )


        if rtl_pc != expected_pc:
            raise RuntimeError(
                "RTL2_PC_DIFF "
                f"python={expected_pc} "
                f"rtl={rtl_pc}"
            )


        if (
            rtl_reconv
            != expected_reconv
        ):
            raise RuntimeError(
                "RTL2_RECONV_DIFF "
                f"python="
                f"{expected_reconv} "
                f"rtl={rtl_reconv}"
            )


        if rtl_requests != 3:
            raise RuntimeError(
                "RTL2 expected exactly "
                "3 external memory requests, "
                f"got {rtl_requests}"
            )


        # ====================================================
        # Active invalid address
        # ====================================================

        fault_program = (
            assemble_source(
                """
                VLOADX V2, S0, V1, 0
                HALT
                """
            )
        )

        fault_vectors = (
            make_vector_state()
        )

        fault_scalars = (
            make_scalar_state()
        )

        fault_memory = (
            make_memory_state()
        )


        fault_scalars[0] = 1000

        for lane in range(WAVE_SIZE):
            fault_vectors[
                1
            ][lane] = (
                100 + lane
            )


        fault_gpu = initialize_gpu(
            fault_program,
            fault_vectors,
            fault_scalars,
            fault_memory,
        )


        python_fault = False

        try:
            with contextlib.redirect_stdout(
                io.StringIO()
            ):
                fault_gpu.step()

        except RuntimeError as error:
            if (
                "VLOADX outside memory"
                not in str(error)
            ):
                raise

            python_fault = True


        if not python_fault:
            raise RuntimeError(
                "Python active invalid "
                "VLOADX did not fault"
            )


        fault_dir = (
            work
            / "fault"
        )

        fault_dir.mkdir()

        write_case(
            fault_dir,
            fault_program,
            fault_vectors,
            fault_scalars,
            fault_memory,
        )


        fault_output = run_command(
            [
                str(executable),
                "+EXPECT_FAULT=1",
            ],
            fault_dir,
        )


        if (
            "RTL2_FAULT_TB=PASS"
            not in fault_output
        ):
            print(fault_output)

            raise RuntimeError(
                "RTL2 active-invalid "
                "fault test failed"
            )


    print(
        normal_output.strip()
    )

    print(
        fault_output.strip()
    )

    print("RTL2_DIFF=PASS")

    print(
        f"PROGRAM_WORDS="
        f"{len(program)}"
    )

    print(
        f"PYTHON_STEPS="
        f"{python_steps}"
    )

    print(
        "VECTOR_WORDS_COMPARED="
        f"{len(expected_vectors)}"
    )

    print(
        "SCALAR_WORDS_COMPARED="
        f"{len(expected_scalars)}"
    )

    print(
        "VECTOR_PREDICATES_COMPARED="
        f"{len(expected_predicates)}"
    )

    print(
        "SCALAR_PREDICATES_COMPARED="
        f"{len(expected_qpredicates)}"
    )

    print(
        "MEMORY_WORDS_COMPARED="
        f"{len(expected_memory)}"
    )

    print(
        "EXTERNAL_MEMORY_REQUESTS="
        f"{rtl_requests}"
    )

    print(
        "MASKED_INVALID_ADDRESS=PASS"
    )

    print(
        "ACTIVE_INVALID_ADDRESS=PASS"
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
