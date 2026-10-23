#!/usr/bin/python3
"""Canonical P32 ordered line progress qualification, isolated evidence only.

The fresh, hash-pinned P31 runner owns a separate strict toolchain and invokes
its unchanged P30/P27/P28/P29 chain. Re-audit those raw streams independently;
never add child calls to the P32 instrumentation domain. Emit final PASS only
after the complete checkpoint/raw-index containment context has exited.
"""
from __future__ import annotations

import sys
sys.dont_write_bytecode = True
import os
if sys.flags.optimize or os.environ.get("PYTHONOPTIMIZE"):
    raise SystemExit("PROD_SEAM_P32_FIRST_FAILURE STAGE=PYTHON_OPTIMIZATION_FORBIDDEN")

import importlib.util
import json
from pathlib import Path
import re
import resource
from types import SimpleNamespace

from p32_validation_support import (Qualification, ValidationFailure, STRICT_FLAGS,
                                    EXACT_VERSION, sha256)


ROOT = Path(__file__).resolve().parents[1]
HEAD = "996d8c188e5d4f94b4bad5289392844d55d092f6"
BRANCH = "main"
DIFF_SHA = "59fac4fc152cc4e46ed60bff0feecf700756d860ed4f44436f532a221570eb8b"
INDEX_SEMANTIC_SHA = "512cef8e2fac0b64a0dd049b69db09ea22b8cef76f74f05777f2aaa54816fbf5"
P31_RECEIPT = "EVIDENCE/P31/CANONICAL/p31-receipt.json"
P31_RECEIPT_SHA = "8876763d1159674883788ed6bc3bc6b41112596a2777651ef4a6086b898a7b5b"
LIVE_CONTAINMENT_POLICY = {
    "authorization": "USER_APPROVED_BOUNDED_CONTAINMENT_EXCEPTION_2026-09-14",
    "scope": "LIVE_PRE_POST_COMPARISON_ONLY",
    "excluded_descendant_prefixes": [".git/refs/codex/turn-diffs/"],
    "namespace_root_excluded": False,
    "other_git_paths_excluded": False,
    "isolated_checkpoint_exclusions": [],
    "frozen_predecessor_exclusions": [],
    "historical_evidence_rewritten": False,
    "refs_deleted_reset_or_rewritten_by_workflow": False,
    "strict_identities": ["source_tree", "HEAD", "branch", "raw_index_content",
                          "tracked_diff_sha256", "staged_state", "frozen_predecessors",
                          "isolated_checkpoint"],
}
# The isolated gate retains full containment. A separately evidenced live
# supervisor must complete before packaging; this constant is not a live PASS.
P31_OWN = {
    "docs/architecture/A0_PROD_SEAM_P31_SELECTIVE_STORE_RECOVERY.md": "10fded52669165245a4399498389f3f9f5f5e24394c8fff7b27085a523c3b544",
    "rtl/memory/a0_production_store_commit_selective_recovery_subsystem.sv": "0501608aad1ef653eaef1986e189bdae973c3d4aa99460f5c410cc2bdb43e26c",
    "rtl/memory/a0_store_attempt_generation_guard.sv": "08817a3356ed8c811f850576b7f50c842679f00363cadd35ecc8bfc470f652cf",
    "rtl/memory/a0_store_commit_recovery_frontend.sv": "9062f79ede7c92e111f060bbfa78cee2dbc87af8018a119990a6d2041c90cfc8",
    "tests/p31_validation_support.py": "a94dc20a4dd4852736856b2caf87a1a4946028916af385eb0fffac298aa19099",
    "tests/rtl/a0_production_store_commit_selective_recovery_store_tb.sv": "b16a58f7f4fab7d914b029b8ac98f36a23cc0a3b9f81d15dab5f43b22a449e0a",
    "tests/rtl/a0_production_store_commit_selective_recovery_subsystem_tb.sv": "33d81cbf081b0da511d6172c757ea904f66a6fe62021e037afeb4687aad2723d",
    "tests/run_prod_seam_p31.py": "f927d34a948c78f66c8d7c980416a2cfb24b245cf55e45cb814f4a0d530bffa1",
}
TOP = "a0_production_store_commit_ordered_progress_subsystem"
STORE_TOP = "a0_production_store_commit_ordered_progress_store_tb"
MEMORY_TOP = TOP + "_tb"
ORDER_TOP = "a0_p32_store_read_order_tb"
GUARD_TOP = "a0_store_read_resource_order_guard_tb"
NEW_RTL = ("a0_store_read_resource_order_guard.sv",
           "a0_store_commit_progress_frontend.sv", TOP + ".sv")
