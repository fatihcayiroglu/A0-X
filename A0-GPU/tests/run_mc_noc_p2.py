#!/usr/bin/env python3

from __future__ import annotations

import os
from pathlib import Path
import re
import shlex
import subprocess
import sys
import tempfile

sys.dont_write_bytecode = True


ROOT = Path(__file__).resolve().parents[1]
P1_DUT = ROOT / "rtl/memory/a0_mc_noc_logical_request_router.sv"
P2_DUT = ROOT / "rtl/memory/a0_mc_noc_logical_transaction_router.sv"
TB = ROOT / "tests/rtl/a0_mc_noc_logical_transaction_router_tb.sv"
DOC = ROOT / "docs/architecture/A0_MC_NOC_P2_LOGICAL_RESPONSE_ROUTING.md"
RUNNER = Path(__file__).resolve()

VERILATOR_ENV = "A0_VERILATOR_BIN"
EXPECTED_VERSION = "5.050"
TOP = "a0_mc_noc_logical_transaction_router_tb"
DUT_TOP = "a0_mc_noc_logical_transaction_router"
COMPILE_TIMEOUT = 360
SIM_TIMEOUT = 90

SCENARIOS: tuple[tuple[int, str], ...] = (
    (1, "RESET_OUTPUTS_GATED"),
    (2, "RESET_RELEASE_EMPTY"),
    (3, "REQUEST_REGISTERED_NO_BYPASS"),
    (4, "REQUEST_HOME_HASH_PRESERVED"),
    (5, "REQUEST_TAG_LINE_EXACT"),
    (6, "OPAQUE_UNUSED_LOCAL_TAG"),
    (7, "REQUEST_STALL_STABLE"),
    (8, "REQUEST_TURNOVER"),
    (9, "DIFFERENT_SLICE_CONCURRENT"),
    (10, "WRONG_CLUSTER_REQUEST_REJECT"),
    (11, "UNUSED_CLUSTER_REQUEST_REJECT"),
    (12, "UNUSED_CU_REQUEST_REJECT"),
    (13, "QUEUED_OWNER_RESERVED"),
    (14, "DUPLICATE_REQUEST_BACKPRESSURE_NO_ERROR"),
    (15, "SLICE_ISSUE_TRANSITION"),
    (16, "CAPACITY_FULL_BACKPRESSURE_NO_ERROR"),
    (17, "RESPONSE_REGISTERED_NO_BYPASS"),
    (18, "BASIC_RESPONSE_ROUTE"),
    (19, "RESPONSE_FULL_TAG_EXACT"),
    (20, "RESPONSE_LINE_EXACT"),
    (21, "RESPONSE_FAULT_EXACT"),
    (22, "RESPONSE_ALL_WORDS_EXACT"),
    (23, "RESPONSE_STALL_STABLE"),
    (24, "RESPONSE_EXACTLY_ONCE"),
    (25, "REVERSE_ORDER_COMPLETION"),
    (26, "SAME_SUFFIX_DIFFERENT_CLUSTERS"),
    (27, "DIFFERENT_CLUSTERS_CONCURRENT_OUTPUT"),
    (28, "SAME_CLUSTER_SIMULTANEOUS_CAPTURE"),
    (29, "SAME_CLUSTER_NO_RESPONSE_LOSS"),
    (30, "BACKPRESSURE_ISOLATION"),
    (31, "RR_CURSOR_ONLY_RETIRE"),
    (32, "RR_SPARSE_COMPLETIONS"),
    (33, "RR_WRAP"),
    (34, "FAIRNESS_BOUND"),
    (35, "ADVERSARIAL_REFILL_NO_STARVATION"),
    (36, "SAME_CYCLE_RETIRE_REUSE"),
    (37, "ORPHAN_REJECT"),
    (38, "PREMATURE_REJECT"),
    (39, "DUPLICATE_COMPLETE_REJECT"),
    (40, "DUPLICATE_EMITTING_REJECT"),
    (41, "POST_RETIRE_ORPHAN_REJECT"),
    (42, "WRONG_LINE_REJECT_OWNER_SURVIVES"),
    (43, "WRONG_HOME_REJECT_OWNER_SURVIVES"),
    (44, "INVALID_RESPONSE_CLUSTER"),
    (45, "INVALID_RESPONSE_CU"),
    (46, "MALFORMED_PEER_DOES_NOT_BLOCK"),
    (47, "SAME_CYCLE_ISSUE_RESPONSE"),
    (48, "FULL_TABLE_RETIRE_REPLACEMENT"),
    (49, "RESET_FLUSH_ALL_STATES"),
    (50, "FINAL_CONSERVATION_DRAIN"),
)
MARKERS = tuple(
    f"MC_NOC_P2_{number:02d}_{name}=PASS"
    for number, name in SCENARIOS
)
SMOKE_MARKER = "MC_NOC_P2_PARAMETER_SMOKE=PASS"
PASS_LINE_RE = re.compile(r"^MC_NOC_P2_[A-Z0-9_]+=PASS$")
DISPLAY_RE = re.compile(
    r'(?m)^[ \t]*\$display[ \t]*\([ \t]*"'
    r'(MC_NOC_P2_([0-9]{2})_([A-Z0-9_]+)=PASS)'
    r'"[ \t]*\)[ \t]*;[ \t]*$'
)

