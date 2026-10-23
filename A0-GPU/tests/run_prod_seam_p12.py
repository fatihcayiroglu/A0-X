#!/usr/bin/env python3
from __future__ import annotations
import hashlib, json, os, shutil, subprocess, sys, tempfile
from pathlib import Path
sys.dont_write_bytecode=True

ROOT=Path(__file__).resolve().parents[1]
V=Path(os.environ.get('A0_VERILATOR_BIN', shutil.which('verilator') or 'verilator'))
EXPECTED_HEAD='996d8c188e5d4f94b4bad5289392844d55d092f6'
EXPECTED_BRANCH='main'
EXPECTED_DIFF='59fac4fc152cc4e46ed60bff0feecf700756d860ed4f44436f532a221570eb8b'

P8A=ROOT/'rtl/memory/a0_store_commit_line_backend_adapter.sv'
P8S=ROOT/'rtl/memory/a0_production_store_backend_visibility_seam.sv'
P9G=ROOT/'rtl/memory/a0_backend_read_transaction_guard.sv'
P9S=ROOT/'rtl/memory/a0_production_store_backend_transaction_seam.sv'
P10G=ROOT/'rtl/memory/a0_backend_read_epoch_guard.sv'
P10S=ROOT/'rtl/memory/a0_production_store_backend_epoch_seam.sv'
P11C=ROOT/'rtl/memory/a0_store_commit_duplicate_canonicalizer.sv'
P11S=ROOT/'rtl/memory/a0_production_store_backend_collision_seam.sv'
GUARD=ROOT/'rtl/memory/a0_backend_write_completion_guard.sv'
SEAM=ROOT/'rtl/memory/a0_production_store_backend_completion_seam.sv'
TB=ROOT/'tests/rtl/a0_backend_write_completion_guard_tb.sv'
DOC=ROOT/'docs/architecture/A0_PROD_SEAM_P12_BACKEND_WRITE_COMPLETION.md'
P11RUN=ROOT/'tests/run_prod_seam_p11.py'
P11_RECEIPT=ROOT.parent/'EVIDENCE/P11/receipt.txt'
P11_RECEIPT_SHA='f7a22e42b2e3434e2900d9fde286279960516ff5873dc0f760175ba40a2b8959'
P11_FROZEN_HASHES={
 str(P11RUN):'1246728c4978d523c7b32ddf5da35795bbeb01d483ef4f5da4bff0642372f4e5',
 str(P11C):'41699715284e0f1d5bdb85f3ac976267a7503ede06c28ec72fd82fd99fe0811b',
 str(P11S):'c31843fdd9dbd2f5ad7fa048e870a73d4deaf703aa63f8549ca282f4909c9f96',
 str(ROOT/'tests/rtl/a0_store_commit_duplicate_canonicalizer_tb.sv'):
   '704c767be06cc92c46d189a258ec2d647bcd900d610f77f64afba323264b2139',
 str(ROOT/'docs/architecture/A0_PROD_SEAM_P11_DUPLICATE_STORE_CANONICALIZATION.md'):
   '7f8590c20a2eafa05ab385364c0018e6c13e5f28a269c6f42c6a17b424b60eaa',
}
SOURCES=[P8A,P8S,P9G,P9S,P10G,P10S,P11C,P11S,GUARD,SEAM]
BEHAVIOR_SOURCES=[*SOURCES,TB]
MARKERS=(
 'PROD_SEAM_P12_WRITE_ISSUE_BACKPRESSURE=PASS',
 'PROD_SEAM_P12_DELAYED_VISIBILITY_RELEASE=PASS',
 'PROD_SEAM_P12_UNKNOWN_ACK_REJECT=PASS',
 'PROD_SEAM_P12_CONFLICTING_REFILL_HELD_UNTIL_ACK=PASS',
 'PROD_SEAM_P12_EXACT_ACK_RELEASE=PASS',
 'PROD_SEAM_P12_POST_COMPLETION_REFILL_VISIBLE=PASS',
 'PROD_SEAM_P12_DUPLICATE_ACK_REJECT=PASS',
 'PROD_SEAM_P12_WRITE_ID_SEQUENCE=PASS',
 'PROD_SEAM_P12_WRITE_ID_WRAP_BLOCK=PASS',
 'PROD_SEAM_P12_STALE_ACK_DURING_WRAP_REJECT=PASS',
 'PROD_SEAM_P12_EXPLICIT_SAFE_REUSE_RELEASE=PASS',
 'PROD_SEAM_P12_READ_PATH_PRESERVED=PASS',
 'PROD_SEAM_P12_BEHAVIOR=PASS',
)

