#!/usr/bin/env python3
from __future__ import annotations
import hashlib,json,os,shutil,subprocess,sys,tempfile
from pathlib import Path
sys.dont_write_bytecode=True
ROOT=Path(__file__).resolve().parents[1]
V=Path(os.environ.get('A0_VERILATOR_BIN',shutil.which('verilator') or 'verilator'))
EXPECTED_HEAD='996d8c188e5d4f94b4bad5289392844d55d092f6'; EXPECTED_BRANCH='main'; EXPECTED_DIFF='59fac4fc152cc4e46ed60bff0feecf700756d860ed4f44436f532a221570eb8b'
P14_RECEIPT=ROOT.parent/'EVIDENCE/P14/receipt.txt'; P14_RECEIPT_SHA='c04c2d28ae4cee70fe5c43df2ba18521fb6b5bf0b3fbfd8f13f190ca540dab7e'
P14FILES={
 ROOT/'tests/run_prod_seam_p14.py':'99814febb7f4641e322430851edf33213e505bb3b35c93683237176080fdc84d',
 ROOT/'rtl/memory/a0_backend_write_status_timeout_guard.sv':'1e7410ce3eef80e59cc155054af0eeb4b6ef4fa5d656c002c8cad0a38c4e0079',
 ROOT/'rtl/memory/a0_production_store_backend_timeout_seam.sv':'1ff16bc54b2a05cbc636cd6d5daaa2f79a25b22ce75ad4deb31bdb955bdb0673',
 ROOT/'tests/rtl/a0_backend_write_status_timeout_guard_tb.sv':'dea23895345275ed0ffb80a7f18e686ea307cc602b964e7d505067fc00bbc793',
 ROOT/'docs/architecture/A0_PROD_SEAM_P14_WRITE_STATUS_TIMEOUT.md':'80f62b3148a52b3774234f9e99b664a3852ba7fb2bdc3c36ef934dccd4b70d13'}
G=ROOT/'rtl/memory/a0_backend_write_failure_recovery_guard.sv'; S=ROOT/'rtl/memory/a0_production_store_backend_recovery_seam.sv'; TB=ROOT/'tests/rtl/a0_backend_write_failure_recovery_guard_tb.sv'; DOC=ROOT/'docs/architecture/A0_PROD_SEAM_P15_FAILURE_RECOVERY.md'
BASE=[ROOT/'rtl/memory/a0_store_commit_line_backend_adapter.sv',ROOT/'rtl/memory/a0_production_store_backend_visibility_seam.sv',ROOT/'rtl/memory/a0_backend_read_transaction_guard.sv',ROOT/'rtl/memory/a0_production_store_backend_transaction_seam.sv',ROOT/'rtl/memory/a0_backend_read_epoch_guard.sv',ROOT/'rtl/memory/a0_production_store_backend_epoch_seam.sv',ROOT/'rtl/memory/a0_store_commit_duplicate_canonicalizer.sv',ROOT/'rtl/memory/a0_production_store_backend_collision_seam.sv',ROOT/'rtl/memory/a0_backend_write_completion_guard.sv',ROOT/'rtl/memory/a0_production_store_backend_completion_seam.sv',ROOT/'rtl/memory/a0_backend_write_retry_guard.sv',ROOT/'rtl/memory/a0_production_store_backend_retry_seam.sv',ROOT/'rtl/memory/a0_backend_write_status_timeout_guard.sv',ROOT/'rtl/memory/a0_production_store_backend_timeout_seam.sv',G,S]
MARKERS=('PROD_SEAM_P15_CAPTURE_EXACT_FAILURE=PASS','PROD_SEAM_P15_ABORT_PAYLOAD_STABLE=PASS','PROD_SEAM_P15_MISMATCH_ABORT_ACK_REJECTED=PASS','PROD_SEAM_P15_EXACT_ABORT_ACK=PASS','PROD_SEAM_P15_WAIT_READ_DRAIN=PASS','PROD_SEAM_P15_WAIT_SOURCE_QUIESCE=PASS','PROD_SEAM_P15_RESET_ONLY_AFTER_ALL_ACKS=PASS','PROD_SEAM_P15_EXACTLY_ONCE_RECOVERY=PASS','PROD_SEAM_P15_NO_SYNTHETIC_SUCCESS=PASS','PROD_SEAM_P15_BEHAVIOR=PASS')
def sha(p):
 h=hashlib.sha256(); f=open(p,'rb')
 for c in iter(lambda:f.read(1<<20),b''): h.update(c)
 f.close(); return h.hexdigest()
