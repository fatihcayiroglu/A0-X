#!/usr/bin/env python3
"""P105 RTL qualification gate; absent simulator is NOT RUN, exit 2."""
import shutil
import subprocess
import sys
import tempfile
from pathlib import Path

ROOT=Path(__file__).resolve().parents[1]
G=ROOT/'rtl'/'graphics'
FILES=['a0_graphics_command_frontend_p43.sv','a0_triangle_coverage_p38.sv',
       'a0_p59_scissor_coverage.sv','a0_p68_depth_compare.sv',
       'a0_p70_rgb_blend.sv','a0_triangle_scissor_depth_blend_p102.sv',
       'a0_sync_frame_scanout_p42.sv','a0_command_dual_bank_scanout_p104.sv',
       'a0_host_command_rx_p45.sv','a0_host_result_tx_p46.sv',
       'a0_scanout_frame_guard_p47.sv','a0_scanout_telemetry_tx_p48.sv',
       'a0_host_tx_fair_arbiter_p49.sv',
       'a0_host_dual_bank_telemetry_bridge_p105.sv']
TB=ROOT/'tests'/'rtl'/'a0_host_dual_bank_telemetry_bridge_p105_tb.sv'

def run():
    if not (shutil.which('iverilog') and shutil.which('vvp')):
        print('P105_REAL_RTL_NOT_RUN: iverilog and vvp required; no inferred PASS',flush=True)
        return 2
    with tempfile.TemporaryDirectory(prefix='a0_p105_') as directory:
        exe=Path(directory)/'tb.vvp'
        compile=['iverilog','-g2012','-Wall','-s',TB.stem,'-o',str(exe),
                 *[str(G/x) for x in FILES],str(TB)]
        cp=subprocess.run(compile,capture_output=True,text=True,timeout=90)
        print('P105_COMPILE_EXIT',cp.returncode,flush=True)
        print(cp.stdout+cp.stderr,flush=True)
        if cp.returncode:return 1
        sim=subprocess.run(['vvp',str(exe)],capture_output=True,text=True,timeout=90)
        print('P105_SIM_EXIT',sim.returncode,flush=True)
        print(sim.stdout+sim.stderr,flush=True)
        return 0 if sim.returncode==0 and 'P105_REAL_RTL_PASS' in sim.stdout else 1

if __name__=='__main__':
    try:sys.exit(run())
    except (OSError,subprocess.TimeoutExpired) as exc:
        print('P105_REAL_RTL_FAILED_OR_TIMED_OUT:',exc,flush=True)
        sys.exit(1)
