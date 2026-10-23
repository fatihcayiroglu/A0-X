#!/usr/bin/env python3
"""P111 real Icarus gate: compile integrated top, simulate monitor TB; fail closed."""
from pathlib import Path
import shutil
import subprocess
import sys
import tempfile

ROOT=Path(__file__).resolve().parents[1]
sys.path.insert(0,str(ROOT/'tests'))
from run_p106_extended_host import FILES as P106_RTL
GRAPH=ROOT/'rtl'/'graphics'
MON=GRAPH/'a0_command_completion_watchdog_p111.sv'
TOP=GRAPH/'a0_host_fragment_dual_bank_diagnostics_p111.sv'
TB=ROOT/'tests'/'rtl'/'a0_command_completion_watchdog_p111_tb.sv'

def command(args,timeout=90):
    proc=subprocess.run(args,stdout=subprocess.PIPE,stderr=subprocess.STDOUT,
                        text=True,timeout=timeout)
    print(proc.stdout,end='')
    return proc.returncode

def run():
    if not (shutil.which('iverilog') and shutil.which('vvp')):
        print('P111_REAL_RTL_NOT_RUN: iverilog/vvp unavailable; exit 2')
        return 2
    with tempfile.TemporaryDirectory(prefix='a0_p111_') as tmp:
        executable=Path(tmp)/'monitor.vvp'
        if command(['iverilog','-g2012','-Wall','-s',TB.stem,
                    '-o',str(executable),str(MON),str(TB)]): return 1
        if command(['vvp',str(executable)]):return 1
        # Elaboration covers the P106->P111 integration, no simulation claim.
        sources=[GRAPH/x for x in P106_RTL]
        if command(['iverilog','-g2012','-Wall','-s',TOP.stem,'-o',str(Path(tmp)/'top.vvp'),
                    *map(str,sources),str(MON),str(TOP)]):return 1
        print('P111_REAL_RTL_PASS: diagnostic monitor simulated; integrated top elaborated')
        return 0

if __name__=='__main__':
    try:sys.exit(run())
    except (OSError,subprocess.TimeoutExpired) as exc:
        print('P111_REAL_RTL_FAILURE:',exc)
        sys.exit(1)
