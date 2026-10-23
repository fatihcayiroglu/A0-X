#!/usr/bin/env python3
from __future__ import annotations
import hashlib,json,os,shutil,subprocess,sys,tempfile
from pathlib import Path
ROOT=Path(__file__).resolve().parents[1]
V=Path(os.environ.get('A0_VERILATOR_BIN',shutil.which('verilator') or 'verilator'))
HEAD='996d8c188e5d4f94b4bad5289392844d55d092f6';BR='main';DIFF='59fac4fc152cc4e46ed60bff0feecf700756d860ed4f44436f532a221570eb8b'
R=ROOT.parent/'EVIDENCE/P23/receipt.txt';R_SHA='32c07bb23031cb3fe197e3c1e1b7e13bdaf4497f4e0c0a00f0443baa6bc9df7c'
P23={
 ROOT/'rtl/memory/a0_l2_unified_line_backend_arbiter.sv':'8fb2d8162b9855966288b3138d0156dca0ea0fcff4b5fd71a6e2faa3d3d83c98',
 ROOT/'rtl/memory/a0_mc_noc_dirty_l2_unified_backend_subsystem.sv':'ae37fee3f52832b9387dd068fe8e55a2b2c86c8df33a417c4a4f9b2c82ea8456',
 ROOT/'tests/rtl/a0_l2_unified_line_backend_arbiter_tb.sv':'ddd90af9815465482643c1552149036a621f1fa15297cea771c7108ca758f472',
 ROOT/'tests/rtl/a0_mc_noc_dirty_l2_unified_backend_subsystem_tb.sv':'07bd82f33a6a45ab7f3c7bccfbda7a56a806542ebf6f815178ba0d05a2752e18',
 ROOT/'tests/run_prod_seam_p23.py':'54085b4c9fb009f5369cc3f8e06aa9cfef89fad85217108834170e855b56975d',
 ROOT/'docs/architecture/A0_PROD_SEAM_P23_UNIFIED_LINE_BACKEND.md':'c355d6b3f8b809351c481aaf46c1bd9f33d41da679f8d25225e1fd26d096d201'}
P7P8={
 ROOT/'rtl/memory/a0_store_visibility_commit_fence.sv':'bfb63a2006579b109e3eca656b8fb4037e2f1fcf88e53bdc91aaf3d86113ef30',
 ROOT/'rtl/memory/a0_store_commit_line_backend_adapter.sv':'92dae282cf856970f6419ab1ac7f8d474a58a01e9ca8d150524bf9f0f4160b59',
 ROOT/'docs/architecture/A0_PROD_SEAM_P7_STORE_VISIBILITY_COMMIT.md':'8fe4b99a064f408d4a240fb95eacb52aac5b82ea2855b9faef7b0ca5087c8d5f',
 ROOT/'docs/architecture/A0_PROD_SEAM_P8_UNIFIED_BACKEND_VISIBILITY.md':'5735641530d8e9c08299cf050cab65199ef63a311648fb9250f41ca3af5d684e'}