PARAMETER_NAMES = (
    "CLIENT_COUNT", "LOCAL_TAG_W", "CLIENT_MAX_OUTSTANDING", "COMMIT_PORT_COUNT",
    "STORE_LANES", "SLICE_COUNT", "LINE_WORDS", "SET_COUNT_PER_SLICE", "WRITE_ID_W",
    "MAX_WB_RETRIES", "STORE_WRITE_ID_W", "MAX_STORE_RETRIES",
    "STORE_STATUS_TIMEOUT_CYCLES", "STORE_GENERATION_W",
)
MATRIX = (
    ("ONE", (1, 1, 1, 1, 1, 1, 1, 1, 1, 0, 1, 0, 1, 1)),
    ("TWO", (2, 2, 2, 2, 4, 2, 4, 16, 4, 2, 4, 2, 4, 2)),
    ("WIDE", (4, 3, 4, 4, 8, 4, 8, 64, 8, 3, 8, 3, 17, 8)),
)
STORE_MARKERS = (
    "PROD_SEAM_P32_FIRST_RECOVERY_ALIAS_CONTAINED=PASS",
    "PROD_SEAM_P32_OTHER_PENDING_PORT_PRESERVED=PASS",
    "PROD_SEAM_P32_REPEATED_RECOVERY_HISTORY=PASS",
    "PROD_SEAM_P32_SAME_CYCLE_OLD_SUCCESS_FAILURE=PASS",
    "PROD_SEAM_P32_RETRY_BACKPRESSURE_PAYLOAD=PASS",
    "PROD_SEAM_P32_MULTILANE_SUCCESS_ONLY_RETIRE=PASS",
    "PROD_SEAM_P32_ABORT_CANCELS_ONLY_REMAINING_STORE_MISSES=PASS",
)
WRAP_MARKERS = ("PROD_SEAM_P32_TRUTHFUL_ALL_GENERATION_WRAP=PASS",)
DEADLINE_MARKERS = ("PROD_SEAM_P32_DEADLINE_PROVENANCE_AND_SAME_CYCLE_MATCH=PASS",)
MEMORY_MARKERS = (
    "PROD_SEAM_P32_DIRTY_SURVIVES_CACHED_READ_LATER_WB=PASS",
    "PROD_SEAM_P32_STALE_STORE_RESET_EDGE_CONTAINED=PASS",
    "PROD_SEAM_P32_READ_RESPONSE_ON_REARM_EDGE=PASS",
    "PROD_SEAM_P32_WB_STATUS_ON_REARM_EDGE=PASS",
    "PROD_SEAM_P32_HIDDEN_REPLACEMENT_READ_RESUMES=PASS",
    "PROD_SEAM_P32_CONCURRENT_READ_WB_STORE_RECOVERY=PASS",
    "PROD_SEAM_P32_PENDING_COMMIT_AND_RESET_EDGE_ADMISSION=PASS",
    "PROD_SEAM_P32_RECOVERY_BACKPRESSURE_FULL_TUPLE=PASS",
    "PROD_SEAM_P32_FRESH_STORE_ON_REARM_EDGE=PASS",
    "PROD_SEAM_P32_HELD_LINE_ACROSS_STORE_MISS=PASS",
    "PROD_SEAM_P32_READ_WB_PROGRESS_DURING_STORE_STATUS_WAIT=PASS",
    "PROD_SEAM_P32_WB_REFILL_PROGRESS_DURING_FAULT_BACKPRESSURE=PASS",
    "PROD_SEAM_P32_WB_REFILL_PROGRESS_DURING_REUSE_PROOF_WAIT=PASS",
    "PROD_SEAM_P32_MEMORY_END_TO_END=PASS",
)
MEMORY_WRAP_MARKERS = (
    "PROD_SEAM_P32_READ_WB_PROGRESS_DURING_GENERATION_WRAP=PASS",
    "PROD_SEAM_P32_MEMORY_WRAP_PASS stores=3 statuses=3 commits=4 reads=3 read_returns=3 "
    "wbs=1 wb_returns=1 clients=3 certificates=1 rearms=0",
)
ORDER_MARKERS = (
    "PROD_SEAM_P32_OLD_READ_BLOCKS_STORE_CLASSIFICATION=PASS",
    "PROD_SEAM_P32_SAME_EDGE_OLD_READ_COMPLETION_WAITS=PASS",
    "PROD_SEAM_P32_ORDERED_STORE_HIT_CACHED_NEW=PASS",
    "PROD_SEAM_P32_ALIAS_READ_WAITS_FOR_RAW_STORE=PASS",
    "PROD_SEAM_P32_EXACT_READ_WAITS_FOR_RAW_STORE=PASS",
    "PROD_SEAM_P32_ORDERED_DIRTY_WB_AND_EXTERNAL_REFILL=PASS",
    "PROD_SEAM_P32_STORE_READ_ORDER_END_TO_END=PASS",
)
GUARD_MARKERS = (
    "P32_ORDER_GUARD_READY_ZERO_PASS",
    "P32_ORDER_GUARD_OLD_READ_ALIAS_REGISTERED_RETIRE_PASS",
    "P32_ORDER_GUARD_ALL_RAW_PORTS_LANES_PASS",
    "P32_ORDER_GUARD_CLIENT_TAG_ISOLATION_PASS",
    "P32_ORDER_GUARD_BUSY_TAG_CAPACITY_PASS",
    "P32_ORDER_GUARD_SAME_EDGE_SLOT_TAG_REUSE_PASS",
    "P32_ORDER_GUARD_INVALID_RESPONSE_STICKY_PASS",
)
CASES = (
    ("store", ("-GMODE=0", "-GGEN=5", "-GMSR=2", "-GTO=64"), 0, STORE_MARKERS),
    ("wrap_gen1", ("-GMODE=1", "-GGEN=1"), 1, WRAP_MARKERS),
    ("wrap_gen2", ("-GMODE=1", "-GGEN=2"), 1, WRAP_MARKERS),
    ("wrap_gen3", ("-GMODE=1", "-GGEN=3"), 1, WRAP_MARKERS),
    ("deadline", ("-GMODE=2", "-GTO=1", "-GMSR=0", "-GGEN=5"), 2, DEADLINE_MARKERS),
)