FLAGS: tuple[str, ...] = (
    "--binary",
    "--timing",
    "--unroll-count",
    "256",
    "-Wall",
    "-Werror-PINMISSING",
    "-Werror-WIDTHEXPAND",
    "-Werror-WIDTHTRUNC",
)


class Failure(RuntimeError):
    def __init__(
        self,
        stage: str,
        error: str,
        *,
        command: str = "NOT_APPLICABLE",
        exit_code: str = "NOT_APPLICABLE",
        configuration: str = "NONE",
        expected: str = "",
        observed: str = "",
        cause: str = "RUNNER_OR_QUALIFICATION_DEFECT",
        dut_or_tb: str = "UNRESOLVED",
    ) -> None:
        super().__init__(error)
        self.stage = stage
        self.error = error
        self.command = command
        self.exit_code = exit_code
        self.configuration = configuration
        self.expected = expected
        self.observed = observed
        self.cause = cause
        self.dut_or_tb = dut_or_tb


def compact(value: object) -> str:
    return " | ".join(str(value).splitlines()) or "NONE"


def report_failure(failure: Failure) -> None:
    print("MC_NOC_P2_FIRST_FAILURE")
    print(f"STAGE={compact(failure.stage)}")
    print(f"COMMAND={compact(failure.command)}")
    print(f"EXIT_CODE={compact(failure.exit_code)}")
    print(f"FIRST_ERROR={compact(failure.error)}")
    print("FAILING_FILE=SEE_TOOL_OUTPUT")
    print("FAILING_LINE=SEE_TOOL_OUTPUT")
    print("SCENARIO=FIRST_UNREACHED_MARKER")
    print(f"CONFIGURATION={compact(failure.configuration)}")
    print(f"EXPECTED={compact(failure.expected)}")
    print(f"OBSERVED={compact(failure.observed)}")
    print(f"ROOT_CAUSE_CLASS={compact(failure.cause)}")
    print(f"DUT_OR_TB={compact(failure.dut_or_tb)}")


def environment() -> dict[str, str]:
    result = os.environ.copy()
    result["PYTHONDONTWRITEBYTECODE"] = "1"
    result["TMPDIR"] = "/tmp"
    result.pop("TEMP", None)
    result.pop("TMP", None)
    return result


