#!/usr/bin/env python3
"""RTL8C-5B1 queued + RTL8C-5B2 physical fault-safe forwarding integration."""

from pathlib import Path
import subprocess
import tempfile

ROOT = Path(__file__).resolve().parents[1]

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
    ROOT / "tests/rtl/a0_multi_wave_core_rtl8c_load_bypass_tb.sv",
]

MARKERS = [
    "RTL8C5B1_YOUNGER_STORE_BLOCKED_BY_OLDER_LOAD=PASS",
    "RTL8C5B1_QUEUED_PARTIAL_FORWARD_NO_MISS=PASS",
    "RTL8C5B1_DEPENDENCY_OVERRIDE_RESPECTS_OLDER_MSHR=PASS",
    "RTL8C_SAME_LINE_DIFFERENT_WORD_LOAD_HOLD=PASS",
    "RTL8C_LOAD_ORDER_WAIT_ENGINE_RELEASE=PASS",
    "RTL8C_CONFLICT_SURVIVES_QUEUE_TO_PHYSICAL=PASS",
    "RTL8C_PAUSE_PRESERVES_LOAD_ORDER_WAIT=PASS",
    "RTL8C_HELD_LOAD_REPLAY_AFTER_STORE=PASS",
    "RTL8C_LOAD_BYPASS_DATA=PASS",
    "RTL8C_PHYSICAL_STORE_NONCONFLICT_LOAD_BYPASS=PASS",
    "RTL8C_PHYSICAL_STORE_LINE_CONFLICT_HOLD=PASS",
    "RTL8C_PHYSICAL_STORE_RESPONSE_NO_REPLAY_DEADLOCK=PASS",
    "RTL8C5B1_PROVISIONAL_WAIT_BEFORE_STORE_RESPONSE=PASS",
    "RTL8C5B1_DEPENDENCY_AGE_SAFE_STORE_DRAIN=PASS",
    "RTL8C5B1_FORWARD_SUCCESS_DATA=PASS",
    "RTL8C5B1_ALL_FORWARD_PROVISIONAL_NO_MISS=PASS",
    "RTL8C5B1_STORE_FAULT_REPLAYS_FORWARDED_LANES=PASS",
    "RTL8C5B1_STORE_FAULT_DISCARDS_PROVISIONAL_DATA=PASS",
    "RTL8C5B1_FAULT_SAFE_QUEUED_FORWARDING=PASS",
    "RTL8C5B2_PHYSICAL_PARTIAL_FORWARD_SINGLE_MISS=PASS",
    "RTL8C5B2_PHYSICAL_PROVISIONAL_WAIT_BEFORE_RESPONSE=PASS",
    "RTL8C5B2_PHYSICAL_FORWARD_SUCCESS_DATA=PASS",
    "RTL8C5B2_PHYSICAL_ALL_FORWARD_PROVISIONAL_NO_MISS=PASS",
    "RTL8C5B2_PHYSICAL_STORE_FAULT_REPLAYS_FORWARDED_LANES=PASS",
    "RTL8C5B2_PHYSICAL_STORE_FAULT_DISCARDS_PROVISIONAL_DATA=PASS",
    "RTL8C5B2_YOUNGEST_QUEUED_BEATS_PHYSICAL=PASS",
    "RTL8C5B2_OLDER_PHYSICAL_RESOLVE_IGNORED=PASS",
    "RTL8C5B2_RESPONSE_CYCLE_PHYSICAL_FORWARD_SUPPRESSED=PASS",
    "RTL8C5B2_RESPONSE_CYCLE_REPLAY_NO_DEADLOCK=PASS",
    "RTL8C5B2_DUPLICATE_PHYSICAL_SOURCE_AMBIGUOUS=PASS",
    "RTL8C5B2_FAULT_SAFE_PHYSICAL_FORWARDING=PASS",
    "RTL8C_SAFE_LOAD_BYPASS_TB=PASS",
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
    if result.returncode != 0:
        raise RuntimeError(
            f"command failed rc={result.returncode}: {' '.join(command)}"
        )
    return result.stdout


def main() -> None:
    core_text = (ROOT / "rtl/core/a0_multi_wave_core.sv").read_text()
    bridge_text = (ROOT / "rtl/memory/a0_wave_load_mshr_bridge.sv").read_text()

    core_contract = [
        "load_store_source_physical_lane_mask",
        "load_store_forward_safe_lane_mask",
        "~load_store_source_ambiguous_lane_mask",
        "store_queue_probe_line_conflict_lane_mask",
        "physical_store_line_conflict_lane_mask",
        "load_store_unresolved_line_conflict_lane_mask",
        "load_mshr_forward_dependency_active",
        "store_queue_drain_age_safe",
        "store_response_resolve_fire",
        "{WAVE_SIZE{store_response_resolve_fire}}",
        "load_forward_seq_i(load_store_source_seq)",
        "load_forward_data_i(load_store_source_wdata)",
    ]
    missing_core = [item for item in core_contract if item not in core_text]
    if missing_core:
        raise RuntimeError(
            "missing RTL8C-5B2 core contract(s): " + ", ".join(missing_core)
        )

    bridge_contract = [
        "wave_forward_wait_mask_q",
        "wave_forward_success_mask_q",
        "store_resolve_fault_i",
        "load_forward_valid_lane_mask_i",
    ]
    missing_bridge = [item for item in bridge_contract if item not in bridge_text]
    if missing_bridge:
        raise RuntimeError(
            "missing RTL8C-5B forwarding bridge contract(s): " + ", ".join(missing_bridge)
        )

    print("RTL8C5B1_STATIC_FORWARD_GUARDS=PASS")
    print("RTL8C5B2_STATIC_PHYSICAL_FORWARD_GUARDS=PASS")

    with tempfile.TemporaryDirectory(prefix="a0_rtl8c5b2_load_bypass_") as td:
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
                "a0_multi_wave_core_rtl8c_load_bypass_tb",
                "--Mdir",
                str(obj_dir),
                *map(str, SOURCES),
            ]
        )
        output = run(
            [str(obj_dir / "Va0_multi_wave_core_rtl8c_load_bypass_tb")]
        )

    missing = [marker for marker in MARKERS if marker not in output]
    if missing:
        raise RuntimeError(
            "missing RTL8C-5B2 forwarding marker(s): " + ", ".join(missing)
        )

    print("RTL8C_SAFE_LOAD_BYPASS_DRIVER=PASS")
    print("RTL8C5B1_QUEUED_FORWARDING_DRIVER=PASS")
    print("RTL8C5B2_PHYSICAL_FORWARDING_DRIVER=PASS")


if __name__ == "__main__":
    main()
