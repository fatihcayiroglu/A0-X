#!/usr/bin/env python3
from __future__ import annotations
import hashlib,json,os,shutil,subprocess,sys,tempfile
from pathlib import Path
ROOT=Path(__file__).resolve().parents[1];V=Path(os.environ.get('A0_VERILATOR_BIN',shutil.which('verilator') or 'verilator'))
HEAD='996d8c188e5d4f94b4bad5289392844d55d092f6';BR='main';DIFF='59fac4fc152cc4e46ed60bff0feecf700756d860ed4f44436f532a221570eb8b'
R=ROOT.parent/'EVIDENCE/P18/receipt.txt';R_SHA='94b477f669b6f23e72a165a5e9b272d585f2da016f97c3a12fb6f33828619dd8'
P18={ROOT/'rtl/memory/a0_l2_writeback_completion_guard.sv':'f8f02a91d30194e09ddcc5a79b31ab4759a455014eb306fbe1abdbd07228e24d',ROOT/'rtl/memory/a0_l2_durable_writeback_slice.sv':'ec2767d9f859d43e9ad02073526e57507a33abdf702dffa226f13a9afe70fabe',ROOT/'tests/rtl/a0_l2_durable_writeback_slice_tb.sv':'0a5bdea387f6b9c673188587b6ebce62bad572476f82eae80e691a8f1f88c89c',ROOT/'tests/run_prod_seam_p18.py':'986fd39d24d6e28e0832fa60dbf2bc6970a8a62e7586a8efb1deef950c2a0d91',ROOT/'docs/architecture/A0_PROD_SEAM_P18_DURABLE_WRITEBACK_COMPLETION.md':'ca74f40630e276dd6e18e908a5f0d58c91e075cc40bfd8aeb7adc7dec984cd88'}
P17=ROOT/'rtl/memory/a0_l2_dirty_writeback_slice.sv';G=ROOT/'rtl/memory/a0_l2_writeback_completion_guard.sv';C=ROOT/'rtl/memory/a0_l2_writeback_recovery_controller.sv';S=ROOT/'rtl/memory/a0_l2_recoverable_writeback_slice.sv';TB=ROOT/'tests/rtl/a0_l2_recoverable_writeback_slice_tb.sv';DOC=ROOT/'docs/architecture/A0_PROD_SEAM_P19_WRITEBACK_RECOVERY.md'
MARK=('PROD_SEAM_P19_EARLY_SAFE_NOT_CAPTURED=PASS','PROD_SEAM_P19_TERMINAL_FAILURE_RETAINS_DIRTY=PASS','PROD_SEAM_P19_RECOVERY_WAITS_FOR_BACKEND_SAFE=PASS','PROD_SEAM_P19_SAFE_ACK_DOES_NOT_CLEAN=PASS','PROD_SEAM_P19_EXACT_VICTIM_REISSUED=PASS','PROD_SEAM_P19_NO_SYNTHETIC_READY_ON_RECOVERY=PASS','PROD_SEAM_P19_POST_RECOVERY_SUCCESS_RELEASES=PASS','PROD_SEAM_P19_RECOVERY_EPOCH_COMPLETES_ONCE=PASS','PROD_SEAM_P19_POST_RECOVERY_REFILL=PASS','PROD_SEAM_P19_BEHAVIOR=PASS')
def sha(p):h=hashlib.sha256();h.update(Path(p).read_bytes());return h.hexdigest()
def fail(s,d,rc=1):print('PROD_SEAM_P19_FIRST_FAILURE',file=sys.stderr);print('STAGE='+s,file=sys.stderr);print('DETAIL='+d,file=sys.stderr);raise SystemExit(rc)
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
 print('PROD_SEAM_P19_EXACT_VERILATOR_5_050=PASS')
 if sha(R)!=R_SHA or 'PROD_SEAM_P18_GATE=PASS' not in R.read_text():fail('P18_RECEIPT','mismatch')
 for f,h in P18.items():
  if sha(f)!=h:fail('P18_IMMUTABILITY',str(f))
 st=C.read_text()+S.read_text();doc=DOC.read_text()
 for x in ('WAIT_SAFE','RESET_GUARD','guard_rst_n_o','backend_recovery_safe_ready_o','a0_l2_writeback_completion_guard','a0_l2_dirty_writeback_slice'):
  if x not in st:fail('STATIC',x)
 for x in ('never resets the cache','early backend recovery-safe signal is not captured','never synthesizes `wb_ready`'):
  if x not in doc:fail('DOC',x)
 print('PROD_SEAM_P19_STATIC_RECOVERY_CONTRACT=PASS');print('PROD_SEAM_P19_BOUNDED_GUARD_ONLY_RESET_SCOPE=PASS');print('PROD_SEAM_P19_DOCUMENTED_NO_SYNTHETIC_RELEASE=PASS')
 with tempfile.TemporaryDirectory(prefix='p19_',dir='/tmp') as d:
  d=Path(d);b=[str(V),'--timing','--unroll-count','512','-Wall','-Werror-PINMISSING','-Werror-WIDTHEXPAND','-Werror-WIDTHTRUNC'];files=[P17,G,C,S]
  vv=(('MIN',['-GSTORE_LANES=1','-GLINE_WORDS=1','-GSET_COUNT=1','-GGLOBAL_TAG_W=1','-GWRITE_ID_W=1','-GMAX_WB_RETRIES=0']),('MID',['-GSTORE_LANES=4','-GLINE_WORDS=4','-GSET_COUNT=16','-GGLOBAL_TAG_W=5','-GWRITE_ID_W=4','-GMAX_WB_RETRIES=2']),('WIDE',['-GSTORE_LANES=32','-GLINE_WORDS=8','-GSET_COUNT=256','-GGLOBAL_TAG_W=12','-GWRITE_ID_W=12','-GMAX_WB_RETRIES=7']))
  for n,ps in vv:run(b+['--lint-only','--top-module','a0_l2_recoverable_writeback_slice','--Mdir',d/('m_'+n.lower()),*ps,*files],'MATRIX_'+n)
  print('PROD_SEAM_P19_STRICT_LINT=PASS');print('PROD_SEAM_P19_PARAMETER_MATRIX=PASS variants=3')
  o=d/'beh';run(b+['--binary','--top-module','a0_l2_recoverable_writeback_slice_tb','--Mdir',o,*files,TB],'BEHAVIOR_BUILD');sim=run([o/'Va0_l2_recoverable_writeback_slice_tb'],'BEHAVIOR_SIM',60);ls=set(sim.splitlines());miss=[m for m in MARK if m not in ls]
  if miss:fail('MARKERS',str(miss))
  print(f'PROD_SEAM_P19_BEHAVIOR=PASS markers={len(MARK)}')
 print('PROD_SEAM_P19_P18_PREDECESSOR=PASS mode=frozen-canonical-receipt')
 h=run(['git','rev-parse','HEAD'],'HEAD',30).strip();br=run(['git','branch','--show-current'],'BRANCH',30).strip();run(['git','diff','--check'],'DIFFCHECK',30);df=run(['bash','-lc','git diff --binary|sha256sum|cut -d" " -f1'],'DIFFSHA',30).strip()
 if(h,br,df)!=(HEAD,BR,DIFF):fail('CONTAINMENT',f'{h} {br} {df}')
 for e,n in [('A0_STRICT_OUTER_LOG','OUTER'),('A0_STRICT_INNER_LOG','INNER')]:
  if os.environ.get(e) and leak(os.environ[e]):fail(n+'_LEAK',str(leak(os.environ[e])))
 print('PROD_SEAM_P19_OUTER_STRICT_LEAK=0');print('PROD_SEAM_P19_INNER_STRICT_LEAK=0');print('PROD_SEAM_P19_POST_CONTAINMENT=PASS');print('PROD_SEAM_P19_GATE=PASS')
if __name__=='__main__':main()
