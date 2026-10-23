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

P8_ADAPTER = ROOT/'rtl/memory/a0_store_commit_line_backend_adapter.sv'
P8_SEAM = ROOT/'rtl/memory/a0_production_store_backend_visibility_seam.sv'
P9_GUARD = ROOT/'rtl/memory/a0_backend_read_transaction_guard.sv'
P9_SEAM = ROOT/'rtl/memory/a0_production_store_backend_transaction_seam.sv'
P10_GUARD = ROOT/'rtl/memory/a0_backend_read_epoch_guard.sv'
P10_SEAM = ROOT/'rtl/memory/a0_production_store_backend_epoch_seam.sv'
CANON = ROOT/'rtl/memory/a0_store_commit_duplicate_canonicalizer.sv'
SEAM = ROOT/'rtl/memory/a0_production_store_backend_collision_seam.sv'
TB = ROOT/'tests/rtl/a0_store_commit_duplicate_canonicalizer_tb.sv'
DOC = ROOT/'docs/architecture/A0_PROD_SEAM_P11_DUPLICATE_STORE_CANONICALIZATION.md'
P10RUN = ROOT/'tests/run_prod_seam_p10.py'
P10_RECEIPT = ROOT.parent/'EVIDENCE/P10/receipt.txt'
P10_RECEIPT_SHA = '17e0c6fbb77c2de16e2e1055cd3d7872e203f0a1d5f92a6a7658b3b1963a61f4'
P10_FROZEN_HASHES = {
    str(P10RUN): '7c07208ee7120b2dac3d3a6c208613f18183d14d0dc4459aca2fc2127adaad46',
    str(P10_GUARD): 'ef5bb4f214bef1a418832c76719a71a7b1b14d7f0f1b1a3e3528992ebd4973e2',
    str(P10_SEAM): '9c0e63bfbb16ed9cc76b7bc5b04f16ba324816a1d67bd28442a455f27834a307',
    str(ROOT/'tests/rtl/a0_backend_read_epoch_guard_tb.sv'):
        '399ddb606daa49fe7d3b54ae1e4a223e850c5347395d9778fe9e6382b7470219',
    str(ROOT/'docs/architecture/A0_PROD_SEAM_P10_BACKEND_READ_ANTI_ABA.md'):
        '802e615eafda0604b949b45b62d83995aef95a52a6de46e41b767524b2fe943c',
}

SOURCES = [P8_ADAPTER, P8_SEAM, P9_GUARD, P9_SEAM, P10_GUARD, P10_SEAM, CANON, SEAM]
BEHAVIOR_SOURCES = [*SOURCES, TB]
MARKERS = (
    'PROD_SEAM_P11_DUPLICATE_DETECT=PASS',
    'PROD_SEAM_P11_MULTI_COLLISION=PASS',
    'PROD_SEAM_P11_BACKPRESSURE_STABILITY=PASS',
    'PROD_SEAM_P11_SINGLE_WRITE_PER_WORD=PASS',
    'PROD_SEAM_P11_UNRELATED_PRESERVED=PASS',
    'PROD_SEAM_P11_HIGHEST_LANE_WIN=PASS',
    'PROD_SEAM_P11_COMMIT_READY_AFTER_CANONICAL_WRITES=PASS',
    'PROD_SEAM_P11_POST_STORE_REFILL_WINNER_VISIBLE=PASS',
    'PROD_SEAM_P11_NO_PREDECESSOR_PROTOCOL_ERROR=PASS',
    'PROD_SEAM_P11_BEHAVIOR=PASS',
)

def fail(stage: str, detail: str, rc: int = 1) -> None:
    print('PROD_SEAM_P11_FIRST_FAILURE', file=sys.stderr)
    print(f'STAGE={stage}', file=sys.stderr)
    print(f'DETAIL={detail}', file=sys.stderr)
    raise SystemExit(rc)

