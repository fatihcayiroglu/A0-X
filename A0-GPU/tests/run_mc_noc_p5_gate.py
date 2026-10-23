#!/usr/bin/env python3

from __future__ import annotations

from dataclasses import dataclass
import hashlib
import os
from pathlib import Path
import re
import shlex
import stat
import subprocess
import sys
import tempfile


sys.dont_write_bytecode = True

RUNNER = Path(__file__).resolve()
CANDIDATE_ROOT = RUNNER.parents[1]
ROOT = Path(os.environ.get("A0_REPO_ROOT", CANDIDATE_ROOT)).resolve()
DOC = CANDIDATE_ROOT / "docs/architecture/A0_MC_NOC_P5_LOGICAL_NOC_FREEZE.md"

EXPECTED_HEAD = "996d8c188e5d4f94b4bad5289392844d55d092f6"
EXPECTED_SUBJECT = "memory: integrate production multi-cu shared l2 cluster"
EXPECTED_BRANCH = "main"
EXPECTED_VERILATOR = Path(
    "/tmp/a0-verilator-ab-8KXw1HJJ/verilator-v5.050/bin/verilator"
)
EXPECTED_VERILATOR_SHA256 = (
    "ea03a1bd85f60779e79d6d9ae14b899abf4bc55f7d47b908a217ba67b23f25fa"
)
EXPECTED_SYSTEM_VERILATOR = Path("/usr/bin/verilator")
EXPECTED_SYSTEM_VERILATOR_SHA256 = (
    "672a1ccf3468902f66387049f001b04f254bbcece7d5e816e3861715889bf252"
)


@dataclass(frozen=True)
class SourceIdentity:
    path: str
    sha256: str
    mode: int


