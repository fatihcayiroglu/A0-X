#!/usr/bin/env python3
"""P106 host v2 TRIANGLE packet builder / inspector (logical byte protocol).

Example:
  python3 tools/a0_host_triangle_p106.py encode --spec examples/p106/triangle.json --output /tmp/triangle.pkt
  python3 tools/a0_host_triangle_p106.py inspect --input /tmp/triangle.pkt
NOT a device uploader; creates/inspects bytes only.
"""
import argparse
import json
import sys
from pathlib import Path
sys.path.insert(0,str(Path(__file__).resolve().parents[1]/'sim'))
from a0_graphics_command_p43 import Command,TRIANGLE
from a0_p102_fragment_reference import FragmentState
from a0_host_extended_p106 import HostDraw,encode_extended_triangle,decode_host_command

KEYS={'tag','color','vertices','depth','depth_op','depth_write','blend','alpha','scissor'}

def from_json(payload):
    if type(payload) is not dict or set(payload) != KEYS:
        raise ValueError('spec must contain exactly tag/color/vertices/depth/depth_op/depth_write/blend/alpha/scissor')
    vertices=payload['vertices']
    if type(vertices) is not list or len(vertices)!=6:
        raise ValueError('vertices must be 6 signed integers')
    scissor=payload['scissor']
    if scissor is not None and (type(scissor) is not list or len(scissor)!=4):
        raise ValueError('scissor must be null or [x,y,width,height]')
    return HostDraw(Command(TRIANGLE,payload['tag'],payload['color'],tuple(vertices)),
                    payload['depth'],FragmentState(payload['depth_op'],
                    payload['depth_write'],payload['blend'],payload['alpha'],
                    None if scissor is None else tuple(scissor)))

def run(argv=None):
    parser=argparse.ArgumentParser(description='P106 logical TRIANGLE packet builder/inspector')
    sub=parser.add_subparsers(dest='action',required=True)
    encode=sub.add_parser('encode')
    encode.add_argument('--spec',type=Path,required=True)
    encode.add_argument('--output',type=Path,required=True)
    inspect=sub.add_parser('inspect')
    inspect.add_argument('--input',type=Path,required=True)
    args=parser.parse_args(argv)
    try:
        if args.action=='encode':
            draw=from_json(json.loads(args.spec.read_text(encoding='utf-8')))
            data=encode_extended_triangle(draw)
            args.output.write_bytes(data)
            print(f'P106_PACKET_WRITTEN bytes={len(data)}')
        else:
            draw=decode_host_command(args.input.read_bytes())
            s=draw.state
            print(json.dumps({'opcode':draw.command.opcode,'tag':draw.command.tag,
                'color':draw.command.color,'vertices':draw.command.vertices,
                'depth':draw.depth,'depth_op':s.depth_op,'depth_write':s.depth_write,
                'blend':s.blend,'alpha':s.alpha,'scissor':s.scissor},sort_keys=True))
        return 0
    except (OSError,ValueError,TypeError,KeyError) as exc:
        print(f'P106_HOST_ERROR: {exc}',file=sys.stderr)
        return 1

if __name__=='__main__':sys.exit(run())
