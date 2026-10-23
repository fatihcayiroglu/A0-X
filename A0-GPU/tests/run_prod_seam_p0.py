#!/usr/bin/env python3

from __future__ import annotations

from dataclasses import dataclass
import argparse
import hashlib
import os
from pathlib import Path
import re
import shlex
import shutil
import stat
import subprocess
import sys
import tempfile


sys.dont_write_bytecode = True

RUNNER = Path(__file__).resolve()
CANDIDATE_ROOT = RUNNER.parents[1]
ROOT = Path(os.environ.get("A0_REPO_ROOT", CANDIDATE_ROOT)).resolve()

DUT = CANDIDATE_ROOT / "rtl/memory/a0_production_cluster_line_seam.sv"
EQUIVALENCE = (
    CANDIDATE_ROOT
    / "tests/rtl/a0_production_cluster_line_seam_equivalence.sv"
)
DOC = (
    CANDIDATE_ROOT
    / "docs/architecture/A0_PROD_SEAM_P0_CLUSTER_LINE_SEAM.md"
)

FABRIC = ROOT / "rtl/memory/a0_line_request_fabric.sv"
L2 = ROOT / "rtl/memory/a0_l2_line_cache.sv"
REFERENCE = ROOT / "rtl/memory/a0_shared_l2_subsystem.sv"
REFERENCE_TB = ROOT / "tests/rtl/a0_shared_l2_subsystem_tb.sv"

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

EXPECTED_IGNORED = (
    (
        "build/a0_test.out",
        "af6019b4d25de029e2d72ad9b5699dbd94e9d51af1809bcfb314dceb76b2cc2d",
        171378,
        0o755,
    ),
)


@dataclass(frozen=True)
class SourceIdentity:
    path: str
    sha256: str
    mode: int


P5_CLOSED_SOURCES: tuple[SourceIdentity, ...] = (
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
    SourceIdentity("docs/architecture/A0_MC_NOC_P5_LOGICAL_NOC_FREEZE.md", "a30d8a1281812920167aa30b8f2be7a4c3f537a0b07f84dcf262bc40d82d75d7", 0o644),
    SourceIdentity("tests/run_mc_noc_p5_gate.py", "1dd7f333d835d1e5aa6dba9728dc609c7e6831890d26fc6ae3462f13d5f0421e", 0o755),
)

TRACKED_DEPENDENCIES: tuple[SourceIdentity, ...] = (
    SourceIdentity("rtl/memory/a0_line_request_fabric.sv", "a72aaf19dbedd6eb37296fd26a5af5909106c552edd858f4de9a6674c1a24bed", 0o644),
    SourceIdentity("rtl/memory/a0_l2_line_cache.sv", "5d67b6ed5cddff2ce86558b9c4664e526c3b05e1f5fd9f4e4049c243a093b086", 0o644),
    SourceIdentity("rtl/memory/a0_shared_l2_subsystem.sv", "006bab6a0397d261c836e175d0b44d915a2483940994da1897f123cc32fd82d5", 0o644),
    SourceIdentity("tests/rtl/a0_shared_l2_subsystem_tb.sv", "0ac89d2475fdffa7f109dc1dce37e34373bddafbf4c23e6d533627d96ac78a2a", 0o644),
    SourceIdentity("tests/run_rtl9d3_shared_l2_integration.py", "2fdafec853832888adedcbbfc2cf9bda5e4dadfdec9c228723152a4fbf9f92f3", 0o755),
)

CANDIDATE_RELATIVE_FILES = (
    "docs/architecture/A0_PROD_SEAM_P0_CLUSTER_LINE_SEAM.md",
    "rtl/memory/a0_production_cluster_line_seam.sv",
    "tests/rtl/a0_production_cluster_line_seam_equivalence.sv",
    "tests/run_prod_seam_p0.py",
)

# The three unchanged artifacts have exact content identities in both modes.
# The runner seals its source with only this one digest literal zeroed, avoiding
# a circular full-file SHA. Canonical patch/validator identities additionally
# bind the complete runner bytes, including this literal, at freeze time.
SELF_SOURCE_SHA256 = "66ebe3754cd963f01819306a512698341b23401a1dbc3e3915c3b214c5513f49"
CANDIDATE_CONTENT_IDENTITIES = (
    (CANDIDATE_RELATIVE_FILES[0], "0496f9fec444d6524b73f7fdaa2cfeb10f0c413ead2e002fd975570e63b5f59f", 8036),
    (CANDIDATE_RELATIVE_FILES[1], "e40b3313066078e811c3791cfe8a9ef4f113f5516d3c36f1b3818c11530d51ae", 8376),
    (CANDIDATE_RELATIVE_FILES[2], "01867fe6ccdaac3722d79fb287e3233c3dc2e14a9e937bdc6da613fd0346dcc5", 13504),
)

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

