#!/usr/bin/env python3

from __future__ import annotations

from pathlib import Path
import os
import shutil
import subprocess
import sys
import tempfile


ROOT = Path(__file__).resolve().parents[1]
VALIDATED_VERILATOR_VERSION = "5.050"
VERILATOR_BIN_ENV = "A0_VERILATOR_BIN"

CONTROLLER_SOURCES = [
    ROOT / "rtl/memory/a0_cluster_store_order_controller.sv",
    ROOT / "tests/rtl/a0_cluster_store_order_controller_tb.sv",
]

BRIDGE_SOURCES = [
    ROOT / "rtl/memory/a0_mshr_table.sv",
    ROOT / "rtl/memory/a0_wave_load_mshr_bridge.sv",
    ROOT / "tests/rtl/a0_wave_load_mshr_bridge_tb.sv",
]

CLUSTER_SOURCES = [
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
    ROOT / "rtl/memory/a0_l2_line_cache.sv",
    ROOT / "rtl/memory/a0_shared_l2_subsystem.sv",
    ROOT / "rtl/core/a0_cu_cluster.sv",
]

RTL9D3_MARKERS = [
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

FROZEN_BRIDGE_MARKERS = [
    "SAME_CYCLE_STORE_LAUNCH_VS_MSHR_MERGE_STORE_WINS=PASS",
    "YOUNGER_LOAD_CANNOT_MERGE_INTO_PRE_STORE_OPEN_MSHR=PASS",
    "OTHER_LINE_MSHR_MERGE_REMAINS_ALLOWED=PASS",
    "PEER_STORE_FAULT_RELEASES_YOUNGER_MSHR_REQUEST=PASS",
    "MULTIPLE_CU_PENDING_STORES_DIFFERENT_LINES=PASS",
    "MULTIPLE_PEER_STORES_SAME_LINE_BLOCK_UNTIL_LAST_RESOLVE=PASS",
    "YOUNGER_LOAD_BLOCKED_WHILE_OLD_MSHR_REFILL_RETURNS=PASS",
    "RESPONSE_CYCLE_INCLUSIVE_BLOCK=PASS",
    "MISMATCHED_STORE_RESPONSE_DOES_NOT_ENABLE_MERGE=PASS",
]

SCENARIO_MARKERS = RTL9D3_MARKERS + FROZEN_BRIDGE_MARKERS

VERILATOR_COMMON = [
    "-Wall",
    "-Wno-BLKSEQ",
    "-Wno-UNUSEDSIGNAL",
    "-Wno-UNUSEDPARAM",
    "--unroll-count",
    "128",
    "-Werror-PINMISSING",
    "-Werror-WIDTHEXPAND",
    "-Werror-WIDTHTRUNC",
]


def run(command: list[str], *, env: dict[str, str] | None = None) -> str:
    result = subprocess.run(
        command,
        cwd=ROOT,
        env=env,
        text=True,
        stdout=subprocess.PIPE,
        stderr=subprocess.STDOUT,
    )
    print(result.stdout, end="")
    if result.returncode:
        raise RuntimeError(
            "command failed rc=" + str(result.returncode) + ": "
            + " ".join(command)
        )
    return result.stdout


def resolve_validated_verilator() -> str:
    configured = os.environ.get(VERILATOR_BIN_ENV)
    requested = configured if configured is not None else "verilator"
    if requested == "":
        raise RuntimeError(
            f"{VERILATOR_BIN_ENV} is set but empty; provide an exact "
            f"Verilator {VALIDATED_VERILATOR_VERSION} executable"
        )
    executable = shutil.which(requested)
    if executable is None:
        detail = (
            "verilator was not found on PATH"
            if configured is None
            else f"{VERILATOR_BIN_ENV} executable was not found: {requested!r}"
        )
        raise RuntimeError(
            f"{detail}; set {VERILATOR_BIN_ENV} to an exact Verilator "
            f"{VALIDATED_VERILATOR_VERSION} executable"
        )
    resolved = Path(executable).resolve(strict=True)
    if not resolved.is_file() or not os.access(resolved, os.X_OK):
        raise RuntimeError(f"Verilator executable is not runnable: {resolved}")
    result = subprocess.run(
        [str(resolved), "--version"],
        cwd=ROOT,
        env=os.environ.copy(),
        text=True,
        stdout=subprocess.PIPE,
        stderr=subprocess.STDOUT,
    )
    reported = result.stdout.strip()
    if result.returncode:
        raise RuntimeError(
            f"Verilator version check failed rc={result.returncode}: "
            f"{resolved}: {reported}"
        )
    lines = [line.strip() for line in reported.splitlines() if line.strip()]
    fields = lines[0].split() if len(lines) == 1 else []
    actual = (
        fields[1]
        if len(fields) >= 2 and fields[0] == "Verilator"
        else "UNPARSEABLE"
    )
    if actual != VALIDATED_VERILATOR_VERSION:
        raise RuntimeError(
            "VERILATOR_TOOLCHAIN_VERSION_MISMATCH "
            f"required_exact={VALIDATED_VERILATOR_VERSION} "
            f"actual={actual} executable={resolved}; set "
            f"{VERILATOR_BIN_ENV} to an exact Verilator "
            f"{VALIDATED_VERILATOR_VERSION} executable"
        )
    print(f"PRODUCTION_VERILATOR_BIN={resolved}")
    print(f"PRODUCTION_VERILATOR_VERSION={actual}")
    return str(resolved)


def validated_child_environment(verilator_bin: str) -> dict[str, str]:
    selected = Path(verilator_bin).resolve(strict=True)
    if not selected.is_file() or not os.access(selected, os.X_OK):
        raise RuntimeError(f"validated Verilator is not runnable: {selected}")
    child_env = os.environ.copy()
    inherited_test_flags = child_env.get("VERILATOR_TEST_FLAGS")
    if inherited_test_flags not in (None, ""):
        raise RuntimeError(
            "uncontrolled VERILATOR_TEST_FLAGS is not permitted at the "
            f"validated toolchain boundary: {inherited_test_flags!r}"
        )
    child_env.pop("VERILATOR_TEST_FLAGS", None)
    child_env[VERILATOR_BIN_ENV] = str(selected)
    selected_dir = str(selected.parent)
    child_env["PATH"] = selected_dir + os.pathsep + child_env.get("PATH", "")
    literal = shutil.which("verilator", path=child_env["PATH"])
    if literal is None:
        raise RuntimeError(
            "validated child toolchain layout does not expose literal "
            f"verilator beside selected executable: {selected}"
        )
    literal_resolved = Path(literal).resolve(strict=True)
    if literal_resolved != selected:
        raise RuntimeError(
            "validated child Verilator resolution mismatch "
            f"selected={selected} literal={literal_resolved}"
        )
    result = subprocess.run(
        [str(literal_resolved), "--version"],
        cwd=ROOT,
        env=child_env,
        text=True,
        stdout=subprocess.PIPE,
        stderr=subprocess.STDOUT,
    )
    reported = result.stdout.strip()
    if result.returncode:
        raise RuntimeError(
            f"child Verilator version check failed rc={result.returncode}: "
            f"{literal_resolved}: {reported}"
        )
    lines = [line.strip() for line in reported.splitlines() if line.strip()]
    fields = lines[0].split() if len(lines) == 1 else []
    actual = (
        fields[1]
        if len(fields) >= 2 and fields[0] == "Verilator"
        else "UNPARSEABLE"
    )
    if actual != VALIDATED_VERILATOR_VERSION:
        raise RuntimeError(
            "CHILD_VERILATOR_VERSION_MISMATCH "
            f"required_exact={VALIDATED_VERILATOR_VERSION} actual={actual} "
            f"executable={literal_resolved}"
        )
    print(f"CHILD_VERILATOR_BIN={literal_resolved}")
    print(f"CHILD_VERILATOR_VERSION={actual}")
    print("CHILD_VERILATOR_RESOLUTION=PASS")
    return child_env


def run_historical_toolchain_regression(child_env: dict[str, str]) -> str:
    output = run(
        [sys.executable, str(ROOT / "tests/run_rtl9d3_shared_l2_integration.py")],
        env=child_env,
    )
    for forbidden in (
        "V3Delayed.cpp:937",
        "Multiple Write refs on LHS of NBA",
        "%Error: Internal Error",
    ):
        if forbidden in output:
            raise RuntimeError(
                "system-5.032 internal-error regression remains: " + forbidden
            )
    if "RTL9D3_SHARED_L2_INTEGRATION_TB=PASS" not in output:
        raise RuntimeError("historical RTL9D3 integration PASS marker missing")
    print("HISTORICAL_RUNNER_TOOLCHAIN_PROPAGATION=PASS")
    print("RTL9D3_CHILD_VERILATOR_VERSION=5.050")
    print("RTL9D3_5032_INTERNAL_ERROR_REGRESSION=PASS")
    return output


def build(
    verilator_bin: str,
    top: str,
    sources: list[Path],
    *,
    execute: bool,
    child_env: dict[str, str] | None = None,
) -> str:
    active_child_env = (
        child_env
        if child_env is not None
        else validated_child_environment(verilator_bin)
    )
    for source in sources:
        if not source.is_file():
            raise RuntimeError(f"missing source: {source}")
    with tempfile.TemporaryDirectory(prefix=f"a0_prod_{top}_") as temp:
        obj = Path(temp) / "obj_dir"
        run([
            verilator_bin,
            "--binary",
            "--timing",
            *VERILATOR_COMMON,
            "--top-module",
            top,
            "--Mdir",
            str(obj),
            *map(str, sources),
        ], env=active_child_env)
        if not execute:
            return ""
        executable = obj / ("V" + top)
        if not executable.is_file():
            raise RuntimeError(f"missing executable: {executable}")
        return run([str(executable)], env=active_child_env)


def lint_variant(
    verilator_bin: str,
    cu_count: int,
    mshr_count: int,
    *,
    child_env: dict[str, str] | None = None,
) -> None:
    active_child_env = (
        child_env
        if child_env is not None
        else validated_child_environment(verilator_bin)
    )
    with tempfile.TemporaryDirectory(prefix="a0_prod_cluster_lint_") as temp:
        run([
            verilator_bin,
            "--lint-only",
            *VERILATOR_COMMON,
            "--top-module",
            "a0_cu_cluster",
            f"-GCU_COUNT={cu_count}",
            f"-GMSHR_COUNT={mshr_count}",
            "--Mdir",
            str(Path(temp) / "obj_dir"),
            *map(str, CLUSTER_SOURCES),
        ], env=active_child_env)


def main() -> None:
    if len(RTL9D3_MARKERS) != 34 or len(FROZEN_BRIDGE_MARKERS) != 9:
        raise RuntimeError("targeted marker partition changed")
    if len(SCENARIO_MARKERS) != 43:
        raise RuntimeError("targeted scenario count is not 43")

    arguments = sys.argv[1:]
    compile_only = "--compile-only" in arguments
    toolchain_check_only = "--toolchain-check-only" in arguments
    historical_toolchain_check_only = (
        "--historical-toolchain-check-only" in arguments
    )
    allowed = (
        "--compile-only",
        "--toolchain-check-only",
        "--historical-toolchain-check-only",
    )
    unknown = [arg for arg in arguments if arg not in allowed]
    if unknown:
        raise RuntimeError("unknown argument(s): " + " ".join(unknown))
    if sum((compile_only, toolchain_check_only, historical_toolchain_check_only)) > 1:
        raise RuntimeError("production runner modes are mutually exclusive")
    verilator_bin = resolve_validated_verilator()
    child_env = validated_child_environment(verilator_bin)
    print("PRODUCTION_VERILATOR_TOOLCHAIN_GUARD=PASS")
    if toolchain_check_only:
        return
    if historical_toolchain_check_only:
        child_env["PYTHONDONTWRITEBYTECODE"] = "1"
        run_historical_toolchain_regression(child_env)
        return

    controller_output = build(
        verilator_bin,
        "a0_cluster_store_order_controller_tb",
        CONTROLLER_SOURCES,
        execute=not compile_only,
        child_env=child_env,
    )
    build(
        verilator_bin,
        "a0_wave_load_mshr_bridge_tb",
        BRIDGE_SOURCES,
        execute=False,
        child_env=child_env,
    )
    cluster_output = build(
        verilator_bin,
        "a0_cu_cluster_shared_l2_tb",
        CLUSTER_SOURCES
        + [ROOT / "tests/rtl/a0_cu_cluster_shared_l2_tb.sv"],
        execute=not compile_only,
        child_env=child_env,
    )

    for cu_count in (1, 2, 3, 4):
        lint_variant(verilator_bin, cu_count, 2, child_env=child_env)
    lint_variant(verilator_bin, 3, 3, child_env=child_env)
    lint_variant(verilator_bin, 3, 4, child_env=child_env)
    print("PRODUCTION_MULTI_CU_PARAMETER_PROOFS=PASS CU_COUNT=1,2,3,4 MSHR=2,3,4")

    if compile_only:
        print("PRODUCTION_MULTI_CU_STATIC_COMPILE=PASS")
        return

    if "A0_CLUSTER_STORE_ORDER_CONTROLLER_TB=PASS" not in controller_output:
        raise RuntimeError("controller support marker missing")
    if "A0_CU_CLUSTER_SHARED_L2_WIRING_TB=PASS" not in cluster_output:
        raise RuntimeError("cluster wiring support marker missing")

    child_env["PYTHONDONTWRITEBYTECODE"] = "1"
    rtl9d3_output = run_historical_toolchain_regression(child_env)
    bridge_output = run(
        [sys.executable, str(ROOT / "tests/run_rtl8b_load_mshr_bridge.py")],
        env=child_env,
    )
    combined = rtl9d3_output + bridge_output
    missing = [marker for marker in SCENARIO_MARKERS if marker not in combined]
    if missing:
        raise RuntimeError("missing production marker(s): " + ", ".join(missing))

    print(f"TARGETED_SCENARIO_COUNT={len(SCENARIO_MARKERS)}")
    print("PRODUCTION_MULTI_CU_SHARED_L2_DRIVER=PASS")


if __name__ == "__main__":
    main()
