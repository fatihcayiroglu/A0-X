#!/usr/bin/python3
"""P36 expected-negative fence witnesses, each in an independent strict domain.

Intended installed location: A0-GPU/tests/run_p36_fence_mutation.py. This draft
does not run on import. A mutant's genuine FAILED qualification summary remains
unchanged. Only its specific semantic assertion after a warning-free build and
complete containment can produce a separate mutation-detection receipt.
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
from p34_validation_support import (
    Qualification, ValidationFailure, STRICT_FLAGS, EXACT_VERSION, sha256, snapshot_tree,
)
import run_prod_seam_p35 as p35

ROOT = Path(__file__).resolve().parents[1]
CTRL = 'a0_memory_drain_fence_controller'
WRAPPER = 'a0_production_atomic_fenced_subsystem'
TOP = WRAPPER + '_tb'
KINDS = ('atomic-retire', 'raw-store')
CLEAN = {'added': [], 'changed': [], 'removed': [], 'unchanged': True, 'raw_index_identical': True}
DIAGNOSTIC = re.compile(r'(?im)%Warning|%Error|%Fatal|\bwarning:|\berror:')
STRICT = {'outer_calls': 2, 'inner_calls': 8, 'outer_elaborations': 1,
          'inner_elaborations': 1, 'outer_stripped_count': 0, 'inner_stripped_count': 0}
TOOL_IDENTITIES = {
    'strict-all-outer-verilator.py': '03bd901f94adf465a0bbf2b688408d9a384a56183e99ec3480a037e0eed2fd67',
    'toolchain/verilator/bin/verilator': 'fb2cc573b1055cf096c90e1efc9966fe56bdb4b265c83590cf2a49f7a0defcdf',
    'toolchain/verilator/bin/verilator_bin': '270d17005174e8133cabe11ad9f62a7b5e43989abfde6e4217d0792df39a2f79',
    'toolchain/verilator/bin/verilator_bin.real': '0875b51592784da5c412e8d80be3ffb56549e2d37e560d9eb43e0ec6e489877f',
}
TOOL_ARCHIVE_SHA = '55fc5164d252a2e660fa1e574ef474dbd62338e8b4d37b2a5d7fa6d808bd5451'
TOOL_MANIFEST_SHA = '1fa59cbbb14d90e10463e3a219d61b50d46a925d8ff8592082db3cc7bb718a84'
MUTATIONS = {
    'atomic-retire': {
        'module': WRAPPER, 'folder': 'p36_no_atomic_retire_drain',
        'label': 'p36_expected_atomic_retire',
        'needle': "        && !atomic_busy_o && (atomic_requester_outstanding_o=='0) && !atomic_retire_valid_o",
        'replacement': '        // NEGATIVE FIXTURE ONLY: omit all three architectural atomic-drain guards.',
        'meaning': 'OMIT_ATOMIC_BUSY_REQUESTER_OUTSTANDING_AND_RETIRE_VALID_FROM_DRAIN_QUIET',
        'scenario': 'HELD_ARCHITECTURAL_RETIRE_AND_SAME_EDGE_RETIRE_CUT',
        'preceding_scenarios': 7,
        'details': (
            'P36_FENCE_EARLY_RESPONSE directed live predecessor',
            'P36_FENCE_EARLY_RESPONSE independent predecessor obligations remain',
        ),
    },
    'raw-store': {
        'module': CTRL, 'folder': 'p36_no_raw_store_enrollment',
        'label': 'p36_expected_raw_store',
        'needle': '                    pending_q <= commit_valid_i & ~(store_complete_i | store_abort_i);',
        'replacement': "                    pending_q <= '0; // NEGATIVE FIXTURE ONLY: omit accepting-edge STORE enrollment.",
        'meaning': 'ZERO_ACCEPTING_EDGE_PENDING_STORE_ENROLLMENT',
        'scenario': 'SAME_EDGE_ALL_STORE_PORTS_CAPTURE_AND_NEW_ADMISSION_BLOCK',
        'preceding_scenarios': 4,
        'details': ('captured STORE obligation mask',),
    },
}
SCENARIO_PREFIX = (
    'EMPTY_FENCE_EXACT_RESPONSE',
    'DIRTY_RESIDENT_DRAIN_NOT_FLUSH_AND_LATER_EXACT_WB',
    'OUTSTANDING_READ_DELIVERY_DRAINS_FENCE',
    'SAME_EDGE_READ_DELIVERY_AND_FENCE_CUT',
    'SAME_EDGE_ALL_STORE_PORTS_CAPTURE_AND_NEW_ADMISSION_BLOCK',
    'CAPTURED_FULL_STORE_PAYLOAD_AND_BACKEND_PROMISE_BACKPRESSURE',
    'LIVE_WB_EXACT_PAYLOAD_AND_SAME_EDGE_STATUS_CUT',
)


def need(ok, detail):
    if not ok:
        raise RuntimeError(detail)


def read_json(path):
    return json.loads(Path(path).read_text())


def configuration(kind):
    need(kind in KINDS, 'EXACT_MUTATION_KIND')
    return MUTATIONS[kind]


def sources(kind):
    config = configuration(kind)
    good = ROOT / 'rtl/memory' / (config['module'] + '.sv')
    bad = ROOT / 'tests/fixtures' / config['folder'] / (config['module'] + '.sv')
    tb = ROOT / 'tests/rtl' / (TOP + '.sv')
    for path in (good, bad, tb):
        need(path.is_file() and not path.is_symlink(), 'MUTATION_REGULAR_SOURCE:' + str(path))
    original = good.read_bytes()
    needle, replacement = config['needle'].encode('utf-8'), config['replacement'].encode('utf-8')
    need(original.count(needle) == 1
         and bad.read_bytes() == original.replace(needle, replacement),
         'EXACT_SINGLE_INTENTIONAL_MUTATION:' + kind)
    return good, bad, tb


def selected_sources(kind):
    good, bad, tb = sources(kind)
    need(p35.ROOT == ROOT and p35.p34.ROOT == ROOT, 'EXACT_FROZEN_PREDECESSOR_SOURCE_ROOTS')
    selected = [*p35.rtl_sources(),
                *(ROOT / 'rtl/memory' / (name + '.sv') for name in p35.NEW_RTL),
                ROOT / 'rtl/memory' / (CTRL + '.sv'), ROOT / 'rtl/memory' / (WRAPPER + '.sv')]
    need(selected.count(good) == 1, 'EXACT_ONE_SELECTED_MUTANT_REPLACEMENT')
    selected = [bad if path == good else path for path in selected] + [tb]
    need(len(selected) == len(set(selected)) == 25, 'EXACT_24_RTL_PLUS_INTEGRATED_TB')
    return selected


def source_pins(kind):
    """Pin every selected dependency, good reference, bad fixture, TB and harness."""
    good, bad, tb = sources(kind)
    paths = {*selected_sources(kind), good, bad, tb, Path(__file__).resolve(),
             ROOT / 'tests/p34_validation_support.py', ROOT / 'tests/run_prod_seam_p34.py',
             ROOT / 'tests/run_prod_seam_p35.py'}
    for path in paths:
        need(path.is_file() and not path.is_symlink(), 'REGULAR_PINNED_INPUT:' + str(path))
    return {str(path): sha256(path) for path in sorted(paths)}


class Reader:
    _strict_rows = Qualification._strict_rows

    def fail(self, stage, detail, rc=1):
        raise RuntimeError(stage + ':' + detail + ':rc=' + str(rc))


def exact_witness(text, kind, tb):
    """Bind the semantic first assertion; record—not invent—the observed cycle."""
    config = configuration(kind)
    lines = text.splitlines()
    markers = [line for line in lines if line.startswith('P36_')]
    expected_markers = ['P36_INTEGRATED_SCENARIO_PASS id=' + str(number) + ' name=' + name
        for number, name in enumerate(SCENARIO_PREFIX[:config['preceding_scenarios']], 1)]
    need(markers == expected_markers and 'P36_INTEGRATED_PASS' not in text
         and 'Verilog $finish' not in text, 'EXACT_PRE_FAILURE_SCENARIO_SEQUENCE:' + kind)
    fatal_source = '        if(!ok)$fatal(1,"P36_INTEGRATED_CHECK_FAILED cycle=%0d %s",cycles,detail);'
    source_lines = tb.read_text().splitlines()
    need(source_lines.count(fatal_source) == 1, 'EXACT_BOUND_TB_FATAL_SITE')
    source_line = source_lines.index(fatal_source) + 1
    remainder = [line for line in lines if line not in expected_markers]
    need(len(remainder) == 3, 'ONLY_ONE_EXPECTED_FATAL_STOP_AND_ABORT')
    fatal = re.fullmatch(r'\[(\d+)\] %Fatal: ' + re.escape(tb.name) + ':' + str(source_line)
        + ': Assertion failed in ' + re.escape(TOP) + r'\.check: P36_INTEGRATED_CHECK_FAILED cycle=(\d+) (.+)',
        remainder[0])
    need(fatal is not None and fatal[3] in config['details'], 'EXACT_OMITTED_DRAIN_ASSERTION:' + kind)
    need(remainder[1] == '%Error: ' + str(tb) + ':' + str(source_line) + ': Verilog $stop'
         and remainder[2] == 'Aborting...', 'EXACT_VERILATOR_FATAL_TERMINATION')
    return {'scenario': config['scenario'], 'completed_scenarios': config['preceding_scenarios'],
            'assertion': fatal[3], 'observed_cycle': int(fatal[2]),
            'observed_simulation_timestamp': int(fatal[1]), 'failing_file': str(tb),
            'failing_line': source_line, 'cycle_was_not_prespecified': True}


def audit_mutation(work, before, index_before, pins, kind):
    config = configuration(kind)
    work = Path(work)
    good, bad, tb = sources(kind)
    need(not work.is_symlink() and work.resolve(strict=True) == work
         and work.name.startswith('a0_p30_' + config['label'] + '_'), 'EXACT_NEGATIVE_WORK')
    need(pins == source_pins(kind), 'EXACT_ALL_DEPENDENCY_SOURCE_PINS')
    need(read_json(work / 'checkpoint-before.json') == before
         == read_json(work / 'checkpoint-after.json') == snapshot_tree(ROOT.parent)
         and (work / 'index-before.raw').read_bytes() == index_before == (ROOT / '.git/index').read_bytes(),
         'NEGATIVE_FULL_CHECKPOINT_RAW_INDEX')
    summary = read_json(work / 'summary.json')
    failure = summary['first_failure']
    need(failure is not None and failure['stage'] == 'mutant_sim' and failure['rc'] in (1, -6)
         and failure['detail'] == 'RC=' + str(failure['rc']) + '; raw_log=' + str(work / '004_mutant_sim.log')
         and summary['secondary_errors'] == [] and summary['strict_verified'] is True
         and summary['checkpoint'] == str(ROOT.parent) and summary['work'] == str(work)
         and read_json(work / 'containment.json') == CLEAN
         and read_json(work / 'first-failure.json') == failure, 'EXPECTED_NEGATIVE_WITH_CLEAN_CONTAINMENT')
    need(read_json(work / 'negative-fixture.json') == {
        'kind': kind, 'source_sha256': pins, 'intentional_mutation': config['meaning'],
        'expected_first_failure': 'mutant_sim', 'expected_semantic_scenario': config['scenario'],
        'expected_cycle': 'NOT_PRESPECIFIED', 'real_dut_pass_claim': False}, 'NEGATIVE_INTENT_SOURCE_BINDING')
    outer = work / 'strict-all-outer-verilator.py'
    obj = work / 'mutant_obj'
    commands = [
        ('version', [str(outer), '--version'], ROOT, 30),
        ('mutant_generate', [str(outer), *STRICT_FLAGS, '--cc', '--exe', '--main', '--top-module', TOP,
            '--Mdir', str(obj), '-GVARIANT=2', *(str(path) for path in selected_sources(kind))], ROOT, 600),
        ('mutant_make', ['/usr/bin/make', '-C', str(obj), '-f', 'V' + TOP + '.mk', '-j1'], ROOT, 600),
        ('mutant_sim', [str(obj / ('V' + TOP))], work, 180),
    ]
    metadata_paths = [p for p in sorted(work.glob('[0-9][0-9][0-9]_*.json')) if 'command' in read_json(p)]
    need([p.name for p in metadata_paths] == [f'{i:03d}_{row[0]}.json' for i, row in enumerate(commands, 1)],
         'NEGATIVE_EXACT_FOUR_COMMANDS')
    records = []
    for number, (name, argv, cwd, timeout) in enumerate(commands, 1):
        path = work / f'{number:03d}_{name}.json'
        meta = read_json(path)
        log = path.with_suffix('.log')
        need(meta['command'] == argv and meta['cwd'] == str(cwd) and meta['timeout_seconds'] == timeout
             and meta['raw_log'] == str(log) and meta['raw_log_sha256'] == sha256(log)
             and not meta['timed_out'] and not meta['interrupted']
             and meta['lifecycle']['group_gone'] is True
             and meta['lifecycle']['group_existed_after_wait'] is False,
             'NEGATIVE_COMMAND_LIFECYCLE:' + name)
        need(meta['rc'] == (failure['rc'] if name == 'mutant_sim' else 0), 'NEGATIVE_EXACT_RC:' + name)
        if name != 'mutant_sim':
            need(not DIAGNOSTIC.search(log.read_text()),
                 'NEGATIVE_CLEAN_COMPILE:' + name)
        records.append({'metadata': str(path), 'sha256': sha256(path),
                        'raw_log': str(log), 'raw_log_sha256': sha256(log)})
    raw = work / '004_mutant_sim.log'
    witness = exact_witness(raw.read_text(), kind, tb)
    reader = Reader()
    outer_rows = reader._strict_rows(work / 'strict-outer.jsonl', outer=True)
    inner_rows = reader._strict_rows(work / 'strict-inner.jsonl', outer=False)
    elaborations = lambda rows: sum('--cc' in row['forwarded'] or '--lint-only' in row['forwarded'] for row in rows)
    need(len(outer_rows) == 2 and len(inner_rows) == 8
         and elaborations(outer_rows) == elaborations(inner_rows) == 1
         and [row['forwarded'] for row in outer_rows] == [commands[0][1][1:], commands[1][1][1:]],
         'NEGATIVE_EXACT_2_8_1_STRICT_DOMAIN')
    need(read_json(work / '005_strict-verification.json') == STRICT,
         'NEGATIVE_RECORDED_STRICT_MATCHES_RAW_BOUNDARIES')
    need((work / '001_version.log').read_text().strip() == EXACT_VERSION, 'NEGATIVE_EXACT_VERILATOR_VERSION')
    provenance = read_json(work / 'toolchain-provenance.json')
    archive = ROOT.parent / 'TOOLCHAIN/verilator-manylinux2014_x86_64-5.050.tar.gz'
    manifest = ROOT.parent / 'TOOLCHAIN/manifest-manylinux2014_x86_64.json'
    identities = {str(work / name): expected for name, expected in TOOL_IDENTITIES.items()}
    need(provenance['archive'] == str(archive) and provenance['archive_sha256'] == TOOL_ARCHIVE_SHA
         and provenance['manifest_sha256'] == TOOL_MANIFEST_SHA
         and sha256(archive) == TOOL_ARCHIVE_SHA and sha256(manifest) == TOOL_MANIFEST_SHA
         and provenance['identities'] == identities, 'NEGATIVE_EXACT_TOOLCHAIN_PROVENANCE')
    for name, expected in identities.items():
        path = Path(name)
        need(path.is_file() and not path.is_symlink() and path.resolve(strict=True) == path
             and sha256(path) == expected,
             'NEGATIVE_PHYSICAL_TOOLCHAIN')
    need(pins == source_pins(kind) and snapshot_tree(ROOT.parent) == before, 'POST_NEGATIVE_AUDIT_CONTAINMENT')
    return {'classification': 'P36_FENCE_MUTATION_DETECTED', 'kind': kind,
        'fixture_qualification_status': 'FAILED_AS_EXPECTED_NOT_DUT_PASS', 'work': str(work),
        'first_failure': failure, 'source_sha256': pins, 'commands': records,
        'raw_log': str(raw), 'raw_log_sha256': sha256(raw), 'witness': witness,
        'strict': {'outer_calls': 2, 'inner_calls': 8, 'elaborations': 1, 'suppression_leaks': '0/0'},
        'compile_diagnostics': '0/0', 'containment': CLEAN}


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--kind', choices=KINDS, required=True)
    parser.add_argument('--work-root', type=Path, required=True)
    args = parser.parse_args()
    resource.setrlimit(resource.RLIMIT_CORE, (0, 0))
    if sys.flags.optimize or os.environ.get('PYTHONOPTIMIZE'):
        raise SystemExit('PYTHON_OPTIMIZATION_FORBIDDEN')
    if (not args.work_root.is_dir() or args.work_root.is_symlink()
            or args.work_root.resolve(strict=True) != args.work_root
            or ROOT.parent == args.work_root or ROOT.parent in args.work_root.parents):
        raise SystemExit('P36_EXPLICIT_EXTERNAL_WORK_ROOT_REQUIRED')
    if shutil.disk_usage(args.work_root).free < 3 * 1024**3:
        raise SystemExit('P36_BUILD_ROOT_FREE_3GIB')
    config = configuration(args.kind)
    pins = source_pins(args.kind)
    q = Qualification(ROOT.parent, label=config['label'], work_root=args.work_root)
    caught = None
    try:
        with q:
            q._json('negative-fixture.json', {
                'kind': args.kind, 'source_sha256': pins, 'intentional_mutation': config['meaning'],
                'expected_first_failure': 'mutant_sim', 'expected_semantic_scenario': config['scenario'],
                'expected_cycle': 'NOT_PRESPECIFIED', 'real_dut_pass_claim': False})
            q.bootstrap()
            binary = q.build_simulation(TOP, selected_sources(args.kind), name='mutant', parameters=['-GVARIANT=2'])
            make_log = q.work / '003_mutant_make.log'
            if DIAGNOSTIC.search(make_log.read_text()):
                q.fail('mutant_make', 'COMPILE_DIAGNOSTIC; raw_log=' + str(make_log), 2)
            q.run([binary], 'mutant_sim', cwd=q.work, timeout=180)
            q.fail('MUTATION_NOT_DETECTED', 'Omitted fence drain obligation survived: ' + args.kind)
    except ValidationFailure as error:
        caught = error
    need(caught is not None and caught.stage == 'mutant_sim', 'NO_EXPECTED_FENCE_MUTATION_FAILURE')
    result = audit_mutation(q.work, q.before, q.index_before, pins, args.kind)
    receipt = q._json('mutation-detection-receipt.json', result)
    print('P36_EXPECTED_FENCE_MUTATION=DETECTED kind=' + args.kind, flush=True)
    print('P36_MUTATION_RECEIPT=' + str(receipt), flush=True)
    print('P36_MUTATION_RECEIPT_SHA256=' + sha256(receipt), flush=True)
    return 0


if __name__ == '__main__':
    raise SystemExit(main())
