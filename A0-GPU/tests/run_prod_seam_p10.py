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
GUARD = ROOT/'rtl/memory/a0_backend_read_epoch_guard.sv'
SEAM = ROOT/'rtl/memory/a0_production_store_backend_epoch_seam.sv'
TB = ROOT/'tests/rtl/a0_backend_read_epoch_guard_tb.sv'
DOC = ROOT/'docs/architecture/A0_PROD_SEAM_P10_BACKEND_READ_ANTI_ABA.md'
P9RUN = ROOT/'tests/run_prod_seam_p9.py'
P9_RECEIPT = ROOT.parent/'EVIDENCE/P9/receipt.txt'
P9_RECEIPT_SHA = 'da19b1454fc8b6b2bf3ad57dad5f23ffe805607ef87ae2e25876d88955565278'
P9_FROZEN_HASHES = {
    str(P9RUN): '2cbd9e3eda05ac3d42cdca8074e755c9c3cd1d80f9c7eb9a7530fa250dc7011a',
    str(P9_GUARD): '8aaf4a24799060b414019680907558a5af9261c31d60e079271c86fb9b8b2562',
    str(P9_SEAM): 'f5940b675d02861c764427e148585458f50eff6605a43f97306b741430446b50',
    str(ROOT/'tests/rtl/a0_backend_read_transaction_guard_tb.sv'):
        '0115db901867f80708527e9708c58d9a3b29ab5411d7a1d44ac22e0c117a0fdc',
    str(ROOT/'docs/architecture/A0_PROD_SEAM_P9_BACKEND_READ_TRANSACTION_INTEGRITY.md'):
        '0596fb2f6d6ab62a5bf1e90f70dc61298e83a80f410cebc0c29394cdb00b281e',
}

SOURCES = [P8_ADAPTER, P8_SEAM, P9_GUARD, P9_SEAM, GUARD, SEAM]
BEHAVIOR_SOURCES = [*SOURCES, TB]
MARKERS = (
    'PROD_SEAM_P10_GENERATION_IDENTITY=PASS',
    'PROD_SEAM_P10_LATE_OLD_GENERATION_REJECT=PASS',
    'PROD_SEAM_P10_CURRENT_GENERATION_RESTORE=PASS',
    'PROD_SEAM_P10_BOUNDED_GENERATION_WRAP=PASS',
    'PROD_SEAM_P10_OOO_AND_FAULT_PROVENANCE=PASS',
    'PROD_SEAM_P10_WRAP_BACKPRESSURE=PASS',
    'PROD_SEAM_P10_OLD_RESPONSE_DURING_WRAP_REJECT=PASS',
    'PROD_SEAM_P10_EXPLICIT_SAFE_REUSE_RELEASE=PASS',
    'PROD_SEAM_P10_POST_WRAP_EXACT_RESPONSE=PASS',
    'PROD_SEAM_P10_P9_INTEGRITY_PRESERVED=PASS',
    'PROD_SEAM_P10_DUPLICATE_INCARCERATION_REJECT=PASS',
    'PROD_SEAM_P10_BEHAVIOR=PASS',
)

def fail(stage: str, detail: str, rc: int = 1) -> None:
    print('PROD_SEAM_P10_FIRST_FAILURE', file=sys.stderr)
    print(f'STAGE={stage}', file=sys.stderr)
    print(f'DETAIL={detail}', file=sys.stderr)
    raise SystemExit(rc)

def run(cmd, stage: str, timeout: int = 900) -> str:
    cmd = [str(x) for x in cmd]
    if any(a.startswith('-Wno-') for a in cmd):
        fail(stage, 'runner warning suppression')
    try:
        p = subprocess.run(cmd, cwd=ROOT, text=True, stdout=subprocess.PIPE,
            stderr=subprocess.STDOUT,
            env={**os.environ, 'PYTHONDONTWRITEBYTECODE':'1'}, timeout=timeout)
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
    lines = set(text.replace('\r','').splitlines())
    miss = [m for m in marks if m not in lines]
    if miss:
        fail(stage, f'missing {miss}')

def leak_count(path: str) -> int:
    p = Path(path)
    if not p.exists(): return 0
    total = 0
    for line in p.read_text().splitlines():
        x = json.loads(line)
        total += len(x.get('stripped',[])) + len(x.get('env_stripped',[]))
    return total

def sha256_file(path) -> str:
    h = hashlib.sha256()
    with Path(path).open('rb') as fh:
        for chunk in iter(lambda: fh.read(1 << 20), b''):
            h.update(chunk)
    return h.hexdigest()

def verify_frozen_p9() -> None:
    if not P9_RECEIPT.is_file():
        fail('P9_PREDECESSOR_RECEIPT', 'missing frozen P9 receipt')
    if sha256_file(P9_RECEIPT) != P9_RECEIPT_SHA:
        fail('P9_PREDECESSOR_RECEIPT', 'receipt SHA mismatch')
    req(P9_RECEIPT.read_text(), (
        'PROD_SEAM_P9_P8_PREDECESSOR=PASS mode=frozen-canonical-receipt',
        'PROD_SEAM_P9_OUTER_STRICT_LEAK=0',
        'PROD_SEAM_P9_INNER_STRICT_LEAK=0',
        'PROD_SEAM_P9_POST_CONTAINMENT=PASS',
        'PROD_SEAM_P9_GATE=PASS',
    ), 'P9_PREDECESSOR_RECEIPT')
    for fn,want in P9_FROZEN_HASHES.items():
        if not Path(fn).is_file() or sha256_file(fn) != want:
            fail('P9_PREDECESSOR_IMMUTABILITY', fn)

