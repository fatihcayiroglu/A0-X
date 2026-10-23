#!/usr/bin/env python3
"""Fail-closed real P113 RTL simulation + elaboration of P106 datapath wrapper."""
from pathlib import Path
import shutil, subprocess, sys, tempfile

ROOT=Path(__file__).resolve().parents[1]
GRAPH=ROOT/'rtl'/'graphics'
TB=ROOT/'tests/rtl/a0_command_progress_watchdog_p113_tb.sv'
MON=GRAPH/'a0_command_progress_watchdog_p113.sv'
TOP=GRAPH/'a0_host_fragment_dual_bank_diagnostics_p113.sv'
sys.path.insert(0,str(ROOT/'tests'))
from run_p106_extended_host import FILES as P106_RTL
MARKER='P113_REAL_RTL_PROGRESS_WATCHDOG_PASS'

def command(cmd,timeout=120):
    p=subprocess.run(cmd,stdout=subprocess.PIPE,stderr=subprocess.STDOUT,
                     text=True,timeout=timeout)
    print(p.stdout,end='',flush=True)
    return p

def run():
    if not (shutil.which('iverilog') and shutil.which('vvp')):
        print('P113_REAL_RTL_NOT_RUN: iverilog/vvp missing (exit 2)',flush=True)
        return 2
    with tempfile.TemporaryDirectory(prefix='a0_p113_') as tmp:
        tmp=Path(tmp)
        bench=tmp/'p113.vvp';top=tmp/'p113-top.vvp'
        if command(['iverilog','-g2012','-Wall','-s',TB.stem,'-o',str(bench),str(MON),str(TB)]).returncode:
            print('P113_COMPILE_FAILURE');return 1
        p=command(['vvp',str(bench)])
        if p.returncode or MARKER not in p.stdout:
            print('P113_SIMULATION_FAILURE');return 1
        sources=[str(GRAPH/x) for x in P106_RTL]
        p=command(['iverilog','-g2012','-Wall','-s',TOP.stem,
                   '-o',str(top),*sources,str(MON),str(TOP)])
        if p.returncode:
            print('P113_INTEGRATION_ELABORATION_FAILURE');return 1
        print('P113_REAL_RTL_PASS: watchdog simulated, P113 top elaborated')
        return 0

if __name__=='__main__':
    try: sys.exit(run())
    except (OSError,subprocess.TimeoutExpired) as e:
        print('P113_REAL_RTL_FAILURE',e)
        sys.exit(1)
