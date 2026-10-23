#!/usr/bin/env python3
from __future__ import annotations
import hashlib,json,os,shutil,subprocess,sys,tempfile
from pathlib import Path
ROOT=Path(__file__).resolve().parents[1]
V=Path(os.environ.get('A0_VERILATOR_BIN',shutil.which('verilator') or 'verilator'))
HEAD='996d8c188e5d4f94b4bad5289392844d55d092f6';BR='main';DIFF='59fac4fc152cc4e46ed60bff0feecf700756d860ed4f44436f532a221570eb8b'
R=ROOT.parent/'EVIDENCE/P21/receipt.txt';R_SHA='57152c9d2984b3dc2f75980389b9978e65c22f519ab1b885e4a8efa4cc8cbe85'
P21={
 ROOT/'rtl/memory/a0_l2_multislice_recoverable_writeback_subsystem.sv':'5b589f27fed04a58fd02c7e24b1e4c70db33051cf399e7451f090ca70b3f617e',
 ROOT/'tests/rtl/a0_l2_multislice_recoverable_writeback_subsystem_tb.sv':'a08b45341edee27759c7d0a235471e1c7130fcebacdda7e7419932a613205f14',
 ROOT/'tests/run_prod_seam_p21.py':'a0c7242122bd56ab5eb8b32ce4bc004a31111d713bcff3cd58f9256e444447f0',
 ROOT/'docs/architecture/A0_PROD_SEAM_P21_MULTISLICE_RECOVERABLE_WRITEBACK.md':'4abcb22924ffc5d2bc22435c815c4ca6d4f4c6b6e7a58cc7159400206c51a1d7'}
FAB=ROOT/'rtl/memory/a0_line_slice_fabric.sv';FAB_SHA='b4b12cbe2b5c6c99806f6b0e3f5e7402c1e1782c4a9b1de8153a64a84be47f39'
P17=ROOT/'rtl/memory/a0_l2_dirty_writeback_slice.sv';G=ROOT/'rtl/memory/a0_l2_writeback_completion_guard.sv';C=ROOT/'rtl/memory/a0_l2_writeback_recovery_controller.sv';P19=ROOT/'rtl/memory/a0_l2_recoverable_writeback_slice.sv';P20=ROOT/'rtl/memory/a0_l2_multislice_writeback_queue.sv';P21S=ROOT/'rtl/memory/a0_l2_multislice_recoverable_writeback_subsystem.sv'
S=ROOT/'rtl/memory/a0_mc_noc_multislice_recoverable_writeback_subsystem.sv';TB=ROOT/'tests/rtl/a0_mc_noc_multislice_recoverable_writeback_subsystem_tb.sv';DOC=ROOT/'docs/architecture/A0_PROD_SEAM_P22_MC_NOC_DIRTY_WRITEBACK.md'
MARK=('PROD_SEAM_P22_CLIENT_HOME_SLICE_ROUTING=PASS','PROD_SEAM_P22_INITIAL_RESPONSE_IDENTITY_RESTORE=PASS','PROD_SEAM_P22_SLICE_LOCAL_DIRTY_UPDATE=PASS','PROD_SEAM_P22_DIRTY_REPLACEMENT_HELD=PASS','PROD_SEAM_P22_UNIFIED_WRITEBACK_IDENTITY=PASS','PROD_SEAM_P22_OOO_SUCCESS_RELEASE_ISOLATION=PASS','PROD_SEAM_P22_REPLACEMENT_REQUESTER_IDENTITY_PRESERVED=PASS','PROD_SEAM_P22_POST_WRITEBACK_RESPONSE_RESTORE=PASS','PROD_SEAM_P22_FINAL_DRAIN_DIAGNOSTIC_CLEAN=PASS','PROD_SEAM_P22_BEHAVIOR=PASS')
def sha(p):h=hashlib.sha256();h.update(Path(p).read_bytes());return h.hexdigest()
def fail(s,d,rc=1):print('PROD_SEAM_P22_FIRST_FAILURE',file=sys.stderr);print('STAGE='+s,file=sys.stderr);print('DETAIL='+d,file=sys.stderr);raise SystemExit(rc)
def run(c,s,t=600):
 c=[str(x) for x in c]
 if any(x.startswith('-Wno-') for x in c):fail(s,'suppression')
 try:p=subprocess.run(c,cwd=ROOT,text=True,stdout=subprocess.PIPE,stderr=subprocess.STDOUT,env={**os.environ,'PYTHONDONTWRITEBYTECODE':'1'},timeout=t)
 except subprocess.TimeoutExpired:fail(s,'TIMEOUT',124)
 if p.returncode:print(p.stdout,file=sys.stderr);fail(s,f'RC={p.returncode}',p.returncode)
 if 'verilator' in Path(c[0]).name and ('%Warning-' in p.stdout or '%Error' in p.stdout):print(p.stdout,file=sys.stderr);fail(s,'diagnostic',2)
 return p.stdout
def leak(x):
 p=Path(x)
 if not p.exists():return 0
 return sum(len(j.get('stripped',[]))+len(j.get('env_stripped',[])) for j in map(json.loads,p.read_text().splitlines()))