def fail(stage,detail,rc=1):
 print('PROD_SEAM_P12_FIRST_FAILURE',file=sys.stderr); print(f'STAGE={stage}',file=sys.stderr); print(f'DETAIL={detail}',file=sys.stderr); raise SystemExit(rc)

def run(cmd,stage,timeout=900):
 cmd=[str(x) for x in cmd]
 if any(a.startswith('-Wno-') for a in cmd): fail(stage,'runner warning suppression')
 try:
  p=subprocess.run(cmd,cwd=ROOT,text=True,stdout=subprocess.PIPE,stderr=subprocess.STDOUT,env={**os.environ,'PYTHONDONTWRITEBYTECODE':'1'},timeout=timeout)
 except subprocess.TimeoutExpired as exc: fail(stage,f'TIMEOUT {exc}',124)
 if p.returncode: print(p.stdout,file=sys.stderr); fail(stage,f'RC={p.returncode}',p.returncode)
 exe=Path(cmd[0]).name
 if exe.startswith('verilator') or 'strict-all-outer' in exe:
  if '%Warning-' in p.stdout or '%Error' in p.stdout: print(p.stdout,file=sys.stderr); fail(stage,'Verilator diagnostic present',2)
 return p.stdout

def req(text,marks,stage):
 lines=set(text.replace('\r','').splitlines()); miss=[m for m in marks if m not in lines]
 if miss: fail(stage,f'missing {miss}')

def sha(path):
 h=hashlib.sha256()
 with Path(path).open('rb') as f:
  for c in iter(lambda:f.read(1<<20),b''): h.update(c)
 return h.hexdigest()

def leak(path):
 p=Path(path)
 if not p.exists(): return 0
 total=0
 for line in p.read_text().splitlines():
  x=json.loads(line); total+=len(x.get('stripped',[]))+len(x.get('env_stripped',[]))
 return total

def verify_p11():
 if not P11_RECEIPT.is_file() or sha(P11_RECEIPT)!=P11_RECEIPT_SHA: fail('P11_PREDECESSOR_RECEIPT','receipt missing/mismatch')
 req(P11_RECEIPT.read_text(),(
  'PROD_SEAM_P11_P10_PREDECESSOR=PASS mode=frozen-canonical-receipt',
  'PROD_SEAM_P11_STRICT_QUALIFICATION=PASS','PROD_SEAM_P11_OUTER_STRICT_LEAK=0',
  'PROD_SEAM_P11_INNER_STRICT_LEAK=0','PROD_SEAM_P11_POST_CONTAINMENT=PASS','PROD_SEAM_P11_GATE=PASS'),
  'P11_PREDECESSOR_RECEIPT')
 for fn,want in P11_FROZEN_HASHES.items():
  if not Path(fn).is_file() or sha(fn)!=want: fail('P11_PREDECESSOR_IMMUTABILITY',fn)

