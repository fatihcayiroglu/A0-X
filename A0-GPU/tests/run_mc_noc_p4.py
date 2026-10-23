#!/usr/bin/env python3

from __future__ import annotations

from dataclasses import dataclass
import hashlib
import math
import os
from pathlib import Path
import re
import shlex
import subprocess
import sys
import tempfile


sys.dont_write_bytecode = True


RUNNER = Path(__file__).resolve()
CANDIDATE_ROOT = RUNNER.parents[1]
ROOT = Path(os.environ.get("A0_REPO_ROOT", CANDIDATE_ROOT)).resolve()

P0_DUT = ROOT / "rtl/memory/a0_cluster_line_noc_endpoint.sv"
P1_DUT = ROOT / "rtl/memory/a0_mc_noc_logical_request_router.sv"
P2_DUT = ROOT / "rtl/memory/a0_mc_noc_logical_transaction_router.sv"
L2_DUT = ROOT / "rtl/memory/a0_l2_line_cache.sv"
P3_DUT = ROOT / "rtl/memory/a0_mc_noc_sliced_l2_subsystem.sv"
TB = CANDIDATE_ROOT / "tests/rtl/a0_mc_noc_p4_measurement_tb.sv"
DOC = (
    CANDIDATE_ROOT
    / "docs/architecture/A0_MC_NOC_P4_PARAMETERIZATION_FAIRNESS_HOL.md"
)

EXPECTED_VERILATOR = Path(
    "/tmp/a0-verilator-ab-8KXw1HJJ/verilator-v5.050/bin/verilator"
)
EXPECTED_VERILATOR_VERSION = "5.050"
EXPECTED_VERILATOR_SHA256 = (
    "ea03a1bd85f60779e79d6d9ae14b899abf4bc55f7d47b908a217ba67b23f25fa"
)

TOP = "a0_mc_noc_p4_measurement_tb"
DUT_TOP = "a0_mc_noc_sliced_l2_subsystem"
COMPILE_TIMEOUT = 600
SIM_TIMEOUT = 300
LARGE_LINT_TIMEOUT = 900


SCENARIOS: tuple[tuple[int, str], ...] = (
    (1, "RESET_TURNOVER_CONSERVATION"),
    (2, "SUSTAINED_SAME_HOME_RR_OPPORTUNITY_BOUND"),
    (3, "BALANCED_DISTINCT_HOME_MIN_K_S_THROUGHPUT"),
    (4, "FULL_HOLD_READY_SENSITIVITY"),
    (5, "FULL_HOLD_PAYLOAD_STABILITY"),
    (6, "SCALAR_REQUEST_HOL_CHARACTERIZED"),
    (7, "OTHER_CLUSTER_HOL_ISOLATION"),
    (8, "LOCAL_RESPONSE_STALL_O_PLUS_ONE_BOUNDARY"),
    (9, "LOCAL_RESPONSE_LOSSLESS_DRAIN"),
    (10, "SIMULTANEOUS_SLICE_RESPONSES"),
    (11, "MISS_Q_SATURATION"),
    (12, "MISS_Q_SLICE_ISOLATION"),
    (13, "HASH_BALANCED_MAPPING"),
    (14, "HASH_HOTSPOT_CHARACTERIZED"),
    (15, "BACKEND_RESPONSE_HIT_STARVATION_CHARACTERIZED"),
    (16, "RESET_FLUSHES_IN_FLIGHT"),
    (17, "SAME_CYCLE_TURNOVER"),
    (18, "NON_POWER_IDENTITY"),
    (19, "FINAL_CONSERVATION"),
)
MARKERS = tuple(
    f"MC_NOC_P4_{number:02d}_{name}=PASS"
    for number, name in SCENARIOS
)
SMOKE_MARKER = "MC_NOC_P4_PARAMETER_SMOKE=PASS"
PASS_LINE_RE = re.compile(r"^MC_NOC_P4_[A-Z0-9_]+=PASS$")
DISPLAY_RE = re.compile(
    r'(?m)^[ \t]*\$display[ \t]*\([ \t]*"'
    r'(MC_NOC_P4_([0-9]{2})_([A-Z0-9_]+)=PASS)'
    r'"[ \t]*\)[ \t]*;[ \t]*$'
)
WARNING_RE = re.compile(r"(?im)(?:^|\b)(?:%Warning|warning:)")


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
            f"L2M{self.l2_miss_count}"
        )


