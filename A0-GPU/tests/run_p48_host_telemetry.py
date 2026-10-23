#!/usr/bin/env python3
"""P48 RTL verification; fail closed on missing HDL tools (exit 2)."""
from pathlib import Path
import shutil
import subprocess
import sys
import tempfile
import json
from datetime import datetime, timezone

ROOT=Path(__file__).resolve().parents[1]
G=ROOT/'rtl'/'graphics'
TB=ROOT/'tests'/'rtl'
SOURCES=[G/x for x in (
 'a0_triangle_coverage_p38.sv', 'a0_sync_frame_ram_p42.sv',
 'a0_sync_frame_scanout_p42.sv','a0_triangle_double_buffer_sync_display_p42.sv',
 'a0_graphics_command_frontend_p43.sv','a0_command_triangle_sync_display_p43.sv',
 'a0_host_command_rx_p45.sv','a0_host_result_tx_p46.sv',
 'a0_host_graphics_bridge_p46.sv','a0_scanout_frame_guard_p47.sv',
 'a0_host_graphics_crc_bridge_p47.sv',
 'a0_scanout_telemetry_tx_p48.sv','a0_host_tx_frame_arbiter_p48.sv',
 'a0_host_graphics_telemetry_bridge_p48.sv')]
TESTS=[
 ('a0_scanout_telemetry_tx_p48_tb',[G/'a0_scanout_telemetry_tx_p48.sv']),
 ('a0_host_tx_frame_arbiter_p48_tb',[G/'a0_host_tx_frame_arbiter_p48.sv'])]


def main():
    if shutil.which('iverilog') and shutil.which('vvp'):
        backend='iverilog'
    elif shutil.which('verilator'):
        backend='verilator'
    else:
        print('P48 RTL NOT RUN: no Icarus/Verilator; exit 2',file=sys.stderr)
        return 2
    with tempfile.TemporaryDirectory(prefix='a0_p48_') as temp:
        for top, sources in TESTS + [('a0_host_graphics_telemetry_bridge_p48',SOURCES)]:
            compile_only=top=='a0_host_graphics_telemetry_bridge_p48'
            if backend=='iverilog':
                binary=Path(temp)/(top+'.vvp')
                args=['iverilog','-g2012','-s',top,'-o',str(binary),*map(str,sources)]
                if compile_only: args += ['-tnull']
                else: args += [str(TB/(top+'.sv'))]
                commands=[args] + ([] if compile_only else [['vvp',str(binary)]])
            else:
                obj=Path(temp)/top
                args=['verilator','--timing','--assert',
                      '--top-module',top,'--Mdir',str(obj)]
                if compile_only: args += ['--lint-only']
                else: args += ['--binary']
                args += [*map(str,sources)]
                if not compile_only: args += [str(TB/(top+'.sv'))]
                commands=[args] + ([] if compile_only else [[str(obj/('V'+top))]])
            for cmd in commands:
                print('+', ' '.join(cmd),flush=True)
                p=subprocess.run(cmd,cwd=ROOT,check=False)
                if p.returncode:
                    print('P48 RTL FAIL',top,'exit',p.returncode,file=sys.stderr)
                    return 1
            print('P48 RTL PASS:',top)
    return 0

if __name__=='__main__': sys.exit(main())