CLOSED_SOURCES: tuple[SourceIdentity, ...] = (
    SourceIdentity("docs/architecture/A0_SLICED_L2_ROUTING_FOUNDATION.md", "6a4b0443bfec3f3ee226e1256fa5da6d37b6e30ff10f3ee3055d157857386073", 0o644),
    SourceIdentity("rtl/memory/a0_line_slice_fabric.sv", "b4b12cbe2b5c6c99806f6b0e3f5e7402c1e1782c4a9b1de8153a64a84be47f39", 0o644),
    SourceIdentity("rtl/memory/a0_multi_slice_l2_subsystem.sv", "c6210d4e860acfbe73181854fe6c3a36dc01041cc88733239d6f1c54e6ddda3c", 0o644),
    SourceIdentity("tests/rtl/a0_line_slice_fabric_tb.sv", "c4a82ee20f7e7c10f6a66fda34f5b636a66c58b035c41c52ac1746a3b04cffa4", 0o644),
    SourceIdentity("tests/rtl/a0_multi_slice_l2_subsystem_tb.sv", "68fb842c9471b10693902430b761b6ba8b1ff4403c6e2ab1ba409b6dac664755", 0o644),
    SourceIdentity("tests/run_sliced_l2_foundation.py", "e0a2e2d17ff111b80eb6b51410fc6fbe4d6347f5c7a9e6546312b6a218c3e9e2", 0o755),
    SourceIdentity("tests/run_sliced_l2_foundation_gate.py", "b5ab066cf10c02d6e6a020eb668e3410260dd4bbcb5bdb50bca08be1802f8a02", 0o755),
    SourceIdentity("docs/architecture/A0_MC_NOC_P0_ENDPOINT.md", "c37dabbefa06ada7e4ebeb5cfa99fba0669176215f3485044a145d9b69ad1e84", 0o644),
    SourceIdentity("rtl/memory/a0_cluster_line_noc_endpoint.sv", "384ee90577e438b03613e78d24dd48f3919085f3e6edb1ec45e8fe6008b193c9", 0o644),
    SourceIdentity("tests/rtl/a0_cluster_line_noc_endpoint_tb.sv", "9678fae2d1a5dc24837084b78f91366c97c2dd6e6724e4152e3b6963d5d3135c", 0o644),
    SourceIdentity("tests/run_mc_noc_p0.py", "d2bb482071aaa193763ad79f25b180dd1dc0b5a8151d950a328c3a2995711c46", 0o755),
    SourceIdentity("docs/architecture/A0_MC_NOC_P1_LOGICAL_REQUEST_ROUTING.md", "6aefe3fd61b3994b41b1239e539691677513aa1af7f19be5bda296c446c46046", 0o644),
    SourceIdentity("rtl/memory/a0_mc_noc_logical_request_router.sv", "9887b2fb3a7fedd8a52745ac5d8f334a1569f2769e1f0105d7174f8a55e37f3d", 0o644),
    SourceIdentity("tests/rtl/a0_mc_noc_logical_request_router_tb.sv", "87552fba66591ec76498824791547212ca9c6793b5162732445e7056b1954859", 0o644),
    SourceIdentity("tests/run_mc_noc_p1.py", "83b4eb44fb2eea58023a42d2ba7b9de856a4a5920b8ed0cd685cfa873b10fc2f", 0o755),
    SourceIdentity("docs/architecture/A0_MC_NOC_P2_LOGICAL_RESPONSE_ROUTING.md", "d17490fe584ca5eaf912f8a82d953f0502219876319d130ba4497493d2a9caae", 0o644),
    SourceIdentity("rtl/memory/a0_mc_noc_logical_transaction_router.sv", "12247282728dfb614e2d65139c49201b9f0aa71eaff5c79950be0a5a9cd60581", 0o644),
    SourceIdentity("tests/rtl/a0_mc_noc_logical_transaction_router_tb.sv", "aaa695d9c562d2dee8a98a0b51966a37ba67391947027deb14bca9e90d51ed2f", 0o644),
    SourceIdentity("tests/run_mc_noc_p2.py", "3746dce5df1625a29ab7a78cf3207df9ae3850bc093be1fa3979bba41a9e0186", 0o755),
    SourceIdentity("docs/architecture/A0_MC_NOC_P3_SLICED_L2_COMPOSITION.md", "99ce3f40b35eeed6241b31c3cf705428818de760f6be3050a1a912808e1cde6a", 0o644),
    SourceIdentity("rtl/memory/a0_mc_noc_sliced_l2_subsystem.sv", "2ac547b359171a8498255f03963a37c2ef28c6760107b16f7bf0be15d93bfe13", 0o644),
    SourceIdentity("tests/rtl/a0_mc_noc_sliced_l2_subsystem_tb.sv", "d3835dbb8a50eb156e1d823c2f8d5c1f6287d7633ec6fd6ab2b701d51db6fc92", 0o644),
    SourceIdentity("tests/run_mc_noc_p3.py", "5d4d3ab26d6e217df6de8b206e075564b58ff7550f6afcf99f4c7c82f2c6b050", 0o755),
    SourceIdentity("docs/architecture/A0_MC_NOC_P4_PARAMETERIZATION_FAIRNESS_HOL.md", "857b778738de0f1a819f3847081ea00c7546d918f63a7954cab8a64eaae922e1", 0o644),
    SourceIdentity("tests/rtl/a0_mc_noc_p4_measurement_tb.sv", "204b08ca958bb44d45ca82d2aa68437bbaaf77b4dc6345b7b76ed83da94a5d6b", 0o644),
    SourceIdentity("tests/run_mc_noc_p4.py", "520fe221477ce5872a57be2c33f7f9633fd750d7a628993286a6bf2f6a09d6b9", 0o755),
)

P5_RELATIVE_FILES = (
    "docs/architecture/A0_MC_NOC_P5_LOGICAL_NOC_FREEZE.md",
    "tests/run_mc_noc_p5_gate.py",
)

WARNING_RE = re.compile(r"(?im)(?:^|\b)(?:%Warning|warning:)")


class Failure(RuntimeError):
    def __init__(
        self,
        stage: str,
        error: str,
        *,
        command: str = "NOT_APPLICABLE",
        exit_code: str = "NOT_APPLICABLE",
        expected: str = "",
        observed: str = "",
        cause: str = "P5_GATE_DEFECT",
    ) -> None:
        super().__init__(error)
        self.stage = stage
        self.error = error
        self.command = command
        self.exit_code = exit_code
        self.expected = expected
        self.observed = observed
        self.cause = cause


def compact(value: str, limit: int = 2400) -> str:
    text = " | ".join(value.replace("\r", "").splitlines())
    return text[-limit:] if len(text) > limit else text


