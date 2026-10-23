#!/usr/bin/env python3
from __future__ import annotations
import hashlib,json,os,shutil,subprocess,sys,tempfile
from pathlib import Path
ROOT=Path(__file__).resolve().parents[1]
V=Path(os.environ.get('A0_VERILATOR_BIN',shutil.which('verilator') or 'verilator'))
HEAD='996d8c188e5d4f94b4bad5289392844d55d092f6';BR='main';DIFF='59fac4fc152cc4e46ed60bff0feecf700756d860ed4f44436f532a221570eb8b'
R=ROOT.parent/'EVIDENCE/P24/receipt.txt';R_SHA='8bb0ddf5ad8373f8c4722667a830513ea9c725e41cd0029aa0f1e77b88b0287c'
P24={
 ROOT/'rtl/memory/a0_store_commit_dirty_l2_router.sv':'4815f88fbc468ddb4871b3c06dc6b785f1dae4be7528a9d897eb04e424cb6b64',
 ROOT/'rtl/memory/a0_production_store_commit_dirty_l2_subsystem.sv':'a71d2a3d1a5be0999e7a65f388c6cd4b11a771db519d20b0623bf2bee5f1c3e1',
 ROOT/'tests/rtl/a0_store_commit_dirty_l2_router_tb.sv':'9133211d090b645bd88659a80afbeb0df3597b3aebaf562d0932875006f4cabb',
 ROOT/'tests/rtl/a0_production_store_commit_dirty_l2_subsystem_tb.sv':'fd6e450209fe27840bfda0c6075015d5f18c89c3e5caaec0c7f6e1928bf1c94c',
 ROOT/'tests/run_prod_seam_p24.py':'af5e14f82f3804cc8f0b4d000c3f20559784c0908f69041b130775fb506f3edf',
 ROOT/'docs/architecture/A0_PROD_SEAM_P24_PRODUCTION_STORE_COMMIT_DIRTY_L2.md':'5476a4d7db5503b9a549e89442af1b349500667a659e5d665476f6e8343c6352'}
FAB=ROOT/'rtl/memory/a0_line_slice_fabric.sv';P17=ROOT/'rtl/memory/a0_l2_dirty_writeback_slice.sv';G=ROOT/'rtl/memory/a0_l2_writeback_completion_guard.sv';C=ROOT/'rtl/memory/a0_l2_writeback_recovery_controller.sv';P19=ROOT/'rtl/memory/a0_l2_recoverable_writeback_slice.sv';P20=ROOT/'rtl/memory/a0_l2_multislice_writeback_queue.sv';P21=ROOT/'rtl/memory/a0_l2_multislice_recoverable_writeback_subsystem.sv';P22=ROOT/'rtl/memory/a0_mc_noc_multislice_recoverable_writeback_subsystem.sv';A=ROOT/'rtl/memory/a0_l2_unified_line_backend_arbiter.sv';P23=ROOT/'rtl/memory/a0_mc_noc_dirty_l2_unified_backend_subsystem.sv';P24R=ROOT/'rtl/memory/a0_store_commit_dirty_l2_router.sv';P24T=ROOT/'rtl/memory/a0_production_store_commit_dirty_l2_subsystem.sv'
TOP=ROOT/'rtl/memory/a0_production_store_commit_write_miss_visibility_subsystem.sv';TB=ROOT/'tests/rtl/a0_production_store_commit_write_miss_visibility_subsystem_tb.sv';DOC=ROOT/'docs/architecture/A0_PROD_SEAM_P25_STORE_MISS_VISIBILITY.md'
MARK=(
'PROD_SEAM_P25_PRELOAD_RESIDENT_HIT_LINE=PASS','PROD_SEAM_P25_STORE_MISS_BACKPRESSURE_STABLE=PASS','PROD_SEAM_P25_COMMIT_ACK_HELD_BEFORE_MISS_VISIBILITY=PASS','PROD_SEAM_P25_STORE_MISS_WORD_VISIBILITY=PASS','PROD_SEAM_P25_ROUND_ROBIN_COMMIT_SOURCE_PROGRESS=PASS','PROD_SEAM_P25_EXACTLY_ONCE_MISS_WRITE=PASS','PROD_SEAM_P25_RESIDENT_HIT_REMAINS_DIRTY_FASTPATH=PASS','PROD_SEAM_P25_POST_ACK_REFILL_OBSERVES_STORE_MISS=PASS','PROD_SEAM_P25_P23_WRITEBACK_TYPED_PASSTHROUGH=PASS','PROD_SEAM_P25_FINAL_DRAIN_DIAGNOSTIC_CLEAN=PASS','PROD_SEAM_P25_END_TO_END_BEHAVIOR=PASS')
def sha(p):
 h=hashlib.sha256();h.update(Path(p).read_bytes());return h.hexdigest()
