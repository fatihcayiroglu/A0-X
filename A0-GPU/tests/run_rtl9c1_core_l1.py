#!/usr/bin/env python3

from __future__ import annotations

from pathlib import Path
import hashlib
import subprocess
import tempfile


ROOT = Path(__file__).resolve().parents[1]

EXPECTED_CORE_HEADER_SHA = (
    "ee30da079c32944d47ee76f57664b6bc"
    "c614ed2ed712096649d956eda41f7a8a"
)

SOURCES = [
    ROOT / "rtl/core/a0_scoreboard.sv",
    ROOT / "rtl/core/a0_dependency_classifier.sv",
    ROOT / "rtl/core/a0_lane_sequencer.sv",
    ROOT / "rtl/core/a0_operand_collector.sv",
    ROOT / "rtl/core/a0_regfile_banked_contexted.sv",
    ROOT / "rtl/core/a0_vector_operand_path_contexted.sv",

    ROOT / "rtl/scheduler/a0_wave_context_file.sv",
    ROOT / "rtl/scheduler/a0_wave_scheduler.sv",
    ROOT / "rtl/scheduler/a0_multi_wave_frontend.sv",
    ROOT / "rtl/scheduler/a0_wave_scoreboard_bank.sv",

    ROOT / "rtl/memory/a0_mshr_table.sv",
    ROOT / "rtl/memory/a0_wave_load_mshr_bridge.sv",
    ROOT / "rtl/memory/a0_store_queue.sv",
    ROOT / "rtl/memory/a0_l1_line_cache.sv",
    ROOT / "rtl/memory/a0_memory_service_boundary.sv",

    ROOT / "rtl/core/a0_multi_wave_core.sv",

    ROOT / "tests/rtl/a0_multi_wave_core_rtl9c1_l1_tb.sv",
]

MARKERS = [
    "RTL9C1_COLD_LOAD_MISS_REACHES_BACKEND=PASS",
    "RTL9C1_NO_LEGACY_READ_REQUEST=PASS",

    "RTL9C1_REFILL_COMPLETES_LOAD=PASS",
    "RTL9C1_REFILL_DATA_REACHES_WAVE=PASS",

    "RTL9C1_SECOND_SAME_LINE_LOAD_ACCEPTED=PASS",
    "RTL9C1_SECOND_SAME_LINE_LOAD_HITS_L1=PASS",
    "RTL9C1_HIT_SUPPRESSES_BACKEND_REQUEST=PASS",
    "RTL9C1_HIT_DATA_REACHES_WAVE=PASS",

    "RTL9C1_STORE_TO_CACHED_LINE_LAUNCHES_LEGACY=PASS",
    "RTL9C1_STORE_TO_CACHED_LINE_INVALIDATES=PASS",
    "RTL9C1_LOAD_AFTER_STORE_MISSES_AGAIN=PASS",

    "RTL9C1_STORE_OTHER_LINE_PRESERVES_CACHED_LINE=PASS",

    "RTL9C1_MULTI_WAVE_SAME_LINE_HIT=PASS",

    "RTL9C1_FINAL_MSHR_DRAIN=PASS",
    "RTL9C1_FAULTED_LOAD_MISS_REACHES_BACKEND=PASS",
    "RTL9C1_FAULTED_REFILL_FORWARDED_TO_CORE=PASS",
    "RTL9C1_FAULTED_REFILL_NOT_CACHED=PASS",
    "RTL9C1_FAULT_RETRY_SAME_LINE_MISSES_AGAIN=PASS",
    "RTL9C1_FAULT_RETRY_SUCCESS_DATA_REACHES_WAVE=PASS",
    "RTL9C1_CORE_L1_END_TO_END_TB=PASS",
]


def run(command: list[str]) -> str:
    result = subprocess.run(
        command,
        cwd=ROOT,
        text=True,
        stdout=subprocess.PIPE,
        stderr=subprocess.STDOUT,
    )

    print(result.stdout, end="")

    if result.returncode:
        raise RuntimeError(
            "command failed rc="
            f"{result.returncode}: "
            + " ".join(map(str, command))
        )

    return result.stdout


def core_header() -> str:
    text = (
        ROOT
        / "rtl/core/a0_multi_wave_core.sv"
    ).read_text(encoding="utf-8")

    start = text.index(
        "module a0_multi_wave_core"
    )

    depth = 0
    saw = False

    for i in range(start, len(text)):
        ch = text[i]

        if ch == "(":
            depth += 1
            saw = True

        elif ch == ")":
            depth -= 1

        elif ch == ";" and saw and depth == 0:
            return text[start:i + 1]

    raise RuntimeError(
        "core module header unterminated"
    )


def main() -> None:
    actual_header_sha = hashlib.sha256(
        core_header().encode()
    ).hexdigest()

    print(
        "RTL9C1_CORE_EXTERNAL_HEADER_SHA256="
        + actual_header_sha
    )

    if actual_header_sha != EXPECTED_CORE_HEADER_SHA:
        raise RuntimeError(
            "core external port contract changed"
        )

    print(
        "RTL9C1_CORE_EXTERNAL_PORT_CONTRACT_UNCHANGED=PASS"
    )

    for source in SOURCES:
        if not source.is_file():
            raise RuntimeError(
                f"missing RTL9C1 source: {source}"
            )

    with tempfile.TemporaryDirectory(
        prefix="a0_rtl9c1_core_l1_"
    ) as temp:
        obj_dir = Path(temp) / "obj_dir"

        run([
            "verilator",
            "--binary",
            "--timing",
            "-Wall",
            "-Wno-BLKSEQ",
            "-Wno-UNUSEDSIGNAL",
            "-Wno-UNUSEDPARAM",
            "-Werror-PINMISSING",
            "-Werror-WIDTHEXPAND",
            "-Werror-WIDTHTRUNC",
            "--top-module",
            "a0_multi_wave_core_rtl9c1_l1_tb",
            "--Mdir",
            str(obj_dir),
            *map(str, SOURCES),
        ])

        exe = (
            obj_dir
            / "Va0_multi_wave_core_rtl9c1_l1_tb"
        )

        if not exe.is_file():
            raise RuntimeError(
                "RTL9C1 executable missing"
            )

        output = run([str(exe)])

    missing = [
        marker
        for marker in MARKERS
        if marker not in output
    ]

    if missing:
        raise RuntimeError(
            "missing RTL9C1 marker(s): "
            + ", ".join(missing)
        )

    print(
        "RTL9C1_TARGETED_MARKERS=PASS "
        f"count={len(MARKERS)}"
    )

    print("RTL9C1_CORE_L1_DRIVER=PASS")


if __name__ == "__main__":
    main()
