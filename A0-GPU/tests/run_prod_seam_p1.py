#!/usr/bin/env python3
from __future__ import annotations

import os
from pathlib import Path
import shutil
import subprocess
import sys
import tempfile

sys.dont_write_bytecode = True
ROOT = Path(__file__).resolve().parents[1]
VERILATOR = Path(os.environ.get("A0_VERILATOR_BIN", shutil.which("verilator") or "verilator"))
EXPECTED_VERSION = "5.050"

FRONTEND = ROOT / "rtl/core/a0_production_cu_cluster_frontend.sv"
FRONTEND_TB = ROOT / "tests/rtl/a0_production_cu_cluster_frontend_tb.sv"
TRAFFIC_TB = ROOT / "tests/rtl/a0_production_cu_cluster_frontend_traffic_tb.sv"
DOC = ROOT / "docs/architecture/A0_PROD_SEAM_P1_PRODUCTION_CU_FRONTEND.md"

CORE_SOURCES = [
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
    ROOT / "rtl/memory/a0_cluster_store_order_controller.sv",
    ROOT / "rtl/memory/a0_line_request_fabric.sv",
    ROOT / "rtl/memory/a0_production_cluster_line_seam.sv",
    FRONTEND,
]

P0_EQ_SOURCES = [
    ROOT / "rtl/memory/a0_line_request_fabric.sv",
    ROOT / "rtl/memory/a0_l2_line_cache.sv",
    ROOT / "rtl/memory/a0_shared_l2_subsystem.sv",
    ROOT / "rtl/memory/a0_production_cluster_line_seam.sv",
    ROOT / "tests/rtl/a0_production_cluster_line_seam_equivalence.sv",
]
P0_REFERENCE_TB = ROOT / "tests/rtl/a0_shared_l2_subsystem_tb.sv"

RTL9D3_MARKERS = (
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
)

TRAFFIC_MARKERS = (
    "PROD_SEAM_P1_RESET_IDLE=PASS",
    "PROD_SEAM_P1_FRONTEND_HOLD_CAPTURE=PASS",
    "PROD_SEAM_P1_REQUEST_CAPTURED_WHILE_BACKPRESSURED=PASS",
    "PROD_SEAM_P1_REQUEST_PAYLOAD_STABLE=PASS",
    "PROD_SEAM_P1_REQUEST_FORWARD_HANDSHAKE=PASS",
    "PROD_SEAM_P1_LOAD_RESPONSE_ROUNDTRIP=PASS",
    "PROD_SEAM_P1_MSHR_FINAL_DRAIN=PASS",
    "PROD_SEAM_P1_FRONTEND_TRAFFIC_TB=PASS",
)

LINT_CONFIGS = (
    (1, 2),
    (2, 2),
    (3, 2),
    (4, 2),
    (3, 4),
)


def run(cmd: list[str], *, timeout: int, stage: str) -> str:
    p = subprocess.run(
        cmd,
        cwd=ROOT,
        text=True,
        stdout=subprocess.PIPE,
        stderr=subprocess.STDOUT,
        timeout=timeout,
        env={**os.environ, "PYTHONDONTWRITEBYTECODE": "1"},
    )
    if p.returncode != 0:
        print(f"PROD_SEAM_P1_FIRST_FAILURE_STAGE={stage}", file=sys.stderr)
        print(f"PROD_SEAM_P1_FIRST_FAILURE_RC={p.returncode}", file=sys.stderr)
        print(p.stdout, file=sys.stderr)
        raise SystemExit(p.returncode or 1)
    if "%Warning-" in p.stdout or "%Error" in p.stdout:
        print(f"PROD_SEAM_P1_FIRST_FAILURE_STAGE={stage}_DIAGNOSTICS", file=sys.stderr)
        print(p.stdout, file=sys.stderr)
        raise SystemExit(2)
    return p.stdout


def verilator_base() -> list[str]:
    return [
        str(VERILATOR),
        "--timing",
        "-Wall",
        "-Werror-PINMISSING",
        "-Werror-WIDTHEXPAND",
    ]


