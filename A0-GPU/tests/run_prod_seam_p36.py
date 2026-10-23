#!/usr/bin/python3
"""DRAFT P36 native qualification; gate PASS does not certify CLOSED.

Promote this successor file only through the separately reviewed lifecycle.
All builds and predecessor runs use the explicit external work root.
"""
import sys
sys.dont_write_bytecode = True
import argparse
import json
import os
from pathlib import Path
import re
import resource
import shutil
from p34_validation_support import Qualification, STRICT_FLAGS, EXACT_VERSION, sha256
import run_prod_seam_p35 as p35
import p36_fresh_p35_audit as audit35
import p36_behavior_audit as behavior
import run_p36_fence_mutation as mutation

ROOT = Path(__file__).resolve().parents[1]
CTRL = 'a0_memory_drain_fence_controller'
TOP = 'a0_production_atomic_fenced_subsystem'
NEW_RTL = (CTRL, TOP)
PHASES = {'component': CTRL, 'integrated': TOP}
MUTATION_KINDS = ('atomic-retire', 'raw-store')
SOURCE_NAMES = (
    'rtl/memory/' + CTRL + '.sv', 'rtl/memory/' + TOP + '.sv',
    'tests/rtl/' + CTRL + '_tb.sv', 'tests/rtl/' + TOP + '_tb.sv',
    'docs/architecture/A0_PROD_SEAM_P36_FENCE_ORDERING_CONTRACT.md',
    'tests/p36_behavior_audit.py', 'tests/p36_fresh_p35_audit.py',
    'tests/run_p36_fence_mutation.py',
    'tests/fixtures/p36_no_atomic_retire_drain/' + TOP + '.sv',
    'tests/fixtures/p36_no_raw_store_enrollment/' + CTRL + '.sv',
    'tests/run_prod_seam_p36.py',
)
STRICT = {'outer_calls': 10, 'inner_calls': 40, 'outer_elaborations': 9,
          'inner_elaborations': 9, 'outer_stripped_count': 0, 'inner_stripped_count': 0}
CLEAN = {'added': [], 'changed': [], 'removed': [],
         'unchanged': True, 'raw_index_identical': True}
DIAGNOSTIC = re.compile(r'(?im)%Warning|%Error|\bwarning:|\berror:')


def ensure(q, condition, detail):
    if not condition:
        q.fail('P36_CONTRACT', detail)


def read_json(path):
    return json.loads(Path(path).read_text(encoding='utf-8'))


def own_sources():
    return {name: sha256(ROOT / name) for name in SOURCE_NAMES}


def frozen_guard(q):
    ensure(q, p35.ROOT == ROOT and audit35.ROOT == ROOT.parent and audit35.REPO == ROOT,
           'EXACT_CURRENT_PREDECESSOR_ROOTS')
    path = ROOT.parent / audit35.P35_RECEIPT
    ensure(q, sha256(path) == audit35.P35_RECEIPT_SHA, 'FROZEN_P35_CANONICAL_RECEIPT')
    receipt = read_json(path)
    ensure(q, p35.own_sources() == receipt['completed_stages']['p35_source_sha256'],
           'FROZEN_P35_SOURCE_IDENTITY')
    _, _, p31, frozen_source = p35.frozen_guard(q)
    return p35, p31, frozen_source, audit35.frozen_archives()


def rtl_sources():
    return [*p35.rtl_sources(), *(ROOT / 'rtl/memory' / (name + '.sv') for name in p35.NEW_RTL),
            *(ROOT / 'rtl/memory' / (name + '.sv') for name in NEW_RTL)]


def selected_sources(phase):
    selected = [ROOT / 'rtl/memory' / (CTRL + '.sv')] if phase == 'component' else rtl_sources()
    return [*selected, ROOT / 'tests/rtl' / (PHASES[phase] + '_tb.sv')]


def lint_parameters(variant):
    return [f'-GCLIENT_COUNT={variant + 2}', f'-GCOMMIT_PORT_COUNT={variant + 2}',
            f'-GSTORE_LANES={variant + 1}', f'-GSLICE_COUNT={1 << variant}',
            f'-GLINE_WORDS={1 << variant}', f'-GSET_COUNT_PER_SLICE={2 << variant}',
            f'-GATOMIC_ENTRY_COUNT={2 << variant}', f'-GATOMIC_GENERATION_W={variant + 1}',
            f'-GCOHERENCE_GEN_W={variant + 1}']


