"""P41 strict test gate. Never reports RTL PASS from Python or parser-only tests."""
import argparse
import shutil
import subprocess
import sys
import tempfile
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
FILES = [ROOT / 'rtl' / 'graphics' / name for name in (
    'a0_triangle_coverage_p38.sv',
    'a0_triangle_framebuffer_p39.sv',
    'a0_frame_scanout_p40.sv',
    'a0_triangle_double_buffer_display_p41.sv',
)]
TB = ROOT / 'tests' / 'rtl' / 'a0_triangle_double_buffer_display_p41_tb.sv'


def main():
    p = argparse.ArgumentParser()
    p.add_argument('--python-only', action='store_true', help='run only reference-model tests (NOT RTL)')
    args = p.parse_args()
    suite = unittest.defaultTestLoader.discover(str(ROOT / 'tests'), pattern='test_p41_double_buffer.py')
    result = unittest.TextTestRunner(verbosity=2).run(suite)
    if not result.wasSuccessful():
        return 1
    print(f'P41 PYTHON REFERENCE PASS ({result.testsRun} tests)', flush=True)
    if args.python_only:
        print('P41 RTL NOT_RUN (--python-only)', flush=True)
        return 0
    with tempfile.TemporaryDirectory(prefix='a0_p41_') as work:
        if shutil.which('iverilog') and shutil.which('vvp'):
            target = str(Path(work) / 'p41.vvp')
            build = ['iverilog', '-g2012', '-s', 'a0_triangle_double_buffer_display_p41_tb',
                     '-o', target, *(str(x) for x in FILES), str(TB)]
            execute = ['vvp', target]
        elif shutil.which('verilator'):
            obj = Path(work) / 'obj'
            build = ['verilator', '--binary', '--timing', '--top-module',
                     'a0_triangle_double_buffer_display_p41_tb', '--Mdir', str(obj),
                     *(str(x) for x in FILES), str(TB)]
            execute = [str(obj / 'Va0_triangle_double_buffer_display_p41_tb')]
        else:
            print('P41 RTL BLOCKED: no complete HDL simulation toolchain available', flush=True)
            return 2
        print('P41 HDL build:', ' '.join(build), flush=True)
        if subprocess.run(build).returncode:
            print('P41 HDL BUILD FAIL', flush=True)
            return 1
        if subprocess.run(execute).returncode:
            print('P41 HDL SIM FAIL', flush=True)
            return 1
        print('P41 HDL SIM PASS', flush=True)
        return 0


if __name__ == '__main__':
    sys.exit(main())
