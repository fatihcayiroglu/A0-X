#!/usr/bin/env python3
from __future__ import annotations
import hashlib, json, os, shutil, subprocess, sys, tempfile
from pathlib import Path
ROOT=Path(__file__).resolve().parents[1]
V=Path(os.environ.get('A0_VERILATOR_BIN',shutil.which('verilator') or 'verilator'))
HEAD='996d8c188e5d4f94b4bad5289392844d55d092f6'; BR='main'; DIFF='59fac4fc152cc4e46ed60bff0feecf700756d860ed4f44436f532a221570eb8b'
P26R=ROOT.parent/'EVIDENCE/P26/receipt.txt'; P26R_SHA='184b0d6e4e4b2e4170f82fa8810cd6a6ce4ff495771ddb6fdd3de0ab78ef2e1e'
P26={
 ROOT/'rtl/memory/a0_store_word_completion_guard.sv':'3d64ce87e76baa75e21f1a2e62a251d7747c88e4e2618d2d74cc5f485662e5a5',
 ROOT/'rtl/memory/a0_production_store_commit_completed_miss_visibility_subsystem.sv':'3e1d9e1b7a1e319e662dd0421c940a7a4a2ba85df51f557aacfc5e415c33d58a',
 ROOT/'tests/rtl/a0_store_word_completion_guard_tb.sv':'415a4dfbef3d4f5e060a605eab0fcd9e55c2185d8991a75ab6234fe9ee492942',
 ROOT/'tests/rtl/a0_production_store_commit_completed_miss_visibility_subsystem_tb.sv':'eea32862f812d940dffebb02b9c7452441c05f1dd76ff9efe9c358062f561f8d',
 ROOT/'tests/run_prod_seam_p26.py':'71df4ecc797a5e5972794ca5921c3cb5ff334ce075ed63b28a38819fe7fbc0f2',
 ROOT/'docs/architecture/A0_PROD_SEAM_P26_STORE_WORD_COMPLETION.md':'26715be0e8cd04ff45a7457557c472359d1661191cc15c230afd144f7a1f35a8'}
NAMES=['a0_line_slice_fabric.sv','a0_l2_dirty_writeback_slice.sv','a0_l2_writeback_completion_guard.sv','a0_l2_writeback_recovery_controller.sv','a0_l2_recoverable_writeback_slice.sv','a0_l2_multislice_writeback_queue.sv','a0_l2_multislice_recoverable_writeback_subsystem.sv','a0_mc_noc_multislice_recoverable_writeback_subsystem.sv','a0_l2_unified_line_backend_arbiter.sv','a0_mc_noc_dirty_l2_unified_backend_subsystem.sv','a0_store_commit_dirty_l2_router.sv','a0_production_store_commit_dirty_l2_subsystem.sv','a0_production_store_commit_write_miss_visibility_subsystem.sv','a0_store_word_completion_guard.sv','a0_production_store_commit_completed_miss_visibility_subsystem.sv','a0_store_word_status_timeout_guard.sv','a0_production_store_commit_timed_miss_visibility_subsystem.sv']
FILES=[ROOT/'rtl/memory'/n for n in NAMES]
TIMEOUT=ROOT/'rtl/memory/a0_store_word_status_timeout_guard.sv'; TOP=ROOT/'rtl/memory/a0_production_store_commit_timed_miss_visibility_subsystem.sv'; TB=ROOT/'tests/rtl/a0_production_store_commit_timed_miss_visibility_subsystem_tb.sv'; DOC=ROOT/'docs/architecture/A0_PROD_SEAM_P27_STORE_WORD_STATUS_TIMEOUT.md'
MARK=('PROD_SEAM_P27_FROZEN_P26_TYPED_PATHS=PASS','PROD_SEAM_P27_TIMEOUT_FAIL_CLOSED=PASS','PROD_SEAM_P27_TIMEOUT_NEVER_ACKS_COMMIT=PASS','PROD_SEAM_P27_TIMEOUT_EXACTLY_ONCE=PASS','PROD_SEAM_P27_LATE_STATUS_CONTAINED=PASS','PROD_SEAM_P27_DEADLINE_MATCHING_SUCCESS_WINS=PASS','PROD_SEAM_P27_RETRY_FRESH_TIMEOUT_WINDOW=PASS','PROD_SEAM_P27_END_TO_END_BEHAVIOR=PASS')
def sha(p):
 h=hashlib.sha256();h.update(Path(p).read_bytes());return h.hexdigest()
def fail(s,d,rc=1):
 print('PROD_SEAM_P27_FIRST_FAILURE',file=sys.stderr);print('STAGE='+s,file=sys.stderr);print('DETAIL='+d,file=sys.stderr);raise SystemExit(rc)
