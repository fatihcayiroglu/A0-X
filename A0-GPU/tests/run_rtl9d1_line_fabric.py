#!/usr/bin/env python3

from pathlib import Path
import subprocess
import tempfile


ROOT = Path(__file__).resolve().parents[1]

RTL = ROOT / "rtl/memory/a0_line_request_fabric.sv"

TB = ROOT / "tests/rtl/a0_line_request_fabric_tb.sv"


MARKERS = [
    "RTL9D1_RESET_IDLE=PASS",
    "RTL9D1_GLOBAL_REQUESTER_TAG_ENCODE=PASS",
    "RTL9D1_REQUEST_LINE_PRESERVED=PASS",
    "RTL9D1_BACKPRESSURE_PAYLOAD_STABLE=PASS",
    "RTL9D1_BACKPRESSURE_BLOCKS_SECOND_ACCEPT=PASS",
    "RTL9D1_ROUND_ROBIN_FAIRNESS=PASS",
    "RTL9D1_NO_REQUEST_LOSS_OR_DUPLICATION=PASS",
    "RTL9D1_OUT_OF_ORDER_RESPONSE_DEMUX=PASS",
    "RTL9D1_LOCAL_TAG_RESTORED=PASS",
    "RTL9D1_RESPONSE_PAYLOAD_PRESERVED=PASS",
    "RTL9D1_INVALID_REQUESTER_TAG_REJECTED=PASS",
    "RTL9D1_MALFORMED_RESPONSE_NO_FANOUT=PASS",
    "RTL9D1_LINE_REQUEST_FABRIC_TB=PASS",
]


def run(cmd):
    result = subprocess.run(
        cmd,
        cwd=ROOT,
        text=True,
        stdout=subprocess.PIPE,
        stderr=subprocess.STDOUT,
    )

    print(
        result.stdout,
        end="",
    )

    if result.returncode:
        raise RuntimeError(
            "command failed: "
            + " ".join(cmd)
        )

    return result.stdout


def main():
    text = RTL.read_text(
        encoding="utf-8"
    )

    required = [
        "module a0_line_request_fabric",
        "parameter integer CLIENT_COUNT = 4",
        "parameter integer LOCAL_TAG_W = 2",
        "parameter integer CLIENT_ID_W =",
        "parameter integer GLOBAL_TAG_W =",
        "logic [CLIENT_ID_W-1:0] rr_q",
        "logic hold_valid_q",
        "slot_available",
        "grant_found",
        "line_resp_tag_error_o",
        "client_id_valid",
        "line_req_global_tag_o = {",
    ]

    for token in required:
        if token not in text:
            raise RuntimeError(
                "RTL9D-1 fabric contract missing: "
                + token
            )

    with tempfile.TemporaryDirectory(
        prefix="a0_rtl9d1_behavior_"
    ) as temp:

        obj = Path(temp) / "obj_dir"

        output = run([
            "verilator",
            "--binary",
            "--timing",
            "-Wall",
            "-Werror-PINMISSING",
            "-Werror-WIDTHEXPAND",
            "-Werror-WIDTHTRUNC",
            "--top-module",
            "a0_line_request_fabric_tb",
            "--Mdir",
            str(obj),
            str(RTL),
            str(TB),
        ])

        exe = (
            obj
            / "Va0_line_request_fabric_tb"
        )

        if not exe.exists():
            raise RuntimeError(
                "RTL9D-1 executable missing"
            )

        output += run([
            str(exe),
        ])

    missing = [
        marker
        for marker in MARKERS
        if marker not in output
    ]

    if missing:
        raise RuntimeError(
            "missing RTL9D-1 behavioral markers: "
            + ", ".join(missing)
        )

    print(
        "RTL9D1_BEHAVIORAL_MARKERS=PASS "
        f"count={len(MARKERS)}"
    )

    # Verify both power-of-two and non-power-of-two client counts.
    for client_count in (
        1,
        3,
        4,
        5,
    ):
        with tempfile.TemporaryDirectory(
            prefix=(
                "a0_rtl9d1_clients_"
                f"{client_count}_"
            )
        ) as temp:

            run([
                "verilator",
                "--lint-only",
                "-Wall",
                "-Werror-PINMISSING",
                "-Werror-WIDTHEXPAND",
                "-Werror-WIDTHTRUNC",
                "--top-module",
                "a0_line_request_fabric",
                f"-GCLIENT_COUNT={client_count}",
                "--Mdir",
                str(
                    Path(temp)
                    / "obj_dir"
                ),
                str(RTL),
            ])

        print(
            "RTL9D1_CLIENT_COUNT_VARIANT=PASS "
            f"CLIENT_COUNT={client_count}"
        )

    print(
        "RTL9D1_CLIENT_COUNT_PARAMETERIZATION=PASS"
    )

    print(
        "RTL9D1_LINE_FABRIC_DRIVER=PASS"
    )


if __name__ == "__main__":
    main()
