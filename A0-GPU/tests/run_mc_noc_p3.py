#!/usr/bin/env python3

from __future__ import annotations

from dataclasses import dataclass
import os
from pathlib import Path
import re
import shlex
import shutil
import subprocess
import sys
import tempfile


sys.dont_write_bytecode = True


ROOT = Path(__file__).resolve().parents[1]
P0_DUT = ROOT / "rtl/memory/a0_cluster_line_noc_endpoint.sv"
P1_DUT = ROOT / "rtl/memory/a0_mc_noc_logical_request_router.sv"
P2_DUT = ROOT / "rtl/memory/a0_mc_noc_logical_transaction_router.sv"
L2_DUT = ROOT / "rtl/memory/a0_l2_line_cache.sv"
P3_DUT = ROOT / "rtl/memory/a0_mc_noc_sliced_l2_subsystem.sv"
TB = ROOT / "tests/rtl/a0_mc_noc_sliced_l2_subsystem_tb.sv"
DOC = ROOT / "docs/architecture/A0_MC_NOC_P3_SLICED_L2_COMPOSITION.md"
RUNNER = Path(__file__).resolve()

VERILATOR_ENV = "A0_VERILATOR_BIN"
EXPECTED_VERSION = "5.050"
TOP = "a0_mc_noc_sliced_l2_subsystem_tb"
DUT_TOP = "a0_mc_noc_sliced_l2_subsystem"
COMPILE_TIMEOUT = 480
SIM_TIMEOUT = 180


SCENARIOS: tuple[tuple[int, str], ...] = (
    (1, "RESET_OUTPUTS_GATED"),
    (2, "RESET_RELEASE_EMPTY"),
    (3, "LOCAL_REQUEST_REGISTERED_NO_BYPASS"),
    (4, "CLUSTER_PREFIX_ADDED_AT_BACKEND"),
    (5, "CU_LOCAL_TAG_EXACT_AT_BACKEND"),
    (6, "LINE_AND_HOME_HASH_EXACT"),
    (7, "COLD_MISS_REACHES_ONLY_HOME_BACKEND"),
    (8, "BACKEND_REQUEST_STALL_STABLE"),
    (9, "BACKEND_REQUEST_TURNOVER"),
    (10, "OPAQUE_UNUSED_LOCAL_TAG_ROUND_TRIP"),
    (11, "TWO_CLUSTER_DIFFERENT_HOME_BACKEND_OVERLAP"),
    (12, "OVERLAP_BACKEND_NETWORK_TAGS_EXACT"),
    (13, "REVERSE_ORDER_CLUSTER_CU_TAG_RESTORE"),
    (14, "REVERSE_ORDER_LINE_DATA_EXACT"),
    (15, "SAME_SUFFIX_DIFFERENT_CLUSTERS_DISTINCT"),
    (16, "SAME_CLUSTER_DIFFERENT_SLICE_SIMULTANEOUS_RESPONSES"),
    (17, "SAME_CLUSTER_SIMULTANEOUS_NO_LOSS"),
    (18, "DIFFERENT_CLUSTERS_SIMULTANEOUS_LOCAL_OUTPUT"),
    (19, "BACKEND_BACKPRESSURE_ISOLATED_PER_SLICE"),
    (20, "LOCAL_RESPONSE_BACKPRESSURE_STABLE"),
    (21, "LOCAL_RESPONSE_BACKPRESSURE_ISOLATED_PER_CLUSTER"),
    (22, "LOCAL_RESPONSE_EXACTLY_ONCE"),
    (23, "SAME_SLICE_CROSS_CLUSTER_RR_PROGRESS"),
    (24, "SAME_SLICE_REVERSE_ORDER_BACKEND_RESPONSE"),
    (25, "SHARED_L2_CROSS_CLUSTER_HIT"),
    (26, "SHARED_L2_HIT_SUPPRESSES_BACKEND"),
    (27, "FAULT_RESPONSE_PRESERVED"),
    (28, "FAULTED_REFILL_NOT_INSTALLED"),
    (29, "SAME_CYCLE_BACKEND_COMPLETION"),
    (30, "SAME_CYCLE_TAG_REUSE_AFTER_LOCAL_RETIRE"),
    (31, "OWNED_DUPLICATE_HELD_BEFORE_BACKEND"),
    (32, "BOUNDARY_BACKPRESSURE_PROPAGATES_NO_LOSS"),
    (33, "INVALID_LOCAL_CU_REJECTED"),
    (34, "ORPHAN_BACKEND_RESPONSE_REJECTED"),
    (35, "WRONG_LINE_RESPONSE_REJECTED_OWNER_SURVIVES"),
    (36, "WRONG_HOME_RESPONSE_REJECTED_OWNER_SURVIVES"),
    (37, "INVALID_RESPONSE_CLUSTER_CU_REJECTED"),
    (38, "MALFORMED_SLICE_PEER_DOES_NOT_BLOCK"),
    (39, "RESET_FLUSHES_IN_FLIGHT_AND_HELD"),
    (40, "FINAL_CONSERVATION_DRAIN"),
)
MARKERS = tuple(
    f"MC_NOC_P3_{number:02d}_{name}=PASS"
    for number, name in SCENARIOS
)
SMOKE_MARKER = "MC_NOC_P3_PARAMETER_SMOKE=PASS"
PASS_LINE_RE = re.compile(r"^MC_NOC_P3_[A-Z0-9_]+=PASS$")
DISPLAY_RE = re.compile(
    r'(?m)^[ \t]*\$display[ \t]*\([ \t]*"'
    r'(MC_NOC_P3_([0-9]{2})_([A-Z0-9_]+)=PASS)'
    r'"[ \t]*\)[ \t]*;[ \t]*$'
)

