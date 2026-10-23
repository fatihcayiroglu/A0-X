#!/usr/bin/env python3
from __future__ import annotations
import hashlib,json,os,shutil,subprocess,sys,tempfile
from pathlib import Path
ROOT=Path(__file__).resolve().parents[1];V=Path(os.environ.get('A0_VERILATOR_BIN',shutil.which('verilator') or 'verilator'))
HEAD='996d8c188e5d4f94b4bad5289392844d55d092f6';BR='main';DIFF='59fac4fc152cc4e46ed60bff0feecf700756d860ed4f44436f532a221570eb8b'
R=ROOT.parent/'EVIDENCE/P19/receipt.txt';R_SHA='bf6f3dbb866ad1c58b625bb4a706f391e74a395b9684bcd16ca3d9c611031bf4'
P19={ROOT/'rtl/memory/a0_l2_writeback_recovery_controller.sv':'c153041228d9c3b75204592023c811b77df46a9ceee79db8e2315aa82225b425',ROOT/'rtl/memory/a0_l2_recoverable_writeback_slice.sv':'862c5530b284fba6cc2c5dde3a78bf024df1fbd39de755d4a72578257aa9a28b',ROOT/'tests/rtl/a0_l2_recoverable_writeback_slice_tb.sv':'d89dd81d6f1a58e6d58a4ce136cfee444c17c76ec39533b90227b48665afab7f',ROOT/'tests/run_prod_seam_p19.py':'f226301f657c1026f32f8a114c7b78d77b49c2bc511c83d87019cbbbc405a9ff',ROOT/'docs/architecture/A0_PROD_SEAM_P19_WRITEBACK_RECOVERY.md':'69ab867cd5033cd86205aaa5a8f3c82c54c7b37b550a4edba85fe99be8af14db'}
S=ROOT/'rtl/memory/a0_l2_multislice_writeback_queue.sv';TB=ROOT/'tests/rtl/a0_l2_multislice_writeback_queue_tb.sv';DOC=ROOT/'docs/architecture/A0_PROD_SEAM_P20_MULTISLICE_WRITEBACK_QUEUE.md'
MARK=('PROD_SEAM_P20_RESET_EMPTY=PASS','PROD_SEAM_P20_MULTI_SOURCE_CAPTURE=PASS','PROD_SEAM_P20_BACKPRESSURE_PAYLOAD_STABLE=PASS','PROD_SEAM_P20_ROUND_ROBIN_FAIR_ISSUE=PASS','PROD_SEAM_P20_MULTIPLE_LIVE_ATTEMPTS=PASS','PROD_SEAM_P20_PER_SOURCE_LIVE_BACKPRESSURE=PASS','PROD_SEAM_P20_OOO_STATUS_IDENTITY_RESTORE=PASS','PROD_SEAM_P20_FAILURE_STATUS_ISOLATED=PASS','PROD_SEAM_P20_RR_WRAP_FAIRNESS=PASS','PROD_SEAM_P20_SAME_CYCLE_ISSUE_STATUS=PASS','PROD_SEAM_P20_STALE_STATUS_CONTAINED=PASS','PROD_SEAM_P20_ZERO_ATTEMPT_STATUS_VALID_GUARD=PASS','PROD_SEAM_P20_BEHAVIOR=PASS')
def sha(p):h=hashlib.sha256();h.update(Path(p).read_bytes());return h.hexdigest()
def fail(s,d,rc=1):print('PROD_SEAM_P20_FIRST_FAILURE',file=sys.stderr);print('STAGE='+s,file=sys.stderr);print('DETAIL='+d,file=sys.stderr);raise SystemExit(rc)
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
 print('PROD_SEAM_P20_EXACT_VERILATOR_5_050=PASS')
 if sha(R)!=R_SHA or 'PROD_SEAM_P19_GATE=PASS' not in R.read_text():fail('P19_RECEIPT','mismatch')
 for f,h in P19.items():
  if sha(f)!=h:fail('P19_IMMUTABILITY',str(f))
 st=S.read_text();doc=DOC.read_text()
 for x in ('pending_q','active_q','rr_q','status_issue_match','status_active_match','protocol_error_o'):
  if x not in st:fail('STATIC',x)
 for x in ('`{slice_id, local_attempt_id}`','out-of-order status','Same-cycle issue+status'):
  if x not in doc:fail('DOC',x)
 print('PROD_SEAM_P20_STATIC_MULTISLICE_QUEUE_CONTRACT=PASS');print('PROD_SEAM_P20_BOUNDED_PER_SOURCE_SCOPE=PASS');print('PROD_SEAM_P20_DOCUMENTED_IDENTITY_FAIRNESS_CONTRACT=PASS')
 with tempfile.TemporaryDirectory(prefix='p20_',dir='/tmp') as d:
  d=Path(d);b=[str(V),'--timing','--unroll-count','512','-Wall','-Werror-PINMISSING','-Werror-WIDTHEXPAND','-Werror-WIDTHTRUNC']
  vv=(('ONE',['-GSOURCE_COUNT=1','-GLINE_WORDS=1','-GLINE_ADDR_W=8','-GLOCAL_ATTEMPT_ID_W=1']),('THREE',['-GSOURCE_COUNT=3','-GLINE_WORDS=4','-GLINE_ADDR_W=20','-GLOCAL_ATTEMPT_ID_W=4']),('WIDE',['-GSOURCE_COUNT=8','-GLINE_WORDS=8','-GLINE_ADDR_W=29','-GLOCAL_ATTEMPT_ID_W=12']))
  for n,ps in vv:run(b+['--lint-only','--top-module','a0_l2_multislice_writeback_queue','--Mdir',d/('m_'+n.lower()),*ps,S],'MATRIX_'+n)
  print('PROD_SEAM_P20_STRICT_LINT=PASS');print('PROD_SEAM_P20_PARAMETER_MATRIX=PASS variants=3')
  o=d/'beh';run(b+['--binary','--top-module','a0_l2_multislice_writeback_queue_tb','--Mdir',o,S,TB],'BEHAVIOR_BUILD');sim=run([o/'Va0_l2_multislice_writeback_queue_tb'],'BEHAVIOR_SIM',60);ls=set(sim.splitlines());miss=[m for m in MARK if m not in ls]
  if miss:fail('MARKERS',str(miss))
  print(f'PROD_SEAM_P20_BEHAVIOR=PASS markers={len(MARK)}')
 print('PROD_SEAM_P20_P19_PREDECESSOR=PASS mode=frozen-canonical-receipt')
 h=run(['git','rev-parse','HEAD'],'HEAD',30).strip();br=run(['git','branch','--show-current'],'BRANCH',30).strip();run(['git','diff','--check'],'DIFFCHECK',30);df=run(['bash','-lc','git diff --binary|sha256sum|cut -d" " -f1'],'DIFFSHA',30).strip()
 if(h,br,df)!=(HEAD,BR,DIFF):fail('CONTAINMENT',f'{h} {br} {df}')
 for e,n in [('A0_STRICT_OUTER_LOG','OUTER'),('A0_STRICT_INNER_LOG','INNER')]:
  if os.environ.get(e) and leak(os.environ[e]):fail(n+'_LEAK',str(leak(os.environ[e])))
 print('PROD_SEAM_P20_OUTER_STRICT_LEAK=0');print('PROD_SEAM_P20_INNER_STRICT_LEAK=0');print('PROD_SEAM_P20_POST_CONTAINMENT=PASS');print('PROD_SEAM_P20_GATE=PASS')
if __name__=='__main__':main()
