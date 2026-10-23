#!/usr/bin/python3
"""Canonical P34 real-cache coherence endpoint qualification.
Independent strict domains; frozen predecessor sources are never repaired here.
The final gate marker is emitted only after complete source/raw-index containment.
"""
from __future__ import annotations
import sys
sys.dont_write_bytecode = True
import os
if sys.flags.optimize or os.environ.get("PYTHONOPTIMIZE"):
    raise SystemExit("PROD_SEAM_P34_FIRST_FAILURE STAGE=PYTHON_OPTIMIZATION_FORBIDDEN")
import importlib.util
import argparse
import json
from pathlib import Path
import re
import resource
from types import SimpleNamespace
from p34_validation_support import Qualification, ValidationFailure, STRICT_FLAGS, EXACT_VERSION, sha256

ROOT = Path(__file__).resolve().parents[1]
HEAD = "996d8c188e5d4f94b4bad5289392844d55d092f6"
BRANCH = "main"
DIFF_SHA = "59fac4fc152cc4e46ed60bff0feecf700756d860ed4f44436f532a221570eb8b"
INDEX_SEMANTIC_SHA = "512cef8e2fac0b64a0dd049b69db09ea22b8cef76f74f05777f2aaa54816fbf5"

P33_RECEIPT = "EVIDENCE/P33/CANONICAL/p33-receipt.json"
P33_RECEIPT_SHA = "b7f51011a784cf5d34892cf1e27c5d793361b1ccf95870ae31fa8e73617851dc"
P33_OWN = {
    "docs/architecture/A0_PROD_SEAM_P33_SCOPED_STORE_QUARANTINE.md": "513bcd47cf9f4adae7ced23ffb14a14457ec63bb05d66034adae4531fe7639b2",
    "rtl/memory/a0_production_store_commit_scoped_progress_subsystem.sv": "f092988414cb7aad85454494388e7fadca88f3dc20a53b4aa64b5c90fdab0914",
    "rtl/memory/a0_store_commit_scoped_recovery_frontend.sv": "4b0da8317d954f8227eff0336c4fed7a2d7d22d2cf4e5def7ff7fdc8ec52c98a",
    "rtl/memory/a0_store_read_quarantine_order_guard.sv": "f007f73988168129c58d1b25af22f336b217ced7e2ae46f299822b24b2855aec",
    "tests/p33_validation_support.py": "a94dc20a4dd4852736856b2caf87a1a4946028916af385eb0fffac298aa19099",
    "tests/rtl/a0_p33_store_read_order_tb.sv": "8545c3f00dd671ea51e958362b82b60207d6e3a28dfe1035f296ca28e049262c",
    "tests/rtl/a0_production_store_commit_scoped_progress_store_tb.sv": "b7c09aacbfcd9b0cc78db16ae042ec1677cd3aa0cc5ad007ec14ae6564efd342",
    "tests/rtl/a0_production_store_commit_scoped_progress_subsystem_tb.sv": "6d9f76f874059ae1cfec416e9bea77ec2d89f1a0bc8976e5a48dc74435b27c64",
    "tests/rtl/a0_store_read_quarantine_order_guard_tb.sv": "842d60334d7e2c53951b1e849aa73545f41f3cb8fff53a088623424cee0a37a8",
    "tests/run_prod_seam_p33.py": "a1e59a4ffdeed1945aa4e23f088860fbd539418cebeec034fb0281146981df28"
}
SUPPORT_SHA = "391de5294c17c5607506ef510acb6d10278545edd869b29431c00c56ef3d81a4"
TOP = "a0_production_store_commit_coherent_progress_subsystem"
TB = TOP + "_tb"
COMPONENT_TOP = "a0_l2_coherence_probe_slice"
NEW_RTL = (
    'a0_l2_coherence_probe_slice.sv',
    'a0_l2_coherent_recoverable_writeback_slice.sv',
    'a0_l2_coherent_multislice_writeback_subsystem.sv',
    'a0_mc_noc_coherent_multislice_writeback_subsystem.sv',
    'a0_mc_noc_coherent_l2_unified_backend_subsystem.sv',
    'a0_production_store_commit_coherent_l2_subsystem.sv',
    'a0_store_read_coherence_order_guard.sv', TOP+'.sv',
)
FROZEN_RTL = (
    'a0_line_slice_fabric.sv', 'a0_l2_writeback_completion_guard.sv',
    'a0_l2_writeback_recovery_controller.sv', 'a0_l2_multislice_writeback_queue.sv',
    'a0_l2_unified_line_backend_arbiter.sv', 'a0_store_commit_dirty_l2_router.sv',
    'a0_store_word_completion_guard.sv', 'a0_store_word_status_timeout_guard.sv',
    'a0_store_attempt_generation_guard.sv', 'a0_store_commit_scoped_recovery_frontend.sv',
)
DIRECT_SCENARIOS = {
    'RESET_EMPTY','OLDER_READ_DRAINS_BEFORE_PROBE','RESIDENT_STORE_QUERY',
    'RAW_STORE_WINS_RAW_PROBE','TAKE_RESPONSE_BACKPRESSURE',
    'REMOTE_HOLD_READ_STORE_ALIAS_BLOCK','RECLAIM_TUPLE_REJECTIONS',
    'EXACT_RECLAIM_REAL_CACHE_BYTES','STALE_GENERATION_REPLAY',
    'GENERATION_EXHAUSTION_HOLDS_QUERY_PROGRESS','TRUTHFUL_IDLE_CERTIFICATE_REARMS',
    'DIRTY_WRITEBACK_PAYLOAD','CAPTURED_STORE_QUARANTINE_AFTER_WITHDRAWAL',
    'RECOVERY_REARM_PROBE_ORDERING','POST_RECOVERY_QUERY_NO_FABRICATED_COMPLETION',
    'HANDSHAKE_ACCOUNTING', 'PENDING_QUERY_BLOCKS_LOCAL_ADMISSION',
    'PENDING_TAKE_BLOCKS_LOCAL_ADMISSION', 'RECLAIM_WITH_WAITING_LOCAL_WORK',
}


