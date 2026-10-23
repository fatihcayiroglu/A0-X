#!/usr/bin/env python3
"""P125 depth-seven real RTL runner, independent strict packet oracle.

Only actual iverilog compile + vvp simulation + exact 10 packet comparison
can produce exit 0. 1=FAIL, 2=NOT_RUN (missing toolchain).
"""
from __future__ import annotations
import re
import shutil
import subprocess
import sys
import tempfile
from pathlib import Path

ROOT=Path(__file__).resolve().parents[1]
RTL=ROOT/'rtl/graphics/a0_scanout_telemetry_loss_fifo_p118.sv'
TB=ROOT/'tests/rtl/a0_p125_depth7_ring_reset_tb.sv'
PASS='P125_REAL_RTL_DEPTH7_RING_RESET_PASS'
WITNESS='P125_DEPTH7_RING_TWO_LOSS_RESET_EPOCH_WITNESS'
PACKET=re.compile(r'^P125_PACKET ([0-9]) ([0-9a-f]{64})$')
PREFIX=re.compile(r'^P125_DISCARDED_PREFIX ([0-9a-f]{18})$')
sys.path.insert(0,str(ROOT/'tools'))
from a0_p122_packet_oracle import frame,loss_notice,decode

EXPECTED=[frame(sequence=k,frame_crc=0xC4000001+k,error=bool(k%2),
                good=10,bad=20,aborted=30) for k in range(7)]
EXPECTED += [loss_notice(sequence=8,dropped=1,good=40,bad=50,aborted=60),
             loss_notice(sequence=9,dropped=2,good=40,bad=50,aborted=60)]
ABORTED=frame(sequence=9,frame_crc=0xC600000A,error=True,
              good=100,bad=200,aborted=300,dropped=2)
NEW=frame(sequence=0,frame_crc=0xD600000B,error=False,
          good=4,bad=5,aborted=6)
EXPECTED.append(NEW)


def assess_stream(text: str)->tuple[bool,str]:
    lines=text.splitlines()
    if lines.count(PASS)!=1 or lines.count(WITNESS)!=1:
        return False,'required unique simulator witness marker missing'
    if any(x in text for x in ('FATAL:','NOT_RUN','Traceback (most recent call last)')):
        return False,'simulator error or skip may not qualify'
    packets=[s for s in lines if s.startswith('P125_PACKET ')]
    if len(packets)!=10:return False,'expected exactly ten complete packet witnesses'
    for idx,line in enumerate(packets):
        m=PACKET.fullmatch(line)
        if m is None or int(m[1])!=idx:return False,f'packet index {idx} invalid'
        try:
            raw=bytes.fromhex(m[2])
            decode(raw)
        except ValueError as exc:return False,f'packet {idx} invalid: {exc}'
        if raw!=EXPECTED[idx]:return False,f'packet {idx} mismatched CRC/sequence/data'
    prefixes=[s for s in lines if s.startswith('P125_DISCARDED_PREFIX ')]
    if len(prefixes)!=1:return False,'need exactly one partial-packet reset witness'
    m=PREFIX.fullmatch(prefixes[0])
    if m is None or bytes.fromhex(m[1])!=ABORTED[:9]:
        return False,'pre-reset transmitted prefix mismatch'
    return True,'ten wire-exact CRC packets and isolated nine-byte reset prefix'


def run()->int:
    if not (shutil.which('iverilog') and shutil.which('vvp')):
        print('P125_REAL_RTL_NOT_RUN: iverilog/vvp missing',flush=True)
        return 2
    with tempfile.TemporaryDirectory(prefix='a0_p125_') as tmp:
        image=Path(tmp)/'p125.vvp'
        try:
            compile_=subprocess.run(['iverilog','-g2012','-Wall','-s',
                'a0_p125_depth7_ring_reset_tb','-o',str(image),str(RTL),str(TB)],
                capture_output=True,text=True,errors='replace',timeout=90)
            print('P125 COMPILE EXIT',compile_.returncode)
            print(compile_.stdout+compile_.stderr,flush=True)
            if compile_.returncode!=0 or not image.is_file():return 1
            sim=subprocess.run(['vvp',str(image)],capture_output=True,text=True,
                               errors='replace',timeout=120)
            print('P125 SIM EXIT',sim.returncode)
            print(sim.stdout+sim.stderr,flush=True)
            passed,explanation=assess_stream(sim.stdout+sim.stderr)
            print('P125 INDEPENDENT PACKET ORACLE:',explanation,flush=True)
            return 0 if sim.returncode==0 and passed else 1
        except (OSError,subprocess.TimeoutExpired) as exc:
            print('P125_REAL_RTL_FAILURE:',repr(exc),flush=True)
            return 1

if __name__=='__main__':sys.exit(run())
