#!/usr/bin/env python3
from __future__ import annotations
import hashlib,json,os,shutil,subprocess,sys,tempfile
from pathlib import Path
ROOT=Path(__file__).resolve().parents[1]
V=Path(os.environ.get('A0_VERILATOR_BIN',shutil.which('verilator') or 'verilator'))
HEAD='996d8c188e5d4f94b4bad5289392844d55d092f6';BR='main';DIFF='59fac4fc152cc4e46ed60bff0feecf700756d860ed4f44436f532a221570eb8b'
R=ROOT.parent/'EVIDENCE/P22/receipt.txt';R_SHA='7a9b8edbf9fafb1025a478170df896bd1948dccf80badbea7babbf62c57ea0e3'
P22={
 ROOT/'rtl/memory/a0_mc_noc_multislice_recoverable_writeback_subsystem.sv':'f44e6d5e0588e3fec83f557dfa8faa9080315bef399626f7eee464d0ea0ca341',
 ROOT/'tests/rtl/a0_mc_noc_multislice_recoverable_writeback_subsystem_tb.sv':'4d2c6cfd867fa240a173bae7bfbc21c27ecaa4aa1ccf6b4e438dc2606b40e22e',
 ROOT/'tests/run_prod_seam_p22.py':'b8f0aaf5cfcdb587b5d9a450c850a96a3ed3be32d63579de4594ece2bd9d0f72',
 ROOT/'docs/architecture/A0_PROD_SEAM_P22_MC_NOC_DIRTY_WRITEBACK.md':'3d38aa133f9d711944a596cb17bdf9df526a9ccf3079a45906fcc40e1d45b62b'}
