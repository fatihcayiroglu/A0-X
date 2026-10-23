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
P12G=ROOT/'rtl/memory/a0_backend_write_completion_guard.sv'
P12S=ROOT/'rtl/memory/a0_production_store_backend_completion_seam.sv'
GUARD=ROOT/'rtl/memory/a0_backend_write_retry_guard.sv'
SEAM=ROOT/'rtl/memory/a0_production_store_backend_retry_seam.sv'
TB=ROOT/'tests/rtl/a0_backend_write_retry_guard_tb.sv'
DOC=ROOT/'docs/architecture/A0_PROD_SEAM_P13_BACKEND_WRITE_RETRY.md'
P12RUN=ROOT/'tests/run_prod_seam_p12.py'
P12_RECEIPT=ROOT.parent/'EVIDENCE/P12/receipt.txt'
P12_RECEIPT_SHA='7ff3019f372cf82373f4c41a6ee1d7deeb46016c86b52e1e842fef7af16a5286'
P12_FROZEN_HASHES={
 str(P12RUN):'2a5f199c0a234037fa4f435ecc8f437496eb13c039d011f4254f9c32528da85d',
 str(P12G):'5ace4bdf232699df7f0225d6f77a7b1b2d2aea07746171014443884d4517057d',
 str(P12S):'e168c1d4a865deea4f96c46b6d1bcbcc1dbc36f5a2f82bf64be3e2d9ab18c497',
 str(ROOT/'tests/rtl/a0_backend_write_completion_guard_tb.sv'):
   'f288288cfda58b7eb56c7c18273244a2f1ce5a3b064caa95430a53c063e039a4',
 str(ROOT/'docs/architecture/A0_PROD_SEAM_P12_BACKEND_WRITE_COMPLETION.md'):
   '88a4c37d3ed08cdac21943fbdd702f25b2653635a54b1b8cd8a3b69d1138ddd4',
}
SOURCES=[P8A,P8S,P9G,P9S,P10G,P10S,P11C,P11S,P12G,P12S,GUARD,SEAM]
BEHAVIOR_SOURCES=[*SOURCES,TB]
MARKERS=(
 'PROD_SEAM_P13_FIRST_RETRYABLE_FAILURE_NO_VISIBILITY=PASS',
 'PROD_SEAM_P13_RETRY_PAYLOAD_EXACT=PASS',
 'PROD_SEAM_P13_P12_WRITE_ID_PRESERVED=PASS',
 'PROD_SEAM_P13_CONFLICTING_REFILL_HELD_DURING_RETRY=PASS',
 'PROD_SEAM_P13_STALE_ATTEMPT_STATUS_REJECT=PASS',
 'PROD_SEAM_P13_RETRY_SUCCESS_EXACT_ONCE_RELEASE=PASS',
 'PROD_SEAM_P13_POST_RETRY_REFILL_VISIBLE=PASS',
 'PROD_SEAM_P13_DUPLICATE_STATUS_REJECT=PASS',
 'PROD_SEAM_P13_RETRY_LIMIT_BOUNDED=PASS',
 'PROD_SEAM_P13_EXHAUSTION_FAIL_CLOSED=PASS',
 'PROD_SEAM_P13_POST_EXHAUSTION_STATUS_REJECT=PASS',
 'PROD_SEAM_P13_TERMINAL_FAILURE_FAIL_CLOSED=PASS',
 'PROD_SEAM_P13_READ_PATH_PRESERVED=PASS',
 'PROD_SEAM_P13_STATUS_PROVENANCE_PRESERVED=PASS',
 'PROD_SEAM_P13_BEHAVIOR=PASS',
)

def fail(stage,detail,rc=1):
 print('PROD_SEAM_P13_FIRST_FAILURE',file=sys.stderr); print(f'STAGE={stage}',file=sys.stderr); print(f'DETAIL={detail}',file=sys.stderr); raise SystemExit(rc)

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

def verify_p12():
 if not P12_RECEIPT.is_file() or sha(P12_RECEIPT)!=P12_RECEIPT_SHA: fail('P12_PREDECESSOR_RECEIPT','receipt missing/mismatch')
 req(P12_RECEIPT.read_text(),(
  'PROD_SEAM_P12_P11_PREDECESSOR=PASS mode=frozen-canonical-receipt',
  'PROD_SEAM_P12_STRICT_QUALIFICATION=PASS','PROD_SEAM_P12_OUTER_STRICT_LEAK=0',
  'PROD_SEAM_P12_INNER_STRICT_LEAK=0','PROD_SEAM_P12_POST_CONTAINMENT=PASS','PROD_SEAM_P12_GATE=PASS'),
  'P12_PREDECESSOR_RECEIPT')
 for fn,want in P12_FROZEN_HASHES.items():
  if not Path(fn).is_file() or sha(fn)!=want: fail('P12_PREDECESSOR_IMMUTABILITY',fn)

