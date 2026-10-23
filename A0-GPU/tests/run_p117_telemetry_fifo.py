#!/usr/bin/env python3
"""P117 HDL gate: 0 real RTL PASS; 1 compile/sim failure; 2 NOT RUN.

Absence of real `iverilog`+`vvp` cannot be mistaken for RTL success.
"""
from pathlib import Path
import shutil
import subprocess
import sys
import tempfile

ROOT = Path(__file__).resolve().parents[1]
GRAPH = ROOT / 'rtl' / 'graphics'
TB = ROOT / 'tests' / 'rtl' / 'a0_telemetry_fifo_p117_tb.sv'
MARKER = 'P117_REAL_RTL_TELEMETRY_FIFO_PASS'


def run():
    if not (shutil.which('iverilog') and shutil.which('vvp')):
        print('P117_REAL_RTL_NOT_RUN: iverilog/vvp absent; exit=2', flush=True)
        return 2
    with tempfile.TemporaryDirectory(prefix='a0_p117_hdl_') as folder:
        exe = Path(folder) / 'p117.vvp'
        args = ['iverilog', '-g2012', '-Wall', '-s', TB.stem,
                '-o', str(exe), str(GRAPH/'a0_scanout_telemetry_fifo_p117.sv'), str(TB)]
        try:
            c = subprocess.run(args, capture_output=True, text=True, timeout=90)
            print('P117_COMPILE_EXIT', c.returncode, flush=True)
            print(c.stdout + c.stderr, flush=True)
            if c.returncode or not exe.is_file():
                print('P117_REAL_RTL_FAIL_COMPILE', flush=True)
                return 1
            s = subprocess.run(['vvp', str(exe)], capture_output=True, text=True, timeout=120)
            print('P117_SIM_EXIT', s.returncode, flush=True)
            print(s.stdout + s.stderr, flush=True)
            if s.returncode or s.stdout.count(MARKER) != 1 or 'FATAL:' in (s.stdout + s.stderr):
                print('P117_REAL_RTL_FAIL_SIM', flush=True)
                return 1
            print('P117_REAL_RTL_PASS: observed 5 complete A0GF packets', flush=True)
            return 0
        except (OSError, subprocess.TimeoutExpired) as exc:
            print('P117_REAL_RTL_FAIL', repr(exc), flush=True)
            return 1


if __name__ == '__main__':
    sys.exit(run())