def run(
    command: list[str],
    *,
    stage: str,
    configuration: str,
    timeout: int,
) -> subprocess.CompletedProcess[str]:
    rendered = shlex.join(command)
    try:
        result = subprocess.run(
            command,
            cwd=ROOT,
            env=environment(),
            text=True,
            encoding="utf-8",
            errors="replace",
            stdout=subprocess.PIPE,
            stderr=subprocess.STDOUT,
            timeout=timeout,
            check=False,
        )
    except subprocess.TimeoutExpired as exc:
        output = exc.stdout or ""
        if isinstance(output, bytes):
            output = output.decode("utf-8", errors="replace")
        print(output, end="")
        raise Failure(
            stage,
            "COMMAND_TIMEOUT",
            command=rendered,
            exit_code="TIMEOUT",
            configuration=configuration,
            expected=f"completion within {timeout}s",
            observed="timeout",
            cause="TOOL_OR_SIMULATION_TIMEOUT",
        ) from exc
    except OSError as exc:
        raise Failure(
            stage,
            "COMMAND_LAUNCH_FAILED",
            command=rendered,
            exit_code="NOT_STARTED",
            configuration=configuration,
            expected="command starts",
            observed=str(exc),
            cause="TOOL_INVOCATION_DEFECT",
            dut_or_tb="NEITHER",
        ) from exc
    print(result.stdout, end="")
    return result


def require_success(
    result: subprocess.CompletedProcess[str],
    command: list[str],
    *,
    stage: str,
    configuration: str,
    dut_or_tb: str,
) -> None:
    if result.returncode != 0:
        raise Failure(
            stage,
            "COMMAND_FAILED",
            command=shlex.join(command),
            exit_code=str(result.returncode),
            configuration=configuration,
            expected="exit code 0",
            observed=f"exit code {result.returncode}",
            cause="SOURCE_TB_OR_TOOL_FAILURE",
            dut_or_tb=dut_or_tb,
        )
    warning_lines = [
        line for line in result.stdout.splitlines()
        if "%Warning" in line
    ]
    if warning_lines:
        raise Failure(
            stage,
            "VERILATOR_WARNING_PRESENT",
            command=shlex.join(command),
            exit_code="0",
            configuration=configuration,
            expected="zero warning lines",
            observed=warning_lines[0],
            cause="STATIC_COMPILE_WARNING",
            dut_or_tb=dut_or_tb,
        )


def require_files() -> None:
    for path in (P1_DUT, P2_DUT, TB, DOC, RUNNER):
        if not path.is_file():
            raise Failure(
                "SOURCE_AVAILABILITY",
                "REQUIRED_FILE_MISSING",
                expected=str(path),
                observed="absent",
                cause="ARTIFACT_AVAILABILITY_DEFECT",
                dut_or_tb="NEITHER",
            )


def require_static_contract() -> None:
    dut = P2_DUT.read_text(encoding="utf-8")
    tb = TB.read_text(encoding="utf-8")
    doc = DOC.read_text(encoding="utf-8")

    required_dut = (
        "module a0_mc_noc_logical_transaction_router",
        "a0_mc_noc_logical_request_router #(",
        "CLUSTER_MAX_OUTSTANDING",
        "OWNER_QUEUED",
        "OWNER_AWAITING",
        "OWNER_COMPLETE",
        "OWNER_EMITTING",
        "slice_resp_protocol_error_o",
        "cluster_resp_ready_i",
        "response_same_cycle_issue",
        "cluster_response_dequeue",
    )
    for token in required_dut:
        if token not in dut:
            raise Failure(
                "STATIC_CONTRACT",
                "DUT_REQUIRED_TOKEN_MISSING",
                expected=token,
                observed="absent",
                cause="RTL_SOURCE_DEFECT",
                dut_or_tb="DUT",
            )

    forbidden_dut = (
        "slice_resp_ready_o",
        "a0_l2_line_cache #(",
        "a0_multi_slice_l2_subsystem #(",
        "a0_cu_cluster #(",
    )
    for token in forbidden_dut:
        if token in dut:
            raise Failure(
                "STATIC_CONTRACT",
                "DUT_FORBIDDEN_DEPENDENCY_PRESENT",
                expected=f"absence of {token}",
                observed="present",
                cause="ARCHITECTURE_SCOPE_DEFECT",
                dut_or_tb="DUT",
            )

    required_doc = (
        "local-tag field remains opaque",
        "no-ready",
        "FREE -> QUEUED -> AWAITING -> COMPLETE -> EMITTING -> FREE",
        "pre-reset response cannot reappear",
        "exactly four files",
        "P3 owns isolated multi-cluster",
    )
    for token in required_doc:
        if token not in doc:
            raise Failure(
                "STATIC_CONTRACT",
                "DOC_REQUIRED_CONTRACT_MISSING",
                expected=token,
                observed="absent",
                cause="DOCUMENTATION_DEFECT",
                dut_or_tb="NEITHER",
            )

    if re.search(r"\bdut\s*\.", tb):
        raise Failure(
            "STATIC_CONTRACT",
            "TB_PRIVATE_IDENTIFIER_DEPENDENCY",
            expected="public ports only",
            observed="hierarchical dut reference",
            cause="TB_DEFECT",
            dut_or_tb="TB",
        )

    literal_markers = tuple(match.group(1) for match in DISPLAY_RE.finditer(tb))
    if literal_markers != MARKERS:
        raise Failure(
            "MARKER_MANIFEST",
            "LITERAL_MARKER_ORDER_OR_IDENTITY_MISMATCH",
            expected=" | ".join(MARKERS),
            observed=" | ".join(literal_markers),
            cause="TB_OR_RUNNER_CONTRACT_DEFECT",
            dut_or_tb="TB",
        )
    if tb.count(f'$display("{SMOKE_MARKER}")') != 1:
        raise Failure(
            "MARKER_MANIFEST",
            "SMOKE_MARKER_IDENTITY_MISMATCH",
            expected="one literal smoke marker",
            observed=str(tb.count(f'$display("{SMOKE_MARKER}")')),
            cause="TB_DEFECT",
            dut_or_tb="TB",
        )


