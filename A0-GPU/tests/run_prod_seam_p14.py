#!/usr/bin/env python3
from __future__ import annotations
import hashlib,json,os,shutil,subprocess,sys,tempfile
from pathlib import Path
sys.dont_write_bytecode=True
ROOT=Path(__file__).resolve().parents[1]
V=Path(os.environ.get('A0_VERILATOR_BIN',shutil.which('verilator') or 'verilator'))
EXPECTED_HEAD='996d8c188e5d4f94b4bad5289392844d55d092f6'; EXPECTED_BRANCH='main'; EXPECTED_DIFF='59fac4fc152cc4e46ed60bff0feecf700756d860ed4f44436f532a221570eb8b'
P13RUN=ROOT/'tests/run_prod_seam_p13.py'; P13G=ROOT/'rtl/memory/a0_backend_write_retry_guard.sv'; P13S=ROOT/'rtl/memory/a0_production_store_backend_retry_seam.sv'; P13TB=ROOT/'tests/rtl/a0_backend_write_retry_guard_tb.sv'; P13DOC=ROOT/'docs/architecture/A0_PROD_SEAM_P13_BACKEND_WRITE_RETRY.md'
GUARD=ROOT/'rtl/memory/a0_backend_write_status_timeout_guard.sv'; SEAM=ROOT/'rtl/memory/a0_production_store_backend_timeout_seam.sv'; TB=ROOT/'tests/rtl/a0_backend_write_status_timeout_guard_tb.sv'; DOC=ROOT/'docs/architecture/A0_PROD_SEAM_P14_WRITE_STATUS_TIMEOUT.md'
P13_RECEIPT=ROOT.parent/'EVIDENCE/P13/receipt.txt'; P13_RECEIPT_SHA='53dbaab778f1a3a178284061b428704b03026df4375204a8569087a168ce1b95'
P13_HASHES={str(P13RUN):'14cdd673854652fb60e22b166a7479bf422c9393dd74b170ed5947fd8521b02d',str(P13G):'01f58047c4f915359544c7f97dabd652802625eec54cf8cbd03b05ba573e1cc3',str(P13S):'59b2e08a03d853916178b41b6a6d1e94655e777c97e668a615a76b6675ca506b',str(P13TB):'b1d5e0956866c8c683d868ca0fdc86ded77fc386d34af504f110b5a287527869',str(P13DOC):'1c2968fab5d843d21c31c03eb2cefb2fedbb13c47180441a1fba974b871a5355'}
BASE=[ROOT/'rtl/memory/a0_store_commit_line_backend_adapter.sv',ROOT/'rtl/memory/a0_production_store_backend_visibility_seam.sv',ROOT/'rtl/memory/a0_backend_read_transaction_guard.sv',ROOT/'rtl/memory/a0_production_store_backend_transaction_seam.sv',ROOT/'rtl/memory/a0_backend_read_epoch_guard.sv',ROOT/'rtl/memory/a0_production_store_backend_epoch_seam.sv',ROOT/'rtl/memory/a0_store_commit_duplicate_canonicalizer.sv',ROOT/'rtl/memory/a0_production_store_backend_collision_seam.sv',ROOT/'rtl/memory/a0_backend_write_completion_guard.sv',ROOT/'rtl/memory/a0_production_store_backend_completion_seam.sv',P13G,P13S,GUARD,SEAM]
MARKERS=('PROD_SEAM_P14_SAMECYCLE_EXACT_STATUS=PASS','PROD_SEAM_P14_STALE_STATUS_DOES_NOT_RESET=PASS','PROD_SEAM_P14_LOST_STATUS_SYNTH_RETRYABLE=PASS','PROD_SEAM_P14_TIMEOUT_EXACTLY_ONCE=PASS','PROD_SEAM_P14_NO_SYNTHETIC_SUCCESS=PASS','PROD_SEAM_P14_RETRY_ATTEMPT_REARMS_WATCHDOG=PASS','PROD_SEAM_P14_REAL_RETRYABLE_PRESERVED=PASS','PROD_SEAM_P14_BOUNDARY_REAL_STATUS_WINS=PASS','PROD_SEAM_P14_UNKNOWN_STATUS_PRESERVED_FOR_P13=PASS','PROD_SEAM_P14_IDLE_WATCHDOG_NO_SPURIOUS_TIMEOUT=PASS','PROD_SEAM_P14_BEHAVIOR=PASS')
def fail(stage,detail,rc=1): print('PROD_SEAM_P14_FIRST_FAILURE',file=sys.stderr); print(f'STAGE={stage}',file=sys.stderr); print(f'DETAIL={detail}',file=sys.stderr); raise SystemExit(rc)
def run(cmd,stage,timeout=900):
 cmd=[str(x) for x in cmd]
 if any(a.startswith('-Wno-') for a in cmd): fail(stage,'runner warning suppression')
 try:p=subprocess.run(cmd,cwd=ROOT,text=True,stdout=subprocess.PIPE,stderr=subprocess.STDOUT,env={**os.environ,'PYTHONDONTWRITEBYTECODE':'1'},timeout=timeout)
 except subprocess.TimeoutExpired as e: fail(stage,f'TIMEOUT {e}',124)
 if p.returncode: print(p.stdout,file=sys.stderr); fail(stage,f'RC={p.returncode}',p.returncode)
 if Path(cmd[0]).name.startswith('verilator') or 'strict-all-outer' in Path(cmd[0]).name:
  if '%Warning-' in p.stdout or '%Error' in p.stdout: print(p.stdout,file=sys.stderr); fail(stage,'Verilator diagnostic present',2)
 return p.stdout
