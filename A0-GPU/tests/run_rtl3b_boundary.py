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
    MEMORY_TRANSACTION_WORDS,
    MEMORY_WORDS,
    WAVE_SIZE,
    coalesce_word_addresses,
)


VECTOR_REG_COUNT = 64
SCALAR_REG_COUNT = 32
PROGRAM_WORDS = 256


def write_hex(path, values, width):
    mask = (1 << (width * 4)) - 1

    path.write_text(
        "".join(
            f"{value & mask:0{width}x}\n"
            for value in values
        )
    )


def read_hex(path, expected_count):
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
                str(arg)
                for arg in args
            )
        )

    return result.stdout


def main():
    verilator = shutil.which("verilator")

    if verilator is None:
        raise RuntimeError(
            "verilator not found"
        )


    source = """
        VLOADX V2, S0, V1, 0
        HALT
    """

    program = assemble_source(source)

    if len(program) != 2:
        raise RuntimeError(
            "RTL3B boundary program "
            f"expected 2 words, got {len(program)}"
        )


    initial_v = [
        [0] * WAVE_SIZE
        for _ in range(VECTOR_REG_COUNT)
    ]

    initial_s = [
        0
        for _ in range(SCALAR_REG_COUNT)
    ]

    initial_memory = [
        0
        for _ in range(MEMORY_WORDS)
    ]


    addresses = []

    for lane in range(WAVE_SIZE):
        address = (
            lane
            * MEMORY_TRANSACTION_WORDS
        )

        addresses.append(address)

        initial_v[1][lane] = address

        initial_memory[address] = (
            0xA0000000 + lane
        )


    golden_metrics = coalesce_word_addresses(
        addresses,
        transaction_words=(
            MEMORY_TRANSACTION_WORDS
        ),
    )

    if golden_metrics["transactions"] != 32:
        raise RuntimeError(
            "SIM8 boundary drift: expected "
            "32 transactions, got "
            f"{golden_metrics['transactions']}"
        )


    gpu = A0GPU(wave_id=0)

    gpu.load_program(
        list(program)
    )

    for reg in range(VECTOR_REG_COUNT):
        for lane in range(WAVE_SIZE):
            gpu.vector_regs[reg][lane] = (
                initial_v[reg][lane]
            )

    for reg in range(SCALAR_REG_COUNT):
        gpu.scalar_regs[reg] = (
            initial_s[reg]
        )

    gpu.memory[:] = initial_memory[:]


    python_steps = 0

    with contextlib.redirect_stdout(
        io.StringIO()
    ):
        while not gpu.halted:
            gpu.step()

            python_steps += 1

            if python_steps > 16:
                raise RuntimeError(
                    "Python RTL3B boundary timeout"
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

    expected_memory = [
        value & 0xFFFFFFFF
        for value in gpu.memory
    ]


    flat_initial_v = [
        initial_v[reg][lane]
        for reg in range(VECTOR_REG_COUNT)
        for lane in range(WAVE_SIZE)
    ]


    halt_word = assemble_source(
        "HALT"
    )[0]

    padded_program = (
        list(program)
        + [halt_word]
        * (
            PROGRAM_WORDS
            - len(program)
        )
    )


    with tempfile.TemporaryDirectory(
        prefix="a0_rtl3b_boundary_"
    ) as temp:

        work = Path(temp)
        obj = work / "obj_dir"


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
            initial_s,
            8,
        )

        write_hex(
            work / "memory_init.hex",
            initial_memory,
            8,
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
                "a0_wave_core_rtl3b_tb",
                "--Mdir",
                str(obj),
                "-o",
                "a0_wave_core_rtl3b_tb",
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
                    / "rtl/memory/"
                    "a0_memory_coalescer.sv"
                ),
                str(
                    ROOT
                    / "rtl/memory/"
                    "a0_memory_coalesced_bridge.sv"
                ),
                str(
                    ROOT
                    / "tests/rtl/"
                    "a0_wave_core_rtl3b_tb.sv"
                ),
            ],
            ROOT,
        )


        output = run_command(
            [
                str(
                    obj
                    / "a0_wave_core_rtl3b_tb"
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

        rtl_memory = read_hex(
            work / "rtl_memory.hex",
            MEMORY_WORDS,
        )

        control = read_hex(
            work / "rtl_control.hex",
            5,
        )


    rtl_exec = control[0]
    rtl_pc = control[1]
    rtl_reconv = control[2]
    rtl_arch_requests = control[3]
    rtl_transactions = control[4]


    for index, (
        expected,
        actual,
    ) in enumerate(
        zip(
            expected_v,
            rtl_v,
        )
    ):
        if expected != actual:
            reg = index // WAVE_SIZE
            lane = index % WAVE_SIZE

            raise RuntimeError(
                "RTL3B_BOUNDARY_VECTOR_DIFF "
                f"V{reg}[{lane}] "
                f"python=0x{expected:08X} "
                f"rtl=0x{actual:08X}"
            )


    for reg, (
        expected,
        actual,
    ) in enumerate(
        zip(
            expected_s,
            rtl_s,
        )
    ):
        if expected != actual:
            raise RuntimeError(
                "RTL3B_BOUNDARY_SCALAR_DIFF "
                f"S{reg} "
                f"python=0x{expected:08X} "
                f"rtl=0x{actual:08X}"
            )


    for address, (
        expected,
        actual,
    ) in enumerate(
        zip(
            expected_memory,
            rtl_memory,
        )
    ):
        if expected != actual:
            raise RuntimeError(
                "RTL3B_BOUNDARY_MEMORY_DIFF "
                f"address={address} "
                f"python=0x{expected:08X} "
                f"rtl=0x{actual:08X}"
            )


    if rtl_exec != 0xFFFFFFFF:
        raise RuntimeError(
            "RTL3B boundary EXEC mismatch: "
            f"0x{rtl_exec:08X}"
        )

    if rtl_pc != 2:
        raise RuntimeError(
            "RTL3B boundary PC mismatch: "
            f"{rtl_pc}"
        )

    if rtl_reconv != 0:
        raise RuntimeError(
            "RTL3B boundary reconvergence "
            f"depth={rtl_reconv}"
        )

    if rtl_arch_requests != 1:
        raise RuntimeError(
            "RTL3B boundary expected "
            "1 architectural request, got "
            f"{rtl_arch_requests}"
        )

    if rtl_transactions != 32:
        raise RuntimeError(
            "RTL3B boundary expected "
            "32 physical transactions, got "
            f"{rtl_transactions}"
        )


    print(output.strip())

    print(
        "RTL3B_32_TRANSACTION_BOUNDARY=PASS"
    )

    print(
        "ARCHITECTURAL_MEMORY_REQUESTS="
        f"{rtl_arch_requests}"
    )

    print(
        "PHYSICAL_TRANSACTIONS="
        f"{rtl_transactions}"
    )

    print(
        "SIM8_TRANSACTION_MATCH=PASS"
    )

    print(
        "VECTOR_WORDS_COMPARED="
        f"{len(expected_v)}"
    )

    print(
        "MEMORY_WORDS_COMPARED="
        f"{len(expected_memory)}"
    )

    print(
        f"FINAL_EXEC_MASK="
        f"0x{rtl_exec:08X}"
    )

    print(
        "FINAL_RECONV_DEPTH="
        f"{rtl_reconv}"
    )


if __name__ == "__main__":
    main()
