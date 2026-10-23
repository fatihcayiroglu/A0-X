#!/usr/bin/env python3
"""P55 software-dual-oracle check + P54 byte capture validation.

No claim about origin of capture: synthetic, RTL and hardware all require
independent provenance. P55 compares software models, NOT two devices.
"""
from __future__ import annotations
import argparse
import json
from pathlib import Path
import sys

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT / 'sim'))
sys.path.insert(0, str(ROOT / 'tools'))
import a0_p54_multiframe_attestation as p54
from a0_host_p44 import load_script, parse_script
from a0_independent_graphics_oracle_p55 import render_commands


class OracleMismatch(ValueError):
    pass


def check_oracles(script: dict) -> dict:
    ref = p54.reference(script)
    width, height, commands = parse_script(script)
    direct = render_commands(width, height, commands)
    if len(direct) != len(ref['frames']):
        raise OracleMismatch('P55 independent frame count disagrees with P54 reference')
    for i, (actual, expected) in enumerate(zip(direct, ref['frames'])):
        for field in ('present_tag', 'frame_crc32', 'rgb_sha256'):
            if actual[field] != expected[field]:
                raise OracleMismatch(f'P55 independent oracle disagrees on frame {i}: {field}')
    return {'status':'PASS','frame_count':len(direct),
            'kind':'P55_TWO_INDEPENDENT_SOFTWARE_GRAPHICS_ORACLES',
            'evidence_level':'SOFTWARE_ONLY_NOT_RTL_OR_HARDWARE'}


def attest(script: dict, capture: bytes, *, chunk_size=7):
    # Must check independence FIRST; P54 output alone can be self-consistent
    # while wrong if its software reference regresses.
    independent = check_oracles(script)
    result = p54.attest(script,capture,chunk_size=chunk_size)
    result['kind'] = 'A0_P55_DUAL_ORACLE_EXTERNAL_BYTE_CHECK'
    result['independent_oracle'] = independent
    return result


def main(argv=None):
    ap=argparse.ArgumentParser(description=__doc__)
    ap.add_argument('--script',required=True,type=Path)
    ap.add_argument('--capture',type=Path,help='external host-capture bytes, provenance separate')
    ap.add_argument('--report',type=Path)
    args=ap.parse_args(argv)
    try:
        script=load_script(args.script)
        if args.capture is None:
            result=check_oracles(script)
        else:
            if args.capture.stat().st_size > p54.MAX_CAPTURE_BYTES:
                raise ValueError('capture exceeds 16 MiB')
            result=attest(script,args.capture.read_bytes())
        if args.report:
            args.report.parent.mkdir(parents=True,exist_ok=True)
            args.report.write_text(json.dumps(result,indent=2,sort_keys=True)+'\n',encoding='utf-8')
        else:
            print(json.dumps(result,indent=2,sort_keys=True))
        return 0 if result['status']=='PASS' else 1
    except (OSError,ValueError,RuntimeError) as exc:
        print('P55 REJECTED: '+str(exc),file=sys.stderr)
        return 2

if __name__=='__main__':
    raise SystemExit(main())
