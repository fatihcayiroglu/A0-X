#!/usr/bin/env python3
"""Fail-closed P47 RTL gate, return 2 when HDL simulator unavailable."""
from pathlib import Path
import argparse
import shutil
import subprocess
import sys
import tempfile

ROOT = Path(__file__).resolve().parents[1]
GFX = ROOT / 'rtl' / 'graphics'
TB = ROOT / 'tests' / 'rtl'

SOURCES = [GFX / name for name in (
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
    'a0_host_graphics_crc_bridge_p47.sv'
)]
GATES = [
    ('a0_scanout_frame_guard_p47_tb', [GFX/'a0_scanout_frame_guard_p47.sv']),
    ('a0_host_graphics_crc_bridge_p47_tb', SOURCES),
]


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument('--build-dir', type=Path, default=None)
    args = ap.parse_args()
    if shutil.which('iverilog') and shutil.which('vvp'):
        backend = 'iverilog'
    elif shutil.which('verilator'):
        backend = 'verilator'
    else:
        print('P47 RTL NOT RUN: no Icarus or Verilator binary found',file=sys.stderr)
        return 2
    with tempfile.TemporaryDirectory(prefix='a0_p47_') as temp:
        builddir = args.build_dir or Path(temp)
        builddir.mkdir(parents=True, exist_ok=True)
        for top, sources in GATES:
            if backend == 'iverilog':
                executable = builddir / (top + '.vvp')
                commands = [
                    ['iverilog','-g2012','-s',top,'-o',str(executable),
                     *map(str,sources),str(TB/(top+'.sv'))],
                    ['vvp',str(executable)]
                ]
            else:
                objdir = (builddir / top).resolve()
                commands = [
                    ['verilator','--binary','--timing','--assert',
                     '--top-module',top,'--Mdir',str(objdir),
                     *map(str,sources),str(TB/(top+'.sv'))],
                    [str(objdir / ('V'+top))]
                ]
            for command in commands:
                print('+',' '.join(command),flush=True)
                status = subprocess.run(command,cwd=ROOT,check=False).returncode
                if status:
                    print('P47 RTL FAIL:',top,'code',status,file=sys.stderr)
                    return 1
            print('P47 RTL PASS:',top)
    print('P47 RTL PASS: 2 benches')
    return 0


if __name__ == '__main__':
    sys.exit(main())
