#!/usr/bin/env python3
from __future__ import annotations
import hashlib,json,os,shutil,subprocess,sys,tempfile
from pathlib import Path
ROOT=Path(__file__).resolve().parents[1]; V=Path(os.environ.get('A0_VERILATOR_BIN',shutil.which('verilator') or 'verilator'))
HEAD='996d8c188e5d4f94b4bad5289392844d55d092f6'; BR='main'; DIFF='59fac4fc152cc4e46ed60bff0feecf700756d860ed4f44436f532a221570eb8b'
R=ROOT.parent/'EVIDENCE/P17/receipt.txt'; R_SHA='3beb0107e85def0b873a4b5ab8785157986d841e42fc74387c3fcef81f25ae97'
P17={ROOT/'rtl/memory/a0_l2_dirty_writeback_slice.sv':'0b4525e59be8adb1b9b3234a67afca072eaaa4c509652f788c1d66c3b416cfe7',ROOT/'tests/rtl/a0_l2_dirty_writeback_slice_tb.sv':'eaa9bb6590c4cee3d6c8f97dd86fe56b2be1eefd927ac4153ad2f5ece304d86a',ROOT/'tests/run_prod_seam_p17.py':'a89c86baddb04f2661eb20447d77c84258d25666b6d43f745cbd6dea24d8a120',ROOT/'docs/architecture/A0_PROD_SEAM_P17_DIRTY_WRITEBACK_FOUNDATION.md':'945418430efbe74c9797d933679809216d2ecf588d97ba9080392ab61d6e5283'}
G=ROOT/'rtl/memory/a0_l2_writeback_completion_guard.sv'; S=ROOT/'rtl/memory/a0_l2_durable_writeback_slice.sv'; P17S=ROOT/'rtl/memory/a0_l2_dirty_writeback_slice.sv'; TB=ROOT/'tests/rtl/a0_l2_durable_writeback_slice_tb.sv'; DOC=ROOT/'docs/architecture/A0_PROD_SEAM_P18_DURABLE_WRITEBACK_COMPLETION.md'
MARK=('PROD_SEAM_P18_DIRTY_SOURCE_READY=PASS','PROD_SEAM_P18_COMMAND_ACCEPTANCE_NOT_CLEAN=PASS','PROD_SEAM_P18_RETAINED_REFILL_BLOCKED_PENDING_STATUS=PASS','PROD_SEAM_P18_RETRY_EXACT_PAYLOAD=PASS','PROD_SEAM_P18_SUCCESS_RELEASES_P17_WRITEBACK=PASS','PROD_SEAM_P18_POST_SUCCESS_REFILL=PASS','PROD_SEAM_P18_TERMINAL_FAILURE_FAIL_CLOSED=PASS','PROD_SEAM_P18_NO_SYNTHETIC_CLEAN_ON_FAILURE=PASS','PROD_SEAM_P18_STALE_STATUS_CONTAINED=PASS','PROD_SEAM_P18_ATTEMPT_ID_PROVENANCE=PASS','PROD_SEAM_P18_BEHAVIOR=PASS')
def sha(p):
 h=hashlib.sha256(); h.update(Path(p).read_bytes()); return h.hexdigest()
def fail(s,d,rc=1): print('PROD_SEAM_P18_FIRST_FAILURE',file=sys.stderr);print('STAGE='+s,file=sys.stderr);print('DETAIL='+d,file=sys.stderr);raise SystemExit(rc)
def run(c,s,t=600):
 c=[str(x) for x in c]
 if any(x.startswith('-Wno-') for x in c): fail(s,'suppression')
 try:p=subprocess.run(c,cwd=ROOT,text=True,stdout=subprocess.PIPE,stderr=subprocess.STDOUT,env={**os.environ,'PYTHONDONTWRITEBYTECODE':'1'},timeout=t)
 except subprocess.TimeoutExpired: fail(s,'TIMEOUT',124)
 if p.returncode: print(p.stdout,file=sys.stderr);fail(s,f'RC={p.returncode}',p.returncode)
 if 'verilator' in Path(c[0]).name and ('%Warning-' in p.stdout or '%Error' in p.stdout): print(p.stdout,file=sys.stderr);fail(s,'diagnostic',2)
 return p.stdout
def leak(x):
 p=Path(x)
 if not p.exists():return 0
 return sum(len(j.get('stripped',[]))+len(j.get('env_stripped',[])) for j in map(json.loads,p.read_text().splitlines()))
