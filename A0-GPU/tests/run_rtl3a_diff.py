#!/usr/bin/env python3

from pathlib import Path
import random
import shutil
import subprocess
import sys
import tempfile


ROOT = Path(__file__).resolve().parents[1]
SIM = ROOT / "sim"

sys.path.insert(0, str(SIM))

from a0_sim import (
    MEMORY_TRANSACTION_WORDS,
    WAVE_SIZE,
    coalesce_word_addresses,
)


TRANSACTION_WORDS = (
    MEMORY_TRANSACTION_WORDS
)

RANDOM_CASES = 64
RANDOM_SEED = 0xA003


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


def write_case(
    directory,
    lane_mask,
    addresses,
):
    mask_value = 0

    for lane, enabled in enumerate(
        lane_mask
    ):
        if enabled:
            mask_value |= (
                1 << lane
            )

    (
        directory
        / "mask.hex"
    ).write_text(
        f"{mask_value:08x}\n"
    )

    (
        directory
        / "addresses.hex"
    ).write_text(
        "".join(
            f"{address & 0xFFFFFFFF:08x}\n"
            for address in addresses
        )
    )


def read_result(path):
    values = [
        int(line.strip(), 16)
        for line
        in path.read_text().splitlines()
        if line.strip()
    ]

    if len(values) < 3:
        raise RuntimeError(
            "RTL3A result is incomplete"
        )

    return {
        "lane_requests": values[0],
        "unique_words": values[1],
        "transactions": values[2],
        "segments": values[3:],
    }


def expected_segments(
    lane_mask,
    addresses,
):
    segments = []
    seen = set()

    for lane in range(WAVE_SIZE):

        if not lane_mask[lane]:
            continue

        segment = (
            addresses[lane]
            // TRANSACTION_WORDS
        )

        if segment not in seen:
            seen.add(segment)
            segments.append(segment)

    return segments


def golden_result(
    lane_mask,
    addresses,
):
    active_addresses = [
        addresses[lane]
        for lane in range(WAVE_SIZE)
        if lane_mask[lane]
    ]

    metrics = coalesce_word_addresses(
        active_addresses,
        transaction_words=(
            TRANSACTION_WORDS
        ),
    )

    return {
        "lane_requests":
            metrics["lane_requests"],

        "unique_words":
            metrics["unique_words"],

        "transactions":
            metrics["transactions"],

        "segments":
            expected_segments(
                lane_mask,
                addresses,
            ),
    }


def compare_case(
    label,
    expected,
    actual,
):
    for field in [
        "lane_requests",
        "unique_words",
        "transactions",
    ]:
        if (
            expected[field]
            != actual[field]
        ):
            raise RuntimeError(
                f"RTL3A_{field.upper()}_DIFF "
                f"case={label} "
                f"python={expected[field]} "
                f"rtl={actual[field]}"
            )

    if (
        expected["segments"]
        != actual["segments"]
    ):
        raise RuntimeError(
            "RTL3A_SEGMENT_DIFF "
            f"case={label} "
            f"python="
            f"{expected['segments']} "
            f"rtl="
            f"{actual['segments']}"
        )