CONFIGURATIONS: tuple[Configuration, ...] = (
    Configuration(1, 1, 1, 1, 1, 1, 1, False),
    Configuration(2, 2, 2, 4, 2, 4, 2, False),
    Configuration(3, 3, 3, 4, 4, 8, 4, True),
    Configuration(4, 2, 2, 8, 4, 16, 4, False),
    Configuration(4, 4, 4, 8, 4, 16, 4, False),
)
LARGE_CONFIGURATION = Configuration(64, 4, 4, 8, 64, 256, 16, False)


DEPENDENCY_HASHES: dict[Path, str] = {
    P0_DUT: "384ee90577e438b03613e78d24dd48f3919085f3e6edb1ec45e8fe6008b193c9",
    P1_DUT: "9887b2fb3a7fedd8a52745ac5d8f334a1569f2769e1f0105d7174f8a55e37f3d",
    P2_DUT: "12247282728dfb614e2d65139c49201b9f0aa71eaff5c79950be0a5a9cd60581",
    L2_DUT: "5d67b6ed5cddff2ce86558b9c4664e526c3b05e1f5fd9f4e4049c243a093b086",
    P3_DUT: "2ac547b359171a8498255f03963a37c2ef28c6760107b16f7bf0be15d93bfe13",
}


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
        cause: str = "P4_QUALIFICATION_DEFECT",
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


def compact(value: str, limit: int = 1800) -> str:
    text = " | ".join(value.replace("\r", "").splitlines())
    return text[-limit:] if len(text) > limit else text


def report_failure(failure: Failure) -> None:
    print("MC_NOC_P4_FIRST_FAILURE", file=sys.stderr)
    print("MC_NOC_P4_QUALIFICATION=FAIL", file=sys.stderr)
    print(f"STAGE={failure.stage}", file=sys.stderr)
    print(f"COMMAND={failure.command}", file=sys.stderr)
    print(f"EXIT_CODE={failure.exit_code}", file=sys.stderr)
    print(f"CONFIGURATION={failure.configuration}", file=sys.stderr)
    print(f"FIRST_ERROR={failure.error}", file=sys.stderr)
    print(f"EXPECTED={compact(failure.expected)}", file=sys.stderr)
    print(f"OBSERVED={compact(failure.observed)}", file=sys.stderr)
    print(f"ROOT_CAUSE_CLASS={failure.cause}", file=sys.stderr)
    print(f"DUT_OR_TB={failure.dut_or_tb}", file=sys.stderr)
    print("TIMING=NOT_MEASURED", file=sys.stderr)
    print("LIVE_REPO_MUTATION=NONE", file=sys.stderr)
    print("COMMIT=NONE", file=sys.stderr)
    print("PUSH=NOT_PERFORMED", file=sys.stderr)


def run(
    command: list[str],
    *,
    stage: str,
    configuration: str,
    timeout: int,
) -> subprocess.CompletedProcess[str]:
    environment = os.environ.copy()
    environment["LC_ALL"] = "C"
    environment["LANG"] = "C"
    environment["PYTHONDONTWRITEBYTECODE"] = "1"
    try:
        return subprocess.run(
            command,
            cwd=ROOT,
            env=environment,
            text=True,
            stdout=subprocess.PIPE,
            stderr=subprocess.STDOUT,
            timeout=timeout,
            check=False,
        )
    except (OSError, subprocess.TimeoutExpired) as exc:
        raise Failure(
            stage,
            "COMMAND_EXECUTION_FAILURE",
            command=shlex.join(command),
            configuration=configuration,
            expected="command completes inside timeout",
            observed=str(exc),
            cause="HOST_OR_TOOL_EXECUTION_DEFECT",
            dut_or_tb="UNRESOLVED",
        ) from exc


def sha256(path: Path) -> str:
    digest = hashlib.sha256()
    with path.open("rb") as stream:
        for chunk in iter(lambda: stream.read(1024 * 1024), b""):
            digest.update(chunk)
    return digest.hexdigest()


def strip_comments(source: str) -> str:
    return re.sub(r"//.*?$|/\*.*?\*/", "", source, flags=re.M | re.S)


