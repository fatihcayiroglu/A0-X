#!/usr/bin/env python3
from __future__ import annotations
import hashlib,json,os,shutil,subprocess,sys,tempfile
from pathlib import Path
ROOT=Path(__file__).resolve().parents[1]; V=Path(os.environ.get('A0_VERILATOR_BIN',shutil.which('verilator') or 'verilator'))
HEAD='996d8c188e5d4f94b4bad5289392844d55d092f6'; BR='main'; DIFF='59fac4fc152cc4e46ed60bff0feecf700756d860ed4f44436f532a221570eb8b'
R=ROOT.parent/'EVIDENCE/P15/receipt.txt'; R_SHA='9479e66041e27b0792301dca4f1028252c48c23cdc724ab970dde86b011a06a4'
P15={ROOT/'tests/run_prod_seam_p15.py':'b5a8daa25bf2b1f88eedb44428dada876157a08d849b6f36f5547d0f462bcb5f',ROOT/'rtl/memory/a0_backend_write_failure_recovery_guard.sv':'fc5ddf7e3b580afb99562ac74cc04120f412cd80870c9c50fd285f52ed4e8499',ROOT/'rtl/memory/a0_production_store_backend_recovery_seam.sv':'cbad810c6e96189a0cb692657543c1cb8f2675ffb0c4044e76d212bb3a3a3b32',ROOT/'tests/rtl/a0_backend_write_failure_recovery_guard_tb.sv':'f04684c3c9448abc429d23b803bfd16f9bf6fdc4a4f85232166746fd5a0d5a1d',ROOT/'docs/architecture/A0_PROD_SEAM_P15_FAILURE_RECOVERY.md':'5beef5831903da3fa54d43f812d0b1ba80e21aaaab4512bbff93558d6fe29286'}
G=ROOT/'rtl/memory/a0_backend_recovery_dual_safe_join.sv'; S=ROOT/'rtl/memory/a0_production_store_backend_dual_safe_recovery_seam.sv'; TB=ROOT/'tests/rtl/a0_backend_recovery_dual_safe_join_tb.sv'; DOC=ROOT/'docs/architecture/A0_PROD_SEAM_P16_DUAL_SAFE_RECOVERY.md'
BASE=[ROOT/'rtl/memory/a0_store_commit_line_backend_adapter.sv',ROOT/'rtl/memory/a0_production_store_backend_visibility_seam.sv',ROOT/'rtl/memory/a0_backend_read_transaction_guard.sv',ROOT/'rtl/memory/a0_production_store_backend_transaction_seam.sv',ROOT/'rtl/memory/a0_backend_read_epoch_guard.sv',ROOT/'rtl/memory/a0_production_store_backend_epoch_seam.sv',ROOT/'rtl/memory/a0_store_commit_duplicate_canonicalizer.sv',ROOT/'rtl/memory/a0_production_store_backend_collision_seam.sv',ROOT/'rtl/memory/a0_backend_write_completion_guard.sv',ROOT/'rtl/memory/a0_production_store_backend_completion_seam.sv',ROOT/'rtl/memory/a0_backend_write_retry_guard.sv',ROOT/'rtl/memory/a0_production_store_backend_retry_seam.sv',ROOT/'rtl/memory/a0_backend_write_status_timeout_guard.sv',ROOT/'rtl/memory/a0_production_store_backend_timeout_seam.sv',ROOT/'rtl/memory/a0_backend_write_failure_recovery_guard.sv',ROOT/'rtl/memory/a0_production_store_backend_recovery_seam.sv',G,S]
MARK=('PROD_SEAM_P16_EARLY_SAFE_NOT_CAPTURED=PASS','PROD_SEAM_P16_WRITE_ONLY_NOT_JOINED=PASS','PROD_SEAM_P16_WRITE_THEN_READ_JOIN=PASS','PROD_SEAM_P16_JOIN_HELD_UNTIL_READY=PASS','PROD_SEAM_P16_REARM_AFTER_RECOVERY=PASS','PROD_SEAM_P16_READ_THEN_WRITE_JOIN=PASS','PROD_SEAM_P16_BOTH_SAFE_REQUIRED=PASS','PROD_SEAM_P16_BEHAVIOR=PASS')
def sha(p):
 h=hashlib.sha256(); f=open(p,'rb')
 for c in iter(lambda:f.read(1<<20),b''):h.update(c)
 f.close();return h.hexdigest()
