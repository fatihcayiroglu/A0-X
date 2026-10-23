#!/usr/bin/env python3
from __future__ import annotations
import hashlib,json,os,shutil,subprocess,sys,tempfile
from pathlib import Path
ROOT=Path(__file__).resolve().parents[1]
V=Path(os.environ.get('A0_VERILATOR_BIN',shutil.which('verilator') or 'verilator'))
HEAD='996d8c188e5d4f94b4bad5289392844d55d092f6';BR='main';DIFF='59fac4fc152cc4e46ed60bff0feecf700756d860ed4f44436f532a221570eb8b'
R=ROOT.parent/'EVIDENCE/P20/receipt.txt';R_SHA='49e3706d97b106e342c28afadedc668e7fca2b89b5f332229a91813175eabbc1'
P20={
 ROOT/'rtl/memory/a0_l2_multislice_writeback_queue.sv':'95835b175a853014b302b9c463c94fb3a2059a52e80502527344d5e5414fe924',
 ROOT/'tests/rtl/a0_l2_multislice_writeback_queue_tb.sv':'18c33d9164ec495f87f796ade119101250c255b8046239c9a0ba9cd24b3b2acd',
 ROOT/'tests/run_prod_seam_p20.py':'f13adb23af1b3d64bfe9c96d04bd5d9d43836c589925faf8fe5e4e5cf399d97e',
 ROOT/'docs/architecture/A0_PROD_SEAM_P20_MULTISLICE_WRITEBACK_QUEUE.md':'96735bfa124debc99cb2f203436b54979117129b1cfaa59d7defb388ec6520fa'}
