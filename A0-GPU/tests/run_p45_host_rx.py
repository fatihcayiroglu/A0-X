#!/usr/bin/env python3
"""Strict P45 RTL behavior runner; never reports PASS without a simulator."""
import argparse
from pathlib import Path
import shutil
import subprocess
import sys

ROOT=Path(__file__).resolve().parents[1]
RX=ROOT/'rtl/graphics/a0_host_command_rx_p45.sv'
TB=ROOT/'tests/rtl/a0_host_command_rx_p45_tb.sv'

def main():
    ap=argparse.ArgumentParser()
    ap.add_argument('--build-dir',type=Path,default=ROOT/'build/p45_rx')
    args=ap.parse_args()
    if (sim:=shutil.which('iverilog')) and (runtime:=shutil.which('vvp')):
        args.build_dir.mkdir(parents=True,exist_ok=True)
        artifact=args.build_dir/'p45_rx.vvp'
        cmds=[[sim,'-g2012','-s','a0_host_command_rx_p45_tb','-o',str(artifact),str(RX),str(TB)],
              [runtime,str(artifact)]]
    elif sim:=shutil.which('verilator'):
        args.build_dir.mkdir(parents=True,exist_ok=True)
        cmds=[[sim,'--binary','--timing','--assert','-Wall','--top-module','a0_host_command_rx_p45_tb',
               '--Mdir',str(args.build_dir.resolve()),str(RX),str(TB)],
              [str(args.build_dir.resolve()/'Va0_host_command_rx_p45_tb')]]
    else:
        print('P45 RTL NOT RUN: full Icarus or Verilator simulator not available',file=sys.stderr)
        return 2
    for command in cmds:
        print('+',' '.join(command),flush=True)
        result=subprocess.run(command,cwd=str(ROOT),check=False)
        if result.returncode:
            print(f'P45 RTL FAIL: command exited {result.returncode}',file=sys.stderr)
            return 1
    print('P45 RTL simulation passed')
    return 0

if __name__=='__main__': sys.exit(main())
