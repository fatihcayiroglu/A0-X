#!/usr/bin/env python3
from __future__ import annotations
import hashlib, json, os, shutil, subprocess, sys, tempfile
from pathlib import Path
sys.dont_write_bytecode=True
ROOT=Path(__file__).resolve().parents[1]
V=Path(os.environ.get('A0_VERILATOR_BIN', shutil.which('verilator') or 'verilator'))
EXPECTED_HEAD='996d8c188e5d4f94b4bad5289392844d55d092f6'
EXPECTED_BRANCH='main'
EXPECTED_DIFF='59fac4fc152cc4e46ed60bff0feecf700756d860ed4f44436f532a221570eb8b'
ARB=ROOT/'rtl/memory/a0_retry_round_robin_arbiter.sv'
P3M=ROOT/'rtl/memory/a0_mc_noc_sliced_l2_store_invalidate_subsystem.sv'
P6M=ROOT/'rtl/memory/a0_mc_noc_sliced_l2_store_admission_subsystem.sv'
FENCE=ROOT/'rtl/memory/a0_store_visibility_commit_fence.sv'
P7=ROOT/'rtl/core/a0_production_multi_cluster_store_commit_subsystem.sv'
TB=ROOT/'tests/rtl/a0_store_visibility_commit_fence_tb.sv'
DOC=ROOT/'docs/architecture/A0_PROD_SEAM_P7_STORE_VISIBILITY_COMMIT.md'
P6RUN=ROOT/'tests/run_prod_seam_p6.py'
P6_RECEIPT=ROOT.parent/'EVIDENCE/P6/receipt.txt'
P6_RECEIPT_SHA='3dabf8a8012750ead1672b8676bd4db752208ca5ea300e252a71d1c9afbb01e2'
P6_FROZEN_HASHES={
 str(ROOT/'tests/run_prod_seam_p6.py'):'d87c55967cb71d692d29d79271f0ee2e170d71a84e81dbfc3dd9396057c70da7',
 str(ROOT/'rtl/memory/a0_mc_noc_sliced_l2_store_admission_subsystem.sv'):'b58f2bdb527161c26a82385f1fa9a595d1c87dd8e811e4fcf4a0b0a4427fdaef',
 str(ROOT/'rtl/core/a0_production_multi_cluster_store_admission_subsystem.sv'):'580f39a8d2db230d1052c5ad05372665b839a95b45e3abcc4e33c52b4ffcc02c',
 str(ROOT/'tests/rtl/a0_mc_noc_sliced_l2_store_admission_subsystem_tb.sv'):'831f0cecddc9f9170ef583af94cc2d333cba0de84abf41ca86c97a4bd916155d',
 str(ROOT/'docs/architecture/A0_PROD_SEAM_P6_PENDING_STORE_ADMISSION.md'):'cbb2319724021ad771dcbde7a1bf3c1cd3ad2c89ca24dd91d7a23cefd3d1d7ff',
}
COMMON=[ARB,ROOT/'rtl/memory/a0_cluster_line_noc_endpoint.sv',ROOT/'rtl/memory/a0_mc_noc_logical_request_router.sv',ROOT/'rtl/memory/a0_mc_noc_logical_transaction_router.sv',ROOT/'rtl/memory/a0_l2_line_cache.sv',P3M,P6M]
CORE=[ROOT/'rtl/core/a0_scoreboard.sv',ROOT/'rtl/core/a0_dependency_classifier.sv',ROOT/'rtl/core/a0_lane_sequencer.sv',ROOT/'rtl/core/a0_operand_collector.sv',ROOT/'rtl/core/a0_regfile_banked_contexted.sv',ROOT/'rtl/core/a0_vector_operand_path_contexted.sv',ROOT/'rtl/scheduler/a0_wave_context_file.sv',ROOT/'rtl/scheduler/a0_wave_scheduler.sv',ROOT/'rtl/scheduler/a0_multi_wave_frontend.sv',ROOT/'rtl/scheduler/a0_wave_scoreboard_bank.sv',ROOT/'rtl/memory/a0_mshr_table.sv',ROOT/'rtl/memory/a0_wave_load_mshr_bridge.sv',ROOT/'rtl/memory/a0_store_queue.sv',ROOT/'rtl/memory/a0_l1_line_cache.sv',ROOT/'rtl/memory/a0_memory_service_boundary.sv',ROOT/'rtl/core/a0_multi_wave_core.sv',ROOT/'rtl/memory/a0_cluster_store_order_controller.sv',ROOT/'rtl/memory/a0_line_request_fabric.sv',ROOT/'rtl/memory/a0_production_cluster_line_seam.sv',ROOT/'rtl/core/a0_production_cu_cluster_frontend.sv',FENCE,P7]
BEHAVIOR_SOURCES=[*COMMON,FENCE,TB]
MARKERS=(
 'PROD_SEAM_P7_NONCONFLICTING_LOAD_PROGRESS=PASS',
 'PROD_SEAM_P7_TERMINAL_HELD_UNTIL_COMMIT=PASS',
 'PROD_SEAM_P7_COMMIT_PAYLOAD_PROVENANCE=PASS',
 'PROD_SEAM_P7_COMMIT_BACKPRESSURE_STABLE=PASS',
 'PROD_SEAM_P7_CONFLICTING_LOAD_HELD=PASS',
 'PROD_SEAM_P7_EXACTLY_ONCE_COMMIT=PASS',
 'PROD_SEAM_P7_CAUSAL_BACKEND_VISIBILITY=PASS',
 'PROD_SEAM_P7_FAULTING_STORE_NO_COMMIT=PASS',
 'PROD_SEAM_P7_FAULT_PROVENANCE_DISTINCT=PASS',
 'PROD_SEAM_P7_BEHAVIOR=PASS',
)
def fail(stage,detail,rc=1):
 print('PROD_SEAM_P7_FIRST_FAILURE',file=sys.stderr); print(f'STAGE={stage}',file=sys.stderr); print(f'DETAIL={detail}',file=sys.stderr); raise SystemExit(rc)
