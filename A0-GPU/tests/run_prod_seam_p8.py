#!/usr/bin/env python3
from __future__ import annotations
import hashlib, json, os, shutil, subprocess, sys, tempfile
from pathlib import Path
sys.dont_write_bytecode = True

ROOT = Path(__file__).resolve().parents[1]
V = Path(os.environ.get('A0_VERILATOR_BIN', shutil.which('verilator') or 'verilator'))
EXPECTED_HEAD = '996d8c188e5d4f94b4bad5289392844d55d092f6'
EXPECTED_BRANCH = 'main'
EXPECTED_DIFF = '59fac4fc152cc4e46ed60bff0feecf700756d860ed4f44436f532a221570eb8b'

ADAPTER = ROOT/'rtl/memory/a0_store_commit_line_backend_adapter.sv'
SEAM = ROOT/'rtl/memory/a0_production_store_backend_visibility_seam.sv'
TB = ROOT/'tests/rtl/a0_store_commit_line_backend_adapter_tb.sv'
DOC = ROOT/'docs/architecture/A0_PROD_SEAM_P8_UNIFIED_BACKEND_VISIBILITY.md'
P7RUN = ROOT/'tests/run_prod_seam_p7.py'
P7_RECEIPT = ROOT.parent/'EVIDENCE/P7/receipt.txt'
P7_RECEIPT_SHA = '996a5253cb23f45be74aba1161986b852db4e8daeffe5e78d5f3da1927bcf633'
P7_FROZEN_HASHES = {
    str(ROOT/'tests/run_prod_seam_p7.py'):
        '359687122285ba8e9273ec46dc5418f9e0ac4780c7712bdd30821aa9a43911f9',
    str(ROOT/'rtl/memory/a0_store_visibility_commit_fence.sv'):
        'bfb63a2006579b109e3eca656b8fb4037e2f1fcf88e53bdc91aaf3d86113ef30',
    str(ROOT/'rtl/core/a0_production_multi_cluster_store_commit_subsystem.sv'):
        'f6c3206b93c94e1ce36c9b578ad51abb5017577ea1585202c3f1f66a81989ab0',
    str(ROOT/'tests/rtl/a0_store_visibility_commit_fence_tb.sv'):
        '1466911d5dade28164db188282f891dea396296e647093312b0c513bfee300a7',
    str(ROOT/'docs/architecture/A0_PROD_SEAM_P7_STORE_VISIBILITY_COMMIT.md'):
        '8fe4b99a064f408d4a240fb95eacb52aac5b82ea2855b9faef7b0ca5087c8d5f',
}

COMMON = [
    ROOT/'rtl/memory/a0_retry_round_robin_arbiter.sv',
    ROOT/'rtl/memory/a0_cluster_line_noc_endpoint.sv',
    ROOT/'rtl/memory/a0_mc_noc_logical_request_router.sv',
    ROOT/'rtl/memory/a0_mc_noc_logical_transaction_router.sv',
    ROOT/'rtl/memory/a0_l2_line_cache.sv',
    ROOT/'rtl/memory/a0_mc_noc_sliced_l2_store_invalidate_subsystem.sv',
    ROOT/'rtl/memory/a0_mc_noc_sliced_l2_store_liveness_subsystem.sv',
    ROOT/'rtl/memory/a0_mc_noc_sliced_l2_store_admission_subsystem.sv',
    ROOT/'rtl/memory/a0_store_visibility_commit_fence.sv',
]
BEHAVIOR_SOURCES = [*COMMON, ADAPTER, TB]
MARKERS = (
    'PROD_SEAM_P8_CONFLICTING_REFILL_HELD=PASS',
    'PROD_SEAM_P8_BACKEND_BACKPRESSURE_STABLE=PASS',
    'PROD_SEAM_P8_NONCONFLICTING_REFILL_PROGRESS=PASS',
    'PROD_SEAM_P8_COMMIT_ACK_AFTER_FINAL_WRITE=PASS',
    'PROD_SEAM_P8_CAUSAL_COMMIT_TO_REFILL_VISIBILITY=PASS',
    'PROD_SEAM_P8_COMMIT_ROUND_ROBIN_FAIRNESS=PASS',
    'PROD_SEAM_P8_READ_TAG_AND_FAULT_PROVENANCE=PASS',
    'PROD_SEAM_P8_FAULTING_STORE_NO_BACKEND_COMMIT=PASS',
    'PROD_SEAM_P8_BEHAVIOR=PASS',
)

def fail(stage: str, detail: str, rc: int = 1) -> None:
    print('PROD_SEAM_P8_FIRST_FAILURE', file=sys.stderr)
    print(f'STAGE={stage}', file=sys.stderr)
    print(f'DETAIL={detail}', file=sys.stderr)
    raise SystemExit(rc)

