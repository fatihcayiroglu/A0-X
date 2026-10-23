"""P42 strict local gate: Python reference + REAL HDL behavior required for PASS.

Return 0 only when both succeed; return 2 when real simulator unavailable.
Noncanonical parser/lint evidence must never be treated as HDL execution.
"""
import argparse
import shutil
import subprocess
import sys
import tempfile
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
SOURCES = [ROOT / 'rtl' / 'graphics' / f for f in (
    'a0_triangle_coverage_p38.sv',
    'a0_sync_frame_ram_p42.sv',
    'a0_sync_frame_scanout_p42.sv',
    'a0_triangle_double_buffer_sync_display_p42.sv',
)]
TB = ROOT / 'tests' / 'rtl' / 'a0_triangle_double_buffer_sync_display_p42_tb.sv'
TOP = 'a0_triangle_double_buffer_sync_display_p42_tb'


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument('--python-only', action='store_true', help='reference checks only; RTL explicitly NOT_RUN')
    args = parser.parse_args()
    suite = unittest.defaultTestLoader.discover(str(ROOT / 'tests'), pattern='test_p42_sync_display.py')
    result = unittest.TextTestRunner(verbosity=2).run(suite)
    if not result.wasSuccessful():
        return 1
    print(f'P42 REFERENCE PASS ({result.testsRun} tests)', flush=True)
    if args.python_only:
        print('P42 RTL NOT_RUN (--python-only)', flush=True)
        return 0
    with tempfile.TemporaryDirectory(prefix='a0_p42_hdl_') as tmp:
        if shutil.which('iverilog') and shutil.which('vvp'):
            output = Path(tmp) / 'a0_p42.vvp'
            build = ['iverilog', '-g2012', '-s', TOP, '-o', str(output),
                     *map(str, SOURCES), str(TB)]
            run = ['vvp', str(output)]
        elif shutil.which('verilator'):
            obj_dir = Path(tmp) / 'obj'
            build = ['verilator', '--binary', '--timing', '--top-module', TOP,
                     '--Mdir', str(obj_dir), *map(str, SOURCES), str(TB)]
            run = [str(obj_dir / f'V{TOP}')]
        else:
            print('P42 RTL BLOCKED: no COMPLETE HDL simulator/runtime installed', flush=True)
            return 2
        print('P42 HDL BUILD:', ' '.join(build), flush=True)
        if subprocess.run(build).returncode != 0:
            print('P42 HDL BUILD FAIL', flush=True)
            return 1
        if subprocess.run(run).returncode != 0:
            print('P42 HDL BEHAVIOR FAIL', flush=True)
            return 1
        print('P42 HDL BEHAVIOR PASS', flush=True)
    return 0

if __name__ == '__main__':
    sys.exit(main())