def ensure(q, condition, detail):
    if not condition:
        q.fail("P34_CONTRACT", detail)

def read_json(path):
    return json.loads(Path(path).read_text(encoding="utf-8"))

def frozen_guard(q):
    for name, expected in P33_OWN.items():
        ensure(q, sha256(ROOT/name) == expected, "FROZEN_P33_SOURCE:"+name)
    ensure(q, sha256(q.checkpoint/P33_RECEIPT) == P33_RECEIPT_SHA, "FROZEN_P33_RECEIPT")
    ensure(q, read_json(q.checkpoint/P33_RECEIPT)["completed_stages"]["p33_source_sha256"] == P33_OWN,
           "FROZEN_P33_RECEIPT_SOURCE_BINDING")
    ensure(q, sha256(ROOT/"tests/p34_validation_support.py") == SUPPORT_SHA, "P34_EXPLICIT_WORK_ROOT_SUPPORT_IDENTITY")
    spec = importlib.util.spec_from_file_location("p34_frozen_p33_contract", ROOT/"tests/run_prod_seam_p33.py")
    ensure(q, spec is not None and spec.loader is not None, "P33_IMPORT_SPEC")
    predecessor = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(predecessor)
    p32, p31, frozen = predecessor.frozen_guard(q)
    return predecessor, p32, p31, frozen

def own_sources():
    paths = [Path(__file__).resolve(), ROOT/"tests/p34_validation_support.py",
        *(ROOT/"rtl/memory"/name for name in NEW_RTL),
        *(ROOT/"tests/rtl"/(name+".sv") for name in (
            COMPONENT_TOP+"_tb", TB, "a0_p34_predecessor_store_tb",
            "a0_p34_predecessor_memory_tb", "a0_p34_predecessor_order_tb", "a0_p34_predecessor_guard_tb")),
        ROOT/"docs/architecture/A0_PROD_SEAM_P34_COHERENCE_ENDPOINT_CONTRACT.md"]
    return {str(p.relative_to(ROOT)):sha256(p) for p in paths}

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

def direct_behavior(q, row, variant):
    lines = row.stdout.splitlines()
    prefixes = [line.removeprefix('P34_INTEGRATED_DEVELOPMENT_PASS=') for line in lines
                if line.startswith('P34_INTEGRATED_DEVELOPMENT_PASS=')]
    if len(prefixes) != 1:
        q.fail('INTEGRATED_SUMMARY', 'MISSING_OR_DUPLICATE:'+str(row.log))
    result = json.loads(prefixes[0])
    scenarios = DIRECT_SCENARIOS | ({'DISJOINT_SET_PROGRESS','DISJOINT_HOME_PROGRESS','RECLAIM_WITH_DISJOINT_PENDING_QUERY'} if variant else set())
    markers = [m.groups() for line in lines if (m := re.fullmatch(
        r'P34_INTEGRATED_SCENARIO_PASS id=(\d+) name=([A-Z0-9_]+)',line))]
    if ([int(i) for i,n in markers] != list(range(1,len(scenarios)+1))
            or {n for i,n in markers} != scenarios):
        q.fail('INTEGRATED_SCENARIOS',repr(markers))
    expected = {'variant':variant, 'slices':1<<variant, 'sets':1<<variant,
        'line_words':1<<variant, 'scenarios':len(scenarios), 'wb':1,'wb_returns':1,
        'stores':1,'store_returns':1,'transfers':5,'reclaims':5,'rejects':5,'errors':5,'rearms':1,
        'checks':(3434,4495,5543)[variant], 'client_accepts':9 if variant==0 else 13,
        'client_responses':9 if variant==0 else 13, 'reads':2 if variant==0 else 4,
        'read_returns':2 if variant==0 else 4, 'probes':13 if variant==0 else 14,
        'probe_responses':13 if variant==0 else 14, 'drains':1,
        'backend_stalls':9, 'probe_stalls':27 if variant==0 else 36}
    if (not isinstance(result,dict) or any(type(v) is not int for v in result.values())
            or set(result) != set(expected)
            or any(result.get(k) != v for k,v in expected.items())
            or any(result.get(a) != result.get(b) for a,b in
                   [('client_accepts','client_responses'),('reads','read_returns'),('probes','probe_responses')])
            or any(result.get(k,0) <= 0 for k in ['checks','client_accepts','reads','probes','drains'])
            or result.get('backend_stalls',0)<9 or result.get('probe_stalls',0)<4):
        q.fail('INTEGRATED_ACCOUNTING',repr(result))
    return result