def read_json(path):
    return json.loads(Path(path).read_text(encoding="utf-8"))


def frozen_guard(q, predecessor=None):
    # Pin the predecessor before importing any of its contracts. Importing the
    # reviewed module does not run main, tests, subprocesses or filesystem writes.
    for name, expected in P31_OWN.items():
        if sha256(ROOT / name) != expected:
            q.fail("FROZEN_P31_IDENTITY", name)
    receipt = q.checkpoint / P31_RECEIPT
    if sha256(receipt) != P31_RECEIPT_SHA:
        q.fail("FROZEN_P31_RECEIPT", str(receipt))
    if read_json(receipt).get("completed_stages", {}).get("p31_source_sha256") != P31_OWN:
        q.fail("FROZEN_P31_RECEIPT", "SOURCE_PIN_DISAGREEMENT")
    if sha256(ROOT / "tests/p32_validation_support.py") != P31_OWN["tests/p31_validation_support.py"]:
        q.fail("P32_SUPPORT_IDENTITY", "RENAMED_SUPPORT_MUST_BE_BYTE_IDENTICAL")
    if predecessor is None:
        spec = importlib.util.spec_from_file_location(
            "p32_frozen_p31_contract", ROOT / "tests/run_prod_seam_p31.py")
        if spec is None or spec.loader is None:
            q.fail("FROZEN_P31_CONTRACT", "IMPORT_SPEC_UNAVAILABLE")
        predecessor = importlib.util.module_from_spec(spec)
        spec.loader.exec_module(predecessor)
    frozen = predecessor.frozen_guard(q)
    return predecessor, frozen


def inherited_sources(q, predecessor, frozen):
    names = predecessor.literal_assignment(q, ROOT / "tests/run_prod_seam_p29.py", "NAMES")
    if (not isinstance(names, list) or len(names) != 19 or len(set(names)) != 19
            or any(not isinstance(name, str) or Path(name).name != name
                   or not name.endswith(".sv") for name in names)):
        q.fail("SOURCE_LIST", "P29_NAMES_CONTRACT")
    if any("A0-GPU/rtl/memory/" + name not in frozen for name in names):
        q.fail("SOURCE_LIST", "UNFROZEN_P29_SOURCE")
    # Preserve P24 cache/fabric/READ/WB, standalone STORE completion/timeout,
    # and the exact P31 global-reset-only generation guard.
    selected = names[:12] + ["a0_store_word_completion_guard.sv",
                             "a0_store_word_status_timeout_guard.sv",
                             "a0_store_attempt_generation_guard.sv"] + list(NEW_RTL)
    if len(selected) != 18 or len(set(selected)) != 18:
        q.fail("SOURCE_LIST", "P32_EXPECTS_18_UNIQUE_RTL_SOURCES")
    return [ROOT / "rtl/memory" / name for name in selected]


