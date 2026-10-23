#!/usr/bin/env python3

from pathlib import Path
import subprocess
import tempfile


ROOT = Path(__file__).resolve().parents[1]

FABRIC = (
    ROOT
    / "rtl/memory/a0_line_request_fabric.sv"
)

L2 = (
    ROOT
    / "rtl/memory/a0_l2_line_cache.sv"
)

WRAPPER = (
    ROOT
    / "rtl/memory/a0_shared_l2_subsystem.sv"
)

TB = (
    ROOT
    / "tests/rtl/a0_shared_l2_subsystem_tb.sv"
)


MARKERS = [
    "RTL9D3_RESET_IDLE=PASS",

    "RTL9D3_CLIENT0_COLD_MISS_REACHES_EXTERNAL_BACKEND=PASS",
    "RTL9D3_FABRIC_GLOBAL_TAG_REACHES_L2_OPAQUELY=PASS",
    "RTL9D3_L2_GLOBAL_TAG_REACHES_BACKEND_UNCHANGED=PASS",
    "RTL9D3_BACKEND_REFILL_ROUTES_TO_CLIENT0=PASS",
    "RTL9D3_CLIENT0_LOCAL_TAG_RESTORED=PASS",

    "RTL9D3_CLIENT1_SAME_LINE_HITS_SHARED_L2=PASS",
    "RTL9D3_CROSS_CLIENT_L2_HIT_SUPPRESSES_BACKEND=PASS",
    "RTL9D3_CLIENT1_LOCAL_TAG_RESTORED=PASS",

    "RTL9D3_SAME_LOCAL_TAG_DIFFERENT_CLIENT_GLOBAL_TAG_UNIQUE=PASS",
    "RTL9D3_SAME_LOCAL_TAG_DIFFERENT_CLIENT_CONCURRENT_MISSES=PASS",

    "RTL9D3_MULTI_CLIENT_MULTIPLE_OUTSTANDING_MISSES=PASS",
    "RTL9D3_EXTERNAL_BACKEND_OOO_RESPONSES=PASS",
    "RTL9D3_OOO_RESPONSES_ROUTE_TO_CORRECT_CLIENTS=PASS",
    "RTL9D3_OOO_LOCAL_TAGS_RESTORED=PASS",

    "RTL9D3_L2_MISS_TRACKER_FULL_BACKPRESSURES_FABRIC=PASS",
    "RTL9D3_FABRIC_BACKPRESSURE_PAYLOAD_STABLE=PASS",
    "RTL9D3_FABRIC_ROUND_ROBIN_FAIRNESS_WITH_L2=PASS",

    "RTL9D3_CLIENT1_STORE_INVALIDATES_CLIENT0_SHARED_LINE=PASS",
    "RTL9D3_CROSS_CLIENT_LOAD_AFTER_STORE_MISSES=PASS",

    "RTL9D3_CLIENT2_STORE_KILLS_CLIENT0_OUTSTANDING_REFILL=PASS",
    "RTL9D3_CROSS_CLIENT_KILLED_REFILL_STILL_ROUTED=PASS",
    "RTL9D3_CROSS_CLIENT_KILLED_REFILL_NOT_INSTALLED=PASS",

    "RTL9D3_CROSS_CLIENT_SAME_CYCLE_STORE_REFILL_STORE_WINS=PASS",

    "RTL9D3_MULTI_CLIENT_SIMULTANEOUS_STORE_FANIN=PASS",
    "RTL9D3_MULTI_CLIENT_STORE_INVALIDATES_MULTIPLE_LINES=PASS",

    "RTL9D3_FAULTED_BACKEND_REFILL_ROUTES_TO_ORIGIN=PASS",
    "RTL9D3_FAULTED_BACKEND_REFILL_NOT_INSTALLED=PASS",

    "RTL9D3_MALFORMED_GLOBAL_REQUESTER_TAG_REJECTED=PASS",
    "RTL9D3_MALFORMED_GLOBAL_REQUESTER_TAG_NO_CLIENT_FANOUT=PASS",
    "RTL9D3_MALFORMED_GLOBAL_REQUESTER_TAG_ERROR_ASSERTED=PASS",

    "RTL9D3_FINAL_L2_MISS_TRACKER_DRAIN=PASS",
    "RTL9D3_FINAL_FABRIC_IDLE=PASS",

    "RTL9D3_SHARED_L2_INTEGRATION_TB=PASS",
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


def lint_variant(
    *,
    client_count=4,
    local_tag_w=2,
    l2_set_count=256,
    l2_miss_count=16,
    store_lanes_per_client=32,
):
    with tempfile.TemporaryDirectory(
        prefix="a0_rtl9d3_lint_"
    ) as temp:

        run([
            "verilator",
            "--lint-only",
            "-Wall",
            "-Werror-PINMISSING",
            "-Werror-WIDTHEXPAND",
            "-Werror-WIDTHTRUNC",
            "--top-module",
            "a0_shared_l2_subsystem",
            f"-GCLIENT_COUNT={client_count}",
            f"-GLOCAL_TAG_W={local_tag_w}",
            f"-GL2_SET_COUNT={l2_set_count}",
            f"-GL2_MISS_COUNT={l2_miss_count}",
            (
                "-GSTORE_LANES_PER_CLIENT="
                f"{store_lanes_per_client}"
            ),
            "--Mdir",
            str(
                Path(temp)
                / "obj_dir"
            ),
            str(FABRIC),
            str(L2),
            str(WRAPPER),
        ])


def main():
    wrapper_text = WRAPPER.read_text(
        encoding="utf-8"
    )

    required = [
        "module a0_shared_l2_subsystem",
        "parameter integer CLIENT_COUNT = 4",
        "parameter integer LOCAL_TAG_W = 2",
        "parameter integer STORE_LANES_PER_CLIENT = 32",
        "parameter integer LINE_WORDS = 8",
        "parameter integer L2_SET_COUNT = 256",
        "parameter integer L2_MISS_COUNT = 16",

        "CLIENT_ID_W",
        "GLOBAL_TAG_W",
        "L2_STORE_LANES",

        "a0_line_request_fabric",
        "a0_l2_line_cache",

        "fabric_line_req_valid",
        "fabric_line_req_global_tag",
        "fabric_line_req_line_addr",

        "l2_store_valid",
        "l2_store_lane_mask",
        "l2_store_word_addr",

        "line_resp_tag_error_o",
    ]

    for token in required:
        if token not in wrapper_text:
            raise RuntimeError(
                "RTL9D-3 static contract missing: "
                + token
            )

    forbidden = [
        "a0_multi_wave_core",
        "a0_memory_service_boundary",
        "a0_l1_line_cache",
    ]

    for token in forbidden:
        if token in wrapper_text:
            raise RuntimeError(
                "RTL9D-3 production/lower-boundary "
                "integration forbidden: "
                + token
            )

    with tempfile.TemporaryDirectory(
        prefix="a0_rtl9d3_behavior_"
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
            "a0_shared_l2_subsystem_tb",
            "--Mdir",
            str(obj),
            str(FABRIC),
            str(L2),
            str(WRAPPER),
            str(TB),
        ])

        exe = (
            obj
            / "Va0_shared_l2_subsystem_tb"
        )

        if not exe.exists():
            raise RuntimeError(
                "RTL9D-3 behavioral executable missing"
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
            "missing RTL9D-3 markers: "
            + ", ".join(missing)
        )

    print(
        "RTL9D3_BEHAVIORAL_MARKERS=PASS "
        f"count={len(MARKERS)}"
    )

    for client_count in (
        1,
        3,
        4,
        5,
    ):
        lint_variant(
            client_count=client_count,
        )

        print(
            "RTL9D3_CLIENT_COUNT_VARIANT=PASS "
            f"CLIENT_COUNT={client_count}"
        )

    for local_tag_w in (
        1,
        2,
        4,
    ):
        lint_variant(
            local_tag_w=local_tag_w,
        )

        print(
            "RTL9D3_LOCAL_TAG_WIDTH_VARIANT=PASS "
            f"LOCAL_TAG_W={local_tag_w}"
        )

    for miss_count in (
        1,
        4,
        16,
    ):
        lint_variant(
            l2_miss_count=miss_count,
        )

        print(
            "RTL9D3_L2_MISS_COUNT_VARIANT=PASS "
            f"L2_MISS_COUNT={miss_count}"
        )

    for store_lanes in (
        1,
        2,
        32,
    ):
        lint_variant(
            store_lanes_per_client=store_lanes,
        )

        print(
            "RTL9D3_STORE_LANES_PER_CLIENT_VARIANT=PASS "
            f"STORE_LANES_PER_CLIENT={store_lanes}"
        )

    for set_count in (
        1,
        4,
        64,
        256,
    ):
        lint_variant(
            l2_set_count=set_count,
        )

        print(
            "RTL9D3_L2_SET_COUNT_VARIANT=PASS "
            f"L2_SET_COUNT={set_count}"
        )

    print(
        "RTL9D3_PARAMETERIZATION=PASS"
    )

    print(
        "RTL9D3_SHARED_L2_INTEGRATION_DRIVER=PASS"
    )


if __name__ == "__main__":
    main()