def simulation(q,top,sources,name,parameters):
    binary=q.build_simulation(top,sources,name=name,parameters=parameters)
    logs=list(q.work.glob('*_'+name+'_make.log'))
    if len(logs)!=1 or re.search(r'(?im)%Warning|%Error|\bwarning:|\berror:',logs[0].read_text()):
        q.fail(name+'_make_diagnostics',repr(logs))
    row=q.run([binary],name+'_sim',cwd=q.work,timeout=180,reject_diagnostics=True)
    print(row.stdout,end='',flush=True)
    return row

COMPONENT_MATRIX = (('one', 1, 1, 1), ('four', 4, 4, 2), ('eight', 8, 8, 3))
SCENARIOS = {
    'RESET_EMPTY', 'COLD_QUERY_MISS', 'TAKE_MISS_NO_ALLOCATION', 'LOCAL_NODE_REJECTED',
    'REFILL_DRAINS_BEFORE_QUERY', 'HIT_BUFFER_DRAINS', 'RESIDENT_STORE_DIRTY_QUERY',
    'RAW_PROBE_PRIORITY', 'EXTERNAL_QUARANTINE', 'DIRTY_TAKE_STABLE_UNTIL_RECEIVER',
    'REMOTE_HOLD_BLOCKS_ALIASES', 'RECLAIM_TUPLE_REJECTIONS', 'RECLAIM_REAL_CACHE_INSTALL',
    'STALE_GENERATION_REPLAY', 'EXHAUSTION_BLOCKS_TAKE_QUERY_ALLOWED',
    'LOW_HIGH_IDLE_REARM_PRESERVES_CACHE', 'REMOTE_HOLD_PREVENTS_REARM',
    'CERTIFIED_GENERATION_ZERO_REUSE', 'EVICTION_WB_STABLE_PROBE_WAITS',
    'REPLACEMENT_REFILL_THEN_PROBE', 'CLEAN_ALIAS_STORE_PRIORITY',
    'DIRTY_ALIAS_STORE_PRIORITY', 'HANDSHAKE_ACCOUNTING',
}


def behavior_summary(q, result, words, sets, generation):
    lines = result.stdout.splitlines()
    summaries = [line.removeprefix('P34_PROBE_DEVELOPMENT_PASS=') for line in lines
                 if line.startswith('P34_PROBE_DEVELOPMENT_PASS=')]
    if len(summaries) != 1:
        q.fail('P34_BEHAVIOR_SUMMARY', 'MISSING_OR_DUPLICATE_SUMMARY:' + str(result.log))
    summary = json.loads(summaries[0])
    expected_scenarios = SCENARIOS | ({'DISJOINT_PROGRESS'} if sets > 1 else set())
    markers = [match.groups() for line in lines if (match := re.fullmatch(
        r'P34_PROBE_SCENARIO_PASS id=(\d+) name=([A-Z0-9_]+)', line)) is not None]
    if ([int(row[0]) for row in markers] != list(range(1, len(expected_scenarios) + 1))
            or {row[1] for row in markers} != expected_scenarios):
        q.fail('P34_BEHAVIOR_SCENARIOS', 'EXACT_UNIQUE_SCENARIOS:' + repr(markers))
    expected = {'line_words': words, 'sets': sets, 'gen_w': generation,
        'scenarios': len(expected_scenarios), 'probe_accepts': 2 * (1 << generation) + 10,
        'probe_responses': 2 * (1 << generation) + 10, 'transfers': 2 * (1 << generation) + 1,
        'reclaims': 2 * (1 << generation) + 1, 'reclaim_rejects': 4,
        'stores': 5 if sets > 1 else 4, 'memory_reads': 5 if sets > 1 else 4, 'wb': 3,
        'read_accepts': 16 if sets > 1 else 13, 'read_responses': 16 if sets > 1 else 13}
    if (not isinstance(summary, dict)
            or set(summary) != set(expected) | {'checks'}
            or any(type(value) is not int for value in summary.values())
            or any(summary.get(key) != value for key, value in expected.items())
            or summary['checks'] < len(expected_scenarios)
            or summary['read_accepts'] != summary['read_responses']):
        q.fail('P34_BEHAVIOR_COUNTS', 'expected=' + repr(expected) + '; observed=' + repr(summary))
    return summary

