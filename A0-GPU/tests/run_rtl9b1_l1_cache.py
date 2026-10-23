#!/usr/bin/env python3
from pathlib import Path
import subprocess
import tempfile

ROOT = Path(__file__).resolve().parents[1]
RTL = ROOT / "rtl/memory/a0_l1_line_cache.sv"
TB = ROOT / "tests/rtl/a0_l1_line_cache_tb.sv"

MARKERS = [
    "RTL9B1_RESET_INVALID=PASS",
    "RTL9B1_COLD_MISS_PASSTHROUGH=PASS",
    "RTL9B1_SUCCESSFUL_REFILL_INSTALL=PASS",
    "RTL9B1_SECOND_REQUEST_HIT_NO_BACKEND=PASS",
    "RTL9B1_HIT_RESPONSE_ONE_CYCLE_BUFFER=PASS",
    "RTL9B1_BACKEND_RESPONSE_BEATS_BUFFERED_HIT=PASS",
    "RTL9B1_BUFFERED_HIT_SURVIVES_BACKEND_COLLISION=PASS",
    "RTL9B1_FAULTED_REFILL_NOT_INSTALLED=PASS",
    "RTL9B1_STORE_INVALIDATES_MATCHING_LINE=PASS",
    "RTL9B1_STORE_OTHER_LINE_DOES_NOT_INVALIDATE=PASS",
    "RTL9B1_MULTI_LANE_STORE_INVALIDATES_MULTIPLE_LINES=PASS",
    "RTL9B1_STORE_FAULT_CONSERVATIVE_INVALIDATION=PASS",
    "RTL9B1_STORE_KILLS_OUTSTANDING_MATCHING_REFILL=PASS",
    "RTL9B1_KILLED_REFILL_STILL_FORWARDED_TO_MSHR=PASS",
    "RTL9B1_KILLED_REFILL_NOT_INSTALLED=PASS",
    "RTL9B1_SAME_CYCLE_STORE_REFILL_INVALIDATE_WINS=PASS",
    "RTL9B1_DIRECT_MAPPED_CONFLICT_REPLACEMENT=PASS",
    "RTL9B1_ENTRY_TAG_PRESERVATION=PASS",
    "RTL9B1_LINE_ADDRESS_PRESERVATION=PASS",
    "RTL9B1_L1_LINE_CACHE_TB=PASS",
]

def run(cmd):
    result = subprocess.run(
        cmd,
        cwd=ROOT,
        text=True,
        stdout=subprocess.PIPE,
        stderr=subprocess.STDOUT,
    )
    print(result.stdout, end="")
    if result.returncode:
        raise RuntimeError("command failed: " + " ".join(cmd))
    return result.stdout

def main():
    text = RTL.read_text()

    required = [
        "module a0_l1_line_cache",
        "parameter integer SET_COUNT = 64",
        "parameter integer LINE_WORDS = 8",
        "hit_buf_valid_q",
        "miss_kill_q",
        "store_conflicts_line",
        "refill_install",
    ]
    for token in required:
        if token not in text:
            raise RuntimeError("L1 primitive contract missing: " + token)

    with tempfile.TemporaryDirectory(prefix="a0_rtl9b1_") as temp:
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
            "a0_l1_line_cache_tb",
            "--Mdir",
            str(obj),
            str(RTL),
            str(TB),
        ])

        exe = obj / "Va0_l1_line_cache_tb"
        if not exe.exists():
            raise RuntimeError("RTL9B-1 executable missing")

        output += run([str(exe)])

    missing = [marker for marker in MARKERS if marker not in output]
    if missing:
        raise RuntimeError(
            "missing RTL9B-1 behavioral markers: " + ", ".join(missing)
        )

    # Parameterization is proven independently from the behavioral TB.
    for set_count in (1, 4, 64, 128):
        with tempfile.TemporaryDirectory(
            prefix=f"a0_rtl9b1_sets_{set_count}_"
        ) as temp:
            run([
                "verilator",
                "--lint-only",
                "-Wall",
                "-Werror-PINMISSING",
                "-Werror-WIDTHEXPAND",
                "-Werror-WIDTHTRUNC",
                "--top-module",
                "a0_l1_line_cache",
                f"-GSET_COUNT={set_count}",
                "--Mdir",
                str(Path(temp) / "obj_dir"),
                str(RTL),
            ])

        print(
            "RTL9B1_SET_COUNT_VARIANT=PASS "
            f"SET_COUNT={set_count}"
        )

    print("RTL9B1_SET_COUNT_PARAMETERIZATION=PASS")
    print("RTL9B1_L1_LINE_CACHE_DRIVER=PASS")

if __name__ == "__main__":
    main()