LINT_CONFIGURATIONS = (
    (1, 1, 1, 1),
    (2, 2, 2, 4),
    (3, 3, 3, 8),
    (4, 2, 32, 8),
    (5, 4, 8, 16),
    (64, 4, 32, 8),
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
        cause: str = "PROD_SEAM_P0_QUALIFICATION_DEFECT",
        dut_or_tb: str = "UNRESOLVED",
    ) -> None:
        super().__init__(error)
        self.stage = stage
        self.error = error
        self.command = command
        self.exit_code = exit_code
        self.expected = expected
        self.observed = observed
        self.cause = cause
        self.dut_or_tb = dut_or_tb


def compact(value: str, limit: int = 2600) -> str:
    text = " | ".join(value.replace("\r", "").splitlines())
    return text[-limit:] if len(text) > limit else text


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
    repo_root: Path | None = None,
) -> subprocess.CompletedProcess[str]:
    environment = os.environ.copy()
    environment["A0_REPO_ROOT"] = str(repo_root or ROOT)
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


def require_success(
    completed: subprocess.CompletedProcess[str],
    *,
    stage: str,
    command: list[str],
    dut_or_tb: str,
) -> str:
    if completed.returncode != 0:
        raise Failure(
            stage,
            "COMMAND_RETURNED_NONZERO",
            command=shlex.join(command),
            exit_code=str(completed.returncode),
            expected="exit code 0",
            observed=completed.stdout,
            cause="DUT_OR_TEST_EXECUTION_DEFECT",
            dut_or_tb=dut_or_tb,
        )
    if WARNING_RE.search(completed.stdout):
        raise Failure(
            stage,
            "WARNING_OUTPUT_PRESENT",
            command=shlex.join(command),
            exit_code="0",
            expected="zero warning lines",
            observed=completed.stdout,
            cause="WARNING_CLEANLINESS_DEFECT",
            dut_or_tb=dut_or_tb,
        )
    return completed.stdout


def git_output(*arguments: str, root: Path = ROOT) -> str:
    command = ["git", "-C", str(root), *arguments]
    completed = run(
        command,
        stage="REPOSITORY_CONTAINMENT",
        cwd=root,
        timeout=60,
        repo_root=root,
    )
    if completed.returncode != 0:
        raise Failure(
            "REPOSITORY_CONTAINMENT",
            "GIT_COMMAND_FAILED",
            command=shlex.join(command),
            exit_code=str(completed.returncode),
            expected="exit code 0",
            observed=completed.stdout,
            cause="REPOSITORY_GUARD_DEFECT",
            dut_or_tb="NEITHER",
        )
    return completed.stdout


def file_record(root: Path, relative: str) -> tuple[str, str, int, int]:
    path = root / relative
    return (
        relative,
        sha256(path),
        path.stat().st_size,
        stat.S_IMODE(path.stat().st_mode),
    )


def repository_snapshot() -> tuple[object, ...]:
    untracked = tuple(sorted(
        line
        for line in git_output(
            "ls-files", "--others", "--exclude-standard"
        ).splitlines()
        if line
    ))
    ignored = tuple(sorted(
        line
        for line in git_output(
            "ls-files", "--others", "--ignored", "--exclude-standard"
        ).splitlines()
        if line
    ))
    return (
        git_output("rev-parse", "HEAD").strip(),
        git_output("log", "-1", "--format=%s").strip(),
        git_output("symbolic-ref", "--quiet", "--short", "HEAD").strip(),
        git_output("diff", "--cached", "--name-status", "--").strip(),
        git_output("diff", "--name-status", "--").strip(),
        tuple(file_record(ROOT, relative) for relative in untracked),
        tuple(file_record(ROOT, relative) for relative in ignored),
    )


def candidate_identity() -> tuple[tuple[str, str, int, int], ...]:
    return tuple(
        file_record(CANDIDATE_ROOT, relative)
        for relative in sorted(CANDIDATE_RELATIVE_FILES)
    )


def expected_untracked_paths() -> tuple[str, ...]:
    paths = [identity.path for identity in P5_CLOSED_SOURCES]
    if CANDIDATE_ROOT == ROOT:
        paths.extend(CANDIDATE_RELATIVE_FILES)
    return tuple(sorted(paths))


