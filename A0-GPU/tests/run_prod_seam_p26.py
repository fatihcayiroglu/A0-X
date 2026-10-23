#!/usr/bin/env python3
from __future__ import annotations
import hashlib,json,os,shutil,subprocess,sys,tempfile
from pathlib import Path
ROOT=Path(__file__).resolve().parents[1]
V=Path(os.environ.get('A0_VERILATOR_BIN',shutil.which('verilator') or 'verilator'))
HEAD='996d8c188e5d4f94b4bad5289392844d55d092f6';BR='main';DIFF='59fac4fc152cc4e46ed60bff0feecf700756d860ed4f44436f532a221570eb8b'
R=ROOT.parent/'EVIDENCE/P25/receipt.txt';R_SHA='3471c6200a6f020480431ac95dab37053c8a8361855dd1d0784d62d3ad8b751b'
P25={ROOT/'rtl/memory/a0_production_store_commit_write_miss_visibility_subsystem.sv':'972dfdbb765d60b51b672fde6ea0b50deaec8708e97db93d843068781c93c1b9',ROOT/'tests/rtl/a0_production_store_commit_write_miss_visibility_subsystem_tb.sv':'bc282ebb901e51e4a3168cc1e252375ea4d4f1991e3914020612afe44a6ff5a9',ROOT/'tests/run_prod_seam_p25.py':'bcd0b28129b59f86c7d1ff1478cc5290be3c0f65006b6bb52129c723cfa1d288',ROOT/'docs/architecture/A0_PROD_SEAM_P25_STORE_MISS_VISIBILITY.md':'8b2b0e8b6bd7be708f7b347c738f244ce05ec7f44bd8530c5cf30eb0b809def3'}
NAMES=['a0_line_slice_fabric.sv','a0_l2_dirty_writeback_slice.sv','a0_l2_writeback_completion_guard.sv','a0_l2_writeback_recovery_controller.sv','a0_l2_recoverable_writeback_slice.sv','a0_l2_multislice_writeback_queue.sv','a0_l2_multislice_recoverable_writeback_subsystem.sv','a0_mc_noc_multislice_recoverable_writeback_subsystem.sv','a0_l2_unified_line_backend_arbiter.sv','a0_mc_noc_dirty_l2_unified_backend_subsystem.sv','a0_store_commit_dirty_l2_router.sv','a0_production_store_commit_dirty_l2_subsystem.sv','a0_production_store_commit_write_miss_visibility_subsystem.sv','a0_store_word_completion_guard.sv','a0_production_store_commit_completed_miss_visibility_subsystem.sv']
FILES=[ROOT/'rtl/memory'/n for n in NAMES]
GUARD=ROOT/'rtl/memory/a0_store_word_completion_guard.sv';TOP=ROOT/'rtl/memory/a0_production_store_commit_completed_miss_visibility_subsystem.sv';GTB=ROOT/'tests/rtl/a0_store_word_completion_guard_tb.sv';TB=ROOT/'tests/rtl/a0_production_store_commit_completed_miss_visibility_subsystem_tb.sv';DOC=ROOT/'docs/architecture/A0_PROD_SEAM_P26_STORE_WORD_COMPLETION.md'
MARK=('PROD_SEAM_P26_STORE_ATTEMPT_BACKPRESSURE_STABLE=PASS','PROD_SEAM_P26_ACCEPT_ALONE_NO_SOURCE_ACK=PASS','PROD_SEAM_P26_RETRY_EXACT_PAYLOAD_NEW_ATTEMPT=PASS','PROD_SEAM_P26_SAME_CYCLE_ACCEPT_SUCCESS=PASS','PROD_SEAM_P26_MATCHING_SUCCESS_ONLY_RELEASE=PASS','PROD_SEAM_P26_STALE_STATUS_CONTAINED=PASS','PROD_SEAM_P26_RETRY_EXHAUSTION_FAIL_CLOSED=PASS','PROD_SEAM_P26_GUARD_BEHAVIOR=PASS','PROD_SEAM_P26_E2E_ACCEPT_ALONE_COMMIT_BLOCKED=PASS','PROD_SEAM_P26_E2E_MATCHING_SUCCESS_RELEASES_COMMIT=PASS','PROD_SEAM_P26_POST_SUCCESS_REFILL_FRESH=PASS','PROD_SEAM_P26_READ_TYPED_PASSTHROUGH=PASS','PROD_SEAM_P26_RESIDENT_DIRTY_FASTPATH_UNCHANGED=PASS','PROD_SEAM_P26_WRITEBACK_TYPED_PASSTHROUGH=PASS','PROD_SEAM_P26_FINAL_DRAIN_DIAGNOSTIC_CLEAN=PASS','PROD_SEAM_P26_END_TO_END_BEHAVIOR=PASS')
def sha(p):h=hashlib.sha256();h.update(Path(p).read_bytes());return h.hexdigest()
def fail(s,d,rc=1):print('PROD_SEAM_P26_FIRST_FAILURE',file=sys.stderr);print('STAGE='+s,file=sys.stderr);print('DETAIL='+d,file=sys.stderr);raise SystemExit(rc)
def run(c,s,t=600,cwd=ROOT):
 c=[str(x) for x in c]
 if any(x.startswith('-Wno-') for x in c):fail(s,'suppression')
 try:p=subprocess.run(c,cwd=cwd,text=True,stdout=subprocess.PIPE,stderr=subprocess.STDOUT,env={**os.environ,'PYTHONDONTWRITEBYTECODE':'1'},timeout=t)
 except subprocess.TimeoutExpired:fail(s,'TIMEOUT',124)
 if p.returncode:print(p.stdout,file=sys.stderr);fail(s,f'RC={p.returncode}',p.returncode)
 if 'verilator' in Path(c[0]).name and ('%Warning-' in p.stdout or '%Error' in p.stdout):print(p.stdout,file=sys.stderr);fail(s,'diagnostic',2)
 return p.stdout