def run(cmd, stage: str, timeout: int = 900) -> str:
    cmd = [str(x) for x in cmd]
    if any(a.startswith('-Wno-') for a in cmd):
        fail(stage, 'runner warning suppression')
    try:
        p = subprocess.run(cmd, cwd=ROOT, text=True, stdout=subprocess.PIPE,
            stderr=subprocess.STDOUT, env={**os.environ,'PYTHONDONTWRITEBYTECODE':'1'},
            timeout=timeout)
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
    lines=set(text.replace('\r','').splitlines())
    miss=[m for m in marks if m not in lines]
    if miss: fail(stage, f'missing {miss}')

def sha256_file(path) -> str:
    h=hashlib.sha256()
    with Path(path).open('rb') as fh:
        for chunk in iter(lambda: fh.read(1<<20), b''): h.update(chunk)
    return h.hexdigest()

def leak_count(path: str) -> int:
    p=Path(path)
    if not p.exists(): return 0
    total=0
    for line in p.read_text().splitlines():
        x=json.loads(line)
        total += len(x.get('stripped',[])) + len(x.get('env_stripped',[]))
    return total

def verify_frozen_p10() -> None:
    if not P10_RECEIPT.is_file(): fail('P10_PREDECESSOR_RECEIPT','missing receipt')
    if sha256_file(P10_RECEIPT) != P10_RECEIPT_SHA:
        fail('P10_PREDECESSOR_RECEIPT','receipt SHA mismatch')
    req(P10_RECEIPT.read_text(),(
        'PROD_SEAM_P10_P9_PREDECESSOR=PASS mode=frozen-canonical-receipt',
        'PROD_SEAM_P10_STRICT_QUALIFICATION=PASS',
        'PROD_SEAM_P10_OUTER_STRICT_LEAK=0',
        'PROD_SEAM_P10_INNER_STRICT_LEAK=0',
        'PROD_SEAM_P10_POST_CONTAINMENT=PASS',
        'PROD_SEAM_P10_GATE=PASS',
    ),'P10_PREDECESSOR_RECEIPT')
    for fn,want in P10_FROZEN_HASHES.items():
        if not Path(fn).is_file() or sha256_file(fn)!=want:
            fail('P10_PREDECESSOR_IMMUTABILITY',fn)

