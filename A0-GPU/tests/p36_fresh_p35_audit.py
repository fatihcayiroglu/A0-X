#!/usr/bin/python3
"""P36-owned read-only audit of a fresh, unchanged P35 predecessor run.

Importing this module executes no qualification. ROOT follows this file's
eventual native A0-GPU/tests location; no former P35 lifecycle root or promotion
receipt is used. The caller owns execution and supplies the actual work root.
"""
import sys
sys.dont_write_bytecode = True
import hashlib
import importlib
import json
import math
import os
from pathlib import Path
import re
import subprocess
from types import SimpleNamespace
from p34_validation_support import Qualification, snapshot_tree, sha256

ROOT = Path(__file__).resolve().parents[2]
REPO = ROOT / 'A0-GPU'
P35_RECEIPT = 'EVIDENCE/P35/CANONICAL/p35-receipt.json'
P35_RECEIPT_SHA = '79ce33bdd34ade80af116addf77a544b441f68bce0837651d42e76d908ef870c'
P35_ZIP = Path('/mnt/d/A0-X-GPU-PROD-SEAM-P35-CLOSED-checkpoint-2026-09-30.zip')
P35_ZIP_SHA = 'bfccbfc46ac797b106e41a29171f56763c1507ee14bf85d203245734480e4811'
P35_ZIP_BYTES = 652134477
FROZEN_ZIPS = {
    'FROZEN/P30/A0-X-GPU-PROD-SEAM-P30-CLOSED-checkpoint-2026-09-12.zip':
        ('101ab718cdf1da26b82315b53c2bce3dcb9b468a93920868848dab56d1c4d01c', 19626801),
    'FROZEN/P31/A0-X-GPU-PROD-SEAM-P31-CLOSED-checkpoint-2026-09-13.zip':
        ('3335932acfc2957f16b742bb41ffe8912a0e50b0eb5df54d9dd13c9a06f9ffb1', 20569498),
    'FROZEN/P32/A0-X-GPU-PROD-SEAM-P32-CLOSED-checkpoint-2026-09-20.zip':
        ('3b74175b000c4e6d3f8427f7687d04fe11c604755c4a88397395e425238872a7', 66771686),
    'FROZEN/P33/A0-X-GPU-PROD-SEAM-P33-CLOSED-checkpoint-2026-09-23.zip':
        ('62f7ec115cb55fb101ae6542e58106f33c2cd990b6a29fcc4d1784c098f0a92b', 143006112),
    'FROZEN/P34/A0-X-GPU-PROD-SEAM-P34-CLOSED-checkpoint-2026-09-27.zip':
        ('018a06006a957f3edb2884ccc9df5f1447d824bbc1c3a6a916431b5923c44390', 300441330),
}
CLEAN = {'added': [], 'changed': [], 'removed': [],
         'unchanged': True, 'raw_index_identical': True}
STRICT = {'outer_calls': 16, 'inner_calls': 64, 'outer_elaborations': 15,
          'inner_elaborations': 15, 'outer_stripped_count': 0, 'inner_stripped_count': 0}
DOMAIN_COUNTS = {
    'P35': (16, 64, 15), 'EXPECTED_NEGATIVE': (2, 8, 1),
    'P34': (19, 76, 18), 'P33': (13, 52, 12),
    'P32': (13, 52, 12), 'P31': (10, 40, 9), 'P30': (25, 100, 21),
}
TOOLCHAIN_SHA = '55fc5164d252a2e660fa1e574ef474dbd62338e8b4d37b2a5d7fa6d808bd5451'
TOOLCHAIN_MANIFEST_SHA = '1fa59cbbb14d90e10463e3a219d61b50d46a925d8ff8592082db3cc7bb718a84'
PHYSICAL_TOOLS = {
    'strict-all-outer-verilator.py':
        '03bd901f94adf465a0bbf2b688408d9a384a56183e99ec3480a037e0eed2fd67',
    'toolchain/verilator/bin/verilator':
        'fb2cc573b1055cf096c90e1efc9966fe56bdb4b265c83590cf2a49f7a0defcdf',
    'toolchain/verilator/bin/verilator_bin':
        '270d17005174e8133cabe11ad9f62a7b5e43989abfde6e4217d0792df39a2f79',
    'toolchain/verilator/bin/verilator_bin.real':
        '0875b51592784da5c412e8d80be3ffb56549e2d37e560d9eb43e0ec6e489877f',
}
DIAGNOSTIC = re.compile(r'(?im)%Warning|%Error|\bwarning:|\berror:')