def require_files_and_identity() -> None:
    required = (*DEPENDENCY_HASHES, TB, DOC, RUNNER)
    for path in required:
        if not path.is_file():
            raise Failure(
                "SOURCE_IDENTITY",
                "REQUIRED_FILE_MISSING",
                expected=str(path),
                observed="absent",
                cause="SOURCE_AVAILABILITY_DEFECT",
                dut_or_tb="NEITHER",
            )

    for path, expected_hash in DEPENDENCY_HASHES.items():
        actual_hash = sha256(path)
        if actual_hash != expected_hash:
            raise Failure(
                "SOURCE_IDENTITY",
                "CLOSED_DEPENDENCY_HASH_MISMATCH",
                expected=f"{expected_hash}:{path}",
                observed=f"{actual_hash}:{path}",
                cause="CLOSED_SOURCE_IDENTITY_DEFECT",
                dut_or_tb="DUT",
            )

    modes = ((DOC, 0o644), (TB, 0o644), (RUNNER, 0o755))
    for path, expected_mode in modes:
        actual_mode = path.stat().st_mode & 0o777
        if actual_mode != expected_mode:
            raise Failure(
                "SOURCE_IDENTITY",
                "P4_SOURCE_MODE_MISMATCH",
                expected=f"{expected_mode:o}:{path}",
                observed=f"{actual_mode:o}:{path}",
                cause="P4_SOURCE_MODE_DEFECT",
                dut_or_tb="NEITHER",
            )


def require_static_contract() -> None:
    try:
        compile(RUNNER.read_text(encoding="utf-8"), str(RUNNER), "exec")
        tb = TB.read_text(encoding="utf-8")
        doc = DOC.read_text(encoding="utf-8")
    except (OSError, UnicodeError, SyntaxError) as exc:
        raise Failure(
            "STATIC_CONTRACT",
            "SOURCE_READ_OR_PARSE_FAILURE",
            observed=str(exc),
            cause="P4_ARTIFACT_DEFECT",
            dut_or_tb="NEITHER",
        ) from exc

    tb_code = strip_comments(tb)
    required_tb = (
        "module a0_mc_noc_p4_measurement_tb",
        "a0_mc_noc_sliced_l2_subsystem #(",
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
    )
    missing_tb = [token for token in required_tb if token not in tb_code]
    if missing_tb:
        raise Failure(
            "STATIC_CONTRACT",
            "TB_PUBLIC_CONTRACT_TOKEN_MISSING",
            expected=" | ".join(required_tb),
            observed="missing=" + repr(missing_tb),
            cause="P4_TB_CONTRACT_DEFECT",
            dut_or_tb="TB",
        )

    private_patterns = (
        r"\bdut\s*\.",
        r"owner_state_q",
        r"owner_network_tag_q",
        r"slice_req_hold_valid_q",
        r"slice_hold_valid_q",
        r"req_hold_valid_q",
        r"resp_hold_valid_q",
    )
    present_private = [
        pattern
        for pattern in private_patterns
        if re.search(pattern, tb_code)
    ]
    if present_private:
        raise Failure(
            "STATIC_CONTRACT",
            "TB_PRIVATE_RTL_DEPENDENCY_PRESENT",
            expected="public P3 ports only",
            observed=" | ".join(present_private),
            cause="P4_BLACK_BOX_CONTRACT_DEFECT",
            dut_or_tb="TB",
        )

    extracted = tuple(match.group(1) for match in DISPLAY_RE.finditer(tb))
    if extracted != MARKERS:
        raise Failure(
            "STATIC_CONTRACT",
            "ORDERED_LITERAL_MARKER_SOURCE_MISMATCH",
            expected=" | ".join(MARKERS),
            observed=" | ".join(extracted),
            cause="P4_MARKER_CONTRACT_DEFECT",
            dut_or_tb="TB",
        )

    required_doc = (
        "MC_NOC_P4_TIMING=NOT_MEASURED",
        "P1 request arbitration        = S arbiters, K candidates each = K*S",
        "P2 = K*O * (4 + NT + A + SID + 32*W)",
        "K=64 U=4 M=4 W=8 S=64 N=256 Q=16",
        "ROUTING_REGISTERED_BITS=339584",
        "COMBINED_REGISTERED_BITS=4955264",
        "within at most\n`K` accepted service opportunities",
        "within at most `O`\nretirement opportunities",
        "P4 black-box test directly proves the P1 `K`-opportunity bound",
        "protected by frozen P2 scenarios 34\nand 35",
        "O+1` completed lines",
        "adds no DUT RTL",
    )
    missing_doc = [token for token in required_doc if token not in doc]
    if missing_doc:
        raise Failure(
            "STATIC_CONTRACT",
            "DOCUMENT_MEASUREMENT_CONTRACT_MISSING",
            expected=" | ".join(required_doc),
            observed="missing=" + repr(missing_doc),
            cause="P4_DOCUMENT_CONTRACT_DEFECT",
            dut_or_tb="NEITHER",
        )

    forbidden_doc = (
        "TIMING=PASS",
        "FMAX=PASS",
        "VOQ_REQUIRED=YES",
        "MULTIPLE_LANES_REQUIRED=YES",
    )
    present_doc = [token for token in forbidden_doc if token in doc]
    if present_doc:
        raise Failure(
            "STATIC_CONTRACT",
            "DOCUMENT_UNSUPPORTED_CONCLUSION_PRESENT",
            expected="measurement without unproved optimization mandate",
            observed=" | ".join(present_doc),
            cause="P4_DOCUMENT_OVERCLAIM_DEFECT",
            dut_or_tb="NEITHER",
        )

    if CANDIDATE_ROOT != ROOT and (CANDIDATE_ROOT / "rtl").exists():
        raise Failure(
            "STATIC_CONTRACT",
            "P4_DUT_RTL_SCOPE_PRESENT",
            expected="no candidate rtl directory",
            observed=str(CANDIDATE_ROOT / "rtl"),
            cause="P4_SCOPE_EXPANSION_DEFECT",
            dut_or_tb="DUT",
        )


