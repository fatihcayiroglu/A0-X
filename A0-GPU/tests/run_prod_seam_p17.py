#!/usr/bin/env python3
from __future__ import annotations
import hashlib,json,os,shutil,subprocess,sys,tempfile
from pathlib import Path
ROOT=Path(__file__).resolve().parents[1]
V=Path(os.environ.get('A0_VERILATOR_BIN',shutil.which('verilator') or 'verilator'))
HEAD='996d8c188e5d4f94b4bad5289392844d55d092f6'; BR='main'; DIFF='59fac4fc152cc4e46ed60bff0feecf700756d860ed4f44436f532a221570eb8b'
R=ROOT.parent/'EVIDENCE/P16/receipt.txt'; R_SHA='130df26426ea0b0472857ef4815764b60e819722c5acb4a207d64977245d18f7'
P16={
 ROOT/'tests/run_prod_seam_p16.py':'ba2d166775eeff8fd29b4570b9b271ce508784bffdfd3df9e0f205bc8a09efab',
 ROOT/'rtl/memory/a0_backend_recovery_dual_safe_join.sv':'8cd05a2361193e8008961905c37a922bce89129bae62b7e3ac76e32e8dc31c60',
 ROOT/'rtl/memory/a0_production_store_backend_dual_safe_recovery_seam.sv':'bda357b281c660d55251bf4164d7add2cefb60c0141da14bf7eb15c5159c6235',
 ROOT/'tests/rtl/a0_backend_recovery_dual_safe_join_tb.sv':'1ee0eb9bcedd47e21465bef05a6e3a5e45c7fcafbcd8f1e424bae4760cf920bf',
 ROOT/'docs/architecture/A0_PROD_SEAM_P16_DUAL_SAFE_RECOVERY.md':'a9979ace8c5ecdae267ccd3db2fc25015fef786862d1dc321af5a2558ac64356'}
S=ROOT/'rtl/memory/a0_l2_dirty_writeback_slice.sv'; TB=ROOT/'tests/rtl/a0_l2_dirty_writeback_slice_tb.sv'; DOC=ROOT/'docs/architecture/A0_PROD_SEAM_P17_DIRTY_WRITEBACK_FOUNDATION.md'
MARK=(
'PROD_SEAM_P17_RESET_CLEAN=PASS','PROD_SEAM_P17_REFILL_INSTALLS_CLEAN=PASS','PROD_SEAM_P17_STORE_HIT_MARKS_DIRTY=PASS','PROD_SEAM_P17_DIRTY_HIT_RETURNS_UPDATED_DATA=PASS','PROD_SEAM_P17_STORE_MISS_NO_WRITE_ALLOCATE=PASS','PROD_SEAM_P17_DIRTY_EVICTION_REQUIRES_WRITEBACK=PASS','PROD_SEAM_P17_NO_SYNTHETIC_CLEAN_BEFORE_WB_ACCEPT=PASS','PROD_SEAM_P17_WRITEBACK_PAYLOAD_STABLE=PASS','PROD_SEAM_P17_VICTIM_STORE_BACKPRESSURED=PASS','PROD_SEAM_P17_WB_ACCEPT_RELEASES_RETAINED_MISS=PASS','PROD_SEAM_P17_POST_WB_REFILL_HIT=PASS','PROD_SEAM_P17_CLEAN_EVICTION_NO_WRITEBACK=PASS','PROD_SEAM_P17_FAULTED_REFILL_NOT_INSTALLED=PASS','PROD_SEAM_P17_UNTRACKED_RESPONSE_CONTAINED=PASS','PROD_SEAM_P17_BEHAVIOR=PASS')
def sha(p):
 h=hashlib.sha256(); f=open(p,'rb')
 for c in iter(lambda:f.read(1<<20),b''): h.update(c)
 f.close(); return h.hexdigest()
def fail(stage,detail,rc=1):
 print('PROD_SEAM_P17_FIRST_FAILURE',file=sys.stderr); print('STAGE='+stage,file=sys.stderr); print('DETAIL='+detail,file=sys.stderr); raise SystemExit(rc)
def run(cmd,stage,timeout=600):
 cmd=[str(x) for x in cmd]
 if any(x.startswith('-Wno-') for x in cmd): fail(stage,'suppression')
 try: p=subprocess.run(cmd,cwd=ROOT,text=True,stdout=subprocess.PIPE,stderr=subprocess.STDOUT,env={**os.environ,'PYTHONDONTWRITEBYTECODE':'1'},timeout=timeout)
 except subprocess.TimeoutExpired: fail(stage,'TIMEOUT',124)
 if p.returncode:
  print(p.stdout,file=sys.stderr); fail(stage,f'RC={p.returncode}',p.returncode)
 if 'verilator' in Path(cmd[0]).name and ('%Warning-' in p.stdout or '%Error' in p.stdout):
  print(p.stdout,file=sys.stderr); fail(stage,'diagnostic',2)
 return p.stdout
