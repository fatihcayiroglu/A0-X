#!/usr/bin/env python3
"""Run a genuine Icarus RTL bench then check its emitted packets in Python.

Return 0 only if real compile, real vvp, adversarial bench and independently
CRC-validated packet decoding all succeed. Return 2 if no toolchain exists.
"""
from __future__ import annotations
import re
import shutil
import subprocess
import sys
import tempfile
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
MODULE = ROOT / 'rtl/graphics/a0_scanout_telemetry_loss_fifo_p118.sv'
TB = ROOT / 'tests/rtl/a0_p123_depth3_reset_stream_tb.sv'
MARKER = 'P123_REAL_RTL_DEPTH3_RESET_PASS'
PREFIX = re.compile(r'^P123_PACKET ([0-8]) ([0-9a-f]{64})$')
sys.path.insert(0, str(ROOT/'tools'))
from a0_p122_packet_oracle import decode, frame, loss_notice

EXPECTED = [
    frame(sequence=i, frame_crc=0xA0000001 + i) for i in range(4)
] + [
    frame(sequence=i+4, frame_crc=0xB0000005 + i) for i in range(3)
] + [
    loss_notice(sequence=8, dropped=1),
    frame(sequence=0, frame_crc=0xD000000A),
]


def assess_stream(output: str) -> tuple[bool, str]:
    """Host-side reference verification, not a substitute for actual simulation."""
    lines = output.splitlines()
    if lines.count(MARKER) != 1:
        return False, 'one exact RTL bench completion marker required'
    if lines.count('P123_PARTIAL_DISCARDED 7') != 1:
        return False, 'interrupted reset packet witness absent'
    if any(t in output for t in ('FATAL:', 'NOT_RUN', 'Traceback (most recent call last)')):
        return False, 'failure or skipped simulation indication'
    packet_lines = [line for line in lines if line.startswith('P123_PACKET ')]
    if len(packet_lines) != len(EXPECTED):
        return False, f'{len(EXPECTED)} actual packet lines required'
    for i, line in enumerate(packet_lines):
        match = PREFIX.fullmatch(line)
        if match is None or int(match[1]) != i:
            return False, f'malformed, repeated or re-ordered packet {i}'
        try:
            data = bytes.fromhex(match[2])
            decode(data)  # Independent zlib CRC32 and strict header validation.
        except ValueError as exc:
            return False, f'packet {i} invalid: {exc}'
        if data != EXPECTED[i]:
            return False, f'packet {i} differs from independent reference wire format'
    return True, 'nine valid ordered packets, eight before and one after reset'


def run() -> int:
    if not (shutil.which('iverilog') and shutil.which('vvp')):
        print('P123_REAL_RTL_NOT_RUN: missing Icarus Verilog or vvp', flush=True)
        return 2
    with tempfile.TemporaryDirectory(prefix='a0_p123_real_') as tmp:
        target = Path(tmp)/'sim.vvp'
        try:
            compile_result = subprocess.run(
                ['iverilog','-g2012','-Wall','-s','a0_p123_depth3_reset_stream_tb',
                 '-o',str(target),str(MODULE),str(TB)],
                stdout=subprocess.PIPE,stderr=subprocess.STDOUT,text=True,
                errors='replace',timeout=90)
            print('P123 COMPILE EXIT',compile_result.returncode,flush=True)
            print(compile_result.stdout,flush=True)
            if compile_result.returncode or not target.is_file(): return 1
            sim = subprocess.run(['vvp',str(target)],stdout=subprocess.PIPE,
                                 stderr=subprocess.STDOUT,text=True,
                                 errors='replace',timeout=120)
            print('P123 SIM EXIT',sim.returncode,flush=True)
            print(sim.stdout,flush=True)
            ok,reason = assess_stream(sim.stdout)
            print('P123 INDEPENDENT PACKET ORACLE:',reason,flush=True)
            return 0 if sim.returncode == 0 and ok else 1
        except (OSError,subprocess.TimeoutExpired) as exc:
            print('P123_REAL_RTL_FAILURE',repr(exc),flush=True)
            return 1

if __name__ == '__main__': sys.exit(run())