def require_repository_contract(
    snapshot: tuple[object, ...], stage: str
) -> None:
    head, subject, branch, index, tracked, untracked, ignored = snapshot
    observed_untracked = tuple(record[0] for record in untracked)
    checks = (
        (head, EXPECTED_HEAD, "HEAD_MISMATCH"),
        (subject, EXPECTED_SUBJECT, "SUBJECT_MISMATCH"),
        (branch, EXPECTED_BRANCH, "BRANCH_MISMATCH"),
        (index, "", "INDEX_DIRTY"),
        (tracked, "", "TRACKED_WORKTREE_DIRTY"),
        (observed_untracked, expected_untracked_paths(), "UNTRACKED_SCOPE_MISMATCH"),
        (ignored, EXPECTED_IGNORED, "IGNORED_IDENTITY_MISMATCH"),
    )
    for observed, expected, error in checks:
        if observed != expected:
            raise Failure(
                stage,
                error,
                expected=repr(expected),
                observed=repr(observed),
                cause="REPOSITORY_GUARD_DEFECT",
                dut_or_tb="NEITHER",
            )


def require_source_identity() -> None:
    for identity in (*P5_CLOSED_SOURCES, *TRACKED_DEPENDENCIES):
        path = ROOT / identity.path
        if not path.is_file():
            raise Failure(
                "SOURCE_IDENTITY",
                "DEPENDENCY_MISSING",
                expected=identity.path,
                observed="ABSENT",
                cause="SOURCE_AVAILABILITY_DEFECT",
                dut_or_tb="NEITHER",
            )
        actual_hash = sha256(path)
        actual_mode = stat.S_IMODE(path.stat().st_mode)
        if actual_hash != identity.sha256 or actual_mode != identity.mode:
            raise Failure(
                "SOURCE_IDENTITY",
                "DEPENDENCY_IDENTITY_MISMATCH",
                expected=f"{identity.sha256}:{identity.mode:o}:{identity.path}",
                observed=f"{actual_hash}:{actual_mode:o}:{identity.path}",
                cause="CLOSED_SOURCE_IDENTITY_DEFECT",
                dut_or_tb="NEITHER",
            )


