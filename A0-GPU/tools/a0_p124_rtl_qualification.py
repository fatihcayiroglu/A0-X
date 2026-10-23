#!/usr/bin/env python3
"""P124 fail-closed actual 17-gate Icarus qualification with evidence chaining.

Never consider Python-only tests or fabricated status as RTL qualification.
Exit 0 all 17 real RTL gates, 1 genuine FAIL, 2 missing simulator NOT_RUN.
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
P123=ROOT/'tools/a0_p123_rtl_qualification.py'
P124=ROOT/'tests/run_p124_depth5_loss_notice_race.py'
MARKER='P124_REAL_RTL_DEPTH5_LOSS_RACE_PASS'
ORACLE_MARKER='P124 INDEPENDENT PACKET ORACLE: eight ordered CRC-checked packets; loss 1 then 2, both retained'


def sha_file(path:Path)->str:
    return hashlib.sha256(path.read_bytes()).hexdigest()


def load_p123():
    spec=importlib.util.spec_from_file_location('a0_p123_gate_for_p124',P123)
    mod=importlib.util.module_from_spec(spec)
    spec.loader.exec_module(mod)
    return mod


def snapshot()->dict[str,str]:
    previous=load_p123().source_snapshot(ROOT)
    newfiles=[P124,ROOT/'tests/rtl/a0_p124_depth5_loss_notice_race_tb.sv',
              ROOT/'tests/test_p124_oracle_and_gate.py',Path(__file__).resolve()]
    for file in newfiles:
        if not file.is_file():raise FileNotFoundError(file)
        previous[file.relative_to(ROOT).as_posix()]=sha_file(file)
    return dict(sorted(previous.items()))


def verify_inherited_p123(info:dict,code:int,evidence:Path)->tuple[bool,str]:
    """Check all prior 16 actual gates, chained evidence files, source digests."""
    try:
        if code!=0 or info.get('status')!='PASS' or info.get('qualified') is not True:
            return False,'P123 did not qualify real RTL'
        if info.get('execution_mode')!='REAL_SUBPROCESS' or info.get('expected_gates')!=16:
            return False,'invalid P123 provenance or gate count'
        if info.get('p122_status')!='PASS' or info.get('p123_status')!='PASS':
            return False,'inherited P122 or P123 failed'
        if info.get('p122_evidence_valid') is not True or info.get('sources_unchanged') is not True:
            return False,'P123 evidence not validated or source changed'
        p123=load_p123()
        snap=p123.source_snapshot(ROOT)
        if info.get('source_snapshot_before')!=snap or info.get('source_snapshot_after')!=snap:
            return False,'P123 source snapshot mismatch'
        p122_dir=evidence/'p122_15_gates'
        p122_path=p122_dir/'qualification.json'
        if sha_file(p122_path)!=info['p122_report_sha256']:
            return False,'P122 summary SHA256 mismatch'
        p122_info=json.loads(p122_path.read_text(encoding='utf8'))
        older_ok,older_reason=p123.verify_inherited_p122(p122_info,0,p122_dir)
        if not older_ok:return False,'P122 invalid: '+older_reason
        p123_log=evidence/'p123_depth3_reset_stream.log'
        if sha_file(p123_log)!=info['p123_log_sha256']:
            return False,'P123 simulator stdout SHA256 mismatch'
        state,why=p123.assess_new(info['p123_exit_code'],
                                   p123_log.read_text(encoding='utf8'))
        if state!='PASS':return False,'P123 witness invalid: '+why
    except (OSError,ValueError,TypeError,KeyError,ImportError,AttributeError) as exc:
        return False,'missing or invalid P123 evidence: '+repr(exc)
    return True,'16 inherited real RTL gates with chained SHA256 evidence'


def assess_new(code:int|None,out:str)->tuple[str,str]:
    if code==2:return 'NOT_RUN','actual Icarus simulator missing'
    if code!=0:return 'FAIL','P124 real RTL subprocess exited nonzero'
    if any(x in out for x in ('NOT_RUN','FATAL:','Traceback (most recent call last)')):
        return 'FAIL','forbidden simulation diagnostic'
    if out.splitlines().count(MARKER)!=1 or out.splitlines().count(ORACLE_MARKER)!=1:
        return 'FAIL','actual RTL pass and eight-packet host oracle markers required'
    return 'PASS','real RTL and independent wire oracle passed'


def atomic_json(path:Path,data:dict)->None:
    path.parent.mkdir(parents=True,exist_ok=True)
    with tempfile.NamedTemporaryFile('w',dir=path.parent,encoding='utf8',
           prefix='.p124-',suffix='.tmp',delete=False) as f:
        json.dump(data,f,indent=2,sort_keys=True);f.write('\n')
        tmp=Path(f.name)
    os.replace(tmp,path)


def run(evidence:Path|None=None)->tuple[int,dict]:
    evidence=Path(evidence or ROOT.parent/'EVIDENCE/P124/rtl_qualification').resolve()
    evidence.mkdir(parents=True,exist_ok=True)
    record={'schema':'A0-P124-SEVENTEEN-REAL-RTL-GATES-1',
       'time_utc':datetime.now(timezone.utc).isoformat(),
       'expected_gates':17,'execution_mode':'REAL_SUBPROCESS',
       'status':'NOT_RUN','qualified':False,'physical_gpu_qualified':False,
       'p123_status':'NOT_RUN','p124_status':'NOT_RUN'}
    try:
        before=snapshot();record['source_snapshot_before']=before
        p123=load_p123()
        old=evidence/'p123_16_gates'
        prev_code,prev=p123.run(evidence=old)
        record.update({'p123_status':prev['status'],
                       'p123_exit_code':prev_code,
                       'p123_report_sha256':sha_file(old/'qualification.json')})
        inherited_ok,reason=verify_inherited_p123(prev,prev_code,old)
        record.update({'p123_evidence_valid':inherited_ok,
                       'p123_validation_detail':reason})
        try:
            result=subprocess.run([sys.executable,'-B',str(P124)],cwd=ROOT,
                     stdout=subprocess.PIPE,stderr=subprocess.STDOUT,
                     text=True,errors='replace',timeout=240,
                     env={**os.environ,'PYTHONDONTWRITEBYTECODE':'1'})
            code,out=result.returncode,result.stdout
        except (OSError,subprocess.TimeoutExpired) as exc:
            code,out=1,repr(exc)
        logfile=evidence/'p124_depth5_loss_notice_race.log'
        logfile.write_text(out,encoding='utf8')
        state,why=assess_new(code,out)
        record.update({'p124_status':state,'p124_exit_code':code,
                       'p124_reason':why,'p124_log_sha256':sha_file(logfile)})
        after=snapshot()
        record.update({'source_snapshot_after':after,
                       'sources_unchanged':before==after})
        if inherited_ok and state=='PASS' and before==after:
            record['status']='PASS';record['qualified']=True;exit_code=0
        elif prev_code==2 and state=='NOT_RUN' and before==after:
            record['status']='NOT_RUN';exit_code=2
        else:
            record['status']='FAIL';exit_code=1
    except (OSError,ValueError,TypeError,ImportError) as exc:
        record.update({'status':'FAIL','reason':repr(exc)});exit_code=1
    atomic_json(evidence/'qualification.json',record)
    return exit_code,record


def main()->int:
    parser=argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--evidence',type=Path,default=ROOT.parent/'EVIDENCE/P124/rtl_qualification')
    args=parser.parse_args()
    code,info=run(evidence=args.evidence)
    print(f"P124_REAL_RTL_QUALIFICATION_{info['status']}: "
          f"previous={info['p123_status']} new={info['p124_status']} "
          f"qualified={info['qualified']}")
    return code

if __name__=='__main__':sys.exit(main())