def parse_behavior(text, phase, variant):
    parser = behavior.audit_component if phase == 'component' else behavior.audit_integrated
    return parser(text, variant)


def exact_commands(q, commands, work, work_root):
    outer = str(work / 'strict-all-outer-verilator.py')
    expected = [('version', [outer, '--version'], ROOT, 30)]
    def git(phase):
        for suffix, args in (('head', ['rev-parse', 'HEAD']), ('branch', ['branch', '--show-current']),
                             ('diffcheck', ['diff', '--check']), ('diff', ['diff', '--binary']),
                             ('staged', ['diff', '--cached', '--name-status']),
                             ('index_semantics', ['ls-files', '--stage', '-z'])):
            expected.append((phase + '_git_' + suffix,
                             ['/usr/bin/git', '-c', 'diff.autoRefreshIndex=false', *args], ROOT, 30))
    git('pre')
    for variant in range(3):
        name = 'lint_' + str(variant)
        expected.append((name, [outer, *STRICT_FLAGS, '--lint-only', '--top-module', TOP,
                               '--Mdir', str(work / name), *lint_parameters(variant),
                               *(str(p) for p in rtl_sources())], ROOT, 600))
    for phase, name_top in PHASES.items():
        for variant in range(3):
            name, top = phase + '_' + str(variant), name_top + '_tb'
            obj = work / (name + '_obj')
            expected.extend([
                (name + '_generate', [outer, *STRICT_FLAGS, '--cc', '--exe', '--main',
                                     '--top-module', top, '--Mdir', str(obj), f'-GVARIANT={variant}',
                                     *(str(p) for p in selected_sources(phase))], ROOT, 600),
                (name + '_make', ['/usr/bin/make', '-C', str(obj), '-f', 'V' + top + '.mk', '-j1'], ROOT, 600),
                (name + '_sim', [str(obj / ('V' + top))], work, 180),
            ])
    for kind in MUTATION_KINDS:
        expected.append(('mutation_' + kind.replace('-', '_'),
                         ['/usr/bin/python3', '-u', str(ROOT / 'tests/run_p36_fence_mutation.py'),
                          '--kind', kind, '--work-root', str(work_root)], ROOT, 1800))
    expected.append(('p35_canonical', ['/usr/bin/python3', '-u', str(ROOT / 'tests/run_prod_seam_p35.py'),
                                       '--work-root', str(work_root)], ROOT, 14400))
    git('post')
    ensure(q, len(expected) == 37 and set(commands) == {
        f'{number:03d}_{name}.log' for number, (name, _, _, _) in enumerate(expected, 1)},
        'EXACT_37_COMMAND_SEQUENCE')
    for number, (name, argv, cwd, timeout) in enumerate(expected, 1):
        row = commands[f'{number:03d}_{name}.log']
        meta = read_json(row['metadata'])
        ensure(q, row['command'] == meta['command'] == argv and meta['cwd'] == str(cwd)
               and meta['timeout_seconds'] == timeout, 'EXACT_COMMAND_CWD_TIMEOUT:' + name)
    return expected


def one_value(q, text, prefix):
    values = [line.removeprefix(prefix) for line in text.splitlines() if line.startswith(prefix)]
    ensure(q, len(values) == 1, 'EXACT_ONE_VALUE:' + prefix)
    return values[0]