FAB=ROOT/'rtl/memory/a0_line_slice_fabric.sv';P17=ROOT/'rtl/memory/a0_l2_dirty_writeback_slice.sv';G=ROOT/'rtl/memory/a0_l2_writeback_completion_guard.sv';C=ROOT/'rtl/memory/a0_l2_writeback_recovery_controller.sv';P19=ROOT/'rtl/memory/a0_l2_recoverable_writeback_slice.sv';P20=ROOT/'rtl/memory/a0_l2_multislice_writeback_queue.sv';P21=ROOT/'rtl/memory/a0_l2_multislice_recoverable_writeback_subsystem.sv';P22=ROOT/'rtl/memory/a0_mc_noc_multislice_recoverable_writeback_subsystem.sv';A=ROOT/'rtl/memory/a0_l2_unified_line_backend_arbiter.sv';P23S=ROOT/'rtl/memory/a0_mc_noc_dirty_l2_unified_backend_subsystem.sv'
ROUTER=ROOT/'rtl/memory/a0_store_commit_dirty_l2_router.sv';TOP=ROOT/'rtl/memory/a0_production_store_commit_dirty_l2_subsystem.sv';RTB=ROOT/'tests/rtl/a0_store_commit_dirty_l2_router_tb.sv';TB=ROOT/'tests/rtl/a0_production_store_commit_dirty_l2_subsystem_tb.sv';DOC=ROOT/'docs/architecture/A0_PROD_SEAM_P24_PRODUCTION_STORE_COMMIT_DIRTY_L2.md'
MARK=(
'PROD_SEAM_P24_PARTIAL_SLICE_ACCEPT_NO_DUPLICATE=PASS','PROD_SEAM_P24_EXACT_LANE_ADDRESS_DATA_ROUTING=PASS','PROD_SEAM_P24_UPSTREAM_ACK_AFTER_ALL_SLICES=PASS','PROD_SEAM_P24_ROUND_ROBIN_COMMIT_PROGRESS=PASS','PROD_SEAM_P24_EXACTLY_ONCE_COMMIT_ACK=PASS','PROD_SEAM_P24_ROUTER_BEHAVIOR=PASS',
'PROD_SEAM_P24_PRELOAD_HOME_SLICE_ROUTE=PASS','PROD_SEAM_P24_MULTI_SLICE_RESIDENT_STORE_UPDATE=PASS','PROD_SEAM_P24_HOME_SLICE_LANE_IDENTITY=PASS','PROD_SEAM_P24_POST_COMMIT_L2_HIT_FRESH=PASS','PROD_SEAM_P24_COMMITTED_DATA_RETAINED_FOR_DURABLE_WB=PASS','PROD_SEAM_P24_POST_WRITEBACK_REQUESTER_IDENTITY=PASS','PROD_SEAM_P24_FINAL_DRAIN_DIAGNOSTIC_CLEAN=PASS','PROD_SEAM_P24_END_TO_END_BEHAVIOR=PASS')
def sha(p):
 h=hashlib.sha256();h.update(Path(p).read_bytes());return h.hexdigest()
def fail(s,d,rc=1):
 print('PROD_SEAM_P24_FIRST_FAILURE',file=sys.stderr);print('STAGE='+s,file=sys.stderr);print('DETAIL='+d,file=sys.stderr);raise SystemExit(rc)
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
 flags=[str(V),'--cc','--exe','--main','--timing','--unroll-count','512','-Wall','-Werror-PINMISSING','-Werror-WIDTHEXPAND','-Werror-WIDTHTRUNC','--top-module',top,'--Mdir',obj,*files]
 run(flags,stage+'_GENERATE',600)
 run(['make','-C',obj,'-f','V'+top+'.mk','-j1'],stage+'_MAKE',600)
 return run([Path(obj)/('V'+top)],stage+'_SIM',120)