def require_tool() -> Path:
    raw = os.environ.get(VERILATOR_ENV, "")
    if not raw:
        raise Failure(
            "TOOLCHAIN_IDENTITY",
            "A0_VERILATOR_BIN_NOT_SET",
            expected=f"{VERILATOR_ENV}=exact Verilator {EXPECTED_VERSION}",
            observed="unset",
            cause="TOOLCHAIN_DEFECT",
            dut_or_tb="NEITHER",
        )
    binary = Path(raw).resolve()
    if not binary.is_file():
        raise Failure(
            "TOOLCHAIN_IDENTITY",
            "VERILATOR_NOT_FOUND",
            expected=str(binary),
            observed="absent",
            cause="TOOLCHAIN_DEFECT",
            dut_or_tb="NEITHER",
        )
    command = [str(binary), "--version"]
    result = run(
        command,
        stage="TOOLCHAIN_IDENTITY",
        configuration="VERSION",
        timeout=30,
    )
    require_success(
        result,
        command,
        stage="TOOLCHAIN_IDENTITY",
        configuration="VERSION",
        dut_or_tb="NEITHER",
    )
    match = re.search(r"Verilator\s+([0-9]+\.[0-9]+)", result.stdout)
    observed = match.group(1) if match else "UNPARSEABLE"
    if observed != EXPECTED_VERSION:
        raise Failure(
            "TOOLCHAIN_IDENTITY",
            "VERILATOR_VERSION_MISMATCH",
            command=shlex.join(command),
            exit_code="0",
            configuration="VERSION",
            expected=EXPECTED_VERSION,
            observed=observed,
            cause="TOOLCHAIN_DEFECT",
            dut_or_tb="NEITHER",
        )
    return binary


def marker_lines(output: str) -> tuple[str, ...]:
    return tuple(
        line.strip() for line in output.splitlines()
        if PASS_LINE_RE.fullmatch(line.strip())
    )