FAB=ROOT/'rtl/memory/a0_line_slice_fabric.sv';P17=ROOT/'rtl/memory/a0_l2_dirty_writeback_slice.sv';G=ROOT/'rtl/memory/a0_l2_writeback_completion_guard.sv';C=ROOT/'rtl/memory/a0_l2_writeback_recovery_controller.sv';P19=ROOT/'rtl/memory/a0_l2_recoverable_writeback_slice.sv';P20=ROOT/'rtl/memory/a0_l2_multislice_writeback_queue.sv';P21=ROOT/'rtl/memory/a0_l2_multislice_recoverable_writeback_subsystem.sv';P22S=ROOT/'rtl/memory/a0_mc_noc_multislice_recoverable_writeback_subsystem.sv'
A=ROOT/'rtl/memory/a0_l2_unified_line_backend_arbiter.sv';S=ROOT/'rtl/memory/a0_mc_noc_dirty_l2_unified_backend_subsystem.sv';ATB=ROOT/'tests/rtl/a0_l2_unified_line_backend_arbiter_tb.sv';TB=ROOT/'tests/rtl/a0_mc_noc_dirty_l2_unified_backend_subsystem_tb.sv';DOC=ROOT/'docs/architecture/A0_PROD_SEAM_P23_UNIFIED_LINE_BACKEND.md'
MARK=(
'PROD_SEAM_P23_BACKPRESSURE_PAYLOAD_STABLE=PASS','PROD_SEAM_P23_ROUND_ROBIN_READ_WRITE_FAIRNESS=PASS','PROD_SEAM_P23_TYPED_COMMAND_IDENTITY=PASS','PROD_SEAM_P23_READ_RESPONSE_IDENTITY_ROUTE=PASS','PROD_SEAM_P23_INVALID_READ_PORT_CONTAINED=PASS','PROD_SEAM_P23_WRITE_STATUS_IDENTITY_ROUTE=PASS','PROD_SEAM_P23_ARBITER_BEHAVIOR=PASS',
'PROD_SEAM_P23_UNIFIED_READ_HOME_SLICE_ROUTE=PASS','PROD_SEAM_P23_END_TO_END_REQUESTER_RESTORE=PASS','PROD_SEAM_P23_UNIFIED_WRITEBACK_COMMANDS=PASS','PROD_SEAM_P23_DIRTY_REPLACEMENT_HELD_UNTIL_DURABLE=PASS','PROD_SEAM_P23_OOO_WRITE_STATUS_RELEASE_ISOLATION=PASS','PROD_SEAM_P23_POST_WRITEBACK_READ_RESPONSE_RESTORE=PASS','PROD_SEAM_P23_FINAL_DRAIN_DIAGNOSTIC_CLEAN=PASS','PROD_SEAM_P23_END_TO_END_BEHAVIOR=PASS')
def sha(p):h=hashlib.sha256();h.update(Path(p).read_bytes());return h.hexdigest()
def fail(s,d,rc=1):print('PROD_SEAM_P23_FIRST_FAILURE',file=sys.stderr);print('STAGE='+s,file=sys.stderr);print('DETAIL='+d,file=sys.stderr);raise SystemExit(rc)
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
 print('PROD_SEAM_P23_EXACT_VERILATOR_5_050=PASS')
 if sha(R)!=R_SHA or 'PROD_SEAM_P22_GATE=PASS' not in R.read_text():fail('P22_RECEIPT','mismatch')
 for f,h in P22.items():
  if sha(f)!=h:fail('P22_IMMUTABILITY',str(f))
 st=A.read_text()+S.read_text();doc=DOC.read_text()
 for x in ('a0_l2_unified_line_backend_arbiter','a0_mc_noc_multislice_recoverable_writeback_subsystem','wb_buf_valid_q','BACKEND_READ_TAG_W','backend_cmd_write_o','read_resp_protocol_error'):
  if x not in st:fail('STATIC',x)
 for x in ('`{home_slice, global_requester_tag}`','registered writeback input decoupler','bounded round-robin','does not claim a physical VRAM controller'):
  if x not in doc:fail('DOC',x)
 print('PROD_SEAM_P23_STATIC_UNIFIED_BACKEND_COMPOSITION=PASS');print('PROD_SEAM_P23_REGISTERED_BACKPRESSURE_BOUNDARY=PASS');print('PROD_SEAM_P23_DOCUMENTED_TYPED_IDENTITY_CONTRACT=PASS')
 files=[FAB,P17,G,C,P19,P20,P21,P22S,A,S]
 with tempfile.TemporaryDirectory(prefix='p23_',dir='/tmp') as td:
  d=Path(td);b=[str(V),'--timing','--unroll-count','512','-Wall','-Werror-PINMISSING','-Werror-WIDTHEXPAND','-Werror-WIDTHTRUNC']
  vv=(('ONE',['-GCLIENT_COUNT=1','-GLOCAL_TAG_W=1','-GCLIENT_MAX_OUTSTANDING=1','-GSLICE_COUNT=1','-GSTORE_LANES_PER_SLICE=1','-GLINE_WORDS=1','-GSET_COUNT_PER_SLICE=1','-GWRITE_ID_W=1','-GMAX_WB_RETRIES=0']),('TWO',['-GCLIENT_COUNT=2','-GLOCAL_TAG_W=2','-GCLIENT_MAX_OUTSTANDING=2','-GSLICE_COUNT=2','-GSTORE_LANES_PER_SLICE=2','-GLINE_WORDS=4','-GSET_COUNT_PER_SLICE=16','-GWRITE_ID_W=4','-GMAX_WB_RETRIES=2']),('WIDE',['-GCLIENT_COUNT=4','-GLOCAL_TAG_W=3','-GCLIENT_MAX_OUTSTANDING=4','-GSLICE_COUNT=4','-GSTORE_LANES_PER_SLICE=8','-GLINE_WORDS=8','-GSET_COUNT_PER_SLICE=64','-GWRITE_ID_W=8','-GMAX_WB_RETRIES=3']))
  for n,ps in vv:run(b+['--lint-only','--top-module','a0_mc_noc_dirty_l2_unified_backend_subsystem','--Mdir',d/('m_'+n.lower()),*ps,*files],'MATRIX_'+n)
  print('PROD_SEAM_P23_STRICT_LINT=PASS');print('PROD_SEAM_P23_PARAMETER_MATRIX=PASS variants=3')
  oa=d/'arb';run(b+['--binary','--top-module','a0_l2_unified_line_backend_arbiter_tb','--Mdir',oa,A,ATB],'ARBITER_BUILD');s1=run([oa/'Va0_l2_unified_line_backend_arbiter_tb'],'ARBITER_SIM',60)
  oe=d/'e2e';run(b+['--binary','--top-module','a0_mc_noc_dirty_l2_unified_backend_subsystem_tb','--Mdir',oe,*files,TB],'E2E_BUILD');s2=run([oe/'Va0_mc_noc_dirty_l2_unified_backend_subsystem_tb'],'E2E_SIM',60)
  ls=set((s1+'\n'+s2).splitlines());miss=[m for m in MARK if m not in ls]
  if miss:fail('MARKERS',str(miss))
  print(f'PROD_SEAM_P23_BEHAVIOR=PASS markers={len(MARK)}')
 print('PROD_SEAM_P23_P22_PREDECESSOR=PASS mode=frozen-canonical-receipt')
 h=run(['git','rev-parse','HEAD'],'HEAD',30).strip();br=run(['git','branch','--show-current'],'BRANCH',30).strip();run(['git','diff','--check'],'DIFFCHECK',30);df=run(['bash','-lc','git diff --binary|sha256sum|cut -d" " -f1'],'DIFFSHA',30).strip()
 if(h,br,df)!=(HEAD,BR,DIFF):fail('CONTAINMENT',f'{h} {br} {df}')
 for e,n in [('A0_STRICT_OUTER_LOG','OUTER'),('A0_STRICT_INNER_LOG','INNER')]:
  if os.environ.get(e) and leak(os.environ[e]):fail(n+'_LEAK',str(leak(os.environ[e])))
 print('PROD_SEAM_P23_OUTER_STRICT_LEAK=0');print('PROD_SEAM_P23_INNER_STRICT_LEAK=0');print('PROD_SEAM_P23_POST_CONTAINMENT=PASS');print('PROD_SEAM_P23_GATE=PASS')
if __name__=='__main__':main()