def exact_p33_commands(q, work, commands, runner, sources):
    expected = []
    outer = str(work / 'strict-all-outer-verilator.py')
    expected.append(('version', [outer, '--version'], ROOT))

    def add_git(phase):
        for suffix, arguments in (
                ('head', ['rev-parse', 'HEAD']), ('branch', ['branch', '--show-current']),
                ('diffcheck', ['diff', '--check']), ('diff', ['diff', '--binary']),
                ('staged', ['diff', '--cached', '--name-status']),
                ('index_semantics', ['ls-files', '--stage', '-z'])):
            expected.append((phase + '_git_' + suffix,
                             ['/usr/bin/git', '-c', 'diff.autoRefreshIndex=false', *arguments], ROOT))

    def add_sim(name, top, parameters, selected):
        obj = work / (name + '_obj')
        expected.append((name + '_generate', [outer, *runner.STRICT_FLAGS, '--cc', '--exe', '--main',
            '--top-module', top, '--Mdir', str(obj), *parameters,
            *(str(path) for path in selected), str(ROOT / 'tests/rtl' / (top + '.sv'))], ROOT))
        expected.append((name + '_make', ['/usr/bin/make', '-C', str(obj), '-f', 'V' + top + '.mk', '-j1'], ROOT))
        expected.append((name + '_sim', [str(obj / ('V' + top))], work))

    add_git('pre')
    for name, values in runner.MATRIX:
        parameters = [f'-G{key}={value}' for key, value in zip(runner.PARAMETER_NAMES, values)]
        expected.append(('matrix_' + name.lower(), [outer, *runner.STRICT_FLAGS, '--lint-only',
            '--top-module', runner.TOP, '--Mdir', str(work / ('lint_' + name.lower())),
            *parameters, *(str(path) for path in sources)], ROOT))
    for name, parameters, mode, markers in runner.CASES:
        add_sim(name, runner.STORE_TOP, parameters, sources)
    add_sim('memory', runner.MEMORY_TOP, (), sources)
    add_sim('memorywrap', runner.MEMORY_TOP, ('-GMODE=1', '-GGEN=1'), sources)
    add_sim('order', runner.ORDER_TOP, (), sources)
    add_sim('guard', runner.GUARD_TOP, (), [ROOT / 'rtl/memory/a0_store_read_quarantine_order_guard.sv'])
    expected.append(('p32_canonical', ['/usr/bin/python3', '-u', str(ROOT / 'tests/run_prod_seam_p32.py')], ROOT))
    add_git('post')
    ensure(q,len(expected) == 44, 'PARENT_COMMAND_CONTRACT_COUNT')
    ensure(q,set(commands) == {f'{number:03d}_{name}.log' for number, (name, _, _) in enumerate(expected, 1)},
         'PARENT_COMMAND_SEQUENCE')
    for number, (name, argv, cwd) in enumerate(expected, 1):
        row = commands[f'{number:03d}_{name}.log']
        metadata = read_json(row['metadata'])
        ensure(q,row['command'] == argv and metadata['command'] == argv and metadata['cwd'] == str(cwd),
             'PARENT_EXACT_COMMAND:' + name)