def require_static_contract() -> None:
    expected_modes = {
        CANDIDATE_RELATIVE_FILES[0]: 0o644,
        CANDIDATE_RELATIVE_FILES[1]: 0o644,
        CANDIDATE_RELATIVE_FILES[2]: 0o644,
        CANDIDATE_RELATIVE_FILES[3]: 0o755,
    }
    if CANDIDATE_ROOT == ROOT:
        # Installed scope is the independently checked Git exact-32 contract.
        # Tracked baseline files and .git metadata are not candidate artifacts.
        require_repository_contract(
            repository_snapshot(), "INSTALLED_CANDIDATE_SCOPE"
        )
    else:
        candidate_paths = tuple(CANDIDATE_ROOT.rglob("*"))
        actual_files = tuple(sorted(
            path.relative_to(CANDIDATE_ROOT).as_posix()
            for path in candidate_paths
            if path.is_file() or path.is_symlink()
        ))
        if (
            actual_files != tuple(sorted(CANDIDATE_RELATIVE_FILES))
            or any(path.is_symlink() for path in candidate_paths)
        ):
            raise Failure(
                "STATIC_CONTRACT",
                "CANDIDATE_SCOPE_MISMATCH",
                expected=repr(tuple(sorted(CANDIDATE_RELATIVE_FILES))),
                observed=repr(actual_files),
                cause="CANDIDATE_SCOPE_DEFECT",
                dut_or_tb="NEITHER",
            )

    for relative, expected_mode in expected_modes.items():
        path = CANDIDATE_ROOT / relative
        if not path.is_file() or path.is_symlink():
            raise Failure(
                "STATIC_CONTRACT",
                "CANDIDATE_REGULAR_FILE_MISSING",
                expected=relative,
                observed="MISSING_OR_NOT_REGULAR",
                cause="CANDIDATE_IDENTITY_DEFECT",
                dut_or_tb="NEITHER",
            )
        actual_mode = stat.S_IMODE(path.lstat().st_mode)
        if actual_mode != expected_mode:
            raise Failure(
                "STATIC_CONTRACT",
                "CANDIDATE_MODE_MISMATCH",
                expected=f"{expected_mode:o}:{relative}",
                observed=f"{actual_mode:o}:{relative}",
                cause="CANDIDATE_IDENTITY_DEFECT",
                dut_or_tb="NEITHER",
            )

    for relative, expected_hash, expected_bytes in CANDIDATE_CONTENT_IDENTITIES:
        path = CANDIDATE_ROOT / relative
        observed_identity = (sha256(path), path.stat().st_size)
        if observed_identity != (expected_hash, expected_bytes):
            raise Failure(
                "STATIC_CONTRACT",
                "CANDIDATE_CONTENT_MISMATCH",
                expected=f"{relative}:{expected_hash}:{expected_bytes}",
                observed=f"{relative}:{observed_identity}",
                cause="CANDIDATE_IDENTITY_DEFECT",
                dut_or_tb="NEITHER",
            )

    runner_bytes = RUNNER.read_bytes()
    seal_pattern = rb'^SELF_SOURCE_SHA256 = "([0-9a-f]{64})"$'
    seals = tuple(re.finditer(seal_pattern, runner_bytes, flags=re.M))
    normalized = re.sub(
        seal_pattern,
        b'SELF_SOURCE_SHA256 = "' + b"0" * 64 + b'"',
        runner_bytes,
        flags=re.M,
    )
    normalized_hash = hashlib.sha256(normalized).hexdigest()
    if (
        len(seals) != 1
        or seals[0].group(1).decode("ascii") != SELF_SOURCE_SHA256
        or normalized_hash != SELF_SOURCE_SHA256
    ):
        raise Failure(
            "STATIC_CONTRACT",
            "RUNNER_CONTENT_MISMATCH",
            expected=SELF_SOURCE_SHA256,
            observed=f"{normalized_hash}:seal_count={len(seals)}",
            cause="CANDIDATE_IDENTITY_DEFECT",
            dut_or_tb="NEITHER",
        )

    try:
        compile(RUNNER.read_text(encoding="utf-8"), str(RUNNER), "exec")
        dut = DUT.read_text(encoding="utf-8")
        equivalence = EQUIVALENCE.read_text(encoding="utf-8")
        document = DOC.read_text(encoding="utf-8")
    except (OSError, UnicodeError, SyntaxError) as exc:
        raise Failure(
            "STATIC_CONTRACT",
            "SOURCE_READ_OR_PARSE_FAILURE",
            observed=str(exc),
            cause="CANDIDATE_SOURCE_DEFECT",
            dut_or_tb="UNRESOLVED",
        ) from exc

    required_dut = (
        "module a0_production_cluster_line_seam",
        "a0_line_request_fabric #(",
        "line_req_global_tag_o",
        "line_resp_global_tag_i",
        "store_observe_valid_o",
        "store_observe_lane_mask_o",
        "store_observe_word_addr_o",
        "client_store_valid_i[flatten_client]",
    )
    missing_dut = [token for token in required_dut if token not in dut]
    forbidden_dut = (
        "a0_l2_line_cache",
        "a0_cluster_line_noc_endpoint",
        "a0_multi_wave_core",
        "a0_cluster_store_order_controller",
    )
    present_dut = [token for token in forbidden_dut if token in dut]
    if missing_dut or present_dut:
        raise Failure(
            "STATIC_CONTRACT",
            "DUT_BOUNDARY_CONTRACT_MISMATCH",
            expected="missing=[] and forbidden=[]",
            observed=f"missing={missing_dut!r} forbidden={present_dut!r}",
            cause="DUT_SCOPE_DEFECT",
            dut_or_tb="DUT",
        )

    required_equivalence = (
        "module a0_production_cluster_line_seam_equivalence",
        "a0_production_cluster_line_seam #(",
        "a0_shared_l2_subsystem #(",
        "a0_l2_line_cache #(",
        "require_equivalent_outputs",
        "reference_subsystem.fabric_line_req_global_tag",
        "reference_subsystem.l2_store_lane_mask",
    )
    missing_equivalence = [
        token for token in required_equivalence if token not in equivalence
    ]
    if missing_equivalence:
        raise Failure(
            "STATIC_CONTRACT",
            "EQUIVALENCE_CONTRACT_MISSING",
            expected=" | ".join(required_equivalence),
            observed="missing=" + repr(missing_equivalence),
            cause="TB_CONTRACT_DEFECT",
            dut_or_tb="TB",
        )

    required_document = (
        "PROD-SEAM-P0",
        "global_tag = {client_id(c), local_tag}",
        "PROD_SEAM_P0_TIMING=NOT_MEASURED",
        "PROD_SEAM_P0_PPA=NOT_MEASURED",
        "PROD_SEAM_P0_COHERENCE=NOT_IMPLEMENTED",
        "PROD_SEAM_P0_PRODUCTION_WIRING=NOT_IMPLEMENTED",
        "PROD-SEAM-P1",
    )
    missing_document = [
        token for token in required_document if token not in document
    ]
    if missing_document:
        raise Failure(
            "STATIC_CONTRACT",
            "DOCUMENT_CONTRACT_MISSING",
            expected=" | ".join(required_document),
            observed="missing=" + repr(missing_document),
            cause="DOCUMENT_CONTRACT_DEFECT",
            dut_or_tb="NEITHER",
        )

    forbidden_document = (
        "PROD_SEAM_P0_TIMING=PASS",
        "PROD_SEAM_P0_PPA=PASS",
        "PROD_SEAM_P0_COHERENCE=PASS",
        "PROD_SEAM_P0_PRODUCTION_WIRING=PASS",
    )
    present_document = [
        token for token in forbidden_document if token in document
    ]
    if present_document:
        raise Failure(
            "STATIC_CONTRACT",
            "DOCUMENT_OVERCLAIM_PRESENT",
            expected="no unsupported timing/PPA/coherence/wiring claim",
            observed=" | ".join(present_document),
            cause="DOCUMENT_OVERCLAIM_DEFECT",
            dut_or_tb="NEITHER",
        )


