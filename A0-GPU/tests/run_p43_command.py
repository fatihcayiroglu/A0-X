"""P43 reference + full HDL: strict gate returns BLOCKED if no simulator.

--python-only explicitly indicates behavioral RTL has NOT been executed.
"""
import argparse
import shutil
import subprocess
import sys
import tempfile
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
SOURCES = [ROOT/'rtl'/'graphics'/n for n in (
    'a0_triangle_coverage_p38.sv', 'a0_sync_frame_ram_p42.sv',
    'a0_sync_frame_scanout_p42.sv', 'a0_triangle_double_buffer_sync_display_p42.sv',
    'a0_graphics_command_frontend_p43.sv','a0_command_triangle_sync_display_p43.sv')]
TOP='a0_command_triangle_sync_display_p43_tb'
TB=ROOT/'tests'/'rtl'/f'{TOP}.sv'

def main():
    ap=argparse.ArgumentParser()
    ap.add_argument('--python-only',action='store_true')
    args=ap.parse_args()
    suite=unittest.defaultTestLoader.discover(str(ROOT/'tests'),pattern='test_p43_graphics_command.py')
    result=unittest.TextTestRunner(verbosity=2).run(suite)
    if not result.wasSuccessful():return 1
    print(f'P43 Python REFERENCE PASS {result.testsRun}; RTL NOT YET VERIFIED',flush=True)
    if args.python_only:return 0
    with tempfile.TemporaryDirectory(prefix='p43_rtl_') as tmp:
        if shutil.which('iverilog') and shutil.which('vvp'):
            output=Path(tmp)/'sim.vvp'
            build=['iverilog','-g2012','-s',TOP,'-o',str(output),*map(str,SOURCES),str(TB)]
            run=['vvp',str(output)]
        elif shutil.which('verilator'):
            obj=Path(tmp)/'obj'
            build=['verilator','--binary','--timing','--top-module',TOP,
                   '--Mdir',str(obj),*map(str,SOURCES),str(TB)]
            run=[str(obj/f'V{TOP}')]
        else:
            print('P43 HDL BLOCKED: no complete simulator/runtime installed',flush=True)
            return 2
        if subprocess.run(build).returncode != 0:return 1
        if subprocess.run(run).returncode != 0:return 1
        print('P43 HDL BEHAVIOR PASS',flush=True)
    return 0

if __name__=='__main__':sys.exit(main())