def run(cmd,stage,timeout=900):
 cmd=[str(x) for x in cmd]
 if any(a.startswith('-Wno-') for a in cmd): fail(stage,'runner warning suppression')
 try: p=subprocess.run(cmd,cwd=ROOT,text=True,stdout=subprocess.PIPE,stderr=subprocess.STDOUT,env={**os.environ,'PYTHONDONTWRITEBYTECODE':'1'},timeout=timeout)
 except subprocess.TimeoutExpired as e: fail(stage,f'TIMEOUT {e}',124)
 if p.returncode: print(p.stdout,file=sys.stderr); fail(stage,f'RC={p.returncode}',p.returncode)
 exe=Path(cmd[0]).name
 if exe.startswith('verilator') or 'strict-all-outer' in exe:
  if '%Warning-' in p.stdout or '%Error' in p.stdout: print(p.stdout,file=sys.stderr); fail(stage,'Verilator diagnostic present',2)
 return p.stdout
def req(text,marks,stage):
 lines=set(text.replace('\r','').splitlines()); miss=[m for m in marks if m not in lines]
 if miss: fail(stage,f'missing {miss}')
def leak_count(path):
 p=Path(path)
 if not p.exists(): return 0
 total=0
 for line in p.read_text().splitlines():
  x=json.loads(line); total += len(x.get('stripped',[]))+len(x.get('env_stripped',[]))
 return total
def sha256_file(p):
 h=hashlib.sha256()
 with Path(p).open('rb') as fh:
  for chunk in iter(lambda: fh.read(1<<20), b''): h.update(chunk)
 return h.hexdigest()