def own_sources():
    paths = [Path(__file__).resolve(), ROOT / "tests/p32_validation_support.py",
             *(ROOT / "rtl/memory" / name for name in NEW_RTL),
             *(ROOT / "tests/rtl" / (top + ".sv")
               for top in (STORE_TOP, MEMORY_TOP, ORDER_TOP, GUARD_TOP)),
             ROOT / "docs/architecture/A0_PROD_SEAM_P32_ORDERED_LINE_PROGRESS.md"]
    return {str(path.relative_to(ROOT)): sha256(path) for path in paths}


def git_guard(q, phase):
    def git(arguments, suffix):
        return q.run(["/usr/bin/git", "-c", "diff.autoRefreshIndex=false", *arguments],
                     phase + "_git_" + suffix, timeout=30)
    head = git(["rev-parse", "HEAD"], "head").stdout.strip()
    if head != HEAD:
        q.fail("REPOSITORY_HEAD", head)
    branch = git(["branch", "--show-current"], "branch").stdout.strip()
    if branch != BRANCH:
        q.fail("REPOSITORY_BRANCH", branch)
    git(["diff", "--check"], "diffcheck")
    diff = git(["diff", "--binary"], "diff")
    if sha256(diff.log) != DIFF_SHA:
        q.fail("REPOSITORY_TRACKED_DIFF", sha256(diff.log))
    staged = git(["diff", "--cached", "--name-status"], "staged")
    if staged.stdout:
        q.fail("REPOSITORY_INDEX_DIRTY", staged.stdout)
    index = git(["ls-files", "--stage", "-z"], "index_semantics")
    if sha256(index.log) != INDEX_SEMANTIC_SHA:
        q.fail("REPOSITORY_INDEX_IDENTITY", sha256(index.log))
    raw_index = ROOT / ".git/index"
    if raw_index.read_bytes() != q.index_before:
        q.fail("REPOSITORY_RAW_INDEX", "CHANGED_SINCE_CONTEXT_ENTRY")
    actual = {"head": head, "branch": branch, "tracked_diff_sha256": sha256(diff.log),
              "index_semantic_sha256": sha256(index.log), "raw_index_sha256": sha256(raw_index),
              "staged_changes": staged.stdout}
    q._json(phase + "-git-identity.json", actual)
    return actual


def markers_in_log(q, path, markers, *, mode=None, parameters=()):
    lines = path.read_text(encoding="utf-8").splitlines()
    invalid = [marker for marker in markers if lines.count(marker) != 1]
    if not markers or invalid:
        q.fail("BEHAVIOR_MARKERS", "EMPTY_MISSING_OR_DUPLICATE:" + json.dumps(invalid)
               + "; raw_log=" + str(path))
    summary = None
    if mode is not None:
        pattern = re.compile(r"PROD_SEAM_P32_STORE_BEHAVIOR=PASS mode=(\d+) "
                             r"issues=(\d+) success=(\d+) abort=(\d+) rearm=(\d+)")
        summaries = [match for line in lines if (match := pattern.fullmatch(line)) is not None]
        if len(summaries) != 1 or int(summaries[0].group(1)) != mode:
            q.fail("BEHAVIOR_SUMMARY", "MISSING_OR_AMBIGUOUS_STORE_SUMMARY; raw_log=" + str(path))
        counts = list(map(int, summaries[0].groups()))
        summary = dict(zip(("mode", "issues", "success", "abort", "rearm"), counts))
        if mode == 0:
            expected = [0, 11, 6, 3, 3]
        elif mode == 2:
            expected = [2, 5, 3, 2, 2]
        else:
            generations = [int(arg.removeprefix("-GGEN=")) for arg in parameters
                           if arg.startswith("-GGEN=")]
            if len(generations) != 1 or generations[0] not in (1, 2, 3):
                q.fail("BEHAVIOR_SUMMARY", "WRAP_GENERATION_PARAMETER_IDENTITY")
            successes = (1 << generations[0]) + 1
            expected = [1, successes, successes, 0, 0]
        if counts != expected:
            q.fail("BEHAVIOR_SUMMARY", "EXACT_EVENT_COUNTS expected=" + str(expected)
                   + "; observed=" + str(counts) + "; raw_log=" + str(path))
    return {"raw_log": str(path), "raw_log_sha256": sha256(path),
            "required_markers": list(markers), "summary": summary,
            "parameters": list(parameters)}


def guard_summary(q, path):
    pattern = re.compile(r"P32_ORDER_GUARD_PASS scenarios=(\d+) checks=(\d+) accepts=(\d+) "
                         r"responses=(\d+) rejected_responses=(\d+)")
    rows = [list(map(int, match.groups())) for line in path.read_text(encoding="utf-8").splitlines()
            if (match := pattern.fullmatch(line)) is not None]
    if rows != [[7, 40, 10, 10, 2]]:
        q.fail("GUARD_BEHAVIOR_SUMMARY", "EXACT_NONVACUOUS_COUNTS:" + json.dumps(rows))
    return dict(zip(("scenarios", "checks", "accepts", "responses", "rejected_responses"), rows[0]))