def need(condition, detail):
    if not condition:
        raise RuntimeError('P36_FRESH_P35:' + detail)


def read_json(path):
    return json.loads(Path(path).read_text(encoding='utf-8'))


def regular(path):
    path = Path(path)
    need(path.is_file() and not path.is_symlink()
         and path.resolve(strict=True) == path, 'EXACT_REGULAR_PATH:' + str(path))
    return path


def frozen_archives():
    pins = {}
    for name, (expected, size) in FROZEN_ZIPS.items():
        path = regular(ROOT / name)
        need(path.stat().st_size == size and sha256(path) == expected,
             'FROZEN_ZIP:' + name)
        pins[str(path)] = {'sha256': expected, 'bytes': size}
    path = regular(P35_ZIP)
    need(path.stat().st_size == P35_ZIP_BYTES and sha256(path) == P35_ZIP_SHA,
         'FROZEN_P35_ZIP')
    pins[str(path)] = {'sha256': P35_ZIP_SHA, 'bytes': P35_ZIP_BYTES}
    return pins


def git_identity():
    """Read exact identities without optional refresh or inherited Git overrides."""
    index = (REPO / '.git/index').read_bytes()
    env = {key: value for key, value in os.environ.items() if not key.startswith('GIT_')}
    env['GIT_OPTIONAL_LOCKS'] = '0'
    def git(*args):
        row = subprocess.run(['/usr/bin/git', '-c', 'diff.autoRefreshIndex=false',
                              '-C', str(REPO), *args],
                             stdout=subprocess.PIPE, stderr=subprocess.PIPE,
                             env=env, timeout=30)
        need(row.returncode == 0 and not row.stderr, 'READ_ONLY_GIT:' + repr(args))
        return row.stdout
    git('diff', '--check')
    result = {
        'head': git('rev-parse', 'HEAD').decode().strip(),
        'branch': git('branch', '--show-current').decode().strip(),
        'tracked_diff_sha256': hashlib.sha256(git('diff', '--binary')).hexdigest(),
        'index_semantic_sha256': hashlib.sha256(git('ls-files', '--stage', '-z')).hexdigest(),
        'raw_index_sha256': sha256(REPO / '.git/index'),
        'staged_changes': git('diff', '--cached', '--name-status').decode(),
    }
    need((REPO / '.git/index').read_bytes() == index, 'READ_ONLY_GIT_RAW_INDEX')
    return result


def owned_work(path, parent, prefix):
    path, parent = Path(path), Path(parent)
    need(path.parent == parent and path.name.startswith(prefix) and path.is_dir()
         and not path.is_symlink() and path.resolve(strict=True) == path,
         'EXACT_OWNED_WORK:' + str(path))
    return path


class Reader:
    _strict_rows = Qualification._strict_rows
    def __init__(self, work, before, index):
        self.work, self.before, self.checkpoint, self.index_before = work, before, ROOT, index
    def fail(self, stage, detail, rc=1):
        raise RuntimeError(f'P36_FRESH_P35:{stage}:{detail}:rc={rc}')


def numeric(value, positive=False):
    return type(value) in (int, float) and math.isfinite(value) and (value > 0 if positive else value >= 0)


def command_lifecycle(path, rc=0):
    path = regular(path)
    meta = read_json(path)
    log = regular(path.with_suffix('.log'))
    need(meta['raw_log'] == str(log) and meta['raw_log_sha256'] == sha256(log)
         and meta['rc'] == rc and meta['timed_out'] is False and meta['interrupted'] is False
         and meta['lifecycle']['group_gone'] is True
         and meta['lifecycle']['group_existed_after_wait'] is False
         and numeric(meta['timeout_seconds'], positive=True) and numeric(meta['elapsed_seconds']),
         'RAW_COMMAND_LIFECYCLE:' + str(path))
    return meta