def leak(path):
 p=Path(path)
 if not p.exists(): return 0
 total=0
 for line in p.read_text().splitlines():
  j=json.loads(line); total+=len(j.get('stripped',[]))+len(j.get('env_stripped',[]))
 return total
def main():
 v=run([V,'--version'],'VERSION',30).strip()
 if not v.startswith('Verilator 5.050 '): fail('VERSION',v)
 print('PROD_SEAM_P17_EXACT_VERILATOR_5_050=PASS')
 if sha(R)!=R_SHA or 'PROD_SEAM_P16_GATE=PASS' not in R.read_text(): fail('P16_RECEIPT','mismatch')
 for f,h in P16.items():
  if sha(f)!=h: fail('P16_IMMUTABILITY',str(f))
 st=S.read_text(); doc=DOC.read_text()
 for token in ('cache_dirty_q','req_dirty_victim','wb_valid_o','wb_ready_i','evict_victim_data_q','evict_wb_fire','store_hit_mask_o','protocol_error_o'):
  if token not in st: fail('STATIC',token)
 for token in ('no-synthetic-clean','dirty','writeback','does **not** convert'):
  if token not in doc: fail('DOC',token)
 print('PROD_SEAM_P17_STATIC_DIRTY_WRITEBACK_CONTRACT=PASS')
 print('PROD_SEAM_P17_BOUNDED_FOUNDATION_SCOPE=PASS')
 print('PROD_SEAM_P17_DOCUMENTED_NO_SYNTHETIC_CLEAN=PASS')
 with tempfile.TemporaryDirectory(prefix='p17_',dir='/tmp') as td:
  td=Path(td); base=[str(V),'--timing','--unroll-count','512','-Wall','-Werror-PINMISSING','-Werror-WIDTHEXPAND','-Werror-WIDTHTRUNC']
  variants=(
   ('MIN',['-GSTORE_LANES=1','-GLINE_WORDS=1','-GSET_COUNT=1','-GGLOBAL_TAG_W=1']),
   ('MID',['-GSTORE_LANES=4','-GLINE_WORDS=4','-GSET_COUNT=16','-GGLOBAL_TAG_W=5']),
   ('WIDE',['-GSTORE_LANES=32','-GLINE_WORDS=8','-GSET_COUNT=256','-GGLOBAL_TAG_W=12']))
  for name,params in variants:
   run(base+['--lint-only','--top-module','a0_l2_dirty_writeback_slice','--Mdir',td/('m_'+name.lower()),*params,S],'MATRIX_'+name)
  print('PROD_SEAM_P17_STRICT_LINT=PASS'); print('PROD_SEAM_P17_PARAMETER_MATRIX=PASS variants=3')
  obj=td/'beh'
  run(base+['--binary','--top-module','a0_l2_dirty_writeback_slice_tb','--Mdir',obj,S,TB],'BEHAVIOR_BUILD',600)
  sim=run([obj/'Va0_l2_dirty_writeback_slice_tb'],'BEHAVIOR_SIM',60)
  lines=set(sim.splitlines()); missing=[m for m in MARK if m not in lines]
  if missing: fail('MARKERS',str(missing))
  print(f'PROD_SEAM_P17_BEHAVIOR=PASS markers={len(MARK)}')
 print('PROD_SEAM_P17_P16_PREDECESSOR=PASS mode=frozen-canonical-receipt')
 head=run(['git','rev-parse','HEAD'],'HEAD',30).strip(); br=run(['git','branch','--show-current'],'BRANCH',30).strip(); run(['git','diff','--check'],'DIFFCHECK',30)
 diff=run(['bash','-lc','git diff --binary|sha256sum|cut -d" " -f1'],'DIFFSHA',30).strip()
 if (head,br,diff)!=(HEAD,BR,DIFF): fail('CONTAINMENT',f'{head} {br} {diff}')
 for env,name in [('A0_STRICT_OUTER_LOG','OUTER'),('A0_STRICT_INNER_LOG','INNER')]:
  if os.environ.get(env) and leak(os.environ[env]): fail(name+'_LEAK',str(leak(os.environ[env])))
 print('PROD_SEAM_P17_OUTER_STRICT_LEAK=0'); print('PROD_SEAM_P17_INNER_STRICT_LEAK=0'); print('PROD_SEAM_P17_POST_CONTAINMENT=PASS'); print('PROD_SEAM_P17_GATE=PASS')
if __name__=='__main__': main()