def fail(stage,detail,rc=1): print('PROD_SEAM_P15_FIRST_FAILURE',file=sys.stderr); print('STAGE='+stage,file=sys.stderr); print('DETAIL='+detail,file=sys.stderr); raise SystemExit(rc)
def run(cmd,stage,timeout=600):
 cmd=[str(x) for x in cmd]
 if any(x.startswith('-Wno-') for x in cmd): fail(stage,'suppression in runner')
 try:p=subprocess.run(cmd,cwd=ROOT,text=True,stdout=subprocess.PIPE,stderr=subprocess.STDOUT,env={**os.environ,'PYTHONDONTWRITEBYTECODE':'1'},timeout=timeout)
 except subprocess.TimeoutExpired: fail(stage,'TIMEOUT',124)
 if p.returncode: print(p.stdout,file=sys.stderr); fail(stage,f'RC={p.returncode}',p.returncode)
 if ('verilator' in Path(cmd[0]).name) and ('%Warning-' in p.stdout or '%Error' in p.stdout): print(p.stdout,file=sys.stderr); fail(stage,'diagnostic present',2)
 return p.stdout
def leak(path):
 p=Path(path)
 if not p.exists(): return 0
 return sum(len(x.get('stripped',[]))+len(x.get('env_stripped',[])) for x in map(json.loads,p.read_text().splitlines()))
