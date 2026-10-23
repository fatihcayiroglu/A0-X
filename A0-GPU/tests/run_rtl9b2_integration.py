#!/usr/bin/env python3

from pathlib import Path
import subprocess
import tempfile

ROOT = Path(__file__).resolve().parents[1]

L1 = ROOT / "rtl/memory/a0_l1_line_cache.sv"
BOUNDARY = ROOT / "rtl/memory/a0_memory_service_boundary.sv"
CORE = ROOT / "rtl/core/a0_multi_wave_core.sv"
TB = ROOT / "tests/rtl/a0_memory_service_boundary_rtl9b2_tb.sv"

MARKERS = [
    "RTL9B2_RESET_CACHE_INVALID=PASS",
    "RTL9B2_LEGACY_READ_BYPASS_UNCHANGED=PASS",
    "RTL9B2_LEGACY_RESPONSE_BYPASS_UNCHANGED=PASS",
    "RTL9B2_LEGACY_STORE_BYPASS_UNCHANGED=PASS",
    "RTL9B2_LEGACY_STORE_INVALIDATES_L1=PASS",
    "RTL9B2_LINE_COLD_MISS_REACHES_BACKEND=PASS",
    "RTL9B2_REFILL_REACHES_MSHR=PASS",
    "RTL9B2_REFILL_INSTALLS_L1=PASS",
    "RTL9B2_SECOND_LINE_REQUEST_HITS_L1=PASS",
    "RTL9B2_L1_HIT_SUPPRESSES_BACKEND_REQUEST=PASS",
    "RTL9B2_ENTRY_TAG_PRESERVED=PASS",
    "RTL9B2_LINE_ADDRESS_PRESERVED=PASS",
    "RTL9B2_FAULTED_REFILL_FORWARDED=PASS",
    "RTL9B2_FAULTED_REFILL_NOT_CACHED=PASS",
    "RTL9B2_STORE_KILLS_OUTSTANDING_REFILL=PASS",
    "RTL9B2_KILLED_REFILL_STILL_FORWARDED=PASS",
    "RTL9B2_KILLED_REFILL_NOT_CACHED=PASS",
    "RTL9B2_SAME_CYCLE_STORE_REFILL_INVALIDATE_WINS=PASS",
    "RTL9B2_LEGACY_AND_LINE_CHANNEL_INDEPENDENCE=PASS",
    "RTL9B2_MEMORY_SERVICE_BOUNDARY_INTEGRATION_TB=PASS",
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
        raise RuntimeError(
            "command failed: " + " ".join(cmd)
        )

    return result.stdout


def main():
    boundary = BOUNDARY.read_text(encoding="utf-8")
    core = CORE.read_text(encoding="utf-8")

    for token in [
        "a0_l1_line_cache #(",
        ".store_valid_i(",
        "legacy_req_valid_i",
        "legacy_req_write_i",
        ".line_mem_req_valid_o(line_req_valid_o)",
        ".line_mem_resp_valid_i(line_resp_valid_i)",
    ]:
        if token not in boundary:
            raise RuntimeError(
                "boundary integration missing: " + token
            )

    start = core.index("a0_memory_service_boundary #(")
    end = core.index(
        "a0_wave_load_mshr_bridge #(",
        start,
    )

    instance = core[start:end]

    for token in [
        ".MSHR_COUNT(MSHR_COUNT)",
        ".L1_SET_COUNT(64)",
        ".clk(clk)",
        ".rst_n(rst_n)",
    ]:
        if token not in instance:
            raise RuntimeError(
                "core boundary integration missing: "
                + token
            )

    with tempfile.TemporaryDirectory(
        prefix="a0_rtl9b2_"
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
            "a0_memory_service_boundary_rtl9b2_tb",
            "--Mdir",
            str(obj),
            str(L1),
            str(BOUNDARY),
            str(TB),
        ])

        exe = (
            obj
            / "Va0_memory_service_boundary_rtl9b2_tb"
        )

        if not exe.exists():
            raise RuntimeError(
                "RTL9B2 integration executable missing"
            )

        output += run([str(exe)])

    missing = [
        marker
        for marker in MARKERS
        if marker not in output
    ]

    if missing:
        raise RuntimeError(
            "missing markers: "
            + ", ".join(missing)
        )

    print("RTL9B2_INTEGRATION_DRIVER=PASS")


if __name__ == "__main__":
    main()