def report_failure(
    failure: Failure,
    *,
    live_repo_mutation: str,
    commit_status: str,
    p5_artifact_mutation: str,
) -> None:
    print("MC_NOC_P5_FIRST_FAILURE", file=sys.stderr)
    print("MC_NOC_P5_LOGICAL_NOC_FREEZE_GATE=FAIL", file=sys.stderr)
    print(f"STAGE={failure.stage}", file=sys.stderr)
    print(f"COMMAND={failure.command}", file=sys.stderr)
    print(f"EXIT_CODE={failure.exit_code}", file=sys.stderr)
    print(f"FIRST_ERROR={failure.error}", file=sys.stderr)
    print(f"EXPECTED={compact(failure.expected)}", file=sys.stderr)
    print(f"OBSERVED={compact(failure.observed)}", file=sys.stderr)
    print(f"ROOT_CAUSE_CLASS={failure.cause}", file=sys.stderr)
    print(f"LIVE_REPO_MUTATION={live_repo_mutation}", file=sys.stderr)
    print(f"P5_ARTIFACT_MUTATION={p5_artifact_mutation}", file=sys.stderr)
    print(f"COMMIT={commit_status}", file=sys.stderr)
    print("PUSH=NOT_PERFORMED", file=sys.stderr)


def sha256(path: Path) -> str:
    digest = hashlib.sha256()
    with path.open("rb") as stream:
        for chunk in iter(lambda: stream.read(1024 * 1024), b""):
            digest.update(chunk)
    return digest.hexdigest()


def run(
    command: list[str],
    *,
    stage: str,
    cwd: Path,
    timeout: int,
) -> subprocess.CompletedProcess[str]:
    environment = os.environ.copy()
    environment["A0_REPO_ROOT"] = str(ROOT)
    environment["A0_VERILATOR_BIN"] = str(EXPECTED_VERILATOR)
    environment["LC_ALL"] = "C"
    environment["LANG"] = "C"
    environment["PYTHONDONTWRITEBYTECODE"] = "1"
    environment["PATH"] = f"{EXPECTED_VERILATOR.parent}:{environment['PATH']}"
    try:
        return subprocess.run(
            command,
            cwd=cwd,
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
            expected=f"completion within {timeout} seconds",
            observed=str(exc),
            cause="HOST_OR_TOOL_EXECUTION_DEFECT",
        ) from exc


def git_output(*arguments: str) -> str:
    completed = run(
        ["git", "-C", str(ROOT), *arguments],
        stage="REPOSITORY_CONTAINMENT",
        cwd=ROOT,
        timeout=60,
    )
    if completed.returncode != 0:
        raise Failure(
            "REPOSITORY_CONTAINMENT",
            "GIT_COMMAND_FAILED",
            command=shlex.join(["git", "-C", str(ROOT), *arguments]),
            exit_code=str(completed.returncode),
            expected="exit code 0",
            observed=completed.stdout,
            cause="REPOSITORY_GUARD_DEFECT",
        )
    return completed.stdout


def require_closed_source_identity(stage: str) -> None:
    for identity in CLOSED_SOURCES:
        path = ROOT / identity.path
        if not path.is_file():
            raise Failure(
                stage,
                "CLOSED_SOURCE_MISSING",
                expected=identity.path,
                observed="ABSENT",
                cause="CLOSED_SOURCE_IDENTITY_DEFECT",
            )
        actual_hash = sha256(path)
        actual_mode = stat.S_IMODE(path.stat().st_mode)
        if actual_hash != identity.sha256:
            raise Failure(
                stage,
                "CLOSED_SOURCE_HASH_MISMATCH",
                expected=f"{identity.sha256}:{identity.path}",
                observed=f"{actual_hash}:{identity.path}",
                cause="CLOSED_SOURCE_IDENTITY_DEFECT",
            )
        if actual_mode != identity.mode:
            raise Failure(
                stage,
                "CLOSED_SOURCE_MODE_MISMATCH",
                expected=f"{identity.mode:o}:{identity.path}",
                observed=f"{actual_mode:o}:{identity.path}",
                cause="CLOSED_SOURCE_IDENTITY_DEFECT",
            )


def expected_untracked() -> tuple[str, ...]:
    closed = tuple(identity.path for identity in CLOSED_SOURCES)
    if CANDIDATE_ROOT == ROOT:
        return tuple(sorted((*closed, *P5_RELATIVE_FILES)))
    return tuple(sorted(closed))