def strict_domain(reader, work, label, exact_version):
    """Verify real executables, outer/inner boundaries, diagnostics and lifecycle."""
    outer = reader._strict_rows(work / 'strict-outer.jsonl', outer=True)
    inner = reader._strict_rows(work / 'strict-inner.jsonl', outer=False)
    elab = lambda rows: sum('--cc' in row['forwarded'] or '--lint-only' in row['forwarded'] for row in rows)
    count_outer, count_inner, count_elab = DOMAIN_COUNTS[label]
    actual = {'outer_calls': len(outer), 'inner_calls': len(inner),
              'outer_elaborations': elab(outer), 'inner_elaborations': elab(inner),
              'outer_stripped_count': 0, 'inner_stripped_count': 0}
    expected = {'outer_calls': count_outer, 'inner_calls': count_inner,
                'outer_elaborations': count_elab, 'inner_elaborations': count_elab,
                'outer_stripped_count': 0, 'inner_stripped_count': 0}
    need(actual == expected, 'EXACT_STRICT_DOMAIN:' + label)
    need((work / '001_version.log').read_text().strip() == exact_version,
         'EXACT_VERSION_DOMAIN:' + label)
    provenance = read_json(work / 'toolchain-provenance.json')
    expected_tools = {str(work / name): expected for name, expected in PHYSICAL_TOOLS.items()}
    need(provenance['archive'] == str(ROOT / 'TOOLCHAIN/verilator-manylinux2014_x86_64-5.050.tar.gz')
         and provenance['archive_sha256'] == TOOLCHAIN_SHA
         and provenance['manifest_sha256'] == TOOLCHAIN_MANIFEST_SHA
         and provenance['identities'] == expected_tools, 'PHYSICAL_TOOLCHAIN_PROVENANCE:' + label)
    for name, expected_sha in expected_tools.items():
        need(sha256(regular(name)) == expected_sha, 'PHYSICAL_TOOLCHAIN_BYTES:' + name)
    metadata = {}
    for path in sorted(work.glob('[0-9][0-9][0-9]_*.json')):
        row = read_json(path)
        if 'command' not in row:
            need(path.name.endswith('_strict-verification.json'), 'UNEXPECTED_NONCOMMAND:' + str(path))
            continue
        is_negative = label == 'EXPECTED_NEGATIVE' and path.name == '004_mutant_sim.json'
        expected_rc = read_json(work / 'summary.json')['first_failure']['rc'] if is_negative else 0
        row = command_lifecycle(path, expected_rc)
        if not is_negative and row['command'][0] != '/usr/bin/git':
            need(DIAGNOSTIC.search(path.with_suffix('.log').read_text()) is None,
                 'DOMAIN_DIAGNOSTIC:' + str(path))
        metadata[str(path)] = sha256(path)
    need(metadata, 'EMPTY_DOMAIN_COMMANDS:' + label)
    return {'work': str(work), 'strict': actual, 'physical_tool_sha256': expected_tools,
            'command_metadata_sha256': metadata, 'compile_diagnostics': '0/0',
            'suppression_leaks': '0/0'}