def require_tool() -> Path:
    requested = Path(os.environ.get("A0_VERILATOR_BIN", EXPECTED_VERILATOR))
    try:
        requested_resolved = requested.resolve(strict=True)
        expected_resolved = EXPECTED_VERILATOR.resolve(strict=True)
    except OSError as exc:
        raise Failure(
            "TOOLCHAIN_IDENTITY",
            "EXACT_VERILATOR_NOT_FOUND",
            expected=str(EXPECTED_VERILATOR),
            observed=str(exc),
            cause="FROZEN_TOOLCHAIN_AVAILABILITY_DEFECT",
            dut_or_tb="NEITHER",
        ) from exc
    if requested_resolved != expected_resolved:
        raise Failure(
            "TOOLCHAIN_IDENTITY",
            "VERILATOR_PATH_MISMATCH",
            expected=str(expected_resolved),
            observed=str(requested_resolved),
            cause="FROZEN_TOOLCHAIN_IDENTITY_DEFECT",
            dut_or_tb="NEITHER",
        )
    actual_hash = sha256(requested_resolved)
    if actual_hash != EXPECTED_VERILATOR_SHA256:
        raise Failure(
            "TOOLCHAIN_IDENTITY",
            "VERILATOR_SHA256_MISMATCH",
            expected=EXPECTED_VERILATOR_SHA256,
            observed=actual_hash,
            cause="FROZEN_TOOLCHAIN_IDENTITY_DEFECT",
            dut_or_tb="NEITHER",
        )
    version_command = [str(requested_resolved), "--version"]
    version = run(
        version_command,
        stage="TOOLCHAIN_IDENTITY",
        configuration="NONE",
        timeout=30,
    )
    if version.returncode != 0:
        raise Failure(
            "TOOLCHAIN_IDENTITY",
            "VERILATOR_VERSION_COMMAND_FAILED",
            command=shlex.join(version_command),
            exit_code=str(version.returncode),
            expected=EXPECTED_VERILATOR_VERSION,
            observed=version.stdout,
            cause="FROZEN_TOOLCHAIN_EXECUTION_DEFECT",
            dut_or_tb="NEITHER",
        )
    match = re.search(r"\bVerilator\s+([0-9]+\.[0-9]+)\b", version.stdout)
    actual_version = match.group(1) if match else "UNPARSEABLE"
    if actual_version != EXPECTED_VERILATOR_VERSION:
        raise Failure(
            "TOOLCHAIN_IDENTITY",
            "VERILATOR_VERSION_MISMATCH",
            command=shlex.join(version_command),
            exit_code="0",
            expected=EXPECTED_VERILATOR_VERSION,
            observed=actual_version,
            cause="FROZEN_TOOLCHAIN_IDENTITY_DEFECT",
            dut_or_tb="NEITHER",
        )
    return requested_resolved