def ignored_snapshot() -> tuple[tuple[str, str, int, int], ...]:
    paths = tuple(
        line for line in git_output(
            "ls-files", "--others", "--ignored", "--exclude-standard"
        ).splitlines() if line
    )
    records: list[tuple[str, str, int, int]] = []
    for relative in sorted(paths):
        path = ROOT / relative
        records.append(
            (
                relative,
                sha256(path),
                path.stat().st_size,
                stat.S_IMODE(path.stat().st_mode),
            )
        )
    return tuple(records)


def repository_snapshot() -> tuple[object, ...]:
    return (
        git_output("rev-parse", "HEAD").strip(),
        git_output("log", "-1", "--format=%s").strip(),
        git_output("symbolic-ref", "--quiet", "--short", "HEAD").strip(),
        git_output("diff", "--cached", "--name-status", "--").strip(),
        git_output("diff", "--name-status", "--").strip(),
        tuple(sorted(line for line in git_output(
            "ls-files", "--others", "--exclude-standard"
        ).splitlines() if line)),
        ignored_snapshot(),
    )


def assess_failure_repository(
    before: tuple[object, ...] | None,
    p5_identity_before: tuple[tuple[str, str, int, int], ...] | None,
) -> tuple[str, str, str]:
    """Return truthful mutation/commit evidence before reporting a failure."""
    if before is None:
        return ("NONE", "NONE", "NONE")

    live_repo_mutation = "NONE"
    commit_status = "UNKNOWN"
    try:
        current = repository_snapshot()
    except Exception:
        live_repo_mutation = "UNKNOWN"
    else:
        commit_status = "NONE" if current[0] == before[0] else "HEAD_CHANGED"
        if current != before:
            live_repo_mutation = "DETECTED"
        else:
            try:
                require_closed_source_identity("FAILURE_PATH_SOURCE_IDENTITY")
            except Exception:
                live_repo_mutation = "DETECTED"

    p5_artifact_mutation = "NONE"
    if p5_identity_before is not None:
        try:
            current_p5_identity = p5_artifact_identity()
        except Exception:
            p5_artifact_mutation = "DETECTED"
        else:
            if current_p5_identity != p5_identity_before:
                p5_artifact_mutation = "DETECTED"
        if p5_artifact_mutation == "DETECTED" and CANDIDATE_ROOT == ROOT:
            live_repo_mutation = "DETECTED"

    return (live_repo_mutation, commit_status, p5_artifact_mutation)


def p5_artifact_identity() -> tuple[tuple[str, str, int, int], ...]:
    records: list[tuple[str, str, int, int]] = []
    for path in (DOC, RUNNER):
        records.append(
            (
                path.relative_to(CANDIDATE_ROOT).as_posix(),
                sha256(path),
                path.stat().st_size,
                stat.S_IMODE(path.stat().st_mode),
            )
        )
    return tuple(records)


def require_repository_contract(snapshot: tuple[object, ...], stage: str) -> None:
    head, subject, branch, index_delta, tracked_delta, untracked, _ignored = snapshot
    expected = expected_untracked()
    checks = (
        (head, EXPECTED_HEAD, "HEAD_MISMATCH"),
        (subject, EXPECTED_SUBJECT, "SUBJECT_MISMATCH"),
        (branch, EXPECTED_BRANCH, "BRANCH_MISMATCH"),
        (index_delta, "", "INDEX_DIRTY"),
        (tracked_delta, "", "TRACKED_WORKTREE_DIRTY"),
        (untracked, expected, "UNTRACKED_SCOPE_MISMATCH"),
    )
    for observed, wanted, error in checks:
        if observed != wanted:
            raise Failure(
                stage,
                error,
                expected=repr(wanted),
                observed=repr(observed),
                cause="REPOSITORY_GUARD_DEFECT",
            )


