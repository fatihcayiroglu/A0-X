#!/usr/bin/env python3

from __future__ import annotations

import sys
sys.dont_write_bytecode = True

from collections import Counter
from dataclasses import dataclass
from pathlib import Path
import os
import re
import shlex
import shutil
import subprocess
import tempfile


ROOT = Path(__file__).resolve().parents[1]
DUT = ROOT / "rtl/memory/a0_cluster_line_noc_endpoint.sv"
TB = ROOT / "tests/rtl/a0_cluster_line_noc_endpoint_tb.sv"
RUNNER = Path(__file__).resolve()

VERILATOR_BIN_ENV = "A0_VERILATOR_BIN"
VALIDATED_VERILATOR_VERSION = "5.050"
TOP_MODULE = "a0_cluster_line_noc_endpoint_tb"
LINE_WORDS = 8
COMPILE_TIMEOUT_SECONDS = 300
SIMULATION_TIMEOUT_SECONDS = 60

SCENARIOS: tuple[tuple[int, str], ...] = (
    (1, "RESET_IDLE"),
    (2, "LOCAL_REQUEST_ACCEPTED"),
    (3, "REQUEST_CLUSTER_ID_ADDED"),
    (4, "REQUEST_CU_LOCAL_TAG_PRESERVED"),
    (5, "REQUEST_LINE_ADDR_PRESERVED"),
    (6, "REQUEST_HOLD_CREATED"),
    (7, "REQUEST_STALL_VALID_HELD"),
    (8, "REQUEST_STALL_PAYLOAD_STABLE"),
    (9, "REQUEST_EXACTLY_ONCE_DRAIN"),
    (10, "REQUEST_BACK_TO_BACK"),
    (11, "REQUEST_SAME_CYCLE_TURNOVER"),
    (12, "REQUEST_CONSERVATION"),
    (13, "ADDRESSED_RESPONSE_ACCEPTED"),
    (14, "RESPONSE_CU_LOCAL_TAG_RESTORED"),
    (15, "RESPONSE_LINE_ADDR_PRESERVED"),
    (16, "RESPONSE_FAULT_PRESERVED"),
    (17, "RESPONSE_LINE_DATA_PRESERVED"),
    (18, "RESPONSE_HOLD_CREATED"),
    (19, "RESPONSE_STALL_VALID_HELD"),
    (20, "RESPONSE_STALL_PAYLOAD_STABLE"),
    (21, "RESPONSE_EXACTLY_ONCE_DRAIN"),
    (22, "RESPONSE_SAME_CYCLE_TURNOVER"),
    (23, "WRONG_LEGAL_CLUSTER_NOT_ACCEPTED"),
    (24, "WRONG_LEGAL_CLUSTER_NO_LOCAL_DELIVERY"),
    (25, "UNUSED_CLUSTER_ENCODING_NOT_ACCEPTED"),
    (26, "UNUSED_CU_ENCODING_NOT_ACCEPTED"),
    (27, "INVALID_IDS_NO_LOCAL_DELIVERY"),
    (28, "INVALID_LOCAL_REQUEST_CU_REJECTED"),
    (29, "REQUEST_RESPONSE_INDEPENDENT_PROGRESS"),
    (30, "SIMULTANEOUS_REQUEST_RESPONSE_HANDSHAKES"),
    (31, "RESET_FLUSHES_HELD_REQUEST"),
    (32, "RESET_FLUSHES_HELD_RESPONSE"),
    (33, "SAME_LOCAL_TAG_DIFFERENT_CU_DISTINCT"),
    (34, "SAME_CU_TAG_DIFFERENT_CLUSTER_DISTINCT"),
    (35, "CODEC_ALL_LEGAL_AND_MAX_ROUND_TRIP"),
    (36, "FINAL_CONSERVATION_AND_DRAIN"),
)

MARKERS: tuple[str, ...] = tuple(
    f"MC_NOC_P0_{index:02d}_{name}=PASS" for index, name in SCENARIOS
)
PARAMETER_SMOKE_MARKER = "MC_NOC_P0_PARAMETER_SMOKE=PASS"
INVALID_CLUSTER_DIAGNOSTIC = "MC_NOC_P0 CLUSTER_ID out of range"

