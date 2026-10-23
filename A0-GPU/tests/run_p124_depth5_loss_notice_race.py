#!/usr/bin/env python3
"""P124: run actual Icarus bench, then independent CRC-checked eight-packet oracle.

Exit 0 only for real compile+simulation+byte-exact oracle, 1 for FAIL,
2 for NOT_RUN (missing simulator). The oracle alone is never RTL proof.
"""
from __future__ import annotations
import re
import shutil
import subprocess
import sys
import tempfile
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
MODULE = ROOT/'rtl/graphics/a0_scanout_telemetry_loss_fifo_p118.sv'
TB = ROOT/'tests/rtl/a0_p124_depth5_loss_notice_race_tb.sv'
MARKER = 'P124_REAL_RTL_DEPTH5_LOSS_RACE_PASS'
RACE = 'P124_DEPTH5_TWO_GENERATIONS_OF_LOSS_NOTICES'
PACKET = re.compile(r'^P124_PACKET ([0-7]) ([0-9a-f]{64})$')
sys.path.insert(0,str(ROOT/'tools'))
from a0_p122_packet_oracle import frame,loss_notice,decode

EXPECTED = [frame(sequence=k,frame_crc=0xA5000001+k,error=bool(k%2),
                  good=11,bad=22,aborted=33) for k in range(5)] + [
    loss_notice(sequence=6,dropped=1,good=99,bad=98,aborted=97),
    loss_notice(sequence=7,dropped=2,good=99,bad=98,aborted=97),
    frame(sequence=7,frame_crc=0xC5000003,error=True,
          good=123,bad=124,aborted=125,dropped=2),
]


def assess_stream(output: str) -> tuple[bool,str]:
    lines=output.splitlines()
    if lines.count(MARKER)!=1 or lines.count(RACE)!=1:
        return False,'missing or duplicate RTL race witness marker'
    if any(token in output for token in ('FATAL:', 'NOT_RUN',
                                          'Traceback (most recent call last)')):
        return False,'failed or skipped RTL run cannot qualify'
    packets=[line for line in lines if line.startswith('P124_PACKET ')]
    if len(packets)!=len(EXPECTED):
        return False,'expected eight and only eight wire packets'
    for i,line in enumerate(packets):
        match=PACKET.fullmatch(line)
        if match is None or int(match[1])!=i:
            return False,f'packet {i}: malformed order or hex encoding'
        raw=bytes.fromhex(match[2])
        try:
            decode(raw) # independent standard-library zlib CRC and strict fields
        except ValueError as exc:
            return False,f'packet {i}: {exc}'
        if raw!=EXPECTED[i]:
            return False,f'packet {i}: mismatched cumulative drop, sequence or snapshot'
    return True,'eight ordered CRC-checked packets; loss 1 then 2, both retained'


def run() -> int:
    if not (shutil.which('iverilog') and shutil.which('vvp')):
        print('P124_REAL_RTL_NOT_RUN: iverilog/vvp missing',flush=True)
        return 2
    with tempfile.TemporaryDirectory(prefix='a0_p124_') as d:
        target=Path(d)/'test.vvp'
        try:
            comp=subprocess.run(['iverilog','-g2012','-Wall','-s',
                      'a0_p124_depth5_loss_notice_race_tb','-o',str(target),
                      str(MODULE),str(TB)],capture_output=True,
                      text=True,errors='replace',timeout=90)
            print('P124 COMPILE EXIT',comp.returncode,flush=True)
            print(comp.stdout+comp.stderr,flush=True)
            if comp.returncode!=0 or not target.is_file():return 1
            sim=subprocess.run(['vvp',str(target)],capture_output=True,
                     text=True,errors='replace',timeout=120)
            print('P124 SIM EXIT',sim.returncode,flush=True)
            print(sim.stdout+sim.stderr,flush=True)
            ok,reason=assess_stream(sim.stdout+sim.stderr)
            print('P124 INDEPENDENT PACKET ORACLE:',reason,flush=True)
            return 0 if sim.returncode==0 and ok else 1
        except (OSError,subprocess.TimeoutExpired) as exc:
            print('P124_REAL_RTL_FAILURE:',repr(exc),flush=True)
            return 1

if __name__=='__main__':sys.exit(run())
