"""P38 standalone gate: oracle always, RTL only when a real tool exists.

An absent or failing RTL simulator makes the full gate fail. It never reports
an RTL PASS based solely on the Python model.
"""
import argparse
import shutil
import subprocess
import sys
import tempfile
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
RTL = ROOT / 'rtl' / 'graphics' / 'a0_triangle_coverage_p38.sv'
TB = ROOT / 'tests' / 'rtl' / 'a0_triangle_coverage_p38_tb.sv'
PYTEST = ROOT / 'tests' / 'test_p38_triangle_coverage.py'


def main() -> int:
    p = argparse.ArgumentParser()
    p.add_argument('--python-only', action='store_true',
                   help='Run Python contract tests only; does not qualify RTL')
    args = p.parse_args()
    print('P38 Python oracle:', flush=True)
    python = subprocess.run([sys.executable, str(PYTEST)], check=False)
    if python.returncode:
        print('P38 PYTHON FAIL', flush=True)
        return 1
    print('P38 PYTHON PASS', flush=True)
    if args.python_only:
        print('P38 RTL NOT_RUN (--python-only)', flush=True)
        return 0
    with tempfile.TemporaryDirectory(prefix='a0_p38_') as d:
        if shutil.which('iverilog') and shutil.which('vvp'):
            out = Path(d) / 'sim.vvp'
            build = ['iverilog', '-g2012', '-s', 'a0_triangle_coverage_p38_tb',
                     '-o', str(out), str(RTL), str(TB)]
            execute = ['vvp', str(out)]
        elif shutil.which('verilator'):
            build = ['verilator', '--binary', '--timing',
                     '--top-module', 'a0_triangle_coverage_p38_tb',
                     '--Mdir', str(Path(d) / 'obj'), str(RTL), str(TB)]
            execute = [str(Path(d) / 'obj' / 'Va0_triangle_coverage_p38_tb')]
        else:
            print('P38 RTL BLOCKED: neither iverilog/vvp nor verilator installed', flush=True)
            return 2
        print('P38 RTL build:', ' '.join(build), flush=True)
        r = subprocess.run(build, check=False)
        if r.returncode:
            print('P38 RTL BUILD FAIL', flush=True)
            return 1
        print('P38 RTL simulation:', ' '.join(execute), flush=True)
        r = subprocess.run(execute, check=False)
        if r.returncode:
            print('P38 RTL SIM FAIL', flush=True)
            return 1
        print('P38 RTL SIM PASS', flush=True)
    return 0


if __name__ == '__main__':
    raise SystemExit(main())
