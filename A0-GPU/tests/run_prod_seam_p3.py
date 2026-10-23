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

P1 = ROOT / "rtl/core/a0_production_cu_cluster_frontend.sv"
P2 = ROOT / "rtl/core/a0_production_multi_cluster_load_subsystem.sv"
P3 = ROOT / "rtl/core/a0_production_multi_cluster_store_invalidate_subsystem.sv"
P3_TB = ROOT / "tests/rtl/a0_production_multi_cluster_store_invalidate_subsystem_tb.sv"
P3_DOC = ROOT / "docs/architecture/A0_PROD_SEAM_P3_GLOBAL_STORE_INVALIDATION.md"
MC_BASE = ROOT / "rtl/memory/a0_mc_noc_sliced_l2_subsystem.sv"
MC_STORE = ROOT / "rtl/memory/a0_mc_noc_sliced_l2_store_invalidate_subsystem.sv"
P2_RUNNER = ROOT / "tests/run_prod_seam_p2.py"

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
MC_COMMON = [
    ROOT / "rtl/memory/a0_cluster_line_noc_endpoint.sv",
    ROOT / "rtl/memory/a0_mc_noc_logical_request_router.sv",
    ROOT / "rtl/memory/a0_mc_noc_logical_transaction_router.sv",
    ROOT / "rtl/memory/a0_l2_line_cache.sv",
]
P3_SOURCES = [*CORE_SOURCES, *MC_COMMON, MC_STORE, P3]

P3_MARKERS = (
    "PROD_SEAM_P3_BASELINE_RESET_IDLE=PASS",
    "PROD_SEAM_P3_BASELINE_MULTI_CLUSTER_TAG_UNIQUENESS=PASS",
    "PROD_SEAM_P3_BASELINE_OOO_CLUSTER1_RESTORE=PASS",
    "PROD_SEAM_P3_BASELINE_OOO_CLUSTER0_RESTORE=PASS",
    "PROD_SEAM_P3_BASELINE_CROSS_CLUSTER_HIT_SUPPRESSES_BACKEND=PASS",
    "PROD_SEAM_P3_BASELINE_CROSS_CLUSTER_SHARED_L2_HIT=PASS",
    "PROD_SEAM_P3_GLOBAL_STORE_BROADCAST=PASS",
    "PROD_SEAM_P3_CROSS_CLUSTER_INVALIDATE_SLICE0=PASS",
    "PROD_SEAM_P3_CROSS_CLUSTER_INVALIDATE_SLICE1=PASS",
    "PROD_SEAM_P3_POST_STORE_RELOAD_UPDATED=PASS",
    "PROD_SEAM_P3_BASELINE_DIAGNOSTICS_CLEAN=PASS",
    "PROD_SEAM_P3_STORE_INVALIDATION_TB=PASS",
)


def fail(stage: str, detail: str, rc: int = 1) -> None:
    print("PROD_SEAM_P3_FIRST_FAILURE", file=sys.stderr)
    print(f"STAGE={stage}", file=sys.stderr)
    print(f"DETAIL={detail}", file=sys.stderr)
    raise SystemExit(rc)


def run(cmd: list[str], stage: str, timeout: int = 900) -> str:
    if any(a.startswith("-Wno-") for a in cmd):
        fail(stage, "runner attempted warning suppression")
    try:
        p = subprocess.run(
            cmd, cwd=ROOT, text=True, stdout=subprocess.PIPE,
            stderr=subprocess.STDOUT,
            env={**os.environ, "PYTHONDONTWRITEBYTECODE": "1"}, timeout=timeout,
        )
    except subprocess.TimeoutExpired as exc:
        fail(stage, f"TIMEOUT after {timeout}s: {exc}", 124)
    if p.returncode != 0:
        print(p.stdout, file=sys.stderr)
        fail(stage, f"RC={p.returncode}", p.returncode or 1)
    if cmd and Path(cmd[0]).name.startswith("verilator"):
        if "%Warning-" in p.stdout or "%Error" in p.stdout:
            print(p.stdout, file=sys.stderr)
            fail(stage, "Verilator diagnostic present", 2)
    return p.stdout


def require_markers(text: str, markers: tuple[str, ...], stage: str) -> None:
    lines = set(text.replace("\r", "").splitlines())
    missing = [m for m in markers if m not in lines]
    if missing:
        fail(stage, f"missing markers: {missing}")


def generate_build_sim(*, top: str, sources: list[Path], obj: Path) -> str:
    cmd = [
        str(VERILATOR), "--timing", "--unroll-count", "512", "-Wall",
        "-Werror-PINMISSING", "-Werror-WIDTHEXPAND", "-Werror-WIDTHTRUNC",
        "--output-split", "5000", "--output-split-cfuncs", "500",
        "-CFLAGS", "-O0", "--cc", "--exe", "--main",
        "--top-module", top, "--Mdir", str(obj), *map(str, sources),
    ]
    run(cmd, f"{top}_GENERATE", 900)
    run(["make", "-C", str(obj), "-f", f"V{top}.mk", "-j1"], f"{top}_BUILD", 2400)
    return run([str(obj / f"V{top}")], f"{top}_SIM", 240)