def source_arguments(include_tb: bool) -> list[str]:
    sources = [P0_DUT, P1_DUT, P2_DUT, L2_DUT, P3_DUT]
    if include_tb:
        sources.append(TB)
    return [str(path) for path in sources]


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


def require_clean_command_output(
    completed: subprocess.CompletedProcess[str],
    command: list[str],
    *,
    stage: str,
    configuration: str,
    dut_or_tb: str,
) -> None:
    if completed.returncode != 0:
        raise Failure(
            stage,
            "COMMAND_RETURNED_NONZERO",
            command=shlex.join(command),
            exit_code=str(completed.returncode),
            configuration=configuration,
            expected="exit code 0",
            observed=completed.stdout,
            cause="RTL_TB_OR_TOOL_FAILURE",
            dut_or_tb=dut_or_tb,
        )
    warning_match = WARNING_RE.search(completed.stdout)
    if warning_match:
        raise Failure(
            stage,
            "WARNING_OUTPUT_PRESENT",
            command=shlex.join(command),
            exit_code="0",
            configuration=configuration,
            expected="zero warning lines",
            observed=completed.stdout,
            cause="WARNING_CLEANLINESS_DEFECT",
            dut_or_tb=dut_or_tb,
        )


def marker_lines(output: str) -> tuple[str, ...]:
    return tuple(
        line.strip()
        for line in output.splitlines()
        if PASS_LINE_RE.fullmatch(line.strip())
    )


def compile_and_run(
    verilator: Path,
    build_root: Path,
    configuration: Configuration,
) -> None:
    mdir = build_root / configuration.short
    executable = mdir / "p4_sim"
    command = [
        str(verilator),
        *FLAGS,
        "--top-module",
        TOP,
        *parameter_arguments(configuration),
        f"-GFULL_SCENARIOS={1 if configuration.full else 0}",
    ]
    if configuration.full:
        command.append("-DMC_NOC_P4_FULL")
    command.extend(
        (
            "--Mdir",
            str(mdir),
            "-o",
            executable.name,
            *source_arguments(include_tb=True),
        )
    )
    compiled = run(
        command,
        stage="FUNCTIONAL_COMPILE",
        configuration=configuration.short,
        timeout=COMPILE_TIMEOUT,
    )
    require_clean_command_output(
        compiled,
        command,
        stage="FUNCTIONAL_COMPILE",
        configuration=configuration.short,
        dut_or_tb="DUT_OR_TB",
    )

    sim_command = [str(executable)]
    simulated = run(
        sim_command,
        stage="FUNCTIONAL_SIMULATION",
        configuration=configuration.short,
        timeout=SIM_TIMEOUT,
    )
    require_clean_command_output(
        simulated,
        sim_command,
        stage="FUNCTIONAL_SIMULATION",
        configuration=configuration.short,
        dut_or_tb="DUT_OR_TB",
    )
    observed_markers = marker_lines(simulated.stdout)
    expected_markers = MARKERS if configuration.full else (SMOKE_MARKER,)
    if observed_markers != expected_markers:
        raise Failure(
            "FUNCTIONAL_MARKERS",
            "ORDERED_MARKER_MISMATCH",
            command=shlex.join(sim_command),
            exit_code="0",
            configuration=configuration.short,
            expected=" | ".join(expected_markers),
            observed=" | ".join(observed_markers),
            cause="P4_BEHAVIOR_OR_MARKER_DEFECT",
            dut_or_tb="DUT_OR_TB",
        )
    print(simulated.stdout, end="" if simulated.stdout.endswith("\n") else "\n")
    print(f"MC_NOC_P4_FUNCTIONAL_CONFIGURATION_{configuration.short}=PASS")