def require_toolchain() -> tuple[tuple[str, str, int, int], ...]:
    records: list[tuple[str, str, int, int]] = []
    identities = (
        (EXPECTED_VERILATOR, EXPECTED_VERILATOR_SHA256, "5.050", 0o755),
        (
            EXPECTED_SYSTEM_VERILATOR,
            EXPECTED_SYSTEM_VERILATOR_SHA256,
            "5.032",
            0o755,
        ),
    )
    for path, expected_hash, expected_version, expected_mode in identities:
        try:
            resolved = path.resolve(strict=True)
        except OSError as exc:
            raise Failure(
                "TOOLCHAIN_IDENTITY",
                "VERILATOR_NOT_FOUND",
                expected=str(path),
                observed=str(exc),
                cause="TOOLCHAIN_AVAILABILITY_DEFECT",
                dut_or_tb="NEITHER",
            ) from exc
        actual_hash = sha256(path)
        actual_mode = stat.S_IMODE(path.stat().st_mode)
        if (
            resolved != path
            or actual_hash != expected_hash
            or actual_mode != expected_mode
        ):
            raise Failure(
                "TOOLCHAIN_IDENTITY",
                "VERILATOR_IDENTITY_MISMATCH",
                expected=f"{path}:{expected_hash}:{expected_mode:o}",
                observed=f"{resolved}:{actual_hash}:{actual_mode:o}",
                cause="TOOLCHAIN_IDENTITY_DEFECT",
                dut_or_tb="NEITHER",
            )
        command = [str(path), "--version"]
        completed = run(
            command,
            stage="TOOLCHAIN_IDENTITY",
            cwd=ROOT,
            timeout=30,
        )
        match = re.search(r"\bVerilator\s+([0-9]+\.[0-9]+)\b", completed.stdout)
        actual_version = match.group(1) if match else "UNPARSEABLE"
        if completed.returncode != 0 or actual_version != expected_version:
            raise Failure(
                "TOOLCHAIN_IDENTITY",
                "VERILATOR_VERSION_MISMATCH",
                command=shlex.join(command),
                exit_code=str(completed.returncode),
                expected=expected_version,
                observed=completed.stdout,
                cause="TOOLCHAIN_IDENTITY_DEFECT",
                dut_or_tb="NEITHER",
            )
        records.append(
            (str(path), actual_hash, path.stat().st_size, actual_mode)
        )
    return tuple(records)


def adapted_reference_tb(destination: Path) -> None:
    source = REFERENCE_TB.read_text(encoding="utf-8")
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
        actual_count = source.count(old)
        if actual_count != expected_count:
            raise Failure(
                "TB_ADAPTATION",
                "REFERENCE_TB_TRANSFORM_COUNT_MISMATCH",
                expected=f"{expected_count}:{old}",
                observed=f"{actual_count}:{old}",
                cause="HASH_LOCKED_TB_ADAPTATION_DEFECT",
                dut_or_tb="TB",
            )
        source = source.replace(old, new)
    destination.write_text(source, encoding="utf-8", newline="\n")


def run_equivalence(temp_root: Path) -> None:
    adapted_tb = temp_root / "a0_production_cluster_line_seam_equivalence_tb.sv"
    adapted_reference_tb(adapted_tb)
    object_root = temp_root / "obj_equivalence"
    top = "a0_production_cluster_line_seam_equivalence_tb"
    compile_command = [
        str(EXPECTED_VERILATOR),
        "--binary",
        "--timing",
        "--unroll-count",
        "512",
        "-Wall",
        "-Werror-PINMISSING",
        "-Werror-WIDTHEXPAND",
        "-Werror-WIDTHTRUNC",
        "--top-module",
        top,
        "--Mdir",
        str(object_root),
        str(FABRIC),
        str(L2),
        str(REFERENCE),
        str(DUT),
        str(EQUIVALENCE),
        str(adapted_tb),
    ]
    compile_result = run(
        compile_command,
        stage="EQUIVALENCE_COMPILE",
        cwd=ROOT,
        timeout=900,
    )
    require_success(
        compile_result,
        stage="EQUIVALENCE_COMPILE",
        command=compile_command,
        dut_or_tb="DUT_OR_TB",
    )
    executable = object_root / f"V{top}"
    if not executable.is_file():
        raise Failure(
            "EQUIVALENCE_COMPILE",
            "EXECUTABLE_MISSING",
            expected=str(executable),
            observed="ABSENT",
            cause="BUILD_ARTIFACT_DEFECT",
            dut_or_tb="NEITHER",
        )
    simulation_command = [str(executable)]
    simulation = run(
        simulation_command,
        stage="EQUIVALENCE_SIMULATION",
        cwd=ROOT,
        timeout=600,
    )
    output = require_success(
        simulation,
        stage="EQUIVALENCE_SIMULATION",
        command=simulation_command,
        dut_or_tb="DUT_OR_TB",
    )
    lines = set(output.replace("\r", "").splitlines())
    missing = [marker for marker in RTL9D3_MARKERS if marker not in lines]
    if missing:
        raise Failure(
            "EQUIVALENCE_SIMULATION",
            "REFERENCE_SCENARIO_MARKERS_MISSING",
            command=shlex.join(simulation_command),
            exit_code="0",
            expected=" | ".join(RTL9D3_MARKERS),
            observed="missing=" + repr(missing),
            cause="EQUIVALENCE_SCENARIO_DEFECT",
            dut_or_tb="DUT_OR_TB",
        )


