#!/usr/bin/env python3
"""P118 REAL Icarus gate: 0=HDL passed, 1=failed, 2=NOT RUN."""
from pathlib import Path
import shutil,subprocess,sys,tempfile
ROOT=Path(__file__).resolve().parents[1]
TB=ROOT/'tests/rtl/a0_telemetry_loss_fifo_p118_tb.sv'
SOURCE=ROOT/'rtl/graphics/a0_scanout_telemetry_loss_fifo_p118.sv'
MARKER='P118_REAL_RTL_LOSS_NOTICE_PASS'

def run():
    if not (shutil.which('iverilog') and shutil.which('vvp')):
        print('P118_REAL_RTL_LOSS_NOTICE_NOT_RUN: iverilog/vvp absent; exit=2',flush=True)
        return 2
    with tempfile.TemporaryDirectory(prefix='a0_p118_') as d:
        exe=Path(d)/'loss.vvp'
        try:
            c=subprocess.run(['iverilog','-g2012','-Wall','-s',TB.stem,'-o',str(exe),str(SOURCE),str(TB)],capture_output=True,text=True,timeout=90)
            print('COMPILE_EXIT',c.returncode,c.stdout,c.stderr,flush=True)
            if c.returncode or not exe.is_file():return 1
            s=subprocess.run(['vvp',str(exe)],capture_output=True,text=True,timeout=120)
            print('SIM_EXIT',s.returncode,s.stdout,s.stderr,flush=True)
            if s.returncode or s.stdout.count(MARKER)!=1 or 'FATAL:' in s.stdout+s.stderr:return 1
            print('P118_REAL_RTL_LOSS_NOTICE_QUALIFIED_PASS',flush=True)
            return 0
        except (OSError,subprocess.TimeoutExpired) as exc:
            print('P118_REAL_RTL_FAILURE',repr(exc),flush=True)
            return 1
if __name__=='__main__':sys.exit(run())