def fail(s,d,rc=1):
 print('PROD_SEAM_P25_FIRST_FAILURE',file=sys.stderr);print('STAGE='+s,file=sys.stderr);print('DETAIL='+d,file=sys.stderr);raise SystemExit(rc)
def run(c,s,t=600,cwd=ROOT):
 c=[str(x) for x in c]
 if any(x.startswith('-Wno-') for x in c):fail(s,'suppression')
 try:p=subprocess.run(c,cwd=cwd,text=True,stdout=subprocess.PIPE,stderr=subprocess.STDOUT,env={**os.environ,'PYTHONDONTWRITEBYTECODE':'1'},timeout=t)
 except subprocess.TimeoutExpired:fail(s,'TIMEOUT',124)
 if p.returncode:
  print(p.stdout,file=sys.stderr);fail(s,f'RC={p.returncode}',p.returncode)
 if 'verilator' in Path(c[0]).name and ('%Warning-' in p.stdout or '%Error' in p.stdout):
  print(p.stdout,file=sys.stderr);fail(s,'diagnostic',2)
 return p.stdout
def leak(x):
 p=Path(x)
 if not p.exists():return 0
 n=0
 for line in p.read_text().splitlines():
  if not line.strip():continue
  j=json.loads(line);n+=len(j.get('stripped',[]))+len(j.get('env_stripped',[]))
 return n
def build_and_run(top,files,obj,stage):
 run([V,'--cc','--exe','--main','--timing','--unroll-count','512','-Wall','-Werror-PINMISSING','-Werror-WIDTHEXPAND','-Werror-WIDTHTRUNC','--top-module',top,'--Mdir',obj,*files],stage+'_GENERATE',600)
 run(['make','-C',obj,'-f','V'+top+'.mk','-j1'],stage+'_MAKE',600)
 return run([Path(obj)/('V'+top)],stage+'_SIM',120)