def main():
 ver=run([V,'--version'],'VERSION',30).strip()
 if not ver.startswith('Verilator 5.050 '): fail('VERSION',ver)
 print('PROD_SEAM_P13_EXACT_VERILATOR_5_050=PASS')
 for f in [*SOURCES,TB,DOC,P12RUN]:
  if not f.is_file(): fail('SOURCE_AVAILABILITY',str(f))
 gt=GUARD.read_text(); st=SEAM.read_text(); dt=DOC.read_text()
 for tok in ('current_attempt_id','retry_count_q','attempt_live_q','exact_retryable_failure','exact_terminal_failure','retry_exhausted_q','terminal_failure_q','PROD_SEAM_P13_UPSTREAM_COMMAND_CHANGED_BEFORE_FIRST_ISSUE'):
  if tok not in gt: fail('STATIC_CONTRACT',tok)
 for tok in ('a0_production_store_backend_completion_seam #(','a0_backend_write_retry_guard #(','p12_protocol_error || write_status_protocol_error_o'):
  if tok not in st: fail('STATIC_COMPOSITION',tok)
 if any(x in gt+st for x in ('atomic_unit','snoop_controller','dirty_q','writeback_queue','ecc_decoder','dram_scheduler')): fail('BOUNDED_SCOPE','scope creep leaked into P13')
 for tok in ('Explicit status and attempt identity','Exact-payload retry and fail-closed exhaustion','Visibility release only on exact SUCCESS','Frozen predecessor preservation','Directed proof','Bounded scope'):
  if tok not in dt: fail('DOCUMENTED_CONTRACT',tok)
 print('PROD_SEAM_P13_STATIC_COMPOSITION_CONTRACT=PASS')
 print('PROD_SEAM_P13_BOUNDED_WRITE_RETRY_SCOPE=PASS')
 print('PROD_SEAM_P13_DOCUMENTED_RETRY_CONTRACT=PASS')
 with tempfile.TemporaryDirectory(prefix='a0_p13_',dir='/tmp') as td0:
  td=Path(td0); base=[str(V),'--timing','--unroll-count','512','-Wall','-Werror-PINMISSING','-Werror-WIDTHEXPAND','-Werror-WIDTHTRUNC']
  variants=(
   ('MIN',['-GCLUSTER_COUNT=1','-GCUS_PER_CLUSTER=1','-GSTORE_LANES=1','-GL2_SLICE_COUNT=1','-GLINE_WORDS=1','-GNETWORK_TAG_W=2','-GREAD_TRACK_COUNT=1','-GREAD_EPOCH_W=1','-GWRITE_ID_W=1','-GMAX_WRITE_RETRIES=0']),
   ('MID',['-GCLUSTER_COUNT=2','-GCUS_PER_CLUSTER=2','-GSTORE_LANES=4','-GL2_SLICE_COUNT=2','-GLINE_WORDS=4','-GNETWORK_TAG_W=3','-GREAD_TRACK_COUNT=4','-GREAD_EPOCH_W=4','-GWRITE_ID_W=4','-GMAX_WRITE_RETRIES=2']),
   ('WIDE',['-GCLUSTER_COUNT=4','-GCUS_PER_CLUSTER=2','-GSTORE_LANES=32','-GL2_SLICE_COUNT=4','-GLINE_WORDS=8','-GNETWORK_TAG_W=6','-GREAD_TRACK_COUNT=16','-GREAD_EPOCH_W=16','-GWRITE_ID_W=16','-GMAX_WRITE_RETRIES=7']),)
  for name,params in variants:
   run(base+['--lint-only','--top-module','a0_production_store_backend_retry_seam','--Mdir',str(td/('matrix_'+name.lower())),*params,*map(str,SOURCES)],f'P13_SEAM_MATRIX_{name}',600)
  print('PROD_SEAM_P13_STRICT_LINT=PASS'); print('PROD_SEAM_P13_PARAMETER_MATRIX=PASS variants=3')
  obj=Path(os.environ.get('A0_P13_BEHAVIOR_OBJDIR',str(td/'beh'))).resolve(); obj.mkdir(parents=True,exist_ok=True)
  run(base+['--output-split','5000','--output-split-cfuncs','500','-CFLAGS','-O0','--cc','--exe','--main','--top-module','a0_backend_write_retry_guard_tb','--Mdir',str(obj),*map(str,BEHAVIOR_SOURCES)],'P13_BEHAVIOR_GENERATE',1200)
  run(['make','-C',str(obj),'-f','Va0_backend_write_retry_guard_tb.mk','-j1'],'P13_BEHAVIOR_BUILD',1800)
  sim=run([str(obj/'Va0_backend_write_retry_guard_tb')],'P13_BEHAVIOR_SIM',180); req(sim,MARKERS,'P13_BEHAVIOR_MARKERS')
  print(f'PROD_SEAM_P13_BEHAVIOR=PASS markers={len(MARKERS)}'); verify_p12(); print('PROD_SEAM_P13_P12_PREDECESSOR=PASS mode=frozen-canonical-receipt')
 head=run(['git','rev-parse','HEAD'],'POST_HEAD',30).strip(); branch=run(['git','branch','--show-current'],'POST_BRANCH',30).strip(); run(['git','diff','--check'],'POST_DIFFCHECK',30)
 diff=run(['bash','-lc','git diff --binary | sha256sum | cut -d" " -f1'],'POST_DIFFSHA',30).strip()
 if (head,branch,diff)!=(EXPECTED_HEAD,EXPECTED_BRANCH,EXPECTED_DIFF): fail('POST_CONTAINMENT',f'{head} {branch} {diff}')
 outer=os.environ.get('A0_STRICT_OUTER_LOG'); inner=os.environ.get('A0_STRICT_INNER_LOG')
 if outer and leak(outer)!=0: fail('OUTER_STRICT_LEAK',str(leak(outer)))
 if inner and leak(inner)!=0: fail('INNER_STRICT_LEAK',str(leak(inner)))
 print('PROD_SEAM_P13_OUTER_STRICT_LEAK=0'); print('PROD_SEAM_P13_INNER_STRICT_LEAK=0'); print('PROD_SEAM_P13_POST_CONTAINMENT=PASS'); print('PROD_SEAM_P13_GATE=PASS')
 return 0
if __name__=='__main__': raise SystemExit(main())