FLAGS: tuple[str, ...] = (
    "--binary",
    "--timing",
    "--unroll-count",
    "512",
    "-Wall",
    "-Werror-PINMISSING",
    "-Werror-WIDTHEXPAND",
    "-Werror-WIDTHTRUNC",
)


@dataclass(frozen=True)
class Configuration:
    cluster_count: int
    cus_per_cluster: int
    mshr_count: int
    line_words: int
    slice_count: int
    set_count: int
    l2_miss_count: int
    full: bool

    @property
    def short(self) -> str:
        return (
            f"K{self.cluster_count}_U{self.cus_per_cluster}_"
            f"M{self.mshr_count}_W{self.line_words}_"
            f"S{self.slice_count}_SET{self.set_count}_"
            f"LM{self.l2_miss_count}"
        )


FULL_CONFIGURATION = Configuration(3, 3, 3, 4, 4, 8, 4, True)
SMOKE_CONFIGURATIONS: tuple[Configuration, ...] = (
    Configuration(1, 1, 1, 1, 1, 1, 1, False),
    Configuration(2, 2, 2, 4, 2, 4, 2, False),
    Configuration(4, 4, 4, 8, 4, 16, 4, False),
)
LARGE_CONFIGURATION = Configuration(8, 4, 4, 8, 4, 256, 16, False)


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


def compact(value: str, limit: int = 1400) -> str:
    rendered = " ".join(value.replace("\r", "").splitlines()).strip()
    return rendered if len(rendered) <= limit else rendered[:limit] + "..."


def report_failure(failure: Failure) -> None:
    print("MC_NOC_P3_VALIDATION=FAIL")
    print(f"STAGE={compact(failure.stage)}")
    print(f"FIRST_ERROR={compact(failure.error)}")
    print(f"COMMAND={compact(failure.command)}")
    print(f"EXIT_CODE={compact(failure.exit_code)}")
    print(f"CONFIGURATION={compact(failure.configuration)}")
    print(f"EXPECTED={compact(failure.expected)}")
    print(f"OBSERVED={compact(failure.observed)}")
    print(f"ROOT_CAUSE_CLASS={compact(failure.cause)}")
    print(f"DUT_OR_TB={compact(failure.dut_or_tb)}")