def audit_fresh_p35(q, result, work_root, identity):
    """Return raw-bound predecessor evidence; execute no compiler or gate."""
    work_root = Path(work_root)
    need(work_root.is_dir() and not work_root.is_symlink()
         and work_root.resolve(strict=True) == work_root
         and work_root != ROOT and ROOT not in work_root.parents, 'EXPLICIT_EXTERNAL_WORK_ROOT')
    need(q.checkpoint == ROOT and result.rc == 0, 'PARENT_ROOT_AND_CHILD_RC')
    before, index = q.before, (REPO / '.git/index').read_bytes()
    need(index == q.index_before and snapshot_tree(ROOT) == before, 'PREAUDIT_FULL_SOURCE_RAW_INDEX')
    frozen = frozen_archives()
    frozen_receipt_path = regular(ROOT / P35_RECEIPT)
    need(sha256(frozen_receipt_path) == P35_RECEIPT_SHA, 'FROZEN_P35_CANONICAL_RECEIPT')
    frozen_receipt = read_json(frozen_receipt_path)
    frozen_completed = frozen_receipt['completed_stages']
    log = regular(result.log)
    need(log.parent == q.work and result.stdout == log.read_text(), 'PARENT_RAW_RESULT')
    parent = command_lifecycle(log.with_suffix('.json'))
    need(parent['command'] == ['/usr/bin/python3', '-u', str(REPO / 'tests/run_prod_seam_p35.py'),
                               '--work-root', str(work_root)]
         and parent['cwd'] == str(REPO), 'EXACT_PARENT_CHILD_INVOCATION')
    lines = result.stdout.splitlines()
    for marker in ('PROD_SEAM_P35_GATE=PASS', 'PROD_SEAM_P35_EXACT_VERILATOR_5_050=PASS',
                   'PROD_SEAM_P35_BEHAVIOR=PASS simulations=12 scenarios=123',
                   'PROD_SEAM_P35_DEDUP_MUTATION=DETECTED',
                   'PROD_SEAM_P35_P34_PREDECESSOR=PASS mode=fresh-unchanged-canonical-runner',
                   'PROD_SEAM_P35_OUTER_STRICT_LEAK=0', 'PROD_SEAM_P35_INNER_STRICT_LEAK=0',
                   'PROD_SEAM_P35_POST_CONTAINMENT=PASS', 'PROD_SEAM_P35_RAW_INDEX_IDENTICAL=PASS'):
        need(lines.count(marker) == 1, 'EXACT_FRESH_MARKER:' + marker)
    def one(prefix):
        values = [line.removeprefix(prefix) for line in lines if line.startswith(prefix)]
        need(len(values) == 1, 'EXACT_ONE_VALUE:' + prefix)
        return values[0]
    work = owned_work(one('VALIDATION_WORK='), work_root, 'a0_p30_p35_gate_')
    need(work != q.work, 'SEPARATE_CHILD_DOMAIN')
    path = regular(work / 'p35-receipt.json')
    need(Path(one('PROD_SEAM_P35_RECEIPT=')) == path, 'CHILD_RECEIPT_PATH')
    receipt_sha = sha256(path)
    receipt, completed = read_json(path), read_json(work / 'p35-completed-stages.json')
    summary, containment = read_json(work / 'summary.json'), read_json(work / 'containment.json')
    need(receipt == {'gate': 'PROD_SEAM_P35_GATE=PASS', 'completed_stages': completed,
                     'summary': summary, 'containment': containment}, 'CANONICAL_RECEIPT_BINDING')
    need(summary == {'checkpoint': str(ROOT), 'work': str(work), 'first_failure': None,
                     'secondary_errors': [], 'strict_verified': True} and containment == CLEAN,
         'CANONICAL_SUMMARY_CONTAINMENT')
    need(before == read_json(work / 'checkpoint-before.json') == read_json(work / 'checkpoint-after.json')
         and index == (work / 'index-before.raw').read_bytes(), 'FULL_CHILD_SOURCE_RAW_INDEX')
    sys.path.insert(0, str(REPO / 'tests'))
    runner = importlib.import_module('run_prod_seam_p35')
    need(runner.ROOT == REPO and runner.p34.ROOT == REPO and runner.audit34.ROOT == ROOT
         and runner.mutation.ROOT == REPO, 'CURRENT_NATIVE_AUDITOR_ROOTS')
    reader = Reader(work, before, index)
    _, _, p31, predecessor_hashes = runner.frozen_guard(reader)
    own = runner.own_sources()
    need(len(own) == 14 and own == completed['p35_source_sha256']
         == frozen_completed['p35_source_sha256'], 'EXACT_FROZEN_P35_FOURTEEN_SOURCES')
    need(completed['frozen_p34_source_sha256'] == runner.p34.own_sources()
         == frozen_completed['frozen_p34_source_sha256']
         and completed['frozen_predecessor_sha256'] == predecessor_hashes
         == frozen_completed['frozen_predecessor_sha256'], 'FROZEN_PREDECESSOR_SOURCE_CHAIN')
    need(identity == git_identity() == completed['pre_identity'] == completed['post_identity']
         == read_json(work / 'pre-git-identity.json') == read_json(work / 'post-git-identity.json'),
         'EXACT_CHILD_GIT_IDENTITY')
    need(completed['work_root'] == str(work_root)
         and completed['exact_version'] == runner.EXACT_VERSION == frozen_completed['exact_version']
         and completed['live_containment_policy'] == frozen_completed['live_containment_policy']
         and completed['live_containment_execution'] == 'EXTERNAL_BOUNDED_SUPERVISOR_REQUIRED',
         'EXACT_VERSION_WORK_ROOT_LIVE_POLICY')
    commands = p31.command_records(reader, work, expected_count=54)
    need(commands == completed['commands'], 'RAW_54_COMMAND_RECEIPT_BINDING')
    expected = runner.exact_commands(reader, commands, work, work_root)
    outer = reader._strict_rows(work / 'strict-outer.jsonl', outer=True)
    need([row['forwarded'] for row in outer] == [argv[1:] for _, argv, _, _ in expected
         if argv[0] == str(work / 'strict-all-outer-verilator.py')], 'OUTER_TO_COMMAND_BINDING')
    need(completed['strict'] == runner.STRICT == STRICT, 'EXACT_PARENT_STRICT_ACCOUNTING')
    def raw(row, stage):
        raw_log = regular(row['raw_log'])
        need(raw_log.parent == work and raw_log.name in commands
             and raw_log.name.endswith('_' + stage + '.log')
             and sha256(raw_log) == row['raw_log_sha256'], 'RAW_STAGE_BINDING:' + stage)
        return SimpleNamespace(log=raw_log, stdout=raw_log.read_text(), rc=0)
    need(len(completed['matrix']) == 3 and set(completed['behavior']) == set(runner.PHASES),
         'EXACT_SUITE_CARDINALITY')
    for variant, row in enumerate(completed['matrix']):
        need(row['variant'] == variant and row['parameters'] == runner.lint_parameters(variant),
             'LINT_VARIANT_PARAMETERS')
        raw(row, 'lint_' + str(variant))
    scenarios = 0
    for phase in runner.PHASES:
        need(set(completed['behavior'][phase]) == {'0', '1', '2'}, 'THREE_BEHAVIOR_VARIANTS')
        for variant in range(3):
            row = completed['behavior'][phase][str(variant)]
            counts = runner.parse_behavior(raw(row, phase + '_' + str(variant) + '_sim').stdout, phase, variant)
            need(row['counts'] == counts, 'EXACT_RAW_BEHAVIOR_COUNTS')
            scenarios += counts['scenarios']
    need(scenarios == 123, 'EXACT_123_SCENARIO_INSTANCES')
    negative = runner.mutation_result(reader, raw(completed['mutation'], 'dedup_mutation'), work_root)
    need(negative == completed['mutation'], 'NEGATIVE_RAW_REAUDIT_BINDING')
    negative_work = owned_work(negative['work'], work_root, 'a0_p30_p35_expected_mutation_')
    predecessor = runner.predecessor_result(reader, raw(completed['p34_predecessor'], 'p34_canonical'),
                                            work_root, identity)
    need(predecessor == completed['p34_predecessor'], 'P34_TO_P30_RECURSIVE_RAW_BINDING')
    predecessor_works = [Path(predecessor['work']), *(Path(p) for p in predecessor['child_work'])]
    need(len(predecessor_works) == 5, 'EXACT_FIVE_PREDECESSOR_DOMAINS')
    domains = [('P35', work), ('EXPECTED_NEGATIVE', negative_work),
               *zip(('P34', 'P33', 'P32', 'P31', 'P30'), predecessor_works, strict=True)]
    need(len({path for _, path in domains}) == 7 and q.work not in {path for _, path in domains},
         'SEVEN_INDEPENDENT_CHILD_DOMAINS')
    domain_audits = {label: strict_domain(reader, domain, label, runner.EXACT_VERSION)
                     for label, domain in domains}
    need(snapshot_tree(ROOT) == before and (REPO / '.git/index').read_bytes() == index
         and git_identity() == identity and sha256(path) == receipt_sha
         and sha256(frozen_receipt_path) == P35_RECEIPT_SHA and frozen_archives() == frozen,
         'POST_RAW_AUDIT_SOURCE_GIT_INDEX_FROZEN_IDENTITY')
    artifacts = ('p35-receipt.json', 'p35-completed-stages.json', 'summary.json', 'containment.json',
                 'checkpoint-before.json', 'checkpoint-after.json', 'index-before.raw',
                 'strict-outer.jsonl', 'strict-inner.jsonl', 'strict-policy.json',
                 'toolchain-provenance.json', 'pre-git-identity.json', 'post-git-identity.json')
    return {'mode': 'fresh-unchanged-canonical-runner', 'work': str(work), 'receipt': str(path),
            'receipt_sha256': receipt_sha, 'raw_log': str(log), 'raw_log_sha256': sha256(log),
            'rc': result.rc, 'parent_command_metadata_sha256': sha256(log.with_suffix('.json')),
            'artifact_sha256': {name: sha256(regular(work / name)) for name in artifacts},
            'commands': commands, 'strict': completed['strict'], 'p35_source_sha256': own,
            'exact_version': runner.EXACT_VERSION, 'work_root': str(work_root),
            'frozen_p35_receipt_sha256': P35_RECEIPT_SHA, 'frozen_zip_identities': frozen,
            'negative_work': str(negative_work), 'negative_mutation': negative,
            'p34_predecessor': predecessor, 'predecessor_work': [str(p) for p in predecessor_works],
            'child_work': [str(negative_work), *(str(p) for p in predecessor_works)],
            'qualified_domains': domain_audits, 'scenario_instances': scenarios,
            'simulations': 12, 'compile_diagnostics': '0/0', 'suppression_leaks': '0/0',
            'containment': containment, 'live_containment_execution': 'EXTERNAL_BOUNDED_SUPERVISOR_REQUIRED'}