def run_lint_matrix(temp_root: Path) -> None:
    for index, (clients, local_tags, store_lanes, line_words) in enumerate(
        LINT_CONFIGURATIONS, start=1
    ):
        configuration = (
            f"CLIENT_COUNT={clients},LOCAL_TAG_W={local_tags},"
            f"STORE_LANES_PER_CLIENT={store_lanes},LINE_WORDS={line_words}"
        )
        command = [
            str(EXPECTED_VERILATOR),
            "--lint-only",
            "-Wall",
            "-Werror-PINMISSING",
            "-Werror-WIDTHEXPAND",
            "-Werror-WIDTHTRUNC",
            "--top-module",
            "a0_production_cluster_line_seam",
            f"-GCLIENT_COUNT={clients}",
            f"-GLOCAL_TAG_W={local_tags}",
            f"-GSTORE_LANES_PER_CLIENT={store_lanes}",
            f"-GLINE_WORDS={line_words}",
            "--Mdir",
            str(temp_root / f"obj_lint_{index}"),
            str(FABRIC),
            str(DUT),
        ]
        completed = run(
            command,
            stage="PARAMETER_LINT_MATRIX",
            cwd=ROOT,
            timeout=900,
        )
        require_success(
            completed,
            stage="PARAMETER_LINT_MATRIX",
            command=command,
            dut_or_tb="DUT",
        )
        print(f"PROD_SEAM_P0_PARAMETER_POINT_{index}=PASS {configuration}")


def run_p5_projection(temp_root: Path) -> None:
    projection = temp_root / "p5_projection"
    clone_command = [
        "git",
        "clone",
        "--no-local",
        "--quiet",
        str(ROOT),
        str(projection),
    ]
    clone = run(
        clone_command,
        stage="P5_PROJECTION_BUILD",
        cwd=temp_root,
        timeout=300,
    )
    require_success(
        clone,
        stage="P5_PROJECTION_BUILD",
        command=clone_command,
        dut_or_tb="NEITHER",
    )

    for identity in P5_CLOSED_SOURCES:
        source = ROOT / identity.path
        destination = projection / identity.path
        destination.parent.mkdir(parents=True, exist_ok=True)
        shutil.copy2(source, destination)
        destination.chmod(identity.mode)
        if (
            sha256(destination) != identity.sha256
            or stat.S_IMODE(destination.stat().st_mode) != identity.mode
        ):
            raise Failure(
                "P5_PROJECTION_BUILD",
                "PROJECTED_SOURCE_IDENTITY_MISMATCH",
                expected=f"{identity.sha256}:{identity.mode:o}:{identity.path}",
                observed=(
                    f"{sha256(destination)}:"
                    f"{stat.S_IMODE(destination.stat().st_mode):o}:"
                    f"{identity.path}"
                ),
                cause="PROJECTION_CONSTRUCTION_DEFECT",
                dut_or_tb="NEITHER",
            )

    gate = projection / "tests/run_mc_noc_p5_gate.py"
    command = [sys.executable, str(gate)]
    completed = run(
        command,
        stage="P5_CLOSED_SOURCE_REGRESSION",
        cwd=projection,
        timeout=7200,
        repo_root=projection,
    )
    output = require_success(
        completed,
        stage="P5_CLOSED_SOURCE_REGRESSION",
        command=command,
        dut_or_tb="PREDECESSOR_GATE",
    )
    lines = set(output.replace("\r", "").splitlines())
    required = (
        "MC_NOC_P5_P0_TO_P4_REGRESSION=PASS",
        "MC_NOC_P5_POST_GATE_CONTAINMENT=PASS",
        "MC_NOC_P5_LOGICAL_NOC_FREEZE_GATE=PASS",
        "MC_NOC_P5_PHASE_A_CLOSURE_PREREQUISITE=PASS",
    )
    missing = [marker for marker in required if marker not in lines]
    if missing:
        raise Failure(
            "P5_CLOSED_SOURCE_REGRESSION",
            "P5_GATE_MARKERS_MISSING",
            command=shlex.join(command),
            exit_code="0",
            expected=" | ".join(required),
            observed="missing=" + repr(missing),
            cause="PREDECESSOR_GATE_CONTRACT_DEFECT",
            dut_or_tb="PREDECESSOR_GATE",
        )


