#!/usr/bin/env python3

from pathlib import Path
import subprocess
import tempfile


ROOT = Path(__file__).resolve().parents[1]

RTL = ROOT / "rtl/memory/a0_l2_line_cache.sv"

TB = ROOT / "tests/rtl/a0_l2_line_cache_tb.sv"


MARKERS = [
    "RTL9D2_RESET_INVALID=PASS",
    "RTL9D2_COLD_MISS_REACHES_BACKEND=PASS",
    "RTL9D2_REQUEST_GLOBAL_TAG_PRESERVED_TO_BACKEND=PASS",
    "RTL9D2_SUCCESSFUL_REFILL_FORWARDED=PASS",
    "RTL9D2_SUCCESSFUL_REFILL_INSTALLS=PASS",
    "RTL9D2_SECOND_REQUEST_HITS_L2=PASS",
    "RTL9D2_L2_HIT_SUPPRESSES_BACKEND=PASS",
    "RTL9D2_HIT_GLOBAL_TAG_PRESERVED=PASS",
    "RTL9D2_SHARED_LINE_REUSE_ACROSS_DIFFERENT_GLOBAL_TAGS=PASS",
    "RTL9D2_DIRECT_MAPPED_CONFLICT_REPLACEMENT=PASS",
    "RTL9D2_MULTIPLE_OUTSTANDING_MISSES=PASS",
    "RTL9D2_OUT_OF_ORDER_BACKEND_RESPONSES=PASS",
    "RTL9D2_OUT_OF_ORDER_TAG_PRESERVATION=PASS",
    "RTL9D2_MISS_SLOT_FULL_BACKPRESSURE=PASS",
    "RTL9D2_REFILL_FREES_MISS_SLOT=PASS",
    "RTL9D2_SAME_GLOBAL_TAG_BUSY_BACKPRESSURE=PASS",
    "RTL9D2_BACKEND_RESPONSE_BEATS_BUFFERED_HIT=PASS",
    "RTL9D2_BUFFERED_HIT_SURVIVES_BACKEND_COLLISION=PASS",
    "RTL9D2_FAULTED_REFILL_FORWARDED=PASS",
    "RTL9D2_FAULTED_REFILL_NOT_INSTALLED=PASS",
    "RTL9D2_STORE_INVALIDATES_MATCHING_CACHED_LINE=PASS",
    "RTL9D2_STORE_OTHER_LINE_PRESERVES_CACHED_LINE=PASS",
    "RTL9D2_MULTI_LANE_STORE_INVALIDATES_MULTIPLE_LINES=PASS",
    "RTL9D2_STORE_KILLS_OUTSTANDING_REFILL=PASS",
    "RTL9D2_KILLED_REFILL_STILL_FORWARDED=PASS",
    "RTL9D2_KILLED_REFILL_NOT_INSTALLED=PASS",
    "RTL9D2_SAME_CYCLE_STORE_REFILL_INVALIDATE_WINS=PASS",
    "RTL9D2_UNTRACKED_BACKEND_RESPONSE_FORWARDED=PASS",
    "RTL9D2_UNTRACKED_BACKEND_RESPONSE_NOT_INSTALLED=PASS",
    "RTL9D2_FINAL_MISS_TRACKER_DRAIN=PASS",
    "RTL9D2_SHARED_L2_LINE_CACHE_TB=PASS",
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
    set_count=256,
    miss_count=16,
    global_tag_w=4,
    store_lanes=32,
):
    with tempfile.TemporaryDirectory(
        prefix="a0_rtl9d2_lint_"
    ) as temp:
        run([
            "verilator",
            "--lint-only",
            "-Wall",
            "-Werror-PINMISSING",
            "-Werror-WIDTHEXPAND",
            "-Werror-WIDTHTRUNC",
            "--top-module",
            "a0_l2_line_cache",
            f"-GSET_COUNT={set_count}",
            f"-GMISS_COUNT={miss_count}",
            f"-GGLOBAL_TAG_W={global_tag_w}",
            f"-GSTORE_LANES={store_lanes}",
            "--Mdir",
            str(
                Path(temp)
                / "obj_dir"
            ),
            str(RTL),
        ])


def main():
    rtl_text = RTL.read_text(
        encoding="utf-8"
    )

    required = [
        "module a0_l2_line_cache",
        "parameter integer STORE_LANES = 32",
        "parameter integer LINE_WORDS = 8",
        "parameter integer SET_COUNT = 256",
        "parameter integer GLOBAL_TAG_W = 4",
        "parameter integer MISS_COUNT = 16",
        "logic miss_valid_q [0:MISS_COUNT-1]",
        "miss_global_tag_q [0:MISS_COUNT-1]",
        "miss_line_q [0:MISS_COUNT-1]",
        "miss_kill_q [0:MISS_COUNT-1]",
        "logic hit_buf_valid_q",
        "store_conflicts_line",
        "resp_track_match",
        "refill_install",
        "line_mem_req_global_tag_o =",
        "line_resp_global_tag_o =",
    ]

    for token in required:
        if token not in rtl_text:
            raise RuntimeError(
                "RTL9D-2 static contract missing: "
                + token
            )

    with tempfile.TemporaryDirectory(
        prefix="a0_rtl9d2_behavior_"
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
            "a0_l2_line_cache_tb",
            "--Mdir",
            str(obj),
            str(RTL),
            str(TB),
        ])

        exe = (
            obj
            / "Va0_l2_line_cache_tb"
        )

        if not exe.exists():
            raise RuntimeError(
                "RTL9D-2 behavioral executable missing"
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
            "missing RTL9D-2 markers: "
            + ", ".join(missing)
        )

    print(
        "RTL9D2_BEHAVIORAL_MARKERS=PASS "
        f"count={len(MARKERS)}"
    )

    for set_count in (
        1,
        4,
        64,
        256,
    ):
        lint_variant(
            set_count=set_count,
        )

        print(
            "RTL9D2_SET_COUNT_VARIANT=PASS "
            f"SET_COUNT={set_count}"
        )

    for miss_count in (
        1,
        4,
        16,
        32,
    ):
        lint_variant(
            miss_count=miss_count,
        )

        print(
            "RTL9D2_MISS_COUNT_VARIANT=PASS "
            f"MISS_COUNT={miss_count}"
        )

    for global_tag_w in (
        1,
        4,
        8,
    ):
        lint_variant(
            global_tag_w=global_tag_w,
        )

        print(
            "RTL9D2_GLOBAL_TAG_WIDTH_VARIANT=PASS "
            f"GLOBAL_TAG_W={global_tag_w}"
        )

    for store_lanes in (
        1,
        4,
        32,
    ):
        lint_variant(
            store_lanes=store_lanes,
        )

        print(
            "RTL9D2_STORE_LANES_VARIANT=PASS "
            f"STORE_LANES={store_lanes}"
        )

    print(
        "RTL9D2_PARAMETERIZATION=PASS"
    )

    print(
        "RTL9D2_SHARED_L2_DRIVER=PASS"
    )


if __name__ == "__main__":
    main()