def run(c,s,t=600,cwd=ROOT):
 c=[str(x) for x in c]
 if any(x.startswith('-Wno-') for x in c): fail(s,'suppression')
 try:p=subprocess.run(c,cwd=cwd,text=True,stdout=subprocess.PIPE,stderr=subprocess.STDOUT,env={**os.environ,'PYTHONDONTWRITEBYTECODE':'1'},timeout=t)
 except subprocess.TimeoutExpired: fail(s,'TIMEOUT',124)
 if p.returncode: print(p.stdout,file=sys.stderr); fail(s,f'RC={p.returncode}',p.returncode)
 if 'verilator' in Path(c[0]).name and ('%Warning-' in p.stdout or '%Error' in p.stdout): print(p.stdout,file=sys.stderr); fail(s,'diagnostic',2)
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
 if not v.startswith('Verilator 5.050 '): fail('VERSION',v)
 print('PROD_SEAM_P27_EXACT_VERILATOR_5_050=PASS')
 if sha(P26R)!=P26R_SHA or 'PROD_SEAM_P26_GATE=PASS' not in P26R.read_text(): fail('P26_RECEIPT','mismatch')
 for f,h in P26.items():
  if sha(f)!=h: fail('P26_IMMUTABILITY',str(f))
 st=TIMEOUT.read_text()+TOP.read_text(); doc=DOC.read_text()
 for x in ('STATUS_TIMEOUT_CYCLES','timeout_fire','timeout_seen_q','stray_status','BACKEND_KIND_STORE_WORD','store_status_timeout_seen_o'):
  if x not in st: fail('STATIC',x)
 for x in ('matching real status on the deadline cycle has priority','fresh timeout window','never converted into success','does not implement terminal STORE_WORD recovery'):
  if x not in doc: fail('DOC',x)
 print('PROD_SEAM_P27_STATIC_TIMEOUT_CONTRACT=PASS');print('PROD_SEAM_P27_DEADLINE_PRIORITY_CONTRACT=PASS');print('PROD_SEAM_P27_DOCUMENTED_FAIL_CLOSED_SCOPE=PASS')
 with tempfile.TemporaryDirectory(prefix='p27_',dir='/tmp') as td:
  d=Path(td);base=[V,'--timing','--unroll-count','512','-Wall','-Werror-PINMISSING','-Werror-WIDTHEXPAND','-Werror-WIDTHTRUNC']
  vv=(('ONE',['-GCLIENT_COUNT=1','-GLOCAL_TAG_W=1','-GCLIENT_MAX_OUTSTANDING=1','-GCOMMIT_PORT_COUNT=1','-GSTORE_LANES=1','-GSLICE_COUNT=1','-GLINE_WORDS=1','-GSET_COUNT_PER_SLICE=1','-GWRITE_ID_W=1','-GMAX_WB_RETRIES=0','-GSTORE_WRITE_ID_W=1','-GMAX_STORE_RETRIES=0','-GSTORE_STATUS_TIMEOUT_CYCLES=1']),('TWO',['-GCLIENT_COUNT=2','-GLOCAL_TAG_W=2','-GCLIENT_MAX_OUTSTANDING=2','-GCOMMIT_PORT_COUNT=2','-GSTORE_LANES=4','-GSLICE_COUNT=2','-GLINE_WORDS=4','-GSET_COUNT_PER_SLICE=16','-GWRITE_ID_W=4','-GMAX_WB_RETRIES=2','-GSTORE_WRITE_ID_W=4','-GMAX_STORE_RETRIES=2','-GSTORE_STATUS_TIMEOUT_CYCLES=4']),('WIDE',['-GCLIENT_COUNT=4','-GLOCAL_TAG_W=3','-GCLIENT_MAX_OUTSTANDING=4','-GCOMMIT_PORT_COUNT=4','-GSTORE_LANES=8','-GSLICE_COUNT=4','-GLINE_WORDS=8','-GSET_COUNT_PER_SLICE=64','-GWRITE_ID_W=8','-GMAX_WB_RETRIES=3','-GSTORE_WRITE_ID_W=8','-GMAX_STORE_RETRIES=3','-GSTORE_STATUS_TIMEOUT_CYCLES=17']))
  for n,ps in vv:run(base+['--lint-only','--top-module','a0_production_store_commit_timed_miss_visibility_subsystem','--Mdir',d/('m_'+n.lower()),*ps,*FILES],'MATRIX_'+n)
  print('PROD_SEAM_P27_STRICT_LINT=PASS');print('PROD_SEAM_P27_PARAMETER_MATRIX=PASS variants=3')
  sim=build('a0_production_store_commit_timed_miss_visibility_subsystem_tb',[*FILES,TB],d/'e2e','E2E')
  ls=set(sim.splitlines());missing=[m for m in MARK if m not in ls]
  if missing: fail('MARKERS',str(missing))
  print(f'PROD_SEAM_P27_BEHAVIOR=PASS markers={len(MARK)}')
 print('PROD_SEAM_P27_P26_PREDECESSOR=PASS mode=frozen-canonical-receipt')
 h=run(['git','rev-parse','HEAD'],'HEAD',30).strip();br=run(['git','branch','--show-current'],'BRANCH',30).strip();run(['git','diff','--check'],'DIFFCHECK',30);df=run(['bash','-lc','git diff --binary|sha256sum|cut -d" " -f1'],'DIFFSHA',30).strip()
 if(h,br,df)!=(HEAD,BR,DIFF): fail('CONTAINMENT',f'{h} {br} {df}')
 for e,n in [('A0_STRICT_OUTER_LOG','OUTER'),('A0_STRICT_INNER_LOG','INNER')]:
  if os.environ.get(e) and leak(os.environ[e]): fail(n+'_LEAK',str(leak(os.environ[e])))
 print('PROD_SEAM_P27_OUTER_STRICT_LEAK=0');print('PROD_SEAM_P27_INNER_STRICT_LEAK=0');print('PROD_SEAM_P27_POST_CONTAINMENT=PASS');print('PROD_SEAM_P27_GATE=PASS')
if __name__=='__main__':main()