def run(
    command: list[str],
    *,
    stage: str,
    configuration: str,
    timeout: int,
) -> subprocess.CompletedProcess[str]:
    try:
        result = subprocess.run(
            command,
            cwd=ROOT,
            text=True,
            stdout=subprocess.PIPE,
            stderr=subprocess.STDOUT,
            timeout=timeout,
            env={**os.environ, "PYTHONDONTWRITEBYTECODE": "1"},
        )
    except subprocess.TimeoutExpired as exc:
        raise Failure(
            stage,
            "COMMAND_TIMEOUT",
            command=shlex.join(command),
            exit_code="TIMEOUT",
            configuration=configuration,
            expected=f"completion within {timeout}s",
            observed=compact(str(exc)),
            cause="TOOL_OR_RUNTIME_TIMEOUT",
            dut_or_tb="UNRESOLVED",
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
            observed=result.stdout[-4000:],
            cause="DUT_TB_OR_TOOL_FAILURE",
            dut_or_tb=dut_or_tb,
        )
    warnings = [
        line.strip() for line in result.stdout.splitlines()
        if "%Warning" in line or re.search(r"\bwarning:\s", line, re.I)
    ]
    if warnings:
        raise Failure(
            stage,
            "VERILATOR_WARNING_PRESENT",
            command=shlex.join(command),
            exit_code="0",
            configuration=configuration,
            expected="zero warning lines",
            observed=warnings[0],
            cause="STATIC_COMPILE_WARNING",
            dut_or_tb=dut_or_tb,
        )


def strip_comments(source: str) -> str:
    return re.sub(r"//.*?$|/\*.*?\*/", "", source, flags=re.M | re.S)


def require_files() -> None:
    for path in (P0_DUT, P1_DUT, P2_DUT, L2_DUT, P3_DUT, TB, DOC, RUNNER):
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
    try:
        compile(RUNNER.read_text(encoding="utf-8"), str(RUNNER), "exec")
        dut = P3_DUT.read_text(encoding="utf-8")
        tb = TB.read_text(encoding="utf-8")
        doc = DOC.read_text(encoding="utf-8")
    except (OSError, UnicodeError, SyntaxError) as exc:
        raise Failure(
            "STATIC_CONTRACT",
            "SOURCE_READ_OR_PARSE_FAILURE",
            observed=str(exc),
            cause="ARTIFACT_DEFECT",
            dut_or_tb="NEITHER",
        ) from exc

    dut_code = strip_comments(dut)
    required_dut = (
        "module a0_mc_noc_sliced_l2_subsystem",
        "a0_cluster_line_noc_endpoint #(",
        "a0_mc_noc_logical_transaction_router #(",
        "a0_l2_line_cache #(",
        "cluster_local_req_valid_i",
        "cluster_local_req_ready_o",
        "cluster_local_resp_valid_o",
        "cluster_local_resp_ready_i",
        "line_mem_req_valid_o",
        "line_mem_req_ready_i",
        "line_mem_resp_valid_i",
        "noc_req_tag_error_o",
        "slice_resp_protocol_error_o",
        "noc_resp_tag_error_o",
        "CLUSTER_MAX_OUTSTANDING",
        "OWNER_SLOT_W",
        "slice_req_hold_valid_q",
        "slice_req_hold_network_tag_q",
        "slice_req_hold_line_addr_q",
        "slice_req_enqueue",
        "slice_req_dequeue",
        "always_ff",
    )
    missing = [token for token in required_dut if token not in dut_code]
    if missing:
        raise Failure(
            "STATIC_CONTRACT",
            "DUT_REQUIRED_TOKEN_MISSING",
            expected=" | ".join(required_dut),
            observed="missing=" + repr(missing),
            cause="RTL_SOURCE_DEFECT",
            dut_or_tb="DUT",
        )

    forbidden_dut = (
        "a0_line_slice_fabric #(",
        "a0_multi_slice_l2_subsystem #(",
        "a0_cu_cluster #(",
        "line_mem_resp_ready_o",
        "always_latch",
    )
    present = [token for token in forbidden_dut if token in dut_code]
    if present:
        raise Failure(
            "STATIC_CONTRACT",
            "DUT_FORBIDDEN_DEPENDENCY_OR_STATE_PRESENT",
            expected=(
                "P0 -> P2 -> registered one-entry per-slice request seam -> L2 "
                "with no legacy/production wrapper or latch"
            ),
            observed="present=" + repr(present),
            cause="ARCHITECTURE_SCOPE_DEFECT",
            dut_or_tb="DUT",
        )

    required_doc = (
        "load-line-only",
        "no-ready",
        "one unchanged P0 endpoint per cluster",
        "one unchanged P2 transaction router",
        "a0_cluster_line_noc_endpoint",
        "a0_mc_noc_logical_transaction_router",
        "a0_l2_line_cache",
        "a0_line_slice_fabric",
        "shared reset",
        "registered elastic request seam",
        "combinational dependency",
        "production",
    )
    missing_doc = [token for token in required_doc if token not in doc]
    if missing_doc:
        raise Failure(
            "STATIC_CONTRACT",
            "DOC_REQUIRED_CONTRACT_MISSING",
            expected=" | ".join(required_doc),
            observed="missing=" + repr(missing_doc),
            cause="DOCUMENTATION_DEFECT",
            dut_or_tb="NEITHER",
        )

    if re.search(r"\bdut\s*\.", strip_comments(tb)):
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
    found = shutil.which(raw)
    if found is None:
        raise Failure(
            "TOOLCHAIN_IDENTITY",
            "VERILATOR_NOT_FOUND",
            expected=raw,
            observed="not executable on PATH",
            cause="TOOLCHAIN_DEFECT",
            dut_or_tb="NEITHER",
        )
    resolved = Path(found).resolve(strict=True)
    result = subprocess.run(
        [str(resolved), "--version"],
        cwd=ROOT,
        text=True,
        stdout=subprocess.PIPE,
        stderr=subprocess.STDOUT,
    )
    fields = result.stdout.strip().split()
    actual = (
        fields[1]
        if result.returncode == 0 and len(fields) >= 2 and fields[0] == "Verilator"
        else "UNPARSEABLE"
    )
    if actual != EXPECTED_VERSION:
        raise Failure(
            "TOOLCHAIN_IDENTITY",
            "VERILATOR_VERSION_MISMATCH",
            command=shlex.join([str(resolved), "--version"]),
            exit_code=str(result.returncode),
            expected=EXPECTED_VERSION,
            observed=actual,
            cause="TOOLCHAIN_DEFECT",
            dut_or_tb="NEITHER",
        )
    print(f"MC_NOC_P3_VERILATOR_BIN={resolved}")
    print(f"MC_NOC_P3_VERILATOR_VERSION={actual}")
    return resolved