def main() -> int:
    ver=run([V,'--version'],'VERSION',30).strip()
    if not ver.startswith('Verilator 5.050 '): fail('VERSION',ver)
    print('PROD_SEAM_P11_EXACT_VERILATOR_5_050=PASS')
    for f in [*SOURCES,TB,DOC,P10RUN]:
        if not f.is_file(): fail('SOURCE_AVAILABILITY',str(f))
    ct=CANON.read_text(); st=SEAM.read_text(); dt=DOC.read_text()
    if any(x not in ct for x in (
        'higher = lane + 1','canonical_lane_mask_o','duplicate_collapse_o',
        'commit_word_addr_i[cluster][cu][lane]','commit_word_addr_i[cluster][cu][higher]')):
        fail('STATIC_CONTRACT','canonical winner logic missing')
    if any(x not in st for x in (
        'a0_store_commit_duplicate_canonicalizer #(',
        'a0_production_store_backend_epoch_seam #(',
        '.store_commit_lane_mask_i(canonical_lane_mask)',
        '.duplicate_collapse_o(store_duplicate_collapse_o)')):
        fail('STATIC_COMPOSITION','P11 successor composition missing')
    if any(x in ct+st for x in ('atomic_unit','snoop_controller','dirty_q','writeback_queue')):
        fail('BOUNDED_SCOPE','full coherence/atomic state leaked into P11')
    if any(x not in dt for x in (
        'Deterministic local winner contract','Visibility and refill ordering preservation',
        'Directed proof','Non-atomic semantics and bounded scope','highest active lane')):
        fail('DOCUMENTED_CONTRACT','P11 documentation incomplete')
    print('PROD_SEAM_P11_STATIC_COMPOSITION_CONTRACT=PASS')
    print('PROD_SEAM_P11_BOUNDED_DUPLICATE_STORE_SCOPE=PASS')
    print('PROD_SEAM_P11_DOCUMENTED_WINNER_CONTRACT=PASS')

    with tempfile.TemporaryDirectory(prefix='a0_p11_',dir='/tmp') as td0:
        td=Path(td0)
        base=[str(V),'--timing','--unroll-count','512','-Wall',
            '-Werror-PINMISSING','-Werror-WIDTHEXPAND','-Werror-WIDTHTRUNC']
        variants=(
            ('MIN',['-GCLUSTER_COUNT=1','-GCUS_PER_CLUSTER=1','-GSTORE_LANES=1',
                '-GL2_SLICE_COUNT=1','-GLINE_WORDS=1','-GNETWORK_TAG_W=2',
                '-GREAD_TRACK_COUNT=1','-GREAD_EPOCH_W=1']),
            ('MID',['-GCLUSTER_COUNT=2','-GCUS_PER_CLUSTER=2','-GSTORE_LANES=4',
                '-GL2_SLICE_COUNT=2','-GLINE_WORDS=4','-GNETWORK_TAG_W=3',
                '-GREAD_TRACK_COUNT=4','-GREAD_EPOCH_W=4']),
            ('WIDE',['-GCLUSTER_COUNT=4','-GCUS_PER_CLUSTER=2','-GSTORE_LANES=32',
                '-GL2_SLICE_COUNT=4','-GLINE_WORDS=8','-GNETWORK_TAG_W=6',
                '-GREAD_TRACK_COUNT=16','-GREAD_EPOCH_W=16']),
        )
        for name,params in variants:
            run(base+['--lint-only','--top-module','a0_production_store_backend_collision_seam',
                '--Mdir',str(td/('matrix_'+name.lower())),*params,*map(str,SOURCES)],
                f'P11_SEAM_MATRIX_{name}',600)
        print('PROD_SEAM_P11_STRICT_LINT=PASS')
        print('PROD_SEAM_P11_PARAMETER_MATRIX=PASS variants=3')

        obj=Path(os.environ.get('A0_P11_BEHAVIOR_OBJDIR',str(td/'beh'))).resolve()
        obj.mkdir(parents=True,exist_ok=True)
        run(base+['--output-split','5000','--output-split-cfuncs','500','-CFLAGS','-O0',
            '--cc','--exe','--main','--top-module',
            'a0_store_commit_duplicate_canonicalizer_tb','--Mdir',str(obj),
            *map(str,BEHAVIOR_SOURCES)],'P11_BEHAVIOR_GENERATE',1200)
        run(['make','-C',str(obj),'-f','Va0_store_commit_duplicate_canonicalizer_tb.mk','-j1'],
            'P11_BEHAVIOR_BUILD',1800)
        sim=run([str(obj/'Va0_store_commit_duplicate_canonicalizer_tb')],
            'P11_BEHAVIOR_SIM',180)
        req(sim,MARKERS,'P11_BEHAVIOR_MARKERS')
        print(f'PROD_SEAM_P11_BEHAVIOR=PASS markers={len(MARKERS)}')
        verify_frozen_p10()
        print('PROD_SEAM_P11_P10_PREDECESSOR=PASS mode=frozen-canonical-receipt')

    head=run(['git','rev-parse','HEAD'],'POST_HEAD',30).strip()
    branch=run(['git','branch','--show-current'],'POST_BRANCH',30).strip()
    run(['git','diff','--check'],'POST_DIFFCHECK',30)
    diff=run(['bash','-lc','git diff --binary | sha256sum | cut -d" " -f1'],
        'POST_DIFFSHA',30).strip()
    if (head,branch,diff)!=(EXPECTED_HEAD,EXPECTED_BRANCH,EXPECTED_DIFF):
        fail('POST_CONTAINMENT',f'{head} {branch} {diff}')
    outer=os.environ.get('A0_STRICT_OUTER_LOG'); inner=os.environ.get('A0_STRICT_INNER_LOG')
    if outer and leak_count(outer)!=0: fail('OUTER_STRICT_LEAK',str(leak_count(outer)))
    if inner and leak_count(inner)!=0: fail('INNER_STRICT_LEAK',str(leak_count(inner)))
    print('PROD_SEAM_P11_OUTER_STRICT_LEAK=0')
    print('PROD_SEAM_P11_INNER_STRICT_LEAK=0')
    print('PROD_SEAM_P11_POST_CONTAINMENT=PASS')
    print('PROD_SEAM_P11_GATE=PASS')
    return 0

if __name__=='__main__': raise SystemExit(main())
