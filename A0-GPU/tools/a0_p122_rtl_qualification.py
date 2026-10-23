#!/usr/bin/env python3
"""P122 fifteen-gate real RTL qualifier; unrun/fake/mutated evidence fails closed.

Runs P121's fourteen *unchanged* inherited runners followed by P122's real
Icarus overflow-race runner. Exit 0=15 actual PASS; 1=FAIL; 2=NOT_RUN.
This is a verification pipeline, never a claim of physical GPU validation.
"""
from __future__ import annotations
import argparse
import hashlib
import importlib.util
import json
import os
from pathlib import Path
import subprocess
import sys
import tempfile
from datetime import datetime, timezone

ROOT = Path(__file__).resolve().parents[1]
P121_PATH = ROOT / 'tools/a0_p121_rtl_qualification.py'
P122_SCRIPT = ROOT / 'tests/run_p122_overflow_race.py'
P122_TB = ROOT / 'tests/rtl/a0_p122_overflow_race_tb.sv'
P122_ORACLE = ROOT / 'tools/a0_p122_packet_oracle.py'
P122_MARKER = 'P122_REAL_RTL_OVERFLOW_RACE_PASS'
REQUIRED = (P121_PATH, P122_SCRIPT, P122_TB, P122_ORACLE, Path(__file__).resolve())


def sha_file(path: Path) -> str:
    return hashlib.sha256(path.read_bytes()).hexdigest()


def load_p121():
    spec=importlib.util.spec_from_file_location('a0_p121_gate', P121_PATH)
    module=importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


def snapshot(root: Path) -> dict[str,str]:
    paths=set()
    for glob in ('rtl/**/*.sv','rtl/**/*.v','tests/rtl/**/*.sv','tests/run_p*.py',
                 'tools/a0_p12*.py','tests/test_p12*.py'):
        paths.update(root.glob(glob))
    paths.update([root / 'tools/a0_p121_rtl_qualification.py',
                  root / 'tools/a0_p122_rtl_qualification.py',
                  root / 'tools/a0_p122_packet_oracle.py',
                  root / 'tests/run_p122_overflow_race.py',
                  root / 'tests/rtl/a0_p122_overflow_race_tb.sv'])
    if not paths or any(not p.is_file() for p in paths):
        raise FileNotFoundError('required qualification source missing')
    return {p.relative_to(root).as_posix(): sha_file(p) for p in sorted(paths)}


def assess_p122(code: int | None, out: str) -> tuple[str,str]:
    if code == 2:
        return 'NOT_RUN', 'runner explicitly reported unrun'
    if code != 0:
        return 'FAIL','runner failed or timed out'
    if any(term in out for term in ('NOT_RUN','FATAL:','Traceback (most recent call last)')):
        return 'FAIL','failure diagnostic'
    if out.splitlines().count(P122_MARKER) != 1:
        return 'FAIL','required real simulation witness absent or duplicated'
    return 'PASS','runner exited 0 with exact real RTL witness'


def verify_p121(report: dict, code: int, evidence: Path) -> tuple[bool,str]:
    """Do not trust a top-level success flag without all 14 actual log witnesses."""
    try:
        gate=load_p121()
        if report.get('execution_mode')!='REAL_SUBPROCESS' or not report.get('qualified'):
            return False,'non-real or unqualified P121 execution'
        if code != 0 or report.get('status')!='PASS':
            return False,'P121 process did not PASS'
        listed=report['gates']
        if len(listed)!=14 or len(report['sources'])==0:
            return False,'incomplete P121 gate list/sources'
        if report['sources'] != gate.source_hashes(ROOT):
            return False,'P121 hashed source set differs from present files'
        for row, (name, runner, marker) in zip(listed,gate.GATES):
            if (row['name'],row['script'],row['marker'],row['status'],row['exit_code']) != \
               (name,runner,marker,'PASS',0):
                return False,'P121 gate mismatch / failed gate'
            log=evidence/(name.lower()+'.log')
            if not log.is_file() or row['log'] != log.name:
                return False,'missing or path-mismatched P121 log'
            data=log.read_bytes()
            if row['log_sha256']!=hashlib.sha256(data).hexdigest() or row['log_bytes']!=len(data):
                return False,'P121 log digest or length mismatch'
            status,_=gate.assess(0,data.decode('utf8','replace'),marker)
            if status!='PASS':
                return False,'P121 log lacks exact witness'
        if not (report.get('toolchain',{}).get('iverilog') and report.get('toolchain',{}).get('vvp')):
            return False,'P121 had no real RTL toolchain'
    except (OSError,ValueError,KeyError,TypeError,IndexError,AttributeError,ImportError) as exc:
        return False,'invalid P121 evidence: '+str(exc)
    return True,'all 14 P121 real gate outputs independently verified'


