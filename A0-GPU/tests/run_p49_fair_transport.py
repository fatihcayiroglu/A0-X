#!/usr/bin/env python3
"""P49 actual RTL gate. Exit 2 when tools are unavailable; never fake PASS."""
from pathlib import Path
import shutil
import subprocess
import sys
import tempfile

ROOT = Path(__file__).resolve().parents[1]
G = ROOT/'rtl'/'graphics'
TB = ROOT/'tests'/'rtl'/'a0_host_tx_fair_arbiter_p49_tb.sv'
BASE = [G/x for x in (
    'a0_triangle_coverage_p38.sv',
    'a0_sync_frame_ram_p42.sv',
    'a0_sync_frame_scanout_p42.sv',
    'a0_triangle_double_buffer_sync_display_p42.sv',
    'a0_graphics_command_frontend_p43.sv',
    'a0_command_triangle_sync_display_p43.sv',
    'a0_host_command_rx_p45.sv',
    'a0_host_result_tx_p46.sv',
    'a0_host_graphics_bridge_p46.sv',
    'a0_scanout_frame_guard_p47.sv',
    'a0_host_graphics_crc_bridge_p47.sv',
    'a0_scanout_telemetry_tx_p48.sv',
    'a0_host_tx_fair_arbiter_p49.sv',
    'a0_host_graphics_fair_bridge_p49.sv',
)]
TOP = 'a0_host_graphics_fair_bridge_p49'
TB_TOP = 'a0_host_tx_fair_arbiter_p49_tb'


def run(command):
    print('+', ' '.join(map(str, command)), flush=True)
    return subprocess.run(command, cwd=ROOT, check=False).returncode


def main():
    if shutil.which('iverilog') and shutil.which('vvp'):
        backend='iverilog'
    elif shutil.which('verilator'):
        backend='verilator'
    else:
        print('P49 RTL NOT RUN: Icarus / Verilator missing (exit 2)',file=sys.stderr)
        return 2
    with tempfile.TemporaryDirectory(prefix='a0_p49_') as tmp:
        tmp=Path(tmp)
        if backend=='iverilog':
            for name, files, run_tb in (
                (TB_TOP,[G/'a0_host_tx_fair_arbiter_p49.sv',TB],True),
                (TOP,BASE,False),
            ):
                out=tmp/(name+'.vvp')
                if run(['iverilog','-g2012','-s',name,'-o',out,*files]):return 1
                if run_tb and run(['vvp',out]):return 1
        else:
            for name, files, run_tb in (
                (TB_TOP,[G/'a0_host_tx_fair_arbiter_p49.sv',TB],True),
                (TOP,BASE,False),
            ):
                obj=tmp/name
                opts=['verilator','--timing','--assert','--top-module',name,'--Mdir',obj]
                opts+=['--binary' if run_tb else '--lint-only']
                if run([*opts,*files]):return 1
                if run_tb and run([obj/('V'+name)]):return 1
    print('P49 RTL PASS (new arbiter simulation and wrapper compile)')
    return 0

if __name__=='__main__':sys.exit(main())