def require_containment(
    before: tuple[object, ...],
    candidate_before: tuple[tuple[str, str, int, int], ...],
    toolchain_before: tuple[tuple[str, str, int, int], ...],
    stage: str,
) -> None:
    current = repository_snapshot()
    if current != before:
        raise Failure(
            stage,
            "LIVE_REPOSITORY_STATE_CHANGED",
            expected=repr(before),
            observed=repr(current),
            cause="LIVE_REPOSITORY_CONTAINMENT_DEFECT",
            dut_or_tb="NEITHER",
        )
    current_candidate = candidate_identity()
    if current_candidate != candidate_before:
        raise Failure(
            stage,
            "CANDIDATE_IDENTITY_CHANGED",
            expected=repr(candidate_before),
            observed=repr(current_candidate),
            cause="CANDIDATE_CONTAINMENT_DEFECT",
            dut_or_tb="NEITHER",
        )
    current_toolchain = require_toolchain()
    if current_toolchain != toolchain_before:
        raise Failure(
            stage,
            "TOOLCHAIN_IDENTITY_CHANGED",
            expected=repr(toolchain_before),
            observed=repr(current_toolchain),
            cause="TOOLCHAIN_CONTAINMENT_DEFECT",
            dut_or_tb="NEITHER",
        )


def assess_failure(
    before: tuple[object, ...] | None,
    candidate_before: tuple[tuple[str, str, int, int], ...] | None,
) -> tuple[str, str, str]:
    live_mutation = "UNKNOWN"
    commit = "UNKNOWN"
    candidate_mutation = "UNKNOWN"
    if before is not None:
        try:
            current = repository_snapshot()
        except Exception:
            pass
        else:
            live_mutation = "NONE" if current == before else "DETECTED"
            commit = "NONE" if current[0] == before[0] else "HEAD_CHANGED"
    if candidate_before is not None:
        try:
            current_candidate = candidate_identity()
        except Exception:
            pass
        else:
            candidate_mutation = (
                "NONE" if current_candidate == candidate_before else "DETECTED"
            )
    return live_mutation, commit, candidate_mutation


def report_failure(
    failure: Failure,
    *,
    live_mutation: str,
    commit: str,
    candidate_mutation: str,
) -> None:
    print("PROD_SEAM_P0_FIRST_FAILURE", file=sys.stderr)
    print("PROD_SEAM_P0_CANDIDATE_QUALIFICATION=FAIL", file=sys.stderr)
    print(f"STAGE={failure.stage}", file=sys.stderr)
    print(f"COMMAND={failure.command}", file=sys.stderr)
    print(f"EXIT_CODE={failure.exit_code}", file=sys.stderr)
    print(f"FIRST_ERROR={failure.error}", file=sys.stderr)
    print(f"EXPECTED={compact(failure.expected)}", file=sys.stderr)
    print(f"OBSERVED={compact(failure.observed)}", file=sys.stderr)
    print(f"ROOT_CAUSE_CLASS={failure.cause}", file=sys.stderr)
    print(f"DUT_OR_TB={failure.dut_or_tb}", file=sys.stderr)
    print(f"CANDIDATE_MUTATION={candidate_mutation}", file=sys.stderr)
    print(f"LIVE_REPO_MUTATION={live_mutation}", file=sys.stderr)
    print(f"COMMIT={commit}", file=sys.stderr)
    print("PUSH=NOT_PERFORMED", file=sys.stderr)


