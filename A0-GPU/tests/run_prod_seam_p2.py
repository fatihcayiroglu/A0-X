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
EXPECTED_HEAD = "996d8c188e5d4f94b4bad5289392844d55d092f6"
EXPECTED_BRANCH = "main"

P2 = ROOT / "rtl/core/a0_production_multi_cluster_load_subsystem.sv"
P2_TB = ROOT / "tests/rtl/a0_production_multi_cluster_load_subsystem_tb.sv"
P2_DOC = ROOT / "docs/architecture/A0_PROD_SEAM_P2_MULTI_CLUSTER_LOAD.md"
P1 = ROOT / "rtl/core/a0_production_cu_cluster_frontend.sv"
P1_TB = ROOT / "tests/rtl/a0_production_cu_cluster_frontend_traffic_tb.sv"
MC_P3 = ROOT / "rtl/memory/a0_mc_noc_sliced_l2_subsystem.sv"
MC_P3_TB = ROOT / "tests/rtl/a0_mc_noc_sliced_l2_subsystem_tb.sv"

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
    P1,
]
MC_SOURCES = [
    ROOT / "rtl/memory/a0_cluster_line_noc_endpoint.sv",
    ROOT / "rtl/memory/a0_mc_noc_logical_request_router.sv",
    ROOT / "rtl/memory/a0_mc_noc_logical_transaction_router.sv",
    ROOT / "rtl/memory/a0_l2_line_cache.sv",
    ROOT / "rtl/memory/a0_line_slice_fabric.sv",
    MC_P3,
]
P2_SOURCES = [*CORE_SOURCES, *MC_SOURCES, P2]

P2_MARKERS = (
    "PROD_SEAM_P2_RESET_IDLE=PASS",
    "PROD_SEAM_P2_MULTI_CLUSTER_TAG_UNIQUENESS=PASS",
    "PROD_SEAM_P2_OOO_CLUSTER1_RESTORE=PASS",
    "PROD_SEAM_P2_OOO_CLUSTER0_RESTORE=PASS",
    "PROD_SEAM_P2_CROSS_CLUSTER_HIT_SUPPRESSES_BACKEND=PASS",
    "PROD_SEAM_P2_CROSS_CLUSTER_SHARED_L2_HIT=PASS",
    "PROD_SEAM_P2_DIAGNOSTICS_CLEAN=PASS",
    "PROD_SEAM_P2_MULTI_CLUSTER_LOAD_TB=PASS",
)
P1_MARKERS = (
    "PROD_SEAM_P1_RESET_IDLE=PASS",
    "PROD_SEAM_P1_FRONTEND_HOLD_CAPTURE=PASS",
    "PROD_SEAM_P1_REQUEST_CAPTURED_WHILE_BACKPRESSURED=PASS",
    "PROD_SEAM_P1_REQUEST_PAYLOAD_STABLE=PASS",
    "PROD_SEAM_P1_REQUEST_FORWARD_HANDSHAKE=PASS",
    "PROD_SEAM_P1_LOAD_RESPONSE_ROUNDTRIP=PASS",
    "PROD_SEAM_P1_MSHR_FINAL_DRAIN=PASS",
    "PROD_SEAM_P1_FRONTEND_TRAFFIC_TB=PASS",
)
P3_SCENARIOS = (
    "RESET_OUTPUTS_GATED", "RESET_RELEASE_EMPTY", "LOCAL_REQUEST_REGISTERED_NO_BYPASS",
    "CLUSTER_PREFIX_ADDED_AT_BACKEND", "CU_LOCAL_TAG_EXACT_AT_BACKEND", "LINE_AND_HOME_HASH_EXACT",
    "COLD_MISS_REACHES_ONLY_HOME_BACKEND", "BACKEND_REQUEST_STALL_STABLE", "BACKEND_REQUEST_TURNOVER",
    "OPAQUE_UNUSED_LOCAL_TAG_ROUND_TRIP", "TWO_CLUSTER_DIFFERENT_HOME_BACKEND_OVERLAP",
    "OVERLAP_BACKEND_NETWORK_TAGS_EXACT", "REVERSE_ORDER_CLUSTER_CU_TAG_RESTORE",
    "REVERSE_ORDER_LINE_DATA_EXACT", "SAME_SUFFIX_DIFFERENT_CLUSTERS_DISTINCT",
    "SAME_CLUSTER_DIFFERENT_SLICE_SIMULTANEOUS_RESPONSES", "SAME_CLUSTER_SIMULTANEOUS_NO_LOSS",
    "DIFFERENT_CLUSTERS_SIMULTANEOUS_LOCAL_OUTPUT", "BACKEND_BACKPRESSURE_ISOLATED_PER_SLICE",
    "LOCAL_RESPONSE_BACKPRESSURE_STABLE", "LOCAL_RESPONSE_BACKPRESSURE_ISOLATED_PER_CLUSTER",
    "LOCAL_RESPONSE_EXACTLY_ONCE", "SAME_SLICE_CROSS_CLUSTER_RR_PROGRESS",
    "SAME_SLICE_REVERSE_ORDER_BACKEND_RESPONSE", "SHARED_L2_CROSS_CLUSTER_HIT",
    "SHARED_L2_HIT_SUPPRESSES_BACKEND", "FAULT_RESPONSE_PRESERVED", "FAULTED_REFILL_NOT_INSTALLED",
    "SAME_CYCLE_BACKEND_COMPLETION", "SAME_CYCLE_TAG_REUSE_AFTER_LOCAL_RETIRE",
    "OWNED_DUPLICATE_HELD_BEFORE_BACKEND", "BOUNDARY_BACKPRESSURE_PROPAGATES_NO_LOSS",
    "INVALID_LOCAL_CU_REJECTED", "ORPHAN_BACKEND_RESPONSE_REJECTED",
    "WRONG_LINE_RESPONSE_REJECTED_OWNER_SURVIVES", "WRONG_HOME_RESPONSE_REJECTED_OWNER_SURVIVES",
    "INVALID_RESPONSE_CLUSTER_CU_REJECTED", "MALFORMED_SLICE_PEER_DOES_NOT_BLOCK",
    "RESET_FLUSHES_IN_FLIGHT_AND_HELD", "FINAL_CONSERVATION_DRAIN",
)
P3_MARKERS = tuple(f"MC_NOC_P3_{i:02d}_{name}=PASS" for i, name in enumerate(P3_SCENARIOS, 1))