LITERAL_DISPLAY_RE = re.compile(
    r'(?m)^[ \t]*\$display[ \t]*\([ \t]*"'
    r"(MC_NOC_P0_([0-9]{2})_([A-Z0-9_]+)=PASS)"
    r'"[ \t]*\)[ \t]*;[ \t]*$'
)
LITERAL_SMOKE_DISPLAY_RE = re.compile(
    r'(?m)^[ \t]*\$display[ \t]*\([ \t]*"'
    + re.escape(PARAMETER_SMOKE_MARKER)
    + r'"[ \t]*\)[ \t]*;[ \t]*$'
)
COMPLETE_PASS_LINE_RE = re.compile(r"^MC_NOC_P0_[A-Z0-9_]+=PASS$")

VERILATOR_FLAGS: tuple[str, ...] = (
    "--binary",
    "--timing",
    "--unroll-count",
    "128",
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
    cluster_id: int
    full_scenarios: bool

    @staticmethod
    def width(count: int) -> int:
        return max(1, (count - 1).bit_length())

    @property
    def network_tag_width(self) -> int:
        return (
            self.width(self.cluster_count)
            + self.width(self.cus_per_cluster)
            + self.width(self.mshr_count)
        )

    @property
    def short_name(self) -> str:
        return (
            f"K{self.cluster_count}_U{self.cus_per_cluster}_"
            f"M{self.mshr_count}"
        )

    @property
    def description(self) -> str:
        mode = "FULL_36" if self.full_scenarios else "SMOKE"
        return (
            f"CLUSTER_COUNT={self.cluster_count} "
            f"CUS_PER_CLUSTER={self.cus_per_cluster} "
            f"MSHR_COUNT={self.mshr_count} "
            f"CLUSTER_ID={self.cluster_id} "
            f"LINE_WORDS={LINE_WORDS} "
            f"NETWORK_TAG_W={self.network_tag_width} "
            f"MODE={mode}"
        )


FULL_CONFIGURATION = Configuration(3, 3, 2, 1, True)
SMOKE_CONFIGURATIONS: tuple[Configuration, ...] = (
    Configuration(1, 1, 1, 0, False),
    Configuration(2, 2, 2, 1, False),
    Configuration(4, 4, 4, 3, False),
)
INVALID_CONFIGURATION = Configuration(3, 3, 2, 3, False)


class RunnerFailure(RuntimeError):
    def __init__(
        self,
        *,
        stage: str,
        first_error: str,
        command: str = "NOT_APPLICABLE",
        exit_code: str = "NOT_APPLICABLE",
        failing_file: str = "NONE",
        scenario: str = "NONE",
        configuration: str = "NONE",
        expected: str = "",
        observed: str = "",
        root_cause_class: str = "MC_NOC_P0_RUNNER_VALIDATION_FAILURE",
        dut_or_tb: str = "NEITHER",
    ) -> None:
        super().__init__(first_error)
        self.stage = stage
        self.first_error = first_error
        self.command = command
        self.exit_code = exit_code
        self.failing_file = failing_file
        self.scenario = scenario
        self.configuration = configuration
        self.expected = expected
        self.observed = observed
        self.root_cause_class = root_cause_class
        self.dut_or_tb = dut_or_tb


def compact(value: object) -> str:
    return " | ".join(str(value).splitlines()) or "NONE"


def report_first_failure(failure: RunnerFailure) -> None:
    print("MC_NOC_P0_FIRST_FAILURE")
    print(f"STAGE={compact(failure.stage)}")
    print(f"COMMAND={compact(failure.command)}")
    print(f"EXIT_CODE={compact(failure.exit_code)}")
    print(f"FIRST_ERROR={compact(failure.first_error)}")
    print(f"FAILING_FILE={compact(failure.failing_file)}")
    print("FAILING_LINE=UNKNOWN")
    print(f"SCENARIO={compact(failure.scenario)}")
    print(f"CONFIGURATION={compact(failure.configuration)}")
    print(f"EXPECTED={compact(failure.expected)}")
    print(f"OBSERVED={compact(failure.observed)}")
    print(f"ROOT_CAUSE_CLASS={compact(failure.root_cause_class)}")
    print(f"DUT_OR_TB={compact(failure.dut_or_tb)}")


def subprocess_environment() -> dict[str, str]:
    environment = os.environ.copy()
    environment["PYTHONDONTWRITEBYTECODE"] = "1"
    environment["TMPDIR"] = "/tmp"
    environment.pop("TEMP", None)
    environment.pop("TMP", None)
    return environment


def run_process(
    command: list[str],
    *,
    stage: str,
    configuration: str = "NONE",
    timeout: int,
    cwd: Path = ROOT,
) -> subprocess.CompletedProcess[str]:
    rendered = shlex.join(command)
    try:
        result = subprocess.run(
            command,
            cwd=cwd,
            env=subprocess_environment(),
            text=True,
            encoding="utf-8",
            errors="replace",
            stdout=subprocess.PIPE,
            stderr=subprocess.STDOUT,
            timeout=timeout,
            check=False,
        )
    except subprocess.TimeoutExpired as error:
        partial = error.stdout or ""
        if isinstance(partial, bytes):
            partial = partial.decode("utf-8", errors="replace")
        print(partial, end="")
        raise RunnerFailure(
            stage=stage,
            first_error="COMMAND_TIMEOUT",
            command=rendered,
            exit_code="TIMEOUT",
            configuration=configuration,
            expected=f"completion within {timeout} seconds",
            observed="timeout",
            root_cause_class="TOOL_OR_SIMULATION_TIMEOUT",
            dut_or_tb="UNRESOLVED",
        ) from error
    except OSError as error:
        raise RunnerFailure(
            stage=stage,
            first_error="COMMAND_LAUNCH_FAILED",
            command=rendered,
            exit_code="NOT_STARTED",
            configuration=configuration,
            expected="command starts",
            observed=str(error),
            root_cause_class="TOOL_INVOCATION_FAILURE",
            dut_or_tb="NEITHER",
        ) from error

    print(result.stdout, end="")
    return result


def require_success(
    result: subprocess.CompletedProcess[str],
    command: list[str],
    *,
    stage: str,
    configuration: Configuration,
    failing_file: Path,
) -> None:
    if result.returncode != 0:
        raise RunnerFailure(
            stage=stage,
            first_error="COMMAND_FAILED",
            command=shlex.join(command),
            exit_code=str(result.returncode),
            failing_file=str(failing_file),
            configuration=configuration.description,
            expected="exit code 0",
            observed=f"exit code {result.returncode}",
            root_cause_class="DUT_TB_OR_TOOLCHAIN_FAILURE",
            dut_or_tb="UNRESOLVED",
        )


def require_no_verilator_warning(
    output: str,
    command: list[str],
    *,
    stage: str,
    configuration: Configuration,
    exit_code: int,
) -> None:
    warning_lines = [line for line in output.splitlines() if "%Warning-" in line]
    if warning_lines:
        raise RunnerFailure(
            stage=stage,
            first_error="VERILATOR_WARNING_PRESENT",
            command=shlex.join(command),
            exit_code=str(exit_code),
            failing_file=str(DUT),
            configuration=configuration.description,
            expected="zero %Warning- lines",
            observed=" || ".join(warning_lines),
            root_cause_class="VERILATOR_WARNING_POLICY_FAILURE",
            dut_or_tb="UNRESOLVED",
        )


def strip_systemverilog_comments(source: str) -> str:
    output: list[str] = []
    index = 0
    state = "code"
    while index < len(source):
        char = source[index]
        next_char = source[index + 1] if index + 1 < len(source) else ""

        if state == "code":
            if char == "/" and next_char == "/":
                output.extend((" ", " "))
                index += 2
                state = "line_comment"
                continue
            if char == "/" and next_char == "*":
                output.extend((" ", " "))
                index += 2
                state = "block_comment"
                continue
            output.append(char)
            if char == '"':
                state = "string"
            index += 1
            continue

        if state == "string":
            output.append(char)
            if char == "\\" and next_char:
                output.append(next_char)
                index += 2
                continue
            if char == '"':
                state = "code"
            index += 1
            continue

        if state == "line_comment":
            if char == "\n":
                output.append(char)
                state = "code"
            else:
                output.append(" ")
            index += 1
            continue

        if char == "*" and next_char == "/":
            output.extend((" ", " "))
            index += 2
            state = "code"
        else:
            output.append("\n" if char == "\n" else " ")
            index += 1

    return "".join(output)


def compile_python_source() -> None:
    try:
        source = RUNNER.read_text(encoding="utf-8")
        compile(source, str(RUNNER), "exec")
    except (OSError, SyntaxError, UnicodeError) as error:
        raise RunnerFailure(
            stage="PYTHON_COMPILE",
            first_error="PYTHON_SOURCE_COMPILE_FAILED",
            failing_file=str(RUNNER),
            expected="runner parses as UTF-8 Python",
            observed=str(error),
            root_cause_class="RUNNER_SOURCE_FAILURE",
        ) from error
    print("PYTHON_COMPILE=PASS")


def static_manifest_crosscheck() -> None:
    for required in (DUT, TB):
        if not required.is_file():
            raise RunnerFailure(
                stage="RUNNER_TB_MANIFEST_CROSSCHECK",
                first_error="REQUIRED_SOURCE_MISSING",
                failing_file=str(required),
                expected="regular file present",
                observed="missing",
                root_cause_class="P0_FILE_SCOPE_FAILURE",
            )

    expected_ids = [index for index, _ in SCENARIOS]
    expected_names = [name for _, name in SCENARIOS]
    if expected_ids != list(range(1, 37)) or len(set(expected_names)) != 36:
        raise RunnerFailure(
            stage="RUNNER_TB_MANIFEST_CROSSCHECK",
            first_error="RUNNER_MANIFEST_INVALID",
            failing_file=str(RUNNER),
            expected="36 unique ordered tuples with IDs 1..36",
            observed=repr(SCENARIOS),
            root_cause_class="RUNNER_MANIFEST_FAILURE",
        )

    try:
        tb_source = TB.read_text(encoding="utf-8")
    except (OSError, UnicodeError) as error:
        raise RunnerFailure(
            stage="RUNNER_TB_MANIFEST_CROSSCHECK",
            first_error="TB_READ_FAILED",
            failing_file=str(TB),
            expected="UTF-8 TB source",
            observed=str(error),
            root_cause_class="TB_SOURCE_FAILURE",
            dut_or_tb="TB",
        ) from error

    tb_code = strip_systemverilog_comments(tb_source)
    matches = list(LITERAL_DISPLAY_RE.finditer(tb_code))
    actual_markers = [match.group(1) for match in matches]
    actual_ids = [int(match.group(2)) for match in matches]
    actual_names = [match.group(3) for match in matches]

    print(f"RUNNER_MANIFEST_COUNT={len(SCENARIOS)}")
    print(f"TB_LITERAL_MARKER_COUNT={len(actual_markers)}")

    if actual_ids != expected_ids:
        raise RunnerFailure(
            stage="RUNNER_TB_MANIFEST_CROSSCHECK",
            first_error="TB_MARKER_ID_MISMATCH",
            failing_file=str(TB),
            expected=repr(expected_ids),
            observed=repr(actual_ids),
            root_cause_class="TB_MANIFEST_FAILURE",
            dut_or_tb="TB",
        )
    print("RUNNER_TB_MARKER_ID_MATCH=PASS")

    if actual_names != expected_names:
        raise RunnerFailure(
            stage="RUNNER_TB_MANIFEST_CROSSCHECK",
            first_error="TB_MARKER_NAME_MISMATCH",
            failing_file=str(TB),
            expected=repr(expected_names),
            observed=repr(actual_names),
            root_cause_class="TB_MANIFEST_FAILURE",
            dut_or_tb="TB",
        )
    print("RUNNER_TB_MARKER_NAME_MATCH=PASS")

    if actual_markers != list(MARKERS):
        raise RunnerFailure(
            stage="RUNNER_TB_MANIFEST_CROSSCHECK",
            first_error="TB_MARKER_ORDER_MISMATCH",
            failing_file=str(TB),
            expected=repr(MARKERS),
            observed=repr(actual_markers),
            root_cause_class="TB_MANIFEST_FAILURE",
            dut_or_tb="TB",
        )
    print("RUNNER_TB_MARKER_ORDER_MATCH=PASS")

    smoke_count = len(LITERAL_SMOKE_DISPLAY_RE.findall(tb_code))
    if smoke_count != 1:
        raise RunnerFailure(
            stage="RUNNER_TB_MANIFEST_CROSSCHECK",
            first_error="TB_PARAMETER_SMOKE_MARKER_NOT_SINGLETON",
            failing_file=str(TB),
            expected="one literal parameter-smoke $display",
            observed=f"count={smoke_count}",
            root_cause_class="TB_MANIFEST_FAILURE",
            dut_or_tb="TB",
        )

    print("RUNNER_TB_MANIFEST_MATCH=PASS")


def resolve_verilator() -> str:
    configured = os.environ.get(VERILATOR_BIN_ENV)
    if configured is None or not configured.strip():
        raise RunnerFailure(
            stage="EXACT_VERILATOR_VERSION_GUARD",
            first_error=f"{VERILATOR_BIN_ENV}_NOT_SET",
            expected=(
                f"{VERILATOR_BIN_ENV} names the exact Verilator "
                f"{VALIDATED_VERILATOR_VERSION} executable"
            ),
            observed=repr(configured),
            root_cause_class="TOOLCHAIN_IDENTITY_FAILURE",
        )

    found = shutil.which(configured)
    if found is None:
        raise RunnerFailure(
            stage="EXACT_VERILATOR_VERSION_GUARD",
            first_error="VERILATOR_NOT_FOUND",
            command=compact(configured),
            expected="executable resolvable by path or PATH",
            observed="not found",
            root_cause_class="TOOLCHAIN_IDENTITY_FAILURE",
        )

    try:
        resolved = str(Path(found).resolve(strict=True))
    except OSError as error:
        raise RunnerFailure(
            stage="EXACT_VERILATOR_VERSION_GUARD",
            first_error="VERILATOR_RESOLVE_FAILED",
            command=compact(configured),
            expected="existing executable",
            observed=str(error),
            root_cause_class="TOOLCHAIN_IDENTITY_FAILURE",
        ) from error

    if not os.access(resolved, os.X_OK):
        raise RunnerFailure(
            stage="EXACT_VERILATOR_VERSION_GUARD",
            first_error="VERILATOR_NOT_EXECUTABLE",
            command=resolved,
            expected="executable file",
            observed="not executable",
            root_cause_class="TOOLCHAIN_IDENTITY_FAILURE",
        )

    command = [resolved, "--version"]
    result = run_process(
        command,
        stage="EXACT_VERILATOR_VERSION_GUARD",
        timeout=30,
        cwd=Path("/tmp"),
    )
    if result.returncode != 0:
        raise RunnerFailure(
            stage="EXACT_VERILATOR_VERSION_GUARD",
            first_error="VERILATOR_VERSION_COMMAND_FAILED",
            command=shlex.join(command),
            exit_code=str(result.returncode),
            expected="exit code 0 and exact version token 5.050",
            observed=compact(result.stdout),
            root_cause_class="TOOLCHAIN_IDENTITY_FAILURE",
        )

    fields = result.stdout.strip().split()
    actual_version = (
        fields[1]
        if len(fields) >= 2 and fields[0] == "Verilator"
        else "UNPARSEABLE"
    )
    if actual_version != VALIDATED_VERILATOR_VERSION:
        raise RunnerFailure(
            stage="EXACT_VERILATOR_VERSION_GUARD",
            first_error="VERILATOR_TOOLCHAIN_VERSION_MISMATCH",
            command=shlex.join(command),
            exit_code=str(result.returncode),
            expected=f"exact version token {VALIDATED_VERILATOR_VERSION}",
            observed=f"token={actual_version} output={compact(result.stdout)}",
            root_cause_class="TOOLCHAIN_IDENTITY_FAILURE",
        )

    print(f"MC_NOC_P0_VERILATOR_BIN={resolved}")
    print(f"VERILATOR_VERSION={actual_version}")
    return resolved


def verilator_command(
    verilator: str,
    configuration: Configuration,
    object_directory: Path,
) -> list[str]:
    return [
        verilator,
        *VERILATOR_FLAGS,
        "--top-module",
        TOP_MODULE,
        "--Mdir",
        str(object_directory),
        f"-GCLUSTER_COUNT={configuration.cluster_count}",
        f"-GCLUSTER_ID={configuration.cluster_id}",
        f"-GCUS_PER_CLUSTER={configuration.cus_per_cluster}",
        f"-GMSHR_COUNT={configuration.mshr_count}",
        f"-GLINE_WORDS={LINE_WORDS}",
        f"-GFULL_SCENARIOS={1 if configuration.full_scenarios else 0}",
        str(DUT),
        str(TB),
    ]


def compile_and_run_legal(
    verilator: str,
    configuration: Configuration,
) -> str:
    prefix = f"a0_mc_noc_p0_{configuration.short_name.lower()}_"
    with tempfile.TemporaryDirectory(prefix=prefix, dir="/tmp") as temporary:
        object_directory = Path(temporary) / "obj_dir"
        command = verilator_command(verilator, configuration, object_directory)
        compile_result = run_process(
            command,
            stage="MAIN_TB_COMPILE",
            configuration=configuration.description,
            timeout=COMPILE_TIMEOUT_SECONDS,
            cwd=Path(temporary),
        )
        require_no_verilator_warning(
            compile_result.stdout,
            command,
            stage="MAIN_TB_COMPILE",
            configuration=configuration,
            exit_code=compile_result.returncode,
        )
        require_success(
            compile_result,
            command,
            stage="MAIN_TB_COMPILE",
            configuration=configuration,
            failing_file=DUT,
        )

        executable = object_directory / f"V{TOP_MODULE}"
        if not executable.is_file():
            raise RunnerFailure(
                stage="MAIN_TB_COMPILE",
                first_error="BEHAVIORAL_EXECUTABLE_MISSING",
                command=shlex.join(command),
                exit_code=str(compile_result.returncode),
                failing_file=str(executable),
                configuration=configuration.description,
                expected="compiled simulation executable",
                observed="missing",
                root_cause_class="TOOLCHAIN_OUTPUT_FAILURE",
            )

        simulation_command = [str(executable)]
        simulation_result = run_process(
            simulation_command,
            stage=(
                "FULL_36_BEHAVIORAL"
                if configuration.full_scenarios
                else "LEGAL_PARAMETER_MATRIX"
            ),
            configuration=configuration.description,
            timeout=SIMULATION_TIMEOUT_SECONDS,
            cwd=Path(temporary),
        )
        require_success(
            simulation_result,
            simulation_command,
            stage=(
                "FULL_36_BEHAVIORAL"
                if configuration.full_scenarios
                else "LEGAL_PARAMETER_MATRIX"
            ),
            configuration=configuration,
            failing_file=TB,
        )
        return simulation_result.stdout


def marker_mentions(output: str) -> list[str]:
    return [
        line
        for line in output.splitlines()
        if "MC_NOC_P0_" in line and "=PASS" in line
    ]


def validate_full_runtime(output: str) -> None:
    mentions = marker_mentions(output)
    malformed = [line for line in mentions if not COMPLETE_PASS_LINE_RE.fullmatch(line)]
    if malformed:
        raise RunnerFailure(
            stage="FULL_36_BEHAVIORAL",
            first_error="NON_CANONICAL_RUNTIME_MARKER_LINE",
            failing_file=str(TB),
            scenario="MARKER_PARSER",
            configuration=FULL_CONFIGURATION.description,
            expected="complete exact MC_NOC_P0_* PASS lines",
            observed=repr(malformed),
            root_cause_class="TB_RUNTIME_MARKER_FAILURE",
            dut_or_tb="TB",
        )

    counts = Counter(mentions)
    missing = [marker for marker in MARKERS if counts[marker] == 0]
    duplicates = [marker for marker in MARKERS if counts[marker] > 1]
    extras = [marker for marker in mentions if marker not in MARKERS]
    if missing or duplicates or extras or mentions != list(MARKERS):
        raise RunnerFailure(
            stage="FULL_36_BEHAVIORAL",
            first_error="RUNTIME_MARKER_SEQUENCE_FAILURE",
            failing_file=str(TB),
            scenario="MARKER_PARSER",
            configuration=FULL_CONFIGURATION.description,
            expected=repr(MARKERS),
            observed=(
                f"actual={mentions!r} missing={missing!r} "
                f"duplicates={duplicates!r} extras={extras!r}"
            ),
            root_cause_class="TB_RUNTIME_MARKER_FAILURE",
            dut_or_tb="TB",
        )

    print(f"TB_SCENARIO_COUNT={len(mentions)}")
    print("TARGETED_36=PASS")
    print("REQUEST_CONSERVATION=PASS")
    print("RESPONSE_CONSERVATION=PASS")
    print("SAME_CYCLE_REQUEST_TURNOVER=PASS")
    print("SAME_CYCLE_RESPONSE_TURNOVER=PASS")
    print("SIMULTANEOUS_REQUEST_RESPONSE_HANDSHAKES=PASS")


def validate_smoke_runtime(
    output: str,
    configuration: Configuration,
) -> None:
    mentions = marker_mentions(output)
    malformed = [line for line in mentions if not COMPLETE_PASS_LINE_RE.fullmatch(line)]
    if malformed or mentions != [PARAMETER_SMOKE_MARKER]:
        raise RunnerFailure(
            stage="LEGAL_PARAMETER_MATRIX",
            first_error="PARAMETER_SMOKE_MARKER_FAILURE",
            failing_file=str(TB),
            scenario="PARAMETER_SMOKE",
            configuration=configuration.description,
            expected=repr([PARAMETER_SMOKE_MARKER]),
            observed=f"markers={mentions!r} malformed={malformed!r}",
            root_cause_class="TB_PARAMETERIZATION_FAILURE",
            dut_or_tb="TB",
        )


def print_parameter_pass(configuration: Configuration) -> None:
    print(f"PARAMETER_{configuration.short_name}=PASS")
    print(f"MC_NOC_P0_PARAMETER_CONFIG=PASS {configuration.description}")


def assert_no_pass_marker(output: str, *, stage: str) -> None:
    emitted = [
        line
        for line in output.splitlines()
        if COMPLETE_PASS_LINE_RE.fullmatch(line)
    ]
    if emitted:
        raise RunnerFailure(
            stage="INVALID_CLUSTER_PARAMETER_FAIL_CLOSED",
            first_error="INVALID_CONFIGURATION_EMITTED_PASS_MARKER",
            failing_file=str(TB),
            scenario="INVALID_CLUSTER_PARAMETER",
            configuration=INVALID_CONFIGURATION.description,
            expected="no canonical or smoke PASS marker",
            observed=f"failure_stage={stage} emitted={emitted!r}",
            root_cause_class="FAIL_CLOSED_QUALIFICATION_FAILURE",
            dut_or_tb="DUT_OR_TB",
        )


def validate_invalid_cluster_parameter(verilator: str) -> None:
    configuration = INVALID_CONFIGURATION
    with tempfile.TemporaryDirectory(
        prefix="a0_mc_noc_p0_invalid_cluster_",
        dir="/tmp",
    ) as temporary:
        object_directory = Path(temporary) / "obj_dir"
        command = verilator_command(verilator, configuration, object_directory)
        compile_result = run_process(
            command,
            stage="INVALID_CLUSTER_PARAMETER_FAIL_CLOSED",
            configuration=configuration.description,
            timeout=COMPILE_TIMEOUT_SECONDS,
            cwd=Path(temporary),
        )
        require_no_verilator_warning(
            compile_result.stdout,
            command,
            stage="INVALID_CLUSTER_PARAMETER_FAIL_CLOSED",
            configuration=configuration,
            exit_code=compile_result.returncode,
        )

        combined_output = compile_result.stdout
        if compile_result.returncode != 0:
            failure_stage = "COMPILE"
        else:
            executable = object_directory / f"V{TOP_MODULE}"
            if not executable.is_file():
                raise RunnerFailure(
                    stage="INVALID_CLUSTER_PARAMETER_FAIL_CLOSED",
                    first_error="INVALID_CONFIGURATION_EXECUTABLE_MISSING",
                    command=shlex.join(command),
                    exit_code=str(compile_result.returncode),
                    failing_file=str(executable),
                    scenario="INVALID_CLUSTER_PARAMETER",
                    configuration=configuration.description,
                    expected="compile failure or runnable executable",
                    observed="compile succeeded but executable is missing",
                    root_cause_class="TOOLCHAIN_OUTPUT_FAILURE",
                )

            simulation_command = [str(executable)]
            simulation_result = run_process(
                simulation_command,
                stage="INVALID_CLUSTER_PARAMETER_FAIL_CLOSED",
                configuration=configuration.description,
                timeout=SIMULATION_TIMEOUT_SECONDS,
                cwd=Path(temporary),
            )
            combined_output += simulation_result.stdout
            if simulation_result.returncode == 0:
                raise RunnerFailure(
                    stage="INVALID_CLUSTER_PARAMETER_FAIL_CLOSED",
                    first_error="INVALID_CLUSTER_PARAMETER_USABLE",
                    command=shlex.join(simulation_command),
                    exit_code="0",
                    failing_file=str(DUT),
                    scenario="INVALID_CLUSTER_PARAMETER",
                    configuration=configuration.description,
                    expected="nonzero startup failure",
                    observed="simulation exited successfully",
                    root_cause_class="DUT_PARAMETER_GUARD_FAILURE",
                    dut_or_tb="DUT",
                )
            failure_stage = "STARTUP"

        assert_no_pass_marker(combined_output, stage=failure_stage)
        if INVALID_CLUSTER_DIAGNOSTIC not in combined_output:
            raise RunnerFailure(
                stage="INVALID_CLUSTER_PARAMETER_FAIL_CLOSED",
                first_error="EXPECTED_CLUSTER_ID_DIAGNOSTIC_MISSING",
                command=shlex.join(command),
                exit_code=str(compile_result.returncode),
                failing_file=str(DUT),
                scenario="INVALID_CLUSTER_PARAMETER",
                configuration=configuration.description,
                expected=INVALID_CLUSTER_DIAGNOSTIC,
                observed=compact(combined_output),
                root_cause_class="DUT_PARAMETER_GUARD_FAILURE",
                dut_or_tb="DUT",
            )

    print(f"INVALID_CLUSTER_PARAMETER_FAILURE_STAGE={failure_stage}")
    print("INVALID_CLUSTER_PARAMETER_FAIL_CLOSED=PASS")


def main() -> None:
    if Path("/tmp").resolve() != Path("/tmp") or not Path("/tmp").is_dir():
        raise RunnerFailure(
            stage="TEMPORARY_OUTPUT_CONTAINMENT",
            first_error="TMP_ROOT_UNAVAILABLE",
            expected="/tmp is an existing directory",
            observed=str(Path("/tmp")),
            root_cause_class="TEMPORARY_OUTPUT_CONTAINMENT_FAILURE",
        )

    compile_python_source()
    static_manifest_crosscheck()
    verilator = resolve_verilator()

    full_output = compile_and_run_legal(verilator, FULL_CONFIGURATION)
    validate_full_runtime(full_output)
    print_parameter_pass(FULL_CONFIGURATION)

    for configuration in SMOKE_CONFIGURATIONS:
        smoke_output = compile_and_run_legal(verilator, configuration)
        validate_smoke_runtime(smoke_output, configuration)
        print_parameter_pass(configuration)

    print("PARAMETERIZATION=PASS")
    validate_invalid_cluster_parameter(verilator)

    print("COMPILE=PASS")
    print("WARNING_LINES=0")
    print("MC_NOC_P0_RUNNER=PASS")


if __name__ == "__main__":
    try:
        main()
    except RunnerFailure as failure:
        report_first_failure(failure)
        raise SystemExit(1) from None
    except Exception as error:
        report_first_failure(
            RunnerFailure(
                stage="RUNNER_INTERNAL",
                first_error=type(error).__name__,
                failing_file=str(RUNNER),
                expected="runner completes without unclassified exception",
                observed=str(error),
                root_cause_class="RUNNER_INTERNAL_FAILURE",
            )
        )
        raise SystemExit(1) from None
