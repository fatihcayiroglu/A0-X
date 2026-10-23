#!/usr/bin/env python3
"""RTL8C-5A store age/source identity foundation verification."""

from __future__ import annotations

from pathlib import Path
import subprocess
import tempfile

ROOT = Path(__file__).resolve().parents[1]
CORE = ROOT / "rtl/core/a0_multi_wave_core.sv"
QUEUE = ROOT / "rtl/memory/a0_store_queue.sv"
TB = ROOT / "tests/rtl/a0_store_queue_rtl8c5_age_tb.sv"


def run(command: list[str]) -> subprocess.CompletedProcess[str]:
    result = subprocess.run(
        command,
        cwd=ROOT,
        text=True,
        stdout=subprocess.PIPE,
        stderr=subprocess.STDOUT,
    )
    print(result.stdout, end="")
    if result.returncode != 0:
        raise RuntimeError(
            f"command failed with exit code {result.returncode}: "
            + " ".join(command)
        )
    return result


def require_once(text: str, needle: str, label: str) -> None:
    count = text.count(needle)
    if count != 1:
        raise RuntimeError(f"{label}: expected 1 occurrence, found {count}")


def main() -> None:
    core = CORE.read_text()
    queue = QUEUE.read_text()

    # Static queue-contract checks are formatting-insensitive. The RTL style
    # deliberately wraps long expressions across lines.
    queue_ws = " ".join(queue.split())

    queue_contract = [
        "input logic [STORE_SEQ_W-1:0] enqueue_seq_i",
        "output logic [STORE_SEQ_W-1:0] drain_seq_o",
        "input logic [STORE_SEQ_W-1:0] probe_seq_boundary_i",
        "probe_source_valid_lane_mask_o",
        "probe_source_ambiguous_lane_mask_o",
        "probe_source_seq_o",
        "probe_source_wdata_o",
        "entry_seq_q[integer'(tail_q)] <= enqueue_seq_i;",
        "entry_seq_q[probe_entry] < probe_seq_boundary_i",
    ]
    for needle in queue_contract:
        if needle not in queue_ws:
            raise RuntimeError(f"queue age/source contract missing: {needle}")

    core_contract = [
        "parameter integer STORE_SEQ_W = 64",
        "logic [STORE_SEQ_W-1:0] store_seq_next_q;",
        "logic [STORE_SEQ_W-1:0] mem_owner_store_seq_q;",
        "logic [STORE_SEQ_W-1:0] load_order_wait_store_seq_boundary_q;",
        ".enqueue_seq_i(store_seq_next_q)",
        ".drain_seq_o(store_queue_drain_seq)",
        ".probe_seq_boundary_i(store_queue_probe_seq_boundary)",
        "store_seq_next_q + STORE_SEQ_W'(1)",
        "mem_owner_store_seq_q <= store_queue_drain_seq;",
        "load_order_wait_store_seq_boundary_q <= store_seq_next_q;",
        "store_queue_probe_seq_boundary = store_seq_next_q;",
        "store_queue_probe_seq_boundary =\n                load_order_wait_store_seq_boundary_q;",
        "load_store_source_valid_lane_mask",
        "load_store_source_ambiguous_lane_mask",
        "load_store_source_seq",
        "load_store_source_wdata",
    ]
    for needle in core_contract:
        if needle not in core:
            raise RuntimeError(f"core age/source contract missing: {needle}")

    require_once(
        core,
        "mem_owner_store_seq_q <= store_queue_drain_seq;",
        "physical store sequence snapshot",
    )
    require_once(
        core,
        "load_order_wait_store_seq_boundary_q <= store_seq_next_q;",
        "held load sequence boundary snapshot",
    )

    with tempfile.TemporaryDirectory(prefix="a0_rtl8c5_age_") as td:
        obj_dir = Path(td) / "obj_dir"
        run(
            [
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
                "a0_store_queue_rtl8c5_age_tb",
                "--Mdir",
                str(obj_dir),
                str(QUEUE),
                str(TB),
            ]
        )
        simulation = run([str(obj_dir / "Va0_store_queue_rtl8c5_age_tb")])

    required = [
        "RTL8C5_QUEUE_SEQUENCE_ORDER=PASS",
        "RTL8C5_PROBE_IGNORES_YOUNGER_STORE=PASS",
        "RTL8C5_PROBE_SELECTS_YOUNGEST_OLDER=PASS",
        "RTL8C5_DUPLICATE_STORE_SOURCE_AMBIGUOUS=PASS",
        "RTL8C5_STORE_QUEUE_AGE_SOURCE_TB=PASS",
    ]
    missing = [marker for marker in required if marker not in simulation.stdout]
    if missing:
        raise RuntimeError(
            "missing RTL8C-5A PASS marker(s): " + ", ".join(missing)
        )

    print("RTL8C5A_QUEUE_AGE_SOURCE_FOUNDATION=PASS")


if __name__ == "__main__":
    main()