def audit_fresh_p33(q, result, p33, p32, p31, frozen, pre_identity):
    lines = result.stdout.splitlines()
    required = ("PROD_SEAM_P33_GATE=PASS", "PROD_SEAM_P33_POST_CONTAINMENT=PASS",
                "PROD_SEAM_P33_RAW_INDEX_IDENTICAL=PASS",
                "PROD_SEAM_P33_P32_PREDECESSOR=PASS mode=fresh-unchanged-canonical-runner",
                "PROD_SEAM_P33_P31_P30_P27_P28_P29_CHAIN=PASS mode=fresh-via-P32")
    for marker in required:
        if lines.count(marker) != 1:
            q.fail("P33_FRESH_RESULT", "MISSING_OR_DUPLICATE:" + marker)
    work_values = [line.removeprefix("VALIDATION_WORK=") for line in lines
                   if line.startswith("VALIDATION_WORK=")]
    receipt_values = [line.removeprefix("PROD_SEAM_P33_RECEIPT=") for line in lines
                      if line.startswith("PROD_SEAM_P33_RECEIPT=")]
    if len(work_values) != 1 or len(receipt_values) != 1:
        q.fail("P33_FRESH_RESULT", "WORK_OR_RECEIPT_NOT_UNIQUE")
    work = Path(work_values[0])
    if (work.parent != Path("/tmp") or not work.name.startswith("a0_p30_p33_gate_")
            or work.is_symlink() or work.resolve(strict=True) != work or work == q.work):
        q.fail("P33_FRESH_RESULT", "UNEXPECTED_CHILD_WORK:" + str(work))
    receipt_path = work / "p33-receipt.json"
    if Path(receipt_values[0]) != receipt_path:
        q.fail("P33_FRESH_RESULT", "RECEIPT_OUTSIDE_CHILD_WORK")
    receipt = read_json(receipt_path)
    summary = read_json(work / "summary.json")
    containment = read_json(work / "containment.json")
    completed = read_json(work / "p33-completed-stages.json")
    if (receipt.get("gate") != "PROD_SEAM_P33_GATE=PASS" or receipt.get("summary") != summary
            or receipt.get("containment") != containment or receipt.get("completed_stages") != completed
            or summary.get("first_failure") is not None or summary.get("secondary_errors") != []
            or summary.get("strict_verified") is not True or summary.get("checkpoint") != str(q.checkpoint)
            or summary.get("work") != str(work)
            or containment != {"added": [], "changed": [], "removed": [],
                               "raw_index_identical": True, "unchanged": True}):
        q.fail("P33_FRESH_AUDIT", "RECEIPT_SUMMARY_OR_CONTAINMENT")
    if (read_json(work / "checkpoint-before.json") != q.before
            or read_json(work / "checkpoint-after.json") != q.before
            or (work / "index-before.raw").read_bytes() != q.index_before):
        q.fail("P33_FRESH_AUDIT", "FULL_CHECKPOINT_OR_RAW_INDEX_MISMATCH")
    if (completed.get("pre_identity") != pre_identity or completed.get("post_identity") != pre_identity
            or completed.get("p33_source_sha256") != P33_OWN
            or completed.get("frozen_p32_source_sha256") != p33.P32_OWN
            or completed.get("frozen_predecessor_sha256") != frozen
            or completed.get("rtl_source_count") != 18):
        q.fail("P33_FRESH_AUDIT", "SOURCE_OR_GIT_IDENTITY")
    commands = p31.command_records(q, work, expected_count=44)
    exact_p33_commands(q, work, commands, p33, p33.inherited_sources(q, p31, frozen))
    if completed.get("commands") != commands:
        q.fail("P33_FRESH_AUDIT", "RAW_COMMAND_RECORD_DISAGREEMENT")
    if (work / "001_version.log").read_text(encoding="utf-8").strip() != EXACT_VERSION:
        q.fail("P33_FRESH_VERSION", str(work / "001_version.log"))
    outer = q._strict_rows(work / "strict-outer.jsonl", outer=True)
    inner = q._strict_rows(work / "strict-inner.jsonl", outer=False)
    count_elab = lambda rows: sum("--lint-only" in row["forwarded"] or "--cc" in row["forwarded"]
                                  for row in rows)
    strict = {"outer_calls": len(outer), "inner_calls": len(inner),
              "outer_elaborations": count_elab(outer), "inner_elaborations": count_elab(inner),
              "outer_stripped_count": 0, "inner_stripped_count": 0}
    if (strict != completed.get("strict") or strict != {
            "outer_calls": 13, "inner_calls": 52, "outer_elaborations": 12,
            "inner_elaborations": 12, "outer_stripped_count": 0, "inner_stripped_count": 0}):
        q.fail("P33_FRESH_STRICT", json.dumps(strict, sort_keys=True))

    def check_raw(row):
        path = Path(row.get("raw_log", ""))
        if (path.parent != work or path.name not in commands
                or row.get("raw_log_sha256") != commands[path.name]["raw_log_sha256"]):
            q.fail("P33_FRESH_RAW_REFERENCE", json.dumps(row, sort_keys=True))
        return path

    if len(completed.get("matrix", [])) != 3:
        q.fail("P33_FRESH_MATRIX", "EXPECTED_THREE_VARIANTS")
    for row, (name, values) in zip(completed["matrix"], p33.MATRIX):
        if row.get("variant") != name or row.get("parameters") != dict(zip(p33.PARAMETER_NAMES, values)):
            q.fail("P33_FRESH_MATRIX", "PARAMETER_IDENTITY")
        check_raw(row)
    behavior = completed.get("behavior", {})
    expected_behavior = {"store", "wrap_gen1", "wrap_gen2", "wrap_gen3", "deadline",
                         "memory", "memorywrap", "order", "guard"}
    if set(behavior) != expected_behavior:
        q.fail("P33_FRESH_BEHAVIOR", "EXPECTED_NINE_SIMULATIONS")
    for name, parameters, mode, markers in p33.CASES:
        actual = p33.markers_in_log(q, check_raw(behavior[name]), markers, mode=mode,
                                    parameters=parameters)
        if behavior[name] != actual:
            q.fail("P33_FRESH_BEHAVIOR", "RAW_CONTRACT_DISAGREEMENT:" + name)
    for name, parameters, markers, summarizer in (
            ("memory", (), p33.MEMORY_MARKERS, None),
            ("memorywrap", ("-GMODE=1", "-GGEN=1"),
             p33.MEMORY_WRAP_MARKERS, p33.memory_wrap_summary),
            ("order", (), p33.ORDER_MARKERS, p33.order_summary),
            ("guard", (), p33.GUARD_MARKERS, p33.guard_summary)):
        actual = p33.markers_in_log(q, check_raw(behavior[name]), markers,
                                    parameters=parameters)
        if summarizer is not None:
            actual["summary"] = summarizer(q, Path(actual["raw_log"]))
        if behavior[name] != actual:
            q.fail("P33_FRESH_BEHAVIOR", "RAW_CONTRACT_DISAGREEMENT:" + name)

    child = completed.get("p32_predecessor", {})
    child_log = check_raw(child)
    if (commands[child_log.name]["command"] != ["/usr/bin/python3", "-u",
                                                  str(ROOT / "tests/run_prod_seam_p32.py")]
            or child.get("rc") != 0 or child.get("mode") != "fresh-unchanged-canonical-runner"):
        q.fail("P33_FRESH_CHAIN", "P32_RUNNER_COMMAND_IDENTITY")
    audited_child = p33.audit_fresh_p32(q, SimpleNamespace(
        stdout=child_log.read_text(encoding="utf-8"), log=child_log, rc=0),
        p32, p31, frozen, pre_identity)
    if child != audited_child:
        q.fail("P33_FRESH_CHAIN", "INDEPENDENT_P32_RAW_AUDIT_DISAGREEMENT")
    names = ("p33-receipt.json", "p33-completed-stages.json", "summary.json", "containment.json",
             "checkpoint-before.json", "checkpoint-after.json", "index-before.raw",
             "strict-outer.jsonl", "strict-inner.jsonl", "strict-policy.json",
             "toolchain-provenance.json")
    return {"mode": "fresh-unchanged-canonical-runner", "raw_log": str(result.log),
            "raw_log_sha256": sha256(result.log), "rc": result.rc, "work": str(work),
            "receipt": str(receipt_path), "receipt_sha256": sha256(receipt_path),
            "artifact_sha256": {name: sha256(work / name) for name in names},
            "commands": commands, "strict": strict, "p32_predecessor": audited_child,
            "containment": containment, "frozen_p33_receipt_sha256": P33_RECEIPT_SHA}



