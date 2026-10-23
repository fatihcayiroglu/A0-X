#!/usr/bin/env python3

from __future__ import annotations

from pathlib import Path
import os
import re
import shutil
import subprocess
import sys
import tempfile


ROOT = Path(__file__).resolve().parents[1]
FABRIC = ROOT / "rtl/memory/a0_line_slice_fabric.sv"
L2 = ROOT / "rtl/memory/a0_l2_line_cache.sv"
SUBSYSTEM = ROOT / "rtl/memory/a0_multi_slice_l2_subsystem.sv"
FABRIC_TB = ROOT / "tests/rtl/a0_line_slice_fabric_tb.sv"
SUBSYSTEM_TB = ROOT / "tests/rtl/a0_multi_slice_l2_subsystem_tb.sv"
DOC = ROOT / "docs/architecture/A0_SLICED_L2_ROUTING_FOUNDATION.md"

VALIDATED_VERILATOR_VERSION = "5.050"
VERILATOR_BIN_ENV = "A0_VERILATOR_BIN"

MARKERS = [
    f"SLICED_L2_{index:02d}_{name}=PASS"
    for index, name in [
        (1, "RESET_IDLE"),
        (2, "HASH_LOW_BITS"),
        (3, "HASH_XOR_FOLD"),
        (4, "CLIENT0_SLICE0_ROUTE"),
        (5, "CLIENT1_SLICE1_ROUTE"),
        (6, "BASIC_RESPONSE_RESTORE"),
        (7, "DIFFERENT_SLICE_CONCURRENCY"),
        (8, "SAME_SLICE_SINGLE_GRANT"),
        (9, "SAME_SLICE_WAITER_PROGRESS"),
        (10, "SAME_SLICE_ROUND_ROBIN_PROGRESS"),
        (11, "BACKPRESSURE_HOLD_CREATED"),
        (12, "BACKPRESSURE_PAYLOAD_STABLE"),
        (13, "BACKPRESSURE_DRAIN"),
        (14, "BACKPRESSURE_ISOLATION"),
        (15, "DUPLICATE_LOCAL_TAG_BLOCKED"),
        (16, "OUTSTANDING_CAPACITY_BLOCK"),
        (17, "MULTI_SLICE_SAME_CLIENT_CAPTURE"),
        (18, "MULTI_RESPONSE_LOSSLESS_DRAIN"),
        (19, "DIFFERENT_CLIENT_RESPONSE_CONCURRENCY"),
        (20, "NO_CROSS_CLIENT_RESPONSE_LEAKAGE"),
        (21, "MALFORMED_CLIENT_ID_REJECTED"),
        (22, "WRONG_LINE_RESPONSE_REJECTED"),
        (23, "WRONG_HOME_SLICE_REJECTED"),
        (24, "DUPLICATE_RESPONSE_REJECTED"),
        (25, "FAULT_RESPONSE_PRESERVED"),
        (26, "SAME_CYCLE_TAG_REUSE_AFTER_EMIT"),
        (27, "NO_PROTOCOL_CORRECT_OVERFLOW"),
        (28, "FINAL_DRAIN"),
        (29, "COLD_MISS_SLICE0"),
        (30, "REFILL_RESPONSE_RESTORED"),
        (31, "COLD_MISS_SLICE1"),
        (32, "L2_HIT_SUPPRESSES_BACKEND"),
        (33, "DIFFERENT_SLICE_MISS_CONCURRENCY"),
        (34, "OOO_RESPONSES_ACROSS_SLICES"),
        (35, "INDEPENDENT_BACKEND_PORTS"),
        (36, "STORE_ROUTED_TO_HOME_SLICE_ONLY"),
        (37, "STORE_INVALIDATES_RESIDENT_HOME_LINE"),
        (38, "UNRELATED_SLICE_UNAFFECTED_BY_STORE"),
        (39, "STORE_KILLS_MATCHING_REFILL_INSTALL"),
        (40, "SAME_CYCLE_STORE_REFILL_NOT_INSTALLED"),
        (41, "FAULTED_REFILL_NOT_INSTALLED"),
        (42, "BACKEND_BACKPRESSURE_ISOLATED_PER_SLICE"),
        (43, "STALLED_SLICE_EVENTUALLY_DRAINS"),
        (44, "FINAL_DRAIN_NO_LOSS"),
        (45, "MULTI_SLICE_L2_SUBSYSTEM"),
    ]
]


def run(command: list[str], *, expect_success: bool = True) -> str:
    result = subprocess.run(
        command,
        cwd=ROOT,
        text=True,
        stdout=subprocess.PIPE,
        stderr=subprocess.STDOUT,
    )
    print(result.stdout, end="")
    if expect_success and result.returncode:
        raise RuntimeError(
            f"command failed rc={result.returncode}: " + " ".join(command)
        )
    if not expect_success and result.returncode == 0:
        raise RuntimeError(
            "command unexpectedly succeeded: " + " ".join(command)
        )
    return result.stdout


