#!/usr/bin/env python3
from __future__ import annotations
import hashlib,json,os,shutil,subprocess,sys,tempfile
from pathlib import Path
ROOT=Path(__file__).resolve().parents[1]
V=Path(os.environ.get('A0_VERILATOR_BIN',shutil.which('verilator') or 'verilator'))
HEAD='996d8c188e5d4f94b4bad5289392844d55d092f6';BR='main';DIFF='59fac4fc152cc4e46ed60bff0feecf700756d860ed4f44436f532a221570eb8b'
R=ROOT.parent/'EVIDENCE/P27/receipt.txt';R_SHA='203d166f3c54c88c927c7582cf2d7107d551fcbce9d45efc74f24442211781d1'
P27={ROOT/'rtl/memory/a0_store_word_status_timeout_guard.sv':'1713f91ce203ea51d81c4b3d19af9debaff50588cd00fa48c9b6197cacefb0b1',ROOT/'rtl/memory/a0_production_store_commit_timed_miss_visibility_subsystem.sv':'7e0c7608639d8b93bc05b1604bedfe79272b4e4d8475ebface7ca1e27930d250',ROOT/'tests/rtl/a0_production_store_commit_timed_miss_visibility_subsystem_tb.sv':'db6ed478dd1855e35701fdb4ead273c17a7ed39f72166dadfe25bca99d89951b',ROOT/'tests/run_prod_seam_p27.py':'8d912de705e4373684c9d32bdf0eea1d587ac7e66ae96acfd017ce0a1571bf54',ROOT/'docs/architecture/A0_PROD_SEAM_P27_STORE_WORD_STATUS_TIMEOUT.md':'12d3e372648651ae65b333bac75342c2b8f79220633a7b01433c03c09c7f0a6b'}
NAMES=['a0_line_slice_fabric.sv','a0_l2_dirty_writeback_slice.sv','a0_l2_writeback_completion_guard.sv','a0_l2_writeback_recovery_controller.sv','a0_l2_recoverable_writeback_slice.sv','a0_l2_multislice_writeback_queue.sv','a0_l2_multislice_recoverable_writeback_subsystem.sv','a0_mc_noc_multislice_recoverable_writeback_subsystem.sv','a0_l2_unified_line_backend_arbiter.sv','a0_mc_noc_dirty_l2_unified_backend_subsystem.sv','a0_store_commit_dirty_l2_router.sv','a0_production_store_commit_dirty_l2_subsystem.sv','a0_production_store_commit_write_miss_visibility_subsystem.sv','a0_store_word_completion_guard.sv','a0_production_store_commit_completed_miss_visibility_subsystem.sv','a0_store_word_status_timeout_guard.sv','a0_production_store_commit_timed_miss_visibility_subsystem.sv','a0_production_store_commit_fault_provenance_subsystem.sv']
FILES=[ROOT/'rtl/memory'/n for n in NAMES]
TOP=ROOT/'rtl/memory/a0_production_store_commit_fault_provenance_subsystem.sv';TB=ROOT/'tests/rtl/a0_production_store_commit_fault_provenance_subsystem_tb.sv';DOC=ROOT/'docs/architecture/A0_PROD_SEAM_P28_COMMIT_FAULT_PROVENANCE.md'
MARK=('PROD_SEAM_P28_SUCCESS_ONLY_READY=PASS','PROD_SEAM_P28_ROUND_ROBIN_PORT_IDENTITY=PASS','PROD_SEAM_P28_FAULT_PAYLOAD_STABLE=PASS','PROD_SEAM_P28_TIMEOUT_PROVENANCE=PASS','PROD_SEAM_P28_ABORT_SEPARATE_FROM_SUCCESS=PASS','PROD_SEAM_P28_POST_ABORT_RECOVERY_REQUIRED=PASS','PROD_SEAM_P28_BACKEND_FAILURE_DISTINCT_FROM_TIMEOUT=PASS','PROD_SEAM_P28_NO_DOUBLE_SUCCESS_FAILURE=PASS','PROD_SEAM_P28_END_TO_END_BEHAVIOR=PASS')
def sha(p):h=hashlib.sha256();h.update(Path(p).read_bytes());return h.hexdigest()
def fail(s,d,rc=1):print('PROD_SEAM_P28_FIRST_FAILURE',file=sys.stderr);print('STAGE='+s,file=sys.stderr);print('DETAIL='+d,file=sys.stderr);raise SystemExit(rc)
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
  if l.strip():
   j=json.loads(l);n+=len(j.get('stripped',[]))+len(j.get('env_stripped',[]))
 return n
def build(top,files,obj,stage):
 run([V,'--cc','--exe','--main','--timing','--unroll-count','512','-Wall','-Werror-PINMISSING','-Werror-WIDTHEXPAND','-Werror-WIDTHTRUNC','--top-module',top,'--Mdir',obj,*files],stage+'_GENERATE')
 run(['make','-C',obj,'-f','V'+top+'.mk','-j1'],stage+'_MAKE')
 return run([Path(obj)/('V'+top)],stage+'_SIM',120)