def order_summary(q, path):
    pattern = re.compile(r"P32_ORDER_CASE_DRAINED case=(\d+) clients=(\d+) reads=(\d+) "
                         r"read_returns=(\d+) wbs=(\d+) wb_statuses=(\d+) stores=(\d+) commits=(\d+)")
    rows = [list(map(int, match.groups())) for line in path.read_text(encoding="utf-8").splitlines()
            if (match := pattern.fullmatch(line)) is not None]
    expected = [[1, 4, 3, 3, 1, 1, 0, 1], [2, 3, 3, 3, 1, 1, 0, 1], [3, 4, 3, 3, 1, 1, 0, 1]]
    if rows != expected:
        q.fail("ORDER_BEHAVIOR_SUMMARY", "EXACT_DRAINED_CASE_COUNTS:" + json.dumps(rows))
    names = ("case", "clients", "reads", "read_returns", "wbs", "wb_statuses", "stores", "commits")
    return [dict(zip(names, row)) for row in rows]


def memory_wrap_summary(q, path):
    pattern = re.compile(r"PROD_SEAM_P32_MEMORY_WRAP_PASS stores=(\d+) statuses=(\d+) commits=(\d+) "
                         r"reads=(\d+) read_returns=(\d+) wbs=(\d+) wb_returns=(\d+) clients=(\d+) "
                         r"certificates=(\d+) rearms=(\d+)")
    rows = [list(map(int, match.groups())) for line in path.read_text(encoding="utf-8").splitlines()
            if (match := pattern.fullmatch(line)) is not None]
    if rows != [[3, 3, 4, 3, 3, 1, 1, 3, 1, 0]]:
        q.fail("MEMORY_WRAP_BEHAVIOR_SUMMARY", "EXACT_DRAINED_COUNTS:" + json.dumps(rows))
    names = ("stores", "statuses", "commits", "reads", "read_returns", "wbs", "wb_returns",
             "clients", "certificates", "rearms")
    return dict(zip(names, rows[0]))


