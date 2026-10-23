#!/usr/bin/python3
"""Canonical P30 qualification; all generated files and evidence stay in /tmp.

Install beside the unchanged, renamed p30_validation_support.py in A0-GPU/tests.
This runner executes P27, P28, and P29 gates; receipts alone never qualify them.
"""
from __future__ import annotations

import sys
sys.dont_write_bytecode = True
import os
if sys.flags.optimize or os.environ.get("PYTHONOPTIMIZE"):
    raise SystemExit("PROD_SEAM_P30_FIRST_FAILURE STAGE=PYTHON_OPTIMIZATION_FORBIDDEN")

import ast
import json
from pathlib import Path
import re
import resource

from p30_validation_support import Qualification, ValidationFailure, STRICT_FLAGS, sha256


ROOT = Path(__file__).resolve().parents[1]
HEAD = "996d8c188e5d4f94b4bad5289392844d55d092f6"
BRANCH = "main"
DIFF_SHA = "59fac4fc152cc4e46ed60bff0feecf700756d860ed4f44436f532a221570eb8b"
INDEX_SEMANTIC_SHA = "512cef8e2fac0b64a0dd049b69db09ea22b8cef76f74f05777f2aaa54816fbf5"
TOP = "a0_production_store_commit_generation_subsystem"
STORE_TOP = "a0_production_store_commit_generation_tb"
MEMORY_TOP = "a0_production_store_commit_generation_memory_tb"

