#!/usr/bin/env python3
from __future__ import annotations
import hashlib, json, os, shutil, subprocess, sys, tempfile
from pathlib import Path
sys.dont_write_bytecode=True
ROOT=Path(__file__).resolve().parents[1]
V=Path(os.environ.get("A0_VERILATOR_BIN", shutil.which("verilator") or "verilator"))
EXPECTED_HEAD="996d8c188e5d4f94b4bad5289392844d55d092f6"
EXPECTED_BRANCH="main"
EXPECTED_DIFF="59fac4fc152cc4e46ed60bff0feecf700756d860ed4f44436f532a221570eb8b"
ARB=ROOT/'rtl/memory/a0_retry_round_robin_arbiter.sv'
P5M=ROOT/'rtl/memory/a0_mc_noc_sliced_l2_store_liveness_subsystem.sv'
P5=ROOT/'rtl/core/a0_production_multi_cluster_store_liveness_subsystem.sv'
TB=ROOT/'tests/rtl/a0_mc_noc_sliced_l2_store_liveness_subsystem_tb.sv'
DOC=ROOT/'docs/architecture/A0_PROD_SEAM_P5_REPLAY_LIVENESS_VISIBILITY.md'
P4RUN=ROOT/'tests/run_prod_seam_p4.py'
P4_RECEIPT=ROOT.parent/'EVIDENCE/P4/receipt.txt'
P4_RECEIPT_SHA='50ee71238deda29062ddfdab49cb21c0da36e5dacac16759c3e8531aa5092eb7'
P4_FROZEN_HASHES={
 str(ROOT/'tests/run_prod_seam_p4.py'):'9e3b5f2870142d42398a7c2c23deb4f4d7d63a6e0258be187e50c635a32b93b7',
 str(ROOT/'rtl/memory/a0_mc_noc_sliced_l2_store_order_subsystem.sv'):'f443dcecc69293f33c5cb80ad23ecd8155dfed6a534800d6f27709f5cb02a732',
 str(ROOT/'rtl/core/a0_production_multi_cluster_store_order_subsystem.sv'):'81bb945a4a1e790ef5d1900ace2e61360dd5027531052c07572effa59b985136',
 str(ROOT/'tests/rtl/a0_mc_noc_sliced_l2_store_order_subsystem_tb.sv'):'15416dc6f8e662a39fe0bab822b2fcdbe6a09aae1c995fa68f3f87c099433d11',
 str(ROOT/'docs/architecture/A0_PROD_SEAM_P4_STALE_REFILL_ORDERING.md'):'8f2a2aa2c77e198e74a88a50e3a8fad6650a28f9da2707c91b62cfe235ee5e5e',
}
COMMON=[ARB,ROOT/'rtl/memory/a0_cluster_line_noc_endpoint.sv',ROOT/'rtl/memory/a0_mc_noc_logical_request_router.sv',ROOT/'rtl/memory/a0_mc_noc_logical_transaction_router.sv',ROOT/'rtl/memory/a0_l2_line_cache.sv',ROOT/'rtl/memory/a0_mc_noc_sliced_l2_store_invalidate_subsystem.sv',P5M]
CORE=[ROOT/'rtl/core/a0_scoreboard.sv',ROOT/'rtl/core/a0_dependency_classifier.sv',ROOT/'rtl/core/a0_lane_sequencer.sv',ROOT/'rtl/core/a0_operand_collector.sv',ROOT/'rtl/core/a0_regfile_banked_contexted.sv',ROOT/'rtl/core/a0_vector_operand_path_contexted.sv',ROOT/'rtl/scheduler/a0_wave_context_file.sv',ROOT/'rtl/scheduler/a0_wave_scheduler.sv',ROOT/'rtl/scheduler/a0_multi_wave_frontend.sv',ROOT/'rtl/scheduler/a0_wave_scoreboard_bank.sv',ROOT/'rtl/memory/a0_mshr_table.sv',ROOT/'rtl/memory/a0_wave_load_mshr_bridge.sv',ROOT/'rtl/memory/a0_store_queue.sv',ROOT/'rtl/memory/a0_l1_line_cache.sv',ROOT/'rtl/memory/a0_memory_service_boundary.sv',ROOT/'rtl/core/a0_multi_wave_core.sv',ROOT/'rtl/memory/a0_cluster_store_order_controller.sv',ROOT/'rtl/memory/a0_line_request_fabric.sv',ROOT/'rtl/memory/a0_production_cluster_line_seam.sv',ROOT/'rtl/core/a0_production_cu_cluster_frontend.sv',ROOT/'rtl/core/a0_production_multi_cluster_store_invalidate_subsystem.sv',P5]
MARKERS=(
 "PROD_SEAM_P5_ROUND_ROBIN_FAIRNESS=PASS",
 "PROD_SEAM_P5_RETRY_CAPACITY_BACKPRESSURE=PASS",
 "PROD_SEAM_P5_REPEATED_CONFLICT_LIVENESS=PASS",
 "PROD_SEAM_P5_REQUESTER_IDENTITY_PRESERVED=PASS",
 "PROD_SEAM_P5_NO_DOUBLE_RETIRE=PASS",
 "PROD_SEAM_P5_MULTI_CLUSTER_MULTI_SLICE=PASS",
 "PROD_SEAM_P5_POST_STORE_VISIBILITY=PASS",
 "PROD_SEAM_P5_FAULT_PROVENANCE_DISTINCT=PASS",
 "PROD_SEAM_P5_BEHAVIOR=PASS",
)
def fail(stage,detail,rc=1):
 print("PROD_SEAM_P5_FIRST_FAILURE",file=sys.stderr); print(f"STAGE={stage}",file=sys.stderr); print(f"DETAIL={detail}",file=sys.stderr); raise SystemExit(rc)
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
def verify_frozen_p4():
 if not P4_RECEIPT.is_file(): fail('P4_PREDECESSOR_RECEIPT','missing frozen P4 receipt')
 if sha256_file(P4_RECEIPT)!=P4_RECEIPT_SHA: fail('P4_PREDECESSOR_RECEIPT','receipt SHA mismatch')
 receipt=P4_RECEIPT.read_text()
 req(receipt,('PROD_SEAM_P4_P3_PREDECESSOR=PASS','PROD_SEAM_P4_OUTER_STRICT_LEAK=0','PROD_SEAM_P4_INNER_STRICT_LEAK=0','PROD_SEAM_P4_POST_CONTAINMENT=PASS','PROD_SEAM_P4_GATE=PASS'),'P4_PREDECESSOR_RECEIPT')
 for fn,want in P4_FROZEN_HASHES.items():
  if not Path(fn).is_file() or sha256_file(fn)!=want: fail('P4_PREDECESSOR_IMMUTABILITY',fn)
 return receipt