def require_static_contract() -> None:
    try:
        compile(RUNNER.read_text(encoding="utf-8"), str(RUNNER), "exec")
        document = DOC.read_text(encoding="utf-8")
    except (OSError, UnicodeError, SyntaxError) as exc:
        raise Failure(
            "STATIC_CONTRACT",
            "SOURCE_READ_OR_PARSE_FAILURE",
            observed=str(exc),
            cause="P5_ARTIFACT_DEFECT",
        ) from exc

    expected_modes = ((DOC, 0o644), (RUNNER, 0o755))
    for path, expected_mode in expected_modes:
        actual_mode = stat.S_IMODE(path.stat().st_mode)
        if actual_mode != expected_mode:
            raise Failure(
                "STATIC_CONTRACT",
                "P5_ARTIFACT_MODE_MISMATCH",
                expected=f"{expected_mode:o}:{path}",
                observed=f"{actual_mode:o}:{path}",
                cause="P5_ARTIFACT_IDENTITY_DEFECT",
            )

    required_document = (
        "MC_NOC_P5_TIMING=NOT_MEASURED",
        "MC_NOC_P5_PPA=NOT_MEASURED",
        "MC_NOC_P5_RTL_OPTIMIZATION_REQUIRED=NOT_INFERRED",
        "MC_NOC_PHASE_A_CLOSED=YES",
        "ROUTING_REGISTERED_BITS=339584",
        "COMBINED_REGISTERED_BITS=4955264",
        "one scalar post-local-fabric line stream per cluster",
        "load-line-only",
        "expose the true post-local-fabric cluster line seam",
        "adds no RTL",
    )
    missing = [token for token in required_document if token not in document]
    if missing:
        raise Failure(
            "STATIC_CONTRACT",
            "DOCUMENT_CONTRACT_MISSING",
            expected=" | ".join(required_document),
            observed="missing=" + repr(missing),
            cause="P5_DOCUMENT_DEFECT",
        )

    forbidden_document = (
        "TIMING=PASS",
        "PPA=PASS",
        "VOQ_REQUIRED=YES",
        "PHYSICAL_NOC_COMPLETE=YES",
        "COHERENCE_COMPLETE=YES",
    )
    present = [token for token in forbidden_document if token in document]
    if present:
        raise Failure(
            "STATIC_CONTRACT",
            "DOCUMENT_OVERCLAIM_PRESENT",
            expected="no unsupported timing/PPA/physical/coherence claim",
            observed=" | ".join(present),
            cause="P5_DOCUMENT_DEFECT",
        )

    if CANDIDATE_ROOT != ROOT:
        candidate_files = tuple(
            sorted(
                path.relative_to(CANDIDATE_ROOT).as_posix()
                for path in CANDIDATE_ROOT.rglob("*")
                if path.is_file()
            )
        )
        if candidate_files != tuple(sorted(P5_RELATIVE_FILES)):
            raise Failure(
                "STATIC_CONTRACT",
                "P5_CANDIDATE_SCOPE_MISMATCH",
                expected=repr(tuple(sorted(P5_RELATIVE_FILES))),
                observed=repr(candidate_files),
                cause="P5_SCOPE_DEFECT",
            )


def require_toolchain() -> None:
    identities = (
        (EXPECTED_VERILATOR, EXPECTED_VERILATOR_SHA256, "5.050"),
        (EXPECTED_SYSTEM_VERILATOR, EXPECTED_SYSTEM_VERILATOR_SHA256, "5.032"),
    )
    for path, expected_hash, expected_version in identities:
        try:
            resolved = path.resolve(strict=True)
        except OSError as exc:
            raise Failure(
                "TOOLCHAIN_IDENTITY",
                "VERILATOR_NOT_FOUND",
                expected=str(path),
                observed=str(exc),
                cause="TOOLCHAIN_AVAILABILITY_DEFECT",
            ) from exc
        if resolved != path or sha256(path) != expected_hash:
            raise Failure(
                "TOOLCHAIN_IDENTITY",
                "VERILATOR_IDENTITY_MISMATCH",
                expected=f"{path}:{expected_hash}",
                observed=f"{resolved}:{sha256(path)}",
                cause="TOOLCHAIN_IDENTITY_DEFECT",
            )
        completed = run(
            [str(path), "--version"],
            stage="TOOLCHAIN_IDENTITY",
            cwd=ROOT,
            timeout=30,
        )
        match = re.search(r"\bVerilator\s+([0-9]+\.[0-9]+)\b", completed.stdout)
        observed_version = match.group(1) if match else "UNPARSEABLE"
        if completed.returncode != 0 or observed_version != expected_version:
            raise Failure(
                "TOOLCHAIN_IDENTITY",
                "VERILATOR_VERSION_MISMATCH",
                command=shlex.join([str(path), "--version"]),
                exit_code=str(completed.returncode),
                expected=expected_version,
                observed=completed.stdout,
                cause="TOOLCHAIN_IDENTITY_DEFECT",
            )