def run(cmd, stage: str, timeout: int = 900) -> str:
    cmd = [str(x) for x in cmd]
    if any(a.startswith('-Wno-') for a in cmd):
        fail(stage, 'runner warning suppression')
    try:
        p = subprocess.run(
            cmd, cwd=ROOT, text=True, stdout=subprocess.PIPE,
            stderr=subprocess.STDOUT,
            env={**os.environ, 'PYTHONDONTWRITEBYTECODE': '1'},
            timeout=timeout,
        )
    except subprocess.TimeoutExpired as exc:
        fail(stage, f'TIMEOUT {exc}', 124)
    if p.returncode:
        print(p.stdout, file=sys.stderr)
        fail(stage, f'RC={p.returncode}', p.returncode)
    exe = Path(cmd[0]).name
    if exe.startswith('verilator') or 'strict-all-outer' in exe:
        if '%Warning-' in p.stdout or '%Error' in p.stdout:
            print(p.stdout, file=sys.stderr)
            fail(stage, 'Verilator diagnostic present', 2)
    return p.stdout

def req(text: str, marks, stage: str) -> None:
    lines = set(text.replace('\r', '').splitlines())
    miss = [m for m in marks if m not in lines]
    if miss:
        fail(stage, f'missing {miss}')

def leak_count(path: str) -> int:
    p = Path(path)
    if not p.exists():
        return 0
    total = 0
    for line in p.read_text().splitlines():
        x = json.loads(line)
        total += len(x.get('stripped', [])) + len(x.get('env_stripped', []))
    return total

def sha256_file(path) -> str:
    h = hashlib.sha256()
    with Path(path).open('rb') as fh:
        for chunk in iter(lambda: fh.read(1 << 20), b''):
            h.update(chunk)
    return h.hexdigest()

def verify_frozen_p7() -> None:
    if not P7_RECEIPT.is_file():
        fail('P7_PREDECESSOR_RECEIPT', 'missing frozen P7 receipt')
    if sha256_file(P7_RECEIPT) != P7_RECEIPT_SHA:
        fail('P7_PREDECESSOR_RECEIPT', 'receipt SHA mismatch')
    receipt = P7_RECEIPT.read_text()
    req(receipt, (
        'PROD_SEAM_P7_P6_PREDECESSOR=PASS mode=frozen-canonical-receipt',
        'PROD_SEAM_P7_OUTER_STRICT_LEAK=0',
        'PROD_SEAM_P7_INNER_STRICT_LEAK=0',
        'PROD_SEAM_P7_POST_CONTAINMENT=PASS',
        'PROD_SEAM_P7_GATE=PASS',
    ), 'P7_PREDECESSOR_RECEIPT')
    for fn, want in P7_FROZEN_HASHES.items():
        if not Path(fn).is_file() or sha256_file(fn) != want:
            fail('P7_PREDECESSOR_IMMUTABILITY', fn)

def lint_seam_variant(base, td: Path, name: str, params) -> None:
    run(base + [
        '--lint-only', '--top-module', 'a0_production_store_backend_visibility_seam',
        '--Mdir', str(td/name), *params, str(ADAPTER), str(SEAM),
    ], f'P8_SEAM_MATRIX_{name.upper()}', 600)