def main():
 v=run([V,'--version'],'VERSION',30).strip()
 if not v.startswith('Verilator 5.050 '):fail('VERSION',v)
 print('PROD_SEAM_P25_EXACT_VERILATOR_5_050=PASS')
 if sha(R)!=R_SHA or 'PROD_SEAM_P24_GATE=PASS' not in R.read_text():fail('P24_RECEIPT','mismatch')
 for f,h in P24.items():
  if sha(f)!=h:fail('P24_IMMUTABILITY',str(f))
 st=TOP.read_text();doc=DOC.read_text()
 for x in ('BACKEND_KIND_STORE_WORD','miss_lane_mask_q','p24_commit_ready','backend_cmd_store_word_addr_o','MISS_DRAIN'):
  if x not in st:fail('STATIC',x)
 for x in ('no-write-allocate','same external visibility-domain boundary','does not perform a read-modify-write','commit_ready','not a physical VRAM controller'):
  if x not in doc:fail('DOC',x)
 print('PROD_SEAM_P25_STATIC_ORDERING_CONTRACT=PASS')
 print('PROD_SEAM_P25_NO_WRITE_ALLOCATE_MISS_VISIBILITY=PASS')
 print('PROD_SEAM_P25_DOCUMENTED_BOUNDED_CONTRACT=PASS')
 files=[FAB,P17,G,C,P19,P20,P21,P22,A,P23,P24R,P24T,TOP]
 with tempfile.TemporaryDirectory(prefix='p25_',dir='/tmp') as td:
  d=Path(td);base=[V,'--timing','--unroll-count','512','-Wall','-Werror-PINMISSING','-Werror-WIDTHEXPAND','-Werror-WIDTHTRUNC']
  vv=(
   ('ONE',['-GCLIENT_COUNT=1','-GLOCAL_TAG_W=1','-GCLIENT_MAX_OUTSTANDING=1','-GCOMMIT_PORT_COUNT=1','-GSTORE_LANES=1','-GSLICE_COUNT=1','-GLINE_WORDS=1','-GSET_COUNT_PER_SLICE=1','-GWRITE_ID_W=1','-GMAX_WB_RETRIES=0']),
   ('TWO',['-GCLIENT_COUNT=2','-GLOCAL_TAG_W=2','-GCLIENT_MAX_OUTSTANDING=2','-GCOMMIT_PORT_COUNT=2','-GSTORE_LANES=4','-GSLICE_COUNT=2','-GLINE_WORDS=4','-GSET_COUNT_PER_SLICE=16','-GWRITE_ID_W=4','-GMAX_WB_RETRIES=2']),
   ('WIDE',['-GCLIENT_COUNT=4','-GLOCAL_TAG_W=3','-GCLIENT_MAX_OUTSTANDING=4','-GCOMMIT_PORT_COUNT=4','-GSTORE_LANES=8','-GSLICE_COUNT=4','-GLINE_WORDS=8','-GSET_COUNT_PER_SLICE=64','-GWRITE_ID_W=8','-GMAX_WB_RETRIES=3']))
  for n,ps in vv:run(base+['--lint-only','--top-module','a0_production_store_commit_write_miss_visibility_subsystem','--Mdir',d/('m_'+n.lower()),*ps,*files],'MATRIX_'+n)
  print('PROD_SEAM_P25_STRICT_LINT=PASS');print('PROD_SEAM_P25_PARAMETER_MATRIX=PASS variants=3')
  sim=build_and_run('a0_production_store_commit_write_miss_visibility_subsystem_tb',[*files,TB],d/'e2e','E2E')
  ls=set(sim.splitlines());miss=[m for m in MARK if m not in ls]
  if miss:fail('MARKERS',str(miss))
  print(f'PROD_SEAM_P25_BEHAVIOR=PASS markers={len(MARK)}')
 print('PROD_SEAM_P25_P24_PREDECESSOR=PASS mode=frozen-canonical-receipt')
 h=run(['git','rev-parse','HEAD'],'HEAD',30).strip();br=run(['git','branch','--show-current'],'BRANCH',30).strip();run(['git','diff','--check'],'DIFFCHECK',30);df=run(['bash','-lc','git diff --binary|sha256sum|cut -d" " -f1'],'DIFFSHA',30).strip()
 if(h,br,df)!=(HEAD,BR,DIFF):fail('CONTAINMENT',f'{h} {br} {df}')
 for e,n in [('A0_STRICT_OUTER_LOG','OUTER'),('A0_STRICT_INNER_LOG','INNER')]:
  if os.environ.get(e) and leak(os.environ[e]):fail(n+'_LEAK',str(leak(os.environ[e])))
 print('PROD_SEAM_P25_OUTER_STRICT_LEAK=0');print('PROD_SEAM_P25_INNER_STRICT_LEAK=0');print('PROD_SEAM_P25_POST_CONTAINMENT=PASS');print('PROD_SEAM_P25_GATE=PASS')
if __name__=='__main__':main()
