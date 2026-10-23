"""Strict P40 independent Python oracle and RTL integration gate.

Exit 0 only if BOTH Python and real RTL simulation pass. Exit 2 if the
necessary HDL toolchain is missing; no synthetic fallback is permitted.
"""
import argparse
import shutil
import subprocess
import sys
import tempfile
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
RTL_DIR = ROOT / 'rtl' / 'graphics'
RTL = [RTL_DIR / f for f in (
    'a0_triangle_coverage_p38.sv', 'a0_triangle_framebuffer_p39.sv',
    'a0_frame_scanout_p40.sv', 'a0_triangle_display_p40.sv')]
TB = ROOT / 'tests' / 'rtl' / 'a0_triangle_display_p40_tb.sv'


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument('--python-only', action='store_true')
    args = ap.parse_args()
    suite = unittest.defaultTestLoader.discover(str(ROOT / 'tests'), pattern='test_p40_frame_scanout.py')
    res = unittest.TextTestRunner(verbosity=2).run(suite)
    if not res.wasSuccessful():
        return 1
    print('P40 PYTHON PASS',flush=True)
    if args.python_only:
        print('P40 RTL NOT_RUN (--python-only)',flush=True)
        return 0
    with tempfile.TemporaryDirectory(prefix='a0_p40_') as temp:
        if shutil.which('iverilog') and shutil.which('vvp'):
            exe = Path(temp) / 'p40.vvp'
            build = ['iverilog','-g2012','-s','a0_triangle_display_p40_tb','-o',str(exe),*(str(r) for r in RTL),str(TB)]
            execute = ['vvp',str(exe)]
        elif shutil.which('verilator'):
            mdir = Path(temp) / 'obj'
            build = ['verilator','--binary','--timing','--top-module','a0_triangle_display_p40_tb','--Mdir',str(mdir),*(str(r) for r in RTL),str(TB)]
            execute = [str(mdir / 'Va0_triangle_display_p40_tb')]
        else:
            print('P40 RTL BLOCKED: no complete HDL simulator on PATH',flush=True)
            return 2
        print('P40 BUILD:', ' '.join(build),flush=True)
        if subprocess.run(build,check=False).returncode:
            print('P40 HDL BUILD FAIL',flush=True)
            return 1
        print('P40 EXEC:', ' '.join(execute),flush=True)
        if subprocess.run(execute,check=False).returncode:
            print('P40 HDL SIM FAIL',flush=True)
            return 1
        print('P40 HDL SIM PASS',flush=True)
        return 0


if __name__=='__main__':
    raise SystemExit(main())