def atomic_json(path:Path,payload:dict):
    path.parent.mkdir(parents=True,exist_ok=True)
    with tempfile.NamedTemporaryFile('w',encoding='utf8',dir=path.parent,
                                     prefix='.p122-',suffix='.tmp',delete=False) as f:
        json.dump(payload,f,indent=2,sort_keys=True);f.write('\n');tmp=Path(f.name)
    os.replace(tmp,path)


def run(root:Path=ROOT,evidence:Path|None=None)->tuple[int,dict]:
    root=Path(root).resolve()
    if root!=ROOT.resolve():
        raise ValueError('P122 real runner is bound to its own source tree')
    evidence=Path(evidence or ROOT.parent/'EVIDENCE/P122/rtl_qualification').resolve()
    evidence.mkdir(parents=True,exist_ok=True)
    report={'schema':'A0-P122-FIFTEEN-REAL-RTL-GATES-1',
            'time_utc':datetime.now(timezone.utc).isoformat(),
            'physical_gpu_qualified':False,'expected_gates':15,
            'qualified':False,'status':'NOT_RUN','execution_mode':'REAL_SUBPROCESS',
            'p121_status':'NOT_RUN','p122_status':'NOT_RUN'}
    try:
        prior=snapshot(root)
        report['source_snapshot_before']=prior
        gate=load_p121()
        base_dir=evidence/'p121_14_gates'
        p121_code,p121=gate.run_all(root,base_dir)
        report['p121_status']=p121['status']
        report['p121_exit_code']=p121_code
        report['p121_evidence_sha256']=sha_file(base_dir/'qualification.json')
        p121_valid,detail=verify_p121(p121,p121_code,base_dir)
        report['p121_evidence_valid']=p121_valid
        report['p121_validation_detail']=detail
        try:
            r=subprocess.run([sys.executable,'-B',str(root/'tests/run_p122_overflow_race.py')],
                             cwd=root,stdout=subprocess.PIPE,stderr=subprocess.STDOUT,
                             text=True,errors='replace',timeout=240,
                             env={**os.environ,'PYTHONDONTWRITEBYTECODE':'1'})
            code,output=r.returncode,r.stdout
        except (OSError,subprocess.TimeoutExpired) as exc:
            code,output=1,str(exc)
        (evidence/'p122_overflow_race.log').write_text(output,encoding='utf8')
        p122_status,p122_reason=assess_p122(code,output)
        report.update({'p122_status':p122_status,'p122_reason':p122_reason,
                       'p122_exit_code':code,
                       'p122_log_sha256':sha_file(evidence/'p122_overflow_race.log')})
        afterward=snapshot(root)
        report['source_snapshot_after']=afterward
        report['sources_unchanged']=prior==afterward
        if (p121_valid and p122_status=='PASS' and report['sources_unchanged']):
            report['status']='PASS';report['qualified']=True;exit_code=0
        elif p121_code==2 and p122_status=='NOT_RUN' and report['sources_unchanged']:
            report['status']='NOT_RUN';exit_code=2
        else:
            report['status']='FAIL';exit_code=1
    except (OSError,ValueError,TypeError,ImportError) as exc:
        report.update({'status':'FAIL','reason':str(exc)})
        exit_code=1
    atomic_json(evidence/'qualification.json',report)
    return exit_code,report


def main():
    p=argparse.ArgumentParser(description=__doc__)
    p.add_argument('--evidence',type=Path,default=ROOT.parent/'EVIDENCE/P122/rtl_qualification')
    args=p.parse_args()
    code,data=run(evidence=args.evidence)
    print('P122_REAL_RTL_QUALIFICATION_'+data['status']+
          f": inherited={data['p121_status']}; new={data['p122_status']}; "
          f"qualified={data['qualified']}",flush=True)
    return code

if __name__=='__main__':sys.exit(main())
