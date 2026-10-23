#!/usr/bin/env python3
"""P125 mandatory 18-gate *actual* RTL qualification, fail closed.

Return 0 only after all 18 genuine simulator executions AND the P125 independent
packet oracle. Return 2 for missing iverilog/vvp (NOT_RUN); 1 for any failure.
Never equate this with FPGA synthesis or hardware verification.
"""
from __future__ import annotations
import argparse
from datetime import datetime,timezone
import hashlib
import importlib.util
import json
import os
from pathlib import Path
import subprocess
import sys
import tempfile

ROOT=Path(__file__).resolve().parents[1]
P124_GATE=ROOT/'tools/a0_p124_rtl_qualification.py'
P125_RUNNER=ROOT/'tests/run_p125_depth7_ring_reset.py'
SOURCE_LIST=[P125_RUNNER,ROOT/'tests/rtl/a0_p125_depth7_ring_reset_tb.sv',
             ROOT/'tests/test_p125_oracle_and_gate.py',Path(__file__).resolve()]
PASS='P125_REAL_RTL_DEPTH7_RING_RESET_PASS'
ORACLE='P125 INDEPENDENT PACKET ORACLE: ten wire-exact CRC packets and isolated nine-byte reset prefix'


def digest(p:Path)->str:
    return hashlib.sha256(p.read_bytes()).hexdigest()


def p124_gate():
    spec=importlib.util.spec_from_file_location('a0_p124_gate_for_p125',P124_GATE)
    mod=importlib.util.module_from_spec(spec)
    spec.loader.exec_module(mod)
    return mod


def snapshot()->dict[str,str]:
    paths=p124_gate().snapshot()
    for p in SOURCE_LIST:
        if not p.is_file():raise FileNotFoundError(p)
        paths[p.relative_to(ROOT).as_posix()]=digest(p)
    return dict(sorted(paths.items()))


def inherited_valid(info:dict,code:int,evidence:Path)->tuple[bool,str]:
    try:
        if code!=0 or info.get('status')!='PASS' or info.get('qualified') is not True:
            return False,'P124 17-gate chain did not PASS'
        if info.get('execution_mode')!='REAL_SUBPROCESS' or info.get('expected_gates')!=17:
            return False,'incorrect P124 evidence mode/count'
        if info.get('p123_status')!='PASS' or info.get('p124_status')!='PASS':
            return False,'inherited P123/P124 failure'
        if info.get('p123_evidence_valid') is not True or info.get('sources_unchanged') is not True:
            return False,'P124 evidence integrity flag missing'
        old=p124_gate()
        expected=old.snapshot()
        if info.get('source_snapshot_before')!=expected or info.get('source_snapshot_after')!=expected:
            return False,'P124 source digest mismatch'
        prev_dir=evidence/'p123_16_gates'
        prior=prev_dir/'qualification.json'
        if digest(prior)!=info.get('p123_report_sha256'):
            return False,'P123 report SHA256 mismatch'
        previous=json.loads(prior.read_text(encoding='utf8'))
        passed,reason=old.verify_inherited_p123(previous,0,prev_dir)
        if not passed:return False,'P123 chained evidence invalid: '+reason
        log=evidence/'p124_depth5_loss_notice_race.log'
        if digest(log)!=info.get('p124_log_sha256'):
            return False,'P124 stdout digest mismatch'
        state,reason=old.assess_new(info.get('p124_exit_code'),log.read_text(encoding='utf8'))
        if state!='PASS':return False,'P124 witness invalid: '+reason
    except (OSError,TypeError,ValueError,KeyError,AttributeError,ImportError) as exc:
        return False,'missing or invalid inherited evidence: '+repr(exc)
    return True,'all 17 inherited real gates with chained SHA256 logs'


def assess_new(code:int|None,output:str)->tuple[str,str]:
    if code==2:return 'NOT_RUN','real simulator unavailable'
    if code!=0:return 'FAIL','P125 simulator/oracle process failed'
    if any(x in output for x in ('NOT_RUN','FATAL:','Traceback (most recent call last)')):
        return 'FAIL','forbidden failure/skip diagnostic'
    if output.splitlines().count(PASS)!=1 or output.splitlines().count(ORACLE)!=1:
        return 'FAIL','simulator and independent oracle witnesses required uniquely'
    return 'PASS','real HDL run and wire-oracle verified'


def save_json(file:Path,data:dict)->None:
    file.parent.mkdir(parents=True,exist_ok=True)
    with tempfile.NamedTemporaryFile('w',dir=file.parent,encoding='utf8',
         prefix='.p125-',suffix='.tmp',delete=False) as f:
        json.dump(data,f,sort_keys=True,indent=2);f.write('\n');tmp=Path(f.name)
    os.replace(tmp,file)


def run(evidence:Path|None=None)->tuple[int,dict]:
    evidence=Path(evidence or ROOT.parent/'EVIDENCE/P125/rtl_qualification').resolve()
    evidence.mkdir(parents=True,exist_ok=True)
    report={'schema':'A0-P125-EIGHTEEN-REAL-RTL-GATES-1',
            'timestamp_utc':datetime.now(timezone.utc).isoformat(),
            'expected_gates':18,'execution_mode':'REAL_SUBPROCESS',
            'physical_gpu_qualified':False,'qualified':False,'status':'NOT_RUN',
            'p124_status':'NOT_RUN','p125_status':'NOT_RUN'}
    try:
        before=snapshot()
        report['source_snapshot_before']=before
        old=p124_gate()
        prior_dir=evidence/'p124_17_gates'
        prior_code,prior=old.run(evidence=prior_dir)
        report.update(p124_status=prior['status'],p124_exit_code=prior_code,
                      p124_report_sha256=digest(prior_dir/'qualification.json'))
        accepted,reason=inherited_valid(prior,prior_code,prior_dir)
        report.update(p124_evidence_valid=accepted,p124_validation_detail=reason)
        try:
            proc=subprocess.run([sys.executable,'-B',str(P125_RUNNER)],cwd=ROOT,
                capture_output=True,text=True,errors='replace',timeout=240,
                env={**os.environ,'PYTHONDONTWRITEBYTECODE':'1'})
            new_code,output=proc.returncode,proc.stdout+proc.stderr
        except (OSError,subprocess.TimeoutExpired) as exc:
            new_code,output=1,repr(exc)
        log=evidence/'p125_depth7_ring_reset.log'
        log.write_text(output,encoding='utf8')
        state,why=assess_new(new_code,output)
        report.update(p125_status=state,p125_exit_code=new_code,
                      p125_reason=why,p125_log_sha256=digest(log))
        after=snapshot()
        report.update(source_snapshot_after=after,sources_unchanged=before==after)
        if accepted and state=='PASS' and before==after:
            report['qualified']=True;report['status']='PASS';exit_code=0
        elif prior_code==2 and state=='NOT_RUN' and before==after:
            report['status']='NOT_RUN';exit_code=2
        else:
            report['status']='FAIL';exit_code=1
    except (OSError,ValueError,TypeError,ImportError,AttributeError) as exc:
        report.update(status='FAIL',reason=repr(exc));exit_code=1
    save_json(evidence/'qualification.json',report)
    return exit_code,report


def main()->int:
    p=argparse.ArgumentParser(description=__doc__)
    p.add_argument('--evidence',type=Path)
    opts=p.parse_args()
    code,r=run(opts.evidence)
    print(f"P125_REAL_RTL_QUALIFICATION_{r['status']}: "
          f"inherited={r['p124_status']} new={r['p125_status']} qualified={r['qualified']}")
    return code

if __name__=='__main__':sys.exit(main())
