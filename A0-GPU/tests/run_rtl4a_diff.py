#!/usr/bin/env python3

from pathlib import Path
import shutil
import subprocess
import tempfile


ROOT = Path(__file__).resolve().parents[1]

WAVE_SIZE = 32

PHYSICAL_CONFIGS = (
    32,
    16,
    8,
    6,
    4,
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


def scenario_masks(
    scenario_id,
):

    if scenario_id == 0:

        exec_mask = (
            (1 << WAVE_SIZE) - 1
        )

        for lane in (
            3,
            9,
            17,
            31,
        ):
            exec_mask &= ~(
                1 << lane
            )

        pred_enable = False
        pred_mask = 0

        return (
            exec_mask,
            pred_enable,
            pred_mask,
        )


    if scenario_id == 1:

        exec_mask = (
            (1 << WAVE_SIZE) - 1
        )

        for lane in (
            5,
            12,
            24,
        ):
            exec_mask &= ~(
                1 << lane
            )


        pred_enable = True
        pred_mask = 0


        for lane in range(
            WAVE_SIZE
        ):
            if lane % 3 != 1:
                pred_mask |= (
                    1 << lane
                )


        return (
            exec_mask,
            pred_enable,
            pred_mask,
        )


    raise RuntimeError(
        f"Unknown scenario "
        f"{scenario_id}"
    )


def expected_beats(
    physical_lanes,
):
    return (
        WAVE_SIZE
        + physical_lanes
        - 1
    ) // physical_lanes


def golden_row(
    *,
    scenario_id,
    beat,
    physical_lanes,
):

    (
        exec_mask,
        pred_enable,
        pred_mask,
    ) = scenario_masks(
        scenario_id
    )


    valid_mask = 0
    active_mask = 0

    logical_lanes = []


    for physical_lane in range(
        physical_lanes
    ):

        logical_lane = (
            beat
            * physical_lanes
            + physical_lane
        )

        logical_lanes.append(
            logical_lane
        )


        if logical_lane >= WAVE_SIZE:
            continue


        valid_mask |= (
            1 << physical_lane
        )


        active = (
            (
                exec_mask
                >> logical_lane
            )
            & 1
        )


        if pred_enable:
            active &= (
                (
                    pred_mask
                    >> logical_lane
                )
                & 1
            )


        if active:
            active_mask |= (
                1 << physical_lane
            )


    return (
        valid_mask,
        active_mask,
        logical_lanes,
    )


def parse_result(
    path,
    *,
    physical_lanes,
):

    rows = []


    for line_number, raw in enumerate(
        path.read_text().splitlines(),
        start=1,
    ):

        raw = raw.strip()

        if not raw:
            continue


        fields = raw.split()


        expected_fields = (
            4
            + physical_lanes
        )


        if (
            len(fields)
            != expected_fields
        ):
            raise RuntimeError(
                f"{path.name}: line "
                f"{line_number}: expected "
                f"{expected_fields} fields, "
                f"found {len(fields)}"
            )


        scenario_id = int(
            fields[0],
            10,
        )

        beat = int(
            fields[1],
            10,
        )

        valid_mask = int(
            fields[2],
            16,
        )

        active_mask = int(
            fields[3],
            16,
        )

        logical_lanes = [
            int(value, 10)
            for value in fields[4:]
        ]


        rows.append(
            (
                scenario_id,
                beat,
                valid_mask,
                active_mask,
                logical_lanes,
            )
        )


    return rows


def verify_configuration(
    verilator,
    physical_lanes,
):

    beats = expected_beats(
        physical_lanes
    )


    with tempfile.TemporaryDirectory(
        prefix=(
            "a0_rtl4a_"
            f"{physical_lanes}_"
        )
    ) as temp:

        work = Path(temp)
        obj = work / "obj_dir"


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
                "a0_lane_sequencer_tb",
                (
                    "-GPHYSICAL_LANES="
                    f"{physical_lanes}"
                ),
                "--Mdir",
                str(obj),
                "-o",
                "a0_lane_sequencer_tb",
                str(
                    ROOT
                    / "rtl/core/"
                    "a0_lane_sequencer.sv"
                ),
                str(
                    ROOT
                    / "tests/rtl/"
                    "a0_lane_sequencer_tb.sv"
                ),
            ],
            cwd=ROOT,
        )


        output = run_command(
            [
                str(
                    obj
                    / "a0_lane_sequencer_tb"
                )
            ],
            cwd=work,
        )


        expected_banner = (
            "RTL4A_TB=PASS "
            f"physical={physical_lanes} "
            f"beats={beats}"
        )


        if expected_banner not in output:
            raise RuntimeError(
                "RTL4A missing PASS banner: "
                + expected_banner
            )


        rows = parse_result(
            work
            / "rtl4a_result.txt",
            physical_lanes=(
                physical_lanes
            ),
        )


    expected_row_count = (
        2
        * beats
    )


    if (
        len(rows)
        != expected_row_count
    ):
        raise RuntimeError(
            "RTL4A row-count mismatch "
            f"physical={physical_lanes} "
            f"expected={expected_row_count} "
            f"actual={len(rows)}"
        )


    row_index = 0


    for scenario_id in (
        0,
        1,
    ):

        for beat in range(
            beats
        ):

            (
                actual_scenario,
                actual_beat,
                actual_valid,
                actual_active,
                actual_lanes,
            ) = rows[
                row_index
            ]

            row_index += 1


            if (
                actual_scenario
                != scenario_id
            ):
                raise RuntimeError(
                    "RTL4A scenario mismatch "
                    f"physical={physical_lanes} "
                    f"expected={scenario_id} "
                    f"actual="
                    f"{actual_scenario}"
                )


            if actual_beat != beat:
                raise RuntimeError(
                    "RTL4A beat mismatch "
                    f"physical={physical_lanes} "
                    f"scenario={scenario_id} "
                    f"expected={beat} "
                    f"actual={actual_beat}"
                )


            (
                expected_valid,
                expected_active,
                expected_lanes,
            ) = golden_row(
                scenario_id=(
                    scenario_id
                ),
                beat=beat,
                physical_lanes=(
                    physical_lanes
                ),
            )


            if (
                actual_valid
                != expected_valid
            ):
                raise RuntimeError(
                    "RTL4A_VALID_MASK_DIFF "
                    f"physical="
                    f"{physical_lanes} "
                    f"scenario="
                    f"{scenario_id} "
                    f"beat={beat} "
                    f"python="
                    f"0x{expected_valid:X} "
                    f"rtl="
                    f"0x{actual_valid:X}"
                )


            if (
                actual_active
                != expected_active
            ):
                raise RuntimeError(
                    "RTL4A_ACTIVE_MASK_DIFF "
                    f"physical="
                    f"{physical_lanes} "
                    f"scenario="
                    f"{scenario_id} "
                    f"beat={beat} "
                    f"python="
                    f"0x{expected_active:X} "
                    f"rtl="
                    f"0x{actual_active:X}"
                )


            for physical_lane in range(
                physical_lanes
            ):
                if not (
                    (
                        expected_valid
                        >> physical_lane
                    )
                    & 1
                ):
                    continue

                if (
                    actual_lanes[
                        physical_lane
                    ]
                    != expected_lanes[
                        physical_lane
                    ]
                ):
                    raise RuntimeError(
                        "RTL4A_LANE_MAPPING_DIFF "
                        f"physical="
                        f"{physical_lanes} "
                        f"scenario="
                        f"{scenario_id} "
                        f"beat={beat} "
                        f"slot="
                        f"{physical_lane} "
                        f"python="
                        f"{expected_lanes[physical_lane]} "
                        f"rtl="
                        f"{actual_lanes[physical_lane]}"
                    )


    return (
        output.strip(),
        beats,
    )