class NormalizedLog:
    """Read-only marker view; identity always binds the original raw file."""
    def __init__(self, path):
        self.path = Path(path)
    def read_text(self, **kwargs):
        return self.path.read_text(**kwargs).replace("P34_PREDECESSOR_P33_ORDER_GUARD", "P33_ORDER_GUARD").replace(
            "P34_PREDECESSOR_P33_", "PROD_SEAM_P33_")

def regression(q, row, predecessor, markers, parameters=(), mode=None, summarizer=None):
    lines = row.stdout.splitlines()
    expected = [m.replace("PROD_SEAM_P33_", "P34_PREDECESSOR_P33_").replace(
        "P33_ORDER_GUARD", "P34_PREDECESSOR_P33_ORDER_GUARD") for m in markers]
    ensure(q, expected and all(lines.count(m)==1 for m in expected), "ADAPTED_REGRESSION_MARKERS:"+str(row.log))
    summary = None
    if mode is not None:
        matches = [list(map(int,m.groups())) for line in lines if (m := re.fullmatch(
            r"P34_PREDECESSOR_P33_STORE_BEHAVIOR=PASS mode=(\d+) issues=(\d+) success=(\d+) abort=(\d+) rearm=(\d+)",line))]
        gen = [int(p.split("=",1)[1]) for p in parameters if p.startswith("-GGEN=")]
        ensure(q, len(gen)==1, "ADAPTED_STORE_GEN_PARAMETER")
        wanted = [0,11,6,3,3] if mode==0 else ([2,5,3,2,2] if mode==2 else [1,(1<<gen[0])+1,(1<<gen[0])+1,0,0])
        ensure(q, matches==[wanted], "ADAPTED_STORE_EXACT_ACCOUNTING:"+repr(matches))
        summary = dict(zip(("mode","issues","success","abort","rearm"),wanted))
    elif summarizer is not None:
        summary = summarizer(q, NormalizedLog(row.log))
    return {"raw_log":str(row.log),"raw_log_sha256":sha256(row.log),
            "required_markers":expected,"parameters":list(parameters),"summary":summary}