def audit_fresh_p31(q, result, predecessor, frozen, pre_identity):
    lines = result.stdout.splitlines()
    required = ("PROD_SEAM_P31_GATE=PASS", "PROD_SEAM_P31_POST_CONTAINMENT=PASS",
                "PROD_SEAM_P31_RAW_INDEX_IDENTICAL=PASS",
                "PROD_SEAM_P31_P30_PREDECESSOR=PASS mode=fresh-unchanged-canonical-runner",
                "PROD_SEAM_P31_P27_P28_P29_CHAIN=PASS mode=fresh-via-P30")
    for marker in required:
        if lines.count(marker) != 1:
            q.fail("P31_FRESH_RESULT", "MISSING_OR_DUPLICATE:" + marker)
    work_values = [line.removeprefix("VALIDATION_WORK=") for line in lines if line.startswith("VALIDATION_WORK=")]
    receipt_values = [line.removeprefix("PROD_SEAM_P31_RECEIPT=") for line in lines
                      if line.startswith("PROD_SEAM_P31_RECEIPT=")]
    if len(work_values) != 1 or len(receipt_values) != 1:
        q.fail("P31_FRESH_RESULT", "WORK_OR_RECEIPT_NOT_UNIQUE")
    work = Path(work_values[0])
    if (work.parent != Path("/tmp") or not work.name.startswith("a0_p30_p31_gate_")
            or work.is_symlink() or work.resolve(strict=True) != work or work == q.work):
        q.fail("P31_FRESH_RESULT", "UNEXPECTED_CHILD_WORK:" + str(work))
    receipt_path = work / "p31-receipt.json"
    if Path(receipt_values[0]) != receipt_path:
        q.fail("P31_FRESH_RESULT", "RECEIPT_OUTSIDE_CHILD_WORK")
    receipt = read_json(receipt_path)
    summary, containment = read_json(work / "summary.json"), read_json(work / "containment.json")
    completed = read_json(work / "p31-completed-stages.json")
    if (receipt.get("gate") != "PROD_SEAM_P31_GATE=PASS" or receipt.get("summary") != summary
            or receipt.get("containment") != containment or receipt.get("completed_stages") != completed
            or summary.get("first_failure") is not None or summary.get("secondary_errors") != []
            or summary.get("strict_verified") is not True or summary.get("checkpoint") != str(q.checkpoint)
            or summary.get("work") != str(work)
            or containment != {"added": [], "changed": [], "removed": [],
                               "raw_index_identical": True, "unchanged": True}):
        q.fail("P31_FRESH_AUDIT", "RECEIPT_SUMMARY_OR_CONTAINMENT")
    if (read_json(work / "checkpoint-before.json") != q.before
            or read_json(work / "checkpoint-after.json") != q.before
            or (work / "index-before.raw").read_bytes() != q.index_before):
        q.fail("P31_FRESH_AUDIT", "FULL_CHECKPOINT_OR_RAW_INDEX_MISMATCH")
    if (completed.get("pre_identity") != pre_identity or completed.get("post_identity") != pre_identity
            or completed.get("p31_source_sha256") != P31_OWN
            or completed.get("frozen_p30_source_sha256") != predecessor.P30_OWN
            or completed.get("frozen_predecessor_sha256") != frozen
            or completed.get("rtl_source_count") != 17):
        q.fail("P31_FRESH_AUDIT", "SOURCE_OR_GIT_IDENTITY")
    commands = predecessor.command_records(q, work, expected_count=35)
    if completed.get("commands") != commands:
        q.fail("P31_FRESH_AUDIT", "RAW_COMMAND_RECORD_DISAGREEMENT")
    if (work / "001_version.log").read_text(encoding="utf-8").strip() != EXACT_VERSION:
        q.fail("P31_FRESH_VERSION", str(work / "001_version.log"))
    outer = q._strict_rows(work / "strict-outer.jsonl", outer=True)
    inner = q._strict_rows(work / "strict-inner.jsonl", outer=False)
    count_elab = lambda rows: sum("--lint-only" in row["forwarded"] or "--cc" in row["forwarded"] for row in rows)
    strict = {"outer_calls": len(outer), "inner_calls": len(inner),
              "outer_elaborations": count_elab(outer), "inner_elaborations": count_elab(inner),
              "outer_stripped_count": 0, "inner_stripped_count": 0}
    if (strict != completed.get("strict") or strict != {
            "outer_calls": 10, "inner_calls": 40, "outer_elaborations": 9,
            "inner_elaborations": 9, "outer_stripped_count": 0, "inner_stripped_count": 0}):
        q.fail("P31_FRESH_STRICT", json.dumps(strict, sort_keys=True))

    def check_raw(row):
        path = Path(row.get("raw_log", ""))
        if (path.parent != work or path.name not in commands
                or row.get("raw_log_sha256") != commands[path.name]["raw_log_sha256"]):
            q.fail("P31_FRESH_RAW_REFERENCE", json.dumps(row, sort_keys=True))
        return path

    if len(completed.get("matrix", [])) != 3:
        q.fail("P31_FRESH_MATRIX", "EXPECTED_THREE_VARIANTS")
    for row, (name, values) in zip(completed["matrix"], predecessor.MATRIX):
        if row.get("variant") != name or row.get("parameters") != dict(zip(predecessor.PARAMETER_NAMES, values)):
            q.fail("P31_FRESH_MATRIX", "PARAMETER_IDENTITY")
        check_raw(row)
    behavior = completed.get("behavior", {})
    if set(behavior) != {"store", "wrap_gen1", "wrap_gen2", "wrap_gen3", "deadline", "memory"}:
        q.fail("P31_FRESH_BEHAVIOR", "EXPECTED_SIX_SIMULATIONS")
    for name, parameters, mode, markers in predecessor.CASES:
        actual = predecessor.markers_in_log(q, check_raw(behavior[name]), markers, mode=mode)
        actual["parameters"] = list(parameters)
        if behavior[name] != actual:
            q.fail("P31_FRESH_BEHAVIOR", "RAW_CONTRACT_DISAGREEMENT:" + name)
    actual = predecessor.markers_in_log(q, check_raw(behavior["memory"]), predecessor.MEMORY_MARKERS)
    if behavior["memory"] != actual:
        q.fail("P31_FRESH_BEHAVIOR", "RAW_MEMORY_CONTRACT_DISAGREEMENT")

    child = completed.get("p30_predecessor", {})
    child_log = check_raw(child)
    if (commands[child_log.name]["command"] != ["/usr/bin/python3", "-u", str(ROOT / "tests/run_prod_seam_p30.py")]
            or child.get("rc") != 0 or child.get("mode") != "fresh-unchanged-canonical-runner"):
        q.fail("P31_FRESH_CHAIN", "P30_RUNNER_COMMAND_IDENTITY")
    # Re-run the hash-pinned P31 auditor, not P30 itself: it validates the fresh
    # P30 raw receipt, all 37 commands, 25/100 strict calls, and P27/P28/P29 runs.
    audited_child = predecessor.audit_fresh_p30(q, SimpleNamespace(
        stdout=child_log.read_text(encoding="utf-8"), log=child_log, rc=0), frozen)
    if child != audited_child:
        q.fail("P31_FRESH_CHAIN", "INDEPENDENT_P30_RAW_AUDIT_DISAGREEMENT")
    names = ("p31-receipt.json", "p31-completed-stages.json", "summary.json", "containment.json",
             "checkpoint-before.json", "checkpoint-after.json", "index-before.raw",
             "strict-outer.jsonl", "strict-inner.jsonl", "strict-policy.json", "toolchain-provenance.json")
    return {"mode": "fresh-unchanged-canonical-runner", "raw_log": str(result.log),
            "raw_log_sha256": sha256(result.log), "rc": result.rc, "work": str(work),
            "receipt": str(receipt_path), "receipt_sha256": sha256(receipt_path),
            "artifact_sha256": {name: sha256(work / name) for name in names},
            "commands": commands, "strict": strict, "p30_predecessor": audited_child,
            "containment": containment, "frozen_p31_receipt_sha256": P31_RECEIPT_SHA}