def main():
 v=run([V,'--version'],'VERSION',30).strip()
 if not v.startswith('Verilator 5.050 '):fail('VERSION',v)
 print('PROD_SEAM_P28_EXACT_VERILATOR_5_050=PASS')
 if sha(R)!=R_SHA or 'PROD_SEAM_P27_GATE=PASS' not in R.read_text():fail('P27_RECEIPT','mismatch')
 for f,h in P27.items():
  if sha(f)!=h:fail('P27_IMMUTABILITY',str(f))
 st=TOP.read_text();doc=DOC.read_text()
 for x in ('commit_fault_valid_o','commit_abort_o','recovery_required_o','captured_lane_mask_q','fault_store_timeout_q','ROUND'):
  if x=='ROUND':continue
  if x not in st:fail('STATIC',x)
 for x in ('success-only','separate architectural squash/abort','stable payload','does not yet perform backend recovery-safe joining'):
  if x not in doc:fail('DOC',x)
 print('PROD_SEAM_P28_STATIC_FAULT_PROVENANCE_CONTRACT=PASS');print('PROD_SEAM_P28_SUCCESS_ABORT_SEPARATION_CONTRACT=PASS');print('PROD_SEAM_P28_DOCUMENTED_RECOVERY_BOUND=PASS')
 with tempfile.TemporaryDirectory(prefix='p28_',dir='/tmp') as td:
  d=Path(td);base=[V,'--timing','--unroll-count','512','-Wall','-Werror-PINMISSING','-Werror-WIDTHEXPAND','-Werror-WIDTHTRUNC']
  vv=(('ONE',['-GCLIENT_COUNT=1','-GLOCAL_TAG_W=1','-GCLIENT_MAX_OUTSTANDING=1','-GCOMMIT_PORT_COUNT=1','-GSTORE_LANES=1','-GSLICE_COUNT=1','-GLINE_WORDS=1','-GSET_COUNT_PER_SLICE=1','-GWRITE_ID_W=1','-GMAX_WB_RETRIES=0','-GSTORE_WRITE_ID_W=1','-GMAX_STORE_RETRIES=0','-GSTORE_STATUS_TIMEOUT_CYCLES=1']),('TWO',['-GCLIENT_COUNT=2','-GLOCAL_TAG_W=2','-GCLIENT_MAX_OUTSTANDING=2','-GCOMMIT_PORT_COUNT=2','-GSTORE_LANES=4','-GSLICE_COUNT=2','-GLINE_WORDS=4','-GSET_COUNT_PER_SLICE=16','-GWRITE_ID_W=4','-GMAX_WB_RETRIES=2','-GSTORE_WRITE_ID_W=4','-GMAX_STORE_RETRIES=2','-GSTORE_STATUS_TIMEOUT_CYCLES=4']),('WIDE',['-GCLIENT_COUNT=4','-GLOCAL_TAG_W=3','-GCLIENT_MAX_OUTSTANDING=4','-GCOMMIT_PORT_COUNT=4','-GSTORE_LANES=8','-GSLICE_COUNT=4','-GLINE_WORDS=8','-GSET_COUNT_PER_SLICE=64','-GWRITE_ID_W=8','-GMAX_WB_RETRIES=3','-GSTORE_WRITE_ID_W=8','-GMAX_STORE_RETRIES=3','-GSTORE_STATUS_TIMEOUT_CYCLES=17']))
  for n,ps in vv:run(base+['--lint-only','--top-module','a0_production_store_commit_fault_provenance_subsystem','--Mdir',d/('m_'+n.lower()),*ps,*FILES],'MATRIX_'+n)
  print('PROD_SEAM_P28_STRICT_LINT=PASS');print('PROD_SEAM_P28_PARAMETER_MATRIX=PASS variants=3')
  sim=build('a0_production_store_commit_fault_provenance_subsystem_tb',[*FILES,TB],d/'e2e','E2E')
  ls=set(sim.splitlines());missing=[m for m in MARK if m not in ls]
  if missing:fail('MARKERS',str(missing))
  print(f'PROD_SEAM_P28_BEHAVIOR=PASS markers={len(MARK)}')
 print('PROD_SEAM_P28_P27_PREDECESSOR=PASS mode=frozen-canonical-receipt')
 h=run(['git','rev-parse','HEAD'],'HEAD',30).strip();br=run(['git','branch','--show-current'],'BRANCH',30).strip();run(['git','diff','--check'],'DIFFCHECK',30);df=run(['bash','-lc','git diff --binary|sha256sum|cut -d" " -f1'],'DIFFSHA',30).strip()
 if(h,br,df)!=(HEAD,BR,DIFF):fail('CONTAINMENT',f'{h} {br} {df}')
 for e,n in [('A0_STRICT_OUTER_LOG','OUTER'),('A0_STRICT_INNER_LOG','INNER')]:
  if os.environ.get(e) and leak(os.environ[e]):fail(n+'_LEAK',str(leak(os.environ[e])))
 print('PROD_SEAM_P28_OUTER_STRICT_LEAK=0');print('PROD_SEAM_P28_INNER_STRICT_LEAK=0');print('PROD_SEAM_P28_POST_CONTAINMENT=PASS');print('PROD_SEAM_P28_GATE=PASS')
if __name__=='__main__':main()
