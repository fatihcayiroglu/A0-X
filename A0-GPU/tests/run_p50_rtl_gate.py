#!/usr/bin/env python3
"""P50 executable simulation gate: P45..P49 regressions then P50 pin trace.

Exit 0 only if a real simulator ran and passed all required suites.
Exit 2 if no simulator. Exit 1 for failure in any required suite.
"""
import argparse
import json
from pathlib import Path
import shutil
import subprocess
import sys
import tempfile
from datetime import datetime, timezone

ROOT = Path(__file__).resolve().parents[1]
G = ROOT / 'rtl' / 'graphics'
TB = ROOT / 'tests' / 'rtl' / 'a0_host_tx_fair_arbiter_p50_trace_tb.sv'
RTL = G / 'a0_host_tx_fair_arbiter_p49.sv'
SCRIPTS = [ROOT / 'tests' / f'run_p{i}_{suffix}.py' for i,suffix in [
    (45,'host_rx'),(46,'host_bridge'),(47,'frame_integrity'),
    (48,'host_telemetry'),(49,'fair_transport')]]


def main(argv=None):
    ap=argparse.ArgumentParser()
    ap.add_argument('--receipt',type=Path)
    ap.add_argument('--seed',type=int,default=50050)
    ap.add_argument('--cycles',type=int,default=6000)
    args=ap.parse_args(argv)
    receipt={'kind':'P50_ACTUAL_RTL_GATE','status':'NOT_RUN',
             'checked_at_utc':datetime.now(timezone.utc).isoformat(),
             'suite_results':[], 'note':'No performance or FPGA claim'}
    def save():
        if args.receipt:
            args.receipt.parent.mkdir(parents=True,exist_ok=True)
            args.receipt.write_text(json.dumps(receipt,indent=2,sort_keys=True)+'\n')
    backend = 'iverilog' if shutil.which('iverilog') and shutil.which('vvp') else (
        'verilator' if shutil.which('verilator') else None)
    if backend is None:
        receipt['reason']='Icarus and Verilator not installed';save()
        print('P50 RTL NOT RUN: no genuine HDL simulator (exit 2)',file=sys.stderr)
        return 2
    receipt['backend']=backend
    try:
        version=subprocess.run([backend,'--version' if backend=='verilator' else '-V'],
                               text=True,capture_output=True,check=False)
        receipt['tool_version']=(version.stdout or version.stderr).splitlines()[0]
        with tempfile.TemporaryDirectory(prefix='a0_p50_rtl_') as td:
            td=Path(td)
            trace=td/'trace.txt';summary=td/'trace.json'
            steps=[[sys.executable,str(ROOT/'tools'/'a0_fair_trace_p50.py'),
                    '--out',str(trace),'--summary',str(summary),
                    '--seed',str(args.seed),'--cycles',str(args.cycles)]]
            for s in SCRIPTS:
                steps.append([sys.executable,str(s)])
            if backend=='iverilog':
                binary=td/'p50_trace.vvp'
                steps.append(['iverilog','-g2012','-s','a0_host_tx_fair_arbiter_p50_trace_tb',
                              '-o',str(binary),str(RTL),str(TB)])
                steps.append(['vvp',str(binary),'+TRACE='+str(trace)])
            else:
                obj=td/'obj_dir'
                steps.append(['verilator','--binary','--timing','--assert',
                              '--top-module','a0_host_tx_fair_arbiter_p50_trace_tb',
                              '--Mdir',str(obj),str(RTL),str(TB)])
                steps.append([str(obj/'Va0_host_tx_fair_arbiter_p50_trace_tb'),
                              '+TRACE='+str(trace)])
            for step in steps:
                print('+',' '.join(step),flush=True)
                r=subprocess.run(step,cwd=ROOT,check=False)
                receipt['suite_results'].append({'command':step,'exit_code':r.returncode})
                if r.returncode != 0:
                    receipt.update(status='FAIL',failed_command=step);save()
                    return 1
            receipt['trace_summary']=json.loads(summary.read_text())
            receipt['status']='PASS'
            save()
            print('P50 RTL GATE PASS: all inherited RTL gates and cycle trace',flush=True)
            return 0
    except (OSError,ValueError) as exc:
        receipt.update(status='FAIL',reason=str(exc));save()
        print('P50 RTL gate failed: '+str(exc),file=sys.stderr)
        return 1


if __name__=='__main__':
    sys.exit(main())
