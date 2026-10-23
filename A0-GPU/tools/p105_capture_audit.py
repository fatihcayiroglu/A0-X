#!/usr/bin/env python3
"""Strict P105 host-capture audit against independently supplied expectations.

Usage: python3 tools/p105_capture_audit.py --manifest golden.json --capture host.bin
This does not replay SystemVerilog or prove the capture came from a real GPU.
An independent golden image/CRC source is required: deriving the expected CRC
from the capture being audited defeats the purpose of attestation.
"""
import argparse
import json
import sys
from pathlib import Path

sys.path.insert(0,str(Path(__file__).resolve().parents[1]/'sim'))
from a0_graphics_command_p43 import Command
from a0_p105_host_double_bank_reference import audit_capture


def run(manifest: Path, capture: Path):
    data = json.loads(manifest.read_text(encoding='utf-8'))
    if not isinstance(data,dict) or set(data)!={'commands','expected_frame_crc32'}:
        raise ValueError('manifest keys must be commands and expected_frame_crc32')
    if not isinstance(data['commands'],list) or not isinstance(data['expected_frame_crc32'],list):
        raise ValueError('manifest arrays required')
    cmds=[]
    for item in data['commands']:
        if not isinstance(item,dict) or set(item)!={'opcode','tag','color','vertices'}:
            raise ValueError('invalid command shape')
        c=Command(item['opcode'],item['tag'],item['color'],tuple(item['vertices']))
        # Verify P44 canonical constraints before trusting manifest commands.
        from a0_host_protocol_p44 import encode_command
        encode_command(c)
        cmds.append(c)
    crcs=[]
    for v in data['expected_frame_crc32']:
        if isinstance(v,str):
            if not v.startswith('0x'):
                raise ValueError('CRC strings must use 0x notation')
            parsed=int(v,16)
        elif type(v) is int:
            parsed=v
        else:
            raise ValueError('CRC must be u32 or 0x-prefixed hex')
        crcs.append(parsed)
    return audit_capture(cmds,crcs,capture.read_bytes())


def main(argv=None):
    ap=argparse.ArgumentParser(description=__doc__)
    ap.add_argument('--manifest',required=True,type=Path)
    ap.add_argument('--capture',required=True,type=Path)
    args=ap.parse_args(argv)
    try:
        result=run(args.manifest,args.capture)
    except (OSError,ValueError,TypeError,KeyError,IndexError) as exc:
        print(json.dumps({'status':'FAIL','reason':str(exc)},sort_keys=True))
        return 1
    print(json.dumps({'status':'PASS',**result},sort_keys=True))
    return 0

if __name__=='__main__':raise SystemExit(main())