def main() -> int:
    version = run([str(VERILATOR), "--version"], "VERSION", 30).strip()
    if not version.startswith("Verilator 5.050 "):
        fail("VERSION", f"expected 5.050, observed {version}")
    print("PROD_SEAM_P3_EXACT_VERILATOR_5_050=PASS", flush=True)

    required = [*P3_SOURCES, P3_TB, P3_DOC, P2, MC_BASE, P2_RUNNER]
    missing = [str(p) for p in required if not p.is_file()]
    if missing:
        fail("SOURCE_AVAILABILITY", str(missing))

    p3_text = P3.read_text(encoding="utf-8")
    mc_text = MC_STORE.read_text(encoding="utf-8")
    required_p3_tokens = (
        "a0_production_cu_cluster_frontend #(",
        "a0_mc_noc_sliced_l2_store_invalidate_subsystem #(",
        "global_store_valid",
        "global_store_lane_mask",
        "global_store_word_addr",
        "store_observe_valid_o",
        "store_observe_lane_mask_o",
        "store_observe_word_addr_o",
    )
    absent = [t for t in required_p3_tokens if t not in p3_text]
    if absent:
        fail("STATIC_COMPOSITION_CONTRACT", f"missing {absent}")
    required_mc_tokens = (
        ".store_valid_i(global_store_valid_i)",
        ".store_lane_mask_i(global_store_lane_mask_i)",
        ".store_word_addr_i(global_store_word_addr_i)",
        "parameter integer STORE_LANES",
    )
    absent_mc = [t for t in required_mc_tokens if t not in mc_text]
    if absent_mc:
        fail("STATIC_STORE_OBSERVATION_CONTRACT", f"missing {absent_mc}")
    forbidden_claim_tokens = ("dirty_q", "writeback_queue", "atomic_unit")
    present_forbidden = [t for t in forbidden_claim_tokens if t in p3_text or t in mc_text]
    if present_forbidden:
        fail("BOUNDED_SCOPE", f"unexpected full-coherence state {present_forbidden}")
    print("PROD_SEAM_P3_STATIC_COMPOSITION_CONTRACT=PASS", flush=True)
    print("PROD_SEAM_P3_BOUNDED_INVALIDATION_SCOPE=PASS", flush=True)

    with tempfile.TemporaryDirectory(prefix="a0_prod_seam_p3_", dir="/tmp") as td:
        tmp = Path(td)
        lint = [
            str(VERILATOR), "--timing", "--unroll-count", "512", "-Wall",
            "-Werror-PINMISSING", "-Werror-WIDTHEXPAND", "-Werror-WIDTHTRUNC",
            "--lint-only", "--top-module", "a0_production_multi_cluster_store_invalidate_subsystem",
            "--Mdir", str(tmp / "lint"), *map(str, P3_SOURCES),
        ]
        run(lint, "P3_STRICT_LINT", 900)
        print("PROD_SEAM_P3_STRICT_LINT=PASS", flush=True)

        # Exercise the new global store-vector width at a non-default 3x3 topology.
        mc_lint = [
            str(VERILATOR), "--timing", "--unroll-count", "512", "-Wall",
            "-Werror-PINMISSING", "-Werror-WIDTHEXPAND", "-Werror-WIDTHTRUNC",
            "--lint-only", "--top-module", "a0_mc_noc_sliced_l2_store_invalidate_subsystem",
            "--Mdir", str(tmp / "mc_matrix_3x3"),
            "-GCLUSTER_COUNT=3", "-GCUS_PER_CLUSTER=3", "-GMSHR_COUNT=3",
            "-GLINE_WORDS=4", "-GL2_SLICE_COUNT=4", "-GL2_SET_COUNT_PER_SLICE=8",
            "-GL2_MISS_COUNT_PER_SLICE=4", "-GSTORE_LANES=288",
            *map(str, [*MC_COMMON, MC_STORE]),
        ]
        run(mc_lint, "P3_STORE_VECTOR_MATRIX_3X3", 600)
        print("PROD_SEAM_P3_STORE_VECTOR_MATRIX_3X3=PASS", flush=True)

        sim = generate_build_sim(
            top="a0_production_multi_cluster_store_invalidate_subsystem_tb",
            sources=[*P3_SOURCES, P3_TB], obj=tmp / "behavior",
        )
        require_markers(sim, P3_MARKERS, "P3_BEHAVIOR_MARKERS")
        print(f"PROD_SEAM_P3_BEHAVIOR=PASS markers={len(P3_MARKERS)}", flush=True)

        predecessor = run([sys.executable, str(P2_RUNNER)], "P2_PREDECESSOR_GATE", 7200)
        require_markers(predecessor, ("PROD_SEAM_P2_GATE=PASS",), "P2_PREDECESSOR_RECEIPT")
        print("PROD_SEAM_P3_P2_PREDECESSOR=PASS", flush=True)

    head = run(["git", "rev-parse", "HEAD"], "POST_HEAD", 30).strip()
    branch = run(["git", "branch", "--show-current"], "POST_BRANCH", 30).strip()
    run(["git", "diff", "--check"], "POST_DIFF_CHECK", 30)
    if head != EXPECTED_HEAD or branch != EXPECTED_BRANCH:
        fail("POST_CONTAINMENT", f"HEAD={head} BRANCH={branch}")
    print("PROD_SEAM_P3_POST_CONTAINMENT=PASS", flush=True)
    print("PROD_SEAM_P3_GATE=PASS", flush=True)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