def run_child(
    name: str,
    relative_runner: str,
    markers: tuple[str, ...],
    *,
    timeout: int,
    log_root: Path,
) -> None:
    command = [sys.executable, str(ROOT / relative_runner)]
    completed = run(command, stage=name, cwd=ROOT, timeout=timeout)
    log_path = log_root / f"{name.lower()}.log"
    log_path.write_text(completed.stdout, encoding="utf-8", newline="\n")
    if completed.returncode != 0:
        raise Failure(
            name,
            "CHILD_GATE_RETURNED_NONZERO",
            command=shlex.join(command),
            exit_code=str(completed.returncode),
            expected="exit code 0",
            observed=completed.stdout,
            cause="CHILD_GATE_FAILURE",
        )
    if WARNING_RE.search(completed.stdout):
        raise Failure(
            name,
            "CHILD_GATE_WARNING_OUTPUT",
            command=shlex.join(command),
            exit_code="0",
            expected="zero warning lines",
            observed=completed.stdout,
            cause="WARNING_CLEANLINESS_DEFECT",
        )
    lines = set(completed.stdout.replace("\r", "").splitlines())
    missing = [marker for marker in markers if marker not in lines]
    if missing:
        raise Failure(
            name,
            "CHILD_GATE_MARKER_MISSING",
            command=shlex.join(command),
            exit_code="0",
            expected=" | ".join(markers),
            observed="missing=" + repr(missing),
            cause="CHILD_GATE_CONTRACT_DEFECT",
        )


CHILDREN: tuple[tuple[str, str, tuple[str, ...], int], ...] = (
    (
        "P4_GATE",
        "tests/run_mc_noc_p4.py",
        (
            "MC_NOC_P4_TARGETED_SCENARIO_COUNT=19",
            "MC_NOC_P4_TARGETED_19=PASS",
            "MC_NOC_P4_FUNCTIONAL_MATRIX_COUNT=5",
            "MC_NOC_P4_FUNCTIONAL_MATRIX=PASS",
            "MC_NOC_P4_LARGE_STRUCTURAL_256_CU=PASS",
            "MC_NOC_P4_LARGE_STRUCTURAL_LINT=PASS",
            "MC_NOC_P4_TIMING=NOT_MEASURED",
            "MC_NOC_P4_RTL_OPTIMIZATION_REQUIRED=NOT_INFERRED",
            "MC_NOC_P4_CANDIDATE_QUALIFICATION=PASS",
        ),
        1800,
    ),
    (
        "P3_GATE",
        "tests/run_mc_noc_p3.py",
        (
            "MC_NOC_P3_TARGETED_SCENARIO_COUNT=40",
            "MC_NOC_P3_TARGETED_40=PASS",
            "MC_NOC_P3_PARAMETER_MATRIX=PASS",
            "MC_NOC_P3_INVALID_CONFIGS_FAIL_CLOSED=PASS",
            "MC_NOC_P3_VALIDATION=PASS",
        ),
        1800,
    ),
    (
        "P2_GATE",
        "tests/run_mc_noc_p2.py",
        (
            "MC_NOC_P2_TARGETED_SCENARIO_COUNT=50",
            "MC_NOC_P2_TARGETED_50=PASS",
            "MC_NOC_P2_PARAMETER_MATRIX=PASS",
            "MC_NOC_P2_INVALID_CONFIGS_FAIL_CLOSED=PASS",
            "MC_NOC_P2_VALIDATION=PASS",
        ),
        1800,
    ),
    (
        "P1_GATE",
        "tests/run_mc_noc_p1.py",
        (
            "TB_SCENARIO_COUNT=44",
            "TARGETED_44=PASS",
            "PARAMETERIZATION=PASS",
            "MC_NOC_P1_RUNNER=PASS",
        ),
        1800,
    ),
    (
        "P0_GATE",
        "tests/run_mc_noc_p0.py",
        (
            "TB_SCENARIO_COUNT=36",
            "TARGETED_36=PASS",
            "PARAMETERIZATION=PASS",
            "MC_NOC_P0_RUNNER=PASS",
        ),
        1200,
    ),
    (
        "V12_PRODUCTION_RECURSIVE_GATE",
        "tests/run_sliced_l2_foundation_gate.py",
        (
            "SLICED_L2_TARGETED_SCENARIOS=PASS count=45",
            "PRODUCTION_MULTI_CU_SHARED_L2_GATE=PASS",
            "SLICED_L2_PRODUCTION_MULTI_CU_RECURSIVE_GATE=PASS",
            "SLICED_L2_FOUNDATION_GATE=PASS",
        ),
        3600,
    ),
)