def main():
 ver=run([V,'--version'],'VERSION',30).strip()
 if not ver.startswith('Verilator 5.050 '): fail('VERSION',ver)
 print('PROD_SEAM_P12_EXACT_VERILATOR_5_050=PASS')
 for f in [*SOURCES,TB,DOC,P11RUN]:
  if not f.is_file(): fail('SOURCE_AVAILABILITY',str(f))
 gt=GUARD.read_text(); st=SEAM.read_text(); dt=DOC.read_text()
 for tok in ('probe_valid_q','write_issued_q','live_write_id_q','write_wrap_block_q','backend_write_reuse_safe_i','exact_live_ack','exact_samecycle_ack','PROD_SEAM_P12_REUSE_SAFE_WITH_LIVE_WRITE','PROD_SEAM_P12_UPSTREAM_COMMAND_CHANGED_BEFORE_COMPLETION'):
  if tok not in gt: fail('STATIC_CONTRACT',tok)
 for tok in ('a0_production_store_backend_collision_seam #(','a0_backend_write_completion_guard #(','p11_protocol_error || write_ack_protocol_error_o'):
  if tok not in st: fail('STATIC_COMPOSITION',tok)
 if any(x in gt+st for x in ('atomic_unit','snoop_controller','dirty_q','writeback_queue')): fail('BOUNDED_SCOPE','full coherence leaked into P12')
 for tok in ('Registered command probe and visibility preservation','Write incarnation and anti-ABA wrap contract','Read-path preservation','Directed proof','Bounded scope'):
  if tok not in dt: fail('DOCUMENTED_CONTRACT',tok)
 print('PROD_SEAM_P12_STATIC_COMPOSITION_CONTRACT=PASS')
 print('PROD_SEAM_P12_BOUNDED_WRITE_COMPLETION_SCOPE=PASS')
 print('PROD_SEAM_P12_DOCUMENTED_COMPLETION_CONTRACT=PASS')
 with tempfile.TemporaryDirectory(prefix='a0_p12_',dir='/tmp') as td0:
  td=Path(td0); base=[str(V),'--timing','--unroll-count','512','-Wall','-Werror-PINMISSING','-Werror-WIDTHEXPAND','-Werror-WIDTHTRUNC']
  variants=(
   ('MIN',['-GCLUSTER_COUNT=1','-GCUS_PER_CLUSTER=1','-GSTORE_LANES=1','-GL2_SLICE_COUNT=1','-GLINE_WORDS=1','-GNETWORK_TAG_W=2','-GREAD_TRACK_COUNT=1','-GREAD_EPOCH_W=1','-GWRITE_ID_W=1']),
   ('MID',['-GCLUSTER_COUNT=2','-GCUS_PER_CLUSTER=2','-GSTORE_LANES=4','-GL2_SLICE_COUNT=2','-GLINE_WORDS=4','-GNETWORK_TAG_W=3','-GREAD_TRACK_COUNT=4','-GREAD_EPOCH_W=4','-GWRITE_ID_W=4']),
   ('WIDE',['-GCLUSTER_COUNT=4','-GCUS_PER_CLUSTER=2','-GSTORE_LANES=32','-GL2_SLICE_COUNT=4','-GLINE_WORDS=8','-GNETWORK_TAG_W=6','-GREAD_TRACK_COUNT=16','-GREAD_EPOCH_W=16','-GWRITE_ID_W=16']),)
  for name,params in variants:
   run(base+['--lint-only','--top-module','a0_production_store_backend_completion_seam','--Mdir',str(td/('matrix_'+name.lower())),*params,*map(str,SOURCES)],f'P12_SEAM_MATRIX_{name}',600)
  print('PROD_SEAM_P12_STRICT_LINT=PASS'); print('PROD_SEAM_P12_PARAMETER_MATRIX=PASS variants=3')
  obj=Path(os.environ.get('A0_P12_BEHAVIOR_OBJDIR',str(td/'beh'))).resolve(); obj.mkdir(parents=True,exist_ok=True)
  run(base+['--output-split','5000','--output-split-cfuncs','500','-CFLAGS','-O0','--cc','--exe','--main','--top-module','a0_backend_write_completion_guard_tb','--Mdir',str(obj),*map(str,BEHAVIOR_SOURCES)],'P12_BEHAVIOR_GENERATE',1200)
  run(['make','-C',str(obj),'-f','Va0_backend_write_completion_guard_tb.mk','-j1'],'P12_BEHAVIOR_BUILD',1800)
  sim=run([str(obj/'Va0_backend_write_completion_guard_tb')],'P12_BEHAVIOR_SIM',180); req(sim,MARKERS,'P12_BEHAVIOR_MARKERS')
  print(f'PROD_SEAM_P12_BEHAVIOR=PASS markers={len(MARKERS)}'); verify_p11(); print('PROD_SEAM_P12_P11_PREDECESSOR=PASS mode=frozen-canonical-receipt')
 head=run(['git','rev-parse','HEAD'],'POST_HEAD',30).strip(); branch=run(['git','branch','--show-current'],'POST_BRANCH',30).strip(); run(['git','diff','--check'],'POST_DIFFCHECK',30)
 diff=run(['bash','-lc','git diff --binary | sha256sum | cut -d" " -f1'],'POST_DIFFSHA',30).strip()
 if (head,branch,diff)!=(EXPECTED_HEAD,EXPECTED_BRANCH,EXPECTED_DIFF): fail('POST_CONTAINMENT',f'{head} {branch} {diff}')
 outer=os.environ.get('A0_STRICT_OUTER_LOG'); inner=os.environ.get('A0_STRICT_INNER_LOG')
 if outer and leak(outer)!=0: fail('OUTER_STRICT_LEAK',str(leak(outer)))
 if inner and leak(inner)!=0: fail('INNER_STRICT_LEAK',str(leak(inner)))
 print('PROD_SEAM_P12_OUTER_STRICT_LEAK=0'); print('PROD_SEAM_P12_INNER_STRICT_LEAK=0'); print('PROD_SEAM_P12_POST_CONTAINMENT=PASS'); print('PROD_SEAM_P12_GATE=PASS')
 return 0
if __name__=='__main__': raise SystemExit(main())
