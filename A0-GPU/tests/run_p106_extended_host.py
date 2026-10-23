#!/usr/bin/env python3
"""P106 mandatory real Icarus RTL compile/run. Absence is NOT RUN (exit 2)."""
import shutil
import subprocess
import sys
import tempfile
from pathlib import Path
ROOT=Path(__file__).resolve().parents[1]
GRAPH=ROOT/'rtl'/'graphics'
FILES=[
 'a0_graphics_command_frontend_p43.sv','a0_triangle_coverage_p38.sv',
 'a0_p59_scissor_coverage.sv','a0_p68_depth_compare.sv',
 'a0_p70_rgb_blend.sv','a0_triangle_scissor_depth_blend_p102.sv',
 'a0_sync_frame_scanout_p42.sv','a0_command_dual_bank_scanout_p104.sv',
 'a0_host_command_rx_p106.sv','a0_host_result_tx_p46.sv',
 'a0_scanout_frame_guard_p47.sv','a0_scanout_telemetry_tx_p48.sv',
 'a0_host_tx_fair_arbiter_p49.sv',
 'a0_host_fragment_dual_bank_bridge_p106.sv'
]
TB=ROOT/'tests'/'rtl'/'a0_host_fragment_dual_bank_bridge_p106_tb.sv'

def run():
    if not (shutil.which('iverilog') and shutil.which('vvp')):
        print('P106_REAL_RTL_NOT_RUN: iverilog and vvp missing; exit 2')
        return 2
    with tempfile.TemporaryDirectory(prefix='a0_p106_') as t:
        executable=Path(t)/'tb.vvp'
        compile_result=subprocess.run(['iverilog','-g2012','-Wall','-s',TB.stem,
            '-o',str(executable),*[str(GRAPH/x) for x in FILES],str(TB)],
            capture_output=True,text=True,timeout=90)
        print('P106_COMPILE_EXIT',compile_result.returncode)
        print(compile_result.stdout,compile_result.stderr)
        if compile_result.returncode:return 1
        simulation=subprocess.run(['vvp',str(executable)],capture_output=True,text=True,timeout=120)
        print('P106_SIM_EXIT',simulation.returncode)
        print(simulation.stdout,simulation.stderr)
        if simulation.returncode:return 1
        return 0 if 'P106_REAL_RTL_PASS' in simulation.stdout else 1

if __name__=='__main__':
    try:sys.exit(run())
    except (OSError,subprocess.TimeoutExpired) as exc:
        print('P106_REAL_RTL_FAILURE',str(exc))
        sys.exit(1)
