#!/usr/bin/env python3
"""P104 Icarus RTL qualification; no simulator => status NOT RUN (exit 2)."""
import shutil
import subprocess
import sys
import tempfile
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
G = ROOT/'rtl'/'graphics'
FILES = ['a0_graphics_command_frontend_p43.sv',
         'a0_triangle_coverage_p38.sv',
         'a0_p59_scissor_coverage.sv',
         'a0_p68_depth_compare.sv',
         'a0_p70_rgb_blend.sv',
         'a0_triangle_scissor_depth_blend_p102.sv',
         'a0_sync_frame_scanout_p42.sv',
         'a0_command_dual_bank_scanout_p104.sv']
TB = ROOT/'tests'/'rtl'/'a0_command_dual_bank_scanout_p104_tb.sv'

def run():
    if not shutil.which('iverilog') or not shutil.which('vvp'):
        print('P104_REAL_RTL_NOT_RUN: requires iverilog and vvp (no inferred PASS)',flush=True)
        return 2
    with tempfile.TemporaryDirectory(prefix='a0_p104_') as d:
        exe=Path(d)/'tb.vvp'
        args=['iverilog','-g2012','-Wall','-s','a0_command_dual_bank_scanout_p104_tb',
              '-o',str(exe),*[str(G/f) for f in FILES],str(TB)]
        p=subprocess.run(args,capture_output=True,text=True,timeout=60)
        print('P104_COMPILE_EXIT',p.returncode,flush=True)
        print(p.stdout+p.stderr,flush=True)
        if p.returncode:return 1
        p=subprocess.run(['vvp',str(exe)],capture_output=True,text=True,timeout=60)
        print('P104_SIM_EXIT',p.returncode,flush=True)
        print(p.stdout+p.stderr,flush=True)
        if p.returncode or 'P104_REAL_RTL_PASS' not in p.stdout:return 1
    return 0
if __name__=='__main__':
    try:sys.exit(run())
    except (subprocess.TimeoutExpired,OSError) as e:
        print('P104_RTL_FAILED_OR_TIMED_OUT:',str(e),flush=True)
        sys.exit(1)