def fail(stage: str, detail: str, rc: int = 1) -> None:
    print("PROD_SEAM_P2_FIRST_FAILURE", file=sys.stderr)
    print(f"STAGE={stage}", file=sys.stderr)
    print(f"DETAIL={detail}", file=sys.stderr)
    raise SystemExit(rc)


def run(cmd: list[str], stage: str, timeout: int = 900) -> str:
    if any(a.startswith("-Wno-") for a in cmd):
        fail(stage, "runner attempted warning suppression")
    try:
        p = subprocess.run(
            cmd, cwd=ROOT, text=True, stdout=subprocess.PIPE, stderr=subprocess.STDOUT,
            env={**os.environ, "PYTHONDONTWRITEBYTECODE": "1"}, timeout=timeout,
        )
    except subprocess.TimeoutExpired as exc:
        fail(stage, f"TIMEOUT after {timeout}s: {exc}", 124)
    if p.returncode != 0:
        print(p.stdout, file=sys.stderr)
        fail(stage, f"RC={p.returncode}", p.returncode or 1)
    if "%Warning-" in p.stdout or "%Error" in p.stdout:
        print(p.stdout, file=sys.stderr)
        fail(stage, "Verilator diagnostic present", 2)
    return p.stdout


def require_markers(text: str, markers: tuple[str, ...], stage: str) -> None:
    lines = set(text.replace("\r", "").splitlines())
    missing = [m for m in markers if m not in lines]
    if missing:
        fail(stage, f"missing markers: {missing}")


def generate_build_sim(
    *, top: str, sources: list[Path], obj: Path, define_args: list[str] | None = None,
    param_args: list[str] | None = None, timeout_generate: int = 600,
) -> str:
    cmd = [
        str(VERILATOR), "--timing", "--unroll-count", "512", "-Wall",
        "-Werror-PINMISSING", "-Werror-WIDTHEXPAND", "-Werror-WIDTHTRUNC",
        "--output-split", "5000", "--output-split-cfuncs", "500",
        "-CFLAGS", "-O0", "--cc", "--exe", "--main",
        "--top-module", top, "--Mdir", str(obj),
    ]
    cmd += define_args or []
    cmd += param_args or []
    cmd += [str(p) for p in sources]
    run(cmd, f"{top}_GENERATE", timeout_generate)
    run(["make", "-C", str(obj), "-f", f"V{top}.mk", "-j1"], f"{top}_BUILD", 1800)
    return run([str(obj / f"V{top}")], f"{top}_SIM", 180)


