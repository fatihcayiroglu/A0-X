#!/usr/bin/env python3
"""P117 complete bytes->pixels->frame CRC->FIFO RTL qualification gate.

0 = real Icarus simulation passed; 1 = real failure; 2 = not run.
"""
from pathlib import Path
import shutil
import subprocess
import sys
import tempfile

ROOT = Path(__file__).resolve().parents[1]
GRAPH = ROOT / 'rtl' / 'graphics'
TB = ROOT / 'tests' / 'rtl' / 'a0_host_telemetry_fifo_e2e_p117_tb.sv'
from run_p106_extended_host import FILES
SOURCES = [f for f in FILES if f != 'a0_host_fragment_dual_bank_bridge_p106.sv'] + [
    'a0_scanout_telemetry_fifo_p117.sv',
    'a0_host_fragment_dual_bank_bridge_p117.sv'
]
MARKER='P117_REAL_RTL_HOST_FIFO_E2E_PASS'


def run():
    if not (shutil.which('iverilog') and shutil.which('vvp')):
        print('P117_HOST_FIFO_E2E_REAL_RTL_NOT_RUN: iverilog/vvp absent; exit=2', flush=True)
        return 2
    with tempfile.TemporaryDirectory(prefix='a0_p117_e2e_') as folder:
        exe = Path(folder) / 'p117_e2e.vvp'
        args = ['iverilog','-g2012','-Wall','-s',TB.stem,'-o',str(exe),
                *[str(GRAPH/x) for x in SOURCES],str(TB)]
        try:
            c=subprocess.run(args,capture_output=True,text=True,timeout=120)
            print('P117_E2E_COMPILE_EXIT',c.returncode,flush=True)
            print(c.stdout+c.stderr,flush=True)
            if c.returncode or not exe.is_file():return 1
            s=subprocess.run(['vvp',str(exe)],capture_output=True,text=True,timeout=180)
            print('P117_E2E_SIM_EXIT',s.returncode,flush=True)
            print(s.stdout+s.stderr,flush=True)
            if s.returncode or s.stdout.count(MARKER)!=1 or 'FATAL:' in (s.stdout+s.stderr):return 1
            print('P117_HOST_FIFO_E2E_REAL_RTL_PASS',flush=True)
            return 0
        except (OSError,subprocess.TimeoutExpired) as exc:
            print('P117_HOST_FIFO_E2E_REAL_RTL_FAIL',repr(exc),flush=True)
            return 1


if __name__=='__main__': sys.exit(run())