def main() -> int:
    parser = argparse.ArgumentParser()
    run_mode = parser.add_mutually_exclusive_group()
    run_mode.add_argument(
        "--targeted-only",
        action="store_true",
        help="run equivalence and parameter checks without predecessor gate",
    )
    run_mode.add_argument(
        "--preflight-only",
        action="store_true",
        help="check exact source, repository, and toolchain contracts only",
    )
    arguments = parser.parse_args()

    before: tuple[object, ...] | None = None
    candidate_before: tuple[tuple[str, str, int, int], ...] | None = None
    try:
        before = repository_snapshot()
        require_repository_contract(before, "PRE_GATE_REPOSITORY")
        require_source_identity()
        require_static_contract()
        candidate_before = candidate_identity()
        toolchain_before = require_toolchain()

        print("PROD_SEAM_P0_BASELINE_GUARD=PASS")
        print("PROD_SEAM_P0_P5_CLOSED_SOURCE_COUNT=28")
        print("PROD_SEAM_P0_P5_CLOSED_SOURCE_IDENTITY=PASS")
        print("PROD_SEAM_P0_STATIC_CONTRACT=PASS")
        print("PROD_SEAM_P0_EXACT_VERILATOR_5_050=PASS")
        print("PROD_SEAM_P0_SYSTEM_VERILATOR_5_032_UNCHANGED=PASS")

        if arguments.preflight_only:
            require_containment(
                before, candidate_before, toolchain_before,
                "POST_PREFLIGHT_CONTAINMENT",
            )
            mode = "INSTALLED" if CANDIDATE_ROOT == ROOT else "EXTERNAL"
            print(f"PROD_SEAM_P0_{mode}_PREFLIGHT=PASS")
            print("PROD_SEAM_P0_BEHAVIORAL_QUALIFICATION=NOT_RUN_PREFLIGHT_ONLY")
            print("LIVE_REPO_MUTATION=NONE")
            print("COMMIT=NONE")
            print("PUSH=NOT_PERFORMED")
            return 0

        with tempfile.TemporaryDirectory(
            prefix="a0_prod_seam_p0_", dir="/tmp"
        ) as temporary:
            temp_root = Path(temporary)
            run_equivalence(temp_root)
            print(
                f"PROD_SEAM_P0_EQUIVALENCE_SCENARIO_COUNT="
                f"{len(RTL9D3_MARKERS)}"
            )
            print(
                f"PROD_SEAM_P0_EQUIVALENCE_TARGETED_"
                f"{len(RTL9D3_MARKERS)}=PASS"
            )
            print("PROD_SEAM_P0_CYCLE_EQUIVALENCE=PASS")
            require_containment(
                before,
                candidate_before,
                toolchain_before,
                "POST_EQUIVALENCE_CONTAINMENT",
            )

            run_lint_matrix(temp_root)
            print(
                f"PROD_SEAM_P0_PARAMETER_MATRIX_COUNT="
                f"{len(LINT_CONFIGURATIONS)}"
            )
            print("PROD_SEAM_P0_PARAMETER_MATRIX=PASS")
            print("PROD_SEAM_P0_LARGE_STRUCTURAL_64_CLIENT=PASS")
            require_containment(
                before,
                candidate_before,
                toolchain_before,
                "POST_PARAMETER_CONTAINMENT",
            )

            if arguments.targeted_only:
                print("PROD_SEAM_P0_P5_CLOSED_SOURCE_REGRESSION=NOT_RUN")
                print("PROD_SEAM_P0_FULL_RECURSIVE_GATE=NOT_RUN")
                print("PROD_SEAM_P0_TARGETED_QUALIFICATION=PASS")
            else:
                run_p5_projection(temp_root)
                print("PROD_SEAM_P0_P5_CLOSED_SOURCE_REGRESSION=PASS")
                print("PROD_SEAM_P0_FULL_RECURSIVE_GATE=PASS")
                require_containment(
                    before,
                    candidate_before,
                    toolchain_before,
                    "POST_FULL_GATE_CONTAINMENT",
                )

        print("PROD_SEAM_P0_POST_GATE_CONTAINMENT=PASS")
        print("PROD_SEAM_P0_TIMING=NOT_MEASURED")
        print("PROD_SEAM_P0_PPA=NOT_MEASURED")
        print("PROD_SEAM_P0_COHERENCE=NOT_IMPLEMENTED")
        print("PROD_SEAM_P0_PRODUCTION_WIRING=NOT_IMPLEMENTED")
        print("LIVE_REPO_MUTATION=NONE")
        print("COMMIT=NONE")
        print("PUSH=NOT_PERFORMED")
        if arguments.targeted_only:
            return 0
        print("PROD_SEAM_P0_CANDIDATE_QUALIFICATION=PASS")
        print("READY_FOR_PROD_SEAM_P0_FREEZE_REVIEW=YES")
        return 0
    except Failure as failure:
        live, commit, candidate = assess_failure(before, candidate_before)
        report_failure(
            failure,
            live_mutation=live,
            commit=commit,
            candidate_mutation=candidate,
        )
        return 1
    except Exception as exc:
        live, commit, candidate = assess_failure(before, candidate_before)
        report_failure(
            Failure(
                "UNEXPECTED_RUNNER_EXCEPTION",
                type(exc).__name__,
                observed=str(exc),
                cause="RUNNER_DEFECT",
            ),
            live_mutation=live,
            commit=commit,
            candidate_mutation=candidate,
        )
        return 1


if __name__ == "__main__":
    raise SystemExit(main())
