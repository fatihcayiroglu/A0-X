#!/usr/bin/python3
"""Canonical P31 selective STORE recovery qualification, isolated evidence only.

Install beside the byte-identical, renamed p31_validation_support.py. A fresh
unchanged P30 runner owns a separate strict toolchain/log stream; its receipt,
raw commands, strict boundaries and P27/P28/P29 runs are independently audited.
No milestone PASS is emitted until the outer context's final containment exits.
"""
from __future__ import annotations

import sys
sys.dont_write_bytecode = True
import os
if sys.flags.optimize or os.environ.get("PYTHONOPTIMIZE"):
    raise SystemExit("PROD_SEAM_P31_FIRST_FAILURE STAGE=PYTHON_OPTIMIZATION_FORBIDDEN")

import ast
import json
from pathlib import Path
import re
import resource

from p31_validation_support import (Qualification, ValidationFailure, STRICT_FLAGS,
                                    EXACT_VERSION, sha256)


ROOT = Path(__file__).resolve().parents[1]
HEAD = "996d8c188e5d4f94b4bad5289392844d55d092f6"
BRANCH = "main"
DIFF_SHA = "59fac4fc152cc4e46ed60bff0feecf700756d860ed4f44436f532a221570eb8b"
INDEX_SEMANTIC_SHA = "512cef8e2fac0b64a0dd049b69db09ea22b8cef76f74f05777f2aaa54816fbf5"
P30_RECEIPT = "EVIDENCE/P30/CANONICAL/p30-receipt.json"
P30_RECEIPT_SHA = "215d54dfc507b8b971aef722cf105f6cb78911704ce6233f11c0575095f99bd7"
P30_OWN = {
    "docs/architecture/A0_PROD_SEAM_P30_GENERATION_IDENTITY.md": "a03310b41a807b2a430a3fefea9edd1745a77593ded5f33b89f4939e9898c9ae",
    "rtl/memory/a0_production_store_commit_generation_subsystem.sv": "46b79d11d7c034390c15644318585ca40d0304f9019f1e90fa6d505b29f3e8ac",
    "tests/p30_validation_support.py": "a94dc20a4dd4852736856b2caf87a1a4946028916af385eb0fffac298aa19099",
    "tests/rtl/a0_production_store_commit_generation_memory_tb.sv": "2a839d255e84a3420af8ffd1f56367f4945b9a7bb004cc62f86e5d2348a0aa03",
    "tests/rtl/a0_production_store_commit_generation_tb.sv": "9c356a4cd3032d22faf6806a3cf6ade75b32dc965fb3d97ff364cea0595ec039",
    "tests/run_prod_seam_p30.py": "37bfc32fa80a58a9c707f53dfbf0bc446f1c5a6ffebce61f7cd5f7e1137c10c0",
}
TOP = "a0_production_store_commit_selective_recovery_subsystem"
STORE_TOP = "a0_production_store_commit_selective_recovery_store_tb"
MEMORY_TOP = TOP + "_tb"
NEW_RTL = ("a0_store_attempt_generation_guard.sv",
           "a0_store_commit_recovery_frontend.sv", TOP + ".sv")
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
    "PROD_SEAM_P31_FIRST_RECOVERY_ALIAS_CONTAINED=PASS",
    "PROD_SEAM_P31_OTHER_PENDING_PORT_PRESERVED=PASS",
    "PROD_SEAM_P31_REPEATED_RECOVERY_HISTORY=PASS",
    "PROD_SEAM_P31_SAME_CYCLE_OLD_SUCCESS_FAILURE=PASS",
    "PROD_SEAM_P31_RETRY_BACKPRESSURE_PAYLOAD=PASS",
    "PROD_SEAM_P31_MULTILANE_SUCCESS_ONLY_RETIRE=PASS",
    "PROD_SEAM_P31_ABORT_CANCELS_ONLY_REMAINING_STORE_MISSES=PASS",
)
WRAP_MARKERS = ("PROD_SEAM_P31_TRUTHFUL_ALL_GENERATION_WRAP=PASS",)
DEADLINE_MARKERS = ("PROD_SEAM_P31_DEADLINE_PROVENANCE_AND_SAME_CYCLE_MATCH=PASS",)
MEMORY_MARKERS = (
    "PROD_SEAM_P31_DIRTY_SURVIVES_CACHED_READ_LATER_WB=PASS",
    "PROD_SEAM_P31_STALE_STORE_RESET_EDGE_CONTAINED=PASS",
    "PROD_SEAM_P31_READ_RESPONSE_ON_REARM_EDGE=PASS",
    "PROD_SEAM_P31_WB_STATUS_ON_REARM_EDGE=PASS",
    "PROD_SEAM_P31_HIDDEN_REPLACEMENT_READ_RESUMES=PASS",
    "PROD_SEAM_P31_CONCURRENT_READ_WB_STORE_RECOVERY=PASS",
    "PROD_SEAM_P31_PENDING_COMMIT_AND_RESET_EDGE_ADMISSION=PASS",
    "PROD_SEAM_P31_RECOVERY_BACKPRESSURE_FULL_TUPLE=PASS",
    "PROD_SEAM_P31_FRESH_STORE_ON_REARM_EDGE=PASS",
    "PROD_SEAM_P31_HELD_LINE_ACROSS_STORE_MISS=PASS",
    "PROD_SEAM_P31_MEMORY_END_TO_END=PASS",
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


def literal_assignment(q, path, name):
    tree = ast.parse(path.read_text(encoding="utf-8"))
    values = [node.value for node in tree.body if isinstance(node, ast.Assign)
              and any(isinstance(target, ast.Name) and target.id == name for target in node.targets)]
    if len(values) != 1:
        q.fail("FROZEN_CONTRACT", str(path) + ":ASSIGNMENT_NOT_UNIQUE:" + name)
    return ast.literal_eval(values[0])


def frozen_guard(q):
    # The hash pin is checked before parsing any predecessor source contract.
    for name, expected in P30_OWN.items():
        if sha256(ROOT / name) != expected:
            q.fail("FROZEN_P30_IDENTITY", name)
    receipt = q.checkpoint / P30_RECEIPT
    if sha256(receipt) != P30_RECEIPT_SHA:
        q.fail("FROZEN_P30_RECEIPT", str(receipt))
    frozen = literal_assignment(q, ROOT / "tests/run_prod_seam_p30.py", "FROZEN")
    if not isinstance(frozen, dict) or len(frozen) != 31:
        q.fail("FROZEN_PREDECESSOR_SET", "EXPECTED_31_PINNED_P30_PREDECESSOR_ARTIFACTS")
    for name, expected in frozen.items():
        relative = Path(name)
        if (relative.is_absolute() or ".." in relative.parts
                or not re.fullmatch(r"[0-9a-f]{64}", expected)):
            q.fail("FROZEN_PREDECESSOR_SET", "UNSAFE_RECORD:" + name)
        if sha256(q.checkpoint / relative) != expected:
            q.fail("FROZEN_PREDECESSOR_IDENTITY", name)
    if sha256(ROOT / "tests/p31_validation_support.py") != P30_OWN["tests/p30_validation_support.py"]:
        q.fail("P31_SUPPORT_IDENTITY", "RENAMED_SUPPORT_MUST_BE_BYTE_IDENTICAL")
    return frozen


def inherited_sources(q, frozen):
    names = literal_assignment(q, ROOT / "tests/run_prod_seam_p29.py", "NAMES")
    if (not isinstance(names, list) or len(names) != 19 or len(set(names)) != 19
            or any(not isinstance(name, str) or Path(name).name != name
                   or not name.endswith(".sv") for name in names)):
        q.fail("SOURCE_LIST", "P29_NAMES_CONTRACT")
    if any("A0-GPU/rtl/memory/" + name not in frozen for name in names):
        q.fail("SOURCE_LIST", "UNFROZEN_P29_SOURCE")
    # P24 persistent cache/fabric/READ/WB composition plus only the standalone
    # STORE completion and timeout guards: no P25/P26/P29 recovery wrapper reset.
    selected = names[:12] + ["a0_store_word_completion_guard.sv",
                             "a0_store_word_status_timeout_guard.sv"] + list(NEW_RTL)
    if len(selected) != 17 or len(set(selected)) != 17:
        q.fail("SOURCE_LIST", "P31_EXPECTS_17_UNIQUE_RTL_SOURCES")
    return [ROOT / "rtl/memory" / name for name in selected]


def own_sources():
    paths = [Path(__file__).resolve(), ROOT / "tests/p31_validation_support.py",
             *(ROOT / "rtl/memory" / name for name in NEW_RTL),
             ROOT / "tests/rtl" / (STORE_TOP + ".sv"),
             ROOT / "tests/rtl" / (MEMORY_TOP + ".sv"),
             ROOT / "docs/architecture/A0_PROD_SEAM_P31_SELECTIVE_STORE_RECOVERY.md"]
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


def markers_in_log(q, path, markers, *, mode=None, milestone=31):
    lines = path.read_text(encoding="utf-8").splitlines()
    invalid = [marker for marker in markers if lines.count(marker) != 1]
    if invalid:
        q.fail("BEHAVIOR_MARKERS", "MISSING_OR_DUPLICATE:" + json.dumps(invalid) + "; raw_log=" + str(path))
    summary = None
    if mode is not None:
        pattern = re.compile(r"PROD_SEAM_P" + str(milestone) + r"_STORE_BEHAVIOR=PASS mode=(\d+) "
                             r"issues=(\d+) success=(\d+) abort=(\d+) rearm=(\d+)")
        summaries = [match for line in lines if (match := pattern.fullmatch(line)) is not None]
        if len(summaries) != 1 or int(summaries[0].group(1)) != mode:
            q.fail("BEHAVIOR_SUMMARY", "MISSING_OR_AMBIGUOUS_STORE_SUMMARY; raw_log=" + str(path))
        counts = list(map(int, summaries[0].groups()))
        summary = dict(zip(("mode", "issues", "success", "abort", "rearm"), counts))
        if counts[1] < 1 or counts[2] < 1 or counts[3] != counts[4]:
            q.fail("BEHAVIOR_SUMMARY", "VACUOUS_TRAFFIC_OR_ABORT_REARM_MISMATCH; raw_log=" + str(path))
        expected_recoveries = 3 if milestone == 31 and mode == 0 else 2
        if mode in (0, 2) and counts[3] != expected_recoveries:
            q.fail("BEHAVIOR_SUMMARY", f"EXPECTED_{expected_recoveries}_REAL_RECOVERIES; raw_log=" + str(path))
        if mode == 1 and counts[3] != 0:
            q.fail("BEHAVIOR_SUMMARY", "UNEXPECTED_WRAP_ABORT; raw_log=" + str(path))
    return {"raw_log": str(path), "raw_log_sha256": sha256(path),
            "required_markers": list(markers), "summary": summary}


def command_records(q, work, *, expected_count):
    """Validate every raw command record, not a printed zero-exit summary."""
    records = {}
    for path in sorted(work.glob("[0-9][0-9][0-9]_*.json")):
        metadata = read_json(path)
        if "command" not in metadata:  # Separate strict-verification records.
            if not path.name.endswith("_strict-verification.json"):
                q.fail("RAW_COMMAND_AUDIT", "UNEXPECTED_NON_COMMAND_RECORD:" + str(path))
            continue
        raw_log = Path(metadata.get("raw_log", ""))
        if (raw_log != path.with_suffix(".log") or raw_log.is_symlink()
                or raw_log.resolve(strict=True).parent != work):
            q.fail("RAW_COMMAND_AUDIT", "RAW_LOG_CONTAINMENT:" + str(path))
        if (metadata.get("rc") != 0 or metadata.get("timed_out") is not False
                or metadata.get("interrupted") is not False
                or metadata.get("lifecycle", {}).get("group_gone") is not True
                or metadata.get("lifecycle", {}).get("group_existed_after_wait") is not False
                or sha256(raw_log) != metadata.get("raw_log_sha256")):
            q.fail("RAW_COMMAND_AUDIT", "EXIT_LIFECYCLE_OR_HASH:" + str(path))
        argv = metadata["command"]
        if not isinstance(argv, list) or not argv or any(not isinstance(arg, str) for arg in argv):
            q.fail("RAW_COMMAND_AUDIT", "MALFORMED_ARGV:" + str(path))
        # Git's tracked diff is source text and can legitimately contain the
        # words warning/error. Diagnostic rejection applies to executed tools.
        if argv[0] != "/usr/bin/git" and re.search(
                r"(?im)%Warning|%Error|\bwarning:|\berror:", raw_log.read_text(encoding="utf-8", errors="replace")):
            q.fail("RAW_COMMAND_AUDIT", "DIAGNOSTIC:" + str(raw_log))
        records[raw_log.name] = {"metadata": str(path), "metadata_sha256": sha256(path),
                                "raw_log": str(raw_log), "raw_log_sha256": sha256(raw_log),
                                "command": argv, "rc": 0}
    if len(records) != expected_count:
        q.fail("RAW_COMMAND_AUDIT", f"EXPECTED={expected_count}; OBSERVED={len(records)}; work={work}")
    return records


def audit_fresh_p30(q, result, frozen):
    lines = result.stdout.splitlines()
    for marker in ("PROD_SEAM_P30_GATE=PASS", "PROD_SEAM_P30_POST_CONTAINMENT=PASS",
                   "PROD_SEAM_P30_RAW_INDEX_IDENTICAL=PASS",
                   "PROD_SEAM_P30_P27_P28_P29_PREDECESSORS=PASS mode=fresh-unchanged-canonical-runners"):
        if lines.count(marker) != 1:
            q.fail("P30_FRESH_RESULT", "MISSING_OR_DUPLICATE:" + marker)
    work_values = [line.removeprefix("VALIDATION_WORK=") for line in lines if line.startswith("VALIDATION_WORK=")]
    receipt_values = [line.removeprefix("PROD_SEAM_P30_RECEIPT=") for line in lines
                      if line.startswith("PROD_SEAM_P30_RECEIPT=")]
    if len(work_values) != 1 or len(receipt_values) != 1:
        q.fail("P30_FRESH_RESULT", "WORK_OR_RECEIPT_NOT_UNIQUE")
    work = Path(work_values[0])
    if (work.parent != Path("/tmp") or not work.name.startswith("a0_p30_p30_gate_")
            or work.is_symlink() or work.resolve(strict=True) != work or work == q.work):
        q.fail("P30_FRESH_RESULT", "UNEXPECTED_CHILD_WORK:" + str(work))
    receipt_path = work / "p30-receipt.json"
    if Path(receipt_values[0]) != receipt_path:
        q.fail("P30_FRESH_RESULT", "RECEIPT_OUTSIDE_CHILD_WORK")
    receipt = read_json(receipt_path)
    summary, containment = read_json(work / "summary.json"), read_json(work / "containment.json")
    completed = read_json(work / "p30-completed-stages.json")
    if (receipt.get("gate") != "PROD_SEAM_P30_GATE=PASS" or receipt.get("summary") != summary
            or receipt.get("containment") != containment or receipt.get("completed_stages") != completed
            or summary.get("first_failure") is not None or summary.get("secondary_errors") != []
            or summary.get("strict_verified") is not True or summary.get("checkpoint") != str(q.checkpoint)
            or summary.get("work") != str(work)
            or containment != {"added": [], "changed": [], "removed": [],
                               "raw_index_identical": True, "unchanged": True}):
        q.fail("P30_FRESH_AUDIT", "RECEIPT_SUMMARY_OR_CONTAINMENT")
    if (read_json(work / "checkpoint-before.json") != q.before
            or read_json(work / "checkpoint-after.json") != q.before
            or (work / "index-before.raw").read_bytes() != q.index_before):
        q.fail("P30_FRESH_AUDIT", "FULL_CHECKPOINT_OR_RAW_INDEX_MISMATCH")
    expected_git = {"head": HEAD, "branch": BRANCH, "tracked_diff_sha256": DIFF_SHA,
                    "index_semantic_sha256": INDEX_SEMANTIC_SHA, "staged_changes": ""}
    if (completed.get("pre_identity") != expected_git or completed.get("post_identity") != expected_git
            or completed.get("p30_source_sha256") != P30_OWN
            or completed.get("frozen_artifact_count") != len(frozen)):
        q.fail("P30_FRESH_AUDIT", "SOURCE_OR_GIT_IDENTITY")
    commands = command_records(q, work, expected_count=37)
    version_log = work / "001_version.log"
    if version_log.read_text(encoding="utf-8").strip() != EXACT_VERSION:
        q.fail("P30_FRESH_VERSION", str(version_log))
    outer = q._strict_rows(work / "strict-outer.jsonl", outer=True)
    inner = q._strict_rows(work / "strict-inner.jsonl", outer=False)
    count_elab = lambda rows: sum("--lint-only" in row["forwarded"] or "--cc" in row["forwarded"] for row in rows)
    strict = {"outer_calls": len(outer), "inner_calls": len(inner),
              "outer_elaborations": count_elab(outer), "inner_elaborations": count_elab(inner),
              "outer_stripped_count": 0, "inner_stripped_count": 0}
    if (strict != completed.get("strict") or strict != {
            "outer_calls": 25, "inner_calls": 100, "outer_elaborations": 21,
            "inner_elaborations": 21, "outer_stripped_count": 0, "inner_stripped_count": 0}):
        q.fail("P30_FRESH_STRICT", json.dumps(strict, sort_keys=True))

    def check_raw(row):
        path = Path(row.get("raw_log", ""))
        if (path.parent != work or path.name not in commands
                or row.get("raw_log_sha256") != commands[path.name]["raw_log_sha256"]):
            q.fail("P30_FRESH_RAW_REFERENCE", json.dumps(row, sort_keys=True))
        return path

    if len(completed.get("matrix", [])) != 3:
        q.fail("P30_FRESH_MATRIX", "EXPECTED_THREE_VARIANTS")
    for row, (name, values) in zip(completed["matrix"], MATRIX):
        if row.get("variant") != name or row.get("parameters") != dict(zip(PARAMETER_NAMES, values)):
            q.fail("P30_FRESH_MATRIX", "PARAMETER_IDENTITY")
        check_raw(row)
    behavior = completed.get("behavior", {})
    if set(behavior) != {"store", "wrap_gen1", "wrap_gen2", "wrap_gen3", "deadline", "memory"}:
        q.fail("P30_FRESH_BEHAVIOR", "EXPECTED_SIX_SIMULATIONS")
    predecessor_runner = ROOT / "tests/run_prod_seam_p30.py"
    for name, _, mode, _ in CASES:
        contract = "STORE_MARKERS" if mode == 0 else "WRAP_MARKERS" if mode == 1 else "DEADLINE_MARKERS"
        markers = literal_assignment(q, predecessor_runner, contract)
        actual = markers_in_log(q, check_raw(behavior[name]), markers, mode=mode, milestone=30)
        if behavior[name].get("summary") != actual["summary"] or behavior[name].get("required_markers") != list(markers):
            q.fail("P30_FRESH_BEHAVIOR", "RAW_SUMMARY_OR_MARKER_DISAGREEMENT:" + name)
    markers = literal_assignment(q, predecessor_runner, "MEMORY_MARKERS")
    markers_in_log(q, check_raw(behavior["memory"]), markers, milestone=30)
    predecessors = completed.get("predecessors", {})
    if set(predecessors) != {"27", "28", "29"}:
        q.fail("P30_FRESH_CHAIN", "EXPECTED_FRESH_P27_P28_P29")
    for milestone, row in predecessors.items():
        path = check_raw(row)
        command = commands[path.name]["command"]
        if (row.get("rc") != 0 or row.get("mode") != "fresh-unchanged-canonical-runner"
                or command != ["/usr/bin/python3", "-u", str(ROOT / "tests" / ("run_prod_seam_p" + milestone + ".py"))]):
            q.fail("P30_FRESH_CHAIN", "RUNNER_COMMAND_IDENTITY:" + milestone)
        markers_in_log(q, path, tuple("PROD_SEAM_P" + milestone + suffix for suffix in (
            "_GATE=PASS", "_POST_CONTAINMENT=PASS", "_EXACT_VERILATOR_5_050=PASS",
            "_OUTER_STRICT_LEAK=0", "_INNER_STRICT_LEAK=0")))
    # Keep the two actual instrumentation domains separate in evidence. Parent
    # strict rows do not observe this child's independently bootstrapped tools.
    names = ("p30-receipt.json", "p30-completed-stages.json", "summary.json", "containment.json",
             "checkpoint-before.json", "checkpoint-after.json", "index-before.raw",
             "strict-outer.jsonl", "strict-inner.jsonl", "strict-policy.json", "toolchain-provenance.json")
    return {"mode": "fresh-unchanged-canonical-runner", "raw_log": str(result.log),
            "raw_log_sha256": sha256(result.log), "rc": result.rc, "work": str(work),
            "receipt": str(receipt_path), "receipt_sha256": sha256(receipt_path),
            "artifact_sha256": {name: sha256(work / name) for name in names},
            "commands": commands, "strict": strict, "predecessors": predecessors,
            "containment": containment, "frozen_p30_receipt_sha256": P30_RECEIPT_SHA}


def main():
    resource.setrlimit(resource.RLIMIT_CORE, (0, 0))
    q = Qualification(checkpoint=ROOT.parent, label="p31_gate")
    try:
        with q:
            frozen = frozen_guard(q)
            own_before = own_sources()
            q._json("p31-source-identities-before.json", own_before)
            q.bootstrap()
            pre_identity = git_guard(q, "pre")
            sources = inherited_sources(q, frozen)
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
                behavior[name] = markers_in_log(q, result.log, markers, mode=mode)
                behavior[name]["parameters"] = list(parameters)
            binary = q.build_simulation(MEMORY_TOP,
                sources + [ROOT / "tests/rtl" / (MEMORY_TOP + ".sv")], name="memory")
            result = q.run([binary], "memory_sim", cwd=q.work, timeout=120)
            behavior["memory"] = markers_in_log(q, result.log, MEMORY_MARKERS)
            predecessor_result = q.run(["/usr/bin/python3", "-u", ROOT / "tests/run_prod_seam_p30.py"],
                                       "p30_canonical", timeout=6000, reject_diagnostics=True)
            predecessor = audit_fresh_p30(q, predecessor_result, frozen)
            frozen_guard(q)
            if own_sources() != own_before:
                q.fail("P31_SOURCE_IDENTITY", "OWN_SOURCE_CHANGED_DURING_QUALIFICATION")
            post_identity = git_guard(q, "post")
            if post_identity != pre_identity:
                q.fail("P31_REPOSITORY_IDENTITY", "PRE_POST_MISMATCH")
            strict = q.assert_strict(minimum_elaborations=9)
            if strict != {"outer_calls": 10, "inner_calls": 40, "outer_elaborations": 9,
                          "inner_elaborations": 9, "outer_stripped_count": 0, "inner_stripped_count": 0}:
                q.fail("P31_STRICT_CALL_ACCOUNTING", json.dumps(strict, sort_keys=True))
            commands = command_records(q, q.work, expected_count=35)
            completed = {"matrix": matrix_results, "behavior": behavior, "p30_predecessor": predecessor,
                         "strict": strict, "commands": commands, "pre_identity": pre_identity,
                         "post_identity": post_identity, "p31_source_sha256": own_before,
                         "frozen_p30_source_sha256": P30_OWN, "frozen_predecessor_sha256": frozen,
                         "rtl_source_count": len(sources)}
            q._json("p31-completed-stages.json", completed)

        summary = read_json(q.work / "summary.json")
        containment = read_json(q.work / "containment.json")
        if (summary.get("first_failure") is not None or summary.get("secondary_errors") != []
                or summary.get("strict_verified") is not True
                or containment != {"added": [], "changed": [], "removed": [],
                                   "raw_index_identical": True, "unchanged": True}
                or own_sources() != own_before):
            raise ValidationFailure("FINAL_AUDIT", "SUMMARY_CONTAINMENT_OR_OWN_SOURCE_MISMATCH")
        receipt = q._json("p31-receipt.json", {"gate": "PROD_SEAM_P31_GATE=PASS",
                            "completed_stages": completed, "containment": containment, "summary": summary})
        print("PROD_SEAM_P31_EXACT_VERILATOR_5_050=PASS")
        print("PROD_SEAM_P31_STRICT_LINT=PASS")
        print("PROD_SEAM_P31_PARAMETER_MATRIX=PASS variants=3")
        print("PROD_SEAM_P31_BEHAVIOR=PASS simulations=" + str(len(behavior)))
        print("PROD_SEAM_P31_P30_PREDECESSOR=PASS mode=fresh-unchanged-canonical-runner")
        print("PROD_SEAM_P31_P27_P28_P29_CHAIN=PASS mode=fresh-via-P30")
        print("PROD_SEAM_P31_OUTER_STRICT_CALLS=" + str(strict["outer_calls"]))
        print("PROD_SEAM_P31_INNER_STRICT_CALLS=" + str(strict["inner_calls"]))
        print("PROD_SEAM_P31_STRICT_ELABORATIONS=" + str(strict["inner_elaborations"]))
        print("PROD_SEAM_P31_OUTER_STRICT_LEAK=" + str(strict["outer_stripped_count"]))
        print("PROD_SEAM_P31_INNER_STRICT_LEAK=" + str(strict["inner_stripped_count"]))
        print("PROD_SEAM_P31_CHILD_P30_OUTER_STRICT_CALLS=" + str(predecessor["strict"]["outer_calls"]))
        print("PROD_SEAM_P31_CHILD_P30_INNER_STRICT_CALLS=" + str(predecessor["strict"]["inner_calls"]))
        print("PROD_SEAM_P31_POST_CONTAINMENT=PASS")
        print("PROD_SEAM_P31_RAW_INDEX_IDENTICAL=PASS")
        print("PROD_SEAM_P31_RECEIPT=" + str(receipt))
        print("PROD_SEAM_P31_GATE=PASS")
        return 0
    except BaseException as error:
        failure = q._first_failure or {
            "stage": getattr(error, "stage", "EXCEPTION"),
            "detail": getattr(error, "detail", repr(error)), "rc": getattr(error, "rc", 1),
        }
        print("PROD_SEAM_P31_FIRST_FAILURE", file=sys.stderr)
        print("STAGE=" + failure["stage"], file=sys.stderr)
        print("DETAIL=" + failure["detail"], file=sys.stderr)
        print("RAW_EXIT_CODE=" + str(failure["rc"]), file=sys.stderr)
        if q.work is not None:
            print("RAW_EVIDENCE=" + str(q.work), file=sys.stderr)
        rc = failure["rc"]
        return rc if 0 < rc < 256 else (128 - rc if -127 <= rc < 0 else 1)


if __name__ == "__main__":
    raise SystemExit(main())