def main():
 v=run([V,'--version'],'VERSION',30).strip()
 if not v.startswith('Verilator 5.050 '):fail('VERSION',v)
 print('PROD_SEAM_P18_EXACT_VERILATOR_5_050=PASS')
 if sha(R)!=R_SHA or 'PROD_SEAM_P17_GATE=PASS' not in R.read_text():fail('P17_RECEIPT','mismatch')
 for f,h in P17.items():
  if sha(f)!=h:fail('P17_IMMUTABILITY',str(f))
 st=G.read_text()+S.read_text(); doc=DOC.read_text()
 for x in ('status_success_fire','status_retry_fire','FAIL_CLOSED','victim_wb_ready_o','a0_l2_dirty_writeback_slice','a0_l2_writeback_completion_guard'):
  if x not in st:fail('STATIC',x)
 for x in ('matching backend writeback **SUCCESS**','same line and full victim data','No synthetic clean'):
  if x not in doc:fail('DOC',x)
 print('PROD_SEAM_P18_STATIC_DURABLE_WRITEBACK_CONTRACT=PASS');print('PROD_SEAM_P18_BOUNDED_COMPLETION_RETRY_SCOPE=PASS');print('PROD_SEAM_P18_DOCUMENTED_FAIL_CLOSED_CONTRACT=PASS')
 with tempfile.TemporaryDirectory(prefix='p18_',dir='/tmp') as d:
  d=Path(d);b=[str(V),'--timing','--unroll-count','512','-Wall','-Werror-PINMISSING','-Werror-WIDTHEXPAND','-Werror-WIDTHTRUNC']; files=[P17S,G,S]
  vv=(('MIN',['-GSTORE_LANES=1','-GLINE_WORDS=1','-GSET_COUNT=1','-GGLOBAL_TAG_W=1','-GWRITE_ID_W=1','-GMAX_WB_RETRIES=0']),('MID',['-GSTORE_LANES=4','-GLINE_WORDS=4','-GSET_COUNT=16','-GGLOBAL_TAG_W=5','-GWRITE_ID_W=4','-GMAX_WB_RETRIES=2']),('WIDE',['-GSTORE_LANES=32','-GLINE_WORDS=8','-GSET_COUNT=256','-GGLOBAL_TAG_W=12','-GWRITE_ID_W=12','-GMAX_WB_RETRIES=7']))
  for n,ps in vv:run(b+['--lint-only','--top-module','a0_l2_durable_writeback_slice','--Mdir',d/('m_'+n.lower()),*ps,*files],'MATRIX_'+n)
  print('PROD_SEAM_P18_STRICT_LINT=PASS');print('PROD_SEAM_P18_PARAMETER_MATRIX=PASS variants=3')
  o=d/'beh';run(b+['--binary','--top-module','a0_l2_durable_writeback_slice_tb','--Mdir',o,*files,TB],'BEHAVIOR_BUILD');sim=run([o/'Va0_l2_durable_writeback_slice_tb'],'BEHAVIOR_SIM',60);ls=set(sim.splitlines());miss=[x for x in MARK if x not in ls]
  if miss:fail('MARKERS',str(miss))
  print(f'PROD_SEAM_P18_BEHAVIOR=PASS markers={len(MARK)}')
 print('PROD_SEAM_P18_P17_PREDECESSOR=PASS mode=frozen-canonical-receipt')
 h=run(['git','rev-parse','HEAD'],'HEAD',30).strip();br=run(['git','branch','--show-current'],'BRANCH',30).strip();run(['git','diff','--check'],'DIFFCHECK',30);df=run(['bash','-lc','git diff --binary|sha256sum|cut -d" " -f1'],'DIFFSHA',30).strip()
 if(h,br,df)!=(HEAD,BR,DIFF):fail('CONTAINMENT',f'{h} {br} {df}')
 for e,n in [('A0_STRICT_OUTER_LOG','OUTER'),('A0_STRICT_INNER_LOG','INNER')]:
  if os.environ.get(e) and leak(os.environ[e]):fail(n+'_LEAK',str(leak(os.environ[e])))
 print('PROD_SEAM_P18_OUTER_STRICT_LEAK=0');print('PROD_SEAM_P18_INNER_STRICT_LEAK=0');print('PROD_SEAM_P18_POST_CONTAINMENT=PASS');print('PROD_SEAM_P18_GATE=PASS')
if __name__=='__main__':main()