def compile_and_run(
    verilator: Path,
    build_root: Path,
    *,
    cluster_count: int,
    cus_per_cluster: int,
    mshr_count: int,
    slice_count: int,
    full: bool,
) -> None:
    short = (
        f"K{cluster_count}_U{cus_per_cluster}_"
        f"M{mshr_count}_S{slice_count}"
    )
    mdir = build_root / short
    executable = mdir / "p2_sim"
    command = [
        str(verilator),
        *FLAGS,
        *((("-DMC_NOC_P2_FULL",) if full else ())),
        "--top-module",
        TOP,
        f"-GCLUSTER_COUNT={cluster_count}",
        f"-GCUS_PER_CLUSTER={cus_per_cluster}",
        f"-GMSHR_COUNT={mshr_count}",
        f"-GSLICE_COUNT={slice_count}",
        f"-GFULL_SCENARIOS={1 if full else 0}",
        "--Mdir",
        str(mdir),
        "-o",
        executable.name,
        str(P1_DUT),
        str(P2_DUT),
        str(TB),
    ]
    result = run(
        command,
        stage="VERILATOR_COMPILE",
        configuration=short,
        timeout=COMPILE_TIMEOUT,
    )
    require_success(
        result,
        command,
        stage="VERILATOR_COMPILE",
        configuration=short,
        dut_or_tb="DUT_OR_TB",
    )

    sim_command = [str(executable)]
    simulation = run(
        sim_command,
        stage="SIMULATION",
        configuration=short,
        timeout=SIM_TIMEOUT,
    )
    require_success(
        simulation,
        sim_command,
        stage="SIMULATION",
        configuration=short,
        dut_or_tb="DUT_OR_TB",
    )
    expected = MARKERS if full else (SMOKE_MARKER,)
    observed = marker_lines(simulation.stdout)
    if observed != expected:
        raise Failure(
            "SCENARIO_MARKERS",
            "RUNTIME_MARKER_ORDER_OR_IDENTITY_MISMATCH",
            command=shlex.join(sim_command),
            exit_code="0",
            configuration=short,
            expected=" | ".join(expected),
            observed=" | ".join(observed),
            cause="DUT_TB_OR_MARKER_FAILURE",
            dut_or_tb="DUT_OR_TB",
        )


def large_structural_lint(verilator: Path, build_root: Path) -> None:
    command = [
        str(verilator),
        "--lint-only",
        "--timing",
        "--unroll-count",
        "512",
        "-Wall",
        "-Werror-PINMISSING",
        "-Werror-WIDTHEXPAND",
        "-Werror-WIDTHTRUNC",
        "--top-module",
        DUT_TOP,
        "-GCLUSTER_COUNT=8",
        "-GCUS_PER_CLUSTER=4",
        "-GMSHR_COUNT=4",
        "-GSLICE_COUNT=4",
        "--Mdir",
        str(build_root / "K8_U4_M4_S4_LINT"),
        str(P1_DUT),
        str(P2_DUT),
    ]
    result = run(
        command,
        stage="LARGE_STRUCTURAL_LINT",
        configuration="K8_U4_M4_S4",
        timeout=COMPILE_TIMEOUT,
    )
    require_success(
        result,
        command,
        stage="LARGE_STRUCTURAL_LINT",
        configuration="K8_U4_M4_S4",
        dut_or_tb="DUT",
    )


def invalid_configuration(
    verilator: Path,
    build_root: Path,
    name: str,
    overrides: tuple[str, ...],
    expected_fragment: str,
) -> None:
    mdir = build_root / f"INVALID_{name}"
    executable = mdir / "invalid_sim"
    command = [
        str(verilator),
        *FLAGS,
        "--top-module",
        DUT_TOP,
        *overrides,
        "--Mdir",
        str(mdir),
        "-o",
        executable.name,
        str(P1_DUT),
        str(P2_DUT),
    ]
    compiled = run(
        command,
        stage="INVALID_CONFIG_COMPILE",
        configuration=name,
        timeout=COMPILE_TIMEOUT,
    )
    require_success(
        compiled,
        command,
        stage="INVALID_CONFIG_COMPILE",
        configuration=name,
        dut_or_tb="DUT",
    )

    sim_command = [str(executable)]
    simulation = run(
        sim_command,
        stage="INVALID_CONFIG_RUNTIME",
        configuration=name,
        timeout=30,
    )
    if simulation.returncode == 0:
        raise Failure(
            "INVALID_CONFIG_RUNTIME",
            "INVALID_CONFIGURATION_DID_NOT_FAIL",
            command=shlex.join(sim_command),
            exit_code="0",
            configuration=name,
            expected="nonzero exit before PASS",
            observed="exit code 0",
            cause="RTL_PARAMETER_GUARD_DEFECT",
            dut_or_tb="DUT",
        )
    if expected_fragment not in simulation.stdout:
        raise Failure(
            "INVALID_CONFIG_RUNTIME",
            "EXPECTED_FATAL_FRAGMENT_MISSING",
            command=shlex.join(sim_command),
            exit_code=str(simulation.returncode),
            configuration=name,
            expected=expected_fragment,
            observed=simulation.stdout[-1000:],
            cause="RTL_OR_RUNNER_DEFECT",
            dut_or_tb="DUT",
        )
    if marker_lines(simulation.stdout):
        raise Failure(
            "INVALID_CONFIG_RUNTIME",
            "INVALID_CONFIGURATION_EMITTED_PASS",
            command=shlex.join(sim_command),
            exit_code=str(simulation.returncode),
            configuration=name,
            expected="no PASS marker",
            observed=" | ".join(marker_lines(simulation.stdout)),
            cause="RTL_OR_RUNNER_DEFECT",
            dut_or_tb="DUT",
        )