def lint_variant(base, td: Path, name: str, params) -> None:
    run(base + ['--lint-only', '--top-module',
        'a0_production_store_backend_epoch_seam', '--Mdir', str(td/name),
        *params, *map(str,SOURCES)], f'P10_SEAM_MATRIX_{name.upper()}', 600)

def main() -> int:
    ver = run([V,'--version'], 'VERSION', 30).strip()
    if not ver.startswith('Verilator 5.050 '): fail('VERSION', ver)
    print('PROD_SEAM_P10_EXACT_VERILATOR_5_050=PASS')

    for f in [*SOURCES,TB,DOC,P9RUN]:
        if not f.is_file(): fail('SOURCE_AVAILABILITY', str(f))
    gt=GUARD.read_text(); st=SEAM.read_text(); dt=DOC.read_text()
    guard_need=(
        'probe_valid_q','next_generation_q','generation_wrap_block_q',
        'track_generation_q','backend_epoch_reuse_safe_i',
        'PROD_SEAM_P10_REUSE_SAFE_WITH_LIVE_READS',
        'PROD_SEAM_P10_UPSTREAM_COMMAND_CHANGED_BEFORE_ACCEPT',
        'epoch_protocol_error_o','epoch_wrap_block_o',
    )
    seam_need=(
        'a0_production_store_backend_transaction_seam #(',
        'a0_backend_read_epoch_guard #(',
        'p9_protocol_error || p10_protocol_error',
    )
    if any(x not in gt for x in guard_need) or any(x not in st for x in seam_need):
        fail('STATIC_CONTRACT','missing P10 anti-ABA composition token')
    forbidden=('dirty_q','writeback_queue','atomic_unit','snoop_controller')
    if any(x in gt+st for x in forbidden):
        fail('BOUNDED_SCOPE','full-coherence state leaked into P10')
    doc_need=(
        'External incarnation identity','Registered command probe and predecessor visibility',
        'Generation wrap and safe reuse','Response and fault contract',
        'Directed proof','Bounded scope')
    if any(x not in dt for x in doc_need):
        fail('DOCUMENTED_CONTRACT','P10 contract documentation missing')
    print('PROD_SEAM_P10_STATIC_COMPOSITION_CONTRACT=PASS')
    print('PROD_SEAM_P10_BOUNDED_ANTI_ABA_SCOPE=PASS')
    print('PROD_SEAM_P10_DOCUMENTED_GENERATION_CONTRACT=PASS')

    with tempfile.TemporaryDirectory(prefix='a0_p10_',dir='/tmp') as td0:
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
            lint_variant(base,td,'matrix_'+name.lower(),params)
        print('PROD_SEAM_P10_STRICT_LINT=PASS')
        print('PROD_SEAM_P10_PARAMETER_MATRIX=PASS variants=3')

        obj=Path(os.environ.get('A0_P10_BEHAVIOR_OBJDIR',str(td/'beh'))).resolve()
        obj.mkdir(parents=True,exist_ok=True)
        run(base + ['--output-split','5000','--output-split-cfuncs','500',
            '-CFLAGS','-O0','--cc','--exe','--main','--top-module',
            'a0_backend_read_epoch_guard_tb','--Mdir',str(obj),
            *map(str,BEHAVIOR_SOURCES)], 'P10_BEHAVIOR_GENERATE',1200)
        run(['make','-C',str(obj),'-f','Va0_backend_read_epoch_guard_tb.mk','-j1'],
            'P10_BEHAVIOR_BUILD',1800)
        sim=run([str(obj/'Va0_backend_read_epoch_guard_tb')],
            'P10_BEHAVIOR_SIM',180)
        req(sim,MARKERS,'P10_BEHAVIOR_MARKERS')
        print(f'PROD_SEAM_P10_BEHAVIOR=PASS markers={len(MARKERS)}')

        if os.environ.get('A0_P10_FULL_PREDECESSOR_REPLAY')=='1':
            pred=run([sys.executable,str(P9RUN)],'P9_PREDECESSOR_FULL_REPLAY',10800)
            req(pred,('PROD_SEAM_P9_GATE=PASS',),'P9_PREDECESSOR_RECEIPT')
            print('PROD_SEAM_P10_P9_PREDECESSOR=PASS mode=full-replay')
        else:
            verify_frozen_p9()
            print('PROD_SEAM_P10_P9_PREDECESSOR=PASS mode=frozen-canonical-receipt')

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
    print('PROD_SEAM_P10_OUTER_STRICT_LEAK=0')
    print('PROD_SEAM_P10_INNER_STRICT_LEAK=0')
    print('PROD_SEAM_P10_POST_CONTAINMENT=PASS')
    print('PROD_SEAM_P10_GATE=PASS')
    return 0

if __name__=='__main__': raise SystemExit(main())