def main() -> int:
    before: tuple[object, ...] | None = None
    local_identity_before: tuple[tuple[str, str, int, int], ...] | None = None
    try:
        require_static_contract()
        require_closed_source_identity("CLOSED_SOURCE_IDENTITY")
        require_toolchain()
        before = repository_snapshot()
        require_repository_contract(before, "PRE_GATE_REPOSITORY")
        local_identity_before = p5_artifact_identity()

        print("MC_NOC_P5_STATIC_CONTRACT=PASS")
        print("MC_NOC_P5_CLOSED_SOURCE_COUNT=26")
        print("MC_NOC_P5_CLOSED_SOURCE_IDENTITY=PASS")
        print("MC_NOC_P5_EXACT_VERILATOR_5_050=PASS")

        with tempfile.TemporaryDirectory(
            prefix="a0_mc_noc_p5_gate_", dir="/tmp"
        ) as temporary:
            log_root = Path(temporary)
            for name, runner, markers, timeout in CHILDREN:
                run_child(
                    name,
                    runner,
                    markers,
                    timeout=timeout,
                    log_root=log_root,
                )
                require_closed_source_identity(f"POST_{name}_SOURCE_IDENTITY")
                current = repository_snapshot()
                if current != before:
                    raise Failure(
                        f"POST_{name}_CONTAINMENT",
                        "REPOSITORY_STATE_CHANGED",
                        expected=repr(before),
                        observed=repr(current),
                        cause="CHILD_GATE_CONTAINMENT_DEFECT",
                    )
                current_local_identity = p5_artifact_identity()
                if current_local_identity != local_identity_before:
                    raise Failure(
                        f"POST_{name}_P5_IDENTITY",
                        "P5_SOURCE_CHANGED_DURING_CHILD_GATE",
                        expected=repr(local_identity_before),
                        observed=repr(current_local_identity),
                        cause="P5_SOURCE_CONTAINMENT_DEFECT",
                    )
                print(f"MC_NOC_P5_{name}=PASS")

        if p5_artifact_identity() != local_identity_before:
            raise Failure(
                "POST_GATE_IDENTITY",
                "P5_SOURCE_CHANGED_DURING_GATE",
                expected=repr(local_identity_before),
                observed=repr(p5_artifact_identity()),
                cause="P5_SOURCE_CONTAINMENT_DEFECT",
            )

        print("MC_NOC_P5_P0_TO_P4_REGRESSION=PASS")
        print("MC_NOC_P5_POST_GATE_CONTAINMENT=PASS")
        print("MC_NOC_P5_TIMING=NOT_MEASURED")
        print("MC_NOC_P5_PPA=NOT_MEASURED")
        print("MC_NOC_P5_RTL_OPTIMIZATION_REQUIRED=NOT_INFERRED")
        print("MC_NOC_P5_LOGICAL_NOC_FREEZE_GATE=PASS")
        print("MC_NOC_P5_PHASE_A_CLOSURE_PREREQUISITE=PASS")
        return 0
    except Failure as failure:
        mutation_status, commit_status, p5_mutation = assess_failure_repository(
            before, local_identity_before
        )
        report_failure(
            failure,
            live_repo_mutation=mutation_status,
            commit_status=commit_status,
            p5_artifact_mutation=p5_mutation,
        )
        return 1
    except Exception as exc:
        mutation_status, commit_status, p5_mutation = assess_failure_repository(
            before, local_identity_before
        )
        report_failure(
            Failure(
                "UNEXPECTED_RUNNER_EXCEPTION",
                type(exc).__name__,
                observed=str(exc),
                cause="P5_RUNNER_DEFECT",
            ),
            live_repo_mutation=mutation_status,
            commit_status=commit_status,
            p5_artifact_mutation=p5_mutation,
        )
        return 1


if __name__ == "__main__":
    raise SystemExit(main())