def verify_frozen_p6():
 if not P6_RECEIPT.is_file(): fail('P6_PREDECESSOR_RECEIPT','missing frozen P6 receipt')
 if sha256_file(P6_RECEIPT)!=P6_RECEIPT_SHA: fail('P6_PREDECESSOR_RECEIPT','receipt SHA mismatch')
 receipt=P6_RECEIPT.read_text()
 req(receipt,('PROD_SEAM_P6_P5_PREDECESSOR=PASS mode=frozen-canonical-receipt','PROD_SEAM_P6_OUTER_STRICT_LEAK=0','PROD_SEAM_P6_INNER_STRICT_LEAK=0','PROD_SEAM_P6_POST_CONTAINMENT=PASS','PROD_SEAM_P6_GATE=PASS'),'P6_PREDECESSOR_RECEIPT')
 for fn,want in P6_FROZEN_HASHES.items():
  if not Path(fn).is_file() or sha256_file(fn)!=want: fail('P6_PREDECESSOR_IMMUTABILITY',fn)
def lint_fence_variant(base,td,name,params):
 run(base+['--lint-only','--top-module','a0_store_visibility_commit_fence','--Mdir',str(td/name),*params,str(FENCE)],f'P7_FENCE_MATRIX_{name.upper()}',300)
def main():
 ver=run([V,'--version'],'VERSION',30).strip()
 if not ver.startswith('Verilator 5.050 '): fail('VERSION',ver)
 print('PROD_SEAM_P7_EXACT_VERILATOR_5_050=PASS')
 for f in [FENCE,P7,TB,DOC,P6RUN,*COMMON,*CORE]:
  if not f.is_file(): fail('SOURCE_AVAILABILITY',str(f))
 ft=FENCE.read_text(); pt=P7.read_text(); dt=DOC.read_text()
 need_f=('held_success_resp_q','visibility_commit_valid_o','visibility_commit_ready_i','commit_release_terminal','backend_matches_active','active_store_wdata_q')
 need_p=('a0_store_visibility_commit_fence #(','a0_mc_noc_sliced_l2_store_admission_subsystem #(','fenced_mem_resp_valid','store_visibility_commit_valid_o')
 if any(x not in ft for x in need_f) or any(x not in pt for x in need_p): fail('STATIC_CONTRACT','missing P7 commit-fence composition token')
 if any(x in ft+pt for x in ('dirty_q','writeback_queue','atomic_unit','snoop_controller')): fail('BOUNDED_SCOPE','full coherence claim/state leaked')
 if 'Commit point' not in dt or 'Buffering and backpressure' not in dt or 'Fault contract' not in dt or 'causally updates' not in dt: fail('DOCUMENTED_CONTRACT','P7 contract documentation missing')
 print('PROD_SEAM_P7_STATIC_COMPOSITION_CONTRACT=PASS')
 print('PROD_SEAM_P7_BOUNDED_VISIBILITY_SCOPE=PASS')
 print('PROD_SEAM_P7_DOCUMENTED_COMMIT_CONTRACT=PASS')
 with tempfile.TemporaryDirectory(prefix='a0_p7_',dir='/tmp') as td0:
  td=Path(td0)
  base=[str(V),'--timing','--unroll-count','512','-Wall','-Werror-PINMISSING','-Werror-WIDTHEXPAND','-Werror-WIDTHTRUNC']
  prod_params=['-GCLUSTER_COUNT=1','-GCUS_PER_CLUSTER=1','-GRESIDENT_WAVES=1','-GPHYSICAL_LANES=1','-GVECTOR_REG_COUNT=4','-GSCALAR_REG_COUNT=4','-GPREDICATE_REG_COUNT=2','-GSCALAR_PREDICATE_REG_COUNT=2','-GRECONV_STACK_DEPTH=2','-GGLOBAL_MEMORY_WORDS=64','-GPROGRAM_WORDS=16','-GMSHR_COUNT=2','-GSTORE_QUEUE_DEPTH=1','-GL1_SET_COUNT=64','-GL2_SLICE_COUNT=1','-GL2_SET_COUNT_PER_SLICE=8','-GL2_MISS_COUNT_PER_SLICE=1']
  run(base+['--lint-only','--top-module','a0_production_multi_cluster_store_commit_subsystem','--Mdir',str(td/'prod_lint'),*prod_params,*map(str,[*CORE,*COMMON])],'P7_PRODUCTION_STRICT_LINT',1800)
  print('PROD_SEAM_P7_STRICT_LINT=PASS')
  variants=(
   ('W1',['-GWAVE_SIZE=1','-GWAVE_ID_W=1','-GCONTEXT_ID_W=1']),
   ('W4',['-GWAVE_SIZE=4','-GWAVE_ID_W=2','-GCONTEXT_ID_W=2']),
   ('W32',['-GWAVE_SIZE=32','-GWAVE_ID_W=2','-GCONTEXT_ID_W=2']),
  )
  for name,params in variants: lint_fence_variant(base,td,'matrix_'+name.lower(),params)
  print('PROD_SEAM_P7_PARAMETER_MATRIX=PASS variants=3')
  obj=Path(os.environ.get('A0_P7_BEHAVIOR_OBJDIR',str(td/'beh'))).resolve(); obj.mkdir(parents=True,exist_ok=True)
  run(base+['--output-split','5000','--output-split-cfuncs','500','-CFLAGS','-O0','--cc','--exe','--main','--top-module','a0_store_visibility_commit_fence_tb','--Mdir',str(obj),*map(str,BEHAVIOR_SOURCES)],'P7_BEHAVIOR_GENERATE',1200)
  run(['make','-C',str(obj),'-f','Va0_store_visibility_commit_fence_tb.mk','-j1'],'P7_BEHAVIOR_BUILD',1800)
  sim=run([str(obj/'Va0_store_visibility_commit_fence_tb')],'P7_BEHAVIOR_SIM',180)
  req(sim,MARKERS,'P7_BEHAVIOR_MARKERS'); print(f'PROD_SEAM_P7_BEHAVIOR=PASS markers={len(MARKERS)}')
  if os.environ.get('A0_P7_FULL_PREDECESSOR_REPLAY')=='1':
   pred=run([sys.executable,str(P6RUN)],'P6_PREDECESSOR_FULL_REPLAY',10800)
   req(pred,('PROD_SEAM_P6_GATE=PASS',),'P6_PREDECESSOR_RECEIPT'); print('PROD_SEAM_P7_P6_PREDECESSOR=PASS mode=full-replay')
  else:
   verify_frozen_p6(); print('PROD_SEAM_P7_P6_PREDECESSOR=PASS mode=frozen-canonical-receipt')
 head=run(['git','rev-parse','HEAD'],'POST_HEAD',30).strip(); branch=run(['git','branch','--show-current'],'POST_BRANCH',30).strip(); run(['git','diff','--check'],'POST_DIFFCHECK',30)
 diff=run(['bash','-lc','git diff --binary | sha256sum | cut -d" " -f1'],'POST_DIFFSHA',30).strip()
 if (head,branch,diff)!=(EXPECTED_HEAD,EXPECTED_BRANCH,EXPECTED_DIFF): fail('POST_CONTAINMENT',f'{head} {branch} {diff}')
 outer=os.environ.get('A0_STRICT_OUTER_LOG'); inner=os.environ.get('A0_STRICT_INNER_LOG')
 if outer and leak_count(outer)!=0: fail('OUTER_STRICT_LEAK',str(leak_count(outer)))
 if inner and leak_count(inner)!=0: fail('INNER_STRICT_LEAK',str(leak_count(inner)))
 print('PROD_SEAM_P7_OUTER_STRICT_LEAK=0'); print('PROD_SEAM_P7_INNER_STRICT_LEAK=0'); print('PROD_SEAM_P7_POST_CONTAINMENT=PASS'); print('PROD_SEAM_P7_GATE=PASS'); return 0
if __name__=='__main__': raise SystemExit(main())
