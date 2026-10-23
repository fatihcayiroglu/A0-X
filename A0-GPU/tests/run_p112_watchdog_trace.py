#!/usr/bin/env python3
"""P112 fail-closed HDL gate: verify vectors, compile P111 RTL, run exact trace."""
from pathlib import Path
from hashlib import sha256
import json
import shutil
import subprocess
import sys
import tempfile

ROOT=Path(__file__).resolve().parents[1]
SIM=ROOT/'sim'
sys.path.insert(0,str(SIM))
from a0_p112_watchdog_trace import CYCLES, COLUMNS, MAX_WAIT, parse_and_replay
TRACE=ROOT/'tests'/'vectors'/'p112_watchdog_4096.hex'
META=TRACE.with_suffix('.json')
MON=ROOT/'rtl'/'graphics'/'a0_command_completion_watchdog_p111.sv'
TB=ROOT/'tests'/'rtl'/'a0_command_completion_watchdog_p112_trace_tb.sv'

def run() -> int:
    blob=TRACE.read_bytes()
    meta=json.loads(META.read_text())
    stats=parse_and_replay(blob,max_wait=MAX_WAIT)
    if (meta.get('sha256')!=sha256(blob).hexdigest() or
        meta.get('cycles')!=CYCLES or meta.get('max_wait_cycles')!=MAX_WAIT or
        meta.get('columns')!=list(COLUMNS) or meta.get('coverage')!=stats):
        print('P112_TRACE_METADATA_MISMATCH: refuse RTL qualification')
        return 1
    print('P112_PYTHON_TRACE_ORACLE_PASS',len(blob.splitlines()),'cycles',flush=True)
    if not shutil.which('iverilog') or not shutil.which('vvp'):
        print('P112_REAL_RTL_NOT_RUN: iverilog/vvp unavailable; exit 2',flush=True)
        return 2
    try:
        with tempfile.TemporaryDirectory(prefix='a0_p112_') as tmp:
            exe=Path(tmp)/'p112_watchdog.vvp'
            build=['iverilog','-g2012','-Wall','-s',TB.stem,'-o',str(exe),str(MON),str(TB)]
            proc=subprocess.run(build,stdout=subprocess.PIPE,stderr=subprocess.STDOUT,
                                text=True,timeout=90)
            print(proc.stdout,end='',flush=True)
            if proc.returncode:
                print('P112_RTL_COMPILE_FAIL',proc.returncode)
                return 1
            proc=subprocess.run(['vvp',str(exe),'+TRACE='+str(TRACE)],stdout=subprocess.PIPE,
                                stderr=subprocess.STDOUT,text=True,timeout=90)
            print(proc.stdout,end='',flush=True)
            if proc.returncode or 'P112_WATCHDOG_RTL_CYCLE_TRACE_PASS cycles=4096' not in proc.stdout:
                print('P112_RTL_SIM_FAIL',proc.returncode)
                return 1
            print('P112_REAL_RTL_PASS: compiled P111 RTL compared for 4096 clock cycles')
            return 0
    except (OSError,subprocess.TimeoutExpired) as exc:
        print('P112_REAL_RTL_FAILURE',type(exc).__name__,str(exc))
        return 1

if __name__=='__main__':
    try:raise SystemExit(run())
    except (ValueError,KeyError,FileNotFoundError,json.JSONDecodeError) as exc:
        print('P112_FAIL_CLOSED',type(exc).__name__,str(exc))
        raise SystemExit(1)