def source_arguments() -> list[str]:
    return [
        str(P0_DUT),
        str(P1_DUT),
        str(P2_DUT),
        str(L2_DUT),
        str(P3_DUT),
    ]


def parameter_arguments(configuration: Configuration) -> list[str]:
    return [
        f"-GCLUSTER_COUNT={configuration.cluster_count}",
        f"-GCUS_PER_CLUSTER={configuration.cus_per_cluster}",
        f"-GMSHR_COUNT={configuration.mshr_count}",
        f"-GLINE_WORDS={configuration.line_words}",
        f"-GL2_SLICE_COUNT={configuration.slice_count}",
        f"-GL2_SET_COUNT_PER_SLICE={configuration.set_count}",
        f"-GL2_MISS_COUNT_PER_SLICE={configuration.l2_miss_count}",
    ]


def marker_lines(output: str) -> tuple[str, ...]:
    return tuple(
        line.strip() for line in output.splitlines()
        if PASS_LINE_RE.fullmatch(line.strip())
    )


def compile_and_run(
    verilator: Path,
    build_root: Path,
    configuration: Configuration,
) -> None:
    mdir = build_root / configuration.short
    executable = mdir / "p3_sim"
    command = [
        str(verilator),
        *FLAGS,
        *(("-DMC_NOC_P3_FULL",) if configuration.full else ()),
        "--top-module",
        TOP,
        *parameter_arguments(configuration),
        f"-GFULL_SCENARIOS={1 if configuration.full else 0}",
        "--Mdir",
        str(mdir),
        "-o",
        executable.name,
        *source_arguments(),
        str(TB),
    ]
    result = run(
        command,
        stage="VERILATOR_COMPILE",
        configuration=configuration.short,
        timeout=COMPILE_TIMEOUT,
    )
    require_success(
        result,
        command,
        stage="VERILATOR_COMPILE",
        configuration=configuration.short,
        dut_or_tb="DUT_OR_TB",
    )

    sim_command = [str(executable)]
    simulation = run(
        sim_command,
        stage="SIMULATION",
        configuration=configuration.short,
        timeout=SIM_TIMEOUT,
    )
    require_success(
        simulation,
        sim_command,
        stage="SIMULATION",
        configuration=configuration.short,
        dut_or_tb="DUT_OR_TB",
    )
    expected = MARKERS if configuration.full else (SMOKE_MARKER,)
    observed = marker_lines(simulation.stdout)
    if observed != expected:
        raise Failure(
            "SCENARIO_MARKERS",
            "RUNTIME_MARKER_ORDER_OR_IDENTITY_MISMATCH",
            command=shlex.join(sim_command),
            exit_code="0",
            configuration=configuration.short,
            expected=" | ".join(expected),
            observed=" | ".join(observed),
            cause="DUT_TB_OR_MARKER_FAILURE",
            dut_or_tb="DUT_OR_TB",
        )