def large_structural_lint(verilator: Path, build_root: Path) -> None:
    mdir = build_root / ("LINT_" + LARGE_CONFIGURATION.short)
    command = [
        str(verilator),
        "--lint-only",
        "--unroll-count",
        "1024",
        "-Wall",
        "-Werror-PINMISSING",
        "-Werror-WIDTHEXPAND",
        "-Werror-WIDTHTRUNC",
        "--top-module",
        DUT_TOP,
        *parameter_arguments(LARGE_CONFIGURATION),
        "--Mdir",
        str(mdir),
        *source_arguments(include_tb=False),
    ]
    completed = run(
        command,
        stage="LARGE_STRUCTURAL_LINT",
        configuration=LARGE_CONFIGURATION.short,
        timeout=LARGE_LINT_TIMEOUT,
    )
    require_clean_command_output(
        completed,
        command,
        stage="LARGE_STRUCTURAL_LINT",
        configuration=LARGE_CONFIGURATION.short,
        dut_or_tb="DUT",
    )


def width(value: int) -> int:
    return max(1, (value - 1).bit_length())


def structural_metrics(
    cluster_count: int,
    cus_per_cluster: int,
    mshr_count: int,
    slice_count: int,
    *,
    line_words: int = 8,
    set_count: int = 256,
    miss_count: int = 16,
) -> dict[str, int]:
    if line_words < 1 or line_words & (line_words - 1):
        raise ValueError("line_words must be a positive power of two")
    if set_count < 1 or set_count & (set_count - 1):
        raise ValueError("set_count must be a positive power of two")
    a_width = 32 - int(math.log2(line_words))
    cid_width = width(cluster_count)
    cuid_width = width(cus_per_cluster)
    local_width = width(mshr_count)
    cluster_local_width = cuid_width + local_width
    network_width = cid_width + cluster_local_width
    slice_width = width(slice_count)
    outstanding = cus_per_cluster * mshr_count
    owner_width = width(outstanding)
    tag_width = a_width - int(math.log2(set_count))

    p0_bits = cluster_count * (
        3
        + network_width
        + cluster_local_width
        + 2 * a_width
        + 32 * line_words
    )
    p1_bits = slice_count * (
        cid_width + 1 + network_width + a_width
    )
    p2_bits = (
        cluster_count
        * outstanding
        * (4 + network_width + a_width + slice_width + 32 * line_words)
        + cluster_count * (1 + 2 * owner_width)
    )
    p3_bits = slice_count * (1 + network_width + a_width)
    routing_bits = p0_bits + p1_bits + p2_bits + p3_bits
    l2_bits = slice_count * (
        set_count * (1 + tag_width + 32 * line_words)
        + miss_count * (2 + network_width + a_width)
        + (1 + network_width + a_width + 32 * line_words)
    )
    return {
        "total_cus": cluster_count * cus_per_cluster,
        "outstanding_per_cluster": outstanding,
        "owner_slots": cluster_count * outstanding,
        "p1_candidate_sites": cluster_count * slice_count,
        "p2_ingress_sites": cluster_count * outstanding,
        "p2_issue_sites": slice_count * outstanding,
        "p2_same_cycle_sites": slice_count * slice_count,
        "l2_request_lookup_sites": slice_count * miss_count,
        "l2_response_lookup_sites": slice_count * miss_count,
        "routing_bits": routing_bits,
        "l2_bits": l2_bits,
        "combined_bits": routing_bits + l2_bits,
    }