def main():
 v=run([V,'--version'],'VERSION',30).strip()
 if not v.startswith('Verilator 5.050 '):fail('VERSION',v)
 print('PROD_SEAM_P22_EXACT_VERILATOR_5_050=PASS')
 if sha(R)!=R_SHA or 'PROD_SEAM_P21_GATE=PASS' not in R.read_text():fail('P21_RECEIPT','mismatch')
 for f,h in P21.items():
  if sha(f)!=h:fail('P21_IMMUTABILITY',str(f))
 if sha(FAB)!=FAB_SHA:fail('FABRIC_IMMUTABILITY',str(FAB))
 st=S.read_text();doc=DOC.read_text()
 for x in ('a0_line_slice_fabric','a0_l2_multislice_recoverable_writeback_subsystem','slice_req_global_tag','slice_resp_global_tag','slice_store_wdata_i','backend_wb_attempt_id_o'):
  if x not in st:fail('STATIC',x)
 for x in ('`{client_id, local_tag}`','exact durable writeback `SUCCESS`','slice-local','does not invent'):
  if x not in doc:fail('DOC',x)
 print('PROD_SEAM_P22_STATIC_FABRIC_DIRTY_L2_COMPOSITION=PASS');print('PROD_SEAM_P22_BOUNDED_SLICE_LOCAL_STORE_SCOPE=PASS');print('PROD_SEAM_P22_DOCUMENTED_REQUESTER_IDENTITY_CONTRACT=PASS')
 with tempfile.TemporaryDirectory(prefix='p22_',dir='/tmp') as d:
  d=Path(d);b=[str(V),'--timing','--unroll-count','512','-Wall','-Werror-PINMISSING','-Werror-WIDTHEXPAND','-Werror-WIDTHTRUNC'];files=[FAB,P17,G,C,P19,P20,P21S,S]
  vv=(('ONE',['-GCLIENT_COUNT=1','-GLOCAL_TAG_W=1','-GCLIENT_MAX_OUTSTANDING=1','-GSLICE_COUNT=1','-GSTORE_LANES_PER_SLICE=1','-GLINE_WORDS=1','-GSET_COUNT_PER_SLICE=1','-GWRITE_ID_W=1','-GMAX_WB_RETRIES=0']),('TWO',['-GCLIENT_COUNT=2','-GLOCAL_TAG_W=2','-GCLIENT_MAX_OUTSTANDING=2','-GSLICE_COUNT=2','-GSTORE_LANES_PER_SLICE=2','-GLINE_WORDS=4','-GSET_COUNT_PER_SLICE=16','-GWRITE_ID_W=4','-GMAX_WB_RETRIES=2']),('WIDE',['-GCLIENT_COUNT=4','-GLOCAL_TAG_W=3','-GCLIENT_MAX_OUTSTANDING=4','-GSLICE_COUNT=4','-GSTORE_LANES_PER_SLICE=8','-GLINE_WORDS=8','-GSET_COUNT_PER_SLICE=64','-GWRITE_ID_W=8','-GMAX_WB_RETRIES=3']))
  for n,ps in vv:run(b+['--lint-only','--top-module','a0_mc_noc_multislice_recoverable_writeback_subsystem','--Mdir',d/('m_'+n.lower()),*ps,*files],'MATRIX_'+n)
  print('PROD_SEAM_P22_STRICT_LINT=PASS');print('PROD_SEAM_P22_PARAMETER_MATRIX=PASS variants=3')
  o=d/'beh';run(b+['--binary','--top-module','a0_mc_noc_multislice_recoverable_writeback_subsystem_tb','--Mdir',o,*files,TB],'BEHAVIOR_BUILD');sim=run([o/'Va0_mc_noc_multislice_recoverable_writeback_subsystem_tb'],'BEHAVIOR_SIM',60);ls=set(sim.splitlines());miss=[m for m in MARK if m not in ls]
  if miss:fail('MARKERS',str(miss))
  print(f'PROD_SEAM_P22_BEHAVIOR=PASS markers={len(MARK)}')
 print('PROD_SEAM_P22_P21_PREDECESSOR=PASS mode=frozen-canonical-receipt')
 h=run(['git','rev-parse','HEAD'],'HEAD',30).strip();br=run(['git','branch','--show-current'],'BRANCH',30).strip();run(['git','diff','--check'],'DIFFCHECK',30);df=run(['bash','-lc','git diff --binary|sha256sum|cut -d" " -f1'],'DIFFSHA',30).strip()
 if(h,br,df)!=(HEAD,BR,DIFF):fail('CONTAINMENT',f'{h} {br} {df}')
 for e,n in [('A0_STRICT_OUTER_LOG','OUTER'),('A0_STRICT_INNER_LOG','INNER')]:
  if os.environ.get(e) and leak(os.environ[e]):fail(n+'_LEAK',str(leak(os.environ[e])))
 print('PROD_SEAM_P22_OUTER_STRICT_LEAK=0');print('PROD_SEAM_P22_INNER_STRICT_LEAK=0');print('PROD_SEAM_P22_POST_CONTAINMENT=PASS');print('PROD_SEAM_P22_GATE=PASS')
if __name__=='__main__':main()