def main():
    resource.setrlimit(resource.RLIMIT_CORE, (0, 0))
    q = Qualification(checkpoint=ROOT.parent, label="p32_gate")
    try:
        with q:
            predecessor, frozen = frozen_guard(q)
            own_before = own_sources()
            if len(own_before) != 10:
                q.fail("P32_SOURCE_IDENTITY", "EXPECTED_TEN_SUCCESSOR_FILES")
            q._json("p32-source-identities-before.json", own_before)
            q.bootstrap()
            pre_identity = git_guard(q, "pre")
            sources = inherited_sources(q, predecessor, frozen)
            matrix_results = []
            for name, values in MATRIX:
                parameters = [f"-G{key}={value}" for key, value in zip(PARAMETER_NAMES, values)]
                result = q.verilator([*STRICT_FLAGS, "--lint-only", "--top-module", TOP,
                                      "--Mdir", q.work / ("lint_" + name.lower()), *parameters, *sources],
                                     "matrix_" + name.lower())
                matrix_results.append({"variant": name, "parameters": dict(zip(PARAMETER_NAMES, values)),
                                       "raw_log": str(result.log), "raw_log_sha256": sha256(result.log)})
            behavior = {}
            for name, parameters, mode, markers in CASES:
                binary = q.build_simulation(STORE_TOP,
                    sources + [ROOT / "tests/rtl" / (STORE_TOP + ".sv")], name=name, parameters=parameters)
                result = q.run([binary], name + "_sim", cwd=q.work, timeout=120)
                behavior[name] = markers_in_log(q, result.log, markers, mode=mode, parameters=parameters)
            for name, top, parameters, markers, selected in (
                    ("memory", MEMORY_TOP, (), MEMORY_MARKERS, sources),
                    ("memorywrap", MEMORY_TOP, ("-GMODE=1", "-GGEN=1"), MEMORY_WRAP_MARKERS, sources),
                    ("order", ORDER_TOP, (), ORDER_MARKERS, sources),
                    ("guard", GUARD_TOP, (), GUARD_MARKERS,
                     [ROOT / "rtl/memory/a0_store_read_resource_order_guard.sv"])):
                binary = q.build_simulation(top,
                    selected + [ROOT / "tests/rtl" / (top + ".sv")], name=name, parameters=parameters)
                result = q.run([binary], name + "_sim", cwd=q.work, timeout=120)
                behavior[name] = markers_in_log(q, result.log, markers, parameters=parameters)
                if name == "guard":
                    behavior[name]["summary"] = guard_summary(q, result.log)
                elif name == "order":
                    behavior[name]["summary"] = order_summary(q, result.log)
                elif name == "memorywrap":
                    behavior[name]["summary"] = memory_wrap_summary(q, result.log)
            predecessor_result = q.run(["/usr/bin/python3", "-u", ROOT / "tests/run_prod_seam_p31.py"],
                                       "p31_canonical", timeout=9000, reject_diagnostics=True)
            predecessor_audit = audit_fresh_p31(q, predecessor_result, predecessor, frozen, pre_identity)
            frozen_guard(q, predecessor)
            if own_sources() != own_before:
                q.fail("P32_SOURCE_IDENTITY", "OWN_SOURCE_CHANGED_DURING_QUALIFICATION")
            post_identity = git_guard(q, "post")
            if post_identity != pre_identity:
                q.fail("P32_REPOSITORY_IDENTITY", "PRE_POST_MISMATCH")
            strict = q.assert_strict(minimum_elaborations=12)
            if strict != {"outer_calls": 13, "inner_calls": 52, "outer_elaborations": 12,
                          "inner_elaborations": 12, "outer_stripped_count": 0, "inner_stripped_count": 0}:
                q.fail("P32_STRICT_CALL_ACCOUNTING", json.dumps(strict, sort_keys=True))
            commands = predecessor.command_records(q, q.work, expected_count=44)
            completed = {"matrix": matrix_results, "behavior": behavior, "p31_predecessor": predecessor_audit,
                         "strict": strict, "commands": commands, "pre_identity": pre_identity,
                         "post_identity": post_identity, "p32_source_sha256": own_before,
                         "frozen_p31_source_sha256": P31_OWN, "frozen_predecessor_sha256": frozen,
                         "live_containment_policy": LIVE_CONTAINMENT_POLICY,
                         "live_containment_execution": "EXTERNAL_BOUNDED_SUPERVISOR_REQUIRED",
                         "rtl_source_count": len(sources)}
            q._json("p32-completed-stages.json", completed)

        summary = read_json(q.work / "summary.json")
        containment = read_json(q.work / "containment.json")
        if (summary.get("first_failure") is not None or summary.get("secondary_errors") != []
                or summary.get("strict_verified") is not True
                or containment != {"added": [], "changed": [], "removed": [],
                                   "raw_index_identical": True, "unchanged": True}
                or own_sources() != own_before):
            raise ValidationFailure("FINAL_AUDIT", "SUMMARY_CONTAINMENT_OR_OWN_SOURCE_MISMATCH")
        receipt = q._json("p32-receipt.json", {"gate": "PROD_SEAM_P32_GATE=PASS",
                            "completed_stages": completed, "containment": containment, "summary": summary})
        print("PROD_SEAM_P32_EXACT_VERILATOR_5_050=PASS")
        print("PROD_SEAM_P32_STRICT_LINT=PASS")
        print("PROD_SEAM_P32_PARAMETER_MATRIX=PASS variants=3")
        print("PROD_SEAM_P32_BEHAVIOR=PASS simulations=" + str(len(behavior)))
        print("PROD_SEAM_P32_P31_PREDECESSOR=PASS mode=fresh-unchanged-canonical-runner")
        print("PROD_SEAM_P32_P30_P27_P28_P29_CHAIN=PASS mode=fresh-via-P31")
        print("PROD_SEAM_P32_OUTER_STRICT_CALLS=" + str(strict["outer_calls"]))
        print("PROD_SEAM_P32_INNER_STRICT_CALLS=" + str(strict["inner_calls"]))
        print("PROD_SEAM_P32_STRICT_ELABORATIONS=" + str(strict["inner_elaborations"]))
        print("PROD_SEAM_P32_OUTER_STRICT_LEAK=" + str(strict["outer_stripped_count"]))
        print("PROD_SEAM_P32_INNER_STRICT_LEAK=" + str(strict["inner_stripped_count"]))
        print("PROD_SEAM_P32_CHILD_P31_OUTER_STRICT_CALLS=" + str(predecessor_audit["strict"]["outer_calls"]))
        print("PROD_SEAM_P32_CHILD_P31_INNER_STRICT_CALLS=" + str(predecessor_audit["strict"]["inner_calls"]))
        nested = predecessor_audit["p30_predecessor"]["strict"]
        print("PROD_SEAM_P32_NESTED_P30_OUTER_STRICT_CALLS=" + str(nested["outer_calls"]))
        print("PROD_SEAM_P32_NESTED_P30_INNER_STRICT_CALLS=" + str(nested["inner_calls"]))
        print("PROD_SEAM_P32_POST_CONTAINMENT=PASS")
        print("PROD_SEAM_P32_RAW_INDEX_IDENTICAL=PASS")
        print("PROD_SEAM_P32_RECEIPT=" + str(receipt))
        print("PROD_SEAM_P32_GATE=PASS")
        return 0
    except BaseException as error:
        failure = q._first_failure or {
            "stage": getattr(error, "stage", "EXCEPTION"),
            "detail": getattr(error, "detail", repr(error)), "rc": getattr(error, "rc", 1),
        }
        print("PROD_SEAM_P32_FIRST_FAILURE", file=sys.stderr)
        print("STAGE=" + failure["stage"], file=sys.stderr)
        print("DETAIL=" + failure["detail"], file=sys.stderr)
        print("RAW_EXIT_CODE=" + str(failure["rc"]), file=sys.stderr)
        if q.work is not None:
            print("RAW_EVIDENCE=" + str(q.work), file=sys.stderr)
        rc = failure["rc"]
        return rc if 0 < rc < 256 else (128 - rc if -127 <= rc < 0 else 1)


if __name__ == "__main__":
    raise SystemExit(main())