def leak(x):
 p=Path(x);n=0
 if not p.exists():return 0
 for l in p.read_text().splitlines():
  if l.strip():j=json.loads(l);n+=len(j.get('stripped',[]))+len(j.get('env_stripped',[]))
 return n
def build(top,files,obj,stage):
 run([V,'--cc','--exe','--main','--timing','--unroll-count','512','-Wall','-Werror-PINMISSING','-Werror-WIDTHEXPAND','-Werror-WIDTHTRUNC','--top-module',top,'--Mdir',obj,*files],stage+'_GENERATE');run(['make','-C',obj,'-f','V'+top+'.mk','-j1'],stage+'_MAKE');return run([Path(obj)/('V'+top)],stage+'_SIM',120)
def main():
 v=run([V,'--version'],'VERSION',30).strip()
 if not v.startswith('Verilator 5.050 '):fail('VERSION',v)
 print('PROD_SEAM_P26_EXACT_VERILATOR_5_050=PASS')
 if sha(R)!=R_SHA or 'PROD_SEAM_P25_GATE=PASS' not in R.read_text():fail('P25_RECEIPT','mismatch')
 for f,h in P25.items():
  if sha(f)!=h:fail('P25_IMMUTABILITY',str(f))
 st=GUARD.read_text()+TOP.read_text();doc=DOC.read_text()
 for x in ('WAIT_STATUS','status_success_fire','status_retry_fire','FAIL_CLOSED','backend_cmd_store_attempt_id_o','store_source_ready'):
  if x not in st:fail('STATIC',x)
 for x in ('does not raise source ready','matching SUCCESS','retryable failure','fail-closed','not a physical VRAM/DRAM controller'):
  if x not in doc:fail('DOC',x)
 print('PROD_SEAM_P26_STATIC_COMPLETION_CONTRACT=PASS');print('PROD_SEAM_P26_MATCHING_SUCCESS_REQUIRED=PASS');print('PROD_SEAM_P26_DOCUMENTED_FAIL_CLOSED_BOUND=PASS')
 with tempfile.TemporaryDirectory(prefix='p26_',dir='/tmp') as td:
  d=Path(td);base=[V,'--timing','--unroll-count','512','-Wall','-Werror-PINMISSING','-Werror-WIDTHEXPAND','-Werror-WIDTHTRUNC']
  vv=(('ONE',['-GCLIENT_COUNT=1','-GLOCAL_TAG_W=1','-GCLIENT_MAX_OUTSTANDING=1','-GCOMMIT_PORT_COUNT=1','-GSTORE_LANES=1','-GSLICE_COUNT=1','-GLINE_WORDS=1','-GSET_COUNT_PER_SLICE=1','-GWRITE_ID_W=1','-GMAX_WB_RETRIES=0','-GSTORE_WRITE_ID_W=1','-GMAX_STORE_RETRIES=0']),('TWO',['-GCLIENT_COUNT=2','-GLOCAL_TAG_W=2','-GCLIENT_MAX_OUTSTANDING=2','-GCOMMIT_PORT_COUNT=2','-GSTORE_LANES=4','-GSLICE_COUNT=2','-GLINE_WORDS=4','-GSET_COUNT_PER_SLICE=16','-GWRITE_ID_W=4','-GMAX_WB_RETRIES=2','-GSTORE_WRITE_ID_W=4','-GMAX_STORE_RETRIES=2']),('WIDE',['-GCLIENT_COUNT=4','-GLOCAL_TAG_W=3','-GCLIENT_MAX_OUTSTANDING=4','-GCOMMIT_PORT_COUNT=4','-GSTORE_LANES=8','-GSLICE_COUNT=4','-GLINE_WORDS=8','-GSET_COUNT_PER_SLICE=64','-GWRITE_ID_W=8','-GMAX_WB_RETRIES=3','-GSTORE_WRITE_ID_W=8','-GMAX_STORE_RETRIES=3']))
  for n,ps in vv:run(base+['--lint-only','--top-module','a0_production_store_commit_completed_miss_visibility_subsystem','--Mdir',d/('m_'+n.lower()),*ps,*FILES],'MATRIX_'+n)
  print('PROD_SEAM_P26_STRICT_LINT=PASS');print('PROD_SEAM_P26_PARAMETER_MATRIX=PASS variants=3')
  s1=build('a0_store_word_completion_guard_tb',[GUARD,GTB],d/'guard','GUARD');s2=build('a0_production_store_commit_completed_miss_visibility_subsystem_tb',[*FILES,TB],d/'e2e','E2E')
  ls=set((s1+'\n'+s2).splitlines());missing=[m for m in MARK if m not in ls]
  if missing:fail('MARKERS',str(missing))
  print(f'PROD_SEAM_P26_BEHAVIOR=PASS markers={len(MARK)}')
 print('PROD_SEAM_P26_P25_PREDECESSOR=PASS mode=frozen-canonical-receipt')
 h=run(['git','rev-parse','HEAD'],'HEAD',30).strip();br=run(['git','branch','--show-current'],'BRANCH',30).strip();run(['git','diff','--check'],'DIFFCHECK',30);df=run(['bash','-lc','git diff --binary|sha256sum|cut -d" " -f1'],'DIFFSHA',30).strip()
 if(h,br,df)!=(HEAD,BR,DIFF):fail('CONTAINMENT',f'{h} {br} {df}')
 for e,n in [('A0_STRICT_OUTER_LOG','OUTER'),('A0_STRICT_INNER_LOG','INNER')]:
  if os.environ.get(e) and leak(os.environ[e]):fail(n+'_LEAK',str(leak(os.environ[e])))
 print('PROD_SEAM_P26_OUTER_STRICT_LEAK=0');print('PROD_SEAM_P26_INNER_STRICT_LEAK=0');print('PROD_SEAM_P26_POST_CONTAINMENT=PASS');print('PROD_SEAM_P26_GATE=PASS')
if __name__=='__main__':main()