def require_structural_formula_oracle() -> dict[str, int]:
    expected_routing = {
        (1, 1, 1, 1): 685,
        (2, 2, 2, 2): 3132,
        (3, 3, 3, 4): 9323,
        (4, 2, 2, 4): 6312,
        (4, 4, 4, 4): 20648,
        (64, 4, 4, 64): 339584,
    }
    for key, expected in expected_routing.items():
        observed = structural_metrics(*key)["routing_bits"]
        if observed != expected:
            raise Failure(
                "STRUCTURAL_FORMULA",
                "ROUTING_STATE_ORACLE_MISMATCH",
                configuration="/".join(str(value) for value in key),
                expected=str(expected),
                observed=str(observed),
                cause="P4_FORMULA_OR_DOCUMENT_DEFECT",
                dut_or_tb="NEITHER",
            )
    large = structural_metrics(64, 4, 4, 64)
    expected_large = {
        "total_cus": 256,
        "owner_slots": 1024,
        "p1_candidate_sites": 4096,
        "p2_ingress_sites": 1024,
        "p2_issue_sites": 1024,
        "p2_same_cycle_sites": 4096,
        "l2_request_lookup_sites": 1024,
        "l2_response_lookup_sites": 1024,
        "routing_bits": 339584,
        "l2_bits": 4615680,
        "combined_bits": 4955264,
    }
    for name, expected in expected_large.items():
        observed = large[name]
        if observed != expected:
            raise Failure(
                "STRUCTURAL_FORMULA",
                "LARGE_STRUCTURAL_ORACLE_MISMATCH",
                configuration=LARGE_CONFIGURATION.short,
                expected=f"{name}={expected}",
                observed=f"{name}={observed}",
                cause="P4_FORMULA_OR_DOCUMENT_DEFECT",
                dut_or_tb="NEITHER",
            )
    return large


def main() -> int:
    try:
        require_files_and_identity()
        require_static_contract()
        verilator = require_tool()
        large = require_structural_formula_oracle()
        print("MC_NOC_P4_STATIC_CONTRACT=PASS")
        print("MC_NOC_P4_CLOSED_DEPENDENCY_IDENTITY=PASS")
        print("MC_NOC_P4_STRUCTURAL_FORMULAS=PASS")

        with tempfile.TemporaryDirectory(
            prefix="a0_mc_noc_p4_",
            dir="/tmp",
        ) as temporary:
            build_root = Path(temporary)
            for configuration in CONFIGURATIONS:
                compile_and_run(verilator, build_root, configuration)

            print("MC_NOC_P4_VERILATOR_5_050_COMPILE=PASS")
            print(f"MC_NOC_P4_TARGETED_SCENARIO_COUNT={len(MARKERS)}")
            print("MC_NOC_P4_TARGETED_19=PASS")
            print("MC_NOC_P4_FUNCTIONAL_MATRIX_COUNT=5")
            print("MC_NOC_P4_FUNCTIONAL_MATRIX=PASS")

            large_structural_lint(verilator, build_root)
            print(
                "MC_NOC_P4_LARGE_STRUCTURAL_CONFIGURATION="
                "K64_U4_M4_W8_S64_SET256_L2M16"
            )
            print("MC_NOC_P4_LARGE_STRUCTURAL_256_CU=PASS")
            print("MC_NOC_P4_LARGE_STRUCTURAL_LINT=PASS")

        print(f"MC_NOC_P4_ROUTING_STATE_K64_BITS={large['routing_bits']}")
        print(f"MC_NOC_P4_L2_STATE_K64_BITS={large['l2_bits']}")
        print(f"MC_NOC_P4_COMBINED_STATE_K64_BITS={large['combined_bits']}")
        print(f"MC_NOC_P4_P1_CANDIDATE_SITES_K64={large['p1_candidate_sites']}")
        print(f"MC_NOC_P4_P2_SAME_CYCLE_SITES_S64={large['p2_same_cycle_sites']}")
        print(f"MC_NOC_P4_L2_REQUEST_LOOKUP_SITES_S64={large['l2_request_lookup_sites']}")
        print(f"MC_NOC_P4_L2_RESPONSE_LOOKUP_SITES_S64={large['l2_response_lookup_sites']}")
        print("MC_NOC_P4_TIMING=NOT_MEASURED")
        print("MC_NOC_P4_RTL_OPTIMIZATION_REQUIRED=NOT_INFERRED")
        print("MC_NOC_P4_OUTPUT_CONTAINMENT=/tmp")
        print("MC_NOC_P4_CANDIDATE_QUALIFICATION=PASS")
        return 0
    except Failure as failure:
        report_failure(failure)
        return 1
    except Exception as exc:  # fail closed on an unexpected harness defect
        failure = Failure(
            "UNEXPECTED_RUNNER_EXCEPTION",
            type(exc).__name__,
            observed=str(exc),
            cause="P4_RUNNER_DEFECT",
            dut_or_tb="NEITHER",
        )
        report_failure(failure)
        return 1


if __name__ == "__main__":
    raise SystemExit(main())
