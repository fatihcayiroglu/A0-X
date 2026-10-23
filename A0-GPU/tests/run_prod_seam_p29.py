#!/usr/bin/env python3
from __future__ import annotations
import hashlib,json,os,shutil,subprocess,sys,tempfile
from pathlib import Path
ROOT=Path(__file__).resolve().parents[1]
V=Path(os.environ.get('A0_VERILATOR_BIN',shutil.which('verilator') or 'verilator'))
HEAD='996d8c188e5d4f94b4bad5289392844d55d092f6';BR='main';DIFF='59fac4fc152cc4e46ed60bff0feecf700756d860ed4f44436f532a221570eb8b'
R=ROOT.parent/'EVIDENCE/P28/receipt.txt';R_SHA='06bbd2ecbe8ba56c9e417b733a71a18cf72656415544f623e6f939f9142adf95'
P28={ROOT/'rtl/memory/a0_production_store_commit_fault_provenance_subsystem.sv':'5d4418e0f244c7f2b29b905afb2ff50f2535b68b1c43016615da0b6c7b5013ed',ROOT/'tests/rtl/a0_production_store_commit_fault_provenance_subsystem_tb.sv':'bcd45b8b278c5a84ce719e07fed185079729d7f3617fbace72fca9bb236616f7',ROOT/'tests/run_prod_seam_p28.py':'1e1a389f4ddcc7d075b60aeb4a26cfb447500a7c0807a6fc5acba2d167b75c0c',ROOT/'docs/architecture/A0_PROD_SEAM_P28_COMMIT_FAULT_PROVENANCE.md':'227a73124c56d14b50922053483fb57d934ac68a5c119c31acf898764e096d3f'}
NAMES=['a0_line_slice_fabric.sv','a0_l2_dirty_writeback_slice.sv','a0_l2_writeback_completion_guard.sv','a0_l2_writeback_recovery_controller.sv','a0_l2_recoverable_writeback_slice.sv','a0_l2_multislice_writeback_queue.sv','a0_l2_multislice_recoverable_writeback_subsystem.sv','a0_mc_noc_multislice_recoverable_writeback_subsystem.sv','a0_l2_unified_line_backend_arbiter.sv','a0_mc_noc_dirty_l2_unified_backend_subsystem.sv','a0_store_commit_dirty_l2_router.sv','a0_production_store_commit_dirty_l2_subsystem.sv','a0_production_store_commit_write_miss_visibility_subsystem.sv','a0_store_word_completion_guard.sv','a0_production_store_commit_completed_miss_visibility_subsystem.sv','a0_store_word_status_timeout_guard.sv','a0_production_store_commit_timed_miss_visibility_subsystem.sv','a0_production_store_commit_fault_provenance_subsystem.sv','a0_production_store_commit_recoverable_fault_subsystem.sv']
FILES=[ROOT/'rtl/memory'/n for n in NAMES]
TB=ROOT/'tests/rtl/a0_production_store_commit_recoverable_fault_subsystem_tb.sv';DOC=ROOT/'docs/architecture/A0_PROD_SEAM_P29_SAFE_STORE_RESTART.md'
MARK=('PROD_SEAM_P29_EARLY_REUSE_SAFE_NOT_REMEMBERED=PASS','PROD_SEAM_P29_ABORT_AND_REUSE_SAFE_JOIN=PASS','PROD_SEAM_P29_CONTROLLED_ONE_CYCLE_REARM=PASS','PROD_SEAM_P29_FRESH_ATTEMPT_DISTINCT=PASS','PROD_SEAM_P29_LATE_OLD_STATUS_CONTAINED=PASS','PROD_SEAM_P29_FRESH_COMMIT_COMPLETES=PASS','PROD_SEAM_P29_END_TO_END_BEHAVIOR=PASS')
def sha(p):return hashlib.sha256(Path(p).read_bytes()).hexdigest()
def fail(s,d,rc=1):print('PROD_SEAM_P29_FIRST_FAILURE',file=sys.stderr);print('STAGE='+s,file=sys.stderr);print('DETAIL='+d,file=sys.stderr);raise SystemExit(rc)
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
def main():
 v=run([V,'--version'],'VERSION',30).strip()
 if not v.startswith('Verilator 5.050 '):fail('VERSION',v)
 print('PROD_SEAM_P29_EXACT_VERILATOR_5_050=PASS')
 if sha(R)!=R_SHA or 'PROD_SEAM_P28_GATE=PASS' not in R.read_text():fail('P28_RECEIPT','mismatch')
 for f,h in P28.items():
  if sha(f)!=h:fail('P28_IMMUTABILITY',str(f))
 st=FILES[-1].read_text();doc=DOC.read_text()
 for x in ('backend_store_status_reuse_safe_i','recovery_rearm_pulse_o','STORE_EPOCH_MASK','epoch_q','p28_rst_n'):
  if x not in st:fail('STATIC',x)
 for x in ('early reuse-safe assertion is deliberately not remembered','one-cycle local rearm/reset','READ tags and WRITEBACK attempt IDs are not remapped','late status'):
  if x not in doc:fail('DOC',x)
 print('PROD_SEAM_P29_STATIC_RECOVERY_CONTRACT=PASS');print('PROD_SEAM_P29_DOCUMENTED_REUSE_SAFE_BOUND=PASS')
 with tempfile.TemporaryDirectory(prefix='p29_',dir='/tmp') as td:
  d=Path(td);base=[V,'--timing','--unroll-count','512','-Wall','-Werror-PINMISSING','-Werror-WIDTHEXPAND','-Werror-WIDTHTRUNC']
  vv=(('ONE',['-GCLIENT_COUNT=1','-GLOCAL_TAG_W=1','-GCLIENT_MAX_OUTSTANDING=1','-GCOMMIT_PORT_COUNT=1','-GSTORE_LANES=1','-GSLICE_COUNT=1','-GLINE_WORDS=1','-GSET_COUNT_PER_SLICE=1','-GWRITE_ID_W=1','-GMAX_WB_RETRIES=0','-GSTORE_WRITE_ID_W=1','-GMAX_STORE_RETRIES=0','-GSTORE_STATUS_TIMEOUT_CYCLES=1']),('TWO',['-GCLIENT_COUNT=2','-GLOCAL_TAG_W=2','-GCLIENT_MAX_OUTSTANDING=2','-GCOMMIT_PORT_COUNT=2','-GSTORE_LANES=4','-GSLICE_COUNT=2','-GLINE_WORDS=4','-GSET_COUNT_PER_SLICE=16','-GWRITE_ID_W=4','-GMAX_WB_RETRIES=2','-GSTORE_WRITE_ID_W=4','-GMAX_STORE_RETRIES=2','-GSTORE_STATUS_TIMEOUT_CYCLES=4']),('WIDE',['-GCLIENT_COUNT=4','-GLOCAL_TAG_W=3','-GCLIENT_MAX_OUTSTANDING=4','-GCOMMIT_PORT_COUNT=4','-GSTORE_LANES=8','-GSLICE_COUNT=4','-GLINE_WORDS=8','-GSET_COUNT_PER_SLICE=64','-GWRITE_ID_W=8','-GMAX_WB_RETRIES=3','-GSTORE_WRITE_ID_W=8','-GMAX_STORE_RETRIES=3','-GSTORE_STATUS_TIMEOUT_CYCLES=17']))
  for n,ps in vv:run(base+['--lint-only','--top-module','a0_production_store_commit_recoverable_fault_subsystem','--Mdir',d/('m_'+n.lower()),*ps,*FILES],'MATRIX_'+n)
  print('PROD_SEAM_P29_STRICT_LINT=PASS');print('PROD_SEAM_P29_PARAMETER_MATRIX=PASS variants=3')
  obj=d/'e2e';run(base+['--cc','--exe','--main','--top-module','a0_production_store_commit_recoverable_fault_subsystem_tb','--Mdir',obj,*FILES,TB],'E2E_GENERATE');run(['make','-C',obj,'-f','Va0_production_store_commit_recoverable_fault_subsystem_tb.mk','-j1'],'E2E_MAKE');sim=run([obj/'Va0_production_store_commit_recoverable_fault_subsystem_tb'],'E2E_SIM',120)
  ls=set(sim.splitlines());missing=[m for m in MARK if m not in ls]
  if missing:fail('MARKERS',str(missing))
  print(f'PROD_SEAM_P29_BEHAVIOR=PASS markers={len(MARK)}')
 print('PROD_SEAM_P29_P28_PREDECESSOR=PASS mode=frozen-canonical-receipt')
 h=run(['git','rev-parse','HEAD'],'HEAD',30).strip();br=run(['git','branch','--show-current'],'BRANCH',30).strip();run(['git','diff','--check'],'DIFFCHECK',30);df=run(['bash','-lc','git diff --binary|sha256sum|cut -d" " -f1'],'DIFFSHA',30).strip()
 if(h,br,df)!=(HEAD,BR,DIFF):fail('CONTAINMENT',f'{h} {br} {df}')
 for e,n in [('A0_STRICT_OUTER_LOG','OUTER'),('A0_STRICT_INNER_LOG','INNER')]:
  if os.environ.get(e) and leak(os.environ[e]):fail(n+'_LEAK',str(leak(os.environ[e])))
 print('PROD_SEAM_P29_OUTER_STRICT_LEAK=0');print('PROD_SEAM_P29_INNER_STRICT_LEAK=0');print('PROD_SEAM_P29_POST_CONTAINMENT=PASS');print('PROD_SEAM_P29_GATE=PASS')
if __name__=='__main__':main()