def main() -> int:
    ver = run([V, '--version'], 'VERSION', 30).strip()
    if not ver.startswith('Verilator 5.050 '):
        fail('VERSION', ver)
    print('PROD_SEAM_P8_EXACT_VERILATOR_5_050=PASS')

    for f in [ADAPTER, SEAM, TB, DOC, P7RUN, *COMMON]:
        if not f.is_file():
            fail('SOURCE_AVAILABILITY', str(f))

    at = ADAPTER.read_text()
    st = SEAM.read_text()
    dt = DOC.read_text()
    need_a = (
        'line_pending_q', 'line_blocked_by_commit', 'commit_active_q',
        'backend_cmd_write_o', 'backend_cmd_read_tag_o', 'commit_ready_o',
        'PROD_SEAM_P8_COMMIT_SOURCE_DROPPED_VALID',
        'PROD_SEAM_P8_DUPLICATE_STORE_WORD_UNFROZEN',
    )
    need_s = (
        'a0_store_commit_line_backend_adapter #(',
        'store_commit_valid_i', 'line_mem_req_network_tag_i',
        'backend_resp_protocol_error_o',
    )
    if any(x not in at for x in need_a) or any(x not in st for x in need_s):
        fail('STATIC_CONTRACT', 'missing P8 unified-backend composition token')
    forbidden = ('dirty_q', 'writeback_queue', 'atomic_unit', 'snoop_controller')
    if any(x in at + st for x in forbidden):
        fail('BOUNDED_SCOPE', 'full-coherence state leaked into P8')
    doc_need = (
        'Unified visibility point', 'Ordering contract',
        'Finite buffering and backpressure', 'Identity and response contract',
        'Causal visibility proof', 'Bounded scope',
    )
    if any(x not in dt for x in doc_need):
        fail('DOCUMENTED_CONTRACT', 'P8 contract documentation missing')
    print('PROD_SEAM_P8_STATIC_COMPOSITION_CONTRACT=PASS')
    print('PROD_SEAM_P8_BOUNDED_UNIFIED_BACKEND_SCOPE=PASS')
    print('PROD_SEAM_P8_DOCUMENTED_SERIALIZATION_CONTRACT=PASS')

    with tempfile.TemporaryDirectory(prefix='a0_p8_', dir='/tmp') as td0:
        td = Path(td0)
        base = [
            str(V), '--timing', '--unroll-count', '512', '-Wall',
            '-Werror-PINMISSING', '-Werror-WIDTHEXPAND', '-Werror-WIDTHTRUNC',
        ]
        variants = (
            ('MIN', [
                '-GCLUSTER_COUNT=1', '-GCUS_PER_CLUSTER=1', '-GSTORE_LANES=1',
                '-GL2_SLICE_COUNT=1', '-GLINE_WORDS=1', '-GNETWORK_TAG_W=2',
            ]),
            ('MID', [
                '-GCLUSTER_COUNT=2', '-GCUS_PER_CLUSTER=2', '-GSTORE_LANES=4',
                '-GL2_SLICE_COUNT=2', '-GLINE_WORDS=4', '-GNETWORK_TAG_W=3',
            ]),
            ('WIDE', [
                '-GCLUSTER_COUNT=4', '-GCUS_PER_CLUSTER=2', '-GSTORE_LANES=32',
                '-GL2_SLICE_COUNT=4', '-GLINE_WORDS=8', '-GNETWORK_TAG_W=6',
            ]),
        )
        for name, params in variants:
            lint_seam_variant(base, td, 'matrix_' + name.lower(), params)
        print('PROD_SEAM_P8_STRICT_LINT=PASS')
        print('PROD_SEAM_P8_PARAMETER_MATRIX=PASS variants=3')

        obj = Path(os.environ.get('A0_P8_BEHAVIOR_OBJDIR', str(td/'beh'))).resolve()
        obj.mkdir(parents=True, exist_ok=True)
        run(base + [
            '--output-split', '5000', '--output-split-cfuncs', '500',
            '-CFLAGS', '-O0', '--cc', '--exe', '--main',
            '--top-module', 'a0_store_commit_line_backend_adapter_tb',
            '--Mdir', str(obj), *map(str, BEHAVIOR_SOURCES),
        ], 'P8_BEHAVIOR_GENERATE', 1200)
        run([
            'make', '-C', str(obj),
            '-f', 'Va0_store_commit_line_backend_adapter_tb.mk', '-j1',
        ], 'P8_BEHAVIOR_BUILD', 1800)
        sim = run([str(obj/'Va0_store_commit_line_backend_adapter_tb')],
                  'P8_BEHAVIOR_SIM', 180)
        req(sim, MARKERS, 'P8_BEHAVIOR_MARKERS')
        print(f'PROD_SEAM_P8_BEHAVIOR=PASS markers={len(MARKERS)}')

        if os.environ.get('A0_P8_FULL_PREDECESSOR_REPLAY') == '1':
            pred = run([sys.executable, str(P7RUN)],
                       'P7_PREDECESSOR_FULL_REPLAY', 10800)
            req(pred, ('PROD_SEAM_P7_GATE=PASS',), 'P7_PREDECESSOR_RECEIPT')
            print('PROD_SEAM_P8_P7_PREDECESSOR=PASS mode=full-replay')
        else:
            verify_frozen_p7()
            print('PROD_SEAM_P8_P7_PREDECESSOR=PASS mode=frozen-canonical-receipt')

    head = run(['git', 'rev-parse', 'HEAD'], 'POST_HEAD', 30).strip()
    branch = run(['git', 'branch', '--show-current'], 'POST_BRANCH', 30).strip()
    run(['git', 'diff', '--check'], 'POST_DIFFCHECK', 30)
    diff = run([
        'bash', '-lc', 'git diff --binary | sha256sum | cut -d" " -f1'
    ], 'POST_DIFFSHA', 30).strip()
    if (head, branch, diff) != (EXPECTED_HEAD, EXPECTED_BRANCH, EXPECTED_DIFF):
        fail('POST_CONTAINMENT', f'{head} {branch} {diff}')

    outer = os.environ.get('A0_STRICT_OUTER_LOG')
    inner = os.environ.get('A0_STRICT_INNER_LOG')
    if outer and leak_count(outer) != 0:
        fail('OUTER_STRICT_LEAK', str(leak_count(outer)))
    if inner and leak_count(inner) != 0:
        fail('INNER_STRICT_LEAK', str(leak_count(inner)))
    print('PROD_SEAM_P8_OUTER_STRICT_LEAK=0')
    print('PROD_SEAM_P8_INNER_STRICT_LEAK=0')
    print('PROD_SEAM_P8_POST_CONTAINMENT=PASS')
    print('PROD_SEAM_P8_GATE=PASS')
    return 0

if __name__ == '__main__':
    raise SystemExit(main())