def main() -> int:
    version = run([str(VERILATOR), "--version"], timeout=30, stage="VERSION").strip()
    if not version.startswith("Verilator 5.050 "):
        print(f"PROD_SEAM_P1_FIRST_FAILURE_STAGE=VERSION_MISMATCH\nOBSERVED={version}", file=sys.stderr)
        return 3
    print("PROD_SEAM_P1_EXACT_VERILATOR_5_050=PASS")

    for path in [*CORE_SOURCES, FRONTEND_TB, TRAFFIC_TB, DOC, *P0_EQ_SOURCES, P0_REFERENCE_TB]:
        if not path.is_file():
            print(f"PROD_SEAM_P1_FIRST_FAILURE_STAGE=MISSING_FILE\nFILE={path}", file=sys.stderr)
            return 4

    text = FRONTEND.read_text(encoding="utf-8")
    forbidden = ("a0_shared_l2_subsystem", "a0_l2_line_cache", "a0_mc_noc_")
    found = [name for name in forbidden if name in text]
    if found:
        print(f"PROD_SEAM_P1_FIRST_FAILURE_STAGE=STATIC_EMBEDDED_DOWNSTREAM\nFOUND={found}", file=sys.stderr)
        return 5
    if "a0_production_cluster_line_seam" not in text:
        print("PROD_SEAM_P1_FIRST_FAILURE_STAGE=STATIC_MISSING_P0_SEAM", file=sys.stderr)
        return 6
    if "line_req_hold_valid_q" not in text:
        print("PROD_SEAM_P1_FIRST_FAILURE_STAGE=STATIC_MISSING_REQUEST_DECOUPLER", file=sys.stderr)
        return 7
    print("PROD_SEAM_P1_L2_FREE_STATIC_CONTRACT=PASS")
    print("PROD_SEAM_P1_REGISTERED_REQUEST_DECOUPLER=PASS")

    with tempfile.TemporaryDirectory(prefix="a0_prod_seam_p1_", dir="/tmp") as tmp:
        tmp_path = Path(tmp)

        for idx, (cu_count, mshr_count) in enumerate(LINT_CONFIGS):
            obj = tmp_path / f"lint_{idx}"
            cmd = verilator_base() + [
                "--lint-only",
                "--top-module", "a0_production_cu_cluster_frontend",
                f"-GCU_COUNT={cu_count}",
                f"-GMSHR_COUNT={mshr_count}",
                "--Mdir", str(obj),
                *map(str, CORE_SOURCES),
            ]
            run(cmd, timeout=180, stage=f"LINT_CU{cu_count}_MSHR{mshr_count}")
            print(f"PROD_SEAM_P1_PARAMETER_VARIANT=PASS CU_COUNT={cu_count} MSHR_COUNT={mshr_count}")
        print(f"PROD_SEAM_P1_PARAMETER_MATRIX=PASS count={len(LINT_CONFIGS)}")

        obj = tmp_path / "behavior"
        cmd = verilator_base() + [
            "--binary",
            "--top-module", "a0_production_cu_cluster_frontend_tb",
            "--Mdir", str(obj),
            *map(str, CORE_SOURCES),
            str(FRONTEND_TB),
        ]
        build_out = run(cmd, timeout=900, stage="FRONTEND_BEHAVIOR_BUILD")
        if "%Warning-" in build_out or "%Error" in build_out:
            raise SystemExit(8)
        sim = run([str(obj / "Va0_production_cu_cluster_frontend_tb")], timeout=60, stage="FRONTEND_BEHAVIOR_SIM")
        if "PROD_SEAM_P1_FRONTEND_WIRING_TB=PASS" not in sim:
            print("PROD_SEAM_P1_FIRST_FAILURE_STAGE=FRONTEND_MARKER", file=sys.stderr)
            print(sim, file=sys.stderr)
            return 9
        print("PROD_SEAM_P1_FRONTEND_BEHAVIOR=PASS")

        # Exercise a real private-L1 miss through the new registered frontend
        # hold and the P0 seam while the downstream interface is backpressured.
        # Output splitting keeps this production model build bounded in
        # resource-constrained qualification environments without changing RTL.
        obj = tmp_path / "active_traffic"
        traffic_top = "a0_production_cu_cluster_frontend_traffic_tb"
        cmd = verilator_base() + [
            "--output-split", "5000",
            "--output-split-cfuncs", "500",
            "-CFLAGS", "-O0",
            "--binary",
            "--top-module", traffic_top,
            "--Mdir", str(obj),
            *map(str, CORE_SOURCES),
            str(TRAFFIC_TB),
        ]
        run(cmd, timeout=1800, stage="FRONTEND_ACTIVE_TRAFFIC_BUILD")
        sim = run(
            [str(obj / f"V{traffic_top}")],
            timeout=60,
            stage="FRONTEND_ACTIVE_TRAFFIC_SIM",
        )
        traffic_lines = set(sim.replace("\r", "").splitlines())
        missing_traffic = [
            marker for marker in TRAFFIC_MARKERS if marker not in traffic_lines
        ]
        if missing_traffic:
            print(
                "PROD_SEAM_P1_FIRST_FAILURE_STAGE=FRONTEND_ACTIVE_TRAFFIC_MARKERS\n"
                f"EXPECTED={len(TRAFFIC_MARKERS)} MISSING={missing_traffic}",
                file=sys.stderr,
            )
            print(sim, file=sys.stderr)
            return 10
        print(
            "PROD_SEAM_P1_FRONTEND_ACTIVE_TRAFFIC=PASS "
            f"markers={len(TRAFFIC_MARKERS)}"
        )

        # The equivalence RTL is a comparator, not a standalone stimulus TB.
        # Reuse the frozen RTL9D3 scenario driver by adapting only its DUT
        # wrapper name/hierarchy in a temporary file, exactly as PROD-SEAM-P0
        # qualification does.  The repository source remains untouched.
        adapted_tb = tmp_path / "a0_production_cluster_line_seam_equivalence_tb.sv"
        adapted_text = P0_REFERENCE_TB.read_text(encoding="utf-8")
        replacements = (
            (
                "module a0_shared_l2_subsystem_tb;",
                "module a0_production_cluster_line_seam_equivalence_tb;",
                1,
            ),
            (
                "a0_shared_l2_subsystem #(",
                "a0_production_cluster_line_seam_equivalence #(",
                1,
            ),
            (
                "dut.line_fabric.",
                "dut.candidate_seam.line_fabric.",
                2,
            ),
        )
        for old, new, expected_count in replacements:
            actual_count = adapted_text.count(old)
            if actual_count != expected_count:
                print(
                    "PROD_SEAM_P1_FIRST_FAILURE_STAGE=P0_TB_ADAPTATION\n"
                    f"EXPECTED_COUNT={expected_count} ACTUAL_COUNT={actual_count} TOKEN={old}",
                    file=sys.stderr,
                )
                return 11
            adapted_text = adapted_text.replace(old, new)
        adapted_tb.write_text(adapted_text, encoding="utf-8", newline="\n")

        obj = tmp_path / "p0_equivalence"
        p0_top = "a0_production_cluster_line_seam_equivalence_tb"
        cmd = verilator_base() + [
            "--unroll-count", "512",
            "-Werror-WIDTHTRUNC",
            "--binary",
            "--top-module", p0_top,
            "--Mdir", str(obj),
            *map(str, P0_EQ_SOURCES),
            str(adapted_tb),
        ]
        run(cmd, timeout=900, stage="P0_EQUIVALENCE_BUILD")
        sim = run([str(obj / f"V{p0_top}")], timeout=600, stage="P0_EQUIVALENCE_SIM")
        lines = set(sim.replace("\r", "").splitlines())
        missing = [marker for marker in RTL9D3_MARKERS if marker not in lines]
        if missing:
            print(
                "PROD_SEAM_P1_FIRST_FAILURE_STAGE=P0_EQUIVALENCE_MARKERS\n"
                f"EXPECTED={len(RTL9D3_MARKERS)} MISSING={missing}",
                file=sys.stderr,
            )
            print(sim, file=sys.stderr)
            return 12
        print(
            "PROD_SEAM_P1_P0_EQUIVALENCE_REPLAY=PASS "
            f"markers={len(RTL9D3_MARKERS)}"
        )

    print("PROD_SEAM_P1_GATE=PASS")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
