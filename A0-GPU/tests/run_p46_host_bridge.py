#!/usr/bin/env python3
"""P46 fail-closed RTL simulation gate. Exit 2 when HDL toolchain unavailable."""
from pathlib import Path
import argparse
import shutil
import subprocess
import sys
import tempfile

ROOT = Path(__file__).resolve().parents[1]
GFX = ROOT/'rtl'/'graphics'
RTLTB = ROOT/'tests'/'rtl'
TX = GFX/'a0_host_result_tx_p46.sv'
RECEIVER = GFX/'a0_host_command_rx_p45.sv'
BRIDGE = GFX/'a0_host_graphics_bridge_p46.sv'
P43_GRAPHICS = [GFX/n for n in (
    'a0_triangle_coverage_p38.sv',
    'a0_sync_frame_ram_p42.sv',
    'a0_sync_frame_scanout_p42.sv',
    'a0_triangle_double_buffer_sync_display_p42.sv',
    'a0_graphics_command_frontend_p43.sv',
    'a0_command_triangle_sync_display_p43.sv'
)]
GATES = [
    ('a0_host_result_tx_p46_tb', [TX]),
    ('a0_host_graphics_bridge_p46_tb', [TX, RECEIVER, BRIDGE, *P43_GRAPHICS]),
]

def main():
    ap=argparse.ArgumentParser()
    ap.add_argument('--build-dir',type=Path,default=None,
                    help='Optional local output directory (default: temporary)')
    args=ap.parse_args()
    if shutil.which('iverilog') and shutil.which('vvp'):
        backend='iverilog'
    elif shutil.which('verilator'):
        backend='verilator'
    else:
        print('P46 RTL NOT RUN: no complete Icarus or Verilator simulator present',file=sys.stderr)
        return 2
    temp = tempfile.TemporaryDirectory(prefix='p46_rtl_') if args.build_dir is None else None
    try:
        outdir = Path(temp.name) if temp else args.build_dir
        outdir.mkdir(parents=True,exist_ok=True)
        for top,srcs in GATES:
            tb = RTLTB/(top+'.sv')
            if backend=='iverilog':
                target=outdir/(top+'.vvp')
                build=['iverilog','-g2012','-s',top,'-o',str(target),*map(str,srcs),str(tb)]
                execute=['vvp',str(target)]
            else:
                objdir=(outdir/top).resolve()
                build=['verilator','--binary','--timing','--assert','--top-module',top,
                       '--Mdir',str(objdir),*map(str,srcs),str(tb)]
                execute=[str(objdir/('V'+top))]
            for command in (build,execute):
                print('+',' '.join(command),flush=True)
                done=subprocess.run(command,cwd=ROOT,check=False)
                if done.returncode:
                    print(f'P46 RTL FAIL: {top} exited {done.returncode}',file=sys.stderr)
                    return 1
            print(f'P46 RTL PASS: {top}',flush=True)
        print('P46 RTL suite PASS: both testbenches executed',flush=True)
        return 0
    finally:
        if temp:temp.cleanup()

if __name__=='__main__':sys.exit(main())