def main() -> int:
    version = run([str(VERILATOR), "--version"], "VERSION", 30).strip()
    if not version.startswith("Verilator 5.050 "):
        fail("VERSION", f"expected 5.050, observed {version}")
    print("PROD_SEAM_P2_EXACT_VERILATOR_5_050=PASS", flush=True)

    required = [*P2_SOURCES, P2_TB, P2_DOC, P1_TB, MC_P3_TB]
    missing = [str(p) for p in required if not p.is_file()]
    if missing:
        fail("SOURCE_AVAILABILITY", str(missing))

    text = P2.read_text(encoding="utf-8")
    required_tokens = (
        "a0_production_cu_cluster_frontend #(", "a0_mc_noc_sliced_l2_subsystem #(",
        ".cluster_local_req_tag_i(cluster_line_req_tag)",
        ".cluster_local_resp_tag_o(cluster_line_resp_tag)",
        "store_observe_valid_o", "cluster_local_req_tag_error_o",
    )
    absent = [t for t in required_tokens if t not in text]
    if absent:
        fail("STATIC_CONTRACT", f"missing {absent}")
    if ".cluster_store" in text:
        fail("STATIC_LOAD_ONLY_BOUNDARY", "P2 unexpectedly consumes cluster stores into NoC/L2")
    print("PROD_SEAM_P2_STATIC_COMPOSITION_CONTRACT=PASS", flush=True)
    print("PROD_SEAM_P2_LOAD_ONLY_STORE_BOUNDARY=PASS", flush=True)

    with tempfile.TemporaryDirectory(prefix="a0_prod_seam_p2_", dir="/tmp") as td:
        tmp = Path(td)
        lint = [
            str(VERILATOR), "--timing", "--unroll-count", "512", "-Wall",
            "-Werror-PINMISSING", "-Werror-WIDTHEXPAND", "-Werror-WIDTHTRUNC",
            "--lint-only", "--top-module", "a0_production_multi_cluster_load_subsystem",
            "--Mdir", str(tmp / "lint"), *map(str, P2_SOURCES),
        ]
        run(lint, "P2_STRICT_LINT", 600)
        print("PROD_SEAM_P2_STRICT_LINT=PASS", flush=True)

        sim = generate_build_sim(
            top="a0_production_multi_cluster_load_subsystem_tb",
            sources=[*P2_SOURCES, P2_TB], obj=tmp / "behavior", timeout_generate=600,
        )
        require_markers(sim, P2_MARKERS, "P2_BEHAVIOR_MARKERS")
        print(f"PROD_SEAM_P2_BEHAVIOR=PASS markers={len(P2_MARKERS)}", flush=True)

        p1sim = generate_build_sim(
            top="a0_production_cu_cluster_frontend_traffic_tb",
            sources=[*CORE_SOURCES, P1_TB], obj=tmp / "p1_predecessor", timeout_generate=300,
        )
        require_markers(p1sim, P1_MARKERS, "P1_PREDECESSOR_MARKERS")
        print(f"PROD_SEAM_P2_P1_PREDECESSOR=PASS markers={len(P1_MARKERS)}", flush=True)

        p3sim = generate_build_sim(
            top="a0_mc_noc_sliced_l2_subsystem_tb",
            sources=[
                ROOT / "rtl/memory/a0_cluster_line_noc_endpoint.sv",
                ROOT / "rtl/memory/a0_mc_noc_logical_request_router.sv",
                ROOT / "rtl/memory/a0_mc_noc_logical_transaction_router.sv",
                ROOT / "rtl/memory/a0_l2_line_cache.sv", MC_P3, MC_P3_TB,
            ],
            obj=tmp / "p3_predecessor",
            define_args=["-DMC_NOC_P3_FULL"],
            param_args=[
                "-GCLUSTER_COUNT=3", "-GCUS_PER_CLUSTER=3", "-GMSHR_COUNT=3",
                "-GLINE_WORDS=4", "-GL2_SLICE_COUNT=4", "-GL2_SET_COUNT_PER_SLICE=8",
                "-GL2_MISS_COUNT_PER_SLICE=4", "-GFULL_SCENARIOS=1",
            ], timeout_generate=300,
        )
        require_markers(p3sim, P3_MARKERS, "MC_NOC_P3_PREDECESSOR_MARKERS")
        print(f"PROD_SEAM_P2_MC_NOC_P3_PREDECESSOR=PASS markers={len(P3_MARKERS)}", flush=True)

    head = run(["git", "rev-parse", "HEAD"], "POST_HEAD", 30).strip()
    branch = run(["git", "branch", "--show-current"], "POST_BRANCH", 30).strip()
    run(["git", "diff", "--check"], "POST_DIFF_CHECK", 30)
    if head != EXPECTED_HEAD or branch != EXPECTED_BRANCH:
        fail("POST_CONTAINMENT", f"HEAD={head} BRANCH={branch}")
    print("PROD_SEAM_P2_POST_CONTAINMENT=PASS", flush=True)
    print("PROD_SEAM_P2_GATE=PASS", flush=True)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