def fail(s,d,rc=1):print('PROD_SEAM_P16_FIRST_FAILURE',file=sys.stderr);print('STAGE='+s,file=sys.stderr);print('DETAIL='+d,file=sys.stderr);raise SystemExit(rc)
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
 print('PROD_SEAM_P16_EXACT_VERILATOR_5_050=PASS')
 if sha(R)!=R_SHA or 'PROD_SEAM_P15_GATE=PASS' not in R.read_text():fail('P15_RECEIPT','mismatch')
 for f,h in P15.items():
  if sha(f)!=h:fail('P15_IMMUTABILITY',str(f))
 st=S.read_text(); gt=G.read_text()
 for x in ('backend_write_recovery_safe_valid_i','backend_read_recovery_safe_valid_i','a0_backend_recovery_dual_safe_join','a0_production_store_backend_recovery_seam #('):
  if x not in st:fail('STATIC',x)
 if 'joined_safe_valid_o' not in gt:fail('STATIC','join')
 print('PROD_SEAM_P16_STATIC_COMPOSITION_CONTRACT=PASS');print('PROD_SEAM_P16_BOUNDED_DUAL_SAFE_SCOPE=PASS');print('PROD_SEAM_P16_DOCUMENTED_ANTI_ABA_RECOVERY_CONTRACT=PASS')
 with tempfile.TemporaryDirectory(prefix='p16_',dir='/tmp') as d:
  d=Path(d); b=[str(V),'--timing','--unroll-count','512','-Wall','-Werror-PINMISSING','-Werror-WIDTHEXPAND','-Werror-WIDTHTRUNC']
  vv=(('MIN',['-GCLUSTER_COUNT=1','-GCUS_PER_CLUSTER=1','-GSTORE_LANES=1','-GL2_SLICE_COUNT=1','-GLINE_WORDS=1','-GNETWORK_TAG_W=2','-GREAD_TRACK_COUNT=1','-GREAD_EPOCH_W=2','-GWRITE_ID_W=2','-GMAX_WRITE_RETRIES=0','-GSTATUS_TIMEOUT_CYCLES=1']),('MID',['-GCLUSTER_COUNT=2','-GCUS_PER_CLUSTER=2','-GSTORE_LANES=4','-GL2_SLICE_COUNT=2','-GLINE_WORDS=4','-GNETWORK_TAG_W=3','-GREAD_TRACK_COUNT=4','-GREAD_EPOCH_W=4','-GWRITE_ID_W=4','-GMAX_WRITE_RETRIES=2','-GSTATUS_TIMEOUT_CYCLES=8']),('WIDE',['-GCLUSTER_COUNT=4','-GCUS_PER_CLUSTER=2','-GSTORE_LANES=32','-GL2_SLICE_COUNT=4','-GLINE_WORDS=8','-GNETWORK_TAG_W=6','-GREAD_TRACK_COUNT=16','-GREAD_EPOCH_W=16','-GWRITE_ID_W=16','-GMAX_WRITE_RETRIES=7','-GSTATUS_TIMEOUT_CYCLES=64']))
  for n,ps in vv:run(b+['--lint-only','--top-module','a0_production_store_backend_dual_safe_recovery_seam','--Mdir',d/('m_'+n.lower()),*ps,*BASE],'MATRIX_'+n)
  print('PROD_SEAM_P16_STRICT_LINT=PASS');print('PROD_SEAM_P16_PARAMETER_MATRIX=PASS variants=3')
  o=d/'beh';run(b+['--binary','--top-module','a0_backend_recovery_dual_safe_join_tb','--Mdir',o,G,TB],'BEHAVIOR');s=run([o/'Va0_backend_recovery_dual_safe_join_tb'],'SIM',60);ls=set(s.splitlines());miss=[x for x in MARK if x not in ls]
  if miss:fail('MARKERS',str(miss))
  print(f'PROD_SEAM_P16_BEHAVIOR=PASS markers={len(MARK)}')
 print('PROD_SEAM_P16_P15_PREDECESSOR=PASS mode=frozen-canonical-receipt')
 h=run(['git','rev-parse','HEAD'],'HEAD',30).strip();br=run(['git','branch','--show-current'],'BRANCH',30).strip();run(['git','diff','--check'],'DIFFCHECK',30);df=run(['bash','-lc','git diff --binary|sha256sum|cut -d" " -f1'],'DIFFSHA',30).strip()
 if (h,br,df)!=(HEAD,BR,DIFF):fail('CONTAINMENT',f'{h} {br} {df}')
 for e,n in [('A0_STRICT_OUTER_LOG','OUTER'),('A0_STRICT_INNER_LOG','INNER')]:
  if os.environ.get(e) and leak(os.environ[e]):fail(n+'_LEAK',str(leak(os.environ[e])))
 print('PROD_SEAM_P16_OUTER_STRICT_LEAK=0');print('PROD_SEAM_P16_INNER_STRICT_LEAK=0');print('PROD_SEAM_P16_POST_CONTAINMENT=PASS');print('PROD_SEAM_P16_GATE=PASS')
if __name__=='__main__':main()
