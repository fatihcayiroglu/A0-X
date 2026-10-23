#!/usr/bin/env python3
"""Fail-closed P103 HDL integration gate, requires real Icarus+vvp."""
import argparse
import shutil
import subprocess
import sys
import tempfile
from pathlib import Path

ROOT=Path(__file__).resolve().parents[1]
GRAPHICS=ROOT/'rtl'/'graphics'
RTL=[
    'a0_graphics_command_frontend_p43.sv',
    'a0_triangle_coverage_p38.sv',
    'a0_p59_scissor_coverage.sv',
    'a0_p68_depth_compare.sv',
    'a0_p70_rgb_blend.sv',
    'a0_triangle_scissor_depth_blend_p102.sv',
    'a0_sync_frame_scanout_p42.sv',
    'a0_command_pixel_scanout_p103.sv'
]
TB=ROOT/'tests'/'rtl'/'a0_command_pixel_scanout_p103_tb.sv'

def run():
    if not shutil.which('iverilog') or not shutil.which('vvp'):
        print('P103_REAL_RTL_NOT_RUN: iverilog/vvp absent; not qualified',flush=True)
        return 2
    with tempfile.TemporaryDirectory(prefix='a0_p103_hdl_') as d:
        out=Path(d)/'p103.vvp'
        compile_cmd=['iverilog','-g2012','-Wall','-s','a0_command_pixel_scanout_p103_tb',
                     '-o',str(out),*(str(GRAPHICS/f) for f in RTL),str(TB)]
        result=subprocess.run(compile_cmd,capture_output=True,text=True)
        print('P103 compile status',result.returncode)
        print(result.stdout+result.stderr)
        if result.returncode: return 1
        result=subprocess.run(['vvp',str(out)],capture_output=True,text=True,timeout=60)
        print('P103 simulation status',result.returncode)
        print(result.stdout+result.stderr)
        if result.returncode or 'P103_REAL_RTL_PASS' not in result.stdout:
            return 1
        return 0

if __name__=='__main__':
    try: sys.exit(run())
    except subprocess.TimeoutExpired:
        print('P103_REAL_RTL_TIMEOUT: not qualified',flush=True)
        sys.exit(1)
