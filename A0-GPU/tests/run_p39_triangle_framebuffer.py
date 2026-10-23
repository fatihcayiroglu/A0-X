"""Run P39 Python tests and actual RTL simulation if available. Exit 2 if blocked."""
import shutil
import subprocess
import sys
import tempfile
from pathlib import Path

BASE = Path(__file__).resolve().parents[1]
TEST = BASE / 'tests' / 'test_p39_triangle_framebuffer.py'
RTL = [BASE / 'rtl' / 'graphics' / n for n in (
    'a0_triangle_coverage_p38.sv', 'a0_triangle_framebuffer_p39.sv')]
TB = BASE / 'tests' / 'rtl' / 'a0_triangle_framebuffer_p39_tb.sv'


def main():
    print('P39 Python model tests:', flush=True)
    result = subprocess.run([sys.executable, str(TEST)], check=False)
    if result.returncode:
        print('P39 Python FAIL', flush=True)
        return 1
    print('P39 Python PASS', flush=True)
    if '--python-only' in sys.argv:
        print('P39 RTL NOT_RUN (--python-only)', flush=True)
        return 0
    with tempfile.TemporaryDirectory(prefix='p39_') as td:
        if shutil.which('iverilog') and shutil.which('vvp'):
            exe = str(Path(td) / 'p39.vvp')
            build = ['iverilog', '-g2012', '-s', 'a0_triangle_framebuffer_p39_tb',
                     '-o', exe, *(str(r) for r in RTL), str(TB)]
            execute = ['vvp', exe]
        elif shutil.which('verilator'):
            mdir = str(Path(td) / 'obj')
            build = ['verilator', '--binary', '--timing',
                     '--top-module', 'a0_triangle_framebuffer_p39_tb',
                     '--Mdir', mdir, *(str(r) for r in RTL), str(TB)]
            execute = [str(Path(mdir) / 'Va0_triangle_framebuffer_p39_tb')]
        else:
            print('P39 RTL BLOCKED: no Icarus/Verilator executable; RTL status NOT_RUN', flush=True)
            return 2
        print('P39 HDL build:', ' '.join(build), flush=True)
        if subprocess.run(build, check=False).returncode:
            print('P39 HDL BUILD FAIL', flush=True)
            return 1
        print('P39 HDL execution:', ' '.join(execute), flush=True)
        if subprocess.run(execute, check=False).returncode:
            print('P39 HDL SIM FAIL', flush=True)
            return 1
        print('P39 HDL PASS', flush=True)
        return 0


if __name__ == '__main__':
    raise SystemExit(main())