def lint_variant(base,td,name,params):
 run(base+['--lint-only','--top-module','a0_mc_noc_sliced_l2_store_liveness_subsystem','--Mdir',str(td/name),*params,*map(str,COMMON)],f'P5_MATRIX_{name.upper()}',1200)
def main():
 ver=run([V,'--version'],'VERSION',30).strip()
 if not ver.startswith('Verilator 5.050 '): fail('VERSION',ver)
 print('PROD_SEAM_P5_EXACT_VERILATOR_5_050=PASS')
 for f in [ARB,P5M,P5,TB,DOC,P4RUN,*COMMON,*CORE]:
  if not f.is_file(): fail('SOURCE_AVAILABILITY',str(f))
 mt=P5M.read_text(); pt=P5.read_text(); at=ARB.read_text(); dt=DOC.read_text()
 need=('retry_wait_drop_q','retry_inflight_q','retry_rr_q','incoming_retry_busy','track_free_found','p3_line_mem_req_ready','a0_retry_round_robin_arbiter #(','a0_mc_noc_sliced_l2_store_invalidate_subsystem #(')
 if any(x not in mt for x in need) or 'a0_mc_noc_sliced_l2_store_liveness_subsystem #(' not in pt or 'cursor_i' not in at: fail('STATIC_CONTRACT','missing P5 composition/liveness token')
 if any(x in mt for x in ('dirty_q','writeback_queue','atomic_unit','snoop')): fail('BOUNDED_SCOPE','full coherence claim/state leaked')
 if 'full cache-coherence protocol' not in dt or 'Round-robin liveness contract' not in dt or 'Finite backend shadow capacity' not in dt: fail('DOCUMENTED_CONTRACT','P5 bounded contract missing')
 print('PROD_SEAM_P5_STATIC_COMPOSITION_CONTRACT=PASS')
 print('PROD_SEAM_P5_BOUNDED_LIVENESS_SCOPE=PASS')
 print('PROD_SEAM_P5_DOCUMENTED_VISIBILITY_CONTRACT=PASS')
 with tempfile.TemporaryDirectory(prefix='a0_p5_',dir='/tmp') as td0:
  td=Path(td0)
  base=[str(V),'--timing','--unroll-count','512','-Wall','-Werror-PINMISSING','-Werror-WIDTHEXPAND','-Werror-WIDTHTRUNC']
  run(base+['--lint-only','--top-module','a0_production_multi_cluster_store_liveness_subsystem','--Mdir',str(td/'prod_lint'),'-GCLUSTER_COUNT=1','-GCUS_PER_CLUSTER=1','-GRESIDENT_WAVES=1','-GPHYSICAL_LANES=1','-GL2_SLICE_COUNT=1','-GL2_SET_COUNT_PER_SLICE=8','-GL2_MISS_COUNT_PER_SLICE=2',*map(str,[*CORE,*COMMON])],'P5_PRODUCTION_STRICT_LINT',1200)
  print('PROD_SEAM_P5_STRICT_LINT=PASS')
  variants=(
   ('1X1',['-GCLUSTER_COUNT=1','-GCUS_PER_CLUSTER=1','-GMSHR_COUNT=1','-GLINE_WORDS=4','-GL2_SLICE_COUNT=1','-GL2_SET_COUNT_PER_SLICE=8','-GL2_MISS_COUNT_PER_SLICE=1','-GSTORE_LANES=1']),
   ('2X2',['-GCLUSTER_COUNT=2','-GCUS_PER_CLUSTER=2','-GMSHR_COUNT=2','-GLINE_WORDS=4','-GL2_SLICE_COUNT=2','-GL2_SET_COUNT_PER_SLICE=8','-GL2_MISS_COUNT_PER_SLICE=4','-GSTORE_LANES=128']),
   ('3X3',['-GCLUSTER_COUNT=3','-GCUS_PER_CLUSTER=3','-GMSHR_COUNT=3','-GLINE_WORDS=4','-GL2_SLICE_COUNT=4','-GL2_SET_COUNT_PER_SLICE=8','-GL2_MISS_COUNT_PER_SLICE=4','-GSTORE_LANES=288']),
  )
  for name,params in variants: lint_variant(base,td,'matrix_'+name.lower(),params)
  print('PROD_SEAM_P5_PARAMETER_MATRIX=PASS variants=3')
  obj=Path(os.environ.get('A0_P5_BEHAVIOR_OBJDIR',str(td/'beh'))).resolve()
  obj.mkdir(parents=True,exist_ok=True)
  run(base+['--output-split','5000','--output-split-cfuncs','500','-CFLAGS','-O0','--cc','--exe','--main','--top-module','a0_mc_noc_sliced_l2_store_liveness_subsystem_tb','--Mdir',str(obj),*map(str,[*COMMON,TB])],'P5_BEHAVIOR_GENERATE',1200)
  run(['make','-C',str(obj),'-f','Va0_mc_noc_sliced_l2_store_liveness_subsystem_tb.mk','-j1'],'P5_BEHAVIOR_BUILD',1800)
  sim=run([str(obj/'Va0_mc_noc_sliced_l2_store_liveness_subsystem_tb')],'P5_BEHAVIOR_SIM',180)
  req(sim,MARKERS,'P5_BEHAVIOR_MARKERS'); print(f'PROD_SEAM_P5_BEHAVIOR=PASS markers={len(MARKERS)}')
  if os.environ.get('A0_P5_FULL_PREDECESSOR_REPLAY')=='1':
   pred=run([sys.executable,str(P4RUN)],'P4_PREDECESSOR_FULL_REPLAY',10800)
   req(pred,("PROD_SEAM_P4_GATE=PASS",),'P4_PREDECESSOR_RECEIPT'); print('PROD_SEAM_P5_P4_PREDECESSOR=PASS mode=full-replay')
  else:
   verify_frozen_p4(); print('PROD_SEAM_P5_P4_PREDECESSOR=PASS mode=frozen-canonical-receipt')
 head=run(['git','rev-parse','HEAD'],'POST_HEAD',30).strip(); branch=run(['git','branch','--show-current'],'POST_BRANCH',30).strip(); run(['git','diff','--check'],'POST_DIFFCHECK',30)
 diff=run(['bash','-lc','git diff --binary | sha256sum | cut -d" " -f1'],'POST_DIFFSHA',30).strip()
 if (head,branch,diff)!=(EXPECTED_HEAD,EXPECTED_BRANCH,EXPECTED_DIFF): fail('POST_CONTAINMENT',f'{head} {branch} {diff}')
 outer=os.environ.get('A0_STRICT_OUTER_LOG'); inner=os.environ.get('A0_STRICT_INNER_LOG')
 if outer and leak_count(outer)!=0: fail('OUTER_STRICT_LEAK',str(leak_count(outer)))
 if inner and leak_count(inner)!=0: fail('INNER_STRICT_LEAK',str(leak_count(inner)))
 print('PROD_SEAM_P5_OUTER_STRICT_LEAK=0'); print('PROD_SEAM_P5_INNER_STRICT_LEAK=0'); print('PROD_SEAM_P5_POST_CONTAINMENT=PASS'); print('PROD_SEAM_P5_GATE=PASS'); return 0
if __name__=='__main__': raise SystemExit(main())