def resolve_verilator() -> str:
    configured = os.environ.get(VERILATOR_BIN_ENV)
    requested = configured if configured is not None else "verilator"
    if not requested:
        raise RuntimeError(f"{VERILATOR_BIN_ENV} is empty")
    found = shutil.which(requested)
    if found is None:
        raise RuntimeError(
            f"Verilator not found; set {VERILATOR_BIN_ENV} to exact "
            f"{VALIDATED_VERILATOR_VERSION} executable"
        )
    resolved = str(Path(found).resolve(strict=True))
    result = subprocess.run(
        [resolved, "--version"],
        cwd=ROOT,
        text=True,
        stdout=subprocess.PIPE,
        stderr=subprocess.STDOUT,
    )
    text = result.stdout.strip()
    fields = text.split()
    actual = fields[1] if result.returncode == 0 and len(fields) >= 2 and fields[0] == "Verilator" else "UNPARSEABLE"
    if actual != VALIDATED_VERILATOR_VERSION:
        raise RuntimeError(
            "VERILATOR_TOOLCHAIN_VERSION_MISMATCH "
            f"required_exact={VALIDATED_VERILATOR_VERSION} actual={actual} "
            f"executable={resolved}"
        )
    print(f"SLICED_L2_VERILATOR_BIN={resolved}")
    print(f"SLICED_L2_VERILATOR_VERSION={actual}")
    return resolved


def compile_python(path: Path) -> None:
    compile(path.read_text(encoding="utf-8"), str(path), "exec")


def behavioral(
    verilator: str,
    *,
    top: str,
    sources: list[Path],
    prefix: str,
) -> str:
    with tempfile.TemporaryDirectory(prefix=prefix) as temp:
        obj = Path(temp) / "obj_dir"
        output = run([
            verilator,
            "--binary",
            "--timing",
            "--unroll-count",
            "128",
            "-Wall",
            "-Werror-PINMISSING",
            "-Werror-WIDTHEXPAND",
            "-Werror-WIDTHTRUNC",
            "--top-module",
            top,
            "--Mdir",
            str(obj),
            *map(str, sources),
        ])
        exe = obj / f"V{top}"
        if not exe.exists():
            raise RuntimeError(f"behavioral executable missing: {exe}")
        output += run([str(exe)])
        return output


def lint_fabric_variant(
    verilator: str,
    *,
    client_count: int,
    slice_count: int,
    max_outstanding: int,
) -> None:
    with tempfile.TemporaryDirectory(prefix="a0_sliced_l2_fabric_lint_") as temp:
        run([
            verilator,
            "--lint-only",
            "--unroll-count",
            "128",
            "-Wall",
            "-Werror-PINMISSING",
            "-Werror-WIDTHEXPAND",
            "-Werror-WIDTHTRUNC",
            "--top-module",
            "a0_line_slice_fabric",
            f"-GCLIENT_COUNT={client_count}",
            "-GLOCAL_TAG_W=2",
            f"-GSLICE_COUNT={slice_count}",
            f"-GCLIENT_MAX_OUTSTANDING={max_outstanding}",
            "--Mdir",
            str(Path(temp) / "obj_dir"),
            str(FABRIC),
        ])


def lint_subsystem_variant(
    verilator: str,
    *,
    client_count: int,
    slice_count: int,
    max_outstanding: int,
) -> None:
    with tempfile.TemporaryDirectory(prefix="a0_sliced_l2_subsystem_lint_") as temp:
        run([
            verilator,
            "--lint-only",
            "--unroll-count",
            "128",
            "-Wall",
            "-Werror-PINMISSING",
            "-Werror-WIDTHEXPAND",
            "-Werror-WIDTHTRUNC",
            "--top-module",
            "a0_multi_slice_l2_subsystem",
            f"-GCLIENT_COUNT={client_count}",
            "-GLOCAL_TAG_W=2",
            f"-GL2_SLICE_COUNT={slice_count}",
            f"-GCLIENT_MAX_OUTSTANDING={max_outstanding}",
            "-GSTORE_LANES_PER_CLIENT=4",
            "-GL2_SET_COUNT_PER_SLICE=16",
            "-GL2_MISS_COUNT_PER_SLICE=4",
            "--Mdir",
            str(Path(temp) / "obj_dir"),
            str(FABRIC),
            str(L2),
            str(SUBSYSTEM),
        ])


def invalid_slice_count_guard(verilator: str) -> None:
    with tempfile.TemporaryDirectory(prefix="a0_sliced_l2_invalid_slice_") as temp:
        obj = Path(temp) / "obj_dir"
        run([
            verilator,
            "--binary",
            "--timing",
            "-Wall",
            "-Werror-PINMISSING",
            "-Werror-WIDTHEXPAND",
            "-Werror-WIDTHTRUNC",
            "--top-module",
            "a0_line_slice_fabric",
            "-GCLIENT_COUNT=1",
            "-GLOCAL_TAG_W=1",
            "-GSLICE_COUNT=3",
            "-GCLIENT_MAX_OUTSTANDING=1",
            "--Mdir",
            str(obj),
            str(FABRIC),
        ])
        exe = obj / "Va0_line_slice_fabric"
        output = run([str(exe)], expect_success=False)
        if "SLICE_COUNT must be a power of two" not in output:
            raise RuntimeError("invalid SLICE_COUNT did not fail for the frozen reason")
    print("SLICED_L2_INVALID_SLICE_COUNT_FAIL_CLOSED=PASS")