def main() -> int:
    try:
        require_files()
        require_static_contract()
        verilator = require_tool()
        print("MC_NOC_P2_STATIC_CONTRACT=PASS")

        with tempfile.TemporaryDirectory(
            prefix="a0_mc_noc_p2_",
            dir="/tmp",
        ) as temporary:
            build_root = Path(temporary)

            compile_and_run(
                verilator,
                build_root,
                cluster_count=3,
                cus_per_cluster=3,
                mshr_count=3,
                slice_count=4,
                full=True,
            )
            print("MC_NOC_P2_VERILATOR_5_050_COMPILE=PASS")
            print(f"MC_NOC_P2_TARGETED_SCENARIO_COUNT={len(MARKERS)}")
            print("MC_NOC_P2_TARGETED_50=PASS")

            for config in (
                (1, 1, 1, 1),
                (2, 2, 2, 2),
                (4, 4, 4, 4),
            ):
                compile_and_run(
                    verilator,
                    build_root,
                    cluster_count=config[0],
                    cus_per_cluster=config[1],
                    mshr_count=config[2],
                    slice_count=config[3],
                    full=False,
                )
            print("MC_NOC_P2_PARAMETER_MATRIX=PASS")

            large_structural_lint(verilator, build_root)
            print("MC_NOC_P2_LARGE_STRUCTURAL_LINT=PASS")

            invalids = (
                (
                    "SLICE_COUNT_3",
                    ("-GSLICE_COUNT=3",),
                    "SLICE_COUNT must be a power of two",
                ),
                (
                    "HASH_SHIFT_29",
                    ("-GSLICE_HASH_SHIFT=29",),
                    "SLICE_HASH_SHIFT must be below LINE_ADDR_W",
                ),
                (
                    "MSHR_COUNT_0",
                    ("-GMSHR_COUNT=0",),
                    "MSHR_COUNT must be >= 1",
                ),
                (
                    "CUS_PER_CLUSTER_0",
                    ("-GCUS_PER_CLUSTER=0",),
                    "CUS_PER_CLUSTER must be 1..4",
                ),
                (
                    "OWNER_CAPACITY_8",
                    ("-GCLUSTER_MAX_OUTSTANDING=8",),
                    "CLUSTER_MAX_OUTSTANDING inconsistent",
                ),
                (
                    "OWNER_SLOT_W_5",
                    ("-GOWNER_SLOT_W=5",),
                    "OWNER_SLOT_W inconsistent",
                ),
            )
            for name, overrides, fragment in invalids:
                invalid_configuration(
                    verilator,
                    build_root,
                    name,
                    overrides,
                    fragment,
                )
            print("MC_NOC_P2_INVALID_CONFIGS_FAIL_CLOSED=PASS")

        print("MC_NOC_P2_VALIDATION=PASS")
        return 0
    except Failure as failure:
        report_failure(failure)
        return 1


if __name__ == "__main__":
    raise SystemExit(main())