# Captured from the attached P29 checkpoint before any successor installation.
# The first 19 hashes cover every RTL source selected by the frozen P29 runner.
FROZEN = {
    "A0-GPU/rtl/memory/a0_line_slice_fabric.sv": "b4b12cbe2b5c6c99806f6b0e3f5e7402c1e1782c4a9b1de8153a64a84be47f39",
    "A0-GPU/rtl/memory/a0_l2_dirty_writeback_slice.sv": "0b4525e59be8adb1b9b3234a67afca072eaaa4c509652f788c1d66c3b416cfe7",
    "A0-GPU/rtl/memory/a0_l2_writeback_completion_guard.sv": "f8f02a91d30194e09ddcc5a79b31ab4759a455014eb306fbe1abdbd07228e24d",
    "A0-GPU/rtl/memory/a0_l2_writeback_recovery_controller.sv": "c153041228d9c3b75204592023c811b77df46a9ceee79db8e2315aa82225b425",
    "A0-GPU/rtl/memory/a0_l2_recoverable_writeback_slice.sv": "862c5530b284fba6cc2c5dde3a78bf024df1fbd39de755d4a72578257aa9a28b",
    "A0-GPU/rtl/memory/a0_l2_multislice_writeback_queue.sv": "95835b175a853014b302b9c463c94fb3a2059a52e80502527344d5e5414fe924",
    "A0-GPU/rtl/memory/a0_l2_multislice_recoverable_writeback_subsystem.sv": "5b589f27fed04a58fd02c7e24b1e4c70db33051cf399e7451f090ca70b3f617e",
    "A0-GPU/rtl/memory/a0_mc_noc_multislice_recoverable_writeback_subsystem.sv": "f44e6d5e0588e3fec83f557dfa8faa9080315bef399626f7eee464d0ea0ca341",
    "A0-GPU/rtl/memory/a0_l2_unified_line_backend_arbiter.sv": "8fb2d8162b9855966288b3138d0156dca0ea0fcff4b5fd71a6e2faa3d3d83c98",
    "A0-GPU/rtl/memory/a0_mc_noc_dirty_l2_unified_backend_subsystem.sv": "ae37fee3f52832b9387dd068fe8e55a2b2c86c8df33a417c4a4f9b2c82ea8456",
    "A0-GPU/rtl/memory/a0_store_commit_dirty_l2_router.sv": "4815f88fbc468ddb4871b3c06dc6b785f1dae4be7528a9d897eb04e424cb6b64",
    "A0-GPU/rtl/memory/a0_production_store_commit_dirty_l2_subsystem.sv": "a71d2a3d1a5be0999e7a65f388c6cd4b11a771db519d20b0623bf2bee5f1c3e1",
    "A0-GPU/rtl/memory/a0_production_store_commit_write_miss_visibility_subsystem.sv": "972dfdbb765d60b51b672fde6ea0b50deaec8708e97db93d843068781c93c1b9",
    "A0-GPU/rtl/memory/a0_store_word_completion_guard.sv": "3d64ce87e76baa75e21f1a2e62a251d7747c88e4e2618d2d74cc5f485662e5a5",
    "A0-GPU/rtl/memory/a0_production_store_commit_completed_miss_visibility_subsystem.sv": "3e1d9e1b7a1e319e662dd0421c940a7a4a2ba85df51f557aacfc5e415c33d58a",
    "A0-GPU/rtl/memory/a0_store_word_status_timeout_guard.sv": "1713f91ce203ea51d81c4b3d19af9debaff50588cd00fa48c9b6197cacefb0b1",
    "A0-GPU/rtl/memory/a0_production_store_commit_timed_miss_visibility_subsystem.sv": "7e0c7608639d8b93bc05b1604bedfe79272b4e4d8475ebface7ca1e27930d250",
    "A0-GPU/rtl/memory/a0_production_store_commit_fault_provenance_subsystem.sv": "5d4418e0f244c7f2b29b905afb2ff50f2535b68b1c43016615da0b6c7b5013ed",
    "A0-GPU/rtl/memory/a0_production_store_commit_recoverable_fault_subsystem.sv": "ade8ac8aa85fa530b58dfc8396d60259ac74a8894435efaa77551900a12188d9",
    "A0-GPU/tests/run_prod_seam_p27.py": "8d912de705e4373684c9d32bdf0eea1d587ac7e66ae96acfd017ce0a1571bf54",
    "EVIDENCE/P27/receipt.txt": "203d166f3c54c88c927c7582cf2d7107d551fcbce9d45efc74f24442211781d1",
    "A0-GPU/tests/run_prod_seam_p28.py": "1e1a389f4ddcc7d075b60aeb4a26cfb447500a7c0807a6fc5acba2d167b75c0c",
    "EVIDENCE/P28/receipt.txt": "06bbd2ecbe8ba56c9e417b733a71a18cf72656415544f623e6f939f9142adf95",
    "A0-GPU/tests/run_prod_seam_p29.py": "f0a2249762b990b29842025085658e1e70ba25c7be9270c52b237a483db7481f",
    "EVIDENCE/P29/receipt.txt": "6682c23071e27c9d0d5c41a0c51f542642c8e6f23b2cb66e1ead924ca16fe829",
    "A0-GPU/tests/rtl/a0_production_store_commit_timed_miss_visibility_subsystem_tb.sv": "db6ed478dd1855e35701fdb4ead273c17a7ed39f72166dadfe25bca99d89951b",
    "A0-GPU/tests/rtl/a0_production_store_commit_fault_provenance_subsystem_tb.sv": "bcd45b8b278c5a84ce719e07fed185079729d7f3617fbace72fca9bb236616f7",
    "A0-GPU/tests/rtl/a0_production_store_commit_recoverable_fault_subsystem_tb.sv": "6ace4a268cae5002e69eddbf4842f38201b72acb8ab3e27febac5752d5aee723",
    "A0-GPU/docs/architecture/A0_PROD_SEAM_P27_STORE_WORD_STATUS_TIMEOUT.md": "12d3e372648651ae65b333bac75342c2b8f79220633a7b01433c03c09c7f0a6b",
    "A0-GPU/docs/architecture/A0_PROD_SEAM_P28_COMMIT_FAULT_PROVENANCE.md": "227a73124c56d14b50922053483fb57d934ac68a5c119c31acf898764e096d3f",
    "A0-GPU/docs/architecture/A0_PROD_SEAM_P29_SAFE_STORE_RESTART.md": "2d007d3820cd5729ecff2d101680e99052cfb67bfb04de0f7bf2d5e20d24bf05",
}

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
    "PROD_SEAM_P30_FIRST_RECOVERY_ALIAS_CONTAINED=PASS",
    "PROD_SEAM_P30_OTHER_PENDING_PORT_PRESERVED=PASS",
    "PROD_SEAM_P30_REPEATED_RECOVERY_HISTORY=PASS",
    "PROD_SEAM_P30_SAME_CYCLE_OLD_SUCCESS_FAILURE=PASS",
    "PROD_SEAM_P30_RETRY_BACKPRESSURE_PAYLOAD=PASS",
    "PROD_SEAM_P30_MULTILANE_SUCCESS_ONLY_RETIRE=PASS",
)
WRAP_MARKERS = ("PROD_SEAM_P30_TRUTHFUL_ALL_GENERATION_WRAP=PASS",)
DEADLINE_MARKERS = ("PROD_SEAM_P30_DEADLINE_PROVENANCE_AND_SAME_CYCLE_MATCH=PASS",)
MEMORY_MARKERS = (
    "PROD_SEAM_P30_MEMORY_TYPED_READ_WRITEBACK=PASS",
    "PROD_SEAM_P30_MEMORY_TWO_REAL_RECOVERIES=PASS",
    "PROD_SEAM_P30_MEMORY_PENDING_READ_DRAIN=PASS",
    "PROD_SEAM_P30_MEMORY_DIRTY_RESET_BLOCKED=PASS",
    "PROD_SEAM_P30_MEMORY_WB_DRAIN_PENDING_CLIENT_BLOCKED=PASS",
    "PROD_SEAM_P30_MEMORY_END_TO_END=PASS",
)