def directed_cases():
    cases = []


    # --------------------------------------------------------
    # 32 contiguous words:
    #
    # 0..31
    #
    # 4 x 8-word transactions.
    # --------------------------------------------------------

    cases.append(
        (
            "contiguous",
            [True] * WAVE_SIZE,
            list(range(WAVE_SIZE)),
        )
    )


    # --------------------------------------------------------
    # Stride = one full transaction.
    #
    # Every lane lands in another segment.
    # --------------------------------------------------------

    cases.append(
        (
            "stride8",
            [True] * WAVE_SIZE,
            [
                lane
                * TRANSACTION_WORDS
                for lane in range(
                    WAVE_SIZE
                )
            ],
        )
    )


    # --------------------------------------------------------
    # First 16 lanes only.
    #
    # Inactive lanes deliberately contain huge values.
    # They must not affect coalescing.
    # --------------------------------------------------------

    cases.append(
        (
            "masked16",
            [
                lane < 16
                for lane in range(
                    WAVE_SIZE
                )
            ],
            [
                lane
                if lane < 16
                else 0xFFFFFFFF
                for lane in range(
                    WAVE_SIZE
                )
            ],
        )
    )


    # --------------------------------------------------------
    # Broadcast.
    #
    # 32 lane requests
    # 1 unique word
    # 1 transaction
    # --------------------------------------------------------

    cases.append(
        (
            "broadcast",
            [True] * WAVE_SIZE,
            [24] * WAVE_SIZE,
        )
    )


    # --------------------------------------------------------
    # Duplicate words spanning multiple segments.
    # --------------------------------------------------------

    cases.append(
        (
            "duplicates",
            [True] * WAVE_SIZE,
            [
                (
                    (lane // 4)
                    * TRANSACTION_WORDS
                )
                for lane in range(
                    WAVE_SIZE
                )
            ],
        )
    )


    return cases


def randomized_cases():
    rng = random.Random(
        RANDOM_SEED
    )

    cases = []

    for case_index in range(
        RANDOM_CASES
    ):
        lane_mask = [
            bool(
                rng.getrandbits(1)
            )
            for _ in range(
                WAVE_SIZE
            )
        ]

        # Avoid empty case because this milestone
        # is focused on active memory requests.
        if not any(lane_mask):
            lane_mask[
                rng.randrange(
                    WAVE_SIZE
                )
            ] = True


        addresses = [
            rng.randrange(
                0,
                1024,
            )
            for _ in range(
                WAVE_SIZE
            )
        ]


        # Occasionally introduce broadcasts/
        # duplicate addresses.
        if (
            case_index % 4 == 0
        ):
            shared_address = (
                rng.randrange(
                    0,
                    1024,
                )
            )

            for lane in range(
                0,
                WAVE_SIZE,
                4,
            ):
                addresses[lane] = (
                    shared_address
                )


        cases.append(
            (
                f"random_{case_index:02d}",
                lane_mask,
                addresses,
            )
        )


    return cases


def main():
    verilator = shutil.which(
        "verilator"
    )

    if verilator is None:
        raise RuntimeError(
            "verilator not found"
        )


    if TRANSACTION_WORDS != 8:
        raise RuntimeError(
            "RTL3A verifier currently "
            "expects SIM8 provisional "
            "TRANSACTION_WORDS=8; "
            f"found {TRANSACTION_WORDS}"
        )


    cases = (
        directed_cases()
        + randomized_cases()
    )


    with tempfile.TemporaryDirectory(
        prefix="a0_rtl3a_"
    ) as temp:

        work = Path(temp)

        obj = (
            work
            / "obj_dir"
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
                "--top-module",
                "a0_memory_coalescer_tb",
                "--Mdir",
                str(obj),
                "-o",
                "a0_memory_coalescer_tb",
                str(
                    ROOT
                    / "rtl/memory/"
                    "a0_memory_coalescer.sv"
                ),
                str(
                    ROOT
                    / "tests/rtl/"
                    "a0_memory_coalescer_tb.sv"
                ),
            ],
            ROOT,
        )


        if "%Warning" in build_output:
            print(build_output)

            raise RuntimeError(
                "RTL3A build produced "
                "Verilator warnings"
            )


        executable = (
            obj
            / "a0_memory_coalescer_tb"
        )


        for (
            label,
            lane_mask,
            addresses,
        ) in cases:

            case_dir = (
                work
                / label
            )

            case_dir.mkdir()


            write_case(
                case_dir,
                lane_mask,
                addresses,
            )


            output = run_command(
                [
                    str(executable),
                ],
                case_dir,
            )


            if (
                "RTL3A_TB=PASS"
                not in output
            ):
                print(output)

                raise RuntimeError(
                    "RTL3A TB did not "
                    f"report PASS: {label}"
                )


            expected = golden_result(
                lane_mask,
                addresses,
            )

            actual = read_result(
                case_dir
                / "coalescer_result.hex"
            )


            compare_case(
                label,
                expected,
                actual,
            )


    contiguous = golden_result(
        [True] * WAVE_SIZE,
        list(range(WAVE_SIZE)),
    )

    stride8 = golden_result(
        [True] * WAVE_SIZE,
        [
            lane
            * TRANSACTION_WORDS
            for lane in range(
                WAVE_SIZE
            )
        ],
    )

    broadcast = golden_result(
        [True] * WAVE_SIZE,
        [24] * WAVE_SIZE,
    )


    print("RTL3A_DIFF=PASS")

    print(
        f"TRANSACTION_WORDS="
        f"{TRANSACTION_WORDS}"
    )

    print(
        "TRANSACTION_BYTES="
        f"{TRANSACTION_WORDS * 4}"
    )

    print(
        f"DIRECTED_CASES="
        f"{len(directed_cases())}"
    )

    print(
        f"RANDOM_CASES="
        f"{RANDOM_CASES}"
    )

    print(
        f"TOTAL_CASES="
        f"{len(cases)}"
    )

    print(
        "CONTIGUOUS_TRANSACTIONS="
        f"{contiguous['transactions']}"
    )

    print(
        "STRIDE8_TRANSACTIONS="
        f"{stride8['transactions']}"
    )

    print(
        "BROADCAST_UNIQUE_WORDS="
        f"{broadcast['unique_words']}"
    )

    print(
        "BROADCAST_TRANSACTIONS="
        f"{broadcast['transactions']}"
    )

    print(
        "SEGMENT_LIST_MATCH=PASS"
    )


if __name__ == "__main__":
    main()