def audit_toolchain_domains(q, child):
    domains=[(Path(child["work"]),33,13,52,12)]
    c32=child["p32_predecessor"]; c31=c32["p31_predecessor"]; c30=c31["p30_predecessor"]
    domains += [(Path(c32["work"]),32,13,52,12),(Path(c31["work"]),31,10,40,9),
                (Path(c30["work"]),30,25,100,21)]
    ensure(q, len({p for p,_,_,_,_ in domains}|{q.work})==5,"INDEPENDENT_INSTRUMENTATION_DOMAINS")
    for work, milestone, outer_count, inner_count, elab_count in domains:
        provenance=read_json(work/"toolchain-provenance.json")
        ensure(q, provenance["archive_sha256"]=="55fc5164d252a2e660fa1e574ef474dbd62338e8b4d37b2a5d7fa6d808bd5451",
               "CHILD_TOOLCHAIN_ARCHIVE:"+str(work))
        for name, expected in provenance["identities"].items():
            path=Path(name)
            ensure(q, path.is_file() and not path.is_symlink() and work in path.parents and sha256(path)==expected,
                   "CHILD_PHYSICAL_TOOLCHAIN:"+name)
        outer=q._strict_rows(work/"strict-outer.jsonl",outer=True)
        inner=q._strict_rows(work/"strict-inner.jsonl",outer=False)
        elabs=lambda rows:sum("--lint-only" in r["forwarded"] or "--cc" in r["forwarded"] for r in rows)
        actual={"outer_calls":len(outer),"inner_calls":len(inner),"outer_elaborations":elabs(outer),
                "inner_elaborations":elabs(inner),"outer_stripped_count":0,"inner_stripped_count":0}
        ensure(q, actual==read_json(work/f"p{milestone}-completed-stages.json")["strict"]==
               {"outer_calls":outer_count,"inner_calls":inner_count,"outer_elaborations":elab_count,
                "inner_elaborations":elab_count,"outer_stripped_count":0,"inner_stripped_count":0},
               "CHILD_EXACT_STRICT_DOMAIN:"+str(milestone))
        # Recheck raw C++ compiler diagnostics too, not only Verilator streams.
        for log in work.glob("*_make.log"):
            ensure(q, not re.search(r"(?im)%Warning|%Error|\bwarning:|\berror:",log.read_text()),
                   "CHILD_COMPILER_DIAGNOSTIC:"+str(log))