def mutation_result(q, row, work_root, kind):
    ensure(q, row.rc == 0 and row.stdout.splitlines().count(
        'P36_EXPECTED_FENCE_MUTATION=DETECTED kind=' + kind) == 1, 'MUTATION_DETECTION_MARKER:' + kind)
    work = Path(one_value(q, row.stdout, 'VALIDATION_WORK='))
    ensure(q, work.parent == work_root and work != q.work and work.is_dir() and not work.is_symlink()
           and work.resolve(strict=True) == work
           and work.name.startswith('a0_p30_p36_expected_' + kind.replace('-', '_') + '_'),
           'EXACT_SEPARATE_NEGATIVE_DOMAIN:' + kind)
    path = Path(one_value(q, row.stdout, 'P36_MUTATION_RECEIPT='))
    ensure(q, path == work / 'mutation-detection-receipt.json'
           and sha256(path) == one_value(q, row.stdout, 'P36_MUTATION_RECEIPT_SHA256='),
           'NEGATIVE_RECEIPT_BINDING:' + kind)
    pins = mutation.source_pins(kind)
    actual = mutation.audit_mutation(work, q.before, q.index_before, pins, kind)
    ensure(q, read_json(path) == actual and actual['classification'] == 'P36_FENCE_MUTATION_DETECTED'
           and actual['kind'] == kind
           and actual['fixture_qualification_status'] == 'FAILED_AS_EXPECTED_NOT_DUT_PASS',
           'INDEPENDENT_NEGATIVE_RAW_REAUDIT:' + kind)
    return {'kind': kind, 'work': str(work), 'receipt': str(path), 'receipt_sha256': sha256(path),
            'raw_log': str(row.log), 'raw_log_sha256': sha256(row.log), 'audit': actual}


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument('--work-root', type=Path, required=True)
    args = parser.parse_args()
    resource.setrlimit(resource.RLIMIT_CORE, (0, 0))
    if sys.flags.optimize or os.environ.get('PYTHONOPTIMIZE'):
        raise SystemExit('PYTHON_OPTIMIZATION_FORBIDDEN')
    if (ROOT.parent.parent != Path('/tmp')
            or not ROOT.parent.name.startswith('a0_p36_checkpoint_')
            or ROOT.name != 'A0-GPU' or ROOT.is_symlink() or ROOT.parent.is_symlink()
            or ROOT.resolve(strict=True) != ROOT):
        raise SystemExit('P36_NATIVE_ISOLATED_CHECKPOINT_REQUIRED')
    if (not args.work_root.is_dir() or args.work_root.is_symlink()
            or args.work_root.resolve(strict=True) != args.work_root
            or ROOT.parent == args.work_root or ROOT.parent in args.work_root.parents):
        raise SystemExit('P36_EXPLICIT_EXTERNAL_WORK_ROOT_REQUIRED')
    if shutil.disk_usage(args.work_root).free < 3 * 1024**3:
        raise SystemExit('P36_BUILD_ROOT_FREE_3GIB')
    q = Qualification(ROOT.parent, label='p36_gate', work_root=args.work_root)
    try:
        with q:
            predecessor, p31, frozen_source, archives = frozen_guard(q)
            own = own_sources()
            ensure(q, len(own) == 11, 'EXACT_ELEVEN_P36_SUCCESSORS')
            q._json('p36-source-identities-before.json', own)
            q.bootstrap()
            identity = predecessor.p34.git_guard(q, 'pre')
            matrix, behaviors = [], {}
            for variant in range(3):
                name = 'lint_' + str(variant)
                row = q.verilator([*STRICT_FLAGS, '--lint-only', '--top-module', TOP,
                                   '--Mdir', q.work / name, *lint_parameters(variant), *rtl_sources()], name)
                matrix.append({'variant': variant, 'parameters': lint_parameters(variant),
                               'raw_log': str(row.log), 'raw_log_sha256': sha256(row.log)})
            for phase, top in PHASES.items():
                behaviors[phase] = {}
                for variant in range(3):
                    name = phase + '_' + str(variant)
                    binary = q.build_simulation(top + '_tb', selected_sources(phase), name=name,
                                                parameters=[f'-GVARIANT={variant}'])
                    logs = list(q.work.glob('*_' + name + '_make.log'))
                    ensure(q, len(logs) == 1 and not DIAGNOSTIC.search(logs[0].read_text()),
                           'CXX_DIAGNOSTICS:' + name)
                    row = q.run([binary], name + '_sim', cwd=q.work, timeout=180, reject_diagnostics=True)
                    try:
                        counts = parse_behavior(row.stdout, phase, variant)
                    except ValueError as error:
                        q.fail('P36_BEHAVIOR', str(error))
                    behaviors[phase][str(variant)] = {
                        'raw_log': str(row.log), 'raw_log_sha256': sha256(row.log), 'counts': counts}
                    print(row.stdout, end='', flush=True)
            scenarios = sum(row['counts']['scenarios'] for values in behaviors.values() for row in values.values())
            ensure(q, scenarios == 93, 'EXACT_93_SCENARIO_INSTANCES')
            mutations = {}
            for kind in MUTATION_KINDS:
                row = q.run(['/usr/bin/python3', '-u', ROOT / 'tests/run_p36_fence_mutation.py',
                             '--kind', kind, '--work-root', args.work_root],
                            'mutation_' + kind.replace('-', '_'), timeout=1800, reject_diagnostics=True)
                mutations[kind] = mutation_result(q, row, args.work_root, kind)
            row = q.run(['/usr/bin/python3', '-u', ROOT / 'tests/run_prod_seam_p35.py',
                         '--work-root', args.work_root], 'p35_canonical', timeout=14400, reject_diagnostics=True)
            fresh = audit35.audit_fresh_p35(q, row, args.work_root, identity)
            domain_paths = [str(q.work), *(r['work'] for r in mutations.values()), fresh['work'], *fresh['child_work']]
            ensure(q, len(domain_paths) == len(set(domain_paths)) == 10, 'TEN_INDEPENDENT_STRICT_DOMAINS')
            _, _, frozen_post, archives_post = frozen_guard(q)
            ensure(q, frozen_post == frozen_source and archives_post == archives and own_sources() == own,
                   'FROZEN_OWN_SOURCE_CONTAINMENT')
            post = predecessor.p34.git_guard(q, 'post')
            ensure(q, post == identity, 'P36_GIT_PRE_POST')
            strict = q.assert_strict(minimum_elaborations=9)
            ensure(q, strict == STRICT, 'EXACT_P36_STRICT_ACCOUNTING')
            commands = p31.command_records(q, q.work, expected_count=37)
            exact_commands(q, commands, q.work, args.work_root)
            completed = {'matrix': matrix, 'behavior': behaviors, 'mutations': mutations,
                         'p35_predecessor': fresh, 'p36_source_sha256': own,
                         'frozen_p35_source_sha256': predecessor.own_sources(),
                         'frozen_predecessor_sha256': frozen_source, 'frozen_archive_identities': archives,
                         'pre_identity': identity, 'post_identity': post, 'strict': strict, 'commands': commands,
                         'work_root': str(args.work_root), 'exact_version': EXACT_VERSION,
                         'live_containment_policy': read_json(ROOT.parent / audit35.P35_RECEIPT)[
                             'completed_stages']['live_containment_policy'],
                         'live_containment_execution': 'EXTERNAL_BOUNDED_SUPERVISOR_REQUIRED',
                         'simulations': 6, 'scenario_instances': scenarios, 'independent_strict_domains': 10}
            q._json('p36-completed-stages.json', completed)
        summary, containment = read_json(q.work / 'summary.json'), read_json(q.work / 'containment.json')
        ensure(q, summary['first_failure'] is None and summary['secondary_errors'] == []
               and summary['strict_verified'] is True and containment == CLEAN and own_sources() == own,
               'P36_FINAL_CONTAINMENT')
        receipt = q._json('p36-receipt.json', {'gate': 'PROD_SEAM_P36_GATE=PASS',
                                             'completed_stages': completed,
                                             'summary': summary, 'containment': containment})
        print('PROD_SEAM_P36_EXACT_VERILATOR_5_050=PASS')
        print('PROD_SEAM_P36_BEHAVIOR=PASS simulations=6 scenarios=93')
        print('PROD_SEAM_P36_ATOMIC_RETIRE_MUTATION=DETECTED')
        print('PROD_SEAM_P36_RAW_STORE_MUTATION=DETECTED')
        print('PROD_SEAM_P36_P35_PREDECESSOR=PASS mode=fresh-unchanged-canonical-runner')
        print('PROD_SEAM_P36_OUTER_STRICT_LEAK=0\nPROD_SEAM_P36_INNER_STRICT_LEAK=0')
        print('PROD_SEAM_P36_POST_CONTAINMENT=PASS\nPROD_SEAM_P36_RAW_INDEX_IDENTICAL=PASS')
        print('PROD_SEAM_P36_RECEIPT=' + str(receipt))
        print('PROD_SEAM_P36_GATE=PASS')
        return 0
    except BaseException as error:
        failure = q._first_failure or {'stage': 'P36_GATE_AUDIT', 'detail': repr(error), 'rc': 1}
        print('PROD_SEAM_P36_FIRST_FAILURE=' + json.dumps(failure, sort_keys=True), flush=True)
        return 1


if __name__ == '__main__':
    raise SystemExit(main())