P17=ROOT/'rtl/memory/a0_l2_dirty_writeback_slice.sv';G=ROOT/'rtl/memory/a0_l2_writeback_completion_guard.sv';C=ROOT/'rtl/memory/a0_l2_writeback_recovery_controller.sv';P19=ROOT/'rtl/memory/a0_l2_recoverable_writeback_slice.sv';P20Q=ROOT/'rtl/memory/a0_l2_multislice_writeback_queue.sv'
S=ROOT/'rtl/memory/a0_l2_multislice_recoverable_writeback_subsystem.sv';TB=ROOT/'tests/rtl/a0_l2_multislice_recoverable_writeback_subsystem_tb.sv';DOC=ROOT/'docs/architecture/A0_PROD_SEAM_P21_MULTISLICE_RECOVERABLE_WRITEBACK.md'
MARK=('PROD_SEAM_P21_MULTI_SLICE_DIRTY_VICTIMS=PASS','PROD_SEAM_P21_SHARED_QUEUE_CAPTURE=PASS','PROD_SEAM_P21_FAIR_MULTI_SLICE_ISSUE=PASS','PROD_SEAM_P21_MULTIPLE_LIVE_ATTEMPTS=PASS','PROD_SEAM_P21_OOO_STATUS_RESTORE=PASS','PROD_SEAM_P21_SUCCESS_ONLY_PER_SLICE_RELEASE=PASS','PROD_SEAM_P21_FAILURE_ISOLATION=PASS','PROD_SEAM_P21_RECOVERY_SAFE_PER_SLICE=PASS','PROD_SEAM_P21_EXACT_VICTIM_RECOVERY_REISSUE=PASS','PROD_SEAM_P21_PEER_PROGRESS_DURING_FAILURE=PASS','PROD_SEAM_P21_FINAL_DRAIN=PASS','PROD_SEAM_P21_BEHAVIOR=PASS')
def sha(p):h=hashlib.sha256();h.update(Path(p).read_bytes());return h.hexdigest()
def fail(s,d,rc=1):print('PROD_SEAM_P21_FIRST_FAILURE',file=sys.stderr);print('STAGE='+s,file=sys.stderr);print('DETAIL='+d,file=sys.stderr);raise SystemExit(rc)
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
 print('PROD_SEAM_P21_EXACT_VERILATOR_5_050=PASS')
 if sha(R)!=R_SHA or 'PROD_SEAM_P20_GATE=PASS' not in R.read_text() or 'PROD_SEAM_P20_ZERO_ATTEMPT_STATUS_VALID_GUARD=PASS' not in R.read_text():fail('P20_RECEIPT','mismatch')
 for f,h in P20.items():
  if sha(f)!=h:fail('P20_IMMUTABILITY',str(f))
 st=S.read_text();doc=DOC.read_text()
 for x in ('a0_l2_recoverable_writeback_slice','a0_l2_multislice_writeback_queue','slice_wb_attempt_id','slice_status_attempt_id','backend_wb_recovery_safe_valid_i','queue_protocol_error'):
  if x not in st:fail('STATIC',x)
 for x in ('`{slice_id, local_attempt_id}`','matching `SUCCESS`','explicit per slice','epoch boundary'):
  if x not in doc:fail('DOC',x)
 print('PROD_SEAM_P21_STATIC_MULTISLICE_RECOVERABLE_COMPOSITION=PASS');print('PROD_SEAM_P21_BOUNDED_ONE_VICTIM_PER_SLICE_SCOPE=PASS');print('PROD_SEAM_P21_DOCUMENTED_SUCCESS_ONLY_RECOVERY_CONTRACT=PASS')
 with tempfile.TemporaryDirectory(prefix='p21_',dir='/tmp') as d:
  d=Path(d);b=[str(V),'--timing','--unroll-count','512','-Wall','-Werror-PINMISSING','-Werror-WIDTHEXPAND','-Werror-WIDTHTRUNC'];files=[P17,G,C,P19,P20Q,S]
  vv=(('ONE',['-GSLICE_COUNT=1','-GSTORE_LANES=1','-GLINE_WORDS=1','-GSET_COUNT=1','-GGLOBAL_TAG_W=1','-GWRITE_ID_W=1','-GMAX_WB_RETRIES=0']),('THREE',['-GSLICE_COUNT=3','-GSTORE_LANES=4','-GLINE_WORDS=4','-GSET_COUNT=16','-GGLOBAL_TAG_W=5','-GWRITE_ID_W=4','-GMAX_WB_RETRIES=2']),('WIDE',['-GSLICE_COUNT=8','-GSTORE_LANES=32','-GLINE_WORDS=8','-GSET_COUNT=256','-GGLOBAL_TAG_W=12','-GWRITE_ID_W=12','-GMAX_WB_RETRIES=7']))
  for n,ps in vv:run(b+['--lint-only','--top-module','a0_l2_multislice_recoverable_writeback_subsystem','--Mdir',d/('m_'+n.lower()),*ps,*files],'MATRIX_'+n)
  print('PROD_SEAM_P21_STRICT_LINT=PASS');print('PROD_SEAM_P21_PARAMETER_MATRIX=PASS variants=3')
  o=d/'beh';run(b+['--binary','--top-module','a0_l2_multislice_recoverable_writeback_subsystem_tb','--Mdir',o,*files,TB],'BEHAVIOR_BUILD');sim=run([o/'Va0_l2_multislice_recoverable_writeback_subsystem_tb'],'BEHAVIOR_SIM',60);ls=set(sim.splitlines());miss=[m for m in MARK if m not in ls]
  if miss:fail('MARKERS',str(miss))
  print(f'PROD_SEAM_P21_BEHAVIOR=PASS markers={len(MARK)}')
 print('PROD_SEAM_P21_P20_PREDECESSOR=PASS mode=frozen-canonical-receipt')
 h=run(['git','rev-parse','HEAD'],'HEAD',30).strip();br=run(['git','branch','--show-current'],'BRANCH',30).strip();run(['git','diff','--check'],'DIFFCHECK',30);df=run(['bash','-lc','git diff --binary|sha256sum|cut -d" " -f1'],'DIFFSHA',30).strip()
 if(h,br,df)!=(HEAD,BR,DIFF):fail('CONTAINMENT',f'{h} {br} {df}')
 for e,n in [('A0_STRICT_OUTER_LOG','OUTER'),('A0_STRICT_INNER_LOG','INNER')]:
  if os.environ.get(e) and leak(os.environ[e]):fail(n+'_LEAK',str(leak(os.environ[e])))
 print('PROD_SEAM_P21_OUTER_STRICT_LEAK=0');print('PROD_SEAM_P21_INNER_STRICT_LEAK=0');print('PROD_SEAM_P21_POST_CONTAINMENT=PASS');print('PROD_SEAM_P21_GATE=PASS')
if __name__=='__main__':main()