def main():

    verilator = shutil.which(
        "verilator"
    )

    if verilator is None:
        raise RuntimeError(
            "verilator not found"
        )


    results = {}


    for physical_lanes in (
        PHYSICAL_CONFIGS
    ):

        (
            output,
            beats,
        ) = verify_configuration(
            verilator,
            physical_lanes,
        )


        print(output)

        results[
            physical_lanes
        ] = beats


    print(
        "RTL4A_DIFF=PASS"
    )

    print(
        f"WAVE_SIZE={WAVE_SIZE}"
    )


    for physical_lanes in (
        PHYSICAL_CONFIGS
    ):
        print(
            "PHYSICAL_LANES_"
            f"{physical_lanes}_BEATS="
            f"{results[physical_lanes]}"
        )


    print(
        "CONFIGURATIONS="
        f"{len(PHYSICAL_CONFIGS)}"
    )

    print(
        "SCENARIOS_PER_CONFIGURATION=2"
    )

    print(
        "LOGICAL_LANE_MAPPING=PASS"
    )

    print(
        "EXEC_MASK_MATCH=PASS"
    )

    print(
        "PREDICATION_MATCH=PASS"
    )

    print(
        "NON_DIVISIBLE_WIDTH=PASS"
    )

    print(
        "TAIL_VALID_MASK=PASS"
    )


if __name__ == "__main__":
    main()