def static_contract() -> None:
    required_files = [FABRIC, L2, SUBSYSTEM, FABRIC_TB, SUBSYSTEM_TB, DOC]
    missing = [str(path.relative_to(ROOT)) for path in required_files if not path.is_file()]
    if missing:
        raise RuntimeError("missing sliced-L2 files: " + ", ".join(missing))

    fabric = FABRIC.read_text(encoding="utf-8")
    subsystem = SUBSYSTEM.read_text(encoding="utf-8")
    doc = DOC.read_text(encoding="utf-8")

    for token in [
        "SLICE_COUNT",
        "CLIENT_MAX_OUTSTANDING",
        "SLICE_HASH_SHIFT",
        "slice_rr_q",
        "response_slot_valid_q",
        "tag_awaiting_q",
        "line_resp_tag_error_o",
        "line_resp_overflow_o",
    ]:
        if token not in fabric:
            raise RuntimeError(f"fabric static contract missing {token}")

    for token in [
        "a0_line_slice_fabric",
        "a0_l2_line_cache",
        "L2_SLICE_COUNT",
        "slice_store_lane_mask",
        "line_mem_req_valid_o",
        "line_mem_resp_valid_i",
    ]:
        if token not in subsystem:
            raise RuntimeError(f"subsystem static contract missing {token}")

    # Check actual SystemVerilog instantiations, not comments/documentation.
    # V1 used a raw substring search here, so the intentional comment
    # "isolated from a0_cu_cluster" falsely tripped the guard before RTL compile.
    subsystem_code = re.sub(r"/\*.*?\*/", "", subsystem, flags=re.S)
    subsystem_code = re.sub(r"//.*", "", subsystem_code)
    for forbidden in [
        "a0_cu_cluster",
        "a0_multi_wave_core",
        "a0_cluster_store_order_controller",
    ]:
        instance_pattern = re.compile(
            rf"(?m)^\s*{re.escape(forbidden)}\s*(?:#\s*\(|[A-Za-z_$][A-Za-z0-9_$]*\s*\()"
        )
        if instance_pattern.search(subsystem_code):
            raise RuntimeError(
                f"production integration forbidden in sliced-L2 foundation: {forbidden}"
            )

    if "cache coherence" not in doc.lower() or "power of two" not in doc.lower():
        raise RuntimeError("architecture document is missing frozen boundary language")

    print("SLICED_L2_STATIC_CONTRACT=PASS")


def main() -> None:
    static_contract()
    compile_python(Path(__file__).resolve())
    print("SLICED_L2_PYTHON_COMPILE=PASS")

    verilator = resolve_verilator()

    output = behavioral(
        verilator,
        top="a0_line_slice_fabric_tb",
        sources=[FABRIC, FABRIC_TB],
        prefix="a0_sliced_l2_fabric_behavior_",
    )
    output += behavioral(
        verilator,
        top="a0_multi_slice_l2_subsystem_tb",
        sources=[FABRIC, L2, SUBSYSTEM, SUBSYSTEM_TB],
        prefix="a0_sliced_l2_subsystem_behavior_",
    )

    missing = [marker for marker in MARKERS if marker not in output]
    duplicates = [marker for marker in MARKERS if output.count(marker) != 1]
    if missing or duplicates:
        raise RuntimeError(
            "targeted marker failure "
            f"missing={missing} non_singleton={duplicates}"
        )
    print(f"SLICED_L2_TARGETED_SCENARIOS=PASS count={len(MARKERS)}")

    variants = [
        (1, 1, 1),
        (1, 2, 2),
        (3, 2, 2),
        (3, 4, 3),
        (4, 4, 4),
    ]
    for client_count, slice_count, max_outstanding in variants:
        lint_fabric_variant(
            verilator,
            client_count=client_count,
            slice_count=slice_count,
            max_outstanding=max_outstanding,
        )
        lint_subsystem_variant(
            verilator,
            client_count=client_count,
            slice_count=slice_count,
            max_outstanding=max_outstanding,
        )
        print(
            "SLICED_L2_STATIC_VARIANT=PASS "
            f"CLIENT_COUNT={client_count} "
            f"SLICE_COUNT={slice_count} "
            f"CLIENT_MAX_OUTSTANDING={max_outstanding}"
        )

    invalid_slice_count_guard(verilator)
    print("SLICED_L2_FOUNDATION_DRIVER=PASS")


if __name__ == "__main__":
    main()
