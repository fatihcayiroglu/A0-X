#!/usr/bin/env python3
"""P123 strict 16/16 actual RTL qualification: P122 15-gate + new host oracle.

0=all 16 real Icarus simulations passed; 1=fail; 2=not run.
Do not claim FPGA, silicon, VRAM or display hardware validation.
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
P122 = ROOT/'tools/a0_p122_rtl_qualification.py'
P123 = ROOT/'tests/run_p123_depth3_reset_stream.py'
TB = ROOT/'tests/rtl/a0_p123_depth3_reset_stream_tb.sv'
ORACLE = ROOT/'tools/a0_p122_packet_oracle.py'
MARKER = 'P123_REAL_RTL_DEPTH3_RESET_PASS'


def sha_file(p: Path) -> str:
    return hashlib.sha256(p.read_bytes()).hexdigest()


def load_p122():
    spec = importlib.util.spec_from_file_location('a0_p122_real_gate',P122)
    mod = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(mod)
    return mod


def source_snapshot(root: Path) -> dict[str,str]:
    patterns = ('rtl/**/*.sv','rtl/**/*.v','tests/rtl/**/*.sv',
                'tests/run_p*.py','tests/test_p12*.py','tools/a0_p12*.py',
                'tests/vectors/*.hex')
    found = set()
    for pat in patterns: found.update(root.glob(pat))
    required = [P122,P123,TB,ORACLE,Path(__file__).resolve(),
                root/'rtl/graphics/a0_scanout_telemetry_loss_fifo_p118.sv']
    found.update(required)
    if not found or any(not p.is_file() for p in found):
        raise FileNotFoundError('missing required RTL source, TB or gate runner')
    return {p.relative_to(root).as_posix():sha_file(p) for p in sorted(found)}


def verify_inherited_p122(info: dict, exit_code: int, evidence: Path) -> tuple[bool,str]:
    """Validate real 15-gate evidence *before* accepting the new 16th test."""
    try:
        if exit_code!=0 or info.get('status')!='PASS' or info.get('qualified') is not True:
            return False,'inherited 15 gate run did not PASS'
        if info.get('execution_mode')!='REAL_SUBPROCESS' or info.get('expected_gates')!=15:
            return False,'inherited evidence not tagged as 15 actual subprocess gates'
        if info.get('p121_status')!='PASS' or info.get('p122_status')!='PASS':
            return False,'inherited subgates were not PASS'
        if info.get('p121_evidence_valid') is not True or info.get('sources_unchanged') is not True:
            return False,'inherited source/evidence integrity failed'
        gate=load_p122()
        snapshot=gate.snapshot(ROOT)
        if info.get('source_snapshot_before')!=snapshot or info.get('source_snapshot_after')!=snapshot:
            return False,'inherited source digests do not match current files'
        older=evidence/'p121_14_gates'
        report_path=older/'qualification.json'
        if sha_file(report_path)!=info['p121_evidence_sha256']:
            return False,'P121 evidence JSON changed'
        prior=json.loads(report_path.read_text(encoding='utf8'))
        p121_valid,reason=gate.verify_p121(prior,0,older)
        if not p121_valid: return False,reason
        logfile=evidence/'p122_overflow_race.log'
        if sha_file(logfile)!=info['p122_log_sha256']:
            return False,'P122 log SHA256 mismatch'
        status,why=gate.assess_p122(0,logfile.read_text(encoding='utf8'))
        if status!='PASS' or info.get('p122_exit_code')!=0:
            return False,'P122 witness invalid: '+why
    except (OSError,ValueError,KeyError,TypeError,IndexError,AttributeError,ImportError) as exc:
        return False,'invalid inherited 15-gate evidence: '+str(exc)
    return True,'all 15 prior real Icarus subgate logs and hashes verified'


def assess_new(code:int|None,output:str)->tuple[str,str]:
    if code==2:return 'NOT_RUN','actual Icarus toolchain missing'
    if code!=0:return 'FAIL','P123 real RTL subprocess failed'
    if any(x in output for x in ('NOT_RUN','FATAL:','Traceback (most recent call last)')):
        return 'FAIL','forbidden diagnostic'
    if output.splitlines().count(MARKER)!=1:
        return 'FAIL','missing or duplicate real simulator marker'
    if 'P123 INDEPENDENT PACKET ORACLE: nine valid ordered packets' not in output:
        return 'FAIL','independent Python oracle did not validate all packets'
    return 'PASS','real Icarus run and nine exact independent packet comparisons'


def write_json(path:Path,data:dict)->None:
    path.parent.mkdir(parents=True,exist_ok=True)
    with tempfile.NamedTemporaryFile('w',encoding='utf8',dir=path.parent,
                                     prefix='.p123-',suffix='.tmp',delete=False) as file:
        json.dump(data,file,indent=2,sort_keys=True);file.write('\n')
        tmp=Path(file.name)
    os.replace(tmp,path)


def run(root:Path=ROOT,evidence:Path|None=None)->tuple[int,dict]:
    root=Path(root).resolve()
    if root!=ROOT.resolve():raise ValueError('real P123 gate bound to its own source tree')
    evidence=Path(evidence or ROOT.parent/'EVIDENCE/P123/rtl_qualification').resolve()
    evidence.mkdir(parents=True,exist_ok=True)
    report={
        'schema':'A0-P123-SIXTEEN-REAL-RTL-GATES-1',
        'time_utc':datetime.now(timezone.utc).isoformat(),
        'expected_gates':16,'execution_mode':'REAL_SUBPROCESS',
        'physical_gpu_qualified':False,'qualified':False,
        'status':'NOT_RUN','p122_status':'NOT_RUN','p123_status':'NOT_RUN',
    }
    try:
        before=source_snapshot(root)
        report['source_snapshot_before']=before
        inherited=load_p122()
        older=evidence/'p122_15_gates'
        prev_code,prev=inherited.run(evidence=older)
        report['p122_status']=prev['status']
        report['p122_exit_code']=prev_code
        report['p122_report_sha256']=sha_file(older/'qualification.json')
        valid,reason=verify_inherited_p122(prev,prev_code,older)
        report['p122_evidence_valid']=valid
        report['p122_validation_detail']=reason
        try:
            result=subprocess.run([sys.executable,'-B',str(P123)],cwd=root,
                                  stdout=subprocess.PIPE,stderr=subprocess.STDOUT,
                                  text=True,errors='replace',timeout=240,
                                  env={**os.environ,'PYTHONDONTWRITEBYTECODE':'1'})
            code,output=result.returncode,result.stdout
        except (OSError,subprocess.TimeoutExpired) as exc:
            code,output=1,repr(exc)
        log=evidence/'p123_depth3_reset_stream.log'
        log.write_text(output,encoding='utf8')
        status,why=assess_new(code,output)
        report.update({'p123_status':status,'p123_reason':why,
                       'p123_exit_code':code,'p123_log_sha256':sha_file(log)})
        after=source_snapshot(root)
        report['source_snapshot_after']=after
        report['sources_unchanged']=before==after
        if valid and status=='PASS' and before==after:
            report['status']='PASS';report['qualified']=True;exit_code=0
        elif prev_code==2 and status=='NOT_RUN' and before==after:
            report['status']='NOT_RUN';exit_code=2
        else:
            report['status']='FAIL';exit_code=1
    except (OSError,ValueError,TypeError,ImportError) as exc:
        report['status']='FAIL';report['reason']=str(exc);exit_code=1
    write_json(evidence/'qualification.json',report)
    return exit_code,report


def main()->int:
    parser=argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--evidence',type=Path,
                        default=ROOT.parent/'EVIDENCE/P123/rtl_qualification')
    args=parser.parse_args()
    code,info=run(evidence=args.evidence)
    print(f"P123_REAL_RTL_QUALIFICATION_{info['status']}: "
          f"inherited={info['p122_status']} new={info['p123_status']} "
          f"qualified={info['qualified']}",flush=True)
    return code

if __name__=='__main__': sys.exit(main())
