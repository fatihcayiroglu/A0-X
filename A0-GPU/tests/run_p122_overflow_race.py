#!/usr/bin/env python3
"""P122 real Icarus-only overflow-race qualification: exit 2 means NOT RUN."""
from pathlib import Path
import shutil
import subprocess
import sys
import tempfile

ROOT=Path(__file__).resolve().parents[1]
MODULE=ROOT/'rtl/graphics/a0_scanout_telemetry_loss_fifo_p118.sv'
TB=ROOT/'tests/rtl/a0_p122_overflow_race_tb.sv'
MARKER='P122_REAL_RTL_OVERFLOW_RACE_PASS'

def run():
    if not (shutil.which('iverilog') and shutil.which('vvp')):
        print('P122_REAL_RTL_NOT_RUN: missing Icarus/vvp',flush=True)
        return 2
    with tempfile.TemporaryDirectory(prefix='a0_p122_real_') as folder:
        target=Path(folder)/'sim.vvp'
        try:
            built=subprocess.run(['iverilog','-g2012','-Wall','-s','a0_p122_overflow_race_tb',
                                  '-o',str(target),str(MODULE),str(TB)],
                                 capture_output=True,text=True,timeout=90)
            print('P122 COMPILE EXIT',built.returncode,built.stdout,built.stderr,flush=True)
            if built.returncode or not target.is_file():return 1
            result=subprocess.run(['vvp',str(target)],capture_output=True,text=True,timeout=120)
            print('P122 SIM EXIT',result.returncode,result.stdout,result.stderr,flush=True)
            if result.returncode or result.stdout.splitlines().count(MARKER)!=1:
                return 1
            if any(x in result.stdout+result.stderr for x in ('FATAL:', 'NOT_RUN', 'Traceback')):
                return 1
            return 0
        except (OSError,subprocess.TimeoutExpired) as exc:
            print('P122_REAL_RTL_FAILURE',repr(exc),flush=True)
            return 1

if __name__=='__main__':sys.exit(run())