def frozen_guard(q):
    for name, expected in FROZEN.items():
        if sha256(q.checkpoint / name) != expected:
            q.fail("FROZEN_IMMUTABILITY", name)


def inherited_sources(q):
    tree = ast.parse((ROOT / "tests/run_prod_seam_p29.py").read_text(encoding="utf-8"))
    values = [n.value for n in tree.body if isinstance(n, ast.Assign)
              and any(isinstance(t, ast.Name) and t.id == "NAMES" for t in n.targets)]
    if len(values) != 1:
        q.fail("SOURCE_LIST", "P29_NAMES_ASSIGNMENT_NOT_UNIQUE")
    names = ast.literal_eval(values[0])
    if (not isinstance(names, list) or len(names) != 19 or len(set(names)) != 19
            or any(not isinstance(n, str) or Path(n).name != n or not n.endswith(".sv") for n in names)):
        q.fail("SOURCE_LIST", "P29_NAMES_CONTRACT")
    if any("A0-GPU/rtl/memory/" + name not in FROZEN for name in names):
        q.fail("SOURCE_LIST", "UNFROZEN_P29_SOURCE")
    return [ROOT / "rtl/memory" / name for name in names]


def git_guard(q, phase):
    def git(args, suffix):
        return q.run(["/usr/bin/git", "-c", "diff.autoRefreshIndex=false", *args],
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
    actual = {"head": head, "branch": branch, "tracked_diff_sha256": sha256(diff.log),
              "index_semantic_sha256": sha256(index.log), "staged_changes": staged.stdout}
    if (head != HEAD or branch != BRANCH or actual["tracked_diff_sha256"] != DIFF_SHA
            or actual["index_semantic_sha256"] != INDEX_SEMANTIC_SHA or staged.stdout):
        q.fail("REPOSITORY_IDENTITY", json.dumps(actual, sort_keys=True))
    q._json(phase + "-git-identity.json", actual)
    return actual


def require_markers(q, result, markers, *, mode=None):
    lines = result.stdout.splitlines()
    missing = [marker for marker in markers if marker not in lines]
    if missing:
        q.fail("BEHAVIOR_MARKERS", json.dumps(missing) + "; raw_log=" + str(result.log))
    summary = None
    if mode is not None:
        pattern = re.compile(r"PROD_SEAM_P30_STORE_BEHAVIOR=PASS mode=(\d+) issues=(\d+) "
                             r"success=(\d+) abort=(\d+) rearm=(\d+)")
        matches = [pattern.fullmatch(line) for line in lines]
        summaries = [m for m in matches if m is not None]
        if len(summaries) != 1 or int(summaries[0].group(1)) != mode:
            q.fail("BEHAVIOR_SUMMARY", "MISSING_OR_AMBIGUOUS_STORE_SUMMARY; raw_log=" + str(result.log))
        counts = list(map(int, summaries[0].groups()))
        if counts[1] < 1 or counts[2] < 1:
            q.fail("BEHAVIOR_SUMMARY", "VACUOUS_STORE_TRAFFIC; raw_log=" + str(result.log))
        summary = dict(zip(("mode", "issues", "success", "abort", "rearm"), counts))
    return {"raw_log": str(result.log), "raw_log_sha256": sha256(result.log),
            "required_markers": list(markers), "summary": summary}


def own_sources():
    paths = [Path(__file__).resolve(), ROOT / "tests/p30_validation_support.py",
             ROOT / "rtl/memory" / (TOP + ".sv"),
             ROOT / "tests/rtl" / (STORE_TOP + ".sv"),
             ROOT / "tests/rtl" / (MEMORY_TOP + ".sv"),
             ROOT / "docs/architecture/A0_PROD_SEAM_P30_GENERATION_IDENTITY.md"]
    return {str(path.relative_to(ROOT)): sha256(path) for path in paths}


def main():
    resource.setrlimit(resource.RLIMIT_CORE, (0, 0))
    q = Qualification(checkpoint=ROOT.parent, label="p30_gate")
    try:
        with q:
            frozen_guard(q)
            own_before = own_sources()
            q._json("p30-source-identities-before.json", own_before)
            q.bootstrap()
            pre_identity = git_guard(q, "pre")
            sources = inherited_sources(q) + [ROOT / "rtl/memory" / (TOP + ".sv")]
            matrix_results = []
            for name, values in MATRIX:
                params = [f"-G{key}={value}" for key, value in zip(PARAMETER_NAMES, values)]
                result = q.verilator([*STRICT_FLAGS, "--lint-only", "--top-module", TOP,
                                      "--Mdir", q.work / ("lint_" + name.lower()), *params, *sources],
                                     "matrix_" + name.lower())
                matrix_results.append({"variant": name, "parameters": dict(zip(PARAMETER_NAMES, values)),
                                       "raw_log": str(result.log), "raw_log_sha256": sha256(result.log)})

            cases = (
                ("store", ("-GMODE=0", "-GGEN=5", "-GMSR=2", "-GTO=64"), 0, STORE_MARKERS),
                ("wrap_gen1", ("-GMODE=1", "-GGEN=1"), 1, WRAP_MARKERS),
                ("wrap_gen2", ("-GMODE=1", "-GGEN=2"), 1, WRAP_MARKERS),
                ("wrap_gen3", ("-GMODE=1", "-GGEN=3"), 1, WRAP_MARKERS),
                ("deadline", ("-GMODE=2", "-GTO=1", "-GMSR=0", "-GGEN=5"), 2, DEADLINE_MARKERS),
            )
            behavior = {}
            for name, params, mode, markers in cases:
                binary = q.build_simulation(STORE_TOP,
                    sources + [ROOT / "tests/rtl" / (STORE_TOP + ".sv")], name=name, parameters=params)
                result = q.run([binary], name + "_sim", cwd=q.work, timeout=120)
                behavior[name] = require_markers(q, result, markers, mode=mode)
                behavior[name]["parameters"] = list(params)
            binary = q.build_simulation(MEMORY_TOP,
                sources + [ROOT / "tests/rtl" / (MEMORY_TOP + ".sv")], name="memory")
            result = q.run([binary], "memory_sim", cwd=q.work, timeout=120)
            behavior["memory"] = require_markers(q, result, MEMORY_MARKERS)

            predecessors = {}
            for milestone in (27, 28, 29):
                result = q.run_canonical(milestone)
                predecessors[str(milestone)] = {
                    "mode": "fresh-unchanged-canonical-runner", "raw_log": str(result.log),
                    "raw_log_sha256": sha256(result.log), "rc": result.rc,
                }
            frozen_guard(q)
            if own_sources() != own_before:
                q.fail("P30_SOURCE_IDENTITY", "OWN_SOURCE_CHANGED_DURING_QUALIFICATION")
            post_identity = git_guard(q, "post")
            # 3 matrix elaborations + 6 P30 testbench generations + 3*4 predecessor elaborations.
            strict = q.assert_strict(minimum_elaborations=21)
            completed = {"matrix": matrix_results, "behavior": behavior,
                         "predecessors": predecessors, "strict": strict,
                         "pre_identity": pre_identity, "post_identity": post_identity,
                         "p30_source_sha256": own_before, "frozen_artifact_count": len(FROZEN)}
            q._json("p30-completed-stages.json", completed)

        # No overall passing marker is emitted inside the context: its exit is
        # responsible for the final strict, helper, checkpoint and raw-index audit.
        summary = json.loads((q.work / "summary.json").read_text(encoding="utf-8"))
        containment = json.loads((q.work / "containment.json").read_text(encoding="utf-8"))
        if (summary.get("first_failure") is not None or summary.get("secondary_errors")
                or not summary.get("strict_verified") or not containment.get("unchanged")
                or not containment.get("raw_index_identical") or own_sources() != own_before):
            raise ValidationFailure("FINAL_AUDIT", "SUMMARY_CONTAINMENT_OR_OWN_SOURCE_MISMATCH")
        receipt = q._json("p30-receipt.json", {
            "gate": "PROD_SEAM_P30_GATE=PASS", "completed_stages": completed,
            "containment": containment, "summary": summary,
        })
        print("PROD_SEAM_P30_EXACT_VERILATOR_5_050=PASS")
        print("PROD_SEAM_P30_FROZEN_P29_P28_P27=PASS artifacts=" + str(len(FROZEN)))
        print("PROD_SEAM_P30_STRICT_LINT=PASS")
        print("PROD_SEAM_P30_PARAMETER_MATRIX=PASS variants=3")
        print("PROD_SEAM_P30_BEHAVIOR=PASS simulations=" + str(len(behavior)))
        print("PROD_SEAM_P30_P27_P28_P29_PREDECESSORS=PASS mode=fresh-unchanged-canonical-runners")
        print("PROD_SEAM_P30_OUTER_STRICT_CALLS=" + str(strict["outer_calls"]))
        print("PROD_SEAM_P30_INNER_STRICT_CALLS=" + str(strict["inner_calls"]))
        print("PROD_SEAM_P30_STRICT_ELABORATIONS=" + str(strict["inner_elaborations"]))
        print("PROD_SEAM_P30_OUTER_STRICT_LEAK=" + str(strict["outer_stripped_count"]))
        print("PROD_SEAM_P30_INNER_STRICT_LEAK=" + str(strict["inner_stripped_count"]))
        print("PROD_SEAM_P30_POST_CONTAINMENT=PASS")
        print("PROD_SEAM_P30_RAW_INDEX_IDENTICAL=PASS")
        print("PROD_SEAM_P30_RECEIPT=" + str(receipt))
        print("PROD_SEAM_P30_GATE=PASS")
        return 0
    except BaseException as error:
        failure = q._first_failure or {
            "stage": getattr(error, "stage", "EXCEPTION"),
            "detail": getattr(error, "detail", repr(error)), "rc": getattr(error, "rc", 1),
        }
        print("PROD_SEAM_P30_FIRST_FAILURE", file=sys.stderr)
        print("STAGE=" + failure["stage"], file=sys.stderr)
        print("DETAIL=" + failure["detail"], file=sys.stderr)
        print("RAW_EXIT_CODE=" + str(failure["rc"]), file=sys.stderr)
        if q.work is not None:
            print("RAW_EVIDENCE=" + str(q.work), file=sys.stderr)
        rc = failure["rc"]
        return rc if 0 < rc < 256 else (128 - rc if -127 <= rc < 0 else 1)


if __name__ == "__main__":
    raise SystemExit(main())