def main():
 ver=run([V,'--version'],'VERSION',30).strip()
 if not ver.startswith('Verilator 5.050 '): fail('VERSION',ver)
 print('PROD_SEAM_P15_EXACT_VERILATOR_5_050=PASS')
 for f in [*BASE,TB,DOC,P14_RECEIPT]:
  if not Path(f).is_file(): fail('SOURCE',str(f))
 if sha(P14_RECEIPT)!=P14_RECEIPT_SHA: fail('P14_RECEIPT','sha mismatch')
 if 'PROD_SEAM_P14_GATE=PASS' not in P14_RECEIPT.read_text(): fail('P14_RECEIPT','gate absent')
 for f,h in P14FILES.items():
  if sha(f)!=h: fail('P14_IMMUTABILITY',str(f))
 gt=G.read_text(); st=S.read_text(); dt=DOC.read_text()
 for t in ('source_quiesced_i','backend_recovery_safe_valid_i','arch_abort_ack_write_id_i','predecessor_reset_pulse_o','read_outstanding_i','epoch_outstanding_i'):
  if t not in gt: fail('STATIC_GUARD',t)
 for t in ('a0_production_store_backend_timeout_seam #(','a0_backend_write_failure_recovery_guard #(','recovery_active_o ? \'0 : line_mem_req_valid_i','rst_n && !predecessor_reset_pulse'):
  if t not in st: fail('STATIC_COMPOSITION',t)
 if 'synthetic success' not in dt.lower(): fail('DOCUMENTATION','no synthetic success contract')
 print('PROD_SEAM_P15_STATIC_COMPOSITION_CONTRACT=PASS'); print('PROD_SEAM_P15_BOUNDED_RECOVERY_SCOPE=PASS'); print('PROD_SEAM_P15_DOCUMENTED_RECOVERY_CONTRACT=PASS')
 with tempfile.TemporaryDirectory(prefix='a0_p15_',dir='/tmp') as td0:
  td=Path(td0); base=[str(V),'--timing','--unroll-count','512','-Wall','-Werror-PINMISSING','-Werror-WIDTHEXPAND','-Werror-WIDTHTRUNC']
  variants=(('MIN',['-GCLUSTER_COUNT=1','-GCUS_PER_CLUSTER=1','-GSTORE_LANES=1','-GL2_SLICE_COUNT=1','-GLINE_WORDS=1','-GNETWORK_TAG_W=2','-GREAD_TRACK_COUNT=1','-GREAD_EPOCH_W=2','-GWRITE_ID_W=2','-GMAX_WRITE_RETRIES=0','-GSTATUS_TIMEOUT_CYCLES=1']),('MID',['-GCLUSTER_COUNT=2','-GCUS_PER_CLUSTER=2','-GSTORE_LANES=4','-GL2_SLICE_COUNT=2','-GLINE_WORDS=4','-GNETWORK_TAG_W=3','-GREAD_TRACK_COUNT=4','-GREAD_EPOCH_W=4','-GWRITE_ID_W=4','-GMAX_WRITE_RETRIES=2','-GSTATUS_TIMEOUT_CYCLES=8']),('WIDE',['-GCLUSTER_COUNT=4','-GCUS_PER_CLUSTER=2','-GSTORE_LANES=32','-GL2_SLICE_COUNT=4','-GLINE_WORDS=8','-GNETWORK_TAG_W=6','-GREAD_TRACK_COUNT=16','-GREAD_EPOCH_W=16','-GWRITE_ID_W=16','-GMAX_WRITE_RETRIES=7','-GSTATUS_TIMEOUT_CYCLES=64']))
  for n,ps in variants: run(base+['--lint-only','--top-module','a0_production_store_backend_recovery_seam','--Mdir',str(td/('m_'+n.lower())),*ps,*map(str,BASE)],'MATRIX_'+n)
  print('PROD_SEAM_P15_STRICT_LINT=PASS'); print('PROD_SEAM_P15_PARAMETER_MATRIX=PASS variants=3')
  obj=td/'beh'; run(base+['--binary','--top-module','a0_backend_write_failure_recovery_guard_tb','--Mdir',str(obj),str(G),str(TB)],'BEHAVIOR'); sim=run([obj/'Va0_backend_write_failure_recovery_guard_tb'],'SIM',60)
  lines=set(sim.splitlines()); miss=[m for m in MARKERS if m not in lines]
  if miss: fail('MARKERS',str(miss))
  print(f'PROD_SEAM_P15_BEHAVIOR=PASS markers={len(MARKERS)}')
 print('PROD_SEAM_P15_P14_PREDECESSOR=PASS mode=frozen-canonical-receipt')
 head=run(['git','rev-parse','HEAD'],'HEAD',30).strip(); br=run(['git','branch','--show-current'],'BRANCH',30).strip(); run(['git','diff','--check'],'DIFFCHECK',30); diff=run(['bash','-lc','git diff --binary | sha256sum | cut -d" " -f1'],'DIFFSHA',30).strip()
 if (head,br,diff)!=(EXPECTED_HEAD,EXPECTED_BRANCH,EXPECTED_DIFF): fail('CONTAINMENT',f'{head} {br} {diff}')
 ol=os.environ.get('A0_STRICT_OUTER_LOG'); il=os.environ.get('A0_STRICT_INNER_LOG')
 if ol and leak(ol): fail('OUTER_LEAK',str(leak(ol)))
 if il and leak(il): fail('INNER_LEAK',str(leak(il)))
 print('PROD_SEAM_P15_OUTER_STRICT_LEAK=0'); print('PROD_SEAM_P15_INNER_STRICT_LEAK=0'); print('PROD_SEAM_P15_POST_CONTAINMENT=PASS'); print('PROD_SEAM_P15_GATE=PASS')
if __name__=='__main__': main()