def large_structural_lint(verilator: Path, build_root: Path) -> None:
    configuration = LARGE_CONFIGURATION
    command = [
        str(verilator),
        "--lint-only",
        "--timing",
        "--unroll-count",
        "1024",
        "-Wall",
        "-Werror-PINMISSING",
        "-Werror-WIDTHEXPAND",
        "-Werror-WIDTHTRUNC",
        "--top-module",
        DUT_TOP,
        *parameter_arguments(configuration),
        "--Mdir",
        str(build_root / (configuration.short + "_LINT")),
        *source_arguments(),
    ]
    result = run(
        command,
        stage="LARGE_STRUCTURAL_LINT",
        configuration=configuration.short,
        timeout=COMPILE_TIMEOUT,
    )
    require_success(
        result,
        command,
        stage="LARGE_STRUCTURAL_LINT",
        configuration=configuration.short,
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
        *source_arguments(),
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
            observed=simulation.stdout[-1600:],
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
        print("MC_NOC_P3_STATIC_CONTRACT=PASS")

        with tempfile.TemporaryDirectory(
            prefix="a0_mc_noc_p3_",
            dir="/tmp",
        ) as temporary:
            build_root = Path(temporary)

            compile_and_run(verilator, build_root, FULL_CONFIGURATION)
            print("MC_NOC_P3_VERILATOR_5_050_COMPILE=PASS")
            print(f"MC_NOC_P3_TARGETED_SCENARIO_COUNT={len(MARKERS)}")
            print("MC_NOC_P3_TARGETED_40=PASS")

            for configuration in SMOKE_CONFIGURATIONS:
                compile_and_run(verilator, build_root, configuration)
            print("MC_NOC_P3_PARAMETER_MATRIX=PASS")

            large_structural_lint(verilator, build_root)
            print(
                "MC_NOC_P3_LARGE_STRUCTURAL_CONFIGURATION="
                "K8_U4_M4_LW8_S4_SET256_L2M16"
            )
            print("MC_NOC_P3_LARGE_STRUCTURAL_K8=PASS")
            print("MC_NOC_P3_LARGE_STRUCTURAL_LINT=PASS")

            invalids = (
                (
                    "SLICE_COUNT_3",
                    ("-GL2_SLICE_COUNT=3",),
                    "SLICE_COUNT must be a power of two",
                ),
                (
                    "HASH_SHIFT_30",
                    ("-GSLICE_HASH_SHIFT=30",),
                    "SLICE_HASH_SHIFT must be below LINE_ADDR_W",
                ),
                (
                    "LINE_WORDS_3",
                    ("-GLINE_WORDS=3",),
                    "LINE_WORDS must be a power of two",
                ),
                (
                    "L2_SET_COUNT_3",
                    ("-GL2_SET_COUNT_PER_SLICE=3",),
                    "L2_SET_COUNT_PER_SLICE must be a power of two",
                ),
                (
                    "L2_MISS_COUNT_0",
                    ("-GL2_MISS_COUNT_PER_SLICE=0",),
                    "L2_MISS_COUNT_PER_SLICE must be >= 1",
                ),
                (
                    "CUS_PER_CLUSTER_5",
                    ("-GCUS_PER_CLUSTER=5",),
                    "CUS_PER_CLUSTER must be 1..4",
                ),
                (
                    "OWNER_SLOT_W_5",
                    ("-GOWNER_SLOT_W=5",),
                    "OWNER_SLOT_W inconsistent",
                ),
                (
                    "OWNER_CAPACITY_5",
                    ("-GCLUSTER_MAX_OUTSTANDING=5",),
                    "CLUSTER_MAX_OUTSTANDING inconsistent",
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
                print(f"MC_NOC_P3_INVALID_{name}=PASS")
            print(f"MC_NOC_P3_INVALID_CONFIGURATION_COUNT={len(invalids)}")
            print("MC_NOC_P3_INVALID_CONFIGS_FAIL_CLOSED=PASS")

        print("MC_NOC_P3_VALIDATION=PASS")
        return 0
    except Failure as failure:
        report_failure(failure)
        return 1


if __name__ == "__main__":
    raise SystemExit(main())