def main():
    resource.setrlimit(resource.RLIMIT_CORE,(0,0))
    parser=argparse.ArgumentParser()
    parser.add_argument("--work-root",type=Path,default=Path("/tmp"))
    args=parser.parse_args()
    q=Qualification(checkpoint=ROOT.parent,label="p34_gate",work_root=args.work_root)
    try:
        with q:
            p33,p32,p31,frozen=frozen_guard(q)
            own=own_sources()
            ensure(q,len(own)==17,"EXACT_SEVENTEEN_P34_SUCCESSORS")
            q._json("p34-source-identities-before.json",own)
            q.bootstrap()
            identity=git_guard(q,"pre")
            sources=[ROOT/"rtl/memory"/n for n in (*FROZEN_RTL,*NEW_RTL)]
            ensure(q,len(sources)==len(set(sources))==18,"EXACT_RTL_SOURCE_SET")
            matrix=[]
            for index,(name,values) in enumerate(p33.MATRIX):
                params=[f"-G{k}={v}" for k,v in zip(p33.PARAMETER_NAMES,values,strict=True)]
                params.append(f"-GCOHERENCE_GEN_W={index+1}")
                row=q.verilator([*STRICT_FLAGS,"--lint-only","--top-module",TOP,"--Mdir",q.work/("lint_"+name),*params,*sources],"lint_"+name)
                matrix.append({"variant":name,"parameters":params,"raw_log":str(row.log),"raw_log_sha256":sha256(row.log)})
            components={}
            for name,words,sets,gen in COMPONENT_MATRIX:
                row=simulation(q,COMPONENT_TOP+"_tb",[ROOT/"rtl/memory"/(COMPONENT_TOP+".sv"),
                    ROOT/"tests/rtl"/(COMPONENT_TOP+"_tb.sv")],"component_"+name,
                    [f"-GLINE_WORDS={words}",f"-GSET_COUNT={sets}",f"-GGEN_W={gen}"])
                components[name]={"raw_log":str(row.log),"raw_log_sha256":sha256(row.log),
                                  "summary":behavior_summary(q,row,words,sets,gen)}
            integrated={}
            for variant in range(3):
                row=simulation(q,TB,[*sources,ROOT/"tests/rtl"/(TB+".sv")],"integrated_"+str(variant),[f"-GVARIANT={variant}"])
                integrated[str(variant)]={"raw_log":str(row.log),"raw_log_sha256":sha256(row.log),
                                          "summary":direct_behavior(q,row,variant)}
            behavior={}
            for name,params,mode,markers in p33.CASES:
                top="a0_p34_predecessor_store_tb"
                row=simulation(q,top,[*sources,ROOT/"tests/rtl"/(top+".sv")],"predecessor_"+name,params)
                behavior[name]=regression(q,row,p33,markers,params,mode=mode)
            for name,top,params,markers,summarizer in (
                ("memory","a0_p34_predecessor_memory_tb",(),p33.MEMORY_MARKERS,None),
                ("memorywrap","a0_p34_predecessor_memory_tb",("-GMODE=1","-GGEN=1"),p33.MEMORY_WRAP_MARKERS,p33.memory_wrap_summary),
                ("order","a0_p34_predecessor_order_tb",(),p33.ORDER_MARKERS,p33.order_summary),
                ("guard","a0_p34_predecessor_guard_tb",(),p33.GUARD_MARKERS,p33.guard_summary)):
                selected=[ROOT/"rtl/memory/a0_store_read_coherence_order_guard.sv"] if name=="guard" else sources
                row=simulation(q,top,[*selected,ROOT/"tests/rtl"/(top+".sv")],"predecessor_"+name,params)
                behavior[name]=regression(q,row,p33,markers,params,summarizer=summarizer)
            result=q.run(["/usr/bin/python3","-u",ROOT/"tests/run_prod_seam_p33.py"],
                         "p33_canonical",timeout=12000,reject_diagnostics=True)
            child=audit_fresh_p33(q,result,p33,p32,p31,frozen,identity)
            audit_toolchain_domains(q,child)
            frozen_guard(q)
            ensure(q,own_sources()==own,"P34_SOURCE_CHANGED_DURING_GATE")
            post=git_guard(q,"post")
            ensure(q,post==identity,"P34_GIT_CHANGED")
            strict=q.assert_strict(minimum_elaborations=18)
            ensure(q,strict=={"outer_calls":19,"inner_calls":76,"outer_elaborations":18,
                "inner_elaborations":18,"outer_stripped_count":0,"inner_stripped_count":0},"P34_STRICT_EXACT_ACCOUNTING")
            commands=p31.command_records(q,q.work,expected_count=62)
            completed={"matrix":matrix,"components":components,"integrated":integrated,"behavior":behavior,
                "p33_predecessor":child,"strict":strict,"commands":commands,"pre_identity":identity,
                "post_identity":post,"p34_source_sha256":own,"frozen_p33_source_sha256":P33_OWN,
                "frozen_predecessor_sha256":frozen,"live_containment_policy":p33.LIVE_CONTAINMENT_POLICY,
                "live_containment_execution":"EXTERNAL_BOUNDED_SUPERVISOR_REQUIRED","rtl_source_count":len(sources)}
            q._json("p34-completed-stages.json",completed)
        summary=read_json(q.work/"summary.json"); containment=read_json(q.work/"containment.json")
        ensure(q,summary["first_failure"] is None and summary["secondary_errors"]==[] and summary["strict_verified"] is True
            and containment=={"added":[],"changed":[],"removed":[],"raw_index_identical":True,"unchanged":True}
            and own_sources()==own,"P34_FINAL_CONTAINMENT")
        receipt=q._json("p34-receipt.json",{"gate":"PROD_SEAM_P34_GATE=PASS","completed_stages":completed,
                        "summary":summary,"containment":containment})
        print("PROD_SEAM_P34_EXACT_VERILATOR_5_050=PASS")
        print("PROD_SEAM_P34_STRICT_LINT=PASS variants=3")
        print("PROD_SEAM_P34_BEHAVIOR=PASS simulations=15")
        print("PROD_SEAM_P34_P33_PREDECESSOR=PASS mode=fresh-unchanged-canonical-runner")
        print("PROD_SEAM_P34_P32_P31_P30_P27_P28_P29_CHAIN=PASS mode=fresh-via-P33")
        print("PROD_SEAM_P34_OUTER_STRICT_LEAK=0")
        print("PROD_SEAM_P34_INNER_STRICT_LEAK=0")
        print("PROD_SEAM_P34_POST_CONTAINMENT=PASS")
        print("PROD_SEAM_P34_RAW_INDEX_IDENTICAL=PASS")
        print("PROD_SEAM_P34_RECEIPT="+str(receipt))
        print("PROD_SEAM_P34_GATE=PASS")
        return 0
    except BaseException as error:
        failure=q._first_failure or {"stage":getattr(error,"stage","EXCEPTION"),
            "detail":getattr(error,"detail",repr(error)),"rc":getattr(error,"rc",1)}
        print("PROD_SEAM_P34_FIRST_FAILURE="+json.dumps(failure,sort_keys=True),file=sys.stderr)
        print("RAW_EVIDENCE="+str(q.work),file=sys.stderr)
        rc=failure["rc"]
        return rc if 0<rc<256 else 1

if __name__=="__main__":
    raise SystemExit(main())
