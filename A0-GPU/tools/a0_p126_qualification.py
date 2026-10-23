#!/usr/bin/env python3
"""P126 software reset-boundary regressions + inherited 18 REAL RTL gates.

0 = all host tests and inherited actual HDL executions PASS.
1 = failure; 2 = NOT_RUN when real HDL simulator is unavailable.
A passing status is NOT physical GPU qualification or proof of a real reset.
"""
from __future__ import annotations
import argparse
from datetime import datetime,timezone
import hashlib
import importlib.util
import json
import os
from pathlib import Path
import re
import subprocess
import sys
import tempfile

ROOT=Path(__file__).resolve().parents[1]
PREVIOUS=ROOT/'tools/a0_p125_rtl_qualification.py'
SUITES=(117,118,119,120,121,122,123,124,125,126)
P126_SOURCES=(ROOT/'sim/a0_p126_reset_boundary_receiver.py',
              ROOT/'tests/test_p126_reset_boundary_receiver.py',
              Path(__file__).resolve())
RUN_PATTERN=re.compile(r'Ran (\d+) tests? in [\d.]+s?')


def digest(p:Path)->str:
    return hashlib.sha256(p.read_bytes()).hexdigest()


def inherited():
    spec=importlib.util.spec_from_file_location('a0_p125_gate_p126',PREVIOUS)
    m=importlib.util.module_from_spec(spec)
    spec.loader.exec_module(m)
    return m


def snapshot()->dict[str,str]:
    paths=inherited().snapshot()
    for p in P126_SOURCES:
        if not p.is_file():raise FileNotFoundError(p)
        paths[p.relative_to(ROOT).as_posix()]=digest(p)
    return dict(sorted(paths.items()))


def assess_tests(rc:int,log:str)->tuple[bool,int]:
    # Parse test runner summary to prevent an empty directory passing as tests.
    matches=RUN_PATTERN.findall(log)
    ok=(rc==0 and len(matches)==1 and int(matches[0])>0 and
        re.search(r'^OK\s*$',log,re.MULTILINE) is not None and
        'FAILED (' not in log and 'skipped=' not in log and 'expected failure' not in log)
    return ok,int(matches[0]) if len(matches)==1 else 0


def inherited_valid(report:dict, code:int, evidence:Path)->bool:
    if code!=0 or report.get('status')!='PASS' or report.get('qualified') is not True:
        return False
    if report.get('expected_gates')!=18 or report.get('execution_mode')!='REAL_SUBPROCESS':
        return False
    if report.get('p124_evidence_valid') is not True or report.get('p125_status')!='PASS':
        return False
    if report.get('sources_unchanged') is not True:
        return False
    old=inherited()
    expected=old.snapshot()
    if report.get('source_snapshot_before')!=expected or report.get('source_snapshot_after')!=expected:
        return False
    try:
        if digest(evidence/'p125_depth7_ring_reset.log')!=report.get('p125_log_sha256'):
            return False
        if digest(evidence/'p124_17_gates/qualification.json')!=report.get('p124_report_sha256'):
            return False
        prior=json.loads((evidence/'p124_17_gates/qualification.json').read_text())
        valid,_=old.inherited_valid(prior,0,evidence/'p124_17_gates')
        if not valid:return False
        state,_=old.assess_new(report.get('p125_exit_code'),
                           (evidence/'p125_depth7_ring_reset.log').read_text())
        return state=='PASS'
    except (OSError,TypeError,ValueError,KeyError):return False


def save_json(p:Path,report:dict)->None:
    p.parent.mkdir(parents=True,exist_ok=True)
    with tempfile.NamedTemporaryFile('w',prefix='.p126-',suffix='.json.tmp',
           dir=p.parent,delete=False,encoding='utf8') as f:
        json.dump(report,f,indent=2,sort_keys=True);f.write('\n');tmp=Path(f.name)
    os.replace(tmp,p)


def run(evidence:Path)->tuple[int,dict]:
    evidence=Path(evidence).resolve()
    evidence.mkdir(parents=True,exist_ok=True)
    result={'schema':'A0-P126-RESET-BOUNDARY-QUALIFICATION-v1',
            'timestamp_utc':datetime.now(timezone.utc).isoformat(),
            'status':'NOT_RUN', 'qualified':False, 'real_rtl_gates_expected':18,
            'real_rtl_gates_verified':0,'physical_gpu_qualified':False,
            'device_reset_authenticated':False, 'execution_mode':'REAL_SUBPROCESS',
            'python_status':'NOT_RUN','rtl_status':'NOT_RUN'}
    rc=1
    try:
        before=snapshot()
        result['source_snapshot_before']=before
        total=0; all_ok=True
        for n in SUITES:
            proc=subprocess.run([sys.executable,'-B','-m','unittest','discover','-s',str(ROOT/'tests'),
                 '-p',f'test_p{n}_*.py','-v'], cwd=ROOT, capture_output=True,
                 text=True, errors='replace',timeout=180,
                 env={**os.environ,'PYTHONDONTWRITEBYTECODE':'1'})
            log=proc.stdout+proc.stderr
            lp=evidence/f'python_p{n}.log';lp.write_text(log,encoding='utf8')
            valid,count=assess_tests(proc.returncode,log)
            result[f'python_p{n}']={'passed':valid, 'tests':count,
                                    'exit_code':proc.returncode, 'sha256':digest(lp)}
            total+=count; all_ok=all_ok and valid
        result['python_tests_total']=total
        result['python_status']='PASS' if all_ok else 'FAIL'
        old=inherited()
        prior_dir=evidence/'p125_18_gates'
        prior_rc,prior=old.run(evidence=prior_dir)
        prior_path=prior_dir/'qualification.json'
        result['p125_exit_code']=prior_rc
        result['p125_report_sha256']=digest(prior_path)
        result['rtl_status']=prior.get('status','FAIL')
        accepted=inherited_valid(prior,prior_rc,prior_dir)
        result['inherited_evidence_valid']=accepted
        if accepted:result['real_rtl_gates_verified']=18
        after=snapshot()
        result['source_snapshot_after']=after
        result['sources_unchanged']=after==before
        if all_ok and accepted and after==before:
            rc=0;result['status']='PASS';result['qualified']=True
        elif all_ok and prior_rc==2 and prior.get('status')=='NOT_RUN' and after==before:
            rc=2;result['status']='NOT_RUN'
        else:
            rc=1;result['status']='FAIL'
    except (OSError, ValueError, TypeError, ImportError, subprocess.TimeoutExpired) as exc:
        result.update(status='FAIL',reason=repr(exc));rc=1
    save_json(evidence/'qualification.json',result)
    return rc,result


def main()->int:
    p=argparse.ArgumentParser(description=__doc__)
    p.add_argument('--evidence',type=Path,default=ROOT.parent/'EVIDENCE/P126/qualification')
    args=p.parse_args()
    code,info=run(args.evidence)
    print(f"P126_QUALIFICATION_{info['status']}: python={info['python_status']}, "
          f"inherited_real_rtl={info['rtl_status']}, "
          f"gates={info['real_rtl_gates_verified']}/18, "
          f"physical_gpu_qualified={info['physical_gpu_qualified']}")
    return code

if __name__=='__main__':sys.exit(main())