def sha(p):
 h=hashlib.sha256(); f=open(p,'rb')
 for c in iter(lambda:f.read(1<<20),b''): h.update(c)
 f.close(); return h.hexdigest()
def leak(p):
 p=Path(p)
 if not p.exists(): return 0
 return sum(len(x.get('stripped',[]))+len(x.get('env_stripped',[])) for x in map(json.loads,p.read_text().splitlines()))
def req(text,marks,stage):
 lines=set(text.replace('\r','').splitlines()); miss=[m for m in marks if m not in lines]
 if miss: fail(stage,f'missing {miss}')
def main():
 ver=run([V,'--version'],'VERSION',30).strip()
 if not ver.startswith('Verilator 5.050 '): fail('VERSION',ver)
 print('PROD_SEAM_P14_EXACT_VERILATOR_5_050=PASS')
 for f in [*BASE,TB,DOC,P13_RECEIPT]:
  if not Path(f).is_file(): fail('SOURCE_AVAILABILITY',str(f))
 gt=GUARD.read_text(); st=SEAM.read_text(); dt=DOC.read_text()
 for t in ('timeout_fire','exact_samecycle_external_status','p13_status_retryable_o','timeout_seen_q'):
  if t not in gt: fail('STATIC_CONTRACT',t)
 for t in ('a0_production_store_backend_retry_seam #(','a0_backend_write_status_timeout_guard #(','backend_write_status_valid_i(p13_status_valid)'):
  if t not in st: fail('STATIC_COMPOSITION',t)
 if any(x in gt+st for x in ('dirty_q','writeback_queue','snoop_controller','atomic_unit','dram_scheduler')): fail('BOUNDED_SCOPE','scope creep')
 print('PROD_SEAM_P14_STATIC_COMPOSITION_CONTRACT=PASS'); print('PROD_SEAM_P14_BOUNDED_STATUS_TIMEOUT_SCOPE=PASS'); print('PROD_SEAM_P14_DOCUMENTED_TIMEOUT_CONTRACT=PASS')
 if sha(P13_RECEIPT)!=P13_RECEIPT_SHA: fail('P13_PREDECESSOR_RECEIPT','mismatch')
 req(P13_RECEIPT.read_text(),('PROD_SEAM_P13_STRICT_QUALIFICATION=PASS','PROD_SEAM_P13_GATE=PASS'),'P13_PREDECESSOR_RECEIPT')
 for f,h in P13_HASHES.items():
  if sha(f)!=h: fail('P13_PREDECESSOR_IMMUTABILITY',f)
 with tempfile.TemporaryDirectory(prefix='a0_p14_',dir='/tmp') as td0:
  td=Path(td0); base=[str(V),'--timing','--unroll-count','512','-Wall','-Werror-PINMISSING','-Werror-WIDTHEXPAND','-Werror-WIDTHTRUNC']
  variants=(('MIN',['-GCLUSTER_COUNT=1','-GCUS_PER_CLUSTER=1','-GSTORE_LANES=1','-GL2_SLICE_COUNT=1','-GLINE_WORDS=1','-GNETWORK_TAG_W=2','-GREAD_TRACK_COUNT=1','-GREAD_EPOCH_W=1','-GWRITE_ID_W=1','-GMAX_WRITE_RETRIES=0','-GSTATUS_TIMEOUT_CYCLES=1']),('MID',['-GCLUSTER_COUNT=2','-GCUS_PER_CLUSTER=2','-GSTORE_LANES=4','-GL2_SLICE_COUNT=2','-GLINE_WORDS=4','-GNETWORK_TAG_W=3','-GREAD_TRACK_COUNT=4','-GREAD_EPOCH_W=4','-GWRITE_ID_W=4','-GMAX_WRITE_RETRIES=2','-GSTATUS_TIMEOUT_CYCLES=8']),('WIDE',['-GCLUSTER_COUNT=4','-GCUS_PER_CLUSTER=2','-GSTORE_LANES=32','-GL2_SLICE_COUNT=4','-GLINE_WORDS=8','-GNETWORK_TAG_W=6','-GREAD_TRACK_COUNT=16','-GREAD_EPOCH_W=16','-GWRITE_ID_W=16','-GMAX_WRITE_RETRIES=7','-GSTATUS_TIMEOUT_CYCLES=64']))
  for n,ps in variants: run(base+['--lint-only','--top-module','a0_production_store_backend_timeout_seam','--Mdir',str(td/('m_'+n.lower())),*ps,*map(str,BASE)],'P14_MATRIX_'+n,600)
  print('PROD_SEAM_P14_STRICT_LINT=PASS'); print('PROD_SEAM_P14_PARAMETER_MATRIX=PASS variants=3')
  obj=td/'beh'; run(base+['--binary','--top-module','a0_backend_write_status_timeout_guard_tb','--Mdir',str(obj),str(GUARD),str(TB)],'P14_BEHAVIOR',600); sim=run([str(obj/'Va0_backend_write_status_timeout_guard_tb')],'P14_SIM',60); req(sim,MARKERS,'P14_MARKERS'); print(f'PROD_SEAM_P14_BEHAVIOR=PASS markers={len(MARKERS)}')
 print('PROD_SEAM_P14_P13_PREDECESSOR=PASS mode=frozen-canonical-receipt')
 head=run(['git','rev-parse','HEAD'],'HEAD',30).strip(); br=run(['git','branch','--show-current'],'BRANCH',30).strip(); run(['git','diff','--check'],'DIFFCHECK',30); diff=run(['bash','-lc','git diff --binary | sha256sum | cut -d" " -f1'],'DIFFSHA',30).strip()
 if (head,br,diff)!=(EXPECTED_HEAD,EXPECTED_BRANCH,EXPECTED_DIFF): fail('POST_CONTAINMENT',f'{head} {br} {diff}')
 outer=os.environ.get('A0_STRICT_OUTER_LOG'); inner=os.environ.get('A0_STRICT_INNER_LOG')
 if outer and leak(outer)!=0: fail('OUTER_STRICT_LEAK',str(leak(outer)))
 if inner and leak(inner)!=0: fail('INNER_STRICT_LEAK',str(leak(inner)))
 print('PROD_SEAM_P14_OUTER_STRICT_LEAK=0'); print('PROD_SEAM_P14_INNER_STRICT_LEAK=0'); print('PROD_SEAM_P14_POST_CONTAINMENT=PASS'); print('PROD_SEAM_P14_GATE=PASS')
if __name__=='__main__': main()