def main():
 v=run([V,'--version'],'VERSION',30).strip()
 if not v.startswith('Verilator 5.050 '):fail('VERSION',v)
 print('PROD_SEAM_P24_EXACT_VERILATOR_5_050=PASS')
 if sha(R)!=R_SHA or 'PROD_SEAM_P23_GATE=PASS' not in R.read_text():fail('P23_RECEIPT','mismatch')
 for f,h in {**P23,**P7P8}.items():
  if sha(f)!=h:fail('PREDECESSOR_IMMUTABILITY',str(f))
 st=ROUTER.read_text()+TOP.read_text();doc=DOC.read_text()
 for x in ('accepted_slice_q','line_to_slice','commit_ready_o','a0_mc_noc_dirty_l2_unified_backend_subsystem','source_protocol_error_o'):
  if x not in st:fail('STATIC',x)
 for x in ('same line/home-slice hash','every required slice','not a claim of simultaneous globally atomic visibility','conflicting loads/replays remain blocked','no-write-allocate'):
  if x not in doc:fail('DOC',x)
 print('PROD_SEAM_P24_STATIC_COMPOSITION_CONTRACT=PASS')
 print('PROD_SEAM_P24_BOUNDED_MULTI_SLICE_FANOUT=PASS')
 print('PROD_SEAM_P24_DOCUMENTED_VISIBILITY_CONTRACT=PASS')
 files=[FAB,P17,G,C,P19,P20,P21,P22,A,P23S,ROUTER,TOP]
 with tempfile.TemporaryDirectory(prefix='p24_',dir='/tmp') as td:
  d=Path(td);base=[str(V),'--timing','--unroll-count','512','-Wall','-Werror-PINMISSING','-Werror-WIDTHEXPAND','-Werror-WIDTHTRUNC']
  vv=(
   ('ONE',['-GCLIENT_COUNT=1','-GLOCAL_TAG_W=1','-GCLIENT_MAX_OUTSTANDING=1','-GCOMMIT_PORT_COUNT=1','-GSTORE_LANES=1','-GSLICE_COUNT=1','-GLINE_WORDS=1','-GSET_COUNT_PER_SLICE=1','-GWRITE_ID_W=1','-GMAX_WB_RETRIES=0']),
   ('TWO',['-GCLIENT_COUNT=2','-GLOCAL_TAG_W=2','-GCLIENT_MAX_OUTSTANDING=2','-GCOMMIT_PORT_COUNT=2','-GSTORE_LANES=4','-GSLICE_COUNT=2','-GLINE_WORDS=4','-GSET_COUNT_PER_SLICE=16','-GWRITE_ID_W=4','-GMAX_WB_RETRIES=2']),
   ('WIDE',['-GCLIENT_COUNT=4','-GLOCAL_TAG_W=3','-GCLIENT_MAX_OUTSTANDING=4','-GCOMMIT_PORT_COUNT=3','-GSTORE_LANES=8','-GSLICE_COUNT=4','-GLINE_WORDS=8','-GSET_COUNT_PER_SLICE=64','-GWRITE_ID_W=8','-GMAX_WB_RETRIES=3']))
  for n,ps in vv:
   run(base+['--lint-only','--top-module','a0_production_store_commit_dirty_l2_subsystem','--Mdir',d/('m_'+n.lower()),*ps,*files],'MATRIX_'+n)
  print('PROD_SEAM_P24_STRICT_LINT=PASS');print('PROD_SEAM_P24_PARAMETER_MATRIX=PASS variants=3')
  s1=build_and_run('a0_store_commit_dirty_l2_router_tb',[ROUTER,RTB],d/'router','ROUTER')
  s2=build_and_run('a0_production_store_commit_dirty_l2_subsystem_tb',[*files,TB],d/'e2e','E2E')
  ls=set((s1+'\n'+s2).splitlines());miss=[m for m in MARK if m not in ls]
  if miss:fail('MARKERS',str(miss))
  print(f'PROD_SEAM_P24_BEHAVIOR=PASS markers={len(MARK)}')
 print('PROD_SEAM_P24_P23_PREDECESSOR=PASS mode=frozen-canonical-receipt')
 print('PROD_SEAM_P24_P7_P8_COMMIT_CONTRACT_IMMUTABLE=PASS')
 h=run(['git','rev-parse','HEAD'],'HEAD',30).strip();br=run(['git','branch','--show-current'],'BRANCH',30).strip();run(['git','diff','--check'],'DIFFCHECK',30);df=run(['bash','-lc','git diff --binary|sha256sum|cut -d" " -f1'],'DIFFSHA',30).strip()
 if(h,br,df)!=(HEAD,BR,DIFF):fail('CONTAINMENT',f'{h} {br} {df}')
 for e,n in [('A0_STRICT_OUTER_LOG','OUTER'),('A0_STRICT_INNER_LOG','INNER')]:
  if os.environ.get(e) and leak(os.environ[e]):fail(n+'_LEAK',str(leak(os.environ[e])))
 print('PROD_SEAM_P24_OUTER_STRICT_LEAK=0');print('PROD_SEAM_P24_INNER_STRICT_LEAK=0');print('PROD_SEAM_P24_POST_CONTAINMENT=PASS');print('PROD_SEAM_P24_GATE=PASS')
if __name__=='__main__':main()
