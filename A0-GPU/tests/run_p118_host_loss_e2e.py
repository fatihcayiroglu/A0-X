#!/usr/bin/env python3
"""P118 real two-frame host graph integration; exit 2 if simulator absent."""
from pathlib import Path
import shutil,subprocess,sys,tempfile
ROOT=Path(__file__).resolve().parents[1]
GRAPH=ROOT/'rtl/graphics'
TB=ROOT/'tests/rtl/a0_host_telemetry_loss_e2e_p118_tb.sv'
from run_p106_extended_host import FILES
SOURCES=[f for f in FILES if f!='a0_host_fragment_dual_bank_bridge_p106.sv']+[
'a0_scanout_telemetry_loss_fifo_p118.sv',
'a0_host_fragment_dual_bank_bridge_p118.sv']
MARKER='P118_REAL_RTL_HOST_LOSS_E2E_PASS'

def run():
    if not (shutil.which('iverilog') and shutil.which('vvp')):
        print('P118_REAL_RTL_HOST_E2E_NOT_RUN: iverilog/vvp absent; exit=2',flush=True)
        return 2
    with tempfile.TemporaryDirectory(prefix='a0_p118_e2e_') as d:
        exe=Path(d)/'e2e.vvp'
        try:
            c=subprocess.run(['iverilog','-g2012','-Wall','-s',TB.stem,'-o',str(exe),
                  *[str(GRAPH/x) for x in SOURCES],str(TB)],capture_output=True,text=True,timeout=120)
            print('COMPILE_EXIT',c.returncode,c.stdout,c.stderr,flush=True)
            if c.returncode or not exe.is_file():return 1
            s=subprocess.run(['vvp',str(exe)],capture_output=True,text=True,timeout=180)
            print('SIM_EXIT',s.returncode,s.stdout,s.stderr,flush=True)
            if s.returncode or s.stdout.count(MARKER)!=1 or 'FATAL:' in s.stdout+s.stderr:return 1
            print('P118_REAL_RTL_HOST_E2E_QUALIFIED_PASS',flush=True)
            return 0
        except (OSError,subprocess.TimeoutExpired) as exc:
            print('P118_REAL_RTL_HOST_E2E_FAILURE',repr(exc),flush=True)
            return 1
if __name__=='__main__':sys.exit(run())
